--!strict
--[[
	NotificationController
	----------------------
	Toasts, item reveals and server announcements.

	The governing rule is that notifications must never become noise. So:
	  * A queue with a hard concurrent limit, and low-priority messages are dropped
	    rather than delayed when the queue is busy — a stale toast helps nobody.
	  * Duplicate messages within a short window collapse into a count rather than
	    stacking.
	  * Rarity drives presentation. A common material is a one-line tick that
	    expires in a second; a legendary is a full reveal that takes over the
	    centre of the screen, because that moment is the reason the loot system
	    exists.
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BTS")
local Theme = require(Shared.Config.Theme)
local Net = require(Shared.Net)
local Maid = require(Shared.Core.Maid)

local Client = script.Parent.Parent
local Components = require(Client.UI.Components)

local NotificationController = {}
NotificationController.Name = "NotificationController"
NotificationController.Priority = 35

local LocalPlayer = Players.LocalPlayer

local MAX_VISIBLE = 4
local TOAST_HEIGHT = 62
local DEFAULT_LIFETIME = 4

--[[ Presentation per kind. `priority` decides what survives a busy queue. ]]
local KINDS = {
	good = { color = Theme.Color.success, priority = 3, lifetime = 4 },
	info = { color = Theme.Color.info, priority = 2, lifetime = 3.5 },
	warning = { color = Theme.Color.warning, priority = 4, lifetime = 5 },
	bad = { color = Theme.Color.danger, priority = 5, lifetime = 5 },
	urgent = { color = Theme.Color.danger, priority = 6, lifetime = 6 },
}

function NotificationController:Init()
	self._maid = Maid.new()
	self._toasts = {}
	self._recent = {}

	local playerGui = LocalPlayer:WaitForChild("PlayerGui")

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "BTS_Notifications"
	screenGui.ResetOnSpawn = false
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.DisplayOrder = Theme.ZIndex.notification
	screenGui.Parent = playerGui
	self._maid:Add(screenGui)
	self._screenGui = screenGui

	-- Toasts stack down the right edge, below the objective panel.
	self._stack = Components.Container({
		parent = screenGui,
		name = "Stack",
		size = UDim2.fromOffset(320, MAX_VISIBLE * (TOAST_HEIGHT + Theme.Space.sm)),
		position = UDim2.new(1, -Theme.Layout.screenPadding, 0, 210),
		anchorPoint = Vector2.new(1, 0),
		zIndex = Theme.ZIndex.notification,
	})
	Components.List(self._stack, { gap = Theme.Space.sm, alignX = Enum.HorizontalAlignment.Right })

	self:_buildRevealPanel(screenGui)
	self:_buildAnnouncementBar(screenGui)
end

function NotificationController:Start()
	self._audio = self.Registry:Find("AudioController")

	self._maid:Add(Net.OnClientEvent("Notification", function(payload)
		self:Push(payload)
	end))

	self._maid:Add(Net.OnClientEvent("ItemAcquired", function(view)
		self:ShowItemReveal(view)
	end))

	self._maid:Add(Net.OnClientEvent("ServerAnnouncement", function(payload)
		self:ShowAnnouncement(payload)
	end))

	self._maid:Add(Net.OnClientEvent("CaptureResult", function(result)
		-- Drops from a capture reveal individually, because a legendary arriving
		-- mid-run is the moment the whole loot system is built around.
		for _, drop in ipairs(result.drops or {}) do
			if drop.kind == "equipment" or drop.kind == "unique" then
				self:ShowItemReveal(drop.view)
			else
				self:Push({
					kind = "good",
					title = ("+%d %s"):format(drop.quantity or 1, drop.name or drop.id),
					transient = true,
					lifetime = 2,
				})
			end
		end
	end))

	self._maid:Add(Net.OnClientEvent("WorldEventStarted", function(payload)
		self:ShowAnnouncement({
			kind = "event",
			title = payload.name,
			body = payload.announcement,
			regionName = payload.regionName,
		})
	end))
end

-- ============================================================================
-- Toasts
-- ============================================================================

function NotificationController:Push(payload: {
	kind: string?,
	title: string,
	body: string?,
	lifetime: number?,
	transient: boolean?,
})
	local kind = KINDS[payload.kind or "info"] or KINDS.info

	-- Collapse duplicates rather than stacking them.
	local key = (payload.title or "") .. "|" .. (payload.body or "")
	local recent = self._recent[key]
	if recent and os.clock() - recent.at < 3 and recent.toast and recent.toast.frame.Parent then
		recent.count += 1
		recent.at = os.clock()
		recent.toast.title.Text = ("%s  ×%d"):format(payload.title, recent.count)
		self:_extendLifetime(recent.toast, kind.lifetime)
		return
	end

	-- A busy queue drops the least important message rather than delaying it.
	if #self._toasts >= MAX_VISIBLE then
		local weakest, weakestIndex = nil, nil
		for index, toast in ipairs(self._toasts) do
			if not weakest or toast.priority < weakest.priority then
				weakest, weakestIndex = toast, index
			end
		end
		if weakest and weakest.priority < kind.priority then
			self:_dismiss(weakestIndex)
		else
			return
		end
	end

	local toast = self:_createToast(payload, kind)
	table.insert(self._toasts, toast)
	self._recent[key] = { at = os.clock(), count = 1, toast = toast }

	if self._audio and not payload.transient then
		self._audio:PlayUi("notification")
	end
end

function NotificationController:_createToast(payload: any, kind: any)
	local frame = Components.Panel({
		parent = self._stack,
		name = "Toast",
		size = UDim2.new(1, 0, 0, TOAST_HEIGHT),
		elevation = 2,
		transparency = 0.08,
		padding = Theme.Space.md,
		zIndex = Theme.ZIndex.notification,
		borderColor = kind.color,
	})
	frame.LayoutOrder = -math.floor(os.clock() * 1000)

	-- A coloured spine rather than a coloured background: the kind is legible
	-- without the text losing contrast.
	local spine = Instance.new("Frame")
	spine.Name = "Spine"
	spine.Size = UDim2.new(0, 3, 1, -Theme.Space.md)
	spine.Position = UDim2.fromOffset(-Theme.Space.md + 2, Theme.Space.sm / 2)
	spine.BackgroundColor3 = kind.color
	spine.BorderSizePixel = 0
	spine.ZIndex = frame.ZIndex + 1
	spine.Parent = frame
	Components.Corner(spine, Theme.Radius.sm)

	local title = Components.Text({
		parent = frame,
		name = "Title",
		text = payload.title,
		size = UDim2.new(1, 0, 0, 18),
		textSize = Theme.Text.body,
		font = Theme.Font.medium,
		color = kind.color,
		zIndex = frame.ZIndex + 1,
	})

	local body = nil
	if payload.body then
		body = Components.Text({
			parent = frame,
			name = "Body",
			text = payload.body,
			position = UDim2.fromOffset(0, 20),
			size = UDim2.new(1, 0, 0, 30),
			textSize = Theme.Text.label,
			color = Theme.Color.textSecondary,
			wrapped = true,
			alignY = Enum.TextYAlignment.Top,
			zIndex = frame.ZIndex + 1,
		})
	end

	Components.FadeIn(frame, { duration = "fast", slide = Vector2.new(40, 0) })

	local toast = {
		frame = frame,
		title = title,
		body = body,
		priority = kind.priority,
		expiresAt = os.clock() + (payload.lifetime or kind.lifetime or DEFAULT_LIFETIME),
	}

	return toast
end

function NotificationController:_extendLifetime(toast: any, lifetime: number)
	toast.expiresAt = os.clock() + lifetime
end

function NotificationController:_dismiss(index: number)
	local toast = self._toasts[index]
	if not toast then
		return
	end
	table.remove(self._toasts, index)

	local frame = toast.frame
	TweenService:Create(frame, Theme.Tween("fast", "exit"), {
		BackgroundTransparency = 1,
		Position = frame.Position + UDim2.fromOffset(40, 0),
	}):Play()
	for _, descendant in ipairs(frame:GetDescendants()) do
		if descendant:IsA("TextLabel") then
			TweenService:Create(descendant, Theme.Tween("fast", "exit"), { TextTransparency = 1 }):Play()
		end
	end

	task.delay(Theme.Duration.fast + 0.05, function()
		frame:Destroy()
	end)
end

-- ============================================================================
-- Item reveal
-- ============================================================================

function NotificationController:_buildRevealPanel(screenGui: ScreenGui)
	local container = Components.Container({
		parent = screenGui,
		name = "Reveal",
		size = UDim2.fromOffset(420, 200),
		position = UDim2.fromScale(0.5, 0.42),
		anchorPoint = Vector2.new(0.5, 0.5),
		zIndex = Theme.ZIndex.notification + 10,
	})
	container.Visible = false
	self._reveal = container

	local panel = Components.Panel({
		parent = container,
		name = "Panel",
		size = UDim2.fromScale(1, 1),
		elevation = 3,
		padding = Theme.Space.xl,
		zIndex = container.ZIndex,
	})
	self._revealPanel = panel

	self._revealRarity = Components.Label({
		parent = panel,
		name = "Rarity",
		text = "",
		size = UDim2.new(1, 0, 0, 16),
		textSize = Theme.Text.label,
		alignX = Enum.TextXAlignment.Center,
		zIndex = panel.ZIndex + 1,
	})

	self._revealName = Components.Text({
		parent = panel,
		name = "Name",
		text = "",
		position = UDim2.fromOffset(0, 22),
		size = UDim2.new(1, 0, 0, 40),
		textSize = Theme.Text.title,
		font = Theme.Font.display,
		alignX = Enum.TextXAlignment.Center,
		wrapped = true,
		zIndex = panel.ZIndex + 1,
	})

	self._revealSlot = Components.Text({
		parent = panel,
		name = "Slot",
		text = "",
		position = UDim2.fromOffset(0, 66),
		size = UDim2.new(1, 0, 0, 18),
		textSize = Theme.Text.label,
		color = Theme.Color.textSecondary,
		alignX = Enum.TextXAlignment.Center,
		zIndex = panel.ZIndex + 1,
	})

	self._revealStats = Components.Container({
		parent = panel,
		name = "Stats",
		size = UDim2.new(1, 0, 0, 70),
		position = UDim2.fromOffset(0, 90),
		zIndex = panel.ZIndex + 1,
	})
	Components.List(self._revealStats, { gap = 2, alignX = Enum.HorizontalAlignment.Center })
end

function NotificationController:ShowItemReveal(view: any)
	if not view then
		return
	end

	local rarity = Theme.GetRarity(view.rarity)
	local isBig = view.rarity == "legendary" or view.rarity == "mythic" or view.rarity == "exotic"

	-- Ordinary drops are a toast; the ones worth remembering take the screen.
	if not isBig then
		self:Push({
			kind = "good",
			title = view.name,
			body = ("%s  ·  %s"):format(rarity.label, view.baseName or ""),
			lifetime = 3,
		})
		if self._audio then
			self._audio:PlayUi(view.rarity == "epic" and "drop_rare" or "drop_common")
		end
		return
	end

	self._revealRarity.Text = string.upper(rarity.label)
	self._revealRarity.TextColor3 = rarity.color
	self._revealName.Text = view.name
	self._revealName.TextColor3 = rarity.color
	self._revealSlot.Text = view.trait
		and string.upper(view.trait.name)
		or string.upper(view.baseName or "")

	self._revealStats:ClearAllChildren()
	Components.List(self._revealStats, { gap = 2, alignX = Enum.HorizontalAlignment.Center })

	local order = 0
	for _, affix in ipairs(view.affixes or {}) do
		order += 1
		if order > 4 then
			break
		end
		Components.Text({
			parent = self._revealStats,
			name = "Affix" .. order,
			text = affix.text,
			size = UDim2.new(1, 0, 0, 15),
			textSize = Theme.Text.label,
			color = Theme.Color.accent,
			alignX = Enum.TextXAlignment.Center,
			layoutOrder = order,
			zIndex = self._revealStats.ZIndex + 1,
		})
	end
	if view.trait then
		order += 1
		Components.Text({
			parent = self._revealStats,
			name = "Trait",
			text = view.trait.description,
			size = UDim2.new(1, 0, 0, 30),
			textSize = Theme.Text.caption,
			color = Theme.Color.warning,
			alignX = Enum.TextXAlignment.Center,
			wrapped = true,
			layoutOrder = order,
			zIndex = self._revealStats.ZIndex + 1,
		})
	end

	local stroke = self._revealPanel:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Color = rarity.color
		stroke.Thickness = Theme.Stroke.thick
	end

	self._reveal.Visible = true
	self._reveal.Size = UDim2.fromOffset(380, 180)
	TweenService:Create(self._reveal, Theme.Tween("slow", "enter"), {
		Size = UDim2.fromOffset(420, 200),
	}):Play()
	Components.FadeIn(self._revealPanel, { duration = "slow" })

	if self._audio then
		self._audio:PlayUi("drop_legendary")
	end

	if self._revealTask then
		task.cancel(self._revealTask)
	end
	self._revealTask = task.delay(4.5, function()
		for _, descendant in ipairs(self._reveal:GetDescendants()) do
			if descendant:IsA("TextLabel") then
				TweenService:Create(descendant, Theme.Tween("slow", "exit"), { TextTransparency = 1 }):Play()
			end
		end
		TweenService:Create(self._revealPanel, Theme.Tween("slow", "exit"), { BackgroundTransparency = 1 }):Play()
		task.wait(Theme.Duration.slow)
		self._reveal.Visible = false
		self._revealTask = nil
	end)
end

-- ============================================================================
-- Server announcements
-- ============================================================================

function NotificationController:_buildAnnouncementBar(screenGui: ScreenGui)
	local bar = Components.Panel({
		parent = screenGui,
		name = "Announcement",
		size = UDim2.fromOffset(620, 46),
		position = UDim2.new(0.5, 0, 0, -60),
		anchorPoint = Vector2.new(0.5, 0),
		elevation = 3,
		padding = Theme.Space.md,
		zIndex = Theme.ZIndex.notification + 5,
	})
	bar.Visible = false
	self._announcementBar = bar

	self._announcementText = Components.Text({
		parent = bar,
		name = "Text",
		text = "",
		size = UDim2.fromScale(1, 1),
		textSize = Theme.Text.body,
		font = Theme.Font.medium,
		alignX = Enum.TextXAlignment.Center,
		richText = true,
		zIndex = bar.ZIndex + 1,
	})
end

function NotificationController:ShowAnnouncement(payload: any)
	local text, color

	if payload.kind == "rare_drop" then
		local rarity = Theme.GetRarity(payload.rarity)
		color = rarity.color
		text = ("%s found <b>%s</b>"):format(payload.playerName, payload.itemName)
	elseif payload.kind == "prestige" then
		color = Theme.Color.sigils
		text = ("%s reached <b>Prestige %d — %s</b>"):format(payload.playerName, payload.rank, payload.rankName)
	elseif payload.kind == "event" then
		color = Theme.Color.warning
		text = payload.regionName
			and ("<b>%s</b> — %s  ·  %s"):format(payload.title, payload.body, payload.regionName)
			or ("<b>%s</b> — %s"):format(payload.title, payload.body)
	else
		color = Theme.Color.textPrimary
		text = payload.title or ""
	end

	self._announcementText.Text = text
	self._announcementText.TextColor3 = color

	local stroke = self._announcementBar:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Color = color
	end

	self._announcementBar.Visible = true
	TweenService:Create(self._announcementBar, Theme.Tween("slow", "enter"), {
		Position = UDim2.new(0.5, 0, 0, Theme.Space.sm),
	}):Play()

	if self._announcementTask then
		task.cancel(self._announcementTask)
	end
	self._announcementTask = task.delay(5, function()
		local slide = TweenService:Create(self._announcementBar, Theme.Tween("slow", "exit"), {
			Position = UDim2.new(0.5, 0, 0, -60),
		})
		slide:Play()
		slide.Completed:Once(function()
			self._announcementBar.Visible = false
		end)
		self._announcementTask = nil
	end)
end

-- ============================================================================
-- Tick
-- ============================================================================

function NotificationController:Update(deltaTime: number)
	local now = os.clock()
	for index = #self._toasts, 1, -1 do
		if now >= self._toasts[index].expiresAt then
			self:_dismiss(index)
		end
	end

	-- Prune the duplicate-collapse table so it does not grow across a session.
	for key, entry in pairs(self._recent) do
		if now - entry.at > 10 then
			self._recent[key] = nil
		end
	end
end

function NotificationController:Destroy()
	if self._revealTask then
		task.cancel(self._revealTask)
	end
	if self._announcementTask then
		task.cancel(self._announcementTask)
	end
	self._maid:DoCleaning()
end

return NotificationController
