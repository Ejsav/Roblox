--!strict
--[[
	Modifiers
	---------
	The affix pool that turns a base item into a specific item, plus the unique traits
	carried by named legendaries and exotics.

	Affix model:
	  * Each affix has six value tiers. The tier a drop can roll is capped by the
	    item's own tier, so a level-3 drop cannot roll an endgame-magnitude affix.
	  * Within a tier, the roll is a uniform range. Two items with the same affix at
	    the same tier are still meaningfully different, which is what makes "one more
	    drop" work.
	  * `slots` restricts where an affix can appear, so a Scanner never rolls
	    containment capacity and a build's slots stay legible.

	Traits are not rolled. They are attached to a specific unique and implement real
	behaviour rather than a stat line, which is what makes a named item a named item.
]]

local TableUtil = require(script.Parent.Parent.Core.TableUtil)

local Modifiers = {}

Modifiers.PREFIX = "prefix"
Modifiers.SUFFIX = "suffix"

--[[
	Tier value ranges are expressed as { min, max } pairs, indexed 1..6.
	`kind` is the stat aggregation channel: flat, increased or more.
]]
Modifiers.Affixes = {

	-- ------------------------------------------------------------ CAPTURE
	{
		id = "affix_tuned",
		name = "Tuned",
		position = "prefix",
		stat = "captureWindow",
		kind = "increased",
		slots = { "capture_device", "utility" },
		weight = 100,
		tiers = {
			{ 0.02, 0.04 },
			{ 0.04, 0.07 },
			{ 0.07, 0.10 },
			{ 0.10, 0.14 },
			{ 0.14, 0.19 },
			{ 0.19, 0.26 },
		},
	},
	{
		id = "affix_greedy",
		name = "Greedy",
		position = "prefix",
		stat = "captureYield",
		kind = "increased",
		slots = { "capture_device", "containment", "utility" },
		weight = 95,
		tiers = {
			{ 0.03, 0.05 },
			{ 0.05, 0.08 },
			{ 0.08, 0.12 },
			{ 0.12, 0.17 },
			{ 0.17, 0.23 },
			{ 0.23, 0.32 },
		},
	},
	{
		id = "affix_reaching",
		name = "Reaching",
		position = "prefix",
		stat = "captureRadius",
		kind = "flat",
		slots = { "capture_device", "scanner" },
		weight = 90,
		tiers = {
			{ 1, 3 },
			{ 3, 5 },
			{ 5, 8 },
			{ 8, 12 },
			{ 12, 17 },
			{ 17, 24 },
		},
	},
	{
		id = "affix_steady",
		name = "Steady",
		position = "suffix",
		suffixText = "of Steadiness",
		stat = "captureStability",
		kind = "flat",
		slots = { "capture_device", "plating", "utility" },
		weight = 55,
		tiers = {
			{ 0.02, 0.04 },
			{ 0.04, 0.06 },
			{ 0.06, 0.09 },
			{ 0.09, 0.13 },
			{ 0.13, 0.18 },
			{ 0.18, 0.24 },
		},
	},
	{
		id = "affix_sustained",
		name = "Sustained",
		position = "suffix",
		suffixText = "of the Chain",
		stat = "chainRetention",
		kind = "flat",
		slots = { "capture_device", "utility" },
		weight = 60,
		tiers = {
			{ 0.05, 0.12 },
			{ 0.12, 0.20 },
			{ 0.20, 0.32 },
			{ 0.32, 0.48 },
			{ 0.48, 0.70 },
			{ 0.70, 1.00 },
		},
	},

	-- -------------------------------------------------------- CONTAINMENT
	{
		id = "affix_capacious",
		name = "Capacious",
		position = "prefix",
		stat = "capacity",
		kind = "flat",
		slots = { "containment", "plating" },
		weight = 100,
		tiers = {
			{ 8, 18 },
			{ 18, 36 },
			{ 36, 70 },
			{ 70, 130 },
			{ 130, 240 },
			{ 240, 420 },
		},
	},
	{
		id = "affix_vast",
		name = "Vast",
		position = "prefix",
		stat = "capacity",
		kind = "increased",
		slots = { "containment" },
		weight = 42,
		tiers = {
			{ 0.03, 0.06 },
			{ 0.06, 0.10 },
			{ 0.10, 0.15 },
			{ 0.15, 0.22 },
			{ 0.22, 0.30 },
			{ 0.30, 0.42 },
		},
	},
	{
		id = "affix_damped",
		name = "Damped",
		position = "prefix",
		stat = "instabilityResist",
		kind = "flat",
		slots = { "containment", "plating", "utility" },
		weight = 80,
		tiers = {
			{ 0.02, 0.04 },
			{ 0.04, 0.07 },
			{ 0.07, 0.11 },
			{ 0.11, 0.16 },
			{ 0.16, 0.22 },
			{ 0.22, 0.30 },
		},
	},
	{
		id = "affix_sealed",
		name = "Sealed",
		position = "suffix",
		suffixText = "of Sealing",
		stat = "ventProtection",
		kind = "flat",
		slots = { "containment", "plating" },
		weight = 50,
		tiers = {
			{ 0.04, 0.08 },
			{ 0.08, 0.14 },
			{ 0.14, 0.21 },
			{ 0.21, 0.30 },
			{ 0.30, 0.42 },
			{ 0.42, 0.56 },
		},
	},
	{
		id = "affix_insured",
		name = "Insured",
		position = "suffix",
		suffixText = "of Recovery",
		stat = "lossProtection",
		kind = "flat",
		slots = { "containment", "utility" },
		weight = 45,
		tiers = {
			{ 0.03, 0.06 },
			{ 0.06, 0.10 },
			{ 0.10, 0.15 },
			{ 0.15, 0.22 },
			{ 0.22, 0.31 },
			{ 0.31, 0.42 },
		},
	},

	-- ----------------------------------------------------------- MOVEMENT
	{
		id = "affix_swift",
		name = "Swift",
		position = "prefix",
		stat = "moveSpeed",
		kind = "flat",
		slots = { "traversal", "containment", "plating" },
		weight = 92,
		tiers = {
			{ 0.3, 0.8 },
			{ 0.8, 1.5 },
			{ 1.5, 2.6 },
			{ 2.6, 4.0 },
			{ 4.0, 6.0 },
			{ 6.0, 8.5 },
		},
	},
	{
		id = "affix_headlong",
		name = "Headlong",
		position = "prefix",
		stat = "sprintSpeed",
		kind = "flat",
		slots = { "traversal" },
		weight = 78,
		tiers = {
			{ 0.6, 1.5 },
			{ 1.5, 3.0 },
			{ 3.0, 5.0 },
			{ 5.0, 7.5 },
			{ 7.5, 11 },
			{ 11, 16 },
		},
	},
	{
		id = "affix_springloaded",
		name = "Spring-Loaded",
		position = "prefix",
		stat = "jumpPower",
		kind = "flat",
		slots = { "traversal" },
		weight = 62,
		tiers = {
			{ 1, 3 },
			{ 3, 6 },
			{ 6, 10 },
			{ 10, 16 },
			{ 16, 24 },
			{ 24, 34 },
		},
	},
	{
		id = "affix_balanced",
		name = "Balanced",
		position = "suffix",
		suffixText = "of Handling",
		stat = "carryPenaltyResist",
		kind = "flat",
		slots = { "traversal", "containment" },
		weight = 55,
		tiers = {
			{ 0.03, 0.07 },
			{ 0.07, 0.12 },
			{ 0.12, 0.19 },
			{ 0.19, 0.28 },
			{ 0.28, 0.40 },
			{ 0.40, 0.55 },
		},
	},
	{
		id = "affix_recycling",
		name = "Recycling",
		position = "suffix",
		suffixText = "of Recycling",
		stat = "abilityCooldown",
		kind = "flat",
		slots = { "traversal", "utility" },
		weight = 48,
		tiers = {
			{ 0.02, 0.04 },
			{ 0.04, 0.07 },
			{ 0.07, 0.10 },
			{ 0.10, 0.14 },
			{ 0.14, 0.19 },
			{ 0.19, 0.25 },
		},
	},

	-- ----------------------------------------------------------- SURVIVAL
	{
		id = "affix_reinforced",
		name = "Reinforced",
		position = "prefix",
		stat = "maxHealth",
		kind = "flat",
		slots = { "plating", "containment", "traversal" },
		weight = 100,
		tiers = {
			{ 6, 14 },
			{ 14, 28 },
			{ 28, 52 },
			{ 52, 95 },
			{ 95, 170 },
			{ 170, 300 },
		},
	},
	{
		id = "affix_insulated",
		name = "Insulated",
		position = "prefix",
		stat = "stormResist",
		kind = "flat",
		slots = { "plating", "containment" },
		weight = 70,
		tiers = {
			{ 0.015, 0.03 },
			{ 0.03, 0.05 },
			{ 0.05, 0.08 },
			{ 0.08, 0.12 },
			{ 0.12, 0.17 },
			{ 0.17, 0.23 },
		},
	},
	{
		id = "affix_absorbing",
		name = "Absorbing",
		position = "suffix",
		suffixText = "of Absorption",
		stat = "shockResist",
		kind = "flat",
		slots = { "plating", "traversal" },
		weight = 66,
		tiers = {
			{ 0.02, 0.05 },
			{ 0.05, 0.08 },
			{ 0.08, 0.12 },
			{ 0.12, 0.18 },
			{ 0.18, 0.25 },
			{ 0.25, 0.34 },
		},
	},
	{
		id = "affix_regenerating",
		name = "Regenerating",
		position = "suffix",
		suffixText = "of Regeneration",
		stat = "healthRegen",
		kind = "flat",
		slots = { "plating", "utility" },
		weight = 58,
		tiers = {
			{ 0.5, 1.5 },
			{ 1.5, 3 },
			{ 3, 5.5 },
			{ 5.5, 9 },
			{ 9, 15 },
			{ 15, 24 },
		},
	},
	{
		id = "affix_cushioned",
		name = "Cushioned",
		position = "suffix",
		suffixText = "of Soft Landing",
		stat = "fallProtection",
		kind = "flat",
		slots = { "traversal", "plating" },
		weight = 44,
		tiers = {
			{ 0.05, 0.12 },
			{ 0.12, 0.22 },
			{ 0.22, 0.34 },
			{ 0.34, 0.50 },
			{ 0.50, 0.70 },
			{ 0.70, 0.90 },
		},
	},

	-- ------------------------------------------------------------ ECONOMY
	{
		id = "affix_lucrative",
		name = "Lucrative",
		position = "prefix",
		stat = "bankRate",
		kind = "increased",
		slots = { "utility", "containment" },
		weight = 72,
		tiers = {
			{ 0.03, 0.06 },
			{ 0.06, 0.10 },
			{ 0.10, 0.15 },
			{ 0.15, 0.22 },
			{ 0.22, 0.30 },
			{ 0.30, 0.42 },
		},
	},
	{
		id = "affix_reckless",
		name = "Reckless",
		position = "prefix",
		stat = "riskBonus",
		kind = "increased",
		slots = { "utility", "capture_device" },
		weight = 40,
		tiers = {
			{ 0.04, 0.08 },
			{ 0.08, 0.14 },
			{ 0.14, 0.22 },
			{ 0.22, 0.32 },
			{ 0.32, 0.45 },
			{ 0.45, 0.62 },
		},
	},
	{
		id = "affix_studious",
		name = "Studious",
		position = "suffix",
		suffixText = "of Learning",
		stat = "xpGain",
		kind = "increased",
		slots = { "utility", "scanner" },
		weight = 50,
		tiers = {
			{ 0.03, 0.06 },
			{ 0.06, 0.10 },
			{ 0.10, 0.15 },
			{ 0.15, 0.21 },
			{ 0.21, 0.29 },
			{ 0.29, 0.40 },
		},
	},
	{
		id = "affix_fortunate",
		name = "Fortunate",
		position = "suffix",
		suffixText = "of Fortune",
		stat = "luck",
		kind = "flat",
		slots = { "scanner", "utility" },
		weight = 52,
		tiers = {
			{ 0.05, 0.12 },
			{ 0.12, 0.24 },
			{ 0.24, 0.42 },
			{ 0.42, 0.68 },
			{ 0.68, 1.00 },
			{ 1.00, 1.45 },
		},
	},
	{
		id = "affix_thorough",
		name = "Thorough",
		position = "suffix",
		suffixText = "of Salvage",
		stat = "resourceYield",
		kind = "increased",
		slots = { "scanner", "utility" },
		weight = 56,
		tiers = {
			{ 0.04, 0.08 },
			{ 0.08, 0.14 },
			{ 0.14, 0.22 },
			{ 0.22, 0.32 },
			{ 0.32, 0.45 },
			{ 0.45, 0.62 },
		},
	},

	-- ------------------------------------------------------------ UTILITY
	{
		id = "affix_farseeing",
		name = "Far-Seeing",
		position = "prefix",
		stat = "scanRange",
		kind = "flat",
		slots = { "scanner", "utility" },
		weight = 88,
		tiers = {
			{ 20, 60 },
			{ 60, 130 },
			{ 130, 240 },
			{ 240, 420 },
			{ 420, 700 },
			{ 700, 1100 },
		},
	},
	{
		id = "affix_perceptive",
		name = "Perceptive",
		position = "suffix",
		suffixText = "of Anomalies",
		stat = "rareDetection",
		kind = "flat",
		slots = { "scanner" },
		weight = 38,
		tiers = {
			{ 0.03, 0.06 },
			{ 0.06, 0.10 },
			{ 0.10, 0.16 },
			{ 0.16, 0.24 },
			{ 0.24, 0.34 },
			{ 0.34, 0.46 },
		},
	},
	{
		id = "affix_radiant",
		name = "Radiant",
		position = "prefix",
		stat = "teamAura",
		kind = "flat",
		slots = { "utility", "scanner" },
		weight = 34,
		tiers = {
			{ 0.05, 0.12 },
			{ 0.12, 0.22 },
			{ 0.22, 0.36 },
			{ 0.36, 0.55 },
			{ 0.55, 0.80 },
			{ 0.80, 1.15 },
		},
	},
	{
		id = "affix_practiced",
		name = "Practised",
		position = "suffix",
		suffixText = "of Field Medicine",
		stat = "reviveSpeed",
		kind = "flat",
		slots = { "utility", "plating" },
		weight = 32,
		tiers = {
			{ 0.08, 0.18 },
			{ 0.18, 0.32 },
			{ 0.32, 0.52 },
			{ 0.52, 0.80 },
			{ 0.80, 1.20 },
			{ 1.20, 1.70 },
		},
	},
	{
		id = "affix_precise",
		name = "Precise",
		position = "suffix",
		suffixText = "of Precision",
		stat = "craftQuality",
		kind = "flat",
		slots = { "utility" },
		weight = 26,
		tiers = {
			{ 0.05, 0.12 },
			{ 0.12, 0.22 },
			{ 0.22, 0.36 },
			{ 0.36, 0.55 },
			{ 0.55, 0.80 },
			{ 0.80, 1.10 },
		},
	},
}

