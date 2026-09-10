--!strict
--[[
	WorldEvents
	-----------
	Server-wide occurrences that interrupt whatever everyone was doing.

	The bar for an event: a player mid-run should look at the announcement and
	genuinely consider abandoning their plan. Events that can be safely ignored are
	just a different-coloured storm, so every entry here either changes the rules of
	the world, pays enough to be worth the detour, or threatens something the player
	already owns.

	Phases run in order. Each phase has a duration and its own objective; the event
	ends when the last phase resolves or the fail condition trips.
]]

local TableUtil = require(script.Parent.Parent.Core.TableUtil)

local WorldEvents = {}

WorldEvents.Scale = {
	MINOR = "minor",       -- one region, background, no announcement fanfare
	MAJOR = "major",       -- one region, server announcement, visible from adjacent regions
	WORLD = "world",       -- multiple regions, full-screen announcement, changes the map
}

WorldEvents.List = {

	{
		id = "event_superstorm",
		name = "Superstorm",
		scale = "world",
		weight = 100,
		minPlayers = 2,
		minLevel = 8,
		regions = { "storm_plains", "industrial_grid", "city_region", "mountain_region" },
		announcement = "A superstorm front is crossing the world. Everything in its path is live.",
		description = "A single enormous cell walks a path across several regions. Everything inside its footprint pays double and hurts double.",
		durationSeconds = 480,
		warningSeconds = 45,
		visibleFromAnywhere = true,

		phases = {
			{
				id = "approach",
				name = "Approach",
				duration = 60,
				objective = "reposition",
				description = "The front is visible on the horizon. Get where you want to be.",
				effects = { stormSpawnMultiplier = 1.4 },
			},
			{
				id = "front",
				name = "The Front",
				duration = 300,
				objective = "capture",
				description = "Capture inside the front. Everything is doubled, including the danger.",
				effects = {
					stormSpawnMultiplier = 3.0,
					captureYieldMultiplier = 2.0,
					exposureDamageMultiplier = 2.0,
					forcedStormTypes = { "sheet_front", "chain_web", "ball_lightning" },
				},
				contribution = { source = "energy_captured", weight = 1.0 },
			},
			{
				id = "wake",
				name = "The Wake",
				duration = 120,
				objective = "collect",
				description = "The front has passed. It left a great deal behind.",
				effects = { resourceSpawnMultiplier = 4.0, stormSpawnMultiplier = 0.5 },
				contribution = { source = "resources_collected", weight = 0.5 },
			},
		},

		rewards = {
			participationXp = 2200,
			participationWatts = 9000,
			topContributorCores = 45,
			lootTable = "legendary_storm_cache",
			lootRolls = 2,
		},
	},

	{
		id = "event_blackout",
		name = "Blackout",
		scale = "world",
		weight = 70,
		minPlayers = 2,
		minLevel = 14,
		regions = { "industrial_grid", "city_region", "underground_network" },
		announcement = "Grid failure. Bank stations and fast travel are offline.",
		description = "Infrastructure drops out world-wide. Every bank station, relay and zipline stops working, and the only way to secure a carry is to reach one of three emergency taps.",
		durationSeconds = 420,
		warningSeconds = 30,
		visibleFromAnywhere = true,

		phases = {
			{
				id = "failure",
				name = "Failure",
				duration = 300,
				objective = "survive",
				description = "Banking is offline. Reach an emergency tap or hold what you have.",
				effects = {
					disableBankStations = true,
					disableFastTravel = true,
					emergencyTapCount = 3,
					instabilityRateMultiplier = 1.3,
					captureYieldMultiplier = 1.6,
				},
				contribution = { source = "energy_banked_at_taps", weight = 1.0 },
			},
			{
				id = "restoration",
				name = "Restoration",
				duration = 120,
				objective = "repair",
				description = "Feed energy into the substations to bring the grid back.",
				effects = { repairTargetCount = 4, repairEnergyEach = 3000 },
				contribution = { source = "energy_donated", weight = 1.4 },
			},
		},

		rewards = {
			participationXp = 1800,
			participationWatts = 7500,
			topContributorCores = 35,
			lootTable = "industrial_salvage",
			lootRolls = 3,
		},
	},

	{
		id = "event_energy_surge",
		name = "Energy Surge",
		scale = "major",
		weight = 130,
		minPlayers = 1,
		minLevel = 4,
		regions = { "starter_district", "storm_plains", "industrial_grid", "city_region", "mountain_region", "electrical_wasteland" },
		announcement = "Atmospheric surge. Yields across the region are climbing.",
		description = "A single region's storms briefly pay far more than they should. Short, frequent, and the reason to keep an eye on the map even during a quiet session.",
		durationSeconds = 240,
		warningSeconds = 20,
		visibleFromAnywhere = false,

		phases = {
			{
				id = "surge",
				name = "Surge",
				duration = 240,
				objective = "capture",
				description = "Everything in the region is worth more. Go.",
				effects = {
					captureYieldMultiplier = 2.5,
					stormSpawnMultiplier = 1.8,
					bankRateMultiplier = 1.4,
				},
				contribution = { source = "energy_banked", weight = 1.0 },
			},
		},

		rewards = {
			participationXp = 700,
			participationWatts = 2600,
			topContributorCores = 10,
			lootTable = "uncommon_components",
			lootRolls = 2,
		},
	},

	{
		id = "event_lightning_cascade",
		name = "Lightning Cascade",
		scale = "major",
		weight = 90,
		minPlayers = 2,
		minLevel = 20,
		regions = { "industrial_grid", "city_region", "electrical_wasteland", "high_altitude" },
		announcement = "Cascade forming. Chain conditions across the region.",
		description = "Every capture in the region arcs to nearby players and strike points. Coordinated groups can build chains that are impossible under normal conditions.",
		durationSeconds = 300,
		warningSeconds = 25,
		visibleFromAnywhere = false,

		phases = {
			{
				id = "cascade",
				name = "Cascade",
				duration = 300,
				objective = "chain",
				description = "Captures arc. Chain length is shared across everyone in range.",
				effects = {
					globalChainLink = true,
					chainLinkRadius = 140,
					sharedChainCounter = true,
					captureYieldMultiplier = 1.5,
					forcedStormTypes = { "chain_web", "transformer_cascade", "coil_resonance" },
				},
				contribution = { source = "chain_contribution", weight = 1.0 },
			},
		},

		rewards = {
			participationXp = 1400,
			participationWatts = 5200,
			topContributorCores = 22,
			lootTable = "resonant_materials",
			lootRolls = 3,
		},
	},

	{
		id = "event_storm_boss",
		name = "Convergence",
		scale = "world",
		weight = 55,
		minPlayers = 3,
		minLevel = 34,
		regions = { "mountain_region", "electrical_wasteland", "high_altitude", "storm_core" },
		announcement = "Convergence detected. Something very large is forming.",
		description = "Multiple cells merge into a single phenomenon with staged behaviour and a health pool. It cannot be solo'd, and it will not leave on its own.",
		durationSeconds = 600,
		warningSeconds = 60,
		visibleFromAnywhere = true,

		phases = {
			{
				id = "gathering",
				name = "Gathering",
				duration = 90,
				objective = "reposition",
				description = "Cells are converging on a single point. Get there.",
				effects = { stormSpawnMultiplier = 2.0, convergenceMarker = true },
			},
			{
				id = "core",
				name = "The Convergence",
				duration = 420,
				objective = "defeat",
				description = "Deplete it. Every capture takes a piece of it.",
				effects = {
					bossHealthBase = 40000,
					bossHealthPerPlayer = 14000,
					bossPhases = 3,
					bossEnrageAt = 360,
					forcedStormTypes = { "core_pulse", "devourer", "echo_bloom" },
				},
				contribution = { source = "boss_damage", weight = 1.0 },
				failCondition = { type = "timeout", consequence = "enrage_wipe" },
			},
			{
				id = "collapse",
				name = "Collapse",
				duration = 90,
				objective = "collect",
				description = "It is coming apart. Take everything before it disperses.",
				effects = { resourceSpawnMultiplier = 8.0, lootBurst = true },
				contribution = { source = "resources_collected", weight = 0.4 },
			},
		},

		rewards = {
			participationXp = 5200,
			participationWatts = 24000,
			topContributorCores = 120,
			lootTable = "legendary_storm_cache",
			lootRolls = 4,
			guaranteedForTop = 3,
		},
	},

	{
		id = "event_anomaly",
		name = "Anomaly",
		scale = "major",
		weight = 40,
		minPlayers = 1,
		minLevel = 40,
		regions = { "electrical_wasteland", "underground_network", "high_altitude", "storm_core" },
		announcement = "Spatial anomaly. A region that should not exist has opened.",
		description = "A temporary pocket region appears with its own rules, its own storms, and a hard closing time. Whatever is inside is gone when it shuts.",
		durationSeconds = 360,
		warningSeconds = 15,
		visibleFromAnywhere = true,

		phases = {
			{
				id = "open",
				name = "Open",
				duration = 300,
				objective = "explore",
				description = "Get in, take what you can, and be out before it closes.",
				effects = {
					spawnsPocketRegion = true,
					pocketRegionRules = { gravityScale = 0.5, instabilityRateMultiplier = 2.0, captureYieldMultiplier = 3.0 },
					forcedStormTypes = { "null_pocket", "echo_bloom", "mirror_flash" },
				},
				contribution = { source = "energy_captured", weight = 1.0 },
			},
			{
				id = "closing",
				name = "Closing",
				duration = 60,
				objective = "escape",
				description = "It is collapsing. Anyone still inside is ejected — and drops what they were carrying.",
				effects = { forcedEjection = true, ejectionCarryLoss = 0.5 },
			},
		},

		rewards = {
			participationXp = 3400,
			participationWatts = 14000,
			topContributorCores = 60,
			lootTable = "null_cache",
			lootRolls = 3,
		},
	},

	{
		id = "event_overload",
		name = "Overload",
		scale = "major",
		weight = 75,
		minPlayers = 2,
		minLevel = 24,
		regions = { "industrial_grid", "underground_network", "high_altitude" },
		announcement = "Infrastructure overload. Stabilise it or lose the sector.",
		description = "A cooperative repair event: several nodes are overloading at once and each one needs energy delivered while under fire. Failure costs the whole server a temporary debuff.",
		durationSeconds = 300,
		warningSeconds = 30,
		visibleFromAnywhere = false,

		phases = {
			{
				id = "stabilise",
				name = "Stabilise",
				duration = 300,
				objective = "deliver",
				description = "Carry energy to each overloading node. Do not bank it — deliver it.",
				effects = {
					nodeCount = 5,
					nodeEnergyEach = 4000,
					nodeDecayPerSecond = 12,
					deliveryRequiresCarry = true,
					exposureDamageMultiplier = 1.5,
				},
				contribution = { source = "energy_delivered", weight = 1.0 },
				failCondition = {
					type = "nodes_lost",
					threshold = 3,
					consequence = "region_debuff",
					debuff = { id = "sector_brownout", durationSeconds = 900, bankRateMultiplier = 0.7 },
				},
			},
		},

		rewards = {
			participationXp = 2000,
			participationWatts = 8200,
			topContributorCores = 28,
			lootTable = "lab_prototypes",
			lootRolls = 2,
		},
	},

	{
		id = "event_devourer_hunt",
		name = "The Hunt",
		scale = "major",
		weight = 45,
		minPlayers = 2,
		minLevel = 50,
		regions = { "electrical_wasteland", "underground_network", "storm_core", "null_reach" },
		announcement = "A Devourer is loose in the region and it is hunting.",
		description = "One Devourer, hugely amplified, hunting whoever carries the most. Everyone else can help — or wait for it to eat the leader and get richer.",
		durationSeconds = 300,
		warningSeconds = 20,
		visibleFromAnywhere = false,

		phases = {
			{
				id = "hunt",
				name = "The Hunt",
				duration = 300,
				objective = "defeat",
				description = "It is going for whoever is carrying the most. Right now that might be you.",
				effects = {
					spawnBoss = "devourer",
					bossScale = 3.0,
					bossHealthBase = 22000,
					bossHealthPerPlayer = 7000,
					drainAmplifier = 2.5,
					marksRichestPlayer = true,
				},
				contribution = { source = "boss_damage", weight = 1.0 },
			},
		},

		rewards = {
			participationXp = 4200,
			participationWatts = 18000,
			topContributorCores = 80,
			lootTable = "legendary_storm_cache",
			lootRolls = 3,
			bonusForMarkedSurvivor = { cores = 40, watts = 12000 },
		},
	},

	{
		id = "event_rare_bloom",
		name = "Rare Bloom",
		scale = "minor",
		weight = 150,
		minPlayers = 1,
		minLevel = 2,
		regions = {
			"starter_district", "storm_plains", "industrial_grid", "city_region",
			"mountain_region", "electrical_wasteland", "underground_network", "high_altitude",
		},
		announcement = "Rare weather forming nearby.",
		description = "A single rare storm type spawns somewhere in the region, marked on the map for anyone with detection. Small, frequent, and the reason the Hunter build exists.",
		durationSeconds = 180,
		warningSeconds = 10,
		visibleFromAnywhere = false,

		phases = {
			{
				id = "bloom",
				name = "Bloom",
				duration = 180,
				objective = "capture",
				description = "One rare cell, marked, for three minutes.",
				effects = {
					spawnRareCell = true,
					rareCellMarked = true,
					captureYieldMultiplier = 1.8,
				},
				contribution = { source = "energy_captured", weight = 1.0 },
			},
		},

		rewards = {
			participationXp = 400,
			participationWatts = 1400,
			topContributorCores = 5,
			lootTable = "resonant_materials",
			lootRolls = 1,
		},
	},
}

