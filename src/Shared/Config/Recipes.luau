--!strict
--[[
	Recipes
	-------
	Crafting: the deterministic path to a specific item, as a counterweight to loot.

	Design rule this file exists to serve: crafting must never be strictly better
	than dropping, or the loot game dies; and it must never be strictly worse, or
	nobody uses it. So crafting gives you the *base* you want with a *guaranteed
	rarity floor* and a *worse affix roll* than an equivalent drop. You craft when
	you need a specific thing; you farm when you want a great thing.

	Ingredient costs are deliberately steep. A crafted tier-5 item should represent
	several sessions of directed play, not an afternoon of vendor trash.
]]

local TableUtil = require(script.Parent.Parent.Core.TableUtil)

local Recipes = {}

Recipes.Categories = {
	{ id = "equipment", name = "Equipment", description = "Build a specific base at a guaranteed rarity." },
	{ id = "refine", name = "Refining", description = "Convert materials upward, at a loss." },
	{ id = "reroll", name = "Reforging", description = "Reroll an item's modifiers." },
	{ id = "consumable", name = "Field Kit", description = "Single-use tools for a run." },
}

Recipes.List = {

	-- ===================================================== EQUIPMENT (tier 1-2)
	{
		id = "craft_field_tap",
		category = "equipment",
		name = "Field Tap",
		description = "A serviceable capture device. Everyone's first build.",
		requiredLevel = 3,
		output = { kind = "equipment", baseId = "dev_field_tap", rarityFloor = "uncommon" },
		ingredients = { scrap_conductor = 24, copper_winding = 8 },
		cost = { watts = 400 },
		craftSeconds = 2,
	},
	{
		id = "craft_standard_cell",
		category = "equipment",
		name = "Standard Cell",
		description = "Reliable containment with no surprises.",
		requiredLevel = 3,
		output = { kind = "equipment", baseId = "cell_standard", rarityFloor = "uncommon" },
		ingredients = { scrap_conductor = 20, cracked_insulator = 14 },
		cost = { watts = 400 },
		craftSeconds = 2,
	},
	{
		id = "craft_lineman_rig",
		category = "equipment",
		name = "Lineman's Rig",
		description = "Plating designed for people who worked live lines deliberately.",
		requiredLevel = 11,
		output = { kind = "equipment", baseId = "plate_lineman", rarityFloor = "rare" },
		ingredients = { cracked_insulator = 40, copper_winding = 24, marsh_salt = 12 },
		cost = { watts = 1800 },
		craftSeconds = 4,
	},
	{
		id = "craft_featherframe",
		category = "equipment",
		name = "Featherframe Cell",
		description = "Small, light, and the Runner's default containment.",
		requiredLevel = 12,
		output = { kind = "equipment", baseId = "cell_light", rarityFloor = "rare" },
		ingredients = { polymer_weave = 18, copper_winding = 30, storm_glass = 6 },
		cost = { watts = 2200 },
		craftSeconds = 4,
	},
	{
		id = "craft_bulk_reservoir",
		category = "equipment",
		name = "Bulk Reservoir",
		description = "Three times the volume, and it moves like it.",
		requiredLevel = 16,
		output = { kind = "equipment", baseId = "cell_bulk", rarityFloor = "rare" },
		ingredients = { industrial_alloy = 34, ferrite_core = 16, cracked_insulator = 30 },
		cost = { watts = 3200 },
		craftSeconds = 5,
	},

	-- ===================================================== EQUIPMENT (tier 3-4)
	{
		id = "craft_cascade_head",
		category = "equipment",
		name = "Cascade Head",
		description = "Holds a chain open far past where a Field Tap gives up.",
		requiredLevel = 26,
		output = { kind = "equipment", baseId = "dev_cascade_head", rarityFloor = "rare" },
		ingredients = { ferrite_core = 30, resonant_shard = 12, capacitor_cell = 8 },
		cost = { watts = 9000 },
		craftSeconds = 8,
	},
	{
		id = "craft_kinetic_frame",
		category = "equipment",
		name = "Kinetic Frame",
		description = "Stores a landing and gives it back on the next jump.",
		requiredLevel = 27,
		output = { kind = "equipment", baseId = "gear_kinetic_frame", rarityFloor = "rare" },
		ingredients = { polymer_weave = 34, ferrite_core = 24, storm_glass = 18 },
		cost = { watts = 9500 },
		craftSeconds = 8,
	},
	{
		id = "craft_resonator",
		category = "equipment",
		name = "Resonator",
		description = "Tuned to the storm rather than fighting it.",
		requiredLevel = 40,
		output = { kind = "equipment", baseId = "dev_resonator", rarityFloor = "epic" },
		ingredients = { resonant_shard = 40, glacier_quartz = 24, capacitor_cell = 30 },
		cost = { watts = 32000, cores = 20 },
		craftSeconds = 12,
	},
	{
		id = "craft_stormsuit",
		category = "equipment",
		name = "Stormsuit",
		description = "The first thing anyone builds after their first trip to the Scour.",
		requiredLevel = 42,
		output = { kind = "equipment", baseId = "plate_stormsuit", rarityFloor = "epic" },
		ingredients = { fulgurite_spine = 26, industrial_alloy = 60, storm_glass = 40 },
		cost = { watts = 36000, cores = 24 },
		craftSeconds = 12,
	},
	{
		id = "craft_layered_containment",
		category = "equipment",
		name = "Layered Containment",
		description = "Nested chambers. When one fails the next one holds — usually.",
		requiredLevel = 44,
		output = { kind = "equipment", baseId = "cell_layered", rarityFloor = "epic" },
		ingredients = { fulgurite_spine = 30, null_residue = 18, capacitor_cell = 40 },
		cost = { watts = 40000, cores = 28 },
		craftSeconds = 12,
	},

	-- ===================================================== EQUIPMENT (tier 5-6)
	{
		id = "craft_skyframe",
		category = "equipment",
		name = "Skyframe Cell",
		description = "Skyiron construction. Enormous capacity that still feels light.",
		requiredLevel = 62,
		output = { kind = "equipment", baseId = "cell_skyframe", rarityFloor = "epic" },
		ingredients = { skyiron = 44, prototype_core = 8, ionised_dust = 30 },
		cost = { watts = 140000, cores = 90 },
		craftSeconds = 18,
	},
	{
		id = "craft_deepshell",
		category = "equipment",
		name = "Deepshell",
		description = "Laboratory plate, reproduced from a recovered pattern.",
		requiredLevel = 60,
		output = { kind = "equipment", baseId = "plate_deepshell", rarityFloor = "epic" },
		ingredients = { lab_alloy = 50, prototype_core = 10, null_residue = 30 },
		cost = { watts = 135000, cores = 85 },
		craftSeconds = 18,
	},
	{
		id = "craft_core_conduit",
		category = "equipment",
		name = "Core Conduit",
		description = "Built from a filament that has not stopped moving since it was drawn.",
		requiredLevel = 78,
		output = { kind = "equipment", baseId = "dev_core_conduit", rarityFloor = "legendary" },
		ingredients = { core_filament = 20, storm_alloy = 34, prototype_core = 24 },
		cost = { watts = 420000, cores = 300 },
		craftSeconds = 25,
	},
	{
		id = "craft_corehide",
		category = "equipment",
		name = "Corehide",
		description = "Storm alloy, hammered flat. It hums against your ribs.",
		requiredLevel = 82,
		output = { kind = "equipment", baseId = "plate_corehide", rarityFloor = "legendary" },
		ingredients = { storm_alloy = 40, core_filament = 16, ionised_dust = 60 },
		cost = { watts = 460000, cores = 320 },
		craftSeconds = 25,
	},

	-- ================================================================ REFINING
	{
		id = "refine_t1_t2",
		category = "refine",
		name = "Refine to Tier 2",
		description = "Ten common materials become three of the tier above.",
		requiredLevel = 8,
		output = { kind = "resource", resourceId = "industrial_alloy", quantity = 3 },
		ingredients = { scrap_conductor = 10 },
		cost = { watts = 200 },
		craftSeconds = 1,
		unlockBehaviour = "material_transmute",
	},
	{
		id = "refine_t2_t3",
		category = "refine",
		name = "Refine to Tier 3",
		description = "Ten tier-two materials become three tier-three.",
		requiredLevel = 24,
		output = { kind = "resource", resourceId = "capacitor_cell", quantity = 3 },
		ingredients = { industrial_alloy = 10 },
		cost = { watts = 1200 },
		craftSeconds = 1,
		unlockBehaviour = "material_transmute",
	},
	{
		id = "refine_t3_t4",
		category = "refine",
		name = "Refine to Tier 4",
		description = "Ten tier-three materials become three tier-four.",
		requiredLevel = 44,
		output = { kind = "resource", resourceId = "skyiron", quantity = 3 },
		ingredients = { capacitor_cell = 10 },
		cost = { watts = 6000 },
		craftSeconds = 1,
		unlockBehaviour = "material_transmute",
	},
	{
		id = "refine_t4_t5",
		category = "refine",
		name = "Refine to Tier 5",
		description = "Ten tier-four materials become two tier-five.",
		requiredLevel = 62,
		output = { kind = "resource", resourceId = "prototype_core", quantity = 2 },
		ingredients = { skyiron = 10 },
		cost = { watts = 26000 },
		craftSeconds = 1,
		unlockBehaviour = "material_transmute",
	},

	-- =============================================================== REFORGING
	{
		id = "reforge_modifiers",
		category = "reroll",
		name = "Reforge",
		description = "Rerolls every modifier on an item. The base and rarity are untouched.",
		requiredLevel = 20,
		output = { kind = "reroll", mode = "affixes" },
		ingredients = { resonant_shard = 6, capacitor_cell = 4 },
		cost = { watts = 4000 },
		craftSeconds = 3,
		requiresItem = true,
	},
	{
		id = "reforge_ascend",
		category = "reroll",
		name = "Ascend",
		description = "Raises an item one rarity and rerolls it. Cannot exceed the base's ceiling.",
		requiredLevel = 46,
		output = { kind = "reroll", mode = "ascend" },
		ingredients = { fulgurite_spine = 12, null_residue = 8, resonant_shard = 20 },
		cost = { watts = 30000, cores = 40 },
		craftSeconds = 6,
		requiresItem = true,
	},

	-- =============================================================== FIELD KIT
	{
		id = "kit_stabiliser",
		category = "consumable",
		name = "Stabiliser Charge",
		description = "Instantly clears half your instability. One use.",
		requiredLevel = 6,
		output = { kind = "consumable", consumableId = "stabiliser_charge", quantity = 3 },
		ingredients = { cracked_insulator = 12, marsh_salt = 6 },
		cost = { watts = 300 },
		craftSeconds = 1,
	},
	{
		id = "kit_beacon",
		category = "consumable",
		name = "Recovery Beacon",
		description = "Marks your death cache permanently and doubles its lifetime. One use.",
		requiredLevel = 14,
		output = { kind = "consumable", consumableId = "recovery_beacon", quantity = 2 },
		ingredients = { copper_winding = 20, storm_glass = 6 },
		cost = { watts = 900 },
		craftSeconds = 1,
	},
	{
		id = "kit_surge",
		category = "consumable",
		name = "Surge Injector",
		description = "Thirty seconds of doubled capture yield. One use.",
		requiredLevel = 30,
		output = { kind = "consumable", consumableId = "surge_injector", quantity = 2 },
		ingredients = { resonant_shard = 10, capacitor_cell = 8 },
		cost = { watts = 5000 },
		craftSeconds = 2,
	},
	{
		id = "kit_insulation",
		category = "consumable",
		name = "Emergency Insulation",
		description = "Two minutes of greatly increased storm resistance. One use.",
		requiredLevel = 44,
		output = { kind = "consumable", consumableId = "emergency_insulation", quantity = 2 },
		ingredients = { fulgurite_spine = 8, polymer_weave = 24 },
		cost = { watts = 18000 },
		craftSeconds = 3,
	},
}

