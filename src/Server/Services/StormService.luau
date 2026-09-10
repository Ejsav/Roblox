--!strict
--[[
	StormService
	------------
	Owns every live storm cell: spawning, drift, decay, strike generation and
	interest-scoped replication.

	Simulation is level-of-detail'd by distance to the nearest player, because a
	fourteen-thousand-stud world will always have most of its weather nowhere near
	anybody. A cell nobody can see still exists and still drifts — it simply thinks
	twice a second instead of twenty times.

	Replication is interest-scoped: a client is told about cells within its scan
	range plus a margin, and receives batched updates rather than a stream per cell.
	Rare storms broadcast globally regardless, because "there is something worth
	crossing the map for" is a core loop input.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BTS")
local Signal = require(Shared.Core.Signal)
local RNG = require(Shared.Core.RNG)
local MathUtil = require(Shared.Core.MathUtil)
local Net = require(Shared.Net)
local Balance = require(Shared.Config.Balance)
local Regions = require(Shared.Config.Regions)
local StormTypes = require(Shared.Config.StormTypes)

local StormBehaviours = require(script.Parent.Parent.Storm.StormBehaviours)

local StormService = {}
StormService.Name = "StormService"
StormService.Dependencies = { "DataService", "StatsService", "RegionService" }
StormService.Priority = 20

local function toVector3(point: { X: number, Y: number, Z: number }): Vector3
	return Vector3.new(point.X, point.Y, point.Z)
end

function StormService:Init()
	self._cells = {} :: { [string]: any }
	self._cellList = {}
	self._strikes = {} :: { [string]: any }
	self._regionState = {}
	self._rng = RNG.new("storms_" .. tostring(os.time()))
	self._nextCellSerial = 0
	self._accumulatedTime = 0
	self._playerPositions = {} :: { [number]: Vector3 }
	self._eventModifiers = {}
	self._worldHooks = {}

	self.CellSpawned = Signal.new("StormService.CellSpawned")
	self.CellDespawned = Signal.new("StormService.CellDespawned")
	self.StrikeEmitted = Signal.new("StormService.StrikeEmitted")
	self.StrikeResolved = Signal.new("StormService.StrikeResolved")

	for _, region in ipairs(Regions.List) do
		self._regionState[region.id] = {
			activeCells = {},
			nextSpawnAt = 0,
			spawnJitter = self._rng:NextRange(0, region.storms.baseSpawnInterval),
		}
	end
end

function StormService:Start()
	self._stats = self.Registry:Get("StatsService")
	self._regions = self.Registry:Get("RegionService")
	self._capture = self.Registry:Find("CaptureService")
	self._carry = self.Registry:Find("CarryService")
	self._combat = self.Registry:Find("CombatService")
end

-- ============================================================================
-- Registration hooks
--
-- The world generator registers callbacks here so behaviours that want real
-- geometry (conductive structures, highest points, ground height) get it, and fall
-- back to synthesised positions when the world has not been built yet.
-- ============================================================================

function StormService:RegisterWorldHooks(hooks: {
	findStructure: ((Vector3, number, number) -> Vector3?)?,
	findHighestPoint: ((Vector3, number) -> Vector3?)?,
	getGroundHeight: ((Vector3) -> number)?,
	spawnWorldPickup: ((any) -> ())?,
	removeWorldPickup: ((string) -> ())?,
})
	for key, value in pairs(hooks) do
		self._worldHooks[key] = value
	end
end

-- ============================================================================
-- Cell lifecycle
-- ============================================================================

--[[ Picks a spawn position inside a region, biased away from its exact centre. ]]
function StormService:_pickSpawnPosition(region: any): Vector3
	local centre = toVector3(region.center)
	local x, z = self._rng:NextPointInAnnulus(region.radius * 0.18, region.radius * 0.92)
	local candidate = centre + Vector3.new(x, 0, z)

	-- Place the cell in the upper half of the region's vertical band, so strikes
	-- come from above rather than out of the floor.
	local low, high = region.verticalRange.min, region.verticalRange.max
	local y = MathUtil.Lerp(low, high, 0.55 + self._rng:NextNumber() * 0.3)
	candidate = Vector3.new(candidate.X, y, candidate.Z)

	if self._worldHooks.getGroundHeight then
		local groundY = self._worldHooks.getGroundHeight(candidate)
		if groundY then
			candidate = Vector3.new(candidate.X, math.max(groundY + 40, low + 20), candidate.Z)
		end
	end

	return candidate
end

--[[ True when the candidate position is far enough from every existing cell. ]]
function StormService:_isSeparated(position: Vector3): boolean
	local minimum = Balance.Storms.MIN_CELL_SEPARATION
	local minimumSq = minimum * minimum
	for _, cell in ipairs(self._cellList) do
		if (cell.position - position).Magnitude ^ 2 < minimumSq then
			return false
		end
	end
	return true
end

--[[ Creates a cell of a given storm type in a region. Returns the cell, or nil. ]]
function StormService:SpawnCell(regionId: string, stormTypeId: string?, overridePosition: Vector3?)
	local region = Regions.ById[regionId]
	if not region then
		return nil
	end
	if #self._cellList >= Balance.Storms.MAX_ACTIVE_CELLS_GLOBAL then
		return nil
	end

	local regionState = self._regionState[regionId]
	if #regionState.activeCells >= region.storms.maxConcurrent then
		return nil
	end

	local chosenTypeId = stormTypeId
	if not chosenTypeId then
		local weights = StormTypes.GetRegionWeights(region.storms)
		chosenTypeId = self._rng:PickWeightedMap(weights)
	end
	local storm = chosenTypeId and StormTypes.ById[chosenTypeId]
	if not storm then
		return nil
	end

	local position = overridePosition
	if not position then
		-- A handful of attempts to find a separated position; if the region is
		-- genuinely crowded, skip this spawn rather than stacking cells.
		for _ = 1, 6 do
			local candidate = self:_pickSpawnPosition(region)
			if self:_isSeparated(candidate) then
				position = candidate
				break
			end
		end
		if not position then
			return nil
		end
	end

	self._nextCellSerial += 1
	local cellId = ("c%d_%s"):format(self._nextCellSerial, self._rng:NextId(4))

	local lifetimeRange = Balance.Storms.CELL_LIFETIME_RANGE
	local driftRange = Balance.Storms.CELL_DRIFT_SPEED_RANGE
	local driftX, driftZ = self._rng:NextUnitXZ()
	local driftSpeed = self._rng:NextRange(driftRange.min, driftRange.max)

	local intensity = region.storms.intensityScale * self._rng:NextRange(0.85, 1.25)
	local maxCharge = storm.strike.strikeCount * 3 + 6

	local cell = {
		id = cellId,
		regionId = regionId,
		stormTypeId = storm.id,
		storm = storm,
		position = position,
		spawnPosition = position,
		radius = math.max(storm.strike.radius * 2.4, 60) * (storm.presentation.scale or 1),
		intensity = intensity,
		tier = storm.tier,
		charge = maxCharge,
		maxCharge = maxCharge,
		spawnedAt = os.clock(),
		expiresAt = os.clock() + self._rng:NextRange(lifetimeRange.min, lifetimeRange.max),
		drift = Vector3.new(driftX, 0, driftZ) * driftSpeed,
		nextTickAt = 0,
		simulationRate = Balance.Storms.SIM_FAR_RATE,
		activeStrikeIds = {},
		captureCount = 0,
		targetUserId = nil,
		despawning = false,
	}

	local behaviour = StormBehaviours.Get(storm.mechanic)
	cell.behaviour = behaviour
	cell.behaviourState = behaviour.init and behaviour.init(cell, storm, self._rng:Stream(cellId)) or {}
	cell.rng = self._rng:Stream(cellId .. "_sim")

	self._cells[cellId] = cell
	table.insert(self._cellList, cell)
	table.insert(regionState.activeCells, cellId)

	self.CellSpawned:Fire(cell)
	self:_replicateCellSpawn(cell)

	if StormTypes.IsBroadcastWorthy(storm.id) then
		self:_broadcastRareStorm(cell)
	end

	return cell
end

function StormService:DespawnCell(cellId: string, reason: string?)
	local cell = self._cells[cellId]
	if not cell or cell.despawning then
		return
	end
	cell.despawning = true

	-- Resolve any strikes still in flight so no client is left with a hanging
	-- telegraph that never discharges.
	for strikeId in pairs(cell.activeStrikeIds) do
		self:_resolveStrike(strikeId, "cell_despawned")
	end

	self._cells[cellId] = nil
	for index, entry in ipairs(self._cellList) do
		if entry.id == cellId then
			table.remove(self._cellList, index)
			break
		end
	end

	local regionState = self._regionState[cell.regionId]
	if regionState then
		for index, id in ipairs(regionState.activeCells) do
			if id == cellId then
				table.remove(regionState.activeCells, index)
				break
			end
		end
	end

	self.CellDespawned:Fire(cell, reason)
	Net.FireAllClients("StormDespawned", cellId, reason)
end

function StormService:GetCell(cellId: string)
	return self._cells[cellId]
end

function StormService:GetStrike(strikeId: string)
	return self._strikes[strikeId]
end

function StormService:GetActiveCells()
	return self._cellList
end

function StormService:GetCellsInRegion(regionId: string)
	local state = self._regionState[regionId]
	if not state then
		return {}
	end
	local cells = {}
	for _, cellId in ipairs(state.activeCells) do
		local cell = self._cells[cellId]
		if cell then
			table.insert(cells, cell)
		end
	end
	return cells
end

-- ============================================================================
-- Strike lifecycle
-- ============================================================================

function StormService:_emitStrike(cell: any, spec: any)
	local now = os.clock()
	local strikeId = ("s%s_%d"):format(cell.id, (cell.strikeSerial or 0) + 1)
	cell.strikeSerial = (cell.strikeSerial or 0) + 1

	local telegraphDuration = spec.telegraphDuration or cell.storm.strike.windup
	-- Higher intensity means faster, tighter strikes: the region's danger rating is
	-- felt as reaction time, not just as damage.
	telegraphDuration = math.max(
		Balance.Capture.MIN_WINDUP_SECONDS,
		telegraphDuration / math.max(0.4, cell.intensity)
	)

	local strike = {
		id = strikeId,
		cellId = cell.id,
		stormTypeId = cell.stormTypeId,
		position = spec.position,
		radius = spec.radius or cell.storm.strike.radius,
		windowHalfWidth = spec.windowHalfWidth or cell.storm.strike.windowHalfWidth,
		telegraphAt = now,
		peakAt = now + telegraphDuration,
		-- The strike stays live briefly past the peak so a late press still grades
		-- rather than silently doing nothing.
		endsAt = now + telegraphDuration + 0.45,
		index = spec.index or 1,
		meta = spec.meta,
		inverted = spec.inverted or false,
		isDecoy = spec.isDecoy or false,
		captured = false,
		capturedBy = {},
		resolved = false,
	}

	self._strikes[strikeId] = strike
	cell.activeStrikeIds[strikeId] = true

	self.StrikeEmitted:Fire(cell, strike)
	self:_replicateStrike(cell, strike)
	return strike
end

--[[ Re-opens the remaining strikes of a web on a shortened window. ]]
function StormService:_reopenStrikes(cell: any, groupKey: string, delay: number, windowScale: number)
	local now = os.clock()
	for strikeId in pairs(cell.activeStrikeIds) do
		local strike = self._strikes[strikeId]
		if strike and not strike.captured and strike.meta and strike.meta.webId == groupKey then
			strike.peakAt = now + delay
			strike.endsAt = strike.peakAt + 0.45
			strike.windowHalfWidth = strike.windowHalfWidth * windowScale
			self:_replicateStrike(cell, strike)
		end
	end
end

function StormService:_resolveStrike(strikeId: string, reason: string)
	local strike = self._strikes[strikeId]
	if not strike or strike.resolved then
		return
	end
	strike.resolved = true

	local cell = self._cells[strike.cellId]
	if cell then
		cell.activeStrikeIds[strikeId] = nil

		if not strike.captured and cell.behaviour.onMiss then
			local ok, err = pcall(cell.behaviour.onMiss, cell, cell.behaviourState, strike, self:_buildContext(cell))
			if not ok then
				warn(("[StormService] onMiss error in %s: %s"):format(cell.storm.mechanic, tostring(err)))
			end
		end
	end

	self._strikes[strikeId] = nil
	self.StrikeResolved:Fire(cell, strike, reason)
	Net.FireAllClients("StrikeResolved", strikeId, strike.captured, reason)
end

--[[ Marks a strike captured. Called by CaptureService after grading. ]]
function StormService:MarkStrikeCaptured(strikeId: string, player: Player)
	local strike = self._strikes[strikeId]
	if not strike then
		return false
	end
	strike.captured = true
	strike.capturedBy[player.UserId] = true

	local cell = self._cells[strike.cellId]
	if cell then
		cell.captureCount += 1
		cell.charge = math.max(0, cell.charge - (cell.storm.yield.chargeCost or 1))
	end
	return true
end

-- ============================================================================
-- Behaviour context
-- ============================================================================

--[[
	Builds the context table behaviours receive. Constructed per call rather than
	cached because it carries per-invocation fields (the capturing player, the awarded
	energy) that must not leak between calls.
]]
function StormService:_buildContext(cell: any, extra: { [string]: any }?)
	local service = self
	local context = {
		now = os.clock(),
		rng = cell.rng,
		strikeInterval = self:_getStrikeInterval(cell),
		Balance = Balance,

		emitStrike = function(spec)
			return service:_emitStrike(cell, spec)
		end,

		emitDemonstration = function(spec)
			-- Demonstration flashes are visual only; they never become capturable.
			Net.FireAllClients("StrikeTelegraph", {
				cellId = cell.id,
				demonstration = true,
				position = spec.position,
				index = spec.index,
				total = spec.total,
				duration = spec.duration,
				stormTypeId = cell.stormTypeId,
			})
		end,

		reopenStrikes = function(groupKey, delay, windowScale)
			service:_reopenStrikes(cell, groupKey, delay, windowScale)
		end,

		getPlayerPosition = function(player)
			return service._playerPositions[player.UserId]
		end,

		getPlayerByUserId = function(userId)
			return Players:GetPlayerByUserId(userId)
		end,

		getPlayersInRadius = function(position, radius)
			local found = {}
			local radiusSq = radius * radius
			for userId, playerPosition in pairs(service._playerPositions) do
				if (playerPosition - position).Magnitude ^ 2 <= radiusSq then
					local player = Players:GetPlayerByUserId(userId)
					if player then
						table.insert(found, player)
					end
				end
			end
			return found
		end,

		getCarriedEnergy = function(player)
			return service._carry and service._carry:GetCarried(player) or 0
		end,

		drainCarried = function(player, fraction, source)
			if service._carry then
				return service._carry:DrainFraction(player, fraction, source)
			end
			return 0
		end,

		drainCarriedFlat = function(player, amount, source)
			if service._carry then
				return service._carry:DrainFlat(player, amount, source)
			end
			return 0
		end,

		damagePlayer = function(player, amount, source)
			if service._combat then
				service._combat:ApplyDamage(player, amount, source)
			end
		end,

		isPlayerAirborne = function(player)
			local character = player.Character
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			if not humanoid then
				return false
			end
			local state = humanoid:GetState()
			return state == Enum.HumanoidStateType.Freefall
				or state == Enum.HumanoidStateType.Jumping
				or state == Enum.HumanoidStateType.Flying
		end,

		setCellTarget = function(targetCell, userId)
			targetCell.targetUserId = userId
		end,

		broadcastCellState = function(targetCell, payload)
			Net.FireAllClients("StormUpdate", { { id = targetCell.id, state = payload } })
		end,

		onEscape = function(escapedCell, consequence)
			service:DespawnCell(escapedCell.id, "escaped")
			if consequence == "room_flood" then
				Net.FireAllClients("Notification", {
					kind = "warning",
					title = "Containment lost",
					body = "The breach reached the vent.",
				})
			end
		end,

		completeEncounter = function(encounterCell, titleId)
			service.CellDespawned:Fire(encounterCell, "encounter_complete")
			service:DespawnCell(encounterCell.id, "encounter_complete")
		end,

		findStructure = self._worldHooks.findStructure,
		findHighestPoint = self._worldHooks.findHighestPoint,
		getGroundHeight = self._worldHooks.getGroundHeight,
		spawnWorldPickup = self._worldHooks.spawnWorldPickup,
		removeWorldPickup = self._worldHooks.removeWorldPickup,
	}

	if extra then
		for key, value in pairs(extra) do
			context[key] = value
		end
	end

	return context
end

--[[ Seconds between strikes for a cell, shaped by intensity and event modifiers. ]]
function StormService:_getStrikeInterval(cell: any): number
	local range = Balance.Storms.STRIKE_INTERVAL_RANGE
	local base = cell.rng:NextRange(range.min, range.max)
	local intensityFactor = 1 / (1 + (cell.intensity - 1) * Balance.Storms.STRIKE_INTERVAL_SCALE_FALLBACK)
	local modifier = self._eventModifiers.strikeIntervalMultiplier or 1
	return base * intensityFactor * modifier
end

-- ============================================================================
-- Simulation
-- ============================================================================

--[[ Chooses a cell's tick rate from its distance to the nearest player. ]]
function StormService:_getSimulationRate(cell: any): number
	local nearestSq = math.huge
	for _, position in pairs(self._playerPositions) do
		local distanceSq = (position - cell.position).Magnitude ^ 2
		if distanceSq < nearestSq then
			nearestSq = distanceSq
		end
	end

	local near = Balance.Storms.SIM_NEAR_DISTANCE
	local far = Balance.Storms.SIM_FAR_DISTANCE
	if nearestSq <= near * near then
		return Balance.Storms.SIM_NEAR_RATE
	elseif nearestSq <= far * far then
		return Balance.Storms.SIM_MID_RATE
	end
	return Balance.Storms.SIM_FAR_RATE
end

--[[ Main simulation step. Called every server heartbeat. ]]
function StormService:Step(dt: number)
	local now = os.clock()
	self:_refreshPlayerPositions()

	-- Expire strikes whose window has fully closed.
	for strikeId, strike in pairs(self._strikes) do
		if now >= strike.endsAt then
			self:_resolveStrike(strikeId, strike.captured and "captured" or "missed")
		end
	end

	-- Step each cell at its own rate.
	for index = #self._cellList, 1, -1 do
		local cell = self._cellList[index]

		if now >= cell.expiresAt then
			self:DespawnCell(cell.id, "expired")
			continue
		end

		cell.simulationRate = self:_getSimulationRate(cell)
		if now < cell.nextTickAt then
			continue
		end

		local step = math.max(cell.simulationRate, now - (cell.lastTickAt or now))
		cell.lastTickAt = now
		cell.nextTickAt = now + cell.simulationRate

		-- Drift, and bounce off the region boundary so cells stay in their region.
		cell.position += cell.drift * step
		local region = Regions.ById[cell.regionId]
		if region then
			local centre = toVector3(region.center)
			local offset = cell.position - centre
			local horizontal = Vector3.new(offset.X, 0, offset.Z)
			if horizontal.Magnitude > region.radius * 0.95 then
				local inward = -horizontal.Unit
				cell.drift = Vector3.new(inward.X, 0, inward.Z) * cell.drift.Magnitude
			end
		end

		-- Charge recovers so a cell cannot be farmed dry permanently, but a heavily
		-- worked cell does thin out for a while.
		cell.charge = math.min(cell.maxCharge, cell.charge + Balance.Storms.CHARGE_REGEN_PER_SECOND * step)

		if cell.charge >= 1 then
			local ok, err = pcall(function()
				cell.behaviour.update(cell, cell.behaviourState, step, self:_buildContext(cell))
			end)
			if not ok then
				warn(("[StormService] update error in %s: %s"):format(cell.storm.mechanic, tostring(err)))
			end
		end
	end

	-- Region spawn loop.
	self._accumulatedTime += dt
	if self._accumulatedTime >= 1 then
		self._accumulatedTime = 0
		self:_runSpawnLoop(now)
	end
end

function StormService:_refreshPlayerPositions()
	table.clear(self._playerPositions)
	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root then
			self._playerPositions[player.UserId] = root.Position
		end
	end
end

function StormService:_runSpawnLoop(now: number)
	local populatedRegions = self._regions and self._regions:GetPopulatedRegions() or {}

	for _, region in ipairs(Regions.List) do
		local state = self._regionState[region.id]
		if now < state.nextSpawnAt then
			continue
		end

		local playersHere = populatedRegions[region.id] or 0

		-- Regions with nobody in them still generate weather, but far more slowly:
		-- the world should feel alive when you arrive, without paying for it while
		-- you are elsewhere.
		local intervalScale = playersHere > 0 and 1 or 4.5
		-- More players means more weather, with diminishing returns so a full server
		-- does not saturate the global cell cap in one region.
		local populationScale = playersHere > 0 and (1 / (1 + math.log(1 + playersHere) * 0.45)) or 1

		local eventScale = self._eventModifiers.stormSpawnMultiplier
		if eventScale and eventScale > 0 then
			populationScale /= eventScale
		end

		local interval = region.storms.baseSpawnInterval * intervalScale * populationScale
		state.nextSpawnAt = now + interval * self._rng:NextRange(0.8, 1.25)

		if playersHere > 0 or self._rng:Chance(0.35) then
			local forcedTypes = self._eventModifiers.forcedStormTypes
			local stormTypeId = nil
			if forcedTypes and #forcedTypes > 0 and self._rng:Chance(0.6) then
				stormTypeId = self._rng:Pick(forcedTypes)
			end
			self:SpawnCell(region.id, stormTypeId)
		end
	end
end

-- ============================================================================
-- Replication
-- ============================================================================

--[[ Players who should know about a cell: those within scan range plus a margin. ]]
function StormService:_getInterestedPlayers(cell: any): { Player }
	local interested = {}
	for _, player in ipairs(Players:GetPlayers()) do
		local position = self._playerPositions[player.UserId]
		if position then
			local scanRange = self._stats and self._stats:GetStat(player, "scanRange") or 600
			-- A generous margin so a cell does not pop in at the exact scan boundary.
			local interestRange = math.max(scanRange, 500) + 400
			if (position - cell.position).Magnitude <= interestRange then
				table.insert(interested, player)
			end
		end
	end
	return interested
end

function StormService:_cellPayload(cell: any)
	return {
		id = cell.id,
		regionId = cell.regionId,
		stormTypeId = cell.stormTypeId,
		position = cell.position,
		radius = cell.radius,
		intensity = cell.intensity,
		tier = cell.tier,
		charge = cell.charge,
		maxCharge = cell.maxCharge,
		expiresAt = cell.expiresAt,
		targetUserId = cell.targetUserId,
	}
end

function StormService:_replicateCellSpawn(cell: any)
	Net.FireClients(self:_getInterestedPlayers(cell), "StormSpawned", self:_cellPayload(cell))
end

function StormService:_replicateStrike(cell: any, strike: any)
	local clientData = nil
	if cell.behaviour.clientData then
		local ok, data = pcall(cell.behaviour.clientData, cell, cell.behaviourState, strike)
		if ok then
			clientData = data
		end
	end

	local payload = {
		id = strike.id,
		cellId = cell.id,
		stormTypeId = cell.stormTypeId,
		position = strike.position,
		radius = strike.radius,
		telegraphAt = strike.telegraphAt,
		peakAt = strike.peakAt,
		endsAt = strike.endsAt,
		windowHalfWidth = strike.windowHalfWidth,
		inverted = strike.inverted,
		index = strike.index,
		data = clientData,
	}

	-- Strike interest is tighter than cell interest: a telegraph the player cannot
	-- possibly reach is noise on their HUD.
	local interested = {}
	for _, player in ipairs(Players:GetPlayers()) do
		local position = self._playerPositions[player.UserId]
		if position and (position - strike.position).Magnitude <= 900 then
			table.insert(interested, player)
		end
	end
	Net.FireClients(interested, "StrikeTelegraph", payload)
end

function StormService:_broadcastRareStorm(cell: any)
	Net.FireAllClients("RareStormAlert", {
		cellId = cell.id,
		stormTypeId = cell.stormTypeId,
		regionId = cell.regionId,
		position = cell.position,
		rarity = cell.storm.rarity,
		name = cell.storm.name,
		expiresAt = cell.expiresAt,
	})
end

--[[ Batched positional sync, called on a slower cadence than the simulation. ]]
function StormService:SyncCells()
	for _, player in ipairs(Players:GetPlayers()) do
		local position = self._playerPositions[player.UserId]
		if not position then
			continue
		end
		local scanRange = self._stats and self._stats:GetStat(player, "scanRange") or 600
		local interestRange = math.max(scanRange, 500) + 400
		local interestRangeSq = interestRange * interestRange

		local updates = {}
		for _, cell in ipairs(self._cellList) do
			if (position - cell.position).Magnitude ^ 2 <= interestRangeSq then
				table.insert(updates, {
					id = cell.id,
					position = cell.position,
					charge = cell.charge,
					targetUserId = cell.targetUserId,
				})
			end
		end

		if #updates > 0 then
			Net.FireClient(player, "StormUpdate", updates)
		end
	end
end

-- ============================================================================
-- World event integration
-- ============================================================================

--[[ Applies event-driven modifiers to storm generation. ]]
function StormService:SetEventModifiers(modifiers: { [string]: any })
	self._eventModifiers = modifiers or {}
end

function StormService:ClearEventModifiers()
	self._eventModifiers = {}
end

--[[ Forces a cell of a specific type, used by world events and admin commands. ]]
function StormService:ForceSpawn(regionId: string, stormTypeId: string, position: Vector3?)
	return self:SpawnCell(regionId, stormTypeId, position)
end

--[[ Pulls the nearest eligible cell toward a position — the Storm Call ability. ]]
function StormService:PullNearestCell(position: Vector3, searchRadius: number, excludeRarities: { string }?)
	local excluded = {}
	for _, rarity in ipairs(excludeRarities or {}) do
		excluded[rarity] = true
	end

	local best, bestDistance = nil, searchRadius
	for _, cell in ipairs(self._cellList) do
		if not excluded[cell.storm.rarity] then
			local distance = (cell.position - position).Magnitude
			if distance < bestDistance then
				best, bestDistance = cell, distance
			end
		end
	end

	if best then
		local direction = (position - best.position)
		if direction.Magnitude > 1 then
			best.drift = direction.Unit * 90
		end
		best.expiresAt = math.max(best.expiresAt, os.clock() + 45)
	end
	return best
end

function StormService:GetStats()
	local byRegion = {}
	for regionId, state in pairs(self._regionState) do
		byRegion[regionId] = #state.activeCells
	end
	local strikeCount = 0
	for _ in pairs(self._strikes) do
		strikeCount += 1
	end
	return {
		cells = #self._cellList,
		strikes = strikeCount,
		byRegion = byRegion,
	}
end

return StormService
