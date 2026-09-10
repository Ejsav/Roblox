--!strict
--[[
	Prestige
	--------
	What happens after the ending.

	The design brief for prestige here: it must never read as "reset everything and
	gain +10%". So a prestige does three things a percentage cannot:

	  1. It keeps everything that represents knowledge — collections, discoveries,
	     records, masteries, legendary equipment — and resets only the numbers you
	     will earn again quickly.
	  2. It opens a separate skill tree whose nodes are capabilities the base game
	     does not contain.
	  3. It unlocks a region that was not merely locked before but genuinely absent.

	Ranks are cheap to describe and expensive to earn, and each one changes the
	world state rather than a multiplier.
]]

local TableUtil = require(script.Parent.Parent.Core.TableUtil)

local Prestige = {}

--[[ What each prestige rank grants. Ranks are cumulative. ]]
Prestige.Ranks = {
	{
		rank = 1,
		name = "Threshold",
		description = "The storms were a search pattern. Now you know what they were looking for.",
		grants = {
			region = "null_reach",
			traversal = "prestige_phase",
			item = "unique_borrowed_time",
			sigils = 3,
			worldState = "inversion_visible",
		},
		unlocksSkillTiers = 1,
	},
	{
		rank = 2,
		name = "Echo",
		description = "Storms in every region begin replaying strikes you have already taken.",
		grants = { sigils = 3, worldState = "echo_storms" },
		unlocksSkillTiers = 1,
	},
	{
		rank = 3,
		name = "Inversion",
		description = "Null Pockets appear across the whole world, not just the Scour.",
		grants = { sigils = 3, worldState = "null_everywhere" },
		unlocksSkillTiers = 1,
	},
	{
		rank = 4,
		name = "Saturation",
		description = "Every region's danger rating rises by one, and so does everything it pays.",
		grants = { sigils = 4, worldState = "danger_plus_one" },
		unlocksSkillTiers = 1,
	},
	{
		rank = 5,
		name = "The Second Eye",
		description = "A second Eye opens somewhere in the world. It is not in the Core.",
		grants = { sigils = 4, worldState = "second_eye" },
		unlocksSkillTiers = 1,
	},
	{
		rank = 6,
		name = "Convergence",
		description = "World events run twice as often and can occur simultaneously.",
		grants = { sigils = 4, worldState = "event_convergence" },
		unlocksSkillTiers = 1,
	},
	{
		rank = 7,
		name = "The Long Wall",
		description = "The Core's outer wall extends across the Sattermarsh. The map has changed.",
		grants = { sigils = 5, worldState = "wall_extended" },
		unlocksSkillTiers = 1,
	},
	{
		rank = 8,
		name = "Recursion",
		description = "Storms begin anticipating your route rather than reacting to it.",
		grants = { sigils = 5, worldState = "predictive_storms" },
		unlocksSkillTiers = 1,
	},
	{
		rank = 9,
		name = "Terminus",
		description = "The door at the end of Null Reach opens.",
		grants = { sigils = 6, worldState = "terminus_open" },
		unlocksSkillTiers = 1,
	},
	{
		rank = 10,
		name = "Borrowed",
		description = "You stop being the one doing the borrowing.",
		grants = { sigils = 8, worldState = "final" },
		unlocksSkillTiers = 1,
	},
	{
		rank = 11,
		name = "Beyond",
		description = "There was never an ending. There was only how far you were willing to go.",
		grants = { sigils = 10, worldState = "beyond" },
		unlocksSkillTiers = 1,
	},
	{
		rank = 12,
		name = "Storm",
		description = "",
		grants = { sigils = 12, worldState = "storm" },
		unlocksSkillTiers = 1,
	},
}

--[[
	The prestige skill tree. Purchased with Sigils, which only prestige produces.
	Every node is a capability rather than a stat, because a player at this point
	has all the stats they need and none of the new verbs.
]]
Prestige.Skills = {
	{
		id = "p_second_cell",
		name = "Second Cell",
		tier = 1,
		cost = 4,
		description = "A second containment cell. Bank one and keep carrying the other.",
		behaviour = "dual_containment",
		requires = {},
	},
	{
		id = "p_storm_sense",
		name = "Storm Sense",
		tier = 1,
		cost = 3,
		description = "Every storm in the world is visible on your map, permanently.",
		behaviour = "global_storm_vision",
		requires = {},
	},
	{
		id = "p_recall",
		name = "Recall",
		tier = 1,
		cost = 3,
		description = "Return to the last place you banked, once every two minutes.",
		behaviour = "recall",
		requires = {},
	},
	{
		id = "p_phase_extended",
		name = "Extended Phase",
		tier = 2,
		cost = 5,
		description = "Phase Step lasts three times as long and can be used mid-air.",
		behaviour = "extended_phase",
		requires = { "p_recall" },
	},
	{
		id = "p_chain_memory",
		name = "Chain Memory",
		tier = 2,
		cost = 6,
		description = "Your chain persists through death, banking and disconnection.",
		behaviour = "persistent_chain",
		requires = { "p_second_cell" },
	},
	{
		id = "p_anomaly_pull",
		name = "Anomaly Pull",
		tier = 2,
		cost = 5,
		description = "Anomalies open near you rather than at random.",
		behaviour = "anomaly_magnet",
		requires = { "p_storm_sense" },
	},
	{
		id = "p_inversion_mastery",
		name = "Inversion Mastery",
		tier = 3,
		cost = 8,
		description = "You choose the polarity of an Inversion storm instead of reading it.",
		behaviour = "polarity_control",
		requires = { "p_anomaly_pull" },
	},
	{
		id = "p_storm_authorship",
		name = "Storm Authorship",
		tier = 3,
		cost = 10,
		description = "Once per run, create a storm of any type you have discovered.",
		behaviour = "author_storm",
		requires = { "p_chain_memory" },
	},
	{
		id = "p_the_calm",
		name = "Carry the Calm",
		tier = 3,
		cost = 9,
		description = "A permanent Eye follows you: a moving twenty-stud zone where instability stops.",
		behaviour = "personal_eye",
		-- Reachable from either tier-2 branch, so a build is not forced down one path.
		requires = {},
		requiresAny = { "p_phase_extended", "p_chain_memory" },
	},
	{
		id = "p_terminus_key",
		name = "Terminus Key",
		tier = 4,
		cost = 14,
		description = "The door at the end of Null Reach recognises you.",
		behaviour = "terminus_access",
		requires = {},
		requiresAny = { "p_inversion_mastery", "p_storm_authorship", "p_the_calm" },
		requiresPrestige = 9,
	},
}

