--!strict
--[[
	TutorialController
	------------------
	Teaching, without a tutorial.

	The design constraint is explicit: within the first minute a player must
	understand storm → get near → time it → take it → carry → bank → get stronger,
	and they must learn it by doing rather than by reading. So this controller never
	blocks input, never opens a modal, and never shows more than one hint at a time.

	Each hint is bound to a moment the player is already in — their first telegraph,
	their first full cell, their first sight of a bank — and disappears the instant
	they act on it. A hint the player has satisfied is never shown again, tracked on
	their profile so it survives a rejoin.
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BTS")
local Theme = require(Shared.Config.Theme)
local Net = require(Shared.Net)
local Maid = require(Shared.Core.Maid)
local Balance = require(Shared.Config.Balance)

local Client = script.Parent.Parent
local Components = require(Client.UI.Components)

local TutorialController = {}
TutorialController.Name = "TutorialController"
TutorialController.Dependencies = { "InputController", "StormController", "InteractionController" }
TutorialController.Priority = 45

local LocalPlayer = Players.LocalPlayer

--[[
	The hint set, in the order a player naturally meets them.

	`trigger` returns true when the hint is relevant right now. `satisfied` returns
	true once the player has demonstrably learned it — at which point the hint
	retires permanently.
]]
local HINTS = {
	{
		id = "move",
		title = "Move",
		body = "Get to the storm. Everything out here starts with distance.",
		priority = 1,
		minSeconds = 2,
	},
	{
		id = "capture",
		title = "Time the capture",
		bodyFormat = "Press %s when the ring closes on the centre.",
		priority = 5,
		requiresTarget = true,
	},
	{
		id = "capture_timing",
		title = "Closer to the centre pays more",
		body = "The ring turns blue at Perfect and gold at Overcharge.",
		priority = 4,
		afterHint = "capture",
	},
	{
		id = "carry",
		title = "That energy is not yours yet",
		body = "It destabilises while you carry it. Bank it before it vents.",
		priority = 6,
		requiresCarry = 1,
	},
	{
		id = "bank",
		title = "Find the light",
		bodyFormat = "Bank stations show a bright column. Stand on the pad and press %s.",
		priority = 7,
		requiresCarry = 1,
		afterHint = "carry",
	},
	{
		id = "instability",
		title = "Containment is climbing",
		body = "The fuller you are, the faster it rises. This is the decision.",
		priority = 9,
		requiresInstability = Balance.Carry.INSTABILITY_WARNING,
	},
	{
		id = "chain",
		title = "You have a chain going",
		body = "Every capture without banking raises your multiplier — and your risk.",
		priority = 6,
		requiresChain = 3,
	},
	{
		id = "upgrade",
		title = "Spend it",
		bodyFormat = "Press %s to upgrade. Every track leads to a new capability, not just a bigger number.",
		priority = 5,
		requiresWatts = 200,
	},
	{
		id = "sprint",
		title = "You can move faster",
		bodyFormat = "Hold %s to sprint. Distance is the real enemy out here.",
		priority = 2,
		minSeconds = 25,
	},
	{
		id = "map",
		title = "The world is larger than this",
		bodyFormat = "Press %s for the map. Everything you can see from the Overlook is reachable eventually.",
		priority = 3,
		minSeconds = 120,
	},
}

function TutorialController:Init()
	self._maid = Maid.new()
	self._shown = {}
	self._satisfied = {}
	self._current = nil
	self._joinedAt = os.clock()
	self._carry = { carried = 0, instability = 0, chain = 0 }
	self._watts = 0
	self._capturedOnce = false
	self._bankedOnce = false
	self._nextEvaluateAt = 0

	local playerGui = LocalPlayer:WaitForChild("PlayerGui")

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "BTS_Tutorial"
	screenGui.ResetOnSpawn = false
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.DisplayOrder = Theme.ZIndex.hudOverlay + 1
	screenGui.Parent = playerGui
	self._maid:Add(screenGui)

	self:_buildHintPanel(screenGui)
end

function TutorialController:Start()
	self._input = self.Registry:Get("InputController")
	self._storms = self.Registry:Get("StormController")
	self._interaction = self.Registry:Get("InteractionController")

	self._maid:Add(Net.OnClientEvent("ProfileSync", function(payload)
		self._watts = payload.profile.watts or 0

		-- Hints already satisfied in a previous session never return.
		local shown = payload.profile.onboarding and payload.profile.onboarding.tipsShown or {}
		for hintId, seen in pairs(shown) do
			if seen and not hintId:match("^funnel_") then
				self._satisfied[hintId] = true
			end
		end

		-- A returning player is past the basics regardless of what was recorded.
		if payload.profile.sessionCount and payload.profile.sessionCount > 2 then
			for _, hint in ipairs(HINTS) do
				if hint.priority <= 7 then
					self._satisfied[hint.id] = true
				end
			end
		end
	end))

	self._maid:Add(Net.OnClientEvent("CarryUpdate", function(snapshot)
		if snapshot.carried ~= nil then
			self._carry = snapshot
		end
	end))

	self._maid:Add(Net.OnClientEvent("BankResult", function(result)
		if result.success then
			self._bankedOnce = true
			self._watts += result.watts or 0
			self:_satisfy("bank")
			self:_satisfy("carry")
		end
	end))

	self._maid:Add(self._storms.CaptureFeedback:Connect(function(result)
		if result.predicted then
			return
		end
		if result.success then
			self._capturedOnce = true
			self:_satisfy("capture")
			if result.grade == "Perfect" or result.grade == "Overcharge" then
				self:_satisfy("capture_timing")
			end
		end
	end))

	self._maid:Add(self._input.ActionBegan:Connect(function(actionId)
		-- Using a control retires its hint immediately, which is the whole design:
		-- the hint exists only until the player has done the thing once.
		if actionId == "sprint" then
			self:_satisfy("sprint")
			self:_satisfy("move")
		elseif actionId == "map" then
			self:_satisfy("map")
		elseif actionId == "upgrades" then
			self:_satisfy("upgrade")
		end
	end))
end

function TutorialController:_buildHintPanel(screenGui: ScreenGui)
	local container = Components.Container({
		parent = screenGui,
		name = "Hint",
		size = UDim2.fromOffset(380, 74),
		position = UDim2.new(0.5, 0, 1, -170),
		anchorPoint = Vector2.new(0.5, 1),
		zIndex = Theme.ZIndex.hudOverlay + 1,
	})
	container.Visible = false
	self._panel = container

	local panel = Components.Panel({
		parent = container,
		name = "Panel",
		size = UDim2.fromScale(1, 1),
		elevation = 2,
		transparency = 0.1,
		padding = Theme.Space.md,
		zIndex = container.ZIndex,
		borderColor = Theme.Color.accent,
	})

	self._hintTitle = Components.Text({
		parent = panel,
		name = "Title",
		text = "",
		size = UDim2.new(1, 0, 0, 20),
		textSize = Theme.Text.body,
		font = Theme.Font.heading,
		color = Theme.Color.accent,
		alignX = Enum.TextXAlignment.Center,
		zIndex = panel.ZIndex + 1,
	})

	self._hintBody = Components.Text({
		parent = panel,
		name = "Body",
		text = "",
		position = UDim2.fromOffset(0, 22),
		size = UDim2.new(1, 0, 0, 30),
		textSize = Theme.Text.label,
		color = Theme.Color.textSecondary,
		alignX = Enum.TextXAlignment.Center,
		wrapped = true,
		alignY = Enum.TextYAlignment.Top,
		zIndex = panel.ZIndex + 1,
	})
end

-- ============================================================================
-- Evaluation
-- ============================================================================

--[[ Whether a hint's conditions are met right now. ]]
function TutorialController:_isRelevant(hint: any): boolean
	if self._satisfied[hint.id] then
		return false
	end

	local elapsed = os.clock() - self._joinedAt
	if hint.minSeconds and elapsed < hint.minSeconds then
		return false
	end
	if hint.afterHint and not self._satisfied[hint.afterHint] then
		return false
	end

	if hint.requiresTarget then
		-- Only prompt about capture when there is actually something to capture,
		-- so the first time the player reads it they can immediately act on it.
		if not self._storms:GetTargetStrike() then
			return false
		end
	end
	if hint.requiresCarry and (self._carry.carried or 0) < hint.requiresCarry then
		return false
	end
	if hint.requiresInstability and (self._carry.instability or 0) < hint.requiresInstability then
		return false
	end
	if hint.requiresChain and (self._carry.chain or 0) < hint.requiresChain then
		return false
	end
	if hint.requiresWatts and self._watts < hint.requiresWatts then
		return false
	end

	return true
end

--[[ The most relevant hint right now, or nil. Highest priority wins. ]]
function TutorialController:_selectHint()
	local best, bestPriority = nil, -1
	for _, hint in ipairs(HINTS) do
		if self:_isRelevant(hint) and hint.priority > bestPriority then
			best, bestPriority = hint, hint.priority
		end
	end
	return best
end

function TutorialController:_satisfy(hintId: string)
	if self._satisfied[hintId] then
		return
	end
	self._satisfied[hintId] = true

	if self._current and self._current.id == hintId then
		self:_hide()
	end
end

function TutorialController:_show(hint: any)
	self._current = hint
	self._shown[hint.id] = true

	self._hintTitle.Text = hint.title

	-- Prompts are resolved at display time, so the hint always names the key the
	-- player's current input method actually uses.
	if hint.bodyFormat then
		local actionId = hint.id
		if hint.id == "bank" then
			actionId = "bank"
		elseif hint.id == "upgrade" then
			actionId = "upgrades"
		end
		self._hintBody.Text = hint.bodyFormat:format(self._input:GetPrompt(actionId))
	else
		self._hintBody.Text = hint.body or ""
	end

	self._panel.Visible = true
	self._panel.Position = UDim2.new(0.5, 0, 1, -160)
	TweenService:Create(self._panel, Theme.Tween("normal", "enter"), {
		Position = UDim2.new(0.5, 0, 1, -170),
	}):Play()
	Components.FadeIn(self._panel, { duration = "normal" })
end

function TutorialController:_hide()
	if not self._current then
		return
	end
	self._current = nil

	local slide = TweenService:Create(self._panel, Theme.Tween("fast", "exit"), {
		Position = UDim2.new(0.5, 0, 1, -160),
	})
	slide:Play()
	for _, descendant in ipairs(self._panel:GetDescendants()) do
		if descendant:IsA("TextLabel") then
			TweenService:Create(descendant, Theme.Tween("fast", "exit"), { TextTransparency = 1 }):Play()
		end
	end
	slide.Completed:Once(function()
		if not self._current then
			self._panel.Visible = false
		end
	end)
end

function TutorialController:Update(deltaTime: number)
	local now = os.clock()
	if now < self._nextEvaluateAt then
		return
	end
	-- Evaluated a few times a second rather than per frame; a hint appearing a
	-- third of a second late is imperceptible and this walks a list.
	self._nextEvaluateAt = now + 0.3

	local hint = self:_selectHint()

	if hint ~= self._current then
		if hint then
			self:_show(hint)
		else
			self:_hide()
		end
	end
end

--[[ Test and debug entry point: clears everything so the flow can be replayed. ]]
function TutorialController:Reset()
	self._satisfied = {}
	self._shown = {}
	self._joinedAt = os.clock()
	self:_hide()
end

function TutorialController:Destroy()
	self._maid:DoCleaning()
end

return TutorialController
