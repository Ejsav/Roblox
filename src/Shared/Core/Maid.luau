--!strict
--[[
	Maid
	----
	Deterministic cleanup container. Every controller, service, storm instance and UI
	screen owns a Maid; when it dies the Maid tears down connections, instances, tasks
	and arbitrary teardown closures in reverse insertion order.

	Reverse order matters: a UI screen typically adds its frame first and its
	connections after, and connections must die before the instances they reference.
]]

local Maid = {}
Maid.__index = Maid

export type Task = RBXScriptConnection | Instance | thread | () -> () | { Destroy: (any) -> () } | { Disconnect: (any) -> () }

function Maid.new()
	return setmetatable({
		_tasks = {},
		_n = 0,
		_destroyed = false,
	}, Maid)
end

function Maid.is(value: any): boolean
	return type(value) == "table" and getmetatable(value) == Maid
end

--[[ Adds a task and returns it for convenient chaining. ]]
function Maid:Add<T>(item: T): T
	if self._destroyed then
		-- Adding to a dead maid should clean up immediately rather than leak.
		Maid._cleanupTask(item)
		return item
	end
	self._n += 1
	self._tasks[self._n] = item
	return item
end

Maid.GiveTask = Maid.Add

--[[ Adds a task under a named key, cleaning up any previous task with that key. ]]
function Maid:Set<T>(key: string, item: T?): T?
	local existing = self._tasks[key]
	if existing ~= nil then
		Maid._cleanupTask(existing)
	end
	self._tasks[key] = item
	return item
end

function Maid:Get(key: string): any
	return self._tasks[key]
end

--[[ Cleans up a single named task without touching the rest. ]]
function Maid:Clear(key: string)
	local existing = self._tasks[key]
	if existing ~= nil then
		self._tasks[key] = nil
		Maid._cleanupTask(existing)
	end
end

function Maid._cleanupTask(item: any)
	local kind = typeof(item)
	if kind == "function" then
		local ok, err = pcall(item)
		if not ok then
			warn("[Maid] teardown function errored: " .. tostring(err))
		end
	elseif kind == "RBXScriptConnection" then
		item:Disconnect()
	elseif kind == "Instance" then
		item:Destroy()
	elseif kind == "thread" then
		-- Cancelling the currently running thread would abort our own cleanup pass.
		if coroutine.running() ~= item then
			pcall(task.cancel, item)
		end
	elseif kind == "table" then
		if type(item.Destroy) == "function" then
			local ok, err = pcall(item.Destroy, item)
			if not ok then
				warn("[Maid] Destroy errored: " .. tostring(err))
			end
		elseif type(item.Disconnect) == "function" then
			pcall(item.Disconnect, item)
		end
	end
end

--[[ Runs every task in reverse insertion order and empties the maid for reuse. ]]
function Maid:DoCleaning()
	local tasks = self._tasks
	local n = self._n

	-- Numeric tasks, newest first.
	for i = n, 1, -1 do
		local item = tasks[i]
		if item ~= nil then
			tasks[i] = nil
			Maid._cleanupTask(item)
		end
	end
	self._n = 0

	-- Named tasks (order is not meaningful for keyed entries).
	for key, item in pairs(tasks) do
		tasks[key] = nil
		Maid._cleanupTask(item)
	end
end

function Maid:Destroy()
	self:DoCleaning()
	self._destroyed = true
end

return Maid
