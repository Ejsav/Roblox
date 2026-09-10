--!strict
--[[
	StormController
	---------------
	Client-side storm state and the capture interaction.

	This is where the game's core verb lives. The server is authoritative over
	everything that matters, but the *feel* — the ring closing, the audio rising, the
	moment you press — is entirely local, because a timing minigame routed through
	the network would be unplayable.

	The contract with the server: the client renders the telegraph it was told about,
	predicts the grade for immediate feedback, and sends its press with a timestamp.
	The server regrades and its answer wins. When the two disagree the client
	corrects, which is rare enough to be invisible and honest enough to be safe.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BTS")
local Signal = require(Shared.Core.Signal)
local Maid = require(Shared.Core.Maid)
local Net = require(Shared.Net)
local Theme = require(Shared.Config.Theme)
local StormTypes = require(Shared.Config.StormTypes)
local Balance = require(Shared.Config.Balance)

local StormController = {}
StormController.Name = "StormController"
StormController.Dependencies = { "InputController" }
StormController.Priority = 20

local LocalPlayer = Players.LocalPlayer

function StormController:Init()
	self._maid = Maid.new()
	self._cells = {} :: { [string]: any }
	self._strikes = {} :: { [string]: any }
	self._captureRadius = Balance.Capture.BASE_CAPTURE_RADIUS
	self._windowScale = 1
	self._lastPressAt = 0

	self.StrikeAppeared = Signal.new("StormController.StrikeAppeared")
	self.StrikeResolved = Signal.new("StormController.StrikeResolved")
	self.CaptureFeedback = Signal.new("StormController.CaptureFeedback")
	self.TargetChanged = Signal.new("StormController.TargetChanged")
end

function StormController:Start()
	self._input = self.Registry:Get("InputController")
	self._vfx = self.Registry:Find("VfxController")
	self._audio = self.Registry:Find("AudioController")

	self._maid:Add(Net.OnClientEvent("StormSpawned", function(payload)
		self:_onCellSpawned(payload)
	end))
	self._maid:Add(Net.OnClientEvent("StormDespawned", function(cellId)
		self:_onCellDespawned(cellId)
	end))
	self._maid:Add(Net.OnClientEvent("StormUpdate", function(updates)
		self:_onCellUpdate(updates)
	end))
	self._maid:Add(Net.OnClientEvent("StrikeTelegraph", function(payload)
		self:_onStrikeTelegraph(payload)
	end))
	self._maid:Add(Net.OnClientEvent("StrikeResolved", function(strikeId, captured, reason)
		self:_onStrikeResolved(strikeId, captured, reason)
	end))
	self._maid:Add(Net.OnClientEvent("CaptureResult", function(result)
		self:_onCaptureResult(result)
	end))
	self._maid:Add(Net.OnClientEvent("ProfileSync", function(payload)
		if payload.stats then
			self:_applyStats(payload.stats)
		end
	end))
	self._maid:Add(Net.OnClientEvent("ProfileDelta", function(payload)
		if payload.stats then
			self:_applyStats(payload.stats)
		end
	end))

	self._maid:Add(self._input.ActionBegan:Connect(function(actionId)
		if actionId == "capture" then
			self:AttemptCapture()
		end
	end))
end

function StormController:_applyStats(stats: { [string]: number })
	self._captureRadius = math.clamp(
		stats.captureRadius or Balance.Capture.BASE_CAPTURE_RADIUS,
		1,
		Balance.Capture.MAX_CAPTURE_RADIUS
	)
	self._windowScale = stats.captureWindow or 1
end

-- ============================================================================
-- Cell tracking
-- ============================================================================

function StormController:_onCellSpawned(payload: any)
	local storm = StormTypes.ById[payload.stormTypeId]
	if not storm then
		return
	end

	self._cells[payload.id] = {
		id = payload.id,
		stormTypeId = payload.stormTypeId,
		storm = storm,
		position = payload.position,
		radius = payload.radius,
		intensity = payload.intensity,
		charge = payload.charge,
		maxCharge = payload.maxCharge,
		tier = payload.tier,
		regionId = payload.regionId,
		targetUserId = payload.targetUserId,
		expiresAt = payload.expiresAt,
	}

	if self._vfx then
		self._vfx:CreateStormCell(self._cells[payload.id])
	end
	if self._audio then
		self._audio:StartStormAmbience(payload.id, self._cells[payload.id])
	end
end

function StormController:_onCellDespawned(cellId: string)
	local cell = self._cells[cellId]
	if not cell then
		return
	end
	self._cells[cellId] = nil

	if self._vfx then
		self._vfx:RemoveStormCell(cellId)
	end
	if self._audio then
		self._audio:StopStormAmbience(cellId)
	end
end

function StormController:_onCellUpdate(updates: { any })
	for _, update in ipairs(updates) do
		local cell = self._cells[update.id]
		if cell then
			if update.position then
				cell.position = update.position
			end
			if update.charge then
				cell.charge = update.charge
			end
			if update.targetUserId ~= nil then
				cell.targetUserId = update.targetUserId
			end
			if update.state then
				cell.state = update.state
			end
			if self._vfx then
				self._vfx:UpdateStormCell(cell)
			end
		end
	end
end

-- ============================================================================
-- Strikes
-- ============================================================================

function StormController:_onStrikeTelegraph(payload: any)
	-- Demonstration flashes are visual only; they must never be treated as a
	-- capture target or the Echo Bloom sequence becomes unreadable.
	if payload.demonstration then
		if self._vfx then
			self._vfx:PlayDemonstration(payload)
		end
		return
	end

	local strike = {
		id = payload.id,
		cellId = payload.cellId,
		stormTypeId = payload.stormTypeId,
		position = payload.position,
		radius = payload.radius,
		telegraphAt = payload.telegraphAt,
		peakAt = payload.peakAt,
		endsAt = payload.endsAt,
		windowHalfWidth = payload.windowHalfWidth,
		inverted = payload.inverted,
		index = payload.index,
		data = payload.data,
		attempted = false,
	}

	self._strikes[strike.id] = strike
	self.StrikeAppeared:Fire(strike)

	if self._vfx then
		self._vfx:CreateTelegraph(strike)
	end
	if self._audio then
		self._audio:PlayTelegraph(strike)
	end
end

function StormController:_onStrikeResolved(strikeId: string, captured: boolean, reason: string)
	local strike = self._strikes[strikeId]
	if not strike then
		return
	end
	self._strikes[strikeId] = nil

	self.StrikeResolved:Fire(strike, captured, reason)

	if self._vfx then
		self._vfx:ResolveTelegraph(strike, captured)
	end
	if self._audio then
		self._audio:PlayDischarge(strike, captured)
	end
end

-- ============================================================================
-- Targeting
-- ============================================================================

--[[
	The strike the player would capture right now: the closest live one inside their
	capture radius, preferring whichever is nearest its peak so a player standing in
	an overlapping cluster always takes the one that is about to fire.
]]
function StormController:GetTargetStrike()
	local character = LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		return nil
	end

	local origin = (root :: BasePart).Position
	local now = Workspace:GetServerTimeNow()

	local best, bestScore = nil, math.huge
	for _, strike in pairs(self._strikes) do
		local position = self:GetStrikePosition(strike)
		local distance = (origin - position).Magnitude
		local reach = self._captureRadius + strike.radius

		if distance <= reach then
			-- Score by time-to-peak first, distance second.
			local timeToPeak = math.abs(strike.peakAt - now)
			local score = timeToPeak * 10 + distance * 0.01
			if score < bestScore then
				best, bestScore = strike, score
			end
		end
	end

	return best
end

--[[
	Where a strike is right now, accounting for behaviours that move it during the
	telegraph. The client reproduces the same motion the server uses so the ring is
	drawn where the capture will actually be tested.
]]
function StormController:GetStrikePosition(strike: any): Vector3
	local data = strike.data
	if not data then
		return strike.position
	end

	local now = Workspace:GetServerTimeNow()
	local elapsed = math.max(0, now - strike.telegraphAt)

	if data.drift then
		local travelled = math.min(data.speed * elapsed, data.distance)
		return data.origin + data.direction * travelled
	elseif data.line then
		local travelled = math.min(data.speed * elapsed, data.length or 1e6)
		return data.origin + data.direction * travelled
	end

	return strike.position
end

--[[ Normalised 0..1 progress through a strike's telegraph. ]]
function StormController:GetStrikeProgress(strike: any): number
	local now = Workspace:GetServerTimeNow()
	local total = strike.peakAt - strike.telegraphAt
	if total <= 0 then
		return 1
	end
	return math.clamp((now - strike.telegraphAt) / total, 0, 1.4)
end

--[[
	The predicted grade if the player pressed at this exact instant. Drives the
	capture ring's colour, so the player is learning the timing continuously rather
	than only at the moment of the press.
]]
function StormController:PredictGrade(strike: any): (string?, number)
	local now = Workspace:GetServerTimeNow()
	local windowHalfWidth = math.clamp(
		strike.windowHalfWidth * self._windowScale,
		Balance.Capture.MIN_WINDOW_HALF_WIDTH,
		0.5
	)

	local timingError = math.abs(now - strike.peakAt)
	local normalised = timingError / math.max(0.01, windowHalfWidth)

	local distance = normalised
	if strike.inverted then
		if distance > 1 then
			return nil, normalised
		end
		distance = 1 - distance
	end

	if distance > 1 then
		return nil, normalised
	end

	for _, grade in ipairs(Balance.Capture.GRADES) do
		if distance <= grade.maxDistance then
			return grade.id, normalised
		end
	end
	return nil, normalised
end

-- ============================================================================
-- Capture
-- ============================================================================

function StormController:AttemptCapture(): boolean
	local now = os.clock()
	if now - self._lastPressAt < Balance.Capture.ATTEMPT_COOLDOWN then
		return false
	end

	local strike = self:GetTargetStrike()
	if not strike then
		-- No target: a distinct, quiet failure so the player learns that range
		-- matters, without being punished for exploring the control.
		self.CaptureFeedback:Fire({ success = false, reason = "no_target" })
		if self._audio then
			self._audio:PlayUi("capture_no_target")
		end
		return false
	end

	self._lastPressAt = now
	strike.attempted = true

	local character = LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		return false
	end

	-- Local prediction: immediate feedback while the server's answer is in flight.
	local predictedGrade, normalised = self:PredictGrade(strike)
	self.CaptureFeedback:Fire({
		success = predictedGrade ~= nil,
		predicted = true,
		grade = predictedGrade,
		normalised = normalised,
		strikeId = strike.id,
	})

	if self._vfx then
		self._vfx:PlayCapturePress(strike, predictedGrade)
	end
	if self._audio then
		self._audio:PlayCapturePress(predictedGrade)
	end

	Net.FireServer(
		"AttemptCapture",
		strike.cellId,
		strike.id,
		Workspace:GetServerTimeNow(),
		(root :: BasePart).Position
	)

	return true
end

function StormController:_onCaptureResult(result: any)
	-- The server's grade is authoritative. When it differs from the prediction the
	-- HUD corrects, which is honest and — because the prediction uses the same
	-- formula — almost never visible.
	self.CaptureFeedback:Fire({
		success = result.success,
		predicted = false,
		grade = result.grade,
		energy = result.energy,
		overflow = result.overflow,
		chain = result.chain,
		multiplier = result.multiplier,
		reason = result.reason,
		normalised = result.normalised,
		salvaged = result.salvaged,
		announce = result.announce,
		drops = result.drops,
		strikeId = result.strikeId,
	})

	if result.success then
		if self._vfx then
			self._vfx:PlayCaptureSuccess(result)
		end
		if self._audio then
			self._audio:PlayCaptureSuccess(result.grade)
		end
		-- Column storms give lift on capture, applied locally for responsiveness.
		if result.applyLift then
			self:_applyLift(result.applyLift)
		end
	else
		if self._vfx then
			self._vfx:PlayCaptureFail(result)
		end
		if self._audio then
			self._audio:PlayCaptureFail(result.reason)
		end
	end
end

function StormController:_applyLift(force: number)
	local character = LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		return
	end
	local part = root :: BasePart
	part.AssemblyLinearVelocity = Vector3.new(
		part.AssemblyLinearVelocity.X,
		math.max(part.AssemblyLinearVelocity.Y, force),
		part.AssemblyLinearVelocity.Z
	)
end

-- ============================================================================
-- Queries for the HUD
-- ============================================================================

function StormController:GetCells()
	return self._cells
end

function StormController:GetStrikes()
	return self._strikes
end

function StormController:GetCaptureRadius(): number
	return self._captureRadius
end

--[[ Live storm cells sorted by distance, for the compass and the map. ]]
function StormController:GetNearbyCells(maxCount: number?)
	local character = LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		return {}
	end
	local origin = (root :: BasePart).Position

	local sorted = {}
	for _, cell in pairs(self._cells) do
		table.insert(sorted, {
			cell = cell,
			distance = (cell.position - origin).Magnitude,
		})
	end
	table.sort(sorted, function(a, b)
		return a.distance < b.distance
	end)

	local out = {}
	for index = 1, math.min(maxCount or 8, #sorted) do
		out[index] = sorted[index]
	end
	return out
end

function StormController:Destroy()
	self._maid:DoCleaning()
end

return StormController
