--!strict
--[[
	Regions
	-------
	The world atlas. Ten regions plus the prestige layer, laid out on a single
	continuous map roughly 17,000 studs across (~5.2 km, ~10 square miles of
	traversable space once vertical layers are counted).

	Layout philosophy: the Starter District sits at the origin with clear sightlines
	to four future regions. Every region is placed so that at least two others are
	visible from its high ground, which is what turns "what is that?" into a goal.

	Coordinates are plain tables rather than Vector3 so this module stays a pure data
	file that loads and validates outside a Roblox runtime.

	Schema per region:
		id                 stable key used in saves; never rename
		name / subtitle    presentation
		order              progression order, drives map sorting and gating hints
		center {X,Y,Z}     world-space centre of the region volume
		radius             horizontal extent in studs
		verticalRange      {min, max} Y bounds of playable space
		danger             1-10, feeds exposure damage and risk multipliers
		recommendedLevel   shown on the map; not a hard gate
		unlock             hard gate: level / quest / cost / traversal ability
		palette            colour identity as hex strings (parsed by the client)
		atmosphere         fog, haze and wind values for the client's region blender
		audio              music and ambience ids
		storms             which storm types spawn here and how often
		hazards            environmental threats unique to the region
		resources          crafting material drop weights
		subregions         named areas inside the region with their own character
		landmarks          ids referencing Landmarks.luau
		bankStations       banking infrastructure positions
		fastTravel         travel node (nil for regions with no direct route in)
		discoveryCount     how many hidden discoveries exist here
		traversalHint      what movement tech makes this region click
]]

local TableUtil = require(script.Parent.Parent.Core.TableUtil)

local Regions = {}

-- ============================================================================
-- Region definitions, in progression order
-- ============================================================================

