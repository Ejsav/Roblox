--!strict
--[[
	MapScreen
	---------
	The world map. In a world this large the map is not a convenience, it is the
	primary tool for deciding what to do next, so it gets first-class treatment.

	What it has to do:
	  * Show the whole world at a glance and let the player zoom into detail.
	  * Make locked regions legible as goals rather than walls — the requirement is
	    always stated, never just "locked".
	  * Show live storm activity, so "where is the weather" is answerable without
	    walking.
	  * Hide what has not been found. A map that reveals every secret on day one
	    removes the reason to explore.

	Rendering: regions and markers are plain frames positioned by a world-to-map
	projection. No image assets, so the map is correct the moment the atlas changes.
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BTS")
local Theme = require(Shared.Config.Theme)
local Regions = require(Shared.Config.Regions)
local StormTypes = require(Shared.Config.StormTypes)
local Maid = require(Shared.Core.Maid)
local MathUtil = require(Shared.Core.MathUtil)
local Net = require(Shared.Net)

local Client = script.Parent.Parent.Parent
local Components = require(Client.UI.Components)

local MapScreen = {}
MapScreen.__index = MapScreen

local LocalPlayer = Players.LocalPlayer

local MIN_ZOOM = 0.5
local MAX_ZOOM = 6

function MapScreen.new(parent: Instance, controllers: any)
	local self = setmetatable({
		_maid = Maid.new(),
		_controllers = controllers,
		_zoom = 1,
		_pan = Vector2.zero,
		_dragging = false,
		_regionFrames = {},
		_markers = {},
		_stormMarkers = {},
		_profile = nil,
		_selectedRegion = nil,
	}, MapScreen)

	self._bounds = Regions.GetWorldBounds()
	self:_build(parent)
	return self
end

-- ============================================================================
-- Projection
-- ============================================================================

--[[
	World XZ to map-space 0..1, before pan and zoom. A single projection used by
	everything on the map guarantees regions, storms and the player never disagree
	about where a point is.
]]
function MapScreen:_project(worldX: number, worldZ: number): Vector2
	local bounds = self._bounds
	return Vector2.new(
		(worldX - bounds.minX) / (bounds.maxX - bounds.minX),
		(worldZ - bounds.minZ) / (bounds.maxZ - bounds.minZ)
	)
end

--[[ Map-space 0..1 to a UDim2 inside the canvas, applying pan and zoom. ]]
function MapScreen:_toCanvas(point: Vector2): UDim2
	local zoomed = (point - Vector2.new(0.5, 0.5)) * self._zoom + Vector2.new(0.5, 0.5) + self._pan
	return UDim2.fromScale(zoomed.X, zoomed.Y)
end

--[[ The map-space size of a world-space radius, at the current zoom. ]]
function MapScreen:_projectRadius(worldRadius: number): number
	local bounds = self._bounds
	return (worldRadius / (bounds.maxX - bounds.minX)) * self._zoom
end

-- ============================================================================
-- Construction
-- ============================================================================

function MapScreen:_build(parent: Instance)
	local root = Components.Panel({
		parent = parent,
		name = "MapScreen",
		size = UDim2.fromScale(1, 1),
		elevation = 0,
		radius = 0,
		zIndex = Theme.ZIndex.panel,
	})
	self._root = root
	self._maid:Add(root)

	-- Header.
	local header = Components.Container({
		parent = root,
		name = "Header",
		size = UDim2.new(1, 0, 0, 56),
		zIndex = root.ZIndex + 1,
	})
	Components.Padding(header, Theme.Space.lg)

	Components.Heading({
		parent = header,
		text = "WORLD",
		size = UDim2.new(0, 200, 1, 0),
		textSize = Theme.Text.title,
		zIndex = header.ZIndex + 1,
	})

	self._regionCountLabel = Components.Label({
		parent = header,
		name = "RegionCount",
		text = "",
		position = UDim2.new(0, 210, 0, 0),
		size = UDim2.new(0, 300, 1, 0),
		textSize = Theme.Text.label,
		zIndex = header.ZIndex + 1,
	})

	-- The canvas itself.
	local canvasContainer = Components.Panel({
		parent = root,
		name = "CanvasContainer",
		size = UDim2.new(1, -Theme.Space.xl, 1, -190),
		position = UDim2.fromOffset(Theme.Space.lg, 60),
		elevation = 0,
		radius = Theme.Radius.lg,
		zIndex = root.ZIndex + 1,
	})
	canvasContainer.ClipsDescendants = true
	canvasContainer.BackgroundColor3 = Theme.Color.void
	self._canvasContainer = canvasContainer

	local canvas = Components.Container({
		parent = canvasContainer,
		name = "Canvas",
		size = UDim2.fromScale(1, 1),
		zIndex = canvasContainer.ZIndex + 1,
	})
	self._canvas = canvas

	self:_buildRegions()
	self:_buildPlayerMarker()
	self:_buildDetailPanel(root)
	self:_bindInteraction()
end

--[[ One disc per region, plus its label and sub-markers. ]]
function MapScreen:_buildRegions()
	for _, region in ipairs(Regions.List) do
		local centre = self:_project(region.center.X, region.center.Z)

		local disc = Instance.new("Frame")
		disc.Name = region.id
		disc.AnchorPoint = Vector2.new(0.5, 0.5)
		disc.BackgroundColor3 = Theme.DangerColor(region.danger)
		disc.BackgroundTransparency = 0.82
		disc.BorderSizePixel = 0
		disc.ZIndex = self._canvas.ZIndex + 1
		disc.Parent = self._canvas
		Components.Corner(disc, Theme.Radius.pill)
		local stroke = Components.Stroke(disc, Theme.DangerColor(region.danger), Theme.Stroke.thin, 0.4)

		local label = Components.Text({
			parent = disc,
			name = "Label",
			text = region.name,
			size = UDim2.fromScale(1, 0),
			position = UDim2.fromScale(0.5, 0.5),
			anchorPoint = Vector2.new(0.5, 0.5),
			textSize = Theme.Text.label,
			font = Theme.Font.medium,
			color = Theme.Color.textPrimary,
			alignX = Enum.TextXAlignment.Center,
			zIndex = disc.ZIndex + 2,
		})
		label.AutomaticSize = Enum.AutomaticSize.Y

		local lockLabel = Components.Text({
			parent = disc,
			name = "Lock",
			text = "",
			size = UDim2.fromScale(1, 0),
			position = UDim2.fromScale(0.5, 0.5),
			anchorPoint = Vector2.new(0.5, -0.2),
			textSize = Theme.Text.caption,
			color = Theme.Color.danger,
			alignX = Enum.TextXAlignment.Center,
			wrapped = true,
			zIndex = disc.ZIndex + 2,
		})
		lockLabel.AutomaticSize = Enum.AutomaticSize.Y

		-- Clicking a region focuses it and fills the detail panel.
		local button = Instance.new("TextButton")
		button.Size = UDim2.fromScale(1, 1)
		button.BackgroundTransparency = 1
		button.Text = ""
		button.ZIndex = disc.ZIndex + 3
		button.Parent = disc
		self._maid:Add(button.Activated:Connect(function()
			self:SelectRegion(region.id)
		end))

		-- Fast travel node.
		local travelMarker = nil
		if region.fastTravel then
			travelMarker = Instance.new("Frame")
			travelMarker.Name = "FastTravel"
			travelMarker.Size = UDim2.fromOffset(10, 10)
			travelMarker.AnchorPoint = Vector2.new(0.5, 0.5)
			travelMarker.BackgroundColor3 = Theme.Color.accent
			travelMarker.BorderSizePixel = 0
			travelMarker.ZIndex = self._canvas.ZIndex + 4
			travelMarker.Parent = self._canvas
			Components.Corner(travelMarker, Theme.Radius.pill)
		end

		self._regionFrames[region.id] = {
			region = region,
			disc = disc,
			stroke = stroke,
			label = label,
			lockLabel = lockLabel,
			travelMarker = travelMarker,
			centre = centre,
		}
	end
end

function MapScreen:_buildPlayerMarker()
	local marker = Instance.new("Frame")
	marker.Name = "Player"
	marker.Size = UDim2.fromOffset(12, 12)
	marker.AnchorPoint = Vector2.new(0.5, 0.5)
	marker.BackgroundColor3 = Theme.Color.textPrimary
	marker.BorderSizePixel = 0
	marker.ZIndex = self._canvas.ZIndex + 10
	marker.Parent = self._canvas
	Components.Corner(marker, Theme.Radius.pill)
	Components.Stroke(marker, Theme.Color.void, Theme.Stroke.thick)
	self._playerMarker = marker

	-- A facing indicator, so the map answers "which way am I pointing?".
	local facing = Instance.new("Frame")
	facing.Name = "Facing"
	facing.Size = UDim2.fromOffset(3, 14)
	facing.AnchorPoint = Vector2.new(0.5, 1)
	facing.Position = UDim2.fromScale(0.5, 0.5)
	facing.BackgroundColor3 = Theme.Color.accent
	facing.BorderSizePixel = 0
	facing.ZIndex = marker.ZIndex - 1
	facing.Parent = marker
	self._playerFacing = facing
end

--[[ The detail panel: everything about the selected region, including its gate. ]]
function MapScreen:_buildDetailPanel(root: Frame)
	local panel = Components.Panel({
		parent = root,
		name = "Detail",
		size = UDim2.new(1, -Theme.Space.xl, 0, 118),
		position = UDim2.new(0, Theme.Space.lg, 1, -(118 + Theme.Space.lg)),
		elevation = 2,
		padding = Theme.Space.lg,
		zIndex = root.ZIndex + 2,
	})
	self._detailPanel = panel

	self._detailTitle = Components.Heading({
		parent = panel,
		name = "Title",
		text = "Select a region",
		size = UDim2.new(1, 0, 0, 24),
		zIndex = panel.ZIndex + 1,
	})

	self._detailSubtitle = Components.Text({
		parent = panel,
		name = "Subtitle",
		text = "",
		position = UDim2.fromOffset(0, 26),
		size = UDim2.new(1, 0, 0, 18),
		textSize = Theme.Text.label,
		color = Theme.Color.textSecondary,
		zIndex = panel.ZIndex + 1,
	})

	self._detailStats = Components.Text({
		parent = panel,
		name = "Stats",
		text = "",
		position = UDim2.fromOffset(0, 48),
		size = UDim2.new(1, 0, 0, 18),
		textSize = Theme.Text.label,
		color = Theme.Color.textTertiary,
		zIndex = panel.ZIndex + 1,
	})

	self._detailStatus = Components.Text({
		parent = panel,
		name = "Status",
		text = "",
		position = UDim2.fromOffset(0, 70),
		size = UDim2.new(1, -160, 0, 18),
		textSize = Theme.Text.label,
		color = Theme.Color.warning,
		wrapped = true,
		zIndex = panel.ZIndex + 1,
	})

	local _, travelButton = Components.Button({
		parent = panel,
		name = "Travel",
		text = "TRAVEL",
		variant = "primary",
		size = UDim2.fromOffset(140, 40),
		position = UDim2.new(1, 0, 1, 0),
		anchorPoint = Vector2.new(1, 1),
		zIndex = panel.ZIndex + 2,
		enabled = false,
	})
	self._travelButton = travelButton

	self._maid:Add(travelButton.Pressed:Connect(function()
		self:_travelToSelected()
	end))
end

-- ============================================================================
-- Interaction
-- ============================================================================

function MapScreen:_bindInteraction()
	local container = self._canvasContainer

	-- Drag to pan.
	self._maid:Add(container.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
		then
			self._dragging = true
			self._dragStart = input.Position
			self._panStart = self._pan
		end
	end))

	self._maid:Add(UserInputService.InputChanged:Connect(function(input)
		if not self._dragging then
			return
		end
		if input.UserInputType ~= Enum.UserInputType.MouseMovement
			and input.UserInputType ~= Enum.UserInputType.Touch
		then
			return
		end

		local containerSize = container.AbsoluteSize
		local delta = Vector2.new(
			(input.Position.X - self._dragStart.X) / containerSize.X,
			(input.Position.Y - self._dragStart.Y) / containerSize.Y
		)
		self._pan = self._panStart + delta
		self:_clampPan()
		self:Refresh()
	end))

	self._maid:Add(UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
		then
			self._dragging = false
		end
	end))

	-- Scroll to zoom, anchored on the container centre.
	self._maid:Add(container.InputChanged:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseWheel then
			self:_setZoom(self._zoom * (input.Position.Z > 0 and 1.18 or 1 / 1.18))
		end
	end))

	-- Pinch to zoom on touch.
	self._maid:Add(UserInputService.TouchPinch:Connect(function(_, scale, _, state)
		if state == Enum.UserInputState.Change then
			self:_setZoom(self._zoom * scale)
		end
	end))
