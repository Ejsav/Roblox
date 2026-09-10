--!strict
--[[
	SettingsScreen
	--------------
	Every setting the game persists, and nothing it does not.

	Built from a declarative table rather than hand-laid rows, because the settings
	list is exactly the kind of thing that grows one option at a time and rots when
	each addition means touching layout code. A new setting is one entry here and a
	matching field in the remote's schema.

	Changes apply locally the instant they are made and are sent to the server to be
	persisted. That order matters: a settings toggle that waits for a round trip
	before the volume changes feels broken, and the server is the store of record,
	not the authority on what the player prefers.

	Accessibility settings are not in a submenu. Reduced motion, colourblind modes
	and subtitles are settings some players cannot play without, and burying them a
	level down treats them as an afterthought.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BTS")
local Theme = require(Shared.Config.Theme)
local Net = require(Shared.Net)
local Maid = require(Shared.Core.Maid)

local Client = script.Parent.Parent.Parent
local Components = require(Client.UI.Components)

local SettingsScreen = {}
SettingsScreen.__index = SettingsScreen

--[[
	kind:
		toggle   a boolean
		choice   one of a fixed set
		slider   a number in [min, max], stepped
]]
local SECTIONS = {
	{
		id = "display",
		name = "Display",
		settings = {
			{
				key = "quality",
				kind = "choice",
				name = "Graphics quality",
				description = "Auto follows your framerate and is what almost everyone should use.",
				options = { "auto", "low", "medium", "high", "ultra" },
			},
			{
				key = "hudScale",
				kind = "slider",
				name = "HUD scale",
				description = "Size of the on-screen readouts.",
				min = 0.6,
				max = 1.6,
				step = 0.1,
			},
			{
				key = "showDamageNumbers",
				kind = "toggle",
				name = "Damage numbers",
				description = "Show numbers when you take or deal damage.",
			},
			{
				key = "showOtherPlayers",
				kind = "toggle",
				name = "Show other runners",
				description = "Turning this off helps on a slow device in a busy region.",
			},
		},
	},
	{
		id = "audio",
		name = "Audio",
		settings = {
			{ key = "musicVolume", kind = "slider", name = "Music", min = 0, max = 1, step = 0.05 },
			{ key = "sfxVolume", kind = "slider", name = "Effects", min = 0, max = 1, step = 0.05 },
		},
	},
	{
		id = "controls",
		name = "Controls",
		settings = {
			{
				key = "holdToSprint",
				kind = "toggle",
				name = "Hold to sprint",
				description = "Off makes sprint a toggle instead.",
			},
			{
				key = "captureAssist",
				kind = "toggle",
				name = "Capture assist",
				description = "Widens the capture window slightly. Costs a little yield.",
			},
		},
	},
	{
		id = "accessibility",
		name = "Accessibility",
		settings = {
			{
				key = "reducedMotion",
				kind = "toggle",
				name = "Reduced motion",
				description = "Removes screen shake, camera kick and most animation flourishes.",
			},
			{
				key = "screenShake",
				kind = "slider",
				name = "Screen shake",
				description = "Independent of reduced motion, so shake can be dialled down without losing everything else.",
				min = 0,
				max = 1,
				step = 0.1,
			},
			{
				key = "colourblindMode",
				kind = "choice",
				name = "Colourblind mode",
				description = "Adjusts the rarity and danger palettes.",
				options = { "off", "protanopia", "deuteranopia", "tritanopia" },
			},
			{
				key = "subtitles",
				kind = "toggle",
				name = "Subtitles",
				description = "Captions for spoken and environmental audio cues.",
			},
		},
	},
}

local CHOICE_LABELS = {
	auto = "Auto",
	low = "Low",
	medium = "Medium",
	high = "High",
	ultra = "Ultra",
	off = "Off",
	protanopia = "Protanopia",
	deuteranopia = "Deuteranopia",
	tritanopia = "Tritanopia",
}

local function labelFor(value: any): string
	return CHOICE_LABELS[tostring(value)] or tostring(value)
end

function SettingsScreen.new(parent: Instance, controllers: any)
	local self = setmetatable({
		_maid = Maid.new(),
		_controllers = controllers,
		_settings = {},
		_widgets = {},
		_pending = nil,
	}, SettingsScreen)

	self:_build(parent)
	return self
end

function SettingsScreen:_build(parent: Instance)
	local root = Components.Panel({
		parent = parent,
		name = "SettingsScreen",
		size = UDim2.fromScale(1, 1),
		elevation = 0,
		radius = 0,
		zIndex = Theme.ZIndex.panel,
	})
	self._root = root
	self._maid:Add(root)

	local header = Components.Container({
		parent = root,
		name = "Header",
		size = UDim2.new(1, 0, 0, 56),
		zIndex = root.ZIndex + 1,
	})
	Components.Padding(header, Theme.Space.lg)

	Components.Heading({
		parent = header,
		text = "SETTINGS",
		size = UDim2.new(0, 240, 1, 0),
		textSize = Theme.Text.title,
		zIndex = header.ZIndex + 1,
	})

	self._savedLabel = Components.Text({
		parent = header,
		name = "Saved",
		text = "",
		size = UDim2.new(0, 240, 1, 0),
		position = UDim2.new(1, -240, 0, 0),
		textSize = Theme.Text.caption,
		color = Theme.Color.success,
		alignX = Enum.TextXAlignment.Right,
		zIndex = header.ZIndex + 1,
	})

	self._list = Components.Scroll({
		parent = root,
		name = "List",
		size = UDim2.new(1, -Theme.Space.xl, 1, -76),
		position = UDim2.fromOffset(Theme.Space.lg, 64),
		gap = Theme.Space.xs,
		zIndex = root.ZIndex + 1,
	})

	self:_buildRows()
end

function SettingsScreen:_buildRows()
	local order = 0

	for _, section in ipairs(SECTIONS) do
		order += 1
		local heading = Components.Text({
			parent = self._list,
			name = section.id,
			text = string.upper(section.name),
			size = UDim2.new(1, -8, 0, 24),
			textSize = Theme.Text.caption,
			font = Theme.Font.medium,
			color = Theme.Color.textTertiary,
			alignY = Enum.TextYAlignment.Bottom,
			zIndex = self._list.ZIndex + 1,
		})
		heading.LayoutOrder = order

		for _, setting in ipairs(section.settings) do
			order += 1
			self:_buildRow(setting, order)
		end
	end
end

function SettingsScreen:_buildRow(setting: any, order: number)
	local row = Components.Panel({
		parent = self._list,
		name = setting.key,
		size = UDim2.new(1, -8, 0, setting.description and 56 or 44),
		elevation = 1,
		padding = Theme.Space.sm,
		zIndex = self._list.ZIndex + 1,
	})
	row.LayoutOrder = order

	Components.Text({
		parent = row,
		name = "Name",
		text = setting.name,
		size = UDim2.new(1, -300, 0, 18),
		textSize = Theme.Text.body,
		zIndex = row.ZIndex + 1,
	})

	if setting.description then
		Components.Text({
			parent = row,
			name = "Description",
			text = setting.description,
			size = UDim2.new(1, -300, 0, 26),
			position = UDim2.fromOffset(0, 20),
			textSize = Theme.Text.caption,
			color = Theme.Color.textTertiary,
			wrapped = true,
			zIndex = row.ZIndex + 1,
		})
	end

	local widget
	if setting.kind == "toggle" then
		widget = self:_buildToggle(row, setting)
	elseif setting.kind == "choice" then
		widget = self:_buildChoice(row, setting)
	else
		widget = self:_buildSlider(row, setting)
	end

	self._widgets[setting.key] = widget
end

function SettingsScreen:_buildToggle(row: Frame, setting: any)
	local _, button = Components.Button({
		parent = row,
		name = "Toggle",
		text = "OFF",
		variant = "ghost",
		size = UDim2.fromOffset(120, 32),
		position = UDim2.new(1, 0, 0.5, 0),
		anchorPoint = Vector2.new(1, 0.5),
		textSize = Theme.Text.caption,
		zIndex = row.ZIndex + 2,
	})

	self._maid:Add(button.Pressed:Connect(function()
		self:Set(setting.key, not self:Get(setting.key))
	end))

	return {
		kind = "toggle",
		apply = function(value: any)
			button:SetText(value and "ON" or "OFF")
		end,
	}
end

function SettingsScreen:_buildChoice(row: Frame, setting: any)
	--[[
		A cycling button rather than a dropdown. There are at most five options, a
		dropdown needs focus management and a click-outside handler to close, and
		cycling works identically on a controller and a phone.
	]]
	local _, button = Components.Button({
		parent = row,
		name = "Choice",
		text = "",
		variant = "ghost",
		size = UDim2.fromOffset(200, 32),
		position = UDim2.new(1, 0, 0.5, 0),
		anchorPoint = Vector2.new(1, 0.5),
		textSize = Theme.Text.caption,
		zIndex = row.ZIndex + 2,
	})

	self._maid:Add(button.Pressed:Connect(function()
		local current = self:Get(setting.key)
		local index = 1
		for position, option in ipairs(setting.options) do
			if option == current then
				index = position
				break
			end
		end
		local nextOption = setting.options[(index % #setting.options) + 1]
		self:Set(setting.key, nextOption)
	end))

	return {
		kind = "choice",
		apply = function(value: any)
			button:SetText(string.upper(labelFor(value)))
		end,
	}
end

function SettingsScreen:_buildSlider(row: Frame, setting: any)
	--[[
		Stepped decrement/increment rather than a draggable track. A drag needs
		pointer capture and behaves badly on touch inside a scrolling list, and every
		slider here has fewer than twenty steps, so the buttons are not slower to use.
	]]
	local container = Components.Container({
		parent = row,
		name = "Slider",
		size = UDim2.fromOffset(220, 32),
		position = UDim2.new(1, 0, 0.5, 0),
		anchorPoint = Vector2.new(1, 0.5),
		zIndex = row.ZIndex + 2,
	})

	local _, down = Components.Button({
		parent = container,
		name = "Down",
		text = "−",
		variant = "ghost",
		size = UDim2.fromOffset(36, 32),
		textSize = Theme.Text.body,
		zIndex = container.ZIndex + 1,
	})

	local value = Components.Text({
		parent = container,
		name = "Value",
		text = "",
		size = UDim2.fromOffset(120, 32),
		position = UDim2.fromOffset(40, 0),
		textSize = Theme.Text.body,
		font = Theme.Font.heading,
		alignX = Enum.TextXAlignment.Center,
		zIndex = container.ZIndex + 1,
	})

	local _, up = Components.Button({
		parent = container,
		name = "Up",
		text = "+",
		variant = "ghost",
		size = UDim2.fromOffset(36, 32),
		position = UDim2.fromOffset(164, 0),
		textSize = Theme.Text.body,
		zIndex = container.ZIndex + 1,
	})

	local function nudge(direction: number)
		local current = tonumber(self:Get(setting.key)) or setting.min
		local stepped = math.clamp(current + direction * setting.step, setting.min, setting.max)
		-- Rounded to the step, or repeated nudges accumulate floating-point drift
		-- and the display starts showing 0.7000000000000001.
		stepped = math.floor(stepped / setting.step + 0.5) * setting.step
		self:Set(setting.key, stepped)
	end

	self._maid:Add(down.Pressed:Connect(function()
		nudge(-1)
	end))
	self._maid:Add(up.Pressed:Connect(function()
		nudge(1)
	end))

	local bar = select(2, Components.Bar({
		parent = row,
		name = "Fill",
		size = UDim2.fromOffset(220, 3),
		position = UDim2.new(1, -220, 1, -4),
		color = Theme.Color.accent,
		zIndex = row.ZIndex + 1,
	}))

	return {
		kind = "slider",
		apply = function(current: any)
			local number = tonumber(current) or setting.min
			-- Percentages read better than decimals for volumes and shake.
			value.Text = (setting.max <= 1)
				and ("%d%%"):format(math.floor(number * 100 + 0.5))
				or ("%.1f"):format(number)
			bar:SetValue((number - setting.min) / math.max(0.0001, setting.max - setting.min), true)
		end,
	}
end

-- ============================================================================
-- State
-- ============================================================================

function SettingsScreen:SetProfile(profile: any)
	if profile and profile.settings then
		self._settings = profile.settings
		self:Refresh()
		-- Applied on arrival, not only on change. Nothing else was applying stored
		-- settings at all, so a returning player's choices had no effect until they
		-- opened this screen and touched something.
		self:ApplyAll()
	end
end

function SettingsScreen:Get(key: string): any
	return self._settings[key]
end

--[[
	Applies a change locally, then persists it.

	Sends are coalesced: turning a volume down ten steps is one write, not ten. The
	remote's budget is generous but a slider is exactly the control that would spend
	it, and the server only cares about where the value landed.
]]
function SettingsScreen:Set(key: string, value: any)
	self._settings[key] = value

	local widget = self._widgets[key]
	if widget then
		widget.apply(value)
	end

	self:ApplyAll()

	self._pending = self._pending or {}
	self._pending[key] = value

	if not self._flushScheduled then
		self._flushScheduled = true
		task.delay(0.4, function()
			self._flushScheduled = false
			self:_flush()
		end)
	end
end

function SettingsScreen:_flush()
	local pending = self._pending
	self._pending = nil

	if not pending or next(pending) == nil then
		return
	end

	Net.FireServer("RequestUpdateSettings", pending)

	self._savedLabel.Text = "Saved"
	task.delay(1.5, function()
		if self._savedLabel then
			self._savedLabel.Text = ""
		end
	end)
end

--[[
	Hands the whole settings table to every controller that declares an applier.

	Fanning out rather than routing each key to a known owner: a controller knows
	which settings are its own, and a table here mapping key to controller would be
	a second place to update every time either side changes.
]]
function SettingsScreen:ApplyAll()
	for _, controller in pairs(self._controllers or {}) do
		if type(controller) == "table" and type((controller :: any).ApplySettings) == "function" then
			local ok, err = pcall(controller.ApplySettings, controller, self._settings)
			if not ok then
				warn(("[Settings] %s:ApplySettings failed: %s"):format(
					tostring((controller :: any).Name or "?"), tostring(err)))
			end
		end
	end
end

function SettingsScreen:Refresh()
	for key, widget in pairs(self._widgets) do
		widget.apply(self._settings[key])
	end
end

function SettingsScreen:SetVisible(visible: boolean)
	self._root.Visible = visible
	if visible then
		self:Refresh()
		Components.FadeIn(self._root, { duration = "fast" })
	else
		-- Leaving flushes immediately rather than waiting out the coalescing delay,
		-- so a change made and then a quick disconnect still persists.
		self:_flush()
	end
end

function SettingsScreen:Destroy()
	self:_flush()
	self._maid:DoCleaning()
end

return SettingsScreen
