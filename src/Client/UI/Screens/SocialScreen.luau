--!strict
--[[
	SocialScreen
	------------
	Who else is here, and how to run with them.

	One list of everyone on the server, with the one action that matters next to
	each name. Your own party is pinned above it, because "who am I with" is a
	different question from "who could I be with" and answering them in one
	undifferentiated list makes both harder to read.

	Every row states why an action is unavailable rather than showing a dead button.
	A greyed INVITE with no explanation is the most common way a social feature
	teaches players that it is broken.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BTS")
local Theme = require(Shared.Config.Theme)
local Maid = require(Shared.Core.Maid)

local Client = script.Parent.Parent.Parent
local Components = require(Client.UI.Components)

local SocialScreen = {}
SocialScreen.__index = SocialScreen

local LocalPlayer = Players.LocalPlayer

function SocialScreen.new(parent: Instance, controllers: any)
	local self = setmetatable({
		_maid = Maid.new(),
		_controllers = controllers,
		_rows = {},
	}, SocialScreen)

	self:_build(parent)
	return self
end

function SocialScreen:_build(parent: Instance)
	local root = Components.Panel({
		parent = parent,
		name = "SocialScreen",
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
		text = "RUNNERS",
		size = UDim2.new(0, 240, 1, 0),
		textSize = Theme.Text.title,
		zIndex = header.ZIndex + 1,
	})

	self._countLabel = Components.Text({
		parent = header,
		name = "Count",
		text = "",
		size = UDim2.new(0, 280, 1, 0),
		position = UDim2.new(1, -280, 0, 0),
		textSize = Theme.Text.caption,
		color = Theme.Color.textTertiary,
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
end

function SocialScreen:SetProfile(profile: any)
	self._profile = profile
end

function SocialScreen:OnOpened()
	self:Refresh()
end

function SocialScreen:_party()
	local controller = self._controllers and self._controllers.PartyController
	return controller, controller and controller:GetParty() or nil
end

function SocialScreen:Refresh()
	for _, row in ipairs(self._rows) do
		row:Destroy()
	end
	self._rows = {}

	local controller, party = self:_party()
	local players = Players:GetPlayers()
	self._countLabel.Text = ("%d on this server"):format(#players)

	local order = 0

	if party then
		order += 1
		self:_addSection(("YOUR PARTY  %d/%d"):format(#(party.members or {}), party.maxSize or 4), order)

		for _, member in ipairs(party.members or {}) do
			order += 1
			self:_addRow({
				userId = member.userId,
				name = member.name,
				level = member.level,
				isLeader = member.isLeader,
				action = member.userId == LocalPlayer.UserId and "leave" or nil,
			}, order)
		end
	end

	order += 1
	self:_addSection("ON THIS SERVER", order)

	-- In the party already? Then they belong in the section above, not in both.
	local inParty = {}
	if party then
		for _, member in ipairs(party.members or {}) do
			inParty[member.userId] = true
		end
	end

	table.sort(players, function(a, b)
		return a.DisplayName < b.DisplayName
	end)

	local listed = 0
	for _, player in ipairs(players) do
		if inParty[player.UserId] or player == LocalPlayer then
			continue
		end

		listed += 1
		order += 1

		local canInvite, reason = true, nil
		if controller then
			canInvite, reason = controller:CanInvite(player.UserId)
		end

		self:_addRow({
			userId = player.UserId,
			name = player.DisplayName,
			action = "invite",
			enabled = canInvite,
			blockText = reason,
		}, order)
	end

	if listed == 0 then
		order += 1
		local empty = Components.Text({
			parent = self._list,
			name = "Empty",
			text = "Nobody else here right now.",
			size = UDim2.new(1, -8, 0, 24),
			textSize = Theme.Text.body,
			color = Theme.Color.textTertiary,
			zIndex = self._list.ZIndex + 1,
		})
		empty.LayoutOrder = order
		table.insert(self._rows, empty)
	end
end

function SocialScreen:_addSection(text: string, order: number)
	local label = Components.Text({
		parent = self._list,
		name = "Section" .. tostring(order),
		text = text,
		size = UDim2.new(1, -8, 0, 22),
		textSize = Theme.Text.caption,
		font = Theme.Font.medium,
		color = Theme.Color.textTertiary,
		alignY = Enum.TextYAlignment.Bottom,
		zIndex = self._list.ZIndex + 1,
	})
	label.LayoutOrder = order
	table.insert(self._rows, label)
end

function SocialScreen:_addRow(entry: any, order: number)
	local row = Components.Panel({
		parent = self._list,
		name = "player" .. tostring(entry.userId),
		size = UDim2.new(1, -8, 0, 44),
		elevation = 1,
		padding = Theme.Space.sm,
		zIndex = self._list.ZIndex + 1,
	})
	row.LayoutOrder = order

	Components.Text({
		parent = row,
		name = "Name",
		text = (entry.isLeader and "★ " or "") .. (entry.name or "Runner"),
		size = UDim2.new(1, -180, 0, 18),
		textSize = Theme.Text.body,
		zIndex = row.ZIndex + 1,
	})

	Components.Text({
		parent = row,
		name = "Sub",
		-- The reason an action is unavailable goes here, so no button is ever dead
		-- and silent.
		text = entry.blockText or (entry.level and ("Level %d"):format(entry.level)) or "",
		size = UDim2.new(1, -180, 0, 14),
		position = UDim2.fromOffset(0, 20),
		textSize = Theme.Text.caption,
		color = entry.blockText and Theme.Color.warning or Theme.Color.textTertiary,
		zIndex = row.ZIndex + 1,
	})

	if entry.action then
		local isLeave = entry.action == "leave"
		local _, button = Components.Button({
			parent = row,
			name = isLeave and "Leave" or "Invite",
			text = isLeave and "LEAVE PARTY" or "INVITE",
			variant = isLeave and "ghost" or "primary",
			size = UDim2.fromOffset(160, 32),
			position = UDim2.new(1, 0, 0.5, 0),
			anchorPoint = Vector2.new(1, 0.5),
			textSize = Theme.Text.caption,
			zIndex = row.ZIndex + 2,
		})
		button:SetEnabled(entry.enabled ~= false)

		self._maid:Add(button.Pressed:Connect(function()
			local controller = select(1, self:_party())
			if not controller then
				return
			end

			if isLeave then
				controller:Leave()
			else
				controller:Invite(entry.userId)
			end

			-- The server answers with a PartyUpdate; re-reading shortly after keeps
			-- the list honest without this screen having to model party state itself.
			task.delay(0.4, function()
				if self._root.Visible then
					self:Refresh()
				end
			end)
		end))
	end

	table.insert(self._rows, row)
end

function SocialScreen:SetVisible(visible: boolean)
	self._root.Visible = visible
	if visible then
		self:Refresh()
		Components.FadeIn(self._root, { duration = "fast" })
	end
end

function SocialScreen:Destroy()
	self._maid:DoCleaning()
end

return SocialScreen
