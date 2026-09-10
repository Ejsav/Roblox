--!strict
--[[
	ServiceRegistry
	---------------
	Dependency-ordered lifecycle management for both the server's services and the
	client's controllers.

	Lifecycle, in strict order across ALL services before moving to the next stage:
		1. Register  every service object is created and named
		2. Init      wire up state; dependencies are resolvable but NOT started
		3. Start     begin doing work; every other service is fully initialised
		4. Ready     everything is running; safe to touch players and the world

	Splitting Init from Start is what removes the entire class of "service A used
	service B before B had loaded its config" bugs. Nothing in Init may call into
	another service's behaviour, only read its handle.

	Dependency order is resolved topologically, and a cycle is a hard error at boot
	rather than an intermittent failure at runtime.
]]

local Signal = require(script.Parent.Signal)

local ServiceRegistry = {}
ServiceRegistry.__index = ServiceRegistry

export type Service = {
	Name: string,
	Dependencies: { string }?,
	Priority: number?,
	Init: ((self: any) -> ())?,
	Start: ((self: any) -> ())?,
	Ready: ((self: any) -> ())?,
	Stop: ((self: any) -> ())?,
}

function ServiceRegistry.new(label: string)
	return setmetatable({
		_label = label,
		_services = {},
		_order = {},
		_started = false,
		_bootReport = {},
		ServiceStarted = Signal.new(label .. ".ServiceStarted"),
		BootCompleted = Signal.new(label .. ".BootCompleted"),
	}, ServiceRegistry)
end

