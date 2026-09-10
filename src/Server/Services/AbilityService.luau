--!strict
--[[
	AbilityService
	--------------
	Active ability activation, cooldowns, charges, channelled effects and the timed
	world objects some abilities leave behind (beacons, domes, anchors).

	Everything an ability does that lasts longer than an instant is modelled here as
	an "effect" with an expiry, so other services can ask simple questions —
	"is this player shielded?", "is anyone's beacon covering them?" — without knowing
	which ability produced the answer.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BTS")
local Signal = require(Shared.Core.Signal)
local Net = require(Shared.Net)
local Abilities = require(Shared.Config.Abilities)
local Balance = require(Shared.Config.Balance)

local AbilityService = {}
AbilityService.Name = "AbilityService"
AbilityService.Dependencies = { "DataService", "StatsService", "CarryService", "CombatService" }
AbilityService.Priority = 34

function AbilityService:Init()
	-- userId -> { abilityId -> readyAt }
	self._cooldowns = {}
	-- userId -> { abilityId -> charges }
	self._charges = {}
	-- userId -> array of { id, abilityId, expiresAt, effects }
	self._activeEffects = {}
	-- world-placed objects: array of { id, abilityId, ownerUserId, position, radius, expiresAt, effects }
	self._placedObjects = {}
	-- userId -> { abilityId -> absorbed damage remaining }
	self._shields = {}

	self.AbilityUsed = Signal.new("AbilityService.AbilityUsed")
	self.EffectExpired = Signal.new("AbilityService.EffectExpired")
end

function AbilityService:Start()
	self._data = self.Registry:Get("DataService")
	self._stats = self.Registry:Get("StatsService")
	self._carry = self.Registry:Get("CarryService")
	self._combat = self.Registry:Get("CombatService")
	self._storms = self.Registry:Find("StormService")
	self._bank = self.Registry:Find("BankService")
	self._analytics = self.Registry:Find("AnalyticsService")

	Net.OnServerEvent("RequestUseAbility", function(player, abilityId, aimPoint)
		self:Use(player, abilityId, aimPoint)
	end)
	Net.OnServerEvent("RequestSetLoadout", function(player, loadout)
		self:SetLoadout(player, loadout)
	end)

	Players.PlayerRemoving:Connect(function(player)
		self._cooldowns[player.UserId] = nil
		self._charges[player.UserId] = nil
		self._activeEffects[player.UserId] = nil
		self._shields[player.UserId] = nil
		for index = #self._placedObjects, 1, -1 do
			if self._placedObjects[index].ownerUserId == player.UserId then
				table.remove(self._placedObjects, index)
			end
		end
	end)
end

-- ============================================================================
-- Cooldowns and charges
-- ============================================================================

function AbilityService:IsReady(player: Player, abilityId: string): boolean
	local cooldowns = self._cooldowns[player.UserId]
	if not cooldowns then
		return true
	end
	return os.clock() >= (cooldowns[abilityId] or 0)
end

function AbilityService:GetRemainingCooldown(player: Player, abilityId: string): number
	local cooldowns = self._cooldowns[player.UserId]
	if not cooldowns then
		return 0
	end
	return math.max(0, (cooldowns[abilityId] or 0) - os.clock())
end

function AbilityService:StartCooldown(player: Player, abilityId: string, overrideSeconds: number?)
	local cooldowns = self._cooldowns[player.UserId]
	if not cooldowns then
		cooldowns = {}
		self._cooldowns[player.UserId] = cooldowns
	end
	local duration = overrideSeconds or Abilities.GetCooldown(abilityId, self._stats:GetStats(player))
	cooldowns[abilityId] = os.clock() + duration
end

--[[ Shaves time off every cooldown. Used by the Relentless keystone. ]]
function AbilityService:ReduceAllCooldowns(player: Player, seconds: number)
	local cooldowns = self._cooldowns[player.UserId]
	if not cooldowns then
		return
	end
	for abilityId, readyAt in pairs(cooldowns) do
		cooldowns[abilityId] = math.max(os.clock(), readyAt - seconds)
	end
	self:_syncAbilityState(player)
end

-- ============================================================================
-- Activation
-- ============================================================================

function AbilityService:Use(player: Player, abilityId: string, aimPoint: Vector3?): (boolean, string?)
	local profile = self._data:GetProfile(player)
	if not profile then
		return false, "no_profile"
	end

	local ability = Abilities.ActiveById[abilityId]
	if not ability then
		return false, "unknown_ability"
	end
	if not profile.abilitiesOwned[abilityId] then
		return false, "not_owned"
	end

	-- Only equipped abilities can fire; the four-slot limit is the point.
	local equipped = false
	for _, slotted in ipairs(profile.loadout) do
		if slotted == abilityId then
			equipped = true
			break
		end
	end
	if not equipped then
		return false, "not_equipped"
	end

	if not self:IsReady(player, abilityId) then
		return false, "on_cooldown"
	end

	if self._combat:IsDowned(player) then
		return false, "downed"
	end

	local effects = Abilities.ResolveEffects(abilityId, self._stats:GetStats(player))
	local handler = self._handlers[abilityId]

	local ok, reason = true, nil
	if handler then
		ok, reason = handler(self, player, ability, effects, aimPoint)
	else
		-- Abilities without bespoke behaviour still apply their generic effect block.
		self:_applyGenericEffect(player, ability, effects)
	end

	if not ok then
		return false, reason
	end

	self:StartCooldown(player, abilityId)
	self.AbilityUsed:Fire(player, abilityId, effects)
	self:_syncAbilityState(player)

	Net.FireAllClients("AbilityState", {
		kind = "used",
		userId = player.UserId,
		abilityId = abilityId,
		vfx = ability.vfx,
		sound = ability.sound,
		position = aimPoint,
	})

	if self._analytics then
		self._analytics:Track(player, "ability_used", { abilityId = abilityId })
	end

	return true, nil
end

--[[ Registers a timed effect on a player. ]]
function AbilityService:_addEffect(player: Player, abilityId: string, duration: number, effects: any)
	local list = self._activeEffects[player.UserId]
	if not list then
		list = {}
		self._activeEffects[player.UserId] = list
	end

	-- Re-using an ability refreshes rather than stacks; two Overclocks at once would
	-- be a balance hole rather than a reward.
	for _, effect in ipairs(list) do
		if effect.abilityId == abilityId then
			effect.expiresAt = os.clock() + duration
			effect.effects = effects
			return effect
		end
	end

	local effect = {
		abilityId = abilityId,
		expiresAt = os.clock() + duration,
		effects = effects,
	}
	table.insert(list, effect)
	return effect
end

function AbilityService:HasEffect(player: Player, abilityId: string): boolean
	for _, effect in ipairs(self._activeEffects[player.UserId] or {}) do
		if effect.abilityId == abilityId and os.clock() < effect.expiresAt then
			return true
		end
	end
	return false
end

function AbilityService:GetEffect(player: Player, abilityId: string)
	for _, effect in ipairs(self._activeEffects[player.UserId] or {}) do
		if effect.abilityId == abilityId and os.clock() < effect.expiresAt then
			return effect
		end
	end
	return nil
end

function AbilityService:_applyGenericEffect(player: Player, ability: any, effects: any)
	if effects.duration then
		self:_addEffect(player, ability.id, effects.duration, effects)
	end
end

-- ============================================================================
-- Per-ability handlers
-- ============================================================================

AbilityService._handlers = {

	purge = function(self, player, ability, effects)
		local ok, reason = self._carry:RequestPurge(player)
		if ok then
			self._combat:SetInvulnerable(player, effects.grantsBriefImmunity or 0)
		end
		return ok, reason
	end,

	surge = function(self, player, ability, effects)
		local carried = self._carry:GetCarried(player)
		if carried <= 0 then
			return false, "no_energy"
		end
		self._carry:DrainFraction(player, effects.energyCostFraction, "surge")
		self._stats:ApplyBuff(player, {
			id = "surge",
			label = "Surge",
			effects = {
				increased = {
					moveSpeed = effects.speedMultiplier - 1,
					sprintSpeed = effects.speedMultiplier - 1,
					jumpPower = (effects.jumpMultiplier or 1) - 1,
				},
			},
			durationSeconds = effects.duration,
			source = "ability",
		})
		self:_addEffect(player, "surge", effects.duration, effects)
		return true, nil
	end,

	emergency_extract = function(self, player, ability, effects)
		if self._carry:GetCarried(player) <= 0 then
			return false, "nothing_to_bank"
		end
		if not self._bank then
			return false, "unavailable"
		end

		self._combat:SetInvulnerable(player, ability.castTime)

		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not root then
			return false, "no_character"
		end

		local station = self._bank:GetNearestStation((root :: BasePart).Position)
		if not station then
			return false, "no_station"
		end

		-- The cast is interruptible by design: extraction should feel like a
		-- decision made a moment too late as often as it feels like a save.
		task.delay(ability.castTime, function()
			if not player.Parent or self._combat:IsDowned(player) then
				return
			end
			local currentRoot = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
			if currentRoot then
				(currentRoot :: BasePart).CFrame = CFrame.new(station.position + Vector3.new(0, 4, 0))
			end
			self._bank:_commitBank(player, station, false, effects.bankPenalty)
		end)

		return true, nil
	end,

	static_shield = function(self, player, ability, effects)
		self._shields[player.UserId] = self._shields[player.UserId] or {}
		self._shields[player.UserId].static_shield = effects.damageAbsorbed
		self:_addEffect(player, "static_shield", effects.duration, effects)
		return true, nil
	end,

	bulwark_stance = function(self, player, ability, effects)
		self:_addEffect(player, "bulwark_stance", effects.duration, effects)
		-- Movement lock is enforced client-side for feel and server-side by the
		-- movement validator, which rejects displacement while the effect is live.
		return true, nil
	end,

	ground_anchor = function(self, player, ability, effects)
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not root then
			return false, "no_character"
		end
		self:_placeObject(player, "ground_anchor", (root :: BasePart).Position, effects.radius, effects.duration, effects)
		self:_addEffect(player, "ground_anchor", effects.duration, effects)
		return true, nil
	end,

	chain_link = function(self, player, ability, effects)
		self:_addEffect(player, "chain_link", effects.duration, effects)
		return true, nil
	end,

	overclock = function(self, player, ability, effects)
		self:_addEffect(player, "overclock", effects.duration, effects)
		return true, nil
	end,

	beacon = function(self, player, ability, effects)
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not root then
			return false, "no_character"
		end
		self:_placeObject(player, "beacon", (root :: BasePart).Position, effects.radius, effects.duration, effects)
		return true, nil
	end,

	field_dome = function(self, player, ability, effects)
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not root then
			return false, "no_character"
		end
		self:_placeObject(player, "field_dome", (root :: BasePart).Position, effects.radius, effects.duration, effects)
		return true, nil
	end,

	scan_pulse = function(self, player, ability, effects)
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not root then
			return false, "no_character"
		end
		local origin = (root :: BasePart).Position

		local revealed = { storms = {}, discoveries = {}, caches = {} }
		if self._storms then
			for _, cell in ipairs(self._storms:GetActiveCells()) do
				if (cell.position - origin).Magnitude <= effects.radius then
					table.insert(revealed.storms, {
						id = cell.id,
						stormTypeId = cell.stormTypeId,
						position = cell.position,
						rarity = cell.storm.rarity,
					})
				end
			end
		end

		local discoveries = self.Registry:Find("DiscoveryService")
		if discoveries and effects.revealsSecrets then
			revealed.discoveries = discoveries:GetUndiscoveredNear(player, origin, effects.radius)
		end

		Net.FireClient(player, "AbilityState", {
			kind = "scan_result",
			abilityId = "scan_pulse",
			revealed = revealed,
			duration = effects.revealDuration,
		})
		return true, nil
	end,

	storm_call = function(self, player, ability, effects)
		if not self._storms then
			return false, "unavailable"
		end
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not root then
			return false, "no_character"
		end
		local cell = self._storms:PullNearestCell(
			(root :: BasePart).Position,
			effects.searchRadius,
			effects.cannotCallRarity
		)
		if not cell then
			return false, "no_cell_in_range"
		end
		Net.FireClient(player, "Notification", {
			kind = "info",
			title = "Storm called",
			body = ("%s is inbound."):format(cell.storm.name),
		})
		return true, nil
	end,

	double_down = function(self, player, ability, effects)
		if self._carry:GetCarried(player) <= 0 then
			return false, "no_energy"
		end
		self:_addEffect(player, "double_down", effects.windowSeconds, effects)
		return true, nil
	end,

	blink_step = function(self, player, ability, effects)
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not root then
			return false, "no_character"
		end

		local part = root :: BasePart
		local direction = part.CFrame.LookVector
		local target = part.Position + direction * effects.distance

		-- A short raycast keeps the blink from depositing the player inside terrain,
		-- while still allowing the "pass through thin geometry" the ability promises.
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { character }
		local hit = workspace:Raycast(part.Position, direction * effects.distance, params)
		if hit then
			local beyond = workspace:Raycast(
				hit.Position + direction * (effects.passesThroughThin or 6),
				direction * 4,
				params
			)
			if beyond then
				target = hit.Position - direction * 3
			else
				target = hit.Position + direction * ((effects.passesThroughThin or 6) + 2)
			end
		end

		local velocity = effects.preservesMomentum and part.AssemblyLinearVelocity or Vector3.zero
		part.CFrame = CFrame.new(target, target + direction)
		part.AssemblyLinearVelocity = velocity

		self._combat:SetInvulnerable(player, effects.iFrames or 0)
		return true, nil
	end,

	siphon = function(self, player, ability, effects)
		if not self._storms then
			return false, "unavailable"
		end
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not root then
			return false, "no_character"
		end

		local origin = (root :: BasePart).Position
		local nearest, nearestDistance = nil, effects.maxRange
		for _, cell in ipairs(self._storms:GetActiveCells()) do
			local distance = (cell.position - origin).Magnitude
			if distance < nearestDistance then
				nearest, nearestDistance = cell, distance
			end
		end
		if not nearest then
			return false, "no_cell_in_range"
		end

		self:_addEffect(player, "siphon", effects.channelDuration, {
			cellId = nearest.id,
			energyPerSecond = effects.energyPerSecond,
			instabilityPerSecond = effects.instabilityPerSecond,
			maxRange = effects.maxRange,
			breaksOnDamage = effects.breaksOnDamage,
			depletesCellCharge = effects.depletesCellCharge,
		})
		return true, nil
	end,

	rally = function(self, player, ability, effects)
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not root then
			return false, "no_character"
		end
		local origin = (root :: BasePart).Position

		local affected = 0
		for _, other in ipairs(Players:GetPlayers()) do
			local otherRoot = other.Character and other.Character:FindFirstChild("HumanoidRootPart")
			if otherRoot and ((otherRoot :: BasePart).Position - origin).Magnitude <= effects.radius then
				if self._combat:IsDowned(other) then
					self._combat:CompleteRevive(other, effects.healFraction)
				else
					self._combat:Heal(other, self._stats:GetStat(other, "maxHealth") * effects.healFraction, "rally")
				end
				self._stats:ApplyBuff(other, {
					id = "rally",
					label = "Rally",
					effects = { increased = { moveSpeed = effects.speedBoost, sprintSpeed = effects.speedBoost } },
					durationSeconds = effects.boostDuration,
					source = "ability",
				})
				affected += 1
			end
		end

		if affected == 0 then
			return false, "nobody_in_range"
		end
		return true, nil
	end,
}

-- ============================================================================
-- Placed objects
-- ============================================================================

function AbilityService:_placeObject(player: Player, abilityId: string, position: Vector3, radius: number, duration: number, effects: any)
	local object = {
		id = ("obj_%d_%s_%d"):format(player.UserId, abilityId, math.floor(os.clock() * 1000)),
		abilityId = abilityId,
		ownerUserId = player.UserId,
		position = position,
		radius = radius,
		expiresAt = os.clock() + duration,
		effects = effects,
	}
	table.insert(self._placedObjects, object)

	Net.FireAllClients("AbilityState", {
		kind = "object_placed",
		objectId = object.id,
		abilityId = abilityId,
		ownerUserId = player.UserId,
		position = position,
		radius = radius,
		duration = duration,
	})

	return object
end

--[[ Placed objects of a kind whose radius contains a position. ]]
function AbilityService:_getCoveringObjects(position: Vector3, abilityId: string)
	local covering = {}
	for _, object in ipairs(self._placedObjects) do
		if object.abilityId == abilityId and (object.position - position).Magnitude <= object.radius then
			table.insert(covering, object)
		end
	end
	return covering
end

function AbilityService:IsInBeaconRange(player: Player): boolean
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		return false
	end
	return #self:_getCoveringObjects((root :: BasePart).Position, "beacon") > 0
end

-- ============================================================================
-- Queries used by other services
-- ============================================================================

--[[ Capture yield multiplier from active abilities (Overclock, Chain Link). ]]
function AbilityService:GetCaptureYieldMultiplier(player: Player): number
	local multiplier = 1
	local overclock = self:GetEffect(player, "overclock")
	if overclock then
		multiplier *= overclock.effects.yieldMultiplier or 1
	end
	return multiplier
end

--[[ Capture window multiplier from active abilities. ]]
function AbilityService:GetCaptureWindowMultiplier(player: Player): number
	local multiplier = 1
	local overclock = self:GetEffect(player, "overclock")
	if overclock then
		multiplier *= overclock.effects.windowMultiplier or 1
	end
	local anchor = self:GetEffect(player, "ground_anchor")
	if anchor then
		multiplier *= 1 + (anchor.effects.captureWindowBonus or 0)
	end
	return multiplier
end

--[[ Exposure damage multiplier from Field Dome coverage. ]]
function AbilityService:GetExposureMultiplier(player: Player): number
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		return 1
	end
	local multiplier = 1
	for _, dome in ipairs(self:_getCoveringObjects((root :: BasePart).Position, "field_dome")) do
		multiplier *= 1 - (dome.effects.exposureReduction or 0)
	end
	return multiplier
end

--[[
	Consumes shield capacity before damage reaches health.
	Returns the damage that survived the shields.
]]
function AbilityService:AbsorbDamage(player: Player, damage: number, source: string): number
	local shields = self._shields[player.UserId]
	if not shields then
		return damage
	end

	local remaining = damage
	for abilityId, pool in pairs(shields) do
		if pool > 0 and self:HasEffect(player, abilityId) then
			local absorbed = math.min(pool, remaining)
			shields[abilityId] = pool - absorbed
			remaining -= absorbed
			if remaining <= 0 then
				break
			end
		end
	end

	-- Bulwark Stance reduces whatever the shields did not eat.
	local bulwark = self:GetEffect(player, "bulwark_stance")
	if bulwark then
		remaining *= 1 - (bulwark.effects.damageReduction or 0)
	end

	-- Siphon breaks on damage.
	local siphon = self:GetEffect(player, "siphon")
	if siphon and siphon.effects.breaksOnDamage and damage > 0 then
		self:_removeEffect(player, "siphon")
	end

	return remaining
end

function AbilityService:_removeEffect(player: Player, abilityId: string)
	local list = self._activeEffects[player.UserId]
	if not list then
		return
	end
	for index = #list, 1, -1 do
		if list[index].abilityId == abilityId then
			table.remove(list, index)
			self.EffectExpired:Fire(player, abilityId)
		end
	end
end

-- ============================================================================
-- Loadout
-- ============================================================================

function AbilityService:SetLoadout(player: Player, loadout: { string }): (boolean, string?)
	local profile = self._data:GetProfile(player)
	if not profile then
		return false, "no_profile"
	end

	local ok, reason = Abilities.ValidateLoadout(loadout, profile.abilitiesOwned)
	if not ok then
		return false, reason
	end

	profile.loadout = loadout
	self._data:MarkDirty(player)
	self:_syncAbilityState(player)
	return true, nil
end

-- ============================================================================
-- Tick
-- ============================================================================

function AbilityService:Step(dt: number)
	local now = os.clock()

	-- Expire effects.
	for userId, list in pairs(self._activeEffects) do
		for index = #list, 1, -1 do
			local effect = list[index]
			if now >= effect.expiresAt then
				table.remove(list, index)
				local player = Players:GetPlayerByUserId(userId)
				if player then
					self.EffectExpired:Fire(player, effect.abilityId)
					if self._shields[userId] then
						self._shields[userId][effect.abilityId] = nil
					end
				end
			end
		end
	end

	-- Expire placed objects.
	for index = #self._placedObjects, 1, -1 do
		local object = self._placedObjects[index]
		if now >= object.expiresAt then
			table.remove(self._placedObjects, index)
			Net.FireAllClients("AbilityState", { kind = "object_removed", objectId = object.id })
		end
	end

	-- Channelled siphon.
	for _, player in ipairs(Players:GetPlayers()) do
		local siphon = self:GetEffect(player, "siphon")
		if siphon and self._storms then
			local cell = self._storms:GetCell(siphon.effects.cellId)
			local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
			if cell and root and (cell.position - (root :: BasePart).Position).Magnitude <= siphon.effects.maxRange then
				self._carry:AddEnergy(player, siphon.effects.energyPerSecond * dt, "siphon")
				local carryState = self._carry:_getState(player)
				carryState.instability = math.min(1, carryState.instability + siphon.effects.instabilityPerSecond * dt)
				carryState.dirty = true
				cell.charge = math.max(0, cell.charge - siphon.effects.depletesCellCharge * dt)
			else
				self:_removeEffect(player, "siphon")
			end
		end

		-- Field Dome healing and instability suppression.
		local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
		if root then
			for _, dome in ipairs(self:_getCoveringObjects((root :: BasePart).Position, "field_dome")) do
				if dome.effects.healPerSecond then
					self._combat:Heal(player, dome.effects.healPerSecond * dt, "field_dome")
				end
				if dome.effects.instabilityDecayRate then
					local carryState = self._carry:_getState(player)
					carryState.instability = math.max(0, carryState.instability - dome.effects.instabilityDecayRate * dt)
					carryState.dirty = true
				end
			end
		end
	end
end

function AbilityService:_syncAbilityState(player: Player)
	local profile = self._data:GetProfile(player)
	if not profile then
		return
	end

	local slots = {}
	for index, abilityId in ipairs(profile.loadout) do
		local ability = Abilities.ActiveById[abilityId]
		if ability then
			slots[index] = {
				abilityId = abilityId,
				name = ability.name,
				icon = ability.icon,
				cooldown = Abilities.GetCooldown(abilityId, self._stats:GetStats(player)),
				remaining = self:GetRemainingCooldown(player, abilityId),
				active = self:HasEffect(player, abilityId),
			}
		end
	end

	local owned = {}
	for abilityId in pairs(profile.abilitiesOwned) do
		table.insert(owned, abilityId)
	end
	table.sort(owned)

	Net.FireClient(player, "AbilityState", { kind = "loadout", slots = slots, owned = owned })
end

--[[ Periodic cooldown sync so the HUD stays honest without per-frame traffic. ]]
function AbilityService:Tick()
	for _, player in ipairs(Players:GetPlayers()) do
		if self._cooldowns[player.UserId] then
			self:_syncAbilityState(player)
		end
	end
end

return AbilityService
