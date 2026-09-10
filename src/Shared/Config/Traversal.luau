--!strict
--[[
	Traversal
	---------
	Movement technology, in the order a player earns it.

	The governing rule: every entry must change *where the player can go*, not just how
	fast they get there. A pure speed increase is an upgrade track (see Upgrades.luau);
	this file is reserved for capabilities that open geometry which was previously
	closed. That is what makes returning to the Starter District at level 60 feel
	different rather than nostalgic.

	`gates` names the world features each ability opens, which the world generator uses
	to place traversal puzzles that are visibly solvable-but-not-yet.
]]

local TableUtil = require(script.Parent.Parent.Core.TableUtil)

local Traversal = {}

Traversal.List = {
	{
		id = "sprint",
		name = "Sprint",
		order = 1,
		description = "Hold to run. Available from the first second of the game.",
		unlockedByDefault = true,
		input = { keyboard = "LeftShift", gamepad = "ButtonL3", touch = "sprint_button" },
		params = {
			accelerationTime = 0.45,
			speedMultiplier = 1.6,
			fovBoost = 6,
		},
		gates = {},
		tutorial = "Hold Shift to move at speed. Distance is the enemy out here.",
	},

	{
		id = "slide",
		name = "Slide",
		order = 2,
		description = "Slide under obstacles and carry momentum down slopes.",
		unlockSource = { type = "upgrade", id = "actuators", level = 6 },
		input = { keyboard = "C", gamepad = "ButtonL3", touch = "slide_button" },
		params = {
			duration = 0.85,
			speedMultiplier = 1.55,
			cooldown = 1.1,
			minEntrySpeed = 20,
			hitboxHeightScale = 0.45,
			slopeAcceleration = 34,
			downhillChain = true,
		},
		gates = { "low_gap", "slide_tunnel", "momentum_ramp" },
		tutorial = "Slide while sprinting. Downhill slides keep building speed.",
	},

	{
		id = "vault",
		name = "Vault",
		order = 3,
		description = "Clear waist-height obstacles without breaking stride.",
		unlockSource = { type = "upgrade", id = "actuators", level = 14 },
		input = { automatic = true },
		params = {
			maxHeight = 5.5,
			minApproachSpeed = 14,
			duration = 0.3,
			exitSpeedRetention = 0.92,
		},
		gates = { "railing", "low_wall", "debris_line" },
		tutorial = "Run at low obstacles and you go over them now.",
	},

	{
		id = "mantle",
		name = "Mantle",
		order = 4,
		description = "Pull yourself onto ledges up to eleven studs above you.",
		unlockSource = { type = "upgrade", id = "actuators", level = 22 },
		input = { automatic = true, assist = "Space" },
		params = {
			maxHeight = 11,
			reachDistance = 4.5,
			duration = 0.45,
			allowFromWater = true,
		},
		gates = { "ledge_low", "catwalk_edge", "container_stack", "rooftop_lip" },
		tutorial = "Jump at a ledge and hold Space. You will pull yourself up.",
	},

	{
		id = "double_jump",
		name = "Kinetic Jump",
		order = 5,
		description = "A second launch in mid-air. Rewrites every gap in the world.",
		unlockSource = { type = "skill", id = "runner_kinetic_jump" },
		input = { keyboard = "Space", gamepad = "ButtonA", touch = "jump_button" },
		params = {
			power = 42,
			resetsOnWallTouch = true,
			resetsOnCapture = true,
			horizontalBoost = 0.35,
		},
		gates = { "gap_medium", "roof_hop", "pylon_crossing" },
		tutorial = "Jump again in the air. Capturing a strike resets it.",
	},

	{
		id = "air_dash",
		name = "Air Dash",
		order = 6,
		description = "A flat burst of horizontal speed mid-air, in any direction.",
		unlockSource = { type = "skill", id = "runner_air_dash" },
		input = { keyboard = "Q", gamepad = "ButtonR1", touch = "dash_button" },
		params = {
			speed = 78,
			duration = 0.24,
			cooldown = 3.2,
			charges = 1,
			ignoresGravityDuring = true,
			iFramesDuration = 0.12,
		},
		gates = { "gap_long", "hazard_crossing", "wasteland_spine_hop" },
		tutorial = "Dash mid-air to cross gaps nothing else can cross. It also dodges.",
	},

	{
		id = "grapple",
		name = "Grapple Line",
		order = 7,
		description = "Fire a conductive line at marked anchors and pull yourself in.",
		unlockSource = { type = "quest", id = "city_the_line" },
		input = { keyboard = "E", gamepad = "ButtonR2", touch = "grapple_button" },
		params = {
			maxRange = 190,
			pullSpeed = 96,
			cooldown = 4.5,
			requiresAnchor = true,
			anchorSearchAngle = 22,
			swingEnabled = true,
			swingDamping = 0.985,
			exitBoost = 1.25,
		},
		gates = { "anchor_point", "tower_ascent", "chasm_crossing", "rooftop_chain" },
		tutorial = "Look at a glowing anchor and press E. Release at the top of a swing for distance.",
	},

	{
		id = "zipline",
		name = "Zip Runner",
		order = 8,
		description = "Ride the transmission and service lines that run through every region.",
		unlockSource = { type = "quest", id = "deep_the_long_cable" },
		input = { automatic = true },
		params = {
			speed = 88,
			canReverse = true,
			dismountBoost = 1.15,
			canFireNewLine = false,
			bidirectional = true,
		},
		gates = { "zipline_run", "cable_descent", "cross_region_line" },
		tutorial = "Jump onto any cable. You will ride it. Jump off whenever you like.",
	},

	{
		id = "glider",
		name = "Storm Glider",
		order = 9,
		description = "Deploy a wing and convert altitude into distance.",
		unlockSource = { type = "quest", id = "mountain_the_long_fall" },
		input = { keyboard = "Space (hold in air)", gamepad = "ButtonA (hold)", touch = "glide_button" },
		params = {
			fallSpeed = 22,
			forwardSpeed = 62,
			turnRate = 1.8,
			minDeployHeight = 25,
			thermalLiftMultiplier = 2.4,
			stallAngle = 55,
			collapsesInStorm = false,
		},
		gates = { "long_descent", "island_crossing", "thermal_ride", "high_altitude_approach" },
		tutorial = "Hold Space while falling. Ride updrafts to gain height instead of losing it.",
	},

	{
		id = "rail",
		name = "Charge Rail",
		order = 10,
		description = "Grind the electrified rail network at speeds nothing on foot approaches.",
		unlockSource = { type = "quest", id = "grid_third_rail" },
		input = { automatic = true },
		params = {
			speed = 132,
			accelerationTime = 1.2,
			requiresInsulation = 0.25,
			damageWithoutInsulation = 22,
			jumpBetweenRails = true,
			boostPads = true,
		},
		gates = { "rail_network", "grid_express", "core_approach_rail" },
		tutorial = "Land on a live rail. If your insulation is rated for it, you ride. If not, it hurts.",
	},

	{
		id = "storm_surf",
		name = "Storm Surf",
		order = 11,
		description = "Ride the pressure front of an active storm cell. Fast, free, and it destabilises you the whole time.",
		unlockSource = { type = "quest", id = "high_riding_the_front" },
		input = { keyboard = "F (inside a cell)", gamepad = "ButtonY", touch = "surf_button" },
		params = {
			liftSpeed = 54,
			driftSpeed = 70,
			instabilityPerSecond = 0.045,
			requiresActiveCell = true,
			cellRadiusTolerance = 1.35,
			steeringAuthority = 0.8,
			captureWhileSurfing = true,
			surfCaptureBonus = 0.25,
		},
		gates = { "storm_bridge", "core_wall_crossing", "cloud_layer" },
		tutorial = "Inside a live cell, press F. The storm carries you — and charges you the whole way.",
	},

	{
		id = "fast_travel",
		name = "Relay Transit",
		order = 12,
		description = "Instant travel between discovered relay stations.",
		unlockSource = { type = "quest", id = "plains_the_long_road" },
		input = { menu = "map" },
		params = {
			requiresDiscovery = true,
			cooldown = 25,
			blockedWhileCarrying = false,
			carryPenalty = 0.0,
			blockedInCombat = true,
		},
		gates = {},
		tutorial = "Open the map and select any relay you have visited.",
	},

	{
		id = "prestige_phase",
		name = "Phase Step",
		order = 13,
		description = "Step briefly out of the world. Pass through matter and hazards alike.",
		unlockSource = { type = "prestige", rank = 1 },
		input = { keyboard = "R", gamepad = "ButtonL2", touch = "phase_button" },
		params = {
			duration = 1.1,
			cooldown = 14,
			speedMultiplier = 1.4,
			passesThroughGeometry = true,
			immuneDuring = true,
			instabilityCost = 0.06,
			maxThickness = 24,
		},
		gates = { "sealed_door", "null_barrier", "inverted_wall" },
		tutorial = "Press R to step sideways out of reality. Doors stop meaning anything.",
	},
}