--[[ Registers a service object. Must happen before Boot. ]]
function ServiceRegistry:Register(service: Service)
	assert(not self._started, "cannot register after boot")
	assert(type(service) == "table", "service must be a table")
	assert(type(service.Name) == "string" and #service.Name > 0, "service needs a Name")
	assert(not self._services[service.Name], "duplicate service: " .. service.Name)

	self._services[service.Name] = service
	return service
end

--[[ Retrieves a registered service by name. Errors if missing, because a typo'd
     dependency should fail loudly at boot rather than silently return nil. ]]
function ServiceRegistry:Get(name: string): any
	local service = self._services[name]
	if not service then
		error(("[%s] unknown service '%s'"):format(self._label, tostring(name)), 2)
	end
	return service
end

--[[ Non-throwing lookup, for genuinely optional dependencies. ]]
function ServiceRegistry:Find(name: string): any?
	return self._services[name]
end

function ServiceRegistry:GetAll(): { [string]: any }
	return self._services
end

--[[
	Produces a boot order satisfying every declared dependency.
	Uses depth-first traversal with an explicit visiting set so a cycle is reported
	with the exact path that formed it.
]]
function ServiceRegistry:ResolveOrder(): { string }
	local order = {}
	local visited = {}
	local visiting = {}
	local path = {}

	local names = {}
	for name in pairs(self._services) do
		table.insert(names, name)
	end
	-- Sort first so that services with no dependency relationship boot in a stable
	-- order, then respect explicit Priority for the same reason.
	table.sort(names, function(a, b)
		local priorityA = self._services[a].Priority or 100
		local priorityB = self._services[b].Priority or 100
		if priorityA ~= priorityB then
			return priorityA < priorityB
		end
		return a < b
	end)

	local function visit(name: string)
		if visited[name] then
			return
		end
		if visiting[name] then
			table.insert(path, name)
			error(("[%s] dependency cycle: %s"):format(self._label, table.concat(path, " -> ")), 0)
		end

		local service = self._services[name]
		if not service then
			error(("[%s] service '%s' is required but not registered"):format(self._label, name), 0)
		end

		visiting[name] = true
		table.insert(path, name)

		local dependencies = service.Dependencies or {}
		-- Sort dependencies for determinism.
		local sortedDependencies = table.clone(dependencies)
		table.sort(sortedDependencies)
		for _, dependency in ipairs(sortedDependencies) do
			visit(dependency)
		end

		table.remove(path)
		visiting[name] = nil
		visited[name] = true
		table.insert(order, name)
	end

	for _, name in ipairs(names) do
		visit(name)
	end

	self._order = order
	return order
end

--[[
	Runs one lifecycle stage across every service in dependency order.
	Errors are caught and recorded so a single broken service does not prevent the
	rest of the game from coming up — a partially working game is far more debuggable
	than a black screen.
]]
function ServiceRegistry:_runStage(stageName: string): { { name: string, ms: number, error: string? } }
	local results = {}
	for _, name in ipairs(self._order) do
		local service = self._services[name]
		local method = (service :: any)[stageName]
		if type(method) == "function" then
			local startClock = os.clock()
			local ok, err = pcall(method, service)
			local elapsedMs = (os.clock() - startClock) * 1000
			if ok then
				table.insert(results, { name = name, ms = elapsedMs })
			else
				table.insert(results, { name = name, ms = elapsedMs, error = tostring(err) })
				warn(("[%s] %s:%s failed: %s"):format(self._label, name, stageName, tostring(err)))
			end
		end
	end
	return results
end

--[[
	Boots every registered service. Returns a report suitable for printing.
]]
function ServiceRegistry:Boot()
	assert(not self._started, "already booted")
	self._started = true

	local bootStart = os.clock()
	self:ResolveOrder()

	local report = {
		label = self._label,
		order = table.clone(self._order),
		init = self:_runStage("Init"),
		start = self:_runStage("Start"),
		ready = self:_runStage("Ready"),
	}

	for _, name in ipairs(self._order) do
		self.ServiceStarted:Fire(name, self._services[name])
	end

	report.totalMs = (os.clock() - bootStart) * 1000
	report.failures = {}
	for _, stage in ipairs({ "init", "start", "ready" }) do
		for _, entry in ipairs(report[stage]) do
			if entry.error then
				table.insert(report.failures, ("%s:%s — %s"):format(entry.name, stage, entry.error))
			end
		end
	end

	self._bootReport = report
	self.BootCompleted:Fire(report)
	return report
end

--[[ Formats the boot report as a readable multi-line block for the Output window. ]]
function ServiceRegistry:FormatReport(report: any?): string
	local data = report or self._bootReport
	if not data or not data.order then
		return "[" .. self._label .. "] no boot report"
	end

	local lines = {}
	table.insert(lines, ("=== %s boot: %d services in %.1fms ==="):format(data.label, #data.order, data.totalMs or 0))

	-- Surface only the services that took real time; a wall of sub-millisecond
	-- entries buries the one that took 400ms.
	local slow = {}
	for _, stage in ipairs({ "init", "start", "ready" }) do
		for _, entry in ipairs(data[stage] or {}) do
			if entry.ms >= 1 then
				table.insert(slow, ("  %-24s %-6s %6.1fms"):format(entry.name, stage, entry.ms))
			end
		end
	end
	if #slow > 0 then
		table.insert(lines, "  --- slowest stages ---")
		for _, line in ipairs(slow) do
			table.insert(lines, line)
		end
	end

	if #(data.failures or {}) > 0 then
		table.insert(lines, ("  !!! %d FAILURES:"):format(#data.failures))
		for _, failure in ipairs(data.failures) do
			table.insert(lines, "    " .. failure)
		end
	else
		table.insert(lines, "  all services healthy")
	end

	return table.concat(lines, "\n")
end

--[[ Runs Stop in reverse dependency order. Used on shutdown. ]]
function ServiceRegistry:Shutdown()
	for index = #self._order, 1, -1 do
		local service = self._services[self._order[index]]
		if type((service :: any).Stop) == "function" then
			local ok, err = pcall((service :: any).Stop, service)
			if not ok then
				warn(("[%s] %s:Stop failed: %s"):format(self._label, service.Name, tostring(err)))
			end
		end
	end
end

function ServiceRegistry:GetBootReport()
	return self._bootReport
end

return ServiceRegistry
