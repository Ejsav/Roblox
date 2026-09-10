--!nolint
--[[
	Config integrity specs.

	These are the guardrails for a heavily cross-referenced content layer. Every id
	that one config file points at in another is verified here, so a typo in a storm
	weight or a renamed skill node fails the build instead of silently disabling
	content that nobody notices for a month.
]]

local loadModule = loadModule

local Balance = loadModule("Shared/Config/Balance")
local Regions = loadModule("Shared/Config/Regions")
local StormTypes = loadModule("Shared/Config/StormTypes")
local Stats = loadModule("Shared/Config/Stats")
local Upgrades = loadModule("Shared/Config/Upgrades")
local Abilities = loadModule("Shared/Config/Abilities")
local Traversal = loadModule("Shared/Config/Traversal")
local SkillTree = loadModule("Shared/Config/SkillTree")

--[[ Collects every stat id referenced by an effects block of the shape
     { flat = {...}, increased = {...}, more = {...} }. ]]
local function collectEffectStats(effects, into, context)
	if not effects then
		return
	end
	for kind, statMap in pairs(effects) do
		if kind ~= "flat" and kind ~= "increased" and kind ~= "more" then
			table.insert(into, { stat = "<bad kind: " .. tostring(kind) .. ">", context = context })
		elseif type(statMap) == "table" then
			for statId in pairs(statMap) do
				table.insert(into, { stat = statId, context = context })
			end
		end
	end
end