-- ============================================================================
-- Traits: fixed behaviours on named items. These are implemented by the
-- gameplay services, which look up `behaviour` and apply the params.
-- ============================================================================

Modifiers.Traits = {
	{
		id = "trait_first_light",
		name = "First Light",
		description = "The first capture of every storm cell is always graded Perfect.",
		behaviour = "first_capture_perfect",
		params = { perCell = true },
	},
	{
		id = "trait_marsh_sight",
		name = "Marsh Sight",
		description = "Storms are visible through terrain, and their telegraph timing is shown numerically.",
		behaviour = "storm_xray",
		params = { showsTiming = true, throughTerrain = true },
	},
	{
		id = "trait_live_current",
		name = "Live Current",
		description = "Electrified rails and cables cause no damage and grant a large speed bonus on exit.",
		behaviour = "rail_immunity",
		params = { exitBoost = 0.55, negatesRailDamage = true },
	},
	{
		id = "trait_lightning_rod",
		name = "Lightning Rod",
		description = "Strikes within range always target you, and being struck restores integrity instead of costing it.",
		behaviour = "attract_and_absorb",
		params = { attractRadius = 70, healFraction = 0.4 },
	},
	{
		id = "trait_precognition",
		name = "Precognition",
		description = "The next strike point of every visible cell is marked two seconds before it telegraphs.",
		behaviour = "predict_strikes",
		params = { leadTime = 2.0, maxCells = 6 },
	},
	{
		id = "trait_origin_stability",
		name = "Origin Stability",
		description = "Instability never rises above the critical threshold. It simply stops.",
		behaviour = "instability_ceiling",
		params = { ceiling = 0.84 },
	},
	{
		id = "trait_lab_override",
		name = "Laboratory Override",
		description = "Containment Breach storms cannot escape you, and Deepline security ignores you entirely.",
		behaviour = "facility_clearance",
		params = { locksBreaches = true, ignoredByDefences = true },
	},
	{
		id = "trait_never_falls",
		name = "Never Falls",
		description = "You take no fall damage from any height, and landing hard launches you forward.",
		behaviour = "fall_immunity",
		params = { launchOnLanding = 0.6 },
	},
	{
		id = "trait_the_calm",
		name = "The Calm",
		description = "While carrying above 90% capacity, all storm damage against you is halved.",
		behaviour = "calm_at_capacity",
		params = { threshold = 0.9, damageReduction = 0.5 },
	},
	{
		id = "trait_borrowed",
		name = "Borrowed Time",
		description = "Your chain never times out. It ends only when you bank, or when you die.",
		behaviour = "infinite_chain_timer",
		params = {},
	},
}

