--!strict
--[[
	LootTables
	----------
	What a storm actually gives you beyond energy.

	A table is a weighted list of entries; each entry is one of:
		resource   a crafting material, with a quantity range
		equipment  a roll on the region/level-appropriate base pool
		unique     a specific named item, always at a very low weight
		currency   cores (the rare currency); watts never drop, they are banked
		nothing    an explicit blank so tables can express "usually nothing"

	The explicit `nothing` entry matters: it makes a table's real drop rate readable
	at a glance instead of hidden inside a global multiplier somewhere else.
]]

local TableUtil = require(script.Parent.Parent.Core.TableUtil)

local LootTables = {}

LootTables.List = {
	{
		id = "common_scrap",
		name = "Scrap",
		minLevel = 1,
		entries = {
			{ kind = "nothing", weight = 520 },
			{ kind = "resource", id = "scrap_conductor", weight = 260, min = 1, max = 4 },
			{ kind = "resource", id = "cracked_insulator", weight = 150, min = 1, max = 3 },
			{ kind = "resource", id = "copper_winding", weight = 55, min = 1, max = 2 },
			{ kind = "equipment", weight = 14, tierBias = 0 },
			{ kind = "currency", id = "cores", weight = 1, min = 1, max = 1 },
		},
	},

	{
		id = "uncommon_components",
		name = "Components",
		minLevel = 6,
		entries = {
			{ kind = "nothing", weight = 430 },
			{ kind = "resource", id = "copper_winding", weight = 190, min = 2, max = 6 },
			{ kind = "resource", id = "cracked_insulator", weight = 120, min = 2, max = 5 },
			{ kind = "resource", id = "marsh_salt", weight = 95, min = 1, max = 4 },
			{ kind = "resource", id = "storm_glass", weight = 60, min = 1, max = 2 },
			{ kind = "equipment", weight = 34, tierBias = 0 },
			{ kind = "currency", id = "cores", weight = 5, min = 1, max = 2 },
		},
	},

	{
		id = "industrial_salvage",
		name = "Industrial Salvage",
		minLevel = 12,
		entries = {
			{ kind = "nothing", weight = 380 },
			{ kind = "resource", id = "industrial_alloy", weight = 210, min = 2, max = 7 },
			{ kind = "resource", id = "ferrite_core", weight = 150, min = 1, max = 5 },
			{ kind = "resource", id = "copper_winding", weight = 120, min = 3, max = 8 },
			{ kind = "resource", id = "capacitor_cell", weight = 34, min = 1, max = 2 },
			{ kind = "equipment", weight = 48, tierBias = 1 },
			{ kind = "currency", id = "cores", weight = 12, min = 1, max = 3 },
		},
	},

	{
		id = "resonant_materials",
		name = "Resonant Materials",
		minLevel = 22,
		entries = {
			{ kind = "nothing", weight = 330 },
			{ kind = "resource", id = "resonant_shard", weight = 180, min = 1, max = 4 },
			{ kind = "resource", id = "storm_glass", weight = 150, min = 2, max = 6 },
			{ kind = "resource", id = "polymer_weave", weight = 120, min = 2, max = 6 },
			{ kind = "resource", id = "capacitor_cell", weight = 90, min = 1, max = 3 },
			{ kind = "equipment", weight = 62, tierBias = 1 },
			{ kind = "currency", id = "cores", weight = 22, min = 1, max = 4 },
		},
	},

	{
		id = "glacier_cache",
		name = "Glacier Cache",
		minLevel = 30,
		entries = {
			{ kind = "nothing", weight = 300 },
			{ kind = "resource", id = "glacier_quartz", weight = 220, min = 2, max = 7 },
			{ kind = "resource", id = "storm_glass", weight = 130, min = 3, max = 8 },
			{ kind = "resource", id = "ferrite_core", weight = 110, min = 2, max = 6 },
			{ kind = "resource", id = "skyiron", weight = 45, min = 1, max = 2 },
			{ kind = "equipment", weight = 70, tierBias = 2 },
			{ kind = "currency", id = "cores", weight = 28, min = 2, max = 5 },
		},
	},

	{
		id = "high_altitude_cache",
		name = "High-Altitude Cache",
		minLevel = 32,
		entries = {
			{ kind = "nothing", weight = 280 },
			{ kind = "resource", id = "skyiron", weight = 190, min = 1, max = 5 },
			{ kind = "resource", id = "resonant_shard", weight = 140, min = 2, max = 5 },
			{ kind = "resource", id = "capacitor_cell", weight = 130, min = 2, max = 6 },
			{ kind = "resource", id = "ionised_dust", weight = 70, min = 1, max = 3 },
			{ kind = "equipment", weight = 84, tierBias = 2 },
			{ kind = "currency", id = "cores", weight = 38, min = 2, max = 6 },
			{ kind = "unique", id = "unique_anchorage_wing", weight = 0.6 },
		},
	},

	{
		id = "wasteland_exotics",
		name = "Wasteland Exotics",
		minLevel = 44,
		entries = {
			{ kind = "nothing", weight = 240 },
			{ kind = "resource", id = "fulgurite_spine", weight = 200, min = 2, max = 6 },
			{ kind = "resource", id = "null_residue", weight = 130, min = 1, max = 4 },
			{ kind = "resource", id = "resonant_shard", weight = 120, min = 3, max = 8 },
			{ kind = "resource", id = "ionised_dust", weight = 100, min = 2, max = 5 },
			{ kind = "equipment", weight = 96, tierBias = 3 },
			{ kind = "currency", id = "cores", weight = 52, min = 3, max = 8 },
			{ kind = "unique", id = "unique_origin_shard", weight = 0.4 },
		},
	},

	{
		id = "null_cache",
		name = "Null Cache",
		minLevel = 46,
		entries = {
			{ kind = "nothing", weight = 200 },
			{ kind = "resource", id = "null_residue", weight = 240, min = 2, max = 7 },
			{ kind = "resource", id = "ionised_dust", weight = 150, min = 2, max = 6 },
			{ kind = "resource", id = "fulgurite_spine", weight = 110, min = 1, max = 4 },
			{ kind = "equipment", weight = 110, tierBias = 3 },
			{ kind = "currency", id = "cores", weight = 66, min = 4, max = 10 },
		},
	},

	{
		id = "lab_prototypes",
		name = "Laboratory Prototypes",
		minLevel = 50,
		entries = {
			{ kind = "nothing", weight = 190 },
			{ kind = "resource", id = "lab_alloy", weight = 220, min = 2, max = 8 },
			{ kind = "resource", id = "capacitor_cell", weight = 150, min = 3, max = 9 },
			{ kind = "resource", id = "prototype_core", weight = 42, min = 1, max = 2 },
			{ kind = "resource", id = "null_residue", weight = 90, min = 1, max = 4 },
			{ kind = "equipment", weight = 120, tierBias = 3 },
			{ kind = "currency", id = "cores", weight = 72, min = 4, max = 12 },
			{ kind = "unique", id = "unique_prototype_eleven", weight = 0.3 },
		},
	},

	{
		id = "legendary_storm_cache",
		name = "Legendary Cache",
		minLevel = 56,
		entries = {
			-- No `nothing` entry: a legendary storm always pays. Landing one is rare
			-- enough that an empty result would read as a bug rather than variance.
			{ kind = "resource", id = "prototype_core", weight = 180, min = 1, max = 4 },
			{ kind = "resource", id = "skyiron", weight = 160, min = 3, max = 9 },
			{ kind = "resource", id = "null_residue", weight = 140, min = 3, max = 8 },
			{ kind = "resource", id = "storm_alloy", weight = 60, min = 1, max = 3 },
			{ kind = "equipment", weight = 220, tierBias = 4, minRarity = "rare" },
			{ kind = "currency", id = "cores", weight = 140, min = 8, max = 24 },
			{ kind = "unique", id = "unique_watchers_eye", weight = 1.2 },
		},
	},

	{
		id = "core_cache",
		name = "Core Cache",
		minLevel = 80,
		entries = {
			{ kind = "resource", id = "storm_alloy", weight = 200, min = 2, max = 7 },
			{ kind = "resource", id = "core_filament", weight = 130, min = 1, max = 4 },
			{ kind = "resource", id = "prototype_core", weight = 150, min = 2, max = 6 },
			{ kind = "resource", id = "ionised_dust", weight = 120, min = 4, max = 12 },
			{ kind = "equipment", weight = 240, tierBias = 5, minRarity = "epic" },
			{ kind = "currency", id = "cores", weight = 180, min = 20, max = 60 },
			{ kind = "unique", id = "unique_eye_of_the_storm", weight = 0.8 },
		},
	},

	{
		id = "eye_cache",
		name = "The Eye's Cache",
		minLevel = 88,
		entries = {
			{ kind = "resource", id = "eye_fragment", weight = 160, min = 1, max = 3 },
			{ kind = "resource", id = "core_filament", weight = 190, min = 3, max = 8 },
			{ kind = "resource", id = "storm_alloy", weight = 170, min = 4, max = 10 },
			{ kind = "equipment", weight = 260, tierBias = 6, minRarity = "legendary" },
			{ kind = "currency", id = "cores", weight = 200, min = 60, max = 160 },
			{ kind = "unique", id = "unique_eye_of_the_storm", weight = 6 },
		},
	},

	{
		id = "prestige_cache",
		name = "Prestige Cache",
		minLevel = 100,
		requiresPrestige = 1,
		entries = {
			{ kind = "resource", id = "sigil_dust", weight = 170, min = 1, max = 4 },
			{ kind = "resource", id = "eye_fragment", weight = 150, min = 2, max = 5 },
			{ kind = "resource", id = "core_filament", weight = 160, min = 4, max = 10 },
			{ kind = "equipment", weight = 250, tierBias = 6, minRarity = "legendary" },
			{ kind = "currency", id = "cores", weight = 190, min = 80, max = 220 },
			{ kind = "unique", id = "unique_borrowed_time", weight = 4 },
		},
	},
}

