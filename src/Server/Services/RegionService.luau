--!strict
--[[
	RegionService
	-------------
	Tracks which region every player is in, enforces region gating, and applies the
	continuous exposure damage that makes a region's danger rating mean something.

	Region membership is sampled rather than computed per frame: a player's region can
	only change by moving, and a quarter-second sample is well inside human reaction
	time for the transition banner.

	Gating is enforced on the server by damage, not by an invisible wall. A player who
	finds a way into the Scour at level 10 is not blocked — they are cooked. That is a
	much better lesson than a barrier, and it preserves the "I got somewhere I should
	not be" moment that makes a big world worth exploring.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BTS")
local Signal = require(Shared.Core.Signal)
local Net = require(Shared.Net)
local Balance = require(Shared.Config.Balance)
local Regions = require(Shared.Config.Regions)

local RegionService = {}
RegionService.Name = "RegionService"
RegionService.Dependencies = { "DataService", "StatsService" }
RegionService.Priority = 12

local SAMPLE_INTERVAL = 0.25

function RegionService:Init()
	self._playerRegions = {} :: { [number]: string }
	self._playerSubregions = {} :: { [number]: string? }
	self._lastSampleAt = 0
	self._exposureAccumulator = {} :: { [number]: number }
	self._safeZones = {}

	self.RegionEntered = Signal.new("RegionService.RegionEntered")
	self.RegionExited = Signal.new("RegionService.RegionExited")
	self.SubregionEntered = Signal.new("RegionService.SubregionEntered")
end

function RegionService:Start()
	self._data = self.Registry:Get("DataService")
	self._stats = self.Registry:Get("StatsService")
	self._combat = self.Registry:Find("CombatService")
	self._carry = self.Registry:Find("CarryService")
	self._quests = self.Registry:Find("QuestService")
	self._progression = self.Registry:Find("ProgressionService")

	Players.PlayerRemoving:Connect(function(player)
		self._playerRegions[player.UserId] = nil
		self._playerSubregions[player.UserId] = nil
		self._exposureAccumulator[player.UserId] = nil
	end)
end

-- ============================================================================
-- Membership
-- ============================================================================

function RegionService:GetPlayerRegion(player: Player): string?
	return self._playerRegions[player.UserId]
end

function RegionService:GetPlayerSubregion(player: Player): string?
	return self._playerSubregions[player.UserId]
end

--[[ regionId -> number of players currently in it. Drives storm spawn density. ]]
function RegionService:GetPopulatedRegions(): { [string]: number }
	local counts = {}
	for _, regionId in pairs(self._playerRegions) do
		counts[regionId] = (counts[regionId] or 0) + 1
	end
	return counts
end

function RegionService:GetPlayersInRegion(regionId: string): { Player }
	local found = {}
	for userId, id in pairs(self._playerRegions) do
		if id == regionId then
			local player = Players:GetPlayerByUserId(userId)
			if player then
				table.insert(found, player)
			end
		end
	end
	return found
end

--[[ Resolves a position to a region and subregion. ]]
function RegionService:ResolvePosition(position: Vector3): (string?, string?)
	local region = Regions.FindContaining(position.X, position.Y, position.Z)
	if not region then
		return nil, nil
	end

	-- Subregions are small and can overlap; the closest centre wins.
	local bestSubregion, bestDistance = nil, math.huge
	for _, subregion in ipairs(region.subregions) do
		local centre = Vector3.new(subregion.center.X, subregion.center.Y, subregion.center.Z)
		local distance = (position - centre).Magnitude
		if distance <= subregion.radius and distance < bestDistance then
			bestSubregion, bestDistance = subregion.id, distance
		end
	end

	return region.id, bestSubregion
end

--[[ Samples every player's position and fires transition events. ]]
function RegionService:_sampleRegions()
	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not root then
			continue
		end

		local position = (root :: BasePart).Position
		local regionId, subregionId = self:ResolvePosition(position)
		if not regionId then
			continue
		end

		local previousRegion = self._playerRegions[player.UserId]
		local previousSubregion = self._playerSubregions[player.UserId]

		if regionId ~= previousRegion then
			self._playerRegions[player.UserId] = regionId
			if previousRegion then
				self.RegionExited:Fire(player, previousRegion)
			end
			self:_onRegionEntered(player, regionId, previousRegion)
		end

		if subregionId ~= previousSubregion then
			self._playerSubregions[player.UserId] = subregionId
			if subregionId then
				self.SubregionEntered:Fire(player, subregionId, regionId)
				if self._quests then
					self._quests:NotifyReach(player, { subregion = subregionId, region = regionId })
				end
			end
		end
	end
end

function RegionService:_onRegionEntered(player: Player, regionId: string, previousRegion: string?)
	local region = Regions.ById[regionId]
	if not region then
		return
	end

	local profile = self._data:GetProfile(player)
	local firstVisit = false

	if profile then
		firstVisit = not profile.regionsVisited[regionId]
		profile.regionsVisited[regionId] = true
		profile.lastRegion = regionId
		profile.regionStats[regionId] = profile.regionStats[regionId] or { captures = 0, banked = 0, deaths = 0 }

		-- Deepest region reached is a genuine bragging record.
		if region.order > (profile.records.deepestRegionReached or 1) then
			profile.records.deepestRegionReached = region.order
		end
		self._data:MarkDirty(player)
	end

	-- Whether the player is actually cleared for this region determines the tone of
	-- the banner: an arrival, or a warning.
	local unlocked, reason, requirement = self:IsPlayerCleared(player, regionId)

	self.RegionEntered:Fire(player, regionId, firstVisit)

	Net.FireClient(player, "RegionChanged", {
		regionId = regionId,
		name = region.name,
		subtitle = region.subtitle,
		danger = region.danger,
		recommendedLevel = region.recommendedLevel,
		firstVisit = firstVisit,
		cleared = unlocked,
		blockedReason = reason,
		requirement = requirement,
		palette = region.palette,
		atmosphere = region.atmosphere,
		audio = region.audio,
	})

	if self._quests then
		self._quests:NotifyReach(player, { region = regionId })
	end

	if firstVisit and self._progression then
		-- First arrival in a region is worth real XP; it is often the payoff for a
		-- long, dangerous traversal.
		self._progression:AwardXp(player, 150 * region.order, "region_discovery")
	end
end

-- ============================================================================
-- Gating
-- ============================================================================

--[[
	Whether a player meets a region's declared unlock requirements.
	Returns (cleared, reasonKey, requirementValue).
]]
function RegionService:IsPlayerCleared(player: Player, regionId: string): (boolean, string?, any)
	local profile = self._data:GetProfile(player)
	if not profile then
		return false, "no_profile", nil
	end
	return Regions.IsUnlocked(regionId, {
		level = profile.level,
		prestige = profile.prestige,
		completedQuests = profile.completedQuests,
		traversal = profile.traversal,
	})
end

--[[
	Exposure damage per second for a player in their current region.
	Returns 0 when their resistance covers the region's danger, which is what makes
	the Insulation track feel like a key rather than a stat.
]]
function RegionService:GetExposureDamage(player: Player): number
	local regionId = self._playerRegions[player.UserId]
	if not regionId then
		return 0
	end
	local region = Regions.ById[regionId]
	if not region or region.danger <= 1 then
		return 0
	end

	local survival = Balance.Survival
	local raw = survival.EXPOSURE_BASE_DAMAGE + survival.EXPOSURE_DAMAGE_PER_DANGER * (region.danger - 1)

	local resistance = math.clamp(self._stats:GetStat(player, "stormResist"), 0, survival.MAX_RESISTANCE)
	local mitigated = raw * (1 - resistance)

	-- The resistance required to shrug a region off entirely scales with its danger.
	-- Below that threshold you take a share; at or above it, nothing.
	local requiredResistance = math.min(survival.MAX_RESISTANCE, (region.danger - 1) * 0.085)
	if resistance >= requiredResistance then
		return 0
	end

	-- Ability and event mitigation.
	local abilities = self.Registry:Find("AbilityService")
	if abilities then
		mitigated *= abilities:GetExposureMultiplier(player)
	end

	-- Lightning Rod keystone doubles exposure against its owner.
	if self._stats:HasBehaviour(player, "aggro_magnet_shared_capture") then
		mitigated *= 2
	end

	return mitigated
end

-- ============================================================================
-- Safe zones
-- ============================================================================

--[[
	Registers a safe zone. Called by the world builder for bank stations, shelters
	and restored infrastructure.
]]
function RegionService:RegisterSafeZone(id: string, position: Vector3, radius: number)
	self._safeZones[id] = { position = position, radius = radius }
end

function RegionService:UnregisterSafeZone(id: string)
	self._safeZones[id] = nil
end

function RegionService:IsInSafeZone(position: Vector3): boolean
	for _, zone in pairs(self._safeZones) do
		if (position - zone.position).Magnitude <= zone.radius then
			return true
		end
	end
	return false
end

-- ============================================================================
-- Tick
-- ============================================================================

function RegionService:Step(dt: number)
	local now = os.clock()

	if now - self._lastSampleAt >= SAMPLE_INTERVAL then
		self._lastSampleAt = now
		self:_sampleRegions()
	end

	-- Exposure is accumulated and applied on a one-second cadence, so a player sees
	-- discrete damage ticks they can react to rather than a smoothly draining bar.
	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not root then
			continue
		end

		local inSafeZone = self:IsInSafeZone((root :: BasePart).Position)
		if self._carry then
			self._carry:SetSafeZone(player, inSafeZone)
		end

		if inSafeZone then
			self._exposureAccumulator[player.UserId] = 0
			continue
		end

		local damage = self:GetExposureDamage(player)
		if damage <= 0 then
			self._exposureAccumulator[player.UserId] = 0
			continue
		end

		local accumulated = (self._exposureAccumulator[player.UserId] or 0) + dt
		if accumulated >= Balance.Survival.EXPOSURE_TICK_INTERVAL then
			self._exposureAccumulator[player.UserId] = 0
			if self._combat then
				self._combat:ApplyDamage(player, damage * Balance.Survival.EXPOSURE_TICK_INTERVAL, "exposure")
			end
		else
			self._exposureAccumulator[player.UserId] = accumulated
		end
	end
end

--[[ Records a per-region statistic on the player's profile. ]]
function RegionService:RecordRegionStat(player: Player, statKey: string, amount: number)
	local profile = self._data:GetProfile(player)
	local regionId = self._playerRegions[player.UserId]
	if not profile or not regionId then
		return
	end
	local stats = profile.regionStats[regionId]
	if not stats then
		stats = { captures = 0, banked = 0, deaths = 0 }
		profile.regionStats[regionId] = stats
	end
	stats[statKey] = (stats[statKey] or 0) + amount
	self._data:MarkDirty(player)
end

return RegionService