--[[ Consumables the recipes above produce, and what using one does. ]]
Recipes.Consumables = {
	stabiliser_charge = {
		id = "stabiliser_charge",
		name = "Stabiliser Charge",
		description = "Clears half your instability instantly.",
		effect = { instabilityRemoved = 0.5 },
		cooldown = 20,
	},
	recovery_beacon = {
		id = "recovery_beacon",
		name = "Recovery Beacon",
		description = "Your next death cache is marked and lasts twice as long.",
		effect = { cacheBeacon = true, cacheLifetimeMultiplier = 2 },
		cooldown = 0,
		persistsUntilDeath = true,
	},
	surge_injector = {
		id = "surge_injector",
		name = "Surge Injector",
		description = "Doubles capture yield for thirty seconds.",
		effect = { buff = { id = "surge_injector", effects = { increased = { captureYield = 1.0 } }, duration = 30 } },
		cooldown = 60,
	},
	emergency_insulation = {
		id = "emergency_insulation",
		name = "Emergency Insulation",
		description = "Greatly increased storm resistance for two minutes.",
		effect = { buff = { id = "emergency_insulation", effects = { flat = { stormResist = 0.3 } }, duration = 120 } },
		cooldown = 90,
	},
}

Recipes.ById = {}
Recipes.ByCategory = {}

