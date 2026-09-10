--!strict
--[[
	Abilities
	---------
	Active and passive abilities. Actives occupy one of four equippable slots; passives
	are always-on and come from skill nodes, equipment traits and prestige.

	Slot discipline: four active slots, hard cap. Players will earn far more than four
	abilities, and being forced to choose is the point — it is where a build stops
	being a stat sheet and starts being an identity.

	Every active declares `tags` so equipment and skills can modify whole classes of
	ability ("all Emergency abilities recharge 30% faster") without enumerating ids.
]]

local TableUtil = require(script.Parent.Parent.Core.TableUtil)

local Abilities = {}

Abilities.SLOT_COUNT = 4

Abilities.Tags = {
	MOVEMENT = "movement",
	OFFENSE = "offense",
	DEFENSE = "defense",
	EMERGENCY = "emergency",
	ECONOMY = "economy",
	TEAM = "team",
	CAPTURE = "capture",
	RISK = "risk",
}

-- ============================================================================
-- ACTIVE ABILITIES
-- ============================================================================

Abilities.Actives = {
	{
		id = "purge",
		name = "Manual Purge",
		tags = { "emergency", "defense" },
		description = "Vent instability instantly at the cost of a slice of your carry. The panic button that keeps runs alive.",
		icon = "purge",
		cooldown = 18,
		castTime = 0.35,
		unlockSource = { type = "upgrade", id = "stabiliser", level = 20 },
		effects = {
			instabilityRemoved = 0.55,
			energyCostFraction = 0.12,
			grantsBriefImmunity = 1.2,
		},
		scaling = { instabilityRemoved = { stat = "instabilityResist", perPoint = 0.3 } },
		vfx = "purge_burst",
		sound = "sfx_ability_purge",
	},

	{
		id = "surge",
		name = "Surge",
		tags = { "movement", "risk" },
		description = "Burn carried energy for a violent burst of speed. The more you burn, the further you go.",
		icon = "surge",
		cooldown = 12,
		castTime = 0,
		unlockSource = { type = "skill", id = "runner_surge" },
		effects = {
			duration = 5.0,
			speedMultiplier = 1.75,
			energyCostFraction = 0.08,
			jumpMultiplier = 1.25,
			leavesTrail = true,
		},
		scaling = { speedMultiplier = { stat = "sprintSpeed", perPoint = 0.004 } },
		vfx = "surge_trail",
		sound = "sfx_ability_surge",
	},

	{
		id = "emergency_extract",
		name = "Emergency Extract",
		tags = { "emergency", "economy" },
		description = "Teleport to the nearest bank station and deposit everything. Long cooldown, and it ends your chain.",
		icon = "extract",
		cooldown = 240,
		castTime = 2.5,
		interruptible = true,
		unlockSource = { type = "quest", id = "plains_close_call" },
		effects = {
			banksCarry = true,
			bankPenalty = 0.15,
			breaksChain = true,
			immuneDuringCast = true,
		},
		scaling = { bankPenalty = { stat = "bankRate", perPoint = -0.04, floor = 0 } },
		vfx = "extract_beam",
		sound = "sfx_ability_extract",
	},

	{
		id = "static_shield",
		name = "Static Shield",
		tags = { "defense" },
		description = "A grounded field that absorbs shock damage and suppresses instability while it holds.",
		icon = "shield",
		cooldown = 26,
		castTime = 0.2,
		unlockSource = { type = "skill", id = "survivor_static_shield" },
		effects = {
			duration = 7,
			damageAbsorbed = 140,
			instabilityFrozen = true,
			radius = 0,
		},
		scaling = { damageAbsorbed = { stat = "maxHealth", perPoint = 0.9 } },
		vfx = "shield_dome",
		sound = "sfx_ability_shield",
	},

	{
		id = "ground_anchor",
		name = "Ground Anchor",
		tags = { "defense", "capture" },
		description = "Drive an anchor into the ground. Nothing moves you, and every strike in range is drawn to it.",
		icon = "anchor",
		cooldown = 34,
		castTime = 0.6,
		unlockSource = { type = "skill", id = "vault_ground_anchor" },
		effects = {
			duration = 9,
			radius = 62,
			redirectsStrikes = true,
			knockbackImmunity = true,
			captureWindowBonus = 0.4,
			movementLocked = true,
		},
		scaling = { radius = { stat = "captureRadius", perPoint = 0.8 } },
		vfx = "anchor_spike",
		sound = "sfx_ability_anchor",
	},

	{
		id = "chain_link",
		name = "Chain Link",
		tags = { "capture", "offense" },
		description = "Your next capture arcs to every strike point within range and takes them all.",
		icon = "chain",
		cooldown = 40,
		castTime = 0,
		unlockSource = { type = "skill", id = "conductor_chain_link" },
		effects = {
			duration = 8,
			arcRange = 70,
			maxArcs = 4,
			arcYieldScale = 0.65,
			arcYieldFalloff = 0.85,
		},
		scaling = { maxArcs = { stat = "multiCapture", perPoint = 1 } },
		vfx = "chain_arc",
		sound = "sfx_ability_chain",
	},

	{
		id = "overclock",
		name = "Overclock",
		tags = { "capture", "risk" },
		description = "Double capture yield and halve the timing window. Pure skill expression, and it will punish you.",
		icon = "overclock",
		cooldown = 60,
		castTime = 0,
		unlockSource = { type = "skill", id = "conductor_overclock" },
		effects = {
			duration = 15,
			yieldMultiplier = 2.0,
			windowMultiplier = 0.5,
			instabilityMultiplier = 1.4,
			missPenaltyMultiplier = 2.0,
		},
		scaling = { duration = { stat = "captureWindow", perPoint = 3.0 } },
		vfx = "overclock_aura",
		sound = "sfx_ability_overclock",
	},

	{
		id = "beacon",
		name = "Relay Beacon",
		tags = { "team", "economy" },
		description = "Plant a beacon that lets every runner in range bank remotely and shares your scan data.",
		icon = "beacon",
		cooldown = 90,
		castTime = 1.2,
		unlockSource = { type = "skill", id = "support_relay_beacon" },
		effects = {
			duration = 45,
			radius = 130,
			enablesRemoteBank = true,
			remoteBankPenaltyReduction = 0.5,
			sharesScanData = true,
			alliesOnly = false,
		},
		scaling = { radius = { stat = "teamAura", perPoint = 40 } },
		vfx = "beacon_pillar",
		sound = "sfx_ability_beacon",
	},

	{
		id = "field_dome",
		name = "Field Dome",
		tags = { "team", "defense" },
		description = "A dome that suppresses instability and exposure damage for everyone standing inside it.",
		icon = "dome",
		cooldown = 75,
		castTime = 1.0,
		unlockSource = { type = "skill", id = "support_field_dome" },
		effects = {
			duration = 20,
			radius = 46,
			instabilityDecayRate = 0.22,
			exposureReduction = 0.85,
			healPerSecond = 3,
		},
		scaling = { radius = { stat = "teamAura", perPoint = 18 }, healPerSecond = { stat = "reviveSpeed", perPoint = 2 } },
		vfx = "dome_field",
		sound = "sfx_ability_dome",
	},

	{
		id = "scan_pulse",
		name = "Scan Pulse",
		tags = { "economy" },
		description = "A hard ping that reveals every storm, cache, anomaly and secret in a wide radius.",
		icon = "pulse",
		cooldown = 45,
		castTime = 0.4,
		unlockSource = { type = "skill", id = "hunter_scan_pulse" },
		effects = {
			radius = 900,
			revealDuration = 30,
			revealsSecrets = true,
			revealsRareStorms = true,
			revealsPlayerCaches = true,
		},
		scaling = { radius = { stat = "scanRange", perPoint = 1.4 } },
		vfx = "scan_ring",
		sound = "sfx_ability_scan",
	},

	{
		id = "storm_call",
		name = "Storm Call",
		tags = { "capture", "economy" },
		description = "Pull an inactive cell to your position and force it to discharge early.",
		icon = "call",
		cooldown = 150,
		castTime = 2.0,
		unlockSource = { type = "skill", id = "hunter_storm_call" },
		effects = {
			searchRadius = 1400,
			pullSpeed = 90,
			forcesEarlyStrike = true,
			cannotCallRarity = { "mythic", "exotic" },
			intensityBonus = 0.25,
		},
		scaling = { searchRadius = { stat = "scanRange", perPoint = 2.0 } },
		vfx = "call_summon",
		sound = "sfx_ability_call",
	},

	{
		id = "double_down",
		name = "Double Down",
		tags = { "risk", "economy" },
		description = "Stake your entire carry. Land the next capture perfectly and it doubles. Miss and you lose half.",
		icon = "gamble",
		cooldown = 55,
		castTime = 0,
		unlockSource = { type = "skill", id = "gambler_double_down" },
		effects = {
			windowSeconds = 12,
			successMultiplier = 2.0,
			failureLossFraction = 0.5,
			requiresGrade = "Perfect",
			stacksUpTo = 3,
		},
		scaling = { successMultiplier = { stat = "riskBonus", perPoint = 0.35 } },
		vfx = "gamble_mark",
		sound = "sfx_ability_gamble",
	},

	{
		id = "blink_step",
		name = "Blink Step",
		tags = { "movement", "emergency" },
		description = "Instantly relocate a short distance in the direction you are looking. Passes through anything thin.",
		icon = "blink",
		cooldown = 9,
		castTime = 0,
		unlockSource = { type = "skill", id = "runner_blink_step" },
		effects = {
			distance = 58,
			charges = 2,
			rechargePerCharge = 9,
			passesThroughThin = 6,
			iFrames = 0.2,
			preservesMomentum = true,
		},
		scaling = { distance = { stat = "moveSpeed", perPoint = 0.9 } },
		vfx = "blink_flash",
		sound = "sfx_ability_blink",
	},

	{
		id = "siphon",
		name = "Siphon",
		tags = { "offense", "economy" },
		description = "Drain energy directly from a live storm cell over time without waiting for a strike.",
		icon = "siphon",
		cooldown = 50,
		castTime = 0,
		channelled = true,
		unlockSource = { type = "skill", id = "conductor_siphon" },
		effects = {
			channelDuration = 6,
			energyPerSecond = 14,
			instabilityPerSecond = 0.06,
			depletesCellCharge = 2.5,
			breaksOnDamage = true,
			maxRange = 70,
		},
		scaling = { energyPerSecond = { stat = "captureYield", perPoint = 9 } },
		vfx = "siphon_tether",
		sound = "sfx_ability_siphon",
	},

	{
		id = "rally",
		name = "Rally",
		tags = { "team" },
		description = "Instantly revive every downed runner in range and grant the whole group a burst of speed.",
		icon = "rally",
		cooldown = 180,
		castTime = 1.5,
		unlockSource = { type = "skill", id = "support_rally" },
		effects = {
			radius = 90,
			revivesDowned = true,
			healFraction = 0.4,
			speedBoost = 0.35,
			boostDuration = 10,
		},
		scaling = { radius = { stat = "teamAura", perPoint = 30 } },
		vfx = "rally_wave",
		sound = "sfx_ability_rally",
	},

	{
		id = "bulwark_stance",
		name = "Bulwark Stance",
		tags = { "defense", "emergency" },
		description = "Root yourself and become nearly immovable. Damage is slashed, instability halts, movement stops.",
		icon = "bulwark",
		cooldown = 70,
		castTime = 0.3,
		unlockSource = { type = "skill", id = "survivor_bulwark" },
		effects = {
			duration = 8,
			damageReduction = 0.8,
			instabilityFrozen = true,
			movementLocked = true,
			reflectFraction = 0.25,
		},
		scaling = { damageReduction = { stat = "stormResist", perPoint = 0.12, cap = 0.92 } },
		vfx = "bulwark_shell",
		sound = "sfx_ability_bulwark",
	},
}

