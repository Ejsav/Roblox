--!strict
--[[
	LeaderboardService
	------------------
	Global and per-server boards.

	Two kinds, because they answer different questions:
	  * Global boards ("who is the best at this, ever") live in OrderedDataStores and
	    are read in pages. They are slow, rate-limited by the platform, and shared by
	    every server, so everything here is built around writing rarely and caching
	    reads aggressively.
	  * Server boards ("who is doing well right now, here") are held in memory and
	    rebuilt from live profiles. They cost nothing, update every few seconds, and
	    are the ones a player actually looks at mid-session — a board you can climb
	    inside one sitting is a far better motivator than one where the top entry is
	    a stranger with a hundred times your playtime.

	Write discipline matters more than anything else in this file. OrderedDataStore
	budgets are per-key and modest, and a record like `totalCaptures` can move dozens
	of times a minute. So a submission is only written when it beats what this server
	last wrote for that player, and then only after a cooldown; between writes the
	value is held and flushed by the slow tick. A dropped write is not a lost record —
	the profile is the source of truth, and the board catches up on the next flush or
	the next session.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BTS")
local Signal = require(Shared.Core.Signal)
local Net = require(Shared.Net)
local Balance = require(Shared.Config.Balance)
local Regions = require(Shared.Config.Regions)

local LeaderboardService = {}
LeaderboardService.Name = "LeaderboardService"
LeaderboardService.Dependencies = { "DataService" }
LeaderboardService.Priority = 48

--[[
	Board definitions.

	`scope` is "global" (OrderedDataStore) or "server" (in-memory).
	`period` is "alltime" or "weekly"; a weekly board writes into a key stamped with
	the ISO week, which is what makes the reset free rather than a scheduled job.
	`source` says where a server board reads its value from a live profile.
	`format` tells the client how to render the number.
]]
local BOARDS = {
	{
		id = "largest_bank",
		name = "Largest Single Bank",
		description = "The most energy carried into a bank in one trip.",
		scope = "global",
		period = "alltime",
		recordKey = "largestBank",
		format = "energy",
	},
	{
		id = "total_banked",
		name = "Total Banked",
		description = "Lifetime energy secured.",
		scope = "global",
		period = "alltime",
		recordKey = "totalBanked",
		format = "energy",
	},
	{
		id = "total_banked_weekly",
		name = "Banked This Week",
		description = "Energy secured since Monday.",
		scope = "global",
		period = "weekly",
		recordKey = "totalBanked",
		-- A weekly board on a lifetime counter would just be the all-time board with
		-- a different name, so this one tracks the delta the player has banked since
		-- the week rolled over.
		delta = true,
		format = "energy",
	},
	{
		id = "highest_multiplier",
		name = "Highest Multiplier",
		description = "The deepest chain anyone has held together.",
		scope = "global",
		period = "alltime",
		recordKey = "highestMultiplier",
		format = "multiplier",
	},
	{
		id = "longest_chain",
		name = "Longest Chain",
		description = "Consecutive captures without breaking.",
		scope = "global",
		period = "alltime",
		recordKey = "longestChain",
		format = "integer",
	},
	{
		id = "level",
		name = "Level",
		description = "Runner level.",
		scope = "global",
		period = "alltime",
		source = "level",
		format = "integer",
	},
	{
		id = "prestige",
		name = "Prestige",
		description = "Runners who started again on purpose.",
		scope = "global",
		period = "alltime",
		source = "prestige",
		format = "integer",
	},

	-- Server boards. Cheap, live, and the ones worth looking at mid-session.
	{
		id = "server_banked",
		name = "Banked — This Server",
		description = "Energy secured since you joined this server.",
		scope = "server",
		source = "sessionBanked",
		format = "energy",
	},
	{
		id = "server_captures",
		name = "Captures — This Server",
		description = "Captures landed on this server.",
		scope = "server",
		source = "sessionCaptures",
		format = "integer",
	},
	{
		id = "server_depth",
		name = "Deepest Region — This Server",
		description = "How far in anyone here has reached.",
		scope = "server",
		source = "deepestRegionReached",
		format = "region",
	},
}

-- OrderedDataStore values must be integers. Energy is fractional, so it is scaled
-- and rounded on the way in and divided on the way out; one decimal place is more
-- than a leaderboard needs and keeps the value well inside the 64-bit range.
local ENERGY_SCALE = 10

local PAGE_SIZE = 10
local MAX_PAGE = 10

-- How long a fetched page is served from cache. Thirty seconds means a busy server
-- makes two calls a minute per board rather than one per request.
local PAGE_CACHE_SECONDS = Balance.Network.LEADERBOARD_SYNC_INTERVAL

-- Minimum gap between two global writes for the same player and board.
local WRITE_COOLDOWN_SECONDS = 60

-- Server boards are rebuilt on this cadence rather than on every change.
local SERVER_BOARD_REBUILD_SECONDS = 5

function LeaderboardService:Init()
	self._boards = {}
	self._boardOrder = {}
	for _, board in ipairs(BOARDS) do
		self._boards[board.id] = board
		table.insert(self._boardOrder, board.id)
	end

	-- boardKey -> OrderedDataStore (or nil when the platform is unavailable)
	self._stores = {}
	-- boardKey -> { fetchedAt, page -> { entries } }
	self._pageCache = {}
	-- boardId -> { [userId] = { value, writtenAt } }
	self._lastWritten = {}
	-- boardId -> { [userId] = value } awaiting a flush
	self._pendingWrites = {}
	-- boardId -> { entries }
	self._serverBoards = {}
	-- userId -> name, so a page render is not a hundred web calls
	self._nameCache = {}

	-- Per-session counters that the server boards read. Reset when a player joins,
	-- which is what makes "this server" mean what it says.
	self._session = {}

	self._useMockStore = false
	self._mock = {}

	self._lastRebuild = 0
	self._accumulator = 0

	self.BoardUpdated = Signal.new("LeaderboardService.BoardUpdated")

	self._stats = { writes = 0, writeFailures = 0, fetches = 0, fetchFailures = 0, cacheHits = 0 }
end

function LeaderboardService:Start()
	self._data = self.Registry:Get("DataService")
	self._analytics = self.Registry:Find("AnalyticsService")

	Net.OnServerEvent("RequestLeaderboard", function(player, boardId, page)
		return self:GetPage(player, boardId, page)
	end)

	Players.PlayerAdded:Connect(function(player)
		self._session[player.UserId] = { banked = 0, captures = 0, joinedAt = os.clock() }
		self:_buildLeaderstats(player)
	end)

	Players.PlayerRemoving:Connect(function(player)
		self:_flushPlayer(player.UserId)
		self._session[player.UserId] = nil
	end)

	for _, player in ipairs(Players:GetPlayers()) do
		self._session[player.UserId] = { banked = 0, captures = 0, joinedAt = os.clock() }
		self:_buildLeaderstats(player)
	end
end

function LeaderboardService:Ready()
	local bank = self.Registry:Find("BankService")
	if bank and bank.Banked then
		bank.Banked:Connect(function(player: Player, amount: number)
			local session = self._session[player.UserId]
			if session and type(amount) == "number" then
				session.banked += amount
			end
		end)
	end

	local capture = self.Registry:Find("CaptureService")
	if capture and capture.Captured then
		capture.Captured:Connect(function(player: Player)
			local session = self._session[player.UserId]
			if session then
				session.captures += 1
			end
		end)
	end

	-- Everything a global board reads that is not a record: level and prestige move
	-- rarely enough to submit on the event itself.
	local progression = self.Registry:Find("ProgressionService")
	if progression and progression.LevelledUp then
		progression.LevelledUp:Connect(function(player: Player, level: number)
			self:Submit(player, "level", level)
		end)
	end

	local prestige = self.Registry:Find("PrestigeService")
	if prestige and prestige.Prestiged then
		prestige.Prestiged:Connect(function(player: Player, rank: number)
			self:Submit(player, "prestige", rank)
		end)
	end

	-- Seed from the loaded profile so a returning player appears on the boards
	-- without having to do anything first.
	if self._data.ProfileLoaded then
		self._data.ProfileLoaded:Connect(function(player: Player)
			self:SubmitAllFromProfile(player)
		end)
	end
end

-- ============================================================================
-- Store access
-- ============================================================================

--[[
	The key a board writes into. Weekly boards stamp the ISO week into the key, so
	the reset is a consequence of the calendar rather than a scheduled job that has
	to run on exactly one server at exactly the right moment.
]]
function LeaderboardService:_storeKey(board: any): string
	if board.period == "weekly" then
		local now = os.date("!*t")
		-- Days since the epoch, shifted so the week starts on Monday.
		local days = math.floor(os.time({
			year = now.year, month = now.month, day = now.day, hour = 12,
		}) / 86400)
		local week = math.floor((days + 3) / 7)
		return ("bts_%s_w%d"):format(board.id, week)
	end
	return "bts_" .. board.id
end

function LeaderboardService:_getStore(board: any)
	local key = self:_storeKey(board)
	if self._stores[key] ~= nil then
		return self._stores[key]
	end

	local ok, store = pcall(function()
		return DataStoreService:GetOrderedDataStore(key)
	end)

	if ok and store then
		self._stores[key] = store
		return store
	end

	-- Same fallback DataService takes: a local session with no API access still gets
	-- working boards, they just do not leave the machine.
	if not self._useMockStore then
		self._useMockStore = true
		warn("[LeaderboardService] OrderedDataStore unavailable; boards are local to this server.")
	end
	self._stores[key] = false
	return nil
end

function LeaderboardService:_mockBoard(key: string)
	self._mock[key] = self._mock[key] or {}
	return self._mock[key]
end

-- ============================================================================
-- Submission
-- ============================================================================

--[[ Scales a value into the integer form the store requires. ]]
local function encodeValue(board: any, value: number): number
	if board.format == "energy" then
		return math.floor(value * ENERGY_SCALE + 0.5)
	end
	if board.format == "multiplier" then
		return math.floor(value * 100 + 0.5)
	end
	return math.floor(value + 0.5)
end

local function decodeValue(board: any, stored: number): number
	if board.format == "energy" then
		return stored / ENERGY_SCALE
	end
	if board.format == "multiplier" then
		return stored / 100
	end
	return stored
end

--[[
	Called by ProgressionService whenever a personal record falls. Fans the record
	out to every board that reads it.
]]
function LeaderboardService:SubmitRecord(player: Player, recordKey: string, value: number)
	for _, board in ipairs(BOARDS) do
		if board.scope == "global" and board.recordKey == recordKey then
			if board.delta then
				self:Submit(player, board.id, self:_weeklyDelta(player, board, value))
			else
				self:Submit(player, board.id, value)
			end
		end
	end
end

--[[
	A weekly board on a lifetime counter tracks progress since the week rolled over.
	The baseline is stamped on the profile the first time the player is seen in a
	given week, so it survives a rejoin and costs one number.
]]
function LeaderboardService:_weeklyDelta(player: Player, board: any, lifetimeValue: number): number
	local profile = self._data:GetProfile(player)
	if not profile then
		return 0
	end

	profile.weeklyBaselines = profile.weeklyBaselines or {}

	local key = self:_storeKey(board)
	local baseline = profile.weeklyBaselines[board.id]

	if not baseline or baseline.key ~= key then
		baseline = { key = key, value = lifetimeValue }
		profile.weeklyBaselines[board.id] = baseline
		-- Old weeks are dead weight on every future save.
		for boardId, entry in pairs(profile.weeklyBaselines) do
			local otherBoard = self._boards[boardId]
			if otherBoard and entry.key ~= self:_storeKey(otherBoard) then
				profile.weeklyBaselines[boardId] = nil
			end
		end
		self._data:MarkDirty(player)
	end

	return math.max(0, lifetimeValue - baseline.value)
end

--[[
	Queues a value for a global board. The write itself happens on the flush, and
	only if this is genuinely better than what this server last wrote.
]]
function LeaderboardService:Submit(player: Player, boardId: string, value: number)
	local board = self._boards[boardId]
	if not board or board.scope ~= "global" then
		return
	end
	if type(value) ~= "number" or value ~= value or value <= 0 then
		return
	end

	local pending = self._pendingWrites[boardId]
	if not pending then
		pending = {}
		self._pendingWrites[boardId] = pending
	end

	local existing = pending[player.UserId]
	if existing and existing >= value then
		return
	end
	pending[player.UserId] = value
end

--[[ Submits every global board's value from the player's current profile. ]]
function LeaderboardService:SubmitAllFromProfile(player: Player)
	local profile = self._data:GetProfile(player)
	if not profile then
		return
	end

	for _, board in ipairs(BOARDS) do
		if board.scope ~= "global" then
			continue
		end

		local value
		if board.recordKey then
			value = profile.records and profile.records[board.recordKey]
			if value and board.delta then
				value = self:_weeklyDelta(player, board, value)
			end
		elseif board.source == "level" then
			value = profile.level
		elseif board.source == "prestige" then
			value = profile.prestige
		end

		if value and value > 0 then
			self:Submit(player, board.id, value)
		end
	end
end

--[[
	Writes queued values that have cleared their cooldown. Returns the number of
	writes attempted, which is what the boot report and the admin console read.
]]
function LeaderboardService:Flush(): number
	local now = os.clock()
	local written = 0

	for boardId, pending in pairs(self._pendingWrites) do
		local board = self._boards[boardId]
		if not board then
			continue
		end

		local lastForBoard = self._lastWritten[boardId]
		if not lastForBoard then
			lastForBoard = {}
			self._lastWritten[boardId] = lastForBoard
		end

		for userId, value in pairs(pending) do
			local last = lastForBoard[userId]
			local cleared = not last or (now - last.writtenAt) >= WRITE_COOLDOWN_SECONDS
			local better = not last or value > last.value

			if cleared and better then
				if self:_write(board, userId, value) then
					lastForBoard[userId] = { value = value, writtenAt = now }
					written += 1
				end
				pending[userId] = nil
			elseif not better then
				-- Nothing to write and nothing to wait for.
				pending[userId] = nil
			end
		end
	end

	return written
end

function LeaderboardService:_write(board: any, userId: number, value: number): boolean
	local encoded = encodeValue(board, value)
	if encoded <= 0 then
		return false
	end

	local store = self:_getStore(board)
	if not store then
		local mock = self:_mockBoard(self:_storeKey(board))
		mock[userId] = encoded
		self._stats.writes += 1
		return true
	end

	local ok, err = pcall(function()
		-- SetAsync rather than UpdateAsync: every board here is a high-water mark and
		-- the caller has already established this beats the last written value, so a
		-- read-modify-write would double the budget cost for nothing.
		store:SetAsync(tostring(userId), encoded)
	end)

	if ok then
		self._stats.writes += 1
		-- The page cache is now stale for this board.
		self._pageCache[self:_storeKey(board)] = nil
		return true
	end

	self._stats.writeFailures += 1
	warn(("[LeaderboardService] write failed on %s: %s"):format(board.id, tostring(err)))
	return false
end

function LeaderboardService:_flushPlayer(userId: number)
	-- A leaving player's best value is written immediately rather than waiting out
	-- the cooldown: they are gone, so there will be no later flush for them.
	for boardId, pending in pairs(self._pendingWrites) do
		local value = pending[userId]
		if value then
			local board = self._boards[boardId]
			if board and self:_write(board, userId, value) then
				local lastForBoard = self._lastWritten[boardId] or {}
				lastForBoard[userId] = { value = value, writtenAt = os.clock() }
				self._lastWritten[boardId] = lastForBoard
			end
			pending[userId] = nil
		end
	end

	for _, lastForBoard in pairs(self._lastWritten) do
		lastForBoard[userId] = nil
	end
end

-- ============================================================================
-- Reading
-- ============================================================================

function LeaderboardService:_nameFor(userId: number): string
	local cached = self._nameCache[userId]
	if cached then
		return cached
	end

	-- A player already here needs no web call at all.
	local player = Players:GetPlayerByUserId(userId)
	if player then
		self._nameCache[userId] = player.DisplayName
		return player.DisplayName
	end

	local ok, name = pcall(function()
		return Players:GetNameFromUserIdAsync(userId)
	end)
	local resolved = (ok and name) or ("Runner %d"):format(userId)
	self._nameCache[userId] = resolved
	return resolved
end

--[[
	One page of a board. Global pages come from the cache when it is warm; server
	boards are already in memory and are simply sliced.
]]
function LeaderboardService:GetPage(player: Player, boardId: string, page: number)
	local board = self._boards[boardId]
	if not board then
		return nil
	end

	page = math.clamp(math.floor(page or 1), 1, MAX_PAGE)

	local entries
	if board.scope == "server" then
		entries = self:_serverPage(board, page)
	else
		entries = self:_globalPage(board, page)
	end

	local viewerRank, viewerValue
	for _, entry in ipairs(entries) do
		if entry.userId == player.UserId then
			viewerRank, viewerValue = entry.rank, entry.value
		end
	end

	return {
		boardId = board.id,
		name = board.name,
		description = board.description,
		scope = board.scope,
		format = board.format,
		page = page,
		pageSize = PAGE_SIZE,
		maxPage = MAX_PAGE,
		entries = entries,
		viewerRank = viewerRank,
		viewerValue = viewerValue,
		-- Told plainly rather than hidden: a board that is local to this server and
		-- one that spans every server are different claims.
		serverLocalOnly = (self._useMockStore and board.scope == "global") or nil,
	}
end

function LeaderboardService:_globalPage(board: any, page: number)
	local key = self:_storeKey(board)
	local cache = self._pageCache[key]

	if cache and (os.clock() - cache.fetchedAt) < PAGE_CACHE_SECONDS and cache.pages[page] then
		self._stats.cacheHits += 1
		return cache.pages[page]
	end

	local store = self:_getStore(board)
	local rows

	if not store then
		rows = {}
		for userId, value in pairs(self:_mockBoard(key)) do
			table.insert(rows, { userId = userId, value = value })
		end
		table.sort(rows, function(a, b)
			return a.value > b.value
		end)
	else
		local ok, result = pcall(function()
			-- Ascending false, one page deep. Paging past the first page costs another
			-- call, which is why MAX_PAGE is ten rather than unbounded.
			local pages = store:GetSortedAsync(false, PAGE_SIZE * page)
			return pages:GetCurrentPage()
		end)

		if not ok then
			self._stats.fetchFailures += 1
			warn(("[LeaderboardService] fetch failed on %s: %s"):format(board.id, tostring(result)))
			return {}
		end

		self._stats.fetches += 1
		rows = {}
		for _, row in ipairs(result) do
			table.insert(rows, { userId = tonumber(row.key) or 0, value = row.value })
		end
	end

	local pages = {}
	for index, row in ipairs(rows) do
		local pageIndex = math.floor((index - 1) / PAGE_SIZE) + 1
		pages[pageIndex] = pages[pageIndex] or {}
		table.insert(pages[pageIndex], {
			rank = index,
			userId = row.userId,
			name = self:_nameFor(row.userId),
			value = decodeValue(board, row.value),
		})
	end

	self._pageCache[key] = { fetchedAt = os.clock(), pages = pages }
	return pages[page] or {}
end

function LeaderboardService:_serverPage(board: any, page: number)
	local entries = self._serverBoards[board.id] or {}
	local out = {}
	local first = (page - 1) * PAGE_SIZE + 1

	for index = first, math.min(first + PAGE_SIZE - 1, #entries) do
		table.insert(out, entries[index])
	end

	return out
end

--[[ Rebuilds every server board from live profiles. ]]
function LeaderboardService:RebuildServerBoards()
	for _, board in ipairs(BOARDS) do
		if board.scope ~= "server" then
			continue
		end

		local rows = {}

		for _, player in ipairs(Players:GetPlayers()) do
			local value = 0
			local session = self._session[player.UserId]

			if board.source == "sessionBanked" then
				value = session and session.banked or 0
			elseif board.source == "sessionCaptures" then
				value = session and session.captures or 0
			else
				local profile = self._data:GetProfile(player)
				value = profile and profile.records and profile.records[board.source] or 0
			end

			if value > 0 then
				table.insert(rows, {
					userId = player.UserId,
					name = player.DisplayName,
					value = value,
				})
			end
		end

		table.sort(rows, function(a, b)
			if a.value ~= b.value then
				return a.value > b.value
			end
			-- A stable tiebreak, so two players on zero do not swap places every tick.
			return a.userId < b.userId
		end)

		for index, row in ipairs(rows) do
			row.rank = index
			if board.format == "region" then
				-- The record stores a region's `order`, which is not promised to equal
				-- its index in the list, so it is looked up rather than indexed.
				for _, region in ipairs(Regions.List) do
					if region.order == math.floor(row.value) then
						row.label = region.name
						break
					end
				end
			end
		end

		self._serverBoards[board.id] = rows
	end

	self.BoardUpdated:Fire("server")
end

-- ============================================================================
-- Roblox player list
-- ============================================================================

--[[
	The built-in player list is the one leaderboard every player sees without
	opening anything, so it carries the two numbers that describe a runner at a
	glance. It is not a substitute for the real boards; it is an advertisement for
	them.
]]
function LeaderboardService:_buildLeaderstats(player: Player)
	if player:FindFirstChild("leaderstats") then
		return
	end

	local folder = Instance.new("Folder")
	folder.Name = "leaderstats"

	local level = Instance.new("IntValue")
	level.Name = "Level"
	level.Value = 1
	level.Parent = folder

	local banked = Instance.new("IntValue")
	banked.Name = "Banked"
	banked.Value = 0
	banked.Parent = folder

	folder.Parent = player
end

function LeaderboardService:_syncLeaderstats()
	for _, player in ipairs(Players:GetPlayers()) do
		local folder = player:FindFirstChild("leaderstats")
		if not folder then
			continue
		end

		local profile = self._data:GetProfile(player)
		if not profile then
			continue
		end

		-- Assigned through a local rather than `(x :: IntValue).Value = ...` directly:
		-- a parenthesised expression opening a statement reads as a call to whatever
		-- came before it.
		local level = folder:FindFirstChild("Level") :: IntValue?
		if level then
			level.Value = profile.level or 1
		end

		local session = self._session[player.UserId]
		local banked = folder:FindFirstChild("Banked") :: IntValue?
		if banked then
			banked.Value = math.floor(session and session.banked or 0)
		end
	end
end

-- ============================================================================
-- Ticking
-- ============================================================================

function LeaderboardService:Tick()
	local now = os.clock()

	if now - self._lastRebuild >= SERVER_BOARD_REBUILD_SECONDS then
		self._lastRebuild = now
		self:RebuildServerBoards()
		self:_syncLeaderstats()
	end

	-- Flushing on the same cadence as the rebuild would be wasteful: the write
	-- cooldown means most flushes have nothing to do, and the ones that do are
	-- yield-heavy. Once every LEADERBOARD_SYNC_INTERVAL is plenty.
	self._accumulator += 0.5
	if self._accumulator >= Balance.Network.LEADERBOARD_SYNC_INTERVAL then
		self._accumulator = 0
		task.spawn(function()
			self:Flush()
		end)
	end
end

function LeaderboardService:GetBoards()
	local out = {}
	for _, boardId in ipairs(self._boardOrder) do
		local board = self._boards[boardId]
		table.insert(out, {
			id = board.id,
			name = board.name,
			description = board.description,
			scope = board.scope,
			period = board.period,
			format = board.format,
		})
	end
	return out
end

function LeaderboardService:GetStats()
	local pendingCount = 0
	for _, pending in pairs(self._pendingWrites) do
		for _ in pairs(pending) do
			pendingCount += 1
		end
	end

	return {
		boards = #BOARDS,
		writes = self._stats.writes,
		writeFailures = self._stats.writeFailures,
		fetches = self._stats.fetches,
		fetchFailures = self._stats.fetchFailures,
		cacheHits = self._stats.cacheHits,
		pendingWrites = pendingCount,
		usingMockStore = self._useMockStore,
	}
end

return LeaderboardService
