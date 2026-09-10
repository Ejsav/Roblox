--!strict
--[[
	UI Components
	-------------
	The reusable building blocks every screen is assembled from.

	The rule this module exists to enforce: no screen creates a raw Frame or
	TextLabel. Everything goes through a component, which means a change to the
	panel treatment or the button press feel happens once and lands everywhere.

	Components return the created Instance plus, where relevant, a small controller
	table for the behaviour that cannot be expressed as properties (a bar that
	animates to a value, a button that reports presses).
]]

local TweenService = game:GetService("TweenService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BTS")
local Theme = require(Shared.Config.Theme)
local Signal = require(Shared.Core.Signal)
local Maid = require(Shared.Core.Maid)
local MathUtil = require(Shared.Core.MathUtil)

local Components = {}

-- ============================================================================
-- Primitives
-- ============================================================================

--[[ Applies a corner radius. ]]
function Components.Corner(parent: Instance, radius: number?): UICorner
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius or Theme.Radius.md)
	corner.Parent = parent
	return corner
end

--[[ Applies a stroke. ]]
function Components.Stroke(parent: Instance, color: Color3?, thickness: number?, transparency: number?): UIStroke
	local stroke = Instance.new("UIStroke")
	stroke.Color = color or Theme.Color.border
	stroke.Thickness = thickness or Theme.Stroke.hairline
	stroke.Transparency = transparency or 0
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = parent
	return stroke
end

--[[ Uniform or per-side padding, in theme space units. ]]
function Components.Padding(parent: Instance, all: number?, sides: {
	top: number?, bottom: number?, left: number?, right: number?,
}?): UIPadding
	local padding = Instance.new("UIPadding")
	local base = all or Theme.Space.md
	padding.PaddingTop = UDim.new(0, (sides and sides.top) or base)
	padding.PaddingBottom = UDim.new(0, (sides and sides.bottom) or base)
	padding.PaddingLeft = UDim.new(0, (sides and sides.left) or base)
	padding.PaddingRight = UDim.new(0, (sides and sides.right) or base)
	padding.Parent = parent
	return padding
end

--[[ A vertical or horizontal stack. ]]
function Components.List(parent: Instance, config: {
	direction: Enum.FillDirection?,
	gap: number?,
	alignX: Enum.HorizontalAlignment?,
	alignY: Enum.VerticalAlignment?,
	sortOrder: Enum.SortOrder?,
}?): UIListLayout
	local settings = config or {}
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = settings.direction or Enum.FillDirection.Vertical
	layout.Padding = UDim.new(0, settings.gap or Theme.Space.sm)
	layout.HorizontalAlignment = settings.alignX or Enum.HorizontalAlignment.Left
	layout.VerticalAlignment = settings.alignY or Enum.VerticalAlignment.Top
	layout.SortOrder = settings.sortOrder or Enum.SortOrder.LayoutOrder
	layout.Parent = parent
	return layout
end

function Components.Grid(parent: Instance, config: {
	cellSize: UDim2,
	gap: number?,
	alignX: Enum.HorizontalAlignment?,
}): UIGridLayout
	local grid = Instance.new("UIGridLayout")
	grid.CellSize = config.cellSize
	grid.CellPadding = UDim2.fromOffset(config.gap or Theme.Space.sm, config.gap or Theme.Space.sm)
	grid.HorizontalAlignment = config.alignX or Enum.HorizontalAlignment.Left
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.Parent = parent
	return grid
end

-- ============================================================================
-- Surfaces
-- ============================================================================

