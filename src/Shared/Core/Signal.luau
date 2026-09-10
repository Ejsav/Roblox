--!strict
--[[
	Signal
	------
	A lightweight, allocation-conscious signal implementation used across BORROW THE STORM
	for decoupled communication between systems.

	Chosen over BindableEvents because:
	  * No serialization boundary (tables, functions and cyclic values pass through intact)
	  * Deferred-free synchronous dispatch when we need deterministic ordering
	  * Connections are reusable objects pulled from a free list, so high-frequency
	    gameplay signals (storm ticks, capture windows) do not thrash the GC.

	Usage:
		local sig = Signal.new("StormSpawned")
		local conn = sig:Connect(function(storm) ... end)
		sig:Fire(storm)
		conn:Disconnect()
]]

local Signal = {}
Signal.__index = Signal

local Connection = {}
Connection.__index = Connection

-- Free list of recycled connection objects.
local freeConnections: { any } = {}
local freeCount = 0

local function acquireConnection(signal, fn, once: boolean)
	local conn
	if freeCount > 0 then
		conn = freeConnections[freeCount]
		freeConnections[freeCount] = nil
		freeCount -= 1
		conn._signal = signal
		conn._fn = fn
		conn._once = once
		conn._next = nil
		conn.Connected = true
	else
		conn = setmetatable({
			_signal = signal,
			_fn = fn,
			_once = once,
			_next = nil,
			Connected = true,
		}, Connection)
	end
	return conn
end

function Connection:Disconnect()
	if not self.Connected then
		return
	end
	self.Connected = false

	local signal = self._signal
	if signal._head == self then
		signal._head = self._next
	else
		local prev = signal._head
		while prev and prev._next ~= self do
			prev = prev._next
		end
		if prev then
			prev._next = self._next
		end
	end

	signal._count -= 1

	self._signal = nil
	self._fn = nil
	self._next = nil

	if freeCount < 128 then
		freeCount += 1
		freeConnections[freeCount] = self
	end
end

Connection.Destroy = Connection.Disconnect

--[[ Creates a new signal. `name` is optional and only used for debugging output. ]]
function Signal.new(name: string?)
	return setmetatable({
		_head = nil,
		_count = 0,
		_name = name or "Signal",
	}, Signal)
end

function Signal:Connect(fn: (...any) -> ())
	assert(type(fn) == "function", "Signal:Connect expects a function")
	local conn = acquireConnection(self, fn, false)
	conn._next = self._head
	self._head = conn
	self._count += 1
	return conn
end

--[[ Connects a handler that automatically disconnects after its first invocation. ]]
function Signal:Once(fn: (...any) -> ())
	assert(type(fn) == "function", "Signal:Once expects a function")
	local conn = acquireConnection(self, fn, true)
	conn._next = self._head
	self._head = conn
	self._count += 1
	return conn
end

--[[
	Fires all connected handlers synchronously in reverse-connection order.
	Handler errors are caught and reported so one bad listener cannot break a
	gameplay-critical broadcast (e.g. a storm despawn).
]]
function Signal:Fire(...)
	local conn = self._head
	while conn do
		-- Cache next before invoking; the handler may disconnect itself.
		local nextConn = conn._next
		if conn.Connected then
			local fn = conn._fn
			if conn._once then
				conn:Disconnect()
			end
			local ok, err = pcall(fn, ...)
			if not ok then
				warn(("[%s] listener error: %s"):format(self._name, tostring(err)))
			end
		end
		conn = nextConn
	end
end

--[[ Fires each handler on its own coroutine. Use when handlers may yield. ]]
function Signal:FireDeferred(...)
	local args = table.pack(...)
	local conn = self._head
	while conn do
		local nextConn = conn._next
		if conn.Connected then
			local fn = conn._fn
			if conn._once then
				conn:Disconnect()
			end
			task.spawn(function()
				fn(table.unpack(args, 1, args.n))
			end)
		end
		conn = nextConn
	end
end

--[[ Yields the calling coroutine until the next Fire, returning its arguments. ]]
function Signal:Wait(): ...any
	local thread = coroutine.running()
	local conn
	conn = self:Connect(function(...)
		conn:Disconnect()
		task.spawn(thread, ...)
	end)
	return coroutine.yield()
end

function Signal:GetConnectionCount(): number
	return self._count
end

function Signal:DisconnectAll()
	local conn = self._head
	while conn do
		local nextConn = conn._next
		conn.Connected = false
		conn._signal = nil
		conn._fn = nil
		conn._next = nil
		conn = nextConn
	end
	self._head = nil
	self._count = 0
end

Signal.Destroy = Signal.DisconnectAll

return Signal
