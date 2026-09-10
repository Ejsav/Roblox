--!strict
--[[
	StormTypes
	----------
	Twenty storm phenomena. Each one is a different capture *verb*, not a reskin with
	bigger numbers — the design rule here is that a player should be able to identify a
	storm by how it makes them move, with the audio and silhouette only confirming it.

	The `mechanic` field selects a behaviour implemented by the server's storm
	behaviour registry (src/Server/Services/StormBehaviours). `params` is passed to it
	verbatim, so retuning a storm never requires touching code.

	Schema:
		id, name, rarity, tier          identity and where it belongs
		mechanic, params                behaviour selection and tuning
		strike                          windup / window / count shaping
		yield                           energy economics
		presentation                    colour, scale, sound, bolt style
		drops                           loot table id and chance scaling
		danger                          contribution to the region's effective danger
		discoveryId                     collection entry unlocked on first capture
		teaches                         short line shown the first time you meet it
]]

local TableUtil = require(script.Parent.Parent.Core.TableUtil)

local StormTypes = {}

StormTypes.List = {

	-- ================================================================ TIER 1
	{
		id = "static_bloom",
		name = "Static Bloom",
		rarity = "common",
		tier = 1,
		mechanic = "single_strike",
		params = {},
		strike = {
			windup = 2.2,
			windowHalfWidth = 0.34,
			strikeCount = 1,
			radius = 30,
		},
		yield = { base = 14, variance = 0.15, chargeCost = 1 },
		presentation = {
			color = "7BE0FF",
			scale = 1.0,
			boltStyle = "soft",
			sound = "sfx_storm_bloom",
			telegraphSound = "sfx_telegraph_soft",
			particleDensity = 0.6,
		},
		drops = { table = "common_scrap", chanceScale = 0.7 },
		danger = 0,
		discoveryId = "storm_static_bloom",
		teaches = "Wait for the flash to peak. Take it at the top.",
	},

	{
		id = "drift_arc",
		name = "Drift Arc",
		rarity = "common",
		tier = 1,
		mechanic = "moving_strike",
		params = {
			-- The strike point slides along a path during the windup, so the player has
			-- to lead it rather than stand still.
			driftSpeed = 11,
			driftPattern = "linear",
			driftDistance = 46,
		},
		strike = {
			windup = 2.4,
			windowHalfWidth = 0.30,
			strikeCount = 1,
			radius = 28,
		},
		yield = { base = 18, variance = 0.18, chargeCost = 1 },
		presentation = {
			color = "8FD8FF",
			scale = 1.05,
			boltStyle = "arc",
			sound = "sfx_storm_drift",
			telegraphSound = "sfx_telegraph_slide",
			particleDensity = 0.7,
		},
		drops = { table = "common_scrap", chanceScale = 0.85 },
		danger = 0,
		discoveryId = "storm_drift_arc",
		teaches = "It moves while it charges. Go where it is going to be.",
	},

	{
		id = "ground_crawler",
		name = "Ground Crawler",
		rarity = "common",
		tier = 1,
		mechanic = "travelling_line",
		params = {
			-- Current runs along the ground toward a random anchor. Capture by standing
			-- on the line at the moment it passes, which reads as a dodge-and-time.
			travelSpeed = 34,
			lineWidth = 7,
			lineLength = 130,
			damageOnContactOutsideWindow = 12,
		},
		strike = {
			windup = 1.9,
			windowHalfWidth = 0.26,
			strikeCount = 1,
			radius = 18,
		},
		yield = { base = 16, variance = 0.2, chargeCost = 1 },
		presentation = {
			color = "9FFFC4",
			scale = 0.9,
			boltStyle = "ground",
			sound = "sfx_storm_crawler",
			telegraphSound = "sfx_telegraph_ground",
			particleDensity = 0.5,
		},
		drops = { table = "common_scrap", chanceScale = 0.9 },
		danger = 1,
		discoveryId = "storm_ground_crawler",
		teaches = "It travels along the ground. Stand on the line, not beside it.",
	},

	-- ================================================================ TIER 2
	{
		id = "sheet_front",
		name = "Sheet Front",
		rarity = "uncommon",
		tier = 2,
		mechanic = "wide_simultaneous",
		params = {
			-- A wall of simultaneous strikes. Every point pays, but you can only be in
			-- one. Reward comes from picking the densest cluster.
			pointCount = 6,
			spread = 120,
			clusterBonusRadius = 26,
			clusterBonusPerNeighbour = 0.14,
		},
		strike = {
			windup = 2.8,
			windowHalfWidth = 0.24,
			strikeCount = 1,
			radius = 26,
		},
		yield = { base = 26, variance = 0.2, chargeCost = 1.4 },
		presentation = {
			color = "A8C8FF",
			scale = 1.6,
			boltStyle = "sheet",
			sound = "sfx_storm_sheet",
			telegraphSound = "sfx_telegraph_wide",
			particleDensity = 1.0,
		},
		drops = { table = "uncommon_components", chanceScale = 1.0 },
		danger = 1,
		discoveryId = "storm_sheet_front",
		teaches = "Six strikes at once. Stand where the most of them overlap.",
	},

	{
		id = "ball_lightning",
		name = "Ball Lightning",
		rarity = "uncommon",
		tier = 2,
		mechanic = "orbital_body",
		params = {
			-- A slow physical orb that orbits the cell. Capture window opens each time
			-- it completes a lap, so timing is spatial rather than purely temporal.
			orbitRadius = 58,
			orbitSpeed = 0.55,
			bodyRadius = 6,
			contactDamage = 18,
			lapsBeforeDischarge = 4,
		},
		strike = {
			windup = 3.6,
			windowHalfWidth = 0.22,
			strikeCount = 4,
			radius = 22,
		},
		yield = { base = 22, variance = 0.25, chargeCost = 1, perStrikeScale = 1.22 },
		presentation = {
			color = "FFD166",
			scale = 1.1,
			boltStyle = "orb",
			sound = "sfx_storm_ball",
			telegraphSound = "sfx_telegraph_orb",
			particleDensity = 0.9,
		},
		drops = { table = "uncommon_components", chanceScale = 1.3 },
		danger = 2,
		discoveryId = "storm_ball_lightning",
		teaches = "Four laps, four chances. Each one pays more than the last.",
	},

	{
		id = "transformer_cascade",
		name = "Transformer Cascade",
		rarity = "uncommon",
		tier = 3,
		mechanic = "sequential_chain",
		params = {
			-- Fires through nearby conductive structures in sequence. Capturing one link
			-- shortens the window on the next, so the chain accelerates under you.
			linkCount = 5,
			linkInterval = 1.35,
			intervalDecayPerLink = 0.86,
			requiresStructure = true,
			structureSearchRadius = 90,
			chainBonusPerLink = 0.2,
		},
		strike = {
			windup = 1.6,
			windowHalfWidth = 0.26,
			strikeCount = 5,
			radius = 24,
		},
		yield = { base = 20, variance = 0.15, chargeCost = 0.8, perStrikeScale = 1.1 },
		presentation = {
			color = "FFA23D",
			scale = 1.2,
			boltStyle = "cascade",
			sound = "sfx_storm_cascade",
			telegraphSound = "sfx_telegraph_cascade",
			particleDensity = 1.1,
		},
		drops = { table = "industrial_salvage", chanceScale = 1.2 },
		danger = 2,
		discoveryId = "storm_transformer_cascade",
		teaches = "It jumps from box to box and it speeds up. Move ahead of it.",
	},

	-- ================================================================ TIER 3
	{
		id = "coil_resonance",
		name = "Coil Resonance",
		rarity = "rare",
		tier = 3,
		mechanic = "rhythmic_beats",
		params = {
			-- A metronome. Beats are evenly spaced and only the accented beat pays full.
			-- The skill is holding a rhythm while the world is trying to kill you.
			beatInterval = 0.72,
			beatCount = 8,
			accentEvery = 4,
			accentYieldScale = 2.6,
			offBeatPenalty = 0.35,
			missBreaksSequence = true,
		},
		strike = {
			windup = 1.2,
			windowHalfWidth = 0.18,
			strikeCount = 8,
			radius = 26,
		},
		yield = { base = 15, variance = 0.1, chargeCost = 0.55 },
		presentation = {
			color = "FF8AE8",
			scale = 1.0,
			boltStyle = "resonance",
			sound = "sfx_storm_coil",
			telegraphSound = "sfx_telegraph_beat",
			particleDensity = 0.8,
		},
		drops = { table = "resonant_materials", chanceScale = 1.4 },
		danger = 3,
		discoveryId = "storm_coil_resonance",
		teaches = "Eight beats. Every fourth one is worth three. Do not break the count.",
	},

	{
		id = "spire_conductor",
		name = "Spire Conductor",
		rarity = "rare",
		tier = 3,
		mechanic = "altitude_gated",
		params = {
			-- Only strikes the highest point in range, and the yield scales with how
			-- high you are when you take it. This is the storm that teaches verticality.
			minAltitudeAboveGround = 40,
			altitudeYieldScale = 0.0011,
			maxAltitudeBonus = 2.4,
			requiresHighestPoint = true,
		},
		strike = {
			windup = 3.0,
			windowHalfWidth = 0.20,
			strikeCount = 1,
			radius = 20,
		},
		yield = { base = 42, variance = 0.2, chargeCost = 1.6 },
		presentation = {
			color = "B9A6FF",
			scale = 1.5,
			boltStyle = "spire",
			sound = "sfx_storm_spire",
			telegraphSound = "sfx_telegraph_high",
			particleDensity = 1.2,
		},
		drops = { table = "high_altitude_cache", chanceScale = 1.5 },
		danger = 3,
		discoveryId = "storm_spire_conductor",
		teaches = "It only hits the highest thing here. Be the highest thing here.",
	},

	{
		id = "mirror_flash",
		name = "Mirror Flash",
		rarity = "rare",
		tier = 3,
		mechanic = "decoy_pair",
		params = {
			-- Two telegraphs, one real. The tell is a quarter-second phase difference in
			-- the flicker, which experienced players read and new ones guess at.
			decoyCount = 1,
			tellLeadTime = 0.28,
			tellSubtlety = 0.6,
			wrongChoicePenalty = 0.5,
			wrongChoiceDamage = 20,
		},
		strike = {
			windup = 2.6,
			windowHalfWidth = 0.22,
			strikeCount = 1,
			radius = 24,
		},
		yield = { base = 55, variance = 0.25, chargeCost = 1.5 },
		presentation = {
			color = "DCE8FF",
			scale = 1.2,
			boltStyle = "mirror",
			sound = "sfx_storm_mirror",
			telegraphSound = "sfx_telegraph_double",
			particleDensity = 0.9,
		},
		drops = { table = "resonant_materials", chanceScale = 1.8 },
		danger = 4,
		discoveryId = "storm_mirror_flash",
		teaches = "One of them is lying. The real one flickers first.",
	},

	-- ================================================================ TIER 4
	{
		id = "chain_web",
		name = "Chain Web",
		rarity = "rare",
		tier = 4,
		mechanic = "linked_nodes",
		params = {
			-- A graph of connected nodes. Capturing one propagates a shortened window to
			-- its neighbours. Clearing the whole web in one pass is the mastery goal.
			nodeCount = 7,
			nodeSpacing = 42,
			propagationDelay = 0.55,
			propagationWindowScale = 0.7,
			fullClearBonus = 1.8,
			collapseAfterSeconds = 9,
		},
		strike = {
			windup = 2.4,
			windowHalfWidth = 0.24,
			strikeCount = 7,
			radius = 20,
		},
		yield = { base = 18, variance = 0.12, chargeCost = 0.6, perStrikeScale = 1.14 },
		presentation = {
			color = "6FE3C6",
			scale = 1.4,
			boltStyle = "web",
			sound = "sfx_storm_web",
			telegraphSound = "sfx_telegraph_web",
			particleDensity = 1.3,
		},
		drops = { table = "resonant_materials", chanceScale = 1.6 },
		danger = 4,
		discoveryId = "storm_chain_web",
		teaches = "Take one and the rest light up. Clear all seven before it collapses.",
	},

	{
		id = "updraft_column",
		name = "Updraft Column",
		rarity = "rare",
		tier = 4,
		mechanic = "vertical_ride",
		params = {
			-- A rising column of charge. You have to be airborne inside it, and the
			-- capture window travels upward, so it doubles as free altitude.
			columnRadius = 26,
			riseSpeed = 46,
			columnHeight = 420,
			mustBeAirborne = true,
			liftForce = 62,
			heightYieldScale = 0.0018,
		},
		strike = {
			windup = 1.4,
			windowHalfWidth = 0.28,
			strikeCount = 3,
			radius = 26,
		},
		yield = { base = 30, variance = 0.2, chargeCost = 1.1, perStrikeScale = 1.3 },
		presentation = {
			color = "9FF0FF",
			scale = 1.8,
			boltStyle = "column",
			sound = "sfx_storm_updraft",
			telegraphSound = "sfx_telegraph_rise",
			particleDensity = 1.4,
		},
		drops = { table = "high_altitude_cache", chanceScale = 1.4 },
		danger = 4,
		discoveryId = "storm_updraft_column",
		teaches = "Jump in. It carries you up and pays you three times on the way.",
	},

	{
		id = "hail_charge",
		name = "Hail Charge",
		rarity = "uncommon",
		tier = 4,
		mechanic = "scatter_shower",
		params = {
			-- Many tiny captures raining down over an area. Individually worthless,
			-- collectively excellent, and it rewards movement over positioning.
			pelletCount = 24,
			showerDuration = 8,
			pelletRadius = 4,
			areaRadius = 110,
			streakBonusPerPellet = 0.05,
			streakResetOnMiss = true,
		},
		strike = {
			windup = 0.5,
			windowHalfWidth = 0.42,
			strikeCount = 24,
			radius = 6,
		},
		yield = { base = 4.5, variance = 0.1, chargeCost = 0.16 },
		presentation = {
			color = "CBD8E6",
			scale = 0.6,
			boltStyle = "hail",
			sound = "sfx_storm_hail",
			telegraphSound = "sfx_telegraph_patter",
			particleDensity = 1.5,
		},
		drops = { table = "glacier_cache", chanceScale = 0.9 },
		danger = 2,
		discoveryId = "storm_hail_charge",
		teaches = "Twenty-four of them. Keep the streak alive and they compound.",
	},

	-- ================================================================ TIER 5
	{
		id = "glass_storm",
		name = "Glass Storm",
		rarity = "epic",
		tier = 5,
		mechanic = "two_phase_harvest",
		params = {
			-- Phase one is a normal capture. Phase two fuses the ground into fulgurite
			-- you then have to physically collect before it cools, which pulls you into
			-- the open exactly when the next cell arrives.
			fuseCount = 5,
			fuseSpread = 90,
			coolDownSeconds = 22,
			harvestValueEach = 26,
			shatterOnLateHarvest = true,
		},
		strike = {
			windup = 2.8,
			windowHalfWidth = 0.20,
			strikeCount = 1,
			radius = 30,
		},
		yield = { base = 62, variance = 0.22, chargeCost = 2.0 },
		presentation = {
			color = "FF4FD8",
			scale = 1.6,
			boltStyle = "glass",
			sound = "sfx_storm_glass",
			telegraphSound = "sfx_telegraph_crystal",
			particleDensity = 1.4,
		},
		drops = { table = "wasteland_exotics", chanceScale = 2.0 },
		danger = 5,
		discoveryId = "storm_glass_storm",
		teaches = "Take the strike, then collect what it fused. You have twenty seconds.",
	},

	{
		id = "null_pocket",
		name = "Null Pocket",
		rarity = "epic",
		tier = 5,
		mechanic = "inverted_window",
		params = {
			-- The rule reverses: capturing at the peak is a failure, and the payout sits
			-- in the dead silence between discharges. It reliably catches every player
			-- exactly once, which is the point.
			inverted = true,
			nullDuration = 1.1,
			peakPenaltyDamage = 34,
			peakPenaltyEnergyLoss = 0.2,
			nullVisualCue = "silence",
		},
		strike = {
			windup = 3.2,
			windowHalfWidth = 0.16,
			strikeCount = 1,
			radius = 26,
		},
		yield = { base = 96, variance = 0.3, chargeCost = 2.2 },
		presentation = {
			color = "1C1C26",
			scale = 1.3,
			boltStyle = "null",
			sound = "sfx_storm_null",
			telegraphSound = "sfx_telegraph_silence",
			particleDensity = 0.4,
		},
		drops = { table = "null_cache", chanceScale = 2.2 },
		danger = 6,
		discoveryId = "storm_null_pocket",
		teaches = "Everything you learned is backwards here. Take it when nothing is happening.",
	},

	{
		id = "containment_breach",
		name = "Containment Breach",
		rarity = "epic",
		tier = 5,
		mechanic = "escaping_body",
		params = {
			-- Loose lab energy fleeing toward an exit. If it reaches the vent it is gone
			-- and the room floods. Genuine urgency without a fail-state cutscene.
			fleeSpeed = 42,
			escapeDistance = 260,
			escapeConsequence = "room_flood",
			interceptWindowScale = 1.2,
			slowOnNearMiss = 0.7,
		},
		strike = {
			windup = 1.1,
			windowHalfWidth = 0.30,
			strikeCount = 3,
			radius = 22,
		},
		yield = { base = 52, variance = 0.2, chargeCost = 1.4, perStrikeScale = 1.4 },
		presentation = {
			color = "37F0A8",
			scale = 1.2,
			boltStyle = "breach",
			sound = "sfx_storm_breach",
			telegraphSound = "sfx_telegraph_alarm",
			particleDensity = 1.2,
		},
		drops = { table = "lab_prototypes", chanceScale = 2.0 },
		danger = 5,
		discoveryId = "storm_containment_breach",
		teaches = "It is running for the vent. Cut it off before it gets there.",
	},

	-- ================================================================ TIER 6
	{
		id = "devourer",
		name = "The Devourer",
		rarity = "legendary",
		tier = 6,
		mechanic = "predatory_drain",
		params = {
			-- Hunts the player carrying the most energy and drains them on contact.
			-- Turns your own success into the thing chasing you.
			huntsRichestPlayer = true,
			detectionRadius = 340,
			pursuitSpeed = 30,
			drainPerSecond = 6.5,
			drainRadius = 30,
			capturableWhileDraining = true,
			captureEndsPursuit = true,
			yieldScalesWithDrained = 1.5,
		},
		strike = {
			windup = 2.0,
			windowHalfWidth = 0.14,
			strikeCount = 1,
			radius = 24,
		},
		yield = { base = 120, variance = 0.35, chargeCost = 3.0 },
		presentation = {
			color = "FF2E63",
			scale = 2.2,
			boltStyle = "devour",
			sound = "sfx_storm_devourer",
			telegraphSound = "sfx_telegraph_hunt",
			particleDensity = 1.8,
		},
		drops = { table = "legendary_storm_cache", chanceScale = 3.0 },
		danger = 7,
		discoveryId = "storm_devourer",
		teaches = "It is coming for whoever is carrying the most. Right now that is you.",
	},

	{
		id = "echo_bloom",
		name = "Echo Bloom",
		rarity = "legendary",
		tier = 6,
		mechanic = "pattern_replay",
		params = {
			-- Shows a sequence, then asks you to reproduce it. Pure memory and nerve;
			-- the only storm where standing still and watching is the correct opening.
			sequenceLength = 5,
			demonstrationInterval = 0.68,
			replayWindowScale = 0.85,
			perfectSequenceBonus = 2.4,
			partialCredit = true,
			sequenceGrowsOnSuccess = true,
			maxSequenceLength = 9,
		},
		strike = {
			windup = 1.0,
			windowHalfWidth = 0.19,
			strikeCount = 5,
			radius = 22,
		},
		yield = { base = 40, variance = 0.15, chargeCost = 1.0, perStrikeScale = 1.2 },
		presentation = {
			color = "FFF3A0",
			scale = 1.5,
			boltStyle = "echo",
			sound = "sfx_storm_echo",
			telegraphSound = "sfx_telegraph_echo",
			particleDensity = 1.3,
		},
		drops = { table = "legendary_storm_cache", chanceScale = 2.6 },
		danger = 6,
		discoveryId = "storm_echo_bloom",
		teaches = "Watch the whole sequence. Then give it back exactly.",
	},

	{
		id = "core_pulse",
		name = "Core Pulse",
		rarity = "legendary",
		tier = 7,
		mechanic = "cooperative_load",
		params = {
			-- Requires more simultaneous capture than one player's containment can hold.
			-- Solo players can take a partial share; a coordinated group takes all of it.
			requiredCaptors = 3,
			soloPartialShare = 0.35,
			perCaptorBonus = 0.28,
			synchronisationWindow = 1.2,
			overloadOnUndercapture = true,
			overloadDamage = 55,
		},
		strike = {
			windup = 4.5,
			windowHalfWidth = 0.18,
			strikeCount = 1,
			radius = 64,
		},
		yield = { base = 440, variance = 0.2, chargeCost = 5.0 },
		presentation = {
			color = "FFE24F",
			scale = 3.0,
			boltStyle = "pulse",
			sound = "sfx_storm_corepulse",
			telegraphSound = "sfx_telegraph_massive",
			particleDensity = 2.0,
		},
		drops = { table = "core_cache", chanceScale = 3.5 },
		danger = 8,
		discoveryId = "storm_core_pulse",
		teaches = "Too much for one containment. Take it together or take a piece.",
	},

	-- ================================================================ TIER 7 / endgame
	{
		id = "the_eye",
		name = "The Eye",
		rarity = "mythic",
		tier = 8,
		mechanic = "sentient_encounter",
		params = {
			-- A multi-stage encounter that reacts to how you play it. Aggressive players
			-- get an aggressive fight; patient players get a different one.
			stages = 3,
			stageHealthPools = { 2400, 3600, 5200 },
			adaptsToPlaystyle = true,
			stageTransitionInvuln = 3.0,
			enrageAfterSeconds = 300,
			minimumParticipants = 1,
			scalesWithParticipants = 0.55,
			awardsTitle = "storm_touched",
		},
		strike = {
			windup = 2.2,
			windowHalfWidth = 0.13,
			strikeCount = 12,
			radius = 40,
		},
		yield = { base = 180, variance = 0.25, chargeCost = 2.5, perStrikeScale = 1.06 },
		presentation = {
			color = "FFFFFF",
			scale = 4.0,
			boltStyle = "eye",
			sound = "sfx_storm_eye",
			telegraphSound = "sfx_telegraph_eye",
			particleDensity = 2.4,
		},
		drops = { table = "eye_cache", chanceScale = 5.0 },
		danger = 10,
		discoveryId = "storm_the_eye",
		teaches = "It is watching how you fight it. It will adjust.",
	},

	{
		id = "inversion",
		name = "Inversion",
		rarity = "exotic",
		tier = 9,
		mechanic = "reality_inversion",
		params = {
			-- Prestige-only. Gravity, capture polarity and the HUD all invert on a
			-- cycle, and the cycle is readable if you pay attention to the audio.
			inversionInterval = 6.0,
			invertsGravity = true,
			invertsCapturePolarity = true,
			invertsHud = true,
			warningLeadTime = 1.4,
			correctPolarityBonus = 2.0,
			wrongPolarityDamage = 70,
		},
		strike = {
			windup = 1.8,
			windowHalfWidth = 0.15,
			strikeCount = 6,
			radius = 28,
		},
		yield = { base = 390, variance = 0.3, chargeCost = 3.5, perStrikeScale = 1.15 },
		presentation = {
			color = "FF6B9D",
			scale = 2.6,
			boltStyle = "inverted",
			sound = "sfx_storm_inversion",
			telegraphSound = "sfx_telegraph_invert",
			particleDensity = 2.2,
		},
		drops = { table = "prestige_cache", chanceScale = 4.0 },
		danger = 10,
		discoveryId = "storm_inversion",
		teaches = "Listen for the flip. Everything reverses, including you.",
	},
}

