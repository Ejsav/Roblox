--!strict
--[[
	PartyController
	---------------
	The party roster and the invite prompt.

	An invite has to be answerable without opening a menu — someone standing next to
	you asking you to group up is a moment measured in seconds — so the prompt is a
	first-class piece of HUD with its own two buttons, not a toast with instructions
	to go and find a screen.

	The roster is deliberately small: names, levels, and who is leading. A party
	panel that shows health bars and positions for three other people is a second
	HUD, and this game already has one. Where everyone is belongs on the map.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BTS")
local Theme = require(Shared.Config.Theme)
local Net = require(Shared.Net)
local Maid = require(Shared.Core.Maid)
local Signal = require(Shared.Core.Signal)

local Client = script.Parent.Parent
local Components = require(Client.UI.Components)

local PartyController = {}
PartyController.Name = "PartyController"
PartyController.Dependencies = { "InputController" }
PartyController.Priority = 35

local LocalPlayer = Players.LocalPlayer

function PartyController:Init()
	self._maid = Maid.new()
	self._party = nil
	self._invite = nil
	self._rosterRows = {}

	self.PartyChanged = Signal.new("Party.Changed")
	self.InviteReceived = Signal.new("Party.InviteReceived")

	local playerGui = LocalPlayer:WaitForChild("PlayerGui")

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "BTS_Party"
	screenGui.ResetOnSpawn = false
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.DisplayOrder = Theme.ZIndex.hudOverlay
	screenGui.Parent = playerGui
	self._maid:Add(screenGui)
	self._gui = screenGui

	self:_buildRoster()
	self:_buildInvitePrompt()
end

function PartyController:Start()
	self._notifications = self.Registry:Find("NotificationController")
	self._audio = self.Registry:Find("AudioController")

	self._maid:Add(Net.OnClientEvent("PartyUpdate", function(payload)
		self:_onUpdate(payload)
	end))
end

-- ============================================================================
-- Building
-- ============================================================================

function PartyController:_buildRoster()
	local panel = Components.Panel({
		parent = self._gui,
		name = "Roster",
		size = UDim2.fromOffset(220, 0),
		position = UDim2.new(0, Theme.Layout.screenPadding, 0.5, 0),
		anchorPoint = Vector2.new(0, 0.5),
		elevation = 1,
		transparency = 0.25,
		padding = Theme.Space.sm,
		zIndex = Theme.ZIndex.hud,
	})
	panel.AutomaticSize = Enum.AutomaticSize.Y
	panel.Visible = false
	self._rosterPanel = panel

	Components.List(panel, { gap = 2 })

	self._rosterHeading = Components.Text({
		parent = panel,
		name = "Heading",
		text = "PARTY",
		size = UDim2.new(1, 0, 0, 14),
		textSize = Theme.Text.caption,
		font = Theme.Font.medium,
		color = Theme.Color.textTertiary,
		layoutOrder = 1,
		zIndex = panel.ZIndex + 1,
	})

	self._rosterList = Components.Container({
		parent = panel,
		name = "Members",
		size = UDim2.new(1, 0, 0, 0),
		zIndex = panel.ZIndex + 1,
	})
	self._rosterList.AutomaticSize = Enum.AutomaticSize.Y
	self._rosterList.LayoutOrder = 2
	Components.List(self._rosterList, { gap = 2 })
end

function PartyController:_buildInvitePrompt()
	local panel = Components.Panel({
		parent = self._gui,
		name = "Invite",
		size = UDim2.fromOffset(340, 116),
		position = UDim2.new(0.5, 0, 0, -140),
		anchorPoint = Vector2.new(0.5, 0),
		elevation = 3,
		padding = Theme.Space.md,
		zIndex = Theme.ZIndex.notification + 2,
	})
	panel.Visible = false
	self._invitePanel = panel

	self._inviteText = Components.Text({
		parent = panel,
		name = "Text",
		text = "",
		size = UDim2.new(1, 0, 0, 40),
		textSize = Theme.Text.body,
		alignY = Enum.TextYAlignment.Top,
		wrapped = true,
		richText = true,
		zIndex = panel.ZIndex + 1,
	})

	local actions = Components.Container({
		parent = panel,
		name = "Actions",
		size = UDim2.new(1, 0, 0, 36),
		position = UDim2.new(0, 0, 1, -36),
		zIndex = panel.ZIndex + 1,
	})
	Components.List(actions, { direction = Enum.FillDirection.Horizontal, gap = Theme.Space.sm })

	local _, accept = Components.Button({
		parent = actions,
		name = "Accept",
		text = "ACCEPT",
		variant = "primary",
		size = UDim2.fromOffset(150, 34),
		textSize = Theme.Text.caption,
		layoutOrder = 1,
		zIndex = actions.ZIndex + 1,
	})
	self._maid:Add(accept.Pressed:Connect(function()
		self:Respond(true)
	end))

	local _, decline = Components.Button({
		parent = actions,
		name = "Decline",
		text = "DECLINE",
		variant = "ghost",
		size = UDim2.fromOffset(130, 34),
		textSize = Theme.Text.caption,
		layoutOrder = 2,
		zIndex = actions.ZIndex + 1,
	})
	self._maid:Add(decline.Pressed:Connect(function()
		self:Respond(false)
	end))
end

-- ============================================================================
-- Messages
-- ============================================================================

function PartyController:_onUpdate(payload: any)
	local kind = payload.kind

	if kind == "party" then
		self._party = payload
		self:_refreshRoster()
		self.PartyChanged:Fire(payload)

	elseif kind == "dissolved" or kind == "left" then
		self._party = nil
		self:_refreshRoster()
		self.PartyChanged:Fire(nil)
		self:_notify("info", "Party", kind == "left" and "You left the party." or "The party broke up.")

	elseif kind == "invite" then
		self:_showInvite(payload)

	elseif kind == "invite_expired" then
		-- Only clear the prompt if it is the one that expired; a newer invite may
		-- already have replaced it on screen.
		if self._invite and self._invite.inviteId == payload.inviteId then
			self:_hideInvite()
		end

	elseif kind == "invite_sent" then
		self:_notify("info", "Invite sent", ("Waiting on %s."):format(payload.toName or "them"))

	elseif kind == "invite_declined" then
		self:_notify("info", "Invite declined", ("%s said no."):format(payload.byName or "They"))

	elseif kind == "refused" then
		self:_notify("bad", "Cannot invite", payload.reason or "")
	end
end

function PartyController:_notify(kind: string, title: string, body: string)
	if self._notifications then
		self._notifications:Push({ kind = kind, title = title, body = body, lifetime = 4 })
	end
end

-- ============================================================================
-- Invites
-- ============================================================================

function PartyController:_showInvite(payload: any)
	self._invite = payload

	self._inviteText.Text = ("<b>%s</b> invited you to a party.\n%d of %d slots filled."):format(
		payload.fromName or "Someone",
		payload.partySize or 1,
		payload.maxSize or 4
	)

	self._invitePanel.Visible = true
	self._invitePanel.Position = UDim2.new(0.5, 0, 0, -140)
	Components.FadeIn(self._invitePanel, { duration = "slow", slide = Vector2.new(0, -20) })
	self._invitePanel.Position = UDim2.new(0.5, 0, 0, Theme.Space.xl)

	if self._audio then
		self._audio:PlayUi("ui_hover")
	end

	self.InviteReceived:Fire(payload)

	-- The prompt disappears on its own when the invite would have expired anyway,
	-- so a declined-by-inaction invite does not leave a dead panel on screen.
	local inviteId = payload.inviteId
	task.delay(payload.expiresIn or 60, function()
		if self._invite and self._invite.inviteId == inviteId then
			self:_hideInvite()
		end
	end)
end

function PartyController:_hideInvite()
	self._invite = nil
	self._invitePanel.Visible = false
end

function PartyController:Respond(accept: boolean): boolean
	local invite = self._invite
	if not invite then
		return false
	end

	Net.FireServer("RequestRespondToInvite", invite.inviteId, accept)
	self:_hideInvite()
	return true
end

-- ============================================================================
-- Actions
-- ============================================================================

function PartyController:Invite(userId: number): boolean
	if userId == LocalPlayer.UserId then
		return false
	end
	Net.FireServer("RequestInviteToParty", userId)
	return true
end

function PartyController:Leave(): boolean
	if not self._party then
		return false
	end
	Net.FireServer("RequestLeaveParty")
	return true
end

function PartyController:GetParty()
	return self._party
end

function PartyController:IsInParty(): boolean
	return self._party ~= nil
end

function PartyController:IsLeader(): boolean
	return self._party ~= nil and self._party.leaderId == LocalPlayer.UserId
end

--[[ Whether a given player can be invited right now, and why not if they cannot. ]]
function PartyController:CanInvite(userId: number): (boolean, string?)
	if userId == LocalPlayer.UserId then
		return false, "That is you."
	end

	local party = self._party
	if not party then
		return true, nil
	end

	for _, member in ipairs(party.members or {}) do
		if member.userId == userId then
			return false, "Already in your party."
		end
	end

	if #(party.members or {}) >= (party.maxSize or 4) then
		return false, "Your party is full."
	end
	if not self:IsLeader() then
		return false, "Only the leader can invite."
	end

	return true, nil
end

-- ============================================================================
-- Roster
-- ============================================================================

function PartyController:_refreshRoster()
	for _, row in ipairs(self._rosterRows) do
		row:Destroy()
	end
	self._rosterRows = {}

	local party = self._party
	if not party then
		self._rosterPanel.Visible = false
		return
	end

	self._rosterPanel.Visible = true
	self._rosterHeading.Text = ("PARTY  %d/%d"):format(#(party.members or {}), party.maxSize or 4)

	for index, member in ipairs(party.members or {}) do
		local row = Components.Container({
			parent = self._rosterList,
			name = "Member" .. tostring(index),
			size = UDim2.new(1, 0, 0, 18),
			zIndex = self._rosterList.ZIndex + 1,
		})
		row.LayoutOrder = index

		local isSelf = member.userId == LocalPlayer.UserId

		Components.Text({
			parent = row,
			name = "Name",
			text = (member.isLeader and "★ " or "") .. (member.name or "Runner"),
			size = UDim2.new(1, -44, 1, 0),
			textSize = Theme.Text.caption,
			font = isSelf and Theme.Font.medium or Theme.Font.regular,
			color = isSelf and Theme.Color.accent or Theme.Color.textSecondary,
			zIndex = row.ZIndex + 1,
		})

		Components.Text({
			parent = row,
			name = "Level",
			text = tostring(member.level or 1),
			size = UDim2.fromOffset(40, 18),
			position = UDim2.new(1, -40, 0, 0),
			textSize = Theme.Text.caption,
			color = Theme.Color.textTertiary,
			alignX = Enum.TextXAlignment.Right,
			zIndex = row.ZIndex + 1,
		})

		table.insert(self._rosterRows, row)
	end
end

function PartyController:Destroy()
	self._maid:DoCleaning()
end

return PartyController
