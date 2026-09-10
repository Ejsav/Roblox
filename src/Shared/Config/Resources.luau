--!strict
--[[
	Resources
	---------
	Crafting materials. Every material is tied to a region and an activity, so that
	"I need Fulgurite Spine" resolves into a concrete plan — go to the Scour, work
	Glass Storms — rather than a wiki lookup.

	Tiers 1-6 map loosely onto the region progression. `sources` documents where a
	material actually comes from and is used by the UI's "where do I find this?"
	panel, which reads directly from this table.
]]

local TableUtil = require(script.Parent.Parent.Core.TableUtil)

local Resources = {}

Resources.List = {
	-- ------------------------------------------------------------------ T1
	{
		id = "scrap_conductor",
		name = "Scrap Conductor",
		tier = 1,
		rarity = "common",
		color = "9FB4D4",
		icon = "scrap",
		description = "Salvaged copper braid. Bent, oxidised, and still the most useful thing in the yard.",
		stackSize = 9999,
		sources = { regions = { "starter_district", "storm_plains" }, activities = { "capture", "salvage" } },
		baseValue = 3,
	},
	{
		id = "cracked_insulator",
		name = "Cracked Insulator",
		tier = 1,
		rarity = "common",
		color = "B4BFE0",
		icon = "insulator",
		description = "Ceramic that failed once already. Ground down, it still resists.",
		stackSize = 9999,
		sources = { regions = { "starter_district", "storm_plains", "industrial_grid" }, activities = { "capture", "salvage" } },
		baseValue = 4,
	},
	{
		id = "copper_winding",
		name = "Copper Winding",
		tier = 1,
		rarity = "common",
		color = "FFA23D",
		icon = "winding",
		description = "Intact transformer winding. The backbone of every capture coil ever built.",
		stackSize = 9999,
		sources = { regions = { "storm_plains", "industrial_grid" }, activities = { "capture", "dismantle" } },
		baseValue = 7,
	},
	{
		id = "marsh_salt",
		name = "Marsh Salt",
		tier = 1,
		rarity = "common",
		color = "A8C6C2",
		icon = "salt",
		description = "Conductive crust from the Sattermarsh flats. Improves any electrolyte.",
		stackSize = 9999,
		sources = { regions = { "storm_plains" }, activities = { "gather" } },
		baseValue = 6,
	},

	-- ------------------------------------------------------------------ T2
	{
		id = "industrial_alloy",
		name = "Industrial Alloy",
		tier = 2,
		rarity = "uncommon",
		color = "D4B48C",
		icon = "alloy",
		description = "Structural plate from Sector Seven. Heavy, dull, and it does not deform.",
		stackSize = 5000,
		sources = { regions = { "industrial_grid", "city_region" }, activities = { "capture", "salvage", "event" } },
		baseValue = 16,
	},
	{
		id = "ferrite_core",
		name = "Ferrite Core",
		tier = 2,
		rarity = "uncommon",
		color = "5A6270",
		icon = "ferrite",
		description = "Magnetic core recovered intact. Shapes a field instead of just carrying it.",
		stackSize = 5000,
		sources = { regions = { "industrial_grid", "city_region", "mountain_region" }, activities = { "capture", "dismantle" } },
		baseValue = 22,
	},
	{
		id = "storm_glass",
		name = "Storm Glass",
		tier = 2,
		rarity = "uncommon",
		color = "8FD8FF",
		icon = "glass",
		description = "Sand fused by a direct strike. Holds a charge for hours after the storm has gone.",
		stackSize = 5000,
		sources = { regions = { "storm_plains", "industrial_grid", "mountain_region" }, activities = { "capture" } },
		baseValue = 34,
	},
	{
		id = "polymer_weave",
		name = "Polymer Weave",
		tier = 2,
		rarity = "uncommon",
		color = "8A7BFF",
		icon = "weave",
		description = "Flexible insulating fabric from Verrick's curtain walls. Light and difficult to tear.",
		stackSize = 5000,
		sources = { regions = { "city_region" }, activities = { "gather", "salvage" } },
		baseValue = 28,
	},

	-- ------------------------------------------------------------------ T3
	{
		id = "capacitor_cell",
		name = "Capacitor Cell",
		tier = 3,
		rarity = "rare",
		color = "FFD166",
		icon = "capacitor",
		description = "Still holding charge after thirty years. Nobody has worked out why.",
		stackSize = 2000,
		sources = { regions = { "industrial_grid", "city_region", "electrical_wasteland" }, activities = { "capture", "event" } },
		baseValue = 90,
	},
	{
		id = "resonant_shard",
		name = "Resonant Shard",
		tier = 3,
		rarity = "rare",
		color = "B9A6FF",
		icon = "shard",
		description = "Rings at a frequency that makes coils behave. Priceless to a Conductor.",
		stackSize = 2000,
		sources = { regions = { "city_region", "mountain_region", "electrical_wasteland" }, activities = { "capture" } },
		baseValue = 130,
	},
	{
		id = "glacier_quartz",
		name = "Glacier Quartz",
		tier = 3,
		rarity = "rare",
		color = "CBD8E6",
		icon = "quartz",
		description = "Clear ice-locked crystal from the Kalder caves. Stays cold under load.",
		stackSize = 2000,
		sources = { regions = { "mountain_region" }, activities = { "gather", "capture" } },
		baseValue = 115,
	},
	{
		id = "lab_alloy",
		name = "Laboratory Alloy",
		tier = 3,
		rarity = "rare",
		color = "9FE0C8",
		icon = "lab_alloy",
		description = "Machined to a tolerance nobody can reproduce any more.",
		stackSize = 2000,
		sources = { regions = { "underground_network" }, activities = { "salvage", "capture" } },
		baseValue = 150,
	},

	-- ------------------------------------------------------------------ T4
	{
		id = "fulgurite_spine",
		name = "Fulgurite Spine",
		tier = 4,
		rarity = "epic",
		color = "FF4FD8",
		icon = "fulgurite",
		description = "A standing spine of glass grown by ten thousand strikes on the same square metre.",
		stackSize = 1000,
		sources = { regions = { "electrical_wasteland" }, activities = { "capture", "gather" }, storms = { "glass_storm" } },
		baseValue = 320,
	},
	{
		id = "skyiron",
		name = "Skyiron",
		tier = 4,
		rarity = "epic",
		color = "C8D8FF",
		icon = "skyiron",
		description = "Alloy that only forms above the cloud layer. Lighter than it has any right to be.",
		stackSize = 1000,
		sources = { regions = { "mountain_region", "high_altitude" }, activities = { "capture", "salvage" } },
		baseValue = 380,
	},
	{
		id = "null_residue",
		name = "Null Residue",
		tier = 4,
		rarity = "epic",
		color = "1C1C26",
		icon = "null",
		description = "What is left where energy stopped existing. It weighs nothing and it is very cold.",
		stackSize = 1000,
		sources = {
			regions = { "electrical_wasteland", "underground_network", "high_altitude", "null_reach" },
			activities = { "capture" },
			storms = { "null_pocket" },
		},
		baseValue = 450,
	},
	{
		id = "ionised_dust",
		name = "Ionised Dust",
		tier = 4,
		rarity = "epic",
		color = "FF8AE8",
		icon = "dust",
		description = "Airborne charge that never settles. Collected, not mined.",
		stackSize = 1000,
		sources = { regions = { "electrical_wasteland", "underground_network", "high_altitude", "storm_core" }, activities = { "gather" } },
		baseValue = 400,
	},

	-- ------------------------------------------------------------------ T5
	{
		id = "prototype_core",
		name = "Prototype Core",
		tier = 5,
		rarity = "legendary",
		color = "37F0A8",
		icon = "prototype",
		description = "Deepline built eleven of these. Nine are unaccounted for.",
		stackSize = 500,
		sources = { regions = { "underground_network", "high_altitude" }, activities = { "capture", "event", "boss" } },
		baseValue = 1400,
	},
	{
		id = "storm_alloy",
		name = "Storm Alloy",
		tier = 5,
		rarity = "legendary",
		color = "FFE24F",
		icon = "storm_alloy",
		description = "Metal that formed inside a permanent storm. It hums when you hold it.",
		stackSize = 500,
		sources = { regions = { "storm_core", "high_altitude", "null_reach" }, activities = { "capture", "boss" } },
		baseValue = 1900,
	},
	{
		id = "core_filament",
		name = "Core Filament",
		tier = 5,
		rarity = "legendary",
		color = "FFF3A0",
		icon = "filament",
		description = "A single strand drawn from the Eye. It has not stopped moving since it was taken.",
		stackSize = 500,
		sources = { regions = { "storm_core", "null_reach" }, activities = { "capture", "boss" }, storms = { "core_pulse", "the_eye" } },
		baseValue = 2600,
	},

	-- ------------------------------------------------------------------ T6
	{
		id = "eye_fragment",
		name = "Eye Fragment",
		tier = 6,
		rarity = "mythic",
		color = "FFFFFF",
		icon = "eye",
		description = "It is looking at you. It has been looking at you since you picked it up.",
		stackSize = 200,
		sources = { regions = { "storm_core", "null_reach" }, activities = { "boss" }, storms = { "the_eye" } },
		baseValue = 9000,
	},
	{
		id = "sigil_dust",
		name = "Sigil Dust",
		tier = 6,
		rarity = "exotic",
		color = "FF2E63",
		icon = "sigil",
		description = "Only exists on the far side of a prestige. Nobody has explained that either.",
		stackSize = 200,
		sources = { regions = { "null_reach" }, activities = { "capture", "boss" }, storms = { "inversion" } },
		baseValue = 14000,
	},
}

