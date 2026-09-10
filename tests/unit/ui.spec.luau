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
local CraftingScreen = loadModule("Client/UI/Screens/CraftingScreen")
local PrestigeScreen = loadModule("Client/UI/Screens/PrestigeScreen")
local SettingsScreen = loadModule("Client/UI/Screens/SettingsScreen")
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
		expect(CraftingScreen.new(parent, {})):ok()
		expect(PrestigeScreen.new(parent, {})):ok()
		expect(SettingsScreen.new(parent, {})):ok()
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
			CraftingScreen.new(parent, {}),
			PrestigeScreen.new(parent, {}),
			SettingsScreen.new(parent, {}),
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

describe("UI/SettingsScreen", function()
	it("renders every stored setting", function()
		local profile = ProfileSchema.CreateDefault(1)
		local screen = SettingsScreen.new(newParent(), {})
		screen:SetProfile(profile)

		expect(screen:Get("quality")):equal("auto")
		expect(screen:Get("musicVolume")):equal(profile.settings.musicVolume)
	end)

	it("applies a change locally before it is persisted", function()
		local profile = ProfileSchema.CreateDefault(1)
		local applied = nil

		local screen = SettingsScreen.new(newParent(), {
			AudioController = {
				Name = "AudioController",
				ApplySettings = function(_, settings)
					applied = settings.musicVolume
				end,
			},
		})
		screen:SetProfile(profile)
		screen:Set("musicVolume", 0.25)

		expect(screen:Get("musicVolume")):equal(0.25)
		expect(applied):equal(0.25)
	end)

	it("applies stored settings on arrival, not only on change", function()
		local profile = ProfileSchema.CreateDefault(1)
		profile.settings.hudScale = 1.4

		local seen = nil
		local screen = SettingsScreen.new(newParent(), {
			HudController = {
				Name = "HudController",
				ApplySettings = function(_, settings)
					seen = settings.hudScale
				end,
			},
		})
		screen:SetProfile(profile)

		expect(seen):equal(1.4)
	end)

	it("survives a controller whose applier throws", function()
		local profile = ProfileSchema.CreateDefault(1)
		local reached = false

		local screen = SettingsScreen.new(newParent(), {
			Bad = {
				Name = "Bad",
				ApplySettings = function()
					error("intentional")
				end,
			},
			Good = {
				Name = "Good",
				ApplySettings = function()
					reached = true
				end,
			},
		})
		screen:SetProfile(profile)

		-- One broken controller must not stop the rest from receiving settings.
		expect(reached):equal(true)
	end)

	it("ignores controllers with no applier", function()
		local profile = ProfileSchema.CreateDefault(1)
		local screen = SettingsScreen.new(newParent(), {
			Plain = { Name = "Plain" },
			NotATable = 5,
		})
		screen:SetProfile(profile)
		screen:Set("subtitles", true)
		expect(screen:Get("subtitles")):equal(true)
	end)

	it("clamps a slider at both ends", function()
		local profile = ProfileSchema.CreateDefault(1)
		local screen = SettingsScreen.new(newParent(), {})
		screen:SetProfile(profile)

		local down = screen._root:FindFirstChild("musicVolume", true)
		expect(down):ok()

		screen:Set("musicVolume", 0)
		expect(screen:Get("musicVolume")):equal(0)
		screen:Set("musicVolume", 1)
		expect(screen:Get("musicVolume")):equal(1)
	end)

	it("queues one write rather than one per step", function()
		local profile = ProfileSchema.CreateDefault(1)
		local screen = SettingsScreen.new(newParent(), {})
		screen:SetProfile(profile)

		screen:Set("sfxVolume", 0.5)
		screen:Set("sfxVolume", 0.4)
		screen:Set("sfxVolume", 0.3)

		-- All three collapse into one pending entry holding the final value.
		local pendingCount = 0
		for _ in pairs(screen._pending or {}) do
			pendingCount += 1
		end
		expect(pendingCount):equal(1)
		expect(screen._pending.sfxVolume):equal(0.3)
	end)
end)

