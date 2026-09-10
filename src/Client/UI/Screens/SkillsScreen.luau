--!strict
--[[
	SkillsScreen
	------------
	The skill tree, drawn as an actual tree.

	Two things matter more than anything else in a skill tree UI, and both are
	structural rather than cosmetic:

	  1. Connections must be visible. A player has to see that Air Dash comes from
	     Kinetic Jump without reading a tooltip, or the tree is a list.
	  2. Powerful future nodes must be visible from the start. The tier-5 keystones
	     are shown greyed with their full description from level one, because
	     wanting Featherweight at level eight is what makes level forty worth
	     reaching.

	Layout is driven by each node's declared grid position, so moving a node in
	config moves it here with no code change.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BTS")
local Theme = require(Shared.Config.Theme)
local SkillTree = require(Shared.Config.SkillTree)
local Net = require(Shared.Net)
local Maid = require(Shared.Core.Maid)

local Client = script.Parent.Parent.Parent
local Components = require(Client.UI.Components)

local SkillsScreen = {}
SkillsScreen.__index = SkillsScreen

local NODE_SIZE = 76
local COLUMN_SPACING = 118
local TIER_SPACING = 112

function SkillsScreen.new(parent: Instance, controllers: any)
	local self = setmetatable({
		_maid = Maid.new(),
		_controllers = controllers,
		_branch = "runner",
		_nodes = {},
		_connections = {},
		_profile = nil,
		_selectedNode = nil,
	}, SkillsScreen)

	self:_build(parent)
	return self
end

function SkillsScreen:_build(parent: Instance)
	local root = Components.Panel({
		parent = parent,
		name = "SkillsScreen",
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
		text = "SKILLS",
		size = UDim2.new(0, 180, 1, 0),
		textSize = Theme.Text.title,
		zIndex = header.ZIndex + 1,
	})

	self._pointsLabel = Components.Text({
		parent = header,
		name = "Points",
		text = "0 points",
		size = UDim2.new(0, 260, 1, 0),
		position = UDim2.new(1, -260, 0, 0),
		textSize = Theme.Text.heading,
		font = Theme.Font.heading,
		color = Theme.Color.accent,
		alignX = Enum.TextXAlignment.Right,
		zIndex = header.ZIndex + 1,
	})

	self._specLabel = Components.Label({
		parent = header,
		name = "Spec",
		text = "",
		size = UDim2.new(0, 300, 0, 16),
		position = UDim2.new(0, 190, 0, 20),
		textSize = Theme.Text.label,
		zIndex = header.ZIndex + 1,
	})

	-- Branch tabs, coloured by branch so the tree's identity carries into the UI.
	local tabs = Components.Container({
		parent = root,
		name = "Branches",
		size = UDim2.new(1, -Theme.Space.xl, 0, 36),
		position = UDim2.fromOffset(Theme.Space.lg, 56),
		zIndex = root.ZIndex + 1,
	})
	Components.List(tabs, { direction = Enum.FillDirection.Horizontal, gap = Theme.Space.xs })

	self._branchButtons = {}
	for _, branch in ipairs(SkillTree.Branches) do
		local _, button = Components.Button({
			parent = tabs,
			name = branch.id,
			text = string.upper(branch.name),
			variant = "ghost",
			size = UDim2.fromOffset(112, 34),
			textSize = Theme.Text.label,
			layoutOrder = branch.order,
			zIndex = tabs.ZIndex + 1,
		})
		self._maid:Add(button.Pressed:Connect(function()
			self:SetBranch(branch.id)
		end))
		self._branchButtons[branch.id] = { controller = button, branch = branch }
	end

	-- The tree canvas.
	local canvasFrame = Components.Panel({
		parent = root,
		name = "TreeCanvas",
		size = UDim2.new(1, -(Theme.Space.xl + 320), 1, -110),
		position = UDim2.fromOffset(Theme.Space.lg, 100),
		elevation = 0,
		radius = Theme.Radius.lg,
		zIndex = root.ZIndex + 1,
	})
	canvasFrame.BackgroundColor3 = Theme.Color.void
	canvasFrame.ClipsDescendants = true
	self._canvas = canvasFrame

	self:_buildNodes()
	self:_buildDetail(root)
end

--[[
	Builds every node once. Nodes for other branches are simply hidden, which keeps
	branch switching instant and avoids rebuilding a hundred instances.
]]
function SkillsScreen:_buildNodes()
	-- Connections are drawn first so they sit behind the nodes.
	for _, node in ipairs(SkillTree.Nodes) do
		for _, requirement in ipairs(node.requires) do
			local prerequisite = SkillTree.NodeById[requirement.id]
			if not prerequisite then
				continue
			end

			local line = Instance.new("Frame")
			line.Name = ("Link_%s_%s"):format(requirement.id, node.id)
			line.AnchorPoint = Vector2.new(0.5, 0.5)
			line.BackgroundColor3 = Theme.Color.border
			line.BorderSizePixel = 0
			line.ZIndex = self._canvas.ZIndex + 1
			line.Parent = self._canvas

			table.insert(self._connections, {
				line = line,
				from = prerequisite,
				to = node,
				requirement = requirement,
			})
		end
	end

	for _, node in ipairs(SkillTree.Nodes) do
		local branch = SkillTree.BranchById[node.branch]
		local branchColor = Color3.fromRGB(
			tonumber(branch.color:sub(1, 2), 16),
			tonumber(branch.color:sub(3, 4), 16),
			tonumber(branch.color:sub(5, 6), 16)
		)

		local frame = Components.Panel({
			parent = self._canvas,
			name = node.id,
			size = UDim2.fromOffset(NODE_SIZE, NODE_SIZE),
			anchorPoint = Vector2.new(0.5, 0.5),
			elevation = 2,
			radius = node.kind == "keystone" and Theme.Radius.sm or Theme.Radius.md,
			zIndex = self._canvas.ZIndex + 3,
		})

		local nameLabel = Components.Text({
			parent = frame,
			name = "Name",
			text = node.name,
			size = UDim2.new(1, -8, 0, 30),
			position = UDim2.fromScale(0.5, 0.42),
			anchorPoint = Vector2.new(0.5, 0.5),
			textSize = Theme.Text.caption,
			font = Theme.Font.medium,
			alignX = Enum.TextXAlignment.Center,
			wrapped = true,
			zIndex = frame.ZIndex + 1,
		})

		local rankLabel = Components.Text({
			parent = frame,
			name = "Rank",
			text = "",
			size = UDim2.new(1, 0, 0, 14),
			position = UDim2.fromScale(0.5, 0.8),
			anchorPoint = Vector2.new(0.5, 0.5),
			textSize = Theme.Text.caption,
			color = Theme.Color.textTertiary,
			alignX = Enum.TextXAlignment.Center,
			zIndex = frame.ZIndex + 1,
		})

		-- A keystone is visually distinct at a glance, because taking one is a
		-- decision the player should recognise as different in kind.
		local kindMarker = nil
		if node.kind == "keystone" then
			kindMarker = Components.Text({
				parent = frame,
				name = "Kind",
				text = "KEYSTONE",
				size = UDim2.new(1, 0, 0, 10),
				position = UDim2.fromScale(0.5, 0.16),
				anchorPoint = Vector2.new(0.5, 0.5),
				textSize = 8,
				color = Theme.Color.warning,
				alignX = Enum.TextXAlignment.Center,
				zIndex = frame.ZIndex + 1,
			})
		end

		local button = Instance.new("TextButton")
		button.Size = UDim2.fromScale(1, 1)
		button.BackgroundTransparency = 1
		button.Text = ""
		button.ZIndex = frame.ZIndex + 3
		button.Parent = frame

		self._maid:Add(button.Activated:Connect(function()
			self:SelectNode(node.id)
		end))
		self._maid:Add(button.MouseEnter:Connect(function()
			self:SelectNode(node.id)
		end))

		self._nodes[node.id] = {
			node = node,
			frame = frame,
			nameLabel = nameLabel,
			rankLabel = rankLabel,
			kindMarker = kindMarker,
			branchColor = branchColor,
			stroke = frame:FindFirstChildOfClass("UIStroke"),
		}
	end
end

function SkillsScreen:_buildDetail(root: Frame)
	local panel = Components.Panel({
		parent = root,
		name = "Detail",
		size = UDim2.fromOffset(300, 0),
		position = UDim2.new(1, -Theme.Space.lg, 0, 100),
		anchorPoint = Vector2.new(1, 0),
		elevation = 2,
		padding = Theme.Space.lg,
		zIndex = root.ZIndex + 2,
	})
	panel.Size = UDim2.new(0, 300, 1, -110)
	self._detailPanel = panel

	self._detailName = Components.Heading({
		parent = panel,
		name = "Name",
		text = "Select a skill",
		size = UDim2.new(1, 0, 0, 26),
		textSize = Theme.Text.heading,
		zIndex = panel.ZIndex + 1,
	})

	self._detailKind = Components.Label({
		parent = panel,
		name = "Kind",
		text = "",
		position = UDim2.fromOffset(0, 28),
		size = UDim2.new(1, 0, 0, 14),
		textSize = Theme.Text.caption,
		zIndex = panel.ZIndex + 1,
	})

	self._detailDescription = Components.Text({
		parent = panel,
		name = "Description",
		text = "",
		position = UDim2.fromOffset(0, 50),
		size = UDim2.new(1, 0, 0, 80),
		textSize = Theme.Text.label,
		color = Theme.Color.textSecondary,
		wrapped = true,
		alignY = Enum.TextYAlignment.Top,
		zIndex = panel.ZIndex + 1,
	})

	self._detailDownside = Components.Text({
		parent = panel,
		name = "Downside",
		text = "",
		position = UDim2.fromOffset(0, 136),
		size = UDim2.new(1, 0, 0, 46),
		textSize = Theme.Text.label,
		color = Theme.Color.danger,
		wrapped = true,
		alignY = Enum.TextYAlignment.Top,
		zIndex = panel.ZIndex + 1,
	})

	self._detailRequirement = Components.Text({
		parent = panel,
		name = "Requirement",
		text = "",
		position = UDim2.fromOffset(0, 188),
		size = UDim2.new(1, 0, 0, 44),
		textSize = Theme.Text.label,
		color = Theme.Color.warning,
		wrapped = true,
		alignY = Enum.TextYAlignment.Top,
		zIndex = panel.ZIndex + 1,
	})

	local _, takeButton = Components.Button({
		parent = panel,
		name = "Take",
		text = "TAKE",
		variant = "primary",
		size = UDim2.new(1, 0, 0, 44),
		position = UDim2.new(0, 0, 1, -44),
		zIndex = panel.ZIndex + 2,
		enabled = false,
	})
	self._takeButton = takeButton

	self._maid:Add(takeButton.Pressed:Connect(function()
		if self._selectedNode then
			Net.FireServer("RequestSpendSkillPoint", self._selectedNode)
		end
	end))

	local _, respecButton = Components.Button({
		parent = panel,
		name = "Respec",
		text = "RESPEC",
		variant = "ghost",
		size = UDim2.new(1, 0, 0, 34),
		position = UDim2.new(0, 0, 1, -86),
		textSize = Theme.Text.caption,
		zIndex = panel.ZIndex + 2,
	})
	self._respecButton = respecButton

	self._maid:Add(respecButton.Pressed:Connect(function()
		Net.FireServer("RequestRespecSkills")
	end))
end

-- ============================================================================
-- Layout
-- ============================================================================

--[[ Node position within the canvas, from its declared grid coordinates. ]]
function SkillsScreen:_nodePosition(node: any): UDim2
	local canvasSize = self._canvas.AbsoluteSize
	local centreX = canvasSize.X / 2

	-- Columns run 1..4; centre the used range so a branch with three columns is not
	-- pinned to the left.
	local x = centreX + (node.position.x - 2.5) * COLUMN_SPACING
	local y = 70 + (node.position.y - 1) * TIER_SPACING

	return UDim2.fromOffset(x, y)
end

function SkillsScreen:SetBranch(branchId: string)
	self._branch = branchId
	self:Refresh()
end

function SkillsScreen:SelectNode(nodeId: string)
	self._selectedNode = nodeId
	self:_updateDetail()

	for id, entry in pairs(self._nodes) do
		if entry.stroke then
			entry.stroke.Thickness = id == nodeId and Theme.Stroke.thick or Theme.Stroke.hairline
		end
	end
end

-- ============================================================================
-- Data
-- ============================================================================

function SkillsScreen:SetProfile(profile: any)
	self._profile = profile
	self:Refresh()
end

function SkillsScreen:_getRank(nodeId: string): number
	if not self._profile then
		return 0
	end
	return self._profile.skills[nodeId] or 0
end

function SkillsScreen:_updateDetail()
	local nodeId = self._selectedNode
	local entry = nodeId and self._nodes[nodeId]
	if not entry then
		return
	end

	local node = entry.node
	local rank = self:_getRank(nodeId)

	self._detailName.Text = node.name
	self._detailName.TextColor3 = entry.branchColor

	local kindText = string.upper(node.kind)
	if node.maxRank > 1 then
		kindText = ("%s  ·  RANK %d / %d"):format(kindText, rank, node.maxRank)
	end
	self._detailKind.Text = kindText

	self._detailDescription.Text = node.description
	self._detailDownside.Text = node.downside and ("DOWNSIDE: " .. node.downside) or ""

	if not self._profile then
		return
	end

	local canRank, reason, detail = SkillTree.CanRankUp(nodeId, self._profile.skills, self._profile.skillPoints)

	if canRank then
		self._detailRequirement.Text = ("Costs %d skill point%s"):format(detail, detail == 1 and "" or "s")
		self._detailRequirement.TextColor3 = Theme.Color.textSecondary
		self._takeButton:SetText(("TAKE — %d PT"):format(detail))
		self._takeButton:SetEnabled(true)
	else
		self._takeButton:SetEnabled(false)
		if reason == "max_rank" then
			self._detailRequirement.Text = "Fully ranked."
			self._detailRequirement.TextColor3 = Theme.Color.success
			self._takeButton:SetText("MAXED")
		elseif reason == "missing_prerequisite" then
			local prerequisite = SkillTree.NodeById[detail.id]
			self._detailRequirement.Text = ("Requires %s at rank %d.")
				:format(prerequisite and prerequisite.name or detail.id, detail.rank)
			self._detailRequirement.TextColor3 = Theme.Color.warning
			self._takeButton:SetText("LOCKED")
		elseif reason == "mutually_exclusive" then
			local other = SkillTree.NodeById[detail]
			self._detailRequirement.Text = ("Cannot be taken with %s.")
				:format(other and other.name or tostring(detail))
			self._detailRequirement.TextColor3 = Theme.Color.danger
			self._takeButton:SetText("EXCLUDED")
		elseif reason == "insufficient_points" then
			self._detailRequirement.Text = ("Needs %d skill points. You have %d.")
				:format(detail, self._profile.skillPoints)
			self._detailRequirement.TextColor3 = Theme.Color.warning
			self._takeButton:SetText(("NEED %d PT"):format(detail))
		end
	end
end

function SkillsScreen:Refresh()
	if not self._profile then
		return
	end

	self._pointsLabel.Text = ("%d point%s"):format(
		self._profile.skillPoints,
		self._profile.skillPoints == 1 and "" or "s"
	)

	local branchId, spent, isHybrid = SkillTree.GetSpecialisation(self._profile.skills)
	if branchId then
		local branch = SkillTree.BranchById[branchId]
		self._specLabel.Text = isHybrid
			and ("HYBRID — %s LEANING"):format(string.upper(branch.name))
			or string.upper(branch.tagline)
	else
		self._specLabel.Text = "NO SPECIALISATION YET"
	end

	for id, entry in pairs(self._branchButtons) do
		entry.controller:SetEnabled(id ~= self._branch)
	end

	-- Nodes.
	for nodeId, entry in pairs(self._nodes) do
		local node = entry.node
		local visible = node.branch == self._branch
		entry.frame.Visible = visible
		if not visible then
			continue
		end

		entry.frame.Position = self:_nodePosition(node)

		local rank = self:_getRank(nodeId)
		local canRank = SkillTree.CanRankUp(nodeId, self._profile.skills, self._profile.skillPoints)

		if rank > 0 then
			-- Taken: the branch colour, at full strength.
			entry.frame.BackgroundColor3 = entry.branchColor:Lerp(Theme.Color.base, 0.55)
			entry.nameLabel.TextColor3 = Theme.Color.textPrimary
			if entry.stroke then
				entry.stroke.Color = entry.branchColor
				entry.stroke.Transparency = 0
			end
		elseif canRank then
			-- Available: dimmer, but clearly live.
			entry.frame.BackgroundColor3 = Theme.Color.elevated
			entry.nameLabel.TextColor3 = Theme.Color.textPrimary
			if entry.stroke then
				entry.stroke.Color = entry.branchColor
				entry.stroke.Transparency = 0.4
			end
		else
			-- Locked: still fully readable, because an unreachable keystone the
			-- player can read is a goal, and one they cannot is invisible.
			entry.frame.BackgroundColor3 = Theme.Color.raised
			entry.nameLabel.TextColor3 = Theme.Color.textDisabled
			if entry.stroke then
				entry.stroke.Color = Theme.Color.border
				entry.stroke.Transparency = 0.5
			end
		end

		entry.rankLabel.Text = node.maxRank > 1 and ("%d/%d"):format(rank, node.maxRank) or ""
	end

	-- Connections.
	for _, connection in ipairs(self._connections) do
		local visible = connection.from.branch == self._branch and connection.to.branch == self._branch
		connection.line.Visible = visible
		if not visible then
			continue
		end

		local fromPosition = self:_nodePosition(connection.from)
		local toPosition = self:_nodePosition(connection.to)

		local fromVector = Vector2.new(fromPosition.X.Offset, fromPosition.Y.Offset)
		local toVector = Vector2.new(toPosition.X.Offset, toPosition.Y.Offset)
		local delta = toVector - fromVector
		local midpoint = fromVector + delta * 0.5

		connection.line.Position = UDim2.fromOffset(midpoint.X, midpoint.Y)
		connection.line.Size = UDim2.fromOffset(math.max(2, delta.Magnitude), 2)
		connection.line.Rotation = math.deg(math.atan2(delta.Y, delta.X))

		-- A satisfied connection is lit; an unsatisfied one is not. That single
		-- distinction is what lets a player read a path at a glance.
		local satisfied = self:_getRank(connection.from.id) >= connection.requirement.rank
		connection.line.BackgroundColor3 = satisfied and Theme.Color.accentDim or Theme.Color.border
		connection.line.BackgroundTransparency = satisfied and 0.1 or 0.6
	end

	self:_updateDetail()

	local respecCost = 2500 + SkillTree.GetSpentPoints(self._profile.skills) * 180
	self._respecButton:SetText(("RESPEC — %s W"):format(Theme.FormatNumber(respecCost)))
	self._respecButton:SetEnabled(spent > 0)
end

function SkillsScreen:SetVisible(visible: boolean)
	self._root.Visible = visible
	if visible then
		self:Refresh()
		Components.FadeIn(self._root, { duration = "fast" })
	end
end

function SkillsScreen:Destroy()
	self._maid:DoCleaning()
end

return SkillsScreen
