--!strict
--[[
	Equipment
	---------
	Six equipment slots and the base items that fill them.

	A dropped item is (base item) + (rolled rarity) + (rolled modifiers) + (optional
	trait). This file defines the bases and the sets; Modifiers.luau defines the affix
	pool and the unique traits. LootService assembles them.

	Design rules enforced here:
	  * Every slot has a viable option at every progression stage — no dead slots.
	  * Higher-tier bases are not strictly better; they trade. A tier-5 containment
	    with huge capacity and a movement penalty must lose to a tier-3 one for a
	    Runner build, or the "build" part of build-crafting is a lie.
	  * Named legendaries are recognisable by name, carry a fixed trait, and are worth
	    talking about in chat.
]]

local TableUtil = require(script.Parent.Parent.Core.TableUtil)

local Equipment = {}

-- ============================================================================
-- Slots
-- ============================================================================

Equipment.Slots = {
	{
		id = "capture_device",
		name = "Capture Device",
		short = "DEVICE",
		order = 1,
		icon = "slot_device",
		description = "How you take the energy. Window, radius and yield live here.",
	},
	{
		id = "containment",
		name = "Containment",
		short = "CELL",
		order = 2,
		icon = "slot_cell",
		description = "How much you can carry and how long it stays stable.",
	},
	{
		id = "plating",
		name = "Plating",
		short = "PLATE",
		order = 3,
		icon = "slot_plate",
		description = "Integrity and resistance. What lets you stand in worse weather.",
	},
	{
		id = "traversal",
		name = "Traversal Gear",
		short = "GEAR",
		order = 4,
		icon = "slot_gear",
		description = "Movement, cooldowns and load handling.",
	},
	{
		id = "scanner",
		name = "Scanner",
		short = "SCAN",
		order = 5,
		icon = "slot_scan",
		description = "Detection range, anomaly sensitivity and fortune.",
	},
	{
		id = "utility",
		name = "Utility",
		short = "UTIL",
		order = 6,
		icon = "slot_util",
		description = "The flexible slot. Economy, team effects, or a build's missing piece.",
	},
}

Equipment.SlotIds = {}
for _, slot in ipairs(Equipment.Slots) do
	table.insert(Equipment.SlotIds, slot.id)
end

-- ============================================================================
-- Base items
-- ============================================================================