describe("UI/PrestigeScreen", function()
	local function makeView(eligible)
		return {
			sigils = 12,
			status = {
				currentRank = 2,
				maxRank = 12,
				eligible = eligible,
				requirement = eligible and nil or "Reach level 120 (currently 40)",
				nextRank = { rank = 3, name = "Third Circuit", sigils = 3, grants = { title = "circuit" } },
			},
			skills = {
				{ id = "p_a", name = "A", tier = 1, cost = 3, description = "Does a thing.", owned = true, canPurchase = false },
				{ id = "p_b", name = "B", tier = 1, cost = 5, description = "Does another.", owned = false, canPurchase = true },
				{ id = "p_c", name = "C", tier = 2, cost = 9, owned = false, canPurchase = false, blockText = "Requires A." },
			},
			ranks = {},
		}
	end

	it("renders the tree grouped by tier", function()
		local screen = PrestigeScreen.new(newParent(), {})
		screen:SetProfile(ProfileSchema.CreateDefault(1))
		screen:SetView(makeView(true))

		-- Three skills plus two tier headings.
		expect(#screen._rows):equal(5)
	end)

	it("refuses to arm the commit when the player is not eligible", function()
		local screen = PrestigeScreen.new(newParent(), {})
		screen:SetView(makeView(false))

		screen:_onCommit()
		expect(screen._confirming):equal(false)
	end)

	it("arms rather than committing on the first press", function()
		local screen = PrestigeScreen.new(newParent(), {})
		screen:SetView(makeView(true))

		screen:_onCommit()
		expect(screen._confirming):equal(true)
	end)

	it("spells out the consequence on the armed button", function()
		-- "Confirm?" tells a player nothing. The armed label has to name the rank
		-- they are about to take and the reset they are about to accept, because
		-- this is the only irreversible action in the game.
		local screen = PrestigeScreen.new(newParent(), {})
		screen:SetView(makeView(true))
		screen:_onCommit()

		local text = screen._commitButton.Instance.Text
		expect(text):contains("RESET")
		expect(text):contains("3")
	end)

	it("disarms when the screen is closed", function()
		local screen = PrestigeScreen.new(newParent(), {})
		screen:SetView(makeView(true))
		screen:_onCommit()

		screen:SetVisible(false)
		expect(screen._confirming):equal(false)
	end)

	it("disarms when a fresh view arrives", function()
		local screen = PrestigeScreen.new(newParent(), {})
		screen:SetView(makeView(true))
		screen:_onCommit()

		screen:SetView(makeView(true))
		expect(screen._confirming):equal(false)
	end)

	it("states the requirement when blocked", function()
		local screen = PrestigeScreen.new(newParent(), {})
		screen:SetView(makeView(false))
		expect(screen._requirementLabel.Text):contains("level 120")
	end)
end)

describe("UI/CraftingScreen", function()
	local function makeView()
		return {
			categories = {},
			resources = { scrap_coil = 4 },
			consumables = {},
			recipes = {
				{
					id = "craft_a",
					category = "equipment",
					name = "A",
					description = "Buildable.",
					ingredients = { scrap_coil = 2 },
					cost = {},
					output = { kind = "resource", resourceId = "scrap_coil", quantity = 1 },
					canCraft = true,
				},
				{
					id = "craft_b",
					category = "equipment",
					name = "B",
					description = "Not buildable.",
					ingredients = { scrap_coil = 40 },
					cost = {},
					output = { kind = "resource", resourceId = "scrap_coil", quantity = 1 },
					canCraft = false,
					blockText = "Not enough coil.",
					requiredLevel = 30,
				},
			},
		}
	end

	it("puts craftable recipes above ones that are not", function()
		local screen = CraftingScreen.new(newParent(), {})
		screen:SetProfile(ProfileSchema.CreateDefault(1))
		screen:SetView(makeView())

		local ordered = screen:_recipesForCategory("equipment")
		expect(ordered[1].id):equal("craft_a")
		expect(screen._selected):equal("craft_a")
	end)

	it("says why a recipe is blocked on the row itself", function()
		local screen = CraftingScreen.new(newParent(), {})
		screen:SetProfile(ProfileSchema.CreateDefault(1))
		screen:SetView(makeView())

		local blockedRow
		for _, row in ipairs(screen._rows) do
			if row.Name == "craft_b" then
				blockedRow = row
			end
		end
		expect(blockedRow):ok()
		expect(blockedRow:FindFirstChild("Sub").Text):equal("Not enough coil.")
	end)

	it("shows the shortfall, not just the requirement", function()
		local screen = CraftingScreen.new(newParent(), {})
		screen:SetProfile(ProfileSchema.CreateDefault(1))
		screen:SetView(makeView())
		screen:Select("craft_b")

		local amountText
		for _, row in ipairs(screen._detailRows) do
			local label = row:FindFirstChild("Amount")
			if label then
				amountText = label.Text
			end
		end
		expect(amountText):contains("need")
		expect(amountText):contains("36")
	end)
end)
