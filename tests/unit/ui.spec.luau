--!nolint
--[[
	UI construction specs.

	These do not assert on pixels. They assert that a screen can be built, handed
	the payload the server actually sends, and refreshed without throwing — which
	is the failure mode that matters, because the alternative way to discover a nil
	index inside a build path is for a player to press a key and get an empty panel.

	Every screen is exercised twice: once empty (the state it is in for the first
	second after joining, before any payload arrives) and once with data.
]]

local loadModule = loadModule

local ProfileSchema = loadModule("Shared/Data/ProfileSchema")
local Quests = loadModule("Shared/Config/Quests")

local MapScreen = loadModule("Client/UI/Screens/MapScreen")
local UpgradesScreen = loadModule("Client/UI/Screens/UpgradesScreen")
local SkillsScreen = loadModule("Client/UI/Screens/SkillsScreen")
local InventoryScreen = loadModule("Client/UI/Screens/InventoryScreen")
local QuestScreen = loadModule("Client/UI/Screens/QuestScreen")
local CodexScreen = loadModule("Client/UI/Screens/CodexScreen")
local Hud = loadModule("Client/UI/Screens/Hud")

local function newParent()
	return Instance.new("Frame")
end

describe("UI/Screens construction", function()
	it("builds every menu screen", function()
		local parent = newParent()
		expect(MapScreen.new(parent, {})):ok()
		expect(UpgradesScreen.new(parent, {})):ok()
		expect(SkillsScreen.new(parent, {})):ok()
		expect(InventoryScreen.new(parent, {})):ok()
		expect(QuestScreen.new(parent, {})):ok()
		expect(CodexScreen.new(parent, {})):ok()
	end)

	it("builds the HUD", function()
		expect(Hud.new(newParent(), {})):ok()
	end)

	it("survives being shown before any data arrives", function()
		-- The first second of a session: the screen exists, the payload does not.
		local parent = newParent()
		for _, screen in ipairs({
			MapScreen.new(parent, {}),
			UpgradesScreen.new(parent, {}),
			SkillsScreen.new(parent, {}),
			InventoryScreen.new(parent, {}),
			QuestScreen.new(parent, {}),
			CodexScreen.new(parent, {}),
		}) do
			screen:SetVisible(true)
			screen:SetVisible(false)
		end
	end)
end)

