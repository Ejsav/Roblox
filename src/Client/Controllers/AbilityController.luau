--!strict
--[[
	AbilityController
	-----------------
	The client half of the ability system: presses, aiming, and the local feedback
	that makes an ability feel like it fired the instant you asked for it.

	Three things this owns, in order of how much they matter:

	1. Sending the press at all. Keys 1-4 map to loadout slots, not to ability ids,
	   because the loadout is what the player rearranges and the keys should follow
	   it rather than the other way round.

	2. Local prediction of the *refusal*, not of the effect. A press that cannot
	   possibly work — nothing slotted, still on cooldown — is refused here, with a
	   sound and a shake, and never reaches the network. A press that might work is
	   always sent and the server decides. That split is deliberate: predicting a
	   success the server then denies produces a visible rollback, while predicting
	   a failure the server would also have refused costs nothing if we are wrong,
	   because the player can simply press again.

	Cooldowns shown here are the server's, corrected on every sync. The local clock
	only interpolates between syncs so the ring animates smoothly at sixty frames a
	second rather than stepping twice a second.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BTS")
local Net = require(Shared.Net)
local Maid = require(Shared.Core.Maid)
local Signal = require(Shared.Core.Signal)
local Abilities = require(Shared.Config.Abilities)

local AbilityController = {}
AbilityController.Name = "AbilityController"
AbilityController.Dependencies = { "InputController" }
AbilityController.Priority = 30

local LocalPlayer = Players.LocalPlayer

local SLOT_ACTIONS = { "ability1", "ability2", "ability3", "ability4" }

function AbilityController:Init()
	self._maid = Maid.new()

	-- Slot index -> { abilityId, name, cooldown, remaining, active }
	self._slots = {}
	self._owned = {}

	-- os.clock() at the moment the last server sync landed, so remaining cooldowns
	-- can be counted down locally between syncs without drifting.
	self._syncedAt = 0

	self.AbilityPressed = Signal.new("Ability.Pressed")
	self.AbilityRefused = Signal.new("Ability.Refused")
	self.SlotsChanged = Signal.new("Ability.SlotsChanged")
end

function AbilityController:Start()
	self._input = self.Registry:Get("InputController")
	self._audio = self.Registry:Find("AudioController")
	self._hud = self.Registry:Find("HudController")
	self._notifications = self.Registry:Find("NotificationController")

	for index, actionId in ipairs(SLOT_ACTIONS) do
		self._maid:Add(self._input.ActionBegan:Connect(function(firedAction)
			if firedAction == actionId then
				self:UseSlot(index)
			end
		end))
	end

	self._maid:Add(Net.OnClientEvent("AbilityState", function(payload)
		self:_onState(payload)
	end))
end

function AbilityController:_onState(payload: any)
	if payload.kind == "loadout" then
		self._slots = payload.slots or {}
		self._owned = payload.owned or {}
		self._syncedAt = os.clock()
		self.SlotsChanged:Fire(self._slots)

	elseif payload.kind == "cooldowns" then
		-- A cooldown-only sync updates the numbers without disturbing the slots,
		-- so a mid-cooldown loadout render never flickers back to empty.
		for index, remaining in pairs(payload.remaining or {}) do
			local slot = self._slots[index]
			if slot then
				slot.remaining = remaining
			end
		end
		self._syncedAt = os.clock()

	elseif payload.kind == "used" then
		local slot = self:_slotFor(payload.abilityId)
		if slot then
			slot.remaining = payload.cooldown or slot.cooldown
			slot.active = payload.active == true
			self._syncedAt = os.clock()
		end

	elseif payload.kind == "refused" then
		-- The server refused something the client thought was fine. Surfaced rather
		-- than swallowed: a button that does nothing and says nothing is the single
		-- most frustrating thing an action game can do.
		self:_refuse(payload.reason or "unavailable", payload.abilityId)
	end
end

function AbilityController:_slotFor(abilityId: string?): any?
	if not abilityId then
		return nil
	end
	for _, slot in ipairs(self._slots) do
		if slot.abilityId == abilityId then
			return slot
		end
	end
	return nil
end

-- ============================================================================
-- Cooldowns
-- ============================================================================

--[[
	Seconds left on a slot, interpolated from the last sync. Never negative, and
	never larger than the last value the server gave — local time only ever counts
	down, so a stalled sync degrades to "ready" rather than to "stuck".
]]
function AbilityController:GetRemaining(index: number): number
	local slot = self._slots[index]
	if not slot then
		return 0
	end
	local elapsed = os.clock() - self._syncedAt
	return math.max(0, (slot.remaining or 0) - elapsed)
end

function AbilityController:IsReady(index: number): boolean
	local slot = self._slots[index]
	return slot ~= nil and self:GetRemaining(index) <= 0
end

function AbilityController:GetSlots()
	return self._slots
end

-- ============================================================================
-- Firing
-- ============================================================================

function AbilityController:UseSlot(index: number): boolean
	local slot = self._slots[index]

	if not slot then
		return self:_refuse("nothing slotted", nil)
	end

	local remaining = self:GetRemaining(index)
	if remaining > 0 then
		return self:_refuse(("%0.1fs"):format(remaining), slot.abilityId)
	end

	return self:Use(slot.abilityId)
end

function AbilityController:Use(abilityId: string): boolean
	local ability = Abilities.ActiveById[abilityId]
	if not ability then
		return false
	end

	-- No aim point is sent. Every ability in the game today centres on the caster,
	-- and the remote's aim argument is optional precisely so that a targeted
	-- ability can start sending one without a protocol change. Computing a raycast
	-- nothing reads would be work performed to look thorough.
	Net.FireServer("RequestUseAbility", abilityId)

	-- Feedback fires on the press rather than on the server's answer. The round
	-- trip is short but not free, and an action game that waits for it feels heavy.
	self.AbilityPressed:Fire(abilityId)
	if self._audio then
		self._audio:PlayUi("ability_cast")
	end

	local slot = self:_slotFor(abilityId)
	if slot then
		-- Predict the cooldown so the ring starts moving immediately. The next sync
		-- corrects it; predicting the cooldown is safe in a way that predicting the
		-- effect is not, because the worst case is a ring that jumps back to ready.
		slot.remaining = slot.cooldown or 0
		self._syncedAt = os.clock()
	end

	return true
end

function AbilityController:_refuse(reason: string, abilityId: string?): boolean
	self.AbilityRefused:Fire(abilityId, reason)

	if self._audio then
		self._audio:PlayUi("ui_denied")
	end
	if self._hud then
		self._hud:FlashAbilityRefusal(abilityId, reason)
	end

	return false
end

-- ============================================================================
-- Loadout
-- ============================================================================

--[[
	Sets the four slots. Validated locally first — unowned, duplicate, or overflow
	entries are stripped — because sending a loadout the server will reject just
	produces a silent no-op the player has to work out for themselves.
]]
function AbilityController:SetLoadout(abilityIds: { string }): boolean
	local owned = {}
	for _, abilityId in ipairs(self._owned) do
		owned[abilityId] = true
	end

	local seen = {}
	local clean = {}
	for _, abilityId in ipairs(abilityIds) do
		if owned[abilityId] and not seen[abilityId] and #clean < 4 then
			seen[abilityId] = true
			table.insert(clean, abilityId)
		end
	end

	Net.FireServer("RequestSetLoadout", clean)
	return #clean > 0
end

function AbilityController:GetOwned(): { string }
	return self._owned
end

function AbilityController:Destroy()
	self._maid:DoCleaning()
end

return AbilityController
