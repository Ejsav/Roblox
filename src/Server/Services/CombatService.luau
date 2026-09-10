--!strict
--[[
	CombatService
	-------------
	Damage, healing, downed state and death. There is no PvP in BORROW THE STORM;
	everything here is the world hurting the player, so the model is deliberately
	simple and the interesting decisions live in the resistance stats.

	Downed state exists so that dying with friends nearby is a moment of tension
	rather than an instant loss. Solo players skip straight to death, because a
	downed timer with nobody coming is just a delay.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BTS")
local Signal = require(Shared.Core.Signal)
local Net = require(Shared.Net)
local Balance = require(Shared.Config.Balance)

local CombatService = {}
CombatService.Name = "CombatService"
CombatService.Dependencies = { "DataService", "StatsService" }
CombatService.Priority = 22

type CombatState = {
	health: number,
	maxHealth: number,
	lastDamageAt: number,
	invulnerableUntil: number,
	downed: boolean,
	downedUntil: number,
	reviverUserId: number?,
	reviveProgress: number,
	damageCapUsedAt: number,
	phoenixUsedAt: number,
	cheatDeathUsedAt: number,
	dirty: boolean,
}

function CombatService:Init()
	self._states = {} :: { [number]: CombatState }
	self._lastSyncAt = 0

	self.Damaged = Signal.new("CombatService.Damaged")
	self.Healed = Signal.new("CombatService.Healed")
	self.Downed = Signal.new("CombatService.Downed")
	self.Revived = Signal.new("CombatService.Revived")
	self.Died = Signal.new("CombatService.Died")
end

function CombatService:Start()
	self._data = self.Registry:Get("DataService")
	self._stats = self.Registry:Get("StatsService")
	self._carry = self.Registry:Find("CarryService")
	self._bank = self.Registry:Find("BankService")
	self._analytics = self.Registry:Find("AnalyticsService")

	Net.OnServerEvent("RequestRevive", function(player, targetUserId)
		self:BeginRevive(player, targetUserId)
	end)

	Players.PlayerAdded:Connect(function(player)
		player.CharacterAdded:Connect(function(character)
			self:_onCharacterAdded(player, character)
		end)
	end)
	Players.PlayerRemoving:Connect(function(player)
		self._states[player.UserId] = nil
	end)
end

function CombatService:_getState(player: Player): CombatState
	local state = self._states[player.UserId]
	if not state then
		local maxHealth = self._stats:GetStat(player, "maxHealth")
		state = {
			health = maxHealth,
			maxHealth = maxHealth,
			lastDamageAt = 0,
			invulnerableUntil = 0,
			downed = false,
			downedUntil = 0,
			reviverUserId = nil,
			reviveProgress = 0,
			damageCapUsedAt = -math.huge,
			phoenixUsedAt = -math.huge,
			cheatDeathUsedAt = -math.huge,
			dirty = true,
		}
		self._states[player.UserId] = state
	end
	return state
end

function CombatService:_onCharacterAdded(player: Player, character: Model)
	local state = self:_getState(player)
	local maxHealth = self._stats:GetStat(player, "maxHealth")

	state.health = maxHealth
	state.maxHealth = maxHealth
	state.downed = false
	state.reviverUserId = nil
	state.reviveProgress = 0
	state.invulnerableUntil = os.clock() + Balance.Survival.RESPAWN_INVULNERABILITY
	state.dirty = true

	-- Roblox's own Humanoid health is driven from ours rather than the other way
	-- round, so all the resistance maths stays in one place.
	local humanoid = character:WaitForChild("Humanoid", 5) :: Humanoid?
	if humanoid then
		humanoid.MaxHealth = maxHealth
		humanoid.Health = maxHealth
		humanoid.BreakJointsOnDeath = false
	end

	self:_sync(player)
end

-- ============================================================================
-- Damage and healing
-- ============================================================================

--[[
	Applies damage after every mitigation the player has earned.
	`source` is recorded for the death summary and for analytics, so a player who
	keeps dying to one thing can be told what it is.
]]
function CombatService:ApplyDamage(player: Player, amount: number, source: string): number
	if type(amount) ~= "number" or amount ~= amount or amount <= 0 then
		return 0
	end

	local state = self:_getState(player)
	local now = os.clock()

	if state.downed or now < state.invulnerableUntil then
		return 0
	end

	local character = player.Character
	if not character then
		return 0
	end

	local damage = amount

	-- Stormborn: exposure heals instead of harming.
	if source == "exposure" and self._stats:HasBehaviour(player, "exposure_heals") then
		self:Heal(player, amount, "stormborn")
		return 0
	end

	-- Ability-granted mitigation (Static Shield, Bulwark Stance).
	local abilities = self.Registry:Find("AbilityService")
	if abilities then
		damage = abilities:AbsorbDamage(player, damage, source)
		if damage <= 0 then
			return 0
		end
	end

	-- Bulwark: cap any single hit that would drop the player below a quarter health.
	if self._stats:HasBehaviour(player, "damage_cap") and (now - state.damageCapUsedAt) > 60 then
		local quarter = state.maxHealth * 0.25
		if state.health - damage < quarter and state.health > quarter then
			damage = state.health - quarter
			state.damageCapUsedAt = now
		end
	end

	state.health -= damage
	state.lastDamageAt = now
	state.dirty = true

	self.Damaged:Fire(player, damage, source)

	if state.health <= 0 then
		self:_handleLethal(player, state, source)
	end

	self:_applyToHumanoid(player, state)
	return damage
end

--[[ Resolves a hit that would kill: cheat-death effects, then downed or death. ]]
function CombatService:_handleLethal(player: Player, state: CombatState, source: string)
	local now = os.clock()

	-- Phoenix Circuit: survive at one integrity, with a full purge.
	if self._stats:HasBehaviour(player, "phoenix") and (now - state.phoenixUsedAt) > 600 then
		state.phoenixUsedAt = now
		state.health = 1
		state.invulnerableUntil = now + 2
		if self._carry then
			local carryState = self._carry:_getState(player)
			carryState.instability = 0
			carryState.dirty = true
		end
		Net.FireClient(player, "Notification", {
			kind = "good",
			title = "Phoenix Circuit",
			body = "You should not have survived that.",
		})
		return
	end

	-- Unkillable keystone: same idea, shorter cooldown, permanent healing penalty.
	if self._stats:HasBehaviour(player, "cheat_death") and (now - state.cheatDeathUsedAt) > 120 then
		state.cheatDeathUsedAt = now
		state.health = 1
		state.invulnerableUntil = now + 1.5
		Net.FireClient(player, "Notification", {
			kind = "good",
			title = "Unkillable",
			body = "Still standing.",
		})
		return
	end

	state.health = 0

	-- Downed only makes sense with somebody nearby who could actually revive.
	local nearby = self:_getNearbyLivingPlayers(player, Balance.Survival.REVIVE_RADIUS * 4)
	if #nearby > 0 then
		self:_setDowned(player, state, source)
	else
		self:Kill(player, source)
	end
end

function CombatService:Heal(player: Player, amount: number, source: string): number
	if type(amount) ~= "number" or amount ~= amount or amount <= 0 then
		return 0
	end
	local state = self:_getState(player)
	if state.downed then
		return 0
	end

	-- Unkillable halves all healing.
	if self._stats:HasBehaviour(player, "cheat_death") then
		amount *= 0.5
	end

	local before = state.health
	state.health = math.min(state.maxHealth, state.health + amount)
	local healed = state.health - before

	if healed > 0 then
		state.dirty = true
		self.Healed:Fire(player, healed, source)
		self:_applyToHumanoid(player, state)
	end
	return healed
end

function CombatService:GetHealth(player: Player): (number, number)
	local state = self:_getState(player)
	return state.health, state.maxHealth
end

function CombatService:IsDowned(player: Player): boolean
	return self:_getState(player).downed
end

function CombatService:SetInvulnerable(player: Player, seconds: number)
	local state = self:_getState(player)
	state.invulnerableUntil = math.max(state.invulnerableUntil, os.clock() + seconds)
end

function CombatService:_applyToHumanoid(player: Player, state: CombatState)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.MaxHealth = state.maxHealth
		-- Never let the Humanoid reach zero on its own: death is our decision, so
		-- that the carry split and the death cache always happen exactly once.
		humanoid.Health = math.max(state.health, state.downed and 1 or 0.01)
	end
end

-- ============================================================================
-- Downed and revive
-- ============================================================================

function CombatService:_getNearbyLivingPlayers(player: Player, radius: number): { Player }
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		return {}
	end
	local origin = (root :: BasePart).Position

	local nearby = {}
	for _, other in ipairs(Players:GetPlayers()) do
		if other ~= player then
			local otherState = self._states[other.UserId]
			if otherState and not otherState.downed and otherState.health > 0 then
				local otherRoot = other.Character and other.Character:FindFirstChild("HumanoidRootPart")
				if otherRoot and ((otherRoot :: BasePart).Position - origin).Magnitude <= radius then
					table.insert(nearby, other)
				end
			end
		end
	end
	return nearby
end

function CombatService:_setDowned(player: Player, state: CombatState, source: string)
	state.downed = true
	state.downedUntil = os.clock() + Balance.Survival.DOWNED_DURATION
	state.reviveProgress = 0
	state.reviverUserId = nil
	state.dirty = true

	self.Downed:Fire(player, source)
	Net.FireAllClients("Notification", {
		kind = "urgent",
		title = ("%s is down"):format(player.DisplayName),
		body = "Reach them before the timer runs out.",
		transient = true,
	})
	self:_sync(player)
end

--[[ Begins (or continues) a revive. Progress accumulates on the service tick. ]]
function CombatService:BeginRevive(reviver: Player, targetUserId: number): (boolean, string?)
	local target = Players:GetPlayerByUserId(targetUserId)
	if not target then
		return false, "no_target"
	end

	local targetState = self._states[targetUserId]
	if not targetState or not targetState.downed then
		return false, "not_downed"
	end

	local reviverRoot = reviver.Character and reviver.Character:FindFirstChild("HumanoidRootPart")
	local targetRoot = target.Character and target.Character:FindFirstChild("HumanoidRootPart")
	if not reviverRoot or not targetRoot then
		return false, "no_character"
	end

	local distance = ((reviverRoot :: BasePart).Position - (targetRoot :: BasePart).Position).Magnitude
	if distance > Balance.Survival.REVIVE_RADIUS then
		return false, "too_far"
	end

	targetState.reviverUserId = reviver.UserId
	return true, nil
end

--[[ Instantly restores a downed player. Used by Rally and by a completed revive. ]]
function CombatService:CompleteRevive(target: Player, healFraction: number?)
	local state = self._states[target.UserId]
	if not state or not state.downed then
		return false
	end

	state.downed = false
	state.reviverUserId = nil
	state.reviveProgress = 0
	state.health = state.maxHealth * (healFraction or 0.4)
	state.invulnerableUntil = os.clock() + 2.5
	state.dirty = true

	self.Revived:Fire(target)
	self:_applyToHumanoid(target, state)
	self:_sync(target)

	Net.FireClient(target, "Notification", {
		kind = "good",
		title = "Back up",
		body = "Your carry is intact.",
	})
	return true
end

-- ============================================================================
-- Death
-- ============================================================================

function CombatService:Kill(player: Player, source: string)
	local state = self:_getState(player)
	state.health = 0
	state.downed = false
	state.dirty = true

	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local position = root and (root :: BasePart).Position or Vector3.new()

	-- The carry split happens here, before the character is destroyed, so the cache
	-- lands where the player actually died.
	local summary = nil
	if self._carry then
		summary = self._carry:OnDeath(player, position)
	end

	if self._bank then
		self._bank:OnPlayerDied(player)
	end

	local profile = self._data:GetProfile(player)
	if profile then
		profile.records.totalDeaths = (profile.records.totalDeaths or 0) + 1
		if not profile.onboarding.seenFirstDeath then
			profile.onboarding.seenFirstDeath = true
		end
		self._data:MarkDirty(player)
	end

	self.Died:Fire(player, source, summary, position)

	Net.FireClient(player, "Notification", {
		kind = "bad",
		title = "You went down",
		body = summary and summary.lost > 0
			and ("Lost %d energy. %d recoverable at the site."):format(
				math.floor(summary.lost),
				math.floor(summary.cached)
			)
			or "Nothing carried.",
	})

	if self._analytics then
		self._analytics:Track(player, "death", {
			source = source,
			carried = summary and math.floor(summary.carried) or 0,
			lost = summary and math.floor(summary.lost) or 0,
		})
	end

	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.Health = 0
	end
end

-- ============================================================================
-- Tick
-- ============================================================================

function CombatService:Step(dt: number)
	local now = os.clock()

	for _, player in ipairs(Players:GetPlayers()) do
		local state = self._states[player.UserId]
		if not state then
			continue
		end

		-- Max health tracks the stat block, which can change mid-run from a buff.
		local maxHealth = self._stats:GetStat(player, "maxHealth")
		if maxHealth ~= state.maxHealth then
			local fraction = state.maxHealth > 0 and (state.health / state.maxHealth) or 1
			state.maxHealth = maxHealth
			state.health = math.min(maxHealth, maxHealth * fraction)
			state.dirty = true
		end

		if state.downed then
			-- Revive progress, or the timer running out.
			local reviver = state.reviverUserId and Players:GetPlayerByUserId(state.reviverUserId) or nil
			local stillClose = false
			if reviver then
				local reviverRoot = reviver.Character and reviver.Character:FindFirstChild("HumanoidRootPart")
				local targetRoot = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
				if reviverRoot and targetRoot then
					local distance = ((reviverRoot :: BasePart).Position - (targetRoot :: BasePart).Position).Magnitude
					stillClose = distance <= Balance.Survival.REVIVE_RADIUS
				end
			end

			if stillClose and reviver then
				local speed = self._stats:GetStat(reviver, "reviveSpeed")
				state.reviveProgress += (dt / Balance.Survival.REVIVE_DURATION) * speed
				state.dirty = true
				if state.reviveProgress >= 1 then
					self:CompleteRevive(player)
				end
			else
				state.reviverUserId = nil
				if state.reviveProgress > 0 then
					state.reviveProgress = math.max(0, state.reviveProgress - dt * 0.5)
					state.dirty = true
				end
			end

			if now >= state.downedUntil then
				self:Kill(player, "bled_out")
			end
			continue
		end

		-- Regeneration after a quiet period.
		if state.health < state.maxHealth
			and (now - state.lastDamageAt) >= Balance.Survival.HEALTH_REGEN_DELAY
		then
			local regen = self._stats:GetStat(player, "healthRegen")
			if regen > 0 then
				self:Heal(player, regen * dt, "regen")
			end
		end
	end

	if now - self._lastSyncAt >= Balance.Network.STATE_SYNC_INTERVAL then
		self._lastSyncAt = now
		for _, player in ipairs(Players:GetPlayers()) do
			local state = self._states[player.UserId]
			if state and state.dirty then
				state.dirty = false
				self:_sync(player)
			end
		end
	end
end

function CombatService:_sync(player: Player)
	local state = self._states[player.UserId]
	if not state then
		return
	end
	Net.FireClient(player, "CarryUpdate", {
		health = state.health,
		maxHealth = state.maxHealth,
		downed = state.downed,
		downedRemaining = state.downed and math.max(0, state.downedUntil - os.clock()) or 0,
		reviveProgress = state.reviveProgress,
		invulnerable = os.clock() < state.invulnerableUntil,
	})
end

return CombatService
