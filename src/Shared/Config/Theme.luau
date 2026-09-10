--!strict
--[[
	Theme
	-----
	The design system. Every colour, size, radius, duration and font in the game
	resolves from here, so the interface reads as one product rather than twenty
	screens that were each styled on the day they were written.

	Visual direction: dark digital. Near-black grounds, a single electric accent,
	generous negative space, and colour used almost exclusively to mean something —
	rarity, danger, or state. Nothing is decorative by default.

	The scales below are deliberately short. A type scale with six sizes produces a
	consistent interface; one with twenty produces a mess, because there is always a
	plausible reason to reach for an in-between value.
]]

local TableUtil = require(script.Parent.Parent.Core.TableUtil)

local Theme = {}

-- ============================================================================
-- Colour
-- ============================================================================

local function rgb(r: number, g: number, b: number): Color3
	return Color3.fromRGB(r, g, b)
end

Theme.Color = {
	-- Grounds, darkest to lightest. `base` is the page; `raised` is a panel;
	-- `overlay` is a modal sitting above everything.
	void = rgb(6, 8, 12),
	base = rgb(11, 14, 20),
	raised = rgb(18, 22, 30),
	elevated = rgb(26, 31, 41),
	overlay = rgb(34, 40, 52),

	-- Lines and separators.
	border = rgb(38, 45, 58),
	borderStrong = rgb(58, 68, 86),
	borderAccent = rgb(88, 200, 255),

	-- Text, in descending emphasis. Four levels is enough for any interface.
	textPrimary = rgb(238, 244, 255),
	textSecondary = rgb(158, 172, 194),
	textTertiary = rgb(104, 118, 140),
	textDisabled = rgb(72, 82, 98),
	textInverse = rgb(11, 14, 20),

	-- The one accent. Used for focus, primary actions and the energy the game is
	-- entirely about.
	accent = rgb(88, 200, 255),
	accentDim = rgb(52, 132, 176),
	accentBright = rgb(150, 224, 255),
	accentGlow = rgb(123, 224, 255),

	-- Semantic state.
	success = rgb(64, 224, 168),
	warning = rgb(255, 186, 68),
	danger = rgb(255, 82, 106),
	info = rgb(122, 162, 255),

	-- Gameplay-specific.
	energy = rgb(123, 224, 255),
	instability = rgb(255, 138, 88),
	instabilityCritical = rgb(255, 72, 88),
	watts = rgb(255, 224, 122),
	cores = rgb(180, 150, 255),
	sigils = rgb(255, 88, 148),
	health = rgb(96, 224, 148),
	chain = rgb(255, 186, 68),

	-- Capture grades. These are read at speed under pressure, so they are maximally
	-- separated in hue rather than tastefully adjacent.
	gradeOvercharge = rgb(255, 240, 140),
	gradePerfect = rgb(88, 232, 255),
	gradeGood = rgb(120, 224, 168),
	gradeWeak = rgb(158, 172, 194),
	gradeMiss = rgb(255, 92, 108),
}

--[[ Rarity colours. Ordered so a player learns the ramp once and it never changes. ]]
Theme.Rarity = {
	common = { color = rgb(158, 172, 194), glow = 0, label = "Common" },
	uncommon = { color = rgb(108, 214, 142), glow = 0.1, label = "Uncommon" },
	rare = { color = rgb(88, 168, 255), glow = 0.25, label = "Rare" },
	epic = { color = rgb(176, 122, 255), glow = 0.4, label = "Epic" },
	legendary = { color = rgb(255, 168, 62), glow = 0.6, label = "Legendary" },
	mythic = { color = rgb(255, 88, 128), glow = 0.8, label = "Mythic" },
	exotic = { color = rgb(120, 255, 236), glow = 1.0, label = "Exotic" },
}

--[[ Danger rating colour, 1-10. Used by the map and region banners. ]]
function Theme.DangerColor(danger: number): Color3
	local t = math.clamp((danger - 1) / 9, 0, 1)
	if t < 0.5 then
		return Theme.Color.success:Lerp(Theme.Color.warning, t * 2)
	end
	return Theme.Color.warning:Lerp(Theme.Color.danger, (t - 0.5) * 2)
