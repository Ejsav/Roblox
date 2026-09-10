--!strict
--[[
	Balance
	-------
	Every globally-tunable number in BORROW THE STORM lives here. Systems read from
	this table rather than embedding literals, so retuning the game is a single-file
	operation and a designer can reason about the whole economy in one place.

	Organising principle: constants are grouped by the loop stage they affect, in the
	order the player experiences them — Capture, Carry, Bank, Progress.
]]

local TableUtil = require(script.Parent.Parent.Core.TableUtil)

local Balance = {}

-- ============================================================================
-- CAPTURE — reading a storm and taking its energy
-- ============================================================================

Balance.Capture = {
	-- A strike telegraphs, peaks, then discharges. The player must trigger capture
	-- during the window centred on the peak.
	-- Windup is deliberately generous at low tiers: a new player should land their
	-- first capture within a couple of attempts without being told the timing.
	BASE_WINDUP_SECONDS = 2.1,
	MIN_WINDUP_SECONDS = 0.55,

	-- Half-width of the capture window as a fraction of total strike duration.
	-- Grade bands are nested inside it.
	BASE_WINDOW_HALF_WIDTH = 0.30,
	MIN_WINDOW_HALF_WIDTH = 0.075,

	-- Grade thresholds, expressed as normalised distance from the perfect moment
	-- (0 = dead centre, 1 = window edge). Checked in order, best first.
	GRADES = {
		{ id = "Overcharge", maxDistance = 0.06, yieldScale = 1.75, xpScale = 2.2, chainValue = 2 },
		{ id = "Perfect", maxDistance = 0.20, yieldScale = 1.35, xpScale = 1.6, chainValue = 1 },
		{ id = "Good", maxDistance = 0.52, yieldScale = 1.00, xpScale = 1.0, chainValue = 1 },
		{ id = "Weak", maxDistance = 1.00, yieldScale = 0.55, xpScale = 0.5, chainValue = 0 },
	},

	-- Missing entirely: the strike discharges into the player.
	MISS_SHOCK_DAMAGE = 14,
	MISS_INSTABILITY_ADD = 0.08,

	-- How close the player must be to the strike point, in studs.
	BASE_CAPTURE_RADIUS = 34,
	MAX_CAPTURE_RADIUS = 96,

	-- Server-side validation slack. The client reports its press time; the server
	-- recomputes the grade from its own clock and rejects anything outside this.
	MAX_LATENCY_COMPENSATION = 0.22,
	MAX_POSITION_ERROR_STUDS = 18,

	-- A chain is a run of captures with no bank in between. Breaking it (banking,
	-- dying, or letting the timer lapse) resets the counter.
	CHAIN_TIMEOUT_SECONDS = 45,
	CHAIN_SOFT_CAP = 40,

	-- Cooldown between capture attempts, preventing input spam from fishing for a
	-- lucky server-side grade.
	ATTEMPT_COOLDOWN = 0.35,
}

-- ============================================================================
-- CARRY — the tension between "I have energy" and "I still have energy"
-- ============================================================================

Balance.Carry = {
	-- Starting containment. Every point of carried energy above this is refused.
	BASE_CAPACITY = 120,

	-- Instability climbs while carrying and is THE pressure mechanic. It scales with
	-- how full you are: at 50% capacity it barely moves, at 100% it races.
	-- rate = BASE + CURVE * (fill ^ EXPONENT)
	INSTABILITY_BASE_RATE = 0.004,
	INSTABILITY_CURVE_RATE = 0.055,
	INSTABILITY_EXPONENT = 2.4,

	-- Above this instability the HUD goes red and audio distorts.
	INSTABILITY_WARNING = 0.62,
	INSTABILITY_CRITICAL = 0.85,

	-- Reaching 1.0 vents: a violent discharge that costs energy and health but does
	-- not wipe the run. Losing everything to a timer would feel arbitrary.
	VENT_ENERGY_LOSS_FRACTION = 0.35,
	VENT_DAMAGE = 26,
	VENT_INSTABILITY_AFTER = 0.30,
	VENT_STAGGER_SECONDS = 1.4,

	-- Instability decays while standing in a stabilised zone (bank stations, safe
	-- rooms, restored infrastructure).
	SAFE_ZONE_DECAY_RATE = 0.28,

	-- Death drops a portion of carried energy as a recoverable cache at the death
	-- site. The rest is gone. Insurance upgrades shift this split.
	DEATH_LOSS_FRACTION = 0.55,
	DEATH_CACHE_FRACTION = 0.30,
	DEATH_CACHE_LIFETIME = 240,
	DEATH_CACHE_RECOVERY_RADIUS = 12,
}

