--!strict
--[[
	StatsService
	------------
	Resolves a player's effective stat block from every contributing source, and is
	the single authority any other service asks "how much capacity does this player
	have?".

	Contribution order matters and is fixed:
		1. Base values from the Stats registry
		2. Core upgrade tracks and their earned milestones
		3. Skill tree ranks
		4. Equipped item base stats
		5. Equipped item rolled affixes
		6. Active set bonuses
		7. Prestige rank bonuses
		8. Temporary buffs (abilities, world events, consumables, region effects)

	Results are cached and invalidated by an explicit dirty flag. Recomputing costs
	roughly a millisecond, which is fine on a purchase and unacceptable per frame, so
	callers get the cache and the cache is precise about when it is stale.

	Every contribution is labelled, so the character sheet can show a player exactly
	which of their thirty sources is giving them capture window.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BTS")
local Signal = require(Shared.Core.Signal)
local Stats = require(Shared.Config.Stats)
local Upgrades = require(Shared.Config.Upgrades)
local SkillTree = require(Shared.Config.SkillTree)
local Equipment = require(Shared.Config.Equipment)
local Modifiers = require(Shared.Config.Modifiers)
local Balance = require(Shared.Config.Balance)

local StatsService = {}
StatsService.Name = "StatsService"
StatsService.Dependencies = { "DataService" }
StatsService.Priority = 5

type BuffEntry = {
	id: string,
	label: string,
	effects: { [string]: { [string]: number } },
	expiresAt: number?,
	stacks: number,
	maxStacks: number?,
	source: string?,
}

function StatsService:Init()
	self._data = nil
	-- userId -> { values, sources, buffs, dirty, behaviours, grants }
	self._cache = {}
	self.StatsChanged = Signal.new("StatsService.StatsChanged")
end

function StatsService:Start()
	self._data = self.Registry:Get("DataService")

	-- Any profile change that could affect stats invalidates the cache.
	self._data.ProfileLoaded:Connect(function(player)
		self:Invalidate(player)
	end)
	self._data.ProfileReleasing:Connect(function(player)
		self._cache[player.UserId] = nil
	end)
end

-- ============================================================================
-- Cache management
-- ============================================================================

local function getEntry(self, userId: number)
	local entry = self._cache[userId]
	if not entry then
		entry = {
			values = nil,
			sources = nil,
			buffs = {},
			dirty = true,
			behaviours = {},
			grants = nil,
		}
		self._cache[userId] = entry
	end
	return entry
end

--[[ Marks a player's stats as needing recomputation on next read. ]]
function StatsService:Invalidate(player: Player)
	local entry = getEntry(self, player.UserId)
	entry.dirty = true
end

function StatsService:InvalidateUserId(userId: number)
	local entry = self._cache[userId]
	if entry then
		entry.dirty = true
	end
end

-- ============================================================================
-- Resolution
-- ============================================================================

--[[
	Builds a fully-resolved stat block for a profile.
	Kept as a pure-ish function taking the profile so it can be unit tested without a
	Player instance or a live session.
]]
function StatsService.ResolveForProfile(profile: any, buffs: { BuffEntry }?, now: number?)
	local accumulator = Stats.CreateAccumulator()

	-- 2. Core upgrades and milestones
	Upgrades.ApplyToAccumulator(Stats, accumulator, profile.upgrades or {})

	-- 3. Skill tree
	SkillTree.ApplyToAccumulator(Stats, accumulator, profile.skills or {})

	-- 4 & 5. Equipped items: base stats then rolled affixes
	local equippedBaseIds = {}
	local itemsByUid = {}
	for _, item in ipairs(profile.inventory or {}) do
		itemsByUid[item.u] = item
	end

	for slotId, uid in pairs(profile.equipped or {}) do
		local item = itemsByUid[uid]
		if item then
			local definition = Equipment.GetDefinition(item.b)
			if definition and definition.slot == slotId then
				table.insert(equippedBaseIds, item.b)
				local label = definition.name

				for kind, statMap in pairs(definition.baseStats or {}) do
					for statId, amount in pairs(statMap) do
						Stats.Contribute(accumulator, statId, kind, amount, label)
					end
				end

				Modifiers.ApplyAffixes(Stats, accumulator, item.m or {}, label)
			end
		end
	end

	-- 6. Set bonuses
	for _, active in ipairs(Equipment.GetActiveSetBonuses(equippedBaseIds)) do
		local label = ("%s (%d)"):format(active.setName, active.tier)
		for kind, statMap in pairs(active.bonus.effects) do
			for statId, amount in pairs(statMap) do
				Stats.Contribute(accumulator, statId, kind, amount, label)
			end
		end
	end

	-- 7. Prestige: a flat yield and capacity bonus per rank, applied as `increased`
	-- so it stacks additively with gear rather than multiplying past it.
	local prestige = profile.prestige or 0
	if prestige > 0 then
		local bonus = prestige * Balance.Progression.PRESTIGE_YIELD_BONUS_PER_RANK
		local label = ("Prestige %d"):format(prestige)
		Stats.Contribute(accumulator, "captureYield", "increased", bonus, label)
		Stats.Contribute(accumulator, "capacity", "increased", bonus, label)
		Stats.Contribute(accumulator, "bankRate", "increased", bonus * 0.5, label)
	end

	-- 8. Temporary buffs
	local currentTime = now or os.clock()
	for _, buff in ipairs(buffs or {}) do
		if not buff.expiresAt or buff.expiresAt > currentTime then
			local stacks = buff.stacks or 1
			for kind, statMap in pairs(buff.effects) do
				for statId, amount in pairs(statMap) do
					Stats.Contribute(accumulator, statId, kind, amount * stacks, buff.label)
				end
			end
		end
	end

	return Stats.Resolve(accumulator)
end

--[[ Returns the cached stat block, recomputing if dirty. ]]
function StatsService:GetStats(player: Player): { [string]: number }
	local entry = getEntry(self, player.UserId)
	if entry.dirty or not entry.values then
		self:Recompute(player)
	end
	return entry.values
end

function StatsService:GetStat(player: Player, statId: string): number
	return self:GetStats(player)[statId] or 0
end

--[[ The labelled breakdown behind each stat, for the character sheet. ]]
function StatsService:GetSources(player: Player)
	local entry = getEntry(self, player.UserId)
	if entry.dirty or not entry.sources then
		self:Recompute(player)
	end
	return entry.sources
end

--[[ Forces a recompute now and broadcasts the change. ]]
function StatsService:Recompute(player: Player)
	local profile = self._data:GetProfile(player)
	if not profile then
		return nil
	end

	local entry = getEntry(self, player.UserId)
	self:_expireBuffs(player.UserId)

	local previous = entry.values
	local values, sources = StatsService.ResolveForProfile(profile, entry.buffs, os.clock())

	entry.values = values
	entry.sources = sources
	entry.dirty = false

	-- Behaviour flags come from upgrade milestones, skill nodes and equipped traits.
	entry.behaviours = self:_collectBehaviours(profile)
	entry.grants = SkillTree.CollectGrants(profile.skills or {})

	self.StatsChanged:Fire(player, values, previous)
	return values
end

--[[
	Gathers every behaviour flag the player has unlocked. Behaviours are booleans that
	change how a system works, as opposed to stats which change how much.
]]
function StatsService:_collectBehaviours(profile: any): { [string]: boolean }
	local behaviours = Upgrades.CollectBehaviours(profile.upgrades or {})

	for behaviourId in pairs(SkillTree.CollectGrants(profile.skills or {}).behaviours) do
		behaviours[behaviourId] = true
	end

	-- Equipped unique traits contribute their behaviour hook.
	local itemsByUid = {}
	for _, item in ipairs(profile.inventory or {}) do
		itemsByUid[item.u] = item
	end
	for _, uid in pairs(profile.equipped or {}) do
		local item = itemsByUid[uid]
		if item and item.t then
			local trait = Modifiers.TraitById[item.t]
			if trait then
				behaviours[trait.behaviour] = true
			end
		end
	end

	return behaviours
end

--[[ True when the player has unlocked a named behaviour. ]]
function StatsService:HasBehaviour(player: Player, behaviourId: string): boolean
	local entry = getEntry(self, player.UserId)
	if entry.dirty or not entry.values then
		self:Recompute(player)
	end
	return entry.behaviours[behaviourId] == true
end

function StatsService:GetBehaviours(player: Player): { [string]: boolean }
	local entry = getEntry(self, player.UserId)
	if entry.dirty or not entry.values then
		self:Recompute(player)
	end
	return entry.behaviours
end

--[[
	Trait parameters for an equipped unique, or nil.
	Services that implement a trait read their tuning from here rather than embedding
	the numbers, so a trait can be retuned in Modifiers.luau alone.
]]
function StatsService:GetTraitParams(player: Player, behaviourId: string): any?
	local profile = self._data:GetProfile(player)
	if not profile then
		return nil
	end
	local itemsByUid = {}
	for _, item in ipairs(profile.inventory or {}) do
		itemsByUid[item.u] = item
	end
	for _, uid in pairs(profile.equipped or {}) do
		local item = itemsByUid[uid]
		if item and item.t then
			local trait = Modifiers.TraitById[item.t]
			if trait and trait.behaviour == behaviourId then
				return trait.params
			end
		end
	end
	return nil
end

-- ============================================================================
-- Buffs
-- ============================================================================

--[[
	Applies a temporary stat modifier.
	`durationSeconds` of nil means it lasts until removed explicitly.
	Re-applying an existing buff id refreshes its duration and, where the buff
	stacks, increments the stack count up to its cap.
]]
function StatsService:ApplyBuff(player: Player, buff: {
	id: string,
	label: string,
	effects: { [string]: { [string]: number } },
	durationSeconds: number?,
	maxStacks: number?,
	source: string?,
})
	local entry = getEntry(self, player.UserId)
	local now = os.clock()

	for _, existing in ipairs(entry.buffs) do
		if existing.id == buff.id then
			existing.expiresAt = buff.durationSeconds and (now + buff.durationSeconds) or nil
			if buff.maxStacks and buff.maxStacks > 1 then
				existing.stacks = math.min(existing.stacks + 1, buff.maxStacks)
			end
			entry.dirty = true
			self:Recompute(player)
			return existing
		end
	end

	local created: BuffEntry = {
		id = buff.id,
		label = buff.label,
		effects = buff.effects,
		expiresAt = buff.durationSeconds and (now + buff.durationSeconds) or nil,
		stacks = 1,
		maxStacks = buff.maxStacks,
		source = buff.source,
	}
	table.insert(entry.buffs, created)
	entry.dirty = true
	self:Recompute(player)
	return created
end

function StatsService:RemoveBuff(player: Player, buffId: string): boolean
	local entry = getEntry(self, player.UserId)
	for index, buff in ipairs(entry.buffs) do
		if buff.id == buffId then
			table.remove(entry.buffs, index)
			entry.dirty = true
			self:Recompute(player)
			return true
		end
	end
	return false
end

function StatsService:HasBuff(player: Player, buffId: string): boolean
	local entry = getEntry(self, player.UserId)
	for _, buff in ipairs(entry.buffs) do
		if buff.id == buffId then
			return true
		end
	end
	return false
end

function StatsService:GetBuffs(player: Player): { BuffEntry }
	local entry = getEntry(self, player.UserId)
	self:_expireBuffs(player.UserId)
	return entry.buffs
end

--[[ Drops expired buffs. Returns true when anything was removed. ]]
function StatsService:_expireBuffs(userId: number): boolean
	local entry = self._cache[userId]
	if not entry then
		return false
	end
	local now = os.clock()
	local removed = false
	for index = #entry.buffs, 1, -1 do
		local buff = entry.buffs[index]
		if buff.expiresAt and buff.expiresAt <= now then
			table.remove(entry.buffs, index)
			removed = true
		end
	end
	if removed then
		entry.dirty = true
	end
	return removed
end

--[[ Slow-tick sweep so buffs expire even for a player whose stats nobody reads. ]]
function StatsService:Tick()
	local Players = game:GetService("Players")
	for userId, entry in pairs(self._cache) do
		if #entry.buffs > 0 and self:_expireBuffs(userId) then
			local player = Players:GetPlayerByUserId(userId)
			if player then
				self:Recompute(player)
			end
		end
	end
end

--[[
	Effective capture window half-width for a player against a specific storm.
	Lives here because both CaptureService (authoritative) and the client HUD
	(predictive) must agree exactly.
]]
function StatsService:GetCaptureWindow(player: Player, stormWindowHalfWidth: number): number
	local windowStat = self:GetStat(player, "captureWindow")
	local scaled = stormWindowHalfWidth * windowStat
	return math.clamp(scaled, Balance.Capture.MIN_WINDOW_HALF_WIDTH, 0.5)
end

--[[ Effective capture radius, clamped to the design ceiling. ]]
function StatsService:GetCaptureRadius(player: Player): number
	return math.clamp(
		self:GetStat(player, "captureRadius"),
		1,
		Balance.Capture.MAX_CAPTURE_RADIUS
	)
end

return StatsService