Equipment.Bases = {

	-- -------------------------------------------------------- CAPTURE DEVICE
	{
		id = "dev_field_tap",
		name = "Field Tap",
		slot = "capture_device",
		tier = 1,
		minRarity = "common",
		maxRarity = "rare",
		requiredLevel = 1,
		baseStats = { flat = { captureRadius = 3 }, increased = { captureWindow = 0.04 } },
		flavour = "Standard issue. Every runner starts with one and most of them keep it too long.",
		dropRegions = { "starter_district", "storm_plains" },
		icon = "dev_tap",
	},
	{
		id = "dev_wide_array",
		name = "Wide Array",
		slot = "capture_device",
		tier = 2,
		minRarity = "common",
		maxRarity = "epic",
		requiredLevel = 10,
		baseStats = { flat = { captureRadius = 11 }, increased = { captureYield = -0.06 } },
		flavour = "Reach at the cost of draw. Favoured by anyone who has been struck once too often.",
		dropRegions = { "storm_plains", "industrial_grid" },
		icon = "dev_array",
	},
	{
		id = "dev_precision_lance",
		name = "Precision Lance",
		slot = "capture_device",
		tier = 2,
		minRarity = "uncommon",
		maxRarity = "epic",
		requiredLevel = 14,
		baseStats = { increased = { captureYield = 0.18, captureWindow = -0.12 }, flat = { captureRadius = -4 } },
		flavour = "Narrow, unforgiving, and it pays anyone who can actually use it.",
		dropRegions = { "industrial_grid", "city_region" },
		icon = "dev_lance",
	},
	{
		id = "dev_cascade_head",
		name = "Cascade Head",
		slot = "capture_device",
		tier = 3,
		minRarity = "uncommon",
		maxRarity = "legendary",
		requiredLevel = 26,
		baseStats = { flat = { chainRetention = 0.35, captureRadius = 5 }, increased = { captureWindow = 0.06 } },
		flavour = "Built for chains. Holds a sequence open long past where a Field Tap gives up.",
		dropRegions = { "city_region", "mountain_region" },
		icon = "dev_cascade",
	},
	{
		id = "dev_resonator",
		name = "Resonator",
		slot = "capture_device",
		tier = 4,
		minRarity = "rare",
		maxRarity = "legendary",
		requiredLevel = 40,
		baseStats = { increased = { captureWindow = 0.14, captureYield = 0.1 }, flat = { captureStability = 0.08 } },
		flavour = "Tuned to the storm rather than fighting it. Expensive, and worth it.",
		dropRegions = { "mountain_region", "electrical_wasteland", "underground_network" },
		icon = "dev_resonator",
	},
	{
		id = "dev_splitfield",
		name = "Splitfield Rig",
		slot = "capture_device",
		tier = 5,
		minRarity = "epic",
		maxRarity = "mythic",
		requiredLevel = 58,
		baseStats = { flat = { multiCapture = 1, captureRadius = 8 }, increased = { captureYield = -0.1 } },
		flavour = "Holds two strike points at once. The first time it works you will laugh.",
		dropRegions = { "underground_network", "high_altitude" },
		icon = "dev_split",
	},
	{
		id = "dev_core_conduit",
		name = "Core Conduit",
		slot = "capture_device",
		tier = 6,
		minRarity = "epic",
		maxRarity = "mythic",
		requiredLevel = 78,
		baseStats = {
			increased = { captureYield = 0.34, captureWindow = 0.1 },
			flat = { captureRadius = 10, multiCapture = 1 },
		},
		flavour = "Built from a filament that has not stopped moving since it was drawn.",
		dropRegions = { "storm_core" },
		icon = "dev_conduit",
	},

	-- ------------------------------------------------------------ CONTAINMENT
	{
		id = "cell_standard",
		name = "Standard Cell",
		slot = "containment",
		tier = 1,
		minRarity = "common",
		maxRarity = "rare",
		requiredLevel = 1,
		baseStats = { flat = { capacity = 30 } },
		flavour = "Does the job. Does not do anything else.",
		dropRegions = { "starter_district", "storm_plains" },
		icon = "cell_std",
	},
	{
		id = "cell_light",
		name = "Featherframe Cell",
		slot = "containment",
		tier = 2,
		minRarity = "common",
		maxRarity = "epic",
		requiredLevel = 12,
		baseStats = { flat = { capacity = 15, carryPenaltyResist = 0.2 }, increased = { moveSpeed = 0.05 } },
		flavour = "Small, and you barely notice it is there. Runners swear by these.",
		dropRegions = { "storm_plains", "city_region" },
		icon = "cell_light",
	},
	{
		id = "cell_bulk",
		name = "Bulk Reservoir",
		slot = "containment",
		tier = 2,
		minRarity = "uncommon",
		maxRarity = "epic",
		requiredLevel = 16,
		baseStats = { flat = { capacity = 95 }, increased = { moveSpeed = -0.09, sprintSpeed = -0.09 } },
		flavour = "Three times the volume and it moves like it. Vaults do not care.",
		dropRegions = { "industrial_grid", "city_region" },
		icon = "cell_bulk",
	},
	{
		id = "cell_damped",
		name = "Damped Cell",
		slot = "containment",
		tier = 3,
		minRarity = "uncommon",
		maxRarity = "legendary",
		requiredLevel = 28,
		baseStats = { flat = { capacity = 60, instabilityResist = 0.12 } },
		flavour = "Slows the climb. Buys you the one extra capture that decides a run.",
		dropRegions = { "city_region", "mountain_region", "underground_network" },
		icon = "cell_damped",
	},
	{
		id = "cell_layered",
		name = "Layered Containment",
		slot = "containment",
		tier = 4,
		minRarity = "rare",
		maxRarity = "legendary",
		requiredLevel = 44,
		baseStats = { flat = { capacity = 190, ventProtection = 0.15, instabilityResist = 0.06 } },
		flavour = "Nested chambers. When one fails the next one holds — usually.",
		dropRegions = { "electrical_wasteland", "underground_network" },
		icon = "cell_layered",
	},
	{
		id = "cell_skyframe",
		name = "Skyframe Cell",
		slot = "containment",
		tier = 5,
		minRarity = "epic",
		maxRarity = "mythic",
		requiredLevel = 62,
		baseStats = {
			flat = { capacity = 260, carryPenaltyResist = 0.35 },
			increased = { jumpPower = 0.12 },
		},
		flavour = "Skyiron construction. Enormous capacity that somehow still feels light.",
		dropRegions = { "high_altitude", "mountain_region" },
		icon = "cell_sky",
	},
	{
		id = "cell_singularity",
		name = "Singularity Chamber",
		slot = "containment",
		tier = 6,
		minRarity = "epic",
		maxRarity = "mythic",
		requiredLevel = 80,
		baseStats = {
			flat = { capacity = 520, instabilityResist = -0.1 },
			increased = { captureYield = 0.12 },
		},
		flavour = "It holds more than it should and it is angrier about it every second.",
		dropRegions = { "storm_core", "null_reach" },
		icon = "cell_singularity",
	},

	-- ---------------------------------------------------------------- PLATING
	{
		id = "plate_workwear",
		name = "Yard Workwear",
		slot = "plating",
		tier = 1,
		minRarity = "common",
		maxRarity = "rare",
		requiredLevel = 1,
		baseStats = { flat = { maxHealth = 20 } },
		flavour = "Not armour. Better than nothing.",
		dropRegions = { "starter_district", "storm_plains" },
		icon = "plate_work",
	},
	{
		id = "plate_lineman",
		name = "Lineman's Rig",
		slot = "plating",
		tier = 2,
		minRarity = "common",
		maxRarity = "epic",
		requiredLevel = 11,
		baseStats = { flat = { maxHealth = 45, shockResist = 0.08 } },
		flavour = "Designed for people who worked on live lines on purpose.",
		dropRegions = { "storm_plains", "industrial_grid" },
		icon = "plate_line",
	},
	{
		id = "plate_grounded",
		name = "Grounded Harness",
		slot = "plating",
		tier = 3,
		minRarity = "uncommon",
		maxRarity = "legendary",
		requiredLevel = 24,
		baseStats = { flat = { maxHealth = 60, stormResist = 0.07 }, increased = { moveSpeed = -0.04 } },
		flavour = "Trailing earth strap. Ugly, effective, and it drags.",
		dropRegions = { "industrial_grid", "city_region" },
		icon = "plate_ground",
	},
	{
		id = "plate_stormsuit",
		name = "Stormsuit",
		slot = "plating",
		tier = 4,
		minRarity = "rare",
		maxRarity = "legendary",
		requiredLevel = 42,
		baseStats = { flat = { maxHealth = 130, stormResist = 0.14, shockResist = 0.1 } },
		flavour = "The first thing anyone builds after their first trip to the Scour.",
		dropRegions = { "electrical_wasteland", "mountain_region" },
		icon = "plate_storm",
	},
	{
		id = "plate_deepshell",
		name = "Deepshell",
		slot = "plating",
		tier = 5,
		minRarity = "epic",
		maxRarity = "mythic",
		requiredLevel = 60,
		baseStats = {
			flat = { maxHealth = 240, stormResist = 0.2, healthRegen = 4 },
			increased = { sprintSpeed = -0.08 },
		},
		flavour = "Laboratory plate, recovered from a body that got most of the way out.",
		dropRegions = { "underground_network", "high_altitude" },
		icon = "plate_deep",
	},
	{
		id = "plate_corehide",
		name = "Corehide",
		slot = "plating",
		tier = 6,
		minRarity = "epic",
		maxRarity = "mythic",
		requiredLevel = 82,
		baseStats = { flat = { maxHealth = 420, stormResist = 0.3, shockResist = 0.2, healthRegen = 8 } },
		flavour = "Storm alloy, hammered flat. It hums against your ribs the whole time.",
		dropRegions = { "storm_core", "null_reach" },
		icon = "plate_core",
	},

	-- --------------------------------------------------------------- TRAVERSAL
	{
		id = "gear_boots",
		name = "Worn Treads",
		slot = "traversal",
		tier = 1,
		minRarity = "common",
		maxRarity = "rare",
		requiredLevel = 1,
		baseStats = { flat = { moveSpeed = 0.6 } },
		flavour = "Somebody put a lot of miles on these before you did.",
		dropRegions = { "starter_district", "storm_plains" },
		icon = "gear_boots",
	},
	{
		id = "gear_sprint_servos",
		name = "Sprint Servos",
		slot = "traversal",
		tier = 2,
		minRarity = "common",
		maxRarity = "epic",
		requiredLevel = 13,
		baseStats = { flat = { sprintSpeed = 3.5 }, increased = { abilityCooldown = 0.0 } },
		flavour = "Loud, fast, and they need rebuilding every few hundred kilometres.",
		dropRegions = { "storm_plains", "industrial_grid" },
		icon = "gear_servo",
	},
	{
		id = "gear_kinetic_frame",
		name = "Kinetic Frame",
		slot = "traversal",
		tier = 3,
		minRarity = "uncommon",
		maxRarity = "legendary",
		requiredLevel = 27,
		baseStats = { flat = { jumpPower = 9, fallProtection = 0.2, moveSpeed = 1.2 } },
		flavour = "Stores the energy of a landing and gives it back on the next jump.",
		dropRegions = { "city_region", "mountain_region" },
		icon = "gear_kinetic",
	},
	{
		id = "gear_recycler",
		name = "Cooldown Recycler",
		slot = "traversal",
		tier = 4,
		minRarity = "rare",
		maxRarity = "legendary",
		requiredLevel = 46,
		baseStats = { flat = { abilityCooldown = 0.14, carryPenaltyResist = 0.15 } },
		flavour = "Bleeds waste heat back into the ability bus. Everything recharges faster.",
		dropRegions = { "underground_network", "electrical_wasteland" },
		icon = "gear_recycle",
	},
	{
		id = "gear_updraft_wing",
		name = "Updraft Wing",
		slot = "traversal",
		tier = 5,
		minRarity = "epic",
		maxRarity = "mythic",
		requiredLevel = 64,
		baseStats = { flat = { jumpPower = 18, fallProtection = 0.6, moveSpeed = 2.4, sprintSpeed = 4 } },
		flavour = "Anchorage-built. Turns a fall into a decision instead of an outcome.",
		dropRegions = { "high_altitude" },
		icon = "gear_wing",
	},
	{
		id = "gear_phase_striders",
		name = "Phase Striders",
		slot = "traversal",
		tier = 6,
		minRarity = "epic",
		maxRarity = "exotic",
		requiredLevel = 84,
		baseStats = {
			flat = { moveSpeed = 4, sprintSpeed = 7, abilityCooldown = 0.2, carryPenaltyResist = 0.4 },
		},
		flavour = "Your feet arrive slightly before the rest of you does.",
		dropRegions = { "storm_core", "null_reach" },
		icon = "gear_phase",
	},

	-- ---------------------------------------------------------------- SCANNER
	{
		id = "scan_handheld",
		name = "Handheld Reader",
		slot = "scanner",
		tier = 1,
		minRarity = "common",
		maxRarity = "rare",
		requiredLevel = 1,
		baseStats = { flat = { scanRange = 80 } },
		flavour = "Beeps when weather is close. Beeps a lot in the Sattermarsh.",
		dropRegions = { "starter_district", "storm_plains" },
		icon = "scan_hand",
	},
	{
		id = "scan_survey",
		name = "Survey Unit",
		slot = "scanner",
		tier = 2,
		minRarity = "common",
		maxRarity = "epic",
		requiredLevel = 15,
		baseStats = { flat = { scanRange = 240, luck = 0.15 } },
		flavour = "Wide sweep. Finds the field before the field finds you.",
		dropRegions = { "storm_plains", "industrial_grid" },
		icon = "scan_survey",
	},
	{
		id = "scan_anomaly",
		name = "Anomaly Detector",
		slot = "scanner",
		tier = 3,
		minRarity = "uncommon",
		maxRarity = "legendary",
		requiredLevel = 30,
		baseStats = { flat = { rareDetection = 0.18, scanRange = 180 }, increased = { resourceYield = -0.05 } },
		flavour = "Ignores ordinary weather entirely. Only speaks up for the strange stuff.",
		dropRegions = { "city_region", "electrical_wasteland" },
		icon = "scan_anomaly",
	},
	{
		id = "scan_prospector",
		name = "Prospector's Lens",
		slot = "scanner",
		tier = 4,
		minRarity = "rare",
		maxRarity = "legendary",
		requiredLevel = 48,
		baseStats = { flat = { luck = 0.7, scanRange = 320 }, increased = { resourceYield = 0.18 } },
		flavour = "Does not find storms. Finds what storms leave behind.",
		dropRegions = { "mountain_region", "electrical_wasteland" },
		icon = "scan_prospect",
	},
	{
		id = "scan_deep_survey",
		name = "Deep Survey Array",
		slot = "scanner",
		tier = 5,
		minRarity = "epic",
		maxRarity = "mythic",
		requiredLevel = 66,
		baseStats = { flat = { scanRange = 900, rareDetection = 0.34, luck = 0.5 } },
		flavour = "Deepline built this to look at something specific. It never says what.",
		dropRegions = { "underground_network", "high_altitude" },
		icon = "scan_deep",
	},
	{
		id = "scan_eyeglass",
		name = "The Eyeglass",
		slot = "scanner",
		tier = 6,
		minRarity = "epic",
		maxRarity = "mythic",
		requiredLevel = 86,
		baseStats = { flat = { scanRange = 1800, rareDetection = 0.6, luck = 1.2 } },
		flavour = "Ground from a fragment. It shows you weather that has not happened yet.",
		dropRegions = { "storm_core", "null_reach" },
		icon = "scan_eye",
	},

	-- ---------------------------------------------------------------- UTILITY
	{
		id = "util_ledger",
		name = "Bank Ledger",
		slot = "utility",
		tier = 1,
		minRarity = "common",
		maxRarity = "epic",
		requiredLevel = 4,
		baseStats = { increased = { bankRate = 0.06 } },
		flavour = "Tracks what you owe yourself. Improves the exchange rate at every tap.",
		dropRegions = { "starter_district", "storm_plains", "industrial_grid" },
		icon = "util_ledger",
	},
	{
		id = "util_salvage_arm",
		name = "Salvage Arm",
		slot = "utility",
		tier = 2,
		minRarity = "common",
		maxRarity = "epic",
		requiredLevel = 18,
		baseStats = { increased = { resourceYield = 0.16 }, flat = { luck = 0.1 } },
		flavour = "An extra hand that only knows how to take things apart.",
		dropRegions = { "industrial_grid", "city_region" },
		icon = "util_arm",
	},
	{
		id = "util_relay_node",
		name = "Relay Node",
		slot = "utility",
		tier = 3,
		minRarity = "uncommon",
		maxRarity = "legendary",
		requiredLevel = 32,
		baseStats = { flat = { teamAura = 0.3, reviveSpeed = 0.4 } },
		flavour = "Broadcasts a little of whatever you have to everyone standing near you.",
		dropRegions = { "city_region", "underground_network" },
		icon = "util_relay",
	},
	{
		id = "util_risk_governor",
		name = "Risk Governor",
		slot = "utility",
		tier = 4,
		minRarity = "rare",
		maxRarity = "legendary",
		requiredLevel = 50,
		baseStats = { increased = { riskBonus = 0.2 }, flat = { chainRetention = 0.3, lossProtection = -0.1 } },
		flavour = "Removes a safety limiter that was there for a reason.",
		dropRegions = { "electrical_wasteland", "high_altitude" },
		icon = "util_risk",
	},
	{
		id = "util_field_workbench",
		name = "Field Workbench",
		slot = "utility",
		tier = 5,
		minRarity = "epic",
		maxRarity = "mythic",
		requiredLevel = 68,
		baseStats = { flat = { craftQuality = 0.6 }, increased = { resourceYield = 0.3 } },
		flavour = "Craft anywhere. Trades a combat slot for never walking home again.",
		dropRegions = { "underground_network", "high_altitude" },
		icon = "util_bench",
	},
	{
		id = "util_sigil_anchor",
		name = "Sigil Anchor",
		slot = "utility",
		tier = 6,
		minRarity = "legendary",
		maxRarity = "exotic",
		requiredLevel = 90,
		baseStats = {
			increased = { bankRate = 0.3, riskBonus = 0.3, xpGain = 0.2 },
			flat = { luck = 1.0 },
		},
		flavour = "Whatever prestige is, this thing is made of it.",
		dropRegions = { "null_reach" },
		icon = "util_sigil",
	},
}

