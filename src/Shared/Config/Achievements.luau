--!strict
--[[
	Achievements
	------------
	Long-tail goals and the titles they award.

	Two rules keep this from becoming a checklist of chores:
	  1. Every achievement describes something a player might do anyway, at a
	     threshold that means they did it deliberately. No "walk 10,000 steps".
	  2. Hidden achievements exist and stay hidden, because discovering that an
	     achievement existed is itself a reward — and it is one of the cheapest
	     "I didn't know the game had this" moments available.

	Progress is evaluated from the profile's own records and collections, so
	nothing here needs its own tracking code.
]]

local TableUtil = require(script.Parent.Parent.Core.TableUtil)

local Achievements = {}

Achievements.Categories = {
	{ id = "capture", name = "Capture" },
	{ id = "economy", name = "Wealth" },
	{ id = "exploration", name = "Exploration" },
	{ id = "survival", name = "Survival" },
	{ id = "mastery", name = "Mastery" },
	{ id = "hidden", name = "Hidden" },
}

--[[
	`source` names where the value comes from:
		record       profile.records[key]
		collection   count of keys in profile[key]
		stat         a live stat value
		level        profile.level
		prestige     profile.prestige
]]
Achievements.List = {
	-- ================================================================ CAPTURE
	{
		id = "ach_first_capture",
		category = "capture",
		name = "First Light",
		description = "Capture energy from a storm.",
		source = { kind = "record", key = "totalCaptures" },
		target = 1,
		rewards = { watts = 200 },
	},
	{
		id = "ach_thousand_captures",
		category = "capture",
		name = "Practised",
		description = "Capture a thousand times.",
		source = { kind = "record", key = "totalCaptures" },
		target = 1000,
		rewards = { watts = 12000, cores = 10, title = "practised" },
	},
	{
		id = "ach_ten_thousand_captures",
		category = "capture",
		name = "Second Nature",
		description = "Capture ten thousand times.",
		source = { kind = "record", key = "totalCaptures" },
		target = 10000,
		rewards = { watts = 180000, cores = 120, title = "second_nature" },
	},
	{
		id = "ach_perfect_streak_25",
		category = "capture",
		name = "Metronome",
		description = "Land twenty-five consecutive Perfect captures.",
		source = { kind = "record", key = "mostPerfectCaptures" },
		target = 25,
		rewards = { watts = 24000, cores = 20, title = "metronome" },
	},
	{
		id = "ach_perfect_streak_100",
		category = "capture",
		name = "Virtuoso",
		description = "Land one hundred consecutive Perfect captures.",
		source = { kind = "record", key = "mostPerfectCaptures" },
		target = 100,
		rewards = { watts = 220000, cores = 180, title = "virtuoso" },
	},
	{
		id = "ach_all_storm_types",
		category = "capture",
		name = "Complete Atlas",
		description = "Capture from every storm type in the world.",
		source = { kind = "collection", key = "stormsDiscovered" },
		target = 20,
		rewards = { watts = 300000, cores = 250, title = "cartographer_of_weather" },
	},

	-- ================================================================= WEALTH
	{
		id = "ach_first_bank",
		category = "economy",
		name = "Banked",
		description = "Bank energy for the first time.",
		source = { kind = "record", key = "totalBanked" },
		target = 1,
		rewards = { watts = 200 },
	},
	{
		id = "ach_big_bank",
		category = "economy",
		name = "Heavy Deposit",
		description = "Bank fifty thousand Watts in a single deposit.",
		source = { kind = "record", key = "largestBank" },
		target = 50000,
		rewards = { watts = 40000, cores = 25, title = "heavy" },
	},
	{
		id = "ach_huge_bank",
		category = "economy",
		name = "The Vault Opens",
		description = "Bank a million Watts in a single deposit.",
		source = { kind = "record", key = "largestBank" },
		target = 1000000,
		rewards = { watts = 500000, cores = 300, title = "the_vault" },
	},
	{
		id = "ach_high_multiplier",
		category = "economy",
		name = "Nerve",
		description = "Bank at a multiplier of five or higher.",
		source = { kind = "record", key = "highestMultiplier" },
		target = 5,
		rewards = { watts = 30000, cores = 20, title = "nerve" },
	},
	{
		id = "ach_extreme_multiplier",
		category = "economy",
		name = "Unreasonable",
		description = "Bank at a multiplier of twelve or higher.",
		source = { kind = "record", key = "highestMultiplier" },
		target = 12,
		rewards = { watts = 260000, cores = 200, title = "unreasonable" },
	},
	{
		id = "ach_long_chain",
		category = "economy",
		name = "Unbanked",
		description = "Reach a chain of fifty.",
		source = { kind = "record", key = "longestChain" },
		target = 50,
		rewards = { watts = 60000, cores = 40, title = "unbanked" },
	},

	-- ============================================================ EXPLORATION
	{
		id = "ach_first_region",
		category = "exploration",
		name = "Beyond Halworth",
		description = "Leave the Starter District.",
		source = { kind = "record", key = "deepestRegionReached" },
		target = 2,
		rewards = { watts = 800 },
	},
	{
		id = "ach_reach_core",
		category = "exploration",
		name = "The Centre",
		description = "Reach the Storm Core.",
		source = { kind = "record", key = "deepestRegionReached" },
		target = 9,
		rewards = { watts = 400000, cores = 300, title = "core_walker" },
	},
	{
		id = "ach_discoveries_25",
		category = "exploration",
		name = "Curious",
		description = "Find twenty-five discoveries.",
		source = { kind = "collection", key = "discoveries" },
		target = 25,
		rewards = { watts = 20000, cores = 15 },
	},
	{
		id = "ach_discoveries_100",
		category = "exploration",
		name = "Nothing Left Unturned",
		description = "Find a hundred discoveries.",
		source = { kind = "collection", key = "discoveries" },
		target = 100,
		rewards = { watts = 200000, cores = 150, title = "unturned" },
	},
	{
		id = "ach_all_relays",
		category = "exploration",
		name = "The Whole Network",
		description = "Discover every relay station.",
		source = { kind = "collection", key = "fastTravelUnlocked" },
		target = 10,
		rewards = { watts = 90000, cores = 60, title = "networked" },
	},
	{
		id = "ach_all_lore",
		category = "exploration",
		name = "What Happened Here",
		description = "Recover every research log in the world.",
		source = { kind = "collection", key = "loreFound" },
		target = 12,
		rewards = { watts = 260000, cores = 200, title = "archivist" },
	},

	-- =============================================================== SURVIVAL
	{
		id = "ach_survive_scour",
		category = "survival",
		name = "Scoured",
		description = "Complete the Gauntlet: ten minutes in the Scour, no bank, no vent.",
		-- Read from the quest rather than from a survival timer. The Gauntlet already
		-- measures this exact condition, including the "no vent" half that a raw
		-- duration record cannot express, and awards the `scoured` title for it — so
		-- the achievement recognises the run and pays the currency rather than
		-- re-deriving a weaker version of the same test.
		source = { kind = "quest", questId = "challenge_the_gauntlet" },
		target = 1,
		rewards = { watts = 80000, cores = 55 },
	},
	{
		id = "ach_hundred_deaths",
		category = "survival",
		name = "Persistent",
		description = "Die a hundred times and keep going.",
		source = { kind = "record", key = "totalDeaths" },
		target = 100,
		rewards = { watts = 30000, title = "persistent" },
	},
	{
		id = "ach_events_50",
		category = "survival",
		name = "All Hands",
		description = "Participate in fifty world events.",
		source = { kind = "record", key = "eventsParticipated" },
		target = 50,
		rewards = { watts = 120000, cores = 80, title = "all_hands" },
	},
	{
		id = "ach_events_top_10",
		category = "survival",
		name = "Decisive",
		description = "Be the top contributor in ten world events.",
		source = { kind = "record", key = "eventsTopContributor" },
		target = 10,
		rewards = { watts = 160000, cores = 110, title = "decisive" },
	},

	-- ================================================================ MASTERY
	{
		id = "ach_level_50",
		category = "mastery",
		name = "Established",
		description = "Reach level fifty.",
		source = { kind = "level" },
		target = 50,
		rewards = { watts = 50000, cores = 30 },
	},
	{
		id = "ach_level_max",
		category = "mastery",
		name = "Ceiling",
		description = "Reach the level cap.",
		source = { kind = "level" },
		target = 120,
		rewards = { watts = 600000, cores = 400, title = "ceiling" },
	},
	{
		id = "ach_first_prestige",
		category = "mastery",
		name = "It Was Never the Ending",
		description = "Prestige for the first time.",
		source = { kind = "prestige" },
		target = 1,
		rewards = { sigils = 2, title = "threshold_crossed" },
	},
	{
		id = "ach_prestige_max",
		category = "mastery",
		name = "Storm",
		description = "Reach the final prestige rank.",
		source = { kind = "prestige" },
		target = 12,
		rewards = { sigils = 20, title = "storm" },
	},
	{
		id = "ach_achievements_half",
		category = "mastery",
		name = "Thorough",
		description = "Earn half of every achievement in the game.",
		source = { kind = "collection", key = "achievements" },
		target = 16,
		rewards = { watts = 150000, cores = 100, title = "thorough" },
	},

	-- ================================================================= HIDDEN
	{
		id = "ach_hidden_null_first",
		category = "hidden",
		hidden = true,
		name = "Backwards",
		description = "Work out what a Null Pocket wants without being told.",
		source = { kind = "storm_capture", stormId = "null_pocket" },
		target = 1,
		rewards = { watts = 25000, cores = 20, title = "backwards" },
	},
	{
		id = "ach_hidden_devoured",
		category = "hidden",
		hidden = true,
		name = "It Came For You",
		description = "Capture a Devourer while it was actively draining you.",
		source = { kind = "storm_capture", stormId = "devourer" },
		target = 1,
		rewards = { watts = 60000, cores = 45, title = "prey_no_longer" },
	},
	{
		id = "ach_hidden_the_eye",
		category = "hidden",
		hidden = true,
		name = "It Was Watching",
		description = "Face the Eye and win.",
		source = { kind = "storm_capture", stormId = "the_eye" },
		target = 1,
		rewards = { watts = 400000, cores = 350, title = "storm_touched" },
	},
	{
		id = "ach_hidden_underyard",
		category = "hidden",
		hidden = true,
		name = "Twelve Marks",
		description = "Find who was living beneath Halworth.",
		source = { kind = "discovery", discoveryId = "halworth_underyard_camp" },
		target = 1,
		rewards = { watts = 5000, title = "counted" },
	},
	{
		id = "ach_hidden_naked_bank",
		category = "hidden",
		hidden = true,
		name = "Bare Hands",
		description = "Bank two thousand energy with nothing equipped.",
		source = { kind = "quest", questId = "challenge_no_upgrades" },
		target = 1,
		rewards = { watts = 40000, cores = 30, title = "purist" },
	},
}

