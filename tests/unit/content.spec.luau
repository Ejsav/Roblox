--!nolint
--[[ Cross-reference and behaviour specs for the equipment, loot and quest content. ]]

local loadModule = loadModule

local Balance = loadModule("Shared/Config/Balance")
local Regions = loadModule("Shared/Config/Regions")
local StormTypes = loadModule("Shared/Config/StormTypes")
local Stats = loadModule("Shared/Config/Stats")
local Resources = loadModule("Shared/Config/Resources")
local Equipment = loadModule("Shared/Config/Equipment")
local Modifiers = loadModule("Shared/Config/Modifiers")
local Quests = loadModule("Shared/Config/Quests")
local Traversal = loadModule("Shared/Config/Traversal")
local Abilities = loadModule("Shared/Config/Abilities")
local RNG = loadModule("Shared/Core/RNG")

-- Luau cannot index a table constructor inline, so the valid aggregation channels
-- live in one shared lookup.
local VALID_KINDS = { flat = true, increased = true, more = true }

describe("Config/Resources", function()
	it("references only real regions and storms in its sources", function()
		for _, resource in ipairs(Resources.List) do
			for _, regionId in ipairs(resource.sources.regions or {}) do
				if not Regions.ById[regionId] then
					error(resource.id .. " sources from unknown region " .. regionId)
				end
			end
			for _, stormId in ipairs(resource.sources.storms or {}) do
				if not StormTypes.ById[stormId] then
					error(resource.id .. " sources from unknown storm " .. stormId)
				end
			end
		end
	end)

	it("increases base value with tier", function()
		local highestByTier = {}
		for _, resource in ipairs(Resources.List) do
			highestByTier[resource.tier] = math.max(highestByTier[resource.tier] or 0, resource.baseValue)
		end
		local previous = 0
		for tier = 1, 6 do
			if highestByTier[tier] then
				expect(highestByTier[tier]):greaterThan(previous)
				previous = highestByTier[tier]
			end
		end
	end)

	it("supplies every material referenced by a region resource table", function()
		for _, region in ipairs(Regions.List) do
			for resourceId in pairs(region.resources) do
				if not Resources.ById[resourceId] then
					error(("region %s drops unknown resource %s"):format(region.id, resourceId))
				end
			end
		end
	end)

	it("places every material in at least one region resource table", function()
		local placed = {}
		for _, region in ipairs(Regions.List) do
			for resourceId in pairs(region.resources) do
				placed[resourceId] = true
			end
		end
		for _, resource in ipairs(Resources.List) do
			if not placed[resource.id] then
				error("resource " .. resource.id .. " never drops anywhere")
			end
		end
	end)

	it("describes where to find a material in plain language", function()
		local text = Resources.DescribeSources("fulgurite_spine", Regions, StormTypes)
		expect(text):contains("The Scour")
		expect(text):contains("Glass Storm")
	end)

	it("rolls region-weighted material drops", function()
		local rng = RNG.new("resource-roll")
		local counts = {}
		local weights = Regions.ById.starter_district.resources
		for _ = 1, 5000 do
			local rolled = Resources.RollForRegion(rng, weights)
			counts[rolled] = (counts[rolled] or 0) + 1
		end
		-- scrap_conductor carries 60 of the 100 weight, so it must dominate.
		expect(counts.scrap_conductor):greaterThan(counts.copper_winding)
	end)
end)

