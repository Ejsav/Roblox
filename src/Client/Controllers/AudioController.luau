--!strict
--[[
	AudioController
	---------------
	Sound. Pooled, budgeted, and mixed by category so a single volume slider
	actually controls what the player expects it to.

	The design job audio does here is warning. A storm should be audible before it
	is visible, and its intensity should be legible from sound alone — which means
	the ambience of a cell is driven continuously by its distance and charge rather
	than being a loop that either plays or does not.

	Sound ids are declared in one table. Where an id is absent the system stays
	silent rather than erroring, so the game is fully playable before audio lands
	and gains its soundtrack by filling in this table.
]]

local Players = game:GetService("Players")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")
local Debris = game:GetService("Debris")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BTS")
local Maid = require(Shared.Core.Maid)
local MathUtil = require(Shared.Core.MathUtil)
local StormTypes = require(Shared.Config.StormTypes)

local AudioController = {}
AudioController.Name = "AudioController"
AudioController.Priority = 16

local LocalPlayer = Players.LocalPlayer

--[[
	Sound library. Empty ids are intentional placeholders: the call sites are already
	correct, and filling in an id here makes that sound start working everywhere.
]]
local SOUNDS = {
	-- Capture
	capture_press = { id = "", volume = 0.5, category = "sfx" },
	capture_overcharge = { id = "", volume = 0.9, category = "sfx", pitch = 1.15 },
	capture_perfect = { id = "", volume = 0.8, category = "sfx", pitch = 1.08 },
	capture_good = { id = "", volume = 0.6, category = "sfx" },
	capture_weak = { id = "", volume = 0.45, category = "sfx", pitch = 0.92 },
	capture_miss = { id = "", volume = 0.5, category = "sfx", pitch = 0.85 },
	capture_no_target = { id = "", volume = 0.25, category = "ui" },

	-- Telegraph and discharge
	telegraph_soft = { id = "", volume = 0.4, category = "sfx" },
	telegraph_urgent = { id = "", volume = 0.6, category = "sfx" },
	discharge = { id = "", volume = 0.7, category = "sfx" },
	thunder_near = { id = "", volume = 0.9, category = "sfx" },
	thunder_far = { id = "", volume = 0.4, category = "sfx" },

	-- Carry and containment
	instability_warning = { id = "", volume = 0.6, category = "sfx" },
	instability_critical = { id = "", volume = 0.8, category = "sfx", looped = true },
	vent = { id = "", volume = 0.9, category = "sfx" },

	-- Banking and rewards
	bank_start = { id = "", volume = 0.5, category = "sfx" },
	bank_complete = { id = "", volume = 0.8, category = "sfx" },
	level_up = { id = "", volume = 0.9, category = "ui" },
	unlock = { id = "", volume = 0.8, category = "ui" },
	drop_common = { id = "", volume = 0.4, category = "ui" },
	drop_rare = { id = "", volume = 0.7, category = "ui" },
	drop_legendary = { id = "", volume = 1.0, category = "ui" },

	-- Interface
	ui_click = { id = "", volume = 0.3, category = "ui" },
	ui_hover = { id = "", volume = 0.15, category = "ui" },
	ui_open = { id = "", volume = 0.35, category = "ui" },
	ui_close = { id = "", volume = 0.3, category = "ui" },
	ui_error = { id = "", volume = 0.4, category = "ui" },
	notification = { id = "", volume = 0.4, category = "ui" },
}

function AudioController:Init()
	self._maid = Maid.new()
	self._volumes = { music = 0.55, sfx = 0.8, ui = 0.8 }
	self._stormAmbience = {} :: { [string]: any }
	self._pool = {}
	self._activeCount = 0
	self._maxConcurrent = 24

	-- Grouped so a category slider adjusts one thing rather than iterating sounds.
	self._groups = {}
	for _, category in ipairs({ "music", "sfx", "ui" }) do
		local group = Instance.new("SoundGroup")
		group.Name = "BTS_" .. category
		group.Volume = self._volumes[category]
		group.Parent = SoundService
		self._groups[category] = group
		self._maid:Add(group)
	end

	self._root = Instance.new("Folder")
	self._root.Name = "BTS_Audio"
	self._root.Parent = SoundService
	self._maid:Add(self._root)
end

function AudioController:Start()
	self._storms = self.Registry:Find("StormController")
end

-- ============================================================================
-- Playback
-- ============================================================================

--[[
	Plays a one-shot. Returns nil when the sound has no id yet or the concurrency
	budget is spent — both of which are normal, so callers never check.
]]
function AudioController:Play(soundKey: string, config: {
	position: Vector3?,
	pitch: number?,
	volumeScale: number?,
}?): Sound?
	local definition = SOUNDS[soundKey]
	if not definition or definition.id == "" then
		return nil
	end
	if self._activeCount >= self._maxConcurrent then
		return nil
	end

	local settings = config or {}
	local sound = Instance.new("Sound")
	sound.SoundId = definition.id
	sound.Volume = definition.volume * (settings.volumeScale or 1)
	sound.PlaybackSpeed = settings.pitch or definition.pitch or 1
	sound.SoundGroup = self._groups[definition.category]
	sound.RollOffMode = Enum.RollOffMode.InverseTapered
	sound.RollOffMaxDistance = 400
	sound.RollOffMinDistance = 12

	if settings.position then
		-- Positional sound needs an emitter part; an attachment on a zero-size
		-- anchored part is the cheapest way to get one.
		local emitter = Instance.new("Part")
		emitter.Size = Vector3.one * 0.1
		emitter.Transparency = 1
		emitter.Anchored = true
		emitter.CanCollide = false
		emitter.CanQuery = false
		emitter.Position = settings.position
		emitter.Parent = self._root
		sound.Parent = emitter
		Debris:AddItem(emitter, 12)
	else
		sound.Parent = self._root
	end

	self._activeCount += 1
	sound.Ended:Once(function()
		self._activeCount -= 1
	end)

	sound:Play()
	Debris:AddItem(sound, 12)
	return sound
