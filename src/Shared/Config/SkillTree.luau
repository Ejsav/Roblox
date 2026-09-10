--!strict
--[[
	SkillTree
	---------
	Seven specialisation branches, ninety-one nodes. Skill points come from levelling.

	Structure per branch: five tiers deep. Tier 1 is cheap and generically useful so
	every build takes it; tiers 3 and 5 hold the capstones that define an archetype.
	Cross-branch prerequisites exist deliberately at tier 4 so hybrids are reachable
	but never free.

	Node kinds:
		stat      ranked numeric investment
		ability   grants an active ability (rank 1 only)
		passive   grants a passive ability (rank 1 only)
		traversal grants a movement capability (rank 1 only)
		keystone  a build-defining node with a real downside attached

	Keystones always carry a cost. A node that is strictly better than not taking it
	is not a decision, and the tree is supposed to be made of decisions.

	`position` is a grid coordinate the UI lays out directly: x is the column within
	the branch, y is the tier.
]]

local TableUtil = require(script.Parent.Parent.Core.TableUtil)

local SkillTree = {}

SkillTree.Branches = {
	{
		id = "runner",
		name = "Runner",
		tagline = "Speed is the only defence that always works.",
		description = "Movement, escape and tempo. Runners bank small and bank often, and nothing catches them.",
		color = "58C8FF",
		icon = "runner",
		order = 1,
	},
	{
		id = "vault",
		name = "Vault",
		tagline = "Carry everything. Come back once.",
		description = "Containment and endurance. Vaults move slowly, hold enormous carries, and turn one run into a fortune.",
		color = "FFA23D",
		icon = "vault",
		order = 2,
	},
	{
		id = "hunter",
		name = "Hunter",
		tagline = "Find what other people walk past.",
		description = "Detection, rare storms and exploration. Hunters know where the good weather is before it forms.",
		color = "6FE3C6",
		icon = "hunter",
		order = 3,
	},
	{
		id = "conductor",
		name = "Conductor",
		tagline = "The storm is an instrument.",
		description = "Capture mastery and chaining. The highest skill ceiling in the game and the highest payoff for reaching it.",
		color = "B9A6FF",
		icon = "conductor",
		order = 4,
	},
	{
		id = "survivor",
		name = "Survivor",
		tagline = "Go where the map says you cannot.",
		description = "Resistance and integrity. Survivors operate in regions that kill everyone else on contact.",
		color = "FF8AE8",
		icon = "survivor",
		order = 5,
	},
	{
		id = "gambler",
		name = "Gambler",
		tagline = "Bank it or double it.",
		description = "Risk multipliers and volatile payouts. Enormous ceilings, brutal floors, no middle ground.",
		color = "FFE24F",
		icon = "gambler",
		order = 6,
	},
	{
		id = "support",
		name = "Conduit",
		tagline = "Everyone runs further when you are here.",
		description = "Team auras, revives and shared banking. The build that makes a server want you online.",
		color = "37F0A8",
		icon = "support",
		order = 7,
	},
}

-- ============================================================================
-- Nodes
-- ============================================================================

