--!strict
--[[
	Quests
	------
	The directed spine of the game. Main quests gate regions and teach mechanics;
	side quests reward exploration and reveal story; challenges test mastery;
	rotating quests give returning players something to do today.

	Objective types (each handled by a matcher in QuestService):
		capture      capture N times, optionally filtered by storm/grade/region
		bank         bank N energy in one deposit, or cumulatively
		reach        arrive at a world position or subregion
		discover     find a specific discovery
		survive      remain in a region/condition for a duration
		collect      gather N of a resource
		craft        build a specific item or category
		defeat       complete a boss or major phenomenon
		event        participate in a world event
		chain        reach a chain length
		traverse     use a traversal ability in a specific way
		escort       protect a moving objective
		deliver      carry energy to a specific place without banking

	Every main quest declares `teaches`, which the UI surfaces as the reason the
	quest exists. If a main quest does not teach something, it should be a side quest.
]]

local TableUtil = require(script.Parent.Parent.Core.TableUtil)

local Quests = {}

Quests.Types = {
	MAIN = "main",
	SIDE = "side",
	CHALLENGE = "challenge",
	DAILY = "daily",
	WEEKLY = "weekly",
	EVENT = "event",
	LEGENDARY = "legendary",
}

-- ============================================================================
-- MAIN QUESTLINE — one chain from the first capture to the Eye
-- ============================================================================

