--!strict
--[[
	PartyService
	------------
	Groups of up to four runners, and the small advantages of running together.

	Design position: a party is a social convenience first and a mechanical bonus
	second. The bonuses are deliberately modest — a quarter more experience at full
	strength, a slightly better chance at a shared drop — because a bonus large
	enough to matter is a bonus that punishes playing alone, and this game's core
	loop is a solo one that happens to be better with company.

	Everything here is session-scoped. A party is a fact about this server right
	now, not something persisted to a profile, so there is no migration, no stale
	membership to reconcile on load, and a server restart cleanly dissolves
	everything. The cost is that a party does not survive a rejoin, which is the
	correct trade: reconstituting a group across servers is a feature with a much
	larger surface than the benefit it buys.

	Invites are held server-side with an expiry, never trusted from the client, and
	the inviter's authority is re-checked at the moment of acceptance rather than at
	the moment of sending — a leader can leave, and their invite must not still be
	able to add someone to a party they no longer belong to.
]]

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BTS")
local Signal = require(Shared.Core.Signal)
local Net = require(Shared.Net)
local Balance = require(Shared.Config.Balance)

local PartyService = {}
PartyService.Name = "PartyService"
PartyService.Dependencies = { "DataService" }
PartyService.Priority = 50

local MAX_SIZE = Balance.Party.MAX_SIZE
local SHARE_RADIUS_SQUARED = Balance.Party.SHARE_RADIUS * Balance.Party.SHARE_RADIUS
local INVITE_EXPIRY = Balance.Party.INVITE_EXPIRY_SECONDS

function PartyService:Init()
	-- partyId -> { id, leaderId, members = { userId, ... }, createdAt }
	self._parties = {}
	-- userId -> partyId
	self._membership = {}
	-- inviteId -> { fromUserId, toUserId, partyId, expiresAt }
	self._invites = {}
	-- userId -> count of invites currently addressed to them, to cap spam cheaply
	self._pendingTo = {}

	self.PartyFormed = Signal.new("PartyService.PartyFormed")
	self.PartyChanged = Signal.new("PartyService.PartyChanged")
	self.PartyDissolved = Signal.new("PartyService.PartyDissolved")

	self._sweepAccumulator = 0
end

function PartyService:Start()
	self._data = self.Registry:Get("DataService")
	self._analytics = self.Registry:Find("AnalyticsService")

	Net.OnServerEvent("RequestInviteToParty", function(player, targetUserId)
		self:Invite(player, targetUserId)
	end)

	Net.OnServerEvent("RequestRespondToInvite", function(player, inviteId, accept)
		self:RespondToInvite(player, inviteId, accept)
	end)

	Net.OnServerEvent("RequestLeaveParty", function(player)
		self:Leave(player)
	end)

	Players.PlayerRemoving:Connect(function(player)
		self:_onPlayerLeft(player.UserId)
	end)
end

-- ============================================================================
-- Queries
-- ============================================================================

function PartyService:GetPartyId(userId: number): string?
	return self._membership[userId]
end

function PartyService:GetParty(partyId: string?)
	return partyId and self._parties[partyId] or nil
end

function PartyService:GetPartyFor(player: Player)
	return self:GetParty(self._membership[player.UserId])
end