SkillTree.Nodes = {

	-- ================================================================ RUNNER
	{
		id = "runner_fleet",
		branch = "runner",
		tier = 1,
		position = { x = 2, y = 1 },
		name = "Fleet",
		kind = "stat",
		description = "Raw movement speed. The foundation of everything else in this branch.",
		maxRank = 5,
		costPerRank = 1,
		effects = { flat = { moveSpeed = 0.5, sprintSpeed = 1.1 } },
		requires = {},
	},
	{
		id = "runner_light_frame",
		branch = "runner",
		tier = 1,
		position = { x = 3, y = 1 },
		name = "Light Frame",
		kind = "stat",
		description = "A full cell slows you far less.",
		maxRank = 4,
		costPerRank = 1,
		effects = { flat = { carryPenaltyResist = 0.07 } },
		requires = {},
	},
	{
		id = "runner_kinetic_jump",
		branch = "runner",
		tier = 2,
		position = { x = 2, y = 2 },
		name = "Kinetic Jump",
		kind = "traversal",
		description = "A second launch in mid-air. Capturing a strike resets it.",
		maxRank = 1,
		costPerRank = 2,
		grantsTraversal = "double_jump",
		requires = { { id = "runner_fleet", rank = 3 } },
	},
	{
		id = "runner_momentum",
		branch = "runner",
		tier = 2,
		position = { x = 3, y = 2 },
		name = "Momentum Capture",
		kind = "passive",
		description = "Capturing while sprinting stacks a speed bonus.",
		maxRank = 1,
		costPerRank = 2,
		grantsPassive = "momentum_capture",
		requires = { { id = "runner_light_frame", rank = 2 } },
	},
	{
		id = "runner_surge",
		branch = "runner",
		tier = 3,
		position = { x = 1, y = 3 },
		name = "Surge",
		kind = "ability",
		description = "Burn carried energy for a burst of speed.",
		maxRank = 1,
		costPerRank = 3,
		grantsAbility = "surge",
		requires = { { id = "runner_kinetic_jump", rank = 1 } },
	},
	{
		id = "runner_air_dash",
		branch = "runner",
		tier = 3,
		position = { x = 2, y = 3 },
		name = "Air Dash",
		kind = "traversal",
		description = "A flat mid-air burst in any direction. Also dodges.",
		maxRank = 1,
		costPerRank = 3,
		grantsTraversal = "air_dash",
		requires = { { id = "runner_kinetic_jump", rank = 1 } },
	},
	{
		id = "runner_recovery",
		branch = "runner",
		tier = 3,
		position = { x = 3, y = 3 },
		name = "Quick Recovery",
		kind = "stat",
		description = "Ability cooldowns recharge faster.",
		maxRank = 4,
		costPerRank = 2,
		effects = { flat = { abilityCooldown = 0.045 } },
		requires = { { id = "runner_momentum", rank = 1 } },
	},
	{
		id = "runner_blink_step",
		branch = "runner",
		tier = 4,
		position = { x = 1, y = 4 },
		name = "Blink Step",
		kind = "ability",
		description = "Instantly relocate a short distance. Two charges.",
		maxRank = 1,
		costPerRank = 4,
		grantsAbility = "blink_step",
		requires = { { id = "runner_air_dash", rank = 1 } },
	},
	{
		id = "runner_line_walker",
		branch = "runner",
		tier = 4,
		position = { x = 3, y = 4 },
		name = "Line Walker",
		kind = "passive",
		description = "Rails and ziplines cost nothing and boost you on exit.",
		maxRank = 1,
		costPerRank = 3,
		grantsPassive = "line_walker",
		requires = { { id = "runner_recovery", rank = 2 } },
	},
	{
		id = "runner_second_wind",
		branch = "runner",
		tier = 4,
		position = { x = 2, y = 4 },
		name = "Second Wind",
		kind = "passive",
		description = "Dropping low restores a burst of integrity.",
		maxRank = 1,
		costPerRank = 3,
		grantsPassive = "second_wind",
		requires = { { id = "runner_surge", rank = 1 } },
	},
	{
		id = "runner_ks_featherweight",
		branch = "runner",
		tier = 5,
		position = { x = 1, y = 5 },
		name = "Featherweight",
		kind = "keystone",
		description = "Movement speed is massively increased and carry weight is irrelevant — but containment is halved.",
		maxRank = 1,
		costPerRank = 6,
		effects = {
			increased = { moveSpeed = 0.35, sprintSpeed = 0.35 },
			flat = { carryPenaltyResist = 1.0 },
			more = { capacity = -0.5 },
		},
		downside = "Containment capacity is halved.",
		requires = { { id = "runner_blink_step", rank = 1 } },
		exclusiveWith = { "vault_ks_deep_reserve" },
	},
	{
		id = "runner_ks_relentless",
		branch = "runner",
		tier = 5,
		position = { x = 3, y = 5 },
		name = "Relentless",
		kind = "keystone",
		description = "Every capture refreshes all ability cooldowns by two seconds. Standing still adds instability.",
		maxRank = 1,
		costPerRank = 6,
		effects = { flat = { abilityCooldown = 0.1 } },
		grantsBehaviour = "capture_refreshes_cooldowns",
		downside = "Instability rises while stationary.",
		requires = { { id = "runner_line_walker", rank = 1 }, { id = "runner_second_wind", rank = 1 } },
	},
	{
		id = "runner_mastery",
		branch = "runner",
		tier = 5,
		position = { x = 2, y = 5 },
		name = "Runner's Mastery",
		kind = "stat",
		description = "Deep investment in pure speed. Scales with every other movement source you own.",
		maxRank = 8,
		costPerRank = 3,
		effects = { increased = { moveSpeed = 0.03, sprintSpeed = 0.035, abilityCooldown = 0.0 } },
		requires = { { id = "runner_second_wind", rank = 1 } },
	},

	-- ================================================================= VAULT
	{
		id = "vault_reinforced",
		branch = "vault",
		tier = 1,
		position = { x = 2, y = 1 },
		name = "Reinforced Cell",
		kind = "stat",
		description = "More containment. The whole branch is downstream of this.",
		maxRank = 6,
		costPerRank = 1,
		effects = { flat = { capacity = 34 } },
		requires = {},
	},
	{
		id = "vault_dampers",
		branch = "vault",
		tier = 1,
		position = { x = 3, y = 1 },
		name = "Dampers",
		kind = "stat",
		description = "Instability climbs more slowly.",
		maxRank = 5,
		costPerRank = 1,
		effects = { flat = { instabilityResist = 0.028 } },
		requires = {},
	},
	{
		id = "vault_hardened",
		branch = "vault",
		tier = 2,
		position = { x = 2, y = 2 },
		name = "Hardened Plating",
		kind = "stat",
		description = "Integrity and shock resistance.",
		maxRank = 5,
		costPerRank = 2,
		effects = { flat = { maxHealth = 16, shockResist = 0.03 } },
		requires = { { id = "vault_reinforced", rank = 3 } },
	},
	{
		id = "vault_overflow",
		branch = "vault",
		tier = 2,
		position = { x = 3, y = 2 },
		name = "Overflow Reserve",
		kind = "passive",
		description = "Energy above capacity is held briefly instead of lost.",
		maxRank = 1,
		costPerRank = 2,
		grantsBehaviour = "overflow_reserve",
		requires = { { id = "vault_dampers", rank = 2 } },
	},
	{
		id = "vault_ground_anchor",
		branch = "vault",
		tier = 3,
		position = { x = 2, y = 3 },
		name = "Ground Anchor",
		kind = "ability",
		description = "Root yourself and draw every strike in range to you.",
		maxRank = 1,
		costPerRank = 3,
		grantsAbility = "ground_anchor",
		requires = { { id = "vault_hardened", rank = 2 } },
	},
	{
		id = "vault_high_stakes",
		branch = "vault",
		tier = 3,
		position = { x = 3, y = 3 },
		name = "High Stakes",
		kind = "passive",
		description = "Carrying above 80% capacity grants a large yield bonus.",
		maxRank = 1,
		costPerRank = 3,
		grantsPassive = "high_stakes",
		requires = { { id = "vault_overflow", rank = 1 } },
	},
	{
		id = "vault_bank_efficiency",
		branch = "vault",
		tier = 3,
		position = { x = 1, y = 3 },
		name = "Bulk Transfer",
		kind = "stat",
		description = "Large banks pay a higher rate.",
		maxRank = 5,
		costPerRank = 2,
		effects = { increased = { bankRate = 0.035 } },
		requires = { { id = "vault_reinforced", rank = 4 } },
	},
	{
		id = "vault_grounded_recovery",
		branch = "vault",
		tier = 4,
		position = { x = 1, y = 4 },
		name = "Grounded Recovery",
		kind = "passive",
		description = "Standing still drains instability rapidly.",
		maxRank = 1,
		costPerRank = 3,
		grantsPassive = "grounded_recovery",
		requires = { { id = "vault_bank_efficiency", rank = 3 } },
	},
	{
		id = "vault_loss_control",
		branch = "vault",
		tier = 4,
		position = { x = 3, y = 4 },
		name = "Loss Control",
		kind = "stat",
		description = "Keep far more of your carry when a run ends badly.",
		maxRank = 5,
		costPerRank = 3,
		effects = { flat = { lossProtection = 0.06, ventProtection = 0.07 } },
		requires = { { id = "vault_high_stakes", rank = 1 } },
	},
	{
		id = "vault_titan",
		branch = "vault",
		tier = 4,
		position = { x = 2, y = 4 },
		name = "Titan Frame",
		kind = "stat",
		description = "Enormous containment, at the cost of nothing but time.",
		maxRank = 6,
		costPerRank = 3,
		effects = { increased = { capacity = 0.05 } },
		requires = { { id = "vault_ground_anchor", rank = 1 } },
	},
	{
		id = "vault_ks_deep_reserve",
		branch = "vault",
		tier = 5,
		position = { x = 2, y = 5 },
		name = "Deep Reserve",
		kind = "keystone",
		description = "Containment is doubled. Movement speed is cut by a third and you cannot sprint above 90% fill.",
		maxRank = 1,
		costPerRank = 6,
		effects = { more = { capacity = 1.0 }, increased = { moveSpeed = -0.33, sprintSpeed = -0.33 } },
		downside = "No sprinting above 90% containment.",
		grantsBehaviour = "no_sprint_when_full",
		requires = { { id = "vault_titan", rank = 3 } },
		exclusiveWith = { "runner_ks_featherweight" },
	},
	{
		id = "vault_ks_immovable",
		branch = "vault",
		tier = 5,
		position = { x = 3, y = 5 },
		name = "Immovable",
		kind = "keystone",
		description = "Nothing knocks you back and exposure damage is halved. You can no longer jump.",
		maxRank = 1,
		costPerRank = 6,
		effects = { flat = { stormResist = 0.22 } },
		downside = "Jumping is disabled.",
		grantsBehaviour = "cannot_jump",
		requires = { { id = "vault_loss_control", rank = 3 } },
	},
	{
		id = "vault_mastery",
		branch = "vault",
		tier = 5,
		position = { x = 1, y = 5 },
		name = "Vault Mastery",
		kind = "stat",
		description = "Containment, resistance and bank rate together.",
		maxRank = 8,
		costPerRank = 3,
		effects = { increased = { capacity = 0.025, bankRate = 0.02 }, flat = { instabilityResist = 0.012 } },
		requires = { { id = "vault_grounded_recovery", rank = 1 } },
	},

	-- ================================================================ HUNTER
	{
		id = "hunter_survey",
		branch = "hunter",
		tier = 1,
		position = { x = 2, y = 1 },
		name = "Survey",
		kind = "stat",
		description = "Scan range. See more of the world at once.",
		maxRank = 6,
		costPerRank = 1,
		effects = { flat = { scanRange = 85 } },
		requires = {},
	},
	{
		id = "hunter_fortune",
		branch = "hunter",
		tier = 1,
		position = { x = 3, y = 1 },
		name = "Fortune",
		kind = "stat",
		description = "Every loot roll tilts toward higher rarities.",
		maxRank = 5,
		costPerRank = 1,
		effects = { flat = { luck = 0.14 } },
		requires = {},
	},
	{
		id = "hunter_scavenger",
		branch = "hunter",
		tier = 2,
		position = { x = 3, y = 2 },
		name = "Scavenger Instinct",
		kind = "passive",
		description = "Nearby undiscovered secrets produce an audio cue.",
		maxRank = 1,
		costPerRank = 2,
		grantsPassive = "scavenger_instinct",
		requires = { { id = "hunter_survey", rank = 3 } },
	},
	{
		id = "hunter_salvage",
		branch = "hunter",
		tier = 2,
		position = { x = 2, y = 2 },
		name = "Efficient Salvage",
		kind = "stat",
		description = "More materials from every source.",
		maxRank = 5,
		costPerRank = 2,
		effects = { increased = { resourceYield = 0.06 } },
		requires = { { id = "hunter_fortune", rank = 2 } },
	},
	{
		id = "hunter_scan_pulse",
		branch = "hunter",
		tier = 3,
		position = { x = 2, y = 3 },
		name = "Scan Pulse",
		kind = "ability",
		description = "Reveal everything in a wide radius, including secrets.",
		maxRank = 1,
		costPerRank = 3,
		grantsAbility = "scan_pulse",
		requires = { { id = "hunter_scavenger", rank = 1 } },
	},
	{
		id = "hunter_anomaly",
		branch = "hunter",
		tier = 3,
		position = { x = 3, y = 3 },
		name = "Anomaly Sense",
		kind = "stat",
		description = "Detect rare storms and anomalies the scanner would miss.",
		maxRank = 4,
		costPerRank = 3,
		effects = { flat = { rareDetection = 0.14 } },
		requires = { { id = "hunter_salvage", rank = 2 } },
	},
	{
		id = "hunter_deep_pockets",
		branch = "hunter",
		tier = 3,
		position = { x = 1, y = 3 },
		name = "Deep Pockets",
		kind = "passive",
		description = "Materials no longer consume inventory space.",
		maxRank = 1,
		costPerRank = 2,
		grantsPassive = "deep_pockets",
		requires = { { id = "hunter_survey", rank = 4 } },
	},
	{
		id = "hunter_storm_call",
		branch = "hunter",
		tier = 4,
		position = { x = 2, y = 4 },
		name = "Storm Call",
		kind = "ability",
		description = "Pull a distant cell to you and force it to discharge.",
		maxRank = 1,
		costPerRank = 4,
		grantsAbility = "storm_call",
		requires = { { id = "hunter_scan_pulse", rank = 1 } },
	},
	{
		id = "hunter_cartographer",
		branch = "hunter",
		tier = 4,
		position = { x = 1, y = 4 },
		name = "Cartographer",
		kind = "stat",
		description = "Discoveries pay far more, and the map remembers more of what you have seen.",
		maxRank = 4,
		costPerRank = 3,
		effects = { increased = { xpGain = 0.04 }, flat = { scanRange = 140 } },
		requires = { { id = "hunter_deep_pockets", rank = 1 } },
	},
	{
		id = "hunter_prospector",
		branch = "hunter",
		tier = 4,
		position = { x = 3, y = 4 },
		name = "Prospector",
		kind = "stat",
		description = "Rarity tilt on top of rarity tilt.",
		maxRank = 5,
		costPerRank = 3,
		effects = { flat = { luck = 0.3 }, increased = { resourceYield = 0.04 } },
		requires = { { id = "hunter_anomaly", rank = 2 } },
	},
	{
		id = "hunter_ks_treasure_sense",
		branch = "hunter",
		tier = 5,
		position = { x = 3, y = 5 },
		name = "Treasure Sense",
		kind = "keystone",
		description = "Every drop rolls twice and keeps the better result. Storm yield is reduced by a quarter.",
		maxRank = 1,
		costPerRank = 6,
		grantsBehaviour = "double_loot_roll",
		effects = { increased = { captureYield = -0.25 } },
		downside = "Capture yield reduced by 25%.",
		requires = { { id = "hunter_prospector", rank = 3 } },
	},
	{
		id = "hunter_ks_pathfinder",
		branch = "hunter",
		tier = 5,
		position = { x = 1, y = 5 },
		name = "Pathfinder",
		kind = "keystone",
		description = "The entire world map is revealed and rare storms broadcast globally. Your position is visible to every player.",
		maxRank = 1,
		costPerRank = 6,
		grantsBehaviour = "global_vision",
		effects = { flat = { rareDetection = 0.5, scanRange = 1200 } },
		downside = "Your location is public to the whole server.",
		requires = { { id = "hunter_cartographer", rank = 2 } },
	},
	{
		id = "hunter_mastery",
		branch = "hunter",
		tier = 5,
		position = { x = 2, y = 5 },
		name = "Hunter's Mastery",
		kind = "stat",
		description = "Fortune, salvage and detection together.",
		maxRank = 8,
		costPerRank = 3,
		effects = { flat = { luck = 0.16, rareDetection = 0.03 }, increased = { resourceYield = 0.02 } },
		requires = { { id = "hunter_storm_call", rank = 1 } },
	},

	-- ============================================================= CONDUCTOR
	{
		id = "conductor_timing",
		branch = "conductor",
		tier = 1,
		position = { x = 2, y = 1 },
		name = "Timing",
		kind = "stat",
		description = "A wider capture window on everything.",
		maxRank = 6,
		costPerRank = 1,
		effects = { increased = { captureWindow = 0.04 } },
		requires = {},
	},
	{
		id = "conductor_draw",
		branch = "conductor",
		tier = 1,
		position = { x = 3, y = 1 },
		name = "Deep Draw",
		kind = "stat",
		description = "More energy per capture.",
		maxRank = 6,
		costPerRank = 1,
		effects = { increased = { captureYield = 0.035 } },
		requires = {},
	},
	{
		id = "conductor_cold_start",
		branch = "conductor",
		tier = 2,
		position = { x = 1, y = 2 },
		name = "Cold Start",
		kind = "passive",
		description = "The first capture after banking is always Perfect.",
		maxRank = 1,
		costPerRank = 2,
		grantsPassive = "cold_start",
		requires = { { id = "conductor_timing", rank = 2 } },
	},
	{
		id = "conductor_reader",
		branch = "conductor",
		tier = 2,
		position = { x = 2, y = 2 },
		name = "Storm Reader",
		kind = "passive",
		description = "Telegraph timing is shown as a numeric countdown.",
		maxRank = 1,
		costPerRank = 2,
		grantsPassive = "storm_reader",
		requires = { { id = "conductor_timing", rank = 3 } },
	},
	{
		id = "conductor_chain_retention",
		branch = "conductor",
		tier = 2,
		position = { x = 3, y = 2 },
		name = "Sustained Arc",
		kind = "stat",
		description = "Chains survive much longer without a capture.",
		maxRank = 5,
		costPerRank = 2,
		effects = { flat = { chainRetention = 0.22 } },
		requires = { { id = "conductor_draw", rank = 2 } },
	},
	{
		id = "conductor_chain_link",
		branch = "conductor",
		tier = 3,
		position = { x = 2, y = 3 },
		name = "Chain Link",
		kind = "ability",
		description = "Your next capture arcs to every strike point in range.",
		maxRank = 1,
		costPerRank = 3,
		grantsAbility = "chain_link",
		requires = { { id = "conductor_reader", rank = 1 } },
	},
	{
		id = "conductor_mark",
		branch = "conductor",
		tier = 3,
		position = { x = 3, y = 3 },
		name = "Conductor's Mark",
		kind = "passive",
		description = "Perfect captures mark a cell so every later capture from it pays more.",
		maxRank = 1,
		costPerRank = 3,
		grantsPassive = "conductor_mark",
		requires = { { id = "conductor_chain_retention", rank = 2 } },
	},
	{
		id = "conductor_static_cling",
		branch = "conductor",
		tier = 3,
		position = { x = 1, y = 3 },
		name = "Static Cling",
		kind = "passive",
		description = "Missed captures still recover a fifth of the energy.",
		maxRank = 1,
		costPerRank = 2,
		grantsPassive = "static_cling",
		requires = { { id = "conductor_cold_start", rank = 1 } },
	},
	{
		id = "conductor_siphon",
		branch = "conductor",
		tier = 4,
		position = { x = 1, y = 4 },
		name = "Siphon",
		kind = "ability",
		description = "Drain a cell directly without waiting for a strike.",
		maxRank = 1,
		costPerRank = 4,
		grantsAbility = "siphon",
		requires = { { id = "conductor_static_cling", rank = 1 } },
	},
	{
		id = "conductor_multi",
		branch = "conductor",
		tier = 4,
		position = { x = 2, y = 4 },
		name = "Split Draw",
		kind = "stat",
		description = "Hold additional strike points in your capture field at once.",
		maxRank = 3,
		costPerRank = 4,
		effects = { flat = { multiCapture = 1 } },
		requires = { { id = "conductor_chain_link", rank = 1 } },
	},
	{
		id = "conductor_overclock",
		branch = "conductor",
		tier = 4,
		position = { x = 3, y = 4 },
		name = "Overclock",
		kind = "ability",
		description = "Double yield, half window. Pure skill expression.",
		maxRank = 1,
		costPerRank = 4,
		grantsAbility = "overclock",
		requires = { { id = "conductor_mark", rank = 1 } },
	},
	{
		id = "conductor_ks_virtuoso",
		branch = "conductor",
		tier = 5,
		position = { x = 2, y = 5 },
		name = "Virtuoso",
		kind = "keystone",
		description = "Overcharge captures pay triple. Any grade below Good yields nothing at all.",
		maxRank = 1,
		costPerRank = 6,
		grantsBehaviour = "virtuoso_grading",
		downside = "Weak captures are worth zero.",
		requires = { { id = "conductor_multi", rank = 2 } },
	},
	{
		id = "conductor_ks_resonance",
		branch = "conductor",
		tier = 5,
		position = { x = 3, y = 5 },
		name = "Perfect Resonance",
		kind = "keystone",
		description = "Consecutive Perfect captures compound without limit. A single miss resets everything, including your chain.",
		maxRank = 1,
		costPerRank = 6,
		grantsBehaviour = "perfect_compounding",
		downside = "One miss resets the entire chain.",
		requires = { { id = "conductor_overclock", rank = 1 } },
	},
	{
		id = "conductor_mastery",
		branch = "conductor",
		tier = 5,
		position = { x = 1, y = 5 },
		name = "Conductor's Mastery",
		kind = "stat",
		description = "Window, yield and chain retention together.",
		maxRank = 8,
		costPerRank = 3,
		effects = { increased = { captureWindow = 0.018, captureYield = 0.022 }, flat = { chainRetention = 0.08 } },
		requires = { { id = "conductor_siphon", rank = 1 } },
	},

	-- ============================================================== SURVIVOR
	{
		id = "survivor_insulated",
		branch = "survivor",
		tier = 1,
		position = { x = 2, y = 1 },
		name = "Insulated",
		kind = "stat",
		description = "Storm resistance. Decides which regions you can stand in.",
		maxRank = 6,
		costPerRank = 1,
		effects = { flat = { stormResist = 0.026 } },
		requires = {},
	},
	{
		id = "survivor_constitution",
		branch = "survivor",
		tier = 1,
		position = { x = 3, y = 1 },
		name = "Constitution",
		kind = "stat",
		description = "Integrity and recovery rate.",
		maxRank = 6,
		costPerRank = 1,
		effects = { flat = { maxHealth = 22, healthRegen = 0.9 } },
		requires = {},
	},
	{
		id = "survivor_soles",
		branch = "survivor",
		tier = 2,
		position = { x = 1, y = 2 },
		name = "Insulated Soles",
		kind = "passive",
		description = "Conductive ground no longer amplifies damage.",
		maxRank = 1,
		costPerRank = 2,
		grantsPassive = "insulated_soles",
		requires = { { id = "survivor_insulated", rank = 2 } },
	},
	{
		id = "survivor_absorb",
		branch = "survivor",
		tier = 2,
		position = { x = 3, y = 2 },
		name = "Shock Absorption",
		kind = "stat",
		description = "Burst damage and fall damage both reduced.",
		maxRank = 5,
		costPerRank = 2,
		effects = { flat = { shockResist = 0.05, fallProtection = 0.08 } },
		requires = { { id = "survivor_constitution", rank = 3 } },
	},
	{
		id = "survivor_static_shield",
		branch = "survivor",
		tier = 3,
		position = { x = 2, y = 3 },
		name = "Static Shield",
		kind = "ability",
		description = "A field that absorbs damage and freezes instability.",
		maxRank = 1,
		costPerRank = 3,
		grantsAbility = "static_shield",
		requires = { { id = "survivor_insulated", rank = 4 } },
	},
	{
		id = "survivor_regeneration",
		branch = "survivor",
		tier = 3,
		position = { x = 3, y = 3 },
		name = "Field Regeneration",
		kind = "stat",
		description = "Recover integrity considerably faster, and sooner.",
		maxRank = 5,
		costPerRank = 2,
		effects = { flat = { healthRegen = 2.4 } },
		requires = { { id = "survivor_absorb", rank = 2 } },
	},
	{
		id = "survivor_hardy",
		branch = "survivor",
		tier = 3,
		position = { x = 1, y = 3 },
		name = "Hardy",
		kind = "stat",
		description = "Flat integrity, the least glamorous and most reliable investment available.",
		maxRank = 6,
		costPerRank = 2,
		effects = { flat = { maxHealth = 34 } },
		requires = { { id = "survivor_soles", rank = 1 } },
	},
	{
		id = "survivor_bulwark",
		branch = "survivor",
		tier = 4,
		position = { x = 2, y = 4 },
		name = "Bulwark Stance",
		kind = "ability",
		description = "Root yourself and slash incoming damage.",
		maxRank = 1,
		costPerRank = 4,
		grantsAbility = "bulwark_stance",
		requires = { { id = "survivor_static_shield", rank = 1 } },
	},
	{
		id = "survivor_deep_rated",
		branch = "survivor",
		tier = 4,
		position = { x = 1, y = 4 },
		name = "Deep Rated",
		kind = "stat",
		description = "Resistance high enough to make hostile regions routine.",
		maxRank = 5,
		costPerRank = 3,
		effects = { flat = { stormResist = 0.038 } },
		requires = { { id = "survivor_hardy", rank = 3 } },
	},
	{
		id = "survivor_vent_control",
		branch = "survivor",
		tier = 4,
		position = { x = 3, y = 4 },
		name = "Vent Control",
		kind = "stat",
		description = "Venting costs far less and staggers you far less.",
		maxRank = 4,
		costPerRank = 3,
		effects = { flat = { ventProtection = 0.11 } },
		requires = { { id = "survivor_regeneration", rank = 2 } },
	},
	{
		id = "survivor_ks_unkillable",
		branch = "survivor",
		tier = 5,
		position = { x = 1, y = 5 },
		name = "Unkillable",
		kind = "keystone",
		description = "Lethal damage leaves you at one integrity once every two minutes. All healing is halved.",
		maxRank = 1,
		costPerRank = 6,
		grantsBehaviour = "cheat_death",
		effects = { increased = { healthRegen = -0.5 } },
		downside = "Healing effectiveness is halved.",
		requires = { { id = "survivor_deep_rated", rank = 3 } },
	},
	{
		id = "survivor_ks_stormborn",
		branch = "survivor",
		tier = 5,
		position = { x = 3, y = 5 },
		name = "Stormborn",
		kind = "keystone",
		description = "Exposure damage heals you instead of hurting you. Bank stations no longer restore integrity.",
		maxRank = 1,
		costPerRank = 6,
		grantsBehaviour = "exposure_heals",
		downside = "Banking no longer heals you.",
		requires = { { id = "survivor_vent_control", rank = 2 } },
	},
	{
		id = "survivor_mastery",
		branch = "survivor",
		tier = 5,
		position = { x = 2, y = 5 },
		name = "Survivor's Mastery",
		kind = "stat",
		description = "Resistance, integrity and recovery together.",
		maxRank = 8,
		costPerRank = 3,
		effects = { flat = { stormResist = 0.014, maxHealth = 20, healthRegen = 0.7 } },
		requires = { { id = "survivor_bulwark", rank = 1 } },
	},

	-- =============================================================== GAMBLER
	{
		id = "gambler_edge",
		branch = "gambler",
		tier = 1,
		position = { x = 2, y = 1 },
		name = "Edge",
		kind = "stat",
		description = "Amplifies the risk multiplier earned from long chains.",
		maxRank = 6,
		costPerRank = 1,
		effects = { increased = { riskBonus = 0.05 } },
		requires = {},
	},
	{
		id = "gambler_nerve",
		branch = "gambler",
		tier = 1,
		position = { x = 3, y = 1 },
		name = "Nerve",
		kind = "stat",
		description = "Chains last longer, giving you room to push one more.",
		maxRank = 5,
		costPerRank = 1,
		effects = { flat = { chainRetention = 0.18 } },
		requires = {},
	},
	{
		id = "gambler_luck",
		branch = "gambler",
		tier = 2,
		position = { x = 3, y = 2 },
		name = "Gambler's Luck",
		kind = "passive",
		description = "Failed gambles refund part of what they cost.",
		maxRank = 1,
		costPerRank = 2,
		grantsPassive = "gamblers_luck",
		requires = { { id = "gambler_nerve", rank = 2 } },
	},
	{
		id = "gambler_greed",
		branch = "gambler",
		tier = 2,
		position = { x = 2, y = 2 },
		name = "Greed",
		kind = "stat",
		description = "Bank rate scales with how long your chain has run.",
		maxRank = 5,
		costPerRank = 2,
		effects = { increased = { bankRate = 0.04 } },
		requires = { { id = "gambler_edge", rank = 3 } },
	},
	{
		id = "gambler_double_down",
		branch = "gambler",
		tier = 3,
		position = { x = 2, y = 3 },
		name = "Double Down",
		kind = "ability",
		description = "Stake your carry on landing a Perfect capture.",
		maxRank = 1,
		costPerRank = 3,
		grantsAbility = "double_down",
		requires = { { id = "gambler_greed", rank = 2 } },
	},
	{
		id = "gambler_brinkmanship",
		branch = "gambler",
		tier = 3,
		position = { x = 3, y = 3 },
		name = "Brinkmanship",
		kind = "stat",
		description = "Yield rises the closer your instability is to critical.",
		maxRank = 4,
		costPerRank = 3,
		effects = { increased = { captureYield = 0.05 } },
		grantsBehaviour = "instability_yield_scaling",
		requires = { { id = "gambler_luck", rank = 1 } },
	},
	{
		id = "gambler_hot_hand",
		branch = "gambler",
		tier = 3,
		position = { x = 1, y = 3 },
		name = "Hot Hand",
		kind = "stat",
		description = "Fortune and experience scale with your current multiplier.",
		maxRank = 4,
		costPerRank = 2,
		effects = { flat = { luck = 0.2 }, increased = { xpGain = 0.05 } },
		requires = { { id = "gambler_edge", rank = 4 } },
	},
	{
		id = "gambler_all_in",
		branch = "gambler",
		tier = 4,
		position = { x = 2, y = 4 },
		name = "All In",
		kind = "stat",
		description = "The risk multiplier soft cap is raised substantially.",
		maxRank = 5,
		costPerRank = 4,
		effects = { increased = { riskBonus = 0.07 } },
		grantsBehaviour = "raised_chain_cap",
		requires = { { id = "gambler_double_down", rank = 1 } },
	},
	{
		id = "gambler_unbroken",
		branch = "gambler",
		tier = 4,
		position = { x = 1, y = 4 },
		name = "Unbroken",
		kind = "passive",
		description = "Your chain survives death once per run.",
		maxRank = 1,
		costPerRank = 4,
		grantsPassive = "unbroken",
		requires = { { id = "gambler_hot_hand", rank = 2 } },
	},
	{
		id = "gambler_windfall",
		branch = "gambler",
		tier = 4,
		position = { x = 3, y = 4 },
		name = "Windfall",
		kind = "stat",
		description = "Banking has a chance to pay double outright.",
		maxRank = 4,
		costPerRank = 4,
		effects = { flat = { luck = 0.18 } },
		grantsBehaviour = "bank_crit",
		requires = { { id = "gambler_brinkmanship", rank = 2 } },
	},
	{
		id = "gambler_ks_everything",
		branch = "gambler",
		tier = 5,
		position = { x = 2, y = 5 },
		name = "Everything On Red",
		kind = "keystone",
		description = "Risk multipliers are doubled. Death takes your entire carry with no cache and no protection.",
		maxRank = 1,
		costPerRank = 6,
		effects = { more = { riskBonus = 1.0 }, flat = { lossProtection = -1.0 } },
		grantsBehaviour = "total_loss_on_death",
		downside = "Death costs you everything.",
		requires = { { id = "gambler_all_in", rank = 3 } },
	},
	{
		id = "gambler_ks_house_edge",
		branch = "gambler",
		tier = 5,
		position = { x = 3, y = 5 },
		name = "House Edge",
		kind = "keystone",
		description = "Every bank is a coin flip: half pay triple, half pay nothing. Chains are unaffected either way.",
		maxRank = 1,
		costPerRank = 6,
		grantsBehaviour = "coinflip_bank",
		downside = "Half of all banks pay nothing.",
		requires = { { id = "gambler_windfall", rank = 2 } },
	},
	{
		id = "gambler_mastery",
		branch = "gambler",
		tier = 5,
		position = { x = 1, y = 5 },
		name = "Gambler's Mastery",
		kind = "stat",
		description = "Risk, fortune and chain retention together.",
		maxRank = 8,
		costPerRank = 3,
		effects = { increased = { riskBonus = 0.03 }, flat = { luck = 0.1, chainRetention = 0.06 } },
		requires = { { id = "gambler_unbroken", rank = 1 } },
	},

	-- =============================================================== SUPPORT
	{
		id = "support_presence",
		branch = "support",
		tier = 1,
		position = { x = 2, y = 1 },
		name = "Presence",
		kind = "stat",
		description = "The strength and reach of everything you project onto nearby runners.",
		maxRank = 6,
		costPerRank = 1,
		effects = { flat = { teamAura = 0.16 } },
		requires = {},
	},
	{
		id = "support_field_medicine",
		branch = "support",
		tier = 1,
		position = { x = 3, y = 1 },
		name = "Field Medicine",
		kind = "stat",
		description = "Revive downed runners far faster.",
		maxRank = 5,
		costPerRank = 1,
		effects = { flat = { reviveSpeed = 0.24 } },
		requires = {},
	},
	{
		id = "support_opportunist",
		branch = "support",
		tier = 2,
		position = { x = 1, y = 2 },
		name = "Opportunist",
		kind = "passive",
		description = "Capturing near another runner benefits both of you.",
		maxRank = 1,
		costPerRank = 2,
		grantsPassive = "opportunist",
		requires = { { id = "support_presence", rank = 2 } },
	},
	{
		id = "support_shared_scan",
		branch = "support",
		tier = 2,
		position = { x = 3, y = 2 },
		name = "Shared Survey",
		kind = "stat",
		description = "Your scan data is broadcast to everyone near you.",
		maxRank = 4,
		costPerRank = 2,
		effects = { flat = { scanRange = 90, teamAura = 0.1 } },
		grantsBehaviour = "share_scan",
		requires = { { id = "support_field_medicine", rank = 2 } },
	},
	{
		id = "support_relay_beacon",
		branch = "support",
		tier = 3,
		position = { x = 2, y = 3 },
		name = "Relay Beacon",
		kind = "ability",
		description = "A beacon that lets everyone nearby bank remotely.",
		maxRank = 1,
		costPerRank = 3,
		grantsAbility = "beacon",
		requires = { { id = "support_presence", rank = 4 } },
	},
	{
		id = "support_conduit",
		branch = "support",
		tier = 3,
		position = { x = 3, y = 3 },
		name = "Conduit",
		kind = "stat",
		description = "Nearby runners gain a share of your capture yield bonus.",
		maxRank = 5,
		costPerRank = 3,
		effects = { flat = { teamAura = 0.22 } },
		grantsBehaviour = "share_yield",
		requires = { { id = "support_shared_scan", rank = 2 } },
	},
	{
		id = "support_efficient",
		branch = "support",
		tier = 3,
		position = { x = 1, y = 3 },
		name = "Efficient Frame",
		kind = "passive",
		description = "Every ability recharges faster.",
		maxRank = 1,
		costPerRank = 3,
		grantsPassive = "efficient_frame",
		requires = { { id = "support_opportunist", rank = 1 } },
	},
	{
		id = "support_field_dome",
		branch = "support",
		tier = 4,
		position = { x = 2, y = 4 },
		name = "Field Dome",
		kind = "ability",
		description = "A dome that suppresses instability and exposure for the whole group.",
		maxRank = 1,
		costPerRank = 4,
		grantsAbility = "field_dome",
		requires = { { id = "support_relay_beacon", rank = 1 } },
	},
	{
		id = "support_guardian",
		branch = "support",
		tier = 4,
		position = { x = 1, y = 4 },
		name = "Guardian",
		kind = "stat",
		description = "Nearby runners take reduced exposure damage.",
		maxRank = 5,
		costPerRank = 3,
		effects = { flat = { teamAura = 0.18, stormResist = 0.02 } },
		grantsBehaviour = "share_resist",
		requires = { { id = "support_efficient", rank = 1 } },
	},
	{
		id = "support_logistics",
		branch = "support",
		tier = 4,
		position = { x = 3, y = 4 },
		name = "Logistics",
		kind = "stat",
		description = "Everyone in your aura banks at a better rate, including you.",
		maxRank = 4,
		costPerRank = 4,
		effects = { increased = { bankRate = 0.03 }, flat = { teamAura = 0.14 } },
		grantsBehaviour = "share_bank_rate",
		requires = { { id = "support_conduit", rank = 2 } },
	},
	{
		id = "support_rally",
		branch = "support",
		tier = 5,
		position = { x = 1, y = 5 },
		name = "Rally",
		kind = "ability",
		description = "Revive everyone downed in range and boost the whole group.",
		maxRank = 1,
		costPerRank = 5,
		grantsAbility = "rally",
		requires = { { id = "support_guardian", rank = 3 } },
	},
	{
		id = "support_ks_lightning_rod",
		branch = "support",
		tier = 5,
		position = { x = 2, y = 5 },
		name = "Lightning Rod",
		kind = "keystone",
		description = "Every storm in the region targets you first, and your whole group captures from your telegraphs. You take double exposure damage.",
		maxRank = 1,
		costPerRank = 6,
		grantsBehaviour = "aggro_magnet_shared_capture",
		downside = "Exposure damage against you is doubled.",
		requires = { { id = "support_field_dome", rank = 1 } },
	},
	{
		id = "support_ks_selfless",
		branch = "support",
		tier = 5,
		position = { x = 3, y = 5 },
		name = "Selfless",
		kind = "keystone",
		description = "Your aura effects are tripled for everyone else and removed entirely for you.",
		maxRank = 1,
		costPerRank = 6,
		effects = { more = { teamAura = 2.0 } },
		grantsBehaviour = "aura_excludes_self",
		downside = "You gain nothing from your own auras.",
		requires = { { id = "support_logistics", rank = 2 } },
	},
	{
		id = "support_mastery",
		branch = "support",
		tier = 5,
		position = { x = 4, y = 5 },
		name = "Conduit's Mastery",
		kind = "stat",
		description = "Aura strength, revive speed and bank rate together.",
		maxRank = 8,
		costPerRank = 3,
		effects = { flat = { teamAura = 0.1, reviveSpeed = 0.12 }, increased = { bankRate = 0.015 } },
		requires = { { id = "support_field_dome", rank = 1 } },
	},
}

