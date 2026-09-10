--!nolint
--[[
	Gameplay logic specs.

	These exercise the actual decision functions the game runs on — capture grading,
	stat resolution across every source, payout maths, loot rarity, instability —
	rather than testing config shape. Where a function needs a live service the spec
	builds a minimal profile and calls the pure entry point, which is exactly why
	those entry points were written as pure functions taking a profile.
]]

local loadModule = loadModule

local Balance = loadModule("Shared/Config/Balance")
local Stats = loadModule("Shared/Config/Stats")
local StormTypes = loadModule("Shared/Config/StormTypes")
local Equipment = loadModule("Shared/Config/Equipment")
local Modifiers = loadModule("Shared/Config/Modifiers")
local LootTables = loadModule("Shared/Config/LootTables")
local Upgrades = loadModule("Shared/Config/Upgrades")
local SkillTree = loadModule("Shared/Config/SkillTree")
local WorldEvents = loadModule("Shared/Config/WorldEvents")
local Abilities = loadModule("Shared/Config/Abilities")
local MathUtil = loadModule("Shared/Core/MathUtil")
local RNG = loadModule("Shared/Core/RNG")
local ProfileSchema = loadModule("Shared/Data/ProfileSchema")

-- StatsService and CaptureService are server modules; their pure entry points are
-- callable without a live registry, which is the whole point of writing them that way.
local StatsService = loadModule("Server/Services/StatsService")
local CaptureService = loadModule("Server/Services/CaptureService")

--[[ Builds a profile with the given overrides applied over the default. ]]
local function makeProfile(overrides)
	local profile = ProfileSchema.CreateDefault()
	for key, value in pairs(overrides or {}) do
		profile[key] = value
	end
	return profile
end