end

function MapScreen:_setZoom(zoom: number)
	self._zoom = math.clamp(zoom, MIN_ZOOM, MAX_ZOOM)
	self:_clampPan()
	self:Refresh()
end

--[[ Keeps the map from being dragged entirely off screen. ]]
function MapScreen:_clampPan()
	local limit = math.max(0, (self._zoom - 1) * 0.5) + 0.15
	self._pan = Vector2.new(
		math.clamp(self._pan.X, -limit, limit),
		math.clamp(self._pan.Y, -limit, limit)
	)
end

function MapScreen:SelectRegion(regionId: string)
	self._selectedRegion = regionId
	self:_updateDetail()

	-- Highlight the selection.
	for id, entry in pairs(self._regionFrames) do
		entry.stroke.Thickness = id == regionId and Theme.Stroke.thick or Theme.Stroke.thin
		entry.stroke.Transparency = id == regionId and 0 or 0.4
	end
end

function MapScreen:_travelToSelected()
	local entry = self._regionFrames[self._selectedRegion]
	if not entry or not entry.region.fastTravel then
		return
	end
	Net.FireServer("RequestFastTravel", entry.region.fastTravel.id)
end

-- ============================================================================
-- Data
-- ============================================================================

function MapScreen:SetProfile(profile: any)
	self._profile = profile
	self:Refresh()
