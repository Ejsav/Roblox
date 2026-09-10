--!strict
--[[
	Bit32Util
	---------
	Exact 32-bit integer arithmetic helpers.

	Why this exists: Luau numbers are IEEE-754 doubles, exact only up to 2^53. A naive
	`bit32.band(a * b, 0xFFFFFFFF)` where both operands approach 2^32 produces a product
	near 2^64, which silently loses low bits — precisely the bits a hash or PRNG relies
	on. That produced a measurably non-uniform generator before this module existed.

	`mul32` splits both operands into 16-bit halves so every intermediate product stays
	under 2^33, well inside exact-double range.
]]

local Bit32Util = {}

local MASK16 = 0xFFFF
local BIT16 = 0x10000
local BIT32 = 0x100000000

--[[ (a * b) mod 2^32, computed exactly. ]]
function Bit32Util.mul32(a: number, b: number): number
	a = a % BIT32
	b = b % BIT32

	local aLow = a % BIT16
	local aHigh = (a - aLow) / BIT16
	local bLow = b % BIT16
	local bHigh = (b - bLow) / BIT16

	-- (aHigh*2^16 + aLow)(bHigh*2^16 + bLow) mod 2^32
	--   = ((aHigh*bLow + aLow*bHigh) mod 2^16) * 2^16 + aLow*bLow   (mod 2^32)
	-- The aHigh*bHigh term is entirely above bit 32 and drops out.
	local middle = (aHigh * bLow + aLow * bHigh) % BIT16
	return (middle * BIT16 + aLow * bLow) % BIT32
end

--[[ (a + b) mod 2^32. ]]
function Bit32Util.add32(a: number, b: number): number
	return (a % BIT32 + b % BIT32) % BIT32
end

--[[ Xor-shift right, the avalanche primitive used by every hash here. ]]
function Bit32Util.xorShiftRight(value: number, shift: number): number
	return bit32.bxor(value, bit32.rshift(value, shift))
end

--[[
	MurmurHash3's 32-bit finalizer. Takes a poorly-distributed integer and spreads its
	entropy across all 32 bits.
]]
function Bit32Util.mix32(value: number): number
	local h = value % BIT32
	h = bit32.bxor(h, bit32.rshift(h, 16))
	h = Bit32Util.mul32(h, 0x85EBCA6B)
	h = bit32.bxor(h, bit32.rshift(h, 13))
	h = Bit32Util.mul32(h, 0xC2B2AE35)
	h = bit32.bxor(h, bit32.rshift(h, 16))
	return h
end

--[[ FNV-1a over a string, returning a 32-bit unsigned integer. ]]
function Bit32Util.hashString(str: string): number
	local hash = 2166136261
	for i = 1, #str do
		hash = bit32.bxor(hash, string.byte(str, i) :: number)
		hash = Bit32Util.mul32(hash, 16777619)
	end
	return hash
end

--[[ Combines two 32-bit values into one with good avalanche characteristics. ]]
function Bit32Util.combine(a: number, b: number): number
	return Bit32Util.mix32(bit32.bxor(a % BIT32, Bit32Util.mul32(b % BIT32, 0x9E3779B1)))
end

Bit32Util.MAX_UINT32 = BIT32

return Bit32Util
