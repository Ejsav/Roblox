--!nolint
--[[
	TestRunner
	----------
	A compact BDD-style runner: describe / it / expect, with focused and skipped
	specs, per-suite hooks, and a summary that exits non-zero on failure so CI can
	gate on it.
]]

local Runner = {}

local state = {
	suites = {},
	currentSuite = nil,
	passed = 0,
	failed = 0,
	skipped = 0,
	failures = {},
	startClock = 0,
}

local ANSI = {
	reset = "\27[0m",
	dim = "\27[2m",
	red = "\27[31m",
	green = "\27[32m",
	yellow = "\27[33m",
	cyan = "\27[36m",
	bold = "\27[1m",
}

local function colorize(color, text)
	return ANSI[color] .. text .. ANSI.reset
end

-- ============================================================================
-- Expectation API
-- ============================================================================

local Expectation = {}
Expectation.__index = Expectation

local function stringify(value, depth)
	depth = depth or 0
	local t = type(value)
	if t == "string" then
		return '"' .. value .. '"'
	elseif t ~= "table" or depth > 2 then
		return tostring(value)
	end
	local parts = {}
	local count = 0
	for k, v in pairs(value) do
		count += 1
		if count > 8 then
			table.insert(parts, "...")
			break
		end
		table.insert(parts, tostring(k) .. " = " .. stringify(v, depth + 1))
	end
	return "{ " .. table.concat(parts, ", ") .. " }"
end

local function deepEquals(a, b)
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	for k, v in pairs(a) do
		if not deepEquals(v, b[k]) then
			return false
		end
	end
	for k in pairs(b) do
		if a[k] == nil then
			return false
		end
	end
	return true
end

local function fail(message)
	error({ __testFailure = true, message = message }, 3)
end

function Expectation.new(value)
	return setmetatable({ _value = value, _negated = false }, Expectation)
end

function Expectation:__index(key)
	if key == "never" then
		self._negated = not self._negated
		return self
	end
	if key == "to" or key == "be" or key == "a" or key == "an" or key == "is" then
		return self
	end
	return rawget(Expectation, key)
end

function Expectation:_assert(condition, message)
	if self._negated then
		condition = not condition
		message = "(negated) " .. message
	end
	if not condition then
		fail(message)
	end
	return self
end

function Expectation:equal(expected)
	return self:_assert(
		self._value == expected,
		("expected %s but got %s"):format(stringify(expected), stringify(self._value))
	)
end
Expectation.equals = Expectation.equal

function Expectation:deepEqual(expected)
	return self:_assert(
		deepEquals(self._value, expected),
		("expected deep-equal to %s but got %s"):format(stringify(expected), stringify(self._value))
	)
end

function Expectation:near(expected, tolerance)
	local tol = tolerance or 1e-6
	local ok = type(self._value) == "number" and math.abs(self._value - expected) <= tol
	return self:_assert(ok, ("expected %s within %s of %s"):format(tostring(self._value), tostring(tol), tostring(expected)))
end

function Expectation:ok()
	return self:_assert(self._value ~= nil and self._value ~= false, ("expected truthy, got %s"):format(stringify(self._value)))
end
Expectation.truthy = Expectation.ok

function Expectation:falsy()
	return self:_assert(self._value == nil or self._value == false, ("expected falsy, got %s"):format(stringify(self._value)))
end

function Expectation:isNil()
	return self:_assert(self._value == nil, ("expected nil, got %s"):format(stringify(self._value)))
end

function Expectation:typeOf(expected)
	return self:_assert(
		type(self._value) == expected,
		("expected type %s but got %s"):format(expected, type(self._value))
	)
end

function Expectation:greaterThan(bound)
	return self:_assert(
		type(self._value) == "number" and self._value > bound,
		("expected %s > %s"):format(tostring(self._value), tostring(bound))
	)
end

function Expectation:greaterOrEqual(bound)
	return self:_assert(
		type(self._value) == "number" and self._value >= bound,
		("expected %s >= %s"):format(tostring(self._value), tostring(bound))
	)
end

function Expectation:lessThan(bound)
	return self:_assert(
		type(self._value) == "number" and self._value < bound,
		("expected %s < %s"):format(tostring(self._value), tostring(bound))
	)
end

function Expectation:lessOrEqual(bound)
	return self:_assert(
		type(self._value) == "number" and self._value <= bound,
		("expected %s <= %s"):format(tostring(self._value), tostring(bound))
	)
end

function Expectation:within(min, max)
	return self:_assert(
		type(self._value) == "number" and self._value >= min and self._value <= max,
		("expected %s within [%s, %s]"):format(tostring(self._value), tostring(min), tostring(max))
	)
end

function Expectation:contains(item)
	local found = false
	if type(self._value) == "table" then
		for _, v in pairs(self._value) do
			if v == item then
				found = true
				break
			end
		end
	elseif type(self._value) == "string" then
		found = string.find(self._value, item, 1, true) ~= nil
	end
	return self:_assert(found, ("expected %s to contain %s"):format(stringify(self._value), stringify(item)))
end

function Expectation:hasKey(key)
	return self:_assert(
		type(self._value) == "table" and self._value[key] ~= nil,
		("expected table to have key %s"):format(tostring(key))
	)
end

function Expectation:hasLength(n)
	local len = type(self._value) == "table" and #self._value or (type(self._value) == "string" and #self._value or -1)
	return self:_assert(len == n, ("expected length %d but got %d"):format(n, len))
end

function Expectation:throws(pattern)
	local ok, err = pcall(self._value)
	if self._negated then
		if not ok then
			fail("expected function not to throw, but it threw: " .. tostring(err))
		end
		return self
	end
	if ok then
		fail("expected function to throw, but it returned normally")
	end
	if pattern then
		local message = type(err) == "table" and tostring(err.message) or tostring(err)
		if not string.find(message, pattern, 1, true) then
			fail(("expected error containing %q but got %q"):format(pattern, message))
		end
	end
	return self