Quests.List = {

	{
		id = "intro_first_light",
		type = "main",
		order = 1,
		region = "starter_district",
		name = "First Light",
		summary = "A storm is forming over Relay Row. Take something from it.",
		description = "Everything here runs on borrowed power. You are here to borrow some.",
		teaches = "Capture timing.",
		giver = "npc_chief_alder",
		prerequisites = {},
		objectives = {
			{ id = "capture_any", type = "capture", target = 1, description = "Capture energy from any storm" },
		},
		rewards = { watts = 120, xp = 60 },
		autoTrack = true,
		firstTimeOnly = true,
	},

	{
		id = "intro_bank_it",
		type = "main",
		order = 2,
		region = "starter_district",
		name = "Bank It",
		summary = "Carried energy is not yours yet. Take it to the pylon.",
		description = "Alder will not stop saying it: energy in your cell belongs to the storm until it is in the bank.",
		teaches = "Banking, and that carrying is a risk rather than a reward.",
		giver = "npc_chief_alder",
		prerequisites = { "intro_first_light" },
		objectives = {
			{ id = "bank_once", type = "bank", target = 1, mode = "deposits", description = "Bank energy at Halworth Pylon" },
		},
		rewards = { watts = 200, xp = 90, unlocksUi = "upgrades" },
		autoTrack = true,
		firstTimeOnly = true,
	},

	{
		id = "intro_get_stronger",
		type = "main",
		order = 3,
		region = "starter_district",
		name = "Get Stronger",
		summary = "Spend what you earned. The storms are not going to get easier.",
		description = "Every Watt you bank is a decision about what kind of runner you become.",
		teaches = "The upgrade loop, and that Watts are for spending.",
		giver = "npc_chief_alder",
		prerequisites = { "intro_bank_it" },
		objectives = {
			{ id = "buy_upgrade", type = "upgrade", target = 1, description = "Purchase any upgrade" },
		},
		rewards = { watts = 250, xp = 120 },
		autoTrack = true,
		firstTimeOnly = true,
	},

	{
		id = "intro_the_overlook",
		type = "main",
		order = 4,
		region = "starter_district",
		name = "The Overlook",
		summary = "Climb the ridge. Look at what you are actually standing in.",
		description = "From up here the Grid, the Spire and the wall all resolve at once. Alder does not say anything. He does not have to.",
		teaches = "The scale of the world, and that distant landmarks are goals.",
		giver = "npc_chief_alder",
		prerequisites = { "intro_get_stronger" },
		objectives = {
			{ id = "reach_overlook", type = "reach", subregion = "halworth_overlook", description = "Reach The Overlook" },
		},
		rewards = { watts = 300, xp = 200, discovery = "halworth_vista" },
		autoTrack = true,
		firstTimeOnly = true,
	},

	{
		id = "plains_the_long_road",
		type = "main",
		order = 5,
		region = "storm_plains",
		name = "The Long Road",
		summary = "Cross the Sattermarsh and reach Stiltmoor. The causeway is exposed the whole way.",
		description = "Nobody has run supplies to Stiltmoor in weeks. The causeway is the only route and it is open sky from end to end.",
		teaches = "Route planning and reading danger before you commit to it.",
		giver = "npc_chief_alder",
		prerequisites = { "intro_the_overlook" },
		requiredLevel = 5,
		objectives = {
			{ id = "reach_stiltmoor", type = "reach", subregion = "plains_stiltvillage", description = "Reach Stiltmoor" },
			{ id = "capture_plains", type = "capture", target = 12, region = "storm_plains", description = "Capture 12 storms in the Sattermarsh" },
		},
		rewards = { watts = 900, xp = 620, unlocksTraversal = "fast_travel", unlocksRegionHint = "industrial_grid" },
		autoTrack = true,
	},

	{
		id = "grid_open_the_gate",
		type = "main",
		order = 6,
		region = "industrial_grid",
		name = "Open the Gate",
		summary = "Sector Seven is sealed. Restore power to three substations and the gate opens itself.",
		description = "The Grid never shut down. It just stopped letting anyone in. Alder thinks the substations still answer to a maintenance sequence.",
		teaches = "Vertical traversal and multi-stage objectives.",
		giver = "npc_engineer_voss",
		prerequisites = { "plains_the_long_road" },
		requiredLevel = 12,
		objectives = {
			{ id = "restore_alpha", type = "interact", target = 1, tag = "substation_alpha", description = "Restore Substation Alpha" },
			{ id = "restore_beta", type = "interact", target = 1, tag = "substation_beta", description = "Restore Substation Beta" },
			{ id = "restore_gamma", type = "interact", target = 1, tag = "substation_gamma", description = "Restore Substation Gamma" },
			{ id = "reach_gate", type = "reach", subregion = "grid_reactorapron", description = "Reach the Reactor Apron" },
		},
		rewards = { watts = 2400, xp = 1800, cores = 3, unlocksRegionHint = "city_region" },
		autoTrack = true,
	},

	{
		id = "grid_third_rail",
		type = "main",
		order = 7,
		region = "industrial_grid",
		name = "Third Rail",
		summary = "The express line still runs. Voss thinks you can ride it if your insulation holds.",
		description = "\"It will either carry you across the whole sector or it will cook you. Bring better insulation than you think you need.\"",
		teaches = "Rail traversal and that resistance is a gate, not a stat.",
		giver = "npc_engineer_voss",
		prerequisites = { "grid_open_the_gate" },
		requiredLevel = 16,
		objectives = {
			{ id = "insulation_rating", type = "stat", stat = "stormResist", target = 0.25, description = "Reach 25% storm resistance" },
			{ id = "ride_rail", type = "traverse", ability = "rail", target = 400, unit = "studs", description = "Ride the rail network for 400 studs" },
		},
		rewards = { watts = 3200, xp = 2400, unlocksTraversal = "rail", item = "unique_third_rail" },
		autoTrack = true,
	},

	{
		id = "city_the_line",
		type = "main",
		order = 8,
		region = "city_region",
		name = "The Upper Line",
		summary = "Verrick's streets flood. The rooftops do not. Find the grapple rig on the Broken Bridge.",
		description = "The Wharf traders will tell you the same thing every time: nobody works the streets any more.",
		teaches = "Grappling, and that the city is a three-dimensional space.",
		giver = "npc_trader_mox",
		prerequisites = { "grid_open_the_gate" },
		requiredLevel = 22,
		objectives = {
			{ id = "reach_bridge", type = "reach", landmark = "the_broken_bridge", description = "Reach the Broken Bridge" },
			{ id = "recover_rig", type = "interact", target = 1, tag = "grapple_cache", description = "Recover the grapple rig" },
		},
		rewards = { watts = 4200, xp = 3200, unlocksTraversal = "grapple" },
		autoTrack = true,
	},

	{
		id = "city_above_the_line",
		type = "main",
		order = 9,
		region = "city_region",
		name = "Above the Line",
		summary = "Take the Spire. It is struck every ninety seconds and something is at the top.",
		description = "Mox says three runners have gone up. Mox says two came back. Mox will not say what the third one found.",
		teaches = "Altitude-gated storms and sustained exposure management.",
		giver = "npc_trader_mox",
		prerequisites = { "city_the_line" },
		requiredLevel = 28,
		objectives = {
			{ id = "reach_spire", type = "reach", subregion = "city_spire", description = "Reach the top of Verrick Spire" },
			{ id = "capture_spire", type = "capture", target = 5, storm = "spire_conductor", description = "Capture 5 Spire Conductors" },
			{ id = "survive_spire", type = "survive", subregion = "city_spire", target = 180, description = "Survive 3 minutes at the mast" },
		},
		rewards = { watts = 7000, xp = 5400, cores = 8, unlocksRegionHint = "mountain_region" },
		autoTrack = true,
	},

	{
		id = "mountain_the_long_fall",
		type = "main",
		order = 10,
		region = "mountain_region",
		name = "The Long Fall",
		summary = "Halfway Camp has a wing nobody has been brave enough to test. Test it.",
		description = "The climber at Halfway has been trying the summit for two years. She has a glider. She has never used it.",
		teaches = "Gliding, thermals, and converting height into distance.",
		giver = "npc_climber_sera",
		prerequisites = { "city_above_the_line" },
		requiredLevel = 32,
		objectives = {
			{ id = "reach_switchbacks", type = "reach", subregion = "mountain_switchbacks", description = "Climb the Switchbacks" },
			{ id = "glide_distance", type = "traverse", ability = "glider", target = 1200, unit = "studs", description = "Glide 1200 studs in one flight" },
		},
		rewards = { watts = 9500, xp = 7200, unlocksTraversal = "glider" },
		autoTrack = true,
	},

	{
		id = "mountain_what_the_watcher_saw",
		type = "main",
		order = 11,
		region = "mountain_region",
		name = "What the Watcher Saw",
		summary = "The Observatory has been sealed since the first storm. Sera has the code.",
		description = "Whoever was in there was not studying the weather. They were waiting for something specific, and they wrote down every time it did not arrive.",
		teaches = "That the storms are not natural, and where to look next.",
		giver = "npc_climber_sera",
		prerequisites = { "mountain_the_long_fall" },
		requiredLevel = 40,
		objectives = {
			{ id = "reach_observatory", type = "reach", subregion = "mountain_observatory", description = "Reach the Observatory" },
			{ id = "read_logs", type = "interact", target = 4, tag = "watcher_log", description = "Recover 4 research logs" },
		},
		rewards = { watts = 16000, xp = 12000, cores = 16, item = "unique_watchers_eye", unlocksRegionHint = "electrical_wasteland" },
		autoTrack = true,
		storyBeat = "The logs describe a single event, thirty-one years ago, at a set of coordinates in the Scour.",
	},

	{
		id = "scour_what_started_it",
		type = "main",
		order = 12,
		region = "electrical_wasteland",
		name = "What Started It",
		summary = "The Watcher's coordinates point at the centre of Origin Crater. Go and look.",
		description = "Shelter Twelve will let you in, restock you, and tell you not to go. They tell everyone not to go.",
		teaches = "Extreme exposure, and that resistance gates content absolutely.",
		giver = "npc_shelter_keeper",
		prerequisites = { "mountain_what_the_watcher_saw" },
		requiredLevel = 44,
		objectives = {
			{ id = "reach_crater", type = "reach", subregion = "wasteland_crater", description = "Reach Origin Crater" },
			{ id = "survive_crater", type = "survive", subregion = "wasteland_crater", target = 120, description = "Survive 2 minutes at the crater floor" },
			{ id = "recover_sample", type = "interact", target = 1, tag = "crater_core_sample", description = "Recover a core sample" },
		},
		rewards = { watts = 26000, xp = 19000, cores = 24, unlocksRegionHint = "underground_network" },
		autoTrack = true,
		storyBeat = "The crater is not a point of impact. It is an exit wound. Something came out of the ground here.",
	},

	{
		id = "deep_the_long_cable",
		type = "main",
		order = 13,
		region = "underground_network",
		name = "The Long Cable",
		summary = "Deepline's intake hall still has power. Follow the cable that is drawing it.",
		description = "Somebody is running a load down here. Thirty years after the last person left.",
		teaches = "Zipline traversal and navigating without light.",
		giver = "npc_archivist",
		prerequisites = { "scour_what_started_it" },
		requiredLevel = 50,
		objectives = {
			{ id = "reach_intake", type = "reach", subregion = "deep_entryhall", description = "Reach Intake Hall" },
			{ id = "follow_cable", type = "traverse", ability = "zipline", target = 800, unit = "studs", description = "Follow the cable 800 studs" },
			{ id = "reach_labs", type = "reach", subregion = "deep_labs", description = "Reach the Wet Labs" },
		},
		rewards = { watts = 40000, xp = 28000, unlocksTraversal = "zipline" },
		autoTrack = true,
	},

	{
		id = "deep_sublevel_nine",
		type = "main",
		order = 14,
		region = "underground_network",
		name = "Sublevel Nine",
		summary = "The Archive says there are eight sublevels. The stairwell disagrees.",
		description = "Every map, every schematic, every evacuation plan stops at eight. The stairs keep going.",
		teaches = "That the world is bigger than its documentation.",
		giver = "npc_archivist",
		prerequisites = { "deep_the_long_cable" },
		requiredLevel = 56,
		objectives = {
			{ id = "open_archive", type = "interact", target = 1, tag = "archive_door", description = "Open the Archive" },
			{ id = "defeat_containment", type = "defeat", boss = "deepline_containment_prime", description = "Contain the breach in the Ring" },
			{ id = "reach_sublevel", type = "reach", subregion = "deep_belowring", description = "Descend to Sublevel Nine" },
		},
		rewards = { watts = 62000, xp = 44000, cores = 40, item = "unique_prototype_eleven", unlocksRegionHint = "high_altitude" },
		autoTrack = true,
		storyBeat = "Sublevel Nine was built to hold something. The doors open outward.",
	},

	{
		id = "high_riding_the_front",
		type = "main",
		order = 15,
		region = "high_altitude",
		name = "Riding the Front",
		summary = "The Anchorage crews do not use ladders. Learn what they do use.",
		description = "\"You are standing on a platform in the middle of a storm asking me how we get around. Look at the storm.\"",
		teaches = "Storm surfing — using the hazard as the transport.",
		giver = "npc_anchorage_dock",
		prerequisites = { "deep_sublevel_nine" },
		requiredLevel = 62,
		objectives = {
			{ id = "reach_anchorage", type = "reach", subregion = "high_mainplatform", description = "Reach Anchorage Prime" },
			{ id = "surf_cells", type = "traverse", ability = "storm_surf", target = 3, unit = "cells", description = "Surf 3 separate storm cells" },
		},
		rewards = { watts = 88000, xp = 60000, unlocksTraversal = "storm_surf" },
		autoTrack = true,
	},

	{
		id = "high_the_launch",
		type = "main",
		order = 16,
		region = "high_altitude",
		name = "The Launch",
		summary = "The launch rails point at the Core. Somebody built them to go there on purpose.",
		description = "Station Six is still transmitting. The transmission is a countdown, and it is nearly finished.",
		teaches = "That the Core is reachable, and what it will cost.",
		giver = "npc_anchorage_dock",
		prerequisites = { "high_riding_the_front" },
		requiredLevel = 70,
		objectives = {
			{ id = "reach_station_six", type = "reach", subregion = "high_derelict", description = "Board Station Six" },
			{ id = "recover_transmission", type = "interact", target = 1, tag = "station_six_transmitter", description = "Recover the transmission" },
			{ id = "charge_rails", type = "bank", target = 25000, mode = "into_objective", description = "Charge the launch rails with 25,000 energy" },
			{ id = "launch", type = "interact", target = 1, tag = "launch_control", description = "Launch" },
		},
		rewards = { watts = 150000, xp = 110000, cores = 90, unlocksRegionHint = "storm_core" },
		autoTrack = true,
		storyBeat = "The transmission is a voice. It has been counting down for thirty-one years, and it is counting in the first person.",
	},

	{
		id = "core_the_wall",
		type = "main",
		order = 17,
		region = "storm_core",
		name = "The Wall",
		summary = "The outer band never stops discharging. Get through it.",
		description = "There is no gap. There is no lull. There is only how fast you are and how much you can take.",
		teaches = "That endgame content is a skill check, not a gear check.",
		giver = "npc_wall_station",
		prerequisites = { "high_the_launch" },
		requiredLevel = 82,
		objectives = {
			{ id = "cross_wall", type = "reach", subregion = "core_spiralband", description = "Cross the Outer Wall" },
			{ id = "survive_spiral", type = "survive", subregion = "core_spiralband", target = 240, description = "Survive 4 minutes in the Spiral" },
		},
		rewards = { watts = 320000, xp = 240000, cores = 180 },
		autoTrack = true,
	},

	{
		id = "core_the_eye",
		type = "main",
		order = 18,
		region = "storm_core",
		name = "The Eye",
		summary = "There is perfect calm at the centre of the worst weather on the planet. Go and find out why.",
		description = "The voice in the transmission is here. It has been waiting for somebody to make it this far, and it is going to ask you a question.",
		teaches = "The answer, and the next question.",
		giver = "npc_wall_station",
		prerequisites = { "core_the_wall" },
		requiredLevel = 88,
		objectives = {
			{ id = "reach_eye", type = "reach", subregion = "core_stillpoint", description = "Reach the Eye" },
			{ id = "defeat_eye", type = "defeat", boss = "the_eye_encounter", description = "Face what is at the centre" },
			{ id = "reach_anchor", type = "reach", subregion = "core_undercore", description = "Find the Anchor beneath the Eye" },
		},
		rewards = { watts = 900000, xp = 700000, cores = 500, item = "unique_eye_of_the_storm", title = "storm_touched", unlocksPrestige = true },
		autoTrack = true,
		storyBeat = "The storms are not weather. They are a search pattern. Something has been looking for a person capable of reaching the centre, and it has just found one.",
	},

	-- ========================================================================
	-- SIDE QUESTS
	-- ========================================================================

	{
		id = "plains_close_call",
		type = "side",
		region = "storm_plains",
		name = "Close Call",
		summary = "Carry a dangerous load and get out alive. Stiltmoor pays for the demonstration.",
		description = "The Stiltmoor engineers want to see a full cell brought in intact. They have a device for people who cannot manage it.",
		giver = "npc_stiltmoor_engineer",
		prerequisites = { "plains_the_long_road" },
		requiredLevel = 8,
		objectives = {
			{ id = "carry_high", type = "carry", target = 0.9, unit = "fill_fraction", description = "Reach 90% containment in one run" },
			{ id = "bank_it", type = "bank", target = 1, mode = "deposits", afterObjective = "carry_high", description = "Bank it without dying" },
		},
		rewards = { watts = 1400, xp = 900, unlocksAbility = "emergency_extract" },
	},

	{
		id = "halworth_underyard",
		type = "side",
		region = "starter_district",
		name = "Somebody Lives Down Here",
		summary = "The Underyard is flooded and somebody has been using it anyway.",
		description = "Bedding. A working lamp. Twelve tally marks scratched into the wall in groups of five, and then nothing.",
		giver = "discovery",
		prerequisites = { "intro_bank_it" },
		objectives = {
			{ id = "find_underyard", type = "discover", discovery = "halworth_underyard_camp", description = "Find the camp in the Underyard" },
		},
		rewards = { watts = 400, xp = 250, lore = "lore_underyard_tally" },
	},

	{
		id = "grid_foundry_nine",
		type = "side",
		region = "industrial_grid",
		name = "Nobody Shut It Down",
		summary = "Foundry Nine is still running its production cycle with nobody feeding it.",
		description = "The crushers run on a ninety-second loop. They have run on a ninety-second loop for thirty-one years.",
		giver = "npc_engineer_voss",
		prerequisites = { "grid_open_the_gate" },
		requiredLevel = 15,
		objectives = {
			{ id = "reach_foundry", type = "reach", subregion = "grid_foundry", description = "Reach Foundry Nine" },
			{ id = "survive_crushers", type = "survive", subregion = "grid_foundry", target = 90, description = "Survive one full production cycle" },
			{ id = "capture_cascade", type = "capture", target = 8, storm = "transformer_cascade", description = "Capture 8 Transformer Cascades" },
		},
		rewards = { watts = 3000, xp = 2100, resources = { industrial_alloy = 40, ferrite_core = 20 } },
	},

	{
		id = "grid_service_tunnels",
		type = "side",
		region = "industrial_grid",
		name = "The Short Way",
		summary = "Voss swears the service tunnels connect every corner of the sector. Prove it.",
		description = "There is no map. There has never been a map. Voss learned it by walking it.",
		giver = "npc_engineer_voss",
		prerequisites = { "grid_open_the_gate" },
		requiredLevel = 17,
		objectives = {
			{ id = "tunnel_nodes", type = "interact", target = 6, tag = "tunnel_junction", description = "Find all 6 tunnel junctions" },
		},
		rewards = { watts = 3600, xp = 2600, discovery = "grid_tunnel_map", unlocksShortcut = "grid_tunnel_network" },
	},

	{
		id = "city_the_quarantine",
		type = "side",
		region = "city_region",
		name = "Sealed From Inside",
		summary = "Nine blocks of Verrick are behind blast barriers. The seals were welded from the inside.",
		description = "Mox will trade for anything that comes out of the Quarantine. Mox will not tell you what he already has.",
		giver = "npc_trader_mox",
		prerequisites = { "city_above_the_line" },
		requiredLevel = 30,
		objectives = {
			{ id = "breach_quarantine", type = "reach", subregion = "city_quarantine", description = "Get inside the Quarantine" },
			{ id = "recover_records", type = "interact", target = 3, tag = "quarantine_record", description = "Recover 3 civic records" },
		},
		rewards = { watts = 8000, xp = 6000, cores = 10, lore = "lore_quarantine_order" },
	},

	{
		id = "city_metro_depot",
		type = "side",
		region = "city_region",
		name = "Last Train",
		summary = "The Metro depot has not been opened since the flood. Something is still drawing power from it.",
		description = "Six lines. Five of them are flooded to the ceiling. The sixth one is dry, and that is worse.",
		giver = "discovery",
		prerequisites = { "city_the_line" },
		requiredLevel = 26,
		objectives = {
			{ id = "reach_depot", type = "discover", discovery = "verrick_metro_depot", description = "Find the Metro depot" },
			{ id = "restore_power", type = "interact", target = 1, tag = "depot_breaker", description = "Restore the depot breaker" },
		},
		rewards = { watts = 6200, xp = 4800, unlocksShortcut = "verrick_metro_line", discovery = "verrick_metro_depot" },
	},

	{
		id = "mountain_the_hollow",
		type = "side",
		region = "mountain_region",
		name = "Deeper Than the Maps",
		summary = "The Kalder ice caves are mapped to four hundred studs. Sera has been to nine hundred.",
		description = "\"It keeps going. I stopped because I ran out of light, not because it ended.\"",
		giver = "npc_climber_sera",
		prerequisites = { "mountain_the_long_fall" },
		requiredLevel = 36,
		objectives = {
			{ id = "descend_hollow", type = "reach", subregion = "mountain_cavesystem", description = "Descend into the Hollow" },
			{ id = "collect_quartz", type = "collect", resource = "glacier_quartz", target = 30, description = "Collect 30 Glacier Quartz" },
		},
		rewards = { watts = 11000, xp = 8200, resources = { glacier_quartz = 40, skyiron = 8 } },
	},

	{
		id = "scour_the_quiet",
		type = "side",
		region = "electrical_wasteland",
		name = "The Quiet",
		summary = "There is a zone in the Scour where the storms simply stop. Find out how big it is.",
		description = "No arcs. No ambient charge. No sound. The Shelter keeper calls it the only safe place in the Scour and refuses to go there.",
		giver = "npc_shelter_keeper",
		prerequisites = { "scour_what_started_it" },
		requiredLevel = 47,
		objectives = {
			{ id = "reach_quiet", type = "reach", subregion = "wasteland_nullzone", description = "Enter the Quiet" },
			{ id = "map_boundary", type = "interact", target = 5, tag = "quiet_marker", description = "Place 5 boundary markers" },
			{ id = "capture_null", type = "capture", target = 6, storm = "null_pocket", description = "Capture 6 Null Pockets" },
		},
		rewards = { watts = 30000, xp = 22000, cores = 20, lore = "lore_the_quiet_expands" },
		storyBeat = "The markers do not agree with each other. The Quiet is not a fixed shape, and it is getting larger.",
	},

	{
		id = "scour_the_hulks",
		type = "side",
		region = "electrical_wasteland",
		name = "The Convoy",
		summary = "Forty vehicles fused into one mass of metal. They were all driving the same direction.",
		description = "Away from the crater. All of them. None of them made it two kilometres.",
		giver = "discovery",
		prerequisites = { "scour_what_started_it" },
		requiredLevel = 48,
		objectives = {
			{ id = "reach_hulks", type = "reach", subregion = "wasteland_hulks", description = "Reach the Hulks" },
			{ id = "salvage_hulks", type = "collect", resource = "fulgurite_spine", target = 25, description = "Salvage 25 Fulgurite Spines" },
		},
		rewards = { watts = 28000, xp = 20000, resources = { fulgurite_spine = 30, null_residue = 12 }, lore = "lore_convoy_manifest" },
	},

	{
		id = "deep_the_ring",
		type = "side",
		region = "underground_network",
		name = "Still Spinning",
		summary = "The Ring spins up on a schedule. Be inside it when it does, and survive.",
		description = "Two kilometres of accelerator, cycling every eleven minutes, with nobody at the controls.",
		giver = "npc_archivist",
		prerequisites = { "deep_the_long_cable" },
		requiredLevel = 54,
		objectives = {
			{ id = "enter_ring", type = "reach", subregion = "deep_reactorring", description = "Enter the Ring" },
			{ id = "survive_cycle", type = "survive", subregion = "deep_reactorring", target = 150, description = "Survive a full spin-up cycle" },
			{ id = "capture_resonance", type = "capture", target = 15, storm = "coil_resonance", description = "Capture 15 Coil Resonances" },
		},
		rewards = { watts = 52000, xp = 38000, cores = 32, resources = { prototype_core = 4 } },
	},

	{
		id = "high_station_six",
		type = "side",
		region = "high_altitude",
		name = "Still Transmitting",
		summary = "Station Six lost power eleven years ago and has not stopped broadcasting.",
		description = "Adrift, dark, and putting out a carrier signal strong enough to read from the Anchorage.",
		giver = "npc_anchorage_dock",
		prerequisites = { "high_riding_the_front" },
		requiredLevel = 66,
		objectives = {
			{ id = "board_six", type = "discover", discovery = "station_six_interior", description = "Board Station Six" },
			{ id = "trace_signal", type = "interact", target = 3, tag = "station_six_relay", description = "Trace the signal through 3 relays" },
		},
		rewards = { watts = 96000, xp = 68000, item = "unique_anchorage_wing", lore = "lore_station_six_log" },
	},

	{
		id = "core_the_throne_field",
		type = "side",
		region = "storm_core",
		name = "Nothing Smaller Than a Building",
		summary = "The largest phenomena in the world gather in the Throne Field. Take from three of them.",
		description = "The Wall station keeps a list of everyone who has tried. It is not a long list.",
		giver = "npc_wall_station",
		prerequisites = { "core_the_wall" },
		requiredLevel = 86,
		objectives = {
			{ id = "reach_throne", type = "reach", subregion = "core_thronefield", description = "Reach the Throne Field" },
			{ id = "capture_pulse", type = "capture", target = 3, storm = "core_pulse", description = "Capture 3 Core Pulses" },
		},
		rewards = { watts = 480000, xp = 340000, cores = 260, resources = { core_filament = 10 } },
	},

	-- ========================================================================
	-- MASTERY CHALLENGES — repeatable proofs of skill
	-- ========================================================================

	{
		id = "challenge_perfect_ten",
		type = "challenge",
		name = "Perfect Ten",
		summary = "Ten consecutive Perfect captures. No Goods, no Weaks, no misses.",
		description = "Anyone can land one. Ten in a row is a different question.",
		prerequisites = { "intro_get_stronger" },
		objectives = {
			{ id = "perfect_streak", type = "capture", target = 10, grade = "Perfect", consecutive = true, description = "10 consecutive Perfect captures" },
		},
		rewards = { watts = 5000, xp = 3000, title = "precise" },
		repeatable = true,
		cooldownHours = 20,
	},

	{
		id = "challenge_deep_run",
		type = "challenge",
		name = "Deep Run",
		summary = "Reach a chain of 25 without banking, and then bank it.",
		description = "The multiplier is not the hard part. The instability is.",
		prerequisites = { "plains_the_long_road" },
		objectives = {
			{ id = "chain_25", type = "chain", target = 25, description = "Reach a chain of 25" },
			{ id = "bank_chain", type = "bank", target = 1, mode = "deposits", afterObjective = "chain_25", description = "Bank without losing it" },
		},
		rewards = { watts = 12000, xp = 7000, cores = 6, title = "unbanked" },
		repeatable = true,
		cooldownHours = 20,
	},

	{
		id = "challenge_untouched",
		type = "challenge",
		name = "Untouched",
		summary = "Bank 5,000 energy in one run without taking any damage at all.",
		description = "Not less damage. None.",
		prerequisites = { "grid_open_the_gate" },
		requiredLevel = 20,
		objectives = {
			{ id = "flawless_bank", type = "bank", target = 5000, mode = "single_deposit", condition = "no_damage_taken", description = "Bank 5,000 energy without taking damage" },
		},
		rewards = { watts = 18000, xp = 11000, cores = 10, title = "untouched" },
		repeatable = true,
		cooldownHours = 20,
	},

	{
		id = "challenge_speed_route",
		type = "challenge",
		name = "The Route",
		summary = "Halworth to Stiltmoor to Substation Alpha in under four minutes.",
		description = "Fast travel does not count. Obviously.",
		prerequisites = { "grid_open_the_gate" },
		objectives = {
			{ id = "route_time", type = "route", checkpoints = { "ft_halworth", "ft_stiltmoor", "ft_grid" }, target = 240, description = "Complete the route in under 4 minutes" },
		},
		rewards = { watts = 15000, xp = 9000, title = "courier" },
		repeatable = true,
		cooldownHours = 20,
		leaderboard = "route_halworth_grid",
	},

	{
		id = "challenge_storm_scholar",
		type = "challenge",
		name = "Storm Scholar",
		summary = "Capture from twelve different storm types in a single session.",
		description = "You will have to cross most of the world to do it.",
		prerequisites = { "city_above_the_line" },
		requiredLevel = 34,
		objectives = {
			{ id = "unique_storms", type = "capture", target = 12, distinctStormTypes = true, sameSession = true, description = "Capture 12 distinct storm types" },
		},
		rewards = { watts = 40000, xp = 26000, cores = 24, title = "scholar" },
		repeatable = true,
		cooldownHours = 44,
	},

	{
		id = "challenge_the_gauntlet",
		type = "challenge",
		name = "The Gauntlet",
		summary = "Survive ten minutes in the Scour without banking and without venting.",
		description = "The ambient charge alone will end most attempts before the storms get involved.",
		prerequisites = { "scour_what_started_it" },
		requiredLevel = 46,
		objectives = {
			{ id = "gauntlet", type = "survive", region = "electrical_wasteland", target = 600, condition = "no_bank_no_vent", description = "Survive 10 minutes, no bank, no vent" },
		},
		rewards = { watts = 65000, xp = 42000, cores = 40, title = "scoured" },
		repeatable = true,
		cooldownHours = 44,
	},

	{
		id = "challenge_solo_pulse",
		type = "challenge",
		name = "Alone at the Centre",
		summary = "Take a Core Pulse solo. It is built for three.",
		description = "The overload will hurt. Bring containment.",
		prerequisites = { "core_the_wall" },
		requiredLevel = 84,
		objectives = {
			{ id = "solo_pulse", type = "capture", target = 1, storm = "core_pulse", condition = "solo", description = "Capture a Core Pulse alone" },
		},
		rewards = { watts = 260000, xp = 180000, cores = 150, title = "singular" },
		repeatable = true,
		cooldownHours = 68,
	},

	{
		id = "challenge_no_upgrades",
		type = "challenge",
		name = "Bare Hands",
		summary = "Bank 2,000 energy with every equipment slot empty.",
		description = "No device. No cell. No plating. Just timing.",
		prerequisites = { "city_the_line" },
		requiredLevel = 25,
		objectives = {
			{ id = "naked_bank", type = "bank", target = 2000, mode = "cumulative_run", condition = "no_equipment", description = "Bank 2,000 energy with nothing equipped" },
		},
		rewards = { watts = 22000, xp = 14000, title = "purist" },
		repeatable = true,
		cooldownHours = 44,
	},
}