-- ============================================================================
-- Derived lookups and queries
-- ============================================================================

StormTypes.ById = {}
StormTypes.ByRarity = {}
StormTypes.ByMechanic = {}

for _, storm in ipairs(StormTypes.List) do
	StormTypes.ById[storm.id] = storm

	StormTypes.ByRarity[storm.rarity] = StormTypes.ByRarity[storm.rarity] or {}
	table.insert(StormTypes.ByRarity[storm.rarity], storm.id)

	StormTypes.ByMechanic[storm.mechanic] = StormTypes.ByMechanic[storm.mechanic] or {}
	table.insert(StormTypes.ByMechanic[storm.mechanic], storm.id)
end

function StormTypes.Get(stormId: string)
	return StormTypes.ById[stormId]
end

--[[
	Total energy a storm yields if every strike is captured at the given grade scale.
	Used by the UI to preview a storm's worth and by tests to keep tier progression
	monotonic.
]]
function StormTypes.MaxYield(stormId: string, gradeScale: number?): number
	local storm = StormTypes.ById[stormId]
	if not storm then
		return 0
	end
	local scale = gradeScale or 1
	local perStrike = storm.yield.perStrikeScale or 1
	local total = 0
	local current = storm.yield.base
	for _ = 1, storm.strike.strikeCount do
		total += current
		current *= perStrike
	end
	return total * scale
end

--[[ Storm ids that can appear in a region, as an id -> weight map. ]]
function StormTypes.GetRegionWeights(regionStormConfig: { types: { [string]: number } }): { [string]: number }
	local weights = {}
	for stormId, weight in pairs(regionStormConfig.types) do
		if StormTypes.ById[stormId] then
			weights[stormId] = weight
		end
	end
	return weights
end

--[[ True when a storm should trigger a server-wide announcement on spawn. ]]
function StormTypes.IsBroadcastWorthy(stormId: string): boolean
	local storm = StormTypes.ById[stormId]
	if not storm then
		return false
	end
	return storm.rarity == "legendary" or storm.rarity == "mythic" or storm.rarity == "exotic"
end

return TableUtil.DeepFreeze(StormTypes)
