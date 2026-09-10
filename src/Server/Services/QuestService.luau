--!strict
--[[
	QuestService
	------------
	Quest state, objective matching, rewards, and the rotating daily/weekly set.

	Objectives are matched by a table of small predicates rather than a giant
	if-chain, so adding an objective type means adding one function. Every gameplay
	service calls a Notify* method; this service decides which active objectives
	that event advances.

	Design constraint honoured here: the player must always know what to do next.
	`GetTracked` never returns nil while an incomplete main quest exists, and the
	HUD reads from it directly.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BTS")
local Signal = require(Shared.Core.Signal)
local RNG = require(Shared.Core.RNG)
local Net = require(Shared.Net)
local Quests = require(Shared.Config.Quests)
local Regions = require(Shared.Config.Regions)
local Resources = require(Shared.Config.Resources)
local StormTypes = require(Shared.Config.StormTypes)
local Balance = require(Shared.Config.Balance)

local QuestService = {}
QuestService.Name = "QuestService"
QuestService.Dependencies = { "DataService", "EconomyService", "ProgressionService", "InventoryService" }
QuestService.Priority = 40

local DAY_SECONDS = 86400
local WEEK_SECONDS = 604800

function QuestService:Init()
	self._rng = RNG.new("quests_" .. tostring(os.time()))
	self._sessionCounters = {} :: { [number]: any }

	self.QuestAccepted = Signal.new("QuestService.QuestAccepted")
	self.QuestCompleted = Signal.new("QuestService.QuestCompleted")
	self.ObjectiveAdvanced = Signal.new("QuestService.ObjectiveAdvanced")
end

function QuestService:Start()
	self._data = self.Registry:Get("DataService")
	self._economy = self.Registry:Get("EconomyService")
	self._progression = self.Registry:Get("ProgressionService")
	self._inventory = self.Registry:Get("InventoryService")
	self._analytics = self.Registry:Find("AnalyticsService")

	Net.OnServerEvent("RequestAcceptQuest", function(player, questId)
		self:Accept(player, questId)
	end)
	Net.OnServerEvent("RequestAbandonQuest", function(player, questId)
		self:Abandon(player, questId)
	end)
	Net.OnServerEvent("RequestTrackQuest", function(player, questId)
		self:SetTracked(player, questId)
	end)

	self._data.ProfileLoaded:Connect(function(player)
		self:_onProfileLoaded(player)
	end)

	Players.PlayerRemoving:Connect(function(player)
		self._sessionCounters[player.UserId] = nil
	end)
end

-- ============================================================================
-- Session state
-- ============================================================================

--[[
	Per-session counters that must not persist: "capture 12 distinct storm types in
	one session" would be trivial if the count survived a rejoin.
]]
function QuestService:_getSession(player: Player)
	local session = self._sessionCounters[player.UserId]
	if not session then
		session = {
			distinctStormTypes = {},
			distinctRegions = {},
			consecutiveGrades = {},
			challengesCompletedThisWeek = 0,
			runDamageTaken = 0,
			routeProgress = {},
		}
		self._sessionCounters[player.UserId] = session
	end
	return session
end

function QuestService:_onProfileLoaded(player: Player)
	local profile = self._data:GetProfile(player)
	if not profile then
		return
	end

	self:_refreshRotating(player, profile)

	-- Auto-accept the next main quest so a new player never has to find a quest
	-- board to be given their first instruction.
	local nextMain = Quests.GetNextMainQuest(profile.completedQuests)
	if nextMain and not profile.activeQuests[nextMain.id] then
		local available = Quests.IsAvailable(nextMain.id, self:_buildQuestState(player, profile))
		if available then
			self:Accept(player, nextMain.id, true)
		end
	end

	-- Restore tracking, or pick the sensible default.
	if not profile.trackedQuest or not profile.activeQuests[profile.trackedQuest] then
		profile.trackedQuest = nextMain and nextMain.id or next(profile.activeQuests)
		self._data:MarkDirty(player)
	end

	self:_syncQuests(player)
end

function QuestService:_buildQuestState(player: Player, profile: any)
	return {
		level = profile.level,
		completedQuests = profile.completedQuests,
		activeQuests = profile.activeQuests,
		questCooldowns = profile.questCooldowns,
		now = os.time(),
	}
end

-- ============================================================================
-- Accept / abandon / track
-- ============================================================================

function QuestService:Accept(player: Player, questId: string, silent: boolean?): (boolean, string?)
	local profile = self._data:GetProfile(player)
	if not profile then
		return false, "no_profile"
	end

	local quest = Quests.ById[questId]
	if not quest then
		return false, "unknown_quest"
	end

	local available, reason = Quests.IsAvailable(questId, self:_buildQuestState(player, profile))
	if not available then
		return false, reason
	end

	local objectives = {}
	for _, objective in ipairs(quest.objectives) do
		objectives[objective.id] = { progress = 0, complete = false }
	end

	profile.activeQuests[questId] = {
		startedAt = os.time(),
		objectives = objectives,
	}

	if not profile.trackedQuest or quest.type == "main" then
		profile.trackedQuest = questId
	end

	self._data:MarkDirty(player)
	self.QuestAccepted:Fire(player, questId)

	if not silent then
		Net.FireClient(player, "Notification", {
			kind = "info",
			title = "Quest started",
			body = quest.name,
		})
	end

	self:_syncQuests(player)

	if self._analytics then
		self._analytics:Track(player, "quest_accepted", { questId = questId, type = quest.type })
	end

	return true, nil
end

function QuestService:Abandon(player: Player, questId: string): boolean
	local profile = self._data:GetProfile(player)
	if not profile or not profile.activeQuests[questId] then
		return false
	end

	local quest = Quests.ById[questId]
	-- Main quests cannot be abandoned; they are the spine, and a player who drops
	-- one has no way back to their own progression.
	if quest and quest.type == "main" then
		return false
	end

	profile.activeQuests[questId] = nil
	if profile.trackedQuest == questId then
		profile.trackedQuest = Quests.GetNextMainQuest(profile.completedQuests)
			and Quests.GetNextMainQuest(profile.completedQuests).id
			or next(profile.activeQuests)
	end
	self._data:MarkDirty(player)
	self:_syncQuests(player)
	return true
end

function QuestService:SetTracked(player: Player, questId: string?): boolean
	local profile = self._data:GetProfile(player)
	if not profile then
		return false
	end
	if questId and not profile.activeQuests[questId] then
		return false
	end
	profile.trackedQuest = questId
	self._data:MarkDirty(player)
	self:_syncQuests(player)
	return true
end

--[[ The quest the HUD should display. Never nil while any quest is active. ]]
function QuestService:GetTracked(player: Player)
	local profile = self._data:GetProfile(player)
	if not profile then
		return nil
	end

	local questId = profile.trackedQuest
	if not questId or not profile.activeQuests[questId] then
		local nextMain = Quests.GetNextMainQuest(profile.completedQuests)
		questId = (nextMain and profile.activeQuests[nextMain.id] and nextMain.id) or next(profile.activeQuests)
	end
	if not questId then
		return nil
	end
	return self:_buildQuestView(player, profile, questId)
end

-- ============================================================================
-- Objective matching
-- ============================================================================

--[[
	One predicate per objective type. Each returns the amount of progress an event
	contributes, or 0. Keeping them separate is what makes adding an objective type
	a five-line change rather than a surgery on a conditional.
]]
local Matchers = {}

Matchers.capture = function(objective, event, session, profile)
	if event.kind ~= "capture" then
		return 0
	end
	if objective.storm and event.stormTypeId ~= objective.storm then
		return 0
	end
	if objective.region and event.regionId ~= objective.region then
		return 0
	end
	if objective.grade and event.grade ~= objective.grade then
		return 0
	end
	if objective.minRarity then
		local order = Balance.Loot.RARITY_ORDER
		local required = table.find(order, objective.minRarity) or 1
		local actual = table.find(order, event.rarity or "common") or 1
		if actual < required then
			return 0
		end
	end
	if objective.distinctStormTypes then
		if session.distinctStormTypes[event.stormTypeId] then
			return 0
		end
		session.distinctStormTypes[event.stormTypeId] = true
		return 1
	end
	if objective.distinctRegions then
		if session.distinctRegions[event.regionId] then
			return 0
		end
		session.distinctRegions[event.regionId] = true
		return 1
	end
	return 1
end

Matchers.bank = function(objective, event, session, profile)
	if event.kind ~= "bank" then
		return 0
	end
	if objective.mode == "deposits" then
		return 1
	end
	if objective.mode == "single_deposit" then
		-- A single deposit objective completes only if one deposit clears the bar.
		return event.energy >= objective.target and objective.target or 0
	end
	return event.energy
end

Matchers.reach = function(objective, event, session, profile)
	if event.kind ~= "reach" then
		return 0
	end
	if objective.subregion and event.subregion == objective.subregion then
		return 1
	end
	if objective.region and event.region == objective.region and not objective.subregion then
		return 1
	end
	if objective.landmark and event.landmark == objective.landmark then
		return 1
	end
	return 0
end

Matchers.discover = function(objective, event, session, profile)
	if event.kind ~= "discover" then
		return 0
	end
	if objective.discovery and event.discoveryId ~= objective.discovery then
		return 0
	end
	return 1
end

Matchers.collect = function(objective, event, session, profile)
	if event.kind ~= "collect" then
		return 0
	end
	if objective.resource and event.resourceId ~= objective.resource then
		return 0
	end
	return event.quantity or 1
end

Matchers.survive = function(objective, event, session, profile)
	if event.kind ~= "survive" then
		return 0
	end
	if objective.region and event.region ~= objective.region then
		return 0
	end
	if objective.subregion and event.subregion ~= objective.subregion then
		return 0
	end
	return event.seconds or 0
end

Matchers.chain = function(objective, event, session, profile)
	if event.kind ~= "chain" then
		return 0
	end
	-- A chain objective tracks the peak reached, not an accumulation.
	return event.chain
end

Matchers.interact = function(objective, event, session, profile)
	if event.kind ~= "interact" then
		return 0
	end
	if objective.tag and event.tag ~= objective.tag then
		return 0
	end
	return 1
end

Matchers.defeat = function(objective, event, session, profile)
	if event.kind ~= "defeat" then
		return 0
	end
	if objective.boss and event.bossId ~= objective.boss then
		return 0
	end
	return 1
end

Matchers.event = function(objective, event, session, profile)
	if event.kind ~= "event" then
		return 0
	end
	if objective.requiresTopContribution and (event.rank or 99) > objective.requiresTopContribution then
		return 0
	end
	return 1
end

Matchers.upgrade = function(objective, event, session, profile)
	return event.kind == "upgrade" and 1 or 0
end

Matchers.traverse = function(objective, event, session, profile)
	if event.kind ~= "traverse" then
		return 0
	end
	if objective.ability and event.ability ~= objective.ability then
		return 0
	end
	return event.amount or 0
end

Matchers.carry = function(objective, event, session, profile)
	if event.kind ~= "carry" then
		return 0
	end
	-- Fill-fraction objectives record the peak reached rather than accumulating.
	return event.fill
end

Matchers.stat = function(objective, event, session, profile)
	if event.kind ~= "stat" then
		return 0
	end
	if objective.stat ~= event.statId then
		return 0
	end
	return event.value
end

Matchers.challenge = function(objective, event, session, profile)
	return event.kind == "challenge_completed" and 1 or 0
end

Matchers.route = function(objective, event, session, profile)
	return event.kind == "route_completed" and objective.target or 0
end

--[[ Objective types whose progress is a high-water mark rather than a sum. ]]
local PEAK_OBJECTIVES = {
	chain = true,
	carry = true,
	stat = true,
}

-- ============================================================================
-- Progress
-- ============================================================================

--[[
	Applies an event to every active quest objective it matches.
	This is the single funnel; every Notify* method builds an event and calls here.
]]
function QuestService:_applyEvent(player: Player, event: any)
	local profile = self._data:GetProfile(player)
	if not profile then
		return
	end

	local session = self:_getSession(player)
	local anyChanged = false
	local completedQuests = {}

	for questId, state in pairs(profile.activeQuests) do
		local quest = Quests.ById[questId]
		if not quest then
			continue
		end

		local questChanged = false

		for _, objective in ipairs(quest.objectives) do
			local objectiveState = state.objectives[objective.id]
			if not objectiveState or objectiveState.complete then
				continue
			end

			-- Sequenced objectives wait for their predecessor.
			if objective.afterObjective then
				local predecessor = state.objectives[objective.afterObjective]
				if not predecessor or not predecessor.complete then
					continue
				end
			end

			local matcher = Matchers[objective.type]
			if not matcher then
				continue
			end

			local contribution = matcher(objective, event, session, profile)
			if contribution <= 0 then
				continue
			end

			-- Conditional objectives (no damage taken, solo, no equipment) are
			-- checked at the moment of contribution.
			if objective.condition and not self:_checkCondition(player, objective.condition, event, session) then
				continue
			end

			local target = objective.target or 1
			if PEAK_OBJECTIVES[objective.type] then
				objectiveState.progress = math.max(objectiveState.progress, contribution)
			else
				objectiveState.progress += contribution
			end

			if objective.consecutive and event.grade and objective.grade and event.grade ~= objective.grade then
				objectiveState.progress = 0
			end

			if objectiveState.progress >= target then
				objectiveState.progress = target
				objectiveState.complete = true
			end

			questChanged = true
			anyChanged = true
			self.ObjectiveAdvanced:Fire(player, questId, objective.id, objectiveState.progress, target)
		end

		if questChanged then
			local allComplete = true
			for _, objective in ipairs(quest.objectives) do
				local objectiveState = state.objectives[objective.id]
				if not objectiveState or not objectiveState.complete then
					allComplete = false
					break
				end
			end
			if allComplete then
				table.insert(completedQuests, questId)
			end
		end
	end

	-- Rotating quests use a flat progress counter rather than named objectives.
	self:_applyEventToRotating(player, profile, event, session)

	if anyChanged then
		self._data:MarkDirty(player)
		self:_syncQuests(player)
	end

	for _, questId in ipairs(completedQuests) do
		self:_completeQuest(player, questId)
	end
end

function QuestService:_checkCondition(player: Player, condition: string, event: any, session: any): boolean
	if condition == "no_damage_taken" then
		return session.runDamageTaken <= 0
	elseif condition == "solo" then
		return #Players:GetPlayers() == 1 or (event.captors or 1) <= 1
	elseif condition == "no_equipment" then
		local profile = self._data:GetProfile(player)
		if not profile then
			return false
		end
		return next(profile.equipped) == nil
	elseif condition == "no_bank_no_vent" then
		return not event.banked and not event.vented
	end
	return true
end

function QuestService:_applyEventToRotating(player: Player, profile: any, event: any, session: any)
	local function advance(list)
		for _, instance in ipairs(list) do
			if instance.complete then
				continue
			end
			local pseudoObjective = {
				type = instance.objectiveType,
				target = instance.target,
				grade = instance.grade,
				minRarity = instance.minRarity,
				region = instance.region,
				resource = instance.resource,
				distinctRegions = instance.distinctRegions,
				requiresTopContribution = instance.requiresTopContribution,
			}
			local matcher = Matchers[instance.objectiveType]
			if matcher then
				local contribution = matcher(pseudoObjective, event, session, profile)
				if contribution > 0 then
					if PEAK_OBJECTIVES[instance.objectiveType] then
						instance.progress = math.max(instance.progress, contribution)
					else
						instance.progress += contribution
					end
					if instance.progress >= instance.target then
						instance.progress = instance.target
						instance.complete = true
						self:_awardRotating(player, instance)
					end
					self._data:MarkDirty(player)
				end
			end
		end
	end

	advance(profile.dailyQuests or {})
	advance(profile.weeklyQuests or {})
end

-- ============================================================================
-- Completion and rewards
-- ============================================================================

function QuestService:_completeQuest(player: Player, questId: string)
	local profile = self._data:GetProfile(player)
	if not profile then
		return
	end
	local quest = Quests.ById[questId]
	if not quest then
		return
	end

	profile.activeQuests[questId] = nil
	profile.completedQuests[questId] = true

	if quest.repeatable and quest.cooldownHours then
		profile.questCooldowns[questId] = os.time() + quest.cooldownHours * 3600
	end

	local granted = self:_grantRewards(player, quest.rewards, "quest:" .. questId)

	self._data:MarkDirty(player)
	self.QuestCompleted:Fire(player, questId)

	Net.FireClient(player, "QuestCompleted", {
		questId = questId,
		name = quest.name,
		type = quest.type,
		storyBeat = quest.storyBeat,
		rewards = granted,
	})

	if quest.type == "challenge" then
		local session = self:_getSession(player)
		session.challengesCompletedThisWeek += 1
		self:_applyEvent(player, { kind = "challenge_completed" })
	end

	-- Chain straight into the next main quest so the player is never left without
	-- a next instruction.
	if quest.type == "main" then
		local nextMain = Quests.GetNextMainQuest(profile.completedQuests)
		if nextMain then
			local available = Quests.IsAvailable(nextMain.id, self:_buildQuestState(player, profile))
			if available then
				self:Accept(player, nextMain.id, true)
				profile.trackedQuest = nextMain.id
			else
				-- Blocked on level: tell the player exactly what to do.
				Net.FireClient(player, "Notification", {
					kind = "info",
					title = "Next: " .. nextMain.name,
					body = nextMain.requiredLevel
						and ("Unlocks at level %d."):format(nextMain.requiredLevel)
						or nextMain.summary,
				})
			end
		end
	end

	self:_syncQuests(player)

	if self._analytics then
		self._analytics:Track(player, "quest_completed", { questId = questId, type = quest.type })
	end
end

--[[ Grants a reward block and returns a description of what was actually given. ]]
function QuestService:_grantRewards(player: Player, rewards: any, source: string)
	local granted = {}

	if rewards.watts then
		local amount = self._economy:Award(player, "watts", rewards.watts, source)
		table.insert(granted, { kind = "currency", id = "watts", name = "Watts", quantity = amount })
	end
	if rewards.cores then
		local amount = self._economy:Award(player, "cores", rewards.cores, source)
		table.insert(granted, { kind = "currency", id = "cores", name = "Cores", quantity = amount })
	end
	if rewards.sigils then
		local amount = self._economy:Award(player, "sigils", rewards.sigils, source)
		table.insert(granted, { kind = "currency", id = "sigils", name = "Sigils", quantity = amount })
	end
	if rewards.xp then
		self._progression:AwardXp(player, rewards.xp, source)
		table.insert(granted, { kind = "xp", quantity = rewards.xp })
	end
	if rewards.resources then
		for resourceId, quantity in pairs(rewards.resources) do
			local amount = self._economy:AwardResource(player, resourceId, quantity, source)
			local resource = Resources.ById[resourceId]
			table.insert(granted, {
				kind = "resource",
				id = resourceId,
				name = resource and resource.name or resourceId,
				quantity = amount,
			})
		end
	end
	if rewards.item then
		local Equipment = require(Shared.Config.Equipment)
		if Equipment.UniqueById[rewards.item] then
			local item = self._inventory:GrantUnique(player, rewards.item, source)
			if item then
				table.insert(granted, {
					kind = "unique",
					id = item.u,
					name = Equipment.UniqueById[rewards.item].name,
					rarity = item.r,
					view = self._inventory:BuildItemView(item),
				})
			end
		end
	end
	if rewards.unlocksTraversal then
		local Traversal = require(Shared.Config.Traversal)
		local ability = Traversal.ById[rewards.unlocksTraversal]
		self._progression:GrantUnlock(player, "traversal", rewards.unlocksTraversal,
			ability and ability.name or rewards.unlocksTraversal,
			{ tutorial = ability and ability.tutorial })
		table.insert(granted, { kind = "traversal", id = rewards.unlocksTraversal, name = ability and ability.name })
	end
	if rewards.unlocksAbility then
		local Abilities = require(Shared.Config.Abilities)
		local ability = Abilities.ActiveById[rewards.unlocksAbility]
		self._progression:GrantUnlock(player, "ability", rewards.unlocksAbility,
			ability and ability.name or rewards.unlocksAbility,
			{ description = ability and ability.description })
		table.insert(granted, { kind = "ability", id = rewards.unlocksAbility, name = ability and ability.name })
	end
	if rewards.title then
		self._progression:GrantUnlock(player, "title", rewards.title, rewards.title)
		table.insert(granted, { kind = "title", id = rewards.title })
	end
	if rewards.lore then
		local profile = self._data:GetProfile(player)
		if profile then
			profile.loreFound[rewards.lore] = true
			self._data:MarkDirty(player)
		end
		table.insert(granted, { kind = "lore", id = rewards.lore })
	end
	if rewards.discovery then
		local discoveries = self.Registry:Find("DiscoveryService")
		if discoveries then
			discoveries:Grant(player, rewards.discovery)
		end
	end

	return granted
end

function QuestService:_awardRotating(player: Player, instance: any)
	local granted = self:_grantRewards(player, instance.rewards, "rotating:" .. instance.templateId)
	Net.FireClient(player, "QuestCompleted", {
		questId = instance.templateId,
		name = instance.name,
		type = instance.type,
		rewards = granted,
	})
end

-- ============================================================================
-- Rotating quests
-- ============================================================================

--[[ Regenerates the daily and weekly sets when their windows have rolled over. ]]
function QuestService:_refreshRotating(player: Player, profile: any)
	local now = os.time()
	local changed = false

	if now >= (profile.dailyResetAt or 0) then
		profile.dailyQuests = self:_generateRotating(profile, Quests.DailyTemplates, 3, "daily")
		profile.dailyResetAt = math.floor(now / DAY_SECONDS) * DAY_SECONDS + DAY_SECONDS
		changed = true
	end

	if now >= (profile.weeklyResetAt or 0) then
		profile.weeklyQuests = self:_generateRotating(profile, Quests.WeeklyTemplates, 2, "weekly")
		profile.weeklyResetAt = math.floor(now / WEEK_SECONDS) * WEEK_SECONDS + WEEK_SECONDS
		changed = true
	end

	if changed then
		self._data:MarkDirty(player)
	end
end

function QuestService:_generateRotating(profile: any, templates: { any }, count: number, kind: string)
	-- Seeded on the player and the period, so the same player sees the same set all
	-- day across servers rather than rerolling on every rejoin.
	local period = kind == "daily" and math.floor(os.time() / DAY_SECONDS) or math.floor(os.time() / WEEK_SECONDS)
	local rng = RNG.new(("%s_%d_%s"):format(tostring(profile.createdAt or 0), period, kind))

	local pool = table.clone(templates)
	rng:Shuffle(pool)

	local unlockedRegions = Regions.GetUnlocked({
		level = profile.level,
		prestige = profile.prestige,
		completedQuests = profile.completedQuests,
		traversal = profile.traversal,
	})

	local instances = {}
	for index = 1, math.min(count, #pool) do
		local template = pool[index]
		local context = {}

		if template.scalesWithRegion and #unlockedRegions > 0 then
			context.region = rng:Pick(unlockedRegions)
			local region = Regions.ById[context.region]
			if template.objectiveType == "collect" and region then
				local resourceIds = {}
				for resourceId in pairs(region.resources) do
					table.insert(resourceIds, resourceId)
				end
				table.sort(resourceIds)
				context.resource = rng:Pick(resourceIds)
			end
		end

		local instance = Quests.InstantiateTemplate(template, profile.level, context)
		instance.complete = false
		instance.summary = self:_formatRotatingSummary(template, instance)
		table.insert(instances, instance)
	end

	return instances
end

function QuestService:_formatRotatingSummary(template: any, instance: any): string
	local regionName = instance.region and Regions.ById[instance.region] and Regions.ById[instance.region].name or "the field"
	local resourceName = instance.resource and Resources.ById[instance.resource] and Resources.ById[instance.resource].name or "materials"

	local ok, formatted = pcall(function()
		if template.scalesWithRegion and template.objectiveType == "collect" then
			return string.format(template.summaryFormat, instance.target, resourceName)
		elseif template.scalesWithRegion then
			return string.format(template.summaryFormat, instance.target, regionName)
		end
		return string.format(template.summaryFormat, instance.target)
	end)
	return ok and formatted or template.name
end

-- ============================================================================
-- Notification entry points, called by gameplay services
-- ============================================================================

function QuestService:NotifyCapture(player: Player, data: any)
	self:_applyEvent(player, {
		kind = "capture",
		stormTypeId = data.stormTypeId,
		regionId = data.regionId,
		grade = data.grade,
		rarity = data.rarity,
		energy = data.energy,
	})
	local carry = self.Registry:Find("CarryService")
	if carry then
		self:_applyEvent(player, { kind = "chain", chain = carry:GetChain(player) })
		self:_applyEvent(player, { kind = "carry", fill = carry:GetFillFraction(player) })
	end
end

function QuestService:NotifyBank(player: Player, data: any)
	self:_applyEvent(player, {
		kind = "bank",
		energy = data.energy,
		watts = data.watts,
		stationId = data.stationId,
		regionId = data.regionId,
	})
	local session = self:_getSession(player)
	session.runDamageTaken = 0
end

function QuestService:NotifyReach(player: Player, data: any)
	self:_applyEvent(player, {
		kind = "reach",
		region = data.region,
		subregion = data.subregion,
		landmark = data.landmark,
	})
end

function QuestService:NotifyDiscovery(player: Player, discoveryId: string)
	self:_applyEvent(player, { kind = "discover", discoveryId = discoveryId })
end

function QuestService:NotifyCollect(player: Player, resourceId: string, quantity: number)
	self:_applyEvent(player, { kind = "collect", resourceId = resourceId, quantity = quantity })
end

function QuestService:NotifyLoot(player: Player, awards: { any })
	for _, award in ipairs(awards) do
		if award.kind == "resource" then
			self:_applyEvent(player, { kind = "collect", resourceId = award.id, quantity = award.quantity })
		end
	end
end

function QuestService:NotifySurvive(player: Player, seconds: number, regionId: string?, subregionId: string?)
	self:_applyEvent(player, {
		kind = "survive",
		seconds = seconds,
		region = regionId,
		subregion = subregionId,
	})
end

function QuestService:NotifyInteract(player: Player, tag: string)
	self:_applyEvent(player, { kind = "interact", tag = tag })
end

function QuestService:NotifyDefeat(player: Player, bossId: string)
	self:_applyEvent(player, { kind = "defeat", bossId = bossId })
end

function QuestService:NotifyEvent(player: Player, eventId: string, rank: number?)
	self:_applyEvent(player, { kind = "event", eventId = eventId, rank = rank })
end

function QuestService:NotifyUpgrade(player: Player, upgradeId: string, level: number)
	self:_applyEvent(player, { kind = "upgrade", upgradeId = upgradeId, level = level })
end

function QuestService:NotifyTraverse(player: Player, ability: string, amount: number)
	self:_applyEvent(player, { kind = "traverse", ability = ability, amount = amount })
end

function QuestService:NotifyStat(player: Player, statId: string, value: number)
	self:_applyEvent(player, { kind = "stat", statId = statId, value = value })
end

function QuestService:NotifyDamageTaken(player: Player, amount: number)
	self:_getSession(player).runDamageTaken += amount
end

function QuestService:NotifyLevelUp(player: Player, level: number)
	local profile = self._data:GetProfile(player)
	if not profile then
		return
	end
	-- A level-up can make the next main quest available; accept it immediately.
	local nextMain = Quests.GetNextMainQuest(profile.completedQuests)
	if nextMain and not profile.activeQuests[nextMain.id] then
		if Quests.IsAvailable(nextMain.id, self:_buildQuestState(player, profile)) then
			self:Accept(player, nextMain.id)
		end
	end
end

-- ============================================================================
-- Views and sync
-- ============================================================================

function QuestService:_buildQuestView(player: Player, profile: any, questId: string)
	local quest = Quests.ById[questId]
	local state = profile.activeQuests[questId]
	if not quest or not state then
		return nil
	end

	local objectives = {}
	for _, objective in ipairs(quest.objectives) do
		local objectiveState = state.objectives[objective.id] or { progress = 0, complete = false }
		local locked = false
		if objective.afterObjective then
			local predecessor = state.objectives[objective.afterObjective]
			locked = not (predecessor and predecessor.complete)
		end
		table.insert(objectives, {
			id = objective.id,
			description = objective.description,
			progress = objectiveState.progress,
			target = objective.target or 1,
			complete = objectiveState.complete,
			locked = locked,
			type = objective.type,
			subregion = objective.subregion,
			region = objective.region,
		})
	end

	return {
		id = questId,
		name = quest.name,
		summary = quest.summary,
		description = quest.description,
		type = quest.type,
		region = quest.region,
		regionName = quest.region and Regions.ById[quest.region] and Regions.ById[quest.region].name or nil,
		objectives = objectives,
		rewards = quest.rewards,
		teaches = quest.teaches,
		giver = quest.giver,
	}
end

function QuestService:_syncQuests(player: Player)
	local profile = self._data:GetProfile(player)
	if not profile then
		return
	end

	local active = {}
	for questId in pairs(profile.activeQuests) do
		local view = self:_buildQuestView(player, profile, questId)
		if view then
			table.insert(active, view)
		end
	end
	table.sort(active, function(a, b)
		local aMain = a.type == "main" and 0 or 1
		local bMain = b.type == "main" and 0 or 1
		if aMain ~= bMain then
			return aMain < bMain
		end
		return a.id < b.id
	end)

	local availableQuests = {}
	for _, quest in ipairs(Quests.GetAvailable(self:_buildQuestState(player, profile))) do
		table.insert(availableQuests, {
			id = quest.id,
			name = quest.name,
			summary = quest.summary,
			type = quest.type,
			region = quest.region,
			requiredLevel = quest.requiredLevel,
			rewards = quest.rewards,
		})
	end

	local fraction, done, total = Quests.GetMainProgress(profile.completedQuests)

	Net.FireClient(player, "QuestUpdate", {
		active = active,
		available = availableQuests,
		tracked = profile.trackedQuest,
		daily = profile.dailyQuests,
		weekly = profile.weeklyQuests,
		dailyResetAt = profile.dailyResetAt,
		weeklyResetAt = profile.weeklyResetAt,
		mainProgress = { fraction = fraction, done = done, total = total },
	})
end

--[[ Slow tick: rolls over daily and weekly sets for connected players. ]]
function QuestService:Tick()
	for _, player in ipairs(Players:GetPlayers()) do
		local profile = self._data:GetProfile(player)
		if profile then
			local before = profile.dailyResetAt
			self:_refreshRotating(player, profile)
			if profile.dailyResetAt ~= before then
				self:_syncQuests(player)
			end
		end
	end
end

return QuestService