-- ============================================================================
-- Rotating quest templates. QuestService instantiates these daily/weekly with
-- region and target values scaled to the player's progression.
-- ============================================================================

Quests.DailyTemplates = {
	{
		id = "daily_capture_count",
		name = "Field Work",
		summaryFormat = "Capture %d storms in %s.",
		type = "daily",
		objectiveType = "capture",
		baseTarget = 25,
		targetPerLevel = 0.8,
		scalesWithRegion = true,
		rewards = { wattsPerLevel = 90, xpPerLevel = 55 },
	},
	{
		id = "daily_bank_total",
		name = "Deposit",
		summaryFormat = "Bank %d energy.",
		type = "daily",
		objectiveType = "bank",
		baseTarget = 1200,
		targetPerLevel = 90,
		rewards = { wattsPerLevel = 110, xpPerLevel = 60 },
	},
	{
		id = "daily_perfect_captures",
		name = "Precision",
		summaryFormat = "Land %d Perfect captures.",
		type = "daily",
		objectiveType = "capture",
		grade = "Perfect",
		baseTarget = 10,
		targetPerLevel = 0.35,
		rewards = { wattsPerLevel = 130, xpPerLevel = 75 },
	},
	{
		id = "daily_chain",
		name = "Hold the Line",
		summaryFormat = "Reach a chain of %d.",
		type = "daily",
		objectiveType = "chain",
		baseTarget = 12,
		targetPerLevel = 0.15,
		rewards = { wattsPerLevel = 140, xpPerLevel = 80 },
	},
	{
		id = "daily_resource",
		name = "Salvage Run",
		summaryFormat = "Collect %d %s.",
		type = "daily",
		objectiveType = "collect",
		baseTarget = 20,
		targetPerLevel = 0.5,
		scalesWithRegion = true,
		rewards = { wattsPerLevel = 100, xpPerLevel = 50 },
	},
	{
		id = "daily_discover",
		name = "Survey",
		summaryFormat = "Find %d undiscovered locations.",
		type = "daily",
		objectiveType = "discover",
		baseTarget = 2,
		targetPerLevel = 0,
		rewards = { wattsPerLevel = 160, xpPerLevel = 110 },
	},
	{
		id = "daily_event",
		name = "All Hands",
		summaryFormat = "Participate in %d world event.",
		type = "daily",
		objectiveType = "event",
		baseTarget = 1,
		targetPerLevel = 0,
		rewards = { wattsPerLevel = 200, xpPerLevel = 140, cores = 2 },
	},
}