Regions.List = {

	-- ------------------------------------------------------------------ 1
	{
		id = "starter_district",
		name = "Halworth Station",
		subtitle = "Starter District",
		order = 1,
		center = { X = 0, Y = 0, Z = 0 },
		radius = 900,
		verticalRange = { min = -60, max = 340 },
		danger = 1,
		recommendedLevel = 1,
		unlock = {},

		palette = {
			fog = "1A2230",
			ambient = "202B3C",
			key = "9FB4D4",
			accent = "58C8FF",
			energy = "7BE0FF",
			terrain = "3E4A57",
		},
		atmosphere = {
			fogStart = 180,
			fogEnd = 1400,
			density = 0.28,
			haze = 1.1,
			glare = 0.12,
			windSpeed = 8,
			cloudCover = 0.55,
			rainIntensity = 0.15,
		},
		audio = {
			ambient = "amb_district_wind",
			music = "mus_halworth_calm",
			tension = "mus_halworth_tension",
		},

		storms = {
			baseSpawnInterval = 26,
			maxConcurrent = 4,
			intensityScale = 0.6,
			types = {
				static_bloom = 62,
				drift_arc = 30,
				ground_crawler = 8,
			},
		},

		hazards = {},

		resources = {
			scrap_conductor = 60,
			cracked_insulator = 30,
			copper_winding = 10,
		},

		subregions = {
			{
				id = "halworth_yard",
				name = "The Yard",
				center = { X = 0, Y = 0, Z = 0 },
				radius = 280,
				role = "hub",
				description = "Cracked concrete, a working bank pylon, and the only three vending posts still lit.",
			},
			{
				id = "halworth_relay",
				name = "Relay Row",
				center = { X = 310, Y = 8, Z = -220 },
				radius = 240,
				role = "tutorial",
				description = "A line of half-height relay masts. Low, safe strikes at predictable intervals.",
			},
			{
				id = "halworth_overlook",
				name = "The Overlook",
				center = { X = -420, Y = 96, Z = 380 },
				radius = 200,
				role = "vista",
				description = "The ridge every new runner climbs. From here you can see the Grid, the Spire, and the wall.",
			},
			{
				id = "halworth_underyard",
				name = "Underyard",
				center = { X = 120, Y = -42, Z = 260 },
				radius = 180,
				role = "secret",
				description = "Flooded service tunnels beneath the yard. Somebody has been living down here.",
			},
		},

		landmarks = { "halworth_pylon", "the_overlook_mast", "wrecked_hauler" },

		bankStations = {
			{ id = "bank_halworth_main", position = { X = 0, Y = 4, Z = -40 }, tier = 1, name = "Halworth Pylon" },
			{ id = "bank_relay_row", position = { X = 330, Y = 6, Z = -260 }, tier = 1, name = "Relay Row Tap" },
		},

		fastTravel = { id = "ft_halworth", position = { X = -40, Y = 4, Z = 60 }, name = "Halworth Station" },

		discoveryCount = 6,
		traversalHint = "sprint",
	},

	-- ------------------------------------------------------------------ 2
	{
		id = "storm_plains",
		name = "The Sattermarsh",
		subtitle = "Storm Plains",
		order = 2,
		center = { X = 2750, Y = 0, Z = 350 },
		radius = 2250,
		verticalRange = { min = -80, max = 520 },
		danger = 2,
		recommendedLevel = 6,
		unlock = { level = 5 },

		palette = {
			fog = "1D2A2E",
			ambient = "24343A",
			key = "A8C6C2",
			accent = "6FE3C6",
			energy = "8FFFE0",
			terrain = "44544C",
		},
		atmosphere = {
			fogStart = 240,
			fogEnd = 2600,
			density = 0.34,
			haze = 1.4,
			glare = 0.18,
			windSpeed = 22,
			cloudCover = 0.72,
			rainIntensity = 0.45,
		},
		audio = {
			ambient = "amb_plains_gale",
			music = "mus_sattermarsh",
			tension = "mus_sattermarsh_tension",
		},

		storms = {
			baseSpawnInterval = 18,
			maxConcurrent = 7,
			intensityScale = 1.0,
			types = {
				static_bloom = 30,
				drift_arc = 34,
				ground_crawler = 16,
				sheet_front = 14,
				ball_lightning = 5,
				mirror_flash = 1,
			},
		},

		hazards = {
			{ id = "flooded_ground", severity = 1, description = "Standing water conducts. Strikes chain across the shallows." },
			{ id = "crosswind", severity = 1, description = "Gale gusts push you off narrow causeways." },
		},

		resources = {
			scrap_conductor = 34,
			cracked_insulator = 24,
			copper_winding = 22,
			marsh_salt = 16,
			storm_glass = 4,
		},

		subregions = {
			{
				id = "plains_causeway",
				name = "The Long Causeway",
				center = { X = 1500, Y = 6, Z = 200 },
				radius = 420,
				role = "traversal",
				description = "A raised road across the marsh. Fast, exposed, and the first place most runners die.",
			},
			{
				id = "plains_pylonfield",
				name = "Pylon Field",
				center = { X = 2900, Y = 12, Z = -400 },
				radius = 620,
				role = "farming",
				description = "Two hundred derelict transmission pylons. Strikes here arc between towers.",
			},
			{
				id = "plains_sinkhole",
				name = "The Sink",
				center = { X = 3400, Y = -64, Z = 900 },
				radius = 380,
				role = "challenge",
				description = "A collapsed basin that floods and drains with the storm cycle.",
			},
			{
				id = "plains_stiltvillage",
				name = "Stiltmoor",
				center = { X = 2100, Y = 24, Z = 1400 },
				radius = 340,
				role = "settlement",
				description = "Fishing platforms on stilts. Traders, a bank tap, and rumours about the Grid.",
			},
			{
				id = "plains_farsight",
				name = "Farsight Ridge",
				center = { X = 4300, Y = 180, Z = 700 },
				radius = 300,
				role = "vista",
				description = "The eastern rise. The Mountain and the Core wall both resolve from up here.",
			},
		},

		landmarks = { "the_leaning_array", "stiltmoor_beacon", "sunken_substation" },

		bankStations = {
			{ id = "bank_stiltmoor", position = { X = 2100, Y = 28, Z = 1400 }, tier = 2, name = "Stiltmoor Tap" },
			{ id = "bank_pylonfield", position = { X = 2880, Y = 14, Z = -380 }, tier = 2, name = "Field Substation" },
		},

		fastTravel = { id = "ft_stiltmoor", position = { X = 2080, Y = 28, Z = 1440 }, name = "Stiltmoor" },

		discoveryCount = 11,
		traversalHint = "slide",
	},

	-- ------------------------------------------------------------------ 3
	{
		id = "industrial_grid",
		name = "The Grid",
		subtitle = "Industrial Sector 7",
		order = 3,
		center = { X = -2600, Y = 0, Z = 1900 },
		radius = 1700,
		verticalRange = { min = -220, max = 760 },
		danger = 3,
		recommendedLevel = 14,
		unlock = { level = 12, quest = "plains_the_long_road" },

		palette = {
			fog = "241E1A",
			ambient = "2E2620",
			key = "D4B48C",
			accent = "FFA23D",
			energy = "FFD166",
			terrain = "4A423A",
		},
		atmosphere = {
			fogStart = 140,
			fogEnd = 1600,
			density = 0.46,
			haze = 1.9,
			glare = 0.3,
			windSpeed = 14,
			cloudCover = 0.85,
			rainIntensity = 0.2,
		},
		audio = {
			ambient = "amb_grid_machinery",
			music = "mus_grid_industrial",
			tension = "mus_grid_alarm",
		},

		storms = {
			baseSpawnInterval = 15,
			maxConcurrent = 8,
			intensityScale = 1.35,
			types = {
				drift_arc = 20,
				sheet_front = 22,
				ball_lightning = 14,
				transformer_cascade = 20,
				ground_crawler = 12,
				coil_resonance = 10,
				mirror_flash = 2,
			},
		},

		hazards = {
			{ id = "live_rail", severity = 2, description = "Energised third rails run the length of every catwalk." },
			{ id = "steam_vent", severity = 2, description = "Pressure vents fire on a cycle. Learn the rhythm." },
			{ id = "crusher_line", severity = 3, description = "Automated presses still running with nobody to stop them." },
		},

		resources = {
			copper_winding = 30,
			cracked_insulator = 18,
			industrial_alloy = 26,
			ferrite_core = 18,
			storm_glass = 7,
			capacitor_cell = 1,
		},

		subregions = {
			{
				id = "grid_substation_alpha",
				name = "Substation Alpha",
				center = { X = -2100, Y = 20, Z = 1500 },
				radius = 380,
				role = "farming",
				description = "Still energised after all these years. Nobody knows what is feeding it.",
			},
			{
				id = "grid_catwalks",
				name = "The Catwalks",
				center = { X = -2600, Y = 120, Z = 1900 },
				radius = 500,
				role = "traversal",
				description = "Three vertical levels of steel walkway. Falling is the main cause of death here.",
			},
			{
				id = "grid_foundry",
				name = "Foundry Nine",
				center = { X = -3200, Y = 40, Z = 2350 },
				radius = 420,
				role = "challenge",
				description = "Molten channels and a crusher line that never shut down.",
			},
			{
				id = "grid_servicetunnels",
				name = "Service Tunnels",
				center = { X = -2400, Y = -160, Z = 2100 },
				radius = 460,
				role = "secret",
				description = "Maintenance warrens under the whole sector. Shortcuts, if you memorise them.",
			},
			{
				id = "grid_reactorapron",
				name = "Reactor Apron",
				center = { X = -3600, Y = 30, Z = 1400 },
				radius = 340,
				role = "gate",
				description = "The approach to the old reactor. The air tastes like metal and the gate is sealed.",
			},
		},

		landmarks = { "reactor_seven", "the_stack", "cooling_towers" },

		bankStations = {
			{ id = "bank_grid_alpha", position = { X = -2100, Y = 24, Z = 1480 }, tier = 3, name = "Alpha Intake" },
			{ id = "bank_grid_catwalk", position = { X = -2600, Y = 126, Z = 1880 }, tier = 3, name = "Catwalk Tap" },
		},

		fastTravel = { id = "ft_grid", position = { X = -2140, Y = 24, Z = 1540 }, name = "Substation Alpha" },

		discoveryCount = 14,
		traversalHint = "mantle",
	},

	-- ------------------------------------------------------------------ 4
	{
		id = "city_region",
		name = "Verrick",
		subtitle = "The Drowned City",
		order = 4,
		center = { X = 300, Y = 0, Z = -4100 },
		radius = 2100,
		verticalRange = { min = -160, max = 1150 },
		danger = 4,
		recommendedLevel = 24,
		unlock = { level = 22, quest = "grid_open_the_gate" },

		palette = {
			fog = "191C29",
			ambient = "1F2436",
			key = "B4BFE0",
			accent = "8A7BFF",
			energy = "B9A6FF",
			terrain = "3A3F52",
		},
		atmosphere = {
			fogStart = 120,
			fogEnd = 2200,
			density = 0.42,
			haze = 1.6,
			glare = 0.22,
			windSpeed = 26,
			cloudCover = 0.9,
			rainIntensity = 0.7,
		},
		audio = {
			ambient = "amb_city_rain",
			music = "mus_verrick_neon",
			tension = "mus_verrick_chase",
		},

		storms = {
			baseSpawnInterval = 13,
			maxConcurrent = 9,
			intensityScale = 1.6,
			types = {
				sheet_front = 18,
				ball_lightning = 16,
				transformer_cascade = 14,
				spire_conductor = 20,
				coil_resonance = 12,
				chain_web = 14,
				mirror_flash = 5,
				null_pocket = 1,
			},
		},

		hazards = {
			{ id = "falling_glass", severity = 3, description = "Storm-loosened curtain wall sheds without warning." },
			{ id = "flooded_metro", severity = 3, description = "The tunnels are waist-deep and conductive." },
			{ id = "collapsing_floor", severity = 2, description = "Water damage. Some floors will not hold you." },
		},

		resources = {
			industrial_alloy = 22,
			ferrite_core = 20,
			storm_glass = 18,
			polymer_weave = 22,
			capacitor_cell = 14,
			resonant_shard = 4,
		},

		subregions = {
			{
				id = "city_rooftops",
				name = "The Upper Line",
				center = { X = 300, Y = 420, Z = -4100 },
				radius = 900,
				role = "traversal",
				description = "Rooftop-to-rooftop across half the city. The fastest route anywhere in Verrick.",
			},
			{
				id = "city_financial",
				name = "The Stack District",
				center = { X = 900, Y = 60, Z = -4600 },
				radius = 520,
				role = "farming",
				description = "Towers dense enough that lightning never reaches the street.",
			},
			{
				id = "city_metro",
				name = "Verrick Metro",
				center = { X = 0, Y = -110, Z = -4000 },
				radius = 780,
				role = "secret",
				description = "Six flooded lines and a maintenance depot nobody has opened in years.",
			},
			{
				id = "city_market",
				name = "Wharf Market",
				center = { X = -500, Y = 12, Z = -3400 },
				radius = 380,
				role = "settlement",
				description = "The largest surviving population in the world. Traders, contracts, and gossip.",
			},
			{
				id = "city_spire",
				name = "Verrick Spire",
				center = { X = 300, Y = 700, Z = -4100 },
				radius = 200,
				role = "challenge",
				description = "The tallest structure still standing. Strikes hit the mast every ninety seconds.",
			},
			{
				id = "city_quarantine",
				name = "The Quarantine",
				center = { X = 1200, Y = 20, Z = -3200 },
				radius = 440,
				role = "gate",
				description = "Nine blocks sealed behind blast barriers. The seal was made from the inside.",
			},
		},

		landmarks = { "verrick_spire", "the_broken_bridge", "cathedral_of_wires", "harbour_cranes" },

		bankStations = {
			{ id = "bank_wharf", position = { X = -500, Y = 16, Z = -3400 }, tier = 4, name = "Wharf Exchange" },
			{ id = "bank_stack", position = { X = 900, Y = 64, Z = -4600 }, tier = 4, name = "Stack Vault" },
			{ id = "bank_spire_base", position = { X = 300, Y = 20, Z = -4020 }, tier = 4, name = "Spire Footing" },
		},

		fastTravel = { id = "ft_verrick", position = { X = -480, Y = 16, Z = -3360 }, name = "Wharf Market" },

		discoveryCount = 22,
		traversalHint = "grapple",
	},

	-- ------------------------------------------------------------------ 5
	{
		id = "mountain_region",
		name = "Kalder Reach",
		subtitle = "The High Country",
		order = 5,
		center = { X = 5400, Y = 400, Z = 3200 },
		radius = 2400,
		verticalRange = { min = 0, max = 2100 },
		danger = 5,
		recommendedLevel = 34,
		unlock = { level = 32, quest = "city_above_the_line", traversal = "grapple" },

		palette = {
			fog = "1C2430",
			ambient = "27303E",
			key = "CBD8E6",
			accent = "5FA8FF",
			energy = "A5D8FF",
			terrain = "5A6270",
		},
		atmosphere = {
			fogStart = 300,
			fogEnd = 3600,
			density = 0.24,
			haze = 0.8,
			glare = 0.5,
			windSpeed = 38,
			cloudCover = 0.4,
			rainIntensity = 0.1,
			snowIntensity = 0.6,
		},
		audio = {
			ambient = "amb_mountain_wind",
			music = "mus_kalder_altitude",
			tension = "mus_kalder_storm",
		},

		storms = {
			baseSpawnInterval = 12,
			maxConcurrent = 8,
			intensityScale = 1.9,
			types = {
				sheet_front = 14,
				ball_lightning = 12,
				spire_conductor = 16,
				chain_web = 16,
				updraft_column = 20,
				hail_charge = 14,
				mirror_flash = 6,
				null_pocket = 2,
			},
		},

		hazards = {
			{ id = "altitude_wind", severity = 3, description = "Gusts strong enough to move you mid-jump." },
			{ id = "ice_sheet", severity = 3, description = "Frozen rock offers almost no grip." },
			{ id = "rockfall", severity = 4, description = "Strikes shear whole faces loose." },
			{ id = "thin_air", severity = 2, description = "Above 1400 studs, recovery is halved." },
		},

		resources = {
			storm_glass = 20,
			ferrite_core = 14,
			resonant_shard = 20,
			glacier_quartz = 24,
			capacitor_cell = 16,
			skyiron = 6,
		},

		subregions = {
			{
				id = "mountain_basecamp",
				name = "Halfway Camp",
				center = { X = 4400, Y = 320, Z = 2600 },
				radius = 300,
				role = "settlement",
				description = "Six tents, a bank tap and a climber who has been trying the summit for two years.",
			},
			{
				id = "mountain_switchbacks",
				name = "The Switchbacks",
				center = { X = 4900, Y = 700, Z = 3000 },
				radius = 520,
				role = "traversal",
				description = "Exposed ledges up the western face. No cover for four hundred studs.",
			},
			{
				id = "mountain_cavesystem",
				name = "The Hollow",
				center = { X = 5600, Y = 260, Z = 3800 },
				radius = 640,
				role = "secret",
				description = "Ice caves that go far deeper than the maps admit.",
			},
			{
				id = "mountain_summit",
				name = "Kalder Summit",
				center = { X = 5900, Y = 1750, Z = 3400 },
				radius = 360,
				role = "challenge",
				description = "Permanent electrical crown. The single richest capture site outside the Core.",
			},
			{
				id = "mountain_observatory",
				name = "The Observatory",
				center = { X = 6400, Y = 1180, Z = 2700 },
				radius = 280,
				role = "story",
				description = "Someone was watching the storms from here, and writing it all down.",
			},
		},

		landmarks = { "kalder_summit_crown", "the_observatory_dome", "hanging_bridge", "frozen_array" },

		bankStations = {
			{ id = "bank_halfway", position = { X = 4400, Y = 324, Z = 2600 }, tier = 5, name = "Halfway Tap" },
			{ id = "bank_observatory", position = { X = 6400, Y = 1184, Z = 2700 }, tier = 5, name = "Observatory Cache" },
		},

		fastTravel = { id = "ft_halfway", position = { X = 4360, Y = 324, Z = 2640 }, name = "Halfway Camp" },

		discoveryCount = 18,
		traversalHint = "glider",
	},

	-- ------------------------------------------------------------------ 6
	{
		id = "electrical_wasteland",
		name = "The Scour",
		subtitle = "Electrical Wasteland",
		order = 6,
		center = { X = -5300, Y = 0, Z = -2700 },
		radius = 2000,
		verticalRange = { min = -300, max = 640 },
		danger = 7,
		recommendedLevel = 46,
		unlock = { level = 44, quest = "mountain_what_the_watcher_saw" },

		palette = {
			fog = "2B1B2E",
			ambient = "331F38",
			key = "E0B4F0",
			accent = "FF4FD8",
			energy = "FF8AE8",
			terrain = "4E3350",
		},
		atmosphere = {
			fogStart = 90,
			fogEnd = 1300,
			density = 0.62,
			haze = 2.4,
			glare = 0.42,
			windSpeed = 30,
			cloudCover = 1.0,
			rainIntensity = 0.0,
			ashIntensity = 0.8,
		},
		audio = {
			ambient = "amb_scour_hum",
			music = "mus_scour_dread",
			tension = "mus_scour_surge",
		},

		storms = {
			baseSpawnInterval = 9,
			maxConcurrent = 11,
			intensityScale = 2.4,
			types = {
				chain_web = 20,
				coil_resonance = 14,
				null_pocket = 14,
				glass_storm = 20,
				ball_lightning = 10,
				transformer_cascade = 8,
				mirror_flash = 10,
				devourer = 4,
			},
		},

		hazards = {
			{ id = "ambient_charge", severity = 5, description = "The ground itself holds charge. Standing still costs health." },
			{ id = "glass_field", severity = 4, description = "Fulgurite forests. Sharp, conductive, and they shatter." },
			{ id = "magnetic_drag", severity = 4, description = "Metal equipment pulls toward the anomalies." },
			{ id = "sensor_blindness", severity = 3, description = "Scanners return noise. Your map lies here." },
		},

		resources = {
			resonant_shard = 22,
			glacier_quartz = 6,
			fulgurite_spine = 26,
			capacitor_cell = 18,
			skyiron = 14,
			null_residue = 12,
			ionised_dust = 2,
		},

		subregions = {
			{
				id = "wasteland_glassfields",
				name = "The Glass Fields",
				center = { X = -5000, Y = 10, Z = -2200 },
				radius = 700,
				role = "farming",
				description = "Kilometres of fused sand shaped into standing spines by ten thousand strikes.",
			},
			{
				id = "wasteland_crater",
				name = "Origin Crater",
				center = { X = -5900, Y = -180, Z = -3100 },
				radius = 520,
				role = "story",
				description = "Whatever happened here, it started at this exact point.",
			},
			{
				id = "wasteland_hulks",
				name = "The Hulks",
				center = { X = -4500, Y = 20, Z = -3300 },
				radius = 480,
				role = "challenge",
				description = "Convoy wrecks fused into a single mass of metal, still carrying current.",
			},
			{
				id = "wasteland_shelter",
				name = "Shelter Twelve",
				center = { X = -4200, Y = -60, Z = -2400 },
				radius = 260,
				role = "settlement",
				description = "The last safe room before the crater. Reinforced, grounded, and never empty.",
			},
			{
				id = "wasteland_nullzone",
				name = "The Quiet",
				center = { X = -6200, Y = 40, Z = -2000 },
				radius = 400,
				role = "secret",
				description = "A zone where the storms simply stop. Nothing grows and nothing arcs.",
			},
		},

		landmarks = { "the_origin_crater", "fulgurite_cathedral", "convoy_hulk", "shelter_twelve_door" },

		bankStations = {
			{ id = "bank_shelter12", position = { X = -4200, Y = -56, Z = -2400 }, tier = 6, name = "Shelter Twelve" },
		},

		fastTravel = { id = "ft_shelter12", position = { X = -4230, Y = -56, Z = -2360 }, name = "Shelter Twelve" },

		discoveryCount = 16,
		traversalHint = "air_dash",
	},

	-- ------------------------------------------------------------------ 7
	{
		id = "underground_network",
		name = "Deepline",
		subtitle = "Research Network",
		order = 7,
		center = { X = -900, Y = -620, Z = -1800 },
		radius = 2600,
		verticalRange = { min = -1400, max = -180 },
		-- Matches the Scour rather than dipping below it: total darkness plus active
		-- automated defences make this no safer than the surface wasteland.
		danger = 7,
		recommendedLevel = 52,
		unlock = { level = 50, quest = "scour_what_started_it" },

		palette = {
			fog = "10161A",
			ambient = "161E22",
			key = "9FE0C8",
			accent = "37F0A8",
			energy = "6BFFC4",
			terrain = "2A3236",
		},
		atmosphere = {
			fogStart = 40,
			fogEnd = 620,
			density = 0.75,
			haze = 2.0,
			glare = 0.06,
			windSpeed = 2,
			cloudCover = 0,
			rainIntensity = 0,
		},
		audio = {
			ambient = "amb_deepline_hum",
			music = "mus_deepline_mystery",
			tension = "mus_deepline_alarm",
		},

		storms = {
			baseSpawnInterval = 20,
			maxConcurrent = 6,
			intensityScale = 1.8,
			types = {
				coil_resonance = 26,
				null_pocket = 18,
				containment_breach = 24,
				chain_web = 12,
				mirror_flash = 12,
				devourer = 6,
				echo_bloom = 2,
			},
		},

		hazards = {
			{ id = "darkness", severity = 4, description = "No ambient light. Your lamp is the only reason you can read a strike." },
			{ id = "pressure_door", severity = 2, description = "Sections seal on a timer. Get caught and you wait." },
			{ id = "coolant_flood", severity = 4, description = "Superconducting coolant. Freezing and conductive at once." },
			{ id = "automated_defence", severity = 5, description = "The facility still considers you an intruder." },
		},

		resources = {
			capacitor_cell = 20,
			resonant_shard = 16,
			null_residue = 20,
			lab_alloy = 24,
			ionised_dust = 14,
			prototype_core = 6,
		},

		subregions = {
			{
				id = "deep_entryhall",
				name = "Intake Hall",
				center = { X = -400, Y = -260, Z = -1300 },
				radius = 340,
				role = "hub",
				description = "The only entrance that still opens. Emergency lighting, thirty years on.",
			},
			{
				id = "deep_labs",
				name = "Wet Labs",
				center = { X = -1100, Y = -520, Z = -1700 },
				radius = 620,
				role = "story",
				description = "Racks of containment vessels, most of them empty, a few of them not.",
			},
			{
				id = "deep_reactorring",
				name = "The Ring",
				center = { X = -1400, Y = -760, Z = -2300 },
				radius = 700,
				role = "challenge",
				description = "A circular accelerator two kilometres around. Still spinning up on a schedule.",
			},
			{
				id = "deep_archive",
				name = "The Archive",
				center = { X = -200, Y = -900, Z = -2600 },
				radius = 380,
				role = "secret",
				description = "Every log, every result, every decision. Somebody wanted this found.",
			},
			{
				id = "deep_belowring",
				name = "Sublevel Nine",
				center = { X = -1700, Y = -1250, Z = -2000 },
				radius = 460,
				role = "gate",
				description = "Below the Ring. The map ends here. The corridor does not.",
			},
		},

		landmarks = { "the_ring", "containment_wall", "archive_door", "sublevel_nine_stair" },

		bankStations = {
			{ id = "bank_intake", position = { X = -400, Y = -256, Z = -1300 }, tier = 6, name = "Intake Terminal" },
			{ id = "bank_archive", position = { X = -200, Y = -896, Z = -2600 }, tier = 7, name = "Archive Terminal" },
		},

		fastTravel = { id = "ft_intake", position = { X = -360, Y = -256, Z = -1260 }, name = "Intake Hall" },

		discoveryCount = 24,
		traversalHint = "zipline",
	},

	-- ------------------------------------------------------------------ 8
	{
		id = "high_altitude",
		name = "The Anchorage",
		subtitle = "High-Altitude Network",
		order = 8,
		center = { X = 2400, Y = 2200, Z = 1600 },
		radius = 2000,
		verticalRange = { min = 1500, max = 3400 },
		danger = 8,
		recommendedLevel = 64,
		unlock = { level = 62, quest = "deep_sublevel_nine", traversal = "glider" },

		palette = {
			fog = "141C2C",
			ambient = "1B2438",
			key = "C8D8FF",
			accent = "4FE0FF",
			energy = "9FF0FF",
			terrain = "465268",
		},
		atmosphere = {
			fogStart = 400,
			fogEnd = 5200,
			density = 0.16,
			haze = 0.5,
			glare = 0.72,
			windSpeed = 52,
			cloudCover = 0.3,
			rainIntensity = 0,
		},
		audio = {
			ambient = "amb_anchorage_highwind",
			music = "mus_anchorage_vast",
			tension = "mus_anchorage_fall",
		},

		storms = {
			baseSpawnInterval = 10,
			maxConcurrent = 9,
			intensityScale = 2.8,
			types = {
				updraft_column = 24,
				sheet_front = 12,
				spire_conductor = 14,
				chain_web = 12,
				hail_charge = 10,
				mirror_flash = 10,
				null_pocket = 8,
				echo_bloom = 8,
				devourer = 2,
			},
		},

		hazards = {
			{ id = "the_drop", severity = 6, description = "Two thousand studs of nothing. There is no fall you survive." },
			{ id = "platform_sway", severity = 4, description = "The stations move in the wind. Aim accordingly." },
			{ id = "decompression", severity = 4, description = "Breached modules vent hard enough to throw you clear." },
			{ id = "static_saturation", severity = 5, description = "Everything up here is charged, including you." },
		},

		resources = {
			skyiron = 26,
			capacitor_cell = 16,
			resonant_shard = 14,
			null_residue = 12,
			ionised_dust = 18,
			prototype_core = 10,
			storm_alloy = 4,
		},

		subregions = {
			{
				id = "high_mainplatform",
				name = "Anchorage Prime",
				center = { X = 2400, Y = 2200, Z = 1600 },
				radius = 420,
				role = "hub",
				description = "The one platform with a working dock, a bank, and floor you can trust.",
			},
			{
				id = "high_harvestring",
				name = "The Harvest Ring",
				center = { X = 3100, Y = 2450, Z = 1900 },
				radius = 620,
				role = "farming",
				description = "Twelve collector arms rotating through the cloud layer, harvesting continuously.",
			},
			{
				id = "high_scaffold",
				name = "The Scaffold",
				center = { X = 1800, Y = 2000, Z = 1200 },
				radius = 560,
				role = "traversal",
				description = "Unfinished structure connecting everything. No railings were ever installed.",
			},
			{
				id = "high_launchdeck",
				name = "Launch Deck",
                center = { X = 2700, Y = 2800, Z = 900 },
				radius = 320,
				role = "challenge",
				description = "Catapult rails aimed at the Core. Somebody intended to go there deliberately.",
			},
			{
				id = "high_derelict",
				name = "Station Six",
				center = { X = 1500, Y = 2650, Z = 2300 },
				radius = 380,
				role = "secret",
				description = "Adrift, unpowered, and still transmitting.",
			},
		},

		landmarks = { "anchorage_prime_mast", "the_harvest_ring", "launch_rails", "station_six_wreck" },

		bankStations = {
			{ id = "bank_anchorage", position = { X = 2400, Y = 2204, Z = 1600 }, tier = 7, name = "Anchorage Vault" },
			{ id = "bank_harvest", position = { X = 3100, Y = 2454, Z = 1900 }, tier = 7, name = "Ring Collector" },
		},

		fastTravel = { id = "ft_anchorage", position = { X = 2440, Y = 2204, Z = 1560 }, name = "Anchorage Prime" },

		discoveryCount = 15,
		traversalHint = "storm_surf",
	},

	-- ------------------------------------------------------------------ 9
	{
		id = "storm_core",
		name = "The Core",
		subtitle = "Permanent Storm System",
		order = 9,
		center = { X = 300, Y = 600, Z = 7400 },
		radius = 2600,
		verticalRange = { min = -200, max = 2800 },
		danger = 10,
		recommendedLevel = 84,
		unlock = { level = 82, quest = "high_the_launch", traversal = "storm_surf" },

		palette = {
			fog = "0E1420",
			ambient = "141C2E",
			key = "DCE8FF",
			accent = "FFE24F",
			energy = "FFF3A0",
			terrain = "2E3646",
		},
		atmosphere = {
			fogStart = 60,
			fogEnd = 1800,
			density = 0.7,
			haze = 2.8,
			glare = 0.9,
			windSpeed = 68,
			cloudCover = 1.0,
			rainIntensity = 0.9,
		},
		audio = {
			ambient = "amb_core_roar",
			music = "mus_core_eye",
			tension = "mus_core_wall",
		},

		storms = {
			baseSpawnInterval = 6,
			maxConcurrent = 14,
			intensityScale = 4.0,
			types = {
				chain_web = 14,
				updraft_column = 12,
				spire_conductor = 10,
				glass_storm = 10,
				null_pocket = 10,
				echo_bloom = 14,
				devourer = 12,
				core_pulse = 14,
				the_eye = 4,
			},
		},

		hazards = {
			{ id = "the_wall", severity = 8, description = "A rotating front of continuous discharge. It does not stop." },
			{ id = "pressure_shear", severity = 7, description = "Wind layers moving in opposite directions." },
			{ id = "total_saturation", severity = 8, description = "Instability climbs even with an empty cell." },
			{ id = "the_watchers", severity = 6, description = "Some of the storms in here appear to be looking for you." },
		},

		resources = {
			storm_alloy = 24,
			prototype_core = 18,
			ionised_dust = 20,
			null_residue = 14,
			skyiron = 10,
			core_filament = 12,
			eye_fragment = 2,
		},

		subregions = {
			{
				id = "core_outerwall",
				name = "The Outer Wall",
				center = { X = 300, Y = 400, Z = 5600 },
				radius = 700,
				role = "gate",
				description = "The first band. Survivable, briefly, with the right gear.",
			},
			{
				id = "core_spiralband",
				name = "The Spiral",
				center = { X = 300, Y = 900, Z = 6600 },
				radius = 900,
				role = "challenge",
				description = "Debris caught in permanent orbit. The only footing between the wall and the eye.",
			},
			{
				id = "core_stillpoint",
				name = "The Eye",
				center = { X = 300, Y = 1200, Z = 7400 },
				radius = 500,
				role = "story",
				description = "Perfect calm at the centre of the worst weather on the planet. That is not natural.",
			},
			{
				id = "core_undercore",
				name = "Beneath the Eye",
				center = { X = 300, Y = -100, Z = 7400 },
				radius = 420,
				role = "secret",
				description = "The storm is anchored to something. The anchor is down here.",
			},
			{
				id = "core_thronefield",
				name = "The Throne Field",
				center = { X = 900, Y = 1500, Z = 8200 },
				radius = 620,
				role = "endgame",
				description = "Where the largest phenomena gather. Nothing here is smaller than a building.",
			},
		},

		landmarks = { "the_wall_front", "the_eye_calm", "the_anchor", "throne_array" },

		bankStations = {
			{ id = "bank_outerwall", position = { X = 300, Y = 404, Z = 5560 }, tier = 8, name = "Wall Station" },
			{ id = "bank_eye", position = { X = 300, Y = 1204, Z = 7400 }, tier = 9, name = "Eye Terminal" },
		},

		fastTravel = { id = "ft_outerwall", position = { X = 300, Y = 404, Z = 5520 }, name = "The Outer Wall" },

		discoveryCount = 20,
		traversalHint = "rail",
	},

	-- ------------------------------------------------------------------ 10 (prestige)
	{
		id = "null_reach",
		name = "Null Reach",
		subtitle = "Beyond the Anchor",
		order = 10,
		center = { X = -7800, Y = 900, Z = 7200 },
		radius = 2200,
		verticalRange = { min = -600, max = 2600 },
		danger = 10,
		recommendedLevel = 120,
		unlock = { prestige = 1, quest = "core_the_eye" },
		prestigeOnly = true,

		palette = {
			fog = "0A0A10",
			ambient = "101018",
			key = "FFFFFF",
			accent = "FF2E63",
			energy = "FF6B9D",
			terrain = "1C1C26",
		},
		atmosphere = {
			fogStart = 30,
			fogEnd = 900,
			density = 0.85,
			haze = 3.2,
			glare = 1.0,
			windSpeed = 0,
			cloudCover = 1.0,
			rainIntensity = 0,
		},
		audio = {
			ambient = "amb_null_silence",
			music = "mus_null_reach",
			tension = "mus_null_contact",
		},

		storms = {
			baseSpawnInterval = 8,
			maxConcurrent = 10,
			intensityScale = 5.0,
			types = {
				null_pocket = 22,
				echo_bloom = 20,
				devourer = 18,
				core_pulse = 16,
				the_eye = 12,
				inversion = 12,
			},
		},

		hazards = {
			{ id = "inverted_gravity", severity = 8, description = "Down is a suggestion here." },
			{ id = "memory_static", severity = 7, description = "Your HUD shows readings from runs you have not taken yet." },
			{ id = "absolute_null", severity = 9, description = "Zones where energy simply ceases to exist, carried or not." },
		},

		resources = {
			eye_fragment = 26,
			core_filament = 22,
			null_residue = 24,
			storm_alloy = 14,
			sigil_dust = 14,
		},

		subregions = {
			{
				id = "null_threshold",
				name = "The Threshold",
				center = { X = -7200, Y = 700, Z = 6600 },
				radius = 400,
				role = "hub",
				description = "The last place your equipment reports numbers you recognise.",
			},
			{
				id = "null_inversion",
				name = "The Inversion",
				center = { X = -7900, Y = 1300, Z = 7200 },
				radius = 720,
				role = "challenge",
				description = "The same terrain, rebuilt upside down, at the same time.",
			},
			{
				id = "null_echofield",
				name = "Echo Field",
				center = { X = -8400, Y = 500, Z = 7800 },
				radius = 640,
				role = "farming",
				description = "Storms that replay strikes from somewhere else. Read the past, catch the present.",
			},
			{
				id = "null_terminus",
				name = "Terminus",
				center = { X = -8800, Y = 1800, Z = 7000 },
				radius = 380,
				role = "endgame",
				description = "The end of the map, and something on the other side of it.",
			},
		},

		landmarks = { "the_threshold_gate", "inverted_spire", "terminus_door" },

		bankStations = {
			{ id = "bank_threshold", position = { X = -7200, Y = 704, Z = 6600 }, tier = 10, name = "Threshold Terminal" },
		},

		fastTravel = { id = "ft_threshold", position = { X = -7240, Y = 704, Z = 6560 }, name = "The Threshold" },

		discoveryCount = 12,
		traversalHint = "prestige_phase",
	},
}

