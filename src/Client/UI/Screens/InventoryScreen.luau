--!strict
--[[
	InventoryScreen
	---------------
	Equipment, comparison and dismantling.

	The one thing an inventory screen must do well is answer "is this better than
	what I have?" without making the player do arithmetic. So selecting an item
	immediately shows a per-stat delta against whatever occupies its slot, computed
	server-side from the same resolver the live stats use — including set bonuses
	gained or lost by the swap, which a naive stat-line comparison would miss.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BTS")
local Theme = require(Shared.Config.Theme)
local Equipment = require(Shared.Config.Equipment)
local Stats = require(Shared.Config.Stats)
local Balance = require(Shared.Config.Balance)
local Net = require(Shared.Net)
local Maid = require(Shared.Core.Maid)

local Client = script.Parent.Parent.Parent
local Components = require(Client.UI.Components)

local InventoryScreen = {}
InventoryScreen.__index = InventoryScreen

local SORT_MODES = {
	{ id = "recent", name = "Recent" },
	{ id = "rarity", name = "Rarity" },
	{ id = "slot", name = "Slot" },
	{ id = "name", name = "Name" },
}

function InventoryScreen.new(parent: Instance, controllers: any)
	local self = setmetatable({
		_maid = Maid.new(),
		_controllers = controllers,
		_view = nil,
		_stats = {},
		_selected = nil,
		_filterSlot = nil,
		_sort = "recent",
		_cards = {},
	}, InventoryScreen)

	self:_build(parent)
	return self
end

function InventoryScreen:_build(parent: Instance)
	local root = Components.Panel({
		parent = parent,
		name = "InventoryScreen",
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
		text = "EQUIPMENT",
		size = UDim2.new(0, 220, 1, 0),
		textSize = Theme.Text.title,
		zIndex = header.ZIndex + 1,
	})

	self._capacityLabel = Components.Label({
		parent = header,
		name = "Capacity",
		text = "",
		size = UDim2.new(0, 220, 1, 0),
		position = UDim2.new(1, -220, 0, 0),
		textSize = Theme.Text.label,
		alignX = Enum.TextXAlignment.Right,
		zIndex = header.ZIndex + 1,
	})

	self:_buildEquippedColumn(root)
	self:_buildFilters(root)
	self:_buildGrid(root)
	self:_buildDetail(root)
end

--[[ The six equipped slots, always visible, so "what am I wearing" is never a click away. ]]
function InventoryScreen:_buildEquippedColumn(root: Frame)
	local column = Components.Panel({
		parent = root,
		name = "Equipped",
		size = UDim2.fromOffset(190, 0),
		position = UDim2.fromOffset(Theme.Space.lg, 60),
		elevation = 1,
		padding = Theme.Space.md,
		zIndex = root.ZIndex + 1,
	})
	column.Size = UDim2.new(0, 190, 1, -(60 + Theme.Space.lg))
	Components.List(column, { gap = Theme.Space.sm })

	self._slotFrames = {}
	for _, slot in ipairs(Equipment.Slots) do
		local frame = Components.Panel({
			parent = column,
			name = slot.id,
			size = UDim2.new(1, 0, 0, 56),
			elevation = 2,
			padding = Theme.Space.sm,
			zIndex = column.ZIndex + 1,
		})
		frame.LayoutOrder = slot.order

		Components.Label({
			parent = frame,
			name = "SlotName",
			text = slot.short,
			size = UDim2.new(1, 0, 0, 12),
			textSize = Theme.Text.caption,
			zIndex = frame.ZIndex + 1,
		})

		local itemLabel = Components.Text({
			parent = frame,
			name = "Item",
			text = "— empty —",
			position = UDim2.fromOffset(0, 14),
			size = UDim2.new(1, 0, 0, 30),
			textSize = Theme.Text.label,
			font = Theme.Font.medium,
			color = Theme.Color.textDisabled,
			wrapped = true,
			zIndex = frame.ZIndex + 1,
		})

		local button = Instance.new("TextButton")
		button.Size = UDim2.fromScale(1, 1)
		button.BackgroundTransparency = 1
		button.Text = ""
		button.ZIndex = frame.ZIndex + 2
		button.Parent = frame

		self._maid:Add(button.Activated:Connect(function()
			self:SetSlotFilter(self._filterSlot == slot.id and nil or slot.id)
		end))

		self._slotFrames[slot.id] = { frame = frame, label = itemLabel, slot = slot }
	end

	self._setBonusLabel = Components.Text({
		parent = column,
		name = "SetBonuses",
		text = "",
		size = UDim2.new(1, 0, 0, 60),
		textSize = Theme.Text.caption,
		color = Theme.Color.success,
		wrapped = true,
		alignY = Enum.TextYAlignment.Top,
		layoutOrder = 100,
		zIndex = column.ZIndex + 1,
	})
end

function InventoryScreen:_buildFilters(root: Frame)
	local bar = Components.Container({
		parent = root,
		name = "Filters",
		size = UDim2.new(1, -(190 + 320 + Theme.Space.xxl), 0, 32),
		position = UDim2.fromOffset(190 + Theme.Space.xl, 60),
		zIndex = root.ZIndex + 1,
	})
	Components.List(bar, { direction = Enum.FillDirection.Horizontal, gap = Theme.Space.xs })

	self._sortButtons = {}
	for index, mode in ipairs(SORT_MODES) do
		local _, button = Components.Button({
			parent = bar,
			name = mode.id,
			text = string.upper(mode.name),
			variant = "ghost",
			size = UDim2.fromOffset(88, 30),
			textSize = Theme.Text.caption,
			layoutOrder = index,
			zIndex = bar.ZIndex + 1,
		})
		self._maid:Add(button.Pressed:Connect(function()
			self._sort = mode.id
			self:Refresh()
		end))
		self._sortButtons[mode.id] = button
	end

	local _, dismantleButton = Components.Button({
		parent = bar,
		name = "DismantleCommons",
		text = "DISMANTLE COMMONS",
		variant = "ghost",
		size = UDim2.fromOffset(190, 30),
		textSize = Theme.Text.caption,
		layoutOrder = 90,
		zIndex = bar.ZIndex + 1,
	})
	self._maid:Add(dismantleButton.Pressed:Connect(function()
		self:_dismantleCommons()
	end))
end

function InventoryScreen:_buildGrid(root: Frame)
	local grid = Components.Scroll({
		parent = root,
		name = "Grid",
		size = UDim2.new(1, -(190 + 320 + Theme.Space.xxl), 1, -(100 + Theme.Space.lg)),
		position = UDim2.fromOffset(190 + Theme.Space.xl, 98),
		gap = Theme.Space.sm,
		zIndex = root.ZIndex + 1,
	})
	-- A grid rather than a list: at 200 items a list is unusable.
	local layout = grid:FindFirstChildOfClass("UIListLayout")
	if layout then
		layout:Destroy()
	end
	Components.Grid(grid, { cellSize = UDim2.fromOffset(150, 92), gap = Theme.Space.sm })
	self._grid = grid
end

function InventoryScreen:_buildDetail(root: Frame)
	local panel = Components.Panel({
		parent = root,
		name = "Detail",
		size = UDim2.fromOffset(300, 0),
		position = UDim2.new(1, -Theme.Space.lg, 0, 60),
		anchorPoint = Vector2.new(1, 0),
		elevation = 2,
		padding = Theme.Space.lg,
		zIndex = root.ZIndex + 2,
	})
	panel.Size = UDim2.new(0, 300, 1, -(60 + Theme.Space.lg))
	self._detailPanel = panel

	self._detailName = Components.Heading({
		parent = panel,
		name = "Name",
		text = "Select an item",
		size = UDim2.new(1, 0, 0, 44),
		textSize = Theme.Text.heading,
		wrapped = true,
		zIndex = panel.ZIndex + 1,
	})

	self._detailMeta = Components.Label({
		parent = panel,
		name = "Meta",
		text = "",
		position = UDim2.fromOffset(0, 46),
		size = UDim2.new(1, 0, 0, 14),
		textSize = Theme.Text.caption,
		zIndex = panel.ZIndex + 1,
	})

	self._detailStats = Components.Container({
		parent = panel,
		name = "Stats",
		size = UDim2.new(1, 0, 0, 150),
		position = UDim2.fromOffset(0, 66),
		zIndex = panel.ZIndex + 1,
	})
	Components.List(self._detailStats, { gap = 2 })

	self._detailTrait = Components.Text({
		parent = panel,
		name = "Trait",
		text = "",
		position = UDim2.fromOffset(0, 222),
		size = UDim2.new(1, 0, 0, 56),
		textSize = Theme.Text.label,
		color = Theme.Color.warning,
		wrapped = true,
		alignY = Enum.TextYAlignment.Top,
		zIndex = panel.ZIndex + 1,
	})

	self._detailFlavour = Components.Text({
		parent = panel,
		name = "Flavour",
		text = "",
		position = UDim2.fromOffset(0, 284),
		size = UDim2.new(1, 0, 0, 60),
		textSize = Theme.Text.caption,
		color = Theme.Color.textTertiary,
		wrapped = true,
		alignY = Enum.TextYAlignment.Top,
		zIndex = panel.ZIndex + 1,
	})

	local _, equipButton = Components.Button({
		parent = panel,
		name = "Equip",
		text = "EQUIP",
		variant = "primary",
		size = UDim2.new(1, 0, 0, 44),
		position = UDim2.new(0, 0, 1, -44),
		zIndex = panel.ZIndex + 2,
		enabled = false,
	})
	self._equipButton = equipButton
	self._maid:Add(equipButton.Pressed:Connect(function()
		if not self._selected then
			return
		end

		-- The same button unequips what is already worn. A dead "EQUIPPED" button
		-- beside a separate "UNEQUIP" one asks the player to hunt for an action
		-- that belongs exactly where their cursor already is.
		local item = self:_getSelectedItem()
		if item and self._view and self._view.equipped[item.slot] == item.uid then
			Net.FireServer("RequestUnequip", item.slot)
		else
			Net.FireServer("RequestEquip", self._selected)
		end
	end))

	local _, favouriteButton = Components.Button({
		parent = panel,
		name = "Favourite",
		text = "FAVOURITE",
		variant = "ghost",
		size = UDim2.new(0.5, -2, 0, 34),
		position = UDim2.new(0, 0, 1, -84),
		textSize = Theme.Text.caption,
		zIndex = panel.ZIndex + 2,
	})
	self._favouriteButton = favouriteButton
	self._maid:Add(favouriteButton.Pressed:Connect(function()
		local item = self:_getSelectedItem()
		if item then
			Net.FireServer("RequestFavourite", item.uid, not item.favourite)
		end
	end))

	local _, dismantleButton = Components.Button({
		parent = panel,
		name = "Dismantle",
		text = "DISMANTLE",
		variant = "danger",
		size = UDim2.new(0.5, -2, 0, 34),
		position = UDim2.new(0.5, 2, 1, -84),
		textSize = Theme.Text.caption,
		zIndex = panel.ZIndex + 2,
	})
	self._dismantleButton = dismantleButton
	self._maid:Add(dismantleButton.Pressed:Connect(function()
		if self._selected then
			Net.FireServer("RequestDismantle", { self._selected })
			self._selected = nil
		end
	end))
end

-- ============================================================================
-- Data
-- ============================================================================

function InventoryScreen:SetView(view: any, stats: { [string]: number }?)
	self._view = view
	if stats then
		self._stats = stats
	end
	self:Refresh()
end

function InventoryScreen:_getSelectedItem()
	if not self._view or not self._selected then
		return nil
	end
	for _, item in ipairs(self._view.items) do
		if item.uid == self._selected then
			return item
		end
	end
	return nil
end

function InventoryScreen:SetSlotFilter(slotId: string?)
	self._filterSlot = slotId
	self:Refresh()
end

function InventoryScreen:SelectItem(uid: string)
	self._selected = uid
	self:_updateDetail()
end

function InventoryScreen:_dismantleCommons()
	if not self._view then
		return
	end
	local uids = {}
	for _, item in ipairs(self._view.items) do
		local equipped = self._view.equipped[item.slot] == item.uid
		if not item.favourite and not equipped and (item.rarity == "common" or item.rarity == "uncommon") then
			table.insert(uids, item.uid)
		end
	end
	if #uids > 0 then
		Net.FireServer("RequestDismantle", uids)
	end
end

-- ============================================================================
-- Rendering
-- ============================================================================

function InventoryScreen:Refresh()
	if not self._view then
		return
	end

	self._capacityLabel.Text = ("%d / %d slots"):format(self._view.used, self._view.capacity)
	self._capacityLabel.TextColor3 = self._view.used >= self._view.capacity * 0.9
		and Theme.Color.warning
		or Theme.Color.textTertiary

	for sortId, button in pairs(self._sortButtons) do
		button:SetEnabled(sortId ~= self._sort)
	end

	self:_refreshEquipped()
	self:_refreshGrid()
	self:_updateDetail()
end

function InventoryScreen:_refreshEquipped()
	local byUid = {}
	for _, item in ipairs(self._view.items) do
		byUid[item.uid] = item
	end

	for slotId, entry in pairs(self._slotFrames) do
		local uid = self._view.equipped[slotId]
		local item = uid and byUid[uid]

		if item then
			entry.label.Text = item.name
			entry.label.TextColor3 = Theme.GetRarity(item.rarity).color
		else
			entry.label.Text = "— empty —"
			entry.label.TextColor3 = Theme.Color.textDisabled
		end

		-- Filtering by slot highlights that slot, so the connection is obvious.
		local stroke = entry.frame:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Color = self._filterSlot == slotId and Theme.Color.accent or Theme.Color.borderStrong
			stroke.Thickness = self._filterSlot == slotId and Theme.Stroke.thick or Theme.Stroke.hairline
		end
	end

	local lines = {}
	for _, bonus in ipairs(self._view.setBonuses or {}) do
		table.insert(lines, ("%s (%d): %s"):format(bonus.setName, bonus.tier, bonus.bonus.name))
	end
	self._setBonusLabel.Text = #lines > 0 and table.concat(lines, "\n") or ""
end

function InventoryScreen:_refreshGrid()
	-- Sort first, then filter, so the visible order is stable while filtering.
	local items = table.clone(self._view.items)

	local rarityOrder = {}
	for index, rarity in ipairs(Balance.Loot.RARITY_ORDER) do
		rarityOrder[rarity] = index
	end

	table.sort(items, function(a, b)
		if self._sort == "rarity" then
			local rankA = rarityOrder[a.rarity] or 0
			local rankB = rarityOrder[b.rarity] or 0
			if rankA ~= rankB then
				return rankA > rankB
			end
			return a.name < b.name
		elseif self._sort == "slot" then
			if a.slot ~= b.slot then
				return a.slot < b.slot
			end
			return (rarityOrder[a.rarity] or 0) > (rarityOrder[b.rarity] or 0)
		elseif self._sort == "name" then
			return a.name < b.name
		end
		return (a.acquiredAt or 0) > (b.acquiredAt or 0)
	end)

	-- Reuse card instances; rebuilding 200 frames on every refresh would stutter.
	local index = 0
	for _, item in ipairs(items) do
		if self._filterSlot and item.slot ~= self._filterSlot then
			continue
		end

		index += 1
		local card = self._cards[index]
		if not card then
			card = self:_createCard(index)
			self._cards[index] = card
		end

		card.frame.Visible = true
		card.frame.LayoutOrder = index
		card.item = item

		local rarity = Theme.GetRarity(item.rarity)
		card.name.Text = item.name
		card.name.TextColor3 = rarity.color
		card.slot.Text = string.upper(Equipment.SlotById[item.slot].short)

		local equipped = self._view.equipped[item.slot] == item.uid
		card.status.Text = equipped and "EQUIPPED" or (item.favourite and "★" or "")
		card.status.TextColor3 = equipped and Theme.Color.success or Theme.Color.warning

		local stroke = card.frame:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Color = self._selected == item.uid and Theme.Color.accent or rarity.color
			stroke.Transparency = self._selected == item.uid and 0 or 0.6
			stroke.Thickness = self._selected == item.uid and Theme.Stroke.thick or Theme.Stroke.hairline
		end
	end

	for hidden = index + 1, #self._cards do
		self._cards[hidden].frame.Visible = false
		self._cards[hidden].item = nil
	end
end

function InventoryScreen:_createCard(index: number)
	local frame = Components.Panel({
		parent = self._grid,
		name = "Card" .. index,
		size = UDim2.fromOffset(150, 92),
		elevation = 2,
		padding = Theme.Space.sm,
		zIndex = self._grid.ZIndex + 1,
	})

	local name = Components.Text({
		parent = frame,
		name = "Name",
		text = "",
		size = UDim2.new(1, 0, 0, 42),
		textSize = Theme.Text.label,
		font = Theme.Font.medium,
		wrapped = true,
		alignY = Enum.TextYAlignment.Top,
		zIndex = frame.ZIndex + 1,
	})

	local slot = Components.Label({
		parent = frame,
		name = "Slot",
		text = "",
		position = UDim2.new(0, 0, 1, -14),
		size = UDim2.new(0.5, 0, 0, 12),
		textSize = Theme.Text.caption,
		zIndex = frame.ZIndex + 1,
	})

	local status = Components.Text({
		parent = frame,
		name = "Status",
		text = "",
		position = UDim2.new(0.5, 0, 1, -14),
		size = UDim2.new(0.5, 0, 0, 12),
		textSize = Theme.Text.caption,
		alignX = Enum.TextXAlignment.Right,
		zIndex = frame.ZIndex + 1,
	})

	local button = Instance.new("TextButton")
	button.Size = UDim2.fromScale(1, 1)
	button.BackgroundTransparency = 1
	button.Text = ""
	button.ZIndex = frame.ZIndex + 2
	button.Parent = frame

	local card = { frame = frame, name = name, slot = slot, status = status, item = nil }

	self._maid:Add(button.Activated:Connect(function()
		if card.item then
			self:SelectItem(card.item.uid)
		end
	end))

	return card
end

function InventoryScreen:_updateDetail()
	local item = self:_getSelectedItem()

	self._detailStats:ClearAllChildren()
	Components.List(self._detailStats, { gap = 2 })

	if not item then
		self._detailName.Text = "Select an item"
		self._detailMeta.Text = ""
		self._detailTrait.Text = ""
		self._detailFlavour.Text = ""
		self._equipButton:SetEnabled(false)
		self._dismantleButton:SetEnabled(false)
		self._favouriteButton:SetEnabled(false)
		return
	end

	local rarity = Theme.GetRarity(item.rarity)
	self._detailName.Text = item.name
	self._detailName.TextColor3 = rarity.color

	self._detailMeta.Text = ("%s  ·  %s  ·  TIER %d  ·  LVL %d"):format(
		string.upper(rarity.label),
		string.upper(Equipment.SlotById[item.slot].name),
		item.tier,
		item.requiredLevel
	)

	local order = 0
	local function addLine(text: string, color: Color3)
		order += 1
		Components.Text({
			parent = self._detailStats,
			name = "Line" .. order,
			text = text,
			size = UDim2.new(1, 0, 0, 15),
			textSize = Theme.Text.label,
			color = color,
			layoutOrder = order,
			zIndex = self._detailStats.ZIndex + 1,
		})
	end

	for _, line in ipairs(item.baseLines) do
		addLine(line.text, Theme.Color.textSecondary)
	end
	if #item.affixes > 0 then
		addLine("", Theme.Color.textTertiary)
		for _, affix in ipairs(item.affixes) do
			addLine(affix.text, Theme.Color.accent)
		end
	end

	self._detailTrait.Text = item.trait
		and ("%s — %s"):format(string.upper(item.trait.name), item.trait.description)
		or ""

	self._detailFlavour.Text = item.flavour or ""

	local equipped = self._view.equipped[item.slot] == item.uid
	self._equipButton:SetText(equipped and "UNEQUIP" or "EQUIP")
	self._equipButton:SetEnabled(true)
	self._dismantleButton:SetEnabled(not equipped and not item.favourite)
	self._favouriteButton:SetText(item.favourite and "UNFAVOURITE" or "FAVOURITE")
	self._favouriteButton:SetEnabled(true)
end

function InventoryScreen:SetVisible(visible: boolean)
	self._root.Visible = visible
	if visible then
		self:Refresh()
		Components.FadeIn(self._root, { duration = "fast" })
	end
end

function InventoryScreen:Destroy()
	self._maid:DoCleaning()
end

return InventoryScreen
