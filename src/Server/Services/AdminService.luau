--!strict
--[[
	AdminService
	------------
	The developer console.

	This is the most dangerous file in the project, so its shape is dictated by that
	rather than by convenience:

	  1. Authorisation is checked on the server, on every single command, from a
	     source the client cannot influence. There is no "is admin" flag on the
	     profile, because a profile is data that has been round-tripped through a
	     datastore and, in the worst case, through a client. Authority comes from the
	     place's owner (or group rank) and from a hard-coded allowlist — nothing else.

	  2. Commands that grant anything are gated a second time, behind a Studio-only
	     check. A live server has no legitimate reason to mint currency, and the
	     ability to do so is the single most valuable thing an attacker could take
	     from this system. Inspection commands stay available everywhere, because
	     that is what a live incident actually needs.

	  3. Every accepted command is logged with who ran it and what they passed.
	     Every rejected one is logged too, and a rejection from a non-owner is
	     reported to the anti-cheat service — a client that knows this remote exists
	     and is guessing at it is a client worth watching.

	The command table is data, so adding a command cannot accidentally add a
	privilege: each entry declares its own level and whether it is Studio-only.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BTS")
local Signal = require(Shared.Core.Signal)
local Net = require(Shared.Net)
local Config = require(Shared.Config)

local AdminService = {}
AdminService.Name = "AdminService"
AdminService.Dependencies = { "DataService" }
AdminService.Priority = 90

--[[
	Explicit allowlist of user ids, for developers who do not own the place. Empty
	by design: an entry here is a permanent grant that survives every future change
	to this file, so adding one should be a deliberate, reviewed act rather than
	something that accumulates.
]]
local ALLOWED_USER_IDS: { [number]: boolean } = {}

--[[ Group rank at or above which a member is treated as staff. 0 disables it. ]]
local STAFF_GROUP_ID = 0
local STAFF_MIN_RANK = 250

local LOG_LIMIT = 200

type Command = {
	name: string,
	summary: string,
	usage: string,
	-- Commands that create value out of nothing. Studio only, always.
	grants: boolean?,
	run: (self: any, player: Player, args: { string }) -> (boolean, string),
}

function AdminService:Init()
	self._log = {}
	self._authCache = {}

	self.CommandRun = Signal.new("AdminService.CommandRun")

	self._commands = self:_buildCommands()
end

function AdminService:Start()
	self._data = self.Registry:Get("DataService")
	self._analytics = self.Registry:Find("AnalyticsService")
	self._antiCheat = self.Registry:Find("AntiCheatService")

	Net.OnServerEvent("AdminCommand", function(player, command, args)
		self:Execute(player, command, args)
	end)

	Players.PlayerRemoving:Connect(function(player)
		self._authCache[player.UserId] = nil
	end)
end

-- ============================================================================
-- Authorisation
-- ============================================================================

--[[
	Whether a player may run admin commands at all.

	Resolved once per player per session and cached, because the group lookup is a
	web call and the answer cannot change mid-session in any way that matters. The
	cache is keyed by user id and cleared when they leave.
]]
function AdminService:IsAuthorised(player: Player): boolean
	local cached = self._authCache[player.UserId]
	if cached ~= nil then
		return cached
	end

	local authorised = false

	-- The place's owner, whether that is a person or a group.
	if game.CreatorType == Enum.CreatorType.User then
		authorised = player.UserId == game.CreatorId
	elseif game.CreatorType == Enum.CreatorType.Group then
		local ok, rank = pcall(function()
			return player:GetRankInGroup(game.CreatorId)
		end)
		-- A failed lookup denies. An admin who has to retry is a nuisance; an
		-- admin granted by a network error is a breach.
		authorised = ok and (rank :: number) >= STAFF_MIN_RANK
	end

	if not authorised and ALLOWED_USER_IDS[player.UserId] then
		authorised = true
	end

	if not authorised and STAFF_GROUP_ID > 0 then
		local ok, rank = pcall(function()
			return player:GetRankInGroup(STAFF_GROUP_ID)
		end)
		authorised = ok and (rank :: number) >= STAFF_MIN_RANK
	end

	self._authCache[player.UserId] = authorised
	return authorised
end

-- ============================================================================
-- Execution
-- ============================================================================

function AdminService:Execute(player: Player, commandName: string, args: { string }): (boolean, string)
	commandName = string.lower(tostring(commandName))
	args = args or {}

	if not self:IsAuthorised(player) then
		self:_record(player, commandName, args, false, "not authorised")

		-- Someone who is not staff firing this remote is either a modified client or
		-- a curious one. Either way the anti-cheat service should know.
		if self._antiCheat then
			self._antiCheat:Report(player, "admin_command_denied", 25, { command = commandName })
		end
		return self:_reply(player, false, "Not authorised.")
	end

	local command = self._commands[commandName]
	if not command then
		return self:_reply(player, false, ("Unknown command '%s'. Try 'help'."):format(commandName))
	end

	if command.grants and not RunService:IsStudio() then
		self:_record(player, commandName, args, false, "granting command outside Studio")
		return self:_reply(player, false, "That command only runs in Studio.")
	end

	local ok, result = pcall(command.run, self, player, args)
	if not ok then
		self:_record(player, commandName, args, false, tostring(result))
		return self:_reply(player, false, "Command errored: " .. tostring(result))
	end

	-- Commands return { ok, message } as one table rather than two values, because
	-- a pcall around a multi-return would need unpacking at every call site and
	-- silently drops everything past the first on the error path.
	local succeeded, message = false, tostring(result)
	if type(result) == "table" then
		succeeded = result[1] ~= false
		message = tostring(result[2])
	end

	self:_record(player, commandName, args, succeeded, message)
	self.CommandRun:Fire(player, commandName, args)

	if self._analytics then
		self._analytics:Track(player, "admin_command", { command = commandName })
	end

	return self:_reply(player, succeeded, message)
end

function AdminService:_reply(player: Player, ok: boolean, message: string): (boolean, string)
	Net.FireClient(player, "Notification", {
		kind = ok and "info" or "bad",
		title = ok and "Command" or "Command failed",
		body = message,
		lifetime = 6,
	})
	return ok, message
end

function AdminService:_record(player: Player, command: string, args: { string }, ok: boolean, detail: string)
	table.insert(self._log, {
		at = os.time(),
		userId = player.UserId,
		name = player.Name,
		command = command,
		args = table.concat(args, " "),
		ok = ok,
		detail = detail,
	})

	while #self._log > LOG_LIMIT do
		table.remove(self._log, 1)
	end

	-- Printed as well as stored: an admin action taken during an incident needs to
	-- be in the server log, not only in a table that dies with the server.
	print(("[Admin] %s (%d) ran '%s %s' -> %s: %s"):format(
		player.Name, player.UserId, command, table.concat(args, " "),
		ok and "ok" or "REFUSED", detail
	))
end

function AdminService:GetLog()
	return table.clone(self._log)
end

-- ============================================================================
-- Commands
-- ============================================================================

--[[ Resolves a name argument to a player, defaulting to the caller. ]]
local function resolveTarget(caller: Player, name: string?): Player?
	if not name or name == "" or name == "me" then
		return caller
	end

	local lowered = string.lower(name)
	for _, player in ipairs(Players:GetPlayers()) do
		if string.lower(player.Name) == lowered or string.lower(player.DisplayName) == lowered then
			return player
		end
		-- Prefix match, so a long username does not have to be typed in full.
		if string.sub(string.lower(player.Name), 1, #lowered) == lowered then
			return player
		end
	end
	return nil
end

function AdminService:_buildCommands(): { [string]: Command }
	local commands: { [string]: Command } = {}

	local function define(command: Command)
		commands[command.name] = command
	end

	-- ---------------------------------------------------------------- inspection
	define({
		name = "help",
		summary = "List commands.",
		usage = "help",
		run = function(this)
			local names = {}
			for _, command in pairs(this._commands) do
				table.insert(names, ("%s — %s"):format(command.usage, command.summary))
			end
			table.sort(names)
			return { true, table.concat(names, "\n") }
		end,
	})

	define({
		name = "stats",
		summary = "Service statistics for this server.",
		usage = "stats [service]",
		run = function(this, _, args)
			local lines = {}
			for name, service in pairs(this.Registry:GetAll()) do
				if args[1] and string.lower(name) ~= string.lower(args[1]) then
					continue
				end
				if type((service :: any).GetStats) ~= "function" then
					continue
				end
				local ok, stats = pcall(service.GetStats, service)
				if ok and type(stats) == "table" then
					local parts = {}
					for key, value in pairs(stats) do
						table.insert(parts, ("%s=%s"):format(key, tostring(value)))
					end
					table.sort(parts)
					table.insert(lines, ("%s: %s"):format(name, table.concat(parts, " ")))
				end
			end
			table.sort(lines)
			return { true, #lines > 0 and table.concat(lines, "\n") or "No matching service." }
		end,
	})

	define({
		name = "profile",
		summary = "Summarise a player's profile.",
		usage = "profile [player]",
		run = function(this, caller, args)
			local target = resolveTarget(caller, args[1])
			if not target then
				return { false, "No such player here." }
			end

			local profile = this._data:GetProfile(target)
			if not profile then
				return { false, "No profile loaded for " .. target.Name .. "." }
			end

			local achievements = 0
			for _ in pairs(profile.achievements or {}) do
				achievements += 1
			end

			return { true, ("%s — level %d, prestige %d, %s W, %s cores, %d achievements, %d items")
				:format(
					target.Name,
					profile.level or 1,
					profile.prestige or 0,
					Config.Theme.FormatNumber(profile.watts or 0),
					Config.Theme.FormatNumber(profile.cores or 0),
					achievements,
					#(profile.inventory or {})
				) }
		end,
	})

	define({
		name = "where",
		summary = "Report a player's position and region.",
		usage = "where [player]",
		run = function(this, caller, args)
			local target = resolveTarget(caller, args[1])
			if not target then
				return { false, "No such player here." }
			end

			local character = target.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if not root then
				return { false, target.Name .. " has no character." }
			end

			local position = (root :: BasePart).Position
			local regions = this.Registry:Find("RegionService")
			local regionId = (regions and regions:GetPlayerRegion(target)) or "unknown"

			return { true, ("%s: %d, %d, %d in %s"):format(
				target.Name,
				math.floor(position.X),
				math.floor(position.Y),
				math.floor(position.Z),
				tostring(regionId)
			) }
		end,
	})

	define({
		name = "verify",
		summary = "Re-run the content integrity check.",
		usage = "verify",
		run = function()
			local ok, problems = Config.Verify()
			if ok then
				return { true, "Content integrity: OK" }
			end
			return { false, ("%d problems:\n%s"):format(#problems, table.concat(problems, "\n")) }
		end,
	})

	define({
		name = "save",
		summary = "Force a save of a player's profile.",
		usage = "save [player]",
		run = function(this, caller, args)
			local target = resolveTarget(caller, args[1])
			if not target then
				return { false, "No such player here." }
			end
			local ok = this._data:SaveProfile(target)
			return { ok, ok and ("Saved " .. target.Name .. ".") or "Save failed." }
		end,
	})

	-- ------------------------------------------------------------------- granting
	-- Everything below creates value and is Studio-only, without exception.
	define({
		name = "give",
		summary = "Grant currency.",
		usage = "give <watts|cores|sigils> <amount> [player]",
		grants = true,
		run = function(this, caller, args)
			local currency = string.lower(args[1] or "")
			local amount = tonumber(args[2])
			local target = resolveTarget(caller, args[3])

			if currency ~= "watts" and currency ~= "cores" and currency ~= "sigils" then
				return { false, "Currency must be watts, cores or sigils." }
			end
			if not amount or amount <= 0 then
				return { false, "Amount must be a positive number." }
			end
			if not target then
				return { false, "No such player here." }
			end

			local economy = this.Registry:Get("EconomyService")
			economy:Award(target, currency, amount, "admin")
			return { true, ("Gave %s %s to %s."):format(tostring(amount), currency, target.Name) }
		end,
	})

	define({
		name = "xp",
		summary = "Grant experience.",
		usage = "xp <amount> [player]",
		grants = true,
		run = function(this, caller, args)
			local amount = tonumber(args[1])
			local target = resolveTarget(caller, args[2])
			if not amount or amount <= 0 then
				return { false, "Amount must be a positive number." }
			end
			if not target then
				return { false, "No such player here." }
			end

			local progression = this.Registry:Get("ProgressionService")
			progression:AwardXp(target, amount, "admin")
			return { true, ("Gave %d xp to %s."):format(amount, target.Name) }
		end,
	})

	define({
		name = "unlock",
		summary = "Grant a region, ability, traversal move or title.",
		usage = "unlock <traversal|ability|title|fast_travel> <id> [player]",
		grants = true,
		run = function(this, caller, args)
			local kind = string.lower(args[1] or "")
			local id = args[2]
			local target = resolveTarget(caller, args[3])

			if not id or id == "" then
				return { false, "An id is required." }
			end
			if not target then
				return { false, "No such player here." }
			end

			local progression = this.Registry:Get("ProgressionService")
			local granted = progression:GrantUnlock(target, kind, id, id)
			return { granted, granted
				and ("Unlocked %s '%s' for %s."):format(kind, id, target.Name)
				or "Nothing granted — already owned, or an unknown kind." }
		end,
	})

	define({
		name = "storm",
		summary = "Spawn a storm of a given type nearby.",
		usage = "storm <stormId>",
		grants = true,
		run = function(this, caller, args)
			local stormId = args[1]
			if not stormId or not Config.StormTypes.ById[stormId] then
				return { false, "Unknown storm type." }
			end

			local character = caller.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if not root then
				return { false, "You have no character." }
			end

			local regions = this.Registry:Find("RegionService")
			local regionId = (regions and regions:GetPlayerRegion(caller)) or "starter_district"

			local storms = this.Registry:Get("StormService")
			local cell = storms:SpawnCell(regionId, stormId, (root :: BasePart).Position)
			return { cell ~= nil, cell and ("Spawned " .. stormId .. ".") or "Spawn refused." }
		end,
	})

	define({
		name = "event",
		summary = "Start a world event.",
		usage = "event <eventId>",
		grants = true,
		run = function(this, _, args)
			local eventId = args[1]
			if not eventId or not Config.WorldEvents.ById[eventId] then
				return { false, "Unknown event." }
			end

			local events = this.Registry:Get("WorldEventService")
			local started = events:StartEvent(eventId)
			return { started ~= nil, started and ("Started " .. eventId .. ".") or "Could not start it." }
		end,
	})

	return commands
end

function AdminService:GetCommands()
	local out = {}
	for name, command in pairs(self._commands) do
		table.insert(out, {
			name = name,
			summary = command.summary,
			usage = command.usage,
			studioOnly = command.grants == true,
		})
	end
	table.sort(out, function(a, b)
		return a.name < b.name
	end)
	return out
end

function AdminService:GetStats()
	local authorised = 0
	for _, value in pairs(self._authCache) do
		if value then
			authorised += 1
		end
	end
	return {
		commands = #self:GetCommands(),
		logged = #self._log,
		authorisedHere = authorised,
	}
end

return AdminService