end

function AudioController:PlayUi(soundKey: string)
	self:Play(soundKey)
end

-- ============================================================================
-- Gameplay hooks
-- ============================================================================

function AudioController:PlayTelegraph(strike: any)
	local storm = StormTypes.ById[strike.stormTypeId]
	local windup = strike.peakAt - strike.telegraphAt

	-- A short windup gets the urgent cue, because a player has no time to look.
	local key = windup < 1.4 and "telegraph_urgent" or "telegraph_soft"
	self:Play(key, { position = strike.position })
end

function AudioController:PlayDischarge(strike: any, captured: boolean)
	if captured then
		return
	end
	self:Play("discharge", { position = strike.position })

	-- Distant discharges become thunder, which is what makes the world sound
	-- occupied even when nothing is happening nearby.
	local character = LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root then
		local distance = ((root :: BasePart).Position - strike.position).Magnitude
		if distance > 200 then
			-- Delay by the speed of sound, which is a small touch that does a lot of
			-- work for how large the world feels.
			task.delay(distance / 340, function()
				self:Play(distance > 700 and "thunder_far" or "thunder_near", {
					volumeScale = math.clamp(1 - distance / 1600, 0.15, 1),
				})
			end)
		end
	end
end

function AudioController:PlayCapturePress(predictedGrade: string?)
	self:Play("capture_press")
end

function AudioController:PlayCaptureSuccess(grade: string)
	local key = "capture_good"
	if grade == "Overcharge" then
		key = "capture_overcharge"
	elseif grade == "Perfect" then
		key = "capture_perfect"
	elseif grade == "Weak" then
		key = "capture_weak"
	end
	self:Play(key)
end

function AudioController:PlayCaptureFail(reason: string?)
	self:Play(reason == "no_target" and "capture_no_target" or "capture_miss")
end

--[[
	Starts a continuous ambience for a cell. Volume and pitch are driven every frame
	from distance and charge, so the sound genuinely reports the cell's state.
]]
function AudioController:StartStormAmbience(cellId: string, cell: any)
	local storm = StormTypes.ById[cell.stormTypeId]
	if not storm then
		return
	end

	local definition = SOUNDS[storm.presentation.sound]
	if not definition or definition.id == "" then
		-- No id yet: record the cell anyway so the update loop is exercised and the
		-- ambience begins working the moment an id is filled in.
		self._stormAmbience[cellId] = { cell = cell, sound = nil }
		return
	end

	local emitter = Instance.new("Part")
	emitter.Size = Vector3.one * 0.1
	emitter.Transparency = 1
	emitter.Anchored = true
	emitter.CanCollide = false
	emitter.CanQuery = false
	emitter.Position = cell.position
	emitter.Parent = self._root

	local sound = Instance.new("Sound")
	sound.SoundId = definition.id
	sound.Looped = true
	sound.Volume = 0
	sound.SoundGroup = self._groups.sfx
	sound.RollOffMode = Enum.RollOffMode.InverseTapered
	sound.RollOffMaxDistance = 900
	sound.RollOffMinDistance = 40
	sound.Parent = emitter
	sound:Play()

	self._stormAmbience[cellId] = { cell = cell, sound = sound, emitter = emitter }
end

function AudioController:StopStormAmbience(cellId: string)
	local entry = self._stormAmbience[cellId]
	if not entry then
		return
	end
	self._stormAmbience[cellId] = nil

	if entry.sound then
		entry.sound:Stop()
	end
	if entry.emitter then
		entry.emitter:Destroy()
	end
end

-- ============================================================================
-- Mixing
-- ============================================================================

function AudioController:SetVolume(category: string, volume: number)
	self._volumes[category] = math.clamp(volume, 0, 1)
	local group = self._groups[category]
	if group then
		group.Volume = self._volumes[category]
	end
end

function AudioController:ApplySettings(settings: any)
	if settings.musicVolume then
		self:SetVolume("music", settings.musicVolume)
	end
	if settings.sfxVolume then
		self:SetVolume("sfx", settings.sfxVolume)
		self:SetVolume("ui", settings.sfxVolume)
	end
end

-- ============================================================================
-- Frame update
-- ============================================================================

function AudioController:Update(deltaTime: number)
	local character = LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		return
	end
	local origin = (root :: BasePart).Position

	for cellId, entry in pairs(self._stormAmbience) do
		local cell = entry.cell
		if entry.emitter then
			entry.emitter.Position = cell.position
		end

		if entry.sound then
			local distance = (cell.position - origin).Magnitude
			-- Volume falls off with distance and rises with the cell's remaining
			-- charge, so a spent cell goes quiet before it looks spent.
			local proximity = math.clamp(1 - distance / 900, 0, 1)
			local charge = cell.maxCharge > 0 and (cell.charge / cell.maxCharge) or 1
			local target = proximity * proximity * MathUtil.Lerp(0.3, 1, charge) * 0.6

			entry.sound.Volume = MathUtil.Damp(entry.sound.Volume, target, 3, deltaTime)
			-- A denser, more charged cell sits slightly lower in pitch, which reads
			-- as heavier without any conscious analysis.
			entry.sound.PlaybackSpeed = MathUtil.Lerp(1.1, 0.85, charge)
		end
	end
end

function AudioController:Destroy()
	for cellId in pairs(self._stormAmbience) do
		self:StopStormAmbience(cellId)
	end
	self._maid:DoCleaning()
end

return AudioController