describe("Config/Equipment", function()
	it("assigns every base and unique to a real slot", function()
		for _, base in ipairs(Equipment.Bases) do
			expect(Equipment.SlotById[base.slot]):ok()
		end
		for _, unique in ipairs(Equipment.Uniques) do
			expect(Equipment.SlotById[unique.slot]):ok()
		end
	end)

	it("references only real stats in base stat blocks", function()
		local function check(definition)
			for kind, statMap in pairs(definition.baseStats) do
				expect(VALID_KINDS[kind]):ok()
				for statId in pairs(statMap) do
					if not Stats.ById[statId] then
						error(("%s grants unknown stat %s"):format(definition.id, statId))
					end
				end
			end
		end
		for _, base in ipairs(Equipment.Bases) do
			check(base)
		end
		for _, unique in ipairs(Equipment.Uniques) do
			check(unique)
		end
	end)

	it("drops every base in at least one real region", function()
		for _, base in ipairs(Equipment.Bases) do
			expect(#base.dropRegions):greaterThan(0)
			for _, regionId in ipairs(base.dropRegions) do
				if not Regions.ById[regionId] then
					error(base.id .. " drops in unknown region " .. regionId)
				end
			end
		end
	end)

	it("fills every slot at every progression stage", function()
		-- No slot may go more than 25 levels without a new base becoming available,
		-- or a build stalls with a dead slot for an entire region.
		for _, slot in ipairs(Equipment.Slots) do
			local levels = {}
			for _, baseId in ipairs(Equipment.BasesBySlot[slot.id]) do
				table.insert(levels, Equipment.BaseById[baseId].requiredLevel)
			end
			table.sort(levels)
			expect(levels[1]):lessOrEqual(5)
			for i = 2, #levels do
				if levels[i] - levels[i - 1] > 25 then
					error(("slot %s has a %d level gap between %d and %d")
						:format(slot.id, levels[i] - levels[i - 1], levels[i - 1], levels[i]))
				end
			end
		end
	end)

	it("gives every unique a real trait", function()
		for _, unique in ipairs(Equipment.Uniques) do
			if not Modifiers.TraitById[unique.trait] then
				error(unique.id .. " carries unknown trait " .. tostring(unique.trait))
			end
		end
	end)

	it("builds set membership from real bases", function()
		for _, set in ipairs(Equipment.Sets) do
			expect(#set.pieces):greaterOrEqual(2)
			for _, pieceId in ipairs(set.pieces) do
				if not Equipment.BaseById[pieceId] then
					error(("set %s references unknown base %s"):format(set.id, pieceId))
				end
			end
			-- Every declared threshold must be reachable with the pieces that exist.
			for threshold in pairs(set.bonuses) do
				expect(threshold):lessOrEqual(#set.pieces)
			end
		end
	end)

	it("references only real stats in set bonuses", function()
		for _, set in ipairs(Equipment.Sets) do
			for threshold, bonus in pairs(set.bonuses) do
				for kind, statMap in pairs(bonus.effects) do
					expect(VALID_KINDS[kind]):ok()
					for statId in pairs(statMap) do
						if not Stats.ById[statId] then
							error(("set %s tier %d grants unknown stat %s"):format(set.id, threshold, statId))
						end
					end
				end
			end
		end
	end)

	it("activates every threshold at or below the worn piece count", function()
		local set = Equipment.SetById.set_deepline
		local worn = { set.pieces[1], set.pieces[2], set.pieces[3] }
		local active = Equipment.GetActiveSetBonuses(worn)
		expect(#active):equal(2)
		expect(active[1].tier):equal(2)
		expect(active[2].tier):equal(3)

		local full = Equipment.GetActiveSetBonuses(set.pieces)
		expect(#full):equal(3)
	end)

	it("ignores set bonuses below the minimum piece count", function()
		local active = Equipment.GetActiveSetBonuses({ "plate_lineman" })
		expect(#active):equal(0)
	end)

	it("reports set progress for the UI", function()
		local progress = Equipment.GetSetProgress({ "plate_lineman", "gear_sprint_servos" })
		expect(progress.set_lineman.owned):equal(2)
		expect(progress.set_lineman.total):equal(3)
	end)

	it("filters drop pools by region and level", function()
		local early = Equipment.GetDropPool("starter_district", 1)
		expect(#early):greaterThan(0)
		for _, baseId in ipairs(early) do
			expect(Equipment.BaseById[baseId].requiredLevel):lessOrEqual(1)
		end

		local locked = Equipment.GetDropPool("storm_core", 5)
		expect(#locked):equal(0)
	end)
end)

describe("Config/Modifiers", function()
	it("references only real stats and slots", function()
		local slots = {}
		for _, slot in ipairs(Equipment.Slots) do
			slots[slot.id] = true
		end
		for _, affix in ipairs(Modifiers.Affixes) do
			if not Stats.ById[affix.stat] then
				error(affix.id .. " affects unknown stat " .. affix.stat)
			end
			expect(VALID_KINDS[affix.kind]):ok()
			expect(#affix.slots):greaterThan(0)
			for _, slotId in ipairs(affix.slots) do
				if not slots[slotId] then
					error(affix.id .. " targets unknown slot " .. slotId)
				end
			end
		end
	end)

	it("defines six strictly increasing tiers for every affix", function()
		for _, affix in ipairs(Modifiers.Affixes) do
			expect(#affix.tiers):equal(Modifiers.MAX_TIER)
			local previousMax = -math.huge
			for tier, range in ipairs(affix.tiers) do
				expect(range[2]):greaterOrEqual(range[1])
				if range[1] < previousMax then
					error(("%s tier %d starts below tier %d's ceiling"):format(affix.id, tier, tier - 1))
				end
				previousMax = range[2]
			end
		end
	end)

	it("offers affixes for every equipment slot", function()
		for _, slot in ipairs(Equipment.Slots) do
			local pool = Modifiers.AffixesBySlot[slot.id]
			expect(pool):ok()
			-- Enough distinct affixes that a max-affix roll never runs the pool dry.
			expect(#pool):greaterOrEqual(6)
		end
	end)

	it("caps affix tier by item tier", function()
		expect(Modifiers.GetMaxAffixTier(1)):equal(1)
		expect(Modifiers.GetMaxAffixTier(4)):equal(4)
		expect(Modifiers.GetMaxAffixTier(7)):equal(6)
	end)

	it("rolls affixes within the declared tier range", function()
		local rng = RNG.new("affix-roll")
		for _ = 1, 400 do
			local rolled = Modifiers.RollAffix(rng, "capture_device", 4)
			expect(rolled):ok()
			local affix = Modifiers.AffixById[rolled.affixId]
			expect(rolled.tier):within(1, 4)
			local range = affix.tiers[rolled.tier]
			expect(rolled.value):within(range[1], range[2])
		end
	end)

	it("never rolls the same affix twice on one item", function()
		local rng = RNG.new("affix-distinct")
		for _ = 1, 200 do
			local rolled = Modifiers.RollAffixes(rng, "utility", 6, 6)
			local seen = {}
			for _, entry in ipairs(rolled) do
				expect(seen[entry.affixId]):isNil()
				seen[entry.affixId] = true
			end
		end
	end)

	it("stops rolling when the slot pool is exhausted", function()
		local rng = RNG.new("affix-exhaust")
		local poolSize = #Modifiers.AffixesBySlot.scanner
		local rolled = Modifiers.RollAffixes(rng, "scanner", 6, poolSize + 5)
		expect(#rolled):equal(poolSize)
	end)

	it("builds prefix-base-suffix names", function()
		local rolled = {
			{ affixId = "affix_tuned", tier = 3, value = 0.08 },
			{ affixId = "affix_fortunate", tier = 2, value = 0.2 },
		}
		local name = Modifiers.BuildName("Resonator", rolled)
		expect(name):equal("Tuned Resonator of Fortune")
	end)

	it("uses the base name alone when nothing rolled", function()
		expect(Modifiers.BuildName("Field Tap", {})):equal("Field Tap")
	end)

	it("describes affixes by their stat's format", function()
		local percentText = Modifiers.DescribeAffix({ affixId = "affix_insulated", tier = 3, value = 0.065 }, Stats)
		expect(percentText):contains("%")
		expect(percentText):contains("Storm Resistance")

		local increasedText = Modifiers.DescribeAffix({ affixId = "affix_greedy", tier = 2, value = 0.07 }, Stats)
		expect(increasedText):contains("increased")
	end)

	it("applies rolled affixes into a stat accumulator", function()
		local accumulator = Stats.CreateAccumulator()
		Modifiers.ApplyAffixes(Stats, accumulator, {
			{ affixId = "affix_capacious", tier = 3, value = 50 },
			{ affixId = "affix_vast", tier = 2, value = 0.08 },
		}, "Test Cell")
		local values = Stats.Resolve(accumulator)
		expect(values.capacity):near((Stats.ById.capacity.base + 50) * 1.08, 1e-6)
	end)

	it("gives every trait a behaviour hook", function()
		for _, trait in ipairs(Modifiers.Traits) do
			expect(trait.behaviour):typeOf("string")
			expect(#trait.description):greaterThan(20)
		end
	end)
end)

describe("Config/Quests", function()
	it("has unique ids and real prerequisites", function()
		local seen = {}
		for _, quest in ipairs(Quests.List) do
			if seen[quest.id] then
				error("duplicate quest id " .. quest.id)
			end
			seen[quest.id] = true
			for _, prerequisiteId in ipairs(quest.prerequisites or {}) do
				if not Quests.ById[prerequisiteId] then
					error(quest.id .. " requires unknown quest " .. prerequisiteId)
				end
			end
		end
	end)

	it("assigns quests to real regions", function()
		for _, quest in ipairs(Quests.List) do
			if quest.region and not Regions.ById[quest.region] then
				error(quest.id .. " is set in unknown region " .. quest.region)
			end
		end
	end)

	it("supplies every quest that a region unlock depends on", function()
		for _, region in ipairs(Regions.List) do
			if region.unlock.quest then
				if not Quests.ById[region.unlock.quest] then
					error(("region %s is gated behind missing quest %s"):format(region.id, region.unlock.quest))
				end
			end
		end
	end)

	it("supplies every quest that a traversal unlock depends on", function()
		for _, ability in ipairs(Traversal.List) do
			local source = ability.unlockSource
			if source and source.type == "quest" then
				if not Quests.ById[source.id] then
					error(("traversal %s is gated behind missing quest %s"):format(ability.id, source.id))
				end
				local quest = Quests.ById[source.id]
				if quest.rewards.unlocksTraversal ~= ability.id then
					error(("quest %s should award traversal %s but awards %s")
						:format(quest.id, ability.id, tostring(quest.rewards.unlocksTraversal)))
				end
			end
		end
	end)

	it("supplies every quest that an ability unlock depends on", function()
		for _, ability in ipairs(Abilities.Actives) do
			local source = ability.unlockSource
			if source and source.type == "quest" then
				if not Quests.ById[source.id] then
					error(("ability %s is gated behind missing quest %s"):format(ability.id, source.id))
				end
			end
		end
	end)

	it("awards only real items, storms and regions", function()
		for _, quest in ipairs(Quests.List) do
			local rewards = quest.rewards
			if rewards.item and not Equipment.GetDefinition(rewards.item) then
				error(quest.id .. " awards unknown item " .. rewards.item)
			end
			if rewards.unlocksRegionHint and not Regions.ById[rewards.unlocksRegionHint] then
				error(quest.id .. " hints at unknown region " .. rewards.unlocksRegionHint)
			end
			if rewards.unlocksTraversal and not Traversal.ById[rewards.unlocksTraversal] then
				error(quest.id .. " awards unknown traversal " .. rewards.unlocksTraversal)
			end
			if rewards.unlocksAbility and not Abilities.ActiveById[rewards.unlocksAbility] then
				error(quest.id .. " awards unknown ability " .. rewards.unlocksAbility)
			end
		end
	end)

	it("references only real storms, subregions and resources in objectives", function()
		for _, quest in ipairs(Quests.List) do
			for _, objective in ipairs(quest.objectives) do
				if objective.storm and not StormTypes.ById[objective.storm] then
					error(quest.id .. " targets unknown storm " .. objective.storm)
				end
				if objective.subregion and not Regions.SubregionsById[objective.subregion] then
					error(quest.id .. " targets unknown subregion " .. objective.subregion)
				end
				if objective.region and not Regions.ById[objective.region] then
					error(quest.id .. " targets unknown region " .. objective.region)
				end
				if objective.resource and not Resources.ById[objective.resource] then
					error(quest.id .. " targets unknown resource " .. objective.resource)
				end
				if objective.stat and not Stats.ById[objective.stat] then
					error(quest.id .. " targets unknown stat " .. objective.stat)
				end
				if objective.ability and not Traversal.ById[objective.ability] then
					error(quest.id .. " targets unknown traversal " .. objective.ability)
				end
				expect(objective.description):typeOf("string")
			end
		end
	end)

	it("makes every main quest teach something", function()
		for _, questId in ipairs(Quests.MainChain) do
			local quest = Quests.ById[questId]
			expect(quest.teaches):typeOf("string")
			expect(#quest.teaches):greaterThan(5)
		end
	end)

	it("orders the main chain by ascending required level", function()
		local previousLevel = 0
		for _, questId in ipairs(Quests.MainChain) do
			local quest = Quests.ById[questId]
			local required = quest.requiredLevel or previousLevel
			expect(required):greaterOrEqual(previousLevel)
			previousLevel = required
		end
	end)

	it("forms a connected main chain with no orphans", function()
		for index, questId in ipairs(Quests.MainChain) do
			local quest = Quests.ById[questId]
			if index == 1 then
				expect(#quest.prerequisites):equal(0)
			else
				expect(#quest.prerequisites):greaterThan(0)
			end
		end
	end)

	it("keeps main quest rewards increasing through the chain", function()
		local previousWatts = 0
		for _, questId in ipairs(Quests.MainChain) do
			local watts = Quests.ById[questId].rewards.watts or 0
			expect(watts):greaterThan(previousWatts)
			previousWatts = watts
		end
	end)

	it("gates availability on prerequisites, level and active state", function()
		local state = { level = 1, completedQuests = {}, activeQuests = {}, questCooldowns = {}, now = 0 }

		expect(Quests.IsAvailable("intro_first_light", state)):ok()

		local ok, reason = Quests.IsAvailable("intro_bank_it", state)
		expect(ok):falsy()
		expect(reason):equal("prerequisite")

		state.completedQuests.intro_first_light = true
		expect(Quests.IsAvailable("intro_bank_it", state)):ok()

		state.activeQuests.intro_bank_it = { progress = 0 }
		local activeOk, activeReason = Quests.IsAvailable("intro_bank_it", state)
		expect(activeOk):falsy()
		expect(activeReason):equal("already_active")
	end)

	it("respects repeatable cooldowns", function()
		local state = {
			level = 50,
			completedQuests = { intro_get_stronger = true, challenge_perfect_ten = true },
			activeQuests = {},
			questCooldowns = { challenge_perfect_ten = 5000 },
			now = 1000,
		}
		local ok, reason = Quests.IsAvailable("challenge_perfect_ten", state)
		expect(ok):falsy()
		expect(reason):equal("on_cooldown")

		state.now = 6000
		expect(Quests.IsAvailable("challenge_perfect_ten", state)):ok()
	end)

	it("blocks completed non-repeatable quests permanently", function()
		local state = {
			level = 50,
			completedQuests = { intro_first_light = true },
			activeQuests = {},
			questCooldowns = {},
			now = 0,
		}
		local ok, reason = Quests.IsAvailable("intro_first_light", state)
		expect(ok):falsy()
		expect(reason):equal("already_completed")
	end)

	it("points at the next main quest and reports chain progress", function()
		expect(Quests.GetNextMainQuest({}).id):equal("intro_first_light")

		local completed = { intro_first_light = true, intro_bank_it = true }
		expect(Quests.GetNextMainQuest(completed).id):equal("intro_get_stronger")

		local fraction, done, total = Quests.GetMainProgress(completed)
		expect(done):equal(2)
		expect(total):equal(#Quests.MainChain)
		expect(fraction):near(2 / total, 1e-9)
	end)

	it("returns nil once the main chain is finished", function()
		local completed = {}
		for _, questId in ipairs(Quests.MainChain) do
			completed[questId] = true
		end
		expect(Quests.GetNextMainQuest(completed)):isNil()
	end)

	it("scales rotating quest templates with level", function()
		local template = Quests.DailyTemplateById.daily_bank_total
		local low = Quests.InstantiateTemplate(template, 5)
		local high = Quests.InstantiateTemplate(template, 90)
		expect(high.target):greaterThan(low.target)
		expect(high.rewards.watts):greaterThan(low.rewards.watts)
		expect(low.objectiveType):equal("bank")
	end)

	it("sorts available quests main-chain first", function()
		local state = {
			level = 60,
			completedQuests = {},
			activeQuests = {},
			questCooldowns = {},
			now = 0,
		}
		local available = Quests.GetAvailable(state)
		expect(#available):greaterThan(0)
		expect(available[1].type):equal("main")
	end)

	it("gives every rotating template a scaling reward", function()
		for _, template in ipairs(Quests.DailyTemplates) do
			expect(template.rewards.wattsPerLevel):greaterThan(0)
		end
		for _, template in ipairs(Quests.WeeklyTemplates) do
			expect(template.rewards.wattsPerLevel):greaterThan(0)
			-- Weeklies must be worth meaningfully more than a daily.
			expect(template.rewards.wattsPerLevel):greaterThan(500)
		end
	end)
end)
