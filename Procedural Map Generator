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
	
	-- terrain generation params - tweaked these a lot to get good results
	SMOOTH_FACTOR = 0.6,     -- higher = smoother terrain, lower = more noise influence
	NOISE_SCALE = 0.1,
	NOISE_STRENGTH = 5,
	MAX_HEIGHT_DIFF = 1,     -- keeps terrain walkable
	
	-- mountains/valleys
	MOUNTAIN_COUNT = 1,
	MOUNTAIN_HEIGHT = 7,
	MOUNTAIN_SIZE = 12,      -- in blocks not studs
	VALLEY_COUNT = 1,
	VALLEY_DEPTH = 5,
	VALLEY_SIZE = 4,
	
	-- structure spawning
	STRUCTURE_CHANCE = 0.75,
	MIN_STRUCT_DIST = 1.5,   -- so they dont overlap
	STRUCT_MIN_SCALE = 0.8,
	STRUCT_MAX_SCALE = 3,
	
	-- edge cliffs
	EDGE_STONE_MIN = 5,
	EDGE_STONE_MAX = 15,
	EDGE_CHANCE = 1,
	EDGE_THRESHOLD = 0.92,   -- how close to edge = "edge"
	
	-- defaults for structures without attributes
	DEFAULT_CHANCE = 10,
	DEFAULT_WEIGHT = 1,
	
	-- portal placement constraints
	UNIQUE_MIN_H = 8,
	UNIQUE_MAX_H = 15,
	UNIQUE_MIN_DIST = 10,
	UNIQUE_MAX_DIST = 30,
	
	-- perf
	YIELD_INTERVAL = 0.03,
	DEBUG_MARKERS = true,
}


-- noise generator with multiple octaves for more natural looking terrain
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
	
	-- offset range needs to be large enough that we dont get similar patterns
	-- even with different seeds. 1e6 works fine, tried 1e4 first but got
	-- noticeable repetition on big maps
	local offsetRange = 1e6
	
	self.offsetX = math.random() * offsetRange * 2 - offsetRange
	self.offsetZ = math.random() * offsetRange * 2 - offsetRange
	self.octaveOffset1 = math.random() * offsetRange * 2 - offsetRange
	self.octaveOffset2 = math.random() * offsetRange * 2 - offsetRange
	self.octaveOffset3 = math.random() * offsetRange * 2 - offsetRange
	
	return self
end

-- returns combined noise value at position, uses 3 octaves for detail
function NoiseGenerator.get(self: NoiseGeneratorType, x: number, z: number): number
	local noiseX = (x + self.offsetX) * CONFIG.NOISE_SCALE
	local noiseZ = (z + self.offsetZ) * CONFIG.NOISE_SCALE
	
	-- layered octaves: base + medium detail + fine detail
	-- weights tuned to avoid overly spiky terrain
	local baseNoise = math.noise(noiseX, noiseZ, self.octaveOffset1)
	local detailNoise1 = math.noise(noiseX * 2.5, noiseZ * 2.5, self.octaveOffset2) * 0.4
	local detailNoise2 = math.noise(noiseX * 5, noiseZ * 5, self.octaveOffset3) * 0.2
	
	return (baseNoise + detailNoise1 + detailNoise2) * CONFIG.NOISE_STRENGTH
end


-- handles mountain/valley positions and their height influence
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

-- places mountains and valleys around the map
-- uses angular distribution so they spread out evenly
function TerrainFeatures.generate(self: TerrainFeaturesType)
	for index = 1, CONFIG.MOUNTAIN_COUNT do
		-- spread mountains evenly around center with some randomness
		local angle = (index - 1) * (2 * math.pi / CONFIG.MOUNTAIN_COUNT) + (math.random() - 0.5)
		local distance = CONFIG.MAP_RADIUS * (0.25 + math.random() * 0.4)
		
		local posX = math.floor(math.cos(angle) * distance)
		local posZ = math.floor(math.sin(angle) * distance)
		
		-- squared comparison avoids sqrt
		local radiusSquared = CONFIG.MAP_RADIUS * CONFIG.MAP_RADIUS
		if posX * posX + posZ * posZ <= radiusSquared then
			table.insert(self.mountains, {x = posX, z = posZ})
		end
	end
	
	-- valleys offset from mountains so they dont overlap
	for index = 1, CONFIG.VALLEY_COUNT do
		local angle = (index - 0.5) * (2 * math.pi / CONFIG.VALLEY_COUNT) + (math.random() - 0.5) * 0.5
		local distance = CONFIG.MAP_RADIUS * (0.3 + math.random() * 0.3)
		
		local posX = math.floor(math.cos(angle) * distance)
		local posZ = math.floor(math.sin(angle) * distance)
		
		if posX * posX + posZ * posZ <= CONFIG.MAP_RADIUS * CONFIG.MAP_RADIUS then
			table.insert(self.valleys, {x = posX, z = posZ})
		end
	end
