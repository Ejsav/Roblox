--!strict
--[[
	Config
	------
	Aggregator for every content table, so a service can `require(Config)` once and
	reach anything rather than accumulating a dozen require lines.

	Also carries the integrity check that runs at boot in Studio. It re-verifies the
	same cross-references the test suite checks, because content can be edited in
	Studio without ever running the headless suite.
]]

local Config = {}

Config.Balance = require(script.Balance)
Config.Regions = require(script.Regions)
Config.StormTypes = require(script.StormTypes)
Config.Stats = require(script.Stats)
Config.Upgrades = require(script.Upgrades)
Config.SkillTree = require(script.SkillTree)
Config.Abilities = require(script.Abilities)
Config.Traversal = require(script.Traversal)
Config.Resources = require(script.Resources)
Config.Equipment = require(script.Equipment)
Config.Modifiers = require(script.Modifiers)
Config.Quests = require(script.Quests)
Config.LootTables = require(script.LootTables)
Config.WorldEvents = require(script.WorldEvents)
Config.Prestige = require(script.Prestige)
Config.Recipes = require(script.Recipes)
Config.Achievements = require(script.Achievements)
Config.Theme = require(script.Theme)

--[[
	Verifies cross-references between content tables.
	Returns (ok, problems). Called at boot in Studio; skipped in production, where the
	CI suite has already guaranteed it.
]]
function Config.Verify(): (boolean, { string })
	local problems = {}

	local function check(condition: boolean, message: string)
		if not condition then
			table.insert(problems, message)
		end
	end

	for _, region in ipairs(Config.Regions.List) do
		for stormId in pairs(region.storms.types) do
			check(Config.StormTypes.ById[stormId] ~= nil, ("region %s references unknown storm %s"):format(region.id, stormId))
		end
		for resourceId in pairs(region.resources) do
			check(Config.Resources.ById[resourceId] ~= nil, ("region %s references unknown resource %s"):format(region.id, resourceId))
		end
		if region.unlock.quest then
			check(Config.Quests.ById[region.unlock.quest] ~= nil,
				("region %s gated behind unknown quest %s"):format(region.id, region.unlock.quest))
		end
		if region.unlock.traversal then
			check(Config.Traversal.ById[region.unlock.traversal] ~= nil,
				("region %s gated behind unknown traversal %s"):format(region.id, region.unlock.traversal))
		end
	end

	for _, storm in ipairs(Config.StormTypes.List) do
		check(Config.LootTables.ById[storm.drops.table] ~= nil,
			("storm %s drops from unknown table %s"):format(storm.id, storm.drops.table))
	end

	for _, node in ipairs(Config.SkillTree.Nodes) do
		if node.grantsAbility then
			check(Config.Abilities.ActiveById[node.grantsAbility] ~= nil,
				("skill %s grants unknown ability %s"):format(node.id, node.grantsAbility))
		end
		if node.grantsTraversal then
			check(Config.Traversal.ById[node.grantsTraversal] ~= nil,
				("skill %s grants unknown traversal %s"):format(node.id, node.grantsTraversal))
		end
	end

	for _, lootTable in ipairs(Config.LootTables.List) do
		for _, entry in ipairs(lootTable.entries) do
			if entry.kind == "resource" then
				check(Config.Resources.ById[entry.id] ~= nil,
					("loot table %s drops unknown resource %s"):format(lootTable.id, tostring(entry.id)))
			elseif entry.kind == "unique" then
				check(Config.Equipment.UniqueById[entry.id] ~= nil,
					("loot table %s drops unknown unique %s"):format(lootTable.id, tostring(entry.id)))
			end
		end
	end

	-- Prestige skills must form a satisfiable graph, or a rank's rewards are
	-- unreachable and the endgame silently dead-ends.
	for _, skill in ipairs(Config.Prestige.Skills) do
		for _, requiredId in ipairs(skill.requires) do
			check(Config.Prestige.SkillById[requiredId] ~= nil,
				("prestige skill %s requires unknown %s"):format(skill.id, requiredId))
		end
		for _, requiredId in ipairs(skill.requiresAny or {}) do
			check(Config.Prestige.SkillById[requiredId] ~= nil,
				("prestige skill %s requires unknown %s"):format(skill.id, requiredId))
		end
	end

	for _, rank in ipairs(Config.Prestige.Ranks) do
		if rank.grants.region then
			check(Config.Regions.ById[rank.grants.region] ~= nil,
				("prestige rank %d grants unknown region %s"):format(rank.rank, rank.grants.region))
		end
		if rank.grants.traversal then
			check(Config.Traversal.ById[rank.grants.traversal] ~= nil,
				("prestige rank %d grants unknown traversal %s"):format(rank.rank, rank.grants.traversal))
		end
		if rank.grants.item then
			check(Config.Equipment.UniqueById[rank.grants.item] ~= nil,
				("prestige rank %d grants unknown item %s"):format(rank.rank, rank.grants.item))
		end
	end

	-- A recipe that names a base or resource which does not exist is a dead entry
	-- in the crafting panel, so it is checked here rather than discovered by a player.
	for _, recipe in ipairs(Config.Recipes.List) do
		for resourceId in pairs(recipe.ingredients) do
			check(Config.Resources.ById[resourceId] ~= nil,
				("recipe %s needs unknown resource %s"):format(recipe.id, resourceId))
		end
		if recipe.output.kind == "equipment" then
			check(Config.Equipment.BaseById[recipe.output.baseId] ~= nil,
				("recipe %s produces unknown base %s"):format(recipe.id, tostring(recipe.output.baseId)))
		elseif recipe.output.kind == "resource" then
			check(Config.Resources.ById[recipe.output.resourceId] ~= nil,
				("recipe %s produces unknown resource %s"):format(recipe.id, tostring(recipe.output.resourceId)))
		elseif recipe.output.kind == "consumable" then
			check(Config.Recipes.Consumables[recipe.output.consumableId] ~= nil,
				("recipe %s produces unknown consumable %s"):format(recipe.id, tostring(recipe.output.consumableId)))
		end
	end

	-- An achievement whose source names something that does not exist can never be
	-- earned, and an unearnable achievement is worse than no achievement: it is a
	-- permanent hole in a completion percentage.
	local achievementCategories = {}
	for _, category in ipairs(Config.Achievements.Categories) do
		achievementCategories[category.id] = true
	end

	for _, achievement in ipairs(Config.Achievements.List) do
		check(achievementCategories[achievement.category] ~= nil,
			("achievement %s sits in unknown category %s"):format(achievement.id, tostring(achievement.category)))
		check((achievement.target or 1) > 0,
			("achievement %s has a non-positive target"):format(achievement.id))

		local source = achievement.source
		if source.kind == "storm_capture" then
			check(Config.StormTypes.ById[source.stormId] ~= nil,
				("achievement %s watches unknown storm %s"):format(achievement.id, tostring(source.stormId)))
		elseif source.kind == "quest" then
			check(Config.Quests.ById[source.questId] ~= nil,
				("achievement %s watches unknown quest %s"):format(achievement.id, tostring(source.questId)))
		elseif source.kind == "collection" then
			check(source.key ~= nil,
				("achievement %s counts an unnamed collection"):format(achievement.id))
		elseif source.kind == "record" then
			check(source.key ~= nil,
				("achievement %s reads an unnamed record"):format(achievement.id))
		end
	end

	-- "Earn half the achievements" has to keep meaning half.
	local halfTarget = math.floor(#Config.Achievements.List / 2)
	for _, achievement in ipairs(Config.Achievements.List) do
		if achievement.source.kind == "collection" and achievement.source.key == "achievements" then
			check(achievement.target == halfTarget,
				("achievement %s targets %d of %d achievements; half is %d")
					:format(achievement.id, achievement.target, #Config.Achievements.List, halfTarget))
		end
	end

	for _, event in ipairs(Config.WorldEvents.List) do
		for _, regionId in ipairs(event.regions) do
			check(Config.Regions.ById[regionId] ~= nil,
				("event %s targets unknown region %s"):format(event.id, regionId))
		end
		check(Config.LootTables.ById[event.rewards.lootTable] ~= nil,
			("event %s awards unknown loot table %s"):format(event.id, tostring(event.rewards.lootTable)))
	end

	return #problems == 0, problems
end

return Config