-- ============================================================================
-- Named uniques. These never roll random bases; they drop whole, with a fixed
-- trait, and they are meant to be recognised by name in chat.
-- ============================================================================

Equipment.Uniques = {
	{
		id = "unique_halworth_relic",
		name = "The Halworth Relic",
		slot = "capture_device",
		rarity = "legendary",
		tier = 2,
		requiredLevel = 15,
		baseStats = { increased = { captureWindow = 0.3 }, flat = { captureRadius = 6 } },
		trait = "trait_first_light",
		flavour = "The tap the station chief was holding when the first storm came through. Still works.",
		dropSource = { type = "boss", id = "halworth_anomaly" },
		icon = "unique_relic",
	},
	{
		id = "unique_stiltmoor_lantern",
		name = "Stiltmoor Lantern",
		slot = "scanner",
		rarity = "legendary",
		tier = 2,
		requiredLevel = 18,
		baseStats = { flat = { scanRange = 520, rareDetection = 0.22 } },
		trait = "trait_marsh_sight",
		flavour = "The fishers hung these to see weather coming across the flats. This one still does.",
		dropSource = { type = "discovery", id = "stiltmoor_deep_cache" },
		icon = "unique_lantern",
	},
	{
		id = "unique_third_rail",
		name = "Third Rail",
		slot = "traversal",
		rarity = "legendary",
		tier = 3,
		requiredLevel = 30,
		baseStats = { flat = { sprintSpeed = 8, moveSpeed = 2.5 } },
		trait = "trait_live_current",
		flavour = "Recovered from the Grid express line. Whoever wore these did not need the rails.",
		dropSource = { type = "quest", id = "grid_third_rail" },
		icon = "unique_rail",
	},
	{
		id = "unique_spire_crown",
		name = "The Spire Crown",
		slot = "plating",
		rarity = "legendary",
		tier = 4,
		requiredLevel = 38,
		baseStats = { flat = { maxHealth = 150, stormResist = 0.18, shockResist = 0.15 } },
		trait = "trait_lightning_rod",
		flavour = "Taken from the top of Verrick Spire, which is struck every ninety seconds without fail.",
		dropSource = { type = "boss", id = "spire_conductor_prime" },
		icon = "unique_crown",
	},
	{
		id = "unique_watchers_eye",
		name = "The Watcher's Eye",
		slot = "scanner",
		rarity = "mythic",
		tier = 5,
		requiredLevel = 55,
		baseStats = { flat = { scanRange = 1200, rareDetection = 0.5, luck = 1.4 } },
		trait = "trait_precognition",
		flavour = "Whoever sat in the Observatory was not watching the storms. They were watching for one.",
		dropSource = { type = "quest", id = "mountain_what_the_watcher_saw" },
		icon = "unique_watcher",
	},
	{
		id = "unique_origin_shard",
		name = "Origin Shard",
		slot = "containment",
		rarity = "mythic",
		tier = 5,
		requiredLevel = 58,
		baseStats = { flat = { capacity = 340, instabilityResist = 0.2 } },
		trait = "trait_origin_stability",
		flavour = "Cut from the exact centre of the crater. It is the only calm thing in the Scour.",
		dropSource = { type = "discovery", id = "scour_crater_floor" },
		icon = "unique_origin",
	},
	{
		id = "unique_prototype_eleven",
		name = "Prototype Eleven",
		slot = "capture_device",
		rarity = "mythic",
		tier = 5,
		requiredLevel = 62,
		baseStats = { increased = { captureYield = 0.4 }, flat = { multiCapture = 1, captureStability = 0.15 } },
		trait = "trait_lab_override",
		flavour = "Deepline built eleven. This is the one they finished.",
		dropSource = { type = "boss", id = "deepline_containment_prime" },
		icon = "unique_proto",
	},
	{
		id = "unique_anchorage_wing",
		name = "Anchorage Wing",
		slot = "traversal",
		rarity = "mythic",
		tier = 6,
		requiredLevel = 70,
		baseStats = { flat = { jumpPower = 26, fallProtection = 0.9, moveSpeed = 5, sprintSpeed = 8 } },
		trait = "trait_never_falls",
		flavour = "Salvaged from Station Six, which is still adrift, and still transmitting.",
		dropSource = { type = "discovery", id = "station_six_interior" },
		icon = "unique_wing",
	},
	{
		id = "unique_eye_of_the_storm",
		name = "Eye of the Storm",
		slot = "containment",
		rarity = "exotic",
		tier = 7,
		requiredLevel = 90,
		baseStats = { flat = { capacity = 700, instabilityResist = 0.35 }, increased = { captureYield = 0.25 } },
		trait = "trait_the_calm",
		flavour = "It does not contain the energy. It convinces it to stay.",
		dropSource = { type = "boss", id = "the_eye_encounter" },
		icon = "unique_eyestorm",
	},
	{
		id = "unique_borrowed_time",
		name = "Borrowed Time",
		slot = "utility",
		rarity = "exotic",
		tier = 7,
		requiredLevel = 95,
		baseStats = { increased = { riskBonus = 0.5, bankRate = 0.25 }, flat = { chainRetention = 1.0 } },
		trait = "trait_borrowed",
		flavour = "Every runner who has held this has said the same thing: it feels like it is counting.",
		dropSource = { type = "prestige", rank = 1 },
		icon = "unique_borrowed",
	},
}

