--!strict
--[[
	CaptureService
	--------------
	Grades and awards every capture. This is the most security-sensitive service in
	the game: it converts a client keypress into permanent value, so it trusts the
	client for exactly one thing — that a press happened — and recomputes everything
	else from server state.

	What the client sends:  cellId, strikeId, its own timestamp, its own position.
	What the server checks:
	  * the strike exists, is live, and belongs to that cell
	  * the player has not already taken this strike
	  * the client timestamp is within a plausible latency window of server time
	  * the client position is within a plausible error of the server's own record
	  * the player is inside their effective capture radius of the strike point
	  * any behaviour-specific rule (altitude, airborne, decoy, polarity)

	Only then does it grade, and the grade is computed from the SERVER's clock.
	Latency compensation is bounded and one-directional: it can forgive a late packet
	up to MAX_LATENCY_COMPENSATION, never manufacture an early one.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BTS")
local Signal = require(Shared.Core.Signal)
local MathUtil = require(Shared.Core.MathUtil)
local Net = require(Shared.Net)
local Balance = require(Shared.Config.Balance)
local StormTypes = require(Shared.Config.StormTypes)

local CaptureService = {}
CaptureService.Name = "CaptureService"
CaptureService.Dependencies = { "DataService", "StatsService", "StormService", "CarryService" }
CaptureService.Priority = 30

function CaptureService:Init()
	self._lastAttemptAt = {} :: { [number]: number }
	self._retryUsed = {} :: { [number]: { [string]: boolean } }

	self.Captured = Signal.new("CaptureService.Captured")
	self.Missed = Signal.new("CaptureService.Missed")
end

function CaptureService:Start()
	self._data = self.Registry:Get("DataService")
	self._stats = self.Registry:Get("StatsService")
	self._storms = self.Registry:Get("StormService")
	self._carry = self.Registry:Get("CarryService")
	self._combat = self.Registry:Find("CombatService")
	self._loot = self.Registry:Find("LootService")
	self._progression = self.Registry:Find("ProgressionService")
	self._quests = self.Registry:Find("QuestService")
	self._analytics = self.Registry:Find("AnalyticsService")
	self._antiCheat = self.Registry:Find("AntiCheatService")
	self._collections = self.Registry:Find("CollectionService_BTS")

	Net.OnServerEvent("AttemptCapture", function(player, cellId, strikeId, clientTime, clientPosition)
		self:HandleAttempt(player, cellId, strikeId, clientTime, clientPosition)
	end)

	Players.PlayerRemoving:Connect(function(player)
		self._lastAttemptAt[player.UserId] = nil
		self._retryUsed[player.UserId] = nil
	end)
end

-- ============================================================================
-- Grading
-- ============================================================================

--[[
	Converts a signed timing error into a grade.
	`normalisedDistance` is |pressTime - peakTime| / windowHalfWidth, so 0 is a dead
	centre press and 1 sits exactly on the window edge.

	For an inverted strike (Null Pocket, and Inversion when flipped) the scoring is
	reversed: pressing at the peak is the failure and the payout is in the silence.
]]
function CaptureService.Grade(normalisedDistance: number, inverted: boolean): (string?, any)
	local distance = normalisedDistance
	if inverted then
		-- 0 becomes the worst possible result and 1 the best; anything past the
		-- window is still a miss.
		if distance > 1 then
			return nil, nil
		end
		distance = 1 - distance
	end

	if distance > 1 then
		return nil, nil
	end

	for _, grade in ipairs(Balance.Capture.GRADES) do
		if distance <= grade.maxDistance then
			return grade.id, grade
		end
	end
	return nil, nil
end

--[[ Looks up a grade definition by id. ]]
function CaptureService.GetGrade(gradeId: string)
	for _, grade in ipairs(Balance.Capture.GRADES) do
		if grade.id == gradeId then
			return grade
		end
	end
	return nil
end

-- ============================================================================
-- Attempt handling
-- ============================================================================

--[[
	Screens an attempt for validity. Returns (ok, reason, context) where context
	carries everything the award path needs so it is not recomputed.
]]
function CaptureService:_screen(player: Player, cellId: string, strikeId: string, clientTime: number, clientPosition: Vector3)
	local now = os.clock()

	-- Attempt cooldown: stops a client spamming presses across a window hoping to
	-- catch a favourable server-side grade.
	local lastAttempt = self._lastAttemptAt[player.UserId] or 0
	if now - lastAttempt < Balance.Capture.ATTEMPT_COOLDOWN then
		return false, "too_fast", nil
	end
	self._lastAttemptAt[player.UserId] = now

	local strike = self._storms:GetStrike(strikeId)
	if not strike then
		return false, "no_such_strike", nil
	end
	if strike.cellId ~= cellId then
		return false, "strike_cell_mismatch", nil
	end
	if strike.resolved then
		return false, "strike_resolved", nil
	end
	if strike.capturedBy[player.UserId] then
		return false, "already_captured", nil
	end

	local cell = self._storms:GetCell(cellId)
	if not cell then
		return false, "no_such_cell", nil
	end
	if cell.charge < 1 then
		return false, "cell_depleted", nil
	end

	-- Server-side position is authoritative; the client's is only used to detect
	-- how far it has drifted.
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		return false, "no_character", nil
	end
	local serverPosition = (root :: BasePart).Position

	local positionError = (serverPosition - clientPosition).Magnitude
	if positionError > Balance.Capture.MAX_POSITION_ERROR_STUDS then
		if self._antiCheat then
			self._antiCheat:Report(player, "capture_position_mismatch", positionError)
		end
		return false, "position_mismatch", nil
	end

	-- Behaviours may move the strike during its telegraph.
	local strikePosition = strike.position
	if cell.behaviour.strikePosition then
		local ok, moved = pcall(cell.behaviour.strikePosition, cell, cell.behaviourState, strike, now)
		if ok and moved then
			strikePosition = moved
		end
	end

	local radius = self._stats:GetCaptureRadius(player)
	local distance = (serverPosition - strikePosition).Magnitude
	if distance > radius + strike.radius then
		return false, "out_of_range", nil
	end

	-- Behaviour-specific eligibility.
	if cell.behaviour.validate then
		local context = self._storms:_buildContext(cell, { player = player, capturePosition = serverPosition })
		local ok, valid, reason = pcall(cell.behaviour.validate, cell, cell.behaviourState, strike, player, context)
		if ok and not valid then
			return false, reason or "behaviour_rejected", { cell = cell, strike = strike, position = serverPosition }
		end
	end

	-- Timing. The server's own clock decides, with bounded forgiveness for latency.
	local serverTime = workspace:GetServerTimeNow()
	local latency = math.clamp(serverTime - clientTime, 0, Balance.Capture.MAX_LATENCY_COMPENSATION)
	local pressAt = now - latency

	local windowHalfWidth = self._stats:GetCaptureWindow(player, strike.windowHalfWidth)
	local timingError = math.abs(pressAt - strike.peakAt)
	local normalised = timingError / math.max(0.01, windowHalfWidth)

	return true, nil, {
		cell = cell,
		strike = strike,
		position = serverPosition,
		strikePosition = strikePosition,
		normalised = normalised,
		windowHalfWidth = windowHalfWidth,
		latency = latency,
	}
end

--[[ Entry point from the network layer. ]]
function CaptureService:HandleAttempt(player: Player, cellId: string, strikeId: string, clientTime: number, clientPosition: Vector3)
	local ok, reason, context = self:_screen(player, cellId, strikeId, clientTime, clientPosition)

	if not ok then
		Net.FireClient(player, "CaptureResult", {
			strikeId = strikeId,
			success = false,
			reason = reason,
		})
		-- Choosing a decoy is a gameplay failure, not a rejected packet, and it has
		-- its own consequence.
		if reason == "decoy" and context then
			self:_handleDecoyChoice(player, context.cell, context.strike)
		end
		return
	end

	local grade, gradeDefinition = CaptureService.Grade(context.normalised, context.strike.inverted)

	-- Cold Start: the first capture after banking is forced to Perfect.
	if self._stats:HasBehaviour(player, "cold_start") and self._carry:IsFirstCaptureAfterBank(player) then
		grade = "Perfect"
		gradeDefinition = CaptureService.GetGrade("Perfect")
	end

	if not grade then
		self:_handleMiss(player, context)
		return
	end

	-- Virtuoso: anything below Good is worth nothing at all.
	if grade == "Weak" and self._stats:HasBehaviour(player, "virtuoso_grading") then
		self:_handleMiss(player, context)
		return
	end

	self:_award(player, context, grade, gradeDefinition)
end

--[[ A miss: shock damage, instability, behaviour hook, and a salvage chance. ]]
function CaptureService:_handleMiss(player: Player, context: any)
	local cell = context.cell
	local strike = context.strike

	-- Auto-Stabiliser can salvage a miss into a Weak capture.
	local stability = self._stats:GetStat(player, "captureStability")
	if stability > 0 and math.random() < stability then
		local weak = CaptureService.GetGrade("Weak")
		self:_award(player, context, "Weak", weak, true)
		return
	end

	-- Static Cling recovers a fraction of the energy from a clean miss.
	local Abilities = require(Shared.Config.Abilities)
	local profile = self._data:GetProfile(player)
	if profile and profile.passivesOwned and profile.passivesOwned.static_cling then
		local passive = Abilities.PassiveById.static_cling
		local salvage = cell.storm.yield.base * passive.params.salvageFraction
		self._carry:AddEnergy(player, salvage, "static_cling")
	end

	local damage = Balance.Capture.MISS_SHOCK_DAMAGE
	local shockResist = math.clamp(self._stats:GetStat(player, "shockResist"), 0, 0.8)
	if self._combat then
		self._combat:ApplyDamage(player, damage * (1 - shockResist), "capture_miss")
	end

	-- A miss makes the load less stable, which is what makes greed compound.
	local carryState = self._carry:_getState(player)
	carryState.instability = math.min(1, carryState.instability + Balance.Capture.MISS_INSTABILITY_ADD)
	carryState.dirty = true

	if cell.behaviour.onMiss then
		local behaviourContext = self._storms:_buildContext(cell, {
			player = player,
			peakCapturePlayer = strike.inverted and player or nil,
		})
		pcall(cell.behaviour.onMiss, cell, cell.behaviourState, strike, behaviourContext)
	end

	self.Missed:Fire(player, cell, strike)
	Net.FireClient(player, "CaptureResult", {
		strikeId = strike.id,
		success = false,
		reason = "mistimed",
		normalised = context.normalised,
	})

	if self._analytics then
		self._analytics:Track(player, "capture_missed", {
			stormTypeId = cell.stormTypeId,
			normalised = context.normalised,
		})
	end
end

function CaptureService:_handleDecoyChoice(player: Player, cell: any, strike: any)
	local params = cell.storm.params
	if self._combat and params.wrongChoiceDamage then
		local shockResist = math.clamp(self._stats:GetStat(player, "shockResist"), 0, 0.8)
		self._combat:ApplyDamage(player, params.wrongChoiceDamage * (1 - shockResist), "mirror_flash_decoy")
	end
	Net.FireClient(player, "CaptureResult", {
		strikeId = strike.id,
		success = false,
		reason = "decoy",
	})
end

-- ============================================================================
-- Awarding
-- ============================================================================

--[[ Computes and grants everything a successful capture produces. ]]
function CaptureService:_award(player: Player, context: any, grade: string, gradeDefinition: any, salvaged: boolean?)
	local cell = context.cell
	local strike = context.strike
	local storm = cell.storm

	-- Base yield with per-strike escalation.
	local perStrike = storm.yield.perStrikeScale or 1
	local baseYield = storm.yield.base * (perStrike ^ math.max(0, (strike.index or 1) - 1))

	-- Variance keeps two identical captures from feeling identical.
	local variance = storm.yield.variance or 0
	if variance > 0 then
		baseYield *= 1 + (math.random() * 2 - 1) * variance
	end

	local yieldMultiplier = gradeDefinition.yieldScale
	local bonusEnergy = 0
	local announce = nil
	local applyLift = nil

	-- Behaviour hook: the mechanic's own contribution to the award.
	if cell.behaviour.onCapture then
		local behaviourContext = self._storms:_buildContext(cell, {
			player = player,
			capturePosition = context.position,
			awardedEnergy = baseYield * yieldMultiplier,
		})
		local ok, result = pcall(cell.behaviour.onCapture, cell, cell.behaviourState, strike, behaviourContext)
		if ok and result then
			yieldMultiplier *= (result.yieldScale or 1)
			bonusEnergy += (result.bonusEnergy or 0)
			announce = result.announce
			applyLift = result.applyLift
		end
	end

	-- Player stat: capture yield.
	yieldMultiplier *= self._stats:GetStat(player, "captureYield")

	-- Conductor's Mark: repeat captures from a marked cell pay more.
	local profile = self._data:GetProfile(player)
	if profile and profile.passivesOwned and profile.passivesOwned.conductor_mark then
		local Abilities = require(Shared.Config.Abilities)
		local params = Abilities.PassiveById.conductor_mark.params
		local stacks = math.min(self._carry:GetCellMarkStacks(player, cell.id), params.maxStacks)
		yieldMultiplier *= 1 + stacks * params.markBonus
	end

	-- High Stakes: a full containment pays more per capture.
	if profile and profile.passivesOwned and profile.passivesOwned.high_stakes then
		local Abilities = require(Shared.Config.Abilities)
		local params = Abilities.PassiveById.high_stakes.params
		if self._carry:GetFillFraction(player) >= params.fillThreshold then
			yieldMultiplier *= 1 + params.yieldBonus
		end
	end

	-- Brinkmanship: yield scales with how close instability is to critical.
	if self._stats:HasBehaviour(player, "instability_yield_scaling") then
		yieldMultiplier *= 1 + self._carry:GetInstability(player) * 0.5
	end

	-- Saturation: yield scales with how full the cell already is.
	if self._stats:HasBehaviour(player, "yield_scales_with_fill") then
		yieldMultiplier *= 1 + self._carry:GetFillFraction(player) * 0.35
	end

	-- Overclock and other timed ability effects.
	local abilities = self.Registry:Find("AbilityService")
	if abilities then
		yieldMultiplier *= abilities:GetCaptureYieldMultiplier(player)
	end

	-- World event modifiers.
	local events = self.Registry:Find("WorldEventService")
	if events then
		yieldMultiplier *= events:GetCaptureYieldMultiplier(player)
	end

	local finalEnergy = math.max(0, baseYield * yieldMultiplier + bonusEnergy)

	-- Commit.
	self._storms:MarkStrikeCaptured(strike.id, player)
	local accepted, overflow = self._carry:AddEnergy(player, finalEnergy, "capture")

	local chainValue = gradeDefinition.chainValue
	self._carry:RegisterCapture(player, chainValue, grade, cell.stormTypeId, cell.id)

	-- Perfect captures with Clean Extraction add no instability at all.
	if (grade == "Perfect" or grade == "Overcharge") and self._stats:HasBehaviour(player, "perfect_no_instability") then
		local carryState = self._carry:_getState(player)
		carryState.instability = math.max(0, carryState.instability - 0.02)
	end

	-- Overcharge with Surplus Draw restores integrity.
	if grade == "Overcharge" and self._stats:HasBehaviour(player, "overcharge_heal") and self._combat then
		self._combat:Heal(player, 12, "overcharge")
	end

	-- Momentum Capture: sprinting captures stack speed.
	if profile and profile.passivesOwned and profile.passivesOwned.momentum_capture then
		local Abilities = require(Shared.Config.Abilities)
		local params = Abilities.PassiveById.momentum_capture.params
		self._stats:ApplyBuff(player, {
			id = "momentum_capture",
			label = "Momentum",
			effects = { increased = { moveSpeed = params.speedPerStack, sprintSpeed = params.speedPerStack } },
			durationSeconds = params.decayDelay,
			maxStacks = params.maxStacks,
			source = "passive",
		})
	end

	-- Relentless: captures shave cooldowns.
	if abilities and self._stats:HasBehaviour(player, "capture_refreshes_cooldowns") then
		abilities:ReduceAllCooldowns(player, 2)
	end

	-- XP.
	local xp = finalEnergy * Balance.Bank.XP_PER_ENERGY * gradeDefinition.xpScale * 0.35
	if self._progression then
		self._progression:AwardXp(player, xp, "capture")
	end

	-- Loot.
	local drops = nil
	if self._loot then
		drops = self._loot:RollCaptureDrop(player, cell, grade)
	end

	-- Discovery of a new storm type is a first-time moment worth marking.
	if profile then
		local previouslySeen = profile.stormsDiscovered[cell.stormTypeId]
		profile.stormsDiscovered[cell.stormTypeId] = (previouslySeen or 0) + 1
		if not previouslySeen then
			self._data:MarkDirty(player)
			Net.FireClient(player, "DiscoveryMade", {
				kind = "storm",
				id = cell.stormTypeId,
				name = storm.name,
				description = storm.teaches,
			})
			profile.records.rareStormsFound = (profile.records.rareStormsFound or 0)
				+ (StormTypes.IsBroadcastWorthy(cell.stormTypeId) and 1 or 0)
		end
		profile.records.totalCaptures = (profile.records.totalCaptures or 0) + 1
		if grade == "Perfect" or grade == "Overcharge" then
			local streak = self._carry:_getState(player).perfectStreak
			if streak > (profile.records.mostPerfectCaptures or 0) then
				profile.records.mostPerfectCaptures = streak
			end
		end
		self._data:MarkDirty(player)
	end

	-- Quest and mastery progress.
	if self._quests then
		self._quests:NotifyCapture(player, {
			stormTypeId = cell.stormTypeId,
			regionId = cell.regionId,
			grade = grade,
			rarity = storm.rarity,
			energy = finalEnergy,
		})
	end
	local masteries = self.Registry:Find("MasteryService")
	if masteries then
		masteries:AwardXp(player, "capture", xp * 0.5)
		masteries:AwardXp(player, "region:" .. cell.regionId, xp * 0.25)
	end

	self.Captured:Fire(player, cell, strike, {
		grade = grade,
		energy = finalEnergy,
		accepted = accepted,
		overflow = overflow,
	})

	Net.FireClient(player, "CaptureResult", {
		strikeId = strike.id,
		cellId = cell.id,
		success = true,
		grade = grade,
		energy = finalEnergy,
		accepted = accepted,
		overflow = overflow,
		chain = self._carry:GetChain(player),
		multiplier = self._carry:GetMultiplier(player),
		normalised = context.normalised,
		salvaged = salvaged or false,
		announce = announce,
		applyLift = applyLift,
		drops = drops,
	})

	self._carry:ForceSync(player)

	if self._analytics then
		self._analytics:Track(player, "capture", {
			stormTypeId = cell.stormTypeId,
			regionId = cell.regionId,
			grade = grade,
			energy = math.floor(finalEnergy),
			chain = self._carry:GetChain(player),
		})
	end
end

--[[
	Server-side test seam and admin helper: force a capture without a client packet.
	Used by the automated integration tests and the developer console.
]]
function CaptureService:ForceCapture(player: Player, strikeId: string, grade: string?)
	local strike = self._storms:GetStrike(strikeId)
	if not strike then
		return false, "no_such_strike"
	end
	local cell = self._storms:GetCell(strike.cellId)
	if not cell then
		return false, "no_such_cell"
	end

	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local position = root and (root :: BasePart).Position or strike.position

	local gradeId = grade or "Perfect"
	local gradeDefinition = CaptureService.GetGrade(gradeId)
	if not gradeDefinition then
		return false, "bad_grade"
	end

	self:_award(player, {
		cell = cell,
		strike = strike,
		position = position,
		strikePosition = strike.position,
		normalised = 0,
		windowHalfWidth = strike.windowHalfWidth,
		latency = 0,
	}, gradeId, gradeDefinition)

	return true, nil
end

return CaptureService
