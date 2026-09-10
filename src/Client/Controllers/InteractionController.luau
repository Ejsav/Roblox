--!strict
--[[
	InteractionController
	---------------------
	Proximity detection and the interaction prompt.

	The prompt is the game's smallest and most-seen piece of UI, so it gets real
	attention: it appears the instant a target is in range, names the action rather
	than the object, shows the correct key for the current input method, and — for
	banking, which is the decision the whole game turns on — previews what the
	player would actually get.

	Detection runs client-side against a manifest the server sent, so the prompt is
	instant. Nothing is trusted: pressing it sends an id, and the server re-checks
	distance and state before anything happens.
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BTS")
local Theme = require(Shared.Config.Theme)
local Net = require(Shared.Net)
local Maid = require(Shared.Core.Maid)
local Signal = require(Shared.Core.Signal)
local MathUtil = require(Shared.Core.MathUtil)
local Balance = require(Shared.Config.Balance)

local Client = script.Parent.Parent
local Components = require(Client.UI.Components)

local InteractionController = {}
InteractionController.Name = "InteractionController"
InteractionController.Dependencies = { "InputController" }
InteractionController.Priority = 25

local LocalPlayer = Players.LocalPlayer

--[[ The verb shown for each interactable kind. Naming the action rather than the
     object is what makes a prompt readable at a glance. ]]
local VERBS = {
	bank = "BANK",
	fast_travel = "USE RELAY",
	quest_object = "INSPECT",
	cache = "RECOVER",
	event_node = "DELIVER",
	gate = "EXAMINE",
	workbench = "CRAFT",
	revive = "REVIVE",
}

function InteractionController:Init()
	self._maid = Maid.new()
	self._manifest = {}
	self._target = nil
	self._carry = nil
	self._banking = false
	self._canRemoteBank = false

	-- Undiscovered secrets in this region, and the ones already reported this
	-- session so a player standing in a trigger does not send it every frame while
	-- the server's answer is in flight.
	self._discoveries = {}
	self._reported = {}

	-- Downed runners near enough to revive, refreshed from combat messages.
	self._downed = {}

	self.TargetChanged = Signal.new("Interaction.TargetChanged")

	local playerGui = LocalPlayer:WaitForChild("PlayerGui")

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "BTS_Interaction"
	screenGui.ResetOnSpawn = false
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.DisplayOrder = Theme.ZIndex.hudOverlay
	screenGui.Parent = playerGui
	self._maid:Add(screenGui)

	self:_buildPrompt(screenGui)
end

function InteractionController:Start()
	self._input = self.Registry:Get("InputController")
	self._audio = self.Registry:Find("AudioController")

	self._maid:Add(Net.OnClientEvent("InteractionManifest", function(manifest)
		self._manifest = manifest
	end))

	self._maid:Add(Net.OnClientEvent("CarryUpdate", function(snapshot)
		if snapshot.carried ~= nil then
			self._carry = snapshot
		end
	end))

	-- Whether remote banking is available is a stat behaviour, so it arrives with
	-- the profile and with any delta that changes what the player can do.
	self._maid:Add(Net.OnClientEvent("ProfileSync", function(payload)
		self:_readBehaviours(payload.behaviours)
	end))

	self._maid:Add(Net.OnClientEvent("ProfileDelta", function(payload)
		if payload.behaviours then
			self:_readBehaviours(payload.behaviours)
		end
	end))

	self._maid:Add(Net.OnClientEvent("BankResult", function()
		self._banking = false
	end))

	-- Dropped caches arrive as their own events rather than in the manifest,
	-- because they are transient.
	self._maid:Add(Net.OnClientEvent("AbilityState", function(payload)
		if payload.kind == "cache_spawned" then
			table.insert(self._manifest, {
				id = payload.id,
				kind = "cache",
				position = payload.position,
				range = Balance.Carry.DEATH_CACHE_RECOVERY_RADIUS,
				name = "Energy cache",
			})
		elseif payload.kind == "cache_removed" then
			for index = #self._manifest, 1, -1 do
				if self._manifest[index].id == payload.id then
					table.remove(self._manifest, index)
				end
			end
		end
	end))

	self._maid:Add(Net.OnClientEvent("DiscoveryManifest", function(entries)
		self._discoveries = entries or {}
	end))

	self._maid:Add(Net.OnClientEvent("DiscoveryMade", function(payload)
		-- Drop it from the manifest the moment it is granted, so the trigger stops
		-- being tested at all rather than being tested and rejected.
		self:_forgetDiscovery(payload.id)
	end))

	self._maid:Add(Net.OnClientEvent("CombatState", function(payload)
		if payload.kind == "downed" then
			self._downed[payload.userId] = payload.position
		elseif payload.kind == "revived" or payload.kind == "died" then
			self._downed[payload.userId] = nil
		end
	end))

	self._maid:Add(self._input.ActionBegan:Connect(function(actionId)
		if actionId == "interact" then
			self:Interact()
		elseif actionId == "bank" then
			-- The bank key means "bank" wherever the player is standing. With a
			-- station in range that is the station; without one it is the remote
			-- deposit, if they have unlocked it. Making the same key do the
			-- available thing beats making the player remember two.
			if self._target and self._target.kind == "bank" then
				self:Interact()
			elseif not self:RemoteBank() then
				self:Interact()
			end
		elseif actionId == "purge" then
			self:Purge()
		end
	end))
end

-- ============================================================================
-- Self actions
-- ============================================================================

--[[
	The panic button. Vents instability at the cost of a slice of the carry.

	Refused locally when there is nothing to purge, because a player mashing it out
	of habit should not spend their rate-limit budget on requests the server will
	decline anyway — and the budget is small precisely because this is the request
	a panicking player sends most.
]]
function InteractionController:Purge(): boolean
	local carry = self._carry
	if not carry or (carry.carried or 0) <= 0 then
		return false
	end
	if (carry.instability or 0) <= 0.01 then
		return false
	end

	Net.FireServer("RequestPurge")

	if self._audio then
		self._audio:PlayUi("ability_purge")
	end
	return true
end

function InteractionController:_readBehaviours(behaviours: any)
	if type(behaviours) ~= "table" then
		return
	end
	self._canRemoteBank = behaviours.remote_bank == true
end

--[[
	Banks from anywhere, at the penalty the unlock carries.

	Returns false when it is not available, so the caller can fall through to the
	ordinary interaction rather than the key silently doing nothing.
]]
function InteractionController:RemoteBank(): boolean
	local carry = self._carry
	if not carry or (carry.carried or 0) <= 0 then
		return false
	end
	if not self._canRemoteBank then
		return false
	end

	Net.FireServer("RequestRemoteBank")
	self._banking = true

	if self._audio then
		self._audio:PlayUi("bank_start")
	end
	return true
end

-- ============================================================================
-- Discoveries
-- ============================================================================

function InteractionController:_forgetDiscovery(discoveryId: string?)
	if not discoveryId then
		return
	end
	for index = #self._discoveries, 1, -1 do
		if self._discoveries[index].id == discoveryId then
			table.remove(self._discoveries, index)
		end
	end
end

--[[
	Reports any discovery trigger the player is standing in.

	Client-side detection because it must be instant and because the server has no
	business testing every player against every secret every frame. Nothing is
	trusted: the report carries an id and a position, and the server re-checks the
	distance from its own copy of where the player is.
]]
function InteractionController:_checkDiscoveries(position: Vector3)
	for _, entry in ipairs(self._discoveries) do
		if self._reported[entry.id] then
			continue
		end
		if (entry.position - position).Magnitude <= (entry.radius or 12) then
			self._reported[entry.id] = true
			Net.FireServer("ReportDiscovery", entry.id, position)
		end
	end
end

-- ============================================================================
-- Revival
-- ============================================================================

--[[ The nearest downed runner within reviving distance, if any. ]]
function InteractionController:_nearestDowned(position: Vector3): (number?, number)
	local bestId, bestDistance = nil, math.huge

	for userId, downedPosition in pairs(self._downed) do
		local distance = (downedPosition - position).Magnitude
		if distance < bestDistance and distance <= Balance.Survival.REVIVE_RADIUS then
			bestId, bestDistance = userId, distance
		end
	end

	return bestId, bestDistance
end

-- ============================================================================
-- Prompt
-- ============================================================================

function InteractionController:_buildPrompt(screenGui: ScreenGui)
	local container = Components.Container({
		parent = screenGui,
		name = "Prompt",
		size = UDim2.fromOffset(320, 92),
		position = UDim2.fromScale(0.5, 0.72),
		anchorPoint = Vector2.new(0.5, 0.5),
		zIndex = Theme.ZIndex.hudOverlay,
	})
	container.Visible = false
	self._prompt = container

	local panel = Components.Panel({
		parent = container,
		name = "Panel",
		size = UDim2.fromScale(1, 1),
		elevation = 2,
		transparency = 0.12,
		padding = Theme.Space.md,
		zIndex = container.ZIndex,
	})
	self._promptPanel = panel

	self._promptKey = Components.Text({
		parent = panel,
		name = "Key",
		text = "E",
		size = UDim2.fromOffset(44, 44),
		position = UDim2.fromOffset(0, 6),
		textSize = Theme.Text.heading,
		font = Theme.Font.heading,
		color = Theme.Color.accent,
		alignX = Enum.TextXAlignment.Center,
		zIndex = panel.ZIndex + 2,
	})

	-- The key is drawn inside a bordered square so it reads as a key rather than
	-- as a letter that happens to be there.
	local keyFrame = Components.Panel({
		parent = panel,
		name = "KeyFrame",
		size = UDim2.fromOffset(44, 44),
		position = UDim2.fromOffset(0, 6),
		elevation = 3,
		radius = Theme.Radius.sm,
		zIndex = panel.ZIndex + 1,
		borderColor = Theme.Color.accent,
	})
	self._promptKey.Parent = keyFrame
	self._promptKey.Position = UDim2.fromScale(0, 0)
	self._promptKey.Size = UDim2.fromScale(1, 1)

	self._promptVerb = Components.Text({
		parent = panel,
		name = "Verb",
		text = "",
		position = UDim2.fromOffset(56, 4),
		size = UDim2.new(1, -56, 0, 22),
		textSize = Theme.Text.body,
		font = Theme.Font.heading,
		color = Theme.Color.textPrimary,
		zIndex = panel.ZIndex + 2,
	})

	self._promptName = Components.Text({
		parent = panel,
		name = "Name",
		text = "",
		position = UDim2.fromOffset(56, 26),
		size = UDim2.new(1, -56, 0, 16),
		textSize = Theme.Text.label,
		color = Theme.Color.textSecondary,
		zIndex = panel.ZIndex + 2,
	})

	-- The payout preview. This is the single most valuable line in the game's UI:
	-- it is the number the player is deciding about.
	self._promptDetail = Components.Text({
		parent = panel,
		name = "Detail",
		text = "",
		position = UDim2.fromOffset(56, 44),
		size = UDim2.new(1, -56, 0, 18),
		textSize = Theme.Text.label,
		font = Theme.Font.medium,
		color = Theme.Color.watts,
		zIndex = panel.ZIndex + 2,
	})

	local _, progressBar = Components.Bar({
		parent = panel,
		name = "Progress",
		size = UDim2.new(1, 0, 0, 3),
		position = UDim2.new(0, 0, 1, -3),
		color = Theme.Color.accent,
		zIndex = panel.ZIndex + 2,
	})
	self._promptProgress = progressBar
end

-- ============================================================================
-- Targeting
-- ============================================================================

--[[ The nearest in-range interactable, or nil. ]]
function InteractionController:_resolveTarget()
	local character = LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		return nil
	end

	local origin = (root :: BasePart).Position

	-- Discoveries are checked on the same pass rather than in their own loop: the
	-- work is identical, and doing it twice would double the per-frame cost of the
	-- cheapest correct implementation.
	self:_checkDiscoveries(origin)

	local best, bestDistance = nil, math.huge

	for _, entry in ipairs(self._manifest) do
		local distance = (entry.position - origin).Magnitude
		if distance <= (entry.range or 16) and distance < bestDistance then
			best, bestDistance = entry, distance
		end
	end

	-- A downed runner outranks every object. Nothing in the manifest is more
	-- urgent than a person on a timer, and a prompt that offered a bank while
	-- somebody bled out next to it would be a design failure, not a preference.
	local downedId, downedDistance = self:_nearestDowned(origin)
	if downedId and downedDistance < math.huge then
		return {
			id = "revive:" .. tostring(downedId),
			kind = "revive",
			userId = downedId,
			position = self._downed[downedId],
			range = Balance.Survival.REVIVE_RADIUS,
			name = "Downed runner",
		}
	end

	return best
end

function InteractionController:Update(deltaTime: number)
	local target = self:_resolveTarget()

	if target ~= self._target then
		self._target = target
		self.TargetChanged:Fire(target)

		if target then
			self:_showPrompt(target)
		else
			self:_hidePrompt()
		end
	end

	if self._target then
		self:_updatePromptDetail(self._target)
	end

	self._promptProgress:Update(deltaTime)
end

function InteractionController:_showPrompt(target: any)
	self._prompt.Visible = true

	local actionId = target.kind == "bank" and "bank" or "interact"
	self._promptKey.Text = self._input:GetPrompt(actionId)
	self._promptVerb.Text = VERBS[target.kind] or "USE"
	self._promptName.Text = target.name or ""

	self._prompt.Position = UDim2.fromScale(0.5, 0.74)
	TweenService:Create(self._prompt, Theme.Tween("fast", "enter"), {
		Position = UDim2.fromScale(0.5, 0.72),
	}):Play()

	if self._audio then
		self._audio:PlayUi("ui_hover")
	end
end

function InteractionController:_hidePrompt()
	self._prompt.Visible = false
end

--[[
	Fills the prompt's detail line. For a bank this is the projected payout, which
	is computed with the same multiplier the server will use, so the number the
	player commits to is the number they get.
]]
function InteractionController:_updatePromptDetail(target: any)
	if target.kind ~= "bank" then
		if target.kind == "cache" then
			self._promptDetail.Text = "Recover dropped energy"
			self._promptDetail.TextColor3 = Theme.Color.energy
		elseif target.kind == "event_node" then
			self._promptDetail.Text = "Deliver your entire carry"
			self._promptDetail.TextColor3 = Theme.Color.warning
		else
			self._promptDetail.Text = ""
		end
		return
	end

	local carry = self._carry
	if not carry or (carry.carried or 0) <= 0 then
		self._promptDetail.Text = "Nothing to bank"
		self._promptDetail.TextColor3 = Theme.Color.textTertiary
		return
	end

	-- Base × the live multiplier. Bank efficiency is folded into the multiplier the
	-- server sends, so this stays a single honest projection rather than a guess.
	local projected = carry.carried * (carry.multiplier or 1) * Balance.Bank.WATTS_PER_ENERGY

	self._promptDetail.Text = ("%s W   ·   %s energy × %.2f"):format(
		Theme.FormatNumber(projected),
		Theme.FormatNumber(carry.carried),
		carry.multiplier or 1
	)
	self._promptDetail.TextColor3 = Theme.Color.watts

	-- The prompt border warns when instability is high, because that is exactly the
	-- moment a player is deciding whether to bank or push on.
	local stroke = self._promptPanel:FindFirstChildOfClass("UIStroke")
	if stroke then
		local instability = carry.instability or 0
		if instability >= Balance.Carry.INSTABILITY_WARNING then
			stroke.Color = Theme.InstabilityColor(instability)
			stroke.Thickness = Theme.Stroke.thick
		else
			stroke.Color = Theme.Color.borderStrong
			stroke.Thickness = Theme.Stroke.hairline
		end
	end
end

-- ============================================================================
-- Action
-- ============================================================================

function InteractionController:Interact(): boolean
	local target = self._target
	if not target or self._banking then
		return false
	end

	if target.kind == "revive" then
		Net.FireServer("RequestRevive", target.userId)
		if self._audio then
			self._audio:PlayUi("ui_click")
		end
		return true
	end

	if target.kind == "bank" then
		-- Banking goes through its own remote rather than the generic interact path,
		-- because it is the only interaction that takes an argument the player
		-- chooses: a partial deposit when they are holding the sprint modifier, so
		-- keeping a chain alive does not require letting go of everything.
		Net.FireServer("RequestBank", target.id, self._input:IsHeld("sprint"))
	else
		Net.FireServer("RequestInteract", target.id)
	end

	if target.kind == "bank" then
		-- Banking has a wind-up on the server; the prompt shows it filling so the
		-- commitment is visible rather than a frozen moment.
		self._banking = true
		self._promptProgress:SetValue(0, true)
		self._promptProgress:SetValue(1)

		task.delay(Balance.Bank.BANK_DURATION + 0.3, function()
			self._banking = false
			self._promptProgress:SetValue(0, true)
		end)

		if self._audio then
			self._audio:PlayUi("bank_start")
		end
	else
		Components.Pulse(self._promptPanel, 1.04, "fast")
		if self._audio then
			self._audio:PlayUi("ui_click")
		end
	end

	return true
end

function InteractionController:GetTarget()
	return self._target
end

function InteractionController:Destroy()
	self._maid:DoCleaning()
end

return InteractionController
