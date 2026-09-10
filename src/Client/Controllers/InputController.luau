--!strict
--[[
	InputController
	---------------
	Input abstraction across keyboard, gamepad and touch.

	Everything in the game binds to an *action*, never to a key. That indirection is
	what makes the same controller code serve three input methods, lets bindings be
	remapped later without touching gameplay, and means a touch button and a keypress
	are genuinely the same event rather than two parallel paths that drift apart.

	The controller also tracks which input method was last used, so the HUD can show
	the correct prompt glyph without asking.
]]

local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BTS")
local Signal = require(Shared.Core.Signal)
local Maid = require(Shared.Core.Maid)

local InputController = {}
InputController.Name = "InputController"
InputController.Priority = 1

export type InputMethod = "keyboard" | "gamepad" | "touch"

--[[
	Action bindings. Each action lists its key on every input method plus a short
	label the HUD uses for prompts.
]]
local ACTIONS = {
	capture = {
		label = "Capture",
		keyboard = Enum.KeyCode.E,
		gamepad = Enum.KeyCode.ButtonX,
		mouse = Enum.UserInputType.MouseButton1,
		touchButton = true,
		touchPriority = 1,
	},
	sprint = {
		label = "Sprint",
		keyboard = Enum.KeyCode.LeftShift,
		gamepad = Enum.KeyCode.ButtonL3,
		hold = true,
		touchButton = true,
		touchPriority = 2,
	},
	slide = {
		label = "Slide",
		keyboard = Enum.KeyCode.C,
		gamepad = Enum.KeyCode.ButtonB,
		touchButton = true,
		touchPriority = 3,
	},
	bank = {
		label = "Bank",
		keyboard = Enum.KeyCode.F,
		gamepad = Enum.KeyCode.ButtonY,
		touchButton = true,
		touchPriority = 4,
	},
	interact = {
		label = "Interact",
		keyboard = Enum.KeyCode.E,
		gamepad = Enum.KeyCode.ButtonA,
		touchButton = true,
		touchPriority = 5,
	},
	ability1 = {
		label = "Ability 1",
		keyboard = Enum.KeyCode.One,
		gamepad = Enum.KeyCode.ButtonR1,
		touchButton = true,
		touchPriority = 6,
	},
	ability2 = {
		label = "Ability 2",
		keyboard = Enum.KeyCode.Two,
		gamepad = Enum.KeyCode.ButtonL1,
		touchButton = true,
		touchPriority = 7,
	},
	ability3 = {
		label = "Ability 3",
		keyboard = Enum.KeyCode.Three,
		gamepad = Enum.KeyCode.ButtonR2,
		touchButton = true,
		touchPriority = 8,
	},
	ability4 = {
		label = "Ability 4",
		keyboard = Enum.KeyCode.Four,
		gamepad = Enum.KeyCode.ButtonL2,
		touchButton = true,
		touchPriority = 9,
	},
	dash = {
		label = "Dash",
		keyboard = Enum.KeyCode.Q,
		gamepad = Enum.KeyCode.ButtonR3,
		touchButton = true,
		touchPriority = 10,
	},
	grapple = {
		label = "Grapple",
		keyboard = Enum.KeyCode.R,
		gamepad = Enum.KeyCode.ButtonR2,
		touchButton = true,
		touchPriority = 11,
	},
	purge = {
		label = "Purge",
		keyboard = Enum.KeyCode.X,
		gamepad = Enum.KeyCode.ButtonL3,
		touchButton = true,
		touchPriority = 12,
	},
	map = {
		label = "Map",
		keyboard = Enum.KeyCode.M,
		gamepad = Enum.KeyCode.ButtonSelect,
	},
	inventory = {
		label = "Inventory",
		keyboard = Enum.KeyCode.Tab,
		gamepad = Enum.KeyCode.DPadUp,
	},
	skills = {
		label = "Skills",
		keyboard = Enum.KeyCode.K,
		gamepad = Enum.KeyCode.DPadLeft,
	},
	quests = {
		label = "Quests",
		keyboard = Enum.KeyCode.J,
		gamepad = Enum.KeyCode.DPadRight,
	},
	upgrades = {
		label = "Upgrades",
		keyboard = Enum.KeyCode.U,
		gamepad = Enum.KeyCode.DPadDown,
	},
	codex = {
		label = "Codex",
		keyboard = Enum.KeyCode.L,
		-- No gamepad binding: the four d-pad directions are spent, and the codex is
		-- the one menu nobody needs to reach in a hurry. It is on the tab bar.
	},
	closeMenu = {
		label = "Close",
		keyboard = Enum.KeyCode.Escape,
		gamepad = Enum.KeyCode.ButtonB,
	},
}

InputController.Actions = ACTIONS

function InputController:Init()
	self._maid = Maid.new()
	self._held = {} :: { [string]: boolean }
	self._method = "keyboard" :: InputMethod
	self._menuOpen = false

	self.ActionBegan = Signal.new("Input.ActionBegan")
	self.ActionEnded = Signal.new("Input.ActionEnded")
	self.MethodChanged = Signal.new("Input.MethodChanged")

	-- Detect the starting method from what the device actually has.
	if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		self._method = "touch"
	elseif UserInputService.GamepadEnabled and not UserInputService.KeyboardEnabled then
		self._method = "gamepad"
	end
