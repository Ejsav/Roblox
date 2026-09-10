--!nolint
--[[ Specs for the infrastructure layer: validation, rate limiting, service
     lifecycle, config integrity and the save schema. ]]

local loadModule = loadModule

local Validate = loadModule("Shared/Core/Validate")
local RateLimiter = loadModule("Shared/Core/RateLimiter")
local ServiceRegistry = loadModule("Shared/Core/ServiceRegistry")
local Config = loadModule("Shared/Config")
local ProfileSchema = loadModule("Shared/Data/ProfileSchema")
local Remotes = loadModule("Shared/Net/Remotes")
local Balance = loadModule("Shared/Config/Balance")
local SkillTree = loadModule("Shared/Config/SkillTree")

describe("Core/Validate", function()
	it("accepts and rejects strings by length", function()
		local check = Validate.String(2, 5)
		expect(check("abc")):ok()
		expect(check("a")):falsy()
		expect(check("abcdef")):falsy()
		expect(check(42)):falsy()
	end)

	it("rejects NaN and infinity as numbers", function()
		local check = Validate.Number(0, 100)
		expect(check(50)):ok()
		expect(check(0 / 0)):falsy()
		expect(check(math.huge)):falsy()
		expect(check(-math.huge)):falsy()
		expect(check(-1)):falsy()
	end)

	it("enforces integers", function()
		local check = Validate.Integer(1, 10)
		expect(check(5)):ok()
		expect(check(5.5)):falsy()
	end)

	it("restricts strings to an allow-list", function()
		local fromArray = Validate.Enum({ "low", "high" })
		expect(fromArray("low")):ok()
		expect(fromArray("ultra")):falsy()

		local fromMap = Validate.Enum({ alpha = 1, beta = 2 })
		expect(fromMap("alpha")):ok()
		expect(fromMap("gamma")):falsy()
	end)

	it("rejects out-of-bounds and NaN vectors", function()
		local check = Validate.Vector3(1000)
		expect(check(Vector3.new(10, 20, 30))):ok()
		expect(check(Vector3.new(99999, 0, 0))):falsy()
		expect(check(Vector3.new(0 / 0, 0, 0))):falsy()
		expect(check("not a vector")):falsy()
	end)

	it("bounds array length and validates elements", function()
		local check = Validate.Array(Validate.String(1, 8), 3)
		expect(check({ "a", "b" })):ok()
		expect(check({ "a", "b", "c", "d" })):falsy()
		expect(check({ "a", 5 })):falsy()
		expect(check({ named = "x" })):falsy()
	end)

	it("rejects unexpected keys in a shape", function()
		local check = Validate.Shape({ a = Validate.Number(), b = Validate.String() })
		expect(check({ a = 1, b = "x" })):ok()
		expect(check({ a = 1, b = "x", sneaky = true })):falsy()
		expect(check({ a = 1 })):falsy()
	end)

	it("honours optional keys in a shape", function()
		local check = Validate.Shape({ a = Validate.Number(), b = Validate.String() }, { b = true })
		expect(check({ a = 1 })):ok()
	end)

	it("validates argument lists positionally", function()
		local checkers = { Validate.String(1, 10), Validate.Integer(0, 5) }
		local ok = Validate.Arguments(checkers, { "abc", 3 }, 2)
		expect(ok):ok()

		local badOk, index = Validate.Arguments(checkers, { "abc", 99 }, 2)
		expect(badOk):falsy()
		expect(index):equal(2)

		local tooMany = Validate.Arguments(checkers, { "a", 1, "extra" }, 3)
		expect(tooMany):falsy()
	end)

	it("strips control characters from display text", function()
		local cleaned = Validate.SanitiseText("hel\nlo\tworld", 100)
		expect(cleaned):equal("helloworld")
		expect(#Validate.SanitiseText(string.rep("x", 500), 20)):equal(20)
	end)
end)

describe("Core/RateLimiter", function()
	it("allows a burst up to the budget then denies", function()
		local limiter = RateLimiter.new()
		local budget = { budget = 3, refill = 1 }
		expect(limiter:Consume(1, "test", budget, 0)):ok()
		expect(limiter:Consume(1, "test", budget, 0)):ok()
		expect(limiter:Consume(1, "test", budget, 0)):ok()
		expect(limiter:Consume(1, "test", budget, 0)):falsy()
	end)

	it("refills over time", function()
		local limiter = RateLimiter.new()
		local budget = { budget = 2, refill = 1 }
		limiter:Consume(1, "test", budget, 0)
		limiter:Consume(1, "test", budget, 0)
		expect(limiter:Consume(1, "test", budget, 0)):falsy()
		expect(limiter:Consume(1, "test", budget, 1.1)):ok()
	end)

	it("never refills above the budget ceiling", function()
		local limiter = RateLimiter.new()
		local budget = { budget = 2, refill = 10 }
		limiter:Consume(1, "test", budget, 0)
		-- A long idle period must not bank unlimited tokens.
		limiter:Consume(1, "test", budget, 1000)
		expect(limiter:Consume(1, "test", budget, 1000)):ok()
		expect(limiter:Consume(1, "test", budget, 1000)):falsy()
	end)

	it("consumes nothing on a denied call", function()
		local limiter = RateLimiter.new()
		local budget = { budget = 1, refill = 1 }
		limiter:Consume(1, "test", budget, 0)
		for _ = 1, 50 do
			limiter:Consume(1, "test", budget, 0)
		end
		-- After one second exactly one token should be back, not minus fifty.
		expect(limiter:Consume(1, "test", budget, 1.0)):ok()
	end)

	it("isolates players and remotes from each other", function()
		local limiter = RateLimiter.new()
		local budget = { budget = 1, refill = 1 }
		expect(limiter:Consume(1, "a", budget, 0)):ok()
		expect(limiter:Consume(1, "a", budget, 0)):falsy()
		expect(limiter:Consume(1, "b", budget, 0)):ok()
		expect(limiter:Consume(2, "a", budget, 0)):ok()
	end)

	it("clears a player's buckets", function()
		local limiter = RateLimiter.new()
		local budget = { budget = 1, refill = 1 }
		limiter:Consume(1, "test", budget, 0)
		limiter:Clear(1)
		expect(limiter:Consume(1, "test", budget, 0)):ok()
	end)

	it("sweeps idle full buckets", function()
		local limiter = RateLimiter.new()
		local budget = { budget = 2, refill = 1 }
		limiter:Consume(1, "test", budget, 0)
		limiter:Consume(1, "test", budget, 500)
		expect(limiter:GetBucketCount()):equal(1)
		limiter:Sweep(1000, 120)
		expect(limiter:GetBucketCount()):equal(0)
	end)
end)

describe("Core/ServiceRegistry", function()
	it("boots services in dependency order", function()
		local registry = ServiceRegistry.new("test")
		local order = {}
		registry:Register({
			Name = "C",
			Dependencies = { "B" },
			Init = function()
				table.insert(order, "C")
			end,
		})
		registry:Register({
			Name = "A",
			Init = function()
				table.insert(order, "A")
			end,
		})
		registry:Register({
			Name = "B",
			Dependencies = { "A" },
			Init = function()
				table.insert(order, "B")
			end,
		})
		registry:Boot()
		expect(order[1]):equal("A")
		expect(order[2]):equal("B")
		expect(order[3]):equal("C")
	end)

	it("runs every Init before any Start", function()
		local registry = ServiceRegistry.new("test-stages")
		local log = {}
		for _, name in ipairs({ "A", "B" }) do
			registry:Register({
				Name = name,
				Init = function()
					table.insert(log, name .. ":init")
				end,
				Start = function()
					table.insert(log, name .. ":start")
				end,
			})
		end
		registry:Boot()
		expect(log[1]):contains("init")
		expect(log[2]):contains("init")
		expect(log[3]):contains("start")
		expect(log[4]):contains("start")
	end)

	it("detects dependency cycles", function()
		local registry = ServiceRegistry.new("cyclic")
		registry:Register({ Name = "A", Dependencies = { "B" } })
		registry:Register({ Name = "B", Dependencies = { "A" } })
		expect(function()
			registry:ResolveOrder()
		end):throws("cycle")
	end)

	it("errors on a missing dependency", function()
		local registry = ServiceRegistry.new("missing")
		registry:Register({ Name = "A", Dependencies = { "Nope" } })
		expect(function()
			registry:ResolveOrder()
		end):throws("not registered")
	end)

	it("isolates a failing service and records it", function()
		local registry = ServiceRegistry.new("failing")
		local healthyStarted = false
		registry:Register({
			Name = "Broken",
			Init = function()
				error("intentional failure")
			end,
		})
		registry:Register({
			Name = "Healthy",
			Start = function()
				healthyStarted = true
			end,
		})
		harness.Mock.captureWarnings = true
		local report = registry:Boot()
		harness.Mock.captureWarnings = false

		expect(healthyStarted):ok()
		expect(#report.failures):equal(1)
		expect(report.failures[1]):contains("Broken")
	end)

	it("respects explicit priority for unrelated services", function()
		local registry = ServiceRegistry.new("priority")
		local order = {}
		registry:Register({
			Name = "Late",
			Priority = 900,
			Init = function()
				table.insert(order, "Late")
			end,
		})
		registry:Register({
			Name = "Early",
			Priority = 1,
			Init = function()
				table.insert(order, "Early")
			end,
		})
		registry:Boot()
		expect(order[1]):equal("Early")
	end)

	it("rejects duplicate registration", function()
		local registry = ServiceRegistry.new("dupes")
		registry:Register({ Name = "A" })
		expect(function()
			registry:Register({ Name = "A" })
		end):throws("duplicate")
	end)

	it("throws a useful error for an unknown Get", function()
		local registry = ServiceRegistry.new("lookup")
		expect(function()
			registry:Get("Nope")
		end):throws("unknown service")
	end)

	it("formats a readable boot report", function()
		local registry = ServiceRegistry.new("report")
		registry:Register({ Name = "A", Init = function() end })
		local report = registry:Boot()
		local text = registry:FormatReport(report)
		expect(text):contains("report boot")
		expect(text):contains("all services healthy")
	end)

	it("stops services in reverse order", function()
		local registry = ServiceRegistry.new("shutdown")
		local order = {}
		registry:Register({
			Name = "A",
			Stop = function()
				table.insert(order, "A")
			end,
		})
		registry:Register({
			Name = "B",
			Dependencies = { "A" },
			Stop = function()
				table.insert(order, "B")
			end,
		})
		registry:Boot()
		registry:Shutdown()
		expect(order[1]):equal("B")
		expect(order[2]):equal("A")
	end)
end)

describe("Net/Remotes", function()
	it("declares a direction for every remote", function()
		for name, definition in pairs(Remotes.Definitions) do
			expect(definition.direction):ok()
			local valid = definition.direction == "C2S"
				or definition.direction == "S2C"
				or definition.direction == "C2SF"
			if not valid then
				error(name .. " has invalid direction " .. tostring(definition.direction))
			end
			expect(definition.description):typeOf("string")
		end
	end)

	it("gives every client-sendable remote a rate limit and a schema", function()
		for name, definition in pairs(Remotes.Definitions) do
			if Remotes.IsClientSendable(name) then
				if not definition.rateLimit then
					error(name .. " is client-sendable but declares no rate limit")
				end
				expect(definition.rateLimit.budget):greaterThan(0)
				expect(definition.rateLimit.refill):greaterThan(0)
				if not definition.args then
					error(name .. " is client-sendable but declares no argument schema")
				end
			end
		end
	end)

	it("declares no rate limit or schema on server-to-client remotes", function()
		for name, definition in pairs(Remotes.Definitions) do
			if definition.direction == "S2C" then
				expect(definition.args):isNil()
			end
		end
	end)

	it("refuses client sends on server-only remotes", function()
		expect(Remotes.IsClientSendable("CaptureResult")):falsy()
		expect(Remotes.IsClientSendable("AttemptCapture")):ok()
	end)

	it("returns names in a stable sorted order", function()
		local first = Remotes.GetNames()
		local second = Remotes.GetNames()
		expect(#first):equal(#second)
		for index, name in ipairs(first) do
			expect(second[index]):equal(name)
		end
	end)
end)

describe("Config integrity check", function()
	it("passes its own runtime verification", function()
		local ok, problems = Config.Verify()
		if not ok then
			error("config verification failed:\n  " .. table.concat(problems, "\n  "))
		end
		expect(ok):ok()
	end)

	it("exposes every content table", function()
		for _, key in ipairs({
			"Balance", "Regions", "StormTypes", "Stats", "Upgrades", "SkillTree",
			"Abilities", "Traversal", "Resources", "Equipment", "Modifiers",
			"Quests", "LootTables", "WorldEvents",
		}) do
			expect(Config[key]):ok()
		end
	end)
end)

describe("Data/ProfileSchema", function()
	it("creates a default profile at the current version", function()
		local profile = ProfileSchema.CreateDefault()
		expect(profile.version):equal(ProfileSchema.VERSION)
		expect(profile.level):equal(1)
		expect(profile.watts):equal(0)
		expect(profile.traversal.sprint):ok()
	end)

	it("treats a nil save as a brand new player", function()
		local profile, report = ProfileSchema.Prepare(nil)
		expect(report.wasNew):ok()
		expect(profile.level):equal(1)
	end)

	it("adds new fields to an old save without touching existing values", function()
		local old = { version = ProfileSchema.VERSION, level = 42, watts = 5000 }
		local profile, report = ProfileSchema.Prepare(old)
		expect(profile.level):equal(42)
		expect(profile.watts):equal(5000)
		expect(profile.cores):equal(0)
		expect(report.fieldsAdded):greaterThan(10)
	end)

	it("migrates money to watts (v1 -> v2)", function()
		local old = { version = 1, money = 1234 }
		local profile = ProfileSchema.Prepare(old)
		expect(profile.watts):equal(1234)
		expect(profile.money):isNil()
		expect(profile.version):equal(ProfileSchema.VERSION)
	end)

	it("migrates the upgrade array to a map (v2 -> v3)", function()
		local old = {
			version = 2,
			upgrades = { { id = "capture_coil", level = 7 }, { id = "scanner", level = 3 } },
		}
		local profile = ProfileSchema.Prepare(old)
		expect(profile.upgrades.capture_coil):equal(7)
		expect(profile.upgrades.scanner):equal(3)
	end)

	it("migrates equipped items into the inventory (v3 -> v4)", function()
		local old = {
			version = 3,
			equipment = {
				capture_device = { b = "dev_field_tap", r = "common", m = {} },
			},
		}
		local profile = ProfileSchema.Prepare(old)
		expect(#profile.inventory):equal(1)
		expect(profile.equipped.capture_device):equal(profile.inventory[1].u)
		expect(profile.equipment):isNil()
	end)

	it("migrates traversal unlocks out of upgrade levels (v6 -> v7)", function()
		local old = { version = 6, upgrades = { actuators = 22 } }
		local profile = ProfileSchema.Prepare(old)
		expect(profile.traversal.slide):ok()
		expect(profile.traversal.vault):ok()
		expect(profile.traversal.mantle):ok()
		expect(profile.traversal.sprint):ok()
	end)

	it("applies every migration for a very old save", function()
		local old = { version = 1, money = 500 }
		local _, report = ProfileSchema.Prepare(old)
		expect(report.fromVersion):equal(1)
		expect(report.migrationSteps):greaterThan(3)
	end)

	it("is idempotent when run twice", function()
		local old = { version = 1, money = 900, upgrades = { { id = "scanner", level = 2 } } }
		local once = ProfileSchema.Prepare(old)
		local watts = once.watts
		local twice = ProfileSchema.Prepare(once)
		expect(twice.watts):equal(watts)
		expect(twice.upgrades.scanner):equal(2)
	end)

	it("clamps hostile currency values", function()
		local profile = ProfileSchema.CreateDefault()
		profile.watts = 1e30
		profile.cores = -500
		local repairs = ProfileSchema.Validate(profile)
		expect(profile.watts):equal(Balance.Currency.WATTS.cap)
		expect(profile.cores):equal(0)
		expect(#repairs):greaterOrEqual(2)
	end)

	it("clamps NaN values rather than propagating them", function()
		local profile = ProfileSchema.CreateDefault()
		profile.watts = 0 / 0
		ProfileSchema.Validate(profile)
		expect(profile.watts):equal(0)
	end)

	it("removes unknown and over-ranked upgrades", function()
		local profile = ProfileSchema.CreateDefault()
		profile.upgrades.not_a_real_upgrade = 5
		profile.upgrades.capture_coil = 9999
		ProfileSchema.Validate(profile)
		expect(profile.upgrades.not_a_real_upgrade):isNil()
		expect(profile.upgrades.capture_coil):equal(40)
	end)

	it("strips skills whose prerequisites are not met", function()
		local profile = ProfileSchema.CreateDefault()
		-- Kinetic Jump requires Fleet rank 3, which this save does not have.
		profile.skills.runner_kinetic_jump = 1
		ProfileSchema.Validate(profile)
		expect(profile.skills.runner_kinetic_jump):isNil()
	end)

	it("keeps legitimately earned skill chains intact", function()
		local profile = ProfileSchema.CreateDefault()
		profile.level = 40
		profile.skills.runner_fleet = 3
		profile.skills.runner_kinetic_jump = 1
		profile.skills.runner_air_dash = 1
		ProfileSchema.Validate(profile)
		expect(profile.skills.runner_fleet):equal(3)
		expect(profile.skills.runner_air_dash):equal(1)
	end)

	it("cascades removal when a prerequisite is stripped", function()
		local profile = ProfileSchema.CreateDefault()
		profile.level = 60
		-- air_dash depends on kinetic_jump which depends on fleet 3; fleet is absent.
		profile.skills.runner_kinetic_jump = 1
		profile.skills.runner_air_dash = 1
		profile.skills.runner_blink_step = 1
		ProfileSchema.Validate(profile)
		expect(profile.skills.runner_kinetic_jump):isNil()
		expect(profile.skills.runner_air_dash):isNil()
		expect(profile.skills.runner_blink_step):isNil()
	end)

	it("recomputes available skill points from level and spend", function()
		local profile = ProfileSchema.CreateDefault()
		profile.level = 10
		profile.skills.runner_fleet = 2
		profile.skillPoints = 9999
		ProfileSchema.Validate(profile)

		local earned = ProfileSchema.CalculateEarnedSkillPoints(10)
		local spent = SkillTree.GetSpentPoints({ runner_fleet = 2 })
		expect(profile.skillPoints):equal(earned - spent)
	end)

	it("awards a bonus skill point every fifth level", function()
		expect(ProfileSchema.CalculateEarnedSkillPoints(1)):equal(0)
		expect(ProfileSchema.CalculateEarnedSkillPoints(2)):equal(1)
		-- Levels 2..5 give four points, plus one bonus at level 5.
		expect(ProfileSchema.CalculateEarnedSkillPoints(5)):equal(5)
		expect(ProfileSchema.CalculateEarnedSkillPoints(10)):equal(11)
	end)

	it("drops malformed and duplicate inventory entries", function()
		local profile = ProfileSchema.CreateDefault()
		profile.inventory = {
			ProfileSchema.CreateItem("a1", "dev_field_tap", "common", {}),
			ProfileSchema.CreateItem("a1", "dev_field_tap", "common", {}),
			ProfileSchema.CreateItem("a2", "not_a_real_base", "common", {}),
			{ nonsense = true },
		}
		ProfileSchema.Validate(profile)
		expect(#profile.inventory):equal(1)
		expect(profile.inventory[1].u):equal("a1")
	end)

	it("clears equipped slots pointing at missing items", function()
		local profile = ProfileSchema.CreateDefault()
		profile.equipped.capture_device = "ghost"
		profile.equipped.not_a_slot = "x"
		ProfileSchema.Validate(profile)
		expect(profile.equipped.capture_device):isNil()
		expect(profile.equipped.not_a_slot):isNil()
	end)

	it("enforces the inventory cap while protecting favourites", function()
		local profile = ProfileSchema.CreateDefault()
		local cap = Balance.Loot.MAX_INVENTORY_SLOTS
		for index = 1, cap + 20 do
			local item = ProfileSchema.CreateItem("u" .. index, "dev_field_tap", "common", {})
			item.a = index
			item.f = (index == 1)
			table.insert(profile.inventory, item)
		end
		ProfileSchema.Validate(profile)
		expect(#profile.inventory):equal(cap)

		local keptFavourite = false
		for _, item in ipairs(profile.inventory) do
			if item.u == "u1" then
				keptFavourite = true
			end
		end
		expect(keptFavourite):ok()
	end)

	it("cleans a loadout of unowned, duplicate and overflow entries", function()
		local profile = ProfileSchema.CreateDefault()
		profile.abilitiesOwned = { surge = true, purge = true }
		profile.loadout = { "surge", "surge", "overclock", "purge", "surge", "purge" }
		ProfileSchema.Validate(profile)
		expect(#profile.loadout):equal(2)
		expect(profile.loadout[1]):equal("surge")
		expect(profile.loadout[2]):equal("purge")
	end)

	it("removes zero-quantity resources", function()
		local profile = ProfileSchema.CreateDefault()
		profile.resources.scrap_conductor = 0
		profile.resources.copper_winding = -5
		profile.resources.storm_glass = 12.7
		ProfileSchema.Validate(profile)
		expect(profile.resources.scrap_conductor):isNil()
		expect(profile.resources.copper_winding):isNil()
		expect(profile.resources.storm_glass):equal(12)
	end)

	it("withholds moderation flags and receipts from the client view", function()
		local profile = ProfileSchema.CreateDefault()
		profile.flags.suspicionTotal = 55
		profile.purchases.consumed = { ["12345"] = 1 }
		local view = ProfileSchema.ToClientView(profile)
		expect(view.flags):isNil()
		expect(view.purchases.consumed):isNil()
		-- The original must be untouched.
		expect(profile.flags.suspicionTotal):equal(55)
	end)

	it("survives a completely corrupt save without throwing", function()
		local corrupt = {
			version = "not a number",
			level = {},
			watts = "lots",
			upgrades = "nope",
			skills = 42,
			inventory = "gone",
			equipped = 7,
			loadout = "bad",
		}
		local profile = ProfileSchema.Prepare(corrupt)
		expect(profile.level):equal(1)
		expect(profile.watts):equal(0)
		expect(type(profile.upgrades)):equal("table")
		expect(type(profile.skills)):equal("table")
		expect(type(profile.inventory)):equal("table")
	end)
end)
