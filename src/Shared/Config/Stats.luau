--!strict
--[[
	Stats
	-----
	The canonical stat registry. Every source of power in the game — core upgrades,
	skill nodes, equipment base values, equipment modifiers, abilities, masteries,
	prestige bonuses and temporary buffs — writes into this same set of keys.

	That single-registry rule is what makes the character sheet honest: the UI can
	show exactly where each point came from because every contribution is tagged.

	Aggregation model (applied in this order, per stat):
		1. base            the stat's baseline
		2. flat            summed additive contributions
		3. increased       summed percentage contributions, applied as (1 + sum)
		4. more            multiplicative contributions, applied as a running product
		5. clamp           min/max bounds

	"increased" adds, "more" multiplies. Keeping the two distinct is what stops
	stacking five +20% sources from silently becoming +149%, and it gives designers a
	lever for rare effects that should genuinely feel rare.
]]

local TableUtil = require(script.Parent.Parent.Core.TableUtil)

local Stats = {}

export type StatDefinition = {
	id: string,
	name: string,
	short: string,
	description: string,
	category: string,
	base: number,
	min: number,
	max: number,
	format: string,
	higherIsBetter: boolean,
	hiddenUntilRelevant: boolean?,
}

Stats.Categories = {
	{ id = "capture", name = "Capture", order = 1 },
	{ id = "containment", name = "Containment", order = 2 },
	{ id = "movement", name = "Movement", order = 3 },
	{ id = "survival", name = "Survival", order = 4 },
	{ id = "economy", name = "Economy", order = 5 },
	{ id = "utility", name = "Utility", order = 6 },
}