-- ============================================================================
-- Sets. Wearing multiple pieces from a set grants escalating bonuses.
-- ============================================================================

Equipment.Sets = {
	{
		id = "set_lineman",
		name = "Lineman's Kit",
		description = "For people who worked the live lines before any of this started.",
		pieces = { "plate_lineman", "gear_sprint_servos", "util_ledger" },
		bonuses = {
			[2] = { name = "Steady Hands", effects = { flat = { shockResist = 0.08 } } },
			[3] = { name = "Line Discipline", effects = { increased = { bankRate = 0.12 }, flat = { captureStability = 0.1 } } },
		},
	},
	{
		id = "set_prospector",
		name = "Prospector's Load",
		description = "Everything a scavenger needs and nothing that helps in a fight.",
		pieces = { "scan_prospector", "util_salvage_arm", "cell_bulk" },
		bonuses = {
			[2] = { name = "Keen Eye", effects = { flat = { luck = 0.3 } } },
			[3] = { name = "Full Haul", effects = { increased = { resourceYield = 0.35 }, flat = { capacity = 60 } } },
		},
	},
	{
		id = "set_stormrunner",
		name = "Stormrunner",
		description = "Light, fast, and built to leave before the weather closes.",
		pieces = { "cell_light", "gear_kinetic_frame", "dev_precision_lance" },
		bonuses = {
			[2] = { name = "Light Step", effects = { increased = { moveSpeed = 0.08 } } },
			[3] = { name = "In and Out", effects = { increased = { sprintSpeed = 0.14, bankRate = 0.15 }, flat = { abilityCooldown = 0.1 } } },
		},
	},
	{
		id = "set_deepline",
		name = "Deepline Issue",
		description = "Laboratory equipment that was never meant to leave the facility.",
		pieces = { "plate_deepshell", "scan_deep_survey", "gear_recycler", "util_field_workbench" },
		bonuses = {
			[2] = { name = "Facility Access", effects = { flat = { stormResist = 0.06 } } },
			[3] = { name = "Research Grade", effects = { flat = { rareDetection = 0.15, craftQuality = 0.4 } } },
			[4] = { name = "Prototype Clearance", effects = { increased = { captureYield = 0.2, resourceYield = 0.25 }, flat = { luck = 0.6 } } },
		},
	},
	{
		id = "set_corebound",
		name = "Corebound",
		description = "Forged from the storm rather than against it.",
		pieces = { "dev_core_conduit", "cell_singularity", "plate_corehide", "gear_phase_striders" },
		bonuses = {
			[2] = { name = "Acclimatised", effects = { flat = { stormResist = 0.1 } } },
			[3] = { name = "Core Resonance", effects = { increased = { captureYield = 0.18, captureWindow = 0.08 } } },
			[4] = { name = "Of the Storm", effects = { increased = { capacity = 0.25, riskBonus = 0.3 }, flat = { instabilityResist = 0.15 } } },
		},
	},
}