-- ============================================================================
-- BANK — converting risk into permanent value
-- ============================================================================

Balance.Bank = {
	-- Watts awarded per unit of energy banked, before multipliers.
	WATTS_PER_ENERGY = 1.0,

	-- XP awarded per unit of energy banked.
	XP_PER_ENERGY = 0.42,

	-- Banking takes time; the animation is a commitment, not an instant button.
	BANK_DURATION = 1.15,
	BANK_INTERRUPT_REFUND = true,

	-- Remote banking (unlocked mid-game) trades a cut for not having to walk back.
	REMOTE_BANK_PENALTY = 0.28,
	REMOTE_BANK_COOLDOWN = 90,

	-- Banking a chain of N captures pays the risk multiplier on the whole carry.
	-- See MathUtil.RiskMultiplier for the curve itself.
	RISK_BONUS_SCALE = 1.0,

	-- Banking within this many seconds of a capture keeps a small "hot bank" bonus,
	-- rewarding decisive play over cautious shuffling.
	HOT_BANK_WINDOW = 12,
	HOT_BANK_BONUS = 0.06,
}

-- ============================================================================
-- PROGRESS — levels, currencies, prestige
-- ============================================================================

Balance.Progression = {
	MAX_LEVEL = 120,
	MAX_PRESTIGE = 12,

	-- Level-ups award a skill point; every fifth level awards two.
	SKILL_POINTS_PER_LEVEL = 1,
	SKILL_POINT_BONUS_INTERVAL = 5,
	SKILL_POINT_BONUS_AMOUNT = 1,

	-- Prestige requires reaching the cap AND clearing the Storm Core questline; a
	-- level gate alone would let players prestige without seeing the content.
	PRESTIGE_LEVEL_REQUIREMENT = 120,
	PRESTIGE_QUEST_REQUIREMENT = "core_the_eye",

	-- What survives a prestige. Everything else resets.
	PRESTIGE_KEEPS = {
		"collections",
		"achievements",
		"records",
		"cosmetics",
		"discoveries",
		"masteryLevels",
		"prestigeSkills",
		"legendaryEquipment",
	},

	-- Each prestige rank permanently multiplies baseline yield and unlocks a tier of
	-- the prestige tree.
	PRESTIGE_YIELD_BONUS_PER_RANK = 0.08,
	PRESTIGE_SIGILS_PER_RANK = 3,
}

Balance.Currency = {
	-- id -> presentation and rules. Order drives HUD display order.
	WATTS = { id = "watts", order = 1, cap = 1e12, softCapWarning = 1e9 },
	CORES = { id = "cores", order = 2, cap = 500000 },
	SIGILS = { id = "sigils", order = 3, cap = 9999 },
}

-- ============================================================================
-- MOVEMENT — the feel of getting there
-- ============================================================================

Balance.Movement = {
	BASE_WALK_SPEED = 16,
	BASE_SPRINT_SPEED = 26,
	BASE_JUMP_POWER = 50,

	SPRINT_ACCELERATION = 22,
	SPRINT_STAMINA_DRAIN = 0,          -- stamina-free by design; sprint is not a resource
	SLIDE_DURATION = 0.85,
	SLIDE_SPEED_MULTIPLIER = 1.55,
	SLIDE_COOLDOWN = 1.1,
	SLIDE_MIN_ENTRY_SPEED = 20,

	VAULT_MAX_HEIGHT = 5.5,
	MANTLE_MAX_HEIGHT = 11,
	MANTLE_DURATION = 0.45,

	AIR_DASH_SPEED = 78,
	AIR_DASH_DURATION = 0.24,
	AIR_DASH_COOLDOWN = 3.2,

	DOUBLE_JUMP_POWER = 42,

	GRAPPLE_MAX_RANGE = 190,
	GRAPPLE_PULL_SPEED = 96,
	GRAPPLE_COOLDOWN = 4.5,

	GLIDER_FALL_SPEED = 22,
	GLIDER_FORWARD_SPEED = 62,
	GLIDER_TURN_RATE = 1.8,

	ZIPLINE_SPEED = 88,
	RAIL_SPEED = 132,

	-- Storm surfing: riding an updraft inside an active storm cell.
	SURF_LIFT_SPEED = 54,
	SURF_DRIFT_SPEED = 70,
	SURF_INSTABILITY_RATE = 0.045,

	-- Carrying heavy energy slows you down. This is the Vault build's core tradeoff.
	CARRY_SPEED_PENALTY_AT_FULL = 0.22,
}