end

--[[ Whether a region is unlocked, and what is blocking it. ]]
function MapScreen:_regionStatus(region: any): (boolean, string?)
	if not self._profile then
		return false, nil
	end

	local unlocked, reason, requirement = Regions.IsUnlocked(region.id, {
		level = self._profile.level,
		prestige = self._profile.prestige,
		completedQuests = self._profile.completedQuests,
		traversal = self._profile.traversal,
	})

	if unlocked then
		return true, nil
	end

	-- The requirement is always stated. A player who knows what a wall costs is
	-- looking at a goal; one who does not is looking at a dead end.
	if reason == "level" then
		return false, ("Level %d"):format(requirement)
	elseif reason == "quest" then
		local Quests = require(Shared.Config.Quests)
		local quest = Quests.ById[requirement]
		return false, quest and quest.name or "Story"
	elseif reason == "traversal" then
		local Traversal = require(Shared.Config.Traversal)
		local ability = Traversal.ById[requirement]
		return false, ability and ability.name or "Movement tech"
	elseif reason == "prestige" then
		return false, ("Prestige %d"):format(requirement)
	end

	return false, "Locked"
end

function MapScreen:_updateDetail()
	local entry = self._regionFrames[self._selectedRegion]
	if not entry then
		self._detailTitle.Text = "Select a region"
		self._detailSubtitle.Text = ""
		self._detailStats.Text = ""
		self._detailStatus.Text = ""
		self._travelButton:SetEnabled(false)
		return
	end

	local region = entry.region
	local unlocked, requirement = self:_regionStatus(region)

	self._detailTitle.Text = region.name
	self._detailSubtitle.Text = region.subtitle

	local visited = self._profile and self._profile.regionsVisited[region.id]
	local discoveries = self._profile and self._profile.discoveries or {}
	local foundHere = 0
	for discoveryId in pairs(discoveries) do
		if discoveryId:match("^" .. region.id) then
			foundHere += 1
		end
	end

	self._detailStats.Text = ("Danger %d  ·  Recommended level %d  ·  Discoveries %d/%d")
		:format(region.danger, region.recommendedLevel, foundHere, region.discoveryCount)

	if unlocked then
		local canTravel = self._profile
			and region.fastTravel
			and self._profile.fastTravelUnlocked[region.fastTravel.id]
		self._detailStatus.Text = canTravel and "" or "Visit this region on foot to unlock its relay."
		self._detailStatus.TextColor3 = Theme.Color.textTertiary
		self._travelButton:SetEnabled(canTravel == true)
	else
		self._detailStatus.Text = "LOCKED — requires " .. (requirement or "more progress")
		self._detailStatus.TextColor3 = Theme.Color.warning
		self._travelButton:SetEnabled(false)
	end

	-- A region never visited shows its atmosphere rather than its contents, so the
	-- map hints without spoiling.
	if not visited then
		self._detailSubtitle.Text = region.subtitle .. "  ·  UNVISITED"
	end