-- ============================================================================
-- Lookups
-- ============================================================================

SkillTree.NodeById = {}
SkillTree.NodesByBranch = {}
SkillTree.BranchById = {}

for _, branch in ipairs(SkillTree.Branches) do
	SkillTree.BranchById[branch.id] = branch
	SkillTree.NodesByBranch[branch.id] = {}
end

for _, node in ipairs(SkillTree.Nodes) do
	SkillTree.NodeById[node.id] = node
	local branchNodes = SkillTree.NodesByBranch[node.branch]
	if branchNodes then
		table.insert(branchNodes, node.id)
	end
end

function SkillTree.GetNode(nodeId: string)
	return SkillTree.NodeById[nodeId]
end

--[[ Skill point cost to take `nodeId` from its current rank to the next. ]]
function SkillTree.GetRankCost(nodeId: string, currentRank: number): number
	local node = SkillTree.NodeById[nodeId]
	if not node or currentRank >= node.maxRank then
		return math.huge
	end
	-- Later ranks of a multi-rank node cost slightly more, so wide beats deep by default.
	return node.costPerRank + math.floor(currentRank / 3)
end

--[[
	Whether a node can be ranked up. Returns (ok, reasonKey, detail) so the UI can
	explain precisely what is blocking the purchase.
]]
function SkillTree.CanRankUp(nodeId: string, ranks: { [string]: number }, availablePoints: number): (boolean, string?, any)
	local node = SkillTree.NodeById[nodeId]
	if not node then
		return false, "unknown_node", nil
	end

	local currentRank = ranks[nodeId] or 0
	if currentRank >= node.maxRank then
		return false, "max_rank", node.maxRank
	end

	-- Exclusivity is checked before prerequisites: it is a permanent blocker, and
	-- telling the player "you already took the opposing keystone" is far more useful
	-- than telling them to go earn a prerequisite they can never spend.
	if node.exclusiveWith then
		for _, exclusiveId in ipairs(node.exclusiveWith) do
			if (ranks[exclusiveId] or 0) > 0 then
				return false, "mutually_exclusive", exclusiveId
			end
		end
	end

	for _, requirement in ipairs(node.requires) do
		if (ranks[requirement.id] or 0) < requirement.rank then
			return false, "missing_prerequisite", requirement
		end
	end

	local cost = SkillTree.GetRankCost(nodeId, currentRank)
	if availablePoints < cost then
		return false, "insufficient_points", cost
	end

	return true, nil, cost
