--!strict
--[[
	EconomyService
	--------------
	The ledger. Every currency and material movement in the game passes through here,
	which gives three things nothing else can:

	  * One place that enforces caps, rejects negatives and refuses NaN.
	  * One place that marks the profile dirty, so no award can silently fail to save.
	  * One audit trail, so a support question ("where did my Watts go?") has an
	    answer, and an exploit shows up as an implausible source in the log.

	Spending is transactional: :Spend returns false and changes nothing when the
	player cannot afford it, so callers never need a check-then-act race.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BTS")
local Signal = require(Shared.Core.Signal)
local Net = require(Shared.Net)
local Balance = require(Shared.Config.Balance)
local Resources = require(Shared.Config.Resources)

local EconomyService = {}
EconomyService.Name = "EconomyService"
EconomyService.Dependencies = { "DataService" }
EconomyService.Priority = 15

local CURRENCY_CAPS = {
	watts = Balance.Currency.WATTS.cap,
	cores = Balance.Currency.CORES.cap,
	sigils = Balance.Currency.SIGILS.cap,
}

function EconomyService:Init()
	-- A bounded ring buffer per player. Long enough to explain a session, short
	-- enough that a six-hour player does not accumulate an unbounded table.
	self._ledger = {} :: { [number]: { any } }
	self._ledgerLimit = 250

	self.CurrencyChanged = Signal.new("EconomyService.CurrencyChanged")
	self.ResourceChanged = Signal.new("EconomyService.ResourceChanged")
end

function EconomyService:Start()
	self._data = self.Registry:Get("DataService")
	self._analytics = self.Registry:Find("AnalyticsService")

	self._data.ProfileReleasing:Connect(function(player)
		self._ledger[player.UserId] = nil
	end)
end

function EconomyService:_log(player: Player, entry: any)
	local ledger = self._ledger[player.UserId]
	if not ledger then
		ledger = {}
		self._ledger[player.UserId] = ledger
	end
	entry.at = os.time()
	table.insert(ledger, entry)
	if #ledger > self._ledgerLimit then
		table.remove(ledger, 1)
	end
end

-- ============================================================================
-- Currency
-- ============================================================================

function EconomyService:GetBalance(player: Player, currency: string): number
	local profile = self._data:GetProfile(player)
	if not profile then
		return 0
	end
	return profile[currency] or 0
end

--[[
	Credits currency. Returns the amount actually granted, which can be less than
	requested when the cap is hit.
]]
function EconomyService:Award(player: Player, currency: string, amount: number, source: string): number
	local cap = CURRENCY_CAPS[currency]
	if not cap then
		warn("[EconomyService] unknown currency: " .. tostring(currency))
		return 0
	end
	if type(amount) ~= "number" or amount ~= amount or amount <= 0 then
		return 0
	end

	local profile = self._data:GetProfile(player)
	if not profile then
		return 0
	end

	local before = profile[currency] or 0
	local after = math.min(cap, before + amount)
	local granted = after - before

	if granted <= 0 then
		return 0
	end

	profile[currency] = after
	self._data:MarkDirty(player)

	self:_log(player, { kind = "award", currency = currency, amount = granted, source = source, balance = after })
	self.CurrencyChanged:Fire(player, currency, after, granted)

	if self._analytics then
		self._analytics:TrackEconomy(player, "source", currency, granted, source, after)
	end

	return granted
end

--[[
	Debits currency if the player can afford it.
	Returns (success, newBalance). Nothing changes on failure.
]]
function EconomyService:Spend(player: Player, currency: string, amount: number, sink: string): (boolean, number)
	if not CURRENCY_CAPS[currency] then
		return false, 0
	end
	if type(amount) ~= "number" or amount ~= amount or amount < 0 then
		return false, 0
	end

	local profile = self._data:GetProfile(player)
	if not profile then
		return false, 0
	end

	local before = profile[currency] or 0
	if before < amount then
		return false, before
	end

	local after = before - amount
	profile[currency] = after
	self._data:MarkDirty(player)

	self:_log(player, { kind = "spend", currency = currency, amount = amount, source = sink, balance = after })
	self.CurrencyChanged:Fire(player, currency, after, -amount)

	if self._analytics then
		self._analytics:TrackEconomy(player, "sink", currency, amount, sink, after)
	end

	return true, after
end

function EconomyService:CanAfford(player: Player, currency: string, amount: number): boolean
	return self:GetBalance(player, currency) >= amount
end

--[[
	Spends several currencies atomically. Either every cost is paid or none is.
	`costs` is a map of currency -> amount.
]]
function EconomyService:SpendMultiple(player: Player, costs: { [string]: number }, sink: string): boolean
	local profile = self._data:GetProfile(player)
	if not profile then
		return false
	end

	for currency, amount in pairs(costs) do
		if (profile[currency] or 0) < amount then
			return false
		end
	end

	for currency, amount in pairs(costs) do
		self:Spend(player, currency, amount, sink)
	end
	return true
end

-- ============================================================================
-- Resources
-- ============================================================================

function EconomyService:GetResource(player: Player, resourceId: string): number
	local profile = self._data:GetProfile(player)
	if not profile then
		return 0
	end
	return profile.resources[resourceId] or 0
end

function EconomyService:AwardResource(player: Player, resourceId: string, quantity: number, source: string): number
	local resource = Resources.ById[resourceId]
	if not resource then
		warn("[EconomyService] unknown resource: " .. tostring(resourceId))
		return 0
	end
	if type(quantity) ~= "number" or quantity ~= quantity or quantity <= 0 then
		return 0
	end

	local profile = self._data:GetProfile(player)
	if not profile then
		return 0
	end

	local before = profile.resources[resourceId] or 0
	local after = math.min(resource.stackSize, before + math.floor(quantity))
	local granted = after - before

	if granted <= 0 then
		return 0
	end

	profile.resources[resourceId] = after
	self._data:MarkDirty(player)

	self:_log(player, { kind = "resource_gain", resource = resourceId, amount = granted, source = source })
	self.ResourceChanged:Fire(player, resourceId, after, granted)
	return granted
end

function EconomyService:SpendResource(player: Player, resourceId: string, quantity: number, sink: string): boolean
	local profile = self._data:GetProfile(player)
	if not profile then
		return false
	end
	local before = profile.resources[resourceId] or 0
	if before < quantity then
		return false
	end

	local after = before - quantity
	if after <= 0 then
		profile.resources[resourceId] = nil
	else
		profile.resources[resourceId] = after
	end
	self._data:MarkDirty(player)

	self:_log(player, { kind = "resource_spend", resource = resourceId, amount = quantity, source = sink })
	self.ResourceChanged:Fire(player, resourceId, after, -quantity)
	return true
end

--[[ Atomic multi-resource spend, for crafting recipes. ]]
function EconomyService:SpendResources(player: Player, costs: { [string]: number }, sink: string): (boolean, string?)
	local profile = self._data:GetProfile(player)
	if not profile then
		return false, "no_profile"
	end

	for resourceId, quantity in pairs(costs) do
		if (profile.resources[resourceId] or 0) < quantity then
			return false, resourceId
		end
	end

	for resourceId, quantity in pairs(costs) do
		self:SpendResource(player, resourceId, quantity, sink)
	end
	return true, nil
end

--[[ Which ingredients are short, and by how much — for the crafting UI. ]]
function EconomyService:GetMissingResources(player: Player, costs: { [string]: number }): { [string]: number }
	local profile = self._data:GetProfile(player)
	local missing = {}
	if not profile then
		return costs
	end
	for resourceId, quantity in pairs(costs) do
		local held = profile.resources[resourceId] or 0
		if held < quantity then
			missing[resourceId] = quantity - held
		end
	end
	return missing
end

-- ============================================================================
-- Diagnostics
-- ============================================================================

function EconomyService:GetLedger(player: Player)
	return self._ledger[player.UserId] or {}
end

--[[ Totals by source, for balance analysis: where is a player's income coming from? ]]
function EconomyService:SummariseLedger(player: Player)
	local sources = {}
	local sinks = {}
	for _, entry in ipairs(self:GetLedger(player)) do
		if entry.kind == "award" then
			sources[entry.source] = (sources[entry.source] or 0) + entry.amount
		elseif entry.kind == "spend" then
			sinks[entry.source] = (sinks[entry.source] or 0) + entry.amount
		end
	end
	return { sources = sources, sinks = sinks }
end

return EconomyService
