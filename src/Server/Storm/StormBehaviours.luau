--!strict
--[[
	StormBehaviours
	---------------
	One implementation per storm mechanic. This is where "twenty storm types" stops
	being a config table and becomes twenty different things to do with your hands.

	Contract. Every behaviour may implement:

		init(cell, storm, rng) -> state
			Called once when the cell spawns. Returns opaque per-cell state.

		update(cell, state, dt, ctx)
			Called on the cell's simulation tick. Emits strikes via ctx.emitStrike.

		strikePosition(cell, state, strike, now) -> Vector3?
			For strikes that move during their telegraph. Returning nil means the
			strike's stored position is authoritative.

		onCapture(cell, state, strike, ctx) -> { yieldScale, bonusEnergy, ... }?
			Fires after a successful capture. Returns multipliers merged into the award.

		onMiss(cell, state, strike, ctx)
			Fires when a strike discharges uncaptured, or a player mistimes it.

		validate(cell, state, strike, player, ctx) -> (boolean, string?)
			Extra eligibility rules beyond range and timing — altitude gates,
			airborne requirements, decoy correctness.

		clientData(cell, state, strike) -> table?
			Extra fields replicated to the client so it can render the mechanic.

	ctx supplies: now, rng, emitStrike, getPlayerPosition, getPlayersInRadius,
	getCarriedEnergy, damagePlayer, Balance, StormTypes.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BTS")
local MathUtil = require(Shared.Core.MathUtil)

local StormBehaviours = {}

local Registry = {}
StormBehaviours.Registry = Registry

--[[ Shared helper: a point on the cell's disc, at ground-ish height. ]]
local function scatterPoint(cell: any, rng: any, spread: number): Vector3
	local x, z = rng:NextPointInDisc(spread)
	return cell.position + Vector3.new(x, 0, z)
end

--[[ Shared helper: default strike spec derived from the storm's config. ]]
local function baseStrike(storm: any, position: Vector3, index: number)
	return {
		position = position,
		telegraphDuration = storm.strike.windup,
		windowHalfWidth = storm.strike.windowHalfWidth,
		radius = storm.strike.radius,
		index = index,
	}
end

-- ============================================================================
-- TIER 1 — single, moving, travelling
-- ============================================================================

Registry.single_strike = {
	id = "single_strike",

	init = function(cell, storm, rng)
		return { emitted = 0 }
	end,

	update = function(cell, state, dt, ctx)
		if state.emitted >= cell.storm.strike.strikeCount then
			return
		end
		if ctx.now < (state.nextAt or 0) then
			return
		end
		local position = scatterPoint(cell, ctx.rng, cell.radius * 0.7)
		ctx.emitStrike(baseStrike(cell.storm, position, state.emitted + 1))
		state.emitted += 1
		state.nextAt = ctx.now + ctx.strikeInterval
	end,
}

Registry.moving_strike = {
	id = "moving_strike",

	init = function(cell, storm, rng)
		local dirX, dirZ = rng:NextUnitXZ()
		return { emitted = 0, direction = Vector3.new(dirX, 0, dirZ) }
	end,

	update = function(cell, state, dt, ctx)
		if ctx.now < (state.nextAt or 0) then
			return
		end
		local params = cell.storm.params
		local origin = scatterPoint(cell, ctx.rng, cell.radius * 0.55)

		-- Re-randomise the drift each strike so the player cannot memorise one lane.
		local dirX, dirZ = ctx.rng:NextUnitXZ()
		state.direction = Vector3.new(dirX, 0, dirZ)

		local spec = baseStrike(cell.storm, origin, state.emitted + 1)
		spec.meta = {
			drift = true,
			origin = origin,
			direction = state.direction,
			speed = params.driftSpeed,
			distance = params.driftDistance,
			pattern = params.driftPattern,
		}
		ctx.emitStrike(spec)
		state.emitted += 1
		state.nextAt = ctx.now + ctx.strikeInterval
	end,

	strikePosition = function(cell, state, strike, now)
		local meta = strike.meta
		if not meta or not meta.drift then
			return nil
		end
		local elapsed = math.max(0, now - strike.telegraphAt)
		local travelled = math.min(meta.speed * elapsed, meta.distance)
		if meta.pattern == "arc" then
			-- A curved lead is harder to read than a straight one.
			local lateral = math.sin(elapsed * 1.7) * meta.distance * 0.22
			local perpendicular = Vector3.new(-meta.direction.Z, 0, meta.direction.X)
			return meta.origin + meta.direction * travelled + perpendicular * lateral
		end
		return meta.origin + meta.direction * travelled
	end,

	clientData = function(cell, state, strike)
		local meta = strike.meta
		if not meta then
			return nil
		end
		return {
			drift = true,
			origin = meta.origin,
			direction = meta.direction,
			speed = meta.speed,
			distance = meta.distance,
		}
	end,
}

Registry.travelling_line = {
	id = "travelling_line",

	init = function(cell, storm, rng)
		return { emitted = 0 }
	end,

	update = function(cell, state, dt, ctx)
		if ctx.now < (state.nextAt or 0) then
			return
		end
		local params = cell.storm.params
		local dirX, dirZ = ctx.rng:NextUnitXZ()
		local direction = Vector3.new(dirX, 0, dirZ)
		local origin = cell.position - direction * (params.lineLength * 0.5)

		local spec = baseStrike(cell.storm, origin, state.emitted + 1)
		spec.meta = {
			line = true,
			origin = origin,
			direction = direction,
			speed = params.travelSpeed,
			length = params.lineLength,
			width = params.lineWidth,
		}
		ctx.emitStrike(spec)
		state.emitted += 1
		state.nextAt = ctx.now + ctx.strikeInterval
	end,

	strikePosition = function(cell, state, strike, now)
		local meta = strike.meta
		if not meta or not meta.line then
			return nil
		end
		local elapsed = math.max(0, now - strike.telegraphAt)
		local travelled = math.min(meta.speed * elapsed, meta.length)
		return meta.origin + meta.direction * travelled
	end,

	onMiss = function(cell, state, strike, ctx)
		-- The current sweeps through whoever did not move.
		local params = cell.storm.params
		if not params.damageOnContactOutsideWindow then
			return
		end
		local position = Registry.travelling_line.strikePosition(cell, state, strike, ctx.now)
		if position then
			for _, player in ipairs(ctx.getPlayersInRadius(position, params.lineWidth * 1.5)) do
				ctx.damagePlayer(player, params.damageOnContactOutsideWindow, "ground_crawler")
			end
		end
	end,

	clientData = function(cell, state, strike)
		local meta = strike.meta
		if not meta then
			return nil
		end
		return { line = true, origin = meta.origin, direction = meta.direction, speed = meta.speed, width = meta.width }
	end,
}

-- ============================================================================
-- TIER 2 — wide, orbital, sequential
-- ============================================================================

Registry.wide_simultaneous = {
	id = "wide_simultaneous",

	init = function(cell, storm, rng)
		return { emitted = 0 }
	end,

	update = function(cell, state, dt, ctx)
		if ctx.now < (state.nextAt or 0) then
			return
		end
		local params = cell.storm.params

		-- One volley of simultaneous points. Clustering is deliberate: the reward for
		-- reading the pattern is standing where several overlap.
		local points = {}
		for index = 1, params.pointCount do
			local x, z = ctx.rng:NextPointInDisc(params.spread)
			points[index] = cell.position + Vector3.new(x, 0, z)
		end

		local volleyId = ctx.rng:NextId(6)
		for index, position in ipairs(points) do
			local neighbours = 0
			for otherIndex, other in ipairs(points) do
				if otherIndex ~= index and (other - position).Magnitude <= params.clusterBonusRadius then
					neighbours += 1
				end
			end
			local spec = baseStrike(cell.storm, position, index)
			spec.meta = {
				volleyId = volleyId,
				clusterNeighbours = neighbours,
				clusterBonus = neighbours * params.clusterBonusPerNeighbour,
			}
			ctx.emitStrike(spec)
		end

		state.emitted += 1
		state.nextAt = ctx.now + ctx.strikeInterval
	end,

	onCapture = function(cell, state, strike, ctx)
		local bonus = strike.meta and strike.meta.clusterBonus or 0
		if bonus > 0 then
			return { yieldScale = 1 + bonus, reason = "cluster" }
		end
		return nil
	end,

	clientData = function(cell, state, strike)
		return strike.meta and { clusterNeighbours = strike.meta.clusterNeighbours } or nil
	end,
}

Registry.orbital_body = {
	id = "orbital_body",

	init = function(cell, storm, rng)
		return {
			angle = rng:NextNumber() * math.pi * 2,
			lap = 0,
			emitted = 0,
			lastContactCheck = 0,
		}
	end,

	update = function(cell, state, dt, ctx)
		local params = cell.storm.params
		local previousAngle = state.angle
		state.angle = (state.angle + params.orbitSpeed * dt) % (math.pi * 2)

		-- Crossing zero completes a lap, and each lap opens a capture window.
		if state.angle < previousAngle then
			state.lap += 1
			if state.lap <= params.lapsBeforeDischarge then
				local position = cell.position + Vector3.new(
					math.cos(state.angle) * params.orbitRadius,
					6,
					math.sin(state.angle) * params.orbitRadius
				)
				local spec = baseStrike(cell.storm, position, state.lap)
				spec.meta = { lap = state.lap, orbital = true }
				ctx.emitStrike(spec)
				state.emitted += 1
			end
		end

		-- Contact damage on the orb itself, sampled rather than per-frame.
		if ctx.now - state.lastContactCheck >= 0.25 then
			state.lastContactCheck = ctx.now
			local orbPosition = Registry.orbital_body.getOrbPosition(cell, state)
			for _, player in ipairs(ctx.getPlayersInRadius(orbPosition, params.bodyRadius)) do
				ctx.damagePlayer(player, params.contactDamage * 0.25, "ball_lightning")
			end
		end
	end,

	getOrbPosition = function(cell, state)
		local params = cell.storm.params
		return cell.position + Vector3.new(
			math.cos(state.angle) * params.orbitRadius,
			6,
			math.sin(state.angle) * params.orbitRadius
		)
	end,

	onCapture = function(cell, state, strike, ctx)
		-- Each successive lap is worth more, so waiting is rewarded and greed is real.
		local lap = strike.meta and strike.meta.lap or 1
		local scale = (cell.storm.yield.perStrikeScale or 1) ^ (lap - 1)
		return { yieldScale = scale, reason = "lap_" .. tostring(lap) }
	end,

	clientData = function(cell, state, strike)
		return { orbital = true, lap = strike.meta and strike.meta.lap or 1, angle = state.angle }
	end,
}

Registry.sequential_chain = {
	id = "sequential_chain",

	init = function(cell, storm, rng)
		return { link = 0, interval = storm.params.linkInterval, capturedLinks = 0 }
	end,

	update = function(cell, state, dt, ctx)
		local params = cell.storm.params
		if ctx.now < (state.nextAt or 0) then
			return
		end
		if state.link >= params.linkCount then
			-- Reset the chain after a pause so the cell keeps producing.
			state.link = 0
			state.interval = params.linkInterval
			state.capturedLinks = 0
			state.nextAt = ctx.now + ctx.strikeInterval * 2
			return
		end

		state.link += 1

		-- Prefer conductive structures when the world provides them; otherwise walk
		-- outward from the cell centre so the cascade still reads as a sequence.
		local position
		if params.requiresStructure and ctx.findStructure then
			position = ctx.findStructure(cell.position, params.structureSearchRadius, state.link)
		end
		if not position then
			local angle = (state.link / params.linkCount) * math.pi * 2
			local distance = cell.radius * (0.3 + 0.5 * (state.link / params.linkCount))
			position = cell.position + Vector3.new(math.cos(angle) * distance, 4, math.sin(angle) * distance)
		end

		local spec = baseStrike(cell.storm, position, state.link)
		spec.telegraphDuration = math.max(0.35, cell.storm.strike.windup * (state.interval / params.linkInterval))
		spec.meta = { link = state.link, chainBonus = (state.link - 1) * params.chainBonusPerLink }
		ctx.emitStrike(spec)

		-- The cascade accelerates, so a player chasing it has to move ahead of it.
		state.interval *= params.intervalDecayPerLink
		state.nextAt = ctx.now + state.interval
	end,

	onCapture = function(cell, state, strike, ctx)
		state.capturedLinks += 1
		local bonus = strike.meta and strike.meta.chainBonus or 0
		return { yieldScale = 1 + bonus, reason = "link_" .. tostring(strike.meta and strike.meta.link or 1) }
	end,

	clientData = function(cell, state, strike)
		return { link = strike.meta and strike.meta.link or 1, total = cell.storm.params.linkCount }
	end,
}

-- ============================================================================
-- TIER 3 — rhythm, altitude, decoys
-- ============================================================================

Registry.rhythmic_beats = {
	id = "rhythmic_beats",

	init = function(cell, storm, rng)
		return { beat = 0, streak = 0, position = nil }
	end,

	update = function(cell, state, dt, ctx)
		local params = cell.storm.params
		if ctx.now < (state.nextAt or 0) then
			return
		end

		if state.beat >= params.beatCount then
			state.beat = 0
			state.streak = 0
			state.position = nil
			state.nextAt = ctx.now + ctx.strikeInterval
			return
		end

		-- The whole sequence happens at one anchor point: this is a rhythm test, not
		-- a movement test, and moving the target would confuse the two.
		if not state.position then
			state.position = scatterPoint(cell, ctx.rng, cell.radius * 0.4)
		end

		state.beat += 1
		local isAccent = (state.beat % params.accentEvery) == 0

		local spec = baseStrike(cell.storm, state.position, state.beat)
		spec.telegraphDuration = params.beatInterval * 0.8
		spec.meta = { beat = state.beat, accent = isAccent, total = params.beatCount }
		ctx.emitStrike(spec)

		state.nextAt = ctx.now + params.beatInterval
	end,

	onCapture = function(cell, state, strike, ctx)
		local params = cell.storm.params
		local meta = strike.meta or {}
		state.streak += 1
		if meta.accent then
			return { yieldScale = params.accentYieldScale, reason = "accent" }
		end
		return { yieldScale = 1, reason = "beat" }
	end,

	onMiss = function(cell, state, strike, ctx)
		if cell.storm.params.missBreaksSequence then
			-- Breaking the count restarts it. The punishment is losing the accents
			-- you were building toward, not damage.
			state.beat = 0
			state.streak = 0
			state.position = nil
		end
	end,

	clientData = function(cell, state, strike)
		local meta = strike.meta or {}
		return {
			beat = meta.beat,
			accent = meta.accent,
			total = meta.total,
			interval = cell.storm.params.beatInterval,
		}
	end,
}

Registry.altitude_gated = {
	id = "altitude_gated",

	init = function(cell, storm, rng)
		return { emitted = 0 }
	end,

	update = function(cell, state, dt, ctx)
		if ctx.now < (state.nextAt or 0) then
			return
		end
		-- Strike the highest point in range if the world offers one; otherwise strike
		-- above the cell so a player who climbs anything nearby is eligible.
		local position = cell.position + Vector3.new(0, cell.radius * 0.4, 0)
		if ctx.findHighestPoint then
			position = ctx.findHighestPoint(cell.position, cell.radius) or position
		end

		local spec = baseStrike(cell.storm, position, state.emitted + 1)
		spec.meta = { altitudeGated = true, groundY = ctx.getGroundHeight and ctx.getGroundHeight(position) or 0 }
		ctx.emitStrike(spec)
		state.emitted += 1
		state.nextAt = ctx.now + ctx.strikeInterval
	end,

	validate = function(cell, state, strike, player, ctx)
		local params = cell.storm.params
		local position = ctx.getPlayerPosition(player)
		if not position then
			return false, "no_position"
		end
		local groundY = (strike.meta and strike.meta.groundY) or 0
		local altitude = position.Y - groundY
		if altitude < params.minAltitudeAboveGround then
			return false, "too_low"
		end
		return true, nil
	end,

	onCapture = function(cell, state, strike, ctx)
		local params = cell.storm.params
		local position = ctx.capturePosition
		if not position then
			return nil
		end
		local groundY = (strike.meta and strike.meta.groundY) or 0
		local altitude = math.max(0, position.Y - groundY)
		local bonus = math.min(params.maxAltitudeBonus, altitude * params.altitudeYieldScale)
		return { yieldScale = 1 + bonus, reason = ("altitude_%d"):format(math.floor(altitude)) }
	end,

	clientData = function(cell, state, strike)
		return {
			altitudeGated = true,
			minAltitude = cell.storm.params.minAltitudeAboveGround,
			groundY = strike.meta and strike.meta.groundY or 0,
		}
	end,
}

Registry.decoy_pair = {
	id = "decoy_pair",

	init = function(cell, storm, rng)
		return { emitted = 0 }
	end,

	update = function(cell, state, dt, ctx)
		if ctx.now < (state.nextAt or 0) then
			return
		end
		local params = cell.storm.params
		local pairId = ctx.rng:NextId(6)
		local total = params.decoyCount + 1
		local realIndex = ctx.rng:NextInteger(1, total)

		for index = 1, total do
			local position = scatterPoint(cell, ctx.rng, cell.radius * 0.65)
			local isReal = index == realIndex
			local spec = baseStrike(cell.storm, position, index)
			spec.meta = {
				pairId = pairId,
				isReal = isReal,
				-- The real strike's flicker leads the decoy's by a fraction of a
				-- second. That is the entire tell, and it is learnable.
				tellOffset = isReal and 0 or params.tellLeadTime,
				subtlety = params.tellSubtlety,
			}
			-- Decoys never actually pay, and taking one costs.
			spec.isDecoy = not isReal
			ctx.emitStrike(spec)
		end

		state.emitted += 1
		state.nextAt = ctx.now + ctx.strikeInterval
	end,

	validate = function(cell, state, strike, player, ctx)
		if strike.meta and strike.meta.isReal == false then
			return false, "decoy"
		end
		return true, nil
	end,

	onMiss = function(cell, state, strike, ctx)
		-- Only a wrong *choice* punishes; letting the whole pair pass is free.
		if strike.meta and strike.meta.isReal == false and ctx.wrongChoicePlayer then
			local params = cell.storm.params
			ctx.damagePlayer(ctx.wrongChoicePlayer, params.wrongChoiceDamage, "mirror_flash")
		end
	end,

	clientData = function(cell, state, strike)
		local meta = strike.meta or {}
		return {
			pairId = meta.pairId,
			tellOffset = meta.tellOffset,
			subtlety = meta.subtlety,
			-- `isReal` is deliberately NOT replicated. The client renders both
			-- identically and the tell is purely in the timing offset above.
		}
	end,
}

-- ============================================================================
-- TIER 4 — webs, columns, scatter
-- ============================================================================

Registry.linked_nodes = {
	id = "linked_nodes",

	init = function(cell, storm, rng)
		return { webId = nil, nodes = {}, captured = 0, expiresAt = 0 }
	end,

	update = function(cell, state, dt, ctx)
		local params = cell.storm.params

		-- Collapse an expired web so a new one can form.
		if state.webId and ctx.now >= state.expiresAt then
			state.webId = nil
			state.nodes = {}
			state.captured = 0
			state.nextAt = ctx.now + ctx.strikeInterval
			return
		end

		if state.webId or ctx.now < (state.nextAt or 0) then
			return
		end

		state.webId = ctx.rng:NextId(6)
		state.captured = 0
		state.expiresAt = ctx.now + params.collapseAfterSeconds
		state.nodes = {}

		-- Lay nodes on a rough ring so the web reads as a shape rather than a cloud.
		local centre = scatterPoint(cell, ctx.rng, cell.radius * 0.35)
		for index = 1, params.nodeCount do
			local angle = (index / params.nodeCount) * math.pi * 2 + ctx.rng:NextRange(-0.25, 0.25)
			local distance = params.nodeSpacing * ctx.rng:NextRange(0.7, 1.3)
			local position = centre + Vector3.new(math.cos(angle) * distance, ctx.rng:NextRange(0, 8), math.sin(angle) * distance)
			state.nodes[index] = { position = position, captured = false }

			local spec = baseStrike(cell.storm, position, index)
			spec.meta = { webId = state.webId, node = index, total = params.nodeCount }
			-- The first node telegraphs normally; the rest open only when propagated.
			spec.telegraphDuration = cell.storm.strike.windup
			ctx.emitStrike(spec)
		end
	end,

	onCapture = function(cell, state, strike, ctx)
		local params = cell.storm.params
		local meta = strike.meta or {}
		if meta.node and state.nodes[meta.node] then
			state.nodes[meta.node].captured = true
		end
		state.captured += 1

		-- Propagation: capturing a node re-opens its neighbours on a shortened window,
		-- which is what turns the web into a route rather than a checklist.
		if ctx.reopenStrikes and meta.webId then
			ctx.reopenStrikes(meta.webId, params.propagationDelay, params.propagationWindowScale)
		end

		local result = { yieldScale = (cell.storm.yield.perStrikeScale or 1) ^ (state.captured - 1) }
		if state.captured >= params.nodeCount then
			result.yieldScale *= params.fullClearBonus
			result.reason = "full_clear"
			result.announce = "Web cleared"
			state.webId = nil
		else
			result.reason = ("node_%d"):format(state.captured)
		end
		return result
	end,

	clientData = function(cell, state, strike)
		local meta = strike.meta or {}
		local positions = {}
		for index, node in ipairs(state.nodes) do
			positions[index] = node.position
		end
		return { webId = meta.webId, node = meta.node, total = meta.total, nodes = positions }
	end,
}

Registry.vertical_ride = {
	id = "vertical_ride",

	init = function(cell, storm, rng)
		return { columnBase = nil, height = 0, emitted = 0, active = false }
	end,

	update = function(cell, state, dt, ctx)
		local params = cell.storm.params

		if not state.active then
			if ctx.now < (state.nextAt or 0) then
				return
			end
			state.active = true
			state.columnBase = cell.position
			state.height = 0
			state.emitted = 0
		end

		state.height += params.riseSpeed * dt

		-- Strikes appear at intervals up the column, so the capture window itself
		-- climbs and the player rides it.
		local segment = params.columnHeight / cell.storm.strike.strikeCount
		local expected = math.floor(state.height / segment)
		if expected > state.emitted and state.emitted < cell.storm.strike.strikeCount then
			state.emitted += 1
			local position = state.columnBase + Vector3.new(0, state.emitted * segment, 0)
			local spec = baseStrike(cell.storm, position, state.emitted)
			spec.meta = { column = true, height = state.emitted * segment, baseY = state.columnBase.Y }
			ctx.emitStrike(spec)
		end

		if state.height >= params.columnHeight then
			state.active = false
			state.nextAt = ctx.now + ctx.strikeInterval * 1.5
		end
	end,

	validate = function(cell, state, strike, player, ctx)
		if not cell.storm.params.mustBeAirborne then
			return true, nil
		end
		if ctx.isPlayerAirborne and not ctx.isPlayerAirborne(player) then
			return false, "not_airborne"
		end
		return true, nil
	end,

	onCapture = function(cell, state, strike, ctx)
		local params = cell.storm.params
		local height = strike.meta and strike.meta.height or 0
		local bonus = height * params.heightYieldScale
		return {
			yieldScale = (cell.storm.yield.perStrikeScale or 1) ^ ((strike.index or 1) - 1) * (1 + bonus),
			reason = "column",
			applyLift = params.liftForce,
		}
	end,

	clientData = function(cell, state, strike)
		return {
			column = true,
			baseY = strike.meta and strike.meta.baseY or 0,
			height = strike.meta and strike.meta.height or 0,
			radius = cell.storm.params.columnRadius,
		}
	end,
}

Registry.scatter_shower = {
	id = "scatter_shower",

	init = function(cell, storm, rng)
		return { emitted = 0, showerStart = 0, streak = 0 }
	end,

	update = function(cell, state, dt, ctx)
		local params = cell.storm.params

		if state.emitted >= params.pelletCount then
			if ctx.now - state.showerStart > params.showerDuration + 4 then
				state.emitted = 0
				state.streak = 0
			end
			return
		end

		if state.emitted == 0 then
			state.showerStart = ctx.now
		end

		-- Pellets fall continuously across the shower window rather than in volleys.
		local expected = math.floor(((ctx.now - state.showerStart) / params.showerDuration) * params.pelletCount)
		while state.emitted < math.min(expected, params.pelletCount) do
			state.emitted += 1
			local x, z = ctx.rng:NextPointInDisc(params.areaRadius)
			local position = cell.position + Vector3.new(x, ctx.rng:NextRange(0, 10), z)
			local spec = baseStrike(cell.storm, position, state.emitted)
			spec.radius = params.pelletRadius
			spec.telegraphDuration = cell.storm.strike.windup
			spec.meta = { pellet = state.emitted, total = params.pelletCount }
			ctx.emitStrike(spec)
		end
	end,

	onCapture = function(cell, state, strike, ctx)
		local params = cell.storm.params
		state.streak += 1
		return {
			yieldScale = 1 + state.streak * params.streakBonusPerPellet,
			reason = ("streak_%d"):format(state.streak),
		}
	end,

	onMiss = function(cell, state, strike, ctx)
		if cell.storm.params.streakResetOnMiss then
			state.streak = 0
		end
	end,

	clientData = function(cell, state, strike)
		return { pellet = true, streak = state.streak, total = cell.storm.params.pelletCount }
	end,
}

-- ============================================================================
-- TIER 5 — harvest, inversion, escape
-- ============================================================================

Registry.two_phase_harvest = {
	id = "two_phase_harvest",

	init = function(cell, storm, rng)
		return { emitted = 0, fulgurites = {} }
	end,

	update = function(cell, state, dt, ctx)
		local params = cell.storm.params

		-- Expire uncollected fulgurites.
		for index = #state.fulgurites, 1, -1 do
			local entry = state.fulgurites[index]
			if ctx.now >= entry.expiresAt then
				if ctx.removeWorldPickup then
					ctx.removeWorldPickup(entry.id)
				end
				table.remove(state.fulgurites, index)
			end
		end

		if ctx.now < (state.nextAt or 0) then
			return
		end
		local position = scatterPoint(cell, ctx.rng, cell.radius * 0.6)
		local spec = baseStrike(cell.storm, position, state.emitted + 1)
		spec.meta = { harvest = true }
		ctx.emitStrike(spec)
		state.emitted += 1
		state.nextAt = ctx.now + ctx.strikeInterval
	end,

	onCapture = function(cell, state, strike, ctx)
		local params = cell.storm.params

		-- Phase two: the strike fuses ground into collectible fulgurite, which pulls
		-- the player into the open exactly when the next cell is arriving.
		for index = 1, params.fuseCount do
			local x, z = ctx.rng:NextPointInDisc(params.fuseSpread)
			local position = strike.position + Vector3.new(x, 0, z)
			local id = ctx.rng:NextId(8)
			table.insert(state.fulgurites, {
				id = id,
				position = position,
				expiresAt = ctx.now + params.coolDownSeconds,
			})
			if ctx.spawnWorldPickup then
				ctx.spawnWorldPickup({
					id = id,
					kind = "fulgurite",
					position = position,
					energyValue = params.harvestValueEach,
					expiresAt = ctx.now + params.coolDownSeconds,
					shatterOnExpire = params.shatterOnLateHarvest,
					cellId = cell.id,
				})
			end
		end

		return { reason = "fused", announce = ("%d fulgurites — %ds"):format(params.fuseCount, params.coolDownSeconds) }
	end,

	clientData = function(cell, state, strike)
		return { harvest = true, coolDown = cell.storm.params.coolDownSeconds }
	end,
}

Registry.inverted_window = {
	id = "inverted_window",

	init = function(cell, storm, rng)
		return { emitted = 0 }
	end,

	update = function(cell, state, dt, ctx)
		if ctx.now < (state.nextAt or 0) then
			return
		end
		local position = scatterPoint(cell, ctx.rng, cell.radius * 0.5)
		local spec = baseStrike(cell.storm, position, state.emitted + 1)
		spec.inverted = true
		spec.meta = {
			inverted = true,
			nullDuration = cell.storm.params.nullDuration,
			nullVisualCue = cell.storm.params.nullVisualCue,
		}
		ctx.emitStrike(spec)
		state.emitted += 1
		state.nextAt = ctx.now + ctx.strikeInterval
	end,

	-- The inversion itself is handled by CaptureService's grading, which reads
	-- strike.inverted and scores distance FROM the peak rather than toward it.
	onMiss = function(cell, state, strike, ctx)
		local params = cell.storm.params
		if ctx.peakCapturePlayer then
			ctx.damagePlayer(ctx.peakCapturePlayer, params.peakPenaltyDamage, "null_pocket")
			if ctx.drainCarried then
				ctx.drainCarried(ctx.peakCapturePlayer, params.peakPenaltyEnergyLoss, "null_pocket")
			end
		end
	end,

	clientData = function(cell, state, strike)
		return { inverted = true, nullDuration = cell.storm.params.nullDuration, cue = cell.storm.params.nullVisualCue }
	end,
}

Registry.escaping_body = {
	id = "escaping_body",

	init = function(cell, storm, rng)
		local dirX, dirZ = rng:NextUnitXZ()
		return {
			position = cell.position,
			direction = Vector3.new(dirX, 0, dirZ),
			travelled = 0,
			emitted = 0,
			escaped = false,
			speedScale = 1,
		}
	end,

	update = function(cell, state, dt, ctx)
		local params = cell.storm.params
		if state.escaped then
			return
		end

		state.position += state.direction * params.fleeSpeed * state.speedScale * dt
		state.travelled += params.fleeSpeed * state.speedScale * dt

		if state.travelled >= params.escapeDistance then
			state.escaped = true
			if ctx.onEscape then
				ctx.onEscape(cell, params.escapeConsequence)
			end
			return
		end

		if ctx.now < (state.nextAt or 0) then
			return
		end
		local spec = baseStrike(cell.storm, state.position, state.emitted + 1)
		spec.windowHalfWidth = cell.storm.strike.windowHalfWidth * params.interceptWindowScale
		spec.meta = { fleeing = true, progress = state.travelled / params.escapeDistance }
		ctx.emitStrike(spec)
		state.emitted += 1
		state.nextAt = ctx.now + ctx.strikeInterval * 0.6
	end,

	strikePosition = function(cell, state, strike, now)
		return state.position
	end,

	onCapture = function(cell, state, strike, ctx)
		-- Landing an intercept slows it, which makes the next one easier: the
		-- encounter rewards momentum rather than punishing a slow start.
		state.speedScale *= cell.storm.params.slowOnNearMiss
		return {
			yieldScale = (cell.storm.yield.perStrikeScale or 1) ^ ((strike.index or 1) - 1),
			reason = "intercept",
		}
	end,

	clientData = function(cell, state, strike)
		return { fleeing = true, progress = strike.meta and strike.meta.progress or 0, escapeDistance = cell.storm.params.escapeDistance }
	end,
}

-- ============================================================================
-- TIER 6+ — predator, memory, cooperative, encounter, inversion
-- ============================================================================

Registry.predatory_drain = {
	id = "predatory_drain",

	init = function(cell, storm, rng)
		return { targetUserId = nil, drained = 0, emitted = 0, lastRetarget = 0 }
	end,

	update = function(cell, state, dt, ctx)
		local params = cell.storm.params

		-- Retarget periodically rather than per-tick, so the hunt is readable: it
		-- commits to a victim long enough for everyone to see who it wants.
		if ctx.now - state.lastRetarget >= 3 then
			state.lastRetarget = ctx.now
			local richest, richestCarry = nil, 0
			for _, player in ipairs(ctx.getPlayersInRadius(cell.position, params.detectionRadius)) do
				local carried = ctx.getCarriedEnergy(player)
				if carried > richestCarry then
					richest, richestCarry = player, carried
				end
			end
			state.targetUserId = richest and richest.UserId or nil
			if ctx.setCellTarget then
				ctx.setCellTarget(cell, state.targetUserId)
			end
		end

		-- Pursue the target.
		local target = state.targetUserId and ctx.getPlayerByUserId(state.targetUserId) or nil
		if target then
			local targetPosition = ctx.getPlayerPosition(target)
			if targetPosition then
				local toTarget = targetPosition - cell.position
				local distance = toTarget.Magnitude
				if distance > 1 then
					cell.position += toTarget.Unit * math.min(params.pursuitSpeed * dt, distance)
				end
				if distance <= params.drainRadius and ctx.drainCarriedFlat then
					local drained = ctx.drainCarriedFlat(target, params.drainPerSecond * dt, "devourer")
					state.drained += drained
				end
			end
		end

		if ctx.now < (state.nextAt or 0) then
			return
		end
		local spec = baseStrike(cell.storm, cell.position + Vector3.new(0, 8, 0), state.emitted + 1)
		spec.meta = { predator = true, targetUserId = state.targetUserId, drained = state.drained }
		ctx.emitStrike(spec)
		state.emitted += 1
		state.nextAt = ctx.now + ctx.strikeInterval
	end,

	onCapture = function(cell, state, strike, ctx)
		local params = cell.storm.params
		-- Everything it ate comes back out, amplified. Getting hunted and then
		-- landing the capture is the best outcome in the game for a Vault build.
		local recovered = state.drained * params.yieldScalesWithDrained
		state.drained = 0
		if params.captureEndsPursuit then
			state.targetUserId = nil
			if ctx.setCellTarget then
				ctx.setCellTarget(cell, nil)
			end
		end
		return { bonusEnergy = recovered, reason = "devoured_returned", announce = "Devourer drained" }
	end,

	clientData = function(cell, state, strike)
		return { predator = true, targetUserId = state.targetUserId, drained = math.floor(state.drained) }
	end,
}

Registry.pattern_replay = {
	id = "pattern_replay",

	init = function(cell, storm, rng)
		return {
			phase = "idle",
			sequence = {},
			demoIndex = 0,
			replayIndex = 0,
			length = storm.params.sequenceLength,
			correct = 0,
		}
	end,

	update = function(cell, state, dt, ctx)
		local params = cell.storm.params

		if state.phase == "idle" then
			if ctx.now < (state.nextAt or 0) then
				return
			end
			-- Build a new sequence of anchor points.
			state.sequence = {}
			for index = 1, state.length do
				state.sequence[index] = scatterPoint(cell, ctx.rng, cell.radius * 0.6)
			end
			state.phase = "demonstrate"
			state.demoIndex = 0
			state.nextAt = ctx.now

		elseif state.phase == "demonstrate" then
			if ctx.now < state.nextAt then
				return
			end
			state.demoIndex += 1
			if state.demoIndex > state.length then
				state.phase = "replay"
				state.replayIndex = 0
				state.correct = 0
				state.nextAt = ctx.now + 0.6
				return
			end
			-- Demonstration flashes are not capturable; they are the lesson.
			if ctx.emitDemonstration then
				ctx.emitDemonstration({
					position = state.sequence[state.demoIndex],
					index = state.demoIndex,
					total = state.length,
					duration = params.demonstrationInterval,
				})
			end
			state.nextAt = ctx.now + params.demonstrationInterval

		elseif state.phase == "replay" then
			if ctx.now < state.nextAt then
				return
			end
			state.replayIndex += 1
			if state.replayIndex > state.length then
				-- Sequence complete. Growing it makes mastery visible.
				if params.sequenceGrowsOnSuccess and state.correct >= state.length then
					state.length = math.min(params.maxSequenceLength, state.length + 1)
				else
					state.length = params.sequenceLength
				end
				state.phase = "idle"
				state.nextAt = ctx.now + ctx.strikeInterval
				return
			end
			local spec = baseStrike(cell.storm, state.sequence[state.replayIndex], state.replayIndex)
			spec.windowHalfWidth = cell.storm.strike.windowHalfWidth * params.replayWindowScale
			spec.meta = { replay = true, step = state.replayIndex, total = state.length }
			ctx.emitStrike(spec)
			state.nextAt = ctx.now + params.demonstrationInterval * 1.1
		end
	end,

	onCapture = function(cell, state, strike, ctx)
		local params = cell.storm.params
		state.correct += 1
		local result = {
			yieldScale = (cell.storm.yield.perStrikeScale or 1) ^ (state.correct - 1),
			reason = ("step_%d"):format(state.correct),
		}
		if state.correct >= state.length then
			result.yieldScale *= params.perfectSequenceBonus
			result.reason = "perfect_sequence"
			result.announce = ("Sequence %d/%d"):format(state.correct, state.length)
		end
		return result
	end,

	onMiss = function(cell, state, strike, ctx)
		if not cell.storm.params.partialCredit then
			state.correct = 0
		end
	end,

	clientData = function(cell, state, strike)
		return {
			replay = true,
			phase = state.phase,
			step = strike.meta and strike.meta.step or 0,
			total = state.length,
			sequence = state.phase == "demonstrate" and state.sequence or nil,
		}
	end,
}

Registry.cooperative_load = {
	id = "cooperative_load",

	init = function(cell, storm, rng)
		return { emitted = 0, pendingCaptors = {}, windowOpenedAt = 0 }
	end,

	update = function(cell, state, dt, ctx)
		if ctx.now < (state.nextAt or 0) then
			return
		end
		local spec = baseStrike(cell.storm, cell.position + Vector3.new(0, 14, 0), state.emitted + 1)
		spec.meta = {
			cooperative = true,
			requiredCaptors = cell.storm.params.requiredCaptors,
			syncWindow = cell.storm.params.synchronisationWindow,
		}
		ctx.emitStrike(spec)
		state.emitted += 1
		state.pendingCaptors = {}
		state.windowOpenedAt = ctx.now
		state.nextAt = ctx.now + ctx.strikeInterval * 2
	end,

	onCapture = function(cell, state, strike, ctx)
		local params = cell.storm.params

		-- Count everyone who took this strike inside the sync window.
		table.insert(state.pendingCaptors, ctx.player)
		local captors = 0
		for _, captor in ipairs(state.pendingCaptors) do
			if captor then
				captors += 1
			end
		end

		if captors >= params.requiredCaptors then
			return {
				yieldScale = 1 + (captors - 1) * params.perCaptorBonus,
				reason = ("synchronised_%d"):format(captors),
				announce = ("Synchronised x%d"):format(captors),
			}
		end

		-- A solo runner can take a share, and eats the overload for the rest.
		local result = { yieldScale = params.soloPartialShare, reason = "partial_share" }
		if params.overloadOnUndercapture and ctx.player then
			ctx.damagePlayer(ctx.player, params.overloadDamage, "core_pulse")
		end
		return result
	end,

	clientData = function(cell, state, strike)
		return {
			cooperative = true,
			required = cell.storm.params.requiredCaptors,
			current = #state.pendingCaptors,
			syncWindow = cell.storm.params.synchronisationWindow,
		}
	end,
}

Registry.sentient_encounter = {
	id = "sentient_encounter",

	init = function(cell, storm, rng)
		return {
			stage = 1,
			health = storm.params.stageHealthPools[1],
			emitted = 0,
			startedAt = 0,
			transitionUntil = 0,
			-- Playstyle read: the encounter counts how the player engages and shifts
			-- its cadence to punish the thing they are relying on.
			aggressionScore = 0,
			patienceScore = 0,
		}
	end,

	update = function(cell, state, dt, ctx)
		local params = cell.storm.params
		if state.startedAt == 0 then
			state.startedAt = ctx.now
		end
		if ctx.now < state.transitionUntil then
			return
		end
		if ctx.now < (state.nextAt or 0) then
			return
		end

		local enraged = (ctx.now - state.startedAt) > params.enrageAfterSeconds
		local aggressive = state.aggressionScore > state.patienceScore

		-- Aggressive players get tighter, faster strikes; patient players get strikes
		-- that punish waiting. Same encounter, different fight.
		local interval = ctx.strikeInterval * (aggressive and 0.7 or 1.15)
		if enraged then
			interval *= 0.6
		end

		local spread = aggressive and cell.radius * 0.9 or cell.radius * 0.4
		local position = scatterPoint(cell, ctx.rng, spread)
		local spec = baseStrike(cell.storm, position, state.emitted + 1)
		if aggressive then
			spec.windowHalfWidth = cell.storm.strike.windowHalfWidth * 0.8
		end
		spec.meta = { stage = state.stage, enraged = enraged, aggressive = aggressive }
		ctx.emitStrike(spec)

		state.emitted += 1
		state.nextAt = ctx.now + interval
	end,

	onCapture = function(cell, state, strike, ctx)
		local params = cell.storm.params

		-- Track engagement style from the time between captures.
		local sinceLast = ctx.now - (state.lastCaptureAt or ctx.now)
		state.lastCaptureAt = ctx.now
		if sinceLast < 3 then
			state.aggressionScore += 1
		else
			state.patienceScore += 1
		end

		local damage = ctx.awardedEnergy or 100
		state.health -= damage

		local result = {
			yieldScale = (cell.storm.yield.perStrikeScale or 1) ^ ((strike.index or 1) - 1),
			reason = ("stage_%d"):format(state.stage),
		}

		if state.health <= 0 then
			if state.stage < params.stages then
				state.stage += 1
				state.health = params.stageHealthPools[state.stage]
				state.transitionUntil = ctx.now + params.stageTransitionInvuln
				result.announce = ("Stage %d"):format(state.stage)
				result.yieldScale *= 1.5
			else
				result.announce = "The Eye yields"
				result.encounterComplete = true
				result.yieldScale *= 3.0
				if ctx.completeEncounter then
					ctx.completeEncounter(cell, params.awardsTitle)
				end
			end
		end

		return result
	end,

	clientData = function(cell, state, strike)
		local params = cell.storm.params
		return {
			encounter = true,
			stage = state.stage,
			stages = params.stages,
			healthFraction = state.health / params.stageHealthPools[state.stage],
			enraged = strike.meta and strike.meta.enraged or false,
		}
	end,
}

Registry.reality_inversion = {
	id = "reality_inversion",

	init = function(cell, storm, rng)
		return { inverted = false, nextFlipAt = 0, emitted = 0 }
	end,

	update = function(cell, state, dt, ctx)
		local params = cell.storm.params

		if ctx.now >= state.nextFlipAt then
			state.inverted = not state.inverted
			state.nextFlipAt = ctx.now + params.inversionInterval
			if ctx.broadcastCellState then
				ctx.broadcastCellState(cell, {
					inverted = state.inverted,
					warningLeadTime = params.warningLeadTime,
					nextFlipAt = state.nextFlipAt,
				})
			end
		end

		if ctx.now < (state.nextAt or 0) then
			return
		end
		local position = scatterPoint(cell, ctx.rng, cell.radius * 0.7)
		local spec = baseStrike(cell.storm, position, state.emitted + 1)
		spec.inverted = state.inverted
		spec.meta = { polarity = state.inverted and "inverted" or "normal", nextFlipAt = state.nextFlipAt }
		ctx.emitStrike(spec)
		state.emitted += 1
		state.nextAt = ctx.now + ctx.strikeInterval
	end,

	onCapture = function(cell, state, strike, ctx)
		local params = cell.storm.params
		-- Matching the current polarity is the whole skill test.
		local matched = (strike.inverted == state.inverted)
		if matched then
			return { yieldScale = params.correctPolarityBonus, reason = "polarity_matched" }
		end
		if ctx.player then
			ctx.damagePlayer(ctx.player, params.wrongPolarityDamage, "inversion")
		end
		return { yieldScale = 0.25, reason = "polarity_wrong" }
	end,

	clientData = function(cell, state, strike)
		local params = cell.storm.params
		return {
			inversion = true,
			inverted = state.inverted,
			nextFlipAt = state.nextFlipAt,
			warningLeadTime = params.warningLeadTime,
			invertsGravity = params.invertsGravity,
			invertsHud = params.invertsHud,
		}
	end,
}

-- ============================================================================
-- Registry access
-- ============================================================================

--[[
	Resolves a behaviour by mechanic name.
	Falls back to single_strike so an unimplemented mechanic still produces a
	playable storm rather than a dead cell.
]]
function StormBehaviours.Get(mechanic: string)
	local behaviour = Registry[mechanic]
	if not behaviour then
		warn(("[StormBehaviours] no implementation for mechanic '%s'; using single_strike"):format(tostring(mechanic)))
		return Registry.single_strike
	end
	return behaviour
end

function StormBehaviours.Has(mechanic: string): boolean
	return Registry[mechanic] ~= nil
end

function StormBehaviours.GetImplementedMechanics(): { string }
	local names = {}
	for name in pairs(Registry) do
		table.insert(names, name)
	end
	table.sort(names)
	return names
end

return StormBehaviours
