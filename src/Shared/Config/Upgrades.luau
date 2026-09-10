--!strict
--[[
	Upgrades
	--------
	Core upgrade tracks: the always-available, Watts-purchased spine of progression
	that a player interacts with in the first two minutes and is still interacting
	with at level 100.

	Design rule enforced here: a track is never *only* a number. Every track declares
	`milestones` — specific levels that unlock new behaviour rather than more of the
	same. The UI surfaces the next milestone prominently so the player is always
	buying toward a capability, not a decimal.

	Cost model: geometric growth from `costBase` at `costGrowth` per level, so early
	levels are impulse purchases and late levels are session goals.
]]

local TableUtil = require(script.Parent.Parent.Core.TableUtil)
local MathUtil = require(script.Parent.Parent.Core.MathUtil)

local Upgrades = {}

Upgrades.List = {

	-- ---------------------------------------------------------------- CAPTURE
	{
		id = "capture_coil",
		name = "Capture Coil",
		category = "capture",
		order = 1,
		description = "The core of your rig. Widens the timing window on every strike in the game.",
		icon = "coil",
		maxLevel = 40,
		costCurrency = "watts",
		costBase = 55,
		costGrowth = 1.155,
		perLevel = {
			increased = { captureWindow = 0.035 },
		},
		milestones = {
			[5] = {
				id = "coil_forgiving",
				name = "Forgiving Coil",
				description = "A missed capture no longer shocks you for full damage.",
				effect = { flat = { shockResist = 0.15 } },
			},
			[12] = {
				id = "coil_autostabilise",
				name = "Auto-Stabiliser",
				description = "Failed captures have a chance to salvage into a Weak capture instead of missing entirely.",
				effect = { flat = { captureStability = 0.18 } },
				unlocksBehaviour = "capture_salvage",
			},
			[22] = {
				id = "coil_second_take",
				name = "Second Take",
				description = "Once per storm cell, a total miss re-opens the window for a final attempt.",
				unlocksBehaviour = "capture_retry",
			},
			[34] = {
				id = "coil_overcharge_bloom",
				name = "Overcharge Bloom",
				description = "Overcharge captures release a shockwave that pre-charges nearby strike points.",
				unlocksBehaviour = "overcharge_bloom",
			},
		},
	},

	{
		id = "field_extender",
		name = "Field Extender",
		category = "capture",
		order = 2,
		description = "Take energy from further away. Turns dangerous captures into safe ones.",
		icon = "radius",
		maxLevel = 30,
		costCurrency = "watts",
		costBase = 70,
		costGrowth = 1.17,
		perLevel = {
			flat = { captureRadius = 1.8 },
		},
		milestones = {
			[8] = {
				id = "extender_reach",
				name = "Extended Reach",
				description = "Capture range now works through thin cover.",
				unlocksBehaviour = "capture_through_cover",
			},
			[18] = {
				id = "extender_split",
				name = "Split Field",
				description = "You can hold two strike points in your field at once.",
				effect = { flat = { multiCapture = 1 } },
				unlocksBehaviour = "multi_capture",
			},
			[30] = {
				id = "extender_dominion",
				name = "Dominion",
				description = "Your field covers an entire small storm cell.",
				effect = { flat = { captureRadius = 12 } },
			},
		},
	},

	{
		id = "yield_regulator",
		name = "Yield Regulator",
		category = "capture",
		order = 3,
		description = "Extract more from every strike you land.",
		icon = "yield",
		maxLevel = 45,
		costCurrency = "watts",
		costBase = 90,
		costGrowth = 1.185,
		perLevel = {
			increased = { captureYield = 0.028 },
		},
		milestones = {
			[10] = {
				id = "regulator_clean",
				name = "Clean Extraction",
				description = "Perfect captures no longer add instability.",
				unlocksBehaviour = "perfect_no_instability",
			},
			[25] = {
				id = "regulator_surplus",
				name = "Surplus Draw",
				description = "Overcharge captures also restore integrity.",
				unlocksBehaviour = "overcharge_heal",
			},
			[45] = {
				id = "regulator_saturation",
				name = "Saturation",
				description = "Yield scales with how full your containment already is.",
				unlocksBehaviour = "yield_scales_with_fill",
			},
		},
	},

	-- ------------------------------------------------------------ CONTAINMENT
	{
		id = "containment_cell",
		name = "Containment Cell",
		category = "containment",
		order = 4,
		description = "How much you can carry before you have to make a decision.",
		icon = "cell",
		maxLevel = 50,
		costCurrency = "watts",
		costBase = 60,
		costGrowth = 1.2,
		perLevel = {
			flat = { capacity = 26 },
			increased = { capacity = 0.012 },
		},
		milestones = {
			[6] = {
				id = "cell_reserve",
				name = "Reserve Chamber",
				description = "Energy above capacity is held in reserve for eight seconds instead of being lost.",
				unlocksBehaviour = "overflow_reserve",
			},
			[16] = {
				id = "cell_partition",
				name = "Partitioned Cell",
				description = "Bank half your carry without ending your chain.",
				unlocksBehaviour = "partial_bank",
			},
			[30] = {
				id = "cell_volatile",
				name = "Volatile Containment",
				description = "Carry legendary-grade unstable energy that a standard cell cannot hold.",
				unlocksBehaviour = "carry_volatile",
			},
			[50] = {
				id = "cell_singularity",
				name = "Singularity Cell",
				description = "Capacity no longer has a hard ceiling; instability rises instead.",
				unlocksBehaviour = "soft_capacity",
			},
		},
	},

	{
		id = "stabiliser",
		name = "Stabiliser Array",
		category = "containment",
		order = 5,
		description = "Slows the climb of instability, buying you the time to push one more capture.",
		icon = "stabiliser",
		maxLevel = 35,
		costCurrency = "watts",
		costBase = 85,
		costGrowth = 1.19,
		perLevel = {
			flat = { instabilityResist = 0.019 },
		},
		milestones = {
			[9] = {
				id = "stabiliser_vent_control",
				name = "Vent Control",
				description = "Venting costs far less energy and no longer staggers you.",
				effect = { flat = { ventProtection = 0.3 } },
			},
			[20] = {
				id = "stabiliser_purge",
				name = "Manual Purge",
				description = "Dump instability on demand at the cost of a slice of your carry.",
				unlocksBehaviour = "manual_purge",
				grantsAbility = "purge",
			},
			[35] = {
				id = "stabiliser_equilibrium",
				name = "Equilibrium",
				description = "Instability stops rising entirely while you are moving at sprint speed.",
				unlocksBehaviour = "motion_equilibrium",
			},
		},
	},

	{
		id = "insurance_module",
		name = "Recovery Module",
		category = "containment",
		order = 6,
		description = "Keeps more of your run when the run goes wrong.",
		icon = "recovery",
		maxLevel = 25,
		costCurrency = "watts",
		costBase = 120,
		costGrowth = 1.22,
		perLevel = {
			flat = { lossProtection = 0.026 },
		},
		milestones = {
			[7] = {
				id = "recovery_beacon",
				name = "Cache Beacon",
				description = "Your death cache is marked on the map and lasts twice as long.",
				unlocksBehaviour = "cache_beacon",
			},
			[15] = {
				id = "recovery_deadman",
				name = "Dead Man's Bank",
				description = "On death, a quarter of your carry is banked automatically instead of dropped.",
				unlocksBehaviour = "deathbank",
			},
			[25] = {
				id = "recovery_phoenix",
				name = "Phoenix Circuit",
				description = "Once every ten minutes, lethal damage is survived at one integrity with a full purge.",
				unlocksBehaviour = "phoenix",
			},
		},
	},

	-- --------------------------------------------------------------- MOVEMENT
	{
		id = "actuators",
		name = "Leg Actuators",
		category = "movement",
		order = 7,
		description = "Faster on foot. Compounds with every other movement system you own.",
		icon = "speed",
		maxLevel = 30,
		costCurrency = "watts",
		costBase = 65,
		costGrowth = 1.165,
		perLevel = {
			flat = { moveSpeed = 0.35, sprintSpeed = 0.75 },
		},
		milestones = {
			[6] = {
				id = "actuators_slide",
				name = "Slide Servos",
				description = "Unlocks the slide.",
				unlocksTraversal = "slide",
			},
			[14] = {
				id = "actuators_vault",
				name = "Vault Assist",
				description = "Unlocks automatic vaulting over waist-height obstacles.",
				unlocksTraversal = "vault",
			},
			[22] = {
				id = "actuators_mantle",
				name = "Mantle Grips",
				description = "Unlocks pulling yourself onto ledges up to eleven studs high.",
				unlocksTraversal = "mantle",
			},
			[30] = {
				id = "actuators_momentum",
				name = "Momentum Bank",
				description = "Speed gained from slides and slopes decays far more slowly.",
				unlocksBehaviour = "momentum_retention",
			},
		},
	},

	{
		id = "load_frame",
		name = "Load Frame",
		category = "movement",
		order = 8,
		description = "Carry a full cell without moving like you are carrying a full cell.",
		icon = "frame",
		maxLevel = 20,
		costCurrency = "watts",
		costBase = 110,
		costGrowth = 1.2,
		perLevel = {
			flat = { carryPenaltyResist = 0.05 },
		},
		milestones = {
			[10] = {
				id = "frame_counterweight",
				name = "Counterweight",
				description = "Carrying above 75% capacity now grants jump height instead of costing speed.",
				unlocksBehaviour = "heavy_jump",
			},
			[20] = {
				id = "frame_null_load",
				name = "Null Load",
				description = "Carry weight no longer affects movement at all.",
				effect = { flat = { carryPenaltyResist = 0.4 } },
			},
		},
	},

	-- --------------------------------------------------------------- SURVIVAL
	{
		id = "suit_plating",
		name = "Suit Plating",
		category = "survival",
		order = 9,
		description = "Integrity. The difference between a close call and a lost run.",
		icon = "armor",
		maxLevel = 40,
		costCurrency = "watts",
		costBase = 75,
		costGrowth = 1.175,
		perLevel = {
			flat = { maxHealth = 9 },
		},
		milestones = {
			[10] = {
				id = "plating_grounded",
				name = "Grounded Plating",
				description = "Standing on metal no longer amplifies shock damage.",
				unlocksBehaviour = "grounded",
			},
			[24] = {
				id = "plating_kinetic",
				name = "Kinetic Dispersal",
				description = "Fall damage is halved and hard landings no longer stagger you.",
				effect = { flat = { fallProtection = 0.5 } },
			},
			[40] = {
				id = "plating_bulwark",
				name = "Bulwark",
				description = "Damage that would drop you below 25% integrity is capped, once per minute.",
				unlocksBehaviour = "damage_cap",
			},
		},
	},

	{
		id = "insulation",
		name = "Storm Insulation",
		category = "survival",
		order = 10,
		description = "Storm resistance. This is what decides which regions you can even enter.",
		icon = "insulation",
		maxLevel = 45,
		costCurrency = "watts",
		costBase = 100,
		costGrowth = 1.2,
		perLevel = {
			flat = { stormResist = 0.014 },
		},
		milestones = {
			[8] = {
				id = "insulation_sector",
				name = "Sector Rated",
				description = "You can survive sustained exposure in the Industrial Grid.",
				gatesRegion = "industrial_grid",
			},
			[18] = {
				id = "insulation_deep",
				name = "Deep Rated",
				description = "You can survive sustained exposure in the Scour.",
				gatesRegion = "electrical_wasteland",
			},
			[30] = {
				id = "insulation_altitude",
				name = "Altitude Rated",
				description = "You can survive sustained exposure in the Anchorage.",
				gatesRegion = "high_altitude",
			},
			[45] = {
				id = "insulation_core",
				name = "Core Rated",
				description = "You can survive the Outer Wall of the Core.",
				gatesRegion = "storm_core",
			},
		},
	},

	-- ---------------------------------------------------------------- ECONOMY
	{
		id = "bank_interface",
		name = "Bank Interface",
		category = "economy",
		order = 11,
		description = "More Watts for the same energy. The compounding upgrade.",
		icon = "bank",
		maxLevel = 40,
		costCurrency = "watts",
		costBase = 130,
		costGrowth = 1.21,
		perLevel = {
			increased = { bankRate = 0.024 },
		},
		milestones = {
			[9] = {
				id = "bank_remote",
				name = "Remote Uplink",
				description = "Bank from anywhere in the world for a percentage cut.",
				unlocksBehaviour = "remote_bank",
			},
			[20] = {
				id = "bank_streak",
				name = "Streak Ledger",
				description = "Consecutive banks without a death build a stacking bonus.",
				unlocksBehaviour = "bank_streak",
			},
			[33] = {
				id = "bank_arbitrage",
				name = "Arbitrage",
				description = "Banking in a region you have mastered pays a regional premium.",
				unlocksBehaviour = "region_premium",
			},
		},
	},

	{
		id = "risk_governor",
		name = "Risk Governor",
		category = "economy",
		order = 12,
		description = "Amplifies the payout on long chains. The greedy player's favourite track.",
		icon = "risk",
		maxLevel = 30,
		costCurrency = "watts",
		costBase = 160,
		costGrowth = 1.23,
		perLevel = {
			increased = { riskBonus = 0.03 },
			flat = { chainRetention = 0.02 },
		},
		milestones = {
			[8] = {
				id = "risk_readout",
				name = "Live Readout",
				description = "Your exact current multiplier and projected payout are shown on the HUD.",
				unlocksBehaviour = "risk_readout",
			},
			[18] = {
				id = "risk_double_or_nothing",
				name = "Double or Nothing",
				description = "Commit at a bank to double your multiplier — or lose the chain outright.",
				unlocksBehaviour = "gamble_bank",
			},
			[30] = {
				id = "risk_unbounded",
				name = "Unbounded",
				description = "The chain soft cap is removed. Nothing stops you but instability.",
				unlocksBehaviour = "no_chain_cap",
			},
		},
	},

	-- ---------------------------------------------------------------- UTILITY
	{
		id = "scanner",
		name = "Field Scanner",
		category = "utility",
		order = 13,
		description = "See storms before they see you. The exploration player's spine.",
		icon = "scanner",
		maxLevel = 35,
		costCurrency = "watts",
		costBase = 80,
		costGrowth = 1.18,
		perLevel = {
			flat = { scanRange = 62 },
		},
		milestones = {
			[7] = {
				id = "scanner_classify",
				name = "Classification",
				description = "Detected storms show their type and tier on the compass.",
				unlocksBehaviour = "storm_classification",
			},
			[15] = {
				id = "scanner_anomaly",
				name = "Anomaly Filter",
				description = "Rare and legendary storms are highlighted world-wide as they spawn.",
				effect = { flat = { rareDetection = 0.35 } },
				unlocksBehaviour = "rare_alerts",
			},
			[24] = {
				id = "scanner_prediction",
				name = "Predictive Modelling",
				description = "The map shows where the next cell will form, thirty seconds early.",
				unlocksBehaviour = "storm_prediction",
			},
			[35] = {
				id = "scanner_deep_survey",
				name = "Deep Survey",
				description = "Undiscovered secrets within scan range show as unresolved contacts.",
				unlocksBehaviour = "secret_pings",
			},
		},
	},

	{
		id = "salvage_rig",
		name = "Salvage Rig",
		category = "utility",
		order = 14,
		description = "More materials from everything. Feeds the entire crafting economy.",
		icon = "salvage",
		maxLevel = 30,
		costCurrency = "watts",
		costBase = 95,
		costGrowth = 1.19,
		perLevel = {
			increased = { resourceYield = 0.03 },
		},
		milestones = {
			[8] = {
				id = "salvage_autocollect",
				name = "Auto-Collector",
				description = "Materials within twenty studs are drawn to you automatically.",
				unlocksBehaviour = "magnet_pickup",
			},
			[18] = {
				id = "salvage_refine",
				name = "Field Refinery",
				description = "Dismantle equipment anywhere without returning to a workbench.",
				unlocksBehaviour = "field_dismantle",
			},
			[30] = {
				id = "salvage_transmute",
				name = "Transmutation",
				description = "Convert surplus materials into the tier above at a fixed rate.",
				unlocksBehaviour = "material_transmute",
			},
		},
	},
}

