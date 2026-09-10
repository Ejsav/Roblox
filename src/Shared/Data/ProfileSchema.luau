--!strict
--[[
	ProfileSchema
	-------------
	The canonical shape of a saved player, plus the migration chain that brings any
	older save forward.

	Rules this file exists to enforce:
	  * A new field is added to `Default` and appears on every existing save via
	    TableUtil.Reconcile. No migration step needed for pure additions.
	  * A field that changes MEANING gets a migration step and a version bump.
	    Silently reinterpreting an old value is how progression gets destroyed.
	  * Migrations run in order and are idempotent, so a save that is five versions
	    behind arrives correct.
	  * `Validate` runs after migration and repairs impossible states rather than
	    rejecting the save. Refusing to load is the worst possible outcome for a
	    player; clamping a corrupt value and logging it is strictly better.

	Key naming is deliberately terse in hot, per-item structures (inventory entries)
	because those are the bulk of a large save's datastore footprint.
]]

local TableUtil = require(script.Parent.Parent.Core.TableUtil)
local Balance = require(script.Parent.Parent.Config.Balance)
local SkillTree = require(script.Parent.Parent.Config.SkillTree)
local Upgrades = require(script.Parent.Parent.Config.Upgrades)
local Equipment = require(script.Parent.Parent.Config.Equipment)
local Traversal = require(script.Parent.Parent.Config.Traversal)
local Achievements = require(script.Parent.Parent.Config.Achievements)

local ProfileSchema = {}

ProfileSchema.VERSION = Balance.Data.CURRENT_SCHEMA_VERSION

--[[ The default profile. Every field a new player starts with. ]]
function ProfileSchema.CreateDefault()
	local traversal = {}
	for abilityId, owned in pairs(Traversal.GetDefaults()) do
		traversal[abilityId] = owned
	end

	return {
		version = ProfileSchema.VERSION,

		-- --------------------------------------------------------------- identity
		createdAt = 0,
		lastSeenAt = 0,
		playTimeSeconds = 0,
		sessionCount = 0,

		-- ------------------------------------------------------------ progression
		level = 1,
		xp = 0,
		prestige = 0,
		skillPoints = 0,
		skillPointsSpent = 0,

		-- ------------------------------------------------------------- currencies
		watts = 0,
		cores = 0,
		sigils = 0,

		-- -------------------------------------------------------------- upgrades
		-- upgradeId -> purchased level
		upgrades = {},

		-- ---------------------------------------------------------------- skills
		-- nodeId -> rank
		skills = {},

		-- ------------------------------------------------------------- abilities
		-- abilityId -> owned
		abilitiesOwned = {},
		-- Four active slots, by ability id. Sparse array; nil means empty slot.
		loadout = {},
		-- passiveId -> owned
		passivesOwned = {},

		-- ------------------------------------------------------------- traversal
		traversal = traversal,

		-- ------------------------------------------------------------- inventory
		-- Array of item entries. See ProfileSchema.CreateItem for the shape.
		inventory = {},
		-- slotId -> item uid
		equipped = {},
		-- resourceId -> quantity
		resources = {},
		-- consumableId -> quantity
		consumables = {},
		nextItemId = 1,

		-- ---------------------------------------------------------------- quests
		-- questId -> true
		completedQuests = {},
		-- questId -> { objectiveId -> progress }
		activeQuests = {},
		-- questId -> unix time when repeatable becomes available again
		questCooldowns = {},
		trackedQuest = nil,
		-- Rotating quests, regenerated daily/weekly
		dailyQuests = {},
		weeklyQuests = {},
		dailyResetAt = 0,
		weeklyResetAt = 0,

		-- --------------------------------------------------------------- regions
		-- regionId -> true once entered
		regionsVisited = {},
		-- fastTravelId -> true once discovered
		fastTravelUnlocked = {},
		-- discoveryId -> true
		discoveries = {},
		-- regionId -> { captures = n, banked = n, deaths = n }
		regionStats = {},
		lastRegion = "starter_district",

		-- ------------------------------------------------------------ collections
		-- stormId -> capture count (presence means discovered)
		stormsDiscovered = {},
		-- loreId -> true
		loreFound = {},
		-- achievementId -> unix time earned
		achievements = {},
		-- boardId -> { key = "<week key>", value = n }. The lifetime figure a weekly
		-- leaderboard measures from, so a weekly board on a lifetime counter shows
		-- progress rather than repeating the all-time board.
		weeklyBaselines = {},
		-- titleId -> true
		titlesOwned = {},
		equippedTitle = nil,
		-- cosmeticId -> true
		cosmeticsOwned = {},
		equippedCosmetics = {},

		-- ---------------------------------------------------------------- mastery
		-- masteryId -> { xp = n, level = n }
		masteries = {},

		-- ---------------------------------------------------------------- records
		records = {
			largestBank = 0,
			highestCarry = 0,
			longestChain = 0,
			highestMultiplier = 0,
			mostPerfectCaptures = 0,
			totalCaptures = 0,
			totalBanked = 0,
			totalDeaths = 0,
			totalDistanceTravelled = 0,
			fastestRouteSeconds = {},
			hardestStormSurvived = 0,
			rareStormsFound = 0,
			eventsParticipated = 0,
			eventsTopContributor = 0,
			bestEventShare = 0,
			deepestRegionReached = 1,
			longestSurvivalSeconds = 0,
		},

		-- ---------------------------------------------------------------- pity
		-- Bad-luck protection state, per loot table.
		pity = {},

		-- ------------------------------------------------------------- prestige
		prestigeSkills = {},
		prestigeUnlocks = {},
		prestigeCount = 0,

		-- ------------------------------------------------------------- settings
		settings = {
			quality = "auto",
			musicVolume = 0.55,
			sfxVolume = 0.8,
			screenShake = 1.0,
			showDamageNumbers = true,
			showOtherPlayers = true,
			colourblindMode = "off",
			hudScale = 1.0,
			reducedMotion = false,
			subtitles = false,
			holdToSprint = true,
			captureAssist = false,
		},

		-- -------------------------------------------------------------- onboarding
		onboarding = {
			seenIntro = false,
			seenFirstCapture = false,
			seenFirstBank = false,
			seenFirstDeath = false,
			seenFirstRare = false,
			seenInstabilityWarning = false,
			seenRegionUnlock = false,
			seenPrestigeTeaser = false,
			tipsShown = {},
		},

		-- -------------------------------------------------------------- purchases
		purchases = {
			-- productId -> count, for receipt idempotency
			consumed = {},
			passesOwned = {},
			totalRobuxSpent = 0,
		},

		-- ------------------------------------------------------------ moderation
		flags = {
			suspicionTotal = 0,
			rejectionCount = 0,
			lastRejectionAt = 0,
		},
	}
