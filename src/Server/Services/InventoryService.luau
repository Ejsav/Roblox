--!strict
--[[
	InventoryService
	----------------
	Owns items: creation, equipping, dismantling and the slot budget.

	An item is (base) + (rarity) + (rolled affixes) + (optional trait). It is stored
	compactly on the profile and expanded into a full view only when the client asks,
	so a 220-slot inventory does not cost a fortune in datastore size or replication.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BTS")
local Signal = require(Shared.Core.Signal)
local RNG = require(Shared.Core.RNG)
local Net = require(Shared.Net)
local Balance = require(Shared.Config.Balance)
local Equipment = require(Shared.Config.Equipment)
local Modifiers = require(Shared.Config.Modifiers)
local Stats = require(Shared.Config.Stats)
local Resources = require(Shared.Config.Resources)
local ProfileSchema = require(Shared.Data.ProfileSchema)

local InventoryService = {}
InventoryService.Name = "InventoryService"
InventoryService.Dependencies = { "DataService", "StatsService", "EconomyService" }
InventoryService.Priority = 28

function InventoryService:Init()
	self._rng = RNG.new("inventory_" .. tostring(os.time()))

	self.ItemAdded = Signal.new("InventoryService.ItemAdded")
	self.ItemRemoved = Signal.new("InventoryService.ItemRemoved")
	self.ItemEquipped = Signal.new("InventoryService.ItemEquipped")
end

function InventoryService:Start()
	self._data = self.Registry:Get("DataService")
	self._stats = self.Registry:Get("StatsService")
	self._economy = self.Registry:Get("EconomyService")
	self._analytics = self.Registry:Find("AnalyticsService")

	Net.OnServerEvent("RequestEquip", function(player, uid)
		self:Equip(player, uid)
	end)
	Net.OnServerEvent("RequestUnequip", function(player, slotId)
		self:Unequip(player, slotId)
	end)
	Net.OnServerEvent("RequestDismantle", function(player, uids)
		self:Dismantle(player, uids)
	end)
	Net.OnServerEvent("RequestFavourite", function(player, uid, favourite)
		self:SetFavourite(player, uid, favourite)
	end)
end

-- ============================================================================
-- Item creation
-- ============================================================================

--[[ Allocates the next per-profile item uid. Short, because it is stored per item. ]]
function InventoryService:_nextUid(profile: any): string
	local serial = profile.nextItemId or 1
	profile.nextItemId = serial + 1
	return "i" .. tostring(serial)
end

--[[
	Rolls a complete item from a base and a rarity.
	Rarity decides affix count; the base's own tier caps affix magnitude.
]]
function InventoryService:RollItem(profile: any, baseId: string, rarity: string, source: string?, rngOverride: any?)
	local definition = Equipment.GetDefinition(baseId)
	if not definition then
		return nil
	end

	local rng = rngOverride or self._rng
	local uid = self:_nextUid(profile)

	-- A named unique drops whole: fixed rarity, fixed trait, no rolled affixes.
	if Equipment.UniqueById[baseId] then
		local item = ProfileSchema.CreateItem(uid, baseId, definition.rarity, {}, definition.trait, source)
		item.a = os.time()
		return item
	end

	-- Clamp the requested rarity into the base's declared band.
	local order = Balance.Loot.RARITY_ORDER
	local rarityIndex = table.find(order, rarity) or 1
	local minIndex = table.find(order, definition.minRarity) or 1
	local maxIndex = table.find(order, definition.maxRarity) or #order
	rarityIndex = math.clamp(rarityIndex, minIndex, maxIndex)
	local finalRarity = order[rarityIndex]

	local countRange = Balance.Loot.MODIFIER_COUNTS[finalRarity]
	local affixCount = rng:NextInteger(countRange.min, countRange.max)
	local affixes = Modifiers.RollAffixes(rng, definition.slot, definition.tier, affixCount)

	local item = ProfileSchema.CreateItem(uid, baseId, finalRarity, affixes, nil, source)
	item.a = os.time()
	return item
end

--[[
	Adds an item to a profile, enforcing the slot cap.
	Returns (item, reason). When full, the item is rejected rather than silently
	dropped, so the client can tell the player to make space.
]]
function InventoryService:AddItem(player: Player, baseId: string, rarity: string, source: string?): (any?, string?)
	local profile = self._data:GetProfile(player)
	if not profile then
		return nil, "no_profile"
	end

	if #profile.inventory >= Balance.Loot.MAX_INVENTORY_SLOTS then
		Net.FireClient(player, "Notification", {
			kind = "warning",
			title = "Inventory full",
			body = "Dismantle something to make room.",
		})
		return nil, "inventory_full"
	end

	local item = self:RollItem(profile, baseId, rarity, source)
	if not item then
		return nil, "unknown_base"
	end

	table.insert(profile.inventory, item)
	self._data:MarkDirty(player)

	self.ItemAdded:Fire(player, item)

	local view = self:BuildItemView(item)
	Net.FireClient(player, "ItemAcquired", view)

	if self._analytics then
		self._analytics:Track(player, "item_acquired", {
			baseId = baseId,
			rarity = item.r,
			source = source,
			affixes = #item.m,
		})
	end

	return item, nil
end

--[[ Grants a specific named unique. Used by quests and boss drops. ]]
function InventoryService:GrantUnique(player: Player, uniqueId: string, source: string?): (any?, string?)
	local definition = Equipment.UniqueById[uniqueId]
	if not definition then
		return nil, "unknown_unique"
	end

	-- Uniques are one-per-player; a duplicate converts to Cores instead.
	local profile = self._data:GetProfile(player)
	if not profile then
		return nil, "no_profile"
	end
	for _, item in ipairs(profile.inventory) do
		if item.b == uniqueId then
			self._economy:Award(player, "cores", 25, "duplicate_unique")
			Net.FireClient(player, "Notification", {
				kind = "good",
				title = "Duplicate",
				body = ("You already hold %s. Converted to 25 Cores."):format(definition.name),
			})
			return nil, "duplicate"
		end
	end

	return self:AddItem(player, uniqueId, definition.rarity, source or "unique")
end

-- ============================================================================
-- Lookup and views
-- ============================================================================

function InventoryService:FindItem(player: Player, uid: string): (any?, number?)
	local profile = self._data:GetProfile(player)
	if not profile then
		return nil, nil
	end
	for index, item in ipairs(profile.inventory) do
		if item.u == uid then
			return item, index
		end
	end
	return nil, nil
end

--[[
	Expands a stored item into a full client view: resolved name, stat lines,
	rarity, set membership and trait text.
]]
function InventoryService:BuildItemView(item: any)
	local definition = Equipment.GetDefinition(item.b)
	if not definition then
		return nil
	end

	local isUnique = Equipment.UniqueById[item.b] ~= nil
	local name = isUnique and definition.name or Modifiers.BuildName(definition.name, item.m or {})

	local baseLines = {}
	for kind, statMap in pairs(definition.baseStats or {}) do
		for statId, amount in pairs(statMap) do
			local stat = Stats.ById[statId]
			if stat then
				table.insert(baseLines, {
					statId = statId,
					kind = kind,
					value = amount,
					text = kind == "flat"
						and ("%+.4g %s"):format(amount, stat.name)
						or ("%+d%% %s %s"):format(math.floor(amount * 100 + 0.5), kind, stat.name),
				})
			end
		end
	end
	table.sort(baseLines, function(a, b)
		return a.statId < b.statId
	end)

	local affixLines = {}
	for _, rolled in ipairs(item.m or {}) do
		local affix = Modifiers.AffixById[rolled.affixId]
		if affix then
			table.insert(affixLines, {
				affixId = rolled.affixId,
				statId = affix.stat,
				tier = rolled.tier,
				value = rolled.value,
				text = Modifiers.DescribeAffix(rolled, Stats),
			})
		end
	end

	local trait = item.t and Modifiers.TraitById[item.t] or nil
	local setId = Equipment.SetByPiece[item.b]

	return {
		uid = item.u,
		baseId = item.b,
		name = name,
		baseName = definition.name,
		slot = definition.slot,
		rarity = item.r,
		tier = definition.tier,
		requiredLevel = definition.requiredLevel,
		flavour = definition.flavour,
		icon = definition.icon,
		favourite = item.f == true,
		acquiredAt = item.a,
		source = item.s,
		isUnique = isUnique,
		baseLines = baseLines,
		affixes = affixLines,
		trait = trait and { id = trait.id, name = trait.name, description = trait.description } or nil,
		setId = setId,
		setName = setId and Equipment.SetById[setId].name or nil,
	}
end

--[[ Full inventory view plus equipped map, for the inventory screen. ]]
function InventoryService:BuildInventoryView(player: Player)
	local profile = self._data:GetProfile(player)
	if not profile then
		return nil
	end

	local items = {}
	for _, item in ipairs(profile.inventory) do
		local view = self:BuildItemView(item)
		if view then
			table.insert(items, view)
		end
	end

	local equippedBaseIds = {}
	for _, uid in pairs(profile.equipped) do
		local item = self:FindItem(player, uid)
		if item then
			table.insert(equippedBaseIds, item.b)
		end
	end

	return {
		items = items,
		equipped = table.clone(profile.equipped),
		slots = Equipment.Slots,
		capacity = Balance.Loot.MAX_INVENTORY_SLOTS,
		used = #profile.inventory,
		setBonuses = Equipment.GetActiveSetBonuses(equippedBaseIds),
		setProgress = Equipment.GetSetProgress(equippedBaseIds),
	}
end

-- ============================================================================
-- Equipping
-- ============================================================================

function InventoryService:Equip(player: Player, uid: string): (boolean, string?)
	local profile = self._data:GetProfile(player)
	if not profile then
		return false, "no_profile"
	end

	local item = self:FindItem(player, uid)
	if not item then
		return false, "not_owned"
	end

	local definition = Equipment.GetDefinition(item.b)
	if not definition then
		return false, "unknown_base"
	end

	if profile.level < definition.requiredLevel then
		Net.FireClient(player, "Notification", {
			kind = "warning",
			title = "Level too low",
			body = ("%s requires level %d."):format(definition.name, definition.requiredLevel),
		})
		return false, "level_too_low"
	end

	profile.equipped[definition.slot] = uid
	self._data:MarkDirty(player)
	self._stats:Invalidate(player)

	self.ItemEquipped:Fire(player, definition.slot, item)
	self:_syncInventory(player)
	return true, nil
end

function InventoryService:Unequip(player: Player, slotId: string): (boolean, string?)
	local profile = self._data:GetProfile(player)
	if not profile then
		return false, "no_profile"
	end
	if not Equipment.SlotById[slotId] then
		return false, "unknown_slot"
	end
	if not profile.equipped[slotId] then
		return false, "slot_empty"
	end

	profile.equipped[slotId] = nil
	self._data:MarkDirty(player)
	self._stats:Invalidate(player)
	self:_syncInventory(player)
	return true, nil
end

--[[
	Compares an item against whatever occupies its slot, returning per-stat deltas.
	This is the whole point of a loot game's inventory screen, so it is computed
	server-side from the same resolver the live stats use.
]]
function InventoryService:CompareToEquipped(player: Player, uid: string)
	local profile = self._data:GetProfile(player)
	if not profile then
		return nil
	end

	local candidate = self:FindItem(player, uid)
	if not candidate then
		return nil
	end
	local definition = Equipment.GetDefinition(candidate.b)
	if not definition then
		return nil
	end

	local StatsService = self.Registry:Get("StatsService")

	local currentValues = StatsService.ResolveForProfile(profile, nil, os.clock())

	-- Resolve against a shallow copy with the candidate equipped, so the comparison
	-- includes set bonuses gained or lost by the swap.
	local hypothetical = table.clone(profile)
	hypothetical.equipped = table.clone(profile.equipped)
	hypothetical.equipped[definition.slot] = uid
	local candidateValues = StatsService.ResolveForProfile(hypothetical, nil, os.clock())

	local deltas = {}
	for statId, value in pairs(candidateValues) do
		local before = currentValues[statId] or 0
		if math.abs(value - before) > 1e-6 then
			local text, direction = Stats.FormatDelta(statId, before, value)
			table.insert(deltas, {
				statId = statId,
				name = Stats.ById[statId].name,
				before = before,
				after = value,
				text = text,
				direction = direction,
			})
		end
	end
	table.sort(deltas, function(a, b)
		return a.statId < b.statId
	end)

	return {
		uid = uid,
		slot = definition.slot,
		replacing = profile.equipped[definition.slot],
		deltas = deltas,
	}
end

-- ============================================================================
-- Dismantling
-- ============================================================================

--[[ Materials returned by breaking an item down. Scales with rarity and tier. ]]
function InventoryService:GetDismantleValue(item: any): { [string]: number }
	local definition = Equipment.GetDefinition(item.b)
	if not definition then
		return {}
	end

	local rarityIndex = table.find(Balance.Loot.RARITY_ORDER, item.r) or 1
	local tier = definition.tier or 1

	-- Return materials from the item's own tier band, which keeps dismantling useful
	-- for crafting at the level you are actually playing.
	local candidates = Resources.ByTier[math.min(6, math.max(1, tier))] or Resources.ByTier[1]
	local yield = {}

	local total = math.floor((2 + rarityIndex * 2.2 + tier * 1.4) * Balance.Loot.DISMANTLE_RETURN_FRACTION * 4)
	local perMaterial = math.max(1, math.floor(total / math.max(1, math.min(3, #candidates))))

	for index = 1, math.min(3, #candidates) do
		yield[candidates[index]] = perMaterial
	end

	return yield
end

function InventoryService:Dismantle(player: Player, uids: { string }): (boolean, string?)
	local profile = self._data:GetProfile(player)
	if not profile then
		return false, "no_profile"
	end

	local totals = {}
	local dismantled = 0
	local skipped = 0

	for _, uid in ipairs(uids) do
		local item, index = self:FindItem(player, uid)
		if not item then
			continue
		end

		-- Favourites and equipped items are protected from bulk operations. Losing a
		-- good drop to a mis-click is the fastest way to lose a player.
		if item.f then
			skipped += 1
			continue
		end
		local definition = Equipment.GetDefinition(item.b)
		if definition and profile.equipped[definition.slot] == uid then
			skipped += 1
			continue
		end

		for resourceId, quantity in pairs(self:GetDismantleValue(item)) do
			totals[resourceId] = (totals[resourceId] or 0) + quantity
		end

		table.remove(profile.inventory, index)
		dismantled += 1
		self.ItemRemoved:Fire(player, item)
	end

	if dismantled == 0 then
		return false, "nothing_dismantled"
	end

	local yieldStat = self._stats:GetStat(player, "resourceYield")
	for resourceId, quantity in pairs(totals) do
		self._economy:AwardResource(player, resourceId, math.floor(quantity * yieldStat), "dismantle")
	end

	self._data:MarkDirty(player)
	self:_syncInventory(player)

	Net.FireClient(player, "Notification", {
		kind = "good",
		title = ("Dismantled %d"):format(dismantled),
		body = skipped > 0 and ("%d protected items were skipped."):format(skipped) or nil,
	})

	return true, nil
end

function InventoryService:SetFavourite(player: Player, uid: string, favourite: boolean): boolean
	local item = self:FindItem(player, uid)
	if not item then
		return false
	end
	item.f = favourite == true
	self._data:MarkDirty(player)
	self:_syncInventory(player)
	return true
end

function InventoryService:_syncInventory(player: Player)
	Net.FireClient(player, "InventoryUpdate", self:BuildInventoryView(player))
end

function InventoryService:GetUsedSlots(player: Player): (number, number)
	local profile = self._data:GetProfile(player)
	if not profile then
		return 0, Balance.Loot.MAX_INVENTORY_SLOTS
	end
	return #profile.inventory, Balance.Loot.MAX_INVENTORY_SLOTS
end

return InventoryService