end

-- calculates how much mountains/valleys affect height at this position
function TerrainFeatures.getInfluence(self: TerrainFeaturesType, x: number, z: number): number
	local totalInfluence = 0
	
	for _, mountain in ipairs(self.mountains) do
		local distance = math.sqrt((x - mountain.x)^2 + (z - mountain.z)^2)
		if distance < CONFIG.MOUNTAIN_SIZE then
			local strength = 1 - distance / CONFIG.MOUNTAIN_SIZE
			-- cubic falloff gives smoother peaks than linear or quadratic
			totalInfluence = totalInfluence + strength * strength * strength * CONFIG.MOUNTAIN_HEIGHT
		end
	end
	
	-- valleys use quadratic - sharper edges look better for low areas
	for _, valley in ipairs(self.valleys) do
		local distance = math.sqrt((x - valley.x)^2 + (z - valley.z)^2)
		if distance < CONFIG.VALLEY_SIZE then
			local strength = 1 - distance / CONFIG.VALLEY_SIZE
			totalInfluence = totalInfluence - strength * strength * CONFIG.VALLEY_DEPTH
		end
	end
	
	return totalInfluence
end


-- structure types
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


-- handles all structure loading and placement
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
	
	-- wait a frame before loading, some models werent fully replicated
	task.wait()
	self:_loadStructures()
end

-- loads structures and indexes them by height for fast lookup
function StructureManager._loadStructures(self: StructureManagerType)
	for _, object in pairs(self.folder:GetChildren()) do
		if not (object:IsA("Model") or object:IsA("BasePart")) then continue end
		
		-- read spawn params from attributes
		local spawnChance = object:GetAttribute("SpawnChance") or CONFIG.DEFAULT_CHANCE
		local minHeight = object:GetAttribute("MinHeight") or CONFIG.MIN_HEIGHT
		local maxHeight = object:GetAttribute("MaxHeight") or CONFIG.MAX_HEIGHT
		local spawnWeight = object:GetAttribute("SpawnWeight") or CONFIG.DEFAULT_WEIGHT
		
		-- clamp and validate
		-- TODO: maybe add validation warnings for bad attribute values
		spawnChance = math.clamp(spawnChance, 0, 100)
		minHeight = math.clamp(minHeight, CONFIG.MIN_HEIGHT, CONFIG.MAX_HEIGHT)
		maxHeight = math.clamp(maxHeight, CONFIG.MIN_HEIGHT, CONFIG.MAX_HEIGHT)
		if minHeight > maxHeight then minHeight, maxHeight = maxHeight, minHeight end
		spawnWeight = math.max(spawnWeight, 0.1)
		
		local structData: StructureData = {
			model = object,
			chance = spawnChance,
			minHeight = minHeight,
			maxHeight = maxHeight,
			weight = spawnWeight,
			name = object.Name,
		}
		
		-- index by every height it can spawn at
		-- tried using range checks at spawn time but this lookup is faster
		for height = minHeight, maxHeight do
			if not self.structuresByHeight[height] then
				self.structuresByHeight[height] = {}
			end
			table.insert(self.structuresByHeight[height], structData)
		end
	end
end