-- ============================================================================
-- COMBAT / SURVIVAL
-- ============================================================================

Balance.Survival = {
	BASE_MAX_HEALTH = 100,
	HEALTH_REGEN_DELAY = 6,
	HEALTH_REGEN_RATE = 4.5,

	-- Storm exposure: standing in a region above your resistance rating.
	EXPOSURE_TICK_INTERVAL = 1.0,
	EXPOSURE_BASE_DAMAGE = 5,
	EXPOSURE_DAMAGE_PER_DANGER = 3.4,

	-- Resistance is a 0..1 fraction of exposure damage negated, capped so no build
	-- can ignore a region outright.
	MAX_RESISTANCE = 0.82,

	FALL_DAMAGE_THRESHOLD = 60,
	FALL_DAMAGE_PER_STUD = 1.35,

	RESPAWN_INVULNERABILITY = 3.0,
	DOWNED_DURATION = 18,             -- window for a teammate to revive
	REVIVE_DURATION = 3.5,
	REVIVE_RADIUS = 10,
}

-- ============================================================================
-- LOOT & RARITY
-- ============================================================================

Balance.Loot = {
	-- Rarity id -> weight at baseline luck, plus presentation rank.
	RARITY_ORDER = { "common", "uncommon", "rare", "epic", "legendary", "mythic", "exotic" },

	RARITY_BASE_WEIGHTS = {
		common = 1000,
		uncommon = 380,
		rare = 118,
		epic = 31,
		legendary = 6.2,
		mythic = 0.85,
		exotic = 0.09,
	},

	-- Luck shifts weight from common toward rare. Applied as weight * (1 + luck * tilt).
	RARITY_LUCK_TILT = {
		common = -0.35,
		uncommon = -0.05,
		rare = 0.45,
		epic = 0.9,
		legendary = 1.6,
		mythic = 2.4,
		exotic = 3.2,
	},

	-- Bad-luck protection: every roll without a rare-or-better raises the floor.
	PITY_INCREMENT = 0.012,
	PITY_CAP = 0.45,
	PITY_RESET_RARITIES = { "epic", "legendary", "mythic", "exotic" },

	-- Modifier count by rarity: how many random affixes an item rolls.
	MODIFIER_COUNTS = {
		common = { min = 0, max = 1 },
		uncommon = { min = 1, max = 2 },
		rare = { min = 2, max = 3 },
		epic = { min = 3, max = 4 },
		legendary = { min = 4, max = 5 },
		mythic = { min = 5, max = 6 },
		exotic = { min = 4, max = 5 },  -- exotics trade affix count for a unique trait
	},

	-- Global drop chance per successful capture, before storm-type and region scaling.
	BASE_DROP_CHANCE = 0.085,
	OVERCHARGE_DROP_BONUS = 0.055,

	MAX_INVENTORY_SLOTS = 220,
	DISMANTLE_RETURN_FRACTION = 0.32,
}

-- ============================================================================
-- STORM SIMULATION
-- ============================================================================

Balance.Storms = {
	-- Global caps protect the server; per-region caps live in Regions.luau.
	MAX_ACTIVE_CELLS_GLOBAL = 46,
	MIN_CELL_SEPARATION = 220,

	-- Cells live, migrate and die. Migration is what makes the world feel weathered
	-- rather than a set of fixed spawn points.
	CELL_LIFETIME_RANGE = { min = 95, max = 260 },
	CELL_DRIFT_SPEED_RANGE = { min = 2.5, max = 11 },

	-- Strike cadence inside a live cell.
	STRIKE_INTERVAL_RANGE = { min = 2.6, max = 7.5 },
	-- How strongly a cell's intensity compresses the gap between its strikes.
	-- Higher values make a dangerous region feel fast rather than merely damaging.
	STRIKE_INTERVAL_SCALE_FALLBACK = 0.55,

	-- A cell's charge pool depletes as players take from it, then recovers. This
	-- stops a single cell being farmed indefinitely by one player.
	CHARGE_REGEN_PER_SECOND = 0.9,
	CHARGE_DEPLETION_PER_CAPTURE = 1.0,

	-- Simulation LOD: cells far from every player tick at a coarse rate.
	SIM_NEAR_DISTANCE = 700,
	SIM_FAR_DISTANCE = 2400,
	SIM_NEAR_RATE = 1 / 20,
	SIM_MID_RATE = 1 / 6,
	SIM_FAR_RATE = 1 / 2,

	-- Rare storm announcement radius; beyond this a player only sees it on the map
	-- if they have detection upgrades.
	RARE_BROADCAST_RADIUS = 3200,
}