Traversal.ById = {}
Traversal.Order = {}
Traversal.GateToAbility = {}

for _, ability in ipairs(Traversal.List) do
	Traversal.ById[ability.id] = ability
	table.insert(Traversal.Order, ability.id)
	for _, gate in ipairs(ability.gates) do
		Traversal.GateToAbility[gate] = ability.id
	end
end

function Traversal.Get(abilityId: string)
	return Traversal.ById[abilityId]
end

--[[ Traversal abilities the player starts with, before any progression. ]]
function Traversal.GetDefaults(): { [string]: boolean }
	local defaults = {}
	for _, ability in ipairs(Traversal.List) do
		if ability.unlockedByDefault then
			defaults[ability.id] = true
		end
	end
	return defaults
end

--[[
	Which traversal ability opens a given world gate, and whether the player has it.
	The world generator tags obstacles with gate ids; the client uses this to render
	a "you cannot do this yet" hint that names the actual ability.
]]
function Traversal.CanPassGate(gateId: string, owned: { [string]: boolean }): (boolean, string?)
	local abilityId = Traversal.GateToAbility[gateId]
	if not abilityId then
		return true, nil
	end
	if owned[abilityId] then
		return true, abilityId
	end
	return false, abilityId
end

--[[ Ordered list of traversal abilities the player does not yet have. ]]
function Traversal.GetLocked(owned: { [string]: boolean }): { any }
	local locked = {}
	for _, ability in ipairs(Traversal.List) do
		if not owned[ability.id] then
			table.insert(locked, ability)
		end
	end
	return locked
end

--[[ The next traversal ability in order that the player has not unlocked. ]]
function Traversal.GetNext(owned: { [string]: boolean }): any?
	for _, ability in ipairs(Traversal.List) do
		if not owned[ability.id] then
			return ability
		end
	end
	return nil
end

return TableUtil.DeepFreeze(Traversal)