end

--[[ Total points spent across a rank table. Used to validate saves and to refund. ]]
function SkillTree.GetSpentPoints(ranks: { [string]: number }): number
	local total = 0
	for nodeId, rank in pairs(ranks) do
		local node = SkillTree.NodeById[nodeId]
		if node then
			for r = 0, math.min(rank, node.maxRank) - 1 do
				total += SkillTree.GetRankCost(nodeId, r)
			end
		end
	end
	return total
end

--[[
	Validates a full rank table: every node exists, prerequisites are satisfied, no
	mutually exclusive pairs, no rank above max. Returns (ok, problems).
	Run on load so a tampered or migrated save cannot grant an impossible build.
]]
function SkillTree.ValidateRanks(ranks: { [string]: number }): (boolean, { string })
	local problems = {}
	for nodeId, rank in pairs(ranks) do
		local node = SkillTree.NodeById[nodeId]
		if not node then
			table.insert(problems, "unknown node: " .. tostring(nodeId))
			continue
		end
		if rank > node.maxRank then
			table.insert(problems, ("%s rank %d exceeds max %d"):format(nodeId, rank, node.maxRank))
		end
		if rank > 0 then
			for _, requirement in ipairs(node.requires) do
				if (ranks[requirement.id] or 0) < requirement.rank then
					table.insert(problems, ("%s requires %s rank %d"):format(nodeId, requirement.id, requirement.rank))
				end
			end
			if node.exclusiveWith then
				for _, exclusiveId in ipairs(node.exclusiveWith) do
					if (ranks[exclusiveId] or 0) > 0 then
						table.insert(problems, ("%s is exclusive with %s"):format(nodeId, exclusiveId))
					end
				end
			end
		end
	end
	return #problems == 0, problems
