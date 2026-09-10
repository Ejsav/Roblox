--!strict
--[[
	SkillService
	------------
	Skill tree purchases, respecs, and the grants that come with them.

	Every purchase is re-validated server-side against the same rules the client's
	tree UI uses, so a tampered client cannot buy a keystone out of order.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BTS")
local Signal = require(Shared.Core.Signal)
local Net = require(Shared.Net)
local SkillTree = require(Shared.Config.SkillTree)
local Abilities = require(Shared.Config.Abilities)
local Traversal = require(Shared.Config.Traversal)

local SkillService = {}
SkillService.Name = "SkillService"
SkillService.Dependencies = { "DataService", "StatsService", "ProgressionService", "EconomyService" }
SkillService.Priority = 27

local RESPEC_BASE_COST = 2500
local RESPEC_COST_PER_POINT = 180

function SkillService:Init()
	self.NodeRanked = Signal.new("SkillService.NodeRanked")
	self.Respecced = Signal.new("SkillService.Respecced")
end

function SkillService:Start()
	self._data = self.Registry:Get("DataService")
	self._stats = self.Registry:Get("StatsService")
	self._progression = self.Registry:Get("ProgressionService")
	self._economy = self.Registry:Get("EconomyService")
	self._analytics = self.Registry:Find("AnalyticsService")

	Net.OnServerEvent("RequestSpendSkillPoint", function(player, nodeId)
		self:RankUp(player, nodeId)
	end)
	Net.OnServerEvent("RequestRespecSkills", function(player)
		self:Respec(player)
	end)
end

--[[ Buys one rank of a node. Returns (success, reason). ]]
function SkillService:RankUp(player: Player, nodeId: string): (boolean, string?)
	local profile = self._data:GetProfile(player)
	if not profile then
		return false, "no_profile"
	end

	local node = SkillTree.NodeById[nodeId]
	if not node then
		return false, "unknown_node"
	end

	local ok, reason, detail = SkillTree.CanRankUp(nodeId, profile.skills, profile.skillPoints)
	if not ok then
		Net.FireClient(player, "Notification", {
			kind = "warning",
			title = "Cannot take that yet",
			body = self:_explainBlock(reason, detail),
		})
		return false, reason
	end

	local cost = detail :: number
	if not self._progression:SpendSkillPoints(player, cost) then
		return false, "insufficient_points"
	end

	local newRank = (profile.skills[nodeId] or 0) + 1
	profile.skills[nodeId] = newRank
	self._data:MarkDirty(player)
	self._stats:Invalidate(player)

	-- Grants only fire on the first rank; a multi-rank stat node grants nothing.
	if newRank == 1 then
		if node.grantsAbility then
			local ability = Abilities.ActiveById[node.grantsAbility]
			self._progression:GrantUnlock(player, "ability", node.grantsAbility,
				ability and ability.name or node.grantsAbility,
				{ description = ability and ability.description })
		end
		if node.grantsPassive then
			local passive = Abilities.PassiveById[node.grantsPassive]
			self._progression:GrantUnlock(player, "passive", node.grantsPassive,
				passive and passive.name or node.grantsPassive,
				{ description = passive and passive.description })
		end
		if node.grantsTraversal then
			local ability = Traversal.ById[node.grantsTraversal]
			self._progression:GrantUnlock(player, "traversal", node.grantsTraversal,
				ability and ability.name or node.grantsTraversal,
				{ tutorial = ability and ability.tutorial })
		end
	end

	self.NodeRanked:Fire(player, nodeId, newRank)

	Net.FireClient(player, "ProfileDelta", {
		skills = { [nodeId] = newRank },
		skillPoints = profile.skillPoints,
		specialisation = self:GetSpecialisation(player),
		behaviours = self._stats:GetBehaviours(player),
		stats = self._stats:GetStats(player),
	})

	if self._analytics then
		self._analytics:Track(player, "skill_ranked", { nodeId = nodeId, rank = newRank, branch = node.branch })
	end

	return true, nil
end

function SkillService:_explainBlock(reason: string?, detail: any): string
	if reason == "missing_prerequisite" and type(detail) == "table" then
		local prerequisite = SkillTree.NodeById[detail.id]
		return ("Requires %s at rank %d."):format(prerequisite and prerequisite.name or detail.id, detail.rank)
	elseif reason == "mutually_exclusive" then
		local other = SkillTree.NodeById[detail]
		return ("You have already taken %s."):format(other and other.name or tostring(detail))
	elseif reason == "insufficient_points" then
		return ("Costs %d skill points."):format(tonumber(detail) or 0)
	elseif reason == "max_rank" then
		return "Already at maximum rank."
	end
	return "Not available."
end

--[[ Refunds every point for a Watts fee that scales with how much is invested. ]]
function SkillService:Respec(player: Player): (boolean, string?)
	local profile = self._data:GetProfile(player)
	if not profile then
		return false, "no_profile"
	end

	local spent = SkillTree.GetSpentPoints(profile.skills)
	if spent == 0 then
		return false, "nothing_to_respec"
	end

	local cost = RESPEC_BASE_COST + spent * RESPEC_COST_PER_POINT
	if not self._economy:Spend(player, "watts", cost, "respec") then
		Net.FireClient(player, "Notification", {
			kind = "warning",
			title = "Respec costs " .. tostring(cost) .. " Watts",
			body = "You cannot afford it yet.",
		})
		return false, "insufficient_funds"
	end

	local refunded = self._progression:RefundAllSkillPoints(player)

	-- Abilities and passives granted by skills are revoked; those granted by
	-- upgrades or quests are not, so ownership is rebuilt from the other sources.
	self:_rebuildGrants(player, profile)

	self.Respecced:Fire(player, refunded)

	Net.FireClient(player, "ProfileDelta", {
		skills = {},
		skillPoints = profile.skillPoints,
		fullSkillReset = true,
	})
	Net.FireClient(player, "Notification", {
		kind = "good",
		title = "Respec complete",
		body = ("%d points refunded."):format(refunded),
	})

	if self._analytics then
		self._analytics:Track(player, "respec", { points = refunded, cost = cost })
	end

	return true, nil
end

--[[
	Rebuilds ability, passive and traversal ownership from every non-skill source.
	Called after a respec so a skill-granted ability is correctly removed while an
	upgrade-granted or quest-granted one survives.
]]
function SkillService:_rebuildGrants(player: Player, profile: any)
	local Upgrades = require(Shared.Config.Upgrades)
	local Quests = require(Shared.Config.Quests)

	local abilities = {}
	local passives = {}
	local traversal = Traversal.GetDefaults()

	-- Upgrade milestones.
	for upgradeId, level in pairs(profile.upgrades) do
		for _, milestone in ipairs(Upgrades.GetEarnedMilestones(upgradeId, level)) do
			if milestone.grantsAbility then
				abilities[milestone.grantsAbility] = true
			end
			if milestone.unlocksTraversal then
				traversal[milestone.unlocksTraversal] = true
			end
		end
	end

	-- Quest rewards.
	for questId in pairs(profile.completedQuests) do
		local quest = Quests.ById[questId]
		if quest then
			if quest.rewards.unlocksAbility then
				abilities[quest.rewards.unlocksAbility] = true
			end
			if quest.rewards.unlocksTraversal then
				traversal[quest.rewards.unlocksTraversal] = true
			end
		end
	end

	-- Prestige grants survive everything.
	if profile.prestige > 0 then
		traversal.prestige_phase = true
	end

	profile.abilitiesOwned = abilities
	profile.passivesOwned = passives
	profile.traversal = traversal

	-- Drop any loadout entry the player no longer owns.
	local cleaned = {}
	for _, abilityId in ipairs(profile.loadout) do
		if abilities[abilityId] then
			table.insert(cleaned, abilityId)
		end
	end
	profile.loadout = cleaned

	self._data:MarkDirty(player)
	self._stats:Invalidate(player)
end

function SkillService:GetSpecialisation(player: Player)
	local profile = self._data:GetProfile(player)
	if not profile then
		return nil
	end
	local branchId, spent, isHybrid = SkillTree.GetSpecialisation(profile.skills)
	if not branchId then
		return nil
	end
	local branch = SkillTree.BranchById[branchId]
	return {
		branchId = branchId,
		name = branch.name,
		tagline = branch.tagline,
		colour = branch.color,
		spent = spent,
		isHybrid = isHybrid,
	}
end

--[[ The full tree view: every node with its rank, availability and block reason. ]]
function SkillService:BuildTreeView(player: Player)
	local profile = self._data:GetProfile(player)
	if not profile then
		return nil
	end

	local nodes = {}
	for _, node in ipairs(SkillTree.Nodes) do
		local rank = profile.skills[node.id] or 0
		local canRank, reason, detail = SkillTree.CanRankUp(node.id, profile.skills, profile.skillPoints)

		table.insert(nodes, {
			id = node.id,
			branch = node.branch,
			tier = node.tier,
			position = node.position,
			name = node.name,
			kind = node.kind,
			description = node.description,
			downside = node.downside,
			rank = rank,
			maxRank = node.maxRank,
			cost = SkillTree.GetRankCost(node.id, rank),
			canRank = canRank,
			blockReason = reason,
			blockText = canRank and nil or self:_explainBlock(reason, detail),
			requires = node.requires,
			exclusiveWith = node.exclusiveWith,
		})
	end

	return {
		branches = SkillTree.Branches,
		nodes = nodes,
		skillPoints = profile.skillPoints,
		spent = SkillTree.GetSpentPoints(profile.skills),
		specialisation = self:GetSpecialisation(player),
		respecCost = RESPEC_BASE_COST + SkillTree.GetSpentPoints(profile.skills) * RESPEC_COST_PER_POINT,
	}
end

return SkillService
