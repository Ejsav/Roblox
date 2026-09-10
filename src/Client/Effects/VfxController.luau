--!strict
--[[
	VfxController
	-------------
	All world-space visual effects: storm cells, strike telegraphs, lightning,
	capture bursts.

	Two constraints shape everything here.

	First, budget. A world with forty live cells could trivially emit ten thousand
	particles. Every effect is drawn from a pool, and the pools are sized by the
	player's quality tier, so a phone renders a smaller version of the same scene
	rather than a broken one.

	Second, readability. A storm is a gameplay object before it is a spectacle: the
	telegraph must be unambiguous about where and when. So the effects are built
	outward from a clear silhouette — a ring on the ground, a column of light, a
	countdown of contracting geometry — and the flourish is layered on top only where
	the budget allows.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")
local Debris = game:GetService("Debris")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BTS")
local Theme = require(Shared.Config.Theme)
local Balance = require(Shared.Config.Balance)
local StormTypes = require(Shared.Config.StormTypes)
local Maid = require(Shared.Core.Maid)
local MathUtil = require(Shared.Core.MathUtil)
local RNG = require(Shared.Core.RNG)

local VfxController = {}
VfxController.Name = "VfxController"
VfxController.Priority = 15

local LocalPlayer = Players.LocalPlayer

function VfxController:Init()
	self._maid = Maid.new()
	self._rng = RNG.new("vfx")
	self._quality = "high"
	self._budget = Balance.Performance.QUALITY_TIERS.high

	self._cellVisuals = {} :: { [string]: any }
	self._telegraphs = {} :: { [string]: any }
	self._boltPool = {}
	self._activeBolts = 0

	self._root = Instance.new("Folder")
	self._root.Name = "BTS_Effects"
	self._root.Parent = Workspace
	self._maid:Add(self._root)
end

function VfxController:Start()
	self._settings = self.Registry:Find("SettingsController")
end

--[[ Settings this controller owns. "auto" is left alone: the runtime tuner owns
     quality in that mode, and overriding it here would fight it every frame. ]]
function VfxController:ApplySettings(settings: any)
	if type(settings) ~= "table" then
		return
	end
	if settings.quality and settings.quality ~= "auto" then
		self:SetQuality(settings.quality)
	end
	if settings.reducedMotion ~= nil then
		self._reducedMotion = settings.reducedMotion == true
	end
end

function VfxController:SetQuality(quality: string)
	self._quality = quality
	self._budget = Balance.Performance.QUALITY_TIERS[quality] or Balance.Performance.QUALITY_TIERS.medium

	-- Existing effects are re-evaluated rather than left at the old budget, so a
	-- quality downgrade takes effect immediately when a device starts struggling.
	for _, visual in pairs(self._cellVisuals) do
		self:_applyCellQuality(visual)
	end
end

-- ============================================================================
-- Storm cells
-- ============================================================================

--[[
	A cell's visual: a slowly rotating charge cloud with a ground ring beneath it.
	The ring matters most — it is how a player judges whether they are inside the
	cell at all — so it is drawn even at the lowest quality.
]]
function VfxController:CreateStormCell(cell: any)
	if self._cellVisuals[cell.id] then
		return
	end

	local storm = StormTypes.ById[cell.stormTypeId]
	if not storm then
		return
	end

	local color = Theme.Rarity[storm.rarity] and Theme.Rarity[storm.rarity].color
		or Color3.fromRGB(123, 224, 255)
	-- The storm's own declared colour wins; rarity only fills in when absent.
	if storm.presentation.color then
		local hex = storm.presentation.color
		color = Color3.fromRGB(
			tonumber(hex:sub(1, 2), 16) or 123,
			tonumber(hex:sub(3, 4), 16) or 224,
			tonumber(hex:sub(5, 6), 16) or 255
		)
	end

	local model = Instance.new("Model")
	model.Name = "Cell_" .. cell.id
	model.Parent = self._root

	-- Ground ring: a flat cylinder marking the cell's footprint.
	local ring = Instance.new("Part")
	ring.Name = "Ring"
	ring.Shape = Enum.PartType.Cylinder
	ring.Size = Vector3.new(1, cell.radius * 2, cell.radius * 2)
	ring.CFrame = CFrame.new(cell.position) * CFrame.Angles(0, 0, math.rad(90))
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanQuery = false
	ring.CanTouch = false
	ring.CastShadow = false
	ring.Material = Enum.Material.Neon
	ring.Color = color
	ring.Transparency = 0.88
	ring.Parent = model

	-- Core: the body of the cell, scaled by the storm's presentation scale.
	local core = Instance.new("Part")
	core.Name = "Core"
	core.Shape = Enum.PartType.Ball
	core.Size = Vector3.one * (18 * (storm.presentation.scale or 1))
	core.Position = cell.position
	core.Anchored = true
	core.CanCollide = false
	core.CanQuery = false
	core.CanTouch = false
	core.CastShadow = false
	core.Material = Enum.Material.Neon
	core.Color = color
	core.Transparency = 0.55
	core.Parent = model
	model.PrimaryPart = core

	local light = Instance.new("PointLight")
	light.Color = color
	light.Brightness = 4
	light.Range = math.min(120, cell.radius * 1.4)
	light.Shadows = false
	light.Parent = core

	local visual = {
		cellId = cell.id,
		model = model,
		ring = ring,
		core = core,
		light = light,
		color = color,
		storm = storm,
		phase = self._rng:NextNumber() * math.pi * 2,
		emitters = {},
	}

	self._cellVisuals[cell.id] = visual
	self:_applyCellQuality(visual)
end

--[[ Adds or removes the optional layers according to the current budget. ]]
function VfxController:_applyCellQuality(visual: any)
	local wantEmitter = self._budget.maxParticleEmitters > 20
	local hasEmitter = visual.emitters.charge ~= nil

	if wantEmitter and not hasEmitter then
		local attachment = Instance.new("Attachment")
		attachment.Parent = visual.core

		local emitter = Instance.new("ParticleEmitter")
		emitter.Color = ColorSequence.new(visual.color)
		emitter.LightEmission = 1
		emitter.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(0.3, 2.5),
			NumberSequenceKeypoint.new(1, 0),
		})
		emitter.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.25, 0.3),
			NumberSequenceKeypoint.new(1, 1),
		})
		emitter.Lifetime = NumberRange.new(0.6, 1.6)
		emitter.Rate = self._quality == "ultra" and 40 or 18
		emitter.Speed = NumberRange.new(4, 14)
		emitter.SpreadAngle = Vector2.new(180, 180)
		emitter.Parent = attachment

		visual.emitters.charge = emitter
		visual.emitters.attachment = attachment
	elseif not wantEmitter and hasEmitter then
		visual.emitters.charge:Destroy()
		visual.emitters.attachment:Destroy()
		visual.emitters.charge = nil
		visual.emitters.attachment = nil
	end

	visual.light.Enabled = self._budget.maxLights > 6
