--!strict
--[[
	ProgressionService
	------------------
	Runner level, XP, skill points, and the unlock announcements that come with them.

	Level-ups are one of the game's few genuine celebration moments, so this service
	is careful about them: it resolves multi-level jumps into a single event carrying
	everything that changed, rather than firing four separate popups when a player
	banks a huge run.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BTS")
local Signal = require(Shared.Core.Signal)
local MathUtil = require(Shared.Core.MathUtil)
local Net = require(Shared.Net)
local Balance = require(Shared.Config.Balance)
local Regions = require(Shared.Config.Regions)
local Traversal = require(Shared.Config.Traversal)
local ProfileSchema = require(Shared.Data.ProfileSchema)

local ProgressionService = {}
ProgressionService.Name = "ProgressionService"
ProgressionService.Dependencies = { "DataService", "StatsService", "EconomyService" }
ProgressionService.Priority = 18

function ProgressionService:Init()
	self.LevelledUp = Signal.new("ProgressionService.LevelledUp")
	self.XpAwarded = Signal.new("ProgressionService.XpAwarded")
	self.UnlockGranted = Signal.new("ProgressionService.UnlockGranted")
end

function ProgressionService:Start()
	self._data = self.Registry:Get("DataService")
	self._stats = self.Registry:Get("StatsService")
	self._analytics = self.Registry:Find("AnalyticsService")
	self._quests = self.Registry:Find("QuestService")
end

-- ============================================================================
-- XP and levelling
-- ============================================================================

--[[ Level, XP into the level, and XP required for the next — the HUD's bar. ]]
function ProgressionService:GetLevelInfo(player: Player)
	local profile = self._data:GetProfile(player)
	if not profile then
		return { level = 1, xpIntoLevel = 0, xpForNext = MathUtil.XpForLevel(1), fraction = 0 }
	end

	local level, into, needed = MathUtil.ResolveLevel(profile.xp, Balance.Progression.MAX_LEVEL)
	return {
		level = level,
		xpIntoLevel = into,
		xpForNext = needed,
		fraction = needed > 0 and (into / needed) or 1,
		isMaxLevel = level >= Balance.Progression.MAX_LEVEL,
	}
end

--[[
	Awards XP and resolves any level-ups it causes.
	Returns the amount actually awarded after multipliers.
]]
function ProgressionService:AwardXp(player: Player, baseAmount: number, source: string): number
	if type(baseAmount) ~= "number" or baseAmount ~= baseAmount or baseAmount <= 0 then
		return 0
	end

	local profile = self._data:GetProfile(player)
	if not profile then
		return 0
	end
	if profile.level >= Balance.Progression.MAX_LEVEL then
		-- At cap, XP still accrues for records and prestige eligibility, but no
		-- further levels are granted.
		profile.xp += baseAmount
		self._data:MarkDirty(player)
		return baseAmount
	end

	local multiplier = self._stats:GetStat(player, "xpGain")
	local events = self.Registry:Find("WorldEventService")
	if events then
		multiplier *= events:GetXpMultiplier(player)
	end

	-- Running with people nearby is worth a little more. Deliberately a small
	-- multiplier: enough that a group notices, never enough that playing alone
	-- feels like falling behind.
	local party = self.Registry:Find("PartyService")
	if party then
		multiplier *= party:GetXpMultiplier(player)
	end

	local amount = baseAmount * multiplier
	local previousLevel = profile.level

	profile.xp += amount

	local newLevel = MathUtil.ResolveLevel(profile.xp, Balance.Progression.MAX_LEVEL)
	if newLevel > previousLevel then
		profile.level = newLevel
		self:_onLevelUp(player, profile, previousLevel, newLevel)
	end

	self._data:MarkDirty(player)
	self.XpAwarded:Fire(player, amount, source)
	return amount
end

--[[ Resolves everything a level jump unlocks, and announces it once. ]]
function ProgressionService:_onLevelUp(player: Player, profile: any, fromLevel: number, toLevel: number)
	-- Skill points are recomputed from total earned rather than incremented, so a
	-- multi-level jump and a rebalance both land on the correct number.
	local earned = ProfileSchema.CalculateEarnedSkillPoints(toLevel)
	local SkillTree = require(Shared.Config.SkillTree)
	local spent = SkillTree.GetSpentPoints(profile.skills)
	local pointsGained = math.max(0, earned - spent) - profile.skillPoints
	profile.skillPoints = math.max(0, earned - spent)
	profile.skillPointsSpent = spent

	-- Regions that opened purely on level.
	local unlockedRegions = {}
	for _, region in ipairs(Regions.List) do
		if region.unlock.level and region.unlock.level > fromLevel and region.unlock.level <= toLevel then
			local state = self:_buildUnlockState(profile)
			if Regions.IsUnlocked(region.id, state) then
				table.insert(unlockedRegions, {
					id = region.id,
					name = region.name,
					subtitle = region.subtitle,
					danger = region.danger,
				})
			end
		end
	end

	self._stats:Invalidate(player)

	self.LevelledUp:Fire(player, toLevel, fromLevel)

	Net.FireClient(player, "LevelUp", {
		level = toLevel,
		previousLevel = fromLevel,
		skillPointsGained = pointsGained,
		skillPointsAvailable = profile.skillPoints,
		unlockedRegions = unlockedRegions,
		nextRegion = self:_describeNextRegion(profile),
	})

	for _, region in ipairs(unlockedRegions) do
		self:GrantUnlock(player, "region", region.id, region.name)
	end

	if self._analytics then
		self._analytics:TrackProgression(player, "level_up", toLevel)
	end

	if self._quests then
		self._quests:NotifyLevelUp(player, toLevel)
	end
end

function ProgressionService:_buildUnlockState(profile: any)
	return {
		level = profile.level,
		prestige = profile.prestige,
		completedQuests = profile.completedQuests,
		traversal = profile.traversal,
	}
end

--[[ The next locked region and what is missing — the "bigger goal" pointer. ]]
function ProgressionService:_describeNextRegion(profile: any)
	local region, reason, value = Regions.GetNextLocked(self:_buildUnlockState(profile))
	if not region then
		return nil
	end

	local requirementText
	if reason == "level" then
		requirementText = ("Reach level %d"):format(value)
	elseif reason == "quest" then
		local Quests = require(Shared.Config.Quests)
		local quest = Quests.ById[value]
		requirementText = quest and ("Complete: " .. quest.name) or "Complete a quest"
	elseif reason == "traversal" then
		local ability = Traversal.ById[value]
		requirementText = ability and ("Unlock " .. ability.name) or "Unlock a movement ability"
	elseif reason == "prestige" then
		requirementText = ("Reach Prestige %d"):format(value)
	else
		requirementText = "Keep going"
	end

	return {
		id = region.id,
		name = region.name,
		subtitle = region.subtitle,
		danger = region.danger,
		recommendedLevel = region.recommendedLevel,
		requirement = requirementText,
		reason = reason,
	}
end

function ProgressionService:GetNextRegion(player: Player)
	local profile = self._data:GetProfile(player)
	if not profile then
		return nil
	end
	return self:_describeNextRegion(profile)
end

-- ============================================================================
-- Unlocks
-- ============================================================================

--[[
	Records and announces an unlock of any kind.
	Every unlock in the game funnels through here so the presentation is consistent
	and the analytics funnel is complete.
]]
function ProgressionService:GrantUnlock(player: Player, kind: string, id: string, displayName: string?, detail: any?)
	local profile = self._data:GetProfile(player)
	if not profile then
		return false
	end

	local isNew = true

	if kind == "traversal" then
		isNew = not profile.traversal[id]
		profile.traversal[id] = true
	elseif kind == "ability" then
		isNew = not profile.abilitiesOwned[id]
		profile.abilitiesOwned[id] = true
		-- Auto-slot the first four abilities so a new player is never handed a
		-- capability they then have to go and find a menu to enable.
		if isNew and #profile.loadout < 4 then
			table.insert(profile.loadout, id)
		end
	elseif kind == "passive" then
		isNew = not profile.passivesOwned[id]
		profile.passivesOwned[id] = true
	elseif kind == "title" then
		isNew = not profile.titlesOwned[id]
		profile.titlesOwned[id] = true
	elseif kind == "fast_travel" then
		isNew = not profile.fastTravelUnlocked[id]
		profile.fastTravelUnlocked[id] = true
	end

	if not isNew then
		return false
	end

	self._data:MarkDirty(player)
	self._stats:Invalidate(player)

	self.UnlockGranted:Fire(player, kind, id)

	Net.FireClient(player, "UnlockGranted", {
		kind = kind,
		id = id,
		name = displayName or id,
		detail = detail,
	})

	if self._analytics then
		self._analytics:Track(player, "unlock", { kind = kind, id = id })
	end

	return true
end

-- ============================================================================
-- Skill points
-- ============================================================================

function ProgressionService:GetSkillPoints(player: Player): number
	local profile = self._data:GetProfile(player)
	return profile and profile.skillPoints or 0
end

--[[ Consumes skill points. Returns false and changes nothing if unaffordable. ]]
function ProgressionService:SpendSkillPoints(player: Player, amount: number): boolean
	local profile = self._data:GetProfile(player)
	if not profile or profile.skillPoints < amount then
		return false
	end
	profile.skillPoints -= amount
	profile.skillPointsSpent += amount
	self._data:MarkDirty(player)
	return true
end

--[[ Returns every point spent, for a respec. ]]
function ProgressionService:RefundAllSkillPoints(player: Player): number
	local profile = self._data:GetProfile(player)
	if not profile then
		return 0
	end
	local SkillTree = require(Shared.Config.SkillTree)
	local spent = SkillTree.GetSpentPoints(profile.skills)

	profile.skills = {}
	profile.skillPoints = ProfileSchema.CalculateEarnedSkillPoints(profile.level)
	profile.skillPointsSpent = 0

	self._data:MarkDirty(player)
	self._stats:Invalidate(player)
	return spent
end

-- ============================================================================
-- Records
-- ============================================================================

--[[
	Updates a "highest ever" record and announces it when it actually improves.
	Records are one of the cheapest sources of pride in the game, so they are only
	announced on a genuine improvement — never on a tie.
]]
function ProgressionService:UpdateRecord(player: Player, recordKey: string, value: number, displayName: string): boolean
	local profile = self._data:GetProfile(player)
	if not profile or not profile.records then
		return false
	end

	local previous = profile.records[recordKey] or 0
	if value <= previous then
		return false
	end

	profile.records[recordKey] = value
	self._data:MarkDirty(player)

	Net.FireClient(player, "RecordBroken", {
		key = recordKey,
		name = displayName,
		value = value,
		previous = previous,
	})

	local leaderboards = self.Registry:Find("LeaderboardService")
	if leaderboards then
		leaderboards:SubmitRecord(player, recordKey, value)
	end

	return true
end

function ProgressionService:IncrementRecord(player: Player, recordKey: string, amount: number)
	local profile = self._data:GetProfile(player)
	if not profile or not profile.records then
		return
	end
	profile.records[recordKey] = (profile.records[recordKey] or 0) + amount
	self._data:MarkDirty(player)
end

return ProgressionService
