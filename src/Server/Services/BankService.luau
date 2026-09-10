--!strict
--[[
	BankService
	-----------
	Converts carried energy into Watts. The moment the whole risk/reward loop resolves.

	The payout breakdown is computed explicitly and sent to the client as separate
	lines, because "you got 4,812 Watts" teaches a player nothing but "1,204 base ×
	2.4 risk × 1.35 bank rate + 6% hot bank" teaches them how to earn more next time.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BTS")
local Signal = require(Shared.Core.Signal)
local Net = require(Shared.Net)
local Balance = require(Shared.Config.Balance)
local Regions = require(Shared.Config.Regions)

local BankService = {}
BankService.Name = "BankService"
BankService.Dependencies = { "DataService", "StatsService", "CarryService", "EconomyService", "ProgressionService" }
BankService.Priority = 35

function BankService:Init()
	self._stationsById = {}
	self._banking = {} :: { [number]: boolean }
	self._streaks = {} :: { [number]: number }

	self.Banked = Signal.new("BankService.Banked")

	-- Build the station lookup from the region atlas.
	for _, region in ipairs(Regions.List) do
		for _, station in ipairs(region.bankStations) do
			self._stationsById[station.id] = {
				id = station.id,
				name = station.name,
				tier = station.tier,
				regionId = region.id,
				position = Vector3.new(station.position.X, station.position.Y, station.position.Z),
			}
		end
	end
end

function BankService:Start()
	self._data = self.Registry:Get("DataService")
	self._stats = self.Registry:Get("StatsService")
	self._carry = self.Registry:Get("CarryService")
	self._economy = self.Registry:Get("EconomyService")
	self._progression = self.Registry:Get("ProgressionService")
	self._quests = self.Registry:Find("QuestService")
	self._analytics = self.Registry:Find("AnalyticsService")
	self._combat = self.Registry:Find("CombatService")

	Net.OnServerEvent("RequestBank", function(player, stationId, partial)
		self:RequestBank(player, stationId, partial == true)
	end)

	Net.OnServerEvent("RequestRemoteBank", function(player)
		self:RequestRemoteBank(player)
	end)

	Players.PlayerRemoving:Connect(function(player)
		self._banking[player.UserId] = nil
		self._streaks[player.UserId] = nil
	end)
end

function BankService:GetStation(stationId: string)
	return self._stationsById[stationId]
end

function BankService:GetAllStations()
	return self._stationsById
end

--[[ The nearest station to a position, and its distance. ]]
function BankService:GetNearestStation(position: Vector3)
	local best, bestDistance = nil, math.huge
	for _, station in pairs(self._stationsById) do
		local distance = (station.position - position).Magnitude
		if distance < bestDistance then
			best, bestDistance = station, distance
		end
	end
	return best, bestDistance
end

-- ============================================================================
-- Payout calculation
-- ============================================================================

--[[
	Computes the full payout breakdown without committing anything.
	The client calls the equivalent path for its live projection, so both must agree
	exactly — which is why every term here comes from a shared source.
]]
function BankService:CalculatePayout(player: Player, energy: number, penalty: number?)
	local multiplier = self._carry:GetMultiplier(player)
	local bankRate = self._stats:GetStat(player, "bankRate")

	local lines = {}

	local base = energy * Balance.Bank.WATTS_PER_ENERGY
	table.insert(lines, { label = "Energy", value = base, kind = "base" })

	local afterRisk = base * multiplier
	if multiplier > 1.0001 then
		table.insert(lines, {
			label = ("Risk ×%.2f"):format(multiplier),
			value = afterRisk - base,
			kind = "multiplier",
		})
	end

	local afterRate = afterRisk * bankRate
	if bankRate > 1.0001 then
		table.insert(lines, {
			label = ("Bank efficiency ×%.2f"):format(bankRate),
			value = afterRate - afterRisk,
			kind = "multiplier",
		})
	end

	local total = afterRate

	-- Streak Ledger: consecutive banks without dying compound.
	local streak = self._streaks[player.UserId] or 0
	if streak > 0 and self._stats:HasBehaviour(player, "bank_streak") then
		local streakBonus = math.min(0.5, streak * 0.03)
		local gained = total * streakBonus
		total += gained
		table.insert(lines, { label = ("Streak ×%d"):format(streak), value = gained, kind = "bonus" })
	end

	-- Arbitrage: a premium for banking in a region you have mastered.
	if self._stats:HasBehaviour(player, "region_premium") then
		local masteries = self.Registry:Find("MasteryService")
		local regionService = self.Registry:Find("RegionService")
		if masteries and regionService then
			local regionId = regionService:GetPlayerRegion(player)
			if regionId then
				local masteryLevel = masteries:GetLevel(player, "region:" .. regionId)
				if masteryLevel > 0 then
					local gained = total * math.min(0.35, masteryLevel * 0.02)
					total += gained
					table.insert(lines, { label = "Regional premium", value = gained, kind = "bonus" })
				end
			end
		end
	end

	-- World event multipliers.
	local events = self.Registry:Find("WorldEventService")
	if events then
		local eventMultiplier = events:GetBankRateMultiplier(player)
		if eventMultiplier > 1.0001 then
			local gained = total * (eventMultiplier - 1)
			total += gained
			table.insert(lines, { label = "Event bonus", value = gained, kind = "bonus" })
		end
	end

	-- Penalty last, so the player sees what the convenience cost them.
	local penaltyFraction = penalty or 0
	if penaltyFraction > 0 then
		local lost = total * penaltyFraction
		total -= lost
		table.insert(lines, { label = "Remote transfer fee", value = -lost, kind = "penalty" })
	end

	return {
		energy = energy,
		watts = math.floor(total + 0.5),
		multiplier = multiplier,
		bankRate = bankRate,
		lines = lines,
	}
end

--[[ Preview for the HUD: what would I get if I banked right now? ]]
function BankService:GetProjection(player: Player)
	local carried = self._carry:GetCarried(player)
	if carried <= 0 then
		return nil
	end
	return self:CalculatePayout(player, carried, 0)
end

-- ============================================================================
-- Banking
-- ============================================================================

function BankService:RequestBank(player: Player, stationId: string, partial: boolean)
	if self._banking[player.UserId] then
		return false, "already_banking"
	end

	local station = self._stationsById[stationId]
	if not station then
		return false, "unknown_station"
	end

	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		return false, "no_character"
	end

	-- Server-side proximity check. The client's own reachability is irrelevant.
	local distance = ((root :: BasePart).Position - station.position).Magnitude
	if distance > 26 then
		return false, "too_far"
	end

	local carried = self._carry:GetCarried(player)
	if carried <= 0 then
		Net.FireClient(player, "BankResult", { success = false, reason = "nothing_to_bank" })
		return false, "nothing_to_bank"
	end

	if partial and not self._stats:HasBehaviour(player, "partial_bank") then
		partial = false
	end

	self._banking[player.UserId] = true

	-- Banking is a commitment with a wind-up, not an instant button.
	task.delay(Balance.Bank.BANK_DURATION, function()
		self._banking[player.UserId] = nil
		if not player.Parent then
			return
		end
		self:_commitBank(player, station, partial, 0)
	end)

	return true, nil
end

function BankService:RequestRemoteBank(player: Player)
	if not self._stats:HasBehaviour(player, "remote_bank") then
		Net.FireClient(player, "BankResult", { success = false, reason = "not_unlocked" })
		return false, "not_unlocked"
	end
	if self._banking[player.UserId] then
		return false, "already_banking"
	end

	local carried = self._carry:GetCarried(player)
	if carried <= 0 then
		Net.FireClient(player, "BankResult", { success = false, reason = "nothing_to_bank" })
		return false, "nothing_to_bank"
	end

	local lastRemote = self._lastRemoteBank and self._lastRemoteBank[player.UserId] or 0
	if os.clock() - lastRemote < Balance.Bank.REMOTE_BANK_COOLDOWN then
		Net.FireClient(player, "BankResult", { success = false, reason = "on_cooldown" })
		return false, "on_cooldown"
	end

	self._lastRemoteBank = self._lastRemoteBank or {}
	self._lastRemoteBank[player.UserId] = os.clock()

	-- A Relay Beacon in range halves the fee.
	local penalty = Balance.Bank.REMOTE_BANK_PENALTY
	local abilities = self.Registry:Find("AbilityService")
	if abilities and abilities:IsInBeaconRange(player) then
		penalty *= 0.5
	end

	self._banking[player.UserId] = true
	task.delay(Balance.Bank.BANK_DURATION, function()
		self._banking[player.UserId] = nil
		if not player.Parent then
			return
		end
		self:_commitBank(player, nil, false, penalty)
	end)

	return true, nil
end

--[[ Actually moves the energy. Everything above this is screening and ceremony. ]]
function BankService:_commitBank(player: Player, station: any?, partial: boolean, penalty: number)
	local energy = partial
		and self._carry:TakeFraction(player, 0.5)
		or self._carry:TakeAll(player)

	if energy <= 0 then
		return
	end

	local payout = self:CalculatePayout(player, energy, penalty)

	-- House Edge: half of all banks pay triple, half pay nothing.
	if self._stats:HasBehaviour(player, "coinflip_bank") then
		if math.random() < 0.5 then
			payout.watts *= 3
			table.insert(payout.lines, { label = "House Edge — won", value = payout.watts * (2 / 3), kind = "bonus" })
		else
			payout.watts = 0
			table.insert(payout.lines, { label = "House Edge — lost", value = 0, kind = "penalty" })
		end
	end

	-- Windfall: a chance for the whole deposit to pay double.
	if self._stats:HasBehaviour(player, "bank_crit") then
		local chance = math.min(0.35, self._stats:GetStat(player, "luck") * 0.06)
		if math.random() < chance then
			payout.watts *= 2
			table.insert(payout.lines, { label = "Windfall", value = payout.watts * 0.5, kind = "bonus" })
		end
	end

	local granted = self._economy:Award(player, "watts", payout.watts, "bank")

	local xp = energy * Balance.Bank.XP_PER_ENERGY
	self._progression:AwardXp(player, xp, "bank")

	-- Records.
	self._progression:UpdateRecord(player, "largestBank", payout.watts, "Largest Bank")
	self._progression:UpdateRecord(player, "highestMultiplier", payout.multiplier, "Highest Multiplier")
	self._progression:UpdateRecord(player, "longestChain", self._carry:GetChain(player), "Longest Chain")
	self._progression:IncrementRecord(player, "totalBanked", energy)

	-- Streak.
	self._streaks[player.UserId] = (self._streaks[player.UserId] or 0) + 1

	-- Banking is also a safe moment: it restores integrity, unless the player took
	-- Stormborn and gave that up.
	if self._combat and not self._stats:HasBehaviour(player, "exposure_heals") then
		self._combat:Heal(player, 25, "bank")
	end

	self._carry:OnBanked(player, partial)

	local profile = self._data:GetProfile(player)
	if profile and not profile.onboarding.seenFirstBank then
		profile.onboarding.seenFirstBank = true
		self._data:MarkDirty(player)
	end

	self.Banked:Fire(player, energy, payout, station)

	Net.FireClient(player, "BankResult", {
		success = true,
		energy = energy,
		watts = granted,
		multiplier = payout.multiplier,
		lines = payout.lines,
		stationName = station and station.name or "Remote Uplink",
		partial = partial,
		streak = self._streaks[player.UserId],
	})

	if self._quests then
		self._quests:NotifyBank(player, {
			energy = energy,
			watts = granted,
			stationId = station and station.id or nil,
			regionId = station and station.regionId or nil,
		})
	end

	local masteries = self.Registry:Find("MasteryService")
	if masteries then
		masteries:AwardXp(player, "banking", xp * 0.3)
	end

	if self._analytics then
		self._analytics:Track(player, "bank", {
			energy = math.floor(energy),
			watts = granted,
			multiplier = payout.multiplier,
			remote = station == nil,
			partial = partial,
		})
	end
end

--[[ Death breaks the bank streak. ]]
function BankService:OnPlayerDied(player: Player)
	self._streaks[player.UserId] = 0
end

function BankService:GetStreak(player: Player): number
	return self._streaks[player.UserId] or 0
end

return BankService