end

--[[ Colourblind-safe substitutions, applied by the client when enabled. ]]
Theme.ColorblindPalettes = {
	protanopia = {
		danger = rgb(255, 176, 0),
		success = rgb(0, 178, 238),
		gradePerfect = rgb(255, 255, 255),
		gradeGood = rgb(0, 178, 238),
	},
	deuteranopia = {
		danger = rgb(255, 158, 0),
		success = rgb(64, 180, 255),
		gradePerfect = rgb(255, 255, 255),
		gradeGood = rgb(64, 180, 255),
	},
	tritanopia = {
		danger = rgb(255, 82, 106),
		success = rgb(126, 226, 96),
		gradePerfect = rgb(255, 132, 168),
		gradeGood = rgb(126, 226, 96),
	},
}

-- ============================================================================
-- Type
-- ============================================================================

Theme.Font = {
	display = Enum.Font.GothamBold,
	heading = Enum.Font.GothamBold,
	body = Enum.Font.Gotham,
	medium = Enum.Font.GothamMedium,
	mono = Enum.Font.Code,
}

--[[
	Type scale in pixels at a 1.0 HUD scale. Six steps, each a clear jump from the
	last, so hierarchy is unambiguous at a glance.
]]
Theme.Text = {
	display = 42,
	title = 28,
	heading = 20,
	body = 15,
	label = 13,
	caption = 11,
}

-- ============================================================================
-- Space
-- ============================================================================

--[[ A 4px base grid. Every gap and pad in the game is one of these. ]]
Theme.Space = {
	xxs = 2,
	xs = 4,
	sm = 8,
	md = 12,
	lg = 16,
	xl = 24,
	xxl = 32,
	xxxl = 48,
}

Theme.Radius = {
	none = 0,
	sm = 4,
	md = 8,
	lg = 12,
	xl = 18,
	pill = 999,
}

Theme.Stroke = {
	hairline = 1,
	thin = 1.5,
	thick = 2,
	heavy = 3,
}

-- ============================================================================
-- Motion
-- ============================================================================

--[[
	Durations in seconds. The rule: anything the player initiated resolves in under
	200ms, because an interface that makes you wait for your own click feels cheap
	no matter how it looks. Only celebratory moments are allowed to be slow.
]]
Theme.Duration = {
	instant = 0.06,
	fast = 0.12,
	normal = 0.2,
	slow = 0.35,
	deliberate = 0.6,
	celebration = 1.2,
}

Theme.Easing = {
	standard = { style = Enum.EasingStyle.Quart, direction = Enum.EasingDirection.Out },
	enter = { style = Enum.EasingStyle.Back, direction = Enum.EasingDirection.Out },
	exit = { style = Enum.EasingStyle.Quad, direction = Enum.EasingDirection.In },
	emphasis = { style = Enum.EasingStyle.Elastic, direction = Enum.EasingDirection.Out },
	linear = { style = Enum.EasingStyle.Linear, direction = Enum.EasingDirection.InOut },
}

--[[ Builds a TweenInfo from a named duration and easing. ]]
function Theme.Tween(durationKey: string, easingKey: string?, delayTime: number?): TweenInfo
	local easing = Theme.Easing[easingKey or "standard"]
	return TweenInfo.new(
		Theme.Duration[durationKey] or Theme.Duration.normal,
		easing.style,
		easing.direction,
		0,
		false,
		delayTime or 0
	)
end

-- ============================================================================
-- Elevation
-- ============================================================================

--[[
	Depth is expressed as background lightness plus border strength rather than drop
	shadows, which read poorly at Roblox's UI resolution and cost fill rate.
]]
Theme.Elevation = {
	[0] = { background = Theme.Color.base, border = Theme.Color.border },
	[1] = { background = Theme.Color.raised, border = Theme.Color.border },
	[2] = { background = Theme.Color.elevated, border = Theme.Color.borderStrong },
	[3] = { background = Theme.Color.overlay, border = Theme.Color.borderStrong },
}

-- ============================================================================
-- Layout
-- ============================================================================