Quests.WeeklyTemplates = {
	{
		id = "weekly_grand_total",
		name = "The Week's Work",
		summaryFormat = "Bank %d energy this week.",
		type = "weekly",
		objectiveType = "bank",
		baseTarget = 30000,
		targetPerLevel = 2200,
		rewards = { wattsPerLevel = 900, xpPerLevel = 600, cores = 15 },
	},
	{
		id = "weekly_rare_storms",
		name = "Rare Weather",
		summaryFormat = "Capture %d rare-or-better storms.",
		type = "weekly",
		objectiveType = "capture",
		minRarity = "rare",
		baseTarget = 20,
		targetPerLevel = 0.4,
		rewards = { wattsPerLevel = 1100, xpPerLevel = 700, cores = 20 },
	},
	{
		id = "weekly_challenges",
		name = "Prove It",
		summaryFormat = "Complete %d mastery challenges.",
		type = "weekly",
		objectiveType = "challenge",
		baseTarget = 3,
		targetPerLevel = 0,
		rewards = { wattsPerLevel = 1400, xpPerLevel = 900, cores = 30 },
	},
	{
		id = "weekly_regions",
		name = "Wide Ranging",
		summaryFormat = "Capture in %d different regions.",
		type = "weekly",
		objectiveType = "capture",
		distinctRegions = true,
		baseTarget = 4,
		targetPerLevel = 0,
		rewards = { wattsPerLevel = 1000, xpPerLevel = 650, cores = 18 },
	},
	{
		id = "weekly_events",
		name = "When It Matters",
		summaryFormat = "Place top-three in %d world events.",
		type = "weekly",
		objectiveType = "event",
		requiresTopContribution = 3,
		baseTarget = 2,
		targetPerLevel = 0,
		rewards = { wattsPerLevel = 1600, xpPerLevel = 1100, cores = 40 },
	},
}