Stats.List = {
	-- ---------------------------------------------------------------- capture
	{
		id = "captureRadius",
		name = "Capture Radius",
		short = "RAD",
		description = "How far from a strike point you can still take the energy.",
		category = "capture",
		base = 34,
		min = 10,
		max = 96,
		format = "studs",
		higherIsBetter = true,
	},
	{
		id = "captureWindow",
		name = "Capture Window",
		short = "WIN",
		description = "Widens the timing window on every strike. The single most forgiving stat in the game.",
		category = "capture",
		base = 1.0,
		min = 0.4,
		max = 2.6,
		format = "multiplier",
		higherIsBetter = true,
	},
	{
		id = "captureYield",
		name = "Capture Yield",
		short = "YLD",
		description = "Energy taken per successful capture.",
		category = "capture",
		base = 1.0,
		min = 0.2,
		max = 8.0,
		format = "multiplier",
		higherIsBetter = true,
	},
	{
		id = "captureStability",
		name = "Capture Stability",
		short = "STB",
		description = "Chance that a failed capture is automatically corrected to a Weak capture instead of a miss.",
		category = "capture",
		base = 0,
		min = 0,
		max = 0.75,
		format = "percent",
		higherIsBetter = true,
	},
	{
		id = "chainRetention",
		name = "Chain Retention",
		short = "CHN",
		description = "Extends how long a capture chain survives without a new capture.",
		category = "capture",
		base = 1.0,
		min = 0.5,
		max = 4.0,
		format = "multiplier",
		higherIsBetter = true,
	},
	{
		id = "multiCapture",
		name = "Multi-Capture",
		short = "MUL",
		description = "Number of additional strikes you can take from a single telegraph.",
		category = "capture",
		base = 0,
		min = 0,
		max = 4,
		format = "integer",
		higherIsBetter = true,
		hiddenUntilRelevant = true,
	},

	-- ------------------------------------------------------------ containment
	{
		id = "capacity",
		name = "Containment",
		short = "CAP",
		description = "Maximum unstable energy you can carry before a run must end.",
		category = "containment",
		base = 120,
		min = 40,
		max = 25000,
		format = "energy",
		higherIsBetter = true,
	},
	{
		id = "instabilityResist",
		name = "Instability Resistance",
		short = "INS",
		description = "Slows how fast carried energy destabilises.",
		category = "containment",
		base = 0,
		min = 0,
		max = 0.85,
		format = "percent",
		higherIsBetter = true,
	},
	{
		id = "ventProtection",
		name = "Vent Protection",
		short = "VNT",
		description = "Reduces the energy lost when containment vents.",
		category = "containment",
		base = 0,
		min = 0,
		max = 0.9,
		format = "percent",
		higherIsBetter = true,
	},
	{
		id = "lossProtection",
		name = "Loss Protection",
		short = "LSS",
		description = "Reduces energy lost on death and increases what your cache preserves.",
		category = "containment",
		base = 0,
		min = 0,
		max = 0.85,
		format = "percent",
		higherIsBetter = true,
	},

	-- --------------------------------------------------------------- movement
	{
		id = "moveSpeed",
		name = "Movement Speed",
		short = "SPD",
		description = "Base traversal speed on foot.",
		category = "movement",
		base = 16,
		min = 8,
		max = 64,
		format = "studs_per_second",
		higherIsBetter = true,
	},
	{
		id = "sprintSpeed",
		name = "Sprint Speed",
		short = "SPR",
		description = "Speed while sprinting.",
		category = "movement",
		base = 26,
		min = 16,
		max = 96,
		format = "studs_per_second",
		higherIsBetter = true,
	},
	{
		id = "jumpPower",
		name = "Jump Power",
		short = "JMP",
		description = "Vertical launch force.",
		category = "movement",
		base = 50,
		min = 30,
		max = 140,
		format = "raw",
		higherIsBetter = true,
	},
	{
		id = "carryPenaltyResist",
		name = "Load Handling",
		short = "LOD",
		description = "Reduces how much a full containment slows you down.",
		category = "movement",
		base = 0,
		min = 0,
		max = 1.0,
		format = "percent",
		higherIsBetter = true,
	},
	{
		id = "abilityCooldown",
		name = "Cooldown Reduction",
		short = "CDR",
		description = "Reduces the recharge time of every active ability.",
		category = "movement",
		base = 0,
		min = 0,
		max = 0.7,
		format = "percent",
		higherIsBetter = true,
	},

	-- --------------------------------------------------------------- survival
	{
		id = "maxHealth",
		name = "Integrity",
		short = "HP",
		description = "How much punishment your suit absorbs before you go down.",
		category = "survival",
		base = 100,
		min = 40,
		max = 2400,
		format = "raw",
		higherIsBetter = true,
	},
	{
		id = "stormResist",
		name = "Storm Resistance",
		short = "RES",
		description = "Reduces continuous exposure damage in high-danger regions. Gates which regions you can survive at all.",
		category = "survival",
		base = 0,
		min = 0,
		max = 0.82,
		format = "percent",
		higherIsBetter = true,
	},
	{
		id = "shockResist",
		name = "Shock Resistance",
		short = "SHK",
		description = "Reduces burst damage from missed captures and hazards.",
		category = "survival",
		base = 0,
		min = 0,
		max = 0.8,
		format = "percent",
		higherIsBetter = true,
	},
	{
		id = "healthRegen",
		name = "Recovery",
		short = "REG",
		description = "Health restored per second once you have been out of danger briefly.",
		category = "survival",
		base = 4.5,
		min = 0,
		max = 60,
		format = "per_second",
		higherIsBetter = true,
	},
	{
		id = "fallProtection",
		name = "Fall Damping",
		short = "FAL",
		description = "Reduces fall damage and raises the height you can drop from safely.",
		category = "survival",
		base = 0,
		min = 0,
		max = 1.0,
		format = "percent",
		higherIsBetter = true,
	},

	-- ---------------------------------------------------------------- economy
	{
		id = "bankRate",
		name = "Bank Efficiency",
		short = "BNK",
		description = "Watts earned per unit of energy banked.",
		category = "economy",
		base = 1.0,
		min = 0.5,
		max = 12.0,
		format = "multiplier",
		higherIsBetter = true,
	},
	{
		id = "riskBonus",
		name = "Risk Multiplier",
		short = "RSK",
		description = "Amplifies the payout bonus earned from long unbanked chains.",
		category = "economy",
		base = 1.0,
		min = 0.5,
		max = 6.0,
		format = "multiplier",
		higherIsBetter = true,
	},
	{
		id = "xpGain",
		name = "Experience Gain",
		short = "XP",
		description = "Runner experience earned from all sources.",
		category = "economy",
		base = 1.0,
		min = 0.5,
		max = 5.0,
		format = "multiplier",
		higherIsBetter = true,
	},
	{
		id = "luck",
		name = "Fortune",
		short = "LCK",
		description = "Tilts every loot roll toward higher rarities.",
		category = "economy",
		base = 0,
		min = 0,
		max = 6.0,
		format = "raw",
		higherIsBetter = true,
	},
	{
		id = "resourceYield",
		name = "Salvage Yield",
		short = "SLV",
		description = "Quantity of crafting materials recovered from every source.",
		category = "economy",
		base = 1.0,
		min = 0.5,
		max = 6.0,
		format = "multiplier",
		higherIsBetter = true,
	},

	-- ---------------------------------------------------------------- utility
	{
		id = "scanRange",
		name = "Scan Range",
		short = "SCN",
		description = "How far your equipment detects storm activity and marks it on the map.",
		category = "utility",
		base = 420,
		min = 120,
		max = 6000,
		format = "studs",
		higherIsBetter = true,
	},
	{
		id = "rareDetection",
		name = "Anomaly Detection",
		short = "ANO",
		description = "Reveals rare storms and hidden anomalies your scanner would otherwise miss.",
		category = "utility",
		base = 0,
		min = 0,
		max = 1.0,
		format = "percent",
		higherIsBetter = true,
	},
	{
		id = "reviveSpeed",
		name = "Field Medicine",
		short = "MED",
		description = "How quickly you bring a downed runner back up.",
		category = "utility",
		base = 1.0,
		min = 0.5,
		max = 4.0,
		format = "multiplier",
		higherIsBetter = true,
	},
	{
		id = "teamAura",
		name = "Team Aura",
		short = "AUR",
		description = "Strength of the bonuses you project onto nearby runners.",
		category = "utility",
		base = 0,
		min = 0,
		max = 3.0,
		format = "multiplier",
		higherIsBetter = true,
		hiddenUntilRelevant = true,
	},
	{
		id = "craftQuality",
		name = "Craft Precision",
		short = "CFT",
		description = "Improves the rolls on everything you build at a workbench.",
		category = "utility",
		base = 0,
		min = 0,
		max = 2.0,
		format = "raw",
		higherIsBetter = true,
		hiddenUntilRelevant = true,
	},
}