--[[
	A panel: the standard surface everything sits on.
	`elevation` selects background and border from the theme's depth scale.
]]
function Components.Panel(config: {
	parent: Instance?,
	name: string?,
	size: UDim2?,
	position: UDim2?,
	anchorPoint: Vector2?,
	elevation: number?,
	radius: number?,
	padding: number?,
	transparency: number?,
	zIndex: number?,
	borderColor: Color3?,
}): Frame
	local elevation = Theme.Elevation[config.elevation or 1]

	local frame = Instance.new("Frame")
	frame.Name = config.name or "Panel"
	frame.Size = config.size or UDim2.fromScale(1, 1)
	frame.Position = config.position or UDim2.fromScale(0, 0)
	frame.AnchorPoint = config.anchorPoint or Vector2.zero
	frame.BackgroundColor3 = elevation.background
	frame.BackgroundTransparency = config.transparency or 0
	frame.BorderSizePixel = 0
	frame.ZIndex = config.zIndex or Theme.ZIndex.panel
	frame.Parent = config.parent

	Components.Corner(frame, config.radius)
	Components.Stroke(frame, config.borderColor or elevation.border)

	if config.padding then
		Components.Padding(frame, config.padding)
	end

	return frame
end

--[[ A transparent container with no treatment, for pure layout. ]]
function Components.Container(config: {
	parent: Instance?,
	name: string?,
	size: UDim2?,
	position: UDim2?,
	anchorPoint: Vector2?,
	zIndex: number?,
}): Frame
	local frame = Instance.new("Frame")
	frame.Name = config.name or "Container"
	frame.Size = config.size or UDim2.fromScale(1, 1)
	frame.Position = config.position or UDim2.fromScale(0, 0)
	frame.AnchorPoint = config.anchorPoint or Vector2.zero
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	frame.ZIndex = config.zIndex or Theme.ZIndex.hud
	frame.Parent = config.parent
	return frame
end

-- ============================================================================
-- Text
-- ============================================================================

function Components.Text(config: {
	parent: Instance?,
	name: string?,
	text: string?,
	size: UDim2?,
	position: UDim2?,
	anchorPoint: Vector2?,
	textSize: number?,
	font: Enum.Font?,
	color: Color3?,
	alignX: Enum.TextXAlignment?,
	alignY: Enum.TextYAlignment?,
	wrapped: boolean?,
	transparency: number?,
	zIndex: number?,
	autoSize: Enum.AutomaticSize?,
	layoutOrder: number?,
	richText: boolean?,
}): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = config.name or "Text"
	label.Text = config.text or ""
	label.Size = config.size or UDim2.new(1, 0, 0, config.textSize or Theme.Text.body)
	label.Position = config.position or UDim2.fromScale(0, 0)
	label.AnchorPoint = config.anchorPoint or Vector2.zero
	label.BackgroundTransparency = 1
	label.TextSize = config.textSize or Theme.Text.body
	label.Font = config.font or Theme.Font.body
	label.TextColor3 = config.color or Theme.Color.textPrimary
	label.TextXAlignment = config.alignX or Enum.TextXAlignment.Left
	label.TextYAlignment = config.alignY or Enum.TextYAlignment.Center
	label.TextWrapped = config.wrapped or false
	label.TextTransparency = config.transparency or 0
	label.RichText = config.richText or false
	label.ZIndex = config.zIndex or Theme.ZIndex.hud
	label.LayoutOrder = config.layoutOrder or 0
	if config.autoSize then
		label.AutomaticSize = config.autoSize
	end
	label.Parent = config.parent
	return label
end

--[[ A heading with its standard treatment. ]]
function Components.Heading(config: any): TextLabel
	config.font = config.font or Theme.Font.heading
	config.textSize = config.textSize or Theme.Text.heading
	config.color = config.color or Theme.Color.textPrimary
	return Components.Text(config)
end

--[[ A small uppercase label, the workhorse of dense HUD readouts. ]]
function Components.Label(config: any): TextLabel
	config.font = config.font or Theme.Font.medium
	config.textSize = config.textSize or Theme.Text.label
	config.color = config.color or Theme.Color.textTertiary
	local label = Components.Text(config)
	if config.uppercase ~= false then
		label.Text = string.upper(label.Text)
	end
	return label
end

-- ============================================================================
-- Button
-- ============================================================================