for _, recipe in ipairs(Recipes.List) do
	Recipes.ById[recipe.id] = recipe
	Recipes.ByCategory[recipe.category] = Recipes.ByCategory[recipe.category] or {}
	table.insert(Recipes.ByCategory[recipe.category], recipe.id)
end

function Recipes.Get(recipeId: string)
	return Recipes.ById[recipeId]
end

--[[
	Whether a player can craft this right now.
	Returns (ok, reasonKey, detail) so the UI can say exactly what is missing.
]]
function Recipes.CanCraft(recipeId: string, profile: any, behaviours: { [string]: boolean }?): (boolean, string?, any)
	local recipe = Recipes.ById[recipeId]
	if not recipe then
		return false, "unknown_recipe", nil
	end

	if profile.level < recipe.requiredLevel then
		return false, "level", recipe.requiredLevel
	end

	if recipe.unlockBehaviour and not (behaviours and behaviours[recipe.unlockBehaviour]) then
		return false, "locked", recipe.unlockBehaviour
	end

	for currency, amount in pairs(recipe.cost or {}) do
		if (profile[currency] or 0) < amount then
			return false, "insufficient_" .. currency, amount
		end
	end

	local missing = {}
	for resourceId, quantity in pairs(recipe.ingredients) do
		local held = profile.resources[resourceId] or 0
		if held < quantity then
			missing[resourceId] = quantity - held
		end
	end
	if next(missing) then
		return false, "missing_ingredients", missing
	end

	return true, nil, nil
end

--[[ Total cost of crafting `quantity` of a recipe. ]]
function Recipes.GetScaledCost(recipeId: string, quantity: number)
	local recipe = Recipes.ById[recipeId]
	if not recipe then
		return nil
	end

	local ingredients = {}
	for resourceId, amount in pairs(recipe.ingredients) do
		ingredients[resourceId] = amount * quantity
	end

	local cost = {}
	for currency, amount in pairs(recipe.cost or {}) do
		cost[currency] = amount * quantity
	end

	return { ingredients = ingredients, cost = cost }
end

return TableUtil.DeepFreeze(Recipes)