Achievements.ById = {}
Achievements.ByCategory = {}

for _, achievement in ipairs(Achievements.List) do
	Achievements.ById[achievement.id] = achievement
	Achievements.ByCategory[achievement.category] = Achievements.ByCategory[achievement.category] or {}
	table.insert(Achievements.ByCategory[achievement.category], achievement.id)
end

--[[
	Current progress toward an achievement, read from the profile.
	Returns (value, target). Achievements whose source is an event rather than a
	counter return 0 until awarded directly.
]]
function Achievements.GetProgress(achievement: any, profile: any): (number, number)
	local source = achievement.source
	local target = achievement.target or 1

	if source.kind == "record" then
		return profile.records and (profile.records[source.key] or 0) or 0, target

	elseif source.kind == "collection" then
		local collection = profile[source.key]
		if type(collection) ~= "table" then
			return 0, target
		end
		local count = 0
		for _ in pairs(collection) do
			count += 1
		end
		return count, target

	elseif source.kind == "level" then
		return profile.level or 1, target

	elseif source.kind == "prestige" then
		return profile.prestige or 0, target

	elseif source.kind == "storm_capture" then
		return (profile.stormsDiscovered and profile.stormsDiscovered[source.stormId]) and 1 or 0, target

	elseif source.kind == "discovery" then
		return (profile.discoveries and profile.discoveries[source.discoveryId]) and 1 or 0, target

	elseif source.kind == "quest" then
		return (profile.completedQuests and profile.completedQuests[source.questId]) and 1 or 0, target
	end

	return 0, target
end

--[[ Every achievement now satisfied but not yet recorded on the profile. ]]
function Achievements.FindNewlyEarned(profile: any): { any }
	local earned = {}
	for _, achievement in ipairs(Achievements.List) do
		if not (profile.achievements and profile.achievements[achievement.id]) then
			local value, target = Achievements.GetProgress(achievement, profile)
			if value >= target then
				table.insert(earned, achievement)
			end
		end
	end
	return earned
end

--[[ Completion, counting hidden achievements only once found. ]]
function Achievements.GetCompletion(profile: any): (number, number)
	local earned = 0
	for _ in pairs(profile.achievements or {}) do
		earned += 1
	end
	return earned, #Achievements.List
end

return TableUtil.DeepFreeze(Achievements)