--[[ Every other member of a player's party, as Player instances still present. ]]
function PartyService:GetMembers(player: Player): { Player }
	local party = self:GetPartyFor(player)
	if not party then
		return {}
	end

	local members = {}
	for _, userId in ipairs(party.members) do
		local other = Players:GetPlayerByUserId(userId)
		if other then
			table.insert(members, other)
		end
	end
	return members
end

--[[
	Members close enough to share benefits, excluding the player themselves.
	Distance is what makes the bonus honest: a party member parked at a bank on the
	other side of the region is not helping.
]]
function PartyService:GetNearbyMembers(player: Player): { Player }
	local origin = self:_positionOf(player)
	if not origin then
		return {}
	end

	local nearby = {}
	for _, other in ipairs(self:GetMembers(player)) do
		if other ~= player then
			local position = self:_positionOf(other)
			if position and (position - origin).Magnitude <= Balance.Party.SHARE_RADIUS then
				table.insert(nearby, other)
			end
		end
	end
	return nearby
end

function PartyService:_positionOf(player: Player): Vector3?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return root and (root :: BasePart).Position or nil
end

--[[ Experience multiplier from nearby party members. 1.0 when alone. ]]
function PartyService:GetXpMultiplier(player: Player): number
	local nearby = #self:GetNearbyMembers(player)
	if nearby <= 0 then
		return 1
	end
	return 1 + math.min(nearby * Balance.Party.XP_BONUS_PER_MEMBER, Balance.Party.MAX_XP_BONUS)
end

--[[ Additive luck from nearby party members, applied by LootService. ]]
function PartyService:GetSharedLuck(player: Player): number
	return #self:GetNearbyMembers(player) * Balance.Party.SHARED_LUCK_PER_MEMBER
end

-- ============================================================================
-- Invites
-- ============================================================================

function PartyService:Invite(player: Player, targetUserId: number): (boolean, string?)
	local target = Players:GetPlayerByUserId(targetUserId)
	if not target then
		return self:_refuse(player, "That runner is not on this server.")
	end
	if target == player then
		return self:_refuse(player, "You cannot invite yourself.")
	end

	if self._membership[targetUserId] then
		return self:_refuse(player, target.DisplayName .. " is already in a party.")
	end

	-- The inviter's party may not exist yet; forming it lazily on acceptance would
	-- mean an invite that cannot state how many seats are left.
	local partyId = self._membership[player.UserId]
	local party = self:GetParty(partyId)

	if party then
		if party.leaderId ~= player.UserId then
			return self:_refuse(player, "Only the party leader can invite.")
		end
		if #party.members >= MAX_SIZE then
			return self:_refuse(player, "The party is full.")
		end
	end

	-- Cap invites addressed at one person rather than invites sent by one person:
	-- the harm being prevented is a player buried in popups, not a player who is
	-- generous with invitations.
	local pending = self._pendingTo[targetUserId] or 0
	if pending >= Balance.Party.MAX_PENDING_INVITES then
		return self:_refuse(player, target.DisplayName .. " has too many pending invites.")
	end

	for _, invite in pairs(self._invites) do
		if invite.fromUserId == player.UserId and invite.toUserId == targetUserId then
			return self:_refuse(player, "You have already invited " .. target.DisplayName .. ".")
		end
	end

	local inviteId = HttpService:GenerateGUID(false)
	self._invites[inviteId] = {
		id = inviteId,
		fromUserId = player.UserId,
		toUserId = targetUserId,
		-- Stored, but re-validated on acceptance: the party can change or vanish
		-- between sending and answering.
		partyId = partyId,
		expiresAt = os.clock() + INVITE_EXPIRY,
	}
	self._pendingTo[targetUserId] = pending + 1

	Net.FireClient(target, "PartyUpdate", {
		kind = "invite",
		inviteId = inviteId,
		fromUserId = player.UserId,
		fromName = player.DisplayName,
		partySize = party and #party.members or 1,
		maxSize = MAX_SIZE,
		expiresIn = INVITE_EXPIRY,
	})

	Net.FireClient(player, "PartyUpdate", {
		kind = "invite_sent",
		toName = target.DisplayName,
	})

	return true, nil
end

function PartyService:RespondToInvite(player: Player, inviteId: string, accept: boolean): (boolean, string?)
	local invite = self._invites[inviteId]
	if not invite or invite.toUserId ~= player.UserId then
		-- Silent on a wrong id: an invite that has expired is the common case and
		-- does not deserve an error popup.
		return false, "unknown_invite"
	end

	self:_removeInvite(inviteId)

	if not accept then
		local inviter = Players:GetPlayerByUserId(invite.fromUserId)
		if inviter then
			Net.FireClient(inviter, "PartyUpdate", {
				kind = "invite_declined",
				byName = player.DisplayName,
			})
		end
		return true, nil
	end

	local inviter = Players:GetPlayerByUserId(invite.fromUserId)
	if not inviter then
		return self:_refuse(player, "They left before you answered.")
	end

	if self._membership[player.UserId] then
		return self:_refuse(player, "You are already in a party.")
	end

	-- Re-checked here rather than trusted from the invite: the inviter may have
	-- joined someone else's party, left, or filled their own since sending.
	local party = self:GetParty(self._membership[invite.fromUserId])

	if not party then
		party = self:_createParty(inviter)
	elseif #party.members >= MAX_SIZE then
		return self:_refuse(player, "That party filled up.")
	end

	self:_addMember(party, player.UserId)
	self:_broadcast(party)

	if self._analytics then
		self._analytics:Track(player, "party_joined", { size = #party.members })
	end

	return true, nil
end

function PartyService:_removeInvite(inviteId: string)
	local invite = self._invites[inviteId]
	if not invite then
		return
	end
	self._invites[inviteId] = nil

	local pending = (self._pendingTo[invite.toUserId] or 1) - 1
	self._pendingTo[invite.toUserId] = pending > 0 and pending or nil
end

-- ============================================================================
-- Membership
-- ============================================================================

function PartyService:_createParty(leader: Player)
	local partyId = HttpService:GenerateGUID(false)
	local party = {
		id = partyId,
		leaderId = leader.UserId,
		members = { leader.UserId },
		createdAt = os.clock(),
	}

	self._parties[partyId] = party
	self._membership[leader.UserId] = partyId
	self.PartyFormed:Fire(partyId, leader)

	return party
end

function PartyService:_addMember(party: any, userId: number)
	table.insert(party.members, userId)
	self._membership[userId] = party.id
	self.PartyChanged:Fire(party.id)
end

function PartyService:Leave(player: Player): boolean
	return self:_removeMember(player.UserId)
end

function PartyService:_removeMember(userId: number): boolean
	local partyId = self._membership[userId]
	local party = self:GetParty(partyId)
	if not party then
		return false
	end

	self._membership[userId] = nil

	local index = table.find(party.members, userId)
	if index then
		table.remove(party.members, index)
	end

	-- A party of one is not a party. Dissolving it rather than leaving a lone
	-- member in a group of one means "am I in a party?" has one honest answer.
	if #party.members <= 1 then
		for _, remainingId in ipairs(party.members) do
			self._membership[remainingId] = nil
			local remaining = Players:GetPlayerByUserId(remainingId)
			if remaining then
				Net.FireClient(remaining, "PartyUpdate", { kind = "dissolved" })
			end
		end

		self._parties[party.id] = nil
		self:_cancelInvitesFor(party.id)
		self.PartyDissolved:Fire(party.id)
		return true
	end

	-- Leadership passes to the longest-standing remaining member rather than
	-- dissolving the group when a leader leaves.
	if party.leaderId == userId then
		party.leaderId = party.members[1]
	end

	self.PartyChanged:Fire(party.id)
	self:_broadcast(party)

	local leaver = Players:GetPlayerByUserId(userId)
	if leaver then
		Net.FireClient(leaver, "PartyUpdate", { kind = "left" })
	end

	return true
end

function PartyService:_onPlayerLeft(userId: number)
	self:_removeMember(userId)

	-- Invites in either direction die with the player.
	for inviteId, invite in pairs(self._invites) do
		if invite.fromUserId == userId or invite.toUserId == userId then
			self:_removeInvite(inviteId)
		end
	end

	self._pendingTo[userId] = nil
end

function PartyService:_cancelInvitesFor(partyId: string)
	for inviteId, invite in pairs(self._invites) do
		if invite.partyId == partyId then
			self:_removeInvite(inviteId)
		end
	end
end

function PartyService:_refuse(player: Player, reason: string): (boolean, string)
	Net.FireClient(player, "PartyUpdate", { kind = "refused", reason = reason })
	return false, reason
end

-- ============================================================================
-- Replication
-- ============================================================================

function PartyService:BuildView(party: any)
	local members = {}

	for _, userId in ipairs(party.members) do
		local player = Players:GetPlayerByUserId(userId)
		if not player then
			continue
		end

		local profile = self._data:GetProfile(player)
		table.insert(members, {
			userId = userId,
			name = player.DisplayName,
			level = profile and profile.level or 1,
			isLeader = userId == party.leaderId,
		})
	end

	return {
		kind = "party",
		partyId = party.id,
		leaderId = party.leaderId,
		members = members,
		maxSize = MAX_SIZE,
	}
end

function PartyService:_broadcast(party: any)
	local view = self:BuildView(party)
	for _, userId in ipairs(party.members) do
		local player = Players:GetPlayerByUserId(userId)
		if player then
			Net.FireClient(player, "PartyUpdate", view)
		end
	end
end

--[[ Expires invites nobody answered. ]]
function PartyService:Tick()
	local now = os.clock()

	for inviteId, invite in pairs(self._invites) do
		if now >= invite.expiresAt then
			self:_removeInvite(inviteId)

			local target = Players:GetPlayerByUserId(invite.toUserId)
			if target then
				Net.FireClient(target, "PartyUpdate", { kind = "invite_expired", inviteId = inviteId })
			end
		end
	end

	-- Party membership is re-broadcast periodically rather than on every change to
	-- a member's level: the panel shows levels, and a level-up is not worth its own
	-- targeted message to three other clients.
	self._sweepAccumulator += 0.5
	if self._sweepAccumulator >= 10 then
		self._sweepAccumulator = 0
		for _, party in pairs(self._parties) do
			self:_broadcast(party)
		end
	end
end

function PartyService:GetStats()
	local parties, members, invites = 0, 0, 0
	for _, party in pairs(self._parties) do
		parties += 1
		members += #party.members
	end
	for _ in pairs(self._invites) do
		invites += 1
	end
	return { parties = parties, members = members, pendingInvites = invites }
end

return PartyService