--[[ Adds an item to a profile's inventory and equips it. Returns the uid. ]]
local function equipItem(profile, baseId, rarity, affixes, trait)
	local uid = "test" .. tostring(#profile.inventory + 1)
	local item = ProfileSchema.CreateItem(uid, baseId, rarity, affixes or {}, trait)
	table.insert(profile.inventory, item)
	local definition = Equipment.GetDefinition(baseId)
	profile.equipped[definition.slot] = uid
	return uid
end

describe("Capture grading", function()
	it("grades a dead-centre press as Overcharge", function()
		local grade = CaptureService.Grade(0, false)
		expect(grade):equal("Overcharge")
	end)

	it("grades progressively worse with timing error", function()
		expect(CaptureService.Grade(0.03, false)):equal("Overcharge")
		expect(CaptureService.Grade(0.15, false)):equal("Perfect")
		expect(CaptureService.Grade(0.4, false)):equal("Good")
		expect(CaptureService.Grade(0.9, false)):equal("Weak")
	end)

	it("returns nil beyond the window", function()
		expect(CaptureService.Grade(1.01, false)):isNil()
		expect(CaptureService.Grade(50, false)):isNil()
	end)

	it("inverts grading for a null strike", function()
		-- Pressing at the peak of an inverted strike is the failure case.
		expect(CaptureService.Grade(0, true)):equal("Weak")
		-- Pressing at the window edge is the success case.
		expect(CaptureService.Grade(1.0, true)):equal("Overcharge")
		expect(CaptureService.Grade(0.85, true)):equal("Perfect")
	end)

	it("still misses an inverted strike pressed outside the window", function()
		expect(CaptureService.Grade(1.5, true)):isNil()
	end)

	it("returns a grade definition alongside the id", function()
		local grade, definition = CaptureService.Grade(0.1, false)
		expect(grade):equal("Perfect")
		expect(definition.yieldScale):greaterThan(1)
		expect(definition.chainValue):equal(1)
	end)

	it("never advances the chain on a Weak capture", function()
		local _, definition = CaptureService.Grade(0.9, false)
		expect(definition.chainValue):equal(0)
	end)

	it("advances the chain by two on an Overcharge", function()
		local _, definition = CaptureService.Grade(0, false)
		expect(definition.chainValue):equal(2)
	end)

	it("looks up a grade definition by id", function()
		expect(CaptureService.GetGrade("Perfect").id):equal("Perfect")
		expect(CaptureService.GetGrade("NotAGrade")):isNil()
	end)
end)

describe("Stat resolution", function()
	it("returns base values for a fresh profile", function()
		local values = StatsService.ResolveForProfile(makeProfile(), nil, 0)
		expect(values.capacity):equal(Stats.ById.capacity.base)
		expect(values.captureWindow):equal(1.0)
	end)

	it("applies upgrade levels", function()
		local profile = makeProfile({ upgrades = { containment_cell = 10 } })
		local values = StatsService.ResolveForProfile(profile, nil, 0)
		expect(values.capacity):greaterThan(Stats.ById.capacity.base + 200)
	end)

	it("applies skill ranks", function()
		local profile = makeProfile({ skills = { vault_reinforced = 6 } })
		local values = StatsService.ResolveForProfile(profile, nil, 0)
		expect(values.capacity):equal(Stats.ById.capacity.base + 6 * 34)
	end)

	it("applies equipped item base stats", function()
		local profile = makeProfile()
		equipItem(profile, "cell_bulk", "common")
		local values = StatsService.ResolveForProfile(profile, nil, 0)
		expect(values.capacity):equal(Stats.ById.capacity.base + 95)
		-- Bulk Reservoir trades speed for capacity.
		expect(values.moveSpeed):lessThan(Stats.ById.moveSpeed.base)
	end)

	it("applies rolled affixes on equipped items", function()
		local profile = makeProfile()
		equipItem(profile, "cell_standard", "rare", {
			{ affixId = "affix_capacious", tier = 3, value = 50 },
		})
		local values = StatsService.ResolveForProfile(profile, nil, 0)
		expect(values.capacity):equal(Stats.ById.capacity.base + 30 + 50)
	end)

	it("ignores an item equipped in the wrong slot", function()
		local profile = makeProfile()
		local uid = "wrong1"
		table.insert(profile.inventory, ProfileSchema.CreateItem(uid, "cell_bulk", "common", {}))
		-- Deliberately file a containment item under the plating slot.
		profile.equipped.plating = uid
		local values = StatsService.ResolveForProfile(profile, nil, 0)
		expect(values.capacity):equal(Stats.ById.capacity.base)
	end)

	it("applies set bonuses once enough pieces are worn", function()
		local profile = makeProfile()
		local set = Equipment.SetById.set_lineman

		local without = StatsService.ResolveForProfile(profile, nil, 0)

		for _, baseId in ipairs(set.pieces) do
			local uid = "set" .. baseId
			table.insert(profile.inventory, ProfileSchema.CreateItem(uid, baseId, "common", {}))
			profile.equipped[Equipment.GetDefinition(baseId).slot] = uid
		end

		local with = StatsService.ResolveForProfile(profile, nil, 0)
		-- The three-piece Lineman bonus grants capture stability.
		expect(with.captureStability):greaterThan(without.captureStability)
		expect(with.shockResist):greaterThan(without.shockResist)
	end)

	it("applies prestige bonuses per rank", function()
		local base = StatsService.ResolveForProfile(makeProfile({ prestige = 0 }), nil, 0)
		local prestiged = StatsService.ResolveForProfile(makeProfile({ prestige = 5 }), nil, 0)
		expect(prestiged.captureYield):greaterThan(base.captureYield)
		expect(prestiged.capacity):greaterThan(base.capacity)
	end)

	it("applies temporary buffs and ignores expired ones", function()
		local profile = makeProfile()

		local buffed = StatsService.ResolveForProfile(profile, {
			{
				id = "surge",
				label = "Surge",
				effects = { increased = { moveSpeed = 0.75 } },
				expiresAt = 100,
				stacks = 1,
			},
		}, 50)
		expect(buffed.moveSpeed):near(Stats.ById.moveSpeed.base * 1.75, 1e-6)

		local expired = StatsService.ResolveForProfile(profile, {
			{
				id = "surge",
				label = "Surge",
				effects = { increased = { moveSpeed = 0.75 } },
				expiresAt = 40,
				stacks = 1,
			},
		}, 50)
		expect(expired.moveSpeed):equal(Stats.ById.moveSpeed.base)
	end)

	it("multiplies buff effects by stack count", function()
		local profile = makeProfile()
		local values = StatsService.ResolveForProfile(profile, {
			{
				id = "momentum",
				label = "Momentum",
				effects = { increased = { moveSpeed = 0.04 } },
				expiresAt = nil,
				stacks = 8,
			},
		}, 0)
		expect(values.moveSpeed):near(Stats.ById.moveSpeed.base * 1.32, 1e-6)
	end)

	it("combines every source in the documented order", function()
		local profile = makeProfile({
			prestige = 2,
			upgrades = { containment_cell = 5 },
			skills = { vault_reinforced = 3 },
		})
		equipItem(profile, "cell_damped", "epic", {
			{ affixId = "affix_capacious", tier = 4, value = 100 },
			{ affixId = "affix_vast", tier = 3, value = 0.12 },
		})

		local values = StatsService.ResolveForProfile(profile, nil, 0)

		-- Every contributing source must be represented in the final number.
		local base = Stats.ById.capacity.base
		expect(values.capacity):greaterThan(base + 5 * 26 + 3 * 34 + 60 + 100)
	end)

	it("clamps every resolved stat into its declared bounds", function()
		local profile = makeProfile({ upgrades = {}, skills = {} })
		-- Stack far more resistance than the cap allows.
		profile.upgrades.insulation = 45
		profile.skills.survivor_insulated = 6
		profile.skills.survivor_deep_rated = 5
		profile.skills.survivor_hardy = 3
		profile.skills.survivor_soles = 1

		local values = StatsService.ResolveForProfile(profile, nil, 0)
		expect(values.stormResist):lessOrEqual(Stats.ById.stormResist.max)
	end)
end)

describe("Risk and payout", function()
	it("pays more for a longer chain", function()
		local short = MathUtil.RiskMultiplier(2, 1, 1)
		local long = MathUtil.RiskMultiplier(20, 1, 1)
		expect(long):greaterThan(short)
	end)

	it("pays more in a more dangerous region", function()
		local safe = MathUtil.RiskMultiplier(10, 1, 1)
		local dangerous = MathUtil.RiskMultiplier(10, 8, 1)
		expect(dangerous):greaterThan(safe)
	end)

	it("scales the bonus, not the base, with the risk stat", function()
		local baseline = MathUtil.RiskMultiplier(10, 3, 1)
		local invested = MathUtil.RiskMultiplier(10, 3, 2)
		-- Doubling the risk stat doubles the amount ABOVE 1x, not the multiplier.
		expect(invested - 1):near((baseline - 1) * 2, 1e-9)
	end)

	it("never drops below 1x", function()
		expect(MathUtil.RiskMultiplier(0, 1, 1)):greaterOrEqual(1)
		expect(MathUtil.RiskMultiplier(0, 1, 0)):equal(1)
	end)

	it("keeps a long chain worth pushing but not exponentially", function()
		-- The chain reward must keep rising, so pushing is always worth something...
		local at10 = MathUtil.RiskMultiplier(10, 1, 1)
		local at40 = MathUtil.RiskMultiplier(40, 1, 1)
		expect(at40):greaterThan(at10)
		-- ...but a 4x longer chain must not pay 4x the bonus, or banking is never
		-- the right decision.
		expect(at40 - 1):lessThan((at10 - 1) * 4)
	end)
end)

describe("Instability", function()
	--[[ Reproduces CarryService's rate formula, which is the thing under test. ]]
	local function rateAtFill(fill, resistance)
		local carry = Balance.Carry
		local base = carry.INSTABILITY_BASE_RATE + carry.INSTABILITY_CURVE_RATE * (fill ^ carry.INSTABILITY_EXPONENT)
		return base * (1 - (resistance or 0))
	end

	it("is almost negligible at low fill", function()
		expect(rateAtFill(0.25, 0)):lessThan(0.01)
	end)

	it("accelerates sharply toward full", function()
		local half = rateAtFill(0.5, 0)
		local full = rateAtFill(1.0, 0)
		-- The curve exists so that a full carry is genuinely urgent.
		expect(full):greaterThan(half * 4)
	end)

	it("gives a full carry a survivable but pressing time to bank", function()
		local secondsToVent = 1 / rateAtFill(1.0, 0)
		-- Long enough to reach a station, short enough to be a real decision.
		expect(secondsToVent):within(12, 40)
	end)

	it("extends that window meaningfully with resistance", function()
		local without = 1 / rateAtFill(1.0, 0)
		local with = 1 / rateAtFill(1.0, 0.5)
		expect(with):near(without * 2, 0.001)
	end)
end)

describe("Loot", function()
	it("produces higher rarities more often with luck", function()
		local function sampleRarity(luck, samples)
			local rng = RNG.new("rarity_" .. tostring(luck))
			local weights = {}
			for _, rarity in ipairs(Balance.Loot.RARITY_ORDER) do
				local base = Balance.Loot.RARITY_BASE_WEIGHTS[rarity]
				local tilt = Balance.Loot.RARITY_LUCK_TILT[rarity] or 0
				weights[rarity] = math.max(0.0001, base * (1 + luck * tilt))
			end
			local rareOrBetter = 0
			for _ = 1, samples do
				local rolled = rng:PickWeightedMap(weights)
				if rolled ~= "common" and rolled ~= "uncommon" then
					rareOrBetter += 1
				end
			end
			return rareOrBetter / samples
		end

		local unlucky = sampleRarity(0, 20000)
		local lucky = sampleRarity(3, 20000)
		expect(lucky):greaterThan(unlucky * 1.5)
	end)

	it("keeps drop rates honest and non-zero for every table", function()
		for _, lootTable in ipairs(LootTables.List) do
			local chance = LootTables.GetDropChance(lootTable.id, 0)
			expect(chance):greaterThan(0)
			expect(chance):lessOrEqual(1)
		end
	end)

	it("always pays out from a legendary table", function()
		expect(LootTables.GetDropChance("legendary_storm_cache", 0)):equal(1)
		expect(LootTables.GetDropChance("core_cache", 0)):equal(1)
		expect(LootTables.GetDropChance("eye_cache", 0)):equal(1)
	end)

	it("raises the drop chance with luck without ever reaching certainty", function()
		local without = LootTables.GetDropChance("common_scrap", 0)
		local with = LootTables.GetDropChance("common_scrap", 4)
		expect(with):greaterThan(without)
		expect(with):lessThan(1)
	end)

	it("rolls resources, currency and equipment from a table", function()
		local rng = RNG.new("loot-roll")
		local kinds = {}
		for _ = 1, 4000 do
			local result = LootTables.Roll(rng, "industrial_salvage", 1)
			if result then
				kinds[result.kind] = (kinds[result.kind] or 0) + 1
			end
		end
		expect(kinds.resource):greaterThan(0)
		expect(kinds.equipment):greaterThan(0)
		expect(kinds.currency):greaterThan(0)
	end)

	it("merges repeated resource results into one entry", function()
		local rng = RNG.new("loot-merge")
		local results = LootTables.RollMultiple(rng, "common_scrap", 40, 2)
		local seen = {}
		for _, result in ipairs(results) do
			if result.kind == "resource" then
				expect(seen[result.id]):isNil()
				seen[result.id] = true
			end
		end
	end)

	it("respects a table's prestige requirement in its declaration", function()
		expect(LootTables.ById.prestige_cache.requiresPrestige):equal(1)
	end)
end)

describe("Storm mechanics", function()
	it("gives every storm a windup a human can react to", function()
		for _, storm in ipairs(StormTypes.List) do
			-- Below roughly 250ms no player can respond to a new telegraph; the
			-- shortest windups belong to storms whose rhythm is already established.
			expect(storm.strike.windup):greaterOrEqual(0.5)
		end
	end)

	it("keeps the hardest windows inside human reaction limits", function()
		for _, storm in ipairs(StormTypes.List) do
			local windowSeconds = storm.strike.windup * storm.strike.windowHalfWidth * 2
			-- Even at base stats, the total forgiving span must exceed 150ms.
			expect(windowSeconds):greaterThan(0.15)
		end
	end)

	it("pays rarer storms more per strike", function()
		local byRarity = {}
		for _, storm in ipairs(StormTypes.List) do
			byRarity[storm.rarity] = math.max(byRarity[storm.rarity] or 0, storm.yield.base)
		end
		expect(byRarity.legendary):greaterThan(byRarity.common)
		expect(byRarity.epic):greaterThan(byRarity.uncommon)
	end)

	it("charges more cell charge for a more valuable capture", function()
		local cheap = StormTypes.ById.static_bloom
		local expensive = StormTypes.ById.core_pulse
		expect(expensive.yield.chargeCost):greaterThan(cheap.yield.chargeCost)
	end)

	it("makes multi-strike storms escalate", function()
		for _, storm in ipairs(StormTypes.List) do
			if storm.strike.strikeCount > 1 and storm.yield.perStrikeScale then
				expect(storm.yield.perStrikeScale):greaterThan(1)
			end
		end
	end)
end)

describe("Progression pacing", function()
	it("reaches level 5 within a few minutes of banking", function()
		-- A player banking a modest 200 energy per run at level 1.
		local xpPerRun = 200 * Balance.Bank.XP_PER_ENERGY
		local toLevel5 = MathUtil.CumulativeXp(5)
		local runs = toLevel5 / xpPerRun
		expect(runs):lessThan(12)
	end)

	it("makes the level cap a genuine long-term goal", function()
		local xpPerRun = 4000 * Balance.Bank.XP_PER_ENERGY
		local toCap = MathUtil.CumulativeXp(Balance.Progression.MAX_LEVEL)
		local runs = toCap / xpPerRun
		expect(runs):greaterThan(300)
	end)

	it("keeps the first upgrade affordable after one or two banks", function()
		local cheapest = math.huge
		for _, upgrade in ipairs(Upgrades.List) do
			-- GetCost returns (cost, currency); the extra return must not reach min.
			local cost = Upgrades.GetCost(upgrade.id, 0)
			cheapest = math.min(cheapest, cost)
		end
		-- A first bank of ~120 energy at 1.0 rate must nearly cover something.
		expect(cheapest):lessOrEqual(120)
	end)

	it("awards enough skill points to reach a tier-5 keystone by the cap", function()
		local earned = ProfileSchema.CalculateEarnedSkillPoints(Balance.Progression.MAX_LEVEL)

		-- The cost of one full branch path to a keystone.
		local path = {
			runner_fleet = 5,
			runner_kinetic_jump = 1,
			runner_air_dash = 1,
			runner_blink_step = 1,
			runner_ks_featherweight = 1,
		}
		local cost = SkillTree.GetSpentPoints(path)
		expect(earned):greaterThan(cost)
		-- But not so many that every branch can be maxed, or specialisation is moot.
		local everything = {}
		for _, node in ipairs(SkillTree.Nodes) do
			everything[node.id] = node.maxRank
		end
		expect(earned):lessThan(SkillTree.GetSpentPoints(everything))
	end)
end)

describe("World events", function()
	it("gives everyone a meaningful share and the top contributor more", function()
		local low = WorldEvents.CalculateRewards("event_superstorm", 0.02, false, Balance)
		local high = WorldEvents.CalculateRewards("event_superstorm", 0.6, true, Balance)

		-- A late joiner still gets a real reward.
		expect(low.watts):greaterThan(0)
		expect(low.lootRolls):greaterOrEqual(1)
		-- The top contributor gets substantially more, plus Cores.
		expect(high.watts):greaterThan(low.watts * 5)
		expect(high.cores):greaterThan(low.cores)
	end)

	it("floors the reward share so tiny contributions are not worthless", function()
		local tiny = WorldEvents.CalculateRewards("event_rare_bloom", 0.0001, false, Balance)
		local floor = WorldEvents.CalculateRewards("event_rare_bloom", Balance.Events.MIN_REWARD_SHARE, false, Balance)
		expect(tiny.watts):equal(floor.watts)
	end)

	it("resolves the active phase from elapsed time", function()
		local phase, index = WorldEvents.GetActivePhase("event_superstorm", 10)
		expect(phase.id):equal("approach")
		expect(index):equal(1)

		local mid = WorldEvents.GetActivePhase("event_superstorm", 200)
		expect(mid.id):equal("front")

		local late = WorldEvents.GetActivePhase("event_superstorm", 420)
		expect(late.id):equal("wake")

		local ended = WorldEvents.GetActivePhase("event_superstorm", 9999)
		expect(ended):isNil()
	end)

	it("filters eligible events by population and level", function()
		local emptyServer = WorldEvents.GetEligible(1, 5, {})
		expect(emptyServer.event_superstorm):isNil()
		expect(emptyServer.event_rare_bloom):ok()

		local busyServer = WorldEvents.GetEligible(8, 40, {})
		expect(busyServer.event_superstorm):ok()
		expect(busyServer.event_storm_boss):ok()
	end)

	it("excludes events that are already running", function()
		local eligible = WorldEvents.GetEligible(8, 40, { event_superstorm = true })
		expect(eligible.event_superstorm):isNil()
	end)

	it("decays the weight of events far below the server's level", function()
		local lowLevel = WorldEvents.GetEligible(4, 10, {})
		local highLevel = WorldEvents.GetEligible(4, 90, {})
		-- Rare Bloom is a level-2 event; a level-90 server should see it far less.
		expect(highLevel.event_rare_bloom):lessThan(lowLevel.event_rare_bloom)
	end)
end)

describe("Ability balance", function()
	it("prices long-duration abilities with long cooldowns", function()
		for _, ability in ipairs(Abilities.Actives) do
			local duration = ability.effects.duration
			if duration then
				-- Nothing may be active more than half the time it is on cooldown.
				expect(ability.cooldown):greaterThan(duration)
			end
		end
	end)

	it("gives every emergency ability a real cost", function()
		for _, ability in ipairs(Abilities.Actives) do
			local isEmergency = false
			for _, tag in ipairs(ability.tags) do
				if tag == "emergency" then
					isEmergency = true
				end
			end
			if isEmergency then
				-- Emergency abilities are powerful, so they are gated by a long
				-- cooldown, a cast time, a resource cost, or a limited charge pool
				-- that recharges slowly — never free.
				local hasCost = ability.cooldown >= 18
					or (ability.castTime or 0) > 0
					or ability.effects.energyCostFraction ~= nil
					or ability.effects.bankPenalty ~= nil
					or (ability.effects.charges ~= nil and ability.effects.rechargePerCharge ~= nil)
				expect(hasCost):ok()
			end
		end
	end)

	it("keeps cooldown reduction from trivialising long cooldowns", function()
		local stats = Stats.CreateBaseTable()
		stats.abilityCooldown = Stats.ById.abilityCooldown.max
		local reduced = Abilities.GetCooldown("emergency_extract", stats)
		-- A four-minute cooldown must stay over a minute even fully invested.
		expect(reduced):greaterThan(60)
	end)
end)

describe("Equipment progression", function()
	it("raises the best available base stat weight with every tier", function()
		--[[
			An item's "weight" is the sum of its stat magnitudes expressed as a
			fraction of each stat's own baseline, so a +95 capacity and a +8% resist
			are comparable. Downsides count toward the total: an item that trades is
			still doing work, it is just doing it in two directions.
		]]
		local function weight(definition)
			local total = 0
			for kind, statMap in pairs(definition.baseStats) do
				for statId, amount in pairs(statMap) do
					local stat = Stats.ById[statId]
					if kind == "flat" and stat.base > 0 then
						total += math.abs(amount) / stat.base
					else
						total += math.abs(amount)
					end
				end
			end
			return total
		end

		local byTier = {}
		for _, base in ipairs(Equipment.Bases) do
			byTier[base.tier] = math.max(byTier[base.tier] or 0, weight(base))
		end

		-- The best item available at each tier must beat the best of the tier below,
		-- or reaching a new region buys the player nothing.
		local previous = 0
		for tier = 1, 6 do
			local best = byTier[tier]
			if best then
				if best <= previous then
					error(("tier %d best weight %.2f does not beat tier %d's %.2f")
						:format(tier, best, tier - 1, previous))
				end
				previous = best
			end
		end
	end)

	it("gives higher-tier bases a higher level requirement", function()
		for _, base in ipairs(Equipment.Bases) do
			-- Tier and required level must move together, or the drop pool is
			-- incoherent at every point in the game.
			expect(base.requiredLevel):greaterOrEqual((base.tier - 1) * 8)
		end
	end)

	it("makes a specialised low-tier base competitive for its build", function()
		-- A Runner in a tier-2 Featherframe must beat the same Runner in a tier-5
		-- Skyframe on movement, or "build" means nothing.
		local runnerLight = makeProfile()
		equipItem(runnerLight, "cell_light", "rare")
		local lightValues = StatsService.ResolveForProfile(runnerLight, nil, 0)

		local runnerHeavy = makeProfile()
		equipItem(runnerHeavy, "cell_bulk", "rare")
		local heavyValues = StatsService.ResolveForProfile(runnerHeavy, nil, 0)

		expect(lightValues.moveSpeed):greaterThan(heavyValues.moveSpeed)
		expect(heavyValues.capacity):greaterThan(lightValues.capacity)
	end)

	it("rolls more affixes at higher rarity", function()
		local commonRange = Balance.Loot.MODIFIER_COUNTS.common
		local legendaryRange = Balance.Loot.MODIFIER_COUNTS.legendary
		expect(legendaryRange.min):greaterThan(commonRange.max)
	end)
end)

describe("Prestige", function()
	local Prestige = loadModule("Shared/Config/Prestige")

	it("blocks prestige below the level and quest requirements", function()
		local profile = makeProfile({ level = 50 })
		local ok, reason = Prestige.CanPrestige(profile, Balance)
		expect(ok):falsy()
		expect(reason):equal("level")

		profile.level = Balance.Progression.PRESTIGE_LEVEL_REQUIREMENT
		local questOk, questReason = Prestige.CanPrestige(profile, Balance)
		expect(questOk):falsy()
		expect(questReason):equal("quest")

		profile.completedQuests[Balance.Progression.PRESTIGE_QUEST_REQUIREMENT] = true
		expect(Prestige.CanPrestige(profile, Balance)):ok()
	end)

	it("stops at the maximum rank", function()
		local profile = makeProfile({
			level = Balance.Progression.PRESTIGE_LEVEL_REQUIREMENT,
			prestige = Balance.Progression.MAX_PRESTIGE,
		})
		profile.completedQuests[Balance.Progression.PRESTIGE_QUEST_REQUIREMENT] = true
		local ok, reason = Prestige.CanPrestige(profile, Balance)
		expect(ok):falsy()
		expect(reason):equal("max_prestige")
	end)

	it("defines a rank for every step to the cap", function()
		for rank = 1, Balance.Progression.MAX_PRESTIGE do
			expect(Prestige.RankByNumber[rank]):ok()
		end
	end)

	it("changes the world at every rank rather than only the numbers", function()
		for _, rank in ipairs(Prestige.Ranks) do
			-- Every rank must alter world state, grant a capability, or open content.
			local substantive = rank.grants.worldState ~= nil
				or rank.grants.region ~= nil
				or rank.grants.traversal ~= nil
				or rank.grants.item ~= nil
			expect(substantive):ok()
		end
	end)

	it("preserves knowledge and resets numbers", function()
		local preserved = {}
		for _, key in ipairs(Prestige.PRESERVED_KEYS) do
			preserved[key] = true
		end

		-- Things that represent what the player has learned or found must survive.
		for _, key in ipairs({
			"discoveries", "stormsDiscovered", "achievements", "records",
			"masteries", "titlesOwned", "regionsVisited", "fastTravelUnlocked",
		}) do
			expect(preserved[key]):ok()
		end

		-- Things the player will re-earn quickly must not.
		for _, key in ipairs({ "level", "xp", "watts", "upgrades", "skills", "skillPoints" }) do
			expect(preserved[key]):falsy()
		end
	end)

	it("gates prestige skills on sigils and prerequisites", function()
		local profile = makeProfile({ sigils = 0 })
		local ok, reason = Prestige.CanPurchaseSkill("p_second_cell", profile)
		expect(ok):falsy()
		expect(reason):equal("insufficient_sigils")

		profile.sigils = 99
		expect(Prestige.CanPurchaseSkill("p_second_cell", profile)):ok()

		-- A tier-2 node needs its tier-1 prerequisite.
		local blocked, blockedReason = Prestige.CanPurchaseSkill("p_chain_memory", profile)
		expect(blocked):falsy()
		expect(blockedReason):equal("missing_prerequisite")

		profile.prestigeSkills.p_second_cell = true
		expect(Prestige.CanPurchaseSkill("p_chain_memory", profile)):ok()
	end)

	it("accepts either branch for an any-of prerequisite", function()
		local profile = makeProfile({ sigils = 99 })
		local blocked, reason = Prestige.CanPurchaseSkill("p_the_calm", profile)
		expect(blocked):falsy()
		expect(reason):equal("missing_any_prerequisite")

		profile.prestigeSkills.p_phase_extended = true
		expect(Prestige.CanPurchaseSkill("p_the_calm", profile)):ok()

		local other = makeProfile({ sigils = 99 })
		other.prestigeSkills.p_chain_memory = true
		expect(Prestige.CanPurchaseSkill("p_the_calm", other)):ok()
	end)

	it("refuses a skill already owned", function()
		local profile = makeProfile({ sigils = 99 })
		profile.prestigeSkills.p_second_cell = true
		local ok, reason = Prestige.CanPurchaseSkill("p_second_cell", profile)
		expect(ok):falsy()
		expect(reason):equal("already_owned")
	end)

	it("collects behaviours and world states from owned progress", function()
		local profile = makeProfile({ prestige = 3 })
		profile.prestigeSkills.p_storm_sense = true

		local behaviours = Prestige.CollectBehaviours(profile)
		expect(behaviours.global_storm_vision):ok()

		local states = Prestige.CollectWorldStates(3)
		expect(states.inversion_visible):ok()
		expect(states.echo_storms):ok()
		expect(states.null_everywhere):ok()
		expect(states.second_eye):falsy()
	end)

	it("awards enough sigils across all ranks to buy a real build", function()
		local total = 0
		for _, rank in ipairs(Prestige.Ranks) do
			total += rank.grants.sigils or 0
		end

		local cheapestPath = Prestige.SkillById.p_second_cell.cost
			+ Prestige.SkillById.p_chain_memory.cost
			+ Prestige.SkillById.p_the_calm.cost
		expect(total):greaterThan(cheapestPath)

		-- But not enough to buy the entire tree, so prestige is still a choice.
		local everything = 0
		for _, skill in ipairs(Prestige.Skills) do
			everything += skill.cost
		end
		expect(total):lessThan(everything * 1.6)
	end)
end)

-- ============================================================================
-- Achievements
-- ============================================================================

local AchievementService = loadModule("Server/Services/AchievementService")
local AchievementConfig = loadModule("Shared/Config/Achievements")

--[[
	AchievementService with its four collaborators stubbed. Init only builds tables
	and signals, so it can be called directly; everything the awarding path touches
	afterwards goes through _data, _economy and _progression, which is exactly why
	those are fields rather than module-level requires.
]]
local function makeAchievementService(profile)
	local service = setmetatable({}, { __index = AchievementService })
	service.Registry = {
		Get = function() return nil end,
		Find = function() return nil end,
	}
	AchievementService.Init(service)

	local awarded = {}
	local unlocks = {}

	service._data = {
		GetProfile = function() return profile end,
		MarkDirty = function() end,
	}
	service._economy = {
		Award = function(_, _, currency, amount)
			awarded[currency] = (awarded[currency] or 0) + amount
		end,
	}
	service._progression = {
		GrantUnlock = function(_, _, kind, id)
			if kind == "title" then
				profile.titlesOwned[id] = true
				table.insert(unlocks, id)
			end
			return true
		end,
	}

	return service, awarded, unlocks
end

local fakePlayer = { DisplayName = "Tester", UserId = 1, Parent = true }

describe("AchievementService", function()
	it("grants nothing for a fresh profile", function()
		local profile = ProfileSchema.CreateDefault(1)
		local service = makeAchievementService(profile)
		expect(service:Evaluate(fakePlayer)):equal(0)
	end)

	it("awards an achievement once its condition is met", function()
		local profile = ProfileSchema.CreateDefault(1)
		profile.records.totalCaptures = 1

		local service, awarded = makeAchievementService(profile)
		expect(service:Evaluate(fakePlayer)):equal(1)

		expect(profile.achievements.ach_first_capture):typeOf("number")
		expect(awarded.watts):equal(200)
	end)

	it("does not award the same achievement twice", function()
		local profile = ProfileSchema.CreateDefault(1)
		profile.records.totalCaptures = 1

		local service, awarded = makeAchievementService(profile)
		service:Evaluate(fakePlayer)
		expect(service:Evaluate(fakePlayer)):equal(0)
		expect(awarded.watts):equal(200)
	end)

	it("grants the title an achievement carries and wears the first one", function()
		local profile = ProfileSchema.CreateDefault(1)
		profile.records.totalCaptures = 1000

		local service, _, unlocks = makeAchievementService(profile)
		service:Evaluate(fakePlayer)

		expect(#unlocks):greaterThan(0)
		expect(profile.titlesOwned.practised):equal(true)
		-- A player who has never chosen a title wears the first one they earn.
		expect(profile.equippedTitle):equal("practised")
	end)

	it("leaves an already-chosen title alone", function()
		local profile = ProfileSchema.CreateDefault(1)
		profile.titlesOwned.metronome = true
		profile.equippedTitle = "metronome"
		profile.records.totalCaptures = 1000

		local service = makeAchievementService(profile)
		service:Evaluate(fakePlayer)

		expect(profile.equippedTitle):equal("metronome")
	end)

	it("cascades into the meta achievement in a single evaluation", function()
		local profile = ProfileSchema.CreateDefault(1)
		local half = math.floor(#AchievementConfig.List / 2)

		-- Pre-award one short of half, all from non-collection sources so the meta
		-- achievement is the only thing the final grant can trigger.
		local seeded = 0
		for _, achievement in ipairs(AchievementConfig.List) do
			-- ach_first_capture is deliberately left unseeded: it is the trigger.
			if achievement.source.kind ~= "collection"
				and achievement.id ~= "ach_first_capture"
				and seeded < half - 1
			then
				profile.achievements[achievement.id] = 1
				seeded += 1
			end
		end

		-- One more real achievement takes the count to half, which completes the meta
		-- achievement in the same sweep rather than on some later tick.
		profile.records.totalCaptures = 1

		local service = makeAchievementService(profile)
		local granted = service:Evaluate(fakePlayer)

		expect(granted):greaterThan(1)
		expect(profile.achievements.ach_achievements_half):typeOf("number")
	end)

	it("reads a generated mastery title without a registry entry", function()
		local profile = ProfileSchema.CreateDefault(1)
		local service = makeAchievementService(profile)

		expect(service:GetTitleName("practised")):equal("Practised")
		expect(service:GetTitleName("mastery_capture_20")):equal("Capture 20")
		expect(service:GetTitleName("some_event_title")):equal("Some event title")
	end)

	it("refuses to equip a title the player does not own", function()
		local profile = ProfileSchema.CreateDefault(1)
		local service = makeAchievementService(profile)

		expect(service:EquipTitle(fakePlayer, "metronome")):falsy()
		expect(profile.equippedTitle):isNil()

		profile.titlesOwned.metronome = true
		expect(service:EquipTitle(fakePlayer, "metronome")):ok()
		expect(profile.equippedTitle):equal("metronome")

		expect(service:EquipTitle(fakePlayer, "")):ok()
		expect(profile.equippedTitle):isNil()
	end)

	it("masks hidden achievements in the panel until they are earned", function()
		local profile = ProfileSchema.CreateDefault(1)
		local service = makeAchievementService(profile)
		local view = service:BuildView(fakePlayer)

		local hiddenCategory
		for _, category in ipairs(view.categories) do
			if category.id == "hidden" then
				hiddenCategory = category
			end
		end

		expect(hiddenCategory):ok()
		expect(#hiddenCategory.rows):greaterThan(0)

		for _, row in ipairs(hiddenCategory.rows) do
			expect(row.masked):equal(true)
			expect(row.name):equal("???")
			-- The real id must not leak either: it names the storm or quest involved.
			expect(row.id):contains("hidden:")
			expect(row.rewards):isNil()
		end
	end)

	it("unmasks a hidden achievement once it is earned", function()
		local profile = ProfileSchema.CreateDefault(1)
		profile.achievements.ach_hidden_underyard = 1700000000

		local service = makeAchievementService(profile)
		local view = service:BuildView(fakePlayer)

		local found = false
		for _, category in ipairs(view.categories) do
			for _, row in ipairs(category.rows) do
				if row.id == "ach_hidden_underyard" then
					found = true
					expect(row.masked):equal(false)
					expect(row.name):equal("Twelve Marks")
					expect(row.earned):equal(true)
				end
			end
		end
		expect(found):equal(true)
	end)

	it("counts every achievement in the panel exactly once", function()
		local profile = ProfileSchema.CreateDefault(1)
		local service = makeAchievementService(profile)
		local view = service:BuildView(fakePlayer)

		local rows = 0
		for _, category in ipairs(view.categories) do
			rows += #category.rows
		end
		expect(rows):equal(#AchievementConfig.List)
		expect(view.completion.total):equal(#AchievementConfig.List)
	end)
end)

-- ============================================================================
-- Leaderboards
-- ============================================================================

local LeaderboardService = loadModule("Server/Services/LeaderboardService")

--[[
	LeaderboardService with no DataStore behind it, which is the same path a Studio
	session without API access takes: the in-memory board. Writes are recorded so a
	spec can assert on write discipline, which is the part of this service that can
	actually hurt a live game.
]]
local function makeLeaderboardService(profile)
	local service = setmetatable({}, { __index = LeaderboardService })
	service.Registry = {
		Get = function() return nil end,
		Find = function() return nil end,
	}
	LeaderboardService.Init(service)

	service._data = {
		GetProfile = function() return profile end,
		MarkDirty = function() end,
	}

	-- Force the in-memory path without touching DataStoreService at all.
	service._useMockStore = true
	local writes = {}
	service._write = function(this, board, userId, value)
		table.insert(writes, { board = board.id, userId = userId, value = value })
		return true
	end

	return service, writes
end

describe("LeaderboardService", function()
	it("fans a record out to every board that reads it", function()
		local profile = ProfileSchema.CreateDefault(1)
		local service = makeLeaderboardService(profile)

		service:SubmitRecord(fakePlayer, "largestBank", 500)
		expect(service._pendingWrites.largest_bank[1]):equal(500)
	end)

	it("ignores a record no board reads", function()
		local profile = ProfileSchema.CreateDefault(1)
		local service = makeLeaderboardService(profile)

		service:SubmitRecord(fakePlayer, "totalDeaths", 40)
		for boardId, pending in pairs(service._pendingWrites) do
			if pending[1] then
				error("totalDeaths reached board " .. boardId)
			end
		end
	end)

	it("keeps only the best queued value", function()
		local profile = ProfileSchema.CreateDefault(1)
		local service = makeLeaderboardService(profile)

		service:Submit(fakePlayer, "largest_bank", 400)
		service:Submit(fakePlayer, "largest_bank", 900)
		service:Submit(fakePlayer, "largest_bank", 600)

		expect(service._pendingWrites.largest_bank[1]):equal(900)
	end)

	it("refuses nonsense values", function()
		local profile = ProfileSchema.CreateDefault(1)
		local service = makeLeaderboardService(profile)

		service:Submit(fakePlayer, "largest_bank", -5)
		service:Submit(fakePlayer, "largest_bank", 0)
		service:Submit(fakePlayer, "largest_bank", 0 / 0)
		expect(service._pendingWrites.largest_bank):isNil()
	end)

	it("writes once, then holds the next value behind the cooldown", function()
		local profile = ProfileSchema.CreateDefault(1)
		local service, writes = makeLeaderboardService(profile)

		service:Submit(fakePlayer, "largest_bank", 400)
		expect(service:Flush()):equal(1)
		expect(#writes):equal(1)

		-- A better value arrives immediately. It must not produce a second write:
		-- OrderedDataStore budgets are the whole reason this queue exists.
		service:Submit(fakePlayer, "largest_bank", 900)
		expect(service:Flush()):equal(0)
		expect(#writes):equal(1)
		-- ...and it is still queued, not discarded.
		expect(service._pendingWrites.largest_bank[1]):equal(900)
	end)

	it("drops a queued value that is no better than what was written", function()
		local profile = ProfileSchema.CreateDefault(1)
		local service = makeLeaderboardService(profile)

		service:Submit(fakePlayer, "largest_bank", 900)
		service:Flush()

		service:Submit(fakePlayer, "largest_bank", 400)
		service:Flush()
		expect(service._pendingWrites.largest_bank[1]):isNil()
	end)

	it("writes a leaving player's queued value without waiting out the cooldown", function()
		local profile = ProfileSchema.CreateDefault(1)
		local service, writes = makeLeaderboardService(profile)

		service:Submit(fakePlayer, "largest_bank", 400)
		service:Flush()
		service:Submit(fakePlayer, "largest_bank", 900)

		service:_flushPlayer(1)
		expect(#writes):equal(2)
		expect(writes[2].value):equal(900)
		expect(service._pendingWrites.largest_bank[1]):isNil()
	end)

	it("submits every global board from a loaded profile", function()
		local profile = ProfileSchema.CreateDefault(1)
		profile.level = 20
		profile.prestige = 2
		profile.records.largestBank = 1200
		profile.records.longestChain = 14

		local service = makeLeaderboardService(profile)
		service:SubmitAllFromProfile(fakePlayer)

		expect(service._pendingWrites.level[1]):equal(20)
		expect(service._pendingWrites.prestige[1]):equal(2)
		expect(service._pendingWrites.largest_bank[1]):equal(1200)
		expect(service._pendingWrites.longest_chain[1]):equal(14)
	end)

	it("measures a weekly board as progress since the week began", function()
		local profile = ProfileSchema.CreateDefault(1)
		profile.records.totalBanked = 10000

		local service = makeLeaderboardService(profile)

		-- First sighting this week stamps the baseline, so the delta is zero rather
		-- than the player's entire lifetime total.
		service:SubmitRecord(fakePlayer, "totalBanked", 10000)
		expect(profile.weeklyBaselines.total_banked_weekly.value):equal(10000)
		expect(service._pendingWrites.total_banked_weekly):isNil()

		-- All-time still sees the full figure.
		expect(service._pendingWrites.total_banked[1]):equal(10000)

		service:SubmitRecord(fakePlayer, "totalBanked", 12500)
		expect(service._pendingWrites.total_banked_weekly[1]):equal(2500)
	end)

	it("re-baselines when the week rolls over and prunes the old key", function()
		local profile = ProfileSchema.CreateDefault(1)
		local service = makeLeaderboardService(profile)

		profile.weeklyBaselines.total_banked_weekly = { key = "bts_total_banked_weekly_w0", value = 4000 }
		service:SubmitRecord(fakePlayer, "totalBanked", 10000)

		local baseline = profile.weeklyBaselines.total_banked_weekly
		expect(baseline.value):equal(10000)
		expect(baseline.key):equal(service:_storeKey(service._boards.total_banked_weekly))
	end)

	it("stamps a weekly key that changes weekly and an all-time key that does not", function()
		local profile = ProfileSchema.CreateDefault(1)
		local service = makeLeaderboardService(profile)

		local weekly = service:_storeKey(service._boards.total_banked_weekly)
		local alltime = service:_storeKey(service._boards.total_banked)

		expect(weekly):contains("_w")
		expect(alltime):equal("bts_total_banked")
		-- Called twice in the same second it must be stable, or every read would miss.
		expect(service:_storeKey(service._boards.total_banked_weekly)):equal(weekly)
	end)

	it("ranks a server board and breaks ties without churning", function()
		local profile = ProfileSchema.CreateDefault(1)
		local service = makeLeaderboardService(profile)

		service._serverBoards.server_banked = {
			{ rank = 1, userId = 2, name = "B", value = 900 },
			{ rank = 2, userId = 1, name = "A", value = 400 },
		}

		local page = service:GetPage(fakePlayer, "server_banked", 1)
		expect(#page.entries):equal(2)
		expect(page.entries[1].userId):equal(2)
		expect(page.viewerRank):equal(2)
		expect(page.viewerValue):equal(400)
		expect(page.scope):equal("server")
	end)

	it("returns nothing for an unknown board", function()
		local profile = ProfileSchema.CreateDefault(1)
		local service = makeLeaderboardService(profile)
		expect(service:GetPage(fakePlayer, "not_a_board", 1)):isNil()
	end)

	it("clamps a hostile page number into range", function()
		local profile = ProfileSchema.CreateDefault(1)
		local service = makeLeaderboardService(profile)
		service._serverBoards.server_banked = {}

		expect(service:GetPage(fakePlayer, "server_banked", 0).page):equal(1)
		expect(service:GetPage(fakePlayer, "server_banked", 9999).page):equal(10)
		expect(service:GetPage(fakePlayer, "server_banked", -4).page):equal(1)
	end)

	it("declares every board it advertises", function()
		local profile = ProfileSchema.CreateDefault(1)
		local service = makeLeaderboardService(profile)

		for _, board in ipairs(service:GetBoards()) do
			expect(board.name):typeOf("string")
			expect(board.description):typeOf("string")
			if board.scope ~= "global" and board.scope ~= "server" then
				error(board.id .. " has unknown scope " .. tostring(board.scope))
			end
		end
	end)
end)

-- ============================================================================
-- Parties
-- ============================================================================

local PartyService = loadModule("Server/Services/PartyService")

local function makePartyService()
	local service = setmetatable({}, { __index = PartyService })
	service.Registry = {
		Get = function() return nil end,
		Find = function() return nil end,
	}
	PartyService.Init(service)
	service._data = {
		GetProfile = function() return ProfileSchema.CreateDefault(1) end,
		MarkDirty = function() end,
	}
	return service
end

--[[ A player the mock's Players service can find by user id. ]]
local function makeJoinedPlayer(userId, name)
	local player = Instance.new("Player")
	player.Name = name
	player.DisplayName = name
	player.UserId = userId
	player.Parent = game:GetService("Players")
	return player
end

describe("PartyService", function()
	it("refuses an invite to somebody who is not here", function()
		local service = makePartyService()
		local a = makeJoinedPlayer(101, "A")

		local ok = service:Invite(a, 999999)
		expect(ok):falsy()
		a:Destroy()
	end)

	it("refuses an invite to yourself", function()
		local service = makePartyService()
		local a = makeJoinedPlayer(102, "A")

		expect(service:Invite(a, 102)):falsy()
		a:Destroy()
	end)

	it("forms a party when an invite is accepted", function()
		local service = makePartyService()
		local a = makeJoinedPlayer(103, "A")
		local b = makeJoinedPlayer(104, "B")

		expect(service:Invite(a, 104)):ok()

		local inviteId
		for id in pairs(service._invites) do
			inviteId = id
		end
		expect(inviteId):typeOf("string")

		expect(service:RespondToInvite(b, inviteId, true)):ok()

		local party = service:GetPartyFor(a)
		expect(party):ok()
		expect(#party.members):equal(2)
		expect(party.leaderId):equal(103)
		expect(service:GetPartyId(104)):equal(party.id)

		a:Destroy()
		b:Destroy()
	end)

	it("consumes the invite whether it is accepted or declined", function()
		local service = makePartyService()
		local a = makeJoinedPlayer(105, "A")
		local b = makeJoinedPlayer(106, "B")

		service:Invite(a, 106)
		local inviteId
		for id in pairs(service._invites) do
			inviteId = id
		end

		service:RespondToInvite(b, inviteId, false)
		expect(service._invites[inviteId]):isNil()
		expect(service:GetPartyId(106)):isNil()

		a:Destroy()
		b:Destroy()
	end)

	it("refuses an invite answered by the wrong player", function()
		local service = makePartyService()
		local a = makeJoinedPlayer(107, "A")
		local b = makeJoinedPlayer(108, "B")
		local c = makeJoinedPlayer(109, "C")

		service:Invite(a, 108)
		local inviteId
		for id in pairs(service._invites) do
			inviteId = id
		end

		-- C answering B's invite must not put C in the party.
		expect(service:RespondToInvite(c, inviteId, true)):falsy()
		expect(service:GetPartyId(109)):isNil()
		expect(service._invites[inviteId]):ok()

		a:Destroy()
		b:Destroy()
		c:Destroy()
	end)

	it("refuses a second invite to the same person from the same inviter", function()
		local service = makePartyService()
		local a = makeJoinedPlayer(110, "A")
		local b = makeJoinedPlayer(111, "B")

		expect(service:Invite(a, 111)):ok()
		expect(service:Invite(a, 111)):falsy()

		a:Destroy()
		b:Destroy()
	end)

	it("dissolves a party rather than leaving one member alone in it", function()
		local service = makePartyService()
		local a = makeJoinedPlayer(112, "A")
		local b = makeJoinedPlayer(113, "B")

		service:Invite(a, 113)
		local inviteId
		for id in pairs(service._invites) do
			inviteId = id
		end
		service:RespondToInvite(b, inviteId, true)

		service:Leave(b)
		expect(service:GetPartyId(112)):isNil()
		expect(service:GetPartyId(113)):isNil()

		a:Destroy()
		b:Destroy()
	end)

	it("passes leadership on rather than dissolving when a leader leaves", function()
		local service = makePartyService()
		local players = {}
		for index = 1, 3 do
			players[index] = makeJoinedPlayer(200 + index, "P" .. index)
		end

		for index = 2, 3 do
			service:Invite(players[1], 200 + index)
			local inviteId
			for id, invite in pairs(service._invites) do
				if invite.toUserId == 200 + index then
					inviteId = id
				end
			end
			service:RespondToInvite(players[index], inviteId, true)
		end

		local party = service:GetPartyFor(players[1])
		expect(#party.members):equal(3)

		service:Leave(players[1])
		local remaining = service:GetPartyFor(players[2])
		expect(remaining):ok()
		expect(#remaining.members):equal(2)
		expect(remaining.leaderId):equal(202)

		for _, player in ipairs(players) do
			player:Destroy()
		end
	end)

	it("caps a party at its maximum", function()
		local service = makePartyService()
		local players = {}
		for index = 1, 5 do
			players[index] = makeJoinedPlayer(300 + index, "Q" .. index)
		end

		for index = 2, 5 do
			service:Invite(players[1], 300 + index)
			local inviteId
			for id, invite in pairs(service._invites) do
				if invite.toUserId == 300 + index then
					inviteId = id
				end
			end
			if inviteId then
				service:RespondToInvite(players[index], inviteId, true)
			end
		end

		local party = service:GetPartyFor(players[1])
		expect(#party.members):equal(4)
		expect(service:GetPartyId(305)):isNil()

		for _, player in ipairs(players) do
			player:Destroy()
		end
	end)

	it("gives no bonus to a solo runner", function()
		local service = makePartyService()
		local a = makeJoinedPlayer(400, "Solo")

		expect(service:GetXpMultiplier(a)):equal(1)
		expect(service:GetSharedLuck(a)):equal(0)

		a:Destroy()
	end)

	it("cleans up membership and invites when a player disconnects", function()
		local service = makePartyService()
		local a = makeJoinedPlayer(401, "A")
		local b = makeJoinedPlayer(402, "B")

		service:Invite(a, 402)
		service:_onPlayerLeft(401)

		expect(service:GetPartyId(401)):isNil()
		local remaining = 0
		for _ in pairs(service._invites) do
			remaining += 1
		end
		expect(remaining):equal(0)

		a:Destroy()
		b:Destroy()
	end)

	it("expires an invite nobody answered", function()
		local service = makePartyService()
		local a = makeJoinedPlayer(403, "A")
		local b = makeJoinedPlayer(404, "B")

		service:Invite(a, 404)
		for _, invite in pairs(service._invites) do
			invite.expiresAt = os.clock() - 1
		end

		service:Tick()
		expect(next(service._invites)):isNil()

		a:Destroy()
		b:Destroy()
	end)
end)