Stats.ById = {}
Stats.Ids = {}
Stats.ByCategory = {}

for _, stat in ipairs(Stats.List) do
	Stats.ById[stat.id] = stat
	table.insert(Stats.Ids, stat.id)
	Stats.ByCategory[stat.category] = Stats.ByCategory[stat.category] or {}
	table.insert(Stats.ByCategory[stat.category], stat.id)
end

--[[ Returns a table of every stat at its base value. ]]
function Stats.CreateBaseTable(): { [string]: number }
	local out = {}
	for _, stat in ipairs(Stats.List) do
		out[stat.id] = stat.base
	end
	return out
end

--[[ Creates the empty accumulator that Stats.Resolve consumes. ]]
function Stats.CreateAccumulator()
	return {
		flat = {},
		increased = {},
		more = {},
		-- sources[statId] = { { label, kind, amount }, ... } for the character sheet
		sources = {},
	}
end

--[[
	Records a contribution.
	`kind` is "flat", "increased" or "more"; `label` is what the UI shows as the source.
]]
function Stats.Contribute(accumulator: any, statId: string, kind: string, amount: number, label: string?)
	if amount == 0 or amount == nil then
		return
	end
	local bucket = accumulator[kind]
	if not bucket then
		warn(("[Stats] unknown contribution kind '%s' for stat '%s'"):format(tostring(kind), tostring(statId)))
		return
	end
	if not Stats.ById[statId] then
		warn(("[Stats] contribution to unknown stat '%s'"):format(tostring(statId)))
		return
	end

	if kind == "more" then
		bucket[statId] = (bucket[statId] or 1) * (1 + amount)
	else
		bucket[statId] = (bucket[statId] or 0) + amount
	end

	if label then
		accumulator.sources[statId] = accumulator.sources[statId] or {}
		table.insert(accumulator.sources[statId], { label = label, kind = kind, amount = amount })
	end