-- ============================================================================
-- Derived lookups, built once at load
-- ============================================================================

Regions.ById = {}
Regions.Order = {}
Regions.SubregionsById = {}
Regions.BankStationsById = {}
Regions.FastTravelById = {}

for _, region in ipairs(Regions.List) do
	Regions.ById[region.id] = region
	table.insert(Regions.Order, region.id)

	for _, subregion in ipairs(region.subregions) do
		Regions.SubregionsById[subregion.id] = {
			regionId = region.id,
			data = subregion,
		}
	end
	for _, station in ipairs(region.bankStations) do
		Regions.BankStationsById[station.id] = {
			regionId = region.id,
			data = station,
		}
	end
	if region.fastTravel then
		Regions.FastTravelById[region.fastTravel.id] = {
			regionId = region.id,
			data = region.fastTravel,
		}
	end
end

--[[ Returns the region definition for an id, or nil. ]]
function Regions.Get(regionId: string)
	return Regions.ById[regionId]
end

--[[ Returns the first region whose horizontal disc contains the point, preferring
     the one whose vertical range also matches. Underground and high-altitude regions
     overlap surface regions in XZ, so the Y test is what disambiguates them. ]]
function Regions.FindContaining(x: number, y: number, z: number)
	local horizontalMatch = nil
	for _, region in ipairs(Regions.List) do
		local dx = x - region.center.X
		local dz = z - region.center.Z
		if dx * dx + dz * dz <= region.radius * region.radius then
			if y >= region.verticalRange.min and y <= region.verticalRange.max then
				return region
			end
			horizontalMatch = horizontalMatch or region
		end
	end
	return horizontalMatch
