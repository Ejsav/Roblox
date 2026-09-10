--!strict
--[[
	AdminController
	---------------
	The developer console.

	A text box and a scrollback, opened with F2. Deliberately plain: this is a tool
	for the person building the game, and every minute spent styling it is a minute
	not spent on the game itself.

	It does no authorisation of its own, and must not be read as doing any. Anyone
	can open this panel and type into it; the server refuses every command from a
	player who is not staff and logs the attempt. Hiding the console behind a client
	check would only mean an attacker uses a modified client instead, and would
	tempt someone into believing the client-side check was the protection.

	Because of that, the console does not appear unless the server has already
	answered at least one command, which keeps it out of an ordinary player's way
	without pretending to be a security boundary.
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BTS")
local Theme = require(Shared.Config.Theme)
local Net = require(Shared.Net)
local Maid = require(Shared.Core.Maid)

local Client = script.Parent.Parent
local Components = require(Client.UI.Components)

local AdminController = {}
AdminController.Name = "AdminController"
AdminController.Dependencies = { "InputController" }
AdminController.Priority = 95

local LocalPlayer = Players.LocalPlayer

local MAX_LINES = 60
local HISTORY_LIMIT = 30

function AdminController:Init()
	self._maid = Maid.new()
	self._open = false
	self._lines = {}
	self._history = {}
	self._historyIndex = 0

	local playerGui = LocalPlayer:WaitForChild("PlayerGui")

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "BTS_Console"
	screenGui.ResetOnSpawn = false
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.DisplayOrder = Theme.ZIndex.notification + 20
	screenGui.Enabled = false
	screenGui.Parent = playerGui
	self._maid:Add(screenGui)
	self._gui = screenGui

	self:_build()
end

function AdminController:Start()
	self._maid:Add(UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		if input.KeyCode == Enum.KeyCode.F2 then
			self:Toggle()
		elseif input.KeyCode == Enum.KeyCode.Escape and self._open then
			self:Close()
		end
	end))

	-- The server answers through the ordinary notification channel, so anything it
	-- says about a command lands in the console as well as on screen.
	self._maid:Add(Net.OnClientEvent("Notification", function(payload)
		if payload.title == "Command" or payload.title == "Command failed" then
			self:_print(payload.body or "", payload.title == "Command failed")
		end
	end))
end

function AdminController:_build()
	local panel = Components.Panel({
		parent = self._gui,
		name = "Console",
		size = UDim2.new(0.7, 0, 0.5, 0),
		position = UDim2.new(0.5, 0, 0, Theme.Space.xl),
		anchorPoint = Vector2.new(0.5, 0),
		elevation = 3,
		padding = Theme.Space.md,
		zIndex = Theme.ZIndex.notification + 20,
	})
	self._panel = panel

	Components.Text({
		parent = panel,
		name = "Title",
		text = "DEVELOPER CONSOLE  ·  type 'help'",
		size = UDim2.new(1, 0, 0, 16),
		textSize = Theme.Text.caption,
		font = Theme.Font.medium,
		color = Theme.Color.textTertiary,
		zIndex = panel.ZIndex + 1,
	})

	self._output = Components.Scroll({
		parent = panel,
		name = "Output",
		size = UDim2.new(1, 0, 1, -60),
		position = UDim2.fromOffset(0, 22),
		gap = 1,
		zIndex = panel.ZIndex + 1,
	})

	local box = Instance.new("TextBox")
	box.Name = "Input"
	box.Size = UDim2.new(1, 0, 0, 30)
	box.Position = UDim2.new(0, 0, 1, -30)
	box.BackgroundColor3 = Theme.Color.base
	box.BorderSizePixel = 0
	box.ClearTextOnFocus = false
	box.Font = Theme.Font.body
	box.TextSize = Theme.Text.body
	box.TextColor3 = Theme.Color.textPrimary
	box.PlaceholderText = "command…"
	box.PlaceholderColor3 = Theme.Color.textDisabled
	box.TextXAlignment = Enum.TextXAlignment.Left
	box.Text = ""
	box.ZIndex = panel.ZIndex + 2
	box.Parent = panel
	Components.Corner(box, Theme.Radius.sm)
	Components.Padding(box, Theme.Space.sm)
	self._input = box

	self._maid:Add(box.FocusLost:Connect(function(enterPressed)
		if enterPressed then
			self:Submit(box.Text)
			box.Text = ""
			-- Refocused so a sequence of commands does not need a click between each.
			task.defer(function()
				if self._open then
					box:CaptureFocus()
				end
			end)
		end
	end))
end

-- ============================================================================
-- Console
-- ============================================================================

function AdminController:Toggle()
	if self._open then
		self:Close()
	else
		self:Open()
	end
end

function AdminController:Open()
	self._open = true
	self._gui.Enabled = true
	self._input:CaptureFocus()

	if #self._lines == 0 then
		self:_print("Type 'help' for the command list. Commands are authorised on the server.", false)
	end
end

function AdminController:Close()
	self._open = false
	self._gui.Enabled = false
	self._input:ReleaseFocus()
end

--[[
	Splits a command line into a name and its arguments.

	Quoted arguments are supported because a player's display name can contain a
	space, and `profile "Some Name"` should reach the server as one argument rather
	than two.
]]
function AdminController.Parse(line: string): (string?, { string })
	local tokens = {}
	local current = {}
	local inQuotes = false

	for index = 1, #line do
		local character = string.sub(line, index, index)

		if character == '"' then
			inQuotes = not inQuotes
		elseif character == " " and not inQuotes then
			if #current > 0 then
				table.insert(tokens, table.concat(current))
				current = {}
			end
		else
			table.insert(current, character)
		end
	end

	if #current > 0 then
		table.insert(tokens, table.concat(current))
	end

	if #tokens == 0 then
		return nil, {}
	end

	local command = table.remove(tokens, 1)
	return command, tokens
end

function AdminController:Submit(line: string): boolean
	line = (line or ""):match("^%s*(.-)%s*$") or ""
	if line == "" then
		return false
	end

	table.insert(self._history, line)
	while #self._history > HISTORY_LIMIT do
		table.remove(self._history, 1)
	end
	self._historyIndex = #self._history + 1

	local command, args = AdminController.Parse(line)
	if not command then
		return false
	end

	self:_print("> " .. line, false)

	-- Clamped to the remote's declared limits, so a long paste is refused here with
	-- an explanation rather than at the gateway with silence.
	if #args > 10 then
		self:_print("Too many arguments (maximum 10).", true)
		return false
	end
	for _, argument in ipairs(args) do
		if #argument > 120 then
			self:_print("An argument is too long (maximum 120 characters).", true)
			return false
		end
	end

	Net.FireServer("AdminCommand", string.sub(command, 1, 40), args)
	return true
end

function AdminController:_print(text: string, isError: boolean)
	-- Server replies arrive as one string with embedded newlines; each becomes its
	-- own row so the scrollback stays scannable.
	for _, chunk in ipairs(string.split(text, "\n")) do
		local label = Components.Text({
			parent = self._output,
			name = "Line" .. tostring(#self._lines + 1),
			text = chunk,
			size = UDim2.new(1, -8, 0, 15),
			textSize = Theme.Text.caption,
			color = isError and Theme.Color.danger or Theme.Color.textSecondary,
			zIndex = self._output.ZIndex + 1,
		})
		label.LayoutOrder = #self._lines + 1
		table.insert(self._lines, label)
	end

	while #self._lines > MAX_LINES do
		local oldest = table.remove(self._lines, 1)
		if oldest then
			oldest:Destroy()
		end
	end
end

function AdminController:GetHistory(): { string }
	return self._history
end

function AdminController:Destroy()
	self._maid:DoCleaning()
end

return AdminController