WorldEvents.ById = {}
WorldEvents.ByRegion = {}

for _, event in ipairs(WorldEvents.List) do
	WorldEvents.ById[event.id] = event
	for _, regionId in ipairs(event.regions) do
		WorldEvents.ByRegion[regionId] = WorldEvents.ByRegion[regionId] or {}
		table.insert(WorldEvents.ByRegion[regionId], event.id)
	end
end

function WorldEvents.Get(eventId: string)
	return WorldEvents.ById[eventId]
end

--[[ Total scheduled runtime of an event, warning included. ]]
function WorldEvents.GetTotalDuration(eventId: string): number
	local event = WorldEvents.ById[eventId]
	if not event then
		return 0
	end
	local total = event.warningSeconds
	for _, phase in ipairs(event.phases) do
		total += phase.duration
	end
	return total
end

--[[
	Events that could start right now, given the server's population and the level
	spread of the players on it. Returns id -> weight for a weighted pick.
]]
function WorldEvents.GetEligible(playerCount: number, medianLevel: number, activeEventIds: { [string]: boolean }): { [string]: number }
	local eligible = {}
	for _, event in ipairs(WorldEvents.List) do
		if not activeEventIds[event.id]
			and playerCount >= event.minPlayers
			and medianLevel >= event.minLevel
		then
			-- Weight decays for events far below the server's level, so a level-80
			-- server is not constantly running Rare Bloom.
			local levelGap = medianLevel - event.minLevel
			local decay = 1 / (1 + math.max(0, levelGap - 25) * 0.06)
			eligible[event.id] = event.weight * decay
		end
	end
	return eligible