-- ============================================================================
-- Lookups and rolling
-- ============================================================================

Modifiers.AffixById = {}
Modifiers.AffixesBySlot = {}
Modifiers.TraitById = {}

for _, affix in ipairs(Modifiers.Affixes) do
	Modifiers.AffixById[affix.id] = affix
	for _, slot in ipairs(affix.slots) do
		Modifiers.AffixesBySlot[slot] = Modifiers.AffixesBySlot[slot] or {}
		table.insert(Modifiers.AffixesBySlot[slot], affix.id)
	end
end

for _, trait in ipairs(Modifiers.Traits) do
	Modifiers.TraitById[trait.id] = trait
end

Modifiers.MAX_TIER = 6

--[[
	The highest affix tier an item of the given item tier may roll.
	Item tiers run 1..7; affix tiers run 1..6, so tier 7 items simply cap out.
]]
function Modifiers.GetMaxAffixTier(itemTier: number): number
	return math.clamp(itemTier, 1, Modifiers.MAX_TIER)
end

--[[
	Rolls a single affix for a slot.
	`exclude` is a set of affix ids already present, so an item never rolls the same
	affix twice. Returns nil when the pool is exhausted.
]]
function Modifiers.RollAffix(rng: any, slot: string, itemTier: number, exclude: { [string]: boolean }?)
	local pool = Modifiers.AffixesBySlot[slot]
	if not pool then
		return nil
	end

	local candidates = {}
	for _, affixId in ipairs(pool) do
		if not (exclude and exclude[affixId]) then
			table.insert(candidates, Modifiers.AffixById[affixId])
		end
	end
	if #candidates == 0 then
		return nil
	end

	local affix = rng:PickWeighted(candidates, "weight")
	if not affix then
		return nil
	end

	-- Tier is weighted toward the item's cap but can roll lower, which is what makes
	-- a high-tier item with a badly-rolled affix a real (and disappointing) outcome.
	local maxTier = Modifiers.GetMaxAffixTier(itemTier)
	local tierRoll = rng:NextNumber()
	local tier = math.max(1, math.ceil(maxTier * (0.45 + 0.55 * tierRoll)))
	tier = math.min(tier, maxTier)

	local range = affix.tiers[tier]
	local value = rng:NextRange(range[1], range[2])

	return {
		affixId = affix.id,
		tier = tier,
		value = value,
	}
