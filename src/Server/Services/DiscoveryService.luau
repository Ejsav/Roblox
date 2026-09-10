--!strict
--[[
	DiscoveryService
	----------------
	Hidden things: the reward for looking rather than grinding.

	Discoveries are registered by the world builder with a world position and a
	radius. The client reports a touch; this service revalidates the distance
	server-side, awards once, and never awards twice.

	The "I didn't know the game had this" moment the design brief asks for lives
	here, so a discovery is always announced with real presentation rather than a
	line of chat.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BTS")
local Signal = require(Shared.Core.Signal)
local Net = require(Shared.Net)
local Regions = require(Shared.Config.Regions)

local DiscoveryService = {}
DiscoveryService.Name = "DiscoveryService"
DiscoveryService.Dependencies = { "DataService", "ProgressionService", "EconomyService" }
DiscoveryService.Priority = 42

function DiscoveryService:Init()
	-- discoveryId -> { id, name, description, position, radius, regionId, kind, rewards }
	self._registry = {}
	self._byRegion = {}

	self.DiscoveryMade = Signal.new("DiscoveryService.DiscoveryMade")
end

function DiscoveryService:Start()
	self._data = self.Registry:Get("DataService")
	self._progression = self.Registry:Get("ProgressionService")
	self._economy = self.Registry:Get("EconomyService")
	self._quests = self.Registry:Find("QuestService")
	self._analytics = self.Registry:Find("AnalyticsService")
	self._antiCheat = self.Registry:Find("AntiCheatService")

	Net.OnServerEvent("ReportDiscovery", function(player, discoveryId, position)
		self:Report(player, discoveryId, position)
	end)
end

--[[ Registers a discovery. Called by the world builder as it places them. ]]
function DiscoveryService:Register(definition: {
	id: string,
	name: string,
	description: string?,
	position: Vector3,
	radius: number?,
	regionId: string,
	kind: string?,
	rewards: any?,
})
	local entry = {
		id = definition.id,
		name = definition.name,
		description = definition.description or "",
		position = definition.position,
		radius = definition.radius or 14,
		regionId = definition.regionId,
		kind = definition.kind or "location",
		rewards = definition.rewards,
	}
	self._registry[entry.id] = entry
	self._byRegion[entry.regionId] = self._byRegion[entry.regionId] or {}
	table.insert(self._byRegion[entry.regionId], entry.id)
	return entry
end

function DiscoveryService:Get(discoveryId: string)
	return self._registry[discoveryId]
end

--[[ Handles a client-reported discovery, revalidating position server-side. ]]
function DiscoveryService:Report(player: Player, discoveryId: string, clientPosition: Vector3): (boolean, string?)
	local entry = self._registry[discoveryId]
	if not entry then
		return false, "unknown_discovery"
	end

	local profile = self._data:GetProfile(player)
	if not profile then
		return false, "no_profile"
	end
	if profile.discoveries[discoveryId] then
		if self._antiCheat then
			self._antiCheat:Report(player, "duplicate_discovery", 1, { discoveryId = discoveryId })
		end
		return false, "already_discovered"
	end

	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		return false, "no_character"
	end

	-- Server position is what counts; a generous margin covers latency without
	-- allowing a discovery to be claimed from across the map.
	local distance = ((root :: BasePart).Position - entry.position).Magnitude
	if distance > entry.radius + 24 then
		if self._antiCheat then
			self._antiCheat:Report(player, "capture_position_mismatch", distance / entry.radius, {
				discoveryId = discoveryId,
			})
		end
		return false, "too_far"
	end

	return self:Grant(player, discoveryId)
end

--[[ Awards a discovery unconditionally. Used by quests and by Report. ]]
function DiscoveryService:Grant(player: Player, discoveryId: string): (boolean, string?)
	local profile = self._data:GetProfile(player)
	if not profile then
		return false, "no_profile"
	end
	if profile.discoveries[discoveryId] then
		return false, "already_discovered"
	end

	local entry = self._registry[discoveryId]
	profile.discoveries[discoveryId] = true
	self._data:MarkDirty(player)

	-- Rewards scale with the region's position in the progression, so a secret in
	-- the Core is worth crossing the Core for.
	local region = entry and Regions.ById[entry.regionId]
	local order = region and region.order or 1
	local watts = (entry and entry.rewards and entry.rewards.watts) or (250 * order * order)
	local xp = (entry and entry.rewards and entry.rewards.xp) or (180 * order * order)

	self._economy:Award(player, "watts", watts, "discovery")
	self._progression:AwardXp(player, xp, "discovery")

	if entry and entry.rewards then
		if entry.rewards.cores then
			self._economy:Award(player, "cores", entry.rewards.cores, "discovery")
		end
		if entry.rewards.item then
			local inventory = self.Registry:Find("InventoryService")
			if inventory then
				inventory:GrantUnique(player, entry.rewards.item, "discovery")
			end
		end
	end

	self.DiscoveryMade:Fire(player, discoveryId)

	Net.FireClient(player, "DiscoveryMade", {
		kind = entry and entry.kind or "location",
		id = discoveryId,
		name = entry and entry.name or discoveryId,
		description = entry and entry.description or "",
		regionId = entry and entry.regionId,
		rewards = { watts = watts, xp = xp },
		total = self:GetDiscoveryProgress(player),
	})

	if self._quests then
		self._quests:NotifyDiscovery(player, discoveryId)
	end
	if self._analytics then
		self._analytics:Track(player, "discovery", { discoveryId = discoveryId, regionId = entry and entry.regionId })
	end

	return true, nil
end

--[[ How many discoveries this player has found, overall and per region. ]]
function DiscoveryService:GetDiscoveryProgress(player: Player)
	local profile = self._data:GetProfile(player)
	if not profile then
		return { found = 0, total = 0 }
	end

	local found = 0
	for _ in pairs(profile.discoveries) do
		found += 1
	end

	local perRegion = {}
	for regionId, ids in pairs(self._byRegion) do
		local regionFound = 0
		for _, id in ipairs(ids) do
			if profile.discoveries[id] then
				regionFound += 1
			end
		end
		perRegion[regionId] = { found = regionFound, total = #ids }
	end

	return {
		found = found,
		total = Regions.TotalDiscoveries(),
		registered = self:_countRegistered(),
		perRegion = perRegion,
	}
end

function DiscoveryService:_countRegistered(): number
	local count = 0
	for _ in pairs(self._registry) do
		count += 1
	end
	return count
end

--[[ Undiscovered entries near a position, for the Scan Pulse ability. ]]
function DiscoveryService:GetUndiscoveredNear(player: Player, origin: Vector3, radius: number)
	local profile = self._data:GetProfile(player)
	if not profile then
		return {}
	end

	local found = {}
	for id, entry in pairs(self._registry) do
		if not profile.discoveries[id] and (entry.position - origin).Magnitude <= radius then
			table.insert(found, {
				id = id,
				position = entry.position,
				kind = entry.kind,
				-- The name is withheld until it is actually found; a scan tells you
				-- something is there, not what it is.
				hint = entry.kind,
			})
		end
	end
	return found
end

return DiscoveryService