-- ============================================================================
-- WORLD EVENTS
-- ============================================================================

Balance.Events = {
	MIN_INTERVAL = 420,
	MAX_INTERVAL = 900,
	MIN_PLAYERS_FOR_MAJOR = 3,
	WARNING_LEAD_TIME = 45,
	MAX_CONCURRENT = 2,

	-- Participation is measured in contribution points; rewards scale with share of
	-- the total, floored so late joiners still get something worth having.
	MIN_REWARD_SHARE = 0.15,
	TOP_CONTRIBUTOR_BONUS = 0.35,
}

-- ============================================================================
-- NETWORKING & SECURITY
-- ============================================================================

--[[
	PARTIES

	Four, because the storm mechanics that need more than one player (chained
	captures, containment relays, the three-runner Core Pulse) all top out around
	three, and a fourth seat means a group of friends never has to leave someone
	out. Beyond that a party stops being a group and becomes a crowd standing on
	the same strike.
]]
Balance.Party = {
	MAX_SIZE = 4,

	-- How close a member must be to share in the party's benefits, in studs. Wide
	-- enough that runners taking different lines through a region stay together,
	-- tight enough that a member idling at the bank contributes nothing.
	SHARE_RADIUS = 320,

	-- Bonus experience per additional nearby member. Deliberately modest: playing
	-- together should be worth doing, never mandatory to keep pace.
	XP_BONUS_PER_MEMBER = 0.08,
	MAX_XP_BONUS = 0.24,

	-- Loot found by a nearby member gives everyone else a small extra roll chance.
	SHARED_LUCK_PER_MEMBER = 0.04,

	INVITE_EXPIRY_SECONDS = 60,
	MAX_PENDING_INVITES = 6,
}

Balance.Network = {
	-- Per-remote rate limits: { budget, refillPerSecond }. Exceeding the budget drops
	-- the request and increments a suspicion counter.
	DEFAULT_RATE_LIMIT = { budget = 20, refill = 10 },

	STATE_SYNC_INTERVAL = 0.2,
	NEARBY_STORM_SYNC_INTERVAL = 0.35,
	LEADERBOARD_SYNC_INTERVAL = 30,

	-- Suspicion decays over time; sustained abuse escalates.
	SUSPICION_DECAY_PER_SECOND = 0.25,
	SUSPICION_KICK_THRESHOLD = 120,
	SUSPICION_LOG_THRESHOLD = 40,

	-- Maximum plausible movement speed used by the teleport check, in studs/second.
	MAX_PLAUSIBLE_SPEED = 340,
	TELEPORT_GRACE_SECONDS = 1.5,
}

Balance.Data = {
	AUTOSAVE_INTERVAL = 120,
	AUTOSAVE_JITTER = 30,
	SAVE_RETRY_ATTEMPTS = 5,
	SAVE_RETRY_BACKOFF = 2.0,
	SESSION_LOCK_TIMEOUT = 90,
	SESSION_LOCK_REFRESH = 30,
	MAX_LOAD_ATTEMPTS = 4,
	CURRENT_SCHEMA_VERSION = 7,
}

-- ============================================================================
-- PERFORMANCE BUDGETS
-- ============================================================================

Balance.Performance = {
	-- Client effect budgets by quality tier. The VFX layer degrades gracefully
	-- rather than dropping frames.
	QUALITY_TIERS = {
		low = { maxParticleEmitters = 14, maxLights = 4, maxBoltSegments = 8, shadowsEnabled = false },
		medium = { maxParticleEmitters = 34, maxLights = 10, maxBoltSegments = 16, shadowsEnabled = true },
		high = { maxParticleEmitters = 72, maxLights = 22, maxBoltSegments = 28, shadowsEnabled = true },
		ultra = { maxParticleEmitters = 130, maxLights = 40, maxBoltSegments = 44, shadowsEnabled = true },
	},

	-- Auto-detect thresholds, measured as a rolling average frame time in ms.
	AUTO_DOWNGRADE_MS = 26,
	AUTO_UPGRADE_MS = 13,
	QUALITY_SAMPLE_WINDOW = 90,

	-- Server budgets.
	MAX_SERVER_STEP_MS = 8,
	SPATIAL_GRID_CELL_SIZE = 256,
}

return TableUtil.DeepFreeze(Balance)
