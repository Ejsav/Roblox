--!strict
--[[
	PlayerService
	-------------
	Player lifecycle: join, profile load, character setup, spawn placement, leave.

	It is deliberately the last thing to start, because it is the service that lets
	players in, and letting a player in before the systems that serve them are ready
	produces exactly the sort of first-thirty-seconds bug that costs a retention
	point.
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BTS")
local Signal = require(Shared.Core.Signal)
local Net = require(Shared.Net)
local Balance = require(Shared.Config.Balance)
local Regions = require(Shared.Config.Regions)
local Quests = require(Shared.Config.Quests)
local ProfileSchema = require(Shared.Data.ProfileSchema)

local PlayerService = {}
PlayerService.Name = "PlayerService"
PlayerService.Dependencies = {
	"DataService", "StatsService", "CarryService", "CombatService",
	"ProgressionService", "QuestService", "InventoryService", "AbilityService",
	"RegionService", "AnalyticsService",
}
PlayerService.Priority = 90

function PlayerService:Init()
	self._ready = {} :: { [number]: boolean }
	self._spawnPoints = {}

	self.PlayerReady = Signal.new("PlayerService.PlayerReady")
	self.PlayerLeaving = Signal.new("PlayerService.PlayerLeaving")

	-- Default spawn: the starter district's fast travel node.
	local starter = Regions.ById.starter_district
	self._defaultSpawn = Vector3.new(
		starter.fastTravel.position.X,
		starter.fastTravel.position.Y + 5,
		starter.fastTravel.position.Z
	)
end

function PlayerService:Start()
	self._data = self.Registry:Get("DataService")
	self._stats = self.Registry:Get("StatsService")
	self._carry = self.Registry:Get("CarryService")
	self._combat = self.Registry:Get("CombatService")
	self._progression = self.Registry:Get("ProgressionService")
	self._quests = self.Registry:Get("QuestService")
	self._inventory = self.Registry:Get("InventoryService")
	self._abilities = self.Registry:Get("AbilityService")
	self._regions = self.Registry:Get("RegionService")
	self._analytics = self.Registry:Get("AnalyticsService")
	self._antiCheat = self.Registry:Find("AntiCheatService")

	Net.OnServerEvent("RequestUpdateSettings", function(player, settings)
		self:UpdateSettings(player, settings)
	end)
	Net.OnServerEvent("ReportClientMetric", function(player, metric)
		self:_recordClientMetric(player, metric)
	end)
end

function PlayerService:Ready()
	-- Only now, with every service started, do we accept players.
	Players.PlayerAdded:Connect(function(player)
		task.spawn(function()
			self:_onPlayerAdded(player)
		end)
	end)

	Players.PlayerRemoving:Connect(function(player)
		self:_onPlayerRemoving(player)
	end)

	-- Anyone who joined during boot (which happens in Studio) is picked up here.
	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(function()
			self:_onPlayerAdded(player)
		end)
	end
end

-- ============================================================================
-- Join
-- ============================================================================

function PlayerService:_onPlayerAdded(player: Player)
	if self._ready[player.UserId] then
		return
	end

	local profile, failureReason = self._data:LoadProfile(player)
	if not profile then
		player:Kick(failureReason or "Could not load your save. Please rejoin.")
		return
	end

	-- Stats must resolve before the character exists, so the humanoid is created
	-- with the right max health and walk speed rather than being corrected a frame
	-- later in front of the player.
	self._stats:Recompute(player)

	self._ready[player.UserId] = true

	player.CharacterAdded:Connect(function(character)
		self:_onCharacterAdded(player, character)
	end)

	if player.Character then
		self:_onCharacterAdded(player, player.Character)
	end

	self:_sendInitialState(player)
	self.PlayerReady:Fire(player, profile)
	self._analytics:TrackFunnel(player, "joined")
end

function PlayerService:_onCharacterAdded(player: Player, character: Model)
	local humanoid = character:WaitForChild("Humanoid", 10) :: Humanoid?
	local root = character:WaitForChild("HumanoidRootPart", 10) :: BasePart?
	if not humanoid or not root then
		return
	end

	local profile = self._data:GetProfile(player)
	if not profile then
		return
	end

	-- Spawn at the last region's fast travel node when one is unlocked, so a
	-- returning player resumes where they were rather than at the tutorial.
	local spawnPosition = self:_resolveSpawn(profile)
	root.CFrame = CFrame.new(spawnPosition)

	self:ApplyMovementStats(player)

	humanoid.Died:Connect(function()
		-- CombatService owns death; this only covers a death it did not cause,
		-- such as falling out of the world.
		if not self._combat:IsDowned(player) then
			local health = self._combat:GetHealth(player)
			if health > 0 then
				self._combat:Kill(player, "world")
			end
		end
	end)

	if self._antiCheat then
		self._antiCheat:GrantMovementGrace(player, 3)
	end

	self._analytics:TrackFunnel(player, "spawned")
end

function PlayerService:_resolveSpawn(profile: any): Vector3
	local regionId = profile.lastRegion
	local region = regionId and Regions.ById[regionId]

	if region and region.fastTravel and profile.fastTravelUnlocked[region.fastTravel.id] then
		return Vector3.new(
			region.fastTravel.position.X,
			region.fastTravel.position.Y + 5,
			region.fastTravel.position.Z
		)
	end

	return self._defaultSpawn
end

--[[
	Pushes the resolved movement stats onto the Humanoid.
	Called on spawn and whenever stats change, so an upgrade is felt immediately.
]]
function PlayerService:ApplyMovementStats(player: Player)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end

	local stats = self._stats:GetStats(player)

	-- Carry weight slows you down, mitigated by Load Handling.
	local fill = self._carry:GetFillFraction(player)
	local penaltyResist = math.clamp(stats.carryPenaltyResist, 0, 1)
	local penalty = Balance.Movement.CARRY_SPEED_PENALTY_AT_FULL * fill * (1 - penaltyResist)

	humanoid.WalkSpeed = stats.moveSpeed * (1 - penalty)
	humanoid.JumpPower = stats.jumpPower
	humanoid.UseJumpPower = true
	humanoid.MaxHealth = stats.maxHealth

	-- Counterweight turns a heavy load into jump height instead of a speed loss.
	if self._stats:HasBehaviour(player, "heavy_jump") and fill >= 0.75 then
		humanoid.WalkSpeed = stats.moveSpeed
		humanoid.JumpPower = stats.jumpPower * (1 + (fill - 0.75) * 0.8)
	end

	-- Immovable disables jumping outright.
	if self._stats:HasBehaviour(player, "cannot_jump") then
		humanoid.JumpPower = 0
	end
end

-- ============================================================================
-- Initial state
-- ============================================================================

--[[
	The one big payload a client receives on join. Everything after this is deltas.
	Sent as a single message so the client can build its entire UI in one pass
	instead of flickering through partial states.
]]
function PlayerService:_sendInitialState(player: Player)
	local profile = self._data:GetProfile(player)
	if not profile then
		return
	end

	local levelInfo = self._progression:GetLevelInfo(player)
	local nextRegion = self._progression:GetNextRegion(player)
	local nextMain = Quests.GetNextMainQuest(profile.completedQuests)

	Net.FireClient(player, "ProfileSync", {
		profile = ProfileSchema.ToClientView(profile),
		stats = self._stats:GetStats(player),
		statSources = self._stats:GetSources(player),
		behaviours = self._stats:GetBehaviours(player),
		level = levelInfo,
		carry = self._carry:GetSnapshot(player),
		inventory = self._inventory:BuildInventoryView(player),
		nextRegion = nextRegion,
		nextQuest = nextMain and {
			id = nextMain.id,
			name = nextMain.name,
			summary = nextMain.summary,
		} or nil,
		-- A returning player gets a short "here is where you were" summary rather
		-- than a wall of popups.
		returningSummary = self:_buildReturningSummary(profile, levelInfo, nextRegion, nextMain),
		serverTime = workspace:GetServerTimeNow(),
	})

	self._abilities:_syncAbilityState(player)
	self._carry:ForceSync(player)
end

function PlayerService:_buildReturningSummary(profile: any, levelInfo: any, nextRegion: any, nextMain: any)
	if profile.sessionCount <= 1 then
		return nil
	end

	local lines = {}

	if nextMain then
		table.insert(lines, { label = "Current objective", value = nextMain.name })
	end
	if nextRegion then
		table.insert(lines, { label = "Next region", value = ("%s — %s"):format(nextRegion.name, nextRegion.requirement) })
	end
	if profile.skillPoints > 0 then
		table.insert(lines, { label = "Unspent skill points", value = tostring(profile.skillPoints) })
	end

	local fraction, done, total = Quests.GetMainProgress(profile.completedQuests)
	table.insert(lines, { label = "Story progress", value = ("%d of %d"):format(done, total) })

	return {
		level = levelInfo.level,
		lastRegion = profile.lastRegion,
		lines = lines,
	}
end

-- ============================================================================
-- Settings
-- ============================================================================

function PlayerService:UpdateSettings(player: Player, settings: { [string]: any }): boolean
	local profile = self._data:GetProfile(player)
	if not profile then
		return false
	end

	-- The remote's schema has already restricted keys and ranges; this only copies.
	for key, value in pairs(settings) do
		if profile.settings[key] ~= nil then
			profile.settings[key] = value
		end
	end

	self._data:MarkDirty(player)
	return true
end

function PlayerService:_recordClientMetric(player: Player, metric: any)
	self._analytics:Track(player, "client_performance", {
		averageFrameMs = math.floor(metric.averageFrameMs),
		quality = metric.quality,
		deviceKind = metric.deviceKind,
	})
end

-- ============================================================================
-- Leave
-- ============================================================================

function PlayerService:_onPlayerRemoving(player: Player)
	self.PlayerLeaving:Fire(player)
	self._ready[player.UserId] = nil
	Net.ClearPlayer(player)
	self._data:ReleaseProfile(player)
end

function PlayerService:IsReady(player: Player): boolean
	return self._ready[player.UserId] == true
end

--[[ Slow tick: keeps humanoid movement in sync with stats and carry weight. ]]
function PlayerService:Tick()
	for _, player in ipairs(Players:GetPlayers()) do
		if self._ready[player.UserId] then
			self:ApplyMovementStats(player)
		end
	end
end

return PlayerService
