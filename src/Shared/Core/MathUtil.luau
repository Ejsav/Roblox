--!strict
--[[
	MathUtil
	--------
	Gameplay math: easing, curves, remapping, spring integration and the shared
	progression formulas that server and client must agree on exactly.
]]

local Bit32Util = require(script.Parent.Bit32Util)

local MathUtil = {}

local mul32 = Bit32Util.mul32
local EPSILON = 1e-6
MathUtil.Epsilon = EPSILON

function MathUtil.Clamp(v: number, min: number, max: number): number
	if v < min then
		return min
	elseif v > max then
		return max
	end
	return v
end

function MathUtil.Clamp01(v: number): number
	return MathUtil.Clamp(v, 0, 1)
end

function MathUtil.Lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

function MathUtil.LerpClamped(a: number, b: number, t: number): number
	return a + (b - a) * MathUtil.Clamp01(t)
end

--[[ Inverse lerp: where does `v` sit between a and b, as 0..1? ]]
function MathUtil.InverseLerp(a: number, b: number, v: number): number
	if math.abs(b - a) < EPSILON then
		return 0
	end
	return (v - a) / (b - a)
end

function MathUtil.Map(v: number, inMin: number, inMax: number, outMin: number, outMax: number): number
	return MathUtil.Lerp(outMin, outMax, MathUtil.InverseLerp(inMin, inMax, v))
end

function MathUtil.MapClamped(v: number, inMin: number, inMax: number, outMin: number, outMax: number): number
	return MathUtil.LerpClamped(outMin, outMax, MathUtil.InverseLerp(inMin, inMax, v))
end

--[[
	Framerate-independent exponential smoothing.
	`speed` is roughly "how many e-foldings per second"; 10 is snappy, 2 is lazy.
]]
function MathUtil.Damp(current: number, target: number, speed: number, dt: number): number
	local t = 1 - math.exp(-speed * dt)
	return current + (target - current) * t
end

--[[ Vector3 variant of Damp, used by camera and HUD-follow logic. ]]
function MathUtil.DampVector(current: Vector3, target: Vector3, speed: number, dt: number): Vector3
	local t = 1 - math.exp(-speed * dt)
	return current + (target - current) * t
end

--[[ Moves `current` toward `target` by at most `maxDelta`. ]]
function MathUtil.MoveToward(current: number, target: number, maxDelta: number): number
	local delta = target - current
	if math.abs(delta) <= maxDelta then
		return target
	end
	return current + (delta > 0 and maxDelta or -maxDelta)
end

function MathUtil.Approximately(a: number, b: number, tolerance: number?): boolean
	return math.abs(a - b) <= (tolerance or EPSILON)
end

function MathUtil.Sign(v: number): number
	if v > 0 then
		return 1
	elseif v < 0 then
		return -1
	end
	return 0
end

function MathUtil.Round(v: number, decimals: number?): number
	local mult = 10 ^ (decimals or 0)
	return math.floor(v * mult + 0.5) / mult
end

--[[ Rounds toward the nearest multiple of `step`. Used for grid-snapping world geometry. ]]
function MathUtil.Snap(v: number, step: number): number
	if step <= 0 then
		return v
	end
	return math.floor(v / step + 0.5) * step
end

-- ============================================================================
-- Easing curves. Every curve maps 0..1 -> 0..1 and is used by UI transitions,
-- storm intensity ramps and capture-window shaping.
-- ============================================================================

local Ease = {}
MathUtil.Ease = Ease

function Ease.Linear(t: number): number
	return t
end

function Ease.InQuad(t: number): number
	return t * t
end

function Ease.OutQuad(t: number): number
	return 1 - (1 - t) * (1 - t)
end

function Ease.InOutQuad(t: number): number
	if t < 0.5 then
		return 2 * t * t
	end
	return 1 - ((-2 * t + 2) ^ 2) / 2
end

function Ease.InCubic(t: number): number
	return t * t * t
end

function Ease.OutCubic(t: number): number
	return 1 - (1 - t) ^ 3
end

function Ease.InOutCubic(t: number): number
	if t < 0.5 then
		return 4 * t * t * t
	end
	return 1 - ((-2 * t + 2) ^ 3) / 2
end

function Ease.OutQuart(t: number): number
	return 1 - (1 - t) ^ 4
end

function Ease.OutQuint(t: number): number
	return 1 - (1 - t) ^ 5
end

function Ease.InExpo(t: number): number
	if t <= 0 then
		return 0
	end
	return 2 ^ (10 * t - 10)
end

function Ease.OutExpo(t: number): number
	if t >= 1 then
		return 1
	end
	return 1 - 2 ^ (-10 * t)
end

function Ease.InOutExpo(t: number): number
	if t <= 0 then
		return 0
	elseif t >= 1 then
		return 1
	elseif t < 0.5 then
		return (2 ^ (20 * t - 10)) / 2
	end
	return (2 - 2 ^ (-20 * t + 10)) / 2
end

