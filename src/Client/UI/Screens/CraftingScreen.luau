--!strict
--[[
	CraftingScreen
	--------------
	Recipes, what they need, and what is stopping you.

	The single most important thing a crafting screen can do is answer "why can't I
	make this?" without the player having to work it out. So every recipe that
	cannot be crafted says so in words, and every missing ingredient is shown with
	the amount short rather than only the amount required — "need 12 more coil wire"
	is actionable, "requires 40 coil wire" is a puzzle.

	Recipes that cannot be crafted are not hidden. A recipe you cannot afford is a
	reason to go and get the materials, which is the entire point of having them.
	Recipes above the player's level are the only thing dimmed, because those are
	the ones no amount of gathering will unlock today.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BTS")
local Theme = require(Shared.Config.Theme)
local Resources = require(Shared.Config.Resources)
local Recipes = require(Shared.Config.Recipes)
local Equipment = require(Shared.Config.Equipment)
local Net = require(Shared.Net)
local Maid = require(Shared.Core.Maid)

local Client = script.Parent.Parent.Parent
local Components = require(Client.UI.Components)

local CraftingScreen = {}
CraftingScreen.__index = CraftingScreen

local LIST_WIDTH = 360

local function resourceName(resourceId: string): string
	local resource = Resources.ById[resourceId]
	return resource and resource.name or resourceId
end

function CraftingScreen.new(parent: Instance, controllers: any)
	local self = setmetatable({
		_maid = Maid.new(),
		_controllers = controllers,
		_category = "equipment",
		_selected = nil,
		_view = nil,
		_quantity = 1,
		_rows = {},
		_detailRows = {},
		_fetching = false,
	}, CraftingScreen)

	self:_build(parent)
	return self
end

function CraftingScreen:_build(parent: Instance)
	local root = Components.Panel({
		parent = parent,
		name = "CraftingScreen",
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
		text = "WORKBENCH",
		size = UDim2.new(0, 260, 1, 0),
		textSize = Theme.Text.title,
		zIndex = header.ZIndex + 1,
	})

	self._categoryLabel = Components.Text({
		parent = header,
		name = "CategoryNote",
		text = "",
		size = UDim2.new(0, 420, 1, 0),
		position = UDim2.new(1, -420, 0, 0),
		textSize = Theme.Text.caption,
		color = Theme.Color.textTertiary,
		alignX = Enum.TextXAlignment.Right,
		zIndex = header.ZIndex + 1,
	})

	local tabs = Components.Container({
		parent = root,
		name = "Tabs",
		size = UDim2.new(0, LIST_WIDTH, 0, 32),
		position = UDim2.fromOffset(Theme.Space.lg, 58),
		zIndex = root.ZIndex + 1,
	})
	Components.List(tabs, { direction = Enum.FillDirection.Horizontal, gap = Theme.Space.xs })

	self._tabButtons = {}
	for index, category in ipairs(Recipes.Categories) do
		local _, button = Components.Button({
			parent = tabs,
			name = category.id,
			text = string.upper(category.name),
			variant = "ghost",
			size = UDim2.fromOffset(84, 28),
			textSize = Theme.Text.caption,
			layoutOrder = index,
			zIndex = tabs.ZIndex + 1,
		})
		self._maid:Add(button.Pressed:Connect(function()
			self:SetCategory(category.id)
		end))
		self._tabButtons[category.id] = button
	end

	self._list = Components.Scroll({
		parent = root,
		name = "List",
		size = UDim2.new(0, LIST_WIDTH, 1, -110),
		position = UDim2.fromOffset(Theme.Space.lg, 96),
		gap = Theme.Space.xs,
		zIndex = root.ZIndex + 1,
	})

	self._status = Components.Text({
		parent = root,
		name = "Status",
		text = "",
		size = UDim2.new(0, LIST_WIDTH, 0, 40),
		position = UDim2.fromOffset(Theme.Space.lg, 110),
		textSize = Theme.Text.body,
		color = Theme.Color.textTertiary,
		wrapped = true,
		zIndex = root.ZIndex + 2,
	})
	self._status.Visible = false

	self:_buildDetail()
end

function CraftingScreen:_buildDetail()
	local left = Theme.Space.lg + LIST_WIDTH + Theme.Space.lg

	local detail = Components.Panel({
		parent = self._root,
		name = "Detail",
		size = UDim2.new(1, -(left + Theme.Space.lg), 1, -(58 + Theme.Space.lg)),
		position = UDim2.fromOffset(left, 58),
		elevation = 1,
		padding = Theme.Space.lg,
		zIndex = self._root.ZIndex + 1,
	})
	self._detail = detail

	self._detailName = Components.Heading({
		parent = detail,
		text = "",
		size = UDim2.new(1, 0, 0, 28),
		textSize = Theme.Text.heading,
		zIndex = detail.ZIndex + 1,
	})

	self._detailDescription = Components.Text({
		parent = detail,
		name = "Description",
		text = "",
		size = UDim2.new(1, 0, 0, 40),
		position = UDim2.fromOffset(0, 30),
		textSize = Theme.Text.body,
		color = Theme.Color.textSecondary,
		alignY = Enum.TextYAlignment.Top,
		wrapped = true,
		zIndex = detail.ZIndex + 1,
	})

	self._detailOutput = Components.Text({
		parent = detail,
		name = "Output",
		text = "",
		size = UDim2.new(1, 0, 0, 18),
		position = UDim2.fromOffset(0, 74),
		textSize = Theme.Text.body,
		font = Theme.Font.medium,
		color = Theme.Color.accent,
		zIndex = detail.ZIndex + 1,
	})

	Components.Text({
		parent = detail,
		name = "CostHeading",
		text = "REQUIRES",
		size = UDim2.new(1, 0, 0, 14),
		position = UDim2.fromOffset(0, 102),
		textSize = Theme.Text.caption,
		font = Theme.Font.medium,
		color = Theme.Color.textTertiary,
		zIndex = detail.ZIndex + 1,
	})

	self._costList = Components.Scroll({
		parent = detail,
		name = "Cost",
		size = UDim2.new(1, 0, 1, -230),
		position = UDim2.fromOffset(0, 122),
		gap = 2,
		zIndex = detail.ZIndex + 1,
	})

	self._blockLabel = Components.Text({
		parent = detail,
		name = "Block",
		text = "",
		size = UDim2.new(1, 0, 0, 34),
		position = UDim2.new(0, 0, 1, -96),
		textSize = Theme.Text.caption,
		color = Theme.Color.warning,
		wrapped = true,
		zIndex = detail.ZIndex + 1,
	})

	local actions = Components.Container({
		parent = detail,
		name = "Actions",
		size = UDim2.new(1, 0, 0, 44),
		position = UDim2.new(0, 0, 1, -44),
		zIndex = detail.ZIndex + 1,
	})
	Components.List(actions, { direction = Enum.FillDirection.Horizontal, gap = Theme.Space.sm })

	local _, craftButton = Components.Button({
		parent = actions,
		name = "Craft",
		text = "CRAFT",
		variant = "primary",
		size = UDim2.fromOffset(200, 42),
		layoutOrder = 1,
		zIndex = actions.ZIndex + 1,
	})
	self._craftButton = craftButton
	self._maid:Add(craftButton.Pressed:Connect(function()
		self:Craft()
	end))

	self._quantityButtons = {}
	for index, amount in ipairs({ 1, 5, 25 }) do
		local _, button = Components.Button({
			parent = actions,
			name = "Qty" .. tostring(amount),
			text = "x" .. tostring(amount),
			variant = "ghost",
			size = UDim2.fromOffset(58, 42),
			textSize = Theme.Text.caption,
			layoutOrder = index + 1,
			zIndex = actions.ZIndex + 1,
		})
		self._maid:Add(button.Pressed:Connect(function()
			self._quantity = amount
			self:_refreshDetail()
		end))
		self._quantityButtons[amount] = button
	end

	self._detailEmpty = Components.Text({
		parent = detail,
		name = "DetailEmpty",
		text = "Select a recipe.",
		size = UDim2.fromScale(1, 1),
		textSize = Theme.Text.body,
		color = Theme.Color.textTertiary,
		alignX = Enum.TextXAlignment.Center,
		zIndex = detail.ZIndex + 3,
	})
end

-- ============================================================================
-- Data
-- ============================================================================

function CraftingScreen:SetView(view: any)
	self._view = view

	local recipes = self:_recipesForCategory(self._category)
	local stillPresent = false
	for _, recipe in ipairs(recipes) do
		if recipe.id == self._selected then
			stillPresent = true
			break
		end
	end
	if not stillPresent then
		self._selected = recipes[1] and recipes[1].id or nil
	end

	self:Refresh()
end

function CraftingScreen:SetProfile(profile: any)
	self._profile = profile
end

function CraftingScreen:SetCategory(categoryId: string)
	if self._category == categoryId then
		return
	end
	self._category = categoryId

	local recipes = self:_recipesForCategory(categoryId)
	self._selected = recipes[1] and recipes[1].id or nil
	self:Refresh()
end

function CraftingScreen:_recipesForCategory(categoryId: string): { any }
	if not self._view then
		return {}
	end

	local out = {}
	for _, recipe in ipairs(self._view.recipes or {}) do
		if recipe.category == categoryId then
			table.insert(out, recipe)
		end
	end

	table.sort(out, function(a, b)
		-- Craftable first, then by level, so the useful half of the list is at the
		-- top rather than interleaved with things that are out of reach.
		if a.canCraft ~= b.canCraft then
			return a.canCraft
		end
		if (a.requiredLevel or 0) ~= (b.requiredLevel or 0) then
			return (a.requiredLevel or 0) < (b.requiredLevel or 0)
		end
		return a.name < b.name
	end)

	return out
end

function CraftingScreen:_findRecipe(recipeId: string?): any?
	if not recipeId or not self._view then
		return nil
	end
	for _, recipe in ipairs(self._view.recipes or {}) do
		if recipe.id == recipeId then
			return recipe
		end
	end
	return nil
end

function CraftingScreen:Select(recipeId: string)
	self._selected = recipeId
	self:Refresh()
end

function CraftingScreen:Craft()
	local recipe = self:_findRecipe(self._selected)
	if not recipe or not recipe.canCraft then
		return
	end

	-- Equipment is one at a time on the server; sending a batch it will silently
	-- reduce would leave the quantity buttons lying to the player.
	local quantity = recipe.output.kind == "equipment" and 1 or self._quantity

	Net.FireServer("RequestCraft", recipe.id, quantity)
	Components.Pulse(self._detail, 1.005, "fast")

	-- The result changes stock, which changes what else is craftable, so the panel
	-- is re-read rather than patched locally.
	task.delay(0.35, function()
		self:RequestRefresh()
	end)
end

function CraftingScreen:RequestRefresh()
	if self._fetching then
		return
	end
	self._fetching = true

	task.spawn(function()
		local view = Net.InvokeServer("RequestCrafting")
		self._fetching = false
		if view then
			self:SetView(view)
		end
	end)
end

function CraftingScreen:OnOpened()
	self:RequestRefresh()
end

-- ============================================================================
-- Rendering
-- ============================================================================

function CraftingScreen:Refresh()
	for categoryId, button in pairs(self._tabButtons) do
		button:SetEnabled(categoryId ~= self._category)
	end

	for _, category in ipairs(Recipes.Categories) do
		if category.id == self._category then
			self._categoryLabel.Text = category.description
		end
	end

	self:_refreshList()
	self:_refreshDetail()
end

function CraftingScreen:_refreshList()
	for _, row in ipairs(self._rows) do
		row:Destroy()
	end
	self._rows = {}

	local recipes = self:_recipesForCategory(self._category)

	self._status.Visible = #recipes == 0
	if #recipes == 0 then
		self._status.Text = self._view and "Nothing in this category yet." or "Loading…"
		return
	end

	for index, recipe in ipairs(recipes) do
		local selected = recipe.id == self._selected
		local locked = recipe.requiredLevel
			and self._profile
			and (self._profile.level or 1) < recipe.requiredLevel

		local row = Components.Panel({
			parent = self._list,
			name = recipe.id,
			size = UDim2.new(1, -8, 0, 48),
			elevation = selected and 2 or 1,
			padding = Theme.Space.sm,
			zIndex = self._list.ZIndex + 1,
		})
		row.LayoutOrder = index

		local nameColor
		if locked then
			nameColor = Theme.Color.textDisabled
		elseif recipe.canCraft then
			nameColor = Theme.Color.textPrimary
		else
			nameColor = Theme.Color.textSecondary
		end

		Components.Text({
			parent = row,
			name = "Name",
			text = recipe.name,
			size = UDim2.new(1, -70, 0, 18),
			textSize = Theme.Text.body,
			font = selected and Theme.Font.medium or Theme.Font.regular,
			color = nameColor,
			zIndex = row.ZIndex + 1,
		})

		Components.Text({
			parent = row,
			name = "Sub",
			-- The block reason goes on the row itself, so scanning the list already
			-- answers "why not?" without a click.
			text = recipe.canCraft and (recipe.description or "") or (recipe.blockText or ""),
			size = UDim2.new(1, -70, 0, 14),
			position = UDim2.fromOffset(0, 20),
			textSize = Theme.Text.caption,
			color = recipe.canCraft and Theme.Color.textTertiary or Theme.Color.warning,
			zIndex = row.ZIndex + 1,
		})

		if recipe.canCraft then
			Components.Text({
				parent = row,
				name = "Ready",
				text = "READY",
				size = UDim2.fromOffset(60, 14),
				position = UDim2.new(1, -60, 0, 2),
				textSize = Theme.Text.caption,
				font = Theme.Font.medium,
				color = Theme.Color.success,
				alignX = Enum.TextXAlignment.Right,
				zIndex = row.ZIndex + 1,
			})
		elseif recipe.requiredLevel then
			Components.Text({
				parent = row,
				name = "Level",
				text = ("LV %d"):format(recipe.requiredLevel),
				size = UDim2.fromOffset(60, 14),
				position = UDim2.new(1, -60, 0, 2),
				textSize = Theme.Text.caption,
				color = Theme.Color.textTertiary,
				alignX = Enum.TextXAlignment.Right,
				zIndex = row.ZIndex + 1,
			})
		end

		local button = Instance.new("TextButton")
		button.Name = "Hit"
		button.Size = UDim2.fromScale(1, 1)
		button.BackgroundTransparency = 1
		button.Text = ""
		button.ZIndex = row.ZIndex + 5
		button.Parent = row
		self._maid:Add(button.Activated:Connect(function()
			self:Select(recipe.id)
		end))

		table.insert(self._rows, row)
	end
end

function CraftingScreen:_refreshDetail()
	local recipe = self:_findRecipe(self._selected)

	self._detailEmpty.Visible = recipe == nil
	for _, child in ipairs(self._detail:GetChildren()) do
		if child:IsA("GuiObject") and child.Name ~= "DetailEmpty" then
			child.Visible = recipe ~= nil
		end
	end

	if not recipe then
		return
	end

	self._detailName.Text = recipe.name
	self._detailDescription.Text = recipe.description or ""
	self._detailOutput.Text = "Produces: " .. self:_describeOutput(recipe.output)

	local isEquipment = recipe.output.kind == "equipment"
	local quantity = isEquipment and 1 or self._quantity

	for amount, button in pairs(self._quantityButtons) do
		-- Equipment is one at a time, so the quantity buttons are disabled rather
		-- than removed: their absence would read as a layout bug.
		button:SetEnabled(not isEquipment and amount ~= self._quantity)
	end

	self:_refreshCost(recipe, quantity)

	self._blockLabel.Text = recipe.canCraft and "" or (recipe.blockText or "")
	self._craftButton:SetText(quantity > 1 and ("CRAFT x" .. tostring(quantity)) or "CRAFT")
	self._craftButton:SetEnabled(recipe.canCraft == true)
end

function CraftingScreen:_refreshCost(recipe: any, quantity: number)
	for _, row in ipairs(self._detailRows) do
		row:Destroy()
	end
	self._detailRows = {}

	local stock = (self._view and self._view.resources) or {}
	local order = 0

	for resourceId, amount in pairs(recipe.ingredients or {}) do
		order += 1
		local needed = amount * quantity
		local held = stock[resourceId] or 0
		local short = math.max(0, needed - held)

		local row = Components.Container({
			parent = self._costList,
			name = resourceId,
			size = UDim2.new(1, -8, 0, 18),
			zIndex = self._costList.ZIndex + 1,
		})
		row.LayoutOrder = order

		Components.Text({
			parent = row,
			name = "Name",
			text = resourceName(resourceId),
			size = UDim2.new(1, -170, 1, 0),
			textSize = Theme.Text.caption,
			color = short > 0 and Theme.Color.warning or Theme.Color.textSecondary,
			zIndex = row.ZIndex + 1,
		})

		Components.Text({
			parent = row,
			name = "Amount",
			-- The shortfall, not the requirement: "need 12 more" is actionable,
			-- "requires 40" is a subtraction the player has to do themselves.
			text = short > 0
				and ("%s / %s   (need %s more)"):format(
					Theme.FormatNumber(held), Theme.FormatNumber(needed), Theme.FormatNumber(short))
				or ("%s / %s"):format(Theme.FormatNumber(held), Theme.FormatNumber(needed)),
			size = UDim2.fromOffset(170, 18),
			position = UDim2.new(1, -170, 0, 0),
			textSize = Theme.Text.caption,
			font = Theme.Font.medium,
			color = short > 0 and Theme.Color.danger or Theme.Color.success,
			alignX = Enum.TextXAlignment.Right,
			zIndex = row.ZIndex + 1,
		})

		table.insert(self._detailRows, row)
	end

	for currency, amount in pairs(recipe.cost or {}) do
		order += 1
		local needed = amount * quantity
		local held = self._profile and (self._profile[currency] or 0) or 0

		local row = Components.Container({
			parent = self._costList,
			name = currency,
			size = UDim2.new(1, -8, 0, 18),
			zIndex = self._costList.ZIndex + 1,
		})
		row.LayoutOrder = order

		Components.Text({
			parent = row,
			name = "Name",
			text = string.upper(currency),
			size = UDim2.new(1, -170, 1, 0),
			textSize = Theme.Text.caption,
			color = Theme.Color[currency] or Theme.Color.textSecondary,
			zIndex = row.ZIndex + 1,
		})

		Components.Text({
			parent = row,
			name = "Amount",
			text = ("%s / %s"):format(Theme.FormatNumber(held), Theme.FormatNumber(needed)),
			size = UDim2.fromOffset(170, 18),
			position = UDim2.new(1, -170, 0, 0),
			textSize = Theme.Text.caption,
			font = Theme.Font.medium,
			color = held >= needed and Theme.Color.success or Theme.Color.danger,
			alignX = Enum.TextXAlignment.Right,
			zIndex = row.ZIndex + 1,
		})

		table.insert(self._detailRows, row)
	end
end

function CraftingScreen:_describeOutput(output: any): string
	if not output then
		return "—"
	end

	if output.kind == "equipment" then
		local base = Equipment.BaseById[output.baseId]
		local rarity = output.rarity and Theme.GetRarity(output.rarity)
		return ("%s%s"):format(
			base and base.name or tostring(output.baseId),
			rarity and ("  ·  " .. rarity.label) or ""
		)
	end

	if output.kind == "resource" then
		return ("%d × %s"):format(output.quantity or 1, resourceName(output.resourceId))
	end

	if output.kind == "consumable" then
		local consumable = Recipes.Consumables[output.consumableId]
		return ("%d × %s"):format(output.quantity or 1, consumable and consumable.name or tostring(output.consumableId))
	end

	return "—"
end

function CraftingScreen:SetVisible(visible: boolean)
	self._root.Visible = visible
	if visible then
		self:Refresh()
		Components.FadeIn(self._root, { duration = "fast" })
	end
end

function CraftingScreen:Destroy()
	self._maid:DoCleaning()
end

return CraftingScreen
