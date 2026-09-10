--!strict
--[[
	BORROW THE STORM — client bootstrap.

	Mirrors the server's lifecycle: controllers are registered, dependency-ordered,
	and taken through Init/Start/Ready before any of them touches the network.

	The client runs one render loop rather than letting each controller connect its
	own RenderStepped, which keeps ordering deterministic — the storm state must
	update before the HUD reads it, or the capture ring lags a frame behind the
	strike it is drawing.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BTS")
local ServiceRegistry = require(Shared.Core.ServiceRegistry)
local Net = require(Shared.Net)
local Balance = require(Shared.Config.Balance)

local ClientRoot = script
local ControllersFolder = ClientRoot:WaitForChild("Controllers")
local EffectsFolder = ClientRoot:WaitForChild("Effects")

local LocalPlayer = Players.LocalPlayer

-- ============================================================================
-- Network
-- ============================================================================

if not Net.InitClient(30) then
	warn("[BTS] client could not reach the remote folder; the server may still be starting")
	return
end

-- ============================================================================
-- Controllers
-- ============================================================================

local registry = ServiceRegistry.new("BTS Client")

local CONTROLLER_MODULES = {
	{ folder = ControllersFolder, name = "InputController" },
	{ folder = EffectsFolder, name = "VfxController" },
	{ folder = ControllersFolder, name = "AudioController" },
	{ folder = ControllersFolder, name = "StormController" },
	{ folder = ControllersFolder, name = "MovementController" },
	{ folder = ControllersFolder, name = "HudController" },
	{ folder = ControllersFolder, name = "MenuController" },
}

for _, entry in ipairs(CONTROLLER_MODULES) do
	local moduleScript = entry.folder:FindFirstChild(entry.name)
	if not moduleScript then
		warn("[BTS] missing controller: " .. entry.name)
		continue
	end
	local ok, controller = pcall(require, moduleScript)
	if ok and type(controller) == "table" then
		registry:Register(controller)
	else
		warn(("[BTS] failed to require %s: %s"):format(entry.name, tostring(controller)))
	end
end

local report = registry:Boot()
if #report.failures > 0 then
	print(registry:FormatReport(report))
end

_G.BTS_CLIENT = { Registry = registry }

-- ============================================================================
-- Render loop
-- ============================================================================

--[[
	One ordered update per frame. The order is the data flow: input has already been
	handled by ContextActionService, storms hold the authoritative-ish state, effects
	read it, and the HUD reads both.
]]
local updateOrder = {}
for _, name in ipairs({ "MovementController", "StormController", "VfxController", "AudioController", "HudController", "MenuController" }) do
	local controller = registry:Find(name)
	if controller and type((controller :: any).Update) == "function" then
		table.insert(updateOrder, controller)
	end
end

RunService.RenderStepped:Connect(function(deltaTime)
	for _, controller in ipairs(updateOrder) do
		local ok, err = pcall(controller.Update, controller, deltaTime)
		if not ok then
			warn(("[BTS] %s:Update error: %s"):format(controller.Name, tostring(err)))
		end
	end
end)

-- ============================================================================
-- Performance sampling
--
-- A rolling frame-time average drives automatic quality selection and is reported
-- to the server for analytics, so device performance is a number rather than a
-- guess when tuning effect budgets.
-- ============================================================================

local frameSamples = {}
local sampleIndex = 0
local currentQuality = "high"
local lastQualityChange = 0
local lastReport = 0

local function detectDeviceKind(): string
	local UserInputService = game:GetService("UserInputService")
	if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		local viewport = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize or Vector2.new(800, 600)
		return viewport.X >= 1000 and "tablet" or "mobile"
	elseif UserInputService.GamepadEnabled and not UserInputService.KeyboardEnabled then
		return "console"
	end
	return "desktop"
end

local deviceKind = detectDeviceKind()

-- Mobile starts conservative and is allowed to climb, rather than starting high and
-- stuttering while it works out it cannot cope.
if deviceKind == "mobile" then
	currentQuality = "low"
elseif deviceKind == "tablet" then
	currentQuality = "medium"
end

local vfx = registry:Find("VfxController")
if vfx then
	vfx:SetQuality(currentQuality)
end

local QUALITY_ORDER = { "low", "medium", "high", "ultra" }

local function adjustQuality(averageMs: number)
	local now = os.clock()
	-- A cooldown between changes stops the quality oscillating on a marginal device.
	if now - lastQualityChange < 8 then
		return
	end

	local index = table.find(QUALITY_ORDER, currentQuality) or 3

	if averageMs > Balance.Performance.AUTO_DOWNGRADE_MS and index > 1 then
		currentQuality = QUALITY_ORDER[index - 1]
		lastQualityChange = now
	elseif averageMs < Balance.Performance.AUTO_UPGRADE_MS and index < #QUALITY_ORDER then
		-- Only climb on desktop; a phone that briefly hits 60fps should not then be
		-- handed the ultra budget.
		if deviceKind == "desktop" or index < 3 then
			currentQuality = QUALITY_ORDER[index + 1]
			lastQualityChange = now
		end
	else
		return
	end

	if vfx then
		vfx:SetQuality(currentQuality)
	end
end

RunService.Heartbeat:Connect(function(deltaTime)
	sampleIndex = (sampleIndex % Balance.Performance.QUALITY_SAMPLE_WINDOW) + 1
	frameSamples[sampleIndex] = deltaTime * 1000

	if sampleIndex ~= Balance.Performance.QUALITY_SAMPLE_WINDOW then
		return
	end

	local total = 0
	for _, sample in ipairs(frameSamples) do
		total += sample
	end
	local average = total / #frameSamples

	adjustQuality(average)

	local now = os.clock()
	if now - lastReport > 120 then
		lastReport = now
		Net.FireServer("ReportClientMetric", {
			averageFrameMs = average,
			quality = currentQuality,
			deviceKind = deviceKind,
		})
	end
end)

-- ============================================================================
-- Core UI
-- ============================================================================

-- The default Roblox health bar and backpack would duplicate our own HUD.
pcall(function()
	StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Health, false)
	StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
end)

print(("[BTS] client ready — %s, quality %s"):format(deviceKind, currentQuality))