end

--[[
	Applies a { statId = amount } table of a single kind. Most content declares its
	effects this way, so this is the common entry point.
]]
function Stats.ContributeTable(accumulator: any, kind: string, effects: { [string]: number }?, label: string?)
	if not effects then
		return
	end
	for statId, amount in pairs(effects) do
		Stats.Contribute(accumulator, statId, kind, amount, label)
	end
end

--[[
	Collapses an accumulator into final stat values.
	Returns (values, sources) so callers can render a breakdown without recomputing.
]]
function Stats.Resolve(accumulator: any): ({ [string]: number }, { [string]: any })
	local values = {}
	for _, stat in ipairs(Stats.List) do
		local value = stat.base
		value += (accumulator.flat[stat.id] or 0)
		value *= (1 + (accumulator.increased[stat.id] or 0))
		value *= (accumulator.more[stat.id] or 1)
		values[stat.id] = math.clamp(value, stat.min, stat.max)
	end
	return values, accumulator.sources
end

--[[ Human-readable rendering of a stat value, driven by its declared format. ]]
function Stats.Format(statId: string, value: number): string
	local stat = Stats.ById[statId]
	if not stat then
		return tostring(value)
	end
	local format = stat.format
	if format == "percent" then
		return ("%d%%"):format(math.floor(value * 100 + 0.5))
	elseif format == "multiplier" then
		return ("%.2fx"):format(value)
	elseif format == "studs" then
		return ("%d studs"):format(math.floor(value + 0.5))
	elseif format == "studs_per_second" then
		return ("%.1f"):format(value)
	elseif format == "per_second" then
		return ("%.1f/s"):format(value)
	elseif format == "integer" then
		return tostring(math.floor(value + 0.5))
	elseif format == "energy" then
		if value >= 1000 then
			return ("%.1fk"):format(value / 1000)
		end
		return tostring(math.floor(value + 0.5))
	end
	return ("%.1f"):format(value)
end

--[[
	Signed delta string for comparison UI ("+12 studs", "-0.30x"). Returns the string
	and a semantic direction ("better", "worse", "same") so the UI picks its own colour.
]]
function Stats.FormatDelta(statId: string, from: number, to: number): (string, string)
	local stat = Stats.ById[statId]
	local delta = to - from
	if math.abs(delta) < 1e-6 then
		return "", "same"
	end
	local direction = "same"
	if stat then
		local improved = (delta > 0) == stat.higherIsBetter
		direction = improved and "better" or "worse"
	end
	local sign = delta > 0 and "+" or ""
	local body
	if stat and stat.format == "percent" then
		body = ("%s%d%%"):format(sign, math.floor(delta * 100 + (delta > 0 and 0.5 or -0.5)))
	elseif stat and stat.format == "multiplier" then
		body = ("%s%.2fx"):format(sign, delta)
	elseif stat and (stat.format == "integer" or stat.format == "energy" or stat.format == "raw" or stat.format == "studs") then
		body = ("%s%d"):format(sign, math.floor(delta + (delta > 0 and 0.5 or -0.5)))
	else
		body = ("%s%.1f"):format(sign, delta)
	end
	return body, direction
end

return TableUtil.DeepFreeze(Stats)