-- ============================================================================
-- PASSIVE ABILITIES
-- Always-on effects granted by skills, equipment traits and prestige ranks.
-- ============================================================================

Abilities.Passives = {
	{
		id = "second_wind",
		name = "Second Wind",
		description = "Dropping below a quarter integrity restores a burst of health. Once every ninety seconds.",
		trigger = "health_threshold",
		params = { threshold = 0.25, healFraction = 0.35, cooldown = 90 },
	},
	{
		id = "momentum_capture",
		name = "Momentum Capture",
		description = "Capturing while sprinting adds a stacking speed bonus that decays out of combat.",
		trigger = "on_capture",
		params = { requiresSprint = true, speedPerStack = 0.04, maxStacks = 8, decayDelay = 6 },
	},
	{
		id = "cold_start",
		name = "Cold Start",
		description = "The first capture after banking always counts as Perfect.",
		trigger = "on_capture",
		params = { onlyFirstAfterBank = true, forcedGrade = "Perfect" },
	},
	{
		id = "static_cling",
		name = "Static Cling",
		description = "Missed captures still recover a fifth of the energy instead of nothing.",
		trigger = "on_miss",
		params = { salvageFraction = 0.2 },
	},
	{
		id = "deep_pockets",
		name = "Deep Pockets",
		description = "Materials you collect no longer count against inventory space.",
		trigger = "passive",
		params = { materialsWeightless = true },
	},
	{
		id = "storm_reader",
		name = "Storm Reader",
		description = "Telegraph timing is displayed as a numeric countdown, not just a visual.",
		trigger = "passive",
		params = { showsNumericTiming = true },
	},
	{
		id = "opportunist",
		name = "Opportunist",
		description = "Capturing from a storm another runner is also working gives both of you a bonus.",
		trigger = "on_capture",
		params = { requiresNearbyPlayer = 60, bonusEach = 0.18 },
	},
	{
		id = "insulated_soles",
		name = "Insulated Soles",
		description = "Standing water and live metal no longer amplify damage taken.",
		trigger = "passive",
		params = { negatesConductiveGround = true },
	},
	{
		id = "scavenger_instinct",
		name = "Scavenger Instinct",
		description = "Undiscovered secrets within a hundred studs produce an audio cue.",
		trigger = "passive",
		params = { secretPingRadius = 100, pingInterval = 4 },
	},
	{
		id = "high_stakes",
		name = "High Stakes",
		description = "Carrying above 80% capacity grants a large yield bonus on every capture.",
		trigger = "passive",
		params = { fillThreshold = 0.8, yieldBonus = 0.4 },
	},
	{
		id = "grounded_recovery",
		name = "Grounded Recovery",
		description = "Standing still for two seconds drains instability rapidly.",
		trigger = "passive",
		params = { stillnessRequired = 2, decayRate = 0.18 },
	},
	{
		id = "line_walker",
		name = "Line Walker",
		description = "Ziplines and rails cost no insulation and grant a speed bonus on exit.",
		trigger = "passive",
		params = { exitBoost = 0.4, negatesRailDamage = true },
	},
	{
		id = "efficient_frame",
		name = "Efficient Frame",
		description = "Every active ability's cooldown is reduced.",
		trigger = "passive",
		params = { cooldownReduction = 0.15 },
	},
	{
		id = "gamblers_luck",
		name = "Gambler's Luck",
		description = "Failed gambles refund a portion of what they cost you.",
		trigger = "passive",
		params = { refundFraction = 0.3 },
	},
	{
		id = "conductor_mark",
		name = "Conductor's Mark",
		description = "Perfect captures mark the cell; every subsequent capture from it pays more.",
		trigger = "on_capture",
		params = { requiresGrade = "Perfect", markBonus = 0.12, maxStacks = 5, perCell = true },
	},
	{
		id = "unbroken",
		name = "Unbroken",
		description = "Your capture chain survives death once per run.",
		trigger = "on_death",
		params = { preservesChain = true, usesPerRun = 1 },
	},
}

