--!strict
--[[
	Build
	-----
	Geometry primitives for the world generator.

	Everything the world is made of goes through these functions, which gives three
	properties for free:
	  * Consistent material and collision settings, so nothing is accidentally
	    unanchored or shadow-casting when it should not be.
	  * Automatic parenting into the right region folder, which is what makes
	    StreamingEnabled work sensibly across a 17,000-stud world.
	  * A single place to add instancing or LOD later without touching the callers.

	Parts are anchored and CastShadow-off by default. In a world this size, a few
	thousand shadow-casting parts is the difference between 60fps and 30 on mobile,
	and almost none of them meaningfully improve the image.
]]

local Build = {}

local DEFAULT_MATERIAL = Enum.Material.Concrete

--[[ Creates a part with the project's standard defaults. ]]
function Build.Part(config: {
	size: Vector3,
	cframe: CFrame?,
	position: Vector3?,
	color: Color3?,
	material: Enum.Material?,
	transparency: number?,
	parent: Instance?,
	name: string?,
	canCollide: boolean?,
	castShadow: boolean?,
	shape: Enum.PartType?,
	reflectance: number?,
}): BasePart
	local part = Instance.new("Part")
	part.Size = config.size
	part.Anchored = true
	part.CanCollide = config.canCollide ~= false
	part.CanTouch = false
	part.CanQuery = true
	part.CastShadow = config.castShadow == true
	part.Material = config.material or DEFAULT_MATERIAL
	part.Color = config.color or Color3.fromRGB(92, 96, 104)
	part.Transparency = config.transparency or 0
	part.Reflectance = config.reflectance or 0
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth

	if config.shape then
		part.Shape = config.shape
	end

	if config.cframe then
		part.CFrame = config.cframe
	elseif config.position then
		part.Position = config.position
	end

	part.Name = config.name or "Part"
	part.Parent = config.parent
	return part
end

--[[ A wedge, for roofs, ramps and rock faces. ]]
function Build.Wedge(config: {
	size: Vector3,
	cframe: CFrame,
	color: Color3?,
	material: Enum.Material?,
	parent: Instance?,
	name: string?,
	canCollide: boolean?,
}): BasePart
	local wedge = Instance.new("WedgePart")
	wedge.Size = config.size
	wedge.CFrame = config.cframe
	wedge.Anchored = true
	wedge.CanCollide = config.canCollide ~= false
	wedge.CanTouch = false
	wedge.CastShadow = false
	wedge.Material = config.material or DEFAULT_MATERIAL
	wedge.Color = config.color or Color3.fromRGB(92, 96, 104)
	wedge.Name = config.name or "Wedge"
	wedge.Parent = config.parent
	return wedge
end

--[[ Creates (or finds) a named folder under a parent. ]]
function Build.Folder(parent: Instance, name: string): Folder
	local existing = parent:FindFirstChild(name)
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = parent
	return folder
end

--[[ A model with a primary part, so it can be pivoted as a unit. ]]
function Build.Model(parent: Instance, name: string): Model
	local model = Instance.new("Model")
	model.Name = name
	model.Parent = parent
	return model
end

-- ============================================================================
-- Composite structures
-- ============================================================================

--[[
	A flat platform with an optional lip, used for rooftops, catwalks and stations.
	Returns the platform part so callers can build on top of it.
]]
function Build.Platform(config: {
	position: Vector3,
	size: Vector2,
	thickness: number?,
	color: Color3?,
	material: Enum.Material?,
	parent: Instance?,
	name: string?,
	railHeight: number?,
	railColor: Color3?,
}): BasePart
	local thickness = config.thickness or 2
	local platform = Build.Part({
		size = Vector3.new(config.size.X, thickness, config.size.Y),
		position = config.position,
		color = config.color,
		material = config.material or Enum.Material.Metal,
		parent = config.parent,
		name = config.name or "Platform",
	})

	if config.railHeight and config.railHeight > 0 then
		local railColor = config.railColor or Color3.fromRGB(60, 64, 72)
		local half = Vector3.new(config.size.X, 0, config.size.Y) / 2
		local offsets = {
			{ Vector3.new(0, 0, half.Z), Vector3.new(config.size.X, config.railHeight, 0.6) },
			{ Vector3.new(0, 0, -half.Z), Vector3.new(config.size.X, config.railHeight, 0.6) },
			{ Vector3.new(half.X, 0, 0), Vector3.new(0.6, config.railHeight, config.size.Y) },
			{ Vector3.new(-half.X, 0, 0), Vector3.new(0.6, config.railHeight, config.size.Y) },
		}
		for index, entry in ipairs(offsets) do
			Build.Part({
				size = entry[2],
				position = config.position + entry[1] + Vector3.new(0, thickness / 2 + config.railHeight / 2, 0),
				color = railColor,
				material = Enum.Material.Metal,
				parent = config.parent,
				name = "Rail" .. index,
				canCollide = true,
			})
		end
	end

	return platform
end

--[[
	A vertical tower of stacked segments, tapering toward the top.
	Used for pylons, masts, transmission towers and skyscrapers.
]]
function Build.Tower(config: {
	basePosition: Vector3,
	height: number,
	baseWidth: number,
	topWidth: number?,
	segments: number?,
	color: Color3?,
	material: Enum.Material?,
	parent: Instance?,
	name: string?,
	rng: any?,
	jitter: number?,
}): Model
	local model = Build.Model(config.parent or workspace, config.name or "Tower")
	local segments = config.segments or math.max(3, math.floor(config.height / 40))
	local topWidth = config.topWidth or config.baseWidth * 0.35
	local jitter = config.jitter or 0

	local segmentHeight = config.height / segments
	for index = 1, segments do
		local t = (index - 1) / math.max(1, segments - 1)
		local width = config.baseWidth + (topWidth - config.baseWidth) * t

		local offset = Vector3.zero
		if jitter > 0 and config.rng then
			offset = Vector3.new(
				config.rng:NextRange(-jitter, jitter),
				0,
				config.rng:NextRange(-jitter, jitter)
			)
		end

		local segment = Build.Part({
			size = Vector3.new(width, segmentHeight, width),
			position = config.basePosition
				+ Vector3.new(0, segmentHeight * (index - 0.5), 0)
				+ offset,
			color = config.color,
			material = config.material or Enum.Material.Metal,
			parent = model,
			name = "Segment" .. index,
		})
		if index == 1 then
			model.PrimaryPart = segment
		end
	end

	return model
end

--[[
	A building shell: floors, a roof, and optional interior floor slabs so the
	inside is traversable rather than solid.
]]
function Build.Building(config: {
	position: Vector3,
	footprint: Vector2,
	floors: number,
	floorHeight: number?,
	color: Color3?,
	material: Enum.Material?,
	parent: Instance?,
	name: string?,
	hollow: boolean?,
	wallThickness: number?,
	windowColor: Color3?,
}): Model
	local model = Build.Model(config.parent or workspace, config.name or "Building")
	local floorHeight = config.floorHeight or 14
	local totalHeight = config.floors * floorHeight
	local thickness = config.wallThickness or 1.5
	local color = config.color or Color3.fromRGB(58, 62, 74)

	if config.hollow then
		-- Four walls plus per-floor slabs. Interiors are what make a city worth
		-- entering rather than merely running across.
		local halfX = config.footprint.X / 2
		local halfZ = config.footprint.Y / 2

		local walls = {
			{ Vector3.new(0, totalHeight / 2, halfZ), Vector3.new(config.footprint.X, totalHeight, thickness) },
			{ Vector3.new(0, totalHeight / 2, -halfZ), Vector3.new(config.footprint.X, totalHeight, thickness) },
			{ Vector3.new(halfX, totalHeight / 2, 0), Vector3.new(thickness, totalHeight, config.footprint.Y) },
			{ Vector3.new(-halfX, totalHeight / 2, 0), Vector3.new(thickness, totalHeight, config.footprint.Y) },
		}
		for index, wall in ipairs(walls) do
			Build.Part({
				size = wall[2],
				position = config.position + wall[1],
				color = color,
				material = config.material or Enum.Material.Concrete,
				parent = model,
				name = "Wall" .. index,
			})
		end

		for floor = 0, config.floors do
			local slab = Build.Part({
				size = Vector3.new(config.footprint.X, 1, config.footprint.Y),
				position = config.position + Vector3.new(0, floor * floorHeight, 0),
				color = color:Lerp(Color3.new(0, 0, 0), 0.25),
				material = Enum.Material.Concrete,
				parent = model,
				name = "Floor" .. floor,
			})
			if floor == 0 then
				model.PrimaryPart = slab
			end
		end
	else
		local solid = Build.Part({
			size = Vector3.new(config.footprint.X, totalHeight, config.footprint.Y),
			position = config.position + Vector3.new(0, totalHeight / 2, 0),
			color = color,
			material = config.material or Enum.Material.Concrete,
			parent = model,
			name = "Mass",
		})
		model.PrimaryPart = solid
	end

	-- A roof slab, which is what rooftop traversal actually lands on.
	Build.Part({
		size = Vector3.new(config.footprint.X + 2, 1.5, config.footprint.Y + 2),
		position = config.position + Vector3.new(0, totalHeight, 0),
		color = color:Lerp(Color3.new(1, 1, 1), 0.08),
		material = Enum.Material.Concrete,
		parent = model,
		name = "Roof",
	})

	return model
end

--[[ A bridge or catwalk between two points, with supports. ]]
function Build.Span(config: {
	from: Vector3,
	to: Vector3,
	width: number?,
	thickness: number?,
	color: Color3?,
	material: Enum.Material?,
	parent: Instance?,
	name: string?,
	supports: boolean?,
	groundY: number?,
}): Model
	local model = Build.Model(config.parent or workspace, config.name or "Span")
	local width = config.width or 8
	local thickness = config.thickness or 1.2

	local delta = config.to - config.from
	local length = delta.Magnitude
	if length < 1 then
		return model
	end

	local midpoint = config.from + delta * 0.5
	local deck = Build.Part({
		size = Vector3.new(width, thickness, length),
		cframe = CFrame.lookAt(midpoint, config.to),
		color = config.color or Color3.fromRGB(72, 76, 84),
		material = config.material or Enum.Material.Metal,
		parent = model,
		name = "Deck",
	})
	model.PrimaryPart = deck

	if config.supports and config.groundY then
		local supportCount = math.max(1, math.floor(length / 60))
		for index = 1, supportCount do
			local t = index / (supportCount + 1)
			local point = config.from + delta * t
			local height = point.Y - config.groundY
			if height > 4 then
				Build.Part({
					size = Vector3.new(3, height, 3),
					position = Vector3.new(point.X, config.groundY + height / 2, point.Z),
					color = Color3.fromRGB(60, 62, 68),
					material = Enum.Material.Metal,
					parent = model,
					name = "Support" .. index,
				})
			end
		end
	end

	return model
end

--[[ A staircase between two heights, built from discrete steps so it is walkable. ]]
function Build.Stairs(config: {
	from: Vector3,
	to: Vector3,
	width: number?,
	stepHeight: number?,
	color: Color3?,
	parent: Instance?,
	name: string?,
}): Model
	local model = Build.Model(config.parent or workspace, config.name or "Stairs")
	local width = config.width or 8
	local stepHeight = config.stepHeight or 2

	local delta = config.to - config.from
	local rise = delta.Y
	local steps = math.max(1, math.ceil(math.abs(rise) / stepHeight))
	local horizontal = Vector3.new(delta.X, 0, delta.Z)
	local stepDepth = horizontal.Magnitude / steps

	if stepDepth < 0.5 then
		return model
	end

	local direction = horizontal.Unit
	for index = 1, steps do
		local t = index / steps
		local position = config.from + Vector3.new(horizontal.X * t, rise * t, horizontal.Z * t)
		Build.Part({
			size = Vector3.new(width, stepHeight, stepDepth),
			cframe = CFrame.lookAt(position, position + direction),
			color = config.color or Color3.fromRGB(76, 80, 88),
			material = Enum.Material.Concrete,
			parent = model,
			name = "Step" .. index,
		})
	end

	return model
end

--[[
	A conductive anchor point for the grapple, marked so the client can highlight it.
	Anchors are what make a vertical region readable: they tell the player where the
	designer thinks they can go.
]]
function Build.GrappleAnchor(position: Vector3, parent: Instance?, name: string?): BasePart
	local anchor = Build.Part({
		size = Vector3.new(3, 3, 3),
		position = position,
		color = Color3.fromRGB(88, 200, 255),
		material = Enum.Material.Neon,
		parent = parent,
		name = name or "GrappleAnchor",
		canCollide = false,
	})
	anchor:AddTag("GrappleAnchor")
	return anchor
end

--[[ A ridable cable between two points. ]]
function Build.Zipline(from: Vector3, to: Vector3, parent: Instance?, name: string?): BasePart
	local delta = to - from
	local cable = Build.Part({
		size = Vector3.new(0.4, 0.4, delta.Magnitude),
		cframe = CFrame.lookAt(from + delta * 0.5, to),
		color = Color3.fromRGB(40, 42, 48),
		material = Enum.Material.Metal,
		parent = parent,
		name = name or "Zipline",
		canCollide = false,
	})
	cable:AddTag("Zipline")
	cable:SetAttribute("FromX", from.X)
	cable:SetAttribute("FromY", from.Y)
	cable:SetAttribute("FromZ", from.Z)
	cable:SetAttribute("ToX", to.X)
	cable:SetAttribute("ToY", to.Y)
	cable:SetAttribute("ToZ", to.Z)
	return cable
end

--[[ An electrified rail segment. ]]
function Build.Rail(from: Vector3, to: Vector3, parent: Instance?, name: string?): BasePart
	local delta = to - from
	local rail = Build.Part({
		size = Vector3.new(1.2, 0.8, delta.Magnitude),
		cframe = CFrame.lookAt(from + delta * 0.5, to),
		color = Color3.fromRGB(255, 162, 61),
		material = Enum.Material.Neon,
		parent = parent,
		name = name or "Rail",
		canCollide = false,
	})
	rail:AddTag("ChargeRail")
	return rail
end

--[[ A point light with sane defaults for a world that is mostly dark. ]]
function Build.Light(parent: BasePart, config: {
	color: Color3?,
	brightness: number?,
	range: number?,
	shadows: boolean?,
}?): PointLight
	local settings = config or {}
	local light = Instance.new("PointLight")
	light.Color = settings.color or Color3.fromRGB(120, 200, 255)
	light.Brightness = settings.brightness or 2
	light.Range = settings.range or 30
	light.Shadows = settings.shadows == true
	light.Parent = parent
	return light
end

--[[ Billboard text, used for station signage and landmark names. ]]
function Build.Sign(parent: BasePart, text: string, config: {
	size: Vector2?,
	color: Color3?,
	studsOffset: Vector3?,
	maxDistance: number?,
	textSize: number?,
}?): BillboardGui
	local settings = config or {}
	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.fromScale(settings.size and settings.size.X or 12, settings.size and settings.size.Y or 3)
	billboard.StudsOffsetWorldSpace = settings.studsOffset or Vector3.new(0, 6, 0)
	billboard.MaxDistance = settings.maxDistance or 400
	billboard.AlwaysOnTop = false
	billboard.Parent = parent

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = text
	label.TextColor3 = settings.color or Color3.fromRGB(200, 232, 255)
	label.TextScaled = true
	label.Font = Enum.Font.GothamMedium
	label.TextStrokeTransparency = 0.6
	label.Parent = billboard

	return billboard
end

--[[ Converts a hex string from the region palette into a Color3. ]]
function Build.HexColor(hex: string): Color3
	local cleaned = hex:gsub("#", "")
	return Color3.fromRGB(
		tonumber(cleaned:sub(1, 2), 16) or 128,
		tonumber(cleaned:sub(3, 4), 16) or 128,
		tonumber(cleaned:sub(5, 6), 16) or 128
	)
end

return Build
