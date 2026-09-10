--!strict
--[[
	AchievementService
	------------------
	Evaluates achievements, awards them, and owns the title catalogue.

	The whole system is deliberately pull-based. Achievements read the profile —
	records, collections, level, prestige — and never keep their own counters. That
	means:
	  * no achievement can drift out of sync with the statistic it describes,
	  * an achievement added months from now is awarded retroactively the first time
	    an existing player loads, with no migration to write,
	  * nothing has to be threaded through twenty call sites to make a new goal work.

	The cost is that "did anything complete?" has to be asked rather than announced.
	Asking is cheap (a scan of the achievement list against one profile table) but
	not free, and the events that could change an achievement — every capture, every
	bank, every pickup — fire many times a minute per player. So events only mark a
	player dirty and the sweep runs on the half-second tick, which collapses a
	thirty-capture run into a handful of evaluations.

	Awarding cascades: earning an achievement can complete the "earn half of every
	achievement" one, so the sweep repeats until the set stops growing.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BTS")
local Signal = require(Shared.Core.Signal)
local Net = require(Shared.Net)
local Achievements = require(Shared.Config.Achievements)

local AchievementService = {}
AchievementService.Name = "AchievementService"
AchievementService.Dependencies = { "DataService", "EconomyService", "ProgressionService" }
AchievementService.Priority = 46

-- How many times a single sweep may re-evaluate after granting something. Four is
-- far more than the content needs (only the meta achievements chain at all) and
-- guarantees the loop cannot run away if a future achievement is self-referential.
local MAX_CASCADE_PASSES = 4

-- An achievement worth interrupting everyone's session for. Hidden achievements
-- qualify because the interesting part is that nobody knew it existed; the rest
-- qualify on reward weight, which is already the design's measure of difficulty.
local ANNOUNCE_CORE_THRESHOLD = 45

local CURRENCY_REWARD_KEYS = { "watts", "cores", "sigils" }

function AchievementService:Init()
	-- player -> true. A set rather than a queue: two captures in one tick are one
	-- evaluation, not two.
	self._dirty = {}

	-- Title display names, built once from the achievements that award them. A title
	-- is stored on the profile as a bare id, so something has to know that
	-- "second_nature" reads as "Second Nature".
	self._titles = {}
	for _, achievement in ipairs(Achievements.List) do
		local titleId = achievement.rewards and achievement.rewards.title
		if titleId then
			self._titles[titleId] = {
				id = titleId,
				name = achievement.name,
				description = achievement.description,
				source = "achievement",
				sourceId = achievement.id,
			}
		end
	end

	self.AchievementEarned = Signal.new("AchievementService.AchievementEarned")
	self.TitleEquipped = Signal.new("AchievementService.TitleEquipped")

	self._stats = { evaluated = 0, granted = 0 }
end

function AchievementService:Start()
	self._data = self.Registry:Get("DataService")
	self._economy = self.Registry:Get("EconomyService")
	self._progression = self.Registry:Get("ProgressionService")
	self._analytics = self.Registry:Find("AnalyticsService")

	Net.OnServerEvent("RequestAchievements", function(player)
		return self:BuildView(player)
	end)

	Net.OnServerEvent("RequestEquipTitle", function(player, titleId)
		self:EquipTitle(player, titleId)
	end)

	Players.PlayerRemoving:Connect(function(player)
		self._dirty[player] = nil
	end)
end

--[[
	Signals are wired in Ready rather than Start so every service that owns one has
	definitely created it. Each listener does nothing but mark the player dirty —
	the real work happens on the tick.
]]
function AchievementService:Ready()
	local function markFrom(serviceName: string, signalName: string)
		local service = self.Registry:Find(serviceName)
		if not service then
			return
		end
		local signal = (service :: any)[signalName]
		if not signal then
			warn(("[BTS] AchievementService: %s has no signal %s"):format(serviceName, signalName))
			return
		end
		signal:Connect(function(player: Player)
			if typeof(player) == "Instance" and player:IsA("Player") then
				self._dirty[player] = true
			end
		end)
	end

	-- Everything that can move a number an achievement reads.
	markFrom("CaptureService", "Captured")
	markFrom("BankService", "Banked")
	markFrom("ProgressionService", "LevelledUp")
	markFrom("DiscoveryService", "DiscoveryMade")
	markFrom("QuestService", "QuestCompleted")
	markFrom("PrestigeService", "Prestiged")
	markFrom("CraftingService", "Crafted")
	markFrom("MasteryService", "MasteryLevelled")
	markFrom("InventoryService", "ItemAdded")
	markFrom("WorldEventService", "EventEnded")

	-- A profile loading is the retroactive path: it catches achievements a player
	-- already qualified for before the achievement existed.
	local data = self.Registry:Find("DataService")
	if data and data.ProfileLoaded then
		data.ProfileLoaded:Connect(function(player: Player)
			self._dirty[player] = true
		end)
	end
end

function AchievementService:Tick()
	if next(self._dirty) == nil then
		return
	end

	local pending = self._dirty
	self._dirty = {}

	for player in pairs(pending) do
		if player.Parent then
			self:Evaluate(player)
		end
	end
end

-- ============================================================================
-- Evaluation
-- ============================================================================

--[[
	Grants every achievement the profile now satisfies. Returns the number granted.
	Safe to call directly — the tick is an optimisation, not a requirement.
]]
function AchievementService:Evaluate(player: Player): number
	local profile = self._data:GetProfile(player)
	if not profile then
		return 0
	end

	self._stats.evaluated += 1

	local granted = 0

	for _ = 1, MAX_CASCADE_PASSES do
		local earned = Achievements.FindNewlyEarned(profile)
		if #earned == 0 then
			break
		end

		-- Stable order, so a cascade always reads the same way in the log and in the
		-- notification stack rather than depending on table iteration.
		table.sort(earned, function(a, b)
			return a.id < b.id
		end)

		for _, achievement in ipairs(earned) do
			self:_award(player, profile, achievement)
			granted += 1
		end
	end

	return granted
end

function AchievementService:_award(player: Player, profile: any, achievement: any)
	-- Recorded first. If a reward grant throws, the player keeps the achievement
	-- rather than being handed it again on the next tick forever.
	profile.achievements[achievement.id] = os.time()
	self._data:MarkDirty(player)

	self._stats.granted += 1

	local rewards = achievement.rewards or {}
	local rewardSummary = {}

	for _, currency in ipairs(CURRENCY_REWARD_KEYS) do
		local amount = rewards[currency]
		if amount and amount > 0 then
			self._economy:Award(player, currency, amount, "achievement:" .. achievement.id)
			table.insert(rewardSummary, { kind = "currency", id = currency, amount = amount })
		end
	end

	if rewards.title then
		self._progression:GrantUnlock(player, "title", rewards.title, achievement.name, {
			description = achievement.description,
			source = "achievement",
		})
		table.insert(rewardSummary, { kind = "title", id = rewards.title, name = achievement.name })

		-- A player who has never chosen a title wears their first one automatically.
		-- Earning a title and seeing nothing change is a reward that failed to land.
		if not profile.equippedTitle then
			profile.equippedTitle = rewards.title
			self.TitleEquipped:Fire(player, rewards.title)
		end
	end

	self.AchievementEarned:Fire(player, achievement.id, achievement)

	Net.FireClient(player, "AchievementEarned", {
		id = achievement.id,
		name = achievement.name,
		description = achievement.description,
		category = achievement.category,
		hidden = achievement.hidden == true,
		rewards = rewardSummary,
		earnedAt = profile.achievements[achievement.id],
		completion = self:_completionPayload(profile),
	})

	if self:_isNoteworthy(achievement) then
		Net.FireAllClients("ServerAnnouncement", {
			kind = "achievement",
			playerName = player.DisplayName,
			achievementName = achievement.name,
			hidden = achievement.hidden == true,
		})
	end

	if self._analytics then
		self._analytics:Track(player, "achievement", {
			id = achievement.id,
			category = achievement.category,
			hidden = achievement.hidden == true,
		})
	end
end

function AchievementService:_isNoteworthy(achievement: any): boolean
	if achievement.hidden then
		return true
	end
	local rewards = achievement.rewards or {}
	return (rewards.cores or 0) >= ANNOUNCE_CORE_THRESHOLD or (rewards.sigils or 0) > 0
end

function AchievementService:_completionPayload(profile: any)
	local earned, total = Achievements.GetCompletion(profile)
	return {
		earned = earned,
		total = total,
		fraction = total > 0 and earned / total or 0,
	}
end

-- ============================================================================
-- Titles
-- ============================================================================

--[[
	Display name for a title id. Achievement titles come from the catalogue built at
	Init; mastery titles are generated ids (`mastery_capture_20`) and are formatted
	from their own shape rather than being registered one by one.
]]
function AchievementService:GetTitleName(titleId: string): string
	local entry = self._titles[titleId]
	if entry then
		return entry.name
	end

	local track, level = titleId:match("^mastery_(.+)_(%d+)$")
	if track then
		local pretty = track:gsub("_", " "):gsub("^%l", string.upper)
		return ("%s %s"):format(pretty, level)
	end

	-- Anything else (prestige ranks, event titles) reads better title-cased than raw.
	return (titleId:gsub("_", " "):gsub("^%l", string.upper))
end

function AchievementService:GetOwnedTitles(player: Player)
	local profile = self._data:GetProfile(player)
	if not profile then
		return {}
	end

	local owned = {}
	for titleId in pairs(profile.titlesOwned or {}) do
		local entry = self._titles[titleId]
		table.insert(owned, {
			id = titleId,
			name = self:GetTitleName(titleId),
			description = entry and entry.description or nil,
			source = entry and entry.source or "other",
			equipped = profile.equippedTitle == titleId,
		})
	end

	table.sort(owned, function(a, b)
		return a.name < b.name
	end)

	return owned
end

--[[ Wears an owned title. An empty id clears the current one. ]]
function AchievementService:EquipTitle(player: Player, titleId: string?): boolean
	local profile = self._data:GetProfile(player)
	if not profile then
		return false
	end

	if titleId == nil or titleId == "" then
		profile.equippedTitle = nil
		self._data:MarkDirty(player)
		self.TitleEquipped:Fire(player, nil)
		return true
	end

	if not (profile.titlesOwned and profile.titlesOwned[titleId]) then
		return false
	end

	profile.equippedTitle = titleId
	self._data:MarkDirty(player)
	self.TitleEquipped:Fire(player, titleId)
	return true
end

-- ============================================================================
-- Views
-- ============================================================================

--[[
	The achievement panel.

	Hidden achievements that have not been earned appear as masked rows. They are
	shown rather than omitted on purpose: a locked mystery advertises that there is
	more in the game without spoiling what it is, and a completion percentage that
	silently excluded them would be a lie.
]]
function AchievementService:BuildView(player: Player)
	local profile = self._data:GetProfile(player)
	if not profile then
		return nil
	end

	local categories = {}
	local byCategory = {}

	for _, category in ipairs(Achievements.Categories) do
		local entry = {
			id = category.id,
			name = category.name,
			rows = {},
			earned = 0,
			total = 0,
		}
		byCategory[category.id] = entry
		table.insert(categories, entry)
	end

	for _, achievement in ipairs(Achievements.List) do
		local bucket = byCategory[achievement.category]
		if not bucket then
			continue
		end

		local earnedAt = profile.achievements and profile.achievements[achievement.id]
		local value, target = Achievements.GetProgress(achievement, profile)
		local masked = achievement.hidden == true and not earnedAt

		-- Written as a branch rather than `masked and nil or achievement.rewards`:
		-- that idiom silently falls through to the second value whenever the first
		-- is nil, which would publish the very title id the mask exists to hide.
		local visibleRewards = nil
		if not masked then
			visibleRewards = achievement.rewards
		end

		bucket.total += 1
		if earnedAt then
			bucket.earned += 1
		end

		table.insert(bucket.rows, {
			id = masked and ("hidden:" .. achievement.id) or achievement.id,
			name = masked and "???" or achievement.name,
			description = masked and "Not everything announces itself." or achievement.description,
			category = achievement.category,
			hidden = achievement.hidden == true,
			masked = masked,
			earned = earnedAt ~= nil,
			earnedAt = earnedAt,
			-- Progress on a masked row would leak how close a player is to something
			-- they are not supposed to know about, so it is withheld entirely.
			value = masked and 0 or math.min(value, target),
			target = masked and 1 or target,
			fraction = masked and 0 or (target > 0 and math.clamp(value / target, 0, 1) or 1),
			rewards = visibleRewards,
		})
	end

	for _, category in ipairs(categories) do
		table.sort(category.rows, function(a, b)
			-- Earned first, then closest to completion: the panel opens on progress,
			-- not on an alphabetised wall.
			if a.earned ~= b.earned then
				return a.earned
			end
			if a.masked ~= b.masked then
				return b.masked
			end
			return a.fraction > b.fraction
		end)
	end

	local completion = self:_completionPayload(profile)

	return {
		categories = categories,
		completion = completion,
		titles = self:GetOwnedTitles(player),
		equippedTitle = profile.equippedTitle,
	}
end

--[[ Compact summary for the profile card and the pause menu header. ]]
function AchievementService:GetSummary(player: Player)
	local profile = self._data:GetProfile(player)
	if not profile then
		return nil
	end

	local completion = self:_completionPayload(profile)
	completion.equippedTitle = profile.equippedTitle
	completion.equippedTitleName = profile.equippedTitle and self:GetTitleName(profile.equippedTitle) or nil
	return completion
end

function AchievementService:GetStats()
	return {
		evaluated = self._stats.evaluated,
		granted = self._stats.granted,
		pending = (function()
			local count = 0
			for _ in pairs(self._dirty) do
				count += 1
			end
			return count
		end)(),
	}
end

return AchievementService