end

--[[ Distance from a point to a region's centre, on the horizontal plane. ]]
function Regions.HorizontalDistanceTo(regionId: string, x: number, z: number): number
	local region = Regions.ById[regionId]
	if not region then
		return math.huge
	end
	local dx = x - region.center.X
	local dz = z - region.center.Z
	return math.sqrt(dx * dx + dz * dz)
end

--[[ All regions a player has unlocked, given their progression state. ]]
function Regions.GetUnlocked(state: {
	level: number,
	prestige: number,
	completedQuests: { [string]: boolean },
	traversal: { [string]: boolean },
}): { string }
	local unlocked = {}
	for _, region in ipairs(Regions.List) do
		if Regions.IsUnlocked(region.id, state) then
			table.insert(unlocked, region.id)
		end
	end
	return unlocked
end

--[[
	Evaluates a region's gate. Returns (unlocked, reasonKey, requirementValue) so the
	UI can say exactly what is missing rather than a generic "locked".
]]
function Regions.IsUnlocked(regionId: string, state: {
	level: number,
	prestige: number,
	completedQuests: { [string]: boolean },
	traversal: { [string]: boolean },
}): (boolean, string?, any)
	local region = Regions.ById[regionId]
	if not region then
		return false, "unknown", nil
	end
	local unlock = region.unlock
	if unlock.prestige and (state.prestige or 0) < unlock.prestige then
		return false, "prestige", unlock.prestige
	end
	if unlock.level and (state.level or 1) < unlock.level then
		return false, "level", unlock.level
	end
	if unlock.quest and not (state.completedQuests and state.completedQuests[unlock.quest]) then
		return false, "quest", unlock.quest
	end
	if unlock.traversal and not (state.traversal and state.traversal[unlock.traversal]) then
		return false, "traversal", unlock.traversal
	end
	return true, nil, nil
end

--[[ The next locked region in progression order — what the UI should point at. ]]
function Regions.GetNextLocked(state: any): (any?, string?, any)
	for _, region in ipairs(Regions.List) do
		local unlocked, reason, value = Regions.IsUnlocked(region.id, state)
		if not unlocked then
			return region, reason, value
		end
	end
	return nil, nil, nil
end

--[[ Total count of discoverable secrets across the whole world. ]]
function Regions.TotalDiscoveries(): number
	local total = 0
	for _, region in ipairs(Regions.List) do
		total += region.discoveryCount
	end
	return total
end

--[[ World bounds, computed from region extents. Used by the map UI and the
     world generator to size the terrain. ]]
function Regions.GetWorldBounds(): { minX: number, maxX: number, minZ: number, maxZ: number, minY: number, maxY: number }
	local minX, maxX = math.huge, -math.huge
	local minZ, maxZ = math.huge, -math.huge
	local minY, maxY = math.huge, -math.huge
	for _, region in ipairs(Regions.List) do
		minX = math.min(minX, region.center.X - region.radius)
		maxX = math.max(maxX, region.center.X + region.radius)
		minZ = math.min(minZ, region.center.Z - region.radius)
		maxZ = math.max(maxZ, region.center.Z + region.radius)
		minY = math.min(minY, region.verticalRange.min)
		maxY = math.max(maxY, region.verticalRange.max)
	end
	return { minX = minX, maxX = maxX, minZ = minZ, maxZ = maxZ, minY = minY, maxY = maxY }
end

return TableUtil.DeepFreeze(Regions)
