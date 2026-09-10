--!strict
--[[
	BORROW THE STORM — server bootstrap.

	Responsibilities, in order:
	  1. Verify content integrity (Studio only) so a broken config fails loudly here
	     rather than as a mystery three systems deep.
	  2. Create the remote instances before any service tries to bind to one.
	  3. Register every service and boot them through the Init/Start/Ready lifecycle.
	  4. Drive the three tick rates the game runs on.
	  5. Print a boot report, because a server that came up silently tells you nothing.

	Three tick rates rather than one:
	  * Step   — every heartbeat. Simulation that must feel continuous: storms,
	             carry instability, combat, abilities, region sampling.
	  * Tick   — twice a second. Bookkeeping that a player would never notice being
	             a frame late: cooldown sync, buff expiry, anti-cheat sampling.
	  * Slow   — every few seconds. Persistence and housekeeping: autosave, quest
	             rollover, rate-limit sweeps.

	Splitting them is what keeps a fourteen-thousand-stud world with forty live storm
	cells inside the frame budget.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BTS")
local ServiceRegistry = require(Shared.Core.ServiceRegistry)
local Net = require(Shared.Net)
local Config = require(Shared.Config)

local ServerRoot = ServerScriptService:WaitForChild("BTSServer")
local ServicesFolder = ServerRoot:WaitForChild("Services")
local WorldFolder = ServerRoot:WaitForChild("World")

-- ============================================================================
-- 1. Content integrity
-- ============================================================================

if RunService:IsStudio() then
	local ok, problems = Config.Verify()
	if not ok then
		warn(("[BTS] CONTENT INTEGRITY FAILED — %d problems:\n  %s")
			:format(#problems, table.concat(problems, "\n  ")))
	else
		print("[BTS] content integrity: OK")
	end
end

-- ============================================================================
-- 2. Network surface
-- ============================================================================

Net.InitServer()

-- ============================================================================
-- 3. Services
-- ============================================================================

local registry = ServiceRegistry.new("BTS Server")

--[[
	Registration order is irrelevant — the registry resolves dependencies
	topologically — but the list is grouped by role so it reads as an architecture
	diagram rather than an import list.
]]
local SERVICE_MODULES = {
	-- Foundation
	"DataService",
	"AnalyticsService",
	"AntiCheatService",
	"EconomyService",
	"RegionService",
	"ProgressionService",
	"StatsService",

	-- Core loop
	"CombatService",
	"CarryService",
	"StormService",
	"CaptureService",
	"BankService",

	-- Progression
	"UpgradeService",
	"SkillService",
	"InventoryService",
	"LootService",
	"AbilityService",
	"QuestService",
	"DiscoveryService",
	"MasteryService",
	"WorldEventService",
	"PrestigeService",
	"InteractionService",
	"CraftingService",
	"AchievementService",
	"LeaderboardService",

	-- Lifecycle (last, because it is what admits players)
	"PlayerService",
}

for _, moduleName in ipairs(SERVICE_MODULES) do
	local moduleScript = ServicesFolder:FindFirstChild(moduleName)
	if not moduleScript then
		warn("[BTS] missing service module: " .. moduleName)
		continue
	end
	local ok, service = pcall(require, moduleScript)
	if ok and type(service) == "table" then
		registry:Register(service)
	else
		warn(("[BTS] failed to require %s: %s"):format(moduleName, tostring(service)))
	end
end

-- World generation is a service too, so it participates in the same lifecycle and
-- gets its dependencies resolved rather than racing them.
local worldBuilderModule = WorldFolder:FindFirstChild("WorldBuilder")
if worldBuilderModule then
	local ok, worldBuilder = pcall(require, worldBuilderModule)
	if ok and type(worldBuilder) == "table" then
		registry:Register(worldBuilder)
	else
		warn("[BTS] failed to require WorldBuilder: " .. tostring(worldBuilder))
	end
end

local report = registry:Boot()
print(registry:FormatReport(report))

-- Expose the registry for the admin console and for in-Studio inspection.
_G.BTS = { Registry = registry }

-- ============================================================================
-- 4. Tick loops
-- ============================================================================

local TICK_INTERVAL = 0.5
local SLOW_INTERVAL = 3.0

local stepServices = {}
local tickServices = {}

for _, name in ipairs(registry:ResolveOrder()) do
	local service = registry:Get(name)
	if type((service :: any).Step) == "function" then
		table.insert(stepServices, service)
	end
	if type((service :: any).Tick) == "function" then
		table.insert(tickServices, service)
	end
end

local tickAccumulator = 0
local slowAccumulator = 0

--[[
	The heartbeat loop. Each service's Step is wrapped so one throwing service
	cannot take the whole simulation down — a partially simulating world is far more
	debuggable than a frozen one.
]]
RunService.Heartbeat:Connect(function(deltaTime)
	-- A very large delta means the server stalled (a long datastore call, a Studio
	-- breakpoint). Clamping stops every timed system from resolving at once and
	-- producing a burst of simultaneous strikes and vents.
	local dt = math.min(deltaTime, 0.25)

	for _, service in ipairs(stepServices) do
		local ok, err = pcall(service.Step, service, dt)
		if not ok then
			warn(("[BTS] %s:Step error: %s"):format(service.Name, tostring(err)))
		end
	end

	tickAccumulator += dt
	if tickAccumulator >= TICK_INTERVAL then
		tickAccumulator = 0
		for _, service in ipairs(tickServices) do
			local ok, err = pcall(service.Tick, service)
			if not ok then
				warn(("[BTS] %s:Tick error: %s"):format(service.Name, tostring(err)))
			end
		end

		-- Storm replication rides the tick rather than the heartbeat: twice a second
		-- is plenty for cells that drift at a few studs per second.
		local storms = registry:Find("StormService")
		if storms then
			pcall(function()
				storms:SyncCells()
			end)
		end
	end

	slowAccumulator += dt
	if slowAccumulator >= SLOW_INTERVAL then
		slowAccumulator = 0
		local data = registry:Find("DataService")
		if data then
			pcall(function()
				data:Tick()
			end)
		end
	end
end)

-- ============================================================================
-- 5. Startup report
-- ============================================================================

task.spawn(function()
	-- Wait a moment so the world generator's own report lands after this one.
	task.wait(2)

	local storms = registry:Find("StormService")
	local data = registry:Find("DataService")

	local lines = { "=== BORROW THE STORM — server online ===" }
	table.insert(lines, ("  regions:        %d"):format(#Config.Regions.List))
	table.insert(lines, ("  storm types:    %d"):format(#Config.StormTypes.List))
	table.insert(lines, ("  quests:         %d"):format(#Config.Quests.List))
	table.insert(lines, ("  skill nodes:    %d"):format(#Config.SkillTree.Nodes))
	table.insert(lines, ("  equipment:      %d bases, %d uniques"):format(
		#Config.Equipment.Bases,
		#Config.Equipment.Uniques
	))
	table.insert(lines, ("  world events:   %d"):format(#Config.WorldEvents.List))

	if data then
		local stats = data:GetStats()
		table.insert(lines, ("  datastore:      %s"):format(
			stats.usingMockStore and "IN-MEMORY (no API access — progress will not persist)" or "live"
		))
	end
	if storms then
		table.insert(lines, ("  active cells:   %d"):format(storms:GetStats().cells))
	end

	print(table.concat(lines, "\n"))
end)