-- weighted random selection - higher weight = more likely to pick
function StructureManager._pickWeighted(self: StructureManagerType, structureList: {StructureData}): StructureData?
	if #structureList == 0 then return nil end
	if #structureList == 1 then return structureList[1] end
	
	local totalWeight = 0
	for _, structData in ipairs(structureList) do
		totalWeight = totalWeight + structData.weight
	end
	
	-- roulette wheel selection
	local randomValue = math.random() * totalWeight
	local currentWeight = 0
	
	for _, structData in ipairs(structureList) do
		currentWeight = currentWeight + structData.weight
		if randomValue <= currentWeight then
			return structData
		end
	end
	
	return structureList[#structureList] -- shouldnt hit this but just in case
end

-- checks if position is far enough from existing structures
function StructureManager._checkDistance(self: StructureManagerType, x: number, z: number, minDistance: number): boolean
	for _, placed in ipairs(self.placedStructures) do
		local distance = math.sqrt((x - placed.x)^2 + (z - placed.z)^2)
		if distance < minDistance then
			return false
		end
	end
	return true
end

-- scales a part or model, handles meshes too
function StructureManager._scaleObject(self: StructureManagerType, object: Model | BasePart, scaleFactor: number)
	if object:IsA("BasePart") then
		object.Size = object.Size * scaleFactor
		object.Anchored = true
	else
		local boundingCFrame, _ = object:GetBoundingBox()
		
		for _, descendant in pairs(object:GetDescendants()) do
			if descendant:IsA("BasePart") then
				descendant.Size = descendant.Size * scaleFactor
				descendant.Position = boundingCFrame.Position + (descendant.Position - boundingCFrame.Position) * scaleFactor
				descendant.Anchored = true
				
				local mesh = descendant:FindFirstChildOfClass("SpecialMesh") or descendant:FindFirstChildOfClass("BlockMesh")
				if mesh then
					mesh.Scale = mesh.Scale * scaleFactor
				end
			end
		end
	end
end

-- places object on top of block with random rotation
function StructureManager._placeAtPosition(self: StructureManagerType, object: Model | BasePart, worldX: number, worldZ: number, blockTopY: number)
	local halfHeight
	
	if object:IsA("BasePart") then
		halfHeight = object.Size.Y / 2
		object.Position = Vector3.new(worldX, blockTopY + halfHeight, worldZ)
		object.CFrame = object.CFrame * CFrame.Angles(0, math.rad(math.random(0, 360)), 0)
	else
		local _, size = object:GetBoundingBox()
		halfHeight = size.Y / 2
		object:PivotTo(CFrame.new(worldX, blockTopY + halfHeight, worldZ))
		object:PivotTo(object:GetPivot() * CFrame.Angles(0, math.rad(math.random(0, 360)), 0))
	end
end

-- records a spot where portal could spawn
function StructureManager.addPortalSpot(self: StructureManagerType, x: number, z: number, height: number)
	if self.portalPlaced or not self.portal then return end
	
	-- portal needs specific height range
	if height < CONFIG.UNIQUE_MIN_H or height > CONFIG.UNIQUE_MAX_H then return end
	
	-- and specific distance from center
	local distanceFromCenter = math.sqrt(x * x + z * z)
	if distanceFromCenter < CONFIG.UNIQUE_MIN_DIST or distanceFromCenter > CONFIG.UNIQUE_MAX_DIST then return end
	
	if not self:_checkDistance(x, z, CONFIG.MIN_STRUCT_DIST * 2) then return end
	
	table.insert(self.portalSpots, {x = x, z = z, height = height})
end

-- picks random valid spot and places portal there
function StructureManager.placePortal(self: StructureManagerType, mapFolder: Folder, blocks: {[string]: {height: number, block: BasePart | Model}})
	if self.portalPlaced or not self.portal or #self.portalSpots == 0 then return end
	
	local selectedSpot = self.portalSpots[math.random(#self.portalSpots)]
	local blockData = blocks[selectedSpot.x .. "," .. selectedSpot.z]
	if not blockData then return end
	
	local clone = self.portal:Clone()
	local worldX = selectedSpot.x * CONFIG.BLOCK_SIZE
	local worldZ = selectedSpot.z * CONFIG.BLOCK_SIZE
	
	-- find top of block
	local blockTopY
	if blockData.block:IsA("BasePart") then
		blockTopY = blockData.block.Position.Y + blockData.block.Size.Y / 2
	else
		local boundingCFrame, size = blockData.block:GetBoundingBox()
		blockTopY = boundingCFrame.Position.Y + size.Y / 2
	end
	
	self:_placeAtPosition(clone, worldX, worldZ, blockTopY)
	clone.Parent = mapFolder
	
	self.portalPlaced = true
	table.insert(self.placedStructures, {
		x = selectedSpot.x,
		z = selectedSpot.z,
		name = "Portal",
		scale = 1,
		height = selectedSpot.height,
		isEdge = false,
		isUnique = true
	})
	
	print("portal placed at " .. selectedSpot.x .. "," .. selectedSpot.z)
end

-- tries to place a structure at this position
function StructureManager.tryPlace(self: StructureManagerType, x: number, z: number, block: BasePart | Model, height: number, mapFolder: Folder)
	if not self.folder then return end
	
	-- check if this is an edge block
	local distanceFromCenter = math.sqrt(x * x + z * z)
	local isEdgeBlock = distanceFromCenter >= CONFIG.MAP_RADIUS * CONFIG.EDGE_THRESHOLD
	
	if isEdgeBlock then
		self:_placeEdgeCliff(x, z, block, height, mapFolder)
		return
	end
	
	-- random chance to spawn
	if math.random() > CONFIG.STRUCTURE_CHANCE then return end
	
	-- dont place too close to other structures
	if not self:_checkDistance(x, z, CONFIG.MIN_STRUCT_DIST) then return end
	
	-- get structures that can spawn at this height
	local availableStructures = self.structuresByHeight[height]
	if not availableStructures or #availableStructures == 0 then return end
	
	-- filter by individual spawn chance
	local candidates = {}
	for _, structData in ipairs(availableStructures) do
		if math.random(1, 100) <= structData.chance then
			table.insert(candidates, structData)
		end
	end
	if #candidates == 0 then return end
	
	local selectedStructure = self:_pickWeighted(candidates)
	if not selectedStructure then return end
	
	-- clone and place with random scale
	local clone = selectedStructure.model:Clone()
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
		x = x,
		z = z,
		name = selectedStructure.name,
		scale = randomScale,
		height = height,
		isEdge = false
	})
end

-- places cliff at map edge
function StructureManager._placeEdgeCliff(self: StructureManagerType, x: number, z: number, block: BasePart | Model, height: number, mapFolder: Folder)
	if math.random() > CONFIG.EDGE_CHANCE then return end
	
	local cliffModel = self.folder:FindFirstChild("Clif")
	if not cliffModel then return end
	
	if not self:_checkDistance(x, z, 1.5) then return end
	
	local clone = cliffModel:Clone()
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
		x = x,
		z = z,
		name = "Clif",
		scale = randomScale,
		height = height,
		isEdge = true
	})