end

--[[
	Creates an inventory item entry.
	Keys are short because inventory dominates a large profile's serialised size:
		u   uid                 b   baseId          r   rarity
		l   level requirement   m   modifiers       t   trait id
		f   favourite           a   acquired at     s   source
]]
function ProfileSchema.CreateItem(uid: string, baseId: string, rarity: string, modifiers: { any }, trait: string?, source: string?)
	return {
		u = uid,
		b = baseId,
		r = rarity,
		m = modifiers or {},
		t = trait,
		f = false,
		a = 0,
		s = source,
	}
end

-- ============================================================================
-- Migrations
--
-- Each entry migrates FROM its index TO index + 1. Additive changes need no entry;
-- reconcile handles those. These exist only where meaning changed.
-- ============================================================================

ProfileSchema.Migrations = {
	[1] = function(profile)
		-- v1 -> v2: currencies were a single `money` field before Cores existed.
		if profile.money ~= nil then
			profile.watts = profile.money
			profile.money = nil
		end
		profile.cores = profile.cores or 0
	end,

	[2] = function(profile)
		-- v2 -> v3: upgrades moved from an array of { id, level } to a map.
		if type(profile.upgrades) == "table" and #profile.upgrades > 0 then
			local converted = {}
			for _, entry in ipairs(profile.upgrades) do
				if type(entry) == "table" and entry.id then
					converted[entry.id] = entry.level or 0
				end
			end
			profile.upgrades = converted
		end
	end,

	[3] = function(profile)
		-- v3 -> v4: `equipment` (slot -> full item table) became `equipped`
		-- (slot -> uid) with the item living in `inventory`.
		if profile.equipment then
			profile.inventory = profile.inventory or {}
			profile.equipped = profile.equipped or {}
			profile.nextItemId = profile.nextItemId or 1
			for slotId, item in pairs(profile.equipment) do
				if type(item) == "table" and item.b then
					local uid = "m" .. tostring(profile.nextItemId)
					profile.nextItemId += 1
					item.u = uid
					table.insert(profile.inventory, item)
					profile.equipped[slotId] = uid
				end
			end
			profile.equipment = nil
		end
	end,

	[4] = function(profile)
		-- v4 -> v5: quest progress was a bare number; it is now per-objective so
		-- multi-objective quests can report partial completion.
		if type(profile.activeQuests) == "table" then
			for questId, progress in pairs(profile.activeQuests) do
				if type(progress) == "number" then
					profile.activeQuests[questId] = { __legacy = progress }
				end
			end
		end
	end,

	[5] = function(profile)
		-- v5 -> v6: records.deepestRegionReached stored a region id string; it is now
		-- the region's numeric order, so comparisons work without a config lookup.
		local records = profile.records
		if records and type(records.deepestRegionReached) == "string" then
			local Regions = require(script.Parent.Parent.Config.Regions)
			local region = Regions.ById[records.deepestRegionReached]
			records.deepestRegionReached = region and region.order or 1
		end
	end,

	[6] = function(profile)
		-- v6 -> v7: traversal unlocks were inferred from upgrade levels at runtime.
		-- They are now stored explicitly so a rebalance of upgrade milestones can
		-- never revoke a movement ability a player already earned.
		profile.traversal = profile.traversal or {}
		for abilityId, owned in pairs(Traversal.GetDefaults()) do
			if profile.traversal[abilityId] == nil then
				profile.traversal[abilityId] = owned
			end
		end
		for abilityId in pairs(Upgrades.CollectTraversal(profile.upgrades or {})) do
			profile.traversal[abilityId] = true
		end
	end,
}

