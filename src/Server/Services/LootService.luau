--!strict
--[[
	LootService
	-----------
	Decides what drops, and makes the drop feel like something.

	Two mechanisms matter here beyond the raw tables:

	  * Bad-luck protection. A pity counter per loot table raises the effective luck
	    on every roll that fails to produce a rare-or-better, and resets when one
	    lands. Without it, variance produces players who genuinely go a whole session
	    with nothing, and those players quit.

	  * Rarity presentation. A common material and a mythic unique both come out of
	    the same function, but they leave through different doors: one is a quiet
	    HUD tick, the other is a server announcement.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BTS")
local Signal = require(Shared.Core.Signal)
local RNG = require(Shared.Core.RNG)
local Net = require(Shared.Net)
local Balance = require(Shared.Config.Balance)
local LootTables = require(Shared.Config.LootTables)
local Equipment = require(Shared.Config.Equipment)
local Resources = require(Shared.Config.Resources)
local StormTypes = require(Shared.Config.StormTypes)

local LootService = {}
LootService.Name = "LootService"
LootService.Dependencies = { "DataService", "StatsService", "EconomyService", "InventoryService" }
LootService.Priority = 32

function LootService:Init()
	self._rng = RNG.new("loot_" .. tostring(os.time()))
	self.LootAwarded = Signal.new("LootService.LootAwarded")
end

function LootService:Start()
	self._data = self.Registry:Get("DataService")
	self._stats = self.Registry:Get("StatsService")
	self._economy = self.Registry:Get("EconomyService")
	self._inventory = self.Registry:Get("InventoryService")
	self._analytics = self.Registry:Find("AnalyticsService")
	self._quests = self.Registry:Find("QuestService")
end

-- ============================================================================
-- Luck and pity
-- ============================================================================

--[[
	Effective luck for a roll: the player's Fortune stat plus accumulated pity for
	this specific loot table.
]]
function LootService:_getEffectiveLuck(player: Player, tableId: string): number
	local base = self._stats:GetStat(player, "luck")

	local profile = self._data:GetProfile(player)
	if not profile then
		return base
	end
	local pity = profile.pity[tableId] or 0
	return base + math.min(Balance.Loot.PITY_CAP, pity)
end

--[[ Advances or resets pity based on what the roll produced. ]]
function LootService:_updatePity(player: Player, tableId: string, results: { any })
	local profile = self._data:GetProfile(player)
	if not profile then
		return
	end

	local resetRarities = {}
	for _, rarity in ipairs(Balance.Loot.PITY_RESET_RARITIES) do
		resetRarities[rarity] = true
	end

	local satisfying = false
	for _, result in ipairs(results) do
		if result.kind == "equipment" and resetRarities[result.rarity] then
			satisfying = true
		elseif result.kind == "unique" then
			satisfying = true
		end
	end

	if satisfying then
		profile.pity[tableId] = 0
	else
		profile.pity[tableId] = math.min(
			Balance.Loot.PITY_CAP,
			(profile.pity[tableId] or 0) + Balance.Loot.PITY_INCREMENT
		)
	end
	self._data:MarkDirty(player)
end

-- ============================================================================
-- Rarity selection
-- ============================================================================

--[[
	Rolls an equipment rarity, tilted by luck and clamped by the table's tier bias.
	`tierBias` shifts the floor upward so an endgame table cannot produce a common.
]]
function LootService:RollRarity(luck: number, tierBias: number?): string
	local weights = {}
	for _, rarity in ipairs(Balance.Loot.RARITY_ORDER) do
		local base = Balance.Loot.RARITY_BASE_WEIGHTS[rarity]
		local tilt = Balance.Loot.RARITY_LUCK_TILT[rarity] or 0
		weights[rarity] = math.max(0.0001, base * (1 + luck * tilt))
	end

	-- A high tier bias suppresses the bottom rarities entirely rather than merely
	-- making them unlikely, which is what stops a Core Cache dropping scrap.
	local bias = tierBias or 0
	if bias > 0 then
		local order = Balance.Loot.RARITY_ORDER
		local floorIndex = math.min(#order, 1 + math.floor(bias * 0.6))
		for index = 1, floorIndex - 1 do
			weights[order[index]] = 0
		end
	end

	return self._rng:PickWeightedMap(weights) or "common"
end

-- ============================================================================
-- Rolling
-- ============================================================================

--[[
	Rolls a loot table and grants everything it produced.
	Returns an array of award descriptors for the client's reveal sequence.
]]
function LootService:RollTable(player: Player, tableId: string, rolls: number, context: {
	regionId: string?,
	source: string?,
	luckBonus: number?,
}): { any }
	local lootTable = LootTables.ById[tableId]
	if not lootTable then
		return {}
	end

	local profile = self._data:GetProfile(player)
	if not profile then
		return {}
	end

	if lootTable.requiresPrestige and profile.prestige < lootTable.requiresPrestige then
		return {}
	end

	local luck = self:_getEffectiveLuck(player, tableId) + (context.luckBonus or 0)

	-- Treasure Sense: roll twice, keep the better result.
	local doubleRoll = self._stats:HasBehaviour(player, "double_loot_roll")

	local awards = {}
	local yieldStat = self._stats:GetStat(player, "resourceYield")

	for _ = 1, rolls do
		local result = LootTables.Roll(self._rng, tableId, luck)
		if doubleRoll then
			local second = LootTables.Roll(self._rng, tableId, luck)
			result = self:_pickBetter(result, second)
		end
		if not result then
			continue
		end

		if result.kind == "resource" then
			local quantity = math.max(1, math.floor(result.quantity * yieldStat))
			local granted = self._economy:AwardResource(player, result.id, quantity, context.source or tableId)
			if granted > 0 then
				local resource = Resources.ById[result.id]
				table.insert(awards, {
					kind = "resource",
					id = result.id,
					name = resource and resource.name or result.id,
					rarity = resource and resource.rarity or "common",
					colour = resource and resource.color or "FFFFFF",
					quantity = granted,
				})
			end

		elseif result.kind == "currency" then
			local granted = self._economy:Award(player, result.id, result.quantity, context.source or tableId)
			if granted > 0 then
				table.insert(awards, {
					kind = "currency",
					id = result.id,
					name = result.id == "cores" and "Cores" or result.id,
					quantity = granted,
				})
			end

		elseif result.kind == "equipment" then
			local pool = Equipment.GetDropPool(context.regionId or profile.lastRegion or "starter_district", profile.level)
			if #pool == 0 then
				-- Fall back to the starter pool so an equipment result is never wasted.
				pool = Equipment.GetDropPool("starter_district", profile.level)
			end
			if #pool > 0 then
				local baseId = self._rng:Pick(pool)
				local rarity = self:RollRarity(luck, result.tierBias)

				-- Honour a table's declared rarity floor.
				if result.minRarity then
					local order = Balance.Loot.RARITY_ORDER
					local floorIndex = table.find(order, result.minRarity) or 1
					local rolledIndex = table.find(order, rarity) or 1
					if rolledIndex < floorIndex then
						rarity = result.minRarity
					end
				end

				local item = self._inventory:AddItem(player, baseId, rarity, context.source or tableId)
				if item then
					local view = self._inventory:BuildItemView(item)
					table.insert(awards, {
						kind = "equipment",
						id = item.u,
						baseId = baseId,
						name = view.name,
						rarity = item.r,
						view = view,
					})
				end
			end

		elseif result.kind == "unique" then
			local item = self._inventory:GrantUnique(player, result.id, context.source or tableId)
			if item then
				local view = self._inventory:BuildItemView(item)
				table.insert(awards, {
					kind = "unique",
					id = item.u,
					baseId = result.id,
					name = view.name,
					rarity = item.r,
					view = view,
				})
				self:_announceRareDrop(player, view)
			end
		end
	end

	self:_updatePity(player, tableId, awards)

	if #awards > 0 then
		self.LootAwarded:Fire(player, awards, tableId)
		if self._quests then
			self._quests:NotifyLoot(player, awards)
		end
	end

	return awards
end

--[[ Picks the more valuable of two roll results, for Treasure Sense. ]]
function LootService:_pickBetter(a: any?, b: any?)
	if not a then
		return b
	end
	if not b then
		return a
	end
	local rank = { nothing = 0, resource = 1, currency = 2, equipment = 3, unique = 4 }
	local rankA = rank[a.kind] or 0
	local rankB = rank[b.kind] or 0
	if rankA ~= rankB then
		return rankA > rankB and a or b
	end
	return (a.quantity or 0) >= (b.quantity or 0) and a or b
end

-- ============================================================================
-- Entry points
-- ============================================================================

--[[
	The per-capture drop roll. Most captures produce nothing; that is deliberate, and
	the base chance lives in Balance so it is tunable in one place.
]]
function LootService:RollCaptureDrop(player: Player, cell: any, grade: string): { any }?
	local storm = cell.storm
	local dropChance = Balance.Loot.BASE_DROP_CHANCE * (storm.drops.chanceScale or 1)

	if grade == "Overcharge" then
		dropChance += Balance.Loot.OVERCHARGE_DROP_BONUS
	end

	-- Fortune raises the chance of getting a roll at all, on top of tilting it.
	local luck = self._stats:GetStat(player, "luck")
	dropChance *= 1 + luck * 0.18

	if self._rng:NextNumber() > dropChance then
		return nil
	end

	return self:RollTable(player, storm.drops.table, 1, {
		regionId = cell.regionId,
		source = "capture:" .. storm.id,
	})
end

--[[ Boss and world event drops: guaranteed, multiple rolls, announced. ]]
function LootService:RollBossDrop(player: Player, tableId: string, rolls: number, source: string): { any }
	local awards = self:RollTable(player, tableId, rolls, { source = source })
	if #awards > 0 then
		Net.FireClient(player, "Notification", {
			kind = "good",
			title = "Cache recovered",
			body = ("%d items"):format(#awards),
		})
	end
	return awards
end

--[[ A legendary or better drop is server news, not a HUD tick. ]]
function LootService:_announceRareDrop(player: Player, view: any)
	if view.rarity ~= "legendary" and view.rarity ~= "mythic" and view.rarity ~= "exotic" then
		return
	end

	Net.FireAllClients("ServerAnnouncement", {
		kind = "rare_drop",
		playerName = player.DisplayName,
		itemName = view.name,
		rarity = view.rarity,
		icon = view.icon,
	})

	if self._analytics then
		self._analytics:Track(player, "rare_drop", { baseId = view.baseId, rarity = view.rarity })
	end
end

--[[
	The drop-rate readout the UI shows on a storm: "roughly 1 in 12, better with
	Fortune". Being honest about odds costs nothing and buys a lot of trust.
]]
function LootService:GetDropChanceDisplay(player: Player, stormTypeId: string): { chance: number, tableName: string }?
	local storm = StormTypes.ById[stormTypeId]
	if not storm then
		return nil
	end
	local lootTable = LootTables.ById[storm.drops.table]
	if not lootTable then
		return nil
	end

	local luck = self:_getEffectiveLuck(player, storm.drops.table)
	local rollChance = Balance.Loot.BASE_DROP_CHANCE * (storm.drops.chanceScale or 1) * (1 + luck * 0.18)
	local tableChance = LootTables.GetDropChance(storm.drops.table, luck)

	return {
		chance = math.min(1, rollChance * tableChance),
		tableName = lootTable.name,
	}
end

return LootService