end

function InputController:Start()
	self:_bindAll()

	self._maid:Add(UserInputService.LastInputTypeChanged:Connect(function(inputType)
		self:_onInputTypeChanged(inputType)
	end))

	-- Roblox's own menu opening must not leave an action stuck held.
	self._maid:Add(GuiService.MenuOpened:Connect(function()
		self:_releaseAll()
	end))
end

-- ============================================================================
-- Binding
-- ============================================================================

function InputController:_bindAll()
	for actionId, definition in pairs(ACTIONS) do
		local keys = {}
		if definition.keyboard then
			table.insert(keys, definition.keyboard)
		end
		if definition.gamepad then
			table.insert(keys, definition.gamepad)
		end
		if definition.mouse then
			table.insert(keys, definition.mouse)
		end

		if #keys == 0 then
			continue
		end

		ContextActionService:BindActionAtPriority(
			"BTS_" .. actionId,
			function(_, state, input)
				return self:_handleAction(actionId, state, input)
			end,
			false,
			Enum.ContextActionPriority.Default.Value,
			table.unpack(keys)
		)
	end
end

function InputController:_handleAction(actionId: string, state: Enum.UserInputState, input: InputObject)
	local definition = ACTIONS[actionId]

	-- Menu actions still work while a menu is open; gameplay actions do not.
	local isMenuAction = actionId == "closeMenu"
		or actionId == "map"
		or actionId == "inventory"
		or actionId == "skills"
		or actionId == "quests"
		or actionId == "codex"
		or actionId == "upgrades"

	if self._menuOpen and not isMenuAction then
		return Enum.ContextActionResult.Pass
	end

	if state == Enum.UserInputState.Begin then
		self._held[actionId] = true
		self.ActionBegan:Fire(actionId, input)
	elseif state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
		if self._held[actionId] then
			self._held[actionId] = false
			self.ActionEnded:Fire(actionId, input)
		end
	end

	return Enum.ContextActionResult.Sink
end

--[[ Fires an action from a touch button or any other synthetic source. ]]
function InputController:FireAction(actionId: string, began: boolean)
	if began then
		if self._held[actionId] then
			return
		end
		self._held[actionId] = true
		self.ActionBegan:Fire(actionId, nil)
	else
		if not self._held[actionId] then
			return
		end
		self._held[actionId] = false
		self.ActionEnded:Fire(actionId, nil)
	end
end

function InputController:IsHeld(actionId: string): boolean
	return self._held[actionId] == true
end

function InputController:_releaseAll()
	for actionId, held in pairs(self._held) do
		if held then
			self._held[actionId] = false
			self.ActionEnded:Fire(actionId, nil)
		end
	end
end

-- ============================================================================
-- Method detection
-- ============================================================================

function InputController:_onInputTypeChanged(inputType: Enum.UserInputType)
	local method: InputMethod = self._method

	if inputType == Enum.UserInputType.Touch then
		method = "touch"
	elseif inputType.Name:match("^Gamepad") then
		method = "gamepad"
	elseif inputType == Enum.UserInputType.Keyboard
		or inputType == Enum.UserInputType.MouseButton1
		or inputType == Enum.UserInputType.MouseButton2
		or inputType == Enum.UserInputType.MouseMovement
	then
		method = "keyboard"
	end

	if method ~= self._method then
		self._method = method
		self.MethodChanged:Fire(method)
	end
end

function InputController:GetMethod(): InputMethod
	return self._method
end

function InputController:IsTouch(): boolean
	return self._method == "touch"
end

function InputController:IsGamepad(): boolean
	return self._method == "gamepad"
end

--[[
	The prompt string for an action on the current input method: "E", "X", or the
	action's label on touch where there is no glyph to show.
]]
function InputController:GetPrompt(actionId: string): string
	local definition = ACTIONS[actionId]
	if not definition then
		return ""
	end

	if self._method == "gamepad" and definition.gamepad then
		-- Trim the "Button" prefix so the HUD reads "X" rather than "ButtonX".
		return (definition.gamepad.Name:gsub("^Button", ""):gsub("^DPad", ""))
	elseif self._method == "touch" then
		return definition.label
	elseif definition.keyboard then
		return definition.keyboard.Name
	end

	return definition.label
end

--[[ Called by the menu controller so gameplay input is suppressed while in menus. ]]
function InputController:SetMenuOpen(open: boolean)
	if self._menuOpen == open then
		return
	end
	self._menuOpen = open
	if open then
		self:_releaseAll()
	end
end

function InputController:IsMenuOpen(): boolean
	return self._menuOpen
end

function InputController:Destroy()
	for actionId in pairs(ACTIONS) do
		ContextActionService:UnbindAction("BTS_" .. actionId)
	end
	self._maid:DoCleaning()
end

return InputController
