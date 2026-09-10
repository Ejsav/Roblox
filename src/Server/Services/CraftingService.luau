--!strict
--[[
	CraftingService
	---------------
	Turns materials into a specific item.

	The balance rule enforced here rather than in config: a crafted item rolls its
	affixes at a *lower* tier band than an equivalent drop. Crafting guarantees the
	base and the rarity floor; it does not guarantee a good item. That is what keeps
	both crafting and farming worth doing.

	Every craft is transactional. Ingredients and currency are checked together and
	spent together, and if item creation fails for any reason the spend is reversed,
	so a full inventory can never silently eat a tier-five recipe.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BTS")
local Signal = require(Shared.Core.Signal)
local RNG = require(Shared.Core.RNG)
local Net = require(Shared.Net)
local Recipes = require(Shared.Config.Recipes)
local Equipment = require(Shared.Config.Equipment)
local Modifiers = require(Shared.Config.Modifiers)
local Balance = require(Shared.Config.Balance)
local Resources = require(Shared.Config.Resources)

local CraftingService = {}
CraftingService.Name = "CraftingService"
CraftingService.Dependencies = { "DataService", "EconomyService", "InventoryService", "StatsService" }
CraftingService.Priority = 46

function CraftingService:Init()
	self._rng = RNG.new("crafting_" .. tostring(os.time()))
	self.Crafted = Signal.new("CraftingService.Crafted")
end

function CraftingService:Start()
	self._data = self.Registry:Get("DataService")
	self._economy = self.Registry:Get("EconomyService")
	self._inventory = self.Registry:Get("InventoryService")
	self._stats = self.Registry:Get("StatsService")
	self._quests = self.Registry:Find("QuestService")
	self._masteries = self.Registry:Find("MasteryService")
	self._analytics = self.Registry:Find("AnalyticsService")

	Net.OnServerEvent("RequestCraft", function(player, recipeId, quantity)
		self:Craft(player, recipeId, quantity)
	end)
end

-- ============================================================================
-- Crafting
-- ============================================================================

function CraftingService:Craft(player: Player, recipeId: string, quantity: number): (boolean, string?)
	local recipe = Recipes.ById[recipeId]
	if not recipe then
		return false, "unknown_recipe"
	end

	local profile = self._data:GetProfile(player)
	if not profile then
		return false, "no_profile"
	end

	-- Reroll recipes operate on an equipped or selected item and are handled
	-- separately; they cannot be batched.
	if recipe.requiresItem then
		return false, "use_reforge"
	end

	local count = math.clamp(math.floor(quantity or 1), 1, 50)

	-- Equipment is one at a time. Batch-crafting gear would produce a wall of
	-- reveals and defeat the point of the reveal.
	if recipe.output.kind == "equipment" then
		count = 1
	end

	local behaviours = self._stats:GetBehaviours(player)
	local ok, reason, detail = Recipes.CanCraft(recipeId, profile, behaviours)
	if not ok then
		Net.FireClient(player, "Notification", {
			kind = "warning",
			title = "Cannot craft",
			body = self:_explainBlock(reason, detail),
		})
		return false, reason
	end

	local scaled = Recipes.GetScaledCost(recipeId, count)

	-- Verify the full batch is affordable before spending anything.
	for resourceId, needed in pairs(scaled.ingredients) do
		if (profile.resources[resourceId] or 0) < needed then
			return false, "missing_ingredients"
		end
	end
	for currency, needed in pairs(scaled.cost) do
		if (profile[currency] or 0) < needed then
			return false, "insufficient_" .. currency
		end
	end

	-- Spend. Recorded so it can be reversed if the output cannot be delivered.
	local spentResources = {}
	local spentCurrency = {}

	for resourceId, needed in pairs(scaled.ingredients) do
		if self._economy:SpendResource(player, resourceId, needed, "craft:" .. recipeId) then
			spentResources[resourceId] = needed
		end
	end
	for currency, needed in pairs(scaled.cost) do
		if self._economy:Spend(player, currency, needed, "craft:" .. recipeId) then
			spentCurrency[currency] = needed
		end
	end

	local result, failure = self:_produce(player, profile, recipe, count)

	if not result then
		-- Refund everything. A failed craft must cost nothing.
		for resourceId, amount in pairs(spentResources) do
			self._economy:AwardResource(player, resourceId, amount, "craft_refund")
		end
		for currency, amount in pairs(spentCurrency) do
			self._economy:Award(player, currency, amount, "craft_refund")
		end
		Net.FireClient(player, "Notification", {
			kind = "warning",
			title = "Craft failed",
			body = failure or "Nothing was consumed.",
		})
		return false, failure
	end

	self.Crafted:Fire(player, recipeId, result)

	if self._masteries then
		self._masteries:AwardXp(player, "equipment", 40 * count)
	end
	if self._quests then
		self._quests:NotifyInteract(player, "craft:" .. recipe.category)
	end
	if self._analytics then
		self._analytics:Track(player, "craft", { recipeId = recipeId, quantity = count })
	end

	return true, nil
end

--[[ Produces a recipe's output. Returns (result, failureReason). ]]
function CraftingService:_produce(player: Player, profile: any, recipe: any, count: number)
	local output = recipe.output

	if output.kind == "equipment" then
		local definition = Equipment.BaseById[output.baseId]
		if not definition then
			return nil, "unknown base"
		end

		local item, failure = self:_craftEquipment(player, profile, definition, output.rarityFloor)
		if not item then
			return nil, failure
		end

		local view = self._inventory:BuildItemView(item)
		Net.FireClient(player, "ItemAcquired", view)
		self._inventory:_syncInventory(player)
		return { kind = "equipment", view = view }, nil

	elseif output.kind == "resource" then
		local granted = self._economy:AwardResource(
			player,
			output.resourceId,
			output.quantity * count,
			"craft:" .. recipe.id
		)
		local resource = Resources.ById[output.resourceId]
		Net.FireClient(player, "Notification", {
			kind = "good",
			title = ("+%d %s"):format(granted, resource and resource.name or output.resourceId),
		})
		return { kind = "resource", quantity = granted }, nil

	elseif output.kind == "consumable" then
		profile.consumables = profile.consumables or {}
		local total = output.quantity * count
		profile.consumables[output.consumableId] = (profile.consumables[output.consumableId] or 0) + total
		self._data:MarkDirty(player)

		local definition = Recipes.Consumables[output.consumableId]
		Net.FireClient(player, "Notification", {
			kind = "good",
			title = ("+%d %s"):format(total, definition and definition.name or output.consumableId),
			body = definition and definition.description or nil,
		})
		return { kind = "consumable", quantity = total }, nil
	end

	return nil, "unsupported output"
end

--[[
	Rolls a crafted item.

	Two deliberate differences from a dropped item:
	  * The rarity is exactly the recipe's floor, never higher. Crafting buys
	    certainty, not luck.
	  * Affix tiers are capped one band below the item's own tier, so a crafted
	    item is a solid floor rather than a replacement for hunting.
	Craft Precision partly closes that gap, which is what makes the stat worth having.
]]
function CraftingService:_craftEquipment(player: Player, profile: any, definition: any, rarityFloor: string)
	if #profile.inventory >= Balance.Loot.MAX_INVENTORY_SLOTS then
		return nil, "Inventory is full."
	end

	local order = Balance.Loot.RARITY_ORDER
	local floorIndex = table.find(order, rarityFloor) or 1
	local maxIndex = table.find(order, definition.maxRarity) or #order
	local rarity = order[math.min(floorIndex, maxIndex)]

	local countRange = Balance.Loot.MODIFIER_COUNTS[rarity]
	local affixCount = self._rng:NextInteger(countRange.min, countRange.max)

	-- Craft Precision raises the effective tier the affixes roll against.
	local precision = math.clamp(self._stats:GetStat(player, "craftQuality"), 0, 2)
	local effectiveTier = math.max(1, definition.tier - 1 + math.floor(precision))

	local affixes = Modifiers.RollAffixes(self._rng, definition.slot, effectiveTier, affixCount)

	local uid = self._inventory:_nextUid(profile)
	local ProfileSchema = require(Shared.Data.ProfileSchema)
	local item = ProfileSchema.CreateItem(uid, definition.id, rarity, affixes, nil, "crafted")
	item.a = os.time()

	table.insert(profile.inventory, item)
	self._data:MarkDirty(player)

	return item, nil
end

-- ============================================================================
-- Reforging
-- ============================================================================

--[[
	Rerolls an item's modifiers, or raises its rarity by one and rerolls.
	Reforging is the sink that makes a good base worth keeping through a rarity tier.
]]
function CraftingService:Reforge(player: Player, recipeId: string, itemUid: string): (boolean, string?)
	local recipe = Recipes.ById[recipeId]
	if not recipe or not recipe.requiresItem then
		return false, "unknown_recipe"
	end

	local profile = self._data:GetProfile(player)
	if not profile then
		return false, "no_profile"
	end

	local item = self._inventory:FindItem(player, itemUid)
	if not item then
		return false, "not_owned"
	end

	local definition = Equipment.GetDefinition(item.b)
	if not definition then
		return false, "unknown_base"
	end
	-- Named uniques carry fixed traits and rolls; reforging one would erase what
	-- makes it that item.
	if Equipment.UniqueById[item.b] then
		Net.FireClient(player, "Notification", {
			kind = "warning",
			title = "Cannot reforge",
			body = "Named equipment cannot be reforged.",
		})
		return false, "unique"
	end

	local behaviours = self._stats:GetBehaviours(player)
	local ok, reason, detail = Recipes.CanCraft(recipeId, profile, behaviours)
	if not ok then
		Net.FireClient(player, "Notification", {
			kind = "warning",
			title = "Cannot reforge",
			body = self:_explainBlock(reason, detail),
		})
		return false, reason
	end

	local scaled = Recipes.GetScaledCost(recipeId, 1)
	local spentOk = self._economy:SpendResources(player, scaled.ingredients, "reforge")
	if not spentOk then
		return false, "missing_ingredients"
	end
	for currency, amount in pairs(scaled.cost) do
		self._economy:Spend(player, currency, amount, "reforge")
	end

	local order = Balance.Loot.RARITY_ORDER
	local rarityIndex = table.find(order, item.r) or 1

	if recipe.output.mode == "ascend" then
		local maxIndex = table.find(order, definition.maxRarity) or #order
		if rarityIndex >= maxIndex then
			Net.FireClient(player, "Notification", {
				kind = "warning",
				title = "Already at the ceiling",
				body = ("%s cannot exceed %s."):format(definition.name, definition.maxRarity),
			})
			-- Refund, since nothing changed.
			for resourceId, amount in pairs(scaled.ingredients) do
				self._economy:AwardResource(player, resourceId, amount, "reforge_refund")
			end
			for currency, amount in pairs(scaled.cost) do
				self._economy:Award(player, currency, amount, "reforge_refund")
			end
			return false, "at_ceiling"
		end
		rarityIndex += 1
		item.r = order[rarityIndex]
	end

	local countRange = Balance.Loot.MODIFIER_COUNTS[item.r]
	local affixCount = self._rng:NextInteger(countRange.min, countRange.max)
	local precision = math.clamp(self._stats:GetStat(player, "craftQuality"), 0, 2)
	local effectiveTier = math.max(1, definition.tier - 1 + math.floor(precision))

	item.m = Modifiers.RollAffixes(self._rng, definition.slot, effectiveTier, affixCount)

	self._data:MarkDirty(player)
	self._stats:Invalidate(player)

	local view = self._inventory:BuildItemView(item)
	Net.FireClient(player, "ItemAcquired", view)
	self._inventory:_syncInventory(player)

	return true, nil
end

-- ============================================================================
-- Consumables
-- ============================================================================

function CraftingService:UseConsumable(player: Player, consumableId: string): (boolean, string?)
	local definition = Recipes.Consumables[consumableId]
	if not definition then
		return false, "unknown_consumable"
	end

	local profile = self._data:GetProfile(player)
	if not profile or (profile.consumables and profile.consumables[consumableId] or 0) <= 0 then
		return false, "none_held"
	end

	self._cooldowns = self._cooldowns or {}
	local key = player.UserId .. ":" .. consumableId
	if definition.cooldown > 0 and os.clock() < (self._cooldowns[key] or 0) then
		return false, "on_cooldown"
	end
	self._cooldowns[key] = os.clock() + definition.cooldown

	profile.consumables[consumableId] -= 1
	if profile.consumables[consumableId] <= 0 then
		profile.consumables[consumableId] = nil
	end
	self._data:MarkDirty(player)

	local effect = definition.effect

	if effect.instabilityRemoved then
		local carry = self.Registry:Find("CarryService")
		if carry then
			local state = carry:_getState(player)
			state.instability = math.max(0, state.instability - effect.instabilityRemoved)
			state.dirty = true
			carry:ForceSync(player)
		end
	end

	if effect.buff then
		self._stats:ApplyBuff(player, {
			id = effect.buff.id,
			label = definition.name,
			effects = effect.buff.effects,
			durationSeconds = effect.buff.duration,
			source = "consumable",
		})
	end

	if effect.cacheBeacon then
		profile.pendingCacheBeacon = true
		self._data:MarkDirty(player)
	end

	Net.FireClient(player, "Notification", {
		kind = "good",
		title = definition.name,
		body = definition.description,
		transient = true,
	})

	return true, nil
end

-- ============================================================================
-- Views
-- ============================================================================

function CraftingService:_explainBlock(reason: string?, detail: any): string
	if reason == "level" then
		return ("Requires level %d."):format(tonumber(detail) or 0)
	elseif reason == "locked" then
		return "Requires an upgrade you have not bought yet."
	elseif reason == "missing_ingredients" then
		local parts = {}
		for resourceId, amount in pairs(detail) do
			local resource = Resources.ById[resourceId]
			table.insert(parts, ("%d %s"):format(amount, resource and resource.name or resourceId))
		end
		table.sort(parts)
		return "Need " .. table.concat(parts, ", ") .. "."
	elseif reason and reason:match("^insufficient_") then
		local currency = reason:gsub("^insufficient_", "")
		return ("Need %d %s."):format(tonumber(detail) or 0, currency)
	end
	return "Not available."
end

--[[ The crafting panel view: every recipe with its availability and shortfall. ]]
function CraftingService:BuildView(player: Player)
	local profile = self._data:GetProfile(player)
	if not profile then
		return nil
	end

	local behaviours = self._stats:GetBehaviours(player)
	local recipes = {}

	for _, recipe in ipairs(Recipes.List) do
		local ok, reason, detail = Recipes.CanCraft(recipe.id, profile, behaviours)
		local missing = self._economy:GetMissingResources(player, recipe.ingredients)

		table.insert(recipes, {
			id = recipe.id,
			category = recipe.category,
			name = recipe.name,
			description = recipe.description,
			requiredLevel = recipe.requiredLevel,
			ingredients = recipe.ingredients,
			cost = recipe.cost,
			output = recipe.output,
			craftSeconds = recipe.craftSeconds,
			requiresItem = recipe.requiresItem,
			canCraft = ok,
			blockText = ok and nil or self:_explainBlock(reason, detail),
			missing = missing,
		})
	end

	return {
		categories = Recipes.Categories,
		recipes = recipes,
		resources = profile.resources,
		consumables = profile.consumables or {},
	}
end

return CraftingService