--[[
	Brings a profile forward to the current version.
	Returns (migrated, fromVersion, stepsApplied).
]]
function ProfileSchema.Migrate(profile: any): (any, number, number)
	local fromVersion = tonumber(profile.version) or 1
	local steps = 0

	local version = fromVersion
	while version < ProfileSchema.VERSION do
		local migration = ProfileSchema.Migrations[version]
		if migration then
			local ok, err = pcall(migration, profile)
			if not ok then
				warn(("[ProfileSchema] migration %d -> %d failed: %s"):format(version, version + 1, tostring(err)))
			else
				steps += 1
			end
		end
		version += 1
	end

	profile.version = ProfileSchema.VERSION
	return profile, fromVersion, steps
end

-- ============================================================================
-- Validation and repair
-- ============================================================================

local function clampNumber(value: any, min: number, max: number, fallback: number): number
	if type(value) ~= "number" or value ~= value then
		return fallback
	end
	return math.clamp(value, min, max)
end

--[[
	Repairs impossible or hostile values in place.
	Returns a list of human-readable repairs so persistent corruption is visible in
	logs rather than silently normalised forever.
]]
function ProfileSchema.Validate(profile: any): { string }
	local repairs = {}

	local function repair(message: string)
		table.insert(repairs, message)
	end

	-- Currencies
	for _, entry in ipairs({
		{ key = "watts", cap = Balance.Currency.WATTS.cap },
		{ key = "cores", cap = Balance.Currency.CORES.cap },
		{ key = "sigils", cap = Balance.Currency.SIGILS.cap },
	}) do
		local value = profile[entry.key]
		local clamped = clampNumber(value, 0, entry.cap, 0)
		if clamped ~= value then
			repair(("%s was %s, clamped to %d"):format(entry.key, tostring(value), clamped))
			profile[entry.key] = clamped
		end
	end

	-- Level and prestige
	local level = clampNumber(profile.level, 1, Balance.Progression.MAX_LEVEL, 1)
	if level ~= profile.level then
		repair(("level was %s, clamped to %d"):format(tostring(profile.level), level))
		profile.level = level
	end
	local prestige = clampNumber(profile.prestige, 0, Balance.Progression.MAX_PRESTIGE, 0)
	if prestige ~= profile.prestige then
		repair(("prestige was %s, clamped to %d"):format(tostring(profile.prestige), prestige))
		profile.prestige = prestige
	end
	profile.xp = clampNumber(profile.xp, 0, 1e15, 0)

	-- Upgrade levels must exist and be within their track's maximum.
	if type(profile.upgrades) ~= "table" then
		profile.upgrades = {}
		repair("upgrades table was missing")
	end
	for upgradeId, upgradeLevel in pairs(profile.upgrades) do
		local definition = Upgrades.ById[upgradeId]
		if not definition then
			profile.upgrades[upgradeId] = nil
			repair("removed unknown upgrade " .. tostring(upgradeId))
		else
			local clamped = clampNumber(upgradeLevel, 0, definition.maxLevel, 0)
			if clamped ~= upgradeLevel then
				repair(("upgrade %s was %s, clamped to %d"):format(upgradeId, tostring(upgradeLevel), clamped))
				profile.upgrades[upgradeId] = clamped
			end
		end
	end

	-- Skill ranks: drop anything unknown, clamp anything over-ranked, then drop any
	-- node whose prerequisites are not satisfied so a tampered save cannot hold a
	-- keystone it never earned.
	if type(profile.skills) ~= "table" then
		profile.skills = {}
		repair("skills table was missing")
	end
	for nodeId, rank in pairs(profile.skills) do
		local node = SkillTree.NodeById[nodeId]
		if not node then
			profile.skills[nodeId] = nil
			repair("removed unknown skill " .. tostring(nodeId))
		else
			local clamped = clampNumber(rank, 0, node.maxRank, 0)
			if clamped ~= rank then
				repair(("skill %s was %s, clamped to %d"):format(nodeId, tostring(rank), clamped))
				profile.skills[nodeId] = clamped
			end
			if clamped == 0 then
				profile.skills[nodeId] = nil
			end
		end
	end

	-- Prerequisite sweep. Repeats until stable, because removing one node can
	-- invalidate another that depended on it.
	local changed = true
	local passes = 0
	while changed and passes < 12 do
		changed = false
		passes += 1
		local ok, problems = SkillTree.ValidateRanks(profile.skills)
		if not ok then
			for _, problem in ipairs(problems) do
				local nodeId = problem:match("^(%S+) requires") or problem:match("^(%S+) is exclusive")
				if nodeId and profile.skills[nodeId] then
					profile.skills[nodeId] = nil
					repair("removed unsatisfiable skill " .. nodeId)
					changed = true
				end
			end
		end
	end

	-- Skill point accounting must match what is actually spent.
	local spent = SkillTree.GetSpentPoints(profile.skills)
	local earned = ProfileSchema.CalculateEarnedSkillPoints(profile.level)
	local available = math.max(0, earned - spent)
	if profile.skillPoints ~= available then
		profile.skillPoints = available
		profile.skillPointsSpent = spent
	end

	-- Inventory: drop entries with unknown bases, deduplicate uids, and enforce the
	-- slot cap by discarding the oldest non-favourited items.
	if type(profile.inventory) ~= "table" then
		profile.inventory = {}
		repair("inventory was missing")
	end
	local seenUids = {}
	local cleanInventory = {}
	for _, item in ipairs(profile.inventory) do
		if type(item) == "table" and type(item.u) == "string" and Equipment.GetDefinition(item.b) then
			if seenUids[item.u] then
				repair("dropped duplicate item uid " .. item.u)
			else
				seenUids[item.u] = true
				if type(item.m) ~= "table" then
					item.m = {}
				end
				table.insert(cleanInventory, item)
			end
		else
			repair("dropped malformed inventory entry")
		end
	end
	if #cleanInventory > Balance.Loot.MAX_INVENTORY_SLOTS then
		table.sort(cleanInventory, function(a, b)
			if a.f ~= b.f then
				return a.f == true
			end
			return (a.a or 0) > (b.a or 0)
		end)
		local overflow = #cleanInventory - Balance.Loot.MAX_INVENTORY_SLOTS
		for _ = 1, overflow do
			table.remove(cleanInventory)
		end
		repair(("trimmed %d items over the inventory cap"):format(overflow))
	end
	profile.inventory = cleanInventory

	-- Equipped slots must reference an owned item of the correct slot.
	if type(profile.equipped) ~= "table" then
		profile.equipped = {}
	end
	for slotId, uid in pairs(profile.equipped) do
		if not Equipment.SlotById[slotId] then
			profile.equipped[slotId] = nil
			repair("cleared unknown equipment slot " .. tostring(slotId))
		elseif not seenUids[uid] then
			profile.equipped[slotId] = nil
			repair(("cleared %s: item %s not in inventory"):format(slotId, tostring(uid)))
		end
	end

	-- Consumables follow the same rules as resources.
	if type(profile.consumables) ~= "table" then
		profile.consumables = {}
	end
	for consumableId, quantity in pairs(profile.consumables) do
		local clamped = math.floor(clampNumber(quantity, 0, 9999, 0))
		if clamped <= 0 then
			profile.consumables[consumableId] = nil
		elseif clamped ~= quantity then
			profile.consumables[consumableId] = clamped
		end
	end

	-- Achievements: a table of id -> unix time. An unknown id is content that was
	-- removed, and it has to go, or it inflates the completion count forever.
	if type(profile.achievements) ~= "table" then
		profile.achievements = {}
		repair("achievements table was missing")
	end
	for achievementId, earnedAt in pairs(profile.achievements) do
		if not Achievements.ById[achievementId] then
			profile.achievements[achievementId] = nil
			repair("dropped unknown achievement " .. tostring(achievementId))
		elseif type(earnedAt) ~= "number" or earnedAt <= 0 then
			-- The achievement is real, so it is kept; only the timestamp is repaired.
			profile.achievements[achievementId] = 1
		end
	end

	-- Weekly leaderboard baselines. A malformed entry is dropped rather than
	-- repaired: the next submission re-stamps it from the current lifetime value,
	-- which is exactly what a missing baseline means.
	if type(profile.weeklyBaselines) ~= "table" then
		profile.weeklyBaselines = {}
	end
	for boardId, entry in pairs(profile.weeklyBaselines) do
		if type(entry) ~= "table"
			or type(entry.key) ~= "string"
			or type(entry.value) ~= "number"
			or entry.value ~= entry.value
			or entry.value < 0
		then
			profile.weeklyBaselines[boardId] = nil
		end
	end

	-- Titles. Unlike achievements, unknown title ids are kept: titles come from
	-- masteries, prestige ranks and events as generated ids, and this module has no
	-- registry of those to check against. Only the shape is enforced.
	if type(profile.titlesOwned) ~= "table" then
		profile.titlesOwned = {}
		repair("titles table was missing")
	end
	for titleId, owned in pairs(profile.titlesOwned) do
		if type(titleId) ~= "string" or owned ~= true then
			profile.titlesOwned[titleId] = nil
		end
	end
	if profile.equippedTitle ~= nil and not profile.titlesOwned[profile.equippedTitle] then
		repair("cleared equipped title " .. tostring(profile.equippedTitle) .. ": not owned")
		profile.equippedTitle = nil
	end

	-- Resources must be non-negative integers.
	if type(profile.resources) ~= "table" then
		profile.resources = {}
	end
	for resourceId, quantity in pairs(profile.resources) do
		local clamped = math.floor(clampNumber(quantity, 0, 1e9, 0))
		if clamped ~= quantity then
			profile.resources[resourceId] = clamped
		end
		if clamped == 0 then
			profile.resources[resourceId] = nil
		end
	end

	-- Loadout: at most four, all owned, no duplicates.
	if type(profile.loadout) ~= "table" then
		profile.loadout = {}
	end
	local loadoutSeen = {}
	local cleanLoadout = {}
	for _, abilityId in ipairs(profile.loadout) do
		if type(abilityId) == "string"
			and profile.abilitiesOwned[abilityId]
			and not loadoutSeen[abilityId]
			and #cleanLoadout < 4
		then
			loadoutSeen[abilityId] = true
			table.insert(cleanLoadout, abilityId)
		end
	end
	if #cleanLoadout ~= #profile.loadout then
		repair("cleaned invalid loadout entries")
	end
	profile.loadout = cleanLoadout

	-- Records cannot be negative.
	if type(profile.records) == "table" then
		for key, value in pairs(profile.records) do
			if type(value) == "number" then
				profile.records[key] = clampNumber(value, 0, 1e15, 0)
			end
		end
	end

	return repairs