-- ============================================================================
-- Lookups and helpers
-- ============================================================================

Abilities.ActiveById = {}
Abilities.PassiveById = {}
Abilities.ActivesByTag = {}

for _, ability in ipairs(Abilities.Actives) do
	Abilities.ActiveById[ability.id] = ability
	for _, tag in ipairs(ability.tags) do
		Abilities.ActivesByTag[tag] = Abilities.ActivesByTag[tag] or {}
		table.insert(Abilities.ActivesByTag[tag], ability.id)
	end
end

for _, passive in ipairs(Abilities.Passives) do
	Abilities.PassiveById[passive.id] = passive
end

function Abilities.GetActive(abilityId: string)
	return Abilities.ActiveById[abilityId]
end

function Abilities.GetPassive(passiveId: string)
	return Abilities.PassiveById[passiveId]
end

--[[
	Resolves an ability's effective cooldown for a given stat block, applying the
	global cooldown-reduction stat. Clamped so nothing becomes spammable.
]]
function Abilities.GetCooldown(abilityId: string, stats: { [string]: number }): number
	local ability = Abilities.ActiveById[abilityId]
	if not ability then
		return 0
	end
	local reduction = math.clamp(stats.abilityCooldown or 0, 0, 0.7)
	return math.max(ability.cooldown * (1 - reduction), ability.cooldown * 0.3)