function Ease.OutBack(t: number, overshoot: number?): number
	local c1 = overshoot or 1.70158
	local c3 = c1 + 1
	return 1 + c3 * (t - 1) ^ 3 + c1 * (t - 1) ^ 2
end

function Ease.InBack(t: number, overshoot: number?): number
	local c1 = overshoot or 1.70158
	local c3 = c1 + 1
	return c3 * t * t * t - c1 * t * t
end

function Ease.OutElastic(t: number): number
	if t <= 0 then
		return 0
	elseif t >= 1 then
		return 1
	end
	local c4 = (2 * math.pi) / 3
	return 2 ^ (-10 * t) * math.sin((t * 10 - 0.75) * c4) + 1
end

function Ease.OutBounce(t: number): number
	local n1, d1 = 7.5625, 2.75
	if t < 1 / d1 then
		return n1 * t * t
	elseif t < 2 / d1 then
		t -= 1.5 / d1
		return n1 * t * t + 0.75
	elseif t < 2.5 / d1 then
		t -= 2.25 / d1
		return n1 * t * t + 0.9375
	end
	t -= 2.625 / d1
	return n1 * t * t + 0.984375
end

--[[ Smoothstep and its higher-order sibling, used for terrain and fog blending. ]]
function Ease.Smoothstep(t: number): number
	t = MathUtil.Clamp01(t)
	return t * t * (3 - 2 * t)
end

function Ease.Smootherstep(t: number): number
	t = MathUtil.Clamp01(t)
	return t * t * t * (t * (t * 6 - 15) + 10)
end

--[[
	A single-peaked "pulse" curve. Returns 1 at t = center and falls off to 0 at
	center +/- width. Powers capture-window scoring: how close was the press to the
	perfect moment?
]]
function MathUtil.Pulse(t: number, center: number, width: number, sharpness: number?): number
	if width <= 0 then
		return 0
	end
	local distance = math.abs(t - center) / width
	if distance >= 1 then
		return 0
	end
	return (1 - distance) ^ (sharpness or 2)
end

--[[ Applies a named easing curve by string, with a safe fallback to linear. ]]
function MathUtil.ApplyEase(name: string, t: number): number
	local fn = (Ease :: any)[name]
	if type(fn) == "function" then
		return fn(MathUtil.Clamp01(t))
	end
	return MathUtil.Clamp01(t)
end

-- ============================================================================
-- Spring integrator. Frame-rate independent, used for HUD needles, camera
-- kick, and the carried-energy instability meter wobble.
-- ============================================================================

local Spring = {}
Spring.__index = Spring
MathUtil.Spring = Spring

function Spring.new(initial: number, frequency: number?, damping: number?)
	return setmetatable({
		Position = initial,
		Velocity = 0,
		Target = initial,
		Frequency = frequency or 6,
		Damping = damping or 1,
	}, Spring)
end

function Spring:Update(dt: number): number
	-- Semi-implicit Euler with sub-stepping for stability at low framerates.
	local steps = math.clamp(math.ceil(dt / (1 / 120)), 1, 8)
	local h = dt / steps
	local omega = self.Frequency * 2 * math.pi
	local zeta = self.Damping
	for _ = 1, steps do
		local accel = -(omega * omega) * (self.Position - self.Target) - 2 * zeta * omega * self.Velocity
		self.Velocity += accel * h
		self.Position += self.Velocity * h
	end
	return self.Position
end

function Spring:Impulse(amount: number)
	self.Velocity += amount
end

function Spring:Snap(value: number)
	self.Position = value
	self.Target = value
	self.Velocity = 0
end

-- ============================================================================
-- Progression formulas. These are the single source of truth; both the server
-- (authoritative) and the client (preview UI) call the same functions so that
-- displayed numbers can never drift from awarded numbers.
-- ============================================================================

--[[
	XP required to advance FROM `level` TO `level + 1`.
	Superlinear but gentle early: level 1->2 is quick, level 40->41 is a session.
]]
function MathUtil.XpForLevel(level: number): number
	if level < 1 then
		return 0
	end
	return math.floor(85 * (level ^ 1.42) + 42 * level + 60)
end

--[[ Total cumulative XP required to reach `level` from level 1. ]]
function MathUtil.CumulativeXp(level: number): number
	local total = 0
	for i = 1, level - 1 do
		total += MathUtil.XpForLevel(i)
	end
	return total
end

--[[
	Resolves a raw cumulative XP value into (level, xpIntoLevel, xpForNext).
	Iterative rather than closed-form because the curve has an additive term;
	levels are capped so a corrupt save cannot spin here forever.
]]
function MathUtil.ResolveLevel(totalXp: number, maxLevel: number): (number, number, number)
	local level = 1
	local remaining = math.max(0, totalXp)
	while level < maxLevel do
		local need = MathUtil.XpForLevel(level)
		if remaining < need then
			return level, remaining, need
		end
		remaining -= need
		level += 1
	end
	return maxLevel, 0, 0
end