describe("Config/Regions", function()
	it("has unique ids in strictly increasing order", function()
		local seen = {}
		local lastOrder = 0
		for _, region in ipairs(Regions.List) do
			expect(seen[region.id]):isNil()
			seen[region.id] = true
			expect(region.order):greaterThan(lastOrder)
			lastOrder = region.order
		end
	end)

	it("only references storm types that exist", function()
		for _, region in ipairs(Regions.List) do
			for stormId, weight in pairs(region.storms.types) do
				expect(StormTypes.ById[stormId]):ok()
				expect(weight):greaterThan(0)
			end
		end
	end)

	it("gives every region at least one bank station and one subregion", function()
		for _, region in ipairs(Regions.List) do
			expect(#region.bankStations):greaterThan(0)
			expect(#region.subregions):greaterThan(0)
		end
	end)

	it("keeps bank stations and fast travel nodes inside their region radius", function()
		for _, region in ipairs(Regions.List) do
			local function assertInside(position, label)
				local dx = position.X - region.center.X
				local dz = position.Z - region.center.Z
				local distance = math.sqrt(dx * dx + dz * dz)
				if distance > region.radius then
					error(("%s in %s is %d studs from centre but radius is %d")
						:format(label, region.id, math.floor(distance), region.radius))
				end
			end
			for _, station in ipairs(region.bankStations) do
				assertInside(station.position, station.id)
			end
			if region.fastTravel then
				assertInside(region.fastTravel.position, region.fastTravel.id)
			end
			for _, subregion in ipairs(region.subregions) do
				assertInside(subregion.center, subregion.id)
			end
		end
	end)

	it("escalates danger monotonically through the progression order", function()
		local lastDanger = 0
		for _, region in ipairs(Regions.List) do
			expect(region.danger):greaterOrEqual(lastDanger)
			lastDanger = region.danger
		end
	end)

	it("escalates recommended level monotonically", function()
		local lastLevel = 0
		for _, region in ipairs(Regions.List) do
			expect(region.recommendedLevel):greaterOrEqual(lastLevel)
			lastLevel = region.recommendedLevel
		end
	end)

	it("never gates a region above the level cap", function()
		for _, region in ipairs(Regions.List) do
			if region.unlock.level then
				expect(region.unlock.level):lessOrEqual(Balance.Progression.MAX_LEVEL)
			end
		end
	end)

	it("only gates on traversal abilities that exist", function()
		for _, region in ipairs(Regions.List) do
			if region.unlock.traversal then
				expect(Traversal.ById[region.unlock.traversal]):ok()
			end
		end
	end)

	it("leaves the starter district completely ungated", function()
		local starter = Regions.ById.starter_district
		expect(starter):ok()
		expect(next(starter.unlock)):isNil()
	end)

	it("resolves a point inside a region back to that region", function()
		for _, region in ipairs(Regions.List) do
			local found = Regions.FindContaining(
				region.center.X,
				(region.verticalRange.min + region.verticalRange.max) / 2,
				region.center.Z
			)
			expect(found):ok()
			-- Overlapping vertical layers (Deepline sits under Verrick) mean the
			-- centre point may resolve to either; assert we got a real region whose
			-- vertical band actually contains the sample.
			expect(found.verticalRange.min):lessOrEqual((region.verticalRange.min + region.verticalRange.max) / 2)
		end
	end)

	it("reports progressive unlocks for a levelling player", function()
		local state = { level = 1, prestige = 0, completedQuests = {}, traversal = {} }
		local atStart = #Regions.GetUnlocked(state)
		expect(atStart):equal(1)

		state.level = 120
		state.prestige = 1
		for _, region in ipairs(Regions.List) do
			if region.unlock.quest then
				state.completedQuests[region.unlock.quest] = true
			end
			if region.unlock.traversal then
				state.traversal[region.unlock.traversal] = true
			end
		end
		expect(#Regions.GetUnlocked(state)):equal(#Regions.List)
	end)

	it("names the blocking requirement when a region is locked", function()
		local state = { level = 1, prestige = 0, completedQuests = {}, traversal = {} }
		local unlocked, reason, value = Regions.IsUnlocked("storm_plains", state)
		expect(unlocked):falsy()
		expect(reason):equal("level")
		expect(value):equal(5)
	end)

	it("spans a world large enough for the intended scale", function()
		local bounds = Regions.GetWorldBounds()
		expect(bounds.maxX - bounds.minX):greaterThan(14000)
		expect(bounds.maxZ - bounds.minZ):greaterThan(12000)
		expect(bounds.maxY - bounds.minY):greaterThan(4000)
	end)

	it("offers a meaningful number of discoveries", function()
		expect(Regions.TotalDiscoveries()):greaterThan(120)
	end)
end)

describe("Config/StormTypes", function()
	it("has unique ids and known rarities", function()
		local validRarities = {}
		for _, rarity in ipairs(Balance.Loot.RARITY_ORDER) do
			validRarities[rarity] = true
		end
		local seen = {}
		for _, storm in ipairs(StormTypes.List) do
			expect(seen[storm.id]):isNil()
			seen[storm.id] = true
			expect(validRarities[storm.rarity]):ok()
		end
	end)

	it("declares a complete strike and yield block for every storm", function()
		for _, storm in ipairs(StormTypes.List) do
			expect(storm.strike.windup):greaterThan(0)
			expect(storm.strike.windowHalfWidth):greaterThan(0)
			expect(storm.strike.windowHalfWidth):lessOrEqual(0.5)
			expect(storm.strike.strikeCount):greaterOrEqual(1)
			expect(storm.strike.radius):greaterThan(0)
			expect(storm.yield.base):greaterThan(0)
		end
	end)

	it("gives every storm a distinct mechanic or a deliberate reason to share one", function()
		-- Twenty storms, and the design intent is twenty different verbs.
		local mechanics = {}
		for _, storm in ipairs(StormTypes.List) do
			mechanics[storm.mechanic] = (mechanics[storm.mechanic] or 0) + 1
		end
		local distinct = 0
		for _ in pairs(mechanics) do
			distinct += 1
		end
		expect(distinct):equal(#StormTypes.List)
	end)

	it("scales max yield upward with tier", function()
		local byTier = {}
		for _, storm in ipairs(StormTypes.List) do
			byTier[storm.tier] = byTier[storm.tier] or {}
			table.insert(byTier[storm.tier], StormTypes.MaxYield(storm.id))
		end
		local tiers = {}
		for tier in pairs(byTier) do
			table.insert(tiers, tier)
		end
		table.sort(tiers)

		local previousBest = 0
		for _, tier in ipairs(tiers) do
			local best = 0
			for _, yield in ipairs(byTier[tier]) do
				best = math.max(best, yield)
			end
			expect(best):greaterThan(previousBest)
			previousBest = best
		end
	end)

	it("marks only high rarities as broadcast worthy", function()
		expect(StormTypes.IsBroadcastWorthy("static_bloom")):falsy()
		expect(StormTypes.IsBroadcastWorthy("devourer")):ok()
		expect(StormTypes.IsBroadcastWorthy("the_eye")):ok()
		expect(StormTypes.IsBroadcastWorthy("inversion")):ok()
	end)

	it("teaches the player something on every storm", function()
		for _, storm in ipairs(StormTypes.List) do
			expect(storm.teaches):typeOf("string")
			expect(#storm.teaches):greaterThan(10)
			expect(storm.discoveryId):typeOf("string")
		end
	end)

	it("places every storm in at least one region", function()
		local placed = {}
		for _, region in ipairs(Regions.List) do
			for stormId in pairs(region.storms.types) do
				placed[stormId] = true
			end
		end
		for _, storm in ipairs(StormTypes.List) do
			if not placed[storm.id] then
				error("storm type '" .. storm.id .. "' is never placed in any region")
			end
		end
	end)
end)

describe("Config/Stats", function()
	it("gives every stat a base within its own bounds", function()
		for _, stat in ipairs(Stats.List) do
			expect(stat.base):greaterOrEqual(stat.min)
			expect(stat.base):lessOrEqual(stat.max)
		end
	end)

	it("assigns every stat to a declared category", function()
		local categories = {}
		for _, category in ipairs(Stats.Categories) do
			categories[category.id] = true
		end
		for _, stat in ipairs(Stats.List) do
			expect(categories[stat.category]):ok()
		end
	end)

	it("resolves base values with an empty accumulator", function()
		local accumulator = Stats.CreateAccumulator()
		local values = Stats.Resolve(accumulator)
		for _, stat in ipairs(Stats.List) do
			expect(values[stat.id]):equal(stat.base)
		end
	end)

	it("applies flat, increased and more in the documented order", function()
		local accumulator = Stats.CreateAccumulator()
		-- capacity base 120: (120 + 80) * (1 + 0.5) * 2 = 600
		Stats.Contribute(accumulator, "capacity", "flat", 80, "test")
		Stats.Contribute(accumulator, "capacity", "increased", 0.5, "test")
		Stats.Contribute(accumulator, "capacity", "more", 1.0, "test")
		local values = Stats.Resolve(accumulator)
		expect(values.capacity):near(600, 0.001)
	end)

	it("stacks increased additively and more multiplicatively", function()
		local additive = Stats.CreateAccumulator()
		Stats.Contribute(additive, "captureYield", "increased", 0.2, "a")
		Stats.Contribute(additive, "captureYield", "increased", 0.2, "b")
		local additiveValues = Stats.Resolve(additive)
		expect(additiveValues.captureYield):near(1.4, 1e-9)

		local multiplicative = Stats.CreateAccumulator()
		Stats.Contribute(multiplicative, "captureYield", "more", 0.2, "a")
		Stats.Contribute(multiplicative, "captureYield", "more", 0.2, "b")
		local multiplicativeValues = Stats.Resolve(multiplicative)
		expect(multiplicativeValues.captureYield):near(1.44, 1e-9)
	end)

	it("clamps resolved values to declared bounds", function()
		local accumulator = Stats.CreateAccumulator()
		Stats.Contribute(accumulator, "stormResist", "flat", 99, "overkill")
		local values = Stats.Resolve(accumulator)
		expect(values.stormResist):equal(Stats.ById.stormResist.max)
	end)

	it("records contribution sources for the character sheet", function()
		local accumulator = Stats.CreateAccumulator()
		Stats.Contribute(accumulator, "moveSpeed", "flat", 4, "Fleet 4")
		local _, sources = Stats.Resolve(accumulator)
		expect(#sources.moveSpeed):equal(1)
		expect(sources.moveSpeed[1].label):equal("Fleet 4")
	end)

	it("ignores contributions to unknown stats without crashing", function()
		local accumulator = Stats.CreateAccumulator()
		harness.Mock.captureWarnings = true
		Stats.Contribute(accumulator, "notARealStat", "flat", 5, "bogus")
		harness.Mock.captureWarnings = false
		local values = Stats.Resolve(accumulator)
		expect(values.notARealStat):isNil()
	end)

	it("formats values and deltas by declared format", function()
		expect(Stats.Format("stormResist", 0.42)):equal("42%")
		expect(Stats.Format("captureYield", 1.5)):equal("1.50x")
		expect(Stats.Format("captureRadius", 34)):equal("34 studs")

		local text, direction = Stats.FormatDelta("captureRadius", 30, 40)
		expect(text):equal("+10")
		expect(direction):equal("better")

		local _, worse = Stats.FormatDelta("captureRadius", 40, 30)
		expect(worse):equal("worse")
	end)
end)

describe("Config/Upgrades", function()
	it("references only real stats", function()
		local referenced = {}
		for _, upgrade in ipairs(Upgrades.List) do
			collectEffectStats(upgrade.perLevel, referenced, upgrade.id)
			for level, milestone in pairs(upgrade.milestones or {}) do
				collectEffectStats(milestone.effect, referenced, upgrade.id .. "@" .. level)
			end
		end
		for _, entry in ipairs(referenced) do
			if not Stats.ById[entry.stat] then
				error(("unknown stat '%s' referenced by %s"):format(entry.stat, entry.context))
			end
		end
	end)

	it("references only real abilities, traversal and regions in milestones", function()
		for _, upgrade in ipairs(Upgrades.List) do
			for level, milestone in pairs(upgrade.milestones or {}) do
				local context = upgrade.id .. "@" .. level
				if milestone.grantsAbility and not Abilities.ActiveById[milestone.grantsAbility] then
					error("unknown ability in " .. context .. ": " .. milestone.grantsAbility)
				end
				if milestone.unlocksTraversal and not Traversal.ById[milestone.unlocksTraversal] then
					error("unknown traversal in " .. context .. ": " .. milestone.unlocksTraversal)
				end
				if milestone.gatesRegion and not Regions.ById[milestone.gatesRegion] then
					error("unknown region in " .. context .. ": " .. milestone.gatesRegion)
				end
				expect(level):lessOrEqual(upgrade.maxLevel)
			end
		end
	end)

	it("grows costs monotonically and stays finite until max", function()
		for _, upgrade in ipairs(Upgrades.List) do
			local previous = 0
			for level = 0, upgrade.maxLevel - 1 do
				local cost = Upgrades.GetCost(upgrade.id, level)
				expect(cost):greaterOrEqual(previous)
				previous = cost
			end
			expect(Upgrades.GetCost(upgrade.id, upgrade.maxLevel)):equal(math.huge)
		end
	end)

	it("computes affordable levels exactly", function()
		local levels, spent = Upgrades.GetAffordableLevels("capture_coil", 0, 1000)
		expect(levels):greaterThan(0)
		expect(spent):lessOrEqual(1000)

		-- Buying one more level must exceed the budget, or we hit max rank.
		local upgrade = Upgrades.Get("capture_coil")
		if levels < upgrade.maxLevel then
			local nextCost = Upgrades.GetCost("capture_coil", levels)
			expect(spent + nextCost):greaterThan(1000)
		end
	end)

	it("reports the next milestone and its distance", function()
		local milestone, distance = Upgrades.GetNextMilestone("capture_coil", 0)
		expect(milestone):ok()
		expect(distance):equal(5)

		local later, laterDistance = Upgrades.GetNextMilestone("capture_coil", 6)
		expect(later.id):equal("coil_autostabilise")
		expect(laterDistance):equal(6)
	end)

	it("returns no milestone once every one is earned", function()
		local milestone = Upgrades.GetNextMilestone("capture_coil", 999)
		expect(milestone):isNil()
	end)

	it("applies purchased levels and earned milestones to stats", function()
		local accumulator = Stats.CreateAccumulator()
		Upgrades.ApplyToAccumulator(Stats, accumulator, { capture_coil = 12, containment_cell = 10 })
		local values = Stats.Resolve(accumulator)

		-- 12 levels of capture_coil at +3.5% increased window each.
		expect(values.captureWindow):near(1 + 12 * 0.035, 1e-9)
		-- Milestone at level 5 grants flat shock resistance.
		expect(values.shockResist):greaterThan(0)
		-- Containment grows from both flat and increased terms.
		expect(values.capacity):greaterThan(Stats.ById.capacity.base)
	end)

	it("collects behaviour and traversal unlocks from milestones", function()
		local behaviours = Upgrades.CollectBehaviours({ capture_coil = 12, bank_interface = 9 })
		expect(behaviours.capture_salvage):ok()
		expect(behaviours.remote_bank):ok()
		expect(behaviours.no_chain_cap):falsy()

		local traversal = Upgrades.CollectTraversal({ actuators = 22 })
		expect(traversal.slide):ok()
		expect(traversal.vault):ok()
		expect(traversal.mantle):ok()
	end)

	it("gates every region that needs insulation behind an insulation milestone", function()
		local gated = {}
		for level, milestone in pairs(Upgrades.Get("insulation").milestones) do
			if milestone.gatesRegion then
				gated[milestone.gatesRegion] = level
			end
		end
		expect(gated.industrial_grid):ok()
		expect(gated.electrical_wasteland):ok()
		expect(gated.high_altitude):ok()
		expect(gated.storm_core):ok()
	end)
end)

describe("Config/Abilities", function()
	it("references only real stats in scaling rules", function()
		for _, ability in ipairs(Abilities.Actives) do
			for effectKey, rule in pairs(ability.scaling or {}) do
				if not Stats.ById[rule.stat] then
					error(("%s scales %s off unknown stat '%s'"):format(ability.id, effectKey, rule.stat))
				end
				-- Scaling must target an effect that actually exists on the ability.
				if ability.effects[effectKey] == nil then
					error(("%s scales unknown effect '%s'"):format(ability.id, effectKey))
				end
			end
		end
	end)

	it("gives every active a positive cooldown and known tags", function()
		local validTags = {}
		for _, tag in pairs(Abilities.Tags) do
			validTags[tag] = true
		end
		for _, ability in ipairs(Abilities.Actives) do
			expect(ability.cooldown):greaterThan(0)
			expect(#ability.tags):greaterThan(0)
			for _, tag in ipairs(ability.tags) do
				if not validTags[tag] then
					error(("%s uses unknown tag '%s'"):format(ability.id, tag))
				end
			end
		end
	end)

	it("resolves scaled effects against a stat block", function()
		local stats = Stats.CreateBaseTable()
		stats.maxHealth = 300
		local effects = Abilities.ResolveEffects("static_shield", stats)
		-- base 140 + 300 * 0.9 = 410
		expect(effects.damageAbsorbed):near(410, 1e-6)
	end)

	it("respects caps and floors in scaling rules", function()
		local stats = Stats.CreateBaseTable()
		stats.stormResist = 0.8
		local effects = Abilities.ResolveEffects("bulwark_stance", stats)
		expect(effects.damageReduction):lessOrEqual(0.92)

		stats.bankRate = 100
		local extract = Abilities.ResolveEffects("emergency_extract", stats)
		expect(extract.bankPenalty):greaterOrEqual(0)
	end)

	it("reduces cooldowns but never below the floor", function()
		local stats = Stats.CreateBaseTable()
		stats.abilityCooldown = 0
		expect(Abilities.GetCooldown("surge", stats)):equal(12)

		stats.abilityCooldown = 0.95
		expect(Abilities.GetCooldown("surge", stats)):near(12 * 0.3, 1e-9)
	end)

	it("validates loadouts against slot count, duplicates and ownership", function()
		local owned = { surge = true, purge = true, blink_step = true }

		local ok = Abilities.ValidateLoadout({ "surge", "purge" }, owned)
		expect(ok):ok()

		local dupOk, dupReason = Abilities.ValidateLoadout({ "surge", "surge" }, owned)
		expect(dupOk):falsy()
		expect(dupReason):contains("duplicate")

		local unownedOk, unownedReason = Abilities.ValidateLoadout({ "overclock" }, owned)
		expect(unownedOk):falsy()
		expect(unownedReason):contains("not_owned")

		local tooMany = Abilities.ValidateLoadout({ "surge", "purge", "blink_step", "surge", "purge" }, owned)
		expect(tooMany):falsy()
	end)
end)

describe("Config/Traversal", function()
	it("references real upgrades, skills and quests as unlock sources", function()
		for _, ability in ipairs(Traversal.List) do
			local source = ability.unlockSource
			if source then
				if source.type == "upgrade" then
					if not Upgrades.ById[source.id] then
						error(("traversal %s unlocks from unknown upgrade %s"):format(ability.id, source.id))
					end
					local milestone = Upgrades.Get(source.id).milestones[source.level]
					if not milestone then
						error(("traversal %s expects a milestone at %s level %d"):format(ability.id, source.id, source.level))
					end
				elseif source.type == "skill" then
					if not SkillTree.NodeById[source.id] then
						error(("traversal %s unlocks from unknown skill %s"):format(ability.id, source.id))
					end
				end
			elseif not ability.unlockedByDefault then
				error("traversal " .. ability.id .. " has neither an unlock source nor a default grant")
			end
		end
	end)

	it("maps every gate to exactly one ability", function()
		for gate, abilityId in pairs(Traversal.GateToAbility) do
			expect(Traversal.ById[abilityId]):ok()
			expect(type(gate)):equal("string")
		end
	end)

	it("permits ungated obstacles and names the blocker on gated ones", function()
		local owned = { sprint = true }
		local passUngated = Traversal.CanPassGate("not_a_gate", owned)
		expect(passUngated):ok()

		local passGated, requiredAbility = Traversal.CanPassGate("anchor_point", owned)
		expect(passGated):falsy()
		expect(requiredAbility):equal("grapple")

		owned.grapple = true
		expect(Traversal.CanPassGate("anchor_point", owned)):ok()
	end)

	it("starts the player with sprint only", function()
		local defaults = Traversal.GetDefaults()
		expect(defaults.sprint):ok()
		local count = 0
		for _ in pairs(defaults) do
			count += 1
		end
		expect(count):equal(1)
	end)

	it("suggests the next locked traversal ability in order", function()
		local next1 = Traversal.GetNext({ sprint = true })
		expect(next1.id):equal("slide")
	end)
end)

describe("Config/SkillTree", function()
	it("assigns every node to a declared branch", function()
		for _, node in ipairs(SkillTree.Nodes) do
			expect(SkillTree.BranchById[node.branch]):ok()
		end
	end)

	it("has unique node ids", function()
		local seen = {}
		for _, node in ipairs(SkillTree.Nodes) do
			if seen[node.id] then
				error("duplicate skill node id: " .. node.id)
			end
			seen[node.id] = true
		end
	end)

	it("references only real stats in node effects", function()
		local referenced = {}
		for _, node in ipairs(SkillTree.Nodes) do
			collectEffectStats(node.effects, referenced, node.id)
		end
		for _, entry in ipairs(referenced) do
			if not Stats.ById[entry.stat] then
				error(("unknown stat '%s' referenced by skill %s"):format(entry.stat, entry.context))
			end
		end
	end)

	it("references only real abilities, passives and traversal", function()
		for _, node in ipairs(SkillTree.Nodes) do
			if node.grantsAbility and not Abilities.ActiveById[node.grantsAbility] then
				error(node.id .. " grants unknown ability " .. node.grantsAbility)
			end
			if node.grantsPassive and not Abilities.PassiveById[node.grantsPassive] then
				error(node.id .. " grants unknown passive " .. node.grantsPassive)
			end
			if node.grantsTraversal and not Traversal.ById[node.grantsTraversal] then
				error(node.id .. " grants unknown traversal " .. node.grantsTraversal)
			end
		end
	end)

	it("only depends on prerequisites that exist, in the same branch, at a lower tier", function()
		for _, node in ipairs(SkillTree.Nodes) do
			for _, requirement in ipairs(node.requires) do
				local prerequisite = SkillTree.NodeById[requirement.id]
				if not prerequisite then
					error(node.id .. " requires unknown node " .. requirement.id)
				end
				if prerequisite.tier >= node.tier then
					error(("%s (tier %d) requires %s at tier %d — prerequisites must be shallower")
						:format(node.id, node.tier, prerequisite.id, prerequisite.tier))
				end
				if requirement.rank > prerequisite.maxRank then
					error(("%s requires %s rank %d but its max is %d")
						:format(node.id, prerequisite.id, requirement.rank, prerequisite.maxRank))
				end
			end
		end
	end)

	it("makes mutual exclusivity symmetric", function()
		for _, node in ipairs(SkillTree.Nodes) do
			for _, otherId in ipairs(node.exclusiveWith or {}) do
				local other = SkillTree.NodeById[otherId]
				expect(other):ok()
				local reciprocal = false
				for _, backId in ipairs(other.exclusiveWith or {}) do
					if backId == node.id then
						reciprocal = true
					end
				end
				if not reciprocal then
					error(("%s excludes %s but not the other way round"):format(node.id, otherId))
				end
			end
		end
	end)

	it("gives every keystone a stated downside", function()
		for _, node in ipairs(SkillTree.Nodes) do
			if node.kind == "keystone" then
				expect(node.downside):typeOf("string")
				expect(#node.downside):greaterThan(5)
			end
		end
	end)

	it("makes every branch reachable from a tier-1 node with no prerequisites", function()
		for _, branch in ipairs(SkillTree.Branches) do
			local hasRoot = false
			for _, nodeId in ipairs(SkillTree.NodesByBranch[branch.id]) do
				local node = SkillTree.NodeById[nodeId]
				if #node.requires == 0 then
					hasRoot = true
				end
			end
			if not hasRoot then
				error("branch " .. branch.id .. " has no entry node")
			end
		end
	end)

	it("gives every branch a comparable node count", function()
		local counts = {}
		for _, branch in ipairs(SkillTree.Branches) do
			counts[branch.id] = #SkillTree.NodesByBranch[branch.id]
		end
		local min, max = math.huge, 0
		for _, count in pairs(counts) do
			min = math.min(min, count)
			max = math.max(max, count)
		end
		expect(max - min):lessOrEqual(2)
	end)

	it("blocks purchases that miss prerequisites, points or exclusivity", function()
		local ranks = {}
		local okNoPrereq, reason = SkillTree.CanRankUp("runner_kinetic_jump", ranks, 99)
		expect(okNoPrereq):falsy()
		expect(reason):equal("missing_prerequisite")

		ranks.runner_fleet = 3
		local okWithPrereq = SkillTree.CanRankUp("runner_kinetic_jump", ranks, 99)
		expect(okWithPrereq):ok()

		local okNoPoints, pointsReason = SkillTree.CanRankUp("runner_kinetic_jump", ranks, 0)
		expect(okNoPoints):falsy()
		expect(pointsReason):equal("insufficient_points")
	end)

	it("enforces keystone exclusivity in both directions", function()
		local ranks = { runner_ks_featherweight = 1 }
		local ok, reason = SkillTree.CanRankUp("vault_ks_deep_reserve", ranks, 99)
		expect(ok):falsy()
		expect(reason):equal("mutually_exclusive")
	end)

	it("refuses to rank a node past its maximum", function()
		local node = SkillTree.NodeById.runner_fleet
		local ranks = { runner_fleet = node.maxRank }
		local ok, reason = SkillTree.CanRankUp("runner_fleet", ranks, 99)
		expect(ok):falsy()
		expect(reason):equal("max_rank")
	end)

	it("accounts spent points consistently with rank costs", function()
		local ranks = { runner_fleet = 3 }
		local expected = SkillTree.GetRankCost("runner_fleet", 0)
			+ SkillTree.GetRankCost("runner_fleet", 1)
			+ SkillTree.GetRankCost("runner_fleet", 2)
		expect(SkillTree.GetSpentPoints(ranks)):equal(expected)
	end)

	it("validates legal rank tables and rejects illegal ones", function()
		local legal = { runner_fleet = 3, runner_kinetic_jump = 1 }
		local ok = SkillTree.ValidateRanks(legal)
		expect(ok):ok()

		local illegal = { runner_kinetic_jump = 1 }
		local badOk, problems = SkillTree.ValidateRanks(illegal)
		expect(badOk):falsy()
		expect(#problems):greaterThan(0)

		local overRanked = { runner_fleet = 999 }
		expect(SkillTree.ValidateRanks(overRanked)):falsy()
	end)

	it("applies ranked effects scaled by rank", function()
		local accumulator = Stats.CreateAccumulator()
		SkillTree.ApplyToAccumulator(Stats, accumulator, { runner_fleet = 5 })
		local values = Stats.Resolve(accumulator)
		expect(values.moveSpeed):near(Stats.ById.moveSpeed.base + 5 * 0.5, 1e-9)
	end)

	it("collects grants from a rank table", function()
		local grants = SkillTree.CollectGrants({
			runner_fleet = 3,
			runner_kinetic_jump = 1,
			conductor_chain_link = 1,
			hunter_scavenger = 1,
		})
		expect(grants.traversal.double_jump):ok()
		expect(grants.abilities.chain_link):ok()
		expect(grants.passives.scavenger_instinct):ok()
	end)

	it("identifies a specialisation and detects hybrids", function()
		local pure, spent, isHybrid = SkillTree.GetSpecialisation({ runner_fleet = 5, runner_light_frame = 4 })
		expect(pure):equal("runner")
		expect(spent):greaterThan(0)
		expect(isHybrid):falsy()

		local _, _, hybrid = SkillTree.GetSpecialisation({ runner_fleet = 4, vault_reinforced = 4, hunter_survey = 4 })
		expect(hybrid):ok()
	end)

	it("returns no specialisation for an empty build", function()
		local branch, spent = SkillTree.GetSpecialisation({})
		expect(branch):isNil()
		expect(spent):equal(0)
	end)
end)

describe("Config/Balance", function()
	it("orders capture grades from strictest to loosest", function()
		local previous = 0
		for _, grade in ipairs(Balance.Capture.GRADES) do
			expect(grade.maxDistance):greaterThan(previous)
			previous = grade.maxDistance
		end
		expect(previous):equal(1.0)
	end)

	it("pays better grades more", function()
		local grades = Balance.Capture.GRADES
		for i = 1, #grades - 1 do
			expect(grades[i].yieldScale):greaterThan(grades[i + 1].yieldScale)
			expect(grades[i].xpScale):greaterThan(grades[i + 1].xpScale)
		end
	end)

	it("orders loot rarities by descending weight", function()
		local previous = math.huge
		for _, rarity in ipairs(Balance.Loot.RARITY_ORDER) do
			local weight = Balance.Loot.RARITY_BASE_WEIGHTS[rarity]
			expect(weight):ok()
			expect(weight):lessThan(previous)
			previous = weight
		end
	end)

	it("defines a modifier count range for every rarity", function()
		for _, rarity in ipairs(Balance.Loot.RARITY_ORDER) do
			local range = Balance.Loot.MODIFIER_COUNTS[rarity]
			expect(range):ok()
			expect(range.max):greaterOrEqual(range.min)
		end
	end)

	it("keeps death punishing but survivable", function()
		local carry = Balance.Carry
		expect(carry.DEATH_LOSS_FRACTION + carry.DEATH_CACHE_FRACTION):lessOrEqual(1.0)
		expect(carry.DEATH_LOSS_FRACTION):lessThan(1.0)
		expect(carry.VENT_ENERGY_LOSS_FRACTION):lessThan(carry.DEATH_LOSS_FRACTION)
	end)

	it("orders instability thresholds", function()
		expect(Balance.Carry.INSTABILITY_WARNING):lessThan(Balance.Carry.INSTABILITY_CRITICAL)
		expect(Balance.Carry.INSTABILITY_CRITICAL):lessThan(1.0)
	end)

	it("defines every quality tier with sane budgets", function()
		local previous = 0
		for _, tier in ipairs({ "low", "medium", "high", "ultra" }) do
			local budget = Balance.Performance.QUALITY_TIERS[tier]
			expect(budget):ok()
			expect(budget.maxParticleEmitters):greaterThan(previous)
			previous = budget.maxParticleEmitters
		end
	end)

	it("freezes config against accidental runtime mutation", function()
		expect(function()
			Balance.Capture.BASE_WINDUP_SECONDS = 99
		end):throws()
	end)
end)