Upgrades.ById = {}
Upgrades.ByCategory = {}

for _, upgrade in ipairs(Upgrades.List) do
	Upgrades.ById[upgrade.id] = upgrade
	Upgrades.ByCategory[upgrade.category] = Upgrades.ByCategory[upgrade.category] or {}
	table.insert(Upgrades.ByCategory[upgrade.category], upgrade.id)
end

function Upgrades.Get(upgradeId: string)
	return Upgrades.ById[upgradeId]
end

--[[ Cost in the track's currency to go from `level` to `level + 1`. ]]
function Upgrades.GetCost(upgradeId: string, level: number): (number, string)
	local upgrade = Upgrades.ById[upgradeId]
	if not upgrade then
		return math.huge, "watts"
	end
	if level >= upgrade.maxLevel then
		return math.huge, upgrade.costCurrency
	end
	return MathUtil.UpgradeCost(upgrade.costBase, upgrade.costGrowth, level), upgrade.costCurrency
end

--[[ Total cost of buying every remaining level in a track. ]]
function Upgrades.GetRemainingCost(upgradeId: string, level: number): number
	local upgrade = Upgrades.ById[upgradeId]
	if not upgrade then
		return 0
	end
	return MathUtil.UpgradeCostRange(upgrade.costBase, upgrade.costGrowth, level, upgrade.maxLevel)
end

--[[
	How many levels of `upgradeId` the given balance can afford starting from `level`.
	Returns (levels, totalCost) so the "buy max" button can be exact.
]]
function Upgrades.GetAffordableLevels(upgradeId: string, level: number, balance: number): (number, number)
	local upgrade = Upgrades.ById[upgradeId]
	if not upgrade then
		return 0, 0
	end
	local bought = 0
	local spent = 0
	local current = level
	while current < upgrade.maxLevel do
		local cost = MathUtil.UpgradeCost(upgrade.costBase, upgrade.costGrowth, current)
		if spent + cost > balance then
			break
		end
		spent += cost
		bought += 1
		current += 1
	end
	return bought, spent
end

--[[ The next milestone at or above `level`, plus how many levels away it is. ]]
function Upgrades.GetNextMilestone(upgradeId: string, level: number): (any?, number?)
	local upgrade = Upgrades.ById[upgradeId]
	if not upgrade or not upgrade.milestones then
		return nil, nil
	end
	local bestLevel = nil
	for milestoneLevel in pairs(upgrade.milestones) do
		if milestoneLevel > level and (bestLevel == nil or milestoneLevel < bestLevel) then
			bestLevel = milestoneLevel
		end
	end
	if not bestLevel then
		return nil, nil
	end
	return upgrade.milestones[bestLevel], bestLevel - level
end

--[[ Every milestone already earned at the given level. ]]
function Upgrades.GetEarnedMilestones(upgradeId: string, level: number): { any }
	local upgrade = Upgrades.ById[upgradeId]
	if not upgrade or not upgrade.milestones then
		return {}
	end
	local levels = {}
	for milestoneLevel in pairs(upgrade.milestones) do
		if milestoneLevel <= level then
			table.insert(levels, milestoneLevel)
		end
	end
	table.sort(levels)
	local earned = {}
	for _, milestoneLevel in ipairs(levels) do
		local milestone = table.clone(upgrade.milestones[milestoneLevel])
		milestone.level = milestoneLevel
		table.insert(earned, milestone)
	end
	return earned
end

--[[
	Applies every purchased upgrade level (and its earned milestones) into a stat
	accumulator. `levels` is a map of upgradeId -> purchased level.
]]
function Upgrades.ApplyToAccumulator(Stats: any, accumulator: any, levels: { [string]: number })
	for _, upgrade in ipairs(Upgrades.List) do
		local level = levels[upgrade.id] or 0
		if level > 0 then
			local label = upgrade.name .. " " .. tostring(level)
			if upgrade.perLevel.flat then
				for statId, amount in pairs(upgrade.perLevel.flat) do
					Stats.Contribute(accumulator, statId, "flat", amount * level, label)
				end
			end
			if upgrade.perLevel.increased then
				for statId, amount in pairs(upgrade.perLevel.increased) do
					Stats.Contribute(accumulator, statId, "increased", amount * level, label)
				end
			end
			if upgrade.perLevel.more then
				for statId, amount in pairs(upgrade.perLevel.more) do
					Stats.Contribute(accumulator, statId, "more", amount * level, label)
				end
			end

			for _, milestone in ipairs(Upgrades.GetEarnedMilestones(upgrade.id, level)) do
				if milestone.effect then
					Stats.ContributeTable(accumulator, "flat", milestone.effect.flat, milestone.name)
					Stats.ContributeTable(accumulator, "increased", milestone.effect.increased, milestone.name)
					Stats.ContributeTable(accumulator, "more", milestone.effect.more, milestone.name)
				end
			end
		end
	end
end

--[[ Collects every behaviour flag unlocked by the player's current upgrade levels. ]]
function Upgrades.CollectBehaviours(levels: { [string]: number }): { [string]: boolean }
	local behaviours = {}
	for _, upgrade in ipairs(Upgrades.List) do
		local level = levels[upgrade.id] or 0
		for _, milestone in ipairs(Upgrades.GetEarnedMilestones(upgrade.id, level)) do
			if milestone.unlocksBehaviour then
				behaviours[milestone.unlocksBehaviour] = true
			end
		end
	end
	return behaviours
end

--[[ Traversal abilities granted by upgrade milestones. ]]
function Upgrades.CollectTraversal(levels: { [string]: number }): { [string]: boolean }
	local traversal = {}
	for _, upgrade in ipairs(Upgrades.List) do
		local level = levels[upgrade.id] or 0
		for _, milestone in ipairs(Upgrades.GetEarnedMilestones(upgrade.id, level)) do
			if milestone.unlocksTraversal then
				traversal[milestone.unlocksTraversal] = true
			end
		end
	end
	return traversal
end

return TableUtil.DeepFreeze(Upgrades)
