--!strict
--[[
	Remotes
	-------
	The complete network surface of the game, declared in one file.

	Every remote states its direction, its rate limit and the schema of its arguments.
	Nothing crosses the boundary that is not listed here, which means the entire attack
	surface can be reviewed by reading a single file.

	Direction:
		C2S   client fires, server handles       (RemoteEvent)
		S2C   server fires, client handles       (RemoteEvent)
		C2SF  client invokes, server returns     (RemoteFunction — used sparingly)

	Rate limits are token buckets: { budget = burst size, refill = tokens per second }.
	They are sized from real gameplay, not guessed: capture allows a burst of 10 because
	a Chain Web legitimately produces seven attempts in a couple of seconds.
]]

local Validate = require(script.Parent.Parent.Core.Validate)

local Remotes = {}

local V = Validate

Remotes.Definitions = {

	-- ====================================================================== CAPTURE
	AttemptCapture = {
		direction = "C2S",
		rateLimit = { budget = 10, refill = 4 },
		description = "Player presses capture on a telegraphed strike.",
		args = {
			V.String(1, 32),        -- cellId
			V.String(1, 32),        -- strikeId
			V.Number(0, 1e6),       -- client press timestamp (workspace:GetServerTimeNow)
			V.Vector3(),            -- client-reported position, cross-checked server-side
		},
	},

	CaptureResult = {
		direction = "S2C",
		description = "Authoritative outcome of a capture attempt.",
	},

	StrikeTelegraph = {
		direction = "S2C",
		description = "A strike is winding up: id, position, timings, storm type.",
	},

	StrikeResolved = {
		direction = "S2C",
		description = "A strike discharged, captured or not.",
	},

	-- ====================================================================== STORMS
	StormSpawned = {
		direction = "S2C",
		description = "A cell entered this client's interest set.",
	},

	StormDespawned = {
		direction = "S2C",
		description = "A cell left this client's interest set or expired.",
	},

	StormUpdate = {
		direction = "S2C",
		description = "Batched positional and charge updates for nearby cells.",
	},

	RareStormAlert = {
		direction = "S2C",
		description = "A broadcast-worthy storm spawned somewhere in the world.",
	},

	-- ======================================================================= CARRY
	CarryUpdate = {
		direction = "S2C",
		description = "Authoritative carry, capacity, instability and chain state.",
	},

	RequestPurge = {
		direction = "C2S",
		rateLimit = { budget = 3, refill = 0.2 },
		description = "Manual instability purge.",
		args = {},
	},

	VentOccurred = {
		direction = "S2C",
		description = "Containment vented; client plays the consequence.",
	},

	-- ======================================================================== BANK
	RequestBank = {
		direction = "C2S",
		rateLimit = { budget = 4, refill = 0.6 },
		description = "Deposit carried energy at a station.",
		args = {
			V.String(1, 48),                -- stationId
			V.Optional(V.Boolean()),        -- partial deposit
		},
	},

	RequestRemoteBank = {
		direction = "C2S",
		rateLimit = { budget = 2, refill = 0.05 },
		description = "Deposit from anywhere at a penalty. Requires the unlock.",
		args = {},
	},

	BankResult = {
		direction = "S2C",
		description = "What the deposit actually paid, with the multiplier breakdown.",
	},

	-- ================================================================== PROGRESSION
	ProfileSync = {
		direction = "S2C",
		description = "Full profile snapshot, sent once on join.",
	},

	ProfileDelta = {
		direction = "S2C",
		description = "Incremental profile changes.",
	},

	RequestPurchaseUpgrade = {
		direction = "C2S",
		rateLimit = { budget = 8, refill = 3 },
		description = "Buy one or more levels of an upgrade track.",
		args = {
			V.String(1, 48),            -- upgradeId
			V.Integer(1, 200),          -- levels to buy
		},
	},

	RequestSpendSkillPoint = {
		direction = "C2S",
		rateLimit = { budget = 8, refill = 3 },
		description = "Rank up a skill node.",
		args = {
			V.String(1, 64),            -- nodeId
		},
	},

	RequestRespecSkills = {
		direction = "C2S",
		rateLimit = { budget = 2, refill = 0.05 },
		description = "Refund every skill point for a fee.",
		args = {},
	},

	RequestPrestigeView = {
		direction = "C2SF",
		rateLimit = { budget = 4, refill = 0.5 },
		description = "Fetch prestige status, ranks and the prestige skill tree.",
		args = {},
	},

	RequestPrestigeSkill = {
		direction = "C2S",
		rateLimit = { budget = 6, refill = 1 },
		description = "Purchase a prestige skill with sigils.",
		args = {
			V.String(1, 48),            -- skill id
		},
	},

	RequestPrestige = {
		direction = "C2S",
		rateLimit = { budget = 1, refill = 0.02 },
		description = "Commit to a prestige reset.",
		args = {
			V.Boolean(),                -- explicit confirmation flag
		},
	},

	LevelUp = {
		direction = "S2C",
		description = "Level increased; client plays the celebration.",
	},

	UnlockGranted = {
		direction = "S2C",
		description = "A region, ability, traversal move or behaviour became available.",
	},

	-- =================================================================== INVENTORY
	RequestEquip = {
		direction = "C2S",
		rateLimit = { budget = 10, refill = 4 },
		description = "Equip an owned item into its slot.",
		args = {
			V.String(1, 40),            -- item uid
		},
	},

	RequestUnequip = {
		direction = "C2S",
		rateLimit = { budget = 10, refill = 4 },
		description = "Clear an equipment slot.",
		args = {
			V.String(1, 32),            -- slotId
		},
	},

	RequestDismantle = {
		direction = "C2S",
		rateLimit = { budget = 12, refill = 4 },
		description = "Break items down for materials.",
		args = {
			V.Array(V.String(1, 40), 50),   -- item uids
		},
	},

	RequestFavourite = {
		direction = "C2S",
		rateLimit = { budget = 20, refill = 8 },
		description = "Toggle an item's favourite flag, which protects it from bulk dismantle.",
		args = {
			V.String(1, 40),
			V.Boolean(),
		},
	},

	RequestCrafting = {
		direction = "C2SF",
		rateLimit = { budget = 4, refill = 0.5 },
		description = "Fetch the crafting panel: recipes, what blocks each, and stock.",
		args = {},
	},

	RequestCraft = {
		direction = "C2S",
		rateLimit = { budget = 6, refill = 1 },
		description = "Craft a recipe at a workbench.",
		args = {
			V.String(1, 48),            -- recipeId
			V.Integer(1, 50),           -- quantity
		},
	},

	InventoryUpdate = {
		direction = "S2C",
		description = "Items added, removed or changed.",
	},

	ItemAcquired = {
		direction = "S2C",
		description = "A drop landed; client plays the reveal appropriate to its rarity.",
	},

	-- ==================================================================== ABILITIES
	RequestUseAbility = {
		direction = "C2S",
		rateLimit = { budget = 6, refill = 2 },
		description = "Activate an equipped ability.",
		args = {
			V.String(1, 40),                    -- abilityId
			V.Optional(V.Vector3()),            -- optional aim point
		},
	},

	RequestSetLoadout = {
		direction = "C2S",
		rateLimit = { budget = 6, refill = 1 },
		description = "Set the four active ability slots.",
		args = {
			V.Array(V.String(1, 40), 4),
		},
	},

	AbilityState = {
		direction = "S2C",
		description = "Cooldowns, charges and active durations.",
	},

	-- ====================================================================== QUESTS
	RequestAcceptQuest = {
		direction = "C2S",
		rateLimit = { budget = 6, refill = 2 },
		description = "Start an available quest.",
		args = { V.String(1, 64) },
	},

	RequestAbandonQuest = {
		direction = "C2S",
		rateLimit = { budget = 6, refill = 1 },
		description = "Drop an active quest.",
		args = { V.String(1, 64) },
	},

	RequestTrackQuest = {
		direction = "C2S",
		rateLimit = { budget = 15, refill = 6 },
		description = "Set which quest the HUD follows.",
		args = { V.Optional(V.String(1, 64)) },
	},

	QuestUpdate = {
		direction = "S2C",
		description = "Objective progress changed.",
	},

	QuestCompleted = {
		direction = "S2C",
		description = "A quest finished; client plays the completion sequence.",
	},

	-- ================================================================ INTERACTION
	RequestInteract = {
		direction = "C2S",
		rateLimit = { budget = 8, refill = 3 },
		description = "Use a nearby interactable: bank, relay, quest object, cache.",
		args = {
			V.String(1, 64),        -- interactable id
		},
	},

	InteractionManifest = {
		direction = "S2C",
		description = "The interactables in the world, so the client can resolve prompts locally.",
	},

	-- ====================================================================== TRAVEL
	RequestFastTravel = {
		direction = "C2S",
		rateLimit = { budget = 3, refill = 0.3 },
		description = "Travel to a discovered relay.",
		args = { V.String(1, 48) },
	},

	RegionChanged = {
		direction = "S2C",
		description = "Player crossed into a different region.",
	},

	-- ================================================================ WORLD EVENTS
	WorldEventStarted = {
		direction = "S2C",
		description = "An event began, with its phases and location.",
	},

	WorldEventPhase = {
		direction = "S2C",
		description = "An event advanced to its next phase.",
	},

	WorldEventEnded = {
		direction = "S2C",
		description = "An event resolved, with per-player rewards.",
	},

	WorldEventProgress = {
		direction = "S2C",
		description = "Live objective and contribution state.",
	},

	-- ===================================================================== SOCIAL
	RequestInviteToParty = {
		direction = "C2S",
		rateLimit = { budget = 5, refill = 0.5 },
		description = "Invite another player to a party.",
		args = { V.Integer(1, 1e12) },      -- target userId
	},

	RequestRespondToInvite = {
		direction = "C2S",
		rateLimit = { budget = 8, refill = 1 },
		description = "Accept or decline a party invite.",
		args = {
			V.String(1, 40),                -- inviteId
			V.Boolean(),                    -- accept
		},
	},

	RequestLeaveParty = {
		direction = "C2S",
		rateLimit = { budget = 4, refill = 0.5 },
		description = "Leave the current party.",
		args = {},
	},

	PartyUpdate = {
		direction = "S2C",
		description = "Party membership and member state.",
	},

	CombatState = {
		direction = "S2C",
		description = "A runner went down, was revived, or died — so others can reach them.",
	},

	RequestRevive = {
		direction = "C2S",
		rateLimit = { budget = 6, refill = 1 },
		description = "Begin reviving a downed runner.",
		args = { V.Integer(1, 1e12) },
	},

	-- ================================================================== DISCOVERY
	DiscoveryManifest = {
		direction = "S2C",
		description = "Undiscovered secret positions near the player, for client-side detection.",
	},

	ReportDiscovery = {
		direction = "C2S",
		rateLimit = { budget = 6, refill = 1 },
		description = "Client touched a discovery trigger; server validates position and awards.",
		args = {
			V.String(1, 64),                -- discoveryId
			V.Vector3(),                    -- client position for the distance check
		},
	},

	DiscoveryMade = {
		direction = "S2C",
		description = "A discovery registered; client plays the reveal.",
	},

	-- =============================================================== ACHIEVEMENTS
	RequestAchievements = {
		direction = "C2SF",
		rateLimit = { budget = 4, refill = 0.5 },
		description = "Fetch the achievement panel, including masked hidden entries.",
		-- Declared empty rather than omitted: an absent schema and a schema that
		-- accepts nothing behave identically at the gateway, but only one of them
		-- says so on purpose.
		args = {},
	},

	RequestEquipTitle = {
		direction = "C2S",
		rateLimit = { budget = 8, refill = 1 },
		description = "Wear an owned title, or clear the current one with an empty id.",
		args = {
			V.String(0, 64),                -- title id, empty to clear
		},
	},

	AchievementEarned = {
		direction = "S2C",
		description = "An achievement completed; client plays the unlock sequence.",
	},

	-- ================================================================ LEADERBOARDS
	RequestLeaderboard = {
		direction = "C2SF",
		rateLimit = { budget = 4, refill = 0.4 },
		description = "Fetch a leaderboard page.",
		args = {
			V.String(1, 48),                -- boardId
			V.Integer(1, 10),               -- page
		},
	},

	RecordBroken = {
		direction = "S2C",
		description = "A personal or server record fell.",
	},

	-- ==================================================================== SETTINGS
	RequestUpdateSettings = {
		direction = "C2S",
		rateLimit = { budget = 10, refill = 2 },
		description = "Persist a client settings change.",
		args = {
			V.Shape({
				quality = V.Optional(V.Enum({ "auto", "low", "medium", "high", "ultra" })),
				musicVolume = V.Optional(V.Number(0, 1)),
				sfxVolume = V.Optional(V.Number(0, 1)),
				screenShake = V.Optional(V.Number(0, 1)),
				showDamageNumbers = V.Optional(V.Boolean()),
				showOtherPlayers = V.Optional(V.Boolean()),
				colourblindMode = V.Optional(V.Enum({ "off", "protanopia", "deuteranopia", "tritanopia" })),
				hudScale = V.Optional(V.Number(0.6, 1.6)),
				reducedMotion = V.Optional(V.Boolean()),
				subtitles = V.Optional(V.Boolean()),
				holdToSprint = V.Optional(V.Boolean()),
				captureAssist = V.Optional(V.Boolean()),
			}, {
				quality = true, musicVolume = true, sfxVolume = true, screenShake = true,
				showDamageNumbers = true, showOtherPlayers = true, colourblindMode = true,
				hudScale = true, reducedMotion = true, subtitles = true, holdToSprint = true,
				captureAssist = true,
			}),
		},
	},

	-- ================================================================== TELEMETRY
	ReportClientMetric = {
		direction = "C2S",
		rateLimit = { budget = 4, refill = 0.2 },
		description = "Client performance sample, used for quality auto-tuning analytics.",
		args = {
			V.Shape({
				averageFrameMs = V.Number(0, 10000),
				quality = V.Enum({ "low", "medium", "high", "ultra" }),
				deviceKind = V.Enum({ "desktop", "mobile", "tablet", "console" }),
			}),
		},
	},

	-- ===================================================================== NOTICES
	Notification = {
		direction = "S2C",
		description = "Toast, banner or modal message.",
	},

	ServerAnnouncement = {
		direction = "S2C",
		description = "Server-wide announcement banner.",
	},

	-- ======================================================================= ADMIN
	AdminCommand = {
		direction = "C2S",
		rateLimit = { budget = 10, refill = 2 },
		description = "Developer command. Server re-checks authorisation on every call.",
		args = {
			V.String(1, 40),                            -- command
			V.Array(V.String(0, 120), 10),              -- arguments
		},
	},
}

--[[ Every remote name, sorted, for deterministic instance creation. ]]
function Remotes.GetNames(): { string }
	local names = {}
	for name in pairs(Remotes.Definitions) do
		table.insert(names, name)
	end
	table.sort(names)
	return names
end

function Remotes.Get(name: string)
	return Remotes.Definitions[name]
end

--[[ True when the remote is a RemoteFunction rather than a RemoteEvent. ]]
function Remotes.IsFunction(name: string): boolean
	local definition = Remotes.Definitions[name]
	return definition ~= nil and definition.direction == "C2SF"
end

--[[ True when clients are permitted to send on this remote. ]]
function Remotes.IsClientSendable(name: string): boolean
	local definition = Remotes.Definitions[name]
	if not definition then
		return false
	end
	return definition.direction == "C2S" or definition.direction == "C2SF"
end

return Remotes
