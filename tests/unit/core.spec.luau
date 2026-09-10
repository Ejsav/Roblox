--!nolint
--[[ Specs for the shared core utility layer. ]]

local loadModule = loadModule

describe("Core/Signal", function()
	local Signal = loadModule("Shared/Core/Signal")

	it("fires connected handlers with arguments", function()
		local sig = Signal.new("test")
		local received
		sig:Connect(function(a, b)
			received = { a, b }
		end)
		sig:Fire(7, "storm")
		expect(received[1]):equal(7)
		expect(received[2]):equal("storm")
	end)

	it("stops firing after disconnect", function()
		local sig = Signal.new()
		local calls = 0
		local conn = sig:Connect(function()
			calls += 1
		end)
		sig:Fire()
		conn:Disconnect()
		sig:Fire()
		expect(calls):equal(1)
	end)

	it("Once handlers auto-disconnect", function()
		local sig = Signal.new()
		local calls = 0
		sig:Once(function()
			calls += 1
		end)
		sig:Fire()
		sig:Fire()
		expect(calls):equal(1)
		expect(sig:GetConnectionCount()):equal(0)
	end)

	it("survives a handler that errors", function()
		local sig = Signal.new("resilient")
		local reached = false
		sig:Connect(function()
			error("intentional")
		end)
		sig:Connect(function()
			reached = true
		end)
		sig:Fire()
		expect(reached):ok()
	end)

	it("allows a handler to disconnect itself mid-fire", function()
		local sig = Signal.new()
		local calls = 0
		local conn
		conn = sig:Connect(function()
			calls += 1
			conn:Disconnect()
		end)
		sig:Fire()
		sig:Fire()
		expect(calls):equal(1)
	end)

	it("tracks connection count accurately", function()
		local sig = Signal.new()
		local a = sig:Connect(function() end)
		local b = sig:Connect(function() end)
		expect(sig:GetConnectionCount()):equal(2)
		a:Disconnect()
		expect(sig:GetConnectionCount()):equal(1)
		b:Disconnect()
		expect(sig:GetConnectionCount()):equal(0)
	end)
end)

describe("Core/Maid", function()
	local Maid = loadModule("Shared/Core/Maid")

	it("runs teardown functions in reverse order", function()
		local maid = Maid.new()
		local order = {}
		maid:Add(function()
			table.insert(order, 1)
		end)
		maid:Add(function()
			table.insert(order, 2)
		end)
		maid:DoCleaning()
		expect(order[1]):equal(2)
		expect(order[2]):equal(1)
	end)

	it("replaces a keyed task and cleans up the previous one", function()
		local maid = Maid.new()
		local cleaned = false
		maid:Set("slot", function()
			cleaned = true
		end)
		maid:Set("slot", function() end)
		expect(cleaned):ok()
	end)

	it("cleans up immediately when adding to a destroyed maid", function()
		local maid = Maid.new()
		maid:Destroy()
		local cleaned = false
		maid:Add(function()
			cleaned = true
		end)
		expect(cleaned):ok()
	end)

	it("destroys instances it owns", function()
		local maid = Maid.new()
		local part = Instance.new("Part")
		maid:Add(part)
		maid:DoCleaning()
		expect(part._destroyed):ok()
	end)
end)