Theme.Layout = {
	-- Below this width the interface switches to its compact arrangement.
	compactBreakpoint = 700,
	-- Touch targets never go below this, per platform accessibility guidance.
	minTouchTarget = 44,
	-- The HUD keeps this clear of every screen edge, inside the safe area.
	screenPadding = 16,
	-- Maximum content width for reading, so text does not stretch on ultrawide.
	maxContentWidth = 1100,
	-- Standard panel and modal sizes.
	panelWidth = 380,
	modalWidth = 620,
	sidebarWidth = 220,
}

Theme.ZIndex = {
	world = 0,
	hud = 10,
	hudOverlay = 20,
	panel = 100,
	modal = 200,
	notification = 300,
	tooltip = 400,
	debug = 500,
}

-- ============================================================================
-- Icons
--
-- Icon ids are declared centrally so a missing asset is a single edit, and so the
-- codebase never sprawls with raw rbxassetid strings.
-- ============================================================================

Theme.Icon = {
	-- Placeholder ids resolve to a neutral square rather than a broken image, which
	-- keeps the interface presentable before art lands.
	fallback = "rbxasset://textures/ui/GuiImagePlaceholder.png",
}

--[[ Resolves an icon key to an asset id, falling back rather than breaking. ]]
function Theme.GetIcon(key: string?): string
	if not key then
		return Theme.Icon.fallback
	end
	return Theme.Icon[key] or Theme.Icon.fallback
end

-- ============================================================================
-- Helpers
-- ============================================================================

--[[ Rarity presentation for an id, falling back to common. ]]
function Theme.GetRarity(rarityId: string?)
	return Theme.Rarity[rarityId or "common"] or Theme.Rarity.common
end

--[[ Capture grade colour. ]]
function Theme.GradeColor(grade: string?): Color3
	if grade == "Overcharge" then
		return Theme.Color.gradeOvercharge
	elseif grade == "Perfect" then
		return Theme.Color.gradePerfect
	elseif grade == "Good" then
		return Theme.Color.gradeGood
	elseif grade == "Weak" then
		return Theme.Color.gradeWeak
	end
	return Theme.Color.gradeMiss
end

--[[
	Instability colour ramp: calm through warning to critical. Returned as a single
	function so every element showing instability agrees on where "bad" starts.
]]
function Theme.InstabilityColor(instability: number): Color3
	if instability < 0.62 then
		return Theme.Color.energy:Lerp(Theme.Color.instability, instability / 0.62)
	end
	return Theme.Color.instability:Lerp(
		Theme.Color.instabilityCritical,
		math.clamp((instability - 0.62) / 0.38, 0, 1)
	)
end

--[[ Currency colour by id. ]]
function Theme.CurrencyColor(currency: string): Color3
	if currency == "cores" then
		return Theme.Color.cores
	elseif currency == "sigils" then
		return Theme.Color.sigils
	end
	return Theme.Color.watts
end

--[[
	Formats a large number for display: 1234 -> "1.2k", 5400000 -> "5.4M".
	Used everywhere a currency or energy value appears, so the HUD never jitters
	between four and five digits mid-run.
]]
function Theme.FormatNumber(value: number, precise: boolean?): string
	local absolute = math.abs(value)
	if precise or absolute < 1000 then
		return tostring(math.floor(value + 0.5))
	elseif absolute < 1000000 then
		return ("%.1fk"):format(value / 1000)
	elseif absolute < 1000000000 then
		return ("%.2fM"):format(value / 1000000)
	end
	return ("%.2fB"):format(value / 1000000000)
end

--[[ Formats seconds as a compact duration: "1:04", "2h 15m". ]]
function Theme.FormatDuration(seconds: number): string
	if seconds < 60 then
		return ("%ds"):format(math.floor(seconds))
	elseif seconds < 3600 then
		return ("%d:%02d"):format(math.floor(seconds / 60), math.floor(seconds % 60))
	end
	return ("%dh %dm"):format(math.floor(seconds / 3600), math.floor((seconds % 3600) / 60))
end

return TableUtil.DeepFreeze(Theme)