end

-- returns stats string for logging
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


-- main map generator class
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
		noise = NoiseGenerator.new(),
		terrain = TerrainFeatures.new(),
		structures = StructureManager.new(),
		groundsFolder = nil :: Folder?,
		mapFolder = nil :: Folder?,
		blocks = {},
		heightStats = {},
		blockCount = 0,
	}, MapGenerator)
	return self
end

function MapGenerator.init(self: MapGeneratorType)
	self.groundsFolder = ReplicatedStorage:WaitForChild("Grounds", 5)
	assert(self.groundsFolder, "Grounds folder not found!")
	
	-- cleanup old map if exists
	local existingMap = workspace:FindFirstChild("GeneratedMap")
	if existingMap then
		existingMap:Destroy()
	end
	
	self.mapFolder = Instance.new("Folder")
	self.mapFolder.Name = "GeneratedMap"
	self.mapFolder.Parent = workspace
	
	-- count available ground blocks
	local foundBlocks = 0
	for height = 1, 20 do
		if self.groundsFolder:FindFirstChild("ground_" .. height) then
			foundBlocks = foundBlocks + 1
		end
	end
	print("found " .. foundBlocks .. " ground blocks")
	
	-- adjust limits if we have fewer blocks
	if foundBlocks < 20 then
		CONFIG.MAX_HEIGHT = foundBlocks
		CONFIG.START_HEIGHT = math.floor(foundBlocks / 2)
	end
	
	self.structures:init()
	self.terrain:generate()
	
	self.blocks = {}
	self.heightStats = {}
	self.blockCount = 0
	
	for height = CONFIG.MIN_HEIGHT, CONFIG.MAX_HEIGHT do
		self.heightStats[height] = 0
	end
