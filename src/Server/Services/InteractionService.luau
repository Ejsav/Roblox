--!strict
--[[
	InteractionService
	------------------
	Everything the player walks up to and uses: bank stations, fast travel relays,
	quest objects, sealed gates, world-event nodes and dropped caches.

	The client detects proximity and shows the prompt because that has to be
	instant; the server re-checks distance, ownership and state on every request
	because the client is not trusted with anything that changes value.

	Interactables are registered by the world builder rather than declared here, so
	the world can add one without this service knowing what it is.
]]

local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BTS")
local Signal = require(Shared.Core.Signal)
local Net = require(Shared.Net)
local Regions = require(Shared.Config.Regions)
local Balance = require(Shared.Config.Balance)

local InteractionService = {}
InteractionService.Name = "InteractionService"
InteractionService.Dependencies = { "DataService", "BankService", "RegionService", "QuestService" }
InteractionService.Priority = 55

--[[ How close a player must be, per interactable kind. Generous, because a
     prompt that appears and then refuses is worse than no prompt. ]]
local RANGES = {
	bank = 26,
	fast_travel = 20,
	quest_object = 14,
	gate = 18,
	event_node = 20,
	cache = Balance.Carry.DEATH_CACHE_RECOVERY_RADIUS,
	workbench = 16,
}

function InteractionService:Init()
	-- id -> { id, kind, position, regionId, data, enabled }
	self._interactables = {}
	self._caches = {}
	self._lastFastTravelAt = {} :: { [number]: number }

	self.Interacted = Signal.new("InteractionService.Interacted")
end

function InteractionService:Start()
	self._data = self.Registry:Get("DataService")
	self._bank = self.Registry:Get("BankService")
	self._regions = self.Registry:Get("RegionService")
	self._quests = self.Registry:Get("QuestService")
	self._carry = self.Registry:Find("CarryService")
	self._economy = self.Registry:Find("EconomyService")
	self._progression = self.Registry:Find("ProgressionService")
	self._events = self.Registry:Find("WorldEventService")
	self._antiCheat = self.Registry:Find("AntiCheatService")
	self._analytics = self.Registry:Find("AnalyticsService")

	Net.OnServerEvent("RequestFastTravel", function(player, nodeId)
		self:FastTravel(player, nodeId)
	end)

	Net.OnServerEvent("RequestInteract", function(player, id)
		self:Interact(player, id)
	end)

	-- The manifest is sent once the world exists, and again to anyone who joins
	-- afterwards, so a client always knows what it can walk up to.
	self._data.ProfileLoaded:Connect(function(player)
		task.defer(function()
			Net.FireClient(player, "InteractionManifest", self:BuildClientManifest())
		end)
	end)

	-- Fast travel nodes come from the atlas, so they exist whether or not the world
	-- generator has finished placing their geometry.
	for _, region in ipairs(Regions.List) do
		if region.fastTravel then
			self:Register({
				id = region.fastTravel.id,
				kind = "fast_travel",
				position = Vector3.new(
					region.fastTravel.position.X,
					region.fastTravel.position.Y,
					region.fastTravel.position.Z
				),
				regionId = region.id,
				data = { name = region.fastTravel.name },
			})
		end
		for _, station in ipairs(region.bankStations) do
			self:Register({
				id = station.id,
				kind = "bank",
				position = Vector3.new(station.position.X, station.position.Y, station.position.Z),
				regionId = region.id,
				data = { name = station.name, tier = station.tier },
			})
		end
	end
end

-- ============================================================================
-- Registration
-- ============================================================================

function InteractionService:Register(definition: {
	id: string,
	kind: string,
	position: Vector3,
	regionId: string?,
	data: any?,
	tag: string?,
})
	self._interactables[definition.id] = {
		id = definition.id,
		kind = definition.kind,
		position = definition.position,
		regionId = definition.regionId,
		data = definition.data or {},
		tag = definition.tag,
		enabled = true,
	}
	return self._interactables[definition.id]
end

function InteractionService:Unregister(id: string)
	self._interactables[id] = nil
end

function InteractionService:SetEnabled(id: string, enabled: boolean)
	local entry = self._interactables[id]
	if entry then
		entry.enabled = enabled
	end
end

function InteractionService:Get(id: string)
	return self._interactables[id]
end

--[[
	Everything within range of a position, for the client's prompt resolver.
	Returned sorted by distance so the client can take the first without sorting.
]]
function InteractionService:GetNearby(position: Vector3, maxRange: number?)
	local found = {}
	for _, entry in ipairs(self:_asList()) do
		if not entry.enabled then
			continue
		end
		local range = maxRange or RANGES[entry.kind] or 16
		local distance = (entry.position - position).Magnitude
		if distance <= range then
			table.insert(found, { entry = entry, distance = distance })
		end
	end
	table.sort(found, function(a, b)
		return a.distance < b.distance
	end)
	return found
end

function InteractionService:_asList()
	local list = {}
	for _, entry in pairs(self._interactables) do
		table.insert(list, entry)
	end
	return list