end

--[[
	Resolves an ability's scaled effect values against a stat block. Returns a fresh
	table so callers can mutate it safely.
]]
function Abilities.ResolveEffects(abilityId: string, stats: { [string]: number }): { [string]: any }
	local ability = Abilities.ActiveById[abilityId]
	if not ability then
		return {}
	end
	local resolved = table.clone(ability.effects)
	if ability.scaling then
		for effectKey, rule in pairs(ability.scaling) do
			local statValue = stats[rule.stat] or 0
			local base = resolved[effectKey]
			if type(base) == "number" then
				local scaled = base + statValue * rule.perPoint
				if rule.cap then
					scaled = math.min(scaled, rule.cap)
				end
				if rule.floor then
					scaled = math.max(scaled, rule.floor)
				end
				resolved[effectKey] = scaled
			end
		end
	end
	return resolved
end

--[[ Validates a loadout: correct slot count, no duplicates, all owned. ]]
function Abilities.ValidateLoadout(loadout: { string }, owned: { [string]: boolean }): (boolean, string?)
	if #loadout > Abilities.SLOT_COUNT then
		return false, "too_many_abilities"
	end
	local seen = {}
	for _, abilityId in ipairs(loadout) do
		if not Abilities.ActiveById[abilityId] then
			return false, "unknown_ability:" .. tostring(abilityId)
		end
		if seen[abilityId] then
			return false, "duplicate_ability:" .. abilityId
		end
		if not owned[abilityId] then
			return false, "not_owned:" .. abilityId
		end
		seen[abilityId] = true
	end
	return true, nil
end

return TableUtil.DeepFreeze(Abilities)
