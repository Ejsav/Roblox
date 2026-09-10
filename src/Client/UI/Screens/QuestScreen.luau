--!strict
--[[
	QuestScreen
	-----------
	The quest log.

	Two panes, because a quest list and a quest are different things. The left pane
	answers "what could I be doing?" at a glance — one line each, grouped, with the
	tracked quest marked. The right pane answers "what exactly does this want?" for
	the one quest the player has selected, in full: every objective with its own
	progress, what it teaches, what it pays, and the single action that matters.

	The rule the layout is built around is that a player should never have to open
	this screen twice to make a decision. Selecting a quest never costs a round trip;
	everything the detail pane shows arrives in the same QuestUpdate as the list.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BTS")
local Theme = require(Shared.Config.Theme)
local Net = require(Shared.Net)
local Maid = require(Shared.Core.Maid)

local Client = script.Parent.Parent.Parent
local Components = require(Client.UI.Components)

local QuestScreen = {}
QuestScreen.__index = QuestScreen

--[[
	Tab order is deliberate: what you are doing, then what you could take, then the
	two rotating sets. Dailies sit after available quests rather than first, because
	a player who opens this screen mid-run is almost always checking an objective,
	not shopping for a new one.
]]
local TABS = {
	{ id = "active", name = "ACTIVE" },
	{ id = "available", name = "AVAILABLE" },
	{ id = "daily", name = "DAILY" },
	{ id = "weekly", name = "WEEKLY" },
}

local TYPE_COLORS = {
	main = Theme.Color.accent,
	side = Theme.Color.info,
	challenge = Theme.Color.warning,
	daily = Theme.Color.success,
	weekly = Theme.Color.sigils,
}

local LIST_WIDTH = 340

local function typeColor(questType: string?): Color3
	return TYPE_COLORS[questType or ""] or Theme.Color.textSecondary
end

--[[ "2h 14m" / "3d 4h". A reset time is only useful as a countdown. ]]
local function formatCountdown(target: number?): string
	if not target then
		return ""
	end
	local remaining = math.max(0, target - os.time())
	if remaining <= 0 then
		return "resetting"
	end

	local days = math.floor(remaining / 86400)
	local hours = math.floor((remaining % 86400) / 3600)
	local minutes = math.floor((remaining % 3600) / 60)

	if days > 0 then
		return ("%dd %dh"):format(days, hours)
	end
	if hours > 0 then
		return ("%dh %dm"):format(hours, minutes)
	end
	return ("%dm"):format(minutes)
end

function QuestScreen.new(parent: Instance, controllers: any)
	local self = setmetatable({
		_maid = Maid.new(),
		_controllers = controllers,
		_tab = "active",
		_selected = nil,
		_view = nil,
		_profile = nil,
		_rows = {},
		_objectiveRows = {},
	}, QuestScreen)

	self:_build(parent)
	return self
end

function QuestScreen:_build(parent: Instance)
	local root = Components.Panel({
		parent = parent,
		name = "QuestScreen",
		size = UDim2.fromScale(1, 1),
		elevation = 0,
		radius = 0,
		zIndex = Theme.ZIndex.panel,
	})
	self._root = root
	self._maid:Add(root)

	-- ------------------------------------------------------------------ header
	local header = Components.Container({
		parent = root,
		name = "Header",
		size = UDim2.new(1, 0, 0, 56),
		zIndex = root.ZIndex + 1,
	})
	Components.Padding(header, Theme.Space.lg)

	Components.Heading({
		parent = header,
		text = "QUESTS",
		size = UDim2.new(0, 220, 1, 0),
		textSize = Theme.Text.title,
		zIndex = header.ZIndex + 1,
	})

	-- Story progress lives in the header because it is the one number that says
	-- how far through the game the player actually is.
	self._storyLabel = Components.Text({
		parent = header,
		name = "Story",
		text = "",
		size = UDim2.new(0, 300, 0, 18),
		position = UDim2.new(1, -300, 0, 4),
		textSize = Theme.Text.caption,
		color = Theme.Color.textSecondary,
		alignX = Enum.TextXAlignment.Right,
		zIndex = header.ZIndex + 1,
	})

	self._storyBar = select(2, Components.Bar({
		parent = header,
		name = "StoryBar",
		size = UDim2.fromOffset(300, 4),
		position = UDim2.new(1, -300, 0, 26),
		color = Theme.Color.accent,
		zIndex = header.ZIndex + 1,
	}))

	-- -------------------------------------------------------------------- tabs
	local tabs = Components.Container({
		parent = root,
		name = "Tabs",
		size = UDim2.new(0, LIST_WIDTH, 0, 34),
		position = UDim2.fromOffset(Theme.Space.lg, 58),
		zIndex = root.ZIndex + 1,
	})
	Components.List(tabs, { direction = Enum.FillDirection.Horizontal, gap = Theme.Space.xs })

	self._tabButtons = {}
	for index, tab in ipairs(TABS) do
		local _, button = Components.Button({
			parent = tabs,
			name = tab.id,
			text = tab.name,
			variant = "ghost",
			size = UDim2.fromOffset(80, 30),
			textSize = Theme.Text.caption,
			layoutOrder = index,
			zIndex = tabs.ZIndex + 1,
		})
		self._maid:Add(button.Pressed:Connect(function()
			self:SetTab(tab.id)
		end))
		self._tabButtons[tab.id] = button
	end

	self._resetLabel = Components.Text({
		parent = root,
		name = "Reset",
		text = "",
		size = UDim2.fromOffset(LIST_WIDTH, 14),
		position = UDim2.fromOffset(Theme.Space.lg, 92),
		textSize = Theme.Text.caption,
		color = Theme.Color.textTertiary,
		zIndex = root.ZIndex + 1,
	})

	-- -------------------------------------------------------------------- list
	self._list = Components.Scroll({
		parent = root,
		name = "List",
		size = UDim2.new(0, LIST_WIDTH, 1, -124),
		position = UDim2.fromOffset(Theme.Space.lg, 110),
		gap = Theme.Space.xs,
		zIndex = root.ZIndex + 1,
	})

	self._emptyLabel = Components.Text({
		parent = root,
		name = "Empty",
		text = "",
		size = UDim2.new(0, LIST_WIDTH, 0, 40),
		position = UDim2.fromOffset(Theme.Space.lg, 130),
		textSize = Theme.Text.body,
		color = Theme.Color.textTertiary,
		wrapped = true,
		zIndex = root.ZIndex + 2,
	})
	self._emptyLabel.Visible = false

	self:_buildDetail()
end

function QuestScreen:_buildDetail()
	local root = self._root
	local left = Theme.Space.lg + LIST_WIDTH + Theme.Space.lg

	local detail = Components.Panel({
		parent = root,
		name = "Detail",
		size = UDim2.new(1, -(left + Theme.Space.lg), 1, -(58 + Theme.Space.lg)),
		position = UDim2.fromOffset(left, 58),
		elevation = 1,
		padding = Theme.Space.lg,
		zIndex = root.ZIndex + 1,
	})
	self._detail = detail

	self._detailType = Components.Text({
		parent = detail,
		name = "Type",
		text = "",
		size = UDim2.new(1, 0, 0, 14),
		textSize = Theme.Text.caption,
		font = Theme.Font.medium,
		color = Theme.Color.accent,
		zIndex = detail.ZIndex + 1,
	})

	self._detailName = Components.Heading({
		parent = detail,
		text = "",
		size = UDim2.new(1, 0, 0, 30),
		position = UDim2.fromOffset(0, 18),
		textSize = Theme.Text.heading,
		zIndex = detail.ZIndex + 1,
	})

	self._detailGiver = Components.Text({
		parent = detail,
		name = "Giver",
		text = "",
		size = UDim2.new(1, 0, 0, 16),
		position = UDim2.fromOffset(0, 50),
		textSize = Theme.Text.caption,
		color = Theme.Color.textTertiary,
		zIndex = detail.ZIndex + 1,
	})

	self._detailDescription = Components.Text({
		parent = detail,
		name = "Description",
		text = "",
		size = UDim2.new(1, 0, 0, 54),
		position = UDim2.fromOffset(0, 72),
		textSize = Theme.Text.body,
		color = Theme.Color.textSecondary,
		alignY = Enum.TextYAlignment.Top,
		wrapped = true,
		zIndex = detail.ZIndex + 1,
	})

	Components.Text({
		parent = detail,
		name = "ObjectivesHeading",
		text = "OBJECTIVES",
		size = UDim2.new(1, 0, 0, 14),
		position = UDim2.fromOffset(0, 134),
		textSize = Theme.Text.caption,
		font = Theme.Font.medium,
		color = Theme.Color.textTertiary,
		zIndex = detail.ZIndex + 1,
	})

	self._objectiveList = Components.Scroll({
		parent = detail,
		name = "Objectives",
		size = UDim2.new(1, 0, 1, -252),
		position = UDim2.fromOffset(0, 154),
		gap = Theme.Space.xs,
		zIndex = detail.ZIndex + 1,
	})

	-- Rewards sit directly above the action button: the last thing read before the
	-- thing clicked.
	self._rewardsLabel = Components.Text({
		parent = detail,
		name = "Rewards",
		text = "",
		size = UDim2.new(1, 0, 0, 34),
		position = UDim2.new(0, 0, 1, -92),
		textSize = Theme.Text.caption,
		color = Theme.Color.watts,
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

	local _, primary = Components.Button({
		parent = actions,
		name = "Primary",
		text = "TRACK",
		variant = "primary",
		size = UDim2.fromOffset(200, 42),
		layoutOrder = 1,
		zIndex = actions.ZIndex + 1,
	})
	self._primaryButton = primary
	self._maid:Add(primary.Pressed:Connect(function()
		self:_onPrimary()
	end))

	local _, secondary = Components.Button({
		parent = actions,
		name = "Secondary",
		text = "ABANDON",
		variant = "ghost",
		size = UDim2.fromOffset(140, 42),
		layoutOrder = 2,
		zIndex = actions.ZIndex + 1,
	})
	self._secondaryButton = secondary
	self._maid:Add(secondary.Pressed:Connect(function()
		self:_onSecondary()
	end))

	self._detailEmpty = Components.Text({
		parent = detail,
		name = "DetailEmpty",
		text = "Select a quest.",
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

function QuestScreen:SetView(view: any)
	self._view = view

	-- Keep the selection if it still exists; otherwise fall back to the tracked
	-- quest, then to the first row. Losing your place because a daily rolled over
	-- is exactly the kind of small rudeness that makes a screen annoying.
	local entries = self:_entriesForTab(self._tab)
	local stillPresent = false
	for _, entry in ipairs(entries) do
		if entry.id == self._selected then
			stillPresent = true
			break
		end
	end

	if not stillPresent then
		self._selected = view.tracked
		for _, entry in ipairs(entries) do
			if entry.id == self._selected then
				stillPresent = true
				break
			end
		end
		if not stillPresent then
			self._selected = entries[1] and entries[1].id or nil
		end
	end

	self:Refresh()
end

function QuestScreen:SetProfile(profile: any)
	self._profile = profile
end

function QuestScreen:SetTab(tabId: string)
	if self._tab == tabId then
		return
	end
	self._tab = tabId

	local entries = self:_entriesForTab(tabId)
	self._selected = entries[1] and entries[1].id or nil
	self:Refresh()
end

--[[
	The rows for a tab. Daily and weekly sets arrive as id lists rather than full
	quest views, so they are resolved against the active and available lists — a
	daily the player has accepted is an active quest that also happens to be daily.
]]
function QuestScreen:_entriesForTab(tabId: string): { any }
	local view = self._view
	if not view then
		return {}
	end

	if tabId == "active" then
		return view.active or {}
	end

	if tabId == "available" then
		return view.available or {}
	end

	local ids = tabId == "daily" and view.daily or view.weekly
	if not ids then
		return {}
	end

	local byId = {}
	for _, entry in ipairs(view.active or {}) do
		byId[entry.id] = entry
	end
	for _, entry in ipairs(view.available or {}) do
		byId[entry.id] = byId[entry.id] or entry
	end

	local out = {}
	for _, questId in ipairs(ids) do
		local entry = byId[questId]
		if entry then
			table.insert(out, entry)
		end
	end
	return out
end

function QuestScreen:_isActive(questId: string): boolean
	for _, entry in ipairs((self._view and self._view.active) or {}) do
		if entry.id == questId then
			return true
		end
	end
	return false
end

function QuestScreen:_findEntry(questId: string?): any?
	if not questId then
		return nil
	end
	for _, entry in ipairs(self:_entriesForTab(self._tab)) do
		if entry.id == questId then
			return entry
		end
	end
	return nil
end

-- ============================================================================
-- Actions
-- ============================================================================

function QuestScreen:_onPrimary()
	local questId = self._selected
	if not questId then
		return
	end

	if self:_isActive(questId) then
		Net.FireServer("RequestTrackQuest", questId)
	else
		Net.FireServer("RequestAcceptQuest", questId)
	end

	Components.Pulse(self._detail, 1.005, "fast")
end

function QuestScreen:_onSecondary()
	local questId = self._selected
	if not questId or not self:_isActive(questId) then
		return
	end
	Net.FireServer("RequestAbandonQuest", questId)
end

function QuestScreen:Select(questId: string)
	self._selected = questId
	self:Refresh()
end

-- ============================================================================
-- Rendering
-- ============================================================================

function QuestScreen:Refresh()
	if not self._view then
		return
	end

	for tabId, button in pairs(self._tabButtons) do
		button:SetEnabled(tabId ~= self._tab)
	end

	local progress = self._view.mainProgress
	if progress then
		self._storyLabel.Text = ("STORY  %d / %d"):format(progress.done or 0, progress.total or 0)
		self._storyBar:SetValue(progress.fraction or 0, true)
	end

	if self._tab == "daily" then
		self._resetLabel.Text = "Resets in " .. formatCountdown(self._view.dailyResetAt)
	elseif self._tab == "weekly" then
		self._resetLabel.Text = "Resets in " .. formatCountdown(self._view.weeklyResetAt)
	else
		self._resetLabel.Text = ""
	end

	self:_refreshList()
	self:_refreshDetail()
end

function QuestScreen:_refreshList()
	local entries = self:_entriesForTab(self._tab)

	-- Rows are rebuilt rather than pooled: a quest list is a handful of entries and
	-- changes only when the server says something changed, so the pooling machinery
	-- would cost more to read than it saves to run.
	for _, row in pairs(self._rows) do
		row:Destroy()
	end
	self._rows = {}

	self._emptyLabel.Visible = #entries == 0
	if #entries == 0 then
		self._emptyLabel.Text = self._tab == "available"
			and "Nothing new available. Level up or finish what you have."
			or "Nothing here yet."
		return
	end

	for index, entry in ipairs(entries) do
		local selected = entry.id == self._selected
		local tracked = self._view.tracked == entry.id

		local row = Components.Panel({
			parent = self._list,
			name = entry.id,
			size = UDim2.new(1, -8, 0, 54),
			elevation = selected and 2 or 1,
			padding = Theme.Space.sm,
			zIndex = self._list.ZIndex + 1,
		})
		row.LayoutOrder = index

		-- A four-pixel spine in the quest's type colour. It reads as a category at a
		-- glance without spending a word on it.
		local spine = Instance.new("Frame")
		spine.Name = "Spine"
		spine.Size = UDim2.new(0, 3, 1, -12)
		spine.Position = UDim2.fromOffset(0, 6)
		spine.BackgroundColor3 = typeColor(entry.type)
		spine.BorderSizePixel = 0
		spine.ZIndex = row.ZIndex + 1
		spine.Parent = row

		Components.Text({
			parent = row,
			name = "Name",
			text = entry.name,
			size = UDim2.new(1, -70, 0, 18),
			position = UDim2.fromOffset(12, 2),
			textSize = Theme.Text.body,
			font = selected and Theme.Font.medium or Theme.Font.regular,
			color = selected and Theme.Color.textPrimary or Theme.Color.textSecondary,
			zIndex = row.ZIndex + 1,
		})

		Components.Text({
			parent = row,
			name = "Summary",
			text = entry.summary or "",
			size = UDim2.new(1, -70, 0, 14),
			position = UDim2.fromOffset(12, 22),
			textSize = Theme.Text.caption,
			color = Theme.Color.textTertiary,
			zIndex = row.ZIndex + 1,
		})

		if tracked then
			Components.Text({
				parent = row,
				name = "Tracked",
				text = "TRACKED",
				size = UDim2.fromOffset(64, 14),
				position = UDim2.new(1, -64, 0, 2),
				textSize = Theme.Text.caption,
				font = Theme.Font.medium,
				color = Theme.Color.accent,
				alignX = Enum.TextXAlignment.Right,
				zIndex = row.ZIndex + 1,
			})
		end

		-- Active quests carry their own completion bar, so the list answers "how far
		-- along am I" without a click.
		if entry.objectives then
			local done, total = 0, #entry.objectives
			for _, objective in ipairs(entry.objectives) do
				if objective.complete then
					done += 1
				end
			end

			local bar = select(2, Components.Bar({
				parent = row,
				name = "Progress",
				size = UDim2.new(1, -24, 0, 3),
				position = UDim2.new(0, 12, 1, -8),
				color = done >= total and Theme.Color.success or typeColor(entry.type),
				zIndex = row.ZIndex + 1,
			}))
			bar:SetValue(total > 0 and done / total or 0, false)
		elseif entry.requiredLevel then
			Components.Text({
				parent = row,
				name = "Level",
				text = ("LV %d"):format(entry.requiredLevel),
				size = UDim2.fromOffset(50, 14),
				position = UDim2.new(1, -50, 1, -18),
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
			self:Select(entry.id)
		end))

		self._rows[entry.id] = row
	end
end

function QuestScreen:_refreshDetail()
	local entry = self:_findEntry(self._selected)

	self._detailEmpty.Visible = entry == nil
	for _, child in ipairs(self._detail:GetChildren()) do
		if child:IsA("GuiObject") and child.Name ~= "DetailEmpty" then
			child.Visible = entry ~= nil
		end
	end

	if not entry then
		return
	end

	self._detailType.Text = string.upper(entry.type or "quest")
		.. (entry.regionName and ("  ·  " .. string.upper(entry.regionName)) or "")
	self._detailType.TextColor3 = typeColor(entry.type)

	self._detailName.Text = entry.name
	self._detailGiver.Text = entry.giver and ("Given by " .. entry.giver) or ""
	self._detailDescription.Text = entry.description or entry.summary or ""

	self:_refreshObjectives(entry)
	self._rewardsLabel.Text = self:_formatRewards(entry.rewards)

	local active = self:_isActive(entry.id)
	local tracked = self._view.tracked == entry.id

	if active then
		self._primaryButton:SetText(tracked and "TRACKED" or "TRACK")
		self._primaryButton:SetEnabled(not tracked)
		self._secondaryButton:SetText("ABANDON")
		-- The main line is the game; abandoning it is not a thing to offer.
		self._secondaryButton:SetEnabled(entry.type ~= "main")
	else
		self._primaryButton:SetText("ACCEPT")
		self._primaryButton:SetEnabled(true)
		self._secondaryButton:SetText("—")
		self._secondaryButton:SetEnabled(false)
	end
end

function QuestScreen:_refreshObjectives(entry: any)
	for _, row in pairs(self._objectiveRows) do
		row:Destroy()
	end
	self._objectiveRows = {}

	local objectives = entry.objectives
	if not objectives then
		local hint = Components.Text({
			parent = self._objectiveList,
			name = "NotAccepted",
			text = "Accept this quest to see its objectives.",
			size = UDim2.new(1, -8, 0, 18),
			textSize = Theme.Text.caption,
			color = Theme.Color.textTertiary,
			zIndex = self._objectiveList.ZIndex + 1,
		})
		table.insert(self._objectiveRows, hint)
		return
	end

	for index, objective in ipairs(objectives) do
		local row = Components.Container({
			parent = self._objectiveList,
			name = objective.id,
			size = UDim2.new(1, -8, 0, 38),
			zIndex = self._objectiveList.ZIndex + 1,
		})
		row.LayoutOrder = index

		local color
		if objective.complete then
			color = Theme.Color.success
		elseif objective.locked then
			-- A locked objective is shown rather than hidden: knowing a quest has a
			-- second stage changes how you approach the first.
			color = Theme.Color.textDisabled
		else
			color = Theme.Color.textPrimary
		end

		Components.Text({
			parent = row,
			name = "Marker",
			text = objective.complete and "✓" or (objective.locked and "·" or "○"),
			size = UDim2.fromOffset(18, 18),
			textSize = Theme.Text.body,
			color = color,
			zIndex = row.ZIndex + 1,
		})

		Components.Text({
			parent = row,
			name = "Description",
			text = objective.description or objective.id,
			size = UDim2.new(1, -110, 0, 18),
			position = UDim2.fromOffset(20, 0),
			textSize = Theme.Text.body,
			color = color,
			zIndex = row.ZIndex + 1,
		})

		local target = objective.target or 1
		if target > 1 and not objective.locked then
			Components.Text({
				parent = row,
				name = "Count",
				text = ("%d / %d"):format(math.min(objective.progress or 0, target), target),
				size = UDim2.fromOffset(84, 18),
				position = UDim2.new(1, -84, 0, 0),
				textSize = Theme.Text.body,
				font = Theme.Font.heading,
				color = color,
				alignX = Enum.TextXAlignment.Right,
				zIndex = row.ZIndex + 1,
			})

			local bar = select(2, Components.Bar({
				parent = row,
				name = "Bar",
				size = UDim2.new(1, -20, 0, 3),
				position = UDim2.fromOffset(20, 24),
				color = objective.complete and Theme.Color.success or Theme.Color.accent,
				zIndex = row.ZIndex + 1,
			}))
			bar:SetValue(math.clamp((objective.progress or 0) / target, 0, 1), false)
		end

		table.insert(self._objectiveRows, row)
	end

	if entry.teaches then
		local teaches = Components.Text({
			parent = self._objectiveList,
			name = "Teaches",
			text = "This quest teaches: " .. entry.teaches,
			size = UDim2.new(1, -8, 0, 30),
			textSize = Theme.Text.caption,
			color = Theme.Color.info,
			wrapped = true,
			zIndex = self._objectiveList.ZIndex + 1,
		})
		teaches.LayoutOrder = #objectives + 1
		table.insert(self._objectiveRows, teaches)
	end
end

function QuestScreen:_formatRewards(rewards: any?): string
	if not rewards then
		return ""
	end

	local parts = {}
	if rewards.watts then
		table.insert(parts, Theme.FormatNumber(rewards.watts) .. " W")
	end
	if rewards.xp then
		table.insert(parts, Theme.FormatNumber(rewards.xp) .. " XP")
	end
	if rewards.cores then
		table.insert(parts, Theme.FormatNumber(rewards.cores) .. " cores")
	end
	if rewards.sigils then
		table.insert(parts, Theme.FormatNumber(rewards.sigils) .. " sigils")
	end
	if rewards.skillPoints then
		table.insert(parts, ("%d skill point%s"):format(rewards.skillPoints, rewards.skillPoints == 1 and "" or "s"))
	end
	if rewards.title then
		table.insert(parts, ('title "%s"'):format(rewards.title))
	end
	if rewards.item then
		table.insert(parts, "an item")
	end
	-- Scaling rewards read as a formula on the server; here they read as a promise.
	if rewards.wattsPerLevel then
		table.insert(parts, "watts scaled to your level")
	end

	if #parts == 0 then
		return ""
	end
	return "REWARDS   " .. table.concat(parts, "   ·   ")
end

function QuestScreen:SetVisible(visible: boolean)
	self._root.Visible = visible
	if visible then
		self:Refresh()
		Components.FadeIn(self._root, { duration = "fast" })
	end
end

function QuestScreen:Destroy()
	self._maid:DoCleaning()
end

return QuestScreen