--[[
	Geometric upgrade cost curve used by every tier-based upgrade track.
	`base` is the level-1 cost, `growth` the per-level multiplier (~1.18 typical).
]]
function MathUtil.UpgradeCost(base: number, growth: number, level: number): number
	return math.floor(base * (growth ^ math.max(0, level)) + 0.5)
end

--[[ Total cost to go from `fromLevel` to `toLevel` inclusive of the target. ]]
function MathUtil.UpgradeCostRange(base: number, growth: number, fromLevel: number, toLevel: number): number
	local total = 0
	for level = fromLevel, toLevel - 1 do
		total += MathUtil.UpgradeCost(base, growth, level)
	end
	return total
end

--[[
	Diminishing-returns accumulator. Each additional point of a stat gives less than
	the last, asymptotically approaching `cap`. Keeps resistance/efficiency stats from
	trivialising content while still feeling rewarding to invest in.
]]
function MathUtil.DiminishingReturns(points: number, halfPoint: number, cap: number): number
	if points <= 0 then
		return 0
	end
	return cap * (points / (points + halfPoint))
end

--[[
	Risk multiplier curve. Carried energy raises the payout multiplier, but the
	marginal gain flattens: doubling your carry does not double your payout, which
	keeps "bank now" a live decision instead of a solved one.
]]
function MathUtil.RiskMultiplier(chainCount: number, dangerRating: number, bonusScale: number): number
	local chainTerm = 1 + 0.135 * (chainCount ^ 0.86)
	local dangerTerm = 1 + 0.09 * math.max(0, dangerRating - 1)
	return 1 + (chainTerm * dangerTerm - 1) * math.max(0, bonusScale)
end

--[[ Weighted random selection from { {weight = n, ...}, ... }. Returns entry and index. ]]
function MathUtil.WeightedPick<T>(entries: { T }, weightFn: (T) -> number, roll: number): (T?, number?)
	local total = 0
	for _, entry in ipairs(entries) do
		total += math.max(0, weightFn(entry))
	end
	if total <= 0 then
		return nil, nil
	end
	local target = roll * total
	local accumulator = 0
	for index, entry in ipairs(entries) do
		accumulator += math.max(0, weightFn(entry))
		if target <= accumulator then
			return entry, index
		end
	end
	return entries[#entries], #entries
end

--[[ Angle helpers (degrees) that handle wrap-around correctly. ]]
function MathUtil.ShortestAngle(from: number, to: number): number
	local delta = (to - from) % 360
	if delta > 180 then
		delta -= 360
	end
	return delta
end

function MathUtil.LerpAngle(from: number, to: number, t: number): number
	return from + MathUtil.ShortestAngle(from, to) * t
end

--[[ Squared horizontal distance; avoids a sqrt in hot proximity loops. ]]
function MathUtil.HorizontalDistanceSq(a: Vector3, b: Vector3): number
	local dx = a.X - b.X
	local dz = a.Z - b.Z
	return dx * dx + dz * dz
end

function MathUtil.HorizontalDistance(a: Vector3, b: Vector3): number
	return math.sqrt(MathUtil.HorizontalDistanceSq(a, b))
end

--[[
	2D value noise with smooth interpolation. Deterministic given a seed, so the world
	generator produces identical terrain detail on every server.
]]
local function hash2(x: number, y: number, seed: number): number
	-- Exact 32-bit arithmetic via Bit32Util; a plain `x * constant` here would exceed
	-- 2^53 and silently drop the low bits the avalanche depends on.
	local h = bit32.bxor(mul32(x, 374761393), mul32(y, 668265263))
	h = bit32.bxor(h, mul32(seed, 1442695041))
	return Bit32Util.mix32(h) / 4294967296
end

function MathUtil.ValueNoise2D(x: number, y: number, seed: number): number
	local xi, yi = math.floor(x), math.floor(y)
	local xf, yf = x - xi, y - yi
	local u = Ease.Smootherstep(xf)
	local v = Ease.Smootherstep(yf)

	local n00 = hash2(xi, yi, seed)
	local n10 = hash2(xi + 1, yi, seed)
	local n01 = hash2(xi, yi + 1, seed)
	local n11 = hash2(xi + 1, yi + 1, seed)

	local top = MathUtil.Lerp(n00, n10, u)
	local bottom = MathUtil.Lerp(n01, n11, u)
	return MathUtil.Lerp(top, bottom, v)
end

--[[ Fractal Brownian motion over ValueNoise2D. Returns 0..1. ]]
function MathUtil.FBM(x: number, y: number, seed: number, octaves: number, lacunarity: number?, gain: number?): number
	local lac = lacunarity or 2
	local g = gain or 0.5
	local amplitude = 1
	local frequency = 1
	local sum = 0
	local norm = 0
	for _ = 1, octaves do
		sum += MathUtil.ValueNoise2D(x * frequency, y * frequency, seed) * amplitude
		norm += amplitude
		amplitude *= g
		frequency *= lac
	end
	if norm <= 0 then
		return 0
	end
	return sum / norm
end

return MathUtil