--[[
	A button with proper interaction states.
	Returns (instance, controller) where the controller exposes `Pressed`,
	`SetEnabled` and `SetText`.

	Press feedback is a scale-down rather than a colour change, because at HUD
	resolution a 3% scale reads instantly and a colour shift does not.
]]
function Components.Button(config: {
	parent: Instance?,
	name: string?,
	text: string?,
	size: UDim2?,
	position: UDim2?,
	anchorPoint: Vector2?,
	variant: string?,          -- "primary" | "secondary" | "ghost" | "danger"
	textSize: number?,
	icon: string?,
	zIndex: number?,
	layoutOrder: number?,
	enabled: boolean?,
})
	local variant = config.variant or "secondary"

	local palette = {
		primary = {
			background = Theme.Color.accent,
			hover = Theme.Color.accentBright,
			text = Theme.Color.textInverse,
			border = Theme.Color.accent,
		},
		secondary = {
			background = Theme.Color.elevated,
			hover = Theme.Color.overlay,
			text = Theme.Color.textPrimary,
			border = Theme.Color.borderStrong,
		},
		ghost = {
			background = Theme.Color.base,
			hover = Theme.Color.raised,
			text = Theme.Color.textSecondary,
			border = Theme.Color.border,
		},
		danger = {
			background = Theme.Color.danger,
			hover = Theme.Color.danger:Lerp(Color3.new(1, 1, 1), 0.15),
			text = Theme.Color.textInverse,
			border = Theme.Color.danger,
		},
	}
	local colors = palette[variant] or palette.secondary

	local button = Instance.new("TextButton")
	button.Name = config.name or "Button"
	button.Size = config.size or UDim2.new(1, 0, 0, Theme.Layout.minTouchTarget)
	button.Position = config.position or UDim2.fromScale(0, 0)
	button.AnchorPoint = config.anchorPoint or Vector2.zero
	button.BackgroundColor3 = colors.background
	button.BorderSizePixel = 0
	button.Text = config.text or ""
	button.TextColor3 = colors.text
	button.TextSize = config.textSize or Theme.Text.body
	button.Font = Theme.Font.medium
	button.AutoButtonColor = false
	button.ZIndex = config.zIndex or Theme.ZIndex.panel
	button.LayoutOrder = config.layoutOrder or 0
	button.Parent = config.parent

	Components.Corner(button, Theme.Radius.md)
	local stroke = Components.Stroke(button, colors.border)

	local maid = Maid.new()
	local controller = {
		Instance = button,
		Pressed = Signal.new("Button.Pressed"),
		_enabled = config.enabled ~= false,
		_maid = maid,
	}

	local baseSize = button.Size

	local function setVisualState(background: Color3, scale: number)
		TweenService:Create(button, Theme.Tween("fast"), {
			BackgroundColor3 = background,
			Size = UDim2.new(
				baseSize.X.Scale * scale,
				baseSize.X.Offset * scale,
				baseSize.Y.Scale * scale,
				baseSize.Y.Offset * scale
			),
		}):Play()
	end

	maid:Add(button.MouseEnter:Connect(function()
		if controller._enabled then
			setVisualState(colors.hover, 1)
		end
	end))

	maid:Add(button.MouseLeave:Connect(function()
		if controller._enabled then
			setVisualState(colors.background, 1)
		end
	end))

	maid:Add(button.MouseButton1Down:Connect(function()
		if controller._enabled then
			setVisualState(colors.hover, 0.97)
		end
	end))

	maid:Add(button.MouseButton1Up:Connect(function()
		if controller._enabled then
			setVisualState(colors.hover, 1)
		end
	end))

	maid:Add(button.Activated:Connect(function()
		if controller._enabled then
			controller.Pressed:Fire()
		end
	end))

	function controller:SetEnabled(enabled: boolean)
		self._enabled = enabled
		button.TextTransparency = enabled and 0 or 0.55
		button.BackgroundTransparency = enabled and 0 or 0.4
		stroke.Transparency = enabled and 0 or 0.6
		button.Active = enabled
	end

	function controller:SetText(text: string)
		button.Text = text
	end

	function controller:Destroy()
		maid:DoCleaning()
		self.Pressed:Destroy()
		button:Destroy()
	end

	if config.enabled == false then
		controller:SetEnabled(false)
	end

	return button, controller
