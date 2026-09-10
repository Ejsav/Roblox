--!strict
--[[
	WorldBuilder
	------------
	Constructs the entire playable world procedurally from the region atlas.

	Why procedural rather than a hand-built place file: the world is roughly 17,000
	studs across with ten regions, and a place file that size is unreviewable,
	unmergeable and impossible to iterate on. Generating from data means a region's
	character lives in Regions.luau where a designer can read it, the whole world
	regenerates identically from a seed, and the repository stays diffable.

	Determinism is load-bearing. Every random decision draws from a named sub-stream
	of the world seed, so the mountain a player sees from the Sattermarsh is the same
	mountain on every server, and a landmark's position can be referenced by other
	systems without being stored.

	Generation is chunked across frames. Building 40,000 parts in one heartbeat would
	stall the server for seconds during which players are already connecting.
]]

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BTS")
local Signal = require(Shared.Core.Signal)
local RNG = require(Shared.Core.RNG)
local MathUtil = require(Shared.Core.MathUtil)
local Regions = require(Shared.Config.Regions)

local Build = require(script.Parent.Build)

local WorldBuilder = {}
WorldBuilder.Name = "WorldBuilder"
WorldBuilder.Dependencies = { "RegionService", "DiscoveryService", "StormService" }
WorldBuilder.Priority = 60

-- The world seed. Fixed so every server builds the identical world; change it and
-- the entire world regenerates, which is a deliberate, visible act.
local WORLD_SEED = "borrow-the-storm-v1"

-- Generation yields after this many parts, keeping each frame's cost bounded.
local PARTS_PER_FRAME = 260

function WorldBuilder:Init()
	self._rng = RNG.new(WORLD_SEED)
	self._root = nil
	self._regionFolders = {}
	self._heightCache = {}
	self._structures = {}      -- conductive structures, for cascade storms
	self._highPoints = {}      -- tall points per region, for spire storms
	self._partBudget = 0
	self._partsBuilt = 0
	self._built = false

	self.BuildProgress = Signal.new("WorldBuilder.BuildProgress")
	self.BuildCompleted = Signal.new("WorldBuilder.BuildCompleted")
end

function WorldBuilder:Start()
	self._regions = self.Registry:Get("RegionService")
	self._discoveries = self.Registry:Get("DiscoveryService")
	self._storms = self.Registry:Get("StormService")

	-- Give the storm system access to real geometry so behaviours that want a
	-- structure or a high point get one instead of a synthesised position.
	self._storms:RegisterWorldHooks({
		findStructure = function(origin, radius, index)
			return self:FindStructureNear(origin, radius, index)
		end,
		findHighestPoint = function(origin, radius)
			return self:FindHighestPointNear(origin, radius)
		end,
		getGroundHeight = function(position)
			return self:GetGroundHeight(position)
		end,
	})
end

function WorldBuilder:Ready()
	task.spawn(function()
		self:BuildWorld()
	end)
end

-- ============================================================================
-- Terrain height
-- ============================================================================

--[[
	The world's height function. Deterministic, cheap, and shared by terrain
	generation, structure placement and storm spawning, so nothing ever ends up
	floating or buried.
]]
function WorldBuilder:GetGroundHeight(position: Vector3): number
	local key = ("%d:%d"):format(math.floor(position.X / 16), math.floor(position.Z / 16))
	local cached = self._heightCache[key]
	if cached then
		return cached
	end

	local region = Regions.FindContaining(position.X, 0, position.Z)
	local baseY = 0
	local amplitude = 30
	local frequency = 0.00055

	if region then
		baseY = region.center.Y
		-- Each region gets its own relief character, which is most of what makes
		-- crossing a border feel like arriving somewhere.
		if region.id == "mountain_region" then
			amplitude = 900
			frequency = 0.00042
		elseif region.id == "storm_plains" then
			amplitude = 26
			frequency = 0.00075
		elseif region.id == "electrical_wasteland" then
			amplitude = 70
			frequency = 0.0011
		elseif region.id == "city_region" then
			amplitude = 14
			frequency = 0.0009
		elseif region.id == "industrial_grid" then
			amplitude = 22
			frequency = 0.0008
		elseif region.id == "high_altitude" or region.id == "underground_network" then
			-- These regions are built entirely from structures; their "ground" is the
			-- bottom of the playable band.
			amplitude = 0
			baseY = region.verticalRange.min
		elseif region.id == "storm_core" then
			amplitude = 180
			frequency = 0.0006
		elseif region.id == "null_reach" then
			amplitude = 220
			frequency = 0.0009
		end
	end

	local noise = MathUtil.FBM(position.X * frequency, position.Z * frequency, 8891, 5)
	local ridge = MathUtil.FBM(position.X * frequency * 2.7, position.Z * frequency * 2.7, 4412, 3)

	local height = baseY + (noise - 0.5) * 2 * amplitude + (ridge - 0.5) * amplitude * 0.28

	-- Flatten a bowl around each region's fast travel node so hubs are level ground
	-- and a player never spawns on a slope they slide off.
	if region and region.fastTravel then
		local hub = Vector3.new(region.fastTravel.position.X, 0, region.fastTravel.position.Z)
		local flat = Vector3.new(position.X, 0, position.Z)
		local distance = (flat - hub).Magnitude
		local flattenRadius = 220
		if distance < flattenRadius then
			local blend = MathUtil.Ease.Smootherstep(distance / flattenRadius)
			height = MathUtil.Lerp(region.fastTravel.position.Y, height, blend)
		end
	end

	self._heightCache[key] = height
	return height