Resources.ById = {}
Resources.ByTier = {}

for _, resource in ipairs(Resources.List) do
	Resources.ById[resource.id] = resource
	Resources.ByTier[resource.tier] = Resources.ByTier[resource.tier] or {}
	table.insert(Resources.ByTier[resource.tier], resource.id)
end

function Resources.Get(resourceId: string)
	return Resources.ById[resourceId]
end

--[[ Sell value of a stack, used by the trader and by dismantling. ]]
function Resources.GetValue(resourceId: string, quantity: number): number
	local resource = Resources.ById[resourceId]
	if not resource then
		return 0
	end
	return resource.baseValue * quantity
end

--[[
	Human-readable answer to "where do I get this?" — the exact string the UI shows
	when a player clicks a missing ingredient in a recipe.
]]
function Resources.DescribeSources(resourceId: string, RegionsConfig: any, StormTypesConfig: any): string
	local resource = Resources.ById[resourceId]
	if not resource then
		return "Unknown material."
	end

	local parts = {}
	local regionNames = {}
	for _, regionId in ipairs(resource.sources.regions or {}) do
		local region = RegionsConfig.ById[regionId]
		if region then
			table.insert(regionNames, region.name)
		end
	end
	if #regionNames > 0 then
		table.insert(parts, "Found in " .. table.concat(regionNames, ", "))
	end

	if resource.sources.storms then
		local stormNames = {}
		for _, stormId in ipairs(resource.sources.storms) do
			local storm = StormTypesConfig.ById[stormId]
			if storm then
				table.insert(stormNames, storm.name)
			end
		end
		if #stormNames > 0 then
			table.insert(parts, "dropped by " .. table.concat(stormNames, " and "))
		end
	end

	local activityLabels = {
		capture = "capturing storms",
		salvage = "salvaging wreckage",
		gather = "gathering in the field",
		dismantle = "dismantling equipment",
		event = "world events",
		boss = "major phenomena",
	}
	local activities = {}
	for _, activity in ipairs(resource.sources.activities or {}) do
		table.insert(activities, activityLabels[activity] or activity)
	end
	if #activities > 0 then
		table.insert(parts, "via " .. table.concat(activities, ", "))
	end

	return table.concat(parts, ", ") .. "."
end

--[[ Rolls a material drop for a region, honouring the region's own weight table. ]]
function Resources.RollForRegion(rng: any, regionResourceWeights: { [string]: number }): string?
	return rng:PickWeightedMap(regionResourceWeights)
end

return TableUtil.DeepFreeze(Resources)