describe("UI/QuestScreen", function()
	--[[ The payload QuestService:_syncQuests actually sends. ]]
	local function makeView()
		local main = Quests.List[1]
		return {
			active = {
				{
					id = main.id,
					name = main.name,
					summary = main.summary,
					description = main.description,
					type = main.type,
					region = main.region,
					regionName = "Halworth",
					giver = main.giver,
					teaches = main.teaches,
					rewards = main.rewards,
					objectives = {
						{
							id = "first",
							description = "Capture three storms",
							progress = 1,
							target = 3,
							complete = false,
							locked = false,
							type = "capture",
						},
						{
							id = "second",
							description = "Bank what you took",
							progress = 0,
							target = 1,
							complete = false,
							locked = true,
							type = "bank",
						},
					},
				},
			},
			available = {
				{
					id = "some_side_quest",
					name = "A Side Quest",
					summary = "Do a thing.",
					type = "side",
					requiredLevel = 12,
					rewards = { watts = 4000, xp = 2200 },
				},
			},
			tracked = main.id,
			daily = { "some_side_quest" },
			weekly = {},
			dailyResetAt = os.time() + 7200,
			weeklyResetAt = os.time() + 400000,
			mainProgress = { fraction = 0.25, done = 6, total = 24 },
		}
	end

	it("renders a full quest payload", function()
		local screen = QuestScreen.new(newParent(), {})
		screen:SetProfile(ProfileSchema.CreateDefault(1))
		screen:SetView(makeView())
		screen:SetVisible(true)
		expect(screen._selected):equal(Quests.List[1].id)
	end)

	it("moves between every tab without throwing", function()
		local screen = QuestScreen.new(newParent(), {})
		screen:SetView(makeView())

		for _, tab in ipairs({ "available", "daily", "weekly", "active" }) do
			screen:SetTab(tab)
			expect(screen._tab):equal(tab)
		end
	end)

	it("resolves a rotating set against the active and available lists", function()
		local screen = QuestScreen.new(newParent(), {})
		screen:SetView(makeView())
		screen:SetTab("daily")

		local entries = screen:_entriesForTab("daily")
		expect(#entries):equal(1)
		expect(entries[1].id):equal("some_side_quest")
	end)

	it("renders an empty tab rather than an empty screen", function()
		local screen = QuestScreen.new(newParent(), {})
		screen:SetView(makeView())
		screen:SetTab("weekly")

		expect(#screen:_entriesForTab("weekly")):equal(0)
		expect(screen._emptyLabel.Visible):equal(true)
		expect(screen._selected):isNil()
	end)

	it("keeps the selection when a payload arrives that still contains it", function()
		local screen = QuestScreen.new(newParent(), {})
		screen:SetView(makeView())

		local selected = screen._selected
		screen:SetView(makeView())
		expect(screen._selected):equal(selected)
	end)

	it("falls back to the tracked quest when the selection disappears", function()
		local screen = QuestScreen.new(newParent(), {})
		screen:SetView(makeView())
		screen._selected = "a_quest_that_went_away"

		screen:SetView(makeView())
		expect(screen._selected):equal(Quests.List[1].id)
	end)

	it("counts an accepted quest as active and an offered one as not", function()
		local screen = QuestScreen.new(newParent(), {})
		screen:SetView(makeView())

		expect(screen:_isActive(Quests.List[1].id)):equal(true)
		expect(screen:_isActive("some_side_quest")):equal(false)
	end)

	it("formats only the rewards a quest actually pays", function()
		local screen = QuestScreen.new(newParent(), {})

		expect(screen:_formatRewards(nil)):equal("")
		expect(screen:_formatRewards({})):equal("")

		local text = screen:_formatRewards({ watts = 1000, xp = 500, skillPoints = 1 })
		expect(text):contains("XP")
		expect(text):contains("1 skill point")
		-- Nothing it does not pay.
		if text:find("cores") then
			error("formatted a reward the quest does not award: " .. text)
		end
	end)

	it("pluralises skill points", function()
		local screen = QuestScreen.new(newParent(), {})
		expect(screen:_formatRewards({ skillPoints = 1 })):contains("1 skill point")
		expect(screen:_formatRewards({ skillPoints = 3 })):contains("3 skill points")
		-- The singular must not be the plural with the "s" merely absent from view.
		if screen:_formatRewards({ skillPoints = 1 }):find("skill points") then
			error("singular reward pluralised")
		end
	end)
end)

describe("UI/CodexScreen", function()
	local AchievementService = loadModule("Server/Services/AchievementService")
	local StormTypes = loadModule("Shared/Config/StormTypes")

	--[[
		The real AchievementService payload rather than a hand-written stand-in, so
		this breaks if the service and the screen ever disagree about its shape.
	]]
	local function makeView(profile)
		local service = setmetatable({}, { __index = AchievementService })
		service.Registry = { Get = function() return nil end, Find = function() return nil end }
		AchievementService.Init(service)
		service._data = {
			GetProfile = function() return profile end,
			MarkDirty = function() end,
		}
		return service:BuildView({ UserId = 1, DisplayName = "Tester" })
	end

	it("renders the achievement panel the service produces", function()
		local profile = ProfileSchema.CreateDefault(1)
		profile.records.totalCaptures = 400
		profile.achievements.ach_first_capture = 1700000000

		local screen = CodexScreen.new(newParent(), {})
		screen:SetProfile(profile)
		screen:SetView(makeView(profile))
		screen:SetVisible(true)

		expect(#screen._rows):greaterThan(0)
		expect(screen._completionLabel.Text):contains("ACHIEVEMENTS")
	end)

	it("moves through every tab without throwing", function()
		local profile = ProfileSchema.CreateDefault(1)
		local screen = CodexScreen.new(newParent(), {})
		screen:SetProfile(profile)
		screen:SetView(makeView(profile))

		for _, tab in ipairs({ "titles", "storms", "boards", "achievements" }) do
			screen:SetTab(tab)
			expect(screen._tab):equal(tab)
		end
	end)

	it("offers a way to wear nothing", function()
		local profile = ProfileSchema.CreateDefault(1)
		profile.titlesOwned.practised = true
		profile.equippedTitle = "practised"

		local screen = CodexScreen.new(newParent(), {})
		screen:SetProfile(profile)
		screen:SetView(makeView(profile))
		screen:SetTab("titles")

		-- One row per owned title, plus the "no title" row.
		expect(#screen._rows):equal(2)
	end)

	it("explains an empty title list rather than showing nothing", function()
		local profile = ProfileSchema.CreateDefault(1)
		local screen = CodexScreen.new(newParent(), {})
		screen:SetProfile(profile)
		screen:SetView(makeView(profile))
		screen:SetTab("titles")

		expect(screen._status.Visible):equal(true)
		expect(screen._status.Text):contains("No titles yet")
	end)

	it("lists every storm, naming only the ones met", function()
		local profile = ProfileSchema.CreateDefault(1)
		local firstStorm = StormTypes.List[1]
		profile.stormsDiscovered[firstStorm.id] = 12

		local screen = CodexScreen.new(newParent(), {})
		screen:SetProfile(profile)
		screen:SetView(makeView(profile))
		screen:SetTab("storms")

		local named, unrecorded = 0, 0
		for _, row in ipairs(screen._rows) do
			local label = row:FindFirstChild("Name")
			if label then
				if label.Text == "Unrecorded" then
					unrecorded += 1
				else
					named += 1
				end
			end
		end

		expect(named):equal(1)
		expect(unrecorded):equal(#StormTypes.List - 1)
	end)

	it("counts the storm log in the header", function()
		local profile = ProfileSchema.CreateDefault(1)
		profile.stormsDiscovered[StormTypes.List[1].id] = 3

		local screen = CodexScreen.new(newParent(), {})
		screen:SetProfile(profile)
		screen:SetView(makeView(profile))
		screen:SetTab("storms")

		expect(screen._completionLabel.Text):contains("STORM LOG  1 / " .. tostring(#StormTypes.List))
	end)

	it("renders a leaderboard page and says where the viewer stands", function()
		local profile = ProfileSchema.CreateDefault(1)
		local screen = CodexScreen.new(newParent(), {})
		screen:SetProfile(profile)
		screen:SetView(makeView(profile))
		screen._tab = "boards"
		screen._boardData = {
			boardId = "largest_bank",
			format = "energy",
			entries = {
				{ rank = 1, userId = 9, name = "Someone", value = 90000 },
				{ rank = 2, userId = 1, name = "Tester", value = 4200 },
			},
			viewerRank = 2,
			viewerValue = 4200,
		}
		screen:Refresh()

		local standing
		for _, row in ipairs(screen._rows) do
			if row.Name == "Standing" then
				standing = row
			end
		end
		expect(standing):ok()
		expect(standing.Text):contains("ranked 2")
	end)

	it("tells a player they are not on a board rather than staying silent", function()
		local profile = ProfileSchema.CreateDefault(1)
		local screen = CodexScreen.new(newParent(), {})
		screen:SetProfile(profile)
		screen:SetView(makeView(profile))
		screen._tab = "boards"
		screen._boardData = {
			boardId = "largest_bank",
			format = "energy",
			entries = { { rank = 1, userId = 9, name = "Someone", value = 90000 } },
		}
		screen:Refresh()

		local standing
		for _, row in ipairs(screen._rows) do
			if row.Name == "Standing" then
				standing = row
			end
		end
		expect(standing.Text):contains("not on this board")
	end)

	it("says when a board is local to this server", function()
		local profile = ProfileSchema.CreateDefault(1)
		local screen = CodexScreen.new(newParent(), {})
		screen:SetProfile(profile)
		screen:SetView(makeView(profile))
		screen._tab = "boards"
		screen._boardData = {
			boardId = "largest_bank",
			format = "energy",
			serverLocalOnly = true,
			entries = { { rank = 1, userId = 1, name = "Tester", value = 10 } },
		}
		screen:Refresh()

		local notice
		for _, row in ipairs(screen._rows) do
			if row.Name == "LocalNotice" then
				notice = row
			end
		end
		expect(notice):ok()
	end)

	it("invites a first score on an empty board", function()
		local profile = ProfileSchema.CreateDefault(1)
		local screen = CodexScreen.new(newParent(), {})
		screen:SetProfile(profile)
		screen:SetView(makeView(profile))
		screen._tab = "boards"
		screen._boardData = { boardId = "largest_bank", format = "energy", entries = {} }
		screen:Refresh()

		expect(screen._status.Visible):equal(true)
		expect(screen._status.Text):contains("Be first")
	end)

	it("never renders a masked achievement's real name", function()
		local profile = ProfileSchema.CreateDefault(1)
		local screen = CodexScreen.new(newParent(), {})
		screen:SetProfile(profile)
		screen:SetView(makeView(profile))
		screen:SetTab("achievements")

		for _, row in ipairs(screen._rows) do
			local marker = row:FindFirstChild("Marker")
			if marker and marker.Text == "?" then
				expect(row:FindFirstChild("Name").Text):equal("???")
			end
		end
	end)
end)