-- ============================================================================
-- Lookups and helpers
-- ============================================================================

Quests.ById = {}
Quests.ByRegion = {}
Quests.MainChain = {}

for _, quest in ipairs(Quests.List) do
	Quests.ById[quest.id] = quest
	if quest.region then
		Quests.ByRegion[quest.region] = Quests.ByRegion[quest.region] or {}
		table.insert(Quests.ByRegion[quest.region], quest.id)
	end
	if quest.type == "main" then
		table.insert(Quests.MainChain, quest.id)
	end
end

table.sort(Quests.MainChain, function(a, b)
	return (Quests.ById[a].order or 0) < (Quests.ById[b].order or 0)
end)

Quests.DailyTemplateById = {}
for _, template in ipairs(Quests.DailyTemplates) do
	Quests.DailyTemplateById[template.id] = template
end
Quests.WeeklyTemplateById = {}
for _, template in ipairs(Quests.WeeklyTemplates) do
	Quests.WeeklyTemplateById[template.id] = template
end

function Quests.Get(questId: string)
	return Quests.ById[questId]
end

--[[
	Whether a quest is currently offerable.
	Returns (available, reasonKey, detail).
]]
function Quests.IsAvailable(questId: string, state: {
	level: number,
	completedQuests: { [string]: boolean },
	activeQuests: { [string]: any },
	questCooldowns: { [string]: number }?,
	now: number?,
}): (boolean, string?, any)
	local quest = Quests.ById[questId]
	if not quest then
		return false, "unknown_quest", nil
	end

	if state.activeQuests[questId] then
		return false, "already_active", nil
	end

	if state.completedQuests[questId] and not quest.repeatable then
		return false, "already_completed", nil
	end

	if quest.repeatable and quest.cooldownHours and state.questCooldowns then
		local readyAt = state.questCooldowns[questId]
		if readyAt and (state.now or 0) < readyAt then
			return false, "on_cooldown", readyAt
		end
	end

	if quest.requiredLevel and state.level < quest.requiredLevel then
		return false, "level", quest.requiredLevel
	end

	for _, prerequisiteId in ipairs(quest.prerequisites or {}) do
		if not state.completedQuests[prerequisiteId] then
			return false, "prerequisite", prerequisiteId
		end
	end

	return true, nil, nil
