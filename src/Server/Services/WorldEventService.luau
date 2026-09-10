--!strict
--[[
	WorldEventService
	-----------------
	Runs server-wide events: scheduling, phases, contribution tracking, rewards.

	The design bar for an event is that a player mid-run should genuinely consider
	abandoning their plan. That means an event has to do one of three things —
	change the rules of the world, pay enough to be worth the detour, or threaten
	something the player already has — and this service is what applies those changes
	to the live game rather than merely announcing them.

	Contribution is tracked per phase and normalised at the end, so a player who
	arrives for the final ninety seconds of a ten-minute event gets a real share of
	what they actually did, not a participation token.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BTS")
local Signal = require(Shared.Core.Signal)
local RNG = require(Shared.Core.RNG)
local Net = require(Shared.Net)
local Balance = require(Shared.Config.Balance)
local Regions = require(Shared.Config.Regions)
local WorldEvents = require(Shared.Config.WorldEvents)

local WorldEventService = {}
WorldEventService.Name = "WorldEventService"
WorldEventService.Dependencies = {
	"DataService", "StormService", "RegionService", "EconomyService",
	"ProgressionService", "LootService", "CarryService",
}
WorldEventService.Priority = 50

function WorldEventService:Init()
	self._rng = RNG.new("events_" .. tostring(os.time()))
	self._active = {} :: { [string]: any }
	self._nextEventAt = os.clock() + self._rng:NextRange(90, 180)
	self._history = {}

	self.EventStarted = Signal.new("WorldEventService.EventStarted")
	self.EventPhaseChanged = Signal.new("WorldEventService.EventPhaseChanged")
	self.EventEnded = Signal.new("WorldEventService.EventEnded")
end

function WorldEventService:Start()
	self._data = self.Registry:Get("DataService")
	self._storms = self.Registry:Get("StormService")
	self._regions = self.Registry:Get("RegionService")
	self._economy = self.Registry:Get("EconomyService")
	self._progression = self.Registry:Get("ProgressionService")
	self._loot = self.Registry:Get("LootService")
	self._carry = self.Registry:Get("CarryService")
	self._quests = self.Registry:Find("QuestService")
	self._bank = self.Registry:Find("BankService")
	self._analytics = self.Registry:Find("AnalyticsService")

	-- Contribution is measured from the events other services already fire, so
	-- nothing has to know it is inside a world event to count toward one.
	local capture = self.Registry:Find("CaptureService")
	if capture then
		capture.Captured:Connect(function(player, cell, strike, result)
			self:_contribute(player, "energy_captured", result.energy)
			self:_contribute(player, "boss_damage", result.energy)
		end)
	end
	if self._bank then
		self._bank.Banked:Connect(function(player, energy)
			self:_contribute(player, "energy_banked", energy)
			self:_contribute(player, "energy_banked_at_taps", energy)
		end)
	end
	self._carry.ChainExtended:Connect(function(player, chain)
		self:_contribute(player, "chain_contribution", chain)
	end)
end

-- ============================================================================
-- Scheduling
-- ============================================================================

function WorldEventService:_countActive(): number
	local count = 0
	for _ in pairs(self._active) do
		count += 1
	end
	return count
end

function WorldEventService:_getMedianLevel(): number
	local levels = {}
	for _, player in ipairs(Players:GetPlayers()) do
		local profile = self._data:GetProfile(player)
		if profile then
			table.insert(levels, profile.level)
		end
	end
	if #levels == 0 then
		return 1
	end
	table.sort(levels)
	return levels[math.ceil(#levels / 2)]
end

function WorldEventService:_trySchedule()
	if self:_countActive() >= Balance.Events.MAX_CONCURRENT then
		return
	end

	local playerCount = #Players:GetPlayers()
	if playerCount == 0 then
		-- No point running an event nobody can join; try again shortly.
		self._nextEventAt = os.clock() + 60
		return
	end

	local activeIds = {}
	for eventId in pairs(self._active) do
		activeIds[eventId] = true
	end

	local eligible = WorldEvents.GetEligible(playerCount, self:_getMedianLevel(), activeIds)

	-- Recently-run events are down-weighted so a server does not see the same
	-- event three times in a row.
	local now = os.time()
	for eventId, lastRun in pairs(self._history) do
		if eligible[eventId] and (now - lastRun) < 1800 then
			eligible[eventId] *= 0.25
		end
	end

	local chosen = self._rng:PickWeightedMap(eligible)
	if chosen then
		self:StartEvent(chosen)
	end

	self._nextEventAt = os.clock() + self._rng:NextRange(Balance.Events.MIN_INTERVAL, Balance.Events.MAX_INTERVAL)
end

-- ============================================================================
-- Lifecycle
-- ============================================================================

function WorldEventService:StartEvent(eventId: string, forcedRegionId: string?): boolean
	local definition = WorldEvents.ById[eventId]
	if not definition or self._active[eventId] then
		return false
	end

	-- Prefer a region players are actually in, so an event is not staged in an
	-- empty corner of the world.
	local populated = self._regions:GetPopulatedRegions()
	local candidates = {}
	for _, regionId in ipairs(definition.regions) do
		if populated[regionId] and populated[regionId] > 0 then
			table.insert(candidates, regionId)
		end
	end
	if #candidates == 0 then
		candidates = table.clone(definition.regions)
	end

	local regionId = forcedRegionId or self._rng:Pick(candidates)
	local region = Regions.ById[regionId]
	if not region then
		return false
	end

	local instance = {
		id = eventId,
		definition = definition,
		regionId = regionId,
		startedAt = os.clock(),
		warningEndsAt = os.clock() + definition.warningSeconds,
		phaseIndex = 0,
		phaseStartedAt = 0,
		contributions = {},
		totalContribution = 0,
		bossHealth = nil,
		nodes = nil,
		failed = false,
		position = Vector3.new(region.center.X, region.center.Y, region.center.Z),
	}

	self._active[eventId] = instance
	self._history[eventId] = os.time()

	self.EventStarted:Fire(instance)

	Net.FireAllClients("WorldEventStarted", {
		id = eventId,
		name = definition.name,
		scale = definition.scale,
		announcement = definition.announcement,
		description = definition.description,
		regionId = regionId,
		regionName = region.name,
		position = instance.position,
		warningSeconds = definition.warningSeconds,
		totalDuration = WorldEvents.GetTotalDuration(eventId),
		visibleFromAnywhere = definition.visibleFromAnywhere,
	})

	if self._analytics then
		self._analytics:Track(nil, "world_event_started", { eventId = eventId, regionId = regionId })
	end

	return true
end

function WorldEventService:_advancePhase(instance: any, phaseIndex: number)
	local definition = instance.definition
	local phase = definition.phases[phaseIndex]

	-- Clear the previous phase's world modifiers before applying the next.
	self:_applyPhaseEffects(instance, nil)

	if not phase then
		self:_endEvent(instance)
		return
	end

	instance.phaseIndex = phaseIndex
	instance.phaseStartedAt = os.clock()

	self:_applyPhaseEffects(instance, phase)
	self.EventPhaseChanged:Fire(instance, phase)

	Net.FireAllClients("WorldEventPhase", {
		id = instance.id,
		phaseId = phase.id,
		phaseName = phase.name,
		phaseIndex = phaseIndex,
		phaseCount = #definition.phases,
		duration = phase.duration,
		description = phase.description,
		objective = phase.objective,
	})
end

--[[ Applies (or clears) a phase's effects on the live world. ]]
function WorldEventService:_applyPhaseEffects(instance: any, phase: any?)
	if not phase then
		self._storms:ClearEventModifiers()
		instance.effects = nil
		return
	end

	local effects = phase.effects or {}
	instance.effects = effects

	self._storms:SetEventModifiers({
		stormSpawnMultiplier = effects.stormSpawnMultiplier,
		forcedStormTypes = effects.forcedStormTypes,
		strikeIntervalMultiplier = effects.stormSpawnMultiplier and (1 / effects.stormSpawnMultiplier) or nil,
	})

	-- Boss phases get a health pool sized to the server's population, so a
	-- convergence with three players is not the same wall as one with twenty.
	if effects.bossHealthBase then
		local playerCount = math.max(1, #Players:GetPlayers())
		instance.bossHealth = effects.bossHealthBase + effects.bossHealthPerPlayer * playerCount
		instance.bossHealthMax = instance.bossHealth
	end

	-- Repair phases need concrete nodes to defend.
	if effects.nodeCount then
		instance.nodes = {}
		local region = Regions.ById[instance.regionId]
		for index = 1, effects.nodeCount do
			local angle = (index / effects.nodeCount) * math.pi * 2
			local distance = region.radius * 0.45
			table.insert(instance.nodes, {
				index = index,
				position = instance.position + Vector3.new(math.cos(angle) * distance, 0, math.sin(angle) * distance),
				energy = 0,
				required = effects.nodeEnergyEach,
				lost = false,
			})
		end
	end

	-- A spawned boss is a real storm cell of the named type, scaled up.
	if effects.spawnBoss then
		local cell = self._storms:ForceSpawn(instance.regionId, effects.spawnBoss, instance.position)
		if cell then
			cell.intensity *= effects.bossScale or 1
			cell.radius *= effects.bossScale or 1
			-- The event owns this cell's lifetime.
			cell.expiresAt = os.clock() + phase.duration + 10
			instance.bossCellId = cell.id
		end
	end

	-- A rare cell for the Bloom event.
	if effects.spawnRareCell then
		local region = Regions.ById[instance.regionId]
		local rareTypes = {}
		for stormId in pairs(region.storms.types) do
			local storm = require(Shared.Config.StormTypes).ById[stormId]
			if storm and (storm.rarity == "rare" or storm.rarity == "epic" or storm.rarity == "legendary") then
				table.insert(rareTypes, stormId)
			end
		end
		if #rareTypes > 0 then
			local cell = self._storms:ForceSpawn(instance.regionId, self._rng:Pick(rareTypes))
			if cell then
				instance.markedCellId = cell.id
			end
		end
	end
end

function WorldEventService:_endEvent(instance: any)
	self:_applyPhaseEffects(instance, nil)
	self._active[instance.id] = nil

	-- Rank contributors so the top one can be identified and rewarded.
	local ranked = {}
	for userId, amount in pairs(instance.contributions) do
		table.insert(ranked, { userId = userId, amount = amount })
	end
	table.sort(ranked, function(a, b)
		return a.amount > b.amount
	end)

	local results = {}

	for rank, entry in ipairs(ranked) do
		local player = Players:GetPlayerByUserId(entry.userId)
		if not player then
			continue
		end

		local share = instance.totalContribution > 0 and (entry.amount / instance.totalContribution) or 0
		local rewards = WorldEvents.CalculateRewards(instance.id, share, rank == 1, Balance)
		if not rewards then
			continue
		end

		self._economy:Award(player, "watts", rewards.watts, "event:" .. instance.id)
		if rewards.cores > 0 then
			self._economy:Award(player, "cores", rewards.cores, "event:" .. instance.id)
		end
		self._progression:AwardXp(player, rewards.xp, "event:" .. instance.id)

		local drops = self._loot:RollTable(player, rewards.lootTable, rewards.lootRolls, {
			regionId = instance.regionId,
			source = "event:" .. instance.id,
		})

		local profile = self._data:GetProfile(player)
		if profile then
			profile.records.eventsParticipated = (profile.records.eventsParticipated or 0) + 1
			if rank == 1 then
				profile.records.eventsTopContributor = (profile.records.eventsTopContributor or 0) + 1
			end
			if share > (profile.records.bestEventShare or 0) then
				profile.records.bestEventShare = share
			end
			self._data:MarkDirty(player)
		end

		if self._quests then
			self._quests:NotifyEvent(player, instance.id, rank)
		end

		table.insert(results, { userId = entry.userId, rank = rank, share = share })

		Net.FireClient(player, "WorldEventEnded", {
			id = instance.id,
			name = instance.definition.name,
			rank = rank,
			participants = #ranked,
			share = share,
			rewards = rewards,
			drops = drops,
			failed = instance.failed,
		})
	end

	-- Everyone else gets the outcome without a reward panel.
	for _, player in ipairs(Players:GetPlayers()) do
		if not instance.contributions[player.UserId] then
			Net.FireClient(player, "WorldEventEnded", {
				id = instance.id,
				name = instance.definition.name,
				participants = #ranked,
				failed = instance.failed,
			})
		end
	end

	self.EventEnded:Fire(instance, results)

	if self._analytics then
		self._analytics:Track(nil, "world_event_ended", {
			eventId = instance.id,
			participants = #ranked,
			failed = instance.failed,
		})
	end
end

-- ============================================================================
-- Contribution
-- ============================================================================

--[[
	Records a player's contribution against whichever active event's current phase
	is measuring that source. A capture during a Superstorm's front phase counts;
	the same capture during its wake phase does not.
]]
function WorldEventService:_contribute(player: Player, source: string, amount: number)
	if amount <= 0 then
		return
	end

	for _, instance in pairs(self._active) do
		local phase = instance.definition.phases[instance.phaseIndex]
		if not phase or not phase.contribution or phase.contribution.source ~= source then
			continue
		end

		-- Only players actually in the event's region count, so a Superstorm cannot
		-- be farmed from the other side of the world.
		local regionId = self._regions:GetPlayerRegion(player)
		if regionId ~= instance.regionId and instance.definition.scale ~= "world" then
			continue
		end

		local weighted = amount * (phase.contribution.weight or 1)
		instance.contributions[player.UserId] = (instance.contributions[player.UserId] or 0) + weighted
		instance.totalContribution += weighted

		-- Boss damage depletes the pool.
		if source == "boss_damage" and instance.bossHealth then
			instance.bossHealth = math.max(0, instance.bossHealth - amount)
		end
	end
end

--[[ Energy delivered to an overload node, called by the interaction system. ]]
function WorldEventService:DeliverToNode(player: Player, eventId: string, nodeIndex: number, energy: number): boolean
	local instance = self._active[eventId]
	if not instance or not instance.nodes then
		return false
	end
	local node = instance.nodes[nodeIndex]
	if not node or node.lost then
		return false
	end

	node.energy = math.min(node.required, node.energy + energy)
	self:_contribute(player, "energy_delivered", energy)
	return true
end

-- ============================================================================
-- Modifiers consumed by other services
-- ============================================================================

--[[ Combined capture yield multiplier from every event affecting this player. ]]
function WorldEventService:GetCaptureYieldMultiplier(player: Player): number
	return self:_getMultiplier(player, "captureYieldMultiplier")
end

function WorldEventService:GetBankRateMultiplier(player: Player): number
	return self:_getMultiplier(player, "bankRateMultiplier")
end

function WorldEventService:GetXpMultiplier(player: Player): number
	return self:_getMultiplier(player, "xpMultiplier")
end

function WorldEventService:GetExposureMultiplier(player: Player): number
	return self:_getMultiplier(player, "exposureDamageMultiplier")
end

function WorldEventService:_getMultiplier(player: Player, key: string): number
	local multiplier = 1
	local regionId = self._regions:GetPlayerRegion(player)

	for _, instance in pairs(self._active) do
		if not instance.effects then
			continue
		end
		local value = instance.effects[key]
		if not value then
			continue
		end
		-- A world-scale event applies everywhere; a regional one only in its region.
		if instance.definition.scale == "world" or regionId == instance.regionId then
			multiplier *= value
		end
	end

	return multiplier
end

--[[ True when banking is currently disabled by a Blackout. ]]
function WorldEventService:AreBanksDisabled(): boolean
	for _, instance in pairs(self._active) do
		if instance.effects and instance.effects.disableBankStations then
			return true
		end
	end
	return false
end

function WorldEventService:IsFastTravelDisabled(): boolean
	for _, instance in pairs(self._active) do
		if instance.effects and instance.effects.disableFastTravel then
			return true
		end
	end
	return false
end

function WorldEventService:GetActiveEvents()
	local list = {}
	for _, instance in pairs(self._active) do
		local phase = instance.definition.phases[instance.phaseIndex]
		table.insert(list, {
			id = instance.id,
			name = instance.definition.name,
			scale = instance.definition.scale,
			regionId = instance.regionId,
			position = instance.position,
			phaseName = phase and phase.name or "Forming",
			phaseIndex = instance.phaseIndex,
			phaseCount = #instance.definition.phases,
			bossHealthFraction = instance.bossHealth and instance.bossHealthMax
				and (instance.bossHealth / instance.bossHealthMax) or nil,
		})
	end
	return list
end

-- ============================================================================
-- Tick
-- ============================================================================

function WorldEventService:Tick()
	local now = os.clock()

	if now >= self._nextEventAt then
		self:_trySchedule()
	end

	for eventId, instance in pairs(self._active) do
		-- Warning period, then phase one.
		if instance.phaseIndex == 0 then
			if now >= instance.warningEndsAt then
				self:_advancePhase(instance, 1)
			end
			continue
		end

		local phase = instance.definition.phases[instance.phaseIndex]
		if not phase then
			self:_endEvent(instance)
			continue
		end

		-- Node decay for repair events.
		if instance.nodes and phase.effects and phase.effects.nodeDecayPerSecond then
			local lostCount = 0
			for _, node in ipairs(instance.nodes) do
				if not node.lost then
					node.energy = math.max(0, node.energy - phase.effects.nodeDecayPerSecond * 0.5)
				end
				if node.lost then
					lostCount += 1
				end
			end

			local failCondition = phase.failCondition
			if failCondition and failCondition.type == "nodes_lost" and lostCount >= failCondition.threshold then
				instance.failed = true
				self:_endEvent(instance)
				continue
			end
		end

		-- A boss whose health reaches zero ends its phase early, which is the
		-- reward for a coordinated group beating the timer.
		if instance.bossHealth and instance.bossHealth <= 0 then
			self:_advancePhase(instance, instance.phaseIndex + 1)
			continue
		end

		if now - instance.phaseStartedAt >= phase.duration then
			-- A boss phase that ran out of time fails rather than advancing.
			if phase.failCondition and phase.failCondition.type == "timeout" and instance.bossHealth and instance.bossHealth > 0 then
				instance.failed = true
				self:_endEvent(instance)
			else
				self:_advancePhase(instance, instance.phaseIndex + 1)
			end
			continue
		end

		-- Live progress for the client's event tracker.
		self:_broadcastProgress(instance, phase, now)
	end
end

function WorldEventService:_broadcastProgress(instance: any, phase: any, now: number)
	instance.lastBroadcastAt = instance.lastBroadcastAt or 0
	if now - instance.lastBroadcastAt < 1 then
		return
	end
	instance.lastBroadcastAt = now

	local topContributor, topAmount = nil, 0
	for userId, amount in pairs(instance.contributions) do
		if amount > topAmount then
			topContributor, topAmount = userId, amount
		end
	end

	Net.FireAllClients("WorldEventProgress", {
		id = instance.id,
		phaseId = phase.id,
		remaining = math.max(0, phase.duration - (now - instance.phaseStartedAt)),
		bossHealthFraction = instance.bossHealth and instance.bossHealthMax
			and (instance.bossHealth / instance.bossHealthMax) or nil,
		nodes = instance.nodes and #instance.nodes or nil,
		totalContribution = instance.totalContribution,
		topContributorUserId = topContributor,
		participants = (function()
			local count = 0
			for _ in pairs(instance.contributions) do
				count += 1
			end
			return count
		end)(),
	})
end

--[[ Admin and test entry point. ]]
function WorldEventService:ForceEvent(eventId: string, regionId: string?): boolean
	return self:StartEvent(eventId, regionId)
end

function WorldEventService:EndEvent(eventId: string): boolean
	local instance = self._active[eventId]
	if not instance then
		return false
	end
	self:_endEvent(instance)
	return true
end

return WorldEventService
