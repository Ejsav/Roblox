--!strict
--[[
	MenuController
	--------------
	Owns every full-screen panel: which one is open, how it opens, and what happens
	to gameplay input while it is.

	One rule shapes the whole thing: opening a menu must never be a decision the
	player regrets. So menus open and close in well under two hundred milliseconds,
	Escape always closes, the key that opened a menu also closes it, and gameplay
	input is suppressed rather than leaking into the world behind.
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BTS")
local Theme = require(Shared.Config.Theme)
local Net = require(Shared.Net)
local Maid = require(Shared.Core.Maid)
local Signal = require(Shared.Core.Signal)

local Client = script.Parent.Parent
local Components = require(Client.UI.Components)
local MapScreen = require(Client.UI.Screens.MapScreen)
local UpgradesScreen = require(Client.UI.Screens.UpgradesScreen)
local SkillsScreen = require(Client.UI.Screens.SkillsScreen)
local InventoryScreen = require(Client.UI.Screens.InventoryScreen)
local QuestScreen = require(Client.UI.Screens.QuestScreen)
local CodexScreen = require(Client.UI.Screens.CodexScreen)

local MenuController = {}
MenuController.Name = "MenuController"
MenuController.Dependencies = { "InputController", "HudController" }
MenuController.Priority = 40

local LocalPlayer = Players.LocalPlayer

--[[ The menus, in tab order, with the action that toggles each. ]]
local MENUS = {
	{ id = "map", name = "MAP", action = "map" },
	{ id = "upgrades", name = "UPGRADES", action = "upgrades" },
	{ id = "skills", name = "SKILLS", action = "skills" },
	{ id = "inventory", name = "EQUIPMENT", action = "inventory" },
	{ id = "quests", name = "QUESTS", action = "quests" },
	{ id = "codex", name = "CODEX", action = "codex" },
}

function MenuController:Init()
	self._maid = Maid.new()
	self._screens = {}
	self._open = nil
	self._profile = nil
	self._stats = {}

	self.MenuOpened = Signal.new("Menu.Opened")
	self.MenuClosed = Signal.new("Menu.Closed")

	local playerGui = LocalPlayer:WaitForChild("PlayerGui")

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "BTS_Menus"
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = false
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.DisplayOrder = Theme.ZIndex.panel
	screenGui.Enabled = false
	screenGui.Parent = playerGui
	self._maid:Add(screenGui)
	self._screenGui = screenGui

	-- A dimming scrim behind the panel, which is what makes a menu read as a layer
	-- rather than a window pasted onto the world.
	local scrim = Instance.new("Frame")
	scrim.Name = "Scrim"
	scrim.Size = UDim2.fromScale(1, 1)
	scrim.BackgroundColor3 = Theme.Color.void
	scrim.BackgroundTransparency = 1
	scrim.BorderSizePixel = 0
	scrim.ZIndex = Theme.ZIndex.panel - 1
	scrim.Parent = screenGui
	self._scrim = scrim

	self._container = Components.Container({
		parent = screenGui,
		name = "Container",
		size = UDim2.new(1, -Theme.Space.xxl, 1, -Theme.Space.xxl),
		position = UDim2.fromScale(0.5, 0.5),
		anchorPoint = Vector2.new(0.5, 0.5),
		zIndex = Theme.ZIndex.panel,
	})

	self:_buildTabBar()
end

function MenuController:Start()
	self._input = self.Registry:Get("InputController")
	self._hud = self.Registry:Get("HudController")
	self._audio = self.Registry:Find("AudioController")

	-- Screens are constructed once, up front. Building a skill tree of ninety-one
	-- nodes on first open would be a visible hitch.
	self._screens.map = MapScreen.new(self._container, self.Registry:GetAll())
	self._screens.upgrades = UpgradesScreen.new(self._container, self.Registry:GetAll())
	self._screens.skills = SkillsScreen.new(self._container, self.Registry:GetAll())
	self._screens.inventory = InventoryScreen.new(self._container, self.Registry:GetAll())
	self._screens.quests = QuestScreen.new(self._container, self.Registry:GetAll())
	self._screens.codex = CodexScreen.new(self._container, self.Registry:GetAll())

	for _, screen in pairs(self._screens) do
		screen:SetVisible(false)
		self._maid:Add(screen)
	end

	self._maid:Add(self._input.ActionBegan:Connect(function(actionId)
		self:_onAction(actionId)
	end))

	self:_bindNetwork()
end

local TAB_WIDTH = 122
local TAB_HEIGHT = 36
local CLOSE_WIDTH = 40

function MenuController:_buildTabBar()
	-- Derived rather than fixed, so adding a menu widens the bar instead of
	-- silently clipping the last tab.
	local barWidth = #MENUS * TAB_WIDTH + CLOSE_WIDTH + (#MENUS) * Theme.Space.xs

	local bar = Components.Container({
		parent = self._screenGui,
		name = "TabBar",
		size = UDim2.fromOffset(barWidth, 40),
		position = UDim2.new(0.5, 0, 0, Theme.Space.sm),
		anchorPoint = Vector2.new(0.5, 0),
		zIndex = Theme.ZIndex.panel + 10,
	})
	Components.List(bar, {
		direction = Enum.FillDirection.Horizontal,
		gap = Theme.Space.xs,
		alignX = Enum.HorizontalAlignment.Center,
	})
	self._tabBar = bar

	self._tabButtons = {}
	for index, menu in ipairs(MENUS) do
		local _, button = Components.Button({
			parent = bar,
			name = menu.id,
			text = menu.name,
			variant = "ghost",
			size = UDim2.fromOffset(TAB_WIDTH, TAB_HEIGHT),
			textSize = Theme.Text.label,
			layoutOrder = index,
			zIndex = bar.ZIndex + 1,
		})
		self._maid:Add(button.Pressed:Connect(function()
			self:Open(menu.id)
		end))
		self._tabButtons[menu.id] = button
	end

	local _, closeButton = Components.Button({
		parent = bar,
		name = "close",
		text = "✕",
		variant = "ghost",
		size = UDim2.fromOffset(CLOSE_WIDTH, TAB_HEIGHT),
		textSize = Theme.Text.body,
		layoutOrder = 99,
		zIndex = bar.ZIndex + 1,
	})
	self._maid:Add(closeButton.Pressed:Connect(function()
		self:Close()
	end))
end

function MenuController:_bindNetwork()
	local maid = self._maid

	maid:Add(Net.OnClientEvent("ProfileSync", function(payload)
		self._profile = payload.profile
		self._stats = payload.stats or {}
		self:_distributeProfile()
		if payload.inventory then
			self._screens.inventory:SetView(payload.inventory, self._stats)
		end
	end))

	maid:Add(Net.OnClientEvent("ProfileDelta", function(payload)
		if not self._profile then
			return
		end
		-- Deltas are shallow-merged onto the cached profile, which is enough for
		-- everything the menus read and far cheaper than a full resync.
		for key, value in pairs(payload) do
			if key == "upgrades" or key == "skills" then
				self._profile[key] = self._profile[key] or {}
				for subKey, subValue in pairs(value) do
					self._profile[key][subKey] = subValue
				end
			elseif key ~= "nextMilestone" and key ~= "specialisation" then
				self._profile[key] = value
			end
		end
		if payload.fullSkillReset then
			self._profile.skills = {}
		end
		if payload.stats then
			self._stats = payload.stats
		end
		self:_distributeProfile()
	end))

	maid:Add(Net.OnClientEvent("InventoryUpdate", function(view)
		self._screens.inventory:SetView(view, self._stats)
	end))

	maid:Add(Net.OnClientEvent("QuestUpdate", function(view)
		self._screens.quests:SetView(view)
	end))

	-- An achievement landing while the codex is open should be visible there
	-- immediately, not on the next open.
	maid:Add(Net.OnClientEvent("AchievementEarned", function()
		if self._open == "codex" then
			self._screens.codex:RequestRefresh()
		end
	end))

	-- Currency changes arrive through several paths; the upgrade screen needs all
	-- of them or its affordability states go stale mid-session.
	maid:Add(Net.OnClientEvent("BankResult", function(result)
		if result.success and self._profile then
			self._profile.watts = (self._profile.watts or 0) + (result.watts or 0)
			self:_distributeProfile()
		end
	end))
end

function MenuController:_distributeProfile()
	if not self._profile then
		return
	end
	self._screens.map:SetProfile(self._profile)
	self._screens.upgrades:SetProfile(self._profile, self._stats)
	self._screens.skills:SetProfile(self._profile)
	self._screens.quests:SetProfile(self._profile)
	self._screens.codex:SetProfile(self._profile)
end

-- ============================================================================
-- Open / close
-- ============================================================================

function MenuController:_onAction(actionId: string)
	if actionId == "closeMenu" then
		if self._open then
			self:Close()
		end
		return
	end

	for _, menu in ipairs(MENUS) do
		if menu.action == actionId then
			-- The key that opens a menu also closes it, which is what players
			-- reflexively try and are surprised when it does not work.
			if self._open == menu.id then
				self:Close()
			else
				self:Open(menu.id)
			end
			return
		end
	end
end

function MenuController:Open(menuId: string)
	if not self._screens[menuId] then
		return
	end

	local wasOpen = self._open ~= nil
	self._open = menuId

	for id, screen in pairs(self._screens) do
		screen:SetVisible(id == menuId)
	end
	for id, button in pairs(self._tabButtons) do
		button:SetEnabled(id ~= menuId)
	end

	-- A screen that needs to fetch something on open says so with OnOpened, rather
	-- than hiding the request inside SetVisible where nothing can call it safely.
	local opened = self._screens[menuId]
	if type((opened :: any).OnOpened) == "function" then
		opened:OnOpened()
	end

	if not wasOpen then
		self._screenGui.Enabled = true
		self._input:SetMenuOpen(true)
		self._hud:SetVisible(false)

		self._scrim.BackgroundTransparency = 1
		TweenService:Create(self._scrim, Theme.Tween("fast"), { BackgroundTransparency = 0.35 }):Play()

		self._container.Position = UDim2.fromScale(0.5, 0.52)
		TweenService:Create(self._container, Theme.Tween("normal", "enter"), {
			Position = UDim2.fromScale(0.5, 0.5),
		}):Play()

		if self._audio then
			self._audio:PlayUi("ui_open")
		end
		self.MenuOpened:Fire(menuId)
	end
end

function MenuController:Close()
	if not self._open then
		return
	end

	local closed = self._open
	self._open = nil

	TweenService:Create(self._scrim, Theme.Tween("fast", "exit"), { BackgroundTransparency = 1 }):Play()
	local slide = TweenService:Create(self._container, Theme.Tween("fast", "exit"), {
		Position = UDim2.fromScale(0.5, 0.52),
	})
	slide:Play()

	slide.Completed:Once(function()
		if not self._open then
			self._screenGui.Enabled = false
			for _, screen in pairs(self._screens) do
				screen:SetVisible(false)
			end
		end
	end)

	self._input:SetMenuOpen(false)
	self._hud:SetVisible(true)

	if self._audio then
		self._audio:PlayUi("ui_close")
	end
	self.MenuClosed:Fire(closed)
end

function MenuController:IsOpen(): boolean
	return self._open ~= nil
end

function MenuController:GetOpenMenu(): string?
	return self._open
end

--[[ The map screen animates live markers, so it needs a per-frame tick while open. ]]
function MenuController:Update(deltaTime: number)
	if self._open == "map" then
		self._screens.map:Update(deltaTime)
	end
end

function MenuController:Destroy()
	self._maid:DoCleaning()
end

return MenuController