end

--[[ Server-side range check, run on every request regardless of what the client says. ]]
function InteractionService:_validateRange(player: Player, entry: any): (boolean, string?)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		return false, "no_character"
	end

	local range = RANGES[entry.kind] or 16
	local distance = ((root :: BasePart).Position - entry.position).Magnitude

	-- A small margin over the client's own range covers latency without allowing
	-- an interaction from meaningfully further away.
	if distance > range * 1.35 then
		if self._antiCheat then
			self._antiCheat:Report(player, "capture_position_mismatch", distance / range, {
				interactable = entry.id,
			})
		end
		return false, "too_far"
	end

	return true, nil
end

-- ============================================================================
-- Fast travel
-- ============================================================================

function InteractionService:FastTravel(player: Player, nodeId: string): (boolean, string?)
	local entry = self._interactables[nodeId]
	if not entry or entry.kind ~= "fast_travel" then
		return false, "unknown_node"
	end

	local profile = self._data:GetProfile(player)
	if not profile then
		return false, "no_profile"
	end

	if not profile.traversal.fast_travel then
		Net.FireClient(player, "Notification", {
			kind = "warning",
			title = "Relay transit locked",
			body = "Complete The Long Road to unlock fast travel.",
		})
		return false, "not_unlocked"
	end

	-- A relay must have been reached on foot before it can be travelled to. This is
	-- what keeps the world's scale meaningful: the first crossing is always real.
	if not profile.fastTravelUnlocked[nodeId] then
		Net.FireClient(player, "Notification", {
			kind = "warning",
			title = "Relay not discovered",
			body = ("Reach %s on foot before travelling to it."):format(entry.data.name or nodeId),
		})
		return false, "not_discovered"
	end

	-- The destination region's own gate still applies.
	if entry.regionId then
		local cleared, reason, requirement = self._regions:IsPlayerCleared(player, entry.regionId)
		if not cleared then
			Net.FireClient(player, "Notification", {
				kind = "warning",
				title = "Region locked",
				body = self:_describeGate(reason, requirement),
			})
			return false, "region_locked"
		end
	end

	if self._events and self._events:IsFastTravelDisabled() then
		Net.FireClient(player, "Notification", {
			kind = "warning",
			title = "Transit offline",
			body = "The relay network is down.",
		})
		return false, "network_down"
	end

	local now = os.clock()
	local cooldown = 25
	if now - (self._lastFastTravelAt[player.UserId] or -math.huge) < cooldown then
		return false, "on_cooldown"
	end
	self._lastFastTravelAt[player.UserId] = now

	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		return false, "no_character"
	end

	-- Grant movement grace before teleporting, or the anti-cheat sees the game's
	-- own mechanic as a speed violation.
	if self._antiCheat then
		self._antiCheat:GrantMovementGrace(player, 3)
	end

	(root :: BasePart).CFrame = CFrame.new(entry.position + Vector3.new(0, 5, 0))

	Net.FireClient(player, "Notification", {
		kind = "info",
		title = entry.data.name or "Relay",
		body = "Transit complete.",
		transient = true,
	})

	if self._analytics then
		self._analytics:Track(player, "fast_travel", { nodeId = nodeId, regionId = entry.regionId })
	end

	return true, nil
end

function InteractionService:_describeGate(reason: string?, requirement: any): string
	if reason == "level" then
		return ("Requires level %d."):format(requirement)
	elseif reason == "quest" then
		return "Requires further progress in the story."
	elseif reason == "traversal" then
		return "Requires movement technology you do not have yet."
	elseif reason == "prestige" then
		return ("Requires Prestige %d."):format(requirement)
	end
	return "Not available yet."
end

--[[ Marks a relay as discovered. Called by RegionService on first arrival. ]]
function InteractionService:DiscoverFastTravel(player: Player, nodeId: string): boolean
	local profile = self._data:GetProfile(player)
	if not profile or profile.fastTravelUnlocked[nodeId] then
		return false
	end

	profile.fastTravelUnlocked[nodeId] = true
	self._data:MarkDirty(player)

	local entry = self._interactables[nodeId]
	if self._progression then
		self._progression:GrantUnlock(player, "fast_travel", nodeId, entry and entry.data.name or nodeId)
	end
	return true
end

-- ============================================================================
-- Death caches
-- ============================================================================

