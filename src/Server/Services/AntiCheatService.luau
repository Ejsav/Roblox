--!strict
--[[
	AntiCheatService
	----------------
	Accumulates suspicion from every validation failure in the game and escalates.

	Philosophy: nothing here is a hair trigger. Legitimate play produces occasional
	rejections — a laggy capture, a physics hiccup on a moving platform — so a single
	failure costs a small amount of suspicion that decays over time. Only a sustained
	pattern reaches the threshold.

	The service never silently rolls back gameplay. Rejections are already handled at
	the point of validation; this exists to notice the pattern, log it, and remove a
	player who is clearly automating.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BTS")
local Signal = require(Shared.Core.Signal)
local Net = require(Shared.Net)
local Balance = require(Shared.Config.Balance)

local AntiCheatService = {}
AntiCheatService.Name = "AntiCheatService"
AntiCheatService.Dependencies = { "DataService" }
AntiCheatService.Priority = 10

--[[
	Suspicion weight per violation kind. Tuned so a handful of laggy captures is
	nothing, while a teleport or an impossible currency claim is immediately serious.
]]
local WEIGHTS = {
	rate_limited = 1,
	invalid_argument = 4,
	wrong_direction = 25,
	unknown_remote = 25,
	unexpected_arguments = 8,
	capture_position_mismatch = 6,
	teleport = 20,
	speed = 3,
	impossible_purchase = 30,
	impossible_reward = 40,
	duplicate_discovery = 2,
}

function AntiCheatService:Init()
	self._suspicion = {} :: { [number]: number }
	self._history = {} :: { [number]: { any } }
	self._lastPositions = {} :: { [number]: { position: Vector3, at: number } }
	self._lastDecayAt = os.clock()

	self.Flagged = Signal.new("AntiCheatService.Flagged")
end

function AntiCheatService:Start()
	self._data = self.Registry:Get("DataService")
	self._analytics = self.Registry:Find("AnalyticsService")

	-- Every rejection at the network edge feeds straight in.
	Net.RequestRejected:Connect(function(player, remoteName, reason)
		local kind = reason and reason:match("^([%a_]+)") or "unknown"
		self:Report(player, kind, 1, { remote = remoteName, reason = reason })
	end)

	Players.PlayerRemoving:Connect(function(player)
		self._suspicion[player.UserId] = nil
		self._history[player.UserId] = nil
		self._lastPositions[player.UserId] = nil
	end)
end

--[[
	Records a violation. `magnitude` scales the weight for continuous violations
	such as a distance overshoot.
]]
function AntiCheatService:Report(player: Player, kind: string, magnitude: number?, detail: any?)
	local weight = (WEIGHTS[kind] or 2) * math.clamp(magnitude or 1, 0.25, 4)

	local total = (self._suspicion[player.UserId] or 0) + weight
	self._suspicion[player.UserId] = total

	local history = self._history[player.UserId]
	if not history then
		history = {}
		self._history[player.UserId] = history
	end
	table.insert(history, { kind = kind, weight = weight, at = os.clock(), detail = detail })
	if #history > 60 then
		table.remove(history, 1)
	end

	local profile = self._data:GetProfile(player)
	if profile and profile.flags then
		profile.flags.rejectionCount = (profile.flags.rejectionCount or 0) + 1
		profile.flags.lastRejectionAt = os.time()
		profile.flags.suspicionTotal = math.max(profile.flags.suspicionTotal or 0, total)
		self._data:MarkDirty(player)
	end

	if total >= Balance.Network.SUSPICION_LOG_THRESHOLD and not (self._logged and self._logged[player.UserId]) then
		self._logged = self._logged or {}
		self._logged[player.UserId] = true
		warn(("[AntiCheat] %s (%d) suspicion %.1f — recent: %s")
			:format(player.Name, player.UserId, total, self:_summariseHistory(player)))
		self.Flagged:Fire(player, total, history)
		if self._analytics then
			self._analytics:Track(player, "anticheat_flagged", { suspicion = math.floor(total), kind = kind })
		end
	end

	if total >= Balance.Network.SUSPICION_KICK_THRESHOLD then
		self:_removePlayer(player, total)
	end
end

function AntiCheatService:_summariseHistory(player: Player): string
	local counts = {}
	for _, entry in ipairs(self._history[player.UserId] or {}) do
		counts[entry.kind] = (counts[entry.kind] or 0) + 1
	end
	local parts = {}
	for kind, count in pairs(counts) do
		table.insert(parts, ("%s x%d"):format(kind, count))
	end
	table.sort(parts)
	return table.concat(parts, ", ")
end

function AntiCheatService:_removePlayer(player: Player, total: number)
	warn(("[AntiCheat] removing %s (%d) at suspicion %.1f"):format(player.Name, player.UserId, total))
	if self._analytics then
		self._analytics:Track(player, "anticheat_kick", { suspicion = math.floor(total) })
	end
	-- The profile is released first so the session lock does not linger.
	self._data:ReleaseProfile(player)
	player:Kick("Disconnected: irregular client behaviour detected. If you believe this is a mistake, please rejoin.")
end

--[[
	Movement plausibility. Called on the slow tick rather than per frame, because a
	single frame of unusual displacement is normal and a sustained one is not.
]]
function AntiCheatService:CheckMovement(player: Player)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		self._lastPositions[player.UserId] = nil
		return
	end

	local position = (root :: BasePart).Position
	local now = os.clock()
	local previous = self._lastPositions[player.UserId]

	self._lastPositions[player.UserId] = { position = position, at = now }

	if not previous then
		return
	end

	local elapsed = now - previous.at
	if elapsed <= 0 then
		return
	end

	local distance = (position - previous.position).Magnitude
	local speed = distance / elapsed

	-- Legitimate teleports (fast travel, emergency extract, blink) mark a grace
	-- window, so the check does not fire on the game's own mechanics.
	if self._graceUntil and (self._graceUntil[player.UserId] or 0) > now then
		return
	end

	if speed > Balance.Network.MAX_PLAUSIBLE_SPEED then
		local overshoot = speed / Balance.Network.MAX_PLAUSIBLE_SPEED
		self:Report(player, distance > 400 and "teleport" or "speed", overshoot, {
			speed = math.floor(speed),
			distance = math.floor(distance),
		})
	end
end

--[[ Marks a legitimate teleport so the movement check ignores it. ]]
function AntiCheatService:GrantMovementGrace(player: Player, seconds: number?)
	self._graceUntil = self._graceUntil or {}
	self._graceUntil[player.UserId] = os.clock() + (seconds or Balance.Network.TELEPORT_GRACE_SECONDS)
	self._lastPositions[player.UserId] = nil
end

function AntiCheatService:GetSuspicion(player: Player): number
	return self._suspicion[player.UserId] or 0
end

--[[ Slow tick: decays suspicion and runs the movement check. ]]
function AntiCheatService:Tick()
	local now = os.clock()
	local elapsed = now - self._lastDecayAt
	self._lastDecayAt = now

	local decay = Balance.Network.SUSPICION_DECAY_PER_SECOND * elapsed
	for userId, total in pairs(self._suspicion) do
		local reduced = math.max(0, total - decay)
		if reduced <= 0 then
			self._suspicion[userId] = nil
			if self._logged then
				self._logged[userId] = nil
			end
		else
			self._suspicion[userId] = reduced
		end
	end

	for _, player in ipairs(Players:GetPlayers()) do
		self:CheckMovement(player)
	end

	Net.Sweep()
end

return AntiCheatService
