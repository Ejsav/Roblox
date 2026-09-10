--!strict
--[[
	UpgradeService
	--------------
	Purchases on the core upgrade tracks, and the milestone unlocks they trigger.

	Buying multiple levels at once is a single transaction: the total cost is computed
	first and either all levels are bought or none are. A partial purchase that ran
	out of Watts halfway would be a support ticket every time.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BTS")
local Signal = require(Shared.Core.Signal)
local Net = require(Shared.Net)
local Upgrades = require(Shared.Config.Upgrades)
local Traversal = require(Shared.Config.Traversal)
local Abilities = require(Shared.Config.Abilities)

local UpgradeService = {}
UpgradeService.Name = "UpgradeService"
UpgradeService.Dependencies = { "DataService", "StatsService", "EconomyService", "ProgressionService" }
UpgradeService.Priority = 26

function UpgradeService:Init()
	self.UpgradePurchased = Signal.new("UpgradeService.UpgradePurchased")
	self.MilestoneReached = Signal.new("UpgradeService.MilestoneReached")
end

function UpgradeService:Start()
	self._data = self.Registry:Get("DataService")
	self._stats = self.Registry:Get("StatsService")
	self._economy = self.Registry:Get("EconomyService")
	self._progression = self.Registry:Get("ProgressionService")
	self._quests = self.Registry:Find("QuestService")
	self._analytics = self.Registry:Find("AnalyticsService")

	Net.OnServerEvent("RequestPurchaseUpgrade", function(player, upgradeId, levels)
		self:Purchase(player, upgradeId, levels)
	end)
end

function UpgradeService:GetLevel(player: Player, upgradeId: string): number
	local profile = self._data:GetProfile(player)
	if not profile then
		return 0
	end
	return profile.upgrades[upgradeId] or 0
end

--[[
	Buys `levels` levels of a track.
	Returns (success, reason, purchasedLevels, spent).
]]
function UpgradeService:Purchase(player: Player, upgradeId: string, levels: number): (boolean, string?, number, number)
	local upgrade = Upgrades.ById[upgradeId]
	if not upgrade then
		return false, "unknown_upgrade", 0, 0
	end

	local profile = self._data:GetProfile(player)
	if not profile then
		return false, "no_profile", 0, 0
	end

	local currentLevel = profile.upgrades[upgradeId] or 0
	if currentLevel >= upgrade.maxLevel then
		return false, "max_level", 0, 0
	end

	local requested = math.clamp(math.floor(levels or 1), 1, upgrade.maxLevel - currentLevel)

	-- Compute the exact total first; buying is all-or-nothing.
	local totalCost = 0
	for offset = 0, requested - 1 do
		local cost = Upgrades.GetCost(upgradeId, currentLevel + offset)
		if cost == math.huge then
			requested = offset
			break
		end
		totalCost += cost
	end

	if requested <= 0 then
		return false, "max_level", 0, 0
	end

	local balance = self._economy:GetBalance(player, upgrade.costCurrency)
	if balance < totalCost then
		Net.FireClient(player, "Notification", {
			kind = "warning",
			title = "Not enough",
			body = ("%s costs %d."):format(upgrade.name, totalCost),
		})
		return false, "insufficient_funds", 0, 0
	end

	local spent = self._economy:Spend(player, upgrade.costCurrency, totalCost, "upgrade:" .. upgradeId)
	if not spent then
		return false, "insufficient_funds", 0, 0
	end

	local newLevel = currentLevel + requested
	profile.upgrades[upgradeId] = newLevel
	self._data:MarkDirty(player)
	self._stats:Invalidate(player)

	-- Milestones crossed by this purchase.
	local crossed = {}
	for milestoneLevel, milestone in pairs(upgrade.milestones or {}) do
		if milestoneLevel > currentLevel and milestoneLevel <= newLevel then
			table.insert(crossed, { level = milestoneLevel, milestone = milestone })
		end
	end
	table.sort(crossed, function(a, b)
		return a.level < b.level
	end)

	for _, entry in ipairs(crossed) do
		self:_applyMilestone(player, upgrade, entry.milestone, entry.level)
	end

	self.UpgradePurchased:Fire(player, upgradeId, newLevel, requested)

	local nextMilestone, distance = Upgrades.GetNextMilestone(upgradeId, newLevel)
	Net.FireClient(player, "ProfileDelta", {
		upgrades = { [upgradeId] = newLevel },
		nextMilestone = nextMilestone and {
			upgradeId = upgradeId,
			name = nextMilestone.name,
			description = nextMilestone.description,
			levelsAway = distance,
		} or nil,
	})

	if self._quests then
		self._quests:NotifyUpgrade(player, upgradeId, newLevel)
	end

	if self._analytics then
		self._analytics:Track(player, "upgrade_purchased", {
			upgradeId = upgradeId,
			level = newLevel,
			levels = requested,
			cost = totalCost,
		})
	end

	return true, nil, requested, totalCost
end

--[[ Applies everything a milestone grants and announces it properly. ]]
function UpgradeService:_applyMilestone(player: Player, upgrade: any, milestone: any, level: number)
	if milestone.unlocksTraversal then
		local ability = Traversal.ById[milestone.unlocksTraversal]
		self._progression:GrantUnlock(
			player,
			"traversal",
			milestone.unlocksTraversal,
			ability and ability.name or milestone.unlocksTraversal,
			{ tutorial = ability and ability.tutorial }
		)
	end

	if milestone.grantsAbility then
		local ability = Abilities.ActiveById[milestone.grantsAbility]
		self._progression:GrantUnlock(
			player,
			"ability",
			milestone.grantsAbility,
			ability and ability.name or milestone.grantsAbility,
			{ description = ability and ability.description }
		)
	end

	self.MilestoneReached:Fire(player, upgrade.id, milestone, level)

	Net.FireClient(player, "UnlockGranted", {
		kind = "milestone",
		id = milestone.id,
		name = milestone.name,
		detail = {
			description = milestone.description,
			upgradeName = upgrade.name,
			level = level,
			gatesRegion = milestone.gatesRegion,
		},
	})
end

--[[
	The full upgrade panel view: level, cost, affordability, next milestone and the
	stat effect of the next level, for every track.
]]
function UpgradeService:BuildUpgradeView(player: Player)
	local profile = self._data:GetProfile(player)
	if not profile then
		return nil
	end

	local Stats = require(Shared.Config.Stats)
	local currentValues = self._stats:GetStats(player)

	local tracks = {}
	for _, upgrade in ipairs(Upgrades.List) do
		local level = profile.upgrades[upgrade.id] or 0
		local cost, currency = Upgrades.GetCost(upgrade.id, level)
		local nextMilestone, distance = Upgrades.GetNextMilestone(upgrade.id, level)

		-- Preview the stat change one level would produce.
		local preview = {}
		for kind, statMap in pairs(upgrade.perLevel) do
			for statId, amount in pairs(statMap) do
				local stat = Stats.ById[statId]
				if stat then
					local before = currentValues[statId] or stat.base
					local after = kind == "flat" and (before + amount)
						or (kind == "increased" and (before * (1 + amount)) or (before * (1 + amount)))
					local text = Stats.FormatDelta(statId, before, after)
					table.insert(preview, { statId = statId, name = stat.name, text = text })
				end
			end
		end

		local affordable, affordableCost = Upgrades.GetAffordableLevels(
			upgrade.id,
			level,
			self._economy:GetBalance(player, upgrade.costCurrency)
		)

		table.insert(tracks, {
			id = upgrade.id,
			name = upgrade.name,
			description = upgrade.description,
			category = upgrade.category,
			icon = upgrade.icon,
			level = level,
			maxLevel = upgrade.maxLevel,
			cost = cost,
			currency = currency,
			canAfford = cost ~= math.huge and self._economy:CanAfford(player, currency, cost),
			affordableLevels = affordable,
			affordableCost = affordableCost,
			preview = preview,
			nextMilestone = nextMilestone and {
				name = nextMilestone.name,
				description = nextMilestone.description,
				levelsAway = distance,
			} or nil,
			earnedMilestones = Upgrades.GetEarnedMilestones(upgrade.id, level),
		})
	end

	table.sort(tracks, function(a, b)
		return (Upgrades.ById[a.id].order or 0) < (Upgrades.ById[b.id].order or 0)
	end)

	return { tracks = tracks }
end

return UpgradeService