end

--[[ The next incomplete main-chain quest — the answer to "what should I do now?". ]]
function Quests.GetNextMainQuest(completedQuests: { [string]: boolean }): any?
	for _, questId in ipairs(Quests.MainChain) do
		if not completedQuests[questId] then
			return Quests.ById[questId]
		end
	end
	return nil
end

--[[ Main-chain completion as a 0..1 fraction, for the profile screen. ]]
function Quests.GetMainProgress(completedQuests: { [string]: boolean }): (number, number, number)
	local done = 0
	for _, questId in ipairs(Quests.MainChain) do
		if completedQuests[questId] then
			done += 1
		end
	end
	local total = #Quests.MainChain
	return done / total, done, total
end

--[[
	Instantiates a rotating quest from a template, scaling targets to the player's
	level so a level-90 daily is not the same twenty captures as a level-4 one.
]]
function Quests.InstantiateTemplate(template: any, level: number, seedContext: { region: string?, resource: string? }?)
	local target = math.floor(template.baseTarget + template.targetPerLevel * level + 0.5)
	local context = seedContext or {}

	local rewards = {}
	if template.rewards.wattsPerLevel then
		rewards.watts = math.floor(template.rewards.wattsPerLevel * math.max(1, level) + 0.5)
	end
	if template.rewards.xpPerLevel then
		rewards.xp = math.floor(template.rewards.xpPerLevel * math.max(1, level) + 0.5)
	end
	if template.rewards.cores then
		rewards.cores = template.rewards.cores
	end

	return {
		templateId = template.id,
		name = template.name,
		type = template.type,
		target = target,
		progress = 0,
		region = context.region,
		resource = context.resource,
		objectiveType = template.objectiveType,
		grade = template.grade,
		minRarity = template.minRarity,
		distinctRegions = template.distinctRegions,
		requiresTopContribution = template.requiresTopContribution,
		rewards = rewards,
	}
end

--[[ Every quest a player could start right now, sorted main-first. ]]
function Quests.GetAvailable(state: any): { any }
	local available = {}
	for _, quest in ipairs(Quests.List) do
		if Quests.IsAvailable(quest.id, state) then
			table.insert(available, quest)
		end
	end
	table.sort(available, function(a, b)
		local aMain = a.type == "main" and 0 or 1
		local bMain = b.type == "main" and 0 or 1
		if aMain ~= bMain then
			return aMain < bMain
		end
		return (a.order or 999) < (b.order or 999)
	end)
	return available
end

return TableUtil.DeepFreeze(Quests)
