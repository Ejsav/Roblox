--!strict
--[[
	HudController
	-------------
	Wires the HUD to the network. It owns the Hud screen instance and translates
	every server message into a HUD call, which keeps the Hud itself a pure view with
	no knowledge of remotes.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BTS")
local Net = require(Shared.Net)
local Theme = require(Shared.Config.Theme)
local Maid = require(Shared.Core.Maid)
local Regions = require(Shared.Config.Regions)

local Client = script.Parent.Parent
local Hud = require(Client.UI.Screens.Hud)

local HudController = {}
HudController.Name = "HudController"
HudController.Dependencies = { "InputController", "StormController" }
HudController.Priority = 30

local LocalPlayer = Players.LocalPlayer

function HudController:Init()
	self._maid = Maid.new()

	local playerGui = LocalPlayer:WaitForChild("PlayerGui")

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "BTS_Hud"
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = false
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.DisplayOrder = Theme.ZIndex.hud
	screenGui.Parent = playerGui
	self._maid:Add(screenGui)

	self._screenGui = screenGui
end

function HudController:Start()
	self._hud = Hud.new(self._screenGui, self.Registry:GetAll())
	self._maid:Add(self._hud)

	local storms = self.Registry:Get("StormController")
	self._maid:Add(storms.CaptureFeedback:Connect(function(result)
		-- Predicted feedback is suppressed when it agrees with what the server will
		-- say; only the authoritative result is shown, which avoids a double flash.
		if result.predicted then
			return
		end
		self._hud:ShowCaptureFeedback(result)
	end))

	self:_bindNetwork()
end

function HudController:_bindNetwork()
	local maid = self._maid

	maid:Add(Net.OnClientEvent("ProfileSync", function(payload)
		self._hud:UpdateCurrency(payload.profile.watts, payload.profile.cores)
		self._hud:UpdateLevel(payload.level)
		self._hud:UpdateCarry(payload.carry)

		-- A returning player gets one compact summary rather than a queue of popups.
		if payload.returningSummary then
			self._hud:ShowBanner({
				title = "Welcome back",
				subtitle = payload.nextQuest and payload.nextQuest.name or nil,
				detail = payload.nextRegion and payload.nextRegion.requirement or nil,
				duration = 5,
			})
		elseif payload.nextQuest then
			self._hud:ShowBanner({
				title = "BORROW THE STORM",
				subtitle = payload.nextQuest.summary,
				duration = 5,
			})
		end
	end))

	maid:Add(Net.OnClientEvent("ProfileDelta", function(payload)
		if payload.watts or payload.cores then
			self._hud:UpdateCurrency(payload.watts, payload.cores)
		end
		if payload.level then
			self._hud:UpdateLevel(payload.level)
		end
	end))

	maid:Add(Net.OnClientEvent("CarryUpdate", function(snapshot)
		self._hud:UpdateCarry(snapshot)
	end))

	maid:Add(Net.OnClientEvent("BankResult", function(result)
		if not result.success then
			return
		end
		self._hud:UpdateCurrency(nil, nil)
		self._hud:ShowBanner({
			title = ("+%s WATTS"):format(Theme.FormatNumber(result.watts)),
			subtitle = ("%s  ·  ×%.2f"):format(result.stationName, result.multiplier),
			detail = ("%s energy banked"):format(Theme.FormatNumber(result.energy)),
			color = Theme.Color.watts,
			duration = 3.5,
		})
	end))

	maid:Add(Net.OnClientEvent("LevelUp", function(payload)
		self._hud:ShowBanner({
			title = ("LEVEL %d"):format(payload.level),
			subtitle = payload.skillPointsGained > 0
				and ("+%d skill point%s"):format(
					payload.skillPointsGained,
					payload.skillPointsGained == 1 and "" or "s"
				)
				or nil,
			detail = payload.nextRegion and ("Next: %s — %s"):format(payload.nextRegion.name, payload.nextRegion.requirement) or nil,
			color = Theme.Color.accent,
			duration = 4.5,
		})
	end))

	maid:Add(Net.OnClientEvent("UnlockGranted", function(payload)
		local detail = payload.detail
		self._hud:ShowBanner({
			title = payload.name,
			subtitle = detail and (detail.description or detail.tutorial) or nil,
			color = Theme.Color.success,
			duration = 4.5,
		})
	end))

	maid:Add(Net.OnClientEvent("RegionChanged", function(payload)
		local dangerColor = Theme.DangerColor(payload.danger)
		self._hud:ShowBanner({
			title = payload.name,
			subtitle = payload.subtitle,
			detail = payload.cleared
				and ("Danger %d  ·  Recommended level %d"):format(payload.danger, payload.recommendedLevel)
				or ("NOT RATED FOR THIS REGION  ·  %s"):format(self:_describeBlock(payload)),
			color = payload.cleared and dangerColor or Theme.Color.danger,
			duration = payload.firstVisit and 6 or 3,
		})
	end))

	maid:Add(Net.OnClientEvent("QuestUpdate", function(payload)
		local tracked = nil
		for _, quest in ipairs(payload.active) do
			if quest.id == payload.tracked then
				tracked = quest
				break
			end
		end
		tracked = tracked or payload.active[1]
		self._hud:UpdateObjective(tracked)
	end))

	maid:Add(Net.OnClientEvent("QuestCompleted", function(payload)
		self._hud:ShowBanner({
			title = "Objective complete",
			subtitle = payload.name,
			detail = payload.storyBeat,
			color = Theme.Color.success,
			duration = payload.storyBeat and 6 or 3.5,
		})
	end))

	maid:Add(Net.OnClientEvent("AbilityState", function(payload)
		if payload.kind == "loadout" then
			self._hud:UpdateAbilities(payload.slots)
		end
	end))

	-- World events feed the tracker from three messages. Start and phase carry the
	-- text; progress carries the numbers, several times a second.
	maid:Add(Net.OnClientEvent("WorldEventStarted", function(payload)
		self._hud:UpdateWorldEvent({
			name = payload.name,
			phaseName = payload.phaseName,
			objective = payload.announcement,
		})
	end))

	maid:Add(Net.OnClientEvent("WorldEventPhase", function(payload)
		self._hud:UpdateWorldEvent({
			phaseName = payload.phaseName,
			phaseIndex = payload.phaseIndex,
			phaseCount = payload.phaseCount,
			objective = payload.description or payload.objective,
			remaining = payload.duration,
		})
	end))

	maid:Add(Net.OnClientEvent("WorldEventProgress", function(payload)
		self._hud:UpdateWorldEvent({
			remaining = payload.remaining,
			bossHealthFraction = payload.bossHealthFraction,
			nodes = payload.nodes,
			contribution = payload.contribution,
		})
	end))

	maid:Add(Net.OnClientEvent("WorldEventEnded", function(payload)
		self._hud:ClearWorldEvent()
		self._hud:ShowBanner({
			title = payload.failed and "EVENT LOST" or "EVENT COMPLETE",
			subtitle = payload.name,
			detail = payload.rank
				and ("Placed %d of %d"):format(payload.rank, payload.participants or payload.rank)
				or nil,
			color = payload.failed and Theme.Color.danger or Theme.Color.success,
			duration = 5,
		})
	end))

	-- A rare storm anywhere on the server is worth interrupting for; it is the
	-- game's only "drop what you are doing" signal that is not an emergency.
	maid:Add(Net.OnClientEvent("RareStormAlert", function(payload)
		local rarity = Theme.GetRarity(payload.rarity)
		self._hud:ShowBanner({
			title = string.upper(payload.name),
			subtitle = ("%s storm sighted"):format(rarity.label),
			detail = payload.regionId and self:_regionName(payload.regionId) or nil,
			color = rarity.color,
			duration = 5,
		})
	end))

	maid:Add(Net.OnClientEvent("DiscoveryMade", function(payload)
		self._hud:ShowBanner({
			title = "Discovery",
			subtitle = payload.name,
			detail = payload.total and ("%d of %d found"):format(payload.total.found, payload.total.total) or nil,
			color = Theme.Color.info,
			duration = 4,
		})
	end))

	maid:Add(Net.OnClientEvent("VentOccurred", function(payload)
		self._hud:ShowBanner({
			title = "CONTAINMENT VENTED",
			subtitle = ("-%s energy"):format(Theme.FormatNumber(payload.lost)),
			color = Theme.Color.instabilityCritical,
			duration = 3,
		})
	end))

	maid:Add(Net.OnClientEvent("RecordBroken", function(payload)
		self._hud:ShowBanner({
			title = "New record",
			subtitle = payload.name,
			detail = Theme.FormatNumber(payload.value),
			color = Theme.Color.warning,
			duration = 3.5,
		})
	end))
end

function HudController:_describeBlock(payload: any): string
	if payload.blockedReason == "level" then
		return ("Requires level %d"):format(payload.requirement)
	elseif payload.blockedReason == "quest" then
		return "Complete the story to enter safely"
	elseif payload.blockedReason == "traversal" then
		return "Requires movement technology you do not have"
	elseif payload.blockedReason == "prestige" then
		return "Requires prestige"
	end
	return "Turn back"
end

function HudController:Update(deltaTime: number)
	if self._hud then
		self._hud:Update(deltaTime)
	end
end

function HudController:GetHud()
	return self._hud
end

function HudController:SetVisible(visible: boolean)
	if self._hud then
		self._hud:SetVisible(visible)
	end
end

function HudController:Destroy()
	self._maid:DoCleaning()
end

--[[ A region's display name, for messages that only carry its id. ]]
function HudController:_regionName(regionId: string): string?
	local region = Regions.ById[regionId]
	return region and region.name or nil
end

--[[ Passed through to the HUD so the ability controller does not need to know
     how the HUD is laid out. ]]
function HudController:FlashAbilityRefusal(abilityId: string?, reason: string?)
	if self._hud then
		self._hud:FlashAbilityRefusal(abilityId, reason)
	end
end

return HudController