end

--[[ Skill points a player of the given level should have earned in total. ]]
function ProfileSchema.CalculateEarnedSkillPoints(level: number): number
	local progression = Balance.Progression
	local total = 0
	for currentLevel = 2, level do
		total += progression.SKILL_POINTS_PER_LEVEL
		if currentLevel % progression.SKILL_POINT_BONUS_INTERVAL == 0 then
			total += progression.SKILL_POINT_BONUS_AMOUNT
		end
	end
	return total
end

--[[
	Full load pipeline: migrate, reconcile against the current default, then validate.
	Returns (profile, report).
]]
function ProfileSchema.Prepare(rawProfile: any?)
	local report = {
		wasNew = false,
		fromVersion = ProfileSchema.VERSION,
		migrationSteps = 0,
		fieldsAdded = 0,
		repairs = {},
	}

	local profile = rawProfile
	if type(profile) ~= "table" then
		profile = ProfileSchema.CreateDefault()
		report.wasNew = true
		return profile, report
	end

	local _, fromVersion, steps = ProfileSchema.Migrate(profile)
	report.fromVersion = fromVersion
	report.migrationSteps = steps

	report.fieldsAdded = TableUtil.Reconcile(profile, ProfileSchema.CreateDefault())
	report.repairs = ProfileSchema.Validate(profile)

	return profile, report
end

--[[
	Strips a profile down to what the client is allowed to see.
	Moderation flags and purchase receipts never leave the server.
]]
function ProfileSchema.ToClientView(profile: any)
	local view = TableUtil.DeepCopy(profile)
	view.flags = nil
	if view.purchases then
		view.purchases.consumed = nil
	end
	return view
end

return ProfileSchema