end

-- gets ground template for height, falls back to lower if not found
function MapGenerator._getGroundBlock(self: MapGeneratorType, height: number): (BasePart | Model)?
	height = math.clamp(height, CONFIG.MIN_HEIGHT, CONFIG.MAX_HEIGHT)
	
	local groundBlock = self.groundsFolder:FindFirstChild("ground_" .. height)
	if groundBlock then
		return groundBlock
	end
	
	-- fallback to lower heights
	for fallbackHeight = height - 1, CONFIG.MIN_HEIGHT, -1 do
		groundBlock = self.groundsFolder:FindFirstChild("ground_" .. fallbackHeight)
		if groundBlock then
			return groundBlock
		end
	end
	
	return self.groundsFolder:FindFirstChild("ground_1")
end

function MapGenerator._isInBounds(self: MapGeneratorType, x: number, z: number): boolean
	return x * x + z * z <= CONFIG.MAP_RADIUS * CONFIG.MAP_RADIUS
end

function MapGenerator._getBlockHeight(self: MapGeneratorType, x: number, z: number): number?
	local blockData = self.blocks[x .. "," .. z]
	return blockData and blockData.height
end

-- calculates height based on neighbors, noise, and terrain features
function MapGenerator._calculateHeight(self: MapGeneratorType, x: number, z: number): number
	-- center starts at configured height
	if x == 0 and z == 0 then
		return CONFIG.START_HEIGHT
	end
	
	-- get neighbor heights
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
	
	if neighborCount == 0 then
		return CONFIG.START_HEIGHT
	end
	
	local averageHeight = totalHeight / neighborCount
	local noiseValue = self.noise:get(x, z)
	local terrainInfluence = self.terrain:getInfluence(x, z)
	
	-- blend neighbor average with noise
	-- higher smooth factor = more neighbor influence = smoother terrain
	local targetHeight = averageHeight * CONFIG.SMOOTH_FACTOR + 
		(averageHeight + noiseValue + terrainInfluence) * (1 - CONFIG.SMOOTH_FACTOR)
	
	-- small random variation
	targetHeight = targetHeight + (math.random() - 0.5) * 1.2
	
	-- gradual dropoff near edge so map doesnt end abruptly
	local normalizedDistance = math.sqrt(x * x + z * z) / CONFIG.MAP_RADIUS
	if normalizedDistance > 0.75 then
		targetHeight = targetHeight - (normalizedDistance - 0.75) * 8
	end
	
	local finalHeight = math.floor(targetHeight + 0.5)
	
	-- enforce max height diff from neighbors so terrain stays walkable
	for _, neighborHeight in ipairs(neighborHeights) do
		if math.abs(finalHeight - neighborHeight) > CONFIG.MAX_HEIGHT_DIFF then
			local direction = finalHeight > neighborHeight and 1 or -1
			finalHeight = neighborHeight + direction * CONFIG.MAX_HEIGHT_DIFF
		end
	end
	
	return math.clamp(finalHeight, CONFIG.MIN_HEIGHT, CONFIG.MAX_HEIGHT)
end

-- places a ground block and tries to spawn structures on it
function MapGenerator._placeBlock(self: MapGeneratorType, x: number, z: number, height: number)
	local template = self:_getGroundBlock(height)
	if not template then return end
	
	local clone = template:Clone()
	local worldX = x * CONFIG.BLOCK_SIZE
	local worldZ = z * CONFIG.BLOCK_SIZE
	local worldY
	
	if clone:IsA("BasePart") then
		worldY = clone.Size.Y / 2
		clone.Position = Vector3.new(worldX, worldY, worldZ)
		clone.Anchored = true
	else
		-- GetBoundingBox can error on empty models, wrap it
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
	
	self.blocks[x .. "," .. z] = {height = height, block = clone}
	self.heightStats[height] = self.heightStats[height] + 1
	self.blockCount = self.blockCount + 1
	
	self.structures:addPortalSpot(x, z, height)
	self.structures:tryPlace(x, z, clone, height, self.mapFolder)
end