end

function VfxController:UpdateStormCell(cell: any)
	local visual = self._cellVisuals[cell.id]
	if not visual then
		return
	end

	visual.core.Position = cell.position
	visual.ring.CFrame = CFrame.new(cell.position) * CFrame.Angles(0, 0, math.rad(90))

	-- A depleted cell visibly dims, which tells a player to move on without any UI.
	local chargeFraction = cell.maxCharge > 0 and (cell.charge / cell.maxCharge) or 1
	visual.core.Transparency = MathUtil.Lerp(0.85, 0.5, chargeFraction)
	visual.light.Brightness = MathUtil.Lerp(1, 4, chargeFraction)

	-- A predatory cell that has marked the local player gets an unmistakable colour.
	if cell.targetUserId == LocalPlayer.UserId then
		visual.core.Color = Theme.Color.danger
		visual.light.Color = Theme.Color.danger
	else
		visual.core.Color = visual.color
		visual.light.Color = visual.color
	end
end

function VfxController:RemoveStormCell(cellId: string)
	local visual = self._cellVisuals[cellId]
	if not visual then
		return
	end
	self._cellVisuals[cellId] = nil

	-- Fade out rather than vanish, so a cell expiring reads as dissipation.
	TweenService:Create(visual.core, Theme.Tween("slow"), { Transparency = 1, Size = Vector3.one }):Play()
	TweenService:Create(visual.ring, Theme.Tween("slow"), { Transparency = 1 }):Play()
	Debris:AddItem(visual.model, Theme.Duration.slow + 0.1)
end

-- ============================================================================
-- Telegraphs
-- ============================================================================