describe("Core/TableUtil", function()
	local TableUtil = loadModule("Shared/Core/TableUtil")

	it("deep-copies nested tables without aliasing", function()
		local source = { a = { b = { c = 1 } } }
		local copy = TableUtil.DeepCopy(source)
		copy.a.b.c = 2
		expect(source.a.b.c):equal(1)
	end)

	it("handles cyclic references in DeepCopy", function()
		local source = { name = "loop" }
		source.self = source
		local copy = TableUtil.DeepCopy(source)
		expect(copy.self):equal(copy)
	end)

	it("reconciles missing keys from a template", function()
		local target = { level = 5 }
		local template = { level = 1, watts = 0, nested = { unlocked = false } }
		local added = TableUtil.Reconcile(target, template)
		expect(added):equal(2)
		expect(target.level):equal(5)
		expect(target.watts):equal(0)
		expect(target.nested.unlocked):equal(false)
	end)

	it("does not clobber player arrays during reconcile", function()
		local target = { owned = { "a", "b" } }
		local template = { owned = {} }
		TableUtil.Reconcile(target, template)
		expect(#target.owned):equal(2)
	end)

	it("produces and applies diffs", function()
		local old = { a = 1, b = { c = 2 }, d = 4 }
		local new = { a = 1, b = { c = 3 }, e = 5 }
		local diff, changed = TableUtil.Diff(old, new)
		expect(changed):ok()
		TableUtil.ApplyDiff(old, diff)
		expect(old.b.c):equal(3)
		expect(old.d):isNil()
		expect(old.e):equal(5)
	end)

	it("swap-removes in constant time preserving membership", function()
		local list = { "a", "b", "c", "d" }
		TableUtil.SwapRemove(list, "b")
		expect(#list):equal(3)
		expect(TableUtil.Contains(list, "b")):falsy()
		expect(TableUtil.Contains(list, "d")):ok()
	end)

	it("sorts stably by key", function()
		local items = { { n = 2, tag = "x" }, { n = 1, tag = "y" }, { n = 2, tag = "z" } }
		local sorted = TableUtil.SortBy(items, function(i)
			return i.n
		end)
		expect(sorted[1].tag):equal("y")
		expect(sorted[2].tag):equal("x")
		expect(sorted[3].tag):equal("z")
	end)
end)

describe("Core/MathUtil", function()
	local MathUtil = loadModule("Shared/Core/MathUtil")

	it("clamps and remaps", function()
		expect(MathUtil.Clamp(15, 0, 10)):equal(10)
		expect(MathUtil.Map(5, 0, 10, 100, 200)):equal(150)
		expect(MathUtil.MapClamped(50, 0, 10, 100, 200)):equal(200)
	end)

	it("produces a monotonically increasing XP curve", function()
		local previous = 0
		for level = 1, 60 do
			local need = MathUtil.XpForLevel(level)
			expect(need):greaterThan(previous)
			previous = need
		end
	end)

	it("resolves levels consistently with the cumulative curve", function()
		for targetLevel = 1, 40 do
			local total = MathUtil.CumulativeXp(targetLevel)
			local level, into = MathUtil.ResolveLevel(total, 200)
			expect(level):equal(targetLevel)
			expect(into):equal(0)
		end
	end)

	it("caps level resolution at maxLevel", function()
		local level = MathUtil.ResolveLevel(1e12, 75)
		expect(level):equal(75)
	end)

	it("scores the capture pulse highest at the centre", function()
		expect(MathUtil.Pulse(0.5, 0.5, 0.2)):equal(1)
		-- 0.7 sits exactly on the window edge; floating point can land a hair inside.
		expect(MathUtil.Pulse(0.7, 0.5, 0.2)):near(0, 1e-12)
		expect(MathUtil.Pulse(0.9, 0.5, 0.2)):equal(0)
		expect(MathUtil.Pulse(0.55, 0.5, 0.2)):greaterThan(0)
		expect(MathUtil.Pulse(0.55, 0.5, 0.2)):lessThan(1)
	end)

	it("keeps risk multiplier growth sublinear", function()
		local one = MathUtil.RiskMultiplier(1, 1, 1)
		local four = MathUtil.RiskMultiplier(4, 1, 1)
		local eight = MathUtil.RiskMultiplier(8, 1, 1)
		expect(four):greaterThan(one)
		expect(eight):greaterThan(four)
		-- Doubling the chain must not double the bonus above 1x.
		expect(eight - 1):lessThan((four - 1) * 2)
	end)

	it("applies diminishing returns approaching but never reaching the cap", function()
		local cap = 0.75
		local low = MathUtil.DiminishingReturns(10, 40, cap)
		local high = MathUtil.DiminishingReturns(400, 40, cap)
		expect(low):lessThan(high)
		expect(high):lessThan(cap)
	end)

	it("generates deterministic bounded FBM noise", function()
		local a = MathUtil.FBM(12.5, -8.25, 991, 4)
		local b = MathUtil.FBM(12.5, -8.25, 991, 4)
		expect(a):equal(b)
		expect(a):within(0, 1)
	end)

	it("integrates a spring toward its target", function()
		local spring = MathUtil.Spring.new(0, 4, 1)
		spring.Target = 10
		for _ = 1, 240 do
			spring:Update(1 / 60)
		end
		expect(spring.Position):near(10, 0.05)
	end)
end)

describe("Core/RNG", function()
	local RNG = loadModule("Shared/Core/RNG")

	it("is deterministic for a given seed", function()
		local a = RNG.new("borrow-the-storm")
		local b = RNG.new("borrow-the-storm")
		for _ = 1, 500 do
			expect(a:NextUInt()):equal(b:NextUInt())
		end
	end)

	it("derives independent named streams", function()
		local parent = RNG.new(1234)
		local loot = parent:Stream("loot")
		local terrain = parent:Stream("terrain")
		local differences = 0
		for _ = 1, 100 do
			if loot:NextUInt() ~= terrain:NextUInt() then
				differences += 1
			end
		end
		expect(differences):greaterThan(90)
	end)

	it("distributes NextNumber roughly uniformly", function()
		local rng = RNG.new("uniformity")
		local buckets = table.create(10, 0)
		local samples = 50000
		for _ = 1, samples do
			local index = math.floor(rng:NextNumber() * 10) + 1
			buckets[index] += 1
		end
		local expected = samples / 10
		for _, count in ipairs(buckets) do
			-- Each decile should land within 8% of the ideal share.
			expect(math.abs(count - expected) / expected):lessThan(0.08)
		end
	end)

	it("respects integer bounds", function()
		local rng = RNG.new(99)
		for _ = 1, 2000 do
			expect(rng:NextInteger(3, 7)):within(3, 7)
		end
	end)

	it("picks weighted entries proportionally", function()
		local rng = RNG.new("weights")
		local counts = { common = 0, rare = 0 }
		for _ = 1, 20000 do
			local pick = rng:PickWeightedMap({ common = 90, rare = 10 })
			counts[pick] += 1
		end
		local ratio = counts.rare / (counts.common + counts.rare)
		expect(ratio):within(0.08, 0.12)
	end)

	it("samples without replacement", function()
		local rng = RNG.new("sample")
		local sample = rng:Sample({ "a", "b", "c", "d", "e" }, 3)
		expect(#sample):equal(3)
		local seen = {}
		for _, item in ipairs(sample) do
			expect(seen[item]):isNil()
			seen[item] = true
		end
	end)

	it("keeps disc sampling inside the radius", function()
		local rng = RNG.new("disc")
		for _ = 1, 1000 do
			local x, z = rng:NextPointInDisc(250)
			expect(math.sqrt(x * x + z * z)):lessOrEqual(250.0001)
		end
	end)
end)