--[[
	Spawns a recoverable cache at a death site. Anyone can pick it up, which turns a
	teammate's death into a decision rather than only a loss.
]]
function InteractionService:SpawnCache(ownerUserId: number, position: Vector3, energy: number)
	if energy <= 0 then
		return nil
	end

	local id = ("cache_%d_%d"):format(ownerUserId, math.floor(os.clock() * 100))
	local entry = self:Register({
		id = id,
		kind = "cache",
		position = position,
		data = {
			ownerUserId = ownerUserId,
			energy = energy,
			expiresAt = os.clock() + Balance.Carry.DEATH_CACHE_LIFETIME,
		},
	})

	self._caches[id] = entry

	-- The owner is told where it is; everyone else has to find it.
	local owner = Players:GetPlayerByUserId(ownerUserId)
	if owner then
		Net.FireClient(owner, "Notification", {
			kind = "info",
			title = "Cache dropped",
			body = ("%d energy recoverable for %d seconds."):format(
				math.floor(energy),
				Balance.Carry.DEATH_CACHE_LIFETIME
			),
		})
	end

	Net.FireAllClients("AbilityState", {
		kind = "cache_spawned",
		id = id,
		position = position,
		ownerUserId = ownerUserId,
		expiresAt = entry.data.expiresAt,
	})

	return entry
end

function InteractionService:_collectCache(player: Player, entry: any): (boolean, string?)
	if not self._carry then
		return false, "unavailable"
	end

	local energy = entry.data.energy or 0
	self:Unregister(entry.id)
	self._caches[entry.id] = nil

	local accepted = self._carry:AddEnergy(player, energy, "cache")

	Net.FireAllClients("AbilityState", { kind = "cache_removed", id = entry.id })
	Net.FireClient(player, "Notification", {
		kind = "good",
		title = "Cache recovered",
		body = ("+%d energy"):format(math.floor(accepted)),
	})

	return true, nil
end

-- ============================================================================
-- Generic interaction
-- ============================================================================

--[[
	Handles an interaction request. The client names what it wants to use; the
	server decides whether that is currently true.
]]
function InteractionService:Interact(player: Player, id: string): (boolean, string?)
	local entry = self._interactables[id]
	if not entry or not entry.enabled then
		return false, "unknown_interactable"
	end

	local inRange, rangeReason = self:_validateRange(player, entry)
	if not inRange then
		return false, rangeReason
	end

	if entry.kind == "bank" then
		if self._events and self._events:AreBanksDisabled() then
			Net.FireClient(player, "Notification", {
				kind = "warning",
				title = "Bank offline",
				body = "The grid is down. Find an emergency tap.",
			})
			return false, "banks_disabled"
		end
		return self._bank:RequestBank(player, id, false)

	elseif entry.kind == "fast_travel" then
		-- Standing on a relay discovers it; travelling is done from the map.
		self:DiscoverFastTravel(player, id)
		return true, nil

	elseif entry.kind == "cache" then
		return self:_collectCache(player, entry)

	elseif entry.kind == "quest_object" then
		self._quests:NotifyInteract(player, entry.tag or entry.id)
		-- Single-use quest objects disable themselves so a player cannot farm one.
		if entry.data.singleUse then
			self:SetEnabled(id, false)
		end
		self.Interacted:Fire(player, entry)
		return true, nil

	elseif entry.kind == "event_node" then
		if not self._events or not self._carry then
			return false, "unavailable"
		end
		-- Delivering to a node consumes carried energy rather than banking it.
		local carried = self._carry:GetCarried(player)
		if carried <= 0 then
			return false, "nothing_to_deliver"
		end
		local delivered = self._carry:DrainFlat(player, carried, "event_delivery")
		self._events:DeliverToNode(player, entry.data.eventId, entry.data.nodeIndex, delivered)
		return true, nil

	elseif entry.kind == "gate" then
		Net.FireClient(player, "Notification", {
			kind = "info",
			title = entry.data.name or "Sealed",
			body = entry.data.hint or "It does not open.",
		})
		return true, nil
	end

	self.Interacted:Fire(player, entry)
	return true, nil
end

-- ============================================================================
-- Tick
-- ============================================================================

function InteractionService:Tick()
	local now = os.clock()

	-- Expire caches.
	for id, entry in pairs(self._caches) do
		if now >= (entry.data.expiresAt or 0) then
			self:Unregister(id)
			self._caches[id] = nil
			Net.FireAllClients("AbilityState", { kind = "cache_removed", id = id })
		end
	end

	-- Standing on an undiscovered relay discovers it, without needing a keypress.
	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not root then
			continue
		end
		local profile = self._data:GetProfile(player)
		if not profile then
			continue
		end

		for _, nearby in ipairs(self:GetNearby((root :: BasePart).Position)) do
			if nearby.entry.kind == "fast_travel" and not profile.fastTravelUnlocked[nearby.entry.id] then
				self:DiscoverFastTravel(player, nearby.entry.id)
			end
		end
	end
end

--[[ The interactable list replicated to a client, so it can resolve prompts
     locally without asking the server what is nearby every frame. ]]
function InteractionService:BuildClientManifest()
	local manifest = {}
	for _, entry in pairs(self._interactables) do
		if entry.enabled then
			table.insert(manifest, {
				id = entry.id,
				kind = entry.kind,
				position = entry.position,
				regionId = entry.regionId,
				name = entry.data.name,
				range = RANGES[entry.kind] or 16,
			})
		end
	end
	return manifest
end

InteractionService.RANGES = RANGES

return InteractionService