end

-- ============================================================================
-- Build orchestration
-- ============================================================================

function WorldBuilder:BuildWorld()
	if self._built then
		return
	end
	self._built = true

	local startClock = os.clock()

	self._root = Build.Folder(Workspace, "BTS_World")
	self._root:SetAttribute("Seed", WORLD_SEED)

	print("[WorldBuilder] generating world...")

	for _, region in ipairs(Regions.List) do
		local folder = Build.Folder(self._root, region.id)
		self._regionFolders[region.id] = folder
		self._highPoints[region.id] = {}
		self._structures[region.id] = {}

		self:_buildRegion(region, folder)
		self.BuildProgress:Fire(region.id)
	end

	local elapsed = (os.clock() - startClock) * 1000
	print(("[WorldBuilder] world generated: %d parts in %.0fms"):format(self._partsBuilt, elapsed))
	self.BuildCompleted:Fire(self._partsBuilt, elapsed)
end

--[[ Yields when the frame's part budget is spent, keeping the server responsive. ]]
function WorldBuilder:_budget(count: number)
	self._partsBuilt += count
	self._partBudget += count
	if self._partBudget >= PARTS_PER_FRAME then
		self._partBudget = 0
		RunService.Heartbeat:Wait()
	end
end

function WorldBuilder:_buildRegion(region: any, folder: Folder)
	local rng = self._rng:Stream("region_" .. region.id)

	self:_buildTerrain(region, folder, rng)
	self:_buildHub(region, folder, rng)
	self:_buildBankStations(region, folder, rng)
	self:_buildSubregions(region, folder, rng)
	self:_buildLandmarks(region, folder, rng)
	self:_buildTraversal(region, folder, rng)
	self:_buildDiscoveries(region, folder, rng)
end

-- ============================================================================
-- Terrain
-- ============================================================================

--[[
	Region terrain as a grid of large tiles, height-sampled from the shared height
	function. Coarse on purpose: this is a stylised world, and a 48-stud tile at this
	scale reads as landscape while keeping the part count survivable.
]]
function WorldBuilder:_buildTerrain(region: any, folder: Folder, rng: any)
	-- The high-altitude and underground regions have no ground; they are built
	-- entirely from platforms and corridors.
	if region.id == "high_altitude" or region.id == "underground_network" then
		return
	end

	local terrainFolder = Build.Folder(folder, "Terrain")
	local tileSize = 96
	local tilesPerSide = math.ceil((region.radius * 2) / tileSize)
	local centre = Vector3.new(region.center.X, 0, region.center.Z)
	local terrainColor = Build.HexColor(region.palette.terrain)

	local built = 0
	for gridX = 0, tilesPerSide do
		for gridZ = 0, tilesPerSide do
			local offsetX = (gridX - tilesPerSide / 2) * tileSize
			local offsetZ = (gridZ - tilesPerSide / 2) * tileSize

			-- Circular region footprint, so regions read as places rather than
			-- squares and the gaps between them become natural frontiers.
			if offsetX * offsetX + offsetZ * offsetZ > region.radius * region.radius then
				continue
			end

			local samplePosition = centre + Vector3.new(offsetX, 0, offsetZ)
			local height = self:GetGroundHeight(samplePosition)

			-- Vary tile colour slightly so a large area does not read as one flat sheet.
			local variation = rng:NextRange(-0.05, 0.05)
			local tileColor = terrainColor:Lerp(
				variation > 0 and Color3.new(1, 1, 1) or Color3.new(0, 0, 0),
				math.abs(variation)
			)

			Build.Part({
				size = Vector3.new(tileSize + 1, 24, tileSize + 1),
				position = Vector3.new(samplePosition.X, height - 12, samplePosition.Z),
				color = tileColor,
				material = self:_terrainMaterial(region),
				parent = terrainFolder,
				name = ("T%d_%d"):format(gridX, gridZ),
			})
			built += 1

			if built % 40 == 0 then
				self:_budget(40)
			end
		end
	end
	self:_budget(built % 40)
end

function WorldBuilder:_terrainMaterial(region: any): Enum.Material
	if region.id == "mountain_region" then
		return Enum.Material.Slate
	elseif region.id == "storm_plains" then
		return Enum.Material.Ground
	elseif region.id == "electrical_wasteland" then
		return Enum.Material.CrackedLava
	elseif region.id == "industrial_grid" then
		return Enum.Material.Metal
	elseif region.id == "city_region" then
		return Enum.Material.Concrete
	elseif region.id == "storm_core" or region.id == "null_reach" then
		return Enum.Material.Basalt
	end
	return Enum.Material.Concrete
end

-- ============================================================================
-- Hub
-- ============================================================================

--[[ The fast travel node and its immediate surroundings: level, lit, and safe. ]]
function WorldBuilder:_buildHub(region: any, folder: Folder, rng: any)
	if not region.fastTravel then
		return
	end

	local hubFolder = Build.Folder(folder, "Hub")
	local position = Vector3.new(
		region.fastTravel.position.X,
		region.fastTravel.position.Y,
		region.fastTravel.position.Z
	)
	local accent = Build.HexColor(region.palette.accent)

	local pad = Build.Platform({
		position = position,
		size = Vector2.new(44, 44),
		thickness = 3,
		color = Build.HexColor(region.palette.terrain):Lerp(Color3.new(0, 0, 0), 0.3),
		material = Enum.Material.Metal,
		parent = hubFolder,
		name = "RelayPad",
	})

	-- A ring of pylons, which reads at distance as "somewhere built" and gives the
	-- region's accent colour a place to live.
	for index = 1, 6 do
		local angle = (index / 6) * math.pi * 2
		local pylonPosition = position + Vector3.new(math.cos(angle) * 26, 9, math.sin(angle) * 26)
		local pylon = Build.Part({
			size = Vector3.new(2, 18, 2),
			position = pylonPosition,
			color = accent,
			material = Enum.Material.Neon,
			parent = hubFolder,
			name = "Pylon" .. index,
		})
		Build.Light(pylon, { color = accent, brightness = 3, range = 42 })
	end

	Build.Sign(pad, region.fastTravel.name, {
		color = accent,
		studsOffset = Vector3.new(0, 14, 0),
		maxDistance = 700,
	})

	pad:AddTag("FastTravelNode")
	pad:SetAttribute("FastTravelId", region.fastTravel.id)
	pad:SetAttribute("RegionId", region.id)

	self._regions:RegisterSafeZone("hub_" .. region.id, position, 40)
	self:_budget(10)
end

-- ============================================================================
-- Bank stations
-- ============================================================================

function WorldBuilder:_buildBankStations(region: any, folder: Folder, rng: any)
	local stationFolder = Build.Folder(folder, "BankStations")
	local energy = Build.HexColor(region.palette.energy)

	for _, station in ipairs(region.bankStations) do
		local position = Vector3.new(station.position.X, station.position.Y, station.position.Z)
		local groundY = self:GetGroundHeight(position)
		-- Stations authored above ground stay where they are (catwalks, platforms);
		-- ones authored at ground level snap to the terrain.
		if position.Y < groundY + 2 then
			position = Vector3.new(position.X, groundY + 2, position.Z)
		end

		local base = Build.Platform({
			position = position,
			size = Vector2.new(24, 24),
			thickness = 2,
			color = Color3.fromRGB(48, 52, 60),
			material = Enum.Material.DiamondPlate,
			parent = stationFolder,
			name = station.id,
		})

		-- The column is the visual signature of a bank: visible from a long way off,
		-- which is exactly what a player carrying a full load is looking for.
		local column = Build.Part({
			size = Vector3.new(4, 26, 4),
			position = position + Vector3.new(0, 14, 0),
			color = energy,
			material = Enum.Material.Neon,
			parent = stationFolder,
			name = station.id .. "_Column",
			canCollide = false,
		})
		Build.Light(column, { color = energy, brightness = 5, range = 70 })

		Build.Sign(column, station.name, {
			color = energy,
			studsOffset = Vector3.new(0, 18, 0),
			maxDistance = 900,
		})

		base:AddTag("BankStation")
		base:SetAttribute("StationId", station.id)
		base:SetAttribute("RegionId", region.id)
		base:SetAttribute("Tier", station.tier)

		self._regions:RegisterSafeZone("bank_" .. station.id, position, 26)
		self:_budget(6)
	end
end

-- ============================================================================
-- Subregions
-- ============================================================================

--[[
	Each subregion gets geometry appropriate to its declared role, which is what
	turns the atlas's prose into something you can stand on.
]]
function WorldBuilder:_buildSubregions(region: any, folder: Folder, rng: any)
	local subFolder = Build.Folder(folder, "Subregions")

	for _, subregion in ipairs(region.subregions) do
		local areaFolder = Build.Folder(subFolder, subregion.id)
		local centre = Vector3.new(subregion.center.X, subregion.center.Y, subregion.center.Z)
		local subRng = rng:Stream(subregion.id)

		if subregion.role == "settlement" or subregion.role == "hub" then
			self:_buildSettlement(region, areaFolder, centre, subregion, subRng)
		elseif subregion.role == "farming" then
			self:_buildFarmingGround(region, areaFolder, centre, subregion, subRng)
		elseif subregion.role == "traversal" then
			self:_buildTraversalCourse(region, areaFolder, centre, subregion, subRng)
		elseif subregion.role == "challenge" or subregion.role == "endgame" then
			self:_buildChallengeSite(region, areaFolder, centre, subregion, subRng)
		elseif subregion.role == "vista" then
			self:_buildVista(region, areaFolder, centre, subregion, subRng)
		elseif subregion.role == "secret" or subregion.role == "story" then
			self:_buildInterior(region, areaFolder, centre, subregion, subRng)
		elseif subregion.role == "gate" then
			self:_buildGate(region, areaFolder, centre, subregion, subRng)
		else
			self:_buildFarmingGround(region, areaFolder, centre, subregion, subRng)
		end

		self:_budget(24)
	end
end

function WorldBuilder:_buildSettlement(region: any, folder: Folder, centre: Vector3, subregion: any, rng: any)
	local color = Build.HexColor(region.palette.terrain):Lerp(Color3.new(1, 1, 1), 0.12)
	local count = math.floor(subregion.radius / 32)

	for index = 1, count do
		local x, z = rng:NextPointInDisc(subregion.radius * 0.8)
		local position = centre + Vector3.new(x, 0, z)
		local groundY = self:GetGroundHeight(position)
		local floors = rng:NextInteger(1, 3)

		Build.Building({
			position = Vector3.new(position.X, groundY, position.Z),
			footprint = Vector2.new(rng:NextRange(14, 26), rng:NextRange(14, 26)),
			floors = floors,
			floorHeight = 12,
			color = color,
			parent = folder,
			name = "Structure" .. index,
			hollow = floors > 1,
		})

		-- Roofs of settlement buildings are legitimate high points.
		table.insert(self._highPoints[region.id], Vector3.new(position.X, groundY + floors * 12, position.Z))
		table.insert(self._structures[region.id], Vector3.new(position.X, groundY + 6, position.Z))
	end
end

function WorldBuilder:_buildFarmingGround(region: any, folder: Folder, centre: Vector3, subregion: any, rng: any)
	-- Pylon fields and spine forests: tall conductive objects that storms arc
	-- between, which is what makes these areas worth working.
	local accent = Build.HexColor(region.palette.accent)
	local count = math.floor(subregion.radius / 22)

	for index = 1, count do
		local x, z = rng:NextPointInDisc(subregion.radius * 0.9)
		local position = centre + Vector3.new(x, 0, z)
		local groundY = self:GetGroundHeight(position)
		local height = rng:NextRange(34, 92)

		Build.Tower({
			basePosition = Vector3.new(position.X, groundY, position.Z),
			height = height,
			baseWidth = rng:NextRange(3, 6),
			topWidth = 1.6,
			segments = 3,
			color = Build.HexColor(region.palette.terrain):Lerp(Color3.new(0, 0, 0), 0.2),
			material = Enum.Material.Metal,
			parent = folder,
			name = "Pylon" .. index,
			rng = rng,
			jitter = 1.2,
		})

		-- A conductive cap, which is both the visual read and the storm target.
		local cap = Build.Part({
			size = Vector3.new(2.4, 2.4, 2.4),
			position = Vector3.new(position.X, groundY + height + 1, position.Z),
			color = accent,
			material = Enum.Material.Neon,
			parent = folder,
			name = "Cap" .. index,
			canCollide = false,
		})
		if index % 4 == 0 then
			Build.Light(cap, { color = accent, brightness = 2, range = 34 })
		end

		local topPoint = Vector3.new(position.X, groundY + height, position.Z)
		table.insert(self._highPoints[region.id], topPoint)
		table.insert(self._structures[region.id], topPoint)
	end
end

function WorldBuilder:_buildTraversalCourse(region: any, folder: Folder, centre: Vector3, subregion: any, rng: any)
	-- A chain of platforms at rising heights with anchors between them: the shape
	-- that teaches a movement ability without a tutorial box.
	local platformCount = 12
	local previousPosition = nil

	for index = 1, platformCount do
		local angle = (index / platformCount) * math.pi * 3
		local distance = subregion.radius * (0.25 + 0.6 * (index / platformCount))
		local position = centre + Vector3.new(math.cos(angle) * distance, 0, math.sin(angle) * distance)
		local groundY = self:GetGroundHeight(position)
		local height = groundY + 20 + index * 14

		local platform = Build.Platform({
			position = Vector3.new(position.X, height, position.Z),
			size = Vector2.new(rng:NextRange(14, 24), rng:NextRange(14, 24)),
			thickness = 1.5,
			color = Color3.fromRGB(64, 68, 78),
			material = Enum.Material.DiamondPlate,
			parent = folder,
			name = "Deck" .. index,
			railHeight = index % 3 == 0 and 4 or nil,
		})

		if previousPosition then
			local gap = (Vector3.new(position.X, height, position.Z) - previousPosition).Magnitude
			-- Short gaps get a bridge; long ones stay open and require movement tech,
			-- which is how the world tells a player what they still cannot do.
			if gap < 55 then
				Build.Span({
					from = previousPosition,
					to = Vector3.new(position.X, height, position.Z),
					width = 6,
					parent = folder,
					name = "Bridge" .. index,
				})
			else
				Build.GrappleAnchor(
					previousPosition:Lerp(Vector3.new(position.X, height, position.Z), 0.5) + Vector3.new(0, 22, 0),
					folder,
					"Anchor" .. index
				)
			end
		end

		previousPosition = Vector3.new(position.X, height, position.Z)
		table.insert(self._highPoints[region.id], previousPosition)
	end
end

function WorldBuilder:_buildChallengeSite(region: any, folder: Folder, centre: Vector3, subregion: any, rng: any)
	local groundY = self:GetGroundHeight(centre)
	local accent = Build.HexColor(region.palette.accent)

	-- A single dominant structure surrounded by broken ground. Challenge sites should
	-- be legible from outside so a player chooses to enter them.
	Build.Tower({
		basePosition = Vector3.new(centre.X, groundY, centre.Z),
		height = 180,
		baseWidth = 30,
		topWidth = 10,
		segments = 6,
		color = Build.HexColor(region.palette.terrain):Lerp(Color3.new(0, 0, 0), 0.3),
		material = Enum.Material.Metal,
		parent = folder,
		name = "Core",
		rng = rng,
		jitter = 2.5,
	})

	local crown = Build.Part({
		size = Vector3.new(14, 6, 14),
		position = Vector3.new(centre.X, groundY + 184, centre.Z),
		color = accent,
		material = Enum.Material.Neon,
		parent = folder,
		name = "Crown",
		canCollide = true,
	})
	Build.Light(crown, { color = accent, brightness = 6, range = 120 })

	table.insert(self._highPoints[region.id], Vector3.new(centre.X, groundY + 184, centre.Z))
	table.insert(self._structures[region.id], Vector3.new(centre.X, groundY + 90, centre.Z))

	-- A ring of debris the player has to negotiate rather than run across.
	for index = 1, 16 do
		local angle = rng:NextNumber() * math.pi * 2
		local distance = rng:NextRange(subregion.radius * 0.3, subregion.radius * 0.85)
		local position = centre + Vector3.new(math.cos(angle) * distance, 0, math.sin(angle) * distance)
		local localGround = self:GetGroundHeight(position)
		Build.Part({
			size = Vector3.new(rng:NextRange(8, 22), rng:NextRange(6, 30), rng:NextRange(8, 22)),
			cframe = CFrame.new(position.X, localGround + 6, position.Z)
				* CFrame.Angles(rng:NextRange(-0.4, 0.4), rng:NextNumber() * math.pi, rng:NextRange(-0.4, 0.4)),
			color = Build.HexColor(region.palette.terrain),
			material = Enum.Material.Slate,
			parent = folder,
			name = "Debris" .. index,
		})
	end
end

function WorldBuilder:_buildVista(region: any, folder: Folder, centre: Vector3, subregion: any, rng: any)
	local groundY = self:GetGroundHeight(centre)

	-- A raised viewing deck. Vistas exist to sell the scale of the world, so they
	-- are placed high and kept clear of clutter.
	local deck = Build.Platform({
		position = Vector3.new(centre.X, groundY + 46, centre.Z),
		size = Vector2.new(38, 38),
		thickness = 2,
		color = Color3.fromRGB(70, 74, 84),
		material = Enum.Material.Metal,
		parent = folder,
		name = "Overlook",
		railHeight = 5,
	})

	Build.Stairs({
		from = Vector3.new(centre.X + 30, groundY, centre.Z),
		to = Vector3.new(centre.X + 20, groundY + 45, centre.Z),
		width = 8,
		parent = folder,
		name = "Ascent",
	})

	Build.Sign(deck, subregion.name, {
		color = Build.HexColor(region.palette.accent),
		studsOffset = Vector3.new(0, 10, 0),
		maxDistance = 600,
	})

	table.insert(self._highPoints[region.id], Vector3.new(centre.X, groundY + 46, centre.Z))
end

function WorldBuilder:_buildInterior(region: any, folder: Folder, centre: Vector3, subregion: any, rng: any)
	-- Interiors are corridors and rooms rather than open ground: the places where a
	-- player slows down, reads something, and finds out what happened here.
	local groundY = self:GetGroundHeight(centre)
	local baseY = region.id == "underground_network" and centre.Y or (groundY - 40)
	local wallColor = Build.HexColor(region.palette.terrain):Lerp(Color3.new(0, 0, 0), 0.35)

	local roomCount = 5
	local previousCentre = nil

	for index = 1, roomCount do
		local angle = (index / roomCount) * math.pi * 2 + rng:NextRange(-0.3, 0.3)
		local distance = subregion.radius * rng:NextRange(0.25, 0.7)
		local roomCentre = Vector3.new(
			centre.X + math.cos(angle) * distance,
			baseY,
			centre.Z + math.sin(angle) * distance
		)

		local width = rng:NextRange(30, 56)
		local depth = rng:NextRange(30, 56)

		Build.Building({
			position = roomCentre,
			footprint = Vector2.new(width, depth),
			floors = 1,
			floorHeight = 20,
			color = wallColor,
			material = Enum.Material.Concrete,
			parent = folder,
			name = "Room" .. index,
			hollow = true,
		})

		-- Interior lighting: sparse, so a lamp upgrade matters underground.
		local lamp = Build.Part({
			size = Vector3.new(2, 0.4, 2),
			position = roomCentre + Vector3.new(0, 18, 0),
			color = Build.HexColor(region.palette.energy),
			material = Enum.Material.Neon,
			parent = folder,
			name = "Lamp" .. index,
			canCollide = false,
		})
		Build.Light(lamp, { color = Build.HexColor(region.palette.energy), brightness = 2.5, range = 40 })

		if previousCentre then
			Build.Span({
				from = previousCentre,
				to = roomCentre,
				width = 10,
				thickness = 1,
				color = wallColor,
				parent = folder,
				name = "Corridor" .. index,
			})
		end
		previousCentre = roomCentre
	end
end

function WorldBuilder:_buildGate(region: any, folder: Folder, centre: Vector3, subregion: any, rng: any)
	local groundY = self:GetGroundHeight(centre)
	local accent = Build.HexColor(region.palette.accent)

	-- A sealed door with visible mechanism. Gates are promises: the player is meant
	-- to see one long before they can open it.
	local frame = Build.Part({
		size = Vector3.new(46, 60, 6),
		position = Vector3.new(centre.X, groundY + 30, centre.Z),
		color = Color3.fromRGB(40, 42, 48),
		material = Enum.Material.DiamondPlate,
		parent = folder,
		name = "GateFrame",
	})

	local door = Build.Part({
		size = Vector3.new(34, 48, 3),
		position = Vector3.new(centre.X, groundY + 26, centre.Z),
		color = Color3.fromRGB(28, 30, 36),
		material = Enum.Material.Metal,
		parent = folder,
		name = "GateDoor",
	})
	door:AddTag("SealedGate")
	door:SetAttribute("SubregionId", subregion.id)
	door:SetAttribute("RegionId", region.id)

	for index = 1, 4 do
		local light = Build.Part({
			size = Vector3.new(2, 2, 1),
			position = Vector3.new(centre.X - 18 + index * 9, groundY + 54, centre.Z - 3.5),
			color = accent,
			material = Enum.Material.Neon,
			parent = folder,
			name = "Indicator" .. index,
			canCollide = false,
		})
		Build.Light(light, { color = accent, brightness = 2, range = 20 })
	end

	Build.Sign(frame, subregion.name, {
		color = accent,
		studsOffset = Vector3.new(0, 34, 0),
		maxDistance = 500,
	})
end

-- ============================================================================
-- Landmarks
-- ============================================================================

--[[
	The enormous, visible-from-anywhere structures. These are the reason a player at
	the Overlook on their first day has a goal for their fiftieth.
]]
function WorldBuilder:_buildLandmarks(region: any, folder: Folder, rng: any)
	local landmarkFolder = Build.Folder(folder, "Landmarks")
	local accent = Build.HexColor(region.palette.accent)
	local energy = Build.HexColor(region.palette.energy)

	for index, landmarkId in ipairs(region.landmarks) do
		-- Landmarks are placed on a wide ring around the region centre so they are
		-- separated and each one owns a piece of the skyline.
		local angle = (index / #region.landmarks) * math.pi * 2 + rng:NextRange(-0.2, 0.2)
		local distance = region.radius * rng:NextRange(0.45, 0.8)
		local position = Vector3.new(
			region.center.X + math.cos(angle) * distance,
			0,
			region.center.Z + math.sin(angle) * distance
		)
		local groundY = self:GetGroundHeight(position)

		-- Scale with the region's progression order: late-game landmarks are
		-- genuinely colossal, which is what makes the horizon read as a difficulty
		-- gradient.
		local height = 200 + region.order * 90 + rng:NextRange(0, 140)
		local width = 24 + region.order * 6

		local model = Build.Tower({
			basePosition = Vector3.new(position.X, groundY, position.Z),
			height = height,
			baseWidth = width,
			topWidth = width * 0.3,
			segments = math.max(5, math.floor(height / 60)),
			color = Build.HexColor(region.palette.terrain):Lerp(Color3.new(0, 0, 0), 0.4),
			material = Enum.Material.Metal,
			parent = landmarkFolder,
			name = landmarkId,
			rng = rng,
			jitter = 3,
		})

		-- A beacon at the top, bright enough to be the thing a player navigates by.
		local beacon = Build.Part({
			size = Vector3.new(width * 0.5, width * 0.5, width * 0.5),
			position = Vector3.new(position.X, groundY + height + width * 0.3, position.Z),
			color = energy,
			material = Enum.Material.Neon,
			parent = landmarkFolder,
			name = landmarkId .. "_Beacon",
			canCollide = false,
			shape = Enum.PartType.Ball,
		})
		Build.Light(beacon, { color = energy, brightness = 8, range = 240 })

		beacon:AddTag("Landmark")
		beacon:SetAttribute("LandmarkId", landmarkId)
		beacon:SetAttribute("RegionId", region.id)

		local topPoint = Vector3.new(position.X, groundY + height, position.Z)
		table.insert(self._highPoints[region.id], topPoint)
		table.insert(self._structures[region.id], topPoint)

		self:_budget(12)
	end
end

-- ============================================================================
-- Traversal infrastructure
-- ============================================================================

function WorldBuilder:_buildTraversal(region: any, folder: Folder, rng: any)
	local traversalFolder = Build.Folder(folder, "Traversal")
	local highPoints = self._highPoints[region.id]
	if #highPoints < 2 then
		return
	end

	-- Ziplines between high points that are far apart horizontally but close in
	-- height: the natural shape for a cable, and a genuine shortcut.
	local zipCount = math.min(10, math.floor(#highPoints / 3))
	for index = 1, zipCount do
		local from = highPoints[rng:NextInteger(1, #highPoints)]
		local to = highPoints[rng:NextInteger(1, #highPoints)]
		local delta = to - from
		local horizontal = Vector3.new(delta.X, 0, delta.Z).Magnitude

		if horizontal > 120 and horizontal < 900 and math.abs(delta.Y) < horizontal * 0.5 then
			Build.Zipline(from + Vector3.new(0, 3, 0), to + Vector3.new(0, 3, 0), traversalFolder, "Zip" .. index)
		end
	end

	-- Grapple anchors scattered at height, so a grapple owner always has options.
	for index = 1, math.min(24, #highPoints) do
		local point = highPoints[rng:NextInteger(1, #highPoints)]
		Build.GrappleAnchor(point + Vector3.new(rng:NextRange(-20, 20), 8, rng:NextRange(-20, 20)), traversalFolder, "Anchor" .. index)
	end

	-- Charge rails in the industrial and core regions, which is where the fiction
	-- supports them.
	if region.id == "industrial_grid" or region.id == "storm_core" or region.id == "high_altitude" then
		local railCount = 6
		for index = 1, railCount do
			local from = highPoints[rng:NextInteger(1, #highPoints)]
			local to = highPoints[rng:NextInteger(1, #highPoints)]
			if (to - from).Magnitude > 200 then
				Build.Rail(from + Vector3.new(0, 2, 0), to + Vector3.new(0, 2, 0), traversalFolder, "Rail" .. index)
			end
		end
	end

	self:_budget(20)
end

-- ============================================================================
-- Discoveries
-- ============================================================================

--[[
	Places the region's declared number of discoveries, registers each with
	DiscoveryService, and gives each a small physical marker that rewards looking
	rather than following a waypoint.
]]
function WorldBuilder:_buildDiscoveries(region: any, folder: Folder, rng: any)
	local discoveryFolder = Build.Folder(folder, "Discoveries")
	local energy = Build.HexColor(region.palette.energy)

	for index = 1, region.discoveryCount do
		local x, z = rng:NextPointInAnnulus(region.radius * 0.2, region.radius * 0.9)
		local position = Vector3.new(region.center.X + x, 0, region.center.Z + z)
		local groundY = self:GetGroundHeight(position)
		local finalPosition = Vector3.new(position.X, groundY + 3, position.Z)

		local id = ("%s_discovery_%d"):format(region.id, index)

		local marker = Build.Part({
			size = Vector3.new(3, 5, 3),
			position = finalPosition,
			color = energy,
			material = Enum.Material.Neon,
			parent = discoveryFolder,
			name = id,
			canCollide = false,
			transparency = 0.35,
		})
		Build.Light(marker, { color = energy, brightness = 1.5, range = 22 })

		marker:AddTag("Discovery")
		marker:SetAttribute("DiscoveryId", id)

		self._discoveries:Register({
			id = id,
			name = ("%s — Site %d"):format(region.name, index),
			description = "Something was here.",
			position = finalPosition,
			radius = 12,
			regionId = region.id,
			kind = "location",
		})
	end

	self:_budget(region.discoveryCount * 2)
end

-- ============================================================================
-- Queries used by storm behaviours
-- ============================================================================

--[[ A conductive structure near a point, for cascade storms. ]]
function WorldBuilder:FindStructureNear(origin: Vector3, radius: number, index: number?): Vector3?
	local region = Regions.FindContaining(origin.X, origin.Y, origin.Z)
	if not region then
		return nil
	end
	local candidates = self._structures[region.id]
	if not candidates or #candidates == 0 then
		return nil
	end

	local inRange = {}
	local radiusSq = radius * radius
	for _, point in ipairs(candidates) do
		if (point - origin).Magnitude ^ 2 <= radiusSq then
			table.insert(inRange, point)
		end
	end
	if #inRange == 0 then
		return nil
	end

	-- Cascade links walk deterministically through the list so the chain has a
	-- readable direction rather than teleporting around.
	local pick = ((index or 1) - 1) % #inRange + 1
	return inRange[pick]
end

--[[ The tallest structure near a point, for altitude-gated storms. ]]
function WorldBuilder:FindHighestPointNear(origin: Vector3, radius: number): Vector3?
	local region = Regions.FindContaining(origin.X, origin.Y, origin.Z)
	if not region then
		return nil
	end
	local candidates = self._highPoints[region.id]
	if not candidates then
		return nil
	end

	local best, bestHeight = nil, -math.huge
	local radiusSq = radius * radius
	for _, point in ipairs(candidates) do
		local flatDistance = Vector3.new(point.X - origin.X, 0, point.Z - origin.Z).Magnitude
		if flatDistance * flatDistance <= radiusSq and point.Y > bestHeight then
			best, bestHeight = point, point.Y
		end
	end
	return best
end

function WorldBuilder:GetStats()
	local highPointCount = 0
	local structureCount = 0
	for _, points in pairs(self._highPoints) do
		highPointCount += #points
	end
	for _, points in pairs(self._structures) do
		structureCount += #points
	end
	return {
		parts = self._partsBuilt,
		highPoints = highPointCount,
		structures = structureCount,
		built = self._built,
	}
end

return WorldBuilder
