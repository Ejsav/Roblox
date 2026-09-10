--!strict
--[[
	CarryService
	------------
	The tension system. Owns how much unstable energy each player is carrying, how
	close it is to venting, and the capture chain that decides what it is worth.

	This is the service the whole game's risk/reward pivots on, so its rules are
	deliberately simple and legible:

	  * Carried energy is capped by the containment stat. Overflow is refused, or
	    held briefly in reserve if the player has that milestone.
	  * Instability climbs as a function of how FULL you are, not how long you have
	    been carrying. At half capacity it barely moves; at the brim it races. That
	    is what makes "one more capture" a real decision rather than a timer.
	  * Hitting full instability vents: a painful but survivable loss. Losing an
	    entire run to a bar filling up would read as arbitrary.
	  * The chain counts captures since the last bank and drives the risk multiplier.
	    It lapses on a timer, on death, and on banking.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BTS")
local Signal = require(Shared.Core.Signal)
local MathUtil = require(Shared.Core.MathUtil)
local Net = require(Shared.Net)
local Balance = require(Shared.Config.Balance)

local CarryService = {}
CarryService.Name = "CarryService"
CarryService.Dependencies = { "DataService", "StatsService" }
CarryService.Priority = 25

type CarryState = {
	carried: number,
	reserve: number,
	reserveExpiresAt: number,
	instability: number,
	chain: number,
	chainExpiresAt: number,
	bestGradeStreak: number,
	perfectStreak: number,
	lastCaptureAt: number,
	lastBankAt: number,
	inSafeZone: boolean,
	venting: boolean,
	sessionCaptures: number,
	distinctStormsThisRun: { [string]: boolean },
	markedCells: { [string]: number },
	dirty: boolean,
}

function CarryService:Init()
	self._states = {} :: { [number]: CarryState }
	self._lastSyncAt = 0

	self.CarryChanged = Signal.new("CarryService.CarryChanged")
	self.Vented = Signal.new("CarryService.Vented")
	self.ChainBroken = Signal.new("CarryService.ChainBroken")
	self.ChainExtended = Signal.new("CarryService.ChainExtended")
end

function CarryService:Start()
	self._data = self.Registry:Get("DataService")
	self._stats = self.Registry:Get("StatsService")
	self._combat = self.Registry:Find("CombatService")

	Net.OnServerEvent("RequestPurge", function(player)
		self:RequestPurge(player)
	end)

	Players.PlayerRemoving:Connect(function(player)
		self._states[player.UserId] = nil
	end)
end

-- ============================================================================
-- State access
-- ============================================================================

function CarryService:_getState(player: Player): CarryState
	local state = self._states[player.UserId]
	if not state then
		state = {
			carried = 0,
			reserve = 0,
			reserveExpiresAt = 0,
			instability = 0,
			chain = 0,
			chainExpiresAt = 0,
			bestGradeStreak = 0,
			perfectStreak = 0,
			lastCaptureAt = 0,
			lastBankAt = 0,
			inSafeZone = false,
			venting = false,
			sessionCaptures = 0,
			distinctStormsThisRun = {},
			markedCells = {},
			dirty = true,
		}
		self._states[player.UserId] = state
	end
	return state
end

function CarryService:GetCarried(player: Player): number
	return self:_getState(player).carried
end

function CarryService:GetInstability(player: Player): number
	return self:_getState(player).instability
end

function CarryService:GetChain(player: Player): number
	return self:_getState(player).chain
end

function CarryService:GetCapacity(player: Player): number
	return self._stats:GetStat(player, "capacity")
end

function CarryService:GetFillFraction(player: Player): number
	local capacity = self:GetCapacity(player)
	if capacity <= 0 then
		return 0
	end
	return math.clamp(self:_getState(player).carried / capacity, 0, 1)
end

function CarryService:GetSnapshot(player: Player)
	local state = self:_getState(player)
	local capacity = self:GetCapacity(player)
	return {
		carried = state.carried,
		reserve = state.reserve,
		capacity = capacity,
		fill = capacity > 0 and (state.carried / capacity) or 0,
		instability = state.instability,
		chain = state.chain,
		chainExpiresAt = state.chainExpiresAt,
		perfectStreak = state.perfectStreak,
		multiplier = self:GetMultiplier(player),
		inSafeZone = state.inSafeZone,
	}
end

-- ============================================================================
-- Adding and removing energy
-- ============================================================================

--[[
	Adds energy to a player's containment.
	Returns (accepted, overflow). Overflow is either held in reserve or lost,
	depending on whether the player has the Reserve Chamber milestone.
]]
function CarryService:AddEnergy(player: Player, amount: number, source: string?): (number, number)
	if amount <= 0 then
		return 0, 0
	end

	local state = self:_getState(player)
	local capacity = self:GetCapacity(player)

	-- Singularity Cell removes the hard ceiling; excess converts to instability
	-- instead of being refused.
	if self._stats:HasBehaviour(player, "soft_capacity") then
		local softOverflow = math.max(0, (state.carried + amount) - capacity)
		state.carried += amount
		if softOverflow > 0 then
			state.instability = math.min(1, state.instability + softOverflow / math.max(1, capacity) * 0.35)
		end
		state.dirty = true
		self:_notify(player, state)
		return amount, 0
	end

	local space = math.max(0, capacity - state.carried)
	local accepted = math.min(amount, space)
	local overflow = amount - accepted

	state.carried += accepted

	if overflow > 0 and self._stats:HasBehaviour(player, "overflow_reserve") then
		-- Overflow is parked for a few seconds; banking or freeing space reclaims it.
		state.reserve += overflow
		state.reserveExpiresAt = os.clock() + 8
		overflow = 0
	end

	state.dirty = true
	self:_notify(player, state)
	return accepted, overflow
end

--[[ Removes a flat amount. Returns how much was actually removed. ]]
function CarryService:DrainFlat(player: Player, amount: number, source: string?): number
	local state = self:_getState(player)
	local removed = math.min(state.carried, math.max(0, amount))
	state.carried -= removed
	if removed > 0 then
		state.dirty = true
		self:_notify(player, state)
	end
	return removed
end

--[[ Removes a fraction of the current carry. ]]
function CarryService:DrainFraction(player: Player, fraction: number, source: string?): number
	local state = self:_getState(player)
	return self:DrainFlat(player, state.carried * math.clamp(fraction, 0, 1), source)
end

--[[ Empties containment entirely and returns what was held. Used by banking. ]]
function CarryService:TakeAll(player: Player): number
	local state = self:_getState(player)
	local total = state.carried + state.reserve
	state.carried = 0
	state.reserve = 0
	state.instability = 0
	state.dirty = true
	self:_notify(player, state)
	return total
end

--[[ Takes a fraction for partial banking, preserving the chain. ]]
function CarryService:TakeFraction(player: Player, fraction: number): number
	local state = self:_getState(player)
	local taken = state.carried * math.clamp(fraction, 0, 1)
	state.carried -= taken
	-- Instability eases proportionally, because the load genuinely got lighter.
	state.instability *= (1 - math.clamp(fraction, 0, 1) * 0.8)
	state.dirty = true
	self:_notify(player, state)
	return taken
end

-- ============================================================================
-- Chain
-- ============================================================================

--[[
	Registers a capture against the chain.
	`chainValue` comes from the capture grade — an Overcharge advances the chain by
	two, a Weak capture does not advance it at all.
]]
function CarryService:RegisterCapture(player: Player, chainValue: number, grade: string, stormTypeId: string, cellId: string)
	local state = self:_getState(player)
	local now = os.clock()

	state.sessionCaptures += 1
	state.lastCaptureAt = now
	state.distinctStormsThisRun[stormTypeId] = true

	if chainValue > 0 then
		local previous = state.chain
		state.chain += chainValue

		-- The soft cap flattens further growth unless the player has removed it.
		if not self._stats:HasBehaviour(player, "no_chain_cap") then
			local cap = Balance.Capture.CHAIN_SOFT_CAP
			if self._stats:HasBehaviour(player, "raised_chain_cap") then
				cap *= 1.75
			end
			state.chain = math.min(state.chain, cap)
		end

		if state.chain > previous then
			self.ChainExtended:Fire(player, state.chain, previous)
		end
	end

	if grade == "Perfect" or grade == "Overcharge" then
		state.perfectStreak += 1
	else
		state.perfectStreak = 0
	end

	-- Borrowed Time removes the timeout entirely.
	if self._stats:HasBehaviour(player, "infinite_chain_timer") then
		state.chainExpiresAt = math.huge
	else
		local retention = self._stats:GetStat(player, "chainRetention")
		state.chainExpiresAt = now + Balance.Capture.CHAIN_TIMEOUT_SECONDS * retention
	end

	-- Conductor's Mark: repeat captures from the same cell pay more.
	state.markedCells[cellId] = (state.markedCells[cellId] or 0) + 1

	state.dirty = true
	self:_notify(player, state)
end

--[[ Ends the chain. `reason` distinguishes banking from dying for analytics. ]]
function CarryService:BreakChain(player: Player, reason: string)
	local state = self:_getState(player)
	if state.chain == 0 then
		return
	end

	-- Unbroken preserves the chain through one death per run.
	if reason == "death" and self._stats:HasBehaviour(player, "unbroken") and not state.usedUnbroken then
		state.usedUnbroken = true
		Net.FireClient(player, "Notification", {
			kind = "good",
			title = "Unbroken",
			body = "Your chain survived.",
		})
		return
	end

	local previous = state.chain
	state.chain = 0
	state.perfectStreak = 0
	state.markedCells = {}
	state.dirty = true

	self.ChainBroken:Fire(player, previous, reason)
	self:_notify(player, state)
end

--[[ The payout multiplier a bank would currently pay. ]]
function CarryService:GetMultiplier(player: Player): number
	local state = self:_getState(player)
	local Regions = require(Shared.Config.Regions)

	local regionService = self.Registry:Find("RegionService")
	local danger = 1
	if regionService then
		local regionId = regionService:GetPlayerRegion(player)
		local region = regionId and Regions.ById[regionId]
		if region then
			danger = region.danger
		end
	end

	local riskStat = self._stats:GetStat(player, "riskBonus")
	local multiplier = MathUtil.RiskMultiplier(state.chain, danger, riskStat * Balance.Bank.RISK_BONUS_SCALE)

	-- Hot bank: deciding quickly after a capture is worth a small premium, which
	-- rewards decisiveness over shuffling around near the station.
	if os.clock() - state.lastCaptureAt <= Balance.Bank.HOT_BANK_WINDOW then
		multiplier += Balance.Bank.HOT_BANK_BONUS
	end

	-- Perfect Resonance compounds consecutive Perfects without limit.
	if self._stats:HasBehaviour(player, "perfect_compounding") and state.perfectStreak > 0 then
		multiplier *= 1 + state.perfectStreak * 0.045
	end

	return multiplier
end

--[[ Mark stacks on a cell, for the Conductor's Mark passive. ]]
function CarryService:GetCellMarkStacks(player: Player, cellId: string): number
	return self:_getState(player).markedCells[cellId] or 0
end

-- ============================================================================
-- Instability
-- ============================================================================

--[[ Instability gained per second at the player's current fill. ]]
function CarryService:GetInstabilityRate(player: Player): number
	local state = self:_getState(player)
	local capacity = self:GetCapacity(player)
	if capacity <= 0 or state.carried <= 0 then
		return 0
	end

	local fill = math.clamp(state.carried / capacity, 0, 1.5)
	local carry = Balance.Carry
	local base = carry.INSTABILITY_BASE_RATE + carry.INSTABILITY_CURVE_RATE * (fill ^ carry.INSTABILITY_EXPONENT)

	local resistance = math.clamp(self._stats:GetStat(player, "instabilityResist"), 0, 0.95)
	local rate = base * (1 - resistance)

	-- Equilibrium: sprinting holds instability steady, which turns the Runner's
	-- movement into a genuine containment strategy.
	if self._stats:HasBehaviour(player, "motion_equilibrium") and self:_isSprinting(player) then
		return 0
	end

	-- Relentless inverts the usual advice: standing still is what costs you.
	if self._stats:HasBehaviour(player, "capture_refreshes_cooldowns") and not self:_isMoving(player) then
		rate *= 1.6
	end

	return rate
end

function CarryService:_isMoving(player: Player): boolean
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		return false
	end
	return (root :: BasePart).AssemblyLinearVelocity.Magnitude > 3
end

function CarryService:_isSprinting(player: Player): boolean
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		return false
	end
	local speed = Vector3.new(
		(root :: BasePart).AssemblyLinearVelocity.X,
		0,
		(root :: BasePart).AssemblyLinearVelocity.Z
	).Magnitude
	return speed > self._stats:GetStat(player, "moveSpeed") * 1.2
end

--[[ Steps instability for one player. Called from the service tick. ]]
function CarryService:_stepInstability(player: Player, state: CarryState, dt: number)
	if state.venting then
		return
	end

	if state.inSafeZone then
		state.instability = math.max(0, state.instability - Balance.Carry.SAFE_ZONE_DECAY_RATE * dt)
		state.dirty = true
		return
	end

	-- Grounded Recovery: holding still bleeds instability off fast.
	if self._stats:HasBehaviour(player, "grounded_recovery") and not self:_isMoving(player) then
		state.stillnessSeconds = (state.stillnessSeconds or 0) + dt
		if state.stillnessSeconds >= 2 then
			state.instability = math.max(0, state.instability - 0.18 * dt)
			state.dirty = true
			return
		end
	else
		state.stillnessSeconds = 0
	end

	local rate = self:GetInstabilityRate(player)
	if rate <= 0 then
		return
	end

	local previous = state.instability
	state.instability = math.min(1, state.instability + rate * dt)
	state.dirty = true

	-- Origin Stability caps instability just below critical, permanently.
	local ceilingParams = self._stats:GetTraitParams(player, "instability_ceiling")
	if ceilingParams then
		state.instability = math.min(state.instability, ceilingParams.ceiling)
	end

	local carry = Balance.Carry
	if previous < carry.INSTABILITY_WARNING and state.instability >= carry.INSTABILITY_WARNING then
		Net.FireClient(player, "Notification", {
			kind = "warning",
			title = "Containment unstable",
			body = "Bank soon.",
			transient = true,
		})
	end

	if state.instability >= 1 then
		self:_vent(player, state)
	end
end

--[[ A vent: violent, costly, and survivable. ]]
function CarryService:_vent(player: Player, state: CarryState)
	if state.venting then
		return
	end
	state.venting = true

	local carry = Balance.Carry
	local protection = math.clamp(self._stats:GetStat(player, "ventProtection"), 0, 0.9)
	local lossFraction = carry.VENT_ENERGY_LOSS_FRACTION * (1 - protection)
	local lost = state.carried * lossFraction

	state.carried -= lost
	state.instability = carry.VENT_INSTABILITY_AFTER
	state.dirty = true

	local damage = carry.VENT_DAMAGE * (1 - protection * 0.6)
	if self._combat then
		self._combat:ApplyDamage(player, damage, "vent")
	end

	self.Vented:Fire(player, lost, damage)
	Net.FireClient(player, "VentOccurred", {
		lost = lost,
		damage = damage,
		remaining = state.carried,
		staggerSeconds = protection >= 0.5 and 0 or carry.VENT_STAGGER_SECONDS,
	})

	self:_notify(player, state)

	-- A short lockout so a vent cannot immediately re-trigger while the player is
	-- still recovering from the first one.
	task.delay(1.5, function()
		local current = self._states[player.UserId]
		if current then
			current.venting = false
		end
	end)
end

--[[ Manual purge: trade a slice of the carry for instability headroom. ]]
function CarryService:RequestPurge(player: Player): (boolean, string?)
	if not self._stats:HasBehaviour(player, "manual_purge") then
		return false, "not_unlocked"
	end

	local abilities = self.Registry:Find("AbilityService")
	if abilities and not abilities:IsReady(player, "purge") then
		return false, "on_cooldown"
	end

	local state = self:_getState(player)
	if state.instability <= 0.05 then
		return false, "nothing_to_purge"
	end

	local Abilities = require(Shared.Config.Abilities)
	local effects = Abilities.ResolveEffects("purge", self._stats:GetStats(player))

	local removed = math.min(state.instability, effects.instabilityRemoved)
	state.instability -= removed
	state.carried *= (1 - effects.energyCostFraction)
	state.dirty = true

	if abilities then
		abilities:StartCooldown(player, "purge")
	end

	self:_notify(player, state)
	return true, nil
end

-- ============================================================================
-- Safe zones, death and reset
-- ============================================================================

function CarryService:SetSafeZone(player: Player, inSafeZone: boolean)
	local state = self:_getState(player)
	if state.inSafeZone ~= inSafeZone then
		state.inSafeZone = inSafeZone
		state.dirty = true
		self:_notify(player, state)
	end
end

--[[
	Handles death: splits the carry into lost, cached and (with the Dead Man's Bank
	milestone) auto-banked portions.
	Returns a summary so DeathService can spawn the cache and tell the player.
]]
function CarryService:OnDeath(player: Player, deathPosition: Vector3)
	local state = self:_getState(player)
	local carried = state.carried + state.reserve

	if carried <= 0 then
		self:BreakChain(player, "death")
		return { carried = 0, lost = 0, cached = 0, banked = 0 }
	end

	local carry = Balance.Carry
	local protection = math.clamp(self._stats:GetStat(player, "lossProtection"), -1, 0.85)

	-- Everything On Red: no protection, no cache, nothing.
	if self._stats:HasBehaviour(player, "total_loss_on_death") then
		state.carried = 0
		state.reserve = 0
		state.instability = 0
		state.dirty = true
		self:BreakChain(player, "death")
		self:_notify(player, state)
		return { carried = carried, lost = carried, cached = 0, banked = 0 }
	end

	local banked = 0
	if self._stats:HasBehaviour(player, "deathbank") then
		banked = carried * 0.25
	end

	local remaining = carried - banked
	local lostFraction = math.clamp(carry.DEATH_LOSS_FRACTION * (1 - protection), 0, 1)
	local cachedFraction = math.clamp(carry.DEATH_CACHE_FRACTION * (1 + protection), 0, 1 - lostFraction)

	local lost = remaining * lostFraction
	local cached = remaining * cachedFraction
	-- Whatever neither fraction claimed stays with the player through the respawn.
	local retained = remaining - lost - cached

	state.carried = retained
	state.reserve = 0
	state.instability = 0
	state.dirty = true

	self:BreakChain(player, "death")
	self:_notify(player, state)

	return {
		carried = carried,
		lost = lost,
		cached = cached,
		banked = banked,
		retained = retained,
		cachePosition = deathPosition,
	}
end

--[[ Called after banking: resets chain and instability, records the timestamp. ]]
function CarryService:OnBanked(player: Player, preserveChain: boolean?)
	local state = self:_getState(player)
	state.lastBankAt = os.clock()
	state.instability = 0
	state.usedUnbroken = nil
	if not preserveChain then
		self:BreakChain(player, "banked")
		state.distinctStormsThisRun = {}
	end
	state.dirty = true
	self:_notify(player, state)
end

function CarryService:GetDistinctStormsThisRun(player: Player): number
	local count = 0
	for _ in pairs(self:_getState(player).distinctStormsThisRun) do
		count += 1
	end
	return count
end

function CarryService:HasBankedSince(player: Player, seconds: number): boolean
	local state = self:_getState(player)
	return (os.clock() - state.lastBankAt) <= seconds
end

--[[ True when the last event was a bank and no capture has happened since — used
     by the Cold Start passive to force a Perfect on the next capture. ]]
function CarryService:IsFirstCaptureAfterBank(player: Player): boolean
	local state = self:_getState(player)
	return state.lastBankAt > state.lastCaptureAt
end

-- ============================================================================
-- Tick and replication
-- ============================================================================

function CarryService:Step(dt: number)
	local now = os.clock()

	for _, player in ipairs(Players:GetPlayers()) do
		local state = self._states[player.UserId]
		if not state then
			continue
		end

		self:_stepInstability(player, state, dt)

		-- Reclaim reserve into free capacity, or drop it when it lapses.
		if state.reserve > 0 then
			if now >= state.reserveExpiresAt then
				state.reserve = 0
				state.dirty = true
			else
				local capacity = self:GetCapacity(player)
				local space = math.max(0, capacity - state.carried)
				if space > 0 then
					local moved = math.min(space, state.reserve)
					state.carried += moved
					state.reserve -= moved
					state.dirty = true
				end
			end
		end

		-- Chain expiry.
		if state.chain > 0 and now >= state.chainExpiresAt then
			self:BreakChain(player, "timeout")
		end
	end

	-- Batched replication on a fixed cadence rather than per change.
	if now - self._lastSyncAt >= Balance.Network.STATE_SYNC_INTERVAL then
		self._lastSyncAt = now
		for _, player in ipairs(Players:GetPlayers()) do
			local state = self._states[player.UserId]
			if state and state.dirty then
				state.dirty = false
				Net.FireClient(player, "CarryUpdate", self:GetSnapshot(player))
			end
		end
	end
end

--[[ Marks state dirty; the batched sync picks it up on the next cadence. ]]
function CarryService:_notify(player: Player, state: CarryState)
	state.dirty = true
	self.CarryChanged:Fire(player, state)
end

--[[ Forces an immediate sync, used after a discrete event like a vent or bank. ]]
function CarryService:ForceSync(player: Player)
	local state = self._states[player.UserId]
	if state then
		state.dirty = false
		Net.FireClient(player, "CarryUpdate", self:GetSnapshot(player))
	end
end

return CarryService