-- ============================================================================
-- Lookups and helpers
-- ============================================================================

Equipment.SlotById = {}
for _, slot in ipairs(Equipment.Slots) do
	Equipment.SlotById[slot.id] = slot
end

Equipment.BaseById = {}
Equipment.BasesBySlot = {}
for _, base in ipairs(Equipment.Bases) do
	Equipment.BaseById[base.id] = base
	Equipment.BasesBySlot[base.slot] = Equipment.BasesBySlot[base.slot] or {}
	table.insert(Equipment.BasesBySlot[base.slot], base.id)
end

Equipment.UniqueById = {}
for _, unique in ipairs(Equipment.Uniques) do
	Equipment.UniqueById[unique.id] = unique
end

Equipment.SetById = {}
Equipment.SetByPiece = {}
for _, set in ipairs(Equipment.Sets) do
	Equipment.SetById[set.id] = set
	for _, pieceId in ipairs(set.pieces) do
		Equipment.SetByPiece[pieceId] = set.id
	end
end

--[[ Resolves a base id from either the base table or the uniques table. ]]
function Equipment.GetDefinition(baseId: string)
	return Equipment.BaseById[baseId] or Equipment.UniqueById[baseId]
end

--[[ Base ids that can drop in a region at or below the player's level. ]]
function Equipment.GetDropPool(regionId: string, playerLevel: number): { string }
	local pool = {}
	for _, base in ipairs(Equipment.Bases) do
		if base.requiredLevel <= playerLevel then
			for _, dropRegion in ipairs(base.dropRegions) do
				if dropRegion == regionId then
					table.insert(pool, base.id)
					break
				end
			end
		end
	end
	return pool
end

--[[
	Set bonuses active for a given list of equipped base ids.
	Returns an array of { setId, setName, tier, bonus } for every threshold met.
]]
function Equipment.GetActiveSetBonuses(equippedBaseIds: { string })
	local counts = {}
	for _, baseId in ipairs(equippedBaseIds) do
		local setId = Equipment.SetByPiece[baseId]
		if setId then
			counts[setId] = (counts[setId] or 0) + 1
		end
	end

	local active = {}
	for setId, count in pairs(counts) do
		local set = Equipment.SetById[setId]
		if set then
			-- Every threshold at or below the piece count is active, so a 4-piece
			-- wearer receives the 2-, 3- and 4-piece bonuses together.
			local thresholds = {}
			for threshold in pairs(set.bonuses) do
				table.insert(thresholds, threshold)
			end
			table.sort(thresholds)
			for _, threshold in ipairs(thresholds) do
				if count >= threshold then
					table.insert(active, {
						setId = setId,
						setName = set.name,
						tier = threshold,
						bonus = set.bonuses[threshold],
					})
				end
			end
		end
	end
	table.sort(active, function(a, b)
		if a.setId == b.setId then
			return a.tier < b.tier
		end
		return a.setId < b.setId
	end)
	return active
end

--[[ Set progress for the UI: how many pieces of each touched set are worn. ]]
function Equipment.GetSetProgress(equippedBaseIds: { string })
	local progress = {}
	for _, baseId in ipairs(equippedBaseIds) do
		local setId = Equipment.SetByPiece[baseId]
		if setId then
			progress[setId] = progress[setId] or { owned = 0, total = #Equipment.SetById[setId].pieces }
			progress[setId].owned += 1
		end
	end
	return progress
end

return TableUtil.DeepFreeze(Equipment)
