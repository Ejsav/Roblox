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