--[[
	A strike telegraph: a ground ring that contracts toward its centre, plus a
	vertical beam. The contraction IS the timing information, so it is animated
	from the strike's own timestamps rather than a tween, which keeps it exact even
	if a frame is dropped.
]]
function VfxController:CreateTelegraph(strike: any)
	if self._telegraphs[strike.id] then
		return
	end

	local storm = StormTypes.ById[strike.stormTypeId]
	local hex = storm and storm.presentation.color or "7BE0FF"
	local color = Color3.fromRGB(
		tonumber(hex:sub(1, 2), 16) or 123,
		tonumber(hex:sub(3, 4), 16) or 224,
		tonumber(hex:sub(5, 6), 16) or 255
	)

	-- An inverted strike is drawn in the danger colour and inverts its animation,
	-- so the player has two independent signals that the rules changed.
	if strike.inverted then
		color = Theme.Color.danger
	end

	local model = Instance.new("Model")
	model.Name = "Telegraph_" .. strike.id
	model.Parent = self._root

	local outer = Instance.new("Part")
	outer.Name = "Outer"
	outer.Shape = Enum.PartType.Cylinder
	outer.Size = Vector3.new(0.4, strike.radius * 3, strike.radius * 3)
	outer.CFrame = CFrame.new(strike.position) * CFrame.Angles(0, 0, math.rad(90))
	outer.Anchored = true
	outer.CanCollide = false
	outer.CanQuery = false
	outer.CanTouch = false
	outer.CastShadow = false
	outer.Material = Enum.Material.Neon
	outer.Color = color
	outer.Transparency = 0.7
	outer.Parent = model

	local target = Instance.new("Part")
	target.Name = "Target"
	target.Shape = Enum.PartType.Cylinder
	target.Size = Vector3.new(0.5, strike.radius * 2, strike.radius * 2)
	target.CFrame = CFrame.new(strike.position) * CFrame.Angles(0, 0, math.rad(90))
	target.Anchored = true
	target.CanCollide = false
	target.CanQuery = false
	target.CanTouch = false
	target.CastShadow = false
	target.Material = Enum.Material.Neon
	target.Color = color
	target.Transparency = 0.85
	target.Parent = model

	local beam = Instance.new("Part")
	beam.Name = "Beam"
	beam.Size = Vector3.new(strike.radius * 0.35, 300, strike.radius * 0.35)
	beam.Position = strike.position + Vector3.new(0, 150, 0)
	beam.Anchored = true
	beam.CanCollide = false
	beam.CanQuery = false
	beam.CanTouch = false
	beam.CastShadow = false
	beam.Material = Enum.Material.Neon
	beam.Color = color
	beam.Transparency = 0.92
	beam.Parent = model

	self._telegraphs[strike.id] = {
		strike = strike,
		model = model,
		outer = outer,
		target = target,
		beam = beam,
		color = color,
	}
end

--[[ Advances every live telegraph. Called from the render loop. ]]
function VfxController:_updateTelegraphs()
	local now = Workspace:GetServerTimeNow()

	for strikeId, telegraph in pairs(self._telegraphs) do
		local strike = telegraph.strike
		local total = strike.peakAt - strike.telegraphAt
		local progress = total > 0 and math.clamp((now - strike.telegraphAt) / total, 0, 1.3) or 1

		-- Follow a moving strike so the ring is always where the capture is tested.
		local position = strike.position
		local data = strike.data
		if data then
			local elapsed = math.max(0, now - strike.telegraphAt)
			if data.drift then
				position = data.origin + data.direction * math.min(data.speed * elapsed, data.distance)
			elseif data.line then
				position = data.origin + data.direction * math.min(data.speed * elapsed, data.length or 1e6)
			end
		end

		local diameter = MathUtil.Lerp(strike.radius * 3, strike.radius * 2, math.clamp(progress, 0, 1))
		telegraph.outer.Size = Vector3.new(0.4, diameter, diameter)
		telegraph.outer.CFrame = CFrame.new(position) * CFrame.Angles(0, 0, math.rad(90))
		telegraph.target.CFrame = telegraph.outer.CFrame

		-- Brightness ramps toward the peak, which is the pre-attentive cue that
		-- makes a telegraph readable in peripheral vision.
		local intensity = MathUtil.Ease.InQuad(math.clamp(progress, 0, 1))
		telegraph.outer.Transparency = MathUtil.Lerp(0.75, 0.25, intensity)
		telegraph.beam.Transparency = MathUtil.Lerp(0.95, 0.55, intensity)
		telegraph.beam.Position = position + Vector3.new(0, 150, 0)

		-- Null Pocket inverts: the beam goes dark and silent at the moment a normal
		-- strike would be brightest.
		if strike.inverted then
			telegraph.beam.Transparency = MathUtil.Lerp(0.55, 0.98, intensity)
		end
	end
end