end

-- ============================================================================
-- Bar
-- ============================================================================

--[[
	An animated progress bar.
	Returns (instance, controller) with `SetValue(fraction, immediate)` and
	`SetColor`. The fill is spring-damped so a value that jitters (carried energy
	during a chain) reads as smooth rather than twitchy.
]]
function Components.Bar(config: {
	parent: Instance?,
	name: string?,
	size: UDim2?,
	position: UDim2?,
	anchorPoint: Vector2?,
	color: Color3?,
	backgroundColor: Color3?,
	radius: number?,
	zIndex: number?,
	layoutOrder: number?,
	showGhost: boolean?,
})
	local container = Instance.new("Frame")
	container.Name = config.name or "Bar"
	container.Size = config.size or UDim2.new(1, 0, 0, 8)
	container.Position = config.position or UDim2.fromScale(0, 0)
	container.AnchorPoint = config.anchorPoint or Vector2.zero
	container.BackgroundColor3 = config.backgroundColor or Theme.Color.raised
	container.BorderSizePixel = 0
	container.ClipsDescendants = true
	container.ZIndex = config.zIndex or Theme.ZIndex.hud
	container.LayoutOrder = config.layoutOrder or 0
	container.Parent = config.parent

	Components.Corner(container, config.radius or Theme.Radius.pill)

	-- The ghost trails behind the fill on a decrease, which is how a player sees
	-- how much they just lost rather than only that the bar is smaller.
	local ghost
	if config.showGhost then
		ghost = Instance.new("Frame")
		ghost.Name = "Ghost"
		ghost.Size = UDim2.fromScale(0, 1)
		ghost.BackgroundColor3 = (config.color or Theme.Color.accent):Lerp(Color3.new(1, 1, 1), 0.4)
		ghost.BackgroundTransparency = 0.55
		ghost.BorderSizePixel = 0
		ghost.ZIndex = container.ZIndex
		ghost.Parent = container
		Components.Corner(ghost, config.radius or Theme.Radius.pill)
	end

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = config.color or Theme.Color.accent
	fill.BorderSizePixel = 0
	fill.ZIndex = container.ZIndex + 1
	fill.Parent = container
	Components.Corner(fill, config.radius or Theme.Radius.pill)

	local controller = {
		Instance = container,
		Fill = fill,
		_value = 0,
		_ghostValue = 0,
		_spring = MathUtil.Spring.new(0, 9, 1),
	}

	function controller:SetValue(fraction: number, immediate: boolean?)
		local clamped = math.clamp(fraction, 0, 1)
		local previous = self._value
		self._value = clamped
		self._spring.Target = clamped

		if immediate then
			self._spring:Snap(clamped)
			fill.Size = UDim2.fromScale(clamped, 1)
			if ghost then
				ghost.Size = UDim2.fromScale(clamped, 1)
				self._ghostValue = clamped
			end
			return
		end

		if ghost and clamped < previous then
			-- Hold the ghost at the old value, then let it catch up.
			self._ghostValue = previous
			ghost.Size = UDim2.fromScale(previous, 1)
			TweenService:Create(ghost, Theme.Tween("deliberate", "exit", 0.25), {
				Size = UDim2.fromScale(clamped, 1),
			}):Play()
		elseif ghost then
			ghost.Size = UDim2.fromScale(clamped, 1)
			self._ghostValue = clamped
		end
	end

	--[[ Called from the client's render loop to advance the spring. ]]
	function controller:Update(deltaTime: number)
		local position = self._spring:Update(deltaTime)
		fill.Size = UDim2.fromScale(math.clamp(position, 0, 1), 1)
	end

	function controller:SetColor(color: Color3, immediate: boolean?)
		if immediate then
			fill.BackgroundColor3 = color
		else
			TweenService:Create(fill, Theme.Tween("normal"), { BackgroundColor3 = color }):Play()
		end
	end

	function controller:Destroy()
		container:Destroy()
	end

	return container, controller
end

-- ============================================================================
-- Value readout
-- ============================================================================

--[[
	A labelled numeric readout that counts smoothly to new values.
	Counting matters: a number that snaps from 1,200 to 6,050 tells the player
	nothing, while one that rolls up tells them how much they just earned.
]]
function Components.Readout(config: {
	parent: Instance?,
	name: string?,
	label: string?,
	value: number?,
	color: Color3?,
	size: UDim2?,
	textSize: number?,
	labelSize: number?,
	alignX: Enum.TextXAlignment?,
	zIndex: number?,
	layoutOrder: number?,
	precise: boolean?,
})
	local container = Components.Container({
		parent = config.parent,
		name = config.name or "Readout",
		size = config.size or UDim2.new(0, 120, 0, 44),
		zIndex = config.zIndex,
	})
	container.LayoutOrder = config.layoutOrder or 0

	local labelText
	if config.label then
		labelText = Components.Label({
			parent = container,
			text = config.label,
			size = UDim2.new(1, 0, 0, config.labelSize or Theme.Text.caption),
			textSize = config.labelSize or Theme.Text.caption,
			alignX = config.alignX or Enum.TextXAlignment.Left,
			zIndex = container.ZIndex,
		})
	end

	local valueText = Components.Text({
		parent = container,
		name = "Value",
		text = "0",
		position = UDim2.new(0, 0, 0, config.label and (config.labelSize or Theme.Text.caption) + 2 or 0),
		size = UDim2.new(1, 0, 0, config.textSize or Theme.Text.heading),
		textSize = config.textSize or Theme.Text.heading,
		font = Theme.Font.heading,
		color = config.color or Theme.Color.textPrimary,
		alignX = config.alignX or Enum.TextXAlignment.Left,
		zIndex = container.ZIndex,
	})

	local controller = {
		Instance = container,
		ValueLabel = valueText,
		_current = config.value or 0,
		_target = config.value or 0,
		_precise = config.precise,
	}

	function controller:SetValue(value: number, immediate: boolean?)
		self._target = value
		if immediate then
			self._current = value
			valueText.Text = Theme.FormatNumber(value, self._precise)
		end
	end

	--[[ Advances the count-up. Called from the client render loop. ]]
	function controller:Update(deltaTime: number)
		if math.abs(self._current - self._target) < 0.5 then
			if self._current ~= self._target then
				self._current = self._target
				valueText.Text = Theme.FormatNumber(self._current, self._precise)
			end
			return
		end
		-- Framerate-independent approach, fast enough to feel responsive and slow
		-- enough to be legible.
		self._current = MathUtil.Damp(self._current, self._target, 9, deltaTime)
		valueText.Text = Theme.FormatNumber(self._current, self._precise)
	end

	function controller:SetColor(color: Color3)
		valueText.TextColor3 = color
	end

	function controller:Destroy()
		container:Destroy()
	end

	return container, controller
end

-- ============================================================================
-- Icon and badge
-- ============================================================================

function Components.Icon(config: {
	parent: Instance?,
	name: string?,
	image: string?,
	size: UDim2?,
	position: UDim2?,
	anchorPoint: Vector2?,
	color: Color3?,
	zIndex: number?,
	layoutOrder: number?,
}): ImageLabel
	local icon = Instance.new("ImageLabel")
	icon.Name = config.name or "Icon"
	icon.Image = Theme.GetIcon(config.image)
	icon.Size = config.size or UDim2.fromOffset(24, 24)
	icon.Position = config.position or UDim2.fromScale(0, 0)
	icon.AnchorPoint = config.anchorPoint or Vector2.zero
	icon.BackgroundTransparency = 1
	icon.ImageColor3 = config.color or Theme.Color.textSecondary
	icon.ScaleType = Enum.ScaleType.Fit
	icon.ZIndex = config.zIndex or Theme.ZIndex.hud
	icon.LayoutOrder = config.layoutOrder or 0
	icon.Parent = config.parent
	return icon
end

--[[ A small pill used for rarity, counts and status. ]]
function Components.Badge(config: {
	parent: Instance?,
	name: string?,
	text: string,
	color: Color3?,
	textColor: Color3?,
	size: UDim2?,
	position: UDim2?,
	anchorPoint: Vector2?,
	zIndex: number?,
	layoutOrder: number?,
}): Frame
	local badge = Instance.new("Frame")
	badge.Name = config.name or "Badge"
	badge.Size = config.size or UDim2.new(0, 0, 0, 20)
	badge.AutomaticSize = Enum.AutomaticSize.X
	badge.Position = config.position or UDim2.fromScale(0, 0)
	badge.AnchorPoint = config.anchorPoint or Vector2.zero
	badge.BackgroundColor3 = config.color or Theme.Color.elevated
	badge.BorderSizePixel = 0
	badge.ZIndex = config.zIndex or Theme.ZIndex.hud
	badge.LayoutOrder = config.layoutOrder or 0
	badge.Parent = config.parent

	Components.Corner(badge, Theme.Radius.sm)
	Components.Padding(badge, Theme.Space.xs, { left = Theme.Space.sm, right = Theme.Space.sm })

	Components.Text({
		parent = badge,
		text = config.text,
		size = UDim2.new(0, 0, 1, 0),
		autoSize = Enum.AutomaticSize.X,
		textSize = Theme.Text.caption,
		font = Theme.Font.medium,
		color = config.textColor or Theme.Color.textPrimary,
		zIndex = badge.ZIndex + 1,
	})

	return badge
end

--[[ A rarity-coloured badge, since it is the most common badge in the game. ]]
function Components.RarityBadge(parent: Instance, rarityId: string, zIndex: number?): Frame
	local rarity = Theme.GetRarity(rarityId)
	return Components.Badge({
		parent = parent,
		text = rarity.label,
		color = rarity.color:Lerp(Theme.Color.base, 0.72),
		textColor = rarity.color,
		zIndex = zIndex,
	})
end

-- ============================================================================
-- Divider and spacer
-- ============================================================================

function Components.Divider(parent: Instance, layoutOrder: number?): Frame
	local divider = Instance.new("Frame")
	divider.Name = "Divider"
	divider.Size = UDim2.new(1, 0, 0, 1)
	divider.BackgroundColor3 = Theme.Color.border
	divider.BorderSizePixel = 0
	divider.LayoutOrder = layoutOrder or 0
	divider.Parent = parent
	return divider
end

function Components.Spacer(parent: Instance, height: number, layoutOrder: number?): Frame
	local spacer = Instance.new("Frame")
	spacer.Name = "Spacer"
	spacer.Size = UDim2.new(1, 0, 0, height)
	spacer.BackgroundTransparency = 1
	spacer.LayoutOrder = layoutOrder or 0
	spacer.Parent = parent
	return spacer
end

-- ============================================================================
-- Scrolling
-- ============================================================================

function Components.Scroll(config: {
	parent: Instance?,
	name: string?,
	size: UDim2?,
	position: UDim2?,
	anchorPoint: Vector2?,
	gap: number?,
	padding: number?,
	zIndex: number?,
	horizontal: boolean?,
}): ScrollingFrame
	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = config.name or "Scroll"
	scroll.Size = config.size or UDim2.fromScale(1, 1)
	scroll.Position = config.position or UDim2.fromScale(0, 0)
	scroll.AnchorPoint = config.anchorPoint or Vector2.zero
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = 4
	scroll.ScrollBarImageColor3 = Theme.Color.borderStrong
	scroll.ScrollBarImageTransparency = 0.3
	scroll.CanvasSize = UDim2.new()
	scroll.AutomaticCanvasSize = config.horizontal and Enum.AutomaticSize.X or Enum.AutomaticSize.Y
	scroll.ScrollingDirection = config.horizontal and Enum.ScrollingDirection.X or Enum.ScrollingDirection.Y
	scroll.ElasticBehavior = Enum.ElasticBehavior.WhenScrollable
	scroll.ZIndex = config.zIndex or Theme.ZIndex.panel
	scroll.Parent = config.parent

	Components.List(scroll, {
		direction = config.horizontal and Enum.FillDirection.Horizontal or Enum.FillDirection.Vertical,
		gap = config.gap,
	})

	if config.padding then
		Components.Padding(scroll, config.padding)
	end

	return scroll
end

-- ============================================================================
-- Animation helpers
-- ============================================================================

--[[ Fades an element in from transparent, optionally sliding it. ]]
function Components.FadeIn(instance: GuiObject, config: {
	duration: string?,
	slide: Vector2?,
	delay: number?,
}?)
	local settings = config or {}
	local targetPosition = instance.Position

	if settings.slide then
		instance.Position = targetPosition + UDim2.fromOffset(settings.slide.X, settings.slide.Y)
	end

	local wasTransparent = instance.BackgroundTransparency
	instance.BackgroundTransparency = 1

	local tween = TweenService:Create(instance, Theme.Tween(settings.duration or "normal", "standard", settings.delay), {
		BackgroundTransparency = wasTransparent,
		Position = targetPosition,
	})
	tween:Play()

	-- Text and image children fade with their parent, which is what makes a panel
	-- appear as one object rather than a background that arrives before its content.
	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("TextLabel") or descendant:IsA("TextButton") then
			local target = descendant.TextTransparency
			descendant.TextTransparency = 1
			TweenService:Create(descendant, Theme.Tween(settings.duration or "normal", "standard", settings.delay), {
				TextTransparency = target,
			}):Play()
		elseif descendant:IsA("ImageLabel") or descendant:IsA("ImageButton") then
			local target = descendant.ImageTransparency
			descendant.ImageTransparency = 1
			TweenService:Create(descendant, Theme.Tween(settings.duration or "normal", "standard", settings.delay), {
				ImageTransparency = target,
			}):Play()
		end
	end

	return tween
end

--[[ A brief scale pulse, used to draw the eye to a value that just changed. ]]
function Components.Pulse(instance: GuiObject, scale: number?, duration: string?)
	local originalSize = instance.Size
	local factor = scale or 1.08

	local expanded = UDim2.new(
		originalSize.X.Scale * factor,
		originalSize.X.Offset * factor,
		originalSize.Y.Scale * factor,
		originalSize.Y.Offset * factor
	)

	local up = TweenService:Create(instance, Theme.Tween(duration or "fast"), { Size = expanded })
	up:Play()
	up.Completed:Once(function()
		TweenService:Create(instance, Theme.Tween(duration or "fast"), { Size = originalSize }):Play()
	end)
end

--[[ A horizontal shake, for rejection and damage. ]]
function Components.Shake(instance: GuiObject, magnitude: number?, cycles: number?)
	local originalPosition = instance.Position
	local amplitude = magnitude or 6
	local count = cycles or 4

	task.spawn(function()
		for index = 1, count do
			local direction = index % 2 == 0 and 1 or -1
			local falloff = 1 - (index / count)
			local tween = TweenService:Create(instance, TweenInfo.new(0.04), {
				Position = originalPosition + UDim2.fromOffset(amplitude * direction * falloff, 0),
			})
			tween:Play()
			tween.Completed:Wait()
		end
		TweenService:Create(instance, Theme.Tween("fast"), { Position = originalPosition }):Play()
	end)
end

return Components
