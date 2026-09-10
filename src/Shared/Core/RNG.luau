--!strict
--[[
	RNG
	---
	Deterministic pseudo-random number generation.

	We implement our own 32-bit LCG-with-avalanche rather than using Roblox's `Random`
	for two reasons:
	  1. World generation must be byte-identical on every server for a given world seed,
	     so distant landmarks line up with the terrain a player sees from another region.
	  2. Loot rolls must be reproducible in unit tests without a Roblox runtime.

	Streams are cheap: derive a named sub-stream from a parent so that (for example)
	"loot" rolls never desynchronise "terrain" rolls when we add a new drop table.
]]

local Bit32Util = require(script.Parent.Bit32Util)

local RNG = {}
RNG.__index = RNG

local UINT32 = 4294967296
local mul32 = Bit32Util.mul32

--[[ Converts an arbitrary string into a 32-bit seed via FNV-1a. ]]
function RNG.HashString(str: string): number
	return Bit32Util.hashString(str)
end

function RNG.new(seed: (number | string)?)
	local numericSeed: number
	if type(seed) == "string" then
		numericSeed = RNG.HashString(seed)
	elseif type(seed) == "number" then
		numericSeed = math.floor(math.abs(seed)) % UINT32
	else
		numericSeed = math.floor((os.clock() * 1e6) % UINT32)
	end
	-- A zero state would lock the generator; nudge it off the fixed point.
	if numericSeed == 0 then
		numericSeed = 0x9E3779B9
	end
	return setmetatable({
		_state = numericSeed,
		_seed = numericSeed,
		_calls = 0,
	}, RNG)
end

--[[ Creates a deterministic child stream keyed by a name. ]]
function RNG:Stream(name: string)
	return RNG.new(Bit32Util.combine(self._seed, Bit32Util.hashString(name)))
end

--[[ Restores the generator to its initial state. ]]
function RNG:Reset()
	self._state = self._seed
	self._calls = 0
end

function RNG:GetSeed(): number
	return self._seed
end

--[[ Advances the state and returns a raw 32-bit unsigned integer. ]]
function RNG:NextUInt(): number
	-- Numerical Recipes LCG for state advance, then a MurmurHash3 finalizer on the
	-- output. The LCG alone has notoriously weak low bits; the finalizer fixes them
	-- without disturbing the full period of the underlying sequence.
	local state = (mul32(self._state, 1664525) + 1013904223) % UINT32
	self._state = state
	self._calls += 1
	return Bit32Util.mix32(state)
end

--[[ Uniform float in [0, 1). ]]
function RNG:NextNumber(): number
	return self:NextUInt() / UINT32
end

--[[ Uniform float in [min, max). ]]
function RNG:NextRange(min: number, max: number): number
	return min + (max - min) * self:NextNumber()
end

--[[ Uniform integer in [min, max] inclusive. ]]
function RNG:NextInteger(min: number, max: number): number
	if max <= min then
		return min
	end
	return min + (self:NextUInt() % (max - min + 1))
end

--[[ True with probability `chance` (0..1). ]]
function RNG:Chance(chance: number): boolean
	return self:NextNumber() < chance
end

--[[ Returns -1 or 1. ]]
function RNG:NextSign(): number
	return self:NextUInt() % 2 == 0 and -1 or 1
end

--[[ Approximately normal distribution via the sum of 3 uniforms (fast, bounded). ]]
function RNG:NextGaussian(mean: number, deviation: number): number
	local sum = self:NextNumber() + self:NextNumber() + self:NextNumber()
	return mean + (sum - 1.5) * 2 * deviation
end

--[[ Picks a uniformly random element of an array. ]]
function RNG:Pick<T>(list: { T }): T?
	local n = #list
	if n == 0 then
		return nil
	end
	return list[self:NextInteger(1, n)]
end

--[[
	Weighted pick. `weightKey` names the numeric field carrying the weight; entries
	with non-positive weight are skipped entirely.
]]
function RNG:PickWeighted<T>(list: { T }, weightKey: string): T?
	local total = 0
	for _, entry in ipairs(list) do
		local w = (entry :: any)[weightKey]
		if type(w) == "number" and w > 0 then
			total += w
		end
	end
	if total <= 0 then
		return nil
	end
	local target = self:NextNumber() * total
	local acc = 0
	for _, entry in ipairs(list) do
		local w = (entry :: any)[weightKey]
		if type(w) == "number" and w > 0 then
			acc += w
			if target <= acc then
				return entry
			end
		end
	end
	return list[#list]
end

--[[ Weighted pick over a map of key -> weight. Returns the key. ]]
function RNG:PickWeightedMap(map: { [string]: number }): string?
	local total = 0
	for _, weight in pairs(map) do
		if weight > 0 then
			total += weight
		end
	end
	if total <= 0 then
		return nil
	end
	-- Sort keys so iteration order cannot vary between runs; determinism matters.
	local keys = {}
	for key in pairs(map) do
		table.insert(keys, key)
	end
	table.sort(keys)

	local target = self:NextNumber() * total
	local acc = 0
	for _, key in ipairs(keys) do
		local weight = map[key]
		if weight > 0 then
			acc += weight
			if target <= acc then
				return key
			end
		end
	end
	return keys[#keys]
end

--[[ In-place Fisher-Yates shuffle. ]]
function RNG:Shuffle<T>(list: { T }): { T }
	for i = #list, 2, -1 do
		local j = self:NextInteger(1, i)
		list[i], list[j] = list[j], list[i]
	end
	return list
end

--[[ Returns `count` distinct elements sampled without replacement. ]]
function RNG:Sample<T>(list: { T }, count: number): { T }
	local pool = table.clone(list)
	self:Shuffle(pool)
	local out = {}
	for i = 1, math.min(count, #pool) do
		out[i] = pool[i]
	end
	return out
end

--[[ Random unit direction on the XZ plane. ]]
function RNG:NextUnitXZ(): (number, number)
	local angle = self:NextNumber() * math.pi * 2
	return math.cos(angle), math.sin(angle)
end

--[[
	Random point inside a disc of the given radius, uniformly distributed by area
	(the sqrt is what prevents clustering at the centre).
]]
function RNG:NextPointInDisc(radius: number): (number, number)
	local r = radius * math.sqrt(self:NextNumber())
	local angle = self:NextNumber() * math.pi * 2
	return math.cos(angle) * r, math.sin(angle) * r
end

--[[ Random point in an annulus, used to place storms away from a region's centre. ]]
function RNG:NextPointInAnnulus(innerRadius: number, outerRadius: number): (number, number)
	local inner2 = innerRadius * innerRadius
	local outer2 = outerRadius * outerRadius
	local r = math.sqrt(inner2 + (outer2 - inner2) * self:NextNumber())
	local angle = self:NextNumber() * math.pi * 2
	return math.cos(angle) * r, math.sin(angle) * r
end

--[[ Generates a short unique-ish id string. Not cryptographic; used for entity ids. ]]
local ID_ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
function RNG:NextId(length: number?): string
	local n = length or 10
	local chars = table.create(n)
	for i = 1, n do
		local index = self:NextInteger(1, #ID_ALPHABET)
		chars[i] = string.sub(ID_ALPHABET, index, index)
	end
	return table.concat(chars)
end

--[[ Shared global stream for non-deterministic, non-persisted cosmetic decisions. ]]
RNG.Global = RNG.new()

return RNG
