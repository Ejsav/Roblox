--!strict
--[[
	MasteryService
	--------------
	Long-horizon progression that runs alongside levels and never resets.

	Masteries answer "what have I actually got good at?" rather than "how long have I
	played?". They accumulate from the activity they describe, so a player who only
	ever works the Sattermarsh has a Sattermarsh mastery and knows it.

	Mastery levels feed small permanent bonuses and unlock cosmetic titles, which is
	deliberately modest: masteries are a record of what you do, not a second stat
	economy that has to be optimised.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BTS")
local Signal = require(Shared.Core.Signal)
local Net = require(Shared.Net)
local Regions = require(Shared.Config.Regions)

local MasteryService = {}
MasteryService.Name = "MasteryService"
MasteryService.Dependencies = { "DataService", "StatsService", "ProgressionService" }
MasteryService.Priority = 44

--[[ Static mastery tracks. Region masteries are generated from the atlas. ]]
local TRACKS = {
	{ id = "capture", name = "Capture", description = "Energy taken from storms." },
	{ id = "banking", name = "Banking", description = "Energy successfully secured." },
	{ id = "movement", name = "Movement", description = "Distance covered under your own power." },
	{ id = "exploration", name = "Exploration", description = "Secrets found and ground covered." },
	{ id = "equipment", name = "Equipment", description = "Items acquired, crafted and refined." },
	{ id = "events", name = "Events", description = "World events survived and won." },
}

local MAX_MASTERY_LEVEL = 50

function MasteryService:Init()
	self._tracks = {}

	for _, track in ipairs(TRACKS) do
		self._tracks[track.id] = track
	end

	-- One mastery per region, so "I know this place" is a real, visible statistic.
	for _, region in ipairs(Regions.List) do
		local id = "region:" .. region.id
		self._tracks[id] = {
			id = id,
			name = region.name,
			description = ("Time and work spent in %s."):format(region.name),
			regionId = region.id,
		}
	end

	self.MasteryLevelled = Signal.new("MasteryService.MasteryLevelled")
end

function MasteryService:Start()
	self._data = self.Registry:Get("DataService")
	self._stats = self.Registry:Get("StatsService")
	self._progression = self.Registry:Get("ProgressionService")
end

--[[ XP required to go from `level` to `level + 1`. Steeper than the runner curve,
     because a mastery is meant to take a long time. ]]
function MasteryService.XpForLevel(level: number): number
	return math.floor(400 * (level ^ 1.6) + 250 * level + 300)
end

function MasteryService:GetLevel(player: Player, trackId: string): number
	local profile = self._data:GetProfile(player)
	if not profile then
		return 0
	end
	local entry = profile.masteries[trackId]
	return entry and entry.level or 0
end

function MasteryService:GetProgress(player: Player, trackId: string)
	local profile = self._data:GetProfile(player)
	if not profile then
		return nil
	end
	local entry = profile.masteries[trackId] or { xp = 0, level = 0 }
	local needed = MasteryService.XpForLevel(entry.level + 1)
	return {
		trackId = trackId,
		level = entry.level,
		xp = entry.xp,
		xpForNext = needed,
		fraction = needed > 0 and math.clamp(entry.xp / needed, 0, 1) or 1,
	}
end

--[[ Awards mastery XP and resolves any level-ups it produces. ]]
function MasteryService:AwardXp(player: Player, trackId: string, amount: number)
	if amount <= 0 or not self._tracks[trackId] then
		return
	end

	local profile = self._data:GetProfile(player)
	if not profile then
		return
	end

	local entry = profile.masteries[trackId]
	if not entry then
		entry = { xp = 0, level = 0 }
		profile.masteries[trackId] = entry
	end

	if entry.level >= MAX_MASTERY_LEVEL then
		return
	end

	entry.xp += amount

	local levelled = false
	while entry.level < MAX_MASTERY_LEVEL do
		local needed = MasteryService.XpForLevel(entry.level + 1)
		if entry.xp < needed then
			break
		end
		entry.xp -= needed
		entry.level += 1
		levelled = true
	end

	self._data:MarkDirty(player)

	if levelled then
		self._stats:Invalidate(player)
		self.MasteryLevelled:Fire(player, trackId, entry.level)

		local track = self._tracks[trackId]
		Net.FireClient(player, "UnlockGranted", {
			kind = "mastery",
			id = trackId,
			name = ("%s Mastery %d"):format(track.name, entry.level),
			detail = { description = track.description, level = entry.level },
		})

		-- Every tenth mastery level awards a title.
		if entry.level % 10 == 0 then
			local titleId = ("mastery_%s_%d"):format(trackId:gsub(":", "_"), entry.level)
			self._progression:GrantUnlock(player, "title", titleId, ("%s %d"):format(track.name, entry.level))
		end
	end
end

--[[
	Passive stat contribution from masteries, applied by StatsService.
	Small and broad: a fraction of a percent per level, so fifty levels across many
	tracks is a real but never dominant advantage.
]]
function MasteryService:ApplyToAccumulator(Stats: any, accumulator: any, profile: any)
	local bonusesByTrack = {
		capture = { increased = { captureYield = 0.004 } },
		banking = { increased = { bankRate = 0.004 } },
		movement = { increased = { moveSpeed = 0.003, sprintSpeed = 0.003 } },
		exploration = { flat = { scanRange = 6, luck = 0.01 } },
		equipment = { flat = { craftQuality = 0.01 } },
		events = { increased = { xpGain = 0.003 } },
	}

	for trackId, entry in pairs(profile.masteries or {}) do
		local level = entry.level or 0
		if level <= 0 then
			continue
		end

		local bonus = bonusesByTrack[trackId]
		if bonus then
			local label = ("%s Mastery %d"):format(self._tracks[trackId] and self._tracks[trackId].name or trackId, level)
			for kind, statMap in pairs(bonus) do
				for statId, amount in pairs(statMap) do
					Stats.Contribute(accumulator, statId, kind, amount * level, label)
				end
			end
		elseif trackId:match("^region:") then
			-- Region mastery reduces exposure in that region specifically; the effect
			-- is applied by RegionService, so nothing is contributed here.
		end
	end
end

--[[ Full mastery panel view. ]]
function MasteryService:BuildView(player: Player)
	local profile = self._data:GetProfile(player)
	if not profile then
		return nil
	end

	local general = {}
	local regional = {}

	for trackId, track in pairs(self._tracks) do
		local progress = self:GetProgress(player, trackId)
		local row = {
			id = trackId,
			name = track.name,
			description = track.description,
			level = progress.level,
			xp = progress.xp,
			xpForNext = progress.xpForNext,
			fraction = progress.fraction,
			maxLevel = MAX_MASTERY_LEVEL,
		}
		if track.regionId then
			row.regionId = track.regionId
			table.insert(regional, row)
		else
			table.insert(general, row)
		end
	end

	table.sort(general, function(a, b)
		return a.id < b.id
	end)
	table.sort(regional, function(a, b)
		local regionA = Regions.ById[a.regionId]
		local regionB = Regions.ById[b.regionId]
		return (regionA and regionA.order or 0) < (regionB and regionB.order or 0)
	end)

	return { general = general, regional = regional, maxLevel = MAX_MASTERY_LEVEL }
end

--[[ Region mastery reduces that region's exposure damage slightly. ]]
function MasteryService:GetRegionExposureReduction(player: Player, regionId: string): number
	local level = self:GetLevel(player, "region:" .. regionId)
	return math.min(0.3, level * 0.006)
end

return MasteryService
