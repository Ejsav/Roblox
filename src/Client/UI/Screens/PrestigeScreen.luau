--!strict
--[[
	PrestigeScreen
	--------------
	The decision to start again, and the tree that makes it worth doing.

	Prestige in this game expands rather than resets — that is the whole pitch — so
	the screen leads with what is kept and what is gained, and states the cost
	plainly underneath rather than burying it. A player who prestiges without
	understanding what they lose will feel cheated no matter how good the maths is,
	so the confirm is two-step and the second step spells it out.

	The skill tree below is permanent progression bought with sigils, which only
	prestige produces. It is laid out by tier because the tiers are the shape of the
	tree; drawing it as a graph would look impressive and read worse.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BTS")
local Theme = require(Shared.Config.Theme)
local Net = require(Shared.Net)
local Maid = require(Shared.Core.Maid)

local Client = script.Parent.Parent.Parent
local Components = require(Client.UI.Components)

local PrestigeScreen = {}
PrestigeScreen.__index = PrestigeScreen

local LIST_WIDTH = 420

function PrestigeScreen.new(parent: Instance, controllers: any)
	local self = setmetatable({
		_maid = Maid.new(),
		_controllers = controllers,
		_view = nil,
		_profile = nil,
		_selected = nil,
		_confirming = false,
		_rows = {},
		_fetching = false,
	}, PrestigeScreen)

	self:_build(parent)
	return self
end

function PrestigeScreen:_build(parent: Instance)
	local root = Components.Panel({
		parent = parent,
		name = "PrestigeScreen",
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
		text = "PRESTIGE",
		size = UDim2.new(0, 240, 1, 0),
		textSize = Theme.Text.title,
		zIndex = header.ZIndex + 1,
	})

	self._sigilLabel = Components.Text({
		parent = header,
		name = "Sigils",
		text = "",
		size = UDim2.new(0, 240, 1, 0),
		position = UDim2.new(1, -240, 0, 0),
		textSize = Theme.Text.heading,
		font = Theme.Font.heading,
		color = Theme.Color.sigils,
		alignX = Enum.TextXAlignment.Right,
		zIndex = header.ZIndex + 1,
	})

	self:_buildStatus()
	self:_buildTree()
end

--[[ The left column: rank, what the next one gives, and the commit button. ]]
function PrestigeScreen:_buildStatus()
	local panel = Components.Panel({
		parent = self._root,
		name = "Status",
		size = UDim2.new(0, LIST_WIDTH, 1, -(58 + Theme.Space.lg)),
		position = UDim2.fromOffset(Theme.Space.lg, 58),
		elevation = 1,
		padding = Theme.Space.lg,
		zIndex = self._root.ZIndex + 1,
	})
	self._statusPanel = panel

	self._rankLabel = Components.Text({
		parent = panel,
		name = "Rank",
		text = "",
		size = UDim2.new(1, 0, 0, 16),
		textSize = Theme.Text.caption,
		font = Theme.Font.medium,
		color = Theme.Color.textTertiary,
		zIndex = panel.ZIndex + 1,
	})

	self._rankName = Components.Heading({
		parent = panel,
		text = "",
		size = UDim2.new(1, 0, 0, 32),
		position = UDim2.fromOffset(0, 20),
		textSize = Theme.Text.display,
		color = Theme.Color.sigils,
		zIndex = panel.ZIndex + 1,
	})

	Components.Text({
		parent = panel,
		name = "GainsHeading",
		text = "THE NEXT RANK GIVES",
		size = UDim2.new(1, 0, 0, 14),
		position = UDim2.fromOffset(0, 62),
		textSize = Theme.Text.caption,
		font = Theme.Font.medium,
		color = Theme.Color.textTertiary,
		zIndex = panel.ZIndex + 1,
	})

	self._gainsList = Components.Scroll({
		parent = panel,
		name = "Gains",
		size = UDim2.new(1, 0, 0, 150),
		position = UDim2.fromOffset(0, 80),
		gap = 2,
		zIndex = panel.ZIndex + 1,
	})

	Components.Text({
		parent = panel,
		name = "CostHeading",
		text = "AND COSTS",
		size = UDim2.new(1, 0, 0, 14),
		position = UDim2.fromOffset(0, 240),
		textSize = Theme.Text.caption,
		font = Theme.Font.medium,
		color = Theme.Color.textTertiary,
		zIndex = panel.ZIndex + 1,
	})

	-- Stated as prose rather than a list of fields, because "you lose your levels
	-- and upgrades" is what the player needs to understand, not a schema diff.
	self._costLabel = Components.Text({
		parent = panel,
		name = "Cost",
		text = "",
		size = UDim2.new(1, 0, 0, 90),
		position = UDim2.fromOffset(0, 258),
		textSize = Theme.Text.body,
		color = Theme.Color.textSecondary,
		alignY = Enum.TextYAlignment.Top,
		wrapped = true,
		zIndex = panel.ZIndex + 1,
	})

	self._requirementLabel = Components.Text({
		parent = panel,
		name = "Requirement",
		text = "",
		size = UDim2.new(1, 0, 0, 40),
		position = UDim2.new(0, 0, 1, -100),
		textSize = Theme.Text.caption,
		color = Theme.Color.warning,
		wrapped = true,
		zIndex = panel.ZIndex + 1,
	})

	local _, commit = Components.Button({
		parent = panel,
		name = "Commit",
		text = "PRESTIGE",
		variant = "primary",
		size = UDim2.new(1, 0, 0, 48),
		position = UDim2.new(0, 0, 1, -48),
		zIndex = panel.ZIndex + 2,
	})
	self._commitButton = commit
	self._maid:Add(commit.Pressed:Connect(function()
		self:_onCommit()
	end))
end

function PrestigeScreen:_buildTree()
	local left = Theme.Space.lg + LIST_WIDTH + Theme.Space.lg

	local panel = Components.Panel({
		parent = self._root,
		name = "Tree",
		size = UDim2.new(1, -(left + Theme.Space.lg), 1, -(58 + Theme.Space.lg)),
		position = UDim2.fromOffset(left, 58),
		elevation = 1,
		padding = Theme.Space.lg,
		zIndex = self._root.ZIndex + 1,
	})

	Components.Text({
		parent = panel,
		name = "Heading",
		text = "PERMANENT SKILLS",
		size = UDim2.new(1, 0, 0, 16),
		textSize = Theme.Text.caption,
		font = Theme.Font.medium,
		color = Theme.Color.textTertiary,
		zIndex = panel.ZIndex + 1,
	})

	Components.Text({
		parent = panel,
		name = "Subheading",
		text = "Bought with sigils. Never lost.",
		size = UDim2.new(1, 0, 0, 14),
		position = UDim2.fromOffset(0, 18),
		textSize = Theme.Text.caption,
		color = Theme.Color.textTertiary,
		zIndex = panel.ZIndex + 1,
	})

	self._treeList = Components.Scroll({
		parent = panel,
		name = "Skills",
		size = UDim2.new(1, 0, 1, -44),
		position = UDim2.fromOffset(0, 42),
		gap = Theme.Space.xs,
		zIndex = panel.ZIndex + 1,
	})

	self._treeStatus = Components.Text({
		parent = panel,
		name = "TreeStatus",
		text = "Loading…",
		size = UDim2.new(1, 0, 0, 24),
		position = UDim2.fromOffset(0, 48),
		textSize = Theme.Text.body,
		color = Theme.Color.textTertiary,
		zIndex = panel.ZIndex + 2,
	})
end

-- ============================================================================
-- Data
-- ============================================================================

function PrestigeScreen:SetView(view: any)
	self._view = view
	-- A refreshed view means the world changed under the confirm, so the two-step
	-- resets rather than leaving a primed button over stale numbers.
	self._confirming = false
	self:Refresh()
end

function PrestigeScreen:SetProfile(profile: any)
	self._profile = profile
end

function PrestigeScreen:RequestRefresh()
	if self._fetching then
		return
	end
	self._fetching = true

	task.spawn(function()
		local view = Net.InvokeServer("RequestPrestigeView")
		self._fetching = false
		if view then
			self:SetView(view)
		end
	end)
end

function PrestigeScreen:OnOpened()
	self:RequestRefresh()
end

-- ============================================================================
-- Actions
-- ============================================================================

--[[
	Two-step commit. The first press arms it and rewrites the button to say exactly
	what is about to happen; the second sends it. Prestige is the only irreversible
	action in the game, and the one place a confirmation is worth the friction.
]]
function PrestigeScreen:_onCommit()
	local status = self._view and self._view.status
	if not status or not status.eligible then
		return
	end

	if not self._confirming then
		self._confirming = true
		self:_refreshStatus()

		-- The arming lapses. A primed irreversible button left sitting on screen is
		-- a trap for the next person who walks past the keyboard.
		task.delay(8, function()
			if self._confirming then
				self._confirming = false
				self:_refreshStatus()
			end
		end)
		return
	end

	Net.FireServer("RequestPrestige", true)
	self._confirming = false
	self._commitButton:SetEnabled(false)
	self._commitButton:SetText("RESETTING…")
end

function PrestigeScreen:PurchaseSkill(skillId: string)
	Net.FireServer("RequestPrestigeSkill", skillId)
	task.delay(0.3, function()
		self:RequestRefresh()
	end)
end

-- ============================================================================
-- Rendering
-- ============================================================================

function PrestigeScreen:Refresh()
	self:_refreshStatus()
	self:_refreshTree()
end

function PrestigeScreen:_refreshStatus()
	local view = self._view
	if not view then
		return
	end

	local status = view.status
	self._sigilLabel.Text = ("%s SIGILS"):format(Theme.FormatNumber(view.sigils or 0))

	if not status then
		return
	end

	self._rankLabel.Text = ("RANK %d OF %d"):format(status.currentRank or 0, status.maxRank or 0)
	self._rankName.Text = status.nextRank and status.nextRank.name or "FINAL RANK"

	for _, child in ipairs(self._gainsList:GetChildren()) do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end

	local gains = status.nextRank and status.nextRank.grants or nil
	local order = 0
	if gains then
		for label, value in pairs(self:_describeGains(gains, status.nextRank)) do
			order += 1
			local row = Components.Text({
				parent = self._gainsList,
				name = "Gain" .. tostring(order),
				text = ("%s  —  %s"):format(label, value),
				size = UDim2.new(1, -8, 0, 18),
				textSize = Theme.Text.caption,
				color = Theme.Color.success,
				zIndex = self._gainsList.ZIndex + 1,
			})
			row.LayoutOrder = order
		end
	end

	if order == 0 then
		local row = Components.Text({
			parent = self._gainsList,
			name = "NoGains",
			text = "Nothing further — this is the last rank.",
			size = UDim2.new(1, -8, 0, 18),
			textSize = Theme.Text.caption,
			color = Theme.Color.textTertiary,
			zIndex = self._gainsList.ZIndex + 1,
		})
		row.LayoutOrder = 1
	end

	self._costLabel.Text = "Your level, upgrades, skill points and equipment reset to nothing. "
		.. "Achievements, discoveries, collections, records, titles and cosmetics are kept, "
		.. "and so is everything on this page."

	self._requirementLabel.Text = status.eligible and "" or (status.requirement or "")

	if not status.eligible then
		self._commitButton:SetText("NOT YET")
		self._commitButton:SetEnabled(false)
	elseif self._confirming then
		-- The second press spells out the trade rather than saying "confirm".
		self._commitButton:SetText("YES — RESET AND TAKE RANK " .. tostring((status.currentRank or 0) + 1))
		self._commitButton:SetEnabled(true)
	else
		self._commitButton:SetText("PRESTIGE")
		self._commitButton:SetEnabled(true)
	end
end

function PrestigeScreen:_describeGains(grants: any, rank: any): { [string]: string }
	local out = {}

	if rank and rank.sigils then
		out["Sigils"] = ("+%d"):format(rank.sigils)
	end
	if grants.traversal then
		out["Traversal"] = grants.traversal
	end
	if grants.item then
		out["Equipment"] = grants.item
	end
	if grants.title then
		out["Title"] = grants.title
	end
	if grants.statMultiplier then
		out["All stats"] = ("+%d%%"):format(math.floor(grants.statMultiplier * 100))
	end
	if grants.regionAccess then
		out["Region"] = grants.regionAccess
	end

	return out
end

function PrestigeScreen:_refreshTree()
	for _, row in ipairs(self._rows) do
		row:Destroy()
	end
	self._rows = {}

	local skills = (self._view and self._view.skills) or {}
	self._treeStatus.Visible = #skills == 0
	if #skills == 0 then
		self._treeStatus.Text = self._view and "No prestige skills available yet." or "Loading…"
		return
	end

	-- Grouped by tier, because the tiers are the shape of the tree.
	local byTier = {}
	local tiers = {}
	for _, skill in ipairs(skills) do
		local tier = skill.tier or 1
		if not byTier[tier] then
			byTier[tier] = {}
			table.insert(tiers, tier)
		end
		table.insert(byTier[tier], skill)
	end
	table.sort(tiers)

	local order = 0
	for _, tier in ipairs(tiers) do
		order += 1
		local heading = Components.Text({
			parent = self._treeList,
			name = "Tier" .. tostring(tier),
			text = ("TIER %d"):format(tier),
			size = UDim2.new(1, -8, 0, 20),
			textSize = Theme.Text.caption,
			font = Theme.Font.medium,
			color = Theme.Color.textTertiary,
			alignY = Enum.TextYAlignment.Bottom,
			zIndex = self._treeList.ZIndex + 1,
		})
		heading.LayoutOrder = order
		table.insert(self._rows, heading)

		table.sort(byTier[tier], function(a, b)
			return a.name < b.name
		end)

		for _, skill in ipairs(byTier[tier]) do
			order += 1
			self:_addSkillRow(skill, order)
		end
	end
end

function PrestigeScreen:_addSkillRow(skill: any, order: number)
	local row = Components.Panel({
		parent = self._treeList,
		name = skill.id,
		size = UDim2.new(1, -8, 0, 54),
		elevation = skill.owned and 2 or 1,
		padding = Theme.Space.sm,
		zIndex = self._treeList.ZIndex + 1,
	})
	row.LayoutOrder = order

	local color
	if skill.owned then
		color = Theme.Color.success
	elseif skill.canPurchase then
		color = Theme.Color.textPrimary
	else
		color = Theme.Color.textDisabled
	end

	Components.Text({
		parent = row,
		name = "Name",
		text = skill.name,
		size = UDim2.new(1, -150, 0, 18),
		textSize = Theme.Text.body,
		font = skill.owned and Theme.Font.medium or Theme.Font.regular,
		color = color,
		zIndex = row.ZIndex + 1,
	})

	Components.Text({
		parent = row,
		name = "Description",
		-- The block reason replaces the description when there is one: knowing why
		-- you cannot buy it matters more than knowing what it does.
		text = (not skill.owned and not skill.canPurchase and skill.blockText)
			or skill.description
			or "",
		size = UDim2.new(1, -150, 0, 28),
		position = UDim2.fromOffset(0, 20),
		textSize = Theme.Text.caption,
		color = (not skill.owned and not skill.canPurchase and skill.blockText)
			and Theme.Color.warning
			or Theme.Color.textTertiary,
		wrapped = true,
		zIndex = row.ZIndex + 1,
	})

	if skill.owned then
		Components.Text({
			parent = row,
			name = "Owned",
			text = "OWNED",
			size = UDim2.fromOffset(130, 18),
			position = UDim2.new(1, -130, 0.5, -9),
			textSize = Theme.Text.caption,
			font = Theme.Font.medium,
			color = Theme.Color.success,
			alignX = Enum.TextXAlignment.Right,
			zIndex = row.ZIndex + 1,
		})
	else
		local _, button = Components.Button({
			parent = row,
			name = "Buy",
			text = ("%d ◆"):format(skill.cost or 0),
			variant = skill.canPurchase and "primary" or "ghost",
			size = UDim2.fromOffset(120, 36),
			position = UDim2.new(1, 0, 0.5, 0),
			anchorPoint = Vector2.new(1, 0.5),
			textSize = Theme.Text.caption,
			zIndex = row.ZIndex + 2,
		})
		button:SetEnabled(skill.canPurchase == true)
		self._maid:Add(button.Pressed:Connect(function()
			self:PurchaseSkill(skill.id)
		end))
	end

	table.insert(self._rows, row)
end

function PrestigeScreen:SetVisible(visible: boolean)
	self._root.Visible = visible
	if visible then
		self:Refresh()
		Components.FadeIn(self._root, { duration = "fast" })
	else
		-- Leaving the screen disarms the commit. Coming back to a primed
		-- irreversible button would be a nasty surprise.
		self._confirming = false
	end
end

function PrestigeScreen:Destroy()
	self._maid:DoCleaning()
end

return PrestigeScreen
