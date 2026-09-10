--!strict
--[[
	AnalyticsService
	----------------
	Instrumentation. Every event a designer would want to answer "where do players
	stop playing?" flows through here.

	It writes to Roblox's own AnalyticsService where available, keeps an in-memory
	rolling summary for the live debug panel, and defines an explicit onboarding
	funnel so the drop-off between "joined" and "banked their first energy" is a
	number rather than a guess.

	Deliberately fire-and-forget: analytics must never be able to break gameplay, so
	every call is wrapped and failures are counted rather than raised.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BTS")
local Signal = require(Shared.Core.Signal)

local AnalyticsService = {}
AnalyticsService.Name = "AnalyticsService"
AnalyticsService.Dependencies = { "DataService" }
AnalyticsService.Priority = 8

--[[
	The onboarding funnel, in order. A player who reaches step N has reached every
	step before it, so drop-off is simply the difference between adjacent counts.
]]
AnalyticsService.FUNNEL = {
	{ id = "joined", name = "Joined" },
	{ id = "spawned", name = "Spawned in" },
	{ id = "saw_first_storm", name = "Saw a storm" },
	{ id = "first_capture_attempt", name = "Attempted a capture" },
	{ id = "first_capture", name = "Captured" },
	{ id = "first_bank", name = "Banked" },
	{ id = "first_upgrade", name = "Bought an upgrade" },
	{ id = "second_bank", name = "Banked again" },
	{ id = "first_death", name = "Died" },
	{ id = "reached_level_5", name = "Reached level 5" },
	{ id = "left_starter_region", name = "Left the starter district" },
	{ id = "first_rare_storm", name = "Found a rare storm" },
	{ id = "first_equipment", name = "Equipped an item" },
	{ id = "first_skill_point", name = "Spent a skill point" },
	{ id = "reached_level_20", name = "Reached level 20" },
	{ id = "first_region_unlock", name = "Unlocked a region" },
	{ id = "first_event", name = "Joined a world event" },
	{ id = "prestiged", name = "Prestiged" },
}

function AnalyticsService:Init()
	self._counts = {}
	self._funnelCounts = {}
	self._sessionStarts = {}
	self._failures = 0
	self._enabled = true

	self.EventTracked = Signal.new("AnalyticsService.EventTracked")

	local ok, service = pcall(function()
		return game:GetService("AnalyticsService")
	end)
	self._robloxAnalytics = ok and service or nil

	for _, step in ipairs(AnalyticsService.FUNNEL) do
		self._funnelCounts[step.id] = 0
	end
end

function AnalyticsService:Start()
	self._data = self.Registry:Get("DataService")

	Players.PlayerAdded:Connect(function(player)
		self._sessionStarts[player.UserId] = os.clock()
		self:TrackFunnel(player, "joined")
	end)

	Players.PlayerRemoving:Connect(function(player)
		local start = self._sessionStarts[player.UserId]
		if start then
			local duration = os.clock() - start
			self:Track(player, "session_end", { seconds = math.floor(duration) })

			local profile = self._data:GetProfile(player)
			if profile then
				profile.playTimeSeconds = (profile.playTimeSeconds or 0) + duration
				self._data:MarkDirty(player)
			end
		end
		self._sessionStarts[player.UserId] = nil
	end)
end

-- ============================================================================
-- Tracking
-- ============================================================================

--[[ Records a custom gameplay event. Never throws. ]]
function AnalyticsService:Track(player: Player?, eventName: string, data: { [string]: any }?)
	if not self._enabled then
		return
	end

	self._counts[eventName] = (self._counts[eventName] or 0) + 1
	self.EventTracked:Fire(player, eventName, data)

	if not self._robloxAnalytics or not player then
		return
	end

	local ok = pcall(function()
		self._robloxAnalytics:LogCustomEvent(player, eventName, 1, data)
	end)
	if not ok then
		self._failures += 1
	end
end

--[[
	Records a funnel step, exactly once per player per step. The "once" is what makes
	the numbers comparable: a player who banks fifty times is one conversion.
]]
function AnalyticsService:TrackFunnel(player: Player, stepId: string)
	local profile = self._data:GetProfile(player)
	if profile then
		profile.onboarding.tipsShown = profile.onboarding.tipsShown or {}
		local key = "funnel_" .. stepId
		if profile.onboarding.tipsShown[key] then
			return
		end
		profile.onboarding.tipsShown[key] = true
		self._data:MarkDirty(player)
	end

	self._funnelCounts[stepId] = (self._funnelCounts[stepId] or 0) + 1
	self:Track(player, "funnel_" .. stepId, {})

	if self._robloxAnalytics then
		local stepNumber = 1
		for index, step in ipairs(AnalyticsService.FUNNEL) do
			if step.id == stepId then
				stepNumber = index
				break
			end
		end
		pcall(function()
			self._robloxAnalytics:LogOnboardingFunnelStepEvent(player, stepNumber, stepId)
		end)
	end
end

--[[ Currency movement, split into sources and sinks for economy tuning. ]]
function AnalyticsService:TrackEconomy(player: Player, flowType: string, currency: string, amount: number, reason: string, balance: number)
	if not self._enabled then
		return
	end
	local key = ("economy_%s_%s_%s"):format(flowType, currency, reason)
	self._counts[key] = (self._counts[key] or 0) + amount

	if self._robloxAnalytics then
		pcall(function()
			self._robloxAnalytics:LogEconomyEvent(
				player,
				flowType == "source" and Enum.AnalyticsEconomyFlowType.Source or Enum.AnalyticsEconomyFlowType.Sink,
				currency,
				amount,
				balance,
				reason
			)
		end)
	end
end

function AnalyticsService:TrackProgression(player: Player, category: string, value: number)
	self:Track(player, "progression_" .. category, { value = value })

	if self._robloxAnalytics then
		pcall(function()
			self._robloxAnalytics:LogProgressionEvent(
				player,
				category,
				Enum.AnalyticsProgressionType.Complete,
				{},
				tostring(value)
			)
		end)
	end
end

-- ============================================================================
-- Reporting
-- ============================================================================

--[[
	The funnel as a readable table, with conversion between adjacent steps.
	Printed by the admin console and by the boot report in Studio.
]]
function AnalyticsService:GetFunnelReport(): string
	local lines = { "=== Onboarding funnel (this server) ===" }
	local previous = nil
	for _, step in ipairs(AnalyticsService.FUNNEL) do
		local count = self._funnelCounts[step.id] or 0
		local conversion = ""
		if previous and previous > 0 then
			conversion = ("  (%d%% of previous)"):format(math.floor((count / previous) * 100 + 0.5))
		end
		table.insert(lines, ("  %-28s %5d%s"):format(step.name, count, conversion))
		previous = count
	end
	return table.concat(lines, "\n")
end

function AnalyticsService:GetCounts()
	return self._counts
end

--[[ Top events by volume, for spotting a runaway event that is spamming. ]]
function AnalyticsService:GetTopEvents(limit: number?)
	local entries = {}
	for name, count in pairs(self._counts) do
		table.insert(entries, { name = name, count = count })
	end
	table.sort(entries, function(a, b)
		return a.count > b.count
	end)
	local out = {}
	for index = 1, math.min(limit or 20, #entries) do
		out[index] = entries[index]
	end
	return out
end

function AnalyticsService:SetEnabled(enabled: boolean)
	self._enabled = enabled
end

return AnalyticsService