end

--[[ Applies every ranked node's effects into a stat accumulator. ]]
function SkillTree.ApplyToAccumulator(Stats: any, accumulator: any, ranks: { [string]: number })
	for nodeId, rank in pairs(ranks) do
		local node = SkillTree.NodeById[nodeId]
		if node and rank > 0 and node.effects then
			local effectiveRank = math.min(rank, node.maxRank)
			local label = node.name .. (node.maxRank > 1 and (" " .. effectiveRank) or "")
			for kind, effects in pairs(node.effects) do
				for statId, amount in pairs(effects) do
					Stats.Contribute(accumulator, statId, kind, amount * effectiveRank, label)
				end
			end
		end
	end
end

--[[ Everything a rank table grants: abilities, passives, traversal and behaviours. ]]
function SkillTree.CollectGrants(ranks: { [string]: number })
	local grants = {
		abilities = {},
		passives = {},
		traversal = {},
		behaviours = {},
	}
	for nodeId, rank in pairs(ranks) do
		local node = SkillTree.NodeById[nodeId]
		if node and rank > 0 then
			if node.grantsAbility then
				grants.abilities[node.grantsAbility] = true
			end
			if node.grantsPassive then
				grants.passives[node.grantsPassive] = true
			end
			if node.grantsTraversal then
				grants.traversal[node.grantsTraversal] = true
			end
			if node.grantsBehaviour then
				grants.behaviours[node.grantsBehaviour] = true
			end
		end
	end
	return grants
end

--[[
	Identifies a build's dominant specialisation for titles and profile display.
	Returns (branchId, spentInBranch, isHybrid).
]]
function SkillTree.GetSpecialisation(ranks: { [string]: number }): (string?, number, boolean)
	local perBranch = {}
	local total = 0
	for nodeId, rank in pairs(ranks) do
		local node = SkillTree.NodeById[nodeId]
		if node and rank > 0 then
			local spent = 0
			for r = 0, math.min(rank, node.maxRank) - 1 do
				spent += SkillTree.GetRankCost(nodeId, r)
			end
			perBranch[node.branch] = (perBranch[node.branch] or 0) + spent
			total += spent
		end
	end
	if total == 0 then
		return nil, 0, false
	end

	local bestBranch, bestSpent = nil, 0
	for branchId, spent in pairs(perBranch) do
		if spent > bestSpent then
			bestBranch, bestSpent = branchId, spent
		end
	end
	-- A build is a hybrid when its top branch holds less than 55% of total investment.
	local isHybrid = (bestSpent / total) < 0.55
	return bestBranch, bestSpent, isHybrid
end

return TableUtil.DeepFreeze(SkillTree)