end

--[[
	Reward split for one participant.
	`share` is their fraction of total contribution; `isTop` marks the highest
	contributor. Everyone above the minimum share gets a real reward, so joining an
	event late is never pointless.
]]
function WorldEvents.CalculateRewards(eventId: string, share: number, isTop: boolean, Balance: any)
	local event = WorldEvents.ById[eventId]
	if not event then
		return nil
	end

	local effectiveShare = math.max(Balance.Events.MIN_REWARD_SHARE, math.min(1, share))
	local rewards = {
		xp = math.floor(event.rewards.participationXp * effectiveShare + 0.5),
		watts = math.floor(event.rewards.participationWatts * effectiveShare + 0.5),
		cores = 0,
		lootTable = event.rewards.lootTable,
		lootRolls = math.max(1, math.floor(event.rewards.lootRolls * effectiveShare + 0.5)),
	}

	if isTop then
		rewards.cores = event.rewards.topContributorCores
		rewards.xp = math.floor(rewards.xp * (1 + Balance.Events.TOP_CONTRIBUTOR_BONUS))
		rewards.watts = math.floor(rewards.watts * (1 + Balance.Events.TOP_CONTRIBUTOR_BONUS))
		if event.rewards.guaranteedForTop then
			rewards.lootRolls = math.max(rewards.lootRolls, event.rewards.guaranteedForTop)
		end
	else
		rewards.cores = math.floor(event.rewards.topContributorCores * effectiveShare * 0.4 + 0.5)
	end

	return rewards
end

--[[ Merges every phase effect that applies at a given elapsed time. ]]
function WorldEvents.GetActivePhase(eventId: string, elapsedSeconds: number)
	local event = WorldEvents.ById[eventId]
	if not event then
		return nil, 0
	end
	local cursor = 0
	for index, phase in ipairs(event.phases) do
		if elapsedSeconds < cursor + phase.duration then
			return phase, index, elapsedSeconds - cursor
		end
		cursor += phase.duration
	end
	return nil, #event.phases + 1, 0
end

return TableUtil.DeepFreeze(WorldEvents)