function VfxController:ResolveTelegraph(strike: any, captured: boolean)
	local telegraph = self._telegraphs[strike.id]
	if not telegraph then
		return
	end
	self._telegraphs[strike.id] = nil

	if not captured and not strike.inverted then
		self:SpawnLightning(strike.position + Vector3.new(0, 260, 0), strike.position, telegraph.color)
	end

	TweenService:Create(telegraph.outer, Theme.Tween("fast"), { Transparency = 1 }):Play()
	TweenService:Create(telegraph.target, Theme.Tween("fast"), { Transparency = 1 }):Play()
	TweenService:Create(telegraph.beam, Theme.Tween("fast"), { Transparency = 1 }):Play()
	Debris:AddItem(telegraph.model, 0.3)
end

--[[ A non-capturable demonstration flash, used by Echo Bloom's teaching phase. ]]
function VfxController:PlayDemonstration(payload: any)
	local marker = Instance.new("Part")
	marker.Shape = Enum.PartType.Ball
	marker.Size = Vector3.one * 8
	marker.Position = payload.position
	marker.Anchored = true
	marker.CanCollide = false
	marker.CanQuery = false
	marker.CastShadow = false
	marker.Material = Enum.Material.Neon
	marker.Color = Theme.Color.warning
	marker.Transparency = 0.2
	marker.Parent = self._root

	TweenService:Create(marker, TweenInfo.new(payload.duration or 0.6), {
		Transparency = 1,
		Size = Vector3.one * 20,
	}):Play()
	Debris:AddItem(marker, (payload.duration or 0.6) + 0.1)
end

-- ============================================================================
-- Lightning
-- ============================================================================

--[[
	A lightning bolt drawn as a chain of segments with lateral jitter.
	Segment count comes from the quality budget, so the same bolt is eight segments
	on a phone and forty-four on a desktop and reads correctly either way.
]]
function VfxController:SpawnLightning(from: Vector3, to: Vector3, color: Color3?)
	if self._activeBolts >= (self._budget.maxBoltSegments > 0 and 12 or 4) then
		return
	end
	self._activeBolts += 1

	local segments = self._budget.maxBoltSegments
	local boltColor = color or Theme.Color.energy

	local model = Instance.new("Model")
	model.Name = "Bolt"
	model.Parent = self._root

	local delta = to - from
	local direction = delta.Unit
	local length = delta.Magnitude
	local segmentLength = length / segments

	-- A perpendicular basis for the jitter, so the bolt wanders in a plane facing
	-- roughly toward the camera rather than into the ground.
	local perpendicular = direction:Cross(Vector3.yAxis)
	if perpendicular.Magnitude < 0.01 then
		perpendicular = direction:Cross(Vector3.xAxis)
	end
	perpendicular = perpendicular.Unit
	local binormal = direction:Cross(perpendicular).Unit

	local previous = from
	for index = 1, segments do
		local t = index / segments
		local straight = from + direction * (segmentLength * index)

		-- Jitter is largest in the middle and zero at both ends, so the bolt starts
		-- and lands exactly where it should.
		local wander = math.sin(t * math.pi) * length * 0.035
		local offset = perpendicular * self._rng:NextRange(-wander, wander)
			+ binormal * self._rng:NextRange(-wander, wander)
		local point = index == segments and to or (straight + offset)

		local segmentDelta = point - previous
		local segment = Instance.new("Part")
		segment.Size = Vector3.new(0.8, 0.8, segmentDelta.Magnitude)
		segment.CFrame = CFrame.lookAt(previous + segmentDelta * 0.5, point)
		segment.Anchored = true
		segment.CanCollide = false
		segment.CanQuery = false
		segment.CanTouch = false
		segment.CastShadow = false
		segment.Material = Enum.Material.Neon
		segment.Color = boltColor
		segment.Transparency = 0.05
		segment.Parent = model

		previous = point
	end

	-- A brief flash at the impact point sells the arrival.
	if self._budget.maxLights > 4 then
		local flash = Instance.new("Part")
		flash.Shape = Enum.PartType.Ball
		flash.Size = Vector3.one * 4
		flash.Position = to
		flash.Anchored = true
		flash.CanCollide = false
		flash.CanQuery = false
		flash.CastShadow = false
		flash.Material = Enum.Material.Neon
		flash.Color = boltColor
		flash.Transparency = 0.1
		flash.Parent = model

		local light = Instance.new("PointLight")
		light.Color = boltColor
		light.Brightness = 12
		light.Range = 70
		light.Shadows = false
		light.Parent = flash

		TweenService:Create(flash, Theme.Tween("normal"), { Size = Vector3.one * 26, Transparency = 1 }):Play()
		TweenService:Create(light, Theme.Tween("normal"), { Brightness = 0 }):Play()
	end

	-- Fade the whole bolt out fast; lightning that lingers looks like a laser.
	task.delay(0.06, function()
		for _, part in ipairs(model:GetChildren()) do
			if part:IsA("BasePart") then
				TweenService:Create(part, Theme.Tween("fast"), { Transparency = 1 }):Play()
			end
		end
	end)

	Debris:AddItem(model, 0.4)
	task.delay(0.4, function()
		self._activeBolts -= 1
	end)
end

-- ============================================================================
-- Capture feedback
-- ============================================================================

function VfxController:PlayCapturePress(strike: any, predictedGrade: string?)
	-- Immediate local feedback at the press, before the server answers.
	local character = LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		return
	end

	local color = Theme.GradeColor(predictedGrade)
	self:SpawnLightning(strike.position, (root :: BasePart).Position + Vector3.new(0, 3, 0), color)
end

function VfxController:PlayCaptureSuccess(result: any)
	local character = LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		return
	end

	local origin = (root :: BasePart).Position
	local color = Theme.GradeColor(result.grade)

	-- A burst whose size scales with the grade, so an Overcharge is visibly an
	-- Overcharge from across the map.
	local scale = result.grade == "Overcharge" and 2.2
		or (result.grade == "Perfect" and 1.5 or 1.0)

	local burst = Instance.new("Part")
	burst.Shape = Enum.PartType.Ball
	burst.Size = Vector3.one * 3
	burst.Position = origin
	burst.Anchored = true
	burst.CanCollide = false
	burst.CanQuery = false
	burst.CastShadow = false
	burst.Material = Enum.Material.Neon
	burst.Color = color
	burst.Transparency = 0.2
	burst.Parent = self._root

	TweenService:Create(burst, Theme.Tween("slow", "standard"), {
		Size = Vector3.one * (22 * scale),
		Transparency = 1,
	}):Play()
	Debris:AddItem(burst, Theme.Duration.slow + 0.1)

	if self._budget.maxLights > 4 then
		local light = Instance.new("PointLight")
		light.Color = color
		light.Brightness = 8 * scale
		light.Range = 50 * scale
		light.Shadows = false
		light.Parent = burst
		TweenService:Create(light, Theme.Tween("slow"), { Brightness = 0 }):Play()
	end
end

function VfxController:PlayCaptureFail(result: any)
	if result.reason == "no_target" then
		return
	end

	local character = LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		return
	end

	-- A short, sharp red pulse at the player. Failure feedback is deliberately
	-- smaller than success feedback: the HUD already says what went wrong.
	local pulse = Instance.new("Part")
	pulse.Shape = Enum.PartType.Ball
	pulse.Size = Vector3.one * 6
	pulse.Position = (root :: BasePart).Position
	pulse.Anchored = true
	pulse.CanCollide = false
	pulse.CanQuery = false
	pulse.CastShadow = false
	pulse.Material = Enum.Material.Neon
	pulse.Color = Theme.Color.danger
	pulse.Transparency = 0.5
	pulse.Parent = self._root

	TweenService:Create(pulse, Theme.Tween("fast"), { Size = Vector3.one * 12, Transparency = 1 }):Play()
	Debris:AddItem(pulse, 0.3)
end

-- ============================================================================
-- Frame update
-- ============================================================================

function VfxController:Update(deltaTime: number)
	self:_updateTelegraphs()

	-- Idle animation on cells: a slow bob and pulse so a cell never looks frozen.
	local now = os.clock()
	for _, visual in pairs(self._cellVisuals) do
		local wave = math.sin(now * 1.4 + visual.phase)
		visual.core.Size = Vector3.one * (18 * (visual.storm.presentation.scale or 1)) * (1 + wave * 0.06)
		visual.ring.Transparency = 0.88 + wave * 0.04
	end
end

function VfxController:GetStats()
	local cellCount = 0
	for _ in pairs(self._cellVisuals) do
		cellCount += 1
	end
	local telegraphCount = 0
	for _ in pairs(self._telegraphs) do
		telegraphCount += 1
	end
	return { cells = cellCount, telegraphs = telegraphCount, bolts = self._activeBolts, quality = self._quality }
end

function VfxController:Destroy()
	self._maid:DoCleaning()
end

return VfxController
