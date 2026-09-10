--!strict
--[[
	DataService
	-----------
	Owns every byte of persistent player state.

	Guarantees:
	  * Session locking. A profile is claimed by exactly one server. A second server
	    that finds a live lock waits for it to lapse rather than loading a stale copy,
	    which is how duplication exploits and rollbacks happen.
	  * Retry with backoff on both load and save. DataStore failures are routine, not
	    exceptional, and a single failed request must never cost a session.
	  * Autosave on a jittered interval, so a full server does not synchronise all its
	    saves into one spike.
	  * Guaranteed shutdown save via BindToClose, with a bounded wait.
	  * Migration and repair on load through ProfileSchema, so old saves come forward
	    and corrupt ones are fixed rather than rejected.

	Everything mutating a profile goes through :Update(), which marks the profile
	dirty. Services never write to a profile table they hold a reference to without
	calling :MarkDirty(), because an unflagged write is a write that silently does not
	persist.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BTS")
local Signal = require(Shared.Core.Signal)
local TableUtil = require(Shared.Core.TableUtil)
local Balance = require(Shared.Config.Balance)
local ProfileSchema = require(Shared.Data.ProfileSchema)

local DataService = {}
DataService.Name = "DataService"
DataService.Priority = 1

local DATASTORE_NAME = "BorrowTheStorm_Profiles_v1"
local KEY_PREFIX = "player_"

--[[ Per-player session state held while they are on this server. ]]
type Session = {
	userId: number,
	key: string,
	profile: any,
	dirty: boolean,
	loadedAt: number,
	lastSaveAt: number,
	nextAutosaveAt: number,
	saving: boolean,
	released: boolean,
	lockToken: string,
	saveFailures: number,
}

function DataService:Init()
	self._sessions = {} :: { [number]: Session }
	self._store = nil
	self._useMockStore = false
	self._shuttingDown = false
	self._stats = {
		loads = 0,
		loadFailures = 0,
		saves = 0,
		saveFailures = 0,
		migrations = 0,
		repairs = 0,
		lockWaits = 0,
	}

	self.ProfileLoaded = Signal.new("DataService.ProfileLoaded")
	self.ProfileReleasing = Signal.new("DataService.ProfileReleasing")
	self.ProfileSaved = Signal.new("DataService.ProfileSaved")

	-- DataStores are unavailable in a local Studio session without API access
	-- enabled. Rather than failing every request, fall back to an in-memory store so
	-- the whole game is still playable and testable locally.
	local ok, store = pcall(function()
		return DataStoreService:GetDataStore(DATASTORE_NAME)
	end)
	if ok and store then
		self._store = store
	else
		self._useMockStore = true
		self._mockData = {}
		warn("[DataService] DataStore unavailable; using in-memory store. Progress will not persist.")
	end

	-- A per-server token so a session lock can identify its owner.
	self._serverToken = tostring(game.JobId) .. "_" .. tostring(math.floor(os.time()))
end

function DataService:Start()
	game:BindToClose(function()
		self:_onShutdown()
	end)
end

-- ============================================================================
-- Store access with retry
-- ============================================================================

local function keyFor(userId: number): string
	return KEY_PREFIX .. tostring(userId)
end

--[[
	Executes a DataStore operation with exponential backoff.
	Returns (ok, result). The final failure is reported to the caller rather than
	thrown, because every caller has a meaningful fallback.
]]
function DataService:_retry(label: string, operation: () -> any): (boolean, any)
	local attempts = Balance.Data.SAVE_RETRY_ATTEMPTS
	local backoff = Balance.Data.SAVE_RETRY_BACKOFF
	local delay = 0.5

	for attempt = 1, attempts do
		local ok, result = pcall(operation)
		if ok then
			return true, result
		end
		if attempt < attempts then
			task.wait(delay)
			delay *= backoff
		else
			warn(("[DataService] %s failed after %d attempts: %s"):format(label, attempts, tostring(result)))
			return false, result
		end
	end
	return false, nil
end

function DataService:_rawGet(key: string): (boolean, any)
	if self._useMockStore then
		return true, self._mockData[key]
	end
	return self:_retry("GetAsync " .. key, function()
		return self._store:GetAsync(key)
	end)
end

function DataService:_rawUpdate(key: string, transform: (any) -> any): (boolean, any)
	if self._useMockStore then
		local updated = transform(self._mockData[key])
		if updated ~= nil then
			self._mockData[key] = updated
		end
		return true, updated
	end
	return self:_retry("UpdateAsync " .. key, function()
		return self._store:UpdateAsync(key, transform)
	end)
end

-- ============================================================================
-- Session locking
--
-- A stored record is { profile = ..., lock = { token, heartbeat } }. A lock whose
-- heartbeat is older than SESSION_LOCK_TIMEOUT is considered abandoned — that
-- covers a server crashing without releasing.
-- ============================================================================

function DataService:_isLockLive(lock: any, now: number): boolean
	if type(lock) ~= "table" or type(lock.heartbeat) ~= "number" then
		return false
	end
	return (now - lock.heartbeat) < Balance.Data.SESSION_LOCK_TIMEOUT
end

--[[
	Attempts to claim a profile. Retries while another server holds a live lock.
	Returns (profile, report) or (nil, reason) if the claim could not be made.
]]
function DataService:_claimProfile(userId: number): (any?, any)
	local key = keyFor(userId)
	local token = self._serverToken .. "_" .. tostring(userId)

	for attempt = 1, Balance.Data.MAX_LOAD_ATTEMPTS do
		local claimed = nil
		local blocked = false

		local ok = self:_rawUpdate(key, function(record)
			local now = os.time()
			record = record or {}

			if self:_isLockLive(record.lock, now) and record.lock.token ~= token then
				-- Someone else owns it. Abort the write so we do not stomp their lock.
				blocked = true
				return nil
			end

			record.lock = { token = token, heartbeat = now }
			claimed = record
			return record
		end)

		if ok and claimed then
			return claimed.profile, { token = token, attempts = attempt }
		end

		if blocked then
			self._stats.lockWaits += 1
			-- Wait a fraction of the lock timeout, then try again. A crashed server's
			-- lock lapses within SESSION_LOCK_TIMEOUT.
			task.wait(math.min(6, Balance.Data.SESSION_LOCK_TIMEOUT / Balance.Data.MAX_LOAD_ATTEMPTS))
		else
			task.wait(1.5)
		end
	end

	return nil, "lock_contended"
end

-- ============================================================================
-- Load / release
-- ============================================================================

--[[
	Loads (or creates) a player's profile and starts their session.
	Returns the prepared profile, or nil when the profile could not be claimed —
	in which case the caller should kick the player with a clear message rather than
	let them play on a profile that will not save.
]]
function DataService:LoadProfile(player: Player): (any?, string?)
	local userId = player.UserId
	if self._sessions[userId] then
		return self._sessions[userId].profile, nil
	end

	local rawProfile, claimInfo = self:_claimProfile(userId)
	if rawProfile == nil and claimInfo == "lock_contended" then
		self._stats.loadFailures += 1
		return nil, "Your save is still active on another server. Please rejoin in a moment."
	end

	local profile, report = ProfileSchema.Prepare(rawProfile)

	self._stats.loads += 1
	if report.migrationSteps > 0 then
		self._stats.migrations += 1
		print(("[DataService] migrated %s from schema v%d (%d steps, %d fields added)")
			:format(player.Name, report.fromVersion, report.migrationSteps, report.fieldsAdded))
	end
	if #report.repairs > 0 then
		self._stats.repairs += 1
		warn(("[DataService] repaired %d issues on %s's profile:\n  %s")
			:format(#report.repairs, player.Name, table.concat(report.repairs, "\n  ")))
	end

	local now = os.time()
	if report.wasNew then
		profile.createdAt = now
	end
	profile.lastSeenAt = now
	profile.sessionCount += 1

	local session: Session = {
		userId = userId,
		key = keyFor(userId),
		profile = profile,
		dirty = true,
		loadedAt = os.clock(),
		lastSaveAt = os.clock(),
		nextAutosaveAt = os.clock() + Balance.Data.AUTOSAVE_INTERVAL
			+ math.random() * Balance.Data.AUTOSAVE_JITTER,
		saving = false,
		released = false,
		lockToken = (claimInfo :: any).token,
		saveFailures = 0,
	}
	self._sessions[userId] = session

	self.ProfileLoaded:Fire(player, profile, report)
	return profile, nil
end

--[[ Returns a player's live profile, or nil if they have no session. ]]
function DataService:GetProfile(player: Player): any?
	local session = self._sessions[player.UserId]
	return session and not session.released and session.profile or nil
end

function DataService:GetProfileByUserId(userId: number): any?
	local session = self._sessions[userId]
	return session and not session.released and session.profile or nil
end

function DataService:HasProfile(player: Player): boolean
	return self:GetProfile(player) ~= nil
end

--[[
	Mutates a profile through a callback and marks it dirty.
	This is the only sanctioned way to change persistent state; it guarantees the
	change will actually be written.
]]
function DataService:Update(player: Player, mutator: (any) -> ()): boolean
	local profile = self:GetProfile(player)
	if not profile then
		return false
	end
	local ok, err = pcall(mutator, profile)
	if not ok then
		warn(("[DataService] Update mutator errored for %s: %s"):format(player.Name, tostring(err)))
		return false
	end
	self:MarkDirty(player)
	return true
end

--[[ Flags a profile as needing a write. Call after any direct mutation. ]]
function DataService:MarkDirty(player: Player)
	local session = self._sessions[player.UserId]
	if session then
		session.dirty = true
	end
end

--[[
	Writes a profile to the datastore, refreshing its session lock in the same
	transaction so the lock never lapses while the player is still connected.
]]
function DataService:_writeProfile(session: Session, releaseLock: boolean): boolean
	if session.saving then
		return false
	end
	session.saving = true

	local profileCopy = TableUtil.DeepCopy(session.profile)
	local token = session.lockToken

	local ok = self:_rawUpdate(session.key, function(record)
		record = record or {}
		local now = os.time()

		-- Only write if we still hold the lock. If another server took over (because
		-- ours stalled long enough for the lock to lapse), abort rather than
		-- overwrite whatever progress they have made.
		if record.lock and record.lock.token ~= token and self:_isLockLive(record.lock, now) then
			return nil
		end

		record.profile = profileCopy
		if releaseLock then
			record.lock = nil
		else
			record.lock = { token = token, heartbeat = now }
		end
		return record
	end)

	session.saving = false

	if ok then
		session.dirty = false
		session.lastSaveAt = os.clock()
		session.saveFailures = 0
		self._stats.saves += 1
		return true
	end

	session.saveFailures += 1
	self._stats.saveFailures += 1
	return false
end

--[[ Forces an immediate save. Used before risky operations such as prestige. ]]
function DataService:SaveProfile(player: Player): boolean
	local session = self._sessions[player.UserId]
	if not session or session.released then
		return false
	end
	local success = self:_writeProfile(session, false)
	if success then
		self.ProfileSaved:Fire(player, session.profile)
	end
	return success
end

--[[
	Ends a session: final save, lock release, session removal.
	Called on PlayerRemoving and on shutdown.
]]
function DataService:ReleaseProfile(player: Player): boolean
	local userId = player.UserId
	local session = self._sessions[userId]
	if not session or session.released then
		return false
	end

	session.released = true
	self.ProfileReleasing:Fire(player, session.profile)

	session.profile.lastSeenAt = os.time()

	local success = self:_writeProfile(session, true)
	if not success then
		warn(("[DataService] FINAL SAVE FAILED for %s (userId %d)"):format(player.Name, userId))
	end

	self._sessions[userId] = nil
	return success
end

-- ============================================================================
-- Autosave and lock heartbeat
-- ============================================================================

--[[
	Called from the server's slow tick. Saves any dirty profile whose autosave window
	has elapsed, and refreshes the lock heartbeat on profiles that are clean but
	still connected.
]]
function DataService:Tick()
	if self._shuttingDown then
		return
	end
	local now = os.clock()

	for userId, session in pairs(self._sessions) do
		if not session.released and not session.saving and now >= session.nextAutosaveAt then
			local player = Players:GetPlayerByUserId(userId)
			if player then
				-- Even a clean profile writes on schedule, because the write is what
				-- refreshes the session lock heartbeat.
				local success = self:_writeProfile(session, false)
				if success then
					self.ProfileSaved:Fire(player, session.profile)
				end
				session.nextAutosaveAt = now + Balance.Data.AUTOSAVE_INTERVAL
					+ math.random() * Balance.Data.AUTOSAVE_JITTER
			end
		end
	end
end

--[[
	Shutdown handler. Releases every session, in parallel, with a bounded wait so
	Roblox's 30-second shutdown budget is respected even on a full server.
]]
function DataService:_onShutdown()
	if self._shuttingDown then
		return
	end
	self._shuttingDown = true

	local pending = 0
	local completed = 0

	for userId, session in pairs(self._sessions) do
		if not session.released then
			pending += 1
			task.spawn(function()
				local player = Players:GetPlayerByUserId(userId)
				if player then
					self:ReleaseProfile(player)
				else
					session.released = true
					self:_writeProfile(session, true)
					self._sessions[userId] = nil
				end
				completed += 1
			end)
		end
	end

	if pending == 0 then
		return
	end

	print(("[DataService] shutdown: saving %d profiles"):format(pending))
	local deadline = os.clock() + 25
	while completed < pending and os.clock() < deadline do
		task.wait(0.2)
	end
	print(("[DataService] shutdown: %d/%d profiles saved"):format(completed, pending))
end

function DataService:Stop()
	self:_onShutdown()
end

-- ============================================================================
-- Diagnostics
-- ============================================================================

function DataService:GetStats()
	local sessionCount = 0
	local dirtyCount = 0
	for _, session in pairs(self._sessions) do
		sessionCount += 1
		if session.dirty then
			dirtyCount += 1
		end
	end
	return {
		sessions = sessionCount,
		dirty = dirtyCount,
		usingMockStore = self._useMockStore,
		loads = self._stats.loads,
		loadFailures = self._stats.loadFailures,
		saves = self._stats.saves,
		saveFailures = self._stats.saveFailures,
		migrations = self._stats.migrations,
		repairs = self._stats.repairs,
		lockWaits = self._stats.lockWaits,
	}
end

--[[ Test seam: swaps in a controllable store implementation. ]]
function DataService:_setMockStore(data: { [string]: any })
	self._useMockStore = true
	self._mockData = data or {}
end

return DataService
