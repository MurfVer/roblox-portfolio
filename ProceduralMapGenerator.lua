--[[
	Procedural Map Generator
	
	Generates terrain using perlin noise, places structures, handles mountains/valleys.
	Uses BFS from center so we always have neighbor heights when calculating new blocks.
	
	v3 - rewrote height calc, old version had issues with chunk borders
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local CONFIG = {
	-- map size
	MAP_RADIUS = 40,
	BLOCK_SIZE = 32,
	
	-- height stuff
	START_HEIGHT = 10,
	MIN_HEIGHT = 1,
	MAX_HEIGHT = 20,
	
	-- SMOOTH_FACTOR controls how much neighbors pull the current block toward their average.
	-- At 1.0 the map would be perfectly flat (pure average), at 0.0 it's pure noise with no
	-- coherence between adjacent blocks. 0.6 keeps terrain walkable while still feeling varied.
	SMOOTH_FACTOR = 0.6,
	NOISE_SCALE = 0.1,
	NOISE_STRENGTH = 5,

	-- MAX_HEIGHT_DIFF = 1 means any block can only be 1 unit above or below its neighbor.
	-- This is what makes the terrain actually navigable on foot — without it, you'd get
	-- sheer vertical walls between adjacent tiles.
	MAX_HEIGHT_DIFF = 1,
	
	-- mountains/valleys
	MOUNTAIN_COUNT = 1,
	MOUNTAIN_HEIGHT = 7,
	MOUNTAIN_SIZE = 12,      -- in blocks not studs
	VALLEY_COUNT = 1,
	VALLEY_DEPTH = 5,
	VALLEY_SIZE = 4,
	
	-- STRUCTURE_CHANCE is a per-block roll, so lower values thin out placement density.
	-- At 0.75 roughly 3 in 4 eligible tiles attempt a spawn, then further filtered by
	-- individual structure chance and distance checks below.
	STRUCTURE_CHANCE = 0.75,
	MIN_STRUCT_DIST = 1.5,   -- prevents two structures occupying the same tile visually
	STRUCT_MIN_SCALE = 0.8,
	STRUCT_MAX_SCALE = 3,
	
	-- edge cliffs
	EDGE_STONE_MIN = 5,
	EDGE_STONE_MAX = 15,
	EDGE_CHANCE = 1,
	-- EDGE_THRESHOLD defines where the "border zone" starts as a fraction of MAP_RADIUS.
	-- 0.92 means the outer 8% of the map radius is treated as edge — wide enough to form
	-- a solid wall of cliffs that hides the map boundary from players.
	EDGE_THRESHOLD = 0.92,
	
	-- defaults for structures without attributes
	DEFAULT_CHANCE = 10,
	DEFAULT_WEIGHT = 1,
	
	-- portal placement constraints
	UNIQUE_MIN_H = 8,
	UNIQUE_MAX_H = 15,
	UNIQUE_MIN_DIST = 10,
	UNIQUE_MAX_DIST = 30,
	
	-- how often the BFS loop yields to the scheduler; too low freezes the server,
	-- too high makes generation feel slow. 0.03s (~2 yields/frame) is the sweet spot.
	YIELD_INTERVAL = 0.03,
	DEBUG_MARKERS = true,
}


-- Noise generator using multiple octaves for more natural-looking terrain.
-- A single octave produces blobs that look artificial; layering 3 at different
-- frequencies and amplitudes mimics how real elevation data behaves at different scales.
local NoiseGenerator = {}
NoiseGenerator.__index = NoiseGenerator

export type NoiseGeneratorType = typeof(setmetatable({} :: {
	offsetX: number,
	offsetZ: number,
	octaveOffset1: number,
	octaveOffset2: number,
	octaveOffset3: number,
}, NoiseGenerator))

function NoiseGenerator.new(): NoiseGeneratorType
	local self = setmetatable({}, NoiseGenerator)
	
	-- Each instance needs a unique spatial offset so two generators with the same
	-- seed don't produce identical maps. 1e6 range makes accidental overlap
	-- practically impossible — 1e4 was tried first but caused visible repetition
	-- on large maps because Roblox's math.noise has a periodic domain.
	local offsetRange = 1e6
	
	self.offsetX = math.random() * offsetRange * 2 - offsetRange
	self.offsetZ = math.random() * offsetRange * 2 - offsetRange

	-- Each octave needs its own independent offset, otherwise octave 2 would just
	-- be a scaled version of octave 1 evaluated at the same seed location,
	-- which cancels out the detail we're trying to add.
	self.octaveOffset1 = math.random() * offsetRange * 2 - offsetRange
	self.octaveOffset2 = math.random() * offsetRange * 2 - offsetRange
	self.octaveOffset3 = math.random() * offsetRange * 2 - offsetRange
	
	return self
end

function NoiseGenerator.get(self: NoiseGeneratorType, x: number, z: number): number
	local noiseX = (x + self.offsetX) * CONFIG.NOISE_SCALE
	local noiseZ = (z + self.offsetZ) * CONFIG.NOISE_SCALE
	
	-- Octave 1 (weight 1.0): large-scale hills and valleys — the "shape" of the map.
	-- Octave 2 (weight 0.4): medium bumps that break up flat plateaus.
	-- Octave 3 (weight 0.2): fine surface roughness so nothing looks perfectly smooth.
	-- Weights halve each octave so coarser features dominate; flipping this would make
	-- terrain look jagged and unreadable from a gameplay perspective.
	local baseNoise    = math.noise(noiseX,       noiseZ,       self.octaveOffset1)
	local detailNoise1 = math.noise(noiseX * 2.5, noiseZ * 2.5, self.octaveOffset2) * 0.4
	local detailNoise2 = math.noise(noiseX * 5,   noiseZ * 5,   self.octaveOffset3) * 0.2
	
	-- Summing all three gives a value roughly in [-1, 1] before NOISE_STRENGTH scaling.
	-- NOISE_STRENGTH converts that normalized value into actual block height units.
	return (baseNoise + detailNoise1 + detailNoise2) * CONFIG.NOISE_STRENGTH
end


local TerrainFeatures = {}
TerrainFeatures.__index = TerrainFeatures

export type TerrainFeaturesType = typeof(setmetatable({} :: {
	mountains: {{x: number, z: number}},
	valleys: {{x: number, z: number}},
}, TerrainFeatures))

function TerrainFeatures.new(): TerrainFeaturesType
	local self = setmetatable({
		mountains = {},
		valleys = {},
	}, TerrainFeatures)
	return self
end

function TerrainFeatures.generate(self: TerrainFeaturesType)
	for index = 1, CONFIG.MOUNTAIN_COUNT do
		-- Dividing the full circle evenly by MOUNTAIN_COUNT guarantees mountains
		-- don't cluster. The small random offset breaks the perfect symmetry so
		-- a map with 4 mountains doesn't look like a compass rose.
		local angle    = (index - 1) * (2 * math.pi / CONFIG.MOUNTAIN_COUNT) + (math.random() - 0.5)
		local distance = CONFIG.MAP_RADIUS * (0.25 + math.random() * 0.4)
		
		local posX = math.floor(math.cos(angle) * distance)
		local posZ = math.floor(math.sin(angle) * distance)
		
		-- Squaring both sides avoids a sqrt call while still doing the correct
		-- radius comparison. Mountains outside the circular map boundary are
		-- discarded so they don't influence edge blocks that won't be generated.
		local radiusSquared = CONFIG.MAP_RADIUS * CONFIG.MAP_RADIUS
		if posX * posX + posZ * posZ <= radiusSquared then
			table.insert(self.mountains, {x = posX, z = posZ})
		end
	end
	
	for index = 1, CONFIG.VALLEY_COUNT do
		-- Offset by 0.5 step so valleys sit between mountains angularly,
		-- preventing a valley from spawning directly underneath a peak.
		local angle    = (index - 0.5) * (2 * math.pi / CONFIG.VALLEY_COUNT) + (math.random() - 0.5) * 0.5
		local distance = CONFIG.MAP_RADIUS * (0.3 + math.random() * 0.3)
		
		local posX = math.floor(math.cos(angle) * distance)
		local posZ = math.floor(math.sin(angle) * distance)
		
		if posX * posX + posZ * posZ <= CONFIG.MAP_RADIUS * CONFIG.MAP_RADIUS then
			table.insert(self.valleys, {x = posX, z = posZ})
		end
	end
end

function TerrainFeatures.getInfluence(self: TerrainFeaturesType, x: number, z: number): number
	local totalInfluence = 0
	
	for _, mountain in ipairs(self.mountains) do
		local distance = math.sqrt((x - mountain.x)^2 + (z - mountain.z)^2)
		if distance < CONFIG.MOUNTAIN_SIZE then
			local strength = 1 - distance / CONFIG.MOUNTAIN_SIZE  -- 1 at peak, 0 at edge
			-- Cubing the strength creates a sharp, narrow peak rather than a broad dome.
			-- strength^2 would be more dome-like; strength^1 (linear) would make the
			-- mountain look like a perfect cone — unrealistic and gameplay-unfriendly.
			totalInfluence = totalInfluence + strength * strength * strength * CONFIG.MOUNTAIN_HEIGHT
		end
	end
	
	for _, valley in ipairs(self.valleys) do
		local distance = math.sqrt((x - valley.x)^2 + (z - valley.z)^2)
		if distance < CONFIG.VALLEY_SIZE then
			local strength = 1 - distance / CONFIG.VALLEY_SIZE
			-- Quadratic (strength^2) for valleys gives steeper walls than a cubic would.
			-- This makes valleys feel like bowls rather than shallow depressions, which
			-- reads more clearly to players navigating the terrain. Note it subtracts —
			-- valleys pull height down while mountains push it up.
			totalInfluence = totalInfluence - strength * strength * CONFIG.VALLEY_DEPTH
		end
	end
	
	return totalInfluence
end


export type StructureData = {
	model: Model | BasePart,
	chance: number,
	minHeight: number,
	maxHeight: number,
	weight: number,
	name: string,
}

export type PlacedStructure = {
	x: number,
	z: number,
	name: string,
	scale: number,
	height: number,
	isEdge: boolean,
	isUnique: boolean?,
}


local StructureManager = {}
StructureManager.__index = StructureManager

export type StructureManagerType = typeof(setmetatable({} :: {
	folder: Folder?,
	portal: Model?,
	structuresByHeight: {[number]: {StructureData}},
	placedStructures: {PlacedStructure},
	portalSpots: {{x: number, z: number, height: number}},
	portalPlaced: boolean,
}, StructureManager))

function StructureManager.new(): StructureManagerType
	local self = setmetatable({
		folder = nil,
		portal = nil,
		structuresByHeight = {},
		placedStructures = {},
		portalSpots = {},
		portalPlaced = false,
	}, StructureManager)
	return self
end

function StructureManager.init(self: StructureManagerType)
	self.folder = ReplicatedStorage:FindFirstChild("RandomStructures")
	self.portal = ReplicatedStorage:FindFirstChild("Portal")
	
	if not self.folder then
		warn("no RandomStructures folder")
		return
	end
	
	-- task.wait() defers loading by one frame. Without it, models added to
	-- ReplicatedStorage in the same script execution cycle may not be fully
	-- replicated yet, causing GetChildren() to return an incomplete list.
	task.wait()
	self:_loadStructures()
end

function StructureManager._loadStructures(self: StructureManagerType)
	for _, object in pairs(self.folder:GetChildren()) do
		if not (object:IsA("Model") or object:IsA("BasePart")) then continue end
		
		local spawnChance = object:GetAttribute("SpawnChance") or CONFIG.DEFAULT_CHANCE
		local minHeight   = object:GetAttribute("MinHeight")   or CONFIG.MIN_HEIGHT
		local maxHeight   = object:GetAttribute("MaxHeight")   or CONFIG.MAX_HEIGHT
		local spawnWeight = object:GetAttribute("SpawnWeight") or CONFIG.DEFAULT_WEIGHT
		
		spawnChance = math.clamp(spawnChance, 0, 100)
		minHeight   = math.clamp(minHeight, CONFIG.MIN_HEIGHT, CONFIG.MAX_HEIGHT)
		maxHeight   = math.clamp(maxHeight, CONFIG.MIN_HEIGHT, CONFIG.MAX_HEIGHT)
		-- Swap if a designer accidentally set min > max so nothing silently fails.
		if minHeight > maxHeight then minHeight, maxHeight = maxHeight, minHeight end
		spawnWeight = math.max(spawnWeight, 0.1)  -- prevent zero-weight from breaking the roulette sum
		
		local structData: StructureData = {
			model    = object,
			chance   = spawnChance,
			minHeight = minHeight,
			maxHeight = maxHeight,
			weight   = spawnWeight,
			name     = object.Name,
		}
		
		-- Pre-indexing by every integer height the structure covers means tryPlace()
		-- does a single O(1) table lookup instead of iterating all structures and
		-- range-checking each one. This matters when structures are checked thousands
		-- of times during map generation.
		for height = minHeight, maxHeight do
			if not self.structuresByHeight[height] then
				self.structuresByHeight[height] = {}
			end
			table.insert(self.structuresByHeight[height], structData)
		end
	end
end

function StructureManager._pickWeighted(self: StructureManagerType, structureList: {StructureData}): StructureData?
	if #structureList == 0 then return nil end
	if #structureList == 1 then return structureList[1] end  -- skip math when there's no choice
	
	local totalWeight = 0
	for _, structData in ipairs(structureList) do
		totalWeight = totalWeight + structData.weight
	end
	
	-- Roulette wheel: pick a random point along the summed weight line,
	-- then walk through entries until we pass that point. Structures with
	-- higher weight occupy a larger segment and are therefore more likely to be hit.
	local randomValue   = math.random() * totalWeight
	local currentWeight = 0
	
	for _, structData in ipairs(structureList) do
		currentWeight = currentWeight + structData.weight
		if randomValue <= currentWeight then
			return structData
		end
	end
	
	-- Floating-point rounding can occasionally push randomValue just past the final
	-- entry's threshold, so return last as a safe fallback instead of returning nil.
	return structureList[#structureList]
end

function StructureManager._checkDistance(self: StructureManagerType, x: number, z: number, minDistance: number): boolean
	for _, placed in ipairs(self.placedStructures) do
		local distance = math.sqrt((x - placed.x)^2 + (z - placed.z)^2)
		-- Early return on the first violation — no need to check remaining structures
		-- once we know this spot is already too close to something.
		if distance < minDistance then
			return false
		end
	end
	return true
end

function StructureManager._scaleObject(self: StructureManagerType, object: Model | BasePart, scaleFactor: number)
	if object:IsA("BasePart") then
		object.Size     = object.Size * scaleFactor
		object.Anchored = true
	else
		-- GetBoundingBox() returns the pivot CFrame of the whole model, which we use
		-- as the scaling origin. Without this anchor point, each part would scale
		-- relative to the world origin (0,0,0) and the model would fly apart.
		local boundingCFrame, _ = object:GetBoundingBox()
		
		for _, descendant in pairs(object:GetDescendants()) do
			if descendant:IsA("BasePart") then
				descendant.Size = descendant.Size * scaleFactor
				-- Translate each part's position outward from the bounding center
				-- proportionally to scaleFactor so relative spacing is preserved.
				descendant.Position = boundingCFrame.Position + (descendant.Position - boundingCFrame.Position) * scaleFactor
				descendant.Anchored = true
				
				-- Meshes have their own internal Scale that is separate from Size.
				-- If we skip this, the mesh geometry won't match the resized collision box.
				local mesh = descendant:FindFirstChildOfClass("SpecialMesh") or descendant:FindFirstChildOfClass("BlockMesh")
				if mesh then
					mesh.Scale = mesh.Scale * scaleFactor
				end
			end
		end
	end
end

function StructureManager._placeAtPosition(self: StructureManagerType, object: Model | BasePart, worldX: number, worldZ: number, blockTopY: number)
	local halfHeight
	
	if object:IsA("BasePart") then
		halfHeight       = object.Size.Y / 2
		-- Adding halfHeight to blockTopY places the object's center exactly at surface level,
		-- so the bottom face sits flush with the top of the terrain block beneath it.
		object.Position  = Vector3.new(worldX, blockTopY + halfHeight, worldZ)
		object.CFrame    = object.CFrame * CFrame.Angles(0, math.rad(math.random(0, 360)), 0)
	else
		local _, size = object:GetBoundingBox()
		halfHeight = size.Y / 2
		-- PivotTo is called twice: first to position, then to rotate. Combining them into
		-- one CFrame would be cleaner but PivotTo resets the internal pivot offset, so
		-- splitting into two calls keeps the rotation applied around the correct center.
		object:PivotTo(CFrame.new(worldX, blockTopY + halfHeight, worldZ))
		object:PivotTo(object:GetPivot() * CFrame.Angles(0, math.rad(math.random(0, 360)), 0))
	end
end

function StructureManager.addPortalSpot(self: StructureManagerType, x: number, z: number, height: number)
	-- portalPlaced check avoids collecting candidates after we've already committed —
	-- the list would never be used and just wastes memory during generation.
	if self.portalPlaced or not self.portal then return end
	
	if height < CONFIG.UNIQUE_MIN_H or height > CONFIG.UNIQUE_MAX_H then return end
	
	local distanceFromCenter = math.sqrt(x * x + z * z)
	-- Min distance keeps the portal away from the spawn tile at center.
	-- Max distance keeps it reachable without crossing the entire map.
	if distanceFromCenter < CONFIG.UNIQUE_MIN_DIST or distanceFromCenter > CONFIG.UNIQUE_MAX_DIST then return end
	
	-- Double the normal minimum separation for portals so no structure ever
	-- visually overlaps with or blocks access to the portal entrance.
	if not self:_checkDistance(x, z, CONFIG.MIN_STRUCT_DIST * 2) then return end
	
	table.insert(self.portalSpots, {x = x, z = z, height = height})
end

function StructureManager.placePortal(self: StructureManagerType, mapFolder: Folder, blocks: {[string]: {height: number, block: BasePart | Model}})
	if self.portalPlaced or not self.portal or #self.portalSpots == 0 then return end
	
	-- Choosing randomly from all valid spots instead of the first valid one prevents
	-- the portal from always appearing in the same map quadrant, which would let
	-- players memorize its location across runs.
	local selectedSpot = self.portalSpots[math.random(#self.portalSpots)]
	local blockData    = blocks[selectedSpot.x .. "," .. selectedSpot.z]
	if not blockData then return end
	
	local clone  = self.portal:Clone()
	local worldX = selectedSpot.x * CONFIG.BLOCK_SIZE
	local worldZ = selectedSpot.z * CONFIG.BLOCK_SIZE
	
	local blockTopY
	if blockData.block:IsA("BasePart") then
		blockTopY = blockData.block.Position.Y + blockData.block.Size.Y / 2
	else
		local boundingCFrame, size = blockData.block:GetBoundingBox()
		blockTopY = boundingCFrame.Position.Y + size.Y / 2
	end
	
	self:_placeAtPosition(clone, worldX, worldZ, blockTopY)
	clone.Parent = mapFolder
	
	-- Set portalPlaced immediately after a successful placement so no subsequent
	-- addPortalSpot() calls can queue new candidates and no race condition can
	-- cause a second portal to be placed if placePortal() were ever called twice.
	self.portalPlaced = true
	table.insert(self.placedStructures, {
		x        = selectedSpot.x,
		z        = selectedSpot.z,
		name     = "Portal",
		scale    = 1,
		height   = selectedSpot.height,
		isEdge   = false,
		isUnique = true
	})
	
	print("portal placed at " .. selectedSpot.x .. "," .. selectedSpot.z)
end

function StructureManager.tryPlace(self: StructureManagerType, x: number, z: number, block: BasePart | Model, height: number, mapFolder: Folder)
	if not self.folder then return end
	
	local distanceFromCenter = math.sqrt(x * x + z * z)
	local isEdgeBlock = distanceFromCenter >= CONFIG.MAP_RADIUS * CONFIG.EDGE_THRESHOLD
	
	-- Edge blocks get cliffs instead of regular structures. Redirecting here keeps
	-- the caller simple — it always calls tryPlace() and the routing happens internally.
	if isEdgeBlock then
		self:_placeEdgeCliff(x, z, block, height, mapFolder)
		return
	end
	
	-- First gate: random per-block roll to control overall structure density.
	-- This runs before the expensive distance check so we skip it most of the time.
	if math.random() > CONFIG.STRUCTURE_CHANCE then return end
	
	if not self:_checkDistance(x, z, CONFIG.MIN_STRUCT_DIST) then return end
	
	local availableStructures = self.structuresByHeight[height]
	if not availableStructures or #availableStructures == 0 then return end
	
	-- Second gate: each structure has its own individual spawn chance on top of
	-- the global STRUCTURE_CHANCE roll. This lets designers make rare structures
	-- that appear infrequently even on tiles where they're technically eligible.
	local candidates = {}
	for _, structData in ipairs(availableStructures) do
		if math.random(1, 100) <= structData.chance then
			table.insert(candidates, structData)
		end
	end
	if #candidates == 0 then return end
	
	local selectedStructure = self:_pickWeighted(candidates)
	if not selectedStructure then return end
	
	local clone       = selectedStructure.model:Clone()
	local randomScale = CONFIG.STRUCT_MIN_SCALE + math.random() * (CONFIG.STRUCT_MAX_SCALE - CONFIG.STRUCT_MIN_SCALE)
	
	local worldX = x * CONFIG.BLOCK_SIZE
	local worldZ = z * CONFIG.BLOCK_SIZE
	
	local blockTopY
	if block:IsA("BasePart") then
		blockTopY = block.Position.Y + block.Size.Y / 2
	else
		local boundingCFrame, size = block:GetBoundingBox()
		blockTopY = boundingCFrame.Position.Y + size.Y / 2
	end
	
	self:_scaleObject(clone, randomScale)
	self:_placeAtPosition(clone, worldX, worldZ, blockTopY)
	clone.Parent = mapFolder
	
	table.insert(self.placedStructures, {
		x      = x,
		z      = z,
		name   = selectedStructure.name,
		scale  = randomScale,
		height = height,
		isEdge = false
	})
end

function StructureManager._placeEdgeCliff(self: StructureManagerType, x: number, z: number, block: BasePart | Model, height: number, mapFolder: Folder)
	if math.random() > CONFIG.EDGE_CHANCE then return end
	
	local cliffModel = self.folder:FindFirstChild("Clif")
	if not cliffModel then return end
	
	-- 1.5 block separation for cliffs is tighter than regular structures (MIN_STRUCT_DIST)
	-- because we want a near-continuous wall rather than scattered rocks with gaps.
	if not self:_checkDistance(x, z, 1.5) then return end
	
	local clone       = cliffModel:Clone()
	-- Cliff scale is measured in studs of height rather than a normalized multiplier,
	-- so the range here intentionally exceeds STRUCT_MAX_SCALE to create tall border walls.
	local randomScale = CONFIG.EDGE_STONE_MIN + math.random() * (CONFIG.EDGE_STONE_MAX - CONFIG.EDGE_STONE_MIN)
	
	local worldX = x * CONFIG.BLOCK_SIZE
	local worldZ = z * CONFIG.BLOCK_SIZE
	
	local blockTopY
	if block:IsA("BasePart") then
		blockTopY = block.Position.Y + block.Size.Y / 2
	else
		local boundingCFrame, size = block:GetBoundingBox()
		blockTopY = boundingCFrame.Position.Y + size.Y / 2
	end
	
	self:_scaleObject(clone, randomScale)
	self:_placeAtPosition(clone, worldX, worldZ, blockTopY)
	clone.Parent = mapFolder
	
	table.insert(self.placedStructures, {
		x      = x,
		z      = z,
		name   = "Clif",
		scale  = randomScale,
		height = height,
		isEdge = true
	})
end

function StructureManager.getStats(self: StructureManagerType): string
	local edgeCount, uniqueCount, regularCount = 0, 0, 0
	local countByName = {}
	
	for _, placed in ipairs(self.placedStructures) do
		if placed.isEdge then
			edgeCount = edgeCount + 1
		elseif placed.isUnique then
			uniqueCount = uniqueCount + 1
		else
			regularCount = regularCount + 1
			countByName[placed.name] = (countByName[placed.name] or 0) + 1
		end
	end
	
	local output = "Structures: " .. #self.placedStructures .. " total\n"
	output = output .. "  edge: " .. edgeCount .. ", unique: " .. uniqueCount .. ", regular: " .. regularCount
	
	for name, count in pairs(countByName) do
		output = output .. "\n  " .. name .. ": " .. count
	end
	
	return output
end


local MapGenerator = {}
MapGenerator.__index = MapGenerator

export type MapGeneratorType = typeof(setmetatable({} :: {
	noise: NoiseGeneratorType,
	terrain: TerrainFeaturesType,
	structures: StructureManagerType,
	groundsFolder: Folder?,
	mapFolder: Folder?,
	blocks: {[string]: {height: number, block: BasePart | Model}},
	heightStats: {[number]: number},
	blockCount: number,
}, MapGenerator))

function MapGenerator.new(): MapGeneratorType
	local self = setmetatable({
		noise      = NoiseGenerator.new(),
		terrain    = TerrainFeatures.new(),
		structures = StructureManager.new(),
		groundsFolder = nil :: Folder?,
		mapFolder     = nil :: Folder?,
		blocks      = {},
		heightStats = {},
		blockCount  = 0,
	}, MapGenerator)
	return self
end

function MapGenerator.init(self: MapGeneratorType)
	self.groundsFolder = ReplicatedStorage:WaitForChild("Grounds", 5)
	assert(self.groundsFolder, "Grounds folder not found!")
	
	local existingMap = workspace:FindFirstChild("GeneratedMap")
	if existingMap then
		-- Destroy the old map before generating a new one so leftover blocks from a
		-- previous run don't accumulate and inflate block counts or cause z-fighting.
		existingMap:Destroy()
	end
	
	self.mapFolder = Instance.new("Folder")
	self.mapFolder.Name = "GeneratedMap"
	self.mapFolder.Parent = workspace
	
	local foundBlocks = 0
	for height = 1, 20 do
		if self.groundsFolder:FindFirstChild("ground_" .. height) then
			foundBlocks = foundBlocks + 1
		end
	end
	print("found " .. foundBlocks .. " ground blocks")
	
	-- If the Grounds folder has fewer than 20 variants, shrink the height range to
	-- match so we never request a tile that doesn't exist and fall back constantly.
	if foundBlocks < 20 then
		CONFIG.MAX_HEIGHT   = foundBlocks
		CONFIG.START_HEIGHT = math.floor(foundBlocks / 2)
	end
	
	self.structures:init()
	self.terrain:generate()
	
	-- Reset state so init() can be called multiple times to regenerate the map
	-- without creating a new MapGenerator instance each time.
	self.blocks      = {}
	self.heightStats = {}
	self.blockCount  = 0
	
	for height = CONFIG.MIN_HEIGHT, CONFIG.MAX_HEIGHT do
		self.heightStats[height] = 0
	end
end

function MapGenerator._getGroundBlock(self: MapGeneratorType, height: number): (BasePart | Model)?
	height = math.clamp(height, CONFIG.MIN_HEIGHT, CONFIG.MAX_HEIGHT)
	
	local groundBlock = self.groundsFolder:FindFirstChild("ground_" .. height)
	if groundBlock then
		return groundBlock
	end
	
	-- Walk downward rather than upward: if ground_7 is missing, ground_6 is visually
	-- closer to the intended height than ground_8 would be, keeping terrain coherent.
	for fallbackHeight = height - 1, CONFIG.MIN_HEIGHT, -1 do
		groundBlock = self.groundsFolder:FindFirstChild("ground_" .. fallbackHeight)
		if groundBlock then
			return groundBlock
		end
	end
	
	return self.groundsFolder:FindFirstChild("ground_1")
end

function MapGenerator._isInBounds(self: MapGeneratorType, x: number, z: number): boolean
	-- Squared comparison avoids a sqrt, valid because both sides are positive and
	-- the relative ordering is preserved when squaring.
	return x * x + z * z <= CONFIG.MAP_RADIUS * CONFIG.MAP_RADIUS
end

function MapGenerator._getBlockHeight(self: MapGeneratorType, x: number, z: number): number?
	local blockData = self.blocks[x .. "," .. z]
	return blockData and blockData.height
end

function MapGenerator._calculateHeight(self: MapGeneratorType, x: number, z: number): number
	-- Center is pinned to START_HEIGHT so the terrain has a known, stable starting
	-- point. If we ran the noise formula here instead, every regeneration would start
	-- from a different height and the BFS propagation would drift unpredictably.
	if x == 0 and z == 0 then
		return CONFIG.START_HEIGHT
	end
	
	local neighborPositions = {{x - 1, z}, {x + 1, z}, {x, z - 1}, {x, z + 1}}
	local totalHeight, neighborCount = 0, 0
	local neighborHeights = {}
	
	for _, position in ipairs(neighborPositions) do
		local height = self:_getBlockHeight(position[1], position[2])
		if height then
			table.insert(neighborHeights, height)
			totalHeight = totalHeight + height
			neighborCount = neighborCount + 1
		end
	end
	
	-- BFS guarantees at least one neighbor is already placed when we reach any block,
	-- so neighborCount == 0 only for the center tile (handled above). The fallback
	-- is a safety net in case this function is ever called out of BFS order.
	if neighborCount == 0 then
		return CONFIG.START_HEIGHT
	end
	
	local averageHeight    = totalHeight / neighborCount
	local noiseValue       = self.noise:get(x, z)
	local terrainInfluence = self.terrain:getInfluence(x, z)
	
	-- SMOOTH_FACTOR blends purely-smoothed (averageHeight) against noise-influenced height.
	-- The right side of the blend adds noiseValue and terrainInfluence on top of the
	-- average — so even at SMOOTH_FACTOR = 0 the neighbor average is still the base,
	-- preventing completely disconnected spikes from appearing.
	local targetHeight = averageHeight * CONFIG.SMOOTH_FACTOR +
		(averageHeight + noiseValue + terrainInfluence) * (1 - CONFIG.SMOOTH_FACTOR)
	
	-- Tiny random jitter breaks up repeating patterns that emerge from the smooth blend,
	-- particularly on flat areas where noise contributes little variation.
	targetHeight = targetHeight + (math.random() - 0.5) * 1.2
	
	-- Linear dropoff past 75% radius: the further toward the edge, the stronger the
	-- pull downward. This avoids an abrupt cliff at the map boundary that would look
	-- artificial and block the player's view of the surrounding cliffs.
	local normalizedDistance = math.sqrt(x * x + z * z) / CONFIG.MAP_RADIUS
	if normalizedDistance > 0.75 then
		targetHeight = targetHeight - (normalizedDistance - 0.75) * 8
	end
	
	local finalHeight = math.floor(targetHeight + 0.5)  -- round to nearest integer block
	
	-- Clamp height diff against every neighbor, not just the average. If one neighbor
	-- is significantly lower, the average could still pass the check while the actual
	-- step to that neighbor exceeds MAX_HEIGHT_DIFF, creating an unclimbable ledge.
	for _, neighborHeight in ipairs(neighborHeights) do
		if math.abs(finalHeight - neighborHeight) > CONFIG.MAX_HEIGHT_DIFF then
			local direction = finalHeight > neighborHeight and 1 or -1
			finalHeight = neighborHeight + direction * CONFIG.MAX_HEIGHT_DIFF
		end
	end
	
	return math.clamp(finalHeight, CONFIG.MIN_HEIGHT, CONFIG.MAX_HEIGHT)
end

function MapGenerator._placeBlock(self: MapGeneratorType, x: number, z: number, height: number)
	local template = self:_getGroundBlock(height)
	if not template then return end
	
	local clone  = template:Clone()
	local worldX = x * CONFIG.BLOCK_SIZE
	local worldZ = z * CONFIG.BLOCK_SIZE
	local worldY
	
	if clone:IsA("BasePart") then
		worldY          = clone.Size.Y / 2   -- place so bottom face sits at Y = 0
		clone.Position  = Vector3.new(worldX, worldY, worldZ)
		clone.Anchored  = true
	else
		-- GetBoundingBox can error on empty or malformed models, so wrap it.
		-- If it fails we skip the block rather than erroring out mid-generation.
		local success, size = pcall(function()
			local _, boundingSize = clone:GetBoundingBox()
			return boundingSize
		end)
		
		if not success or not size then
			clone:Destroy()
			return
		end
		
		worldY = size.Y / 2
		clone:PivotTo(CFrame.new(worldX, worldY, worldZ))
		
		for _, part in pairs(clone:GetDescendants()) do
			if part:IsA("BasePart") then
				part.Anchored = true
			end
		end
	end
	
	clone.Parent = self.mapFolder
	
	-- Store by grid key (not world position) because all neighbor lookups use grid
	-- coordinates. Converting to world coords every lookup would add unnecessary math.
	self.blocks[x .. "," .. z] = {height = height, block = clone}
	self.heightStats[height]   = self.heightStats[height] + 1
	self.blockCount             = self.blockCount + 1
	
	-- Portal spots must be collected during placement (not after) because we need the
	-- block reference to calculate blockTopY when the portal is actually placed later.
	self.structures:addPortalSpot(x, z, height)
	self.structures:tryPlace(x, z, clone, height, self.mapFolder)
end

function MapGenerator.generate(self: MapGeneratorType)
	print("generating map...")
	local startTime    = os.clock()
	local lastYieldTime = startTime
	local lastLogCount  = 0
	
	-- BFS from center ensures every block's neighbors are already placed when we
	-- calculate its height. A spiral or random order would leave gaps where
	-- _calculateHeight() falls back to START_HEIGHT, producing visible seams.
	local queue      = {{0, 0}}
	local visited    = {["0,0"] = true}
	local queueIndex = 1  -- index pointer avoids table.remove() which is O(n)
	
	while queueIndex <= #queue do
		local currentPos = queue[queueIndex]
		queueIndex       = queueIndex + 1
		
		local currentX, currentZ = currentPos[1], currentPos[2]
		
		if self:_isInBounds(currentX, currentZ) then
			local height = self:_calculateHeight(currentX, currentZ)
			self:_placeBlock(currentX, currentZ, height)
			
			if self.blockCount - lastLogCount >= 1000 then
				lastLogCount = self.blockCount
				print(self.blockCount .. " blocks...")
			end
			
			-- Yielding on a time delta rather than every N blocks keeps frame time
			-- consistent regardless of how expensive _placeBlock() happens to be on
			-- any given tile (e.g., tiles with structures take longer).
			if os.clock() - lastYieldTime > CONFIG.YIELD_INTERVAL then
				RunService.Heartbeat:Wait()
				lastYieldTime = os.clock()
			end
			
			local neighborOffsets = {{-1, 0}, {1, 0}, {0, -1}, {0, 1}}
			for _, offset in ipairs(neighborOffsets) do
				local neighborX = currentX + offset[1]
				local neighborZ = currentZ + offset[2]
				local key       = neighborX .. "," .. neighborZ
				
				-- visited check prevents the same tile from being enqueued multiple
				-- times when two already-processed neighbors both point to it, which
				-- would cause duplicate blocks stacked on top of each other.
				if not visited[key] and self:_isInBounds(neighborX, neighborZ) then
					visited[key] = true
					table.insert(queue, {neighborX, neighborZ})
				end
			end
		end
	end
	
	-- Portal is placed after all terrain blocks exist so _checkDistance() has the full
	-- structure list and blockTopY calculations can query any block in self.blocks.
	self.structures:placePortal(self.mapFolder, self.blocks)
	
	local elapsedTime = os.clock() - startTime
	print(string.format("done! %d blocks in %.1fs", self.blockCount, elapsedTime))
	
	local lowestHeight, highestHeight = CONFIG.MAX_HEIGHT, CONFIG.MIN_HEIGHT
	for height = CONFIG.MIN_HEIGHT, CONFIG.MAX_HEIGHT do
		if self.heightStats[height] > 0 then
			lowestHeight  = math.min(lowestHeight, height)
			highestHeight = math.max(highestHeight, height)
		end
	end
	print("heights: " .. lowestHeight .. "-" .. highestHeight)
	print(self.structures:getStats())
	
	self:_createSpawnLocation()
	self:_addDebugMarkers()
end

function MapGenerator._createSpawnLocation(self: MapGeneratorType)
	local spawnLocation = Instance.new("SpawnLocation")
	-- Y = 150 places the spawn well above the tallest possible terrain (MAX_HEIGHT * BLOCK_SIZE)
	-- so players aren't spawned inside blocks if generation is still running when they join.
	spawnLocation.Position = Vector3.new(0, 150, 0)
	spawnLocation.Size     = Vector3.new(15, 1, 15)
	spawnLocation.Anchored = true
	spawnLocation.Material   = Enum.Material.Neon
	spawnLocation.BrickColor = BrickColor.new("Lime green")
	spawnLocation.Parent     = workspace
end

function MapGenerator._addDebugMarkers(self: MapGeneratorType)
	if not CONFIG.DEBUG_MARKERS then return end
	
	for index, mountain in ipairs(self.terrain.mountains) do
		local marker = Instance.new("Part")
		marker.Name        = "Mountain" .. index
		-- Tall narrow pillar makes the marker visible from any camera angle without
		-- covering a wide area that would obscure the terrain underneath it.
		marker.Size        = Vector3.new(20, 200, 20)
		marker.Position    = Vector3.new(mountain.x * CONFIG.BLOCK_SIZE, 100, mountain.z * CONFIG.BLOCK_SIZE)
		marker.BrickColor  = BrickColor.new("Brown")
		marker.Material    = Enum.Material.Rock
		marker.Transparency = 0.5  -- semi-transparent so terrain is still visible beneath it
		marker.CanCollide  = false  -- markers are visual only; solid would block player movement
		marker.Anchored    = true
		marker.Parent      = self.mapFolder
	end
	
	for index, valley in ipairs(self.terrain.valleys) do
		local marker = Instance.new("Part")
		marker.Name        = "Valley" .. index
		marker.Size        = Vector3.new(25, 25, 25)
		marker.Position    = Vector3.new(valley.x * CONFIG.BLOCK_SIZE, 15, valley.z * CONFIG.BLOCK_SIZE)
		marker.BrickColor  = BrickColor.new("Deep blue")
		marker.Material    = Enum.Material.ForceField
		marker.Transparency = 0.4
		marker.CanCollide  = false
		marker.Anchored    = true
		marker.Parent      = self.mapFolder
	end
end


-- Seed rng with a time-based value so maps differ between server starts.
-- The loop discards the first 10 values because Lua's LCG can produce a predictable
-- low-entropy sequence for the first few calls after seeding.
math.randomseed(os.clock() * 1000)
for _ = 1, 10 do
	math.random()
end

local generator = MapGenerator.new()
generator:init()
generator:generate()
