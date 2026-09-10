--!strict
--[[
	PrestigeService
	---------------
	The reset that is not a reset.

	Two things make this service careful rather than simple. First, it destroys a
	hundred hours of progression, so it forces a save before touching anything and
	refuses to proceed if that save fails — a prestige lost to a datastore hiccup is
	unrecoverable. Second, what survives is defined by an explicit allow-list rather
	than a deny-list, because a field added later should default to being reset, not
	to being silently kept forever.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BTS")
local Signal = require(Shared.Core.Signal)
local TableUtil = require(Shared.Core.TableUtil)
local Net = require(Shared.Net)
local Balance = require(Shared.Config.Balance)
local Prestige = require(Shared.Config.Prestige)
local Equipment = require(Shared.Config.Equipment)
local Traversal = require(Shared.Config.Traversal)
local ProfileSchema = require(Shared.Data.ProfileSchema)

local PrestigeService = {}
PrestigeService.Name = "PrestigeService"
PrestigeService.Dependencies = { "DataService", "StatsService", "ProgressionService", "EconomyService", "InventoryService" }
PrestigeService.Priority = 52

function PrestigeService:Init()
	self.Prestiged = Signal.new("PrestigeService.Prestiged")
	self.PrestigeSkillPurchased = Signal.new("PrestigeService.PrestigeSkillPurchased")
end

function PrestigeService:Start()
	self._data = self.Registry:Get("DataService")
	self._stats = self.Registry:Get("StatsService")
	self._progression = self.Registry:Get("ProgressionService")
	self._economy = self.Registry:Get("EconomyService")
	self._inventory = self.Registry:Get("InventoryService")
	self._analytics = self.Registry:Find("AnalyticsService")

	Net.OnServerEvent("RequestPrestige", function(player, confirmed)
		if confirmed == true then
			self:Prestige(player)
		end
	end)
end

--[[ Eligibility, plus a description of what is missing. ]]
function PrestigeService:GetStatus(player: Player)
	local profile = self._data:GetProfile(player)
	if not profile then
		return nil
	end

	local eligible, reason, requirement = Prestige.CanPrestige(profile, Balance)
	local nextRank = Prestige.RankByNumber[profile.prestige + 1]

	local requirementText
	if reason == "level" then
		requirementText = ("Reach level %d (currently %d)"):format(requirement, profile.level)
	elseif reason == "quest" then
		requirementText = "Complete the Storm Core questline"
	elseif reason == "max_prestige" then
		requirementText = "You have reached the final rank"
	end

	return {
		currentRank = profile.prestige,
		maxRank = Balance.Progression.MAX_PRESTIGE,
		eligible = eligible,
		blockedReason = reason,
		requirement = requirementText,
		nextRank = nextRank and {
			rank = nextRank.rank,
			name = nextRank.name,
			description = nextRank.description,
			grants = nextRank.grants,
		} or nil,
		sigils = profile.sigils,
		preview = self:_buildPreview(profile),
	}
end

--[[ Exactly what a prestige will keep and what it will take. ]]
function PrestigeService:_buildPreview(profile: any)
	local keptLegendaries = 0
	for _, item in ipairs(profile.inventory) do
		local rarity = item.r
		if rarity == "legendary" or rarity == "mythic" or rarity == "exotic" then
			keptLegendaries += 1
		end
	end

	local discoveryCount = 0
	for _ in pairs(profile.discoveries) do
		discoveryCount += 1
	end

	return {
		keeps = {
			{ label = "Discoveries", value = discoveryCount },
			{ label = "Storm types found", value = (function()
				local count = 0
				for _ in pairs(profile.stormsDiscovered) do
					count += 1
				end
				return count
			end)() },
			{ label = "Legendary equipment", value = keptLegendaries },
			{ label = "Masteries", value = (function()
				local count = 0
				for _ in pairs(profile.masteries) do
					count += 1
				end
				return count
			end)() },
			{ label = "Records and achievements", value = "all" },
			{ label = "Fast travel network", value = "all" },
		},
		resets = {
			{ label = "Level", value = profile.level },
			{ label = "Watts", value = profile.watts },
			{ label = "Upgrades", value = (function()
				local count = 0
				for _ in pairs(profile.upgrades) do
					count += 1
				end
				return count
			end)() },
			{ label = "Skill points", value = profile.skillPointsSpent + profile.skillPoints },
			{ label = "Non-legendary equipment", value = #profile.inventory - keptLegendaries },
		},
	}
end

-- ============================================================================
-- The reset
-- ============================================================================

function PrestigeService:Prestige(player: Player): (boolean, string?)
	local profile = self._data:GetProfile(player)
	if not profile then
		return false, "no_profile"
	end

	local eligible, reason = Prestige.CanPrestige(profile, Balance)
	if not eligible then
		Net.FireClient(player, "Notification", {
			kind = "warning",
			title = "Not yet",
			body = self:GetStatus(player).requirement or "Requirements not met.",
		})
		return false, reason
	end

	-- Commit the pre-prestige state first. If this write fails the prestige does not
	-- happen, because a failed save after the reset would be unrecoverable.
	if not self._data:SaveProfile(player) then
		Net.FireClient(player, "Notification", {
			kind = "bad",
			title = "Could not save",
			body = "Prestige was cancelled to protect your progress. Try again shortly.",
		})
		return false, "save_failed"
	end

	local newRank = profile.prestige + 1
	local rankDefinition = Prestige.RankByNumber[newRank]

	-- Build the new profile from a fresh default, then copy across the allow-list.
	local preserved = {}
	for _, key in ipairs(Prestige.PRESERVED_KEYS) do
		preserved[key] = TableUtil.DeepCopy(profile[key])
	end

	-- Legendary-and-better equipment survives; everything else does not.
	local keptInventory = {}
	local keptEquipped = {}
	for _, item in ipairs(profile.inventory) do
		if item.r == "legendary" or item.r == "mythic" or item.r == "exotic" then
			table.insert(keptInventory, TableUtil.DeepCopy(item))
		end
	end
	-- Re-equip whatever survived, so a prestiged player is not naked.
	local keptUids = {}
	for _, item in ipairs(keptInventory) do
		keptUids[item.u] = item
	end
	for slotId, uid in pairs(profile.equipped) do
		if keptUids[uid] then
			keptEquipped[slotId] = uid
		end
	end

	local fresh = ProfileSchema.CreateDefault()
	for key, value in pairs(preserved) do
		fresh[key] = value
	end

	fresh.prestige = newRank
	fresh.prestigeCount = (profile.prestigeCount or 0) + 1
	fresh.inventory = keptInventory
	fresh.equipped = keptEquipped
	fresh.nextItemId = profile.nextItemId
	fresh.lastSeenAt = os.time()

	-- Traversal earned through prestige persists; the rest is re-earned.
	fresh.traversal = Traversal.GetDefaults()
	for rank = 1, newRank do
		local definition = Prestige.RankByNumber[rank]
		if definition and definition.grants.traversal then
			fresh.traversal[definition.grants.traversal] = true
		end
	end

	-- Main-chain quests stay completed so the player is not marched through the
	-- story again, but their region gates are re-evaluated against the new level.
	fresh.completedQuests = preserved.completedQuests

	-- Replace the live profile in place, so every service holding a reference sees
	-- the new state without needing to re-resolve it.
	for key in pairs(profile) do
		profile[key] = nil
	end
	for key, value in pairs(fresh) do
		profile[key] = value
	end

	self._data:MarkDirty(player)

	-- Rank rewards.
	local sigils = Prestige.GetSigilAward(newRank, Balance)
	self._economy:Award(player, "sigils", sigils, "prestige")

	if rankDefinition and rankDefinition.grants.item then
		self._inventory:GrantUnique(player, rankDefinition.grants.item, "prestige")
	end

	self._stats:Invalidate(player)
	self._data:SaveProfile(player)

	self.Prestiged:Fire(player, newRank)

	-- Prestige is one of the game's largest presentation moments, so it is
	-- announced to the whole server as well as to the player.
	Net.FireClient(player, "UnlockGranted", {
		kind = "prestige",
		id = "prestige_" .. tostring(newRank),
		name = ("PRESTIGE %d — %s"):format(newRank, rankDefinition and rankDefinition.name or ""),
		detail = {
			description = rankDefinition and rankDefinition.description or "",
			sigils = sigils,
			grants = rankDefinition and rankDefinition.grants or nil,
		},
	})

	Net.FireAllClients("ServerAnnouncement", {
		kind = "prestige",
		playerName = player.DisplayName,
		rank = newRank,
		rankName = rankDefinition and rankDefinition.name or "",
	})

	if self._analytics then
		self._analytics:TrackFunnel(player, "prestiged")
		self._analytics:Track(player, "prestige", { rank = newRank })
	end

	return true, nil
end

-- ============================================================================
-- Prestige skills
-- ============================================================================

function PrestigeService:PurchaseSkill(player: Player, skillId: string): (boolean, string?)
	local profile = self._data:GetProfile(player)
	if not profile then
		return false, "no_profile"
	end

	local ok, reason, detail = Prestige.CanPurchaseSkill(skillId, profile)
	if not ok then
		Net.FireClient(player, "Notification", {
			kind = "warning",
			title = "Cannot take that",
			body = self:_explainBlock(reason, detail),
		})
		return false, reason
	end

	local skill = Prestige.SkillById[skillId]
	if not self._economy:Spend(player, "sigils", skill.cost, "prestige_skill:" .. skillId) then
		return false, "insufficient_sigils"
	end

	profile.prestigeSkills[skillId] = true
	self._data:MarkDirty(player)
	self._stats:Invalidate(player)

	self.PrestigeSkillPurchased:Fire(player, skillId)

	Net.FireClient(player, "UnlockGranted", {
		kind = "prestige_skill",
		id = skillId,
		name = skill.name,
		detail = { description = skill.description },
	})

	return true, nil
end

function PrestigeService:_explainBlock(reason: string?, detail: any): string
	if reason == "insufficient_sigils" then
		return ("Costs %d Sigils."):format(tonumber(detail) or 0)
	elseif reason == "missing_prerequisite" then
		local prerequisite = Prestige.SkillById[detail]
		return ("Requires %s."):format(prerequisite and prerequisite.name or tostring(detail))
	elseif reason == "missing_any_prerequisite" then
		return "Requires one of the tier below."
	elseif reason == "prestige_rank" then
		return ("Requires Prestige %d."):format(tonumber(detail) or 0)
	elseif reason == "already_owned" then
		return "Already owned."
	end
	return "Not available."
end

--[[ Behaviour flags this player has from prestige, merged into their stat block. ]]
function PrestigeService:GetBehaviours(player: Player): { [string]: boolean }
	local profile = self._data:GetProfile(player)
	if not profile then
		return {}
	end
	return Prestige.CollectBehaviours(profile)
end

--[[ World state flags for the player's rank, which alter storm generation. ]]
function PrestigeService:GetWorldStates(player: Player): { [string]: boolean }
	local profile = self._data:GetProfile(player)
	if not profile then
		return {}
	end
	return Prestige.CollectWorldStates(profile.prestige)
end

--[[ The full prestige panel view. ]]
function PrestigeService:BuildView(player: Player)
	local profile = self._data:GetProfile(player)
	if not profile then
		return nil
	end

	local skills = {}
	for _, skill in ipairs(Prestige.Skills) do
		local owned = profile.prestigeSkills[skill.id] == true
		local canPurchase, reason, detail = Prestige.CanPurchaseSkill(skill.id, profile)
		table.insert(skills, {
			id = skill.id,
			name = skill.name,
			tier = skill.tier,
			cost = skill.cost,
			description = skill.description,
			owned = owned,
			canPurchase = canPurchase,
			blockText = canPurchase and nil or self:_explainBlock(reason, detail),
			requires = skill.requires,
			requiresAny = skill.requiresAny,
		})
	end

	return {
		status = self:GetStatus(player),
		skills = skills,
		ranks = Prestige.Ranks,
		sigils = profile.sigils,
	}
end

return PrestigeService