-- generates entire map using BFS from center
-- BFS ensures we always have neighbor heights when calculating new blocks
function MapGenerator.generate(self: MapGeneratorType)
	print("generating map...")
	local startTime = os.clock()
	local lastYieldTime = startTime
	local lastLogCount = 0
	
	-- BFS from center guarantees neighbors exist when we calc height
	-- tried spiral pattern first but had edge artifacts
	local queue = {{0, 0}}
	local visited = {["0,0"] = true}
	local queueIndex = 1
	
	while queueIndex <= #queue do
		local currentPos = queue[queueIndex]
		queueIndex = queueIndex + 1
		
		local currentX, currentZ = currentPos[1], currentPos[2]
		
		if self:_isInBounds(currentX, currentZ) then
			local height = self:_calculateHeight(currentX, currentZ)
			self:_placeBlock(currentX, currentZ, height)
			
			-- log progress
			if self.blockCount - lastLogCount >= 1000 then
				lastLogCount = self.blockCount
				print(self.blockCount .. " blocks...")
			end
			
			-- yield so game doesnt freeze
			if os.clock() - lastYieldTime > CONFIG.YIELD_INTERVAL then
				RunService.Heartbeat:Wait()
				lastYieldTime = os.clock()
			end
			
			-- add neighbors to queue
			local neighborOffsets = {{-1, 0}, {1, 0}, {0, -1}, {0, 1}}
			for _, offset in ipairs(neighborOffsets) do
				local neighborX = currentX + offset[1]
				local neighborZ = currentZ + offset[2]
				local key = neighborX .. "," .. neighborZ
				
				if not visited[key] and self:_isInBounds(neighborX, neighborZ) then
					visited[key] = true
					table.insert(queue, {neighborX, neighborZ})
				end
			end
		end
	end
	
	-- place portal after terrain done
	self.structures:placePortal(self.mapFolder, self.blocks)
	
	local elapsedTime = os.clock() - startTime
	print(string.format("done! %d blocks in %.1fs", self.blockCount, elapsedTime))
	
	-- log height range
	local lowestHeight, highestHeight = CONFIG.MAX_HEIGHT, CONFIG.MIN_HEIGHT
	for height = CONFIG.MIN_HEIGHT, CONFIG.MAX_HEIGHT do
		if self.heightStats[height] > 0 then
			lowestHeight = math.min(lowestHeight, height)
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
	spawnLocation.Position = Vector3.new(0, 150, 0)
	spawnLocation.Size = Vector3.new(15, 1, 15)
	spawnLocation.Anchored = true
	spawnLocation.Material = Enum.Material.Neon
	spawnLocation.BrickColor = BrickColor.new("Lime green")
	spawnLocation.Parent = workspace
end

-- adds debug markers for mountains/valleys, can disable in config
function MapGenerator._addDebugMarkers(self: MapGeneratorType)
	if not CONFIG.DEBUG_MARKERS then return end
	
	for index, mountain in ipairs(self.terrain.mountains) do
		local marker = Instance.new("Part")
		marker.Name = "Mountain" .. index
		marker.Size = Vector3.new(20, 200, 20)
		marker.Position = Vector3.new(mountain.x * CONFIG.BLOCK_SIZE, 100, mountain.z * CONFIG.BLOCK_SIZE)
		marker.BrickColor = BrickColor.new("Brown")
		marker.Material = Enum.Material.Rock
		marker.Transparency = 0.5
		marker.CanCollide = false
		marker.Anchored = true
		marker.Parent = self.mapFolder
	end
	
	for index, valley in ipairs(self.terrain.valleys) do
		local marker = Instance.new("Part")
		marker.Name = "Valley" .. index
		marker.Size = Vector3.new(25, 25, 25)
		marker.Position = Vector3.new(valley.x * CONFIG.BLOCK_SIZE, 15, valley.z * CONFIG.BLOCK_SIZE)
		marker.BrickColor = BrickColor.new("Deep blue")
		marker.Material = Enum.Material.ForceField
		marker.Transparency = 0.4
		marker.CanCollide = false
		marker.Anchored = true
		marker.Parent = self.mapFolder
	end
end


-- init rng
math.randomseed(os.clock() * 1000)
-- first few random() calls can be predictable on some systems
for _ = 1, 10 do
	math.random()
end

-- run
local generator = MapGenerator.new()
generator:init()
generator:generate()
