--!strict
--[[
	Hud
	---
	The in-world interface. Everything a player needs while actually running, and
	nothing they do not.

	Layout, and why:
	  * Bottom-left    carry, capacity and instability. The three numbers that decide
	                   whether to keep going, placed where the eye rests during play.
	  * Bottom-centre  the capture ring, drawn at the crosshair because that is where
	                   the player is already looking when a strike telegraphs.
	  * Bottom-right   abilities. Reachable, glanceable, never in the way.
	  * Top-left       currency and level. Read between runs, not during them.
	  * Top-right      the tracked objective. The answer to "what am I doing?".
	  * Top-centre     region banner and event alerts. Transient, high-priority.

	Everything except the carry cluster fades out when it has nothing to say, so the
	screen during a quiet moment is almost empty and during a storm is dense.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BTS")
local Theme = require(Shared.Config.Theme)
local Balance = require(Shared.Config.Balance)
local Maid = require(Shared.Core.Maid)
local MathUtil = require(Shared.Core.MathUtil)

local Client = script.Parent.Parent.Parent
local Components = require(Client.UI.Components)

local Hud = {}
Hud.__index = Hud

local LocalPlayer = Players.LocalPlayer

function Hud.new(screenGui: ScreenGui, controllers: any)
	local self = setmetatable({
		_gui = screenGui,
		_controllers = controllers,
		_maid = Maid.new(),
		_bars = {},
		_readouts = {},
		_state = {
			carried = 0,
			capacity = 120,
			instability = 0,
			chain = 0,
			multiplier = 1,
			health = 100,
			maxHealth = 100,
			watts = 0,
			cores = 0,
			level = 1,
			levelFraction = 0,
		},
		_compact = false,
	}, Hud)

	self:_build()
	return self
end

-- ============================================================================
-- Construction
-- ============================================================================

function Hud:_build()
	local root = Components.Container({
		parent = self._gui,
		name = "Hud",
		size = UDim2.fromScale(1, 1),
		zIndex = Theme.ZIndex.hud,
	})
	self._root = root

	self:_buildCarryCluster(root)
	self:_buildCaptureRing(root)
	self:_buildAbilityBar(root)
	self:_buildTopLeft(root)
	self:_buildObjective(root)
	self:_buildWorldEvent(root)
	self:_buildBanner(root)
	self:_buildCompass(root)
	self:_buildFeedback(root)

	self:_applyLayout()
end

--[[ Carry, capacity, instability, chain — the decision cluster. ]]
function Hud:_buildCarryCluster(root: Frame)
	local panel = Components.Container({
		parent = root,
		name = "CarryCluster",
		size = UDim2.fromOffset(320, 120),
		position = UDim2.new(0, Theme.Layout.screenPadding, 1, -Theme.Layout.screenPadding),
		anchorPoint = Vector2.new(0, 1),
		zIndex = Theme.ZIndex.hud,
	})
	self._carryCluster = panel

	-- Carried energy: the biggest number on the screen, because it is the one the
	-- whole risk decision turns on.
	local _, carriedReadout = Components.Readout({
		parent = panel,
		name = "Carried",
		label = "Carrying",
		color = Theme.Color.energy,
		size = UDim2.new(0, 200, 0, 52),
		position = UDim2.fromOffset(0, 0),
		textSize = Theme.Text.display,
		labelSize = Theme.Text.caption,
		zIndex = Theme.ZIndex.hud,
	})
	self._readouts.carried = carriedReadout

	local capacityLabel = Components.Text({
		parent = panel,
		name = "Capacity",
		text = "/ 120",
		position = UDim2.fromOffset(0, 54),
		size = UDim2.new(0, 200, 0, 16),
		textSize = Theme.Text.label,
		color = Theme.Color.textTertiary,
		zIndex = Theme.ZIndex.hud,
	})
	self._capacityLabel = capacityLabel

	-- Fill bar.
	local _, fillBar = Components.Bar({
		parent = panel,
		name = "FillBar",
		size = UDim2.new(1, 0, 0, 8),
		position = UDim2.fromOffset(0, 76),
		color = Theme.Color.energy,
		showGhost = true,
		zIndex = Theme.ZIndex.hud,
	})
	self._bars.fill = fillBar

	-- Instability bar, directly beneath, so the two are read together.
	local _, instabilityBar = Components.Bar({
		parent = panel,
		name = "InstabilityBar",
		size = UDim2.new(1, 0, 0, 5),
		position = UDim2.fromOffset(0, 88),
		color = Theme.Color.instability,
		zIndex = Theme.ZIndex.hud,
	})
	self._bars.instability = instabilityBar

	local instabilityLabel = Components.Label({
		parent = panel,
		name = "InstabilityLabel",
		text = "Stable",
		position = UDim2.fromOffset(0, 96),
		size = UDim2.new(1, 0, 0, 14),
		textSize = Theme.Text.caption,
		color = Theme.Color.textTertiary,
		zIndex = Theme.ZIndex.hud,
	})
	self._instabilityLabel = instabilityLabel

	-- Chain and multiplier sit to the right of the carry number, appearing only
	-- once a chain actually exists.
	local chainContainer = Components.Container({
		parent = panel,
		name = "Chain",
		size = UDim2.fromOffset(110, 52),
		position = UDim2.new(1, 0, 0, 0),
		anchorPoint = Vector2.new(1, 0),
		zIndex = Theme.ZIndex.hud,
	})
	self._chainContainer = chainContainer

	self._chainLabel = Components.Text({
		parent = chainContainer,
		name = "ChainValue",
		text = "×1.00",
		size = UDim2.new(1, 0, 0, 28),
		textSize = Theme.Text.title,
		font = Theme.Font.heading,
		color = Theme.Color.chain,
		alignX = Enum.TextXAlignment.Right,
		zIndex = Theme.ZIndex.hud,
	})

	self._chainCount = Components.Label({
		parent = chainContainer,
		name = "ChainCount",
		text = "Chain 0",
		position = UDim2.fromOffset(0, 30),
		size = UDim2.new(1, 0, 0, 14),
		textSize = Theme.Text.caption,
		alignX = Enum.TextXAlignment.Right,
		color = Theme.Color.textTertiary,
		zIndex = Theme.ZIndex.hud,
	})

	chainContainer.Visible = false

	-- Health, above the carry cluster: the fourth thing you look at, so it is the
	-- fourth thing down.
	local _, healthBar = Components.Bar({
		parent = panel,
		name = "HealthBar",
		size = UDim2.new(0, 200, 0, 5),
		position = UDim2.fromOffset(0, 112),
		color = Theme.Color.health,
		zIndex = Theme.ZIndex.hud,
	})
	self._bars.health = healthBar
end

--[[
	The capture ring: a shrinking circle at the crosshair that closes on the strike's
	peak and changes colour with the predicted grade.

	Drawn as concentric frames rather than an image so it scales cleanly and needs no
	assets. The outer ring is the window; the inner marker is now.
]]
function Hud:_buildCaptureRing(root: Frame)
	local container = Components.Container({
		parent = root,
		name = "CaptureRing",
		size = UDim2.fromOffset(220, 220),
		position = UDim2.fromScale(0.5, 0.5),
		anchorPoint = Vector2.new(0.5, 0.5),
		zIndex = Theme.ZIndex.hudOverlay,
	})
	container.Visible = false
	self._captureRing = container

	-- The window ring: static, marks where a Perfect lands.
	local windowRing = Instance.new("Frame")
	windowRing.Name = "Window"
	windowRing.Size = UDim2.fromOffset(96, 96)
	windowRing.Position = UDim2.fromScale(0.5, 0.5)
	windowRing.AnchorPoint = Vector2.new(0.5, 0.5)
	windowRing.BackgroundTransparency = 1
	windowRing.ZIndex = container.ZIndex
	windowRing.Parent = container
	Components.Corner(windowRing, Theme.Radius.pill)
	local windowStroke = Components.Stroke(windowRing, Theme.Color.textTertiary, Theme.Stroke.thin, 0.4)
	self._windowStroke = windowStroke

	-- The closing ring: shrinks from the outside toward the window ring.
	local closingRing = Instance.new("Frame")
	closingRing.Name = "Closing"
	closingRing.Size = UDim2.fromOffset(200, 200)
	closingRing.Position = UDim2.fromScale(0.5, 0.5)
	closingRing.AnchorPoint = Vector2.new(0.5, 0.5)
	closingRing.BackgroundTransparency = 1
	closingRing.ZIndex = container.ZIndex + 1
	closingRing.Parent = container
	Components.Corner(closingRing, Theme.Radius.pill)
	local closingStroke = Components.Stroke(closingRing, Theme.Color.accent, Theme.Stroke.thick)
	self._closingRing = closingRing
	self._closingStroke = closingStroke

	-- Centre dot, which is the actual aim point.
	local centre = Instance.new("Frame")
	centre.Name = "Centre"
	centre.Size = UDim2.fromOffset(6, 6)
	centre.Position = UDim2.fromScale(0.5, 0.5)
	centre.AnchorPoint = Vector2.new(0.5, 0.5)
	centre.BackgroundColor3 = Theme.Color.textPrimary
	centre.BorderSizePixel = 0
	centre.ZIndex = container.ZIndex + 2
	centre.Parent = container
	Components.Corner(centre, Theme.Radius.pill)

	-- Storm name and the prompt, beneath the ring.
	self._captureLabel = Components.Text({
		parent = container,
		name = "StormName",
		text = "",
		position = UDim2.new(0.5, 0, 1, -18),
		size = UDim2.new(1, 0, 0, 18),
		anchorPoint = Vector2.new(0.5, 0),
		textSize = Theme.Text.label,
		font = Theme.Font.medium,
		color = Theme.Color.textSecondary,
		alignX = Enum.TextXAlignment.Center,
		zIndex = container.ZIndex + 2,
	})

	self._capturePrompt = Components.Text({
		parent = container,
		name = "Prompt",
		text = "",
		position = UDim2.new(0.5, 0, 1, 2),
		size = UDim2.new(1, 0, 0, 16),
		anchorPoint = Vector2.new(0.5, 0),
		textSize = Theme.Text.caption,
		color = Theme.Color.textTertiary,
		alignX = Enum.TextXAlignment.Center,
		zIndex = container.ZIndex + 2,
	})
end

function Hud:_buildAbilityBar(root: Frame)
	local container = Components.Container({
		parent = root,
		name = "Abilities",
		size = UDim2.fromOffset(240, 56),
		position = UDim2.new(1, -Theme.Layout.screenPadding, 1, -Theme.Layout.screenPadding),
		anchorPoint = Vector2.new(1, 1),
		zIndex = Theme.ZIndex.hud,
	})
	self._abilityBar = container

	Components.List(container, {
		direction = Enum.FillDirection.Horizontal,
		gap = Theme.Space.sm,
		alignX = Enum.HorizontalAlignment.Right,
	})

	self._abilitySlots = {}
	for index = 1, 4 do
		local slot = Components.Panel({
			parent = container,
			name = "Slot" .. index,
			size = UDim2.fromOffset(52, 52),
			elevation = 1,
			radius = Theme.Radius.md,
			transparency = 0.15,
			zIndex = Theme.ZIndex.hud,
		})
		slot.LayoutOrder = index

		local key = Components.Text({
			parent = slot,
			name = "Key",
			text = tostring(index),
			position = UDim2.fromOffset(4, 2),
			size = UDim2.fromOffset(14, 12),
			textSize = Theme.Text.caption,
			color = Theme.Color.textTertiary,
			zIndex = slot.ZIndex + 2,
		})

		local name = Components.Text({
			parent = slot,
			name = "Name",
			text = "",
			position = UDim2.fromScale(0.5, 0.55),
			size = UDim2.new(1, -6, 0, 24),
			anchorPoint = Vector2.new(0.5, 0.5),
			textSize = Theme.Text.caption,
			font = Theme.Font.medium,
			color = Theme.Color.textSecondary,
			alignX = Enum.TextXAlignment.Center,
			wrapped = true,
			zIndex = slot.ZIndex + 2,
		})

		-- The cooldown sweep is a fill that drains downward, which reads faster than
		-- a number when four of them are ticking at once.
		local cooldown = Instance.new("Frame")
		cooldown.Name = "Cooldown"
		cooldown.Size = UDim2.fromScale(1, 0)
		cooldown.Position = UDim2.fromScale(0, 1)
		cooldown.AnchorPoint = Vector2.new(0, 1)
		cooldown.BackgroundColor3 = Theme.Color.void
		cooldown.BackgroundTransparency = 0.35
		cooldown.BorderSizePixel = 0
		cooldown.ZIndex = slot.ZIndex + 1
		cooldown.Parent = slot
		Components.Corner(cooldown, Theme.Radius.md)

		self._abilitySlots[index] = {
			frame = slot,
			key = key,
			name = name,
			cooldown = cooldown,
			abilityId = nil,
		}
	end

	container.Visible = false
end

function Hud:_buildTopLeft(root: Frame)
	local container = Components.Container({
		parent = root,
		name = "Status",
		size = UDim2.fromOffset(280, 64),
		position = UDim2.fromOffset(Theme.Layout.screenPadding, Theme.Layout.screenPadding),
		zIndex = Theme.ZIndex.hud,
	})
	self._statusPanel = container

	local _, wattsReadout = Components.Readout({
		parent = container,
		name = "Watts",
		label = "Watts",
		color = Theme.Color.watts,
		size = UDim2.fromOffset(130, 42),
		textSize = Theme.Text.heading,
		zIndex = Theme.ZIndex.hud,
	})
	self._readouts.watts = wattsReadout

	local _, coresReadout = Components.Readout({
		parent = container,
		name = "Cores",
		label = "Cores",
		color = Theme.Color.cores,
		size = UDim2.fromOffset(90, 42),
		position = UDim2.fromOffset(140, 0),
		textSize = Theme.Text.heading,
		precise = true,
		zIndex = Theme.ZIndex.hud,
	})
	self._readouts.cores = coresReadout

	self._levelLabel = Components.Label({
		parent = container,
		name = "Level",
		text = "Level 1",
		position = UDim2.fromOffset(0, 44),
		size = UDim2.new(0, 130, 0, 14),
		textSize = Theme.Text.caption,
		color = Theme.Color.textSecondary,
		zIndex = Theme.ZIndex.hud,
	})

	local _, xpBar = Components.Bar({
		parent = container,
		name = "XpBar",
		size = UDim2.new(0, 230, 0, 3),
		position = UDim2.fromOffset(0, 60),
		color = Theme.Color.accentDim,
		zIndex = Theme.ZIndex.hud,
	})
	self._bars.xp = xpBar
end

function Hud:_buildObjective(root: Frame)
	local panel = Components.Panel({
		parent = root,
		name = "Objective",
		size = UDim2.fromOffset(280, 0),
		position = UDim2.new(1, -Theme.Layout.screenPadding, 0, Theme.Layout.screenPadding),
		anchorPoint = Vector2.new(1, 0),
		elevation = 1,
		transparency = 0.25,
		padding = Theme.Space.md,
		zIndex = Theme.ZIndex.hud,
	})
	panel.AutomaticSize = Enum.AutomaticSize.Y
	panel.Visible = false
	self._objectivePanel = panel

	Components.List(panel, { gap = Theme.Space.xs })

	self._objectiveTitle = Components.Text({
		parent = panel,
		name = "Title",
		text = "",
		size = UDim2.new(1, 0, 0, 18),
		textSize = Theme.Text.body,
		font = Theme.Font.medium,
		color = Theme.Color.textPrimary,
		layoutOrder = 1,
		zIndex = panel.ZIndex + 1,
	})

	self._objectiveList = Components.Container({
		parent = panel,
		name = "Objectives",
		size = UDim2.new(1, 0, 0, 0),
		zIndex = panel.ZIndex + 1,
	})
	self._objectiveList.AutomaticSize = Enum.AutomaticSize.Y
	self._objectiveList.LayoutOrder = 2
	Components.List(self._objectiveList, { gap = Theme.Space.xxs })
end

--[[
	The world-event tracker.

	Sits under the objective panel because it is the same kind of information —
	"what am I supposed to be doing right now" — and a player should not have to
	look in two corners for it. Hidden entirely when no event is running, rather
	than shown empty: permanent chrome for an occasional thing is how a HUD becomes
	noise.
]]
function Hud:_buildWorldEvent(root: Frame)
	local panel = Components.Panel({
		parent = root,
		name = "WorldEvent",
		size = UDim2.fromOffset(280, 0),
		position = UDim2.new(1, -Theme.Layout.screenPadding, 0, Theme.Layout.screenPadding + 120),
		anchorPoint = Vector2.new(1, 0),
		elevation = 1,
		transparency = 0.2,
		padding = Theme.Space.md,
		zIndex = Theme.ZIndex.hud,
	})
	panel.AutomaticSize = Enum.AutomaticSize.Y
	panel.Visible = false
	self._eventPanel = panel

	Components.List(panel, { gap = Theme.Space.xxs })

	self._eventName = Components.Text({
		parent = panel,
		name = "Name",
		text = "",
		size = UDim2.new(1, 0, 0, 16),
		textSize = Theme.Text.caption,
		font = Theme.Font.medium,
		color = Theme.Color.warning,
		layoutOrder = 1,
		zIndex = panel.ZIndex + 1,
	})

	self._eventPhase = Components.Text({
		parent = panel,
		name = "Phase",
		text = "",
		size = UDim2.new(1, 0, 0, 18),
		textSize = Theme.Text.body,
		font = Theme.Font.medium,
		layoutOrder = 2,
		zIndex = panel.ZIndex + 1,
	})

	self._eventObjective = Components.Text({
		parent = panel,
		name = "Objective",
		text = "",
		size = UDim2.new(1, 0, 0, 28),
		textSize = Theme.Text.caption,
		color = Theme.Color.textSecondary,
		wrapped = true,
		alignY = Enum.TextYAlignment.Top,
		layoutOrder = 3,
		zIndex = panel.ZIndex + 1,
	})

	self._eventTimer = Components.Text({
		parent = panel,
		name = "Timer",
		text = "",
		size = UDim2.new(1, 0, 0, 18),
		textSize = Theme.Text.body,
		font = Theme.Font.heading,
		color = Theme.Color.textPrimary,
		alignX = Enum.TextXAlignment.Right,
		layoutOrder = 4,
		zIndex = panel.ZIndex + 1,
	})

	-- Boss health only appears for events that have a boss, which is why it is a
	-- separate bar rather than a repurposed progress bar with a changing label.
	self._eventBossBar = select(2, Components.Bar({
		parent = panel,
		name = "BossHealth",
		size = UDim2.new(1, 0, 0, 5),
		color = Theme.Color.danger,
		layoutOrder = 5,
		zIndex = panel.ZIndex + 1,
	}))
	self._eventBossBar.Instance.Visible = false

	self._eventContribution = Components.Text({
		parent = panel,
		name = "Contribution",
		text = "",
		size = UDim2.new(1, 0, 0, 14),
		textSize = Theme.Text.caption,
		color = Theme.Color.textTertiary,
		layoutOrder = 6,
		zIndex = panel.ZIndex + 1,
	})
end

--[[ The transient banner: region arrivals, event alerts, major unlocks. ]]
function Hud:_buildBanner(root: Frame)
	local banner = Components.Container({
		parent = root,
		name = "Banner",
		size = UDim2.fromOffset(560, 90),
		position = UDim2.new(0.5, 0, 0, 60),
		anchorPoint = Vector2.new(0.5, 0),
		zIndex = Theme.ZIndex.hudOverlay,
	})
	banner.Visible = false
	self._banner = banner

	self._bannerTitle = Components.Text({
		parent = banner,
		name = "Title",
		text = "",
		size = UDim2.new(1, 0, 0, 40),
		textSize = Theme.Text.title,
		font = Theme.Font.display,
		color = Theme.Color.textPrimary,
		alignX = Enum.TextXAlignment.Center,
		zIndex = banner.ZIndex,
	})

	self._bannerSubtitle = Components.Text({
		parent = banner,
		name = "Subtitle",
		text = "",
		position = UDim2.fromOffset(0, 40),
		size = UDim2.new(1, 0, 0, 22),
		textSize = Theme.Text.body,
		color = Theme.Color.textSecondary,
		alignX = Enum.TextXAlignment.Center,
		zIndex = banner.ZIndex,
	})

	self._bannerDetail = Components.Text({
		parent = banner,
		name = "Detail",
		text = "",
		position = UDim2.fromOffset(0, 62),
		size = UDim2.new(1, 0, 0, 18),
		textSize = Theme.Text.label,
		color = Theme.Color.textTertiary,
		alignX = Enum.TextXAlignment.Center,
		zIndex = banner.ZIndex,
	})
end

--[[
	The compass strip: nearby storms as ticks along a horizontal band at the top,
	so a player can find weather by turning rather than by opening the map.
]]
function Hud:_buildCompass(root: Frame)
	local compass = Components.Container({
		parent = root,
		name = "Compass",
		size = UDim2.fromOffset(420, 26),
		position = UDim2.new(0.5, 0, 0, Theme.Layout.screenPadding),
		anchorPoint = Vector2.new(0.5, 0),
		zIndex = Theme.ZIndex.hud,
	})
	self._compass = compass

	local track = Instance.new("Frame")
	track.Name = "Track"
	track.Size = UDim2.new(1, 0, 0, 2)
	track.Position = UDim2.fromScale(0, 0.5)
	track.BackgroundColor3 = Theme.Color.border
	track.BackgroundTransparency = 0.4
	track.BorderSizePixel = 0
	track.ZIndex = compass.ZIndex
	track.Parent = compass

	self._compassMarkers = {}
	-- A fixed pool: allocating markers per frame would churn instances constantly.
	for index = 1, 10 do
		local marker = Instance.new("Frame")
		marker.Name = "Marker" .. index
		marker.Size = UDim2.fromOffset(3, 14)
		marker.AnchorPoint = Vector2.new(0.5, 0.5)
		marker.Position = UDim2.fromScale(0.5, 0.5)
		marker.BackgroundColor3 = Theme.Color.accent
		marker.BorderSizePixel = 0
		marker.Visible = false
		marker.ZIndex = compass.ZIndex + 1
		marker.Parent = compass
		Components.Corner(marker, Theme.Radius.sm)
		self._compassMarkers[index] = marker
	end
end

--[[ The capture feedback line: grade and energy, right under the ring. ]]
function Hud:_buildFeedback(root: Frame)
	local feedback = Components.Text({
		parent = root,
		name = "Feedback",
		text = "",
		size = UDim2.fromOffset(400, 40),
		position = UDim2.fromScale(0.5, 0.62),
		anchorPoint = Vector2.new(0.5, 0.5),
		textSize = Theme.Text.title,
		font = Theme.Font.display,
		color = Theme.Color.textPrimary,
		alignX = Enum.TextXAlignment.Center,
		transparency = 1,
		zIndex = Theme.ZIndex.hudOverlay,
	})
	self._feedback = feedback
end

-- ============================================================================
-- Layout
-- ============================================================================

--[[
	Adapts the layout for narrow screens. Not a scale-down: the ability bar moves,
	the objective panel narrows, and the compass shortens, because a phone needs a
	different arrangement rather than a smaller one.
]]
function Hud:_applyLayout()
	local viewport = Workspace.CurrentCamera and Workspace.CurrentCamera.ViewportSize or Vector2.new(1920, 1080)
	local compact = viewport.X < Theme.Layout.compactBreakpoint

	if compact == self._compact then
		return
	end
	self._compact = compact

	if compact then
		self._carryCluster.Size = UDim2.fromOffset(240, 108)
		self._objectivePanel.Size = UDim2.fromOffset(200, 0)
		self._eventPanel.Size = UDim2.fromOffset(200, 0)
		self._compass.Size = UDim2.fromOffset(260, 26)
		self._abilityBar.Position = UDim2.new(1, -Theme.Layout.screenPadding, 1, -110)
		self._readouts.carried.ValueLabel.TextSize = Theme.Text.title
	else
		self._carryCluster.Size = UDim2.fromOffset(320, 120)
		self._objectivePanel.Size = UDim2.fromOffset(280, 0)
		self._eventPanel.Size = UDim2.fromOffset(280, 0)
		self._compass.Size = UDim2.fromOffset(420, 26)
		self._abilityBar.Position = UDim2.new(1, -Theme.Layout.screenPadding, 1, -Theme.Layout.screenPadding)
		self._readouts.carried.ValueLabel.TextSize = Theme.Text.display
	end
end

-- ============================================================================
-- State updates
-- ============================================================================

function Hud:UpdateCarry(snapshot: any)
	local state = self._state
	state.carried = snapshot.carried or state.carried
	state.capacity = snapshot.capacity or state.capacity
	state.instability = snapshot.instability or state.instability
	state.chain = snapshot.chain or state.chain
	state.multiplier = snapshot.multiplier or state.multiplier

	if snapshot.health then
		state.health = snapshot.health
	end
	if snapshot.maxHealth then
		state.maxHealth = snapshot.maxHealth
	end

	self._readouts.carried:SetValue(state.carried)
	self._capacityLabel.Text = "/ " .. Theme.FormatNumber(state.capacity)

	local fill = state.capacity > 0 and (state.carried / state.capacity) or 0
	self._bars.fill:SetValue(fill)
	self._bars.instability:SetValue(state.instability)
	self._bars.instability:SetColor(Theme.InstabilityColor(state.instability))
	self._bars.health:SetValue(state.maxHealth > 0 and (state.health / state.maxHealth) or 0)

	-- Instability wording rather than a percentage: at speed, a word is read faster
	-- than a number, and the exact value does not change the decision.
	local instabilityText, instabilityColor
	if state.instability >= Balance.Carry.INSTABILITY_CRITICAL then
		instabilityText = "CRITICAL — BANK NOW"
		instabilityColor = Theme.Color.instabilityCritical
	elseif state.instability >= Balance.Carry.INSTABILITY_WARNING then
		instabilityText = "Unstable"
		instabilityColor = Theme.Color.instability
	elseif state.instability > 0.2 then
		instabilityText = "Holding"
		instabilityColor = Theme.Color.textSecondary
	else
		instabilityText = "Stable"
		instabilityColor = Theme.Color.textTertiary
	end
	self._instabilityLabel.Text = string.upper(instabilityText)
	self._instabilityLabel.TextColor3 = instabilityColor

	-- The chain readout only exists while a chain does.
	local hasChain = state.chain > 0
	if hasChain ~= self._chainContainer.Visible then
		self._chainContainer.Visible = hasChain
		if hasChain then
			Components.FadeIn(self._chainContainer, { duration = "fast" })
		end
	end
	if hasChain then
		self._chainLabel.Text = ("×%.2f"):format(state.multiplier)
		self._chainCount.Text = ("Chain %d"):format(state.chain)
	end
end

function Hud:UpdateCurrency(watts: number?, cores: number?)
	if watts then
		self._state.watts = watts
		self._readouts.watts:SetValue(watts)
	end
	if cores then
		self._state.cores = cores
		self._readouts.cores:SetValue(cores)
	end
end

function Hud:UpdateLevel(levelInfo: any)
	self._state.level = levelInfo.level
	self._state.levelFraction = levelInfo.fraction
	self._levelLabel.Text = ("LEVEL %d"):format(levelInfo.level)
	self._bars.xp:SetValue(levelInfo.fraction)
end

function Hud:UpdateAbilities(slots: { any })
	local hasAny = false
	for index, slot in ipairs(self._abilitySlots) do
		local data = slots[index]
		if data then
			hasAny = true
			slot.abilityId = data.abilityId
			slot.name.Text = data.name
			slot.frame.BackgroundTransparency = 0.15
			slot.name.TextColor3 = data.remaining > 0 and Theme.Color.textTertiary or Theme.Color.textPrimary
			slot.cooldown.Size = UDim2.fromScale(1, data.cooldown > 0 and (data.remaining / data.cooldown) or 0)
		else
			slot.abilityId = nil
			slot.name.Text = ""
			slot.frame.BackgroundTransparency = 0.6
			slot.cooldown.Size = UDim2.fromScale(1, 0)
		end
	end

	if hasAny ~= self._abilityBar.Visible then
		self._abilityBar.Visible = hasAny
	end
end

--[[
	Flashes a slot to say a press was refused. Which slot is worked out from the
	ability id when there is one; a press with nothing slotted flashes the bar
	itself, so "that key does nothing yet" still produces a visible answer rather
	than silence.
]]
function Hud:FlashAbilityRefusal(abilityId: string?, reason: string?)
	local target = self._abilityBar

	for _, slot in ipairs(self._abilitySlots) do
		if abilityId and slot.abilityId == abilityId then
			target = slot.frame
			break
		end
	end

	if not target then
		return
	end

	Components.Shake(target, 4, 2)

	if reason and reason ~= "" then
		self:ShowBanner({
			title = "NOT READY",
			subtitle = reason,
			color = Theme.Color.textTertiary,
			duration = 1.2,
		})
	end
end

function Hud:UpdateObjective(quest: any?)
	if not quest then
		self._objectivePanel.Visible = false
		return
	end

	self._objectivePanel.Visible = true
	self._objectiveTitle.Text = quest.name

	self._objectiveList:ClearAllChildren()
	Components.List(self._objectiveList, { gap = Theme.Space.xxs })

	for index, objective in ipairs(quest.objectives) do
		local complete = objective.complete
		local text
		if objective.target > 1 then
			text = ("%s  %d/%d"):format(objective.description, math.floor(objective.progress), objective.target)
		else
			text = objective.description
		end

		Components.Text({
			parent = self._objectiveList,
			name = "Objective" .. index,
			text = (complete and "✓ " or "• ") .. text,
			size = UDim2.new(1, 0, 0, 16),
			textSize = Theme.Text.label,
			color = complete and Theme.Color.success
				or (objective.locked and Theme.Color.textDisabled or Theme.Color.textSecondary),
			wrapped = true,
			autoSize = Enum.AutomaticSize.Y,
			layoutOrder = index,
			zIndex = self._objectivePanel.ZIndex + 1,
		})
	end
end

-- ============================================================================
-- Banner
-- ============================================================================

--[[
	Shows or updates the world-event tracker. Three messages feed it — start, phase
	change, and progress — and each carries only what it knows, so fields are
	written when present and left alone when absent rather than being cleared by a
	message that simply did not mention them.
]]
function Hud:UpdateWorldEvent(payload: any?)
	if not payload then
		self._eventPanel.Visible = false
		self._eventBossBar.Instance.Visible = false
		return
	end

	if not self._eventPanel.Visible then
		self._eventPanel.Visible = true
		Components.FadeIn(self._eventPanel, { duration = "fast", slide = Vector2.new(20, 0) })
	end

	if payload.name then
		self._eventName.Text = string.upper(payload.name)
	end

	if payload.phaseName then
		self._eventPhase.Text = payload.phaseCount
			and ("%s  (%d/%d)"):format(payload.phaseName, payload.phaseIndex or 1, payload.phaseCount)
			or payload.phaseName
	end

	if payload.objective then
		self._eventObjective.Text = payload.objective
	end

	if payload.remaining then
		local remaining = math.max(0, payload.remaining)
		self._eventTimer.Text = ("%d:%02d"):format(math.floor(remaining / 60), math.floor(remaining % 60))
		-- The last ten seconds turn red, because that is when a player's decision
		-- about whether to commit or bail actually changes.
		self._eventTimer.TextColor3 = remaining <= 10 and Theme.Color.danger or Theme.Color.textPrimary
	end

	if payload.bossHealthFraction then
		self._eventBossBar.Instance.Visible = true
		self._eventBossBar:SetValue(payload.bossHealthFraction, true)
	end

	if payload.contribution then
		self._eventContribution.Text = ("Your contribution: %s"):format(Theme.FormatNumber(payload.contribution))
	elseif payload.nodes then
		self._eventContribution.Text = ("%d nodes active"):format(payload.nodes)
	end
end

function Hud:ClearWorldEvent()
	self:UpdateWorldEvent(nil)
end

function Hud:ShowBanner(config: {
	title: string,
	subtitle: string?,
	detail: string?,
	color: Color3?,
	duration: number?,
})
	self._bannerTitle.Text = config.title
	self._bannerTitle.TextColor3 = config.color or Theme.Color.textPrimary
	self._bannerSubtitle.Text = config.subtitle or ""
	self._bannerDetail.Text = config.detail or ""

	self._banner.Visible = true
	self._banner.Position = UDim2.new(0.5, 0, 0, 40)

	for _, descendant in ipairs(self._banner:GetDescendants()) do
		if descendant:IsA("TextLabel") then
			descendant.TextTransparency = 1
			TweenService:Create(descendant, Theme.Tween("slow", "standard"), { TextTransparency = 0 }):Play()
		end
	end
	TweenService:Create(self._banner, Theme.Tween("slow", "enter"), {
		Position = UDim2.new(0.5, 0, 0, 60),
	}):Play()

	-- Cancel any previous dismissal so a rapid second banner does not vanish early.
	if self._bannerTask then
		task.cancel(self._bannerTask)
	end
	self._bannerTask = task.delay(config.duration or 4, function()
		for _, descendant in ipairs(self._banner:GetDescendants()) do
			if descendant:IsA("TextLabel") then
				TweenService:Create(descendant, Theme.Tween("slow", "exit"), { TextTransparency = 1 }):Play()
			end
		end
		task.wait(Theme.Duration.slow)
		self._banner.Visible = false
		self._bannerTask = nil
	end)
end

-- ============================================================================
-- Capture feedback
-- ============================================================================

function Hud:ShowCaptureFeedback(result: any)
	local text, color

	if result.success then
		color = Theme.GradeColor(result.grade)
		if result.energy then
			text = ("%s  +%s"):format(string.upper(result.grade), Theme.FormatNumber(result.energy))
		else
			text = string.upper(result.grade)
		end
		if result.announce then
			text = text .. "  ·  " .. result.announce
		end
	else
		color = Theme.Color.gradeMiss
		if result.reason == "no_target" then
			text = "NOTHING IN RANGE"
			color = Theme.Color.textTertiary
		elseif result.reason == "decoy" then
			text = "DECOY"
		elseif result.reason == "out_of_range" then
			text = "TOO FAR"
		elseif result.reason == "too_low" then
			text = "TOO LOW"
		elseif result.reason == "not_airborne" then
			text = "GET AIRBORNE"
		elseif result.reason == "mistimed" then
			text = "MISSED"
		else
			text = "MISSED"
		end
	end

	self._feedback.Text = text
	self._feedback.TextColor3 = color
	self._feedback.TextTransparency = 0
	self._feedback.Position = UDim2.fromScale(0.5, 0.62)

	TweenService:Create(self._feedback, Theme.Tween("deliberate", "exit"), {
		TextTransparency = 1,
		Position = UDim2.fromScale(0.5, 0.58),
	}):Play()

	if result.success then
		Components.Pulse(self._readouts.carried.Instance, 1.12, "fast")
	elseif result.reason ~= "no_target" then
		Components.Shake(self._carryCluster, 5, 4)
	end
end

-- ============================================================================
-- Per-frame update
-- ============================================================================

--[[
	Called every render step. Advances the animated bars and readouts, and drives the
	capture ring, which is the one element that genuinely needs frame-rate fidelity.
]]
function Hud:Update(deltaTime: number)
	for _, bar in pairs(self._bars) do
		bar:Update(deltaTime)
	end
	for _, readout in pairs(self._readouts) do
		readout:Update(deltaTime)
	end

	self:_updateCaptureRing()
	self:_updateCompass()
	self:_applyLayout()
end

function Hud:_updateCaptureRing()
	local storms = self._controllers.StormController
	if not storms then
		return
	end

	local strike = storms:GetTargetStrike()
	if not strike then
		if self._captureRing.Visible then
			self._captureRing.Visible = false
		end
		return
	end

	if not self._captureRing.Visible then
		self._captureRing.Visible = true
	end

	local progress = storms:GetStrikeProgress(strike)
	local grade, normalised = storms:PredictGrade(strike)

	-- The ring closes from 200px to the 96px window ring as the strike approaches
	-- its peak, then continues shrinking past it so a late press reads as late.
	local size = MathUtil.Lerp(200, 96, math.clamp(progress, 0, 1))
	if progress > 1 then
		size = MathUtil.Lerp(96, 60, math.clamp(progress - 1, 0, 1))
	end
	self._closingRing.Size = UDim2.fromOffset(size, size)

	-- Colour is the predicted grade, which teaches the timing continuously.
	local ringColor = grade and Theme.GradeColor(grade) or Theme.Color.textTertiary
	self._closingStroke.Color = ringColor
	self._closingStroke.Thickness = grade == "Perfect" or grade == "Overcharge"
		and Theme.Stroke.heavy
		or Theme.Stroke.thick

	-- An inverted strike flips the meaning, so the window ring is marked differently
	-- and the label says so outright.
	local storm = require(Shared.Config.StormTypes).ById[strike.stormTypeId]
	if strike.inverted then
		self._windowStroke.Color = Theme.Color.danger
		self._captureLabel.Text = (storm and storm.name or "Storm") .. "  ·  INVERTED"
		self._captureLabel.TextColor3 = Theme.Color.danger
	else
		self._windowStroke.Color = Theme.Color.textTertiary
		self._captureLabel.Text = storm and storm.name or "Storm"
		self._captureLabel.TextColor3 = Theme.Color.textSecondary
	end

	local input = self._controllers.InputController
	self._capturePrompt.Text = input and ("[%s] CAPTURE"):format(input:GetPrompt("capture")) or "CAPTURE"
end

function Hud:_updateCompass()
	local storms = self._controllers.StormController
	local camera = Workspace.CurrentCamera
	if not storms or not camera then
		return
	end

	local character = LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		for _, marker in ipairs(self._compassMarkers) do
			marker.Visible = false
		end
		return
	end

	local origin = (root :: BasePart).Position
	local lookVector = camera.CFrame.LookVector
	local forward = Vector3.new(lookVector.X, 0, lookVector.Z)
	if forward.Magnitude < 0.01 then
		return
	end
	forward = forward.Unit
	local right = Vector3.new(forward.Z, 0, -forward.X)

	local nearby = storms:GetNearbyCells(#self._compassMarkers)

	for index, marker in ipairs(self._compassMarkers) do
		local entry = nearby[index]
		if not entry then
			marker.Visible = false
			continue
		end

		local toCell = entry.cell.position - origin
		local flat = Vector3.new(toCell.X, 0, toCell.Z)
		if flat.Magnitude < 0.01 then
			marker.Visible = false
			continue
		end
		flat = flat.Unit

		-- Project onto the camera's forward/right basis; anything behind is hidden
		-- rather than clamped to an edge, which would lie about direction.
		local forwardDot = flat:Dot(forward)
		if forwardDot <= 0.1 then
			marker.Visible = false
			continue
		end

		local rightDot = flat:Dot(right)
		local normalised = math.clamp(rightDot / math.max(0.2, forwardDot) * 0.5, -1, 1)

		marker.Visible = true
		marker.Position = UDim2.fromScale(0.5 + normalised * 0.5, 0.5)

		local storm = require(Shared.Config.StormTypes).ById[entry.cell.stormTypeId]
		local rarity = storm and Theme.GetRarity(storm.rarity) or Theme.GetRarity("common")
		marker.BackgroundColor3 = rarity.color

		-- Nearer storms read as taller ticks, so proximity is legible without text.
		local proximity = math.clamp(1 - entry.distance / 1200, 0.25, 1)
		marker.Size = UDim2.fromOffset(3, 8 + 10 * proximity)
	end
end

--[[
	Scales the whole HUD. Applied as one UIScale on the root rather than by resizing
	each element, so a player who needs larger text gets larger everything and the
	layout keeps its proportions.
]]
function Hud:SetScale(scale: number)
	local clamped = math.clamp(scale or 1, 0.6, 1.6)

	local uiScale = self._root:FindFirstChildOfClass("UIScale")
	if not uiScale then
		uiScale = Instance.new("UIScale")
		uiScale.Parent = self._root
	end
	uiScale.Scale = clamped
end

function Hud:SetVisible(visible: boolean)
	self._root.Visible = visible
end

function Hud:Destroy()
	if self._bannerTask then
		task.cancel(self._bannerTask)
	end
	self._maid:DoCleaning()
	self._root:Destroy()
end

return Hud