end

--[[ Rolls `count` distinct affixes for a slot. ]]
function Modifiers.RollAffixes(rng: any, slot: string, itemTier: number, count: number)
	local rolled = {}
	local used = {}
	for _ = 1, count do
		local affix = Modifiers.RollAffix(rng, slot, itemTier, used)
		if not affix then
			break
		end
		used[affix.affixId] = true
		table.insert(rolled, affix)
	end
	return rolled
end

--[[ Display text for a rolled affix, e.g. "+14% increased Capture Yield". ]]
function Modifiers.DescribeAffix(rolled: any, Stats: any): string
	local affix = Modifiers.AffixById[rolled.affixId]
	if not affix then
		return "Unknown modifier"
	end
	local stat = Stats.ById[affix.stat]
	local statName = stat and stat.name or affix.stat

	if affix.kind == "flat" then
		if stat and stat.format == "percent" then
			return ("+%d%% %s"):format(math.floor(rolled.value * 100 + 0.5), statName)
		end
		return ("+%s %s"):format(
			rolled.value >= 10 and tostring(math.floor(rolled.value + 0.5)) or ("%.1f"):format(rolled.value),
			statName
		)
	elseif affix.kind == "increased" then
		return ("%d%% increased %s"):format(math.floor(rolled.value * 100 + 0.5), statName)
	end
	return ("%d%% more %s"):format(math.floor(rolled.value * 100 + 0.5), statName)
end

--[[
	Builds a generated item name from its base and affixes, in the classic
	prefix-base-suffix shape: "Tuned Resonator of Fortune".
]]
function Modifiers.BuildName(baseName: string, rolledAffixes: { any }): string
	local prefix, suffix
	for _, rolled in ipairs(rolledAffixes) do
		local affix = Modifiers.AffixById[rolled.affixId]
		if affix then
			if affix.position == "prefix" and not prefix then
				prefix = affix.name
			elseif affix.position == "suffix" and not suffix then
				suffix = affix.suffixText or ("of " .. affix.name)
			end
		end
	end

	local name = baseName
	if prefix then
		name = prefix .. " " .. name
	end
	if suffix then
		name = name .. " " .. suffix
	end
	return name
end

--[[ Applies an item's rolled affixes into a stat accumulator. ]]
function Modifiers.ApplyAffixes(Stats: any, accumulator: any, rolledAffixes: { any }, label: string)
	for _, rolled in ipairs(rolledAffixes) do
		local affix = Modifiers.AffixById[rolled.affixId]
		if affix then
			Stats.Contribute(accumulator, affix.stat, affix.kind, rolled.value, label)
		end
	end
end

return TableUtil.DeepFreeze(Modifiers)