Prestige.SkillById = {}
for _, skill in ipairs(Prestige.Skills) do
	Prestige.SkillById[skill.id] = skill
end

Prestige.RankByNumber = {}
for _, rank in ipairs(Prestige.Ranks) do
	Prestige.RankByNumber[rank.rank] = rank
end

--[[ Everything a player keeps through a prestige, by profile key. ]]
Prestige.PRESERVED_KEYS = {
	"version",
	"createdAt",
	"playTimeSeconds",
	"sessionCount",
	"prestige",
	"prestigeCount",
	"sigils",
	"prestigeSkills",
	"prestigeUnlocks",
	"completedQuests",
	"discoveries",
	"stormsDiscovered",
	"loreFound",
	"achievements",
	"titlesOwned",
	"equippedTitle",
	"cosmeticsOwned",
	"equippedCosmetics",
	"masteries",
	"records",
	"settings",
	"onboarding",
	"purchases",
	"flags",
	"regionsVisited",
	"fastTravelUnlocked",
	"regionStats",
	"pity",
}

--[[
	Whether a player may prestige, and what is missing if not.
	Returns (eligible, reasonKey, requirement).
]]
function Prestige.CanPrestige(profile: any, Balance: any): (boolean, string?, any)
	local progression = Balance.Progression

	if profile.prestige >= progression.MAX_PRESTIGE then
		return false, "max_prestige", progression.MAX_PRESTIGE
	end
	if profile.level < progression.PRESTIGE_LEVEL_REQUIREMENT then
		return false, "level", progression.PRESTIGE_LEVEL_REQUIREMENT
	end
	if not profile.completedQuests[progression.PRESTIGE_QUEST_REQUIREMENT] then
		return false, "quest", progression.PRESTIGE_QUEST_REQUIREMENT
	end

	return true, nil, nil
end

--[[ Sigils awarded for a prestige at the given rank. ]]
function Prestige.GetSigilAward(newRank: number, Balance: any): number
	local definition = Prestige.RankByNumber[newRank]
	if definition and definition.grants.sigils then
		return definition.grants.sigils
	end
	return Balance.Progression.PRESTIGE_SIGILS_PER_RANK
end

--[[
	Whether a prestige skill can be purchased.
	Returns (ok, reasonKey, detail).
]]
function Prestige.CanPurchaseSkill(skillId: string, profile: any): (boolean, string?, any)
	local skill = Prestige.SkillById[skillId]
	if not skill then
		return false, "unknown_skill", nil
	end
	if profile.prestigeSkills[skillId] then
		return false, "already_owned", nil
	end
	if (profile.sigils or 0) < skill.cost then
		return false, "insufficient_sigils", skill.cost
	end
	if skill.requiresPrestige and profile.prestige < skill.requiresPrestige then
		return false, "prestige_rank", skill.requiresPrestige
	end

	for _, requiredId in ipairs(skill.requires) do
		if not profile.prestigeSkills[requiredId] then
			return false, "missing_prerequisite", requiredId
		end
	end

	if skill.requiresAny then
		local satisfied = false
		for _, requiredId in ipairs(skill.requiresAny) do
			if profile.prestigeSkills[requiredId] then
				satisfied = true
				break
			end
		end
		if not satisfied then
			return false, "missing_any_prerequisite", skill.requiresAny
		end
	end

	return true, nil, nil
end

--[[ Behaviour flags granted by a player's owned prestige skills. ]]
function Prestige.CollectBehaviours(profile: any): { [string]: boolean }
	local behaviours = {}
	for skillId, owned in pairs(profile.prestigeSkills or {}) do
		if owned then
			local skill = Prestige.SkillById[skillId]
			if skill then
				behaviours[skill.behaviour] = true
			end
		end
	end
	return behaviours
end

--[[ World state flags from every rank the player has reached. ]]
function Prestige.CollectWorldStates(prestigeRank: number): { [string]: boolean }
	local states = {}
	for _, definition in ipairs(Prestige.Ranks) do
		if definition.rank <= prestigeRank and definition.grants.worldState then
			states[definition.grants.worldState] = true
		end
	end
	return states
end

return TableUtil.DeepFreeze(Prestige)