end

-- ============================================================================
-- Rendering
-- ============================================================================

function MapScreen:Refresh()
	local unlockedCount = 0

	for _, entry in pairs(self._regionFrames) do
		local region = entry.region
		local unlocked, requirement = self:_regionStatus(region)
		local visited = self._profile and self._profile.regionsVisited[region.id]

		if unlocked then
			unlockedCount += 1
		end

		local radiusScale = self:_projectRadius(region.radius)
		local containerAspect = self._canvasContainer.AbsoluteSize
		local aspect = containerAspect.Y > 0 and (containerAspect.X / containerAspect.Y) or 1

		entry.disc.Position = self:_toCanvas(entry.centre)
		-- Scale is expressed against the container's width on both axes so a disc
		-- stays circular regardless of the panel's aspect ratio.
		entry.disc.Size = UDim2.fromScale(radiusScale * 2, radiusScale * 2 * aspect)

		-- Unvisited regions are dimmer; locked ones show their requirement.
		if visited then
			entry.disc.BackgroundTransparency = 0.78
			entry.label.TextTransparency = 0
		else
			entry.disc.BackgroundTransparency = 0.9
			entry.label.TextTransparency = 0.35
		end

		entry.lockLabel.Text = unlocked and "" or (requirement or "LOCKED")
		entry.label.TextSize = math.clamp(Theme.Text.label * self._zoom * 0.8, 9, 22)

		if entry.travelMarker then
			local travelPoint = self:_project(region.fastTravel.position.X, region.fastTravel.position.Z)
			entry.travelMarker.Position = self:_toCanvas(travelPoint)
			local discovered = self._profile and self._profile.fastTravelUnlocked[region.fastTravel.id]
			entry.travelMarker.BackgroundColor3 = discovered and Theme.Color.accent or Theme.Color.textDisabled
			entry.travelMarker.Visible = unlocked
		end
	end

	self._regionCountLabel.Text = ("%d of %d regions unlocked"):format(unlockedCount, #Regions.List)
	self:_updateDetail()
end

--[[ Per-frame: the player marker and live storm markers. ]]
function MapScreen:Update(deltaTime: number)
	local character = LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root then
		local position = (root :: BasePart).Position
		self._playerMarker.Position = self:_toCanvas(self:_project(position.X, position.Z))
		self._playerMarker.Visible = true

		local camera = Workspace.CurrentCamera
		if camera then
			local look = camera.CFrame.LookVector
			-- Map Z increases downward on screen, so the rotation is negated.
			self._playerFacing.Rotation = -math.deg(math.atan2(look.X, -look.Z))
		end
	else
		self._playerMarker.Visible = false
	end

	self:_updateStormMarkers()
end

--[[
	Live storm markers. Only storms the player's scanner can actually see are drawn;
	the map does not know more than the equipment does.
]]
function MapScreen:_updateStormMarkers()
	local storms = self._controllers.StormController
	if not storms then
		return
	end

	local cells = storms:GetCells()
	local seen = {}

	for cellId, cell in pairs(cells) do
		seen[cellId] = true
		local marker = self._stormMarkers[cellId]

		if not marker then
			marker = Instance.new("Frame")
			marker.Name = "Storm_" .. cellId
			marker.Size = UDim2.fromOffset(8, 8)
			marker.AnchorPoint = Vector2.new(0.5, 0.5)
			marker.BorderSizePixel = 0
			marker.ZIndex = self._canvas.ZIndex + 6
			marker.Parent = self._canvas
			Components.Corner(marker, Theme.Radius.pill)
			self._stormMarkers[cellId] = marker
		end

		local storm = StormTypes.ById[cell.stormTypeId]
		local rarity = storm and Theme.GetRarity(storm.rarity) or Theme.GetRarity("common")
		marker.BackgroundColor3 = rarity.color

		-- Rare storms are drawn larger, because "there is something worth crossing
		-- the map for" is the single most useful thing the map can say.
		local isRare = storm and (storm.rarity ~= "common" and storm.rarity ~= "uncommon")
		marker.Size = UDim2.fromOffset(isRare and 14 or 8, isRare and 14 or 8)
		marker.Position = self:_toCanvas(self:_project(cell.position.X, cell.position.Z))
	end

	for cellId, marker in pairs(self._stormMarkers) do
		if not seen[cellId] then
			marker:Destroy()
			self._stormMarkers[cellId] = nil
		end
	end
end

--[[ Centres the map on the player, used when the screen opens. ]]
function MapScreen:CentreOnPlayer()
	local character = LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		return
	end
	local position = (root :: BasePart).Position
	local projected = self:_project(position.X, position.Z)
	self._pan = (Vector2.new(0.5, 0.5) - projected) * self._zoom
	self:_clampPan()
	self:Refresh()
end

function MapScreen:SetVisible(visible: boolean)
	self._root.Visible = visible
	if visible then
		self:CentreOnPlayer()
		Components.FadeIn(self._root, { duration = "fast" })
	end
end

function MapScreen:Destroy()
	self._maid:DoCleaning()
end

return MapScreen