LootTables.ById = {}
for _, table_ in ipairs(LootTables.List) do
	LootTables.ById[table_.id] = table_
end

function LootTables.Get(tableId: string)
	return LootTables.ById[tableId]
end

--[[
	Rolls a single entry from a table.
	`luck` shifts weight away from `nothing` and toward equipment and uniques, which is
	how the Fortune stat is felt: not more drops of the same thing, but better ones.
	Returns nil for a `nothing` result.
]]
function LootTables.Roll(rng: any, tableId: string, luck: number?)
	local lootTable = LootTables.ById[tableId]
	if not lootTable then
		return nil
	end

	local luckValue = math.max(0, luck or 0)
	local weighted = {}
	for _, entry in ipairs(lootTable.entries) do
		local weight = entry.weight
		if entry.kind == "nothing" then
			-- Luck erodes the blank result, but never removes it entirely.
			weight = weight / (1 + luckValue * 0.55)
		elseif entry.kind == "equipment" then
			weight = weight * (1 + luckValue * 0.4)
		elseif entry.kind == "unique" then
			weight = weight * (1 + luckValue * 1.1)
		elseif entry.kind == "currency" then
			weight = weight * (1 + luckValue * 0.25)
		end
		table.insert(weighted, { entry = entry, weight = weight })
	end

	local picked = rng:PickWeighted(weighted, "weight")
	if not picked or picked.entry.kind == "nothing" then
		return nil
	end

	local entry = picked.entry
	local result = { kind = entry.kind, id = entry.id }
	if entry.min and entry.max then
		result.quantity = rng:NextInteger(entry.min, entry.max)
	else
		result.quantity = 1
	end
	result.tierBias = entry.tierBias
	result.minRarity = entry.minRarity
	return result
