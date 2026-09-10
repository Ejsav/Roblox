--!strict
--[[
	UpgradesScreen
	--------------
	The core upgrade tracks.

	The screen's job is to make the next purchase obvious and the one after that
	desirable. So each track shows what one level does *to your actual numbers* —
	not the raw modifier — and, more importantly, what the next milestone unlocks.
	A player should never be buying a decimal; they should be buying toward a
	capability they can name.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BTS")
local Theme = require(Shared.Config.Theme)
local Upgrades = require(Shared.Config.Upgrades)
local Stats = require(Shared.Config.Stats)
local Net = require(Shared.Net)
local Maid = require(Shared.Core.Maid)

local Client = script.Parent.Parent.Parent
local Components = require(Client.UI.Components)

local UpgradesScreen = {}
UpgradesScreen.__index = UpgradesScreen

local CATEGORIES = {
	{ id = "capture", name = "Capture" },
	{ id = "containment", name = "Containment" },
	{ id = "movement", name = "Movement" },
	{ id = "survival", name = "Survival" },
	{ id = "economy", name = "Economy" },
	{ id = "utility", name = "Utility" },
}

function UpgradesScreen.new(parent: Instance, controllers: any)
	local self = setmetatable({
		_maid = Maid.new(),
		_controllers = controllers,
		_rows = {},
		_category = "capture",
		_profile = nil,
		_stats = {},
		_buyAmount = 1,
	}, UpgradesScreen)

	self:_build(parent)
	return self
end

function UpgradesScreen:_build(parent: Instance)
	local root = Components.Panel({
		parent = parent,
		name = "UpgradesScreen",
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
		text = "UPGRADES",
		size = UDim2.new(0, 220, 1, 0),
		textSize = Theme.Text.title,
		zIndex = header.ZIndex + 1,
	})

	self._wattsLabel = Components.Text({
		parent = header,
		name = "Watts",
		text = "0",
		size = UDim2.new(0, 220, 1, 0),
		position = UDim2.new(1, -220, 0, 0),
		textSize = Theme.Text.heading,
		font = Theme.Font.heading,
		color = Theme.Color.watts,
		alignX = Enum.TextXAlignment.Right,
		zIndex = header.ZIndex + 1,
	})

	-- Category tabs.
	local tabs = Components.Container({
		parent = root,
		name = "Tabs",
		size = UDim2.new(1, -Theme.Space.xl, 0, 36),
		position = UDim2.fromOffset(Theme.Space.lg, 56),
		zIndex = root.ZIndex + 1,
	})
	Components.List(tabs, { direction = Enum.FillDirection.Horizontal, gap = Theme.Space.xs })

	self._tabButtons = {}
	for index, category in ipairs(CATEGORIES) do
		local _, button = Components.Button({
			parent = tabs,
			name = category.id,
			text = string.upper(category.name),
			variant = "ghost",
			size = UDim2.fromOffset(120, 34),
			textSize = Theme.Text.label,
			layoutOrder = index,
			zIndex = tabs.ZIndex + 1,
		})
		self._maid:Add(button.Pressed:Connect(function()
			self:SetCategory(category.id)
		end))
		self._tabButtons[category.id] = button
	end

	-- Buy-amount selector. "Buy max" is the single most requested affordance in
	-- any upgrade screen, so it is present from the start rather than added later.
	local amounts = Components.Container({
		parent = root,
		name = "Amounts",
		size = UDim2.fromOffset(240, 30),
		position = UDim2.new(1, -(240 + Theme.Space.lg), 0, 58),
		zIndex = root.ZIndex + 1,
	})
	Components.List(amounts, { direction = Enum.FillDirection.Horizontal, gap = Theme.Space.xs, alignX = Enum.HorizontalAlignment.Right })

	self._amountButtons = {}
	for index, amount in ipairs({ 1, 5, 25, -1 }) do
		local _, button = Components.Button({
			parent = amounts,
			name = "Amount" .. tostring(amount),
			text = amount == -1 and "MAX" or ("x" .. tostring(amount)),
			variant = "ghost",
			size = UDim2.fromOffset(54, 28),
			textSize = Theme.Text.caption,
			layoutOrder = index,
			zIndex = amounts.ZIndex + 1,
		})
		self._maid:Add(button.Pressed:Connect(function()
			self._buyAmount = amount
			self:Refresh()
		end))
		self._amountButtons[amount] = button
	end

	self._list = Components.Scroll({
		parent = root,
		name = "List",
		size = UDim2.new(1, -Theme.Space.xl, 1, -110),
		position = UDim2.fromOffset(Theme.Space.lg, 100),
		gap = Theme.Space.sm,
		zIndex = root.ZIndex + 1,
	})

	self:_buildRows()
end

--[[ One row per track, built once and updated in place. ]]
function UpgradesScreen:_buildRows()
	for index, upgrade in ipairs(Upgrades.List) do
		local row = Components.Panel({
			parent = self._list,
			name = upgrade.id,
			size = UDim2.new(1, -8, 0, 96),
			elevation = 1,
			padding = Theme.Space.md,
			zIndex = self._list.ZIndex + 1,
		})
		row.LayoutOrder = upgrade.order or index

		local title = Components.Text({
			parent = row,
			name = "Title",
			text = upgrade.name,
			size = UDim2.new(1, -180, 0, 20),
			textSize = Theme.Text.body,
			font = Theme.Font.medium,
			zIndex = row.ZIndex + 1,
		})

		local level = Components.Text({
			parent = row,
			name = "Level",
			text = "0",
			size = UDim2.fromOffset(80, 20),
			position = UDim2.new(1, -170, 0, 0),
			textSize = Theme.Text.body,
			font = Theme.Font.heading,
			color = Theme.Color.accent,
			alignX = Enum.TextXAlignment.Right,
			zIndex = row.ZIndex + 1,
		})

		local description = Components.Text({
			parent = row,
			name = "Description",
			text = upgrade.description,
			position = UDim2.fromOffset(0, 22),
			size = UDim2.new(1, -180, 0, 16),
			textSize = Theme.Text.caption,
			color = Theme.Color.textTertiary,
			wrapped = true,
			zIndex = row.ZIndex + 1,
		})

		-- The effect preview: what one level actually does to the player's numbers.
		local preview = Components.Text({
			parent = row,
			name = "Preview",
			text = "",
			position = UDim2.fromOffset(0, 42),
			size = UDim2.new(1, -180, 0, 16),
			textSize = Theme.Text.caption,
			color = Theme.Color.success,
			zIndex = row.ZIndex + 1,
		})

		-- The milestone line: what they are buying toward.
		local milestone = Components.Text({
			parent = row,
			name = "Milestone",
			text = "",
			position = UDim2.fromOffset(0, 60),
			size = UDim2.new(1, -180, 0, 16),
			textSize = Theme.Text.caption,
			color = Theme.Color.warning,
			wrapped = true,
			zIndex = row.ZIndex + 1,
		})

		local progress = select(2, Components.Bar({
			parent = row,
			name = "Progress",
			size = UDim2.new(1, -180, 0, 3),
			position = UDim2.fromOffset(0, 80),
			color = Theme.Color.accentDim,
			zIndex = row.ZIndex + 1,
		}))

		local _, buyButton = Components.Button({
			parent = row,
			name = "Buy",
			text = "BUY",
			variant = "primary",
			size = UDim2.fromOffset(150, 56),
			position = UDim2.new(1, 0, 0.5, 0),
			anchorPoint = Vector2.new(1, 0.5),
			textSize = Theme.Text.label,
			zIndex = row.ZIndex + 2,
		})

		self._maid:Add(buyButton.Pressed:Connect(function()
			self:_purchase(upgrade.id)
		end))

		self._rows[upgrade.id] = {
			upgrade = upgrade,
			frame = row,
			title = title,
			level = level,
			description = description,
			preview = preview,
			milestone = milestone,
			progress = progress,
			buyButton = buyButton,
		}
	end
end

function UpgradesScreen:_purchase(upgradeId: string)
	local row = self._rows[upgradeId]
	if not row or not self._profile then
		return
	end

	local currentLevel = self._profile.upgrades[upgradeId] or 0
	local levels = self._buyAmount

	if levels == -1 then
		local affordable = Upgrades.GetAffordableLevels(upgradeId, currentLevel, self._profile.watts or 0)
		levels = math.max(1, affordable)
	end

	Net.FireServer("RequestPurchaseUpgrade", upgradeId, levels)
	Components.Pulse(row.frame, 1.01, "fast")
end

function UpgradesScreen:SetCategory(categoryId: string)
	self._category = categoryId
	self:Refresh()
end

function UpgradesScreen:SetProfile(profile: any, stats: { [string]: number }?)
	self._profile = profile
	if stats then
		self._stats = stats
	end
	self:Refresh()
end

function UpgradesScreen:Refresh()
	if not self._profile then
		return
	end

	self._wattsLabel.Text = Theme.FormatNumber(self._profile.watts or 0) .. " W"

	for categoryId, button in pairs(self._tabButtons) do
		button:SetEnabled(categoryId ~= self._category)
	end
	for amount, button in pairs(self._amountButtons) do
		button:SetEnabled(amount ~= self._buyAmount)
	end

	for upgradeId, row in pairs(self._rows) do
		local upgrade = row.upgrade
		local visible = upgrade.category == self._category
		row.frame.Visible = visible
		if not visible then
			continue
		end

		local level = self._profile.upgrades[upgradeId] or 0
		local cost = Upgrades.GetCost(upgradeId, level)
		local maxed = level >= upgrade.maxLevel

		row.level.Text = maxed and "MAX" or ("%d / %d"):format(level, upgrade.maxLevel)
		row.level.TextColor3 = maxed and Theme.Color.success or Theme.Color.accent
		row.progress:SetValue(level / upgrade.maxLevel, true)

		-- Effect preview: resolve what one more level does to the live stat, so the
		-- player sees "+2 studs" rather than "+1.8 flat captureRadius".
		local previewParts = {}
		for kind, statMap in pairs(upgrade.perLevel) do
			for statId, amount in pairs(statMap) do
				local stat = Stats.ById[statId]
				if not stat then
					continue
				end
				local before = self._stats[statId] or stat.base
				local after
				if kind == "flat" then
					after = before + amount
				else
					after = before * (1 + amount)
				end
				local text = Stats.FormatDelta(statId, before, after)
				if text ~= "" then
					table.insert(previewParts, ("%s %s"):format(text, stat.name))
				end
			end
		end
		row.preview.Text = maxed and "" or table.concat(previewParts, "   ")

		local milestone, distance = Upgrades.GetNextMilestone(upgradeId, level)
		if milestone then
			row.milestone.Text = ("NEXT (%d more): %s — %s")
				:format(distance, milestone.name, milestone.description)
		else
			row.milestone.Text = ""
		end

		if maxed then
			row.buyButton:SetText("MAXED")
			row.buyButton:SetEnabled(false)
		else
			local levels = self._buyAmount
			local totalCost = cost
			if levels == -1 then
				local affordable, spent = Upgrades.GetAffordableLevels(upgradeId, level, self._profile.watts or 0)
				levels = math.max(1, affordable)
				totalCost = affordable > 0 and spent or cost
			elseif levels > 1 then
				totalCost = 0
				for offset = 0, levels - 1 do
					local stepCost = Upgrades.GetCost(upgradeId, level + offset)
					if stepCost == math.huge then
						break
					end
					totalCost += stepCost
				end
			end

			local affordable = (self._profile.watts or 0) >= totalCost
			row.buyButton:SetText(("%s\n%s W"):format(
				levels > 1 and ("BUY x" .. tostring(levels)) or "BUY",
				Theme.FormatNumber(totalCost)
			))
			row.buyButton:SetEnabled(affordable)
		end
	end
end

function UpgradesScreen:SetVisible(visible: boolean)
	self._root.Visible = visible
	if visible then
		self:Refresh()
		Components.FadeIn(self._root, { duration = "fast" })
	end
end

function UpgradesScreen:Destroy()
	self._maid:DoCleaning()
end

return UpgradesScreen
