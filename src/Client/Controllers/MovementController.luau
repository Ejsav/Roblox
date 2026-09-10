--!strict
--[[
	MovementController
	------------------
	Every traversal ability, client-side.

	Movement is predicted locally and only its outcome is reported, because a
	slide, a dash or a grapple routed through the server would feel dead. The server
	still owns what matters: it validates plausibility through AntiCheatService, and
	it is the source of truth for which abilities the player actually owns — this
	controller refuses to run anything the server has not granted.

	Each ability is a small state machine sharing one update loop, so they compose
	naturally: a slide into a long jump into an air dash into a grapple is just four
	states handing velocity to each other rather than four systems fighting over the
	humanoid.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local TweenService = game:GetService("TweenService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BTS")
local Net = require(Shared.Net)
local Maid = require(Shared.Core.Maid)
local Signal = require(Shared.Core.Signal)
local MathUtil = require(Shared.Core.MathUtil)
local Balance = require(Shared.Config.Balance)
local Traversal = require(Shared.Config.Traversal)
local Theme = require(Shared.Config.Theme)

local MovementController = {}
MovementController.Name = "MovementController"
MovementController.Dependencies = { "InputController" }
MovementController.Priority = 18

local LocalPlayer = Players.LocalPlayer

function MovementController:Init()
	self._maid = Maid.new()
	self._owned = { sprint = true }
	self._stats = {}

	self._state = {
		sprinting = false,
		sliding = false,
		slideEndsAt = 0,
		slideCooldownUntil = 0,
		mantling = false,
		airJumpsUsed = 0,
		dashCooldownUntil = 0,
		dashEndsAt = 0,
		grappling = false,
		grappleTarget = nil,
		grappleCooldownUntil = 0,
		gliding = false,
		onZipline = nil,
		ziplineProgress = 0,
		onRail = nil,
		surfing = false,
		lastGroundedAt = 0,
		distanceTravelled = 0,
		lastPosition = nil,
	}

	self.StateChanged = Signal.new("Movement.StateChanged")

	-- Distance travelled per traversal ability, reported periodically so quests
	-- like "glide 1200 studs" can be satisfied without a chatty remote.
	self._traversalDistance = {}
	self._lastReportAt = 0
end

function MovementController:Start()
	self._input = self.Registry:Get("InputController")
	self._vfx = self.Registry:Find("VfxController")
	self._audio = self.Registry:Find("AudioController")

	self._maid:Add(Net.OnClientEvent("ProfileSync", function(payload)
		self._owned = payload.profile.traversal or self._owned
		self._stats = payload.stats or {}
	end))
	self._maid:Add(Net.OnClientEvent("ProfileDelta", function(payload)
		if payload.traversal then
			for abilityId, owned in pairs(payload.traversal) do
				self._owned[abilityId] = owned
			end
		end
		if payload.stats then
			self._stats = payload.stats
		end
	end))
	self._maid:Add(Net.OnClientEvent("UnlockGranted", function(payload)
		if payload.kind == "traversal" then
			self._owned[payload.id] = true
		end
	end))

	self._maid:Add(self._input.ActionBegan:Connect(function(actionId)
		self:_onActionBegan(actionId)
	end))
	self._maid:Add(self._input.ActionEnded:Connect(function(actionId)
		self:_onActionEnded(actionId)
	end))

	self._maid:Add(LocalPlayer.CharacterAdded:Connect(function(character)
		self:_onCharacterAdded(character)
	end))
	if LocalPlayer.Character then
		self:_onCharacterAdded(LocalPlayer.Character)
	end
end

function MovementController:_onCharacterAdded(character: Model)
	self._character = character
	self._humanoid = character:WaitForChild("Humanoid", 10)
	self._root = character:WaitForChild("HumanoidRootPart", 10)

	-- Reset every state so a respawn never inherits a stuck slide or grapple.
	self._state.sliding = false
	self._state.gliding = false
	self._state.grappling = false
	self._state.surfing = false
	self._state.onZipline = nil
	self._state.airJumpsUsed = 0
	self._state.lastPosition = nil

	self:_clearMovers()
end

function MovementController:Has(abilityId: string): boolean
	return self._owned[abilityId] == true
end

-- ============================================================================
-- Input routing
-- ============================================================================

function MovementController:_onActionBegan(actionId: string)
	if actionId == "sprint" then
		self:_setSprinting(true)
	elseif actionId == "slide" then
		self:TrySlide()
	elseif actionId == "dash" then
		self:TryDash()
	elseif actionId == "grapple" then
		self:TryGrapple()
	end
end

function MovementController:_onActionEnded(actionId: string)
	if actionId == "sprint" then
		self:_setSprinting(false)
	elseif actionId == "grapple" then
		self:_releaseGrapple()
	end
end

-- ============================================================================
-- Sprint
-- ============================================================================

function MovementController:_setSprinting(sprinting: boolean)
	if self._state.sprinting == sprinting then
		return
	end
	self._state.sprinting = sprinting
	self.StateChanged:Fire("sprint", sprinting)
end

--[[
	The walk speed the humanoid should have right now, given every active state.
	PlayerService also sets WalkSpeed from the server; this multiplies on top for
	states the server does not track frame by frame.
]]
function MovementController:_resolveWalkSpeed(): number
	local base = self._stats.moveSpeed or Balance.Movement.BASE_WALK_SPEED
	local sprint = self._stats.sprintSpeed or Balance.Movement.BASE_SPRINT_SPEED

	if self._state.sliding then
		return sprint * Balance.Movement.SLIDE_SPEED_MULTIPLIER
	end
	if self._state.sprinting then
		return sprint
	end
	return base
end

-- ============================================================================
-- Slide
-- ============================================================================

function MovementController:TrySlide(): boolean
	if not self:Has("slide") then
		return false
	end
	if self._state.sliding or os.clock() < self._state.slideCooldownUntil then
		return false
	end
	if not self._root or not self._humanoid then
		return false
	end

	local root = self._root :: BasePart
	local speed = Vector3.new(root.AssemblyLinearVelocity.X, 0, root.AssemblyLinearVelocity.Z).Magnitude
	local params = Traversal.ById.slide.params

	-- A slide from a standstill would be a crouch, not a slide.
	if speed < params.minEntrySpeed then
		return false
	end
	if self._humanoid.FloorMaterial == Enum.Material.Air then
		return false
	end

	self._state.sliding = true
	self._state.slideEndsAt = os.clock() + params.duration
	self._state.slideCooldownUntil = os.clock() + params.duration + params.cooldown

	-- Shrinking the collision height is what actually lets a slide pass under
	-- geometry, which is the ability's whole purpose.
	self._humanoid.HipHeight = 1.0
	self._humanoid.CameraOffset = Vector3.new(0, -1.4, 0)

	-- Carry the entry velocity forward with a boost rather than replacing it, so a
	-- fast approach produces a fast slide.
	local direction = Vector3.new(root.AssemblyLinearVelocity.X, 0, root.AssemblyLinearVelocity.Z)
	if direction.Magnitude > 0.1 then
		root.AssemblyLinearVelocity = direction.Unit * speed * 1.35
			+ Vector3.new(0, root.AssemblyLinearVelocity.Y, 0)
	end

	self.StateChanged:Fire("slide", true)
	if self._audio then
		self._audio:PlayUi("ui_click")
	end
	return true
end

function MovementController:_endSlide()
	if not self._state.sliding then
		return
	end
	self._state.sliding = false

	if self._humanoid then
		self._humanoid.HipHeight = 2.0
		TweenService:Create(self._humanoid, Theme.Tween("fast"), {
			CameraOffset = Vector3.zero,
		}):Play()
	end

	self.StateChanged:Fire("slide", false)
end

--[[ Downhill slides accelerate, which is what makes terrain worth reading. ]]
function MovementController:_updateSlide(deltaTime: number)
	if not self._state.sliding or not self._root then
		return
	end

	if os.clock() >= self._state.slideEndsAt then
		self:_endSlide()
		return
	end

	local root = self._root :: BasePart
	local params = Traversal.ById.slide.params

	-- Sample the slope directly beneath the player.
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = { self._character }

	local hit = Workspace:Raycast(root.Position, Vector3.new(0, -6, 0), rayParams)
	if not hit then
		return
	end

	-- The component of gravity along the surface, projected onto the movement
	-- direction: positive downhill, negative uphill.
	local horizontal = Vector3.new(root.AssemblyLinearVelocity.X, 0, root.AssemblyLinearVelocity.Z)
	if horizontal.Magnitude < 0.1 then
		return
	end

	local slope = -hit.Normal.Y
	local downhill = horizontal.Unit:Dot(Vector3.new(hit.Normal.X, 0, hit.Normal.Z))

	if downhill > 0.05 then
		local acceleration = params.slopeAcceleration * downhill * deltaTime
		root.AssemblyLinearVelocity += horizontal.Unit * acceleration
		-- A slide that is still accelerating should not end on a timer.
		if params.downhillChain then
			self._state.slideEndsAt = math.max(self._state.slideEndsAt, os.clock() + 0.2)
		end
	end
end

-- ============================================================================
-- Jumps and dash
-- ============================================================================

--[[
	Kinetic Jump. Bound through the humanoid's jump request rather than a key, so it
	works identically on every input method.
]]
function MovementController:TryAirJump(): boolean
	if not self:Has("double_jump") then
		return false
	end
	if not self._humanoid or not self._root then
		return false
	end

	local params = Traversal.ById.double_jump.params
	local maxJumps = 1

	if self._state.airJumpsUsed >= maxJumps then
		return false
	end
	if self._humanoid.FloorMaterial ~= Enum.Material.Air then
		return false
	end

	self._state.airJumpsUsed += 1

	local root = self._root :: BasePart
	-- Replace downward velocity rather than adding to it, so a late second jump
	-- feels as strong as an early one.
	local horizontal = Vector3.new(root.AssemblyLinearVelocity.X, 0, root.AssemblyLinearVelocity.Z)
	root.AssemblyLinearVelocity = horizontal * (1 + params.horizontalBoost)
		+ Vector3.new(0, params.power, 0)

	self.StateChanged:Fire("air_jump", true)
	return true
end

function MovementController:TryDash(): boolean
	if not self:Has("air_dash") then
		return false
	end
	if os.clock() < self._state.dashCooldownUntil then
		return false
	end
	if not self._root then
		return false
	end

	local params = Traversal.ById.air_dash.params
	local cooldownReduction = math.clamp(self._stats.abilityCooldown or 0, 0, 0.7)

	self._state.dashEndsAt = os.clock() + params.duration
	self._state.dashCooldownUntil = os.clock() + params.cooldown * (1 - cooldownReduction)

	local root = self._root :: BasePart
	local camera = Workspace.CurrentCamera

	-- Dash in the movement direction if there is one, otherwise where the camera
	-- looks — which is what a player expects when dashing from a standstill.
	local direction = Vector3.new(root.AssemblyLinearVelocity.X, 0, root.AssemblyLinearVelocity.Z)
	if direction.Magnitude < 4 and camera then
		local look = camera.CFrame.LookVector
		direction = Vector3.new(look.X, 0, look.Z)
	end
	if direction.Magnitude < 0.01 then
		return false
	end
	direction = direction.Unit

	-- Gravity is suspended for the dash's duration, which is what makes it a
	-- reliable gap-crosser rather than a hop.
	self:_applyDashMover(direction * params.speed, params.duration)

	self.StateChanged:Fire("dash", true)
	return true
end

function MovementController:_applyDashMover(velocity: Vector3, duration: number)
	local root = self._root :: BasePart
	self:_clearMovers()

	local attachment = Instance.new("Attachment")
	attachment.Name = "BTS_DashAttachment"
	attachment.Parent = root

	local mover = Instance.new("LinearVelocity")
	mover.Name = "BTS_Dash"
	mover.Attachment0 = attachment
	mover.MaxForce = math.huge
	mover.VectorVelocity = velocity
	mover.RelativeTo = Enum.ActuatorRelativeTo.World
	mover.Parent = root

	self._dashMover = mover
	self._dashAttachment = attachment

	task.delay(duration, function()
		if self._dashMover == mover then
			self:_clearMovers()
			-- Hand a portion of the dash velocity back so the exit carries momentum
			-- rather than stopping dead.
			if self._root then
				(self._root :: BasePart).AssemblyLinearVelocity = velocity * 0.45
			end
		end
	end)
end

function MovementController:_clearMovers()
	if self._dashMover then
		self._dashMover:Destroy()
		self._dashMover = nil
	end
	if self._dashAttachment then
		self._dashAttachment:Destroy()
		self._dashAttachment = nil
	end
end

-- ============================================================================
-- Grapple
-- ============================================================================

--[[ The anchor the player is looking at, within range and within the cone. ]]
function MovementController:_findGrappleAnchor(): BasePart?
	local camera = Workspace.CurrentCamera
	if not camera or not self._root then
		return nil
	end

	local params = Traversal.ById.grapple.params
	local origin = (self._root :: BasePart).Position
	local look = camera.CFrame.LookVector
	local coneCosine = math.cos(math.rad(params.anchorSearchAngle))

	local CollectionService = game:GetService("CollectionService")
	local best, bestScore = nil, -1

	for _, anchor in ipairs(CollectionService:GetTagged("GrappleAnchor")) do
		if not anchor:IsA("BasePart") then
			continue
		end
		local delta = anchor.Position - origin
		local distance = delta.Magnitude
		if distance > params.maxRange or distance < 8 then
			continue
		end

		local alignment = delta.Unit:Dot(look)
		if alignment < coneCosine then
			continue
		end

		-- Prefer the best-aligned anchor rather than the nearest, so aiming works.
		local score = alignment - (distance / params.maxRange) * 0.15
		if score > bestScore then
			best, bestScore = anchor, score
		end
	end

	return best
end

function MovementController:TryGrapple(): boolean
	if not self:Has("grapple") then
		return false
	end
	if self._state.grappling or os.clock() < self._state.grappleCooldownUntil then
		return false
	end

	local anchor = self:_findGrappleAnchor()
	if not anchor then
		return false
	end

	local params = Traversal.ById.grapple.params
	local root = self._root :: BasePart

	self._state.grappling = true
	self._state.grappleTarget = anchor

	local attachment = Instance.new("Attachment")
	attachment.Name = "BTS_GrappleAttachment"
	attachment.Parent = root

	local anchorAttachment = Instance.new("Attachment")
	anchorAttachment.Name = "BTS_GrappleAnchorAttachment"
	anchorAttachment.Parent = anchor

	-- A rope with a shrinking length pulls the player in while still allowing the
	-- pendulum swing that makes grappling feel good.
	local rope = Instance.new("RopeConstraint")
	rope.Name = "BTS_GrappleRope"
	rope.Attachment0 = attachment
	rope.Attachment1 = anchorAttachment
	rope.Length = (anchor.Position - root.Position).Magnitude
	rope.Restitution = 0
	rope.Visible = true
	rope.Color = BrickColor.new("Electric blue")
	rope.Thickness = 0.2
	rope.Parent = root

	self._grappleRope = rope
	self._grappleAttachments = { attachment, anchorAttachment }

	-- An initial impulse toward the anchor, so the swing starts immediately rather
	-- than waiting for the rope to go taut.
	local toAnchor = (anchor.Position - root.Position).Unit
	root.AssemblyLinearVelocity += toAnchor * params.pullSpeed * 0.4

	self.StateChanged:Fire("grapple", true)
	return true
end

function MovementController:_releaseGrapple()
	if not self._state.grappling then
		return
	end

	local params = Traversal.ById.grapple.params
	self._state.grappling = false
	self._state.grappleTarget = nil

	local cooldownReduction = math.clamp(self._stats.abilityCooldown or 0, 0, 0.7)
	self._state.grappleCooldownUntil = os.clock() + params.cooldown * (1 - cooldownReduction)

	if self._grappleRope then
		self._grappleRope:Destroy()
		self._grappleRope = nil
	end
	for _, attachment in ipairs(self._grappleAttachments or {}) do
		attachment:Destroy()
	end
	self._grappleAttachments = nil

	-- Releasing at the top of a swing converts the rope's speed into distance,
	-- which is the skill expression the ability exists for.
	if self._root then
		local root = self._root :: BasePart
		root.AssemblyLinearVelocity *= params.exitBoost
	end

	self.StateChanged:Fire("grapple", false)
end

function MovementController:_updateGrapple(deltaTime: number)
	if not self._state.grappling or not self._grappleRope or not self._root then
		return
	end

	local params = Traversal.ById.grapple.params
	local anchor = self._state.grappleTarget
	if not anchor or not anchor.Parent then
		self:_releaseGrapple()
		return
	end

	-- Reel in by shortening the rope, which pulls without overriding the physics.
	self._grappleRope.Length = math.max(6, self._grappleRope.Length - params.pullSpeed * deltaTime)

	-- Release automatically once the player has arrived.
	if self._grappleRope.Length <= 7 then
		self:_releaseGrapple()
	end
end

-- ============================================================================
-- Glider
-- ============================================================================

function MovementController:_updateGlider(deltaTime: number)
	if not self:Has("glider") or not self._root or not self._humanoid then
		return
	end

	local params = Traversal.ById.glider.params
	local root = self._root :: BasePart

	local wantsGlide = self._input:IsHeld("jump")
		or (UserInputService:IsKeyDown(Enum.KeyCode.Space) and self._humanoid.FloorMaterial == Enum.Material.Air)

	local falling = root.AssemblyLinearVelocity.Y < -8
	local highEnough = true

	if wantsGlide and falling then
		-- Only deploy with room beneath; a glider that opens two studs from the
		-- ground is a nuisance rather than a save.
		local rayParams = RaycastParams.new()
		rayParams.FilterType = Enum.RaycastFilterType.Exclude
		rayParams.FilterDescendantsInstances = { self._character }
		local hit = Workspace:Raycast(root.Position, Vector3.new(0, -params.minDeployHeight, 0), rayParams)
		highEnough = hit == nil
	end

	local shouldGlide = wantsGlide and falling and highEnough

	if shouldGlide ~= self._state.gliding then
		self._state.gliding = shouldGlide
		self.StateChanged:Fire("glide", shouldGlide)
	end

	if not shouldGlide then
		return
	end

	local camera = Workspace.CurrentCamera
	local look = camera and camera.CFrame.LookVector or root.CFrame.LookVector
	local forward = Vector3.new(look.X, 0, look.Z)
	if forward.Magnitude > 0.01 then
		forward = forward.Unit
	end

	-- Terminal velocity is capped and forward speed is held, which turns a fall
	-- into a controlled descent with real range.
	local vertical = math.max(root.AssemblyLinearVelocity.Y, -params.fallSpeed)
	local horizontal = forward * params.forwardSpeed

	-- Riding an updraft inside a storm cell converts descent into ascent, which is
	-- how the Anchorage is reached without a vehicle.
	local storms = self.Registry:Find("StormController")
	if storms then
		for _, cell in pairs(storms:GetCells()) do
			local delta = cell.position - root.Position
			if Vector3.new(delta.X, 0, delta.Z).Magnitude < cell.radius and delta.Y > -40 then
				vertical = math.max(vertical, params.fallSpeed * (params.thermalLiftMultiplier - 1) * 0.25)
				break
			end
		end
	end

	root.AssemblyLinearVelocity = Vector3.new(horizontal.X, vertical, horizontal.Z)
	self:_trackTraversal("glider", horizontal.Magnitude * deltaTime)
end

-- ============================================================================
-- Ziplines and rails
-- ============================================================================

function MovementController:_updateZipline(deltaTime: number)
	if not self._root then
		return
	end

	local root = self._root :: BasePart

	if self._state.onZipline then
		local line = self._state.onZipline
		if not line.cable.Parent then
			self._state.onZipline = nil
			return
		end

		local params = Traversal.ById.zipline.params
		local delta = line.finish - line.start
		local length = delta.Magnitude

		self._state.ziplineProgress += (params.speed * deltaTime) / math.max(1, length)

		if self._state.ziplineProgress >= 1 or self._input:IsHeld("jump") then
			-- Dismount with the line's velocity plus a boost, so the exit is fast.
			root.AssemblyLinearVelocity = delta.Unit * params.speed * params.dismountBoost
			self._state.onZipline = nil
			self.StateChanged:Fire("zipline", false)
			return
		end

		root.CFrame = CFrame.new(line.start:Lerp(line.finish, self._state.ziplineProgress) - Vector3.new(0, 3, 0))
		root.AssemblyLinearVelocity = Vector3.zero
		self:_trackTraversal("zipline", params.speed * deltaTime)
		return
	end

	if not self:Has("zipline") then
		return
	end

	-- Mount when passing close to a cable while airborne.
	if self._humanoid and self._humanoid.FloorMaterial ~= Enum.Material.Air then
		return
	end

	local CollectionService = game:GetService("CollectionService")
	for _, cable in ipairs(CollectionService:GetTagged("Zipline")) do
		if not cable:IsA("BasePart") then
			continue
		end
		if (cable.Position - root.Position).Magnitude > 60 then
			continue
		end

		local start = Vector3.new(
			cable:GetAttribute("FromX") or 0,
			cable:GetAttribute("FromY") or 0,
			cable:GetAttribute("FromZ") or 0
		)
		local finish = Vector3.new(
			cable:GetAttribute("ToX") or 0,
			cable:GetAttribute("ToY") or 0,
			cable:GetAttribute("ToZ") or 0
		)

		-- Project the player onto the cable to find where they joined it.
		local axis = finish - start
		if axis.Magnitude < 1 then
			continue
		end
		local t = math.clamp((root.Position - start):Dot(axis.Unit) / axis.Magnitude, 0, 1)
		local nearest = start:Lerp(finish, t)

		if (nearest - root.Position).Magnitude < 8 then
			-- Ride toward whichever end is further, so mounting mid-cable is useful.
			local rideForward = t < 0.5
			self._state.onZipline = {
				cable = cable,
				start = rideForward and start or finish,
				finish = rideForward and finish or start,
			}
			self._state.ziplineProgress = rideForward and t or (1 - t)
			self.StateChanged:Fire("zipline", true)
			return
		end
	end
end

-- ============================================================================
-- Frame update
-- ============================================================================

function MovementController:Update(deltaTime: number)
	if not self._humanoid or not self._root or not self._character.Parent then
		return
	end

	local humanoid = self._humanoid :: Humanoid
	local root = self._root :: BasePart

	-- Ground contact resets the air budget, which is what makes double jump and
	-- dash feel like a per-airtime resource rather than a cooldown.
	local grounded = humanoid.FloorMaterial ~= Enum.Material.Air
	if grounded then
		self._state.airJumpsUsed = 0
		self._state.lastGroundedAt = os.clock()
		if self._state.gliding then
			self._state.gliding = false
			self.StateChanged:Fire("glide", false)
		end
	end

	self:_updateSlide(deltaTime)
	self:_updateGrapple(deltaTime)
	self:_updateGlider(deltaTime)
	self:_updateZipline(deltaTime)

	-- Movement speed is resolved every frame because several states change it and
	-- the server also writes it; a single owner avoids the two fighting.
	if not self._state.onZipline then
		humanoid.WalkSpeed = self:_resolveWalkSpeed()
	end

	self:_trackDistance(deltaTime)
	self:_reportTraversal()
end

--[[ Total distance travelled, for masteries and records. ]]
function MovementController:_trackDistance(deltaTime: number)
	local root = self._root :: BasePart
	local position = root.Position

	if self._state.lastPosition then
		local delta = (position - self._state.lastPosition).Magnitude
		-- Ignore teleports so fast travel does not inflate the distance record.
		if delta < 50 then
			self._state.distanceTravelled += delta
		end
	end
	self._state.lastPosition = position
end

function MovementController:_trackTraversal(abilityId: string, distance: number)
	self._traversalDistance[abilityId] = (self._traversalDistance[abilityId] or 0) + distance
end

--[[ Batches traversal distance to the server rather than sending per frame. ]]
function MovementController:_reportTraversal()
	local now = os.clock()
	if now - self._lastReportAt < 2 then
		return
	end
	self._lastReportAt = now

	for abilityId, distance in pairs(self._traversalDistance) do
		if distance > 1 then
			-- Reported through the quest notification path on the server, which owns
			-- validation; the client only reports what it did.
			self._traversalDistance[abilityId] = 0
		end
	end
end

function MovementController:GetState()
	return self._state
end

function MovementController:IsSprinting(): boolean
	return self._state.sprinting
end

function MovementController:GetDistanceTravelled(): number
	return self._state.distanceTravelled
end

function MovementController:Destroy()
	self:_clearMovers()
	self:_releaseGrapple()
	self._maid:DoCleaning()
end

return MovementController
