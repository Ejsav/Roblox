--!strict
--[[
	CodexScreen
	-----------
	Everything the player has collected, proved, or is being measured against.

	Four tabs that look unrelated and are not: achievements are what you have done,
	titles are what you can show for it, the storm log is what you have met, and the
	boards are where that puts you next to everyone else. Splitting them across four
	menus would make each one too thin to open; together they are the screen a player
	goes to when they want to feel like they have got somewhere.

	Two rules the screen is built around:
	  * Nothing here is a chore list. Every row states a thing worth doing, and rows
	    already done stay visible — a completed achievement is a receipt, not
	    something to be cleared away.
	  * Hidden achievements are shown, masked. A locked mystery advertises that the
	    game has more in it; omitting the rows entirely would make the completion
	    count a lie and teach the player nothing.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BTS")
local Theme = require(Shared.Config.Theme)
local StormTypes = require(Shared.Config.StormTypes)
local Net = require(Shared.Net)
local Maid = require(Shared.Core.Maid)

local Client = script.Parent.Parent.Parent
local Components = require(Client.UI.Components)

local CodexScreen = {}
CodexScreen.__index = CodexScreen

local TABS = {
	{ id = "achievements", name = "ACHIEVEMENTS" },
	{ id = "titles", name = "TITLES" },
	{ id = "storms", name = "STORM LOG" },
	{ id = "boards", name = "BOARDS" },
}

--[[
	The boards the client offers. Kept here rather than fetched so the tab renders
	its list instantly and only pays a round trip for the page the player picks.
	An id the server does not recognise simply returns nothing, which is the correct
	behaviour for a board that was retired.
]]
local BOARDS = {
	{ id = "server_banked", name = "Banked — This Server" },
	{ id = "server_captures", name = "Captures — This Server" },
	{ id = "largest_bank", name = "Largest Single Bank" },
	{ id = "total_banked", name = "Total Banked" },
	{ id = "total_banked_weekly", name = "Banked This Week" },
	{ id = "highest_multiplier", name = "Highest Multiplier" },
	{ id = "longest_chain", name = "Longest Chain" },
	{ id = "level", name = "Level" },
	{ id = "prestige", name = "Prestige" },
}

local RARITY_ORDER = { common = 1, uncommon = 2, rare = 3, epic = 4, legendary = 5, mythic = 6, exotic = 7 }

local function formatBoardValue(format: string?, value: number, label: string?): string
	if label then
		return label
	end
	if format == "energy" then
		return Theme.FormatNumber(value) .. " W"
	end
	if format == "multiplier" then
		return ("x%.2f"):format(value)
	end
	return Theme.FormatNumber(value)
end

function CodexScreen.new(parent: Instance, controllers: any)
	local self = setmetatable({
		_maid = Maid.new(),
		_controllers = controllers,
		_tab = "achievements",
		_profile = nil,
		_view = nil,
		_board = BOARDS[1].id,
		_boardPage = 1,
		_boardData = nil,
		_fetching = false,
		_rows = {},
	}, CodexScreen)

	self:_build(parent)
	return self
end

function CodexScreen:_build(parent: Instance)
	local root = Components.Panel({
		parent = parent,
		name = "CodexScreen",
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
		text = "CODEX",
		size = UDim2.new(0, 220, 1, 0),
		textSize = Theme.Text.title,
		zIndex = header.ZIndex + 1,
	})

	-- The completion figure sits in the header on every tab, because it is the one
	-- number that says how much of this screen is still ahead of the player.
	self._completionLabel = Components.Text({
		parent = header,
		name = "Completion",
		text = "",
		size = UDim2.new(0, 340, 0, 18),
		position = UDim2.new(1, -340, 0, 4),
		textSize = Theme.Text.caption,
		color = Theme.Color.textSecondary,
		alignX = Enum.TextXAlignment.Right,
		zIndex = header.ZIndex + 1,
	})

	self._completionBar = select(2, Components.Bar({
		parent = header,
		name = "CompletionBar",
		size = UDim2.fromOffset(340, 4),
		position = UDim2.new(1, -340, 0, 26),
		color = Theme.Color.accent,
		zIndex = header.ZIndex + 1,
	}))

	local tabs = Components.Container({
		parent = root,
		name = "Tabs",
		size = UDim2.new(1, -Theme.Space.xl, 0, 34),
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
			size = UDim2.fromOffset(150, 30),
			textSize = Theme.Text.caption,
			layoutOrder = index,
			zIndex = tabs.ZIndex + 1,
		})
		self._maid:Add(button.Pressed:Connect(function()
			self:SetTab(tab.id)
		end))
		self._tabButtons[tab.id] = button
	end

	-- A secondary bar the boards tab fills with board names. Empty on other tabs
	-- rather than absent, so the content below never shifts vertically between tabs.
	self._subBar = Components.Scroll({
		parent = root,
		name = "SubBar",
		size = UDim2.new(1, -Theme.Space.xl, 0, 30),
		position = UDim2.fromOffset(Theme.Space.lg, 96),
		gap = Theme.Space.xs,
		horizontal = true,
		zIndex = root.ZIndex + 1,
	})

	self._list = Components.Scroll({
		parent = root,
		name = "List",
		size = UDim2.new(1, -Theme.Space.xl, 1, -142),
		position = UDim2.fromOffset(Theme.Space.lg, 132),
		gap = Theme.Space.xs,
		zIndex = root.ZIndex + 1,
	})

	self._status = Components.Text({
		parent = root,
		name = "Status",
		text = "",
		size = UDim2.new(1, -Theme.Space.xl, 0, 20),
		position = UDim2.fromOffset(Theme.Space.lg, 136),
		textSize = Theme.Text.body,
		color = Theme.Color.textTertiary,
		zIndex = root.ZIndex + 3,
	})
	self._status.Visible = false

	self:_buildBoardButtons()
end

function CodexScreen:_buildBoardButtons()
	self._boardButtons = {}
	for index, board in ipairs(BOARDS) do
		local _, button = Components.Button({
			parent = self._subBar,
			name = board.id,
			text = string.upper(board.name),
			variant = "ghost",
			size = UDim2.fromOffset(190, 26),
			textSize = Theme.Text.caption,
			layoutOrder = index,
			zIndex = self._subBar.ZIndex + 1,
		})
		self._maid:Add(button.Pressed:Connect(function()
			self:SetBoard(board.id)
		end))
		self._boardButtons[board.id] = button
	end
end

-- ============================================================================
-- Data
-- ============================================================================

function CodexScreen:SetProfile(profile: any)
	self._profile = profile
	if self._root.Visible then
		self:Refresh()
	end
end

--[[ The AchievementService panel payload. ]]
function CodexScreen:SetView(view: any)
	self._view = view
	if self._root.Visible then
		self:Refresh()
	end
end

function CodexScreen:SetTab(tabId: string)
	if self._tab == tabId then
		return
	end
	self._tab = tabId
	self:Refresh()

	if tabId == "boards" and not self._boardData then
		self:_fetchBoard()
	end
end

function CodexScreen:SetBoard(boardId: string)
	if self._board == boardId then
		return
	end
	self._board = boardId
	self._boardPage = 1
	self._boardData = nil
	self:Refresh()
	self:_fetchBoard()
end

--[[
	Fetches a board page. Guarded against overlapping requests: the remote is rate
	limited, and a player clicking through boards faster than the server answers
	would otherwise burn the budget and get nothing back for any of them.
]]
function CodexScreen:_fetchBoard()
	if self._fetching then
		return
	end
	self._fetching = true

	local boardId, page = self._board, self._boardPage

	task.spawn(function()
		local result = Net.InvokeServer("RequestLeaderboard", boardId, page)
		self._fetching = false

		-- The player may have moved on while that was in flight; a stale answer must
		-- not overwrite what they are looking at now.
		if boardId ~= self._board or page ~= self._boardPage then
			return
		end

		self._boardData = result
		if self._tab == "boards" then
			self:Refresh()
		end
	end)
end

function CodexScreen:RequestTitle(titleId: string?)
	Net.FireServer("RequestEquipTitle", titleId or "")
end

-- ============================================================================
-- Rendering
-- ============================================================================

function CodexScreen:Refresh()
	for tabId, button in pairs(self._tabButtons) do
		button:SetEnabled(tabId ~= self._tab)
	end

	self._subBar.Visible = self._tab == "boards"
	for boardId, button in pairs(self._boardButtons) do
		button:SetEnabled(boardId ~= self._board)
	end

	self:_refreshCompletion()
	self:_clearRows()

	if self._tab == "achievements" then
		self:_renderAchievements()
	elseif self._tab == "titles" then
		self:_renderTitles()
	elseif self._tab == "storms" then
		self:_renderStorms()
	else
		self:_renderBoards()
	end
end

function CodexScreen:_clearRows()
	for _, row in ipairs(self._rows) do
		row:Destroy()
	end
	self._rows = {}
	self._status.Visible = false
end

function CodexScreen:_setStatus(text: string)
	self._status.Text = text
	self._status.Visible = true
end

function CodexScreen:_refreshCompletion()
	if self._tab == "storms" then
		local found = 0
		for _ in pairs((self._profile and self._profile.stormsDiscovered) or {}) do
			found += 1
		end
		local total = #StormTypes.List
		self._completionLabel.Text = ("STORM LOG  %d / %d"):format(found, total)
		self._completionBar:SetValue(total > 0 and found / total or 0, true)
		return
	end

	local completion = self._view and self._view.completion
	if completion then
		self._completionLabel.Text = ("ACHIEVEMENTS  %d / %d"):format(completion.earned, completion.total)
		self._completionBar:SetValue(completion.fraction or 0, true)
	else
		self._completionLabel.Text = ""
		self._completionBar:SetValue(0, false)
	end
end

--[[ A section heading inside the scrolling list. ]]
function CodexScreen:_addSection(text: string, order: number)
	local label = Components.Text({
		parent = self._list,
		name = "Section" .. tostring(order),
		text = string.upper(text),
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

function CodexScreen:_renderAchievements()
	if not self._view then
		self:_setStatus("Loading…")
		return
	end

	local order = 0
	for _, category in ipairs(self._view.categories or {}) do
		if #category.rows == 0 then
			continue
		end

		order += 1
		self:_addSection(("%s   %d / %d"):format(category.name, category.earned, category.total), order)

		for _, entry in ipairs(category.rows) do
			order += 1
			self:_addAchievementRow(entry, order)
		end
	end

	if order == 0 then
		self:_setStatus("Nothing yet.")
	end
end

function CodexScreen:_addAchievementRow(entry: any, order: number)
	local row = Components.Panel({
		parent = self._list,
		name = entry.id,
		size = UDim2.new(1, -8, 0, 52),
		elevation = 1,
		padding = Theme.Space.sm,
		zIndex = self._list.ZIndex + 1,
	})
	row.LayoutOrder = order

	local color
	if entry.earned then
		color = Theme.Color.success
	elseif entry.masked then
		color = Theme.Color.textDisabled
	else
		color = Theme.Color.textPrimary
	end

	Components.Text({
		parent = row,
		name = "Marker",
		text = entry.earned and "✓" or (entry.masked and "?" or "○"),
		size = UDim2.fromOffset(20, 18),
		textSize = Theme.Text.body,
		font = Theme.Font.heading,
		color = color,
		zIndex = row.ZIndex + 1,
	})

	Components.Text({
		parent = row,
		name = "Name",
		text = entry.name,
		size = UDim2.new(1, -180, 0, 18),
		position = UDim2.fromOffset(24, 0),
		textSize = Theme.Text.body,
		font = entry.earned and Theme.Font.medium or Theme.Font.regular,
		color = color,
		zIndex = row.ZIndex + 1,
	})

	Components.Text({
		parent = row,
		name = "Description",
		text = entry.description or "",
		size = UDim2.new(1, -180, 0, 14),
		position = UDim2.fromOffset(24, 18),
		textSize = Theme.Text.caption,
		color = Theme.Color.textTertiary,
		zIndex = row.ZIndex + 1,
	})

	if entry.earned then
		Components.Text({
			parent = row,
			name = "Earned",
			text = entry.earnedAt and os.date("!%d %b %Y", entry.earnedAt) or "EARNED",
			size = UDim2.fromOffset(150, 18),
			position = UDim2.new(1, -150, 0, 0),
			textSize = Theme.Text.caption,
			color = Theme.Color.success,
			alignX = Enum.TextXAlignment.Right,
			zIndex = row.ZIndex + 1,
		})
	elseif not entry.masked and (entry.target or 1) > 1 then
		Components.Text({
			parent = row,
			name = "Progress",
			text = ("%s / %s"):format(Theme.FormatNumber(entry.value or 0), Theme.FormatNumber(entry.target)),
			size = UDim2.fromOffset(150, 18),
			position = UDim2.new(1, -150, 0, 0),
			textSize = Theme.Text.body,
			font = Theme.Font.heading,
			color = Theme.Color.accent,
			alignX = Enum.TextXAlignment.Right,
			zIndex = row.ZIndex + 1,
		})

		local bar = select(2, Components.Bar({
			parent = row,
			name = "Bar",
			size = UDim2.new(1, -24, 0, 3),
			position = UDim2.new(0, 24, 1, -6),
			color = Theme.Color.accent,
			zIndex = row.ZIndex + 1,
		}))
		bar:SetValue(entry.fraction or 0, false)
	end

	table.insert(self._rows, row)
end

function CodexScreen:_renderTitles()
	local titles = (self._view and self._view.titles) or {}

	if #titles == 0 then
		self:_setStatus("No titles yet. Achievements, masteries and prestige ranks award them.")
		return
	end

	local equipped = self._view and self._view.equippedTitle

	-- "None" is a real choice and needs a row, or a player who wants to wear nothing
	-- has no way to say so.
	local order = 1
	self:_addTitleRow({
		id = "",
		name = "No title",
		description = "Wear nothing.",
	}, equipped == nil, order)

	for index, title in ipairs(titles) do
		order = index + 1
		self:_addTitleRow(title, title.id == equipped, order)
	end
end

function CodexScreen:_addTitleRow(title: any, equipped: boolean, order: number)
	local row = Components.Panel({
		parent = self._list,
		name = "title_" .. (title.id ~= "" and title.id or "none"),
		size = UDim2.new(1, -8, 0, 46),
		elevation = equipped and 2 or 1,
		padding = Theme.Space.sm,
		zIndex = self._list.ZIndex + 1,
	})
	row.LayoutOrder = order

	Components.Text({
		parent = row,
		name = "Name",
		text = title.name,
		size = UDim2.new(1, -160, 0, 18),
		textSize = Theme.Text.body,
		font = equipped and Theme.Font.medium or Theme.Font.regular,
		color = equipped and Theme.Color.accent or Theme.Color.textPrimary,
		zIndex = row.ZIndex + 1,
	})

	Components.Text({
		parent = row,
		name = "Source",
		text = title.description or (title.source == "achievement" and "Achievement" or "Earned"),
		size = UDim2.new(1, -160, 0, 14),
		position = UDim2.fromOffset(0, 18),
		textSize = Theme.Text.caption,
		color = Theme.Color.textTertiary,
		zIndex = row.ZIndex + 1,
	})

	local _, button = Components.Button({
		parent = row,
		name = "Wear",
		text = equipped and "WORN" or "WEAR",
		variant = equipped and "ghost" or "primary",
		size = UDim2.fromOffset(140, 32),
		position = UDim2.new(1, 0, 0.5, 0),
		anchorPoint = Vector2.new(1, 0.5),
		textSize = Theme.Text.caption,
		zIndex = row.ZIndex + 2,
	})
	button:SetEnabled(not equipped)
	self._maid:Add(button.Pressed:Connect(function()
		self:RequestTitle(title.id)
	end))

	table.insert(self._rows, row)
end

--[[
	The storm log. Undiscovered storms show their tier and nothing else: the shape
	of what is missing is a map of where to go next, but naming an unmet storm would
	spend the moment of meeting it.
]]
function CodexScreen:_renderStorms()
	local discovered = (self._profile and self._profile.stormsDiscovered) or {}

	local byTier = {}
	for _, storm in ipairs(StormTypes.List) do
		byTier[storm.tier] = byTier[storm.tier] or {}
		table.insert(byTier[storm.tier], storm)
	end

	local tiers = {}
	for tier in pairs(byTier) do
		table.insert(tiers, tier)
	end
	table.sort(tiers)

	local order = 0
	for _, tier in ipairs(tiers) do
		local storms = byTier[tier]
		table.sort(storms, function(a, b)
			local aRarity = RARITY_ORDER[a.rarity] or 0
			local bRarity = RARITY_ORDER[b.rarity] or 0
			if aRarity ~= bRarity then
				return aRarity < bRarity
			end
			return a.name < b.name
		end)

		local found = 0
		for _, storm in ipairs(storms) do
			if discovered[storm.id] then
				found += 1
			end
		end

		order += 1
		self:_addSection(("Tier %d   %d / %d"):format(tier, found, #storms), order)

		for _, storm in ipairs(storms) do
			order += 1
			self:_addStormRow(storm, discovered[storm.id], order)
		end
	end
end

function CodexScreen:_addStormRow(storm: any, captures: number?, order: number)
	local known = captures ~= nil
	local rarity = Theme.GetRarity(storm.rarity)

	local row = Components.Panel({
		parent = self._list,
		name = storm.id,
		size = UDim2.new(1, -8, 0, 50),
		elevation = 1,
		padding = Theme.Space.sm,
		zIndex = self._list.ZIndex + 1,
	})
	row.LayoutOrder = order

	local spine = Instance.new("Frame")
	spine.Name = "Spine"
	spine.Size = UDim2.new(0, 3, 1, -12)
	spine.Position = UDim2.fromOffset(0, 6)
	spine.BackgroundColor3 = known and rarity.color or Theme.Color.border
	spine.BorderSizePixel = 0
	spine.ZIndex = row.ZIndex + 1
	spine.Parent = row

	Components.Text({
		parent = row,
		name = "Name",
		text = known and storm.name or "Unrecorded",
		size = UDim2.new(1, -200, 0, 18),
		position = UDim2.fromOffset(12, 0),
		textSize = Theme.Text.body,
		font = known and Theme.Font.medium or Theme.Font.regular,
		color = known and rarity.color or Theme.Color.textDisabled,
		zIndex = row.ZIndex + 1,
	})

	Components.Text({
		parent = row,
		name = "Detail",
		-- What a storm teaches is the single most useful line about it, so a
		-- discovered storm shows that rather than restating its rarity.
		text = known and (storm.teaches or "") or ("Tier %d  ·  %s"):format(storm.tier, rarity.label),
		size = UDim2.new(1, -200, 0, 14),
		position = UDim2.fromOffset(12, 20),
		textSize = Theme.Text.caption,
		color = Theme.Color.textTertiary,
		wrapped = true,
		zIndex = row.ZIndex + 1,
	})

	if known then
		Components.Text({
			parent = row,
			name = "Captures",
			text = ("%s captured"):format(Theme.FormatNumber(captures or 0)),
			size = UDim2.fromOffset(180, 18),
			position = UDim2.new(1, -180, 0, 2),
			textSize = Theme.Text.caption,
			color = Theme.Color.textSecondary,
			alignX = Enum.TextXAlignment.Right,
			zIndex = row.ZIndex + 1,
		})
	end

	table.insert(self._rows, row)
end

function CodexScreen:_renderBoards()
	local data = self._boardData

	if not data then
		self:_setStatus(self._fetching and "Loading…" or "No entries yet.")
		return
	end

	local order = 0

	if data.serverLocalOnly then
		order += 1
		local notice = Components.Text({
			parent = self._list,
			name = "LocalNotice",
			text = "This board is local to this server — global scores are unavailable right now.",
			size = UDim2.new(1, -8, 0, 20),
			textSize = Theme.Text.caption,
			color = Theme.Color.warning,
			zIndex = self._list.ZIndex + 1,
		})
		notice.LayoutOrder = order
		table.insert(self._rows, notice)
	end

	if #(data.entries or {}) == 0 then
		self:_setStatus("Nobody has posted a score here yet. Be first.")
		return
	end

	for _, entry in ipairs(data.entries) do
		order += 1

		local isViewer = entry.rank == data.viewerRank
		local row = Components.Panel({
			parent = self._list,
			name = "rank" .. tostring(entry.rank),
			size = UDim2.new(1, -8, 0, 38),
			elevation = isViewer and 2 or 1,
			padding = Theme.Space.sm,
			zIndex = self._list.ZIndex + 1,
		})
		row.LayoutOrder = order

		-- The top three get the colour. Beyond that a rank is a number.
		local rankColor = Theme.Color.textSecondary
		if entry.rank == 1 then
			rankColor = Theme.Color.watts
		elseif entry.rank == 2 then
			rankColor = Theme.Color.textPrimary
		elseif entry.rank == 3 then
			rankColor = Theme.Color.instability
		end

		Components.Text({
			parent = row,
			name = "Rank",
			text = ("%d"):format(entry.rank),
			size = UDim2.fromOffset(44, 20),
			textSize = Theme.Text.body,
			font = Theme.Font.heading,
			color = rankColor,
			alignX = Enum.TextXAlignment.Right,
			zIndex = row.ZIndex + 1,
		})

		Components.Text({
			parent = row,
			name = "Name",
			text = entry.name or "Runner",
			size = UDim2.new(1, -240, 0, 20),
			position = UDim2.fromOffset(56, 0),
			textSize = Theme.Text.body,
			font = isViewer and Theme.Font.medium or Theme.Font.regular,
			color = isViewer and Theme.Color.accent or Theme.Color.textPrimary,
			zIndex = row.ZIndex + 1,
		})

		Components.Text({
			parent = row,
			name = "Value",
			text = formatBoardValue(data.format, entry.value or 0, entry.label),
			size = UDim2.fromOffset(170, 20),
			position = UDim2.new(1, -170, 0, 0),
			textSize = Theme.Text.body,
			font = Theme.Font.heading,
			color = Theme.Color.textPrimary,
			alignX = Enum.TextXAlignment.Right,
			zIndex = row.ZIndex + 1,
		})

		table.insert(self._rows, row)
	end

	-- Where the player stands, stated even when they are off this page. A board you
	-- are not on should still tell you where you are.
	order += 1
	local standing = Components.Text({
		parent = self._list,
		name = "Standing",
		text = data.viewerRank
			and ("You are ranked %d with %s."):format(
				data.viewerRank,
				formatBoardValue(data.format, data.viewerValue or 0)
			)
			or "You are not on this board yet.",
		size = UDim2.new(1, -8, 0, 24),
		textSize = Theme.Text.caption,
		color = Theme.Color.textSecondary,
		zIndex = self._list.ZIndex + 1,
	})
	standing.LayoutOrder = order
	table.insert(self._rows, standing)
end

function CodexScreen:SetVisible(visible: boolean)
	self._root.Visible = visible
	if not visible then
		return
	end

	self:Refresh()
	Components.FadeIn(self._root, { duration = "fast" })
end

--[[
	Called by the menu controller when this screen is opened. Kept out of
	SetVisible deliberately: a visibility setter that also fires network requests is
	a setter you cannot call to reset state, and every caller then has to know it is
	really two operations wearing one name.
]]
function CodexScreen:OnOpened()
	-- Opening is the signal to re-read: the panel is cheap to build and stale
	-- achievement progress is worse than a frame of "Loading…".
	self:RequestRefresh()
	if self._tab == "boards" then
		self:_fetchBoard()
	end
end

--[[ Asks the server for a fresh achievement panel. ]]
function CodexScreen:RequestRefresh()
	if self._refreshing then
		return
	end
	self._refreshing = true

	task.spawn(function()
		local view = Net.InvokeServer("RequestAchievements")
		self._refreshing = false
		if view then
			self:SetView(view)
		end
	end)
end

function CodexScreen:Destroy()
	self._maid:DoCleaning()
end

return CodexScreen