end

Runner.expect = Expectation.new

-- ============================================================================
-- Suite API
-- ============================================================================

function Runner.describe(name, body)
	local suite = {
		name = name,
		specs = {},
		beforeEach = {},
		afterEach = {},
		beforeAll = {},
		afterAll = {},
		parent = state.currentSuite,
	}
	table.insert(state.suites, suite)
	local previous = state.currentSuite
	state.currentSuite = suite
	local ok, err = pcall(body)
	state.currentSuite = previous
	if not ok then
		table.insert(suite.specs, {
			name = "<suite definition>",
			fn = function()
				error(err, 0)
			end,
		})
	end
end

local function addSpec(name, fn, modifiers)
	local suite = state.currentSuite
	if not suite then
		error("it() called outside of describe()")
	end
	table.insert(suite.specs, {
		name = name,
		fn = fn,
		skip = modifiers and modifiers.skip,
		focus = modifiers and modifiers.focus,
	})
end

function Runner.it(name, fn)
	addSpec(name, fn)
end

function Runner.itSkip(name, fn)
	addSpec(name, fn, { skip = true })
end

function Runner.itFocus(name, fn)
	addSpec(name, fn, { focus = true })
end

function Runner.beforeEach(fn)
	table.insert(state.currentSuite.beforeEach, fn)
end

function Runner.afterEach(fn)
	table.insert(state.currentSuite.afterEach, fn)
end

function Runner.beforeAll(fn)
	table.insert(state.currentSuite.beforeAll, fn)
end

function Runner.afterAll(fn)
	table.insert(state.currentSuite.afterAll, fn)
end

-- ============================================================================
-- Execution
-- ============================================================================

local function collectHooks(suite, field)
	local chain = {}
	local node = suite
	while node do
		table.insert(chain, 1, node)
		node = node.parent
	end
	local hooks = {}
	for _, ancestor in ipairs(chain) do
		for _, hook in ipairs(ancestor[field]) do
			table.insert(hooks, hook)
		end
	end
	return hooks
end

local function suitePath(suite)
	local parts = {}
	local node = suite
	while node do
		table.insert(parts, 1, node.name)
		node = node.parent
	end
	return table.concat(parts, " › ")
end

function Runner.run(filter)
	state.startClock = os.clock()

	local anyFocused = false
	for _, suite in ipairs(state.suites) do
		for _, spec in ipairs(suite.specs) do
			if spec.focus then
				anyFocused = true
			end
		end
	end

	for _, suite in ipairs(state.suites) do
		local path = suitePath(suite)
		if filter and not string.find(path:lower(), filter:lower(), 1, true) then
			continue
		end
		if #suite.specs == 0 then
			continue
		end

		print(colorize("cyan", "\n  " .. path))

		for _, hook in ipairs(collectHooks(suite, "beforeAll")) do
			local ok, err = pcall(hook)
			if not ok then
				print(colorize("red", "    beforeAll failed: " .. tostring(err)))
			end
		end

		for _, spec in ipairs(suite.specs) do
			if spec.skip or (anyFocused and not spec.focus) then
				state.skipped += 1
				print(colorize("dim", "    ○ " .. spec.name))
				continue
			end

			for _, hook in ipairs(collectHooks(suite, "beforeEach")) do
				pcall(hook)
			end

			local ok, err = pcall(spec.fn)

			for _, hook in ipairs(collectHooks(suite, "afterEach")) do
				pcall(hook)
			end

			if ok then
				state.passed += 1
				print(colorize("green", "    ✓ ") .. spec.name)
			else
				state.failed += 1
				local message
				if type(err) == "table" and err.__testFailure then
					message = err.message
				else
					message = tostring(err)
				end
				print(colorize("red", "    ✗ " .. spec.name))
				print(colorize("red", "        " .. message))
				table.insert(state.failures, { path = path, name = spec.name, message = message })
			end
		end

		for _, hook in ipairs(collectHooks(suite, "afterAll")) do
			pcall(hook)
		end
	end

	local elapsed = (os.clock() - state.startClock) * 1000
	print("")
	print(("  %s  %s  %s   %s"):format(
		colorize("green", state.passed .. " passed"),
		state.failed > 0 and colorize("red", state.failed .. " failed") or colorize("dim", "0 failed"),
		state.skipped > 0 and colorize("yellow", state.skipped .. " skipped") or colorize("dim", "0 skipped"),
		colorize("dim", ("%.1fms"):format(elapsed))
	))

	if state.failed > 0 then
		print(colorize("red", "\n  FAILURES:"))
		for _, failure in ipairs(state.failures) do
			print(colorize("red", ("    %s › %s"):format(failure.path, failure.name)))
			print(colorize("dim", "      " .. failure.message))
		end
	end
	print("")

	return state.failed == 0, state
end

function Runner.reset()
	state.suites = {}
	state.currentSuite = nil
	state.passed = 0
	state.failed = 0
	state.skipped = 0
	state.failures = {}
end

--[[ Installs describe/it/expect as globals so spec files read cleanly. ]]
function Runner.install()
	local g = getfenv(0)
	g.describe = Runner.describe
	g.it = Runner.it
	g.itSkip = Runner.itSkip
	g.itFocus = Runner.itFocus
	g.expect = Runner.expect
	g.beforeEach = Runner.beforeEach
	g.afterEach = Runner.afterEach
	g.beforeAll = Runner.beforeAll
	g.afterAll = Runner.afterAll
	return Runner
end

return Runner