end

--[[
	Rolls a table `count` times and merges resource quantities, so a boss drop reads
	as one summary rather than fourteen separate lines.
]]
function LootTables.RollMultiple(rng: any, tableId: string, count: number, luck: number?)
	local merged = {}
	local order = {}
	for _ = 1, count do
		local result = LootTables.Roll(rng, tableId, luck)
		if result then
			if result.kind == "resource" or result.kind == "currency" then
				local key = result.kind .. ":" .. tostring(result.id)
				if merged[key] then
					merged[key].quantity += result.quantity
				else
					merged[key] = result
					table.insert(order, key)
				end
			else
				-- Equipment and uniques are always distinct items.
				table.insert(order, result)
			end
		end
	end

	local out = {}
	for _, key in ipairs(order) do
		if type(key) == "string" then
			table.insert(out, merged[key])
		else
			table.insert(out, key)
		end
	end
	return out
end

--[[
	The chance a given roll produces anything at all, at a given luck value.
	Used by the UI's drop-rate readout and by balance tests.
]]
function LootTables.GetDropChance(tableId: string, luck: number?): number
	local lootTable = LootTables.ById[tableId]
	if not lootTable then
		return 0
	end
	local luckValue = math.max(0, luck or 0)
	local total, blank = 0, 0
	for _, entry in ipairs(lootTable.entries) do
		local weight = entry.weight
		if entry.kind == "nothing" then
			weight = weight / (1 + luckValue * 0.55)
			blank += weight
		elseif entry.kind == "equipment" then
			weight = weight * (1 + luckValue * 0.4)
		elseif entry.kind == "unique" then
			weight = weight * (1 + luckValue * 1.1)
		elseif entry.kind == "currency" then
			weight = weight * (1 + luckValue * 0.25)
		end
		total += weight
	end
	if total <= 0 then
		return 0
	end
	return 1 - (blank / total)
end

return TableUtil.DeepFreeze(LootTables)
