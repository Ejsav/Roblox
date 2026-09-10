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
