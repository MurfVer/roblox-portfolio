--[[
	BIRD COMBAT SYSTEM v3.3
	handles morphing, attacks, abilities, teams
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Debris = game:GetService("Debris")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local AnalyticsService = game:GetService("AnalyticsService")

Players.RespawnTime = 5

local SPAWN_PROTECTION = {
	FIRST_SPAWN_DURATION = 5,
	RESPAWN_DURATION = 10,
	STUN_DURATION = 2,
}

local SOUNDS = {
	TAKEOFF = "rbxassetid://77406134298919",
	ATTACK = "rbxassetid://87017429876204",
	HIT = "rbxassetid://85950177437755",
	DEATH = "rbxassetid://126363611774095",
	ICICLE_HIT = "rbxassetid://98429772907900",
}

_G.FreeForAllActive = false
_G.CurrentGameMode = nil

local PlayerFirstKill = {}

local function logFunnelStep(player, step, stepName)
	pcall(function()
		AnalyticsService:LogOnboardingFunnelStepEvent(player, step, stepName)
	end)
end

-- 3d sound at player pos, uses linear rolloff so it fades with distance
local function playWorldSound(character, soundId, volume, maxDistance)
	if not character then return end
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then return end

	local sound = Instance.new("Sound")
	sound.SoundId = soundId
	sound.Volume = volume or 1
	sound.RollOffMode = Enum.RollOffMode.Linear
	sound.RollOffMinDistance = 10
	sound.RollOffMaxDistance = maxDistance or 100
	sound.Parent = rootPart
	sound:Play()

	Debris:AddItem(sound, 10)
end

-- remote events setup
local BirdRemotes = Instance.new("Folder")
BirdRemotes.Name = "BirdRemotes"
BirdRemotes.Parent = ReplicatedStorage

local SelectBird = Instance.new("RemoteEvent")
SelectBird.Name = "SelectBird"
SelectBird.Parent = BirdRemotes

local Attack = Instance.new("RemoteEvent")
Attack.Name = "Attack"
Attack.Parent = BirdRemotes

local UseAbility = Instance.new("RemoteEvent")
UseAbility.Name = "UseAbility"
UseAbility.Parent = BirdRemotes

local TakeDamage = Instance.new("RemoteEvent")
TakeDamage.Name = "TakeDamage"
TakeDamage.Parent = BirdRemotes

local Stunned = Instance.new("RemoteEvent")
Stunned.Name = "Stunned"
Stunned.Parent = BirdRemotes

local Slowed = Instance.new("RemoteEvent")
Slowed.Name = "Slowed"
Slowed.Parent = BirdRemotes

local Heal = Instance.new("RemoteEvent")
Heal.Name = "Heal"
Heal.Parent = BirdRemotes

local SpawnShield = Instance.new("RemoteEvent")
SpawnShield.Name = "SpawnShield"
SpawnShield.Parent = BirdRemotes

local Invulnerable = Instance.new("RemoteEvent")
Invulnerable.Name = "Invulnerable"
Invulnerable.Parent = BirdRemotes

local PlaySound = Instance.new("RemoteEvent")
PlaySound.Name = "PlaySound"
PlaySound.Parent = BirdRemotes

local SetInvisible = Instance.new("RemoteEvent")
SetInvisible.Name = "SetInvisible"
SetInvisible.Parent = BirdRemotes

local ForceReveal = Instance.new("RemoteEvent")
ForceReveal.Name = "ForceReveal"
ForceReveal.Parent = BirdRemotes

local InvisibilityChanged = Instance.new("RemoteEvent")
InvisibilityChanged.Name = "InvisibilityChanged"
InvisibilityChanged.Parent = BirdRemotes

local SpawnVFX = Instance.new("RemoteEvent")
SpawnVFX.Name = "SpawnVFX"
SpawnVFX.Parent = BirdRemotes

local HealingZoneEffect = Instance.new("RemoteEvent")
HealingZoneEffect.Name = "HealingZoneEffect"
HealingZoneEffect.Parent = BirdRemotes

PlaySound.OnServerEvent:Connect(function(player, soundType)
	local char = player.Character
	if not char then return end

	local soundId = SOUNDS[soundType]
	if not soundId then return end

	local volume = 1
	local maxDist = 100

	if soundType == "TAKEOFF" then
		volume = 0.8
		maxDist = 80
	elseif soundType == "ATTACK" then
		volume = 0.7
		maxDist = 60
	end

	playWorldSound(char, soundId, volume, maxDist)
end)

local EggRemotes = nil
task.spawn(function()
	EggRemotes = ReplicatedStorage:WaitForChild("EggGameRemotes", 10)
end)

-- bird configs, each has different stats and attack style
local BIRD_TYPES = {
	PIGEON = {
		name = "Pigeon",
		MAX_HP = 100,
		DAMAGE = 20,
		ATTACK_RANGE = 30,
		ATTACK_TYPE = "WING", -- cone aoe
		ATTACK_ANGLE = 160,
		ABILITY_DAMAGE = 25,
		ABILITY_SLOW_DURATION = 4,
		ABILITY_SLOW_PERCENT = 0.6,
		HP_REGEN = 2,
	},

	HUMMINGBIRD = {
		name = "Hummingbird",
		MAX_HP = 80,
		DAMAGE = 18,
		ATTACK_RANGE = 30,
		ATTACK_TYPE = "STING", -- single target closest
		ATTACK_ANGLE = 120,
		ABILITY_DAMAGE = 25,
		ABILITY_DASH_DISTANCE = 50,
		HP_REGEN = 3,
	},

	KIWI = {
		name = "Kiwi",
		MAX_HP = 200,
		DAMAGE = 20,
		ATTACK_RANGE = 40,
		ATTACK_TYPE = "RAM", -- dash forward hit
		ATTACK_DASH = 50,
		ATTACK_KNOCKBACK = 35,
		ABILITY_DAMAGE = 30,
		ABILITY_STUN_DURATION = 2.5,
		ABILITY_RADIUS = 35,
		HP_REGEN = 8,
	},

	PENGUIN = {
		name = "Penguin",
		MAX_HP = 120,
		DAMAGE = 18,
		ATTACK_TYPE = "SLIDE", -- aoe around self
		SLIDE_SPEED = 80,
		ABILITY_DAMAGE = 35,
		ABILITY_FREEZE_DURATION = 3,
		ABILITY_ICICLE_SPEED = 150,
		HP_REGEN = 3,
		CAN_FLY = false, -- penguins cant fly lol
	},

	CROW = {
		name = "Crow",
		MAX_HP = 90,
		DAMAGE = 25,
		ATTACK_RANGE = 30,
		ATTACK_TYPE = "PECK", -- single + backstab
		ATTACK_ANGLE = 160,
		ABILITY_DURATION = 3,
		BACKSTAB_BONUS = 0.5, -- 50% extra when invis
		HP_REGEN = 3,
	},

	FLAMINGO = {
		name = "Flamingo",
		MAX_HP = 95,
		DAMAGE = 14,
		ATTACK_RANGE = 30,
		ATTACK_TYPE = "BEAK",
		ATTACK_ANGLE = 160,
		ABILITY_HEAL_PER_SEC = 6,
		ABILITY_SLOW_PERCENT = 0.3,
		ABILITY_RADIUS = 20,
		ABILITY_DURATION = 5,
		HP_REGEN = 4,
	},
}

local BIRD_MODELS = {
	PIGEON = nil,
	HUMMINGBIRD = nil,
	KIWI = nil,
	PENGUIN = nil,
	CROW = nil,
	FLAMINGO = nil,
}

-- cframe offsets for each bird model, tweaked these to look right on character
local BIRD_OFFSETS = {
	PIGEON = CFrame.new(0, 0, 0) * CFrame.Angles(0, math.rad(-90), 0),
	HUMMINGBIRD = CFrame.new(0, -2, 0) * CFrame.Angles(0, math.rad(-90), 0),
	KIWI = CFrame.new(0, -1, 0) * CFrame.Angles(0, math.rad(-90), 0),
	PENGUIN = CFrame.new(0, 1, 0) * CFrame.Angles(0, math.rad(-90), 0),
	CROW = CFrame.new(0, 0, 0) * CFrame.Angles(0, math.rad(-90), 0),
	FLAMINGO = CFrame.new(0, 0, 0) * CFrame.Angles(0, math.rad(-90), 0),
}

local function loadBirdModels()
	local success, err = pcall(function()
		BIRD_MODELS.PIGEON = ServerStorage:WaitForChild("Pigeon", 5)
		BIRD_MODELS.HUMMINGBIRD = ServerStorage:WaitForChild("Hummingbird", 5)
		BIRD_MODELS.KIWI = ServerStorage:WaitForChild("Kiwi", 5)
		BIRD_MODELS.PENGUIN = ServerStorage:WaitForChild("Penguin", 5)
		BIRD_MODELS.CROW = ServerStorage:WaitForChild("Crow", 5)
		BIRD_MODELS.FLAMINGO = ServerStorage:WaitForChild("Flamingo", 5)
	end)

	if not success then
		warn("BirdMorph: Failed to load models -", err)
	end
end

local HiddenCharacters = {}

-- parts we dont hide (bird model, effects, etc)
local IGNORE_PARTS = {
	["HumanoidRootPart"] = true,
	["BirdMorph"] = true,
	["CarriedEgg"] = true,
	["ShieldVisual"] = true,
	["DivineAura"] = true,
	["StunStarsEffect"] = true,
	["SlowIceEffect"] = true,
	["FreezeEffect"] = true,
}

local function shouldIgnorePart(descendant)
	if IGNORE_PARTS[descendant.Name] then
		return true
	end

	if descendant:FindFirstAncestor("BirdMorph") then
		return true
	end

	if descendant:IsA("BillboardGui") or descendant:FindFirstAncestorOfClass("BillboardGui") then
		return true
	end

	if descendant.Name:find("Effect") or descendant.Name:find("Visual") or descendant.Name:find("Aura") then
		return true
	end

	return false
end

-- make player model invisible so only bird shows
local function enforceCharacterHidden(character)
	if not character then return end

	for _, descendant in ipairs(character:GetDescendants()) do
		if descendant:IsA("BasePart") and not shouldIgnorePart(descendant) then
			if descendant.Transparency ~= 1 then
				descendant.Transparency = 1
			end
		end

		if descendant:IsA("Decal") and not shouldIgnorePart(descendant) then
			if descendant.Transparency ~= 1 then
				descendant.Transparency = 1
			end
		end
	end

	-- remove hats too
	for _, child in ipairs(character:GetChildren()) do
		if child:IsA("Accessory") then
			child:Destroy()
		end
	end
end

local function startHidingCharacter(player, character)
	if not character then return end

	HiddenCharacters[player] = true
	enforceCharacterHidden(character)

	-- catch new parts that spawn
	character.DescendantAdded:Connect(function(descendant)
		if not HiddenCharacters[player] then return end
		task.wait()

		if descendant:IsA("BasePart") and not shouldIgnorePart(descendant) then
			descendant.Transparency = 1
		elseif descendant:IsA("Decal") and not shouldIgnorePart(descendant) then
			descendant.Transparency = 1
		elseif descendant:IsA("Accessory") then
			descendant:Destroy()
		end
	end)

	-- keep parts hidden if something changes them
	for _, descendant in ipairs(character:GetDescendants()) do
		if descendant:IsA("BasePart") and not shouldIgnorePart(descendant) then
			descendant:GetPropertyChangedSignal("Transparency"):Connect(function()
				if HiddenCharacters[player] and descendant.Transparency ~= 1 then
					if not shouldIgnorePart(descendant) then
						descendant.Transparency = 1
					end
				end
			end)
		end
	end
end

local function removeBirdMorph(character)
	if not character then return end
	local existing = character:FindFirstChild("BirdMorph")
	if existing then
		existing:Destroy()
	end
end

-- weld bird model to player hrp
local function applyBirdMorph(player, birdType)
	local character = player.Character
	if not character then return end

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then return end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then return end

	removeBirdMorph(character)

	local template = BIRD_MODELS[birdType]
	if not template then 
		warn("BirdMorph: No template for", birdType)
		return 
	end

	enforceCharacterHidden(character)

	local morph = template:Clone()
	morph.Name = "BirdMorph"

	local meshPart = morph:FindFirstChildWhichIsA("MeshPart") or morph:FindFirstChildWhichIsA("BasePart")
	if not meshPart then
		warn("BirdMorph: No MeshPart found in", birdType)
		morph:Destroy()
		return
	end

	-- make massless so doesnt affect physics
	meshPart.Anchored = false
	meshPart.CanCollide = false
	meshPart.Massless = true
	meshPart.CanQuery = false

	for _, part in ipairs(morph:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Anchored = false
			part.CanCollide = false
			part.Massless = true
			part.CanQuery = false
		end
	end

	morph.Parent = character

	local offset = BIRD_OFFSETS[birdType] or CFrame.new(0, 0, 0)

	-- weld with offset
	local weld = Instance.new("Weld")
	weld.Name = "BirdMorphWeld"
	weld.Part0 = rootPart
	weld.Part1 = meshPart
	weld.C0 = offset
	weld.Parent = meshPart

	meshPart.CFrame = rootPart.CFrame * offset
	morph:SetAttribute("BirdType", birdType)
end

local function updateMorphVisibility(player, visible)
	local character = player.Character
	if not character then return end

	local morph = character:FindFirstChild("BirdMorph")
	if not morph then return end

	local targetTransparency = visible and 0 or 1

	for _, part in ipairs(morph:GetDescendants()) do
		if part:IsA("BasePart") then
			TweenService:Create(part, TweenInfo.new(0.3), {
				Transparency = targetTransparency
			}):Play()
		end
	end
end

-- vfx templates
local BirdVFX = ReplicatedStorage:WaitForChild("BirdVFX", 5)
local PenguinVFX = BirdVFX and BirdVFX:WaitForChild("Penguin", 5)
local FlamingoVFX = BirdVFX and BirdVFX:WaitForChild("Flamingo", 5)

local SERVER_VFX = {
	Penguin = {
		Icicle = PenguinVFX and PenguinVFX:FindFirstChild("Icicle"),
		FreezeBlock = PenguinVFX and PenguinVFX:FindFirstChild("FreezeBlock"),
		IceShard = PenguinVFX and PenguinVFX:FindFirstChild("IceShard"),
	},
	Flamingo = {
		HealingPond = FlamingoVFX and FlamingoVFX:FindFirstChild("HealingPond"),
		WingSlap = FlamingoVFX and FlamingoVFX:FindFirstChild("WingSlap"),
	}
}

-- player state tracking
local PlayerData = {}
local StunnedPlayers = {}
local SlowedPlayers = {}

local function getPlayerData(player)
	if not PlayerData[player] then
		PlayerData[player] = {
			birdType = "PIGEON",
			hp = BIRD_TYPES.PIGEON.MAX_HP,
			lastAttack = 0,
			lastAbility = 0,
			lastDamageTime = 0,
			isDead = false,
			isInvincible = false,
			isInvisible = false,
			invisibleUntil = 0,
			team = nil,
			inGame = false,
			combatEnabled = false,
			hasSpawnProtection = false,
			spawnProtectionEndTime = 0,
			hasSelectedBird = false,
			lastDeathTime = 0,
		}
	end
	return PlayerData[player]
end

-- returns config with newbie hp bonus applied if needed
local function getBirdConfig(player)
	local data = getPlayerData(player)
	local baseConfig = BIRD_TYPES[data.birdType] or BIRD_TYPES.PIGEON

	local hpMultiplier = 1
	if _G.GetNewbieHPMultiplier then
		hpMultiplier = _G.GetNewbieHPMultiplier(player)
	end

	if hpMultiplier > 1 then
		return {
			name = baseConfig.name,
			MAX_HP = math.floor(baseConfig.MAX_HP * hpMultiplier),
			DAMAGE = baseConfig.DAMAGE,
			ATTACK_RANGE = baseConfig.ATTACK_RANGE,
			ATTACK_TYPE = baseConfig.ATTACK_TYPE,
			ATTACK_ANGLE = baseConfig.ATTACK_ANGLE,
			ATTACK_DASH = baseConfig.ATTACK_DASH,
			ATTACK_KNOCKBACK = baseConfig.ATTACK_KNOCKBACK,
			ABILITY_DAMAGE = baseConfig.ABILITY_DAMAGE,
			ABILITY_SLOW_DURATION = baseConfig.ABILITY_SLOW_DURATION,
			ABILITY_SLOW_PERCENT = baseConfig.ABILITY_SLOW_PERCENT,
			ABILITY_DASH_DISTANCE = baseConfig.ABILITY_DASH_DISTANCE,
			ABILITY_STUN_DURATION = baseConfig.ABILITY_STUN_DURATION,
			ABILITY_RADIUS = baseConfig.ABILITY_RADIUS,
			ABILITY_FREEZE_DURATION = baseConfig.ABILITY_FREEZE_DURATION,
			ABILITY_ICICLE_SPEED = baseConfig.ABILITY_ICICLE_SPEED,
			HP_REGEN = baseConfig.HP_REGEN,
			CAN_FLY = baseConfig.CAN_FLY,
			SLIDE_SPEED = baseConfig.SLIDE_SPEED,
		}
	end

	return baseConfig
end

_G.ResyncPlayerHP = function(player)
	local char = player.Character
	if not char then return end

	local humanoid = char:FindFirstChildOfClass("Humanoid")
	if not humanoid then return end

	local data = PlayerData[player]
	if not data then return end

	local config = getBirdConfig(player)
	if not config then return end

	local newMaxHP = config.MAX_HP
	local healthPercent = humanoid.MaxHealth > 0 and (humanoid.Health / humanoid.MaxHealth) or 1

	humanoid.MaxHealth = newMaxHP
	humanoid.Health = newMaxHP * healthPercent
	data.hp = humanoid.Health
end

local function getPlayerTeam(player)
	local data = getPlayerData(player)
	return data.team
end

local function giveSpawnProtection(player, duration)
	local data = getPlayerData(player)
	if not data then return end

	local char = player.Character
	if not char then return end

	local humanoid = char:FindFirstChildOfClass("Humanoid")
	if not humanoid then return end

	data.isInvincible = true
	data.hasSpawnProtection = true
	data.spawnProtectionEndTime = tick() + duration

	SpawnShield:FireClient(player, duration)
	if _G.SetPlayerInvulnerableStatus then
		_G.SetPlayerInvulnerableStatus(player, true)
	end

	task.delay(duration, function()
		if PlayerData[player] and PlayerData[player].hasSpawnProtection then
			PlayerData[player].isInvincible = false
			PlayerData[player].hasSpawnProtection = false
			PlayerData[player].spawnProtectionEndTime = 0
			if _G.SetPlayerInvulnerableStatus then
				_G.SetPlayerInvulnerableStatus(player, false)
			end
		end
	end)
end

_G.GiveSpawnProtection = giveSpawnProtection

local function canPlayerAttack(player)
	local data = getPlayerData(player)
	if not data then return false end
	if not data.inGame then return false end
	if not data.combatEnabled then return false end
	if data.isDead then return false end
	return true
end

local function canPlayerTakeDamage(player)
	local data = getPlayerData(player)
	if not data then return false end
	if not data.inGame then return false end
	if not data.combatEnabled then return false end
	if data.isDead then return false end

	local char = player.Character
	if not char then return false end

	local humanoid = char:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then return false end

	-- check spawn protection timer
	if data.spawnProtectionEndTime and data.spawnProtectionEndTime > 0 then
		if tick() < data.spawnProtectionEndTime then
			return false
		else
			-- expired, clear it
			data.isInvincible = false
			data.hasSpawnProtection = false
			data.spawnProtectionEndTime = 0
			if _G.SetPlayerInvulnerableStatus then
				_G.SetPlayerInvulnerableStatus(player, false)
			end
		end
	end

	if data.isInvincible and not data.hasSpawnProtection then
		return false
	end

	return true
end

local function isPlayerInLobby(player)
	local data = PlayerData[player]

	if data then
		if not data.inGame then return true end
		if not data.combatEnabled then return true end
	end

	if _G.IsPlayerInLobby then
		return _G.IsPlayerInLobby(player)
	end

	return false
end

-- check if players are on opposite teams
local function areEnemies(player1, player2)
	if player1 == player2 then return false end

	local gamePhase = "lobby"
	if _G.GetGamePhase then
		gamePhase = _G.GetGamePhase()
	end
	if gamePhase ~= "playing" then return false end

	local data1 = PlayerData[player1]
	local data2 = PlayerData[player2]

	if data1 and not data1.combatEnabled then return false end
	if data2 and not data2.combatEnabled then return false end

	if isPlayerInLobby(player1) or isPlayerInLobby(player2) then
		return false
	end

	-- ffa mode everyone fights
	if _G.FreeForAllActive == true then return true end
	if _G.CurrentGameMode == "FREE_FOR_ALL" then return true end
	if _G.GetCurrentGameMode then
		local mode = _G.GetCurrentGameMode()
		if mode == "FREE_FOR_ALL" then return true end
	end

	-- team check
	local team1 = getPlayerTeam(player1)
	local team2 = getPlayerTeam(player2)

	-- try different team sources
	if not team1 and _G.GetPlayerKOTHTeam then
		team1 = _G.GetPlayerKOTHTeam(player1)
	end
	if not team2 and _G.GetPlayerKOTHTeam then
		team2 = _G.GetPlayerKOTHTeam(player2)
	end

	if not team1 and _G.GetPlayerEggTeam then
		team1 = _G.GetPlayerEggTeam(player1)
	end
	if not team2 and _G.GetPlayerEggTeam then
		team2 = _G.GetPlayerEggTeam(player2)
	end

	if not team1 and player1.Team then
		team1 = player1.Team.Name
	end
	if not team2 and player2.Team then
		team2 = player2.Team.Name
	end

	if not team1 and not team2 then return false end
	if not team1 or not team2 then return false end

	return team1 ~= team2
end

local function syncHpToHumanoid(player)
	local data = PlayerData[player]
	if not data then return end

	local char = player.Character
	if not char then return end

	local humanoid = char:FindFirstChildOfClass("Humanoid")
	if not humanoid then return end

	local config = getBirdConfig(player)

	humanoid.MaxHealth = config.MAX_HP
	humanoid.Health = data.hp
end

-- break invisibility when attacked/damaged
local function forceRevealPlayer(player, reason)
	local data = PlayerData[player]
	if not data then return end

	if data.isInvisible then
		data.isInvisible = false
		data.invisibleUntil = 0

		updateMorphVisibility(player, true)

		if _G.SetBillboardVisible then
			_G.SetBillboardVisible(player, true)
		end

		ForceReveal:FireClient(player, reason)
		InvisibilityChanged:FireAllClients(player, false)
	end
end

-- crow invis toggle from client
SetInvisible.OnServerEvent:Connect(function(player, invisible)
	local data = getPlayerData(player)

	if data.birdType ~= "CROW" then return end

	data.isInvisible = invisible
	if invisible then
		data.invisibleUntil = tick() + BIRD_TYPES.CROW.ABILITY_DURATION
		updateMorphVisibility(player, false)
	else
		data.invisibleUntil = 0
		updateMorphVisibility(player, true)
	end

	if _G.SetBillboardVisible then
		_G.SetBillboardVisible(player, not invisible)
	end

	InvisibilityChanged:FireAllClients(player, invisible)
end)

_G.IsPlayerInvisible = function(player)
	local data = PlayerData[player]
	if not data then return false end
	if not data.isInvisible then return false end
	if tick() > data.invisibleUntil then
		data.isInvisible = false
		return false
	end
	return true
end

-- stun locks movement, shows stars vfx
local function stunPlayer(player, duration)
	local char = player.Character
	if not char then return end

	local humanoid = char:FindFirstChildOfClass("Humanoid")
	if not humanoid then return end

	local data = PlayerData[player]
	if data then
		if data.isInvincible or data.hasSpawnProtection then return end
		if data.spawnProtectionEndTime and tick() < data.spawnProtectionEndTime then return end
		if data.isDead then return end
	end

	local currentTime = tick()
	
	-- dont override longer stun
	if StunnedPlayers[player] and StunnedPlayers[player] > currentTime then
		local remainingStun = StunnedPlayers[player] - currentTime
		if duration <= remainingStun then return end
	end

	local stunData = SlowedPlayers[player]
	local originalSpeed = 16
	local originalJump = 50

	if stunData and stunData.originalSpeed then
		originalSpeed = stunData.originalSpeed
		originalJump = stunData.originalJump or 50
	else
		originalSpeed = humanoid.WalkSpeed
		originalJump = humanoid.JumpPower
		if originalSpeed == 0 then originalSpeed = 16 end
	end

	humanoid.WalkSpeed = 0
	humanoid.JumpPower = 0

	StunnedPlayers[player] = currentTime + duration
	if _G.SetPlayerStunned then
		_G.SetPlayerStunned(player, true)
	end

	Stunned:FireClient(player, duration)

	if data and data.isInvisible then
		forceRevealPlayer(player, "stunned")
	end

	-- stars effect above head
	local rootPart = char:FindFirstChild("HumanoidRootPart")
	if rootPart then
		local oldEffect = char:FindFirstChild("StunStarsEffect")
		if oldEffect then oldEffect:Destroy() end

		local stunEffect = Instance.new("Part")
		stunEffect.Name = "StunStarsEffect"
		stunEffect.Size = Vector3.new(1, 1, 1)
		stunEffect.Transparency = 1
		stunEffect.Anchored = false
		stunEffect.CanCollide = false
		stunEffect.CanQuery = false
		stunEffect.Massless = true
		stunEffect.Parent = char

		local weld = Instance.new("Weld")
		weld.Part0 = rootPart
		weld.Part1 = stunEffect
		weld.C0 = CFrame.new(0, 4, 0)
		weld.Parent = stunEffect

		local particles = Instance.new("ParticleEmitter")
		particles.Color = ColorSequence.new(Color3.fromRGB(255, 255, 100))
		particles.Size = NumberSequence.new(0.5, 0.2)
		particles.Lifetime = NumberRange.new(0.3, 0.5)
		particles.Rate = 20
		particles.Speed = NumberRange.new(2, 4)
		particles.SpreadAngle = Vector2.new(360, 360)
		particles.Shape = Enum.ParticleEmitterShape.Sphere
		particles.Parent = stunEffect

		Debris:AddItem(stunEffect, duration)
	end

	task.delay(duration, function()
		if StunnedPlayers[player] and tick() >= StunnedPlayers[player] then
			StunnedPlayers[player] = nil
			if _G.SetPlayerStunned then
				_G.SetPlayerStunned(player, false)
			end

			if humanoid and humanoid.Parent then
				local slowData = SlowedPlayers[player]
				if slowData and slowData.endTime > tick() then
					humanoid.WalkSpeed = slowData.slowedSpeed or (originalSpeed * 0.5)
					humanoid.JumpPower = originalJump
				else
					humanoid.WalkSpeed = originalSpeed
					humanoid.JumpPower = originalJump
					SlowedPlayers[player] = nil
					if _G.SetPlayerSlowed then
						_G.SetPlayerSlowed(player, false)
					end
				end
			end
		end
	end)
end

local function slowPlayer(player, duration, slowPercent)
	local char = player.Character
	if not char then return end

	local humanoid = char:FindFirstChildOfClass("Humanoid")
	if not humanoid then return end

	local data = PlayerData[player]
	if data then
		if data.isInvincible or data.hasSpawnProtection then return end
		if data.spawnProtectionEndTime and tick() < data.spawnProtectionEndTime then return end
		if data.isDead then return end
	end

	slowPercent = slowPercent or 0.5
	local currentTime = tick()

	local originalSpeed = 16
	local originalJump = 50

	local existingData = SlowedPlayers[player]
	if existingData and existingData.originalSpeed then
		originalSpeed = existingData.originalSpeed
		originalJump = existingData.originalJump or 50
	else
		originalSpeed = humanoid.WalkSpeed
		originalJump = humanoid.JumpPower
		if originalSpeed == 0 then originalSpeed = 16 end
	end

	local slowedSpeed = originalSpeed * (1 - slowPercent)

	SlowedPlayers[player] = {
		endTime = currentTime + duration,
		originalSpeed = originalSpeed,
		originalJump = originalJump,
		slowedSpeed = slowedSpeed,
	}

	if _G.SetPlayerSlowed then
		_G.SetPlayerSlowed(player, true)
	end

	-- only apply if not stunned
	if not StunnedPlayers[player] or StunnedPlayers[player] <= currentTime then
		humanoid.WalkSpeed = slowedSpeed
	end

	-- also slow flight if flying
	if _G.SetFlightSlow then
		_G.SetFlightSlow(player, slowPercent, duration, "Combat")
	end

	Slowed:FireClient(player, duration)

	local rootPart = char:FindFirstChild("HumanoidRootPart")
	if rootPart then
		local oldEffect = char:FindFirstChild("SlowIceEffect")
		if oldEffect then oldEffect:Destroy() end

		local slowEffect = Instance.new("Part")
		slowEffect.Name = "SlowIceEffect"
		slowEffect.Size = Vector3.new(1, 1, 1)
		slowEffect.Transparency = 1
		slowEffect.Anchored = false
		slowEffect.CanCollide = false
		slowEffect.CanQuery = false
		slowEffect.Massless = true
		slowEffect.Parent = char

		local weld = Instance.new("Weld")
		weld.Part0 = rootPart
		weld.Part1 = slowEffect
		weld.C0 = CFrame.new(0, -2, 0)
		weld.Parent = slowEffect

		local particles = Instance.new("ParticleEmitter")
		particles.Color = ColorSequence.new(Color3.fromRGB(150, 200, 255))
		particles.Size = NumberSequence.new(0.3, 0.1)
		particles.Lifetime = NumberRange.new(0.5, 1)
		particles.Rate = 15
		particles.Speed = NumberRange.new(1, 2)
		particles.SpreadAngle = Vector2.new(180, 180)
		particles.Parent = slowEffect

		Debris:AddItem(slowEffect, duration)
	end

	task.delay(duration, function()
		local slowData = SlowedPlayers[player]
		if slowData and tick() >= slowData.endTime then
			SlowedPlayers[player] = nil
			if _G.SetPlayerSlowed then
				_G.SetPlayerSlowed(player, false)
			end

			if humanoid and humanoid.Parent then
				if not StunnedPlayers[player] or StunnedPlayers[player] <= tick() then
					humanoid.WalkSpeed = originalSpeed
				end
			end
		end
	end)
end

_G.StunPlayer = stunPlayer
_G.SlowPlayer = slowPlayer

_G.HealPlayerHP = function(player, amount)
	local data = PlayerData[player]
	if not data then return 0 end
	if data.isDead then return 0 end

	local config = getBirdConfig(player)
	local oldHP = data.hp
	data.hp = math.min(data.hp + amount, config.MAX_HP)
	local actualHeal = data.hp - oldHP

	syncHpToHumanoid(player)

	if actualHeal > 0 then
		Heal:FireClient(player, actualHeal)
	end

	return actualHeal
end

-- also hit decoy clones
local function checkAndDamageClones(attacker, position, radius, damage)
	for _, obj in ipairs(workspace:GetChildren()) do
		if obj.Name:find("_DecoyClone") and obj:IsA("Model") then
			local cloneRoot = obj:FindFirstChild("HumanoidRootPart")
			local cloneHumanoid = obj:FindFirstChildOfClass("Humanoid")

			if cloneRoot and cloneHumanoid and cloneHumanoid.Health > 0 then
				local distance = (cloneRoot.Position - position).Magnitude
				if distance <= radius then
					cloneHumanoid:TakeDamage(damage)
				end
			end
		end
	end
end

-- main damage function, handles shields/buffs/death
local function dealDamage(attacker, victim, damage)
	if not canPlayerAttack(attacker) then
		return false
	end

	if not canPlayerTakeDamage(victim) then
		return false
	end

	if not areEnemies(attacker, victim) then
		return false
	end

	local victimData = getPlayerData(victim)
	if victimData.isDead then return false end
	if victimData.isInvincible then return false end

	if _G.IsPlayerInvulnerable and _G.IsPlayerInvulnerable(victim) then
		return false
	end

	local actualDamage = damage

	-- newbie bonus
	if _G.GetNewbieDamageMultiplier then
		local damageMultiplier = _G.GetNewbieDamageMultiplier(attacker)
		if damageMultiplier > 1 then
			actualDamage = actualDamage * damageMultiplier
		end
	end

	-- shield absorb
	if _G.CheckShield then
		actualDamage = _G.CheckShield(victim, damage)
	end

	-- damage amp debuff
	if _G.GetDamageAmplifier then
		local amp = _G.GetDamageAmplifier(victim)
		if amp > 1 then
			actualDamage = actualDamage * amp
		end
	end

	if actualDamage <= 0 then
		return false
	end

	victimData.hp = victimData.hp - actualDamage
	victimData.lastDamageTime = tick()

	syncHpToHumanoid(victim)
	playWorldSound(victim.Character, SOUNDS.HIT, 0.8, 80)
	TakeDamage:FireClient(victim, actualDamage, attacker.Name)

	if victimData.isInvisible then
		forceRevealPlayer(victim, "damaged")
	end

	-- lifesteal
	if _G.GetLifestealAmount then
		_G.GetLifestealAmount(attacker, actualDamage)
	end

	if _G.OnPlayerDamagedForEgg then
		_G.OnPlayerDamagedForEgg(victim)
	end

	-- handle death
	if victimData.hp <= 0 then
		victimData.hp = 0
		victimData.isDead = true
		victimData.lastDeathTime = tick()

		StunnedPlayers[victim] = nil
		SlowedPlayers[victim] = nil

		if victimData.isInvisible then
			forceRevealPlayer(victim, "death")
		end

		playWorldSound(victim.Character, SOUNDS.DEATH, 1.5, 150)

		if _G.OnPlayerKill then
			_G.OnPlayerKill(attacker, victim)
		end

		if _G.RewardKill then
			_G.RewardKill(attacker)
		end

		if not PlayerFirstKill[attacker] then
			PlayerFirstKill[attacker] = true
			logFunnelStep(attacker, 16, "First Kill")
		end

		local humanoid = victim.Character and victim.Character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid.Health = 0
		end

		victimData.isInvincible = true
		victimData.lastDamageTime = tick() + 7
	end

	return true
end

_G.DealDamageToPlayer = function(attacker, victim, damage, abilityName)
	return dealDamage(attacker, victim, damage)
end

_G.DamagePlayerHP = function(player, amount)
	local data = PlayerData[player]
	if not data then return 0 end
	if data.isDead then return 0 end

	if _G.IsPlayerInvulnerable and _G.IsPlayerInvulnerable(player) then
		return 0
	end

	local actualDamage = amount
	if _G.CheckShield then
		actualDamage = _G.CheckShield(player, amount)
	end

	if actualDamage <= 0 then return 0 end

	data.hp = math.max(0, data.hp - actualDamage)
	data.lastDamageTime = tick()

	if data.isInvisible then
		forceRevealPlayer(player, "damaged")
	end

	syncHpToHumanoid(player)
	TakeDamage:FireClient(player, actualDamage, "Environment")

	return actualDamage
end

-- spatial query for enemies
local function getEnemiesInRadius(attacker, position, radius)
	local found = {}

	for _, player in ipairs(Players:GetPlayers()) do
		if player ~= attacker and player.Character and areEnemies(attacker, player) then
			local rootPart = player.Character:FindFirstChild("HumanoidRootPart")
			if rootPart then
				local distance = (rootPart.Position - position).Magnitude
				if distance <= radius then
					local data = getPlayerData(player)
					if not data.isDead then
						table.insert(found, {player = player, distance = distance, rootPart = rootPart})
					end
				end
			end
		end
	end

	return found
end

SelectBird.OnServerEvent:Connect(function(player, birdType)
	if not BIRD_TYPES[birdType] then return end

	local data = getPlayerData(player)
	if data.isDead then return end

	if data.birdType == "CROW" and data.isInvisible then
		forceRevealPlayer(player, "bird_change")
	end

	local wasFirstSelection = not data.hasSelectedBird

	data.birdType = birdType
	data.hasSelectedBird = true
	local config = BIRD_TYPES[birdType]
	data.hp = config.MAX_HP
	syncHpToHumanoid(player)

	if data.combatEnabled then
		applyBirdMorph(player, birdType)
	end

	if data.inGame and wasFirstSelection then
		local currentMode = _G.GetCurrentGameModeForSpawn and _G.GetCurrentGameModeForSpawn()

		if currentMode == "FREE_FOR_ALL" then
			if _G.SpawnFFAPlayerAfterSelection then
				_G.SpawnFFAPlayerAfterSelection(player)
			else
				data.combatEnabled = true
				local char = player.Character
				if char then
					startHidingCharacter(player, char)
					applyBirdMorph(player, birdType)
				end
				giveSpawnProtection(player, SPAWN_PROTECTION.FIRST_SPAWN_DURATION)
			end
		else
			if data.team then
				local char = player.Character
				if char and not char:FindFirstChild("BirdMorph") then
					startHidingCharacter(player, char)
					applyBirdMorph(player, birdType)
					data.combatEnabled = true
					giveSpawnProtection(player, SPAWN_PROTECTION.FIRST_SPAWN_DURATION)

					task.delay(0.2, function()
						if player.Parent and _G.SetBillboardVisible then
							_G.SetBillboardVisible(player, true)
						end
					end)
				end
			end
		end
	end
end)

-- attack handler, different logic per bird type
Attack.OnServerEvent:Connect(function(player, direction, birdType, clientPos)
	local data = getPlayerData(player)
	if data.isDead then return end

	if not canPlayerAttack(player) then
		return
	end

	local config = getBirdConfig(player)
	local char = player.Character
	if not char then return end

	local rootPart = char:FindFirstChild("HumanoidRootPart")
	if not rootPart then return end

	-- use client pos but sanity check it
	local attackPos = clientPos or rootPart.Position
	if clientPos then
		local serverPos = rootPart.Position
		local posDiff = (clientPos - serverPos).Magnitude
		if posDiff > 20 then
			attackPos = serverPos
		end
	end

	local playerBirdType = data.birdType or "PIGEON"
	SpawnVFX:FireAllClients("ATTACK", player, playerBirdType, attackPos, direction)

	-- PIGEON: cone aoe
	if config.ATTACK_TYPE == "WING" then
		local hitPlayers = {}

		for _, otherPlayer in ipairs(Players:GetPlayers()) do
			if otherPlayer ~= player and otherPlayer.Character and areEnemies(player, otherPlayer) then
				local otherData = getPlayerData(otherPlayer)
				if not otherData.isDead then
					local otherRoot = otherPlayer.Character:FindFirstChild("HumanoidRootPart")
					if otherRoot then
						local toEnemy = otherRoot.Position - attackPos
						local distance = toEnemy.Magnitude

						if distance <= config.ATTACK_RANGE then
							-- angle check for cone
							local dot = direction:Dot(toEnemy.Unit)
							local angle = math.deg(math.acos(math.clamp(dot, -1, 1)))

							if angle <= config.ATTACK_ANGLE / 2 then
								table.insert(hitPlayers, otherPlayer)
							end
						end
					end
				end
			end
		end

		for _, victim in ipairs(hitPlayers) do
			if dealDamage(player, victim, config.DAMAGE) then
				local victimRoot = victim.Character:FindFirstChild("HumanoidRootPart")
				if victimRoot then
					local hitFx = Instance.new("Part")
					hitFx.Name = "WingHitEffect"
					hitFx.Size = Vector3.new(3, 3, 3)
					hitFx.Shape = Enum.PartType.Ball
					hitFx.Position = victimRoot.Position
					hitFx.Anchored = true
					hitFx.CanCollide = false
					hitFx.Transparency = 0.3
					hitFx.Color = Color3.fromRGB(150, 180, 255)
					hitFx.Material = Enum.Material.Neon
					hitFx.Parent = workspace
					Debris:AddItem(hitFx, 0.2)
				end
			end
		end
		checkAndDamageClones(player, attackPos, config.ATTACK_RANGE, config.DAMAGE)
	end

	-- HUMMINGBIRD: single target closest
	if config.ATTACK_TYPE == "STING" then
		local bestTarget = nil
		local bestDist = config.ATTACK_RANGE

		for _, otherPlayer in ipairs(Players:GetPlayers()) do
			if otherPlayer ~= player and otherPlayer.Character and areEnemies(player, otherPlayer) then
				local otherData = getPlayerData(otherPlayer)
				if not otherData.isDead then
					local otherRoot = otherPlayer.Character:FindFirstChild("HumanoidRootPart")
					if otherRoot then
						local toEnemy = otherRoot.Position - attackPos
						local distance = toEnemy.Magnitude

						if distance <= config.ATTACK_RANGE then
							local dot = direction:Dot(toEnemy.Unit)
							local angle = math.deg(math.acos(math.clamp(dot, -1, 1)))

							if angle <= config.ATTACK_ANGLE / 2 and distance < bestDist then
								bestTarget = otherPlayer
								bestDist = distance
							end
						end
					end
				end
			end
		end

		if bestTarget then
			if dealDamage(player, bestTarget, config.DAMAGE) then
				local victimRoot = bestTarget.Character:FindFirstChild("HumanoidRootPart")
				if victimRoot then
					local hitFx = Instance.new("Part")
					hitFx.Name = "StingHitEffect"
					hitFx.Size = Vector3.new(2, 2, 2)
					hitFx.Shape = Enum.PartType.Ball
					hitFx.Position = victimRoot.Position
					hitFx.Anchored = true
					hitFx.CanCollide = false
					hitFx.Transparency = 0
					hitFx.Color = Color3.fromRGB(100, 255, 180)
					hitFx.Material = Enum.Material.Neon
					hitFx.Parent = workspace

					TweenService:Create(hitFx, TweenInfo.new(0.1), {
						Size = Vector3.new(5, 5, 5),
						Transparency = 1
					}):Play()
					Debris:AddItem(hitFx, 0.15)
				end
			end
		end
		checkAndDamageClones(player, attackPos, config.ATTACK_RANGE, config.DAMAGE)
	end

	-- KIWI: ram with knockback
	if config.ATTACK_TYPE == "RAM" then
		local dashDistance = config.ATTACK_DASH or 12
		local startPos = attackPos
		local hitPlayers = {}

		for _, otherPlayer in ipairs(Players:GetPlayers()) do
			if otherPlayer ~= player and otherPlayer.Character and areEnemies(player, otherPlayer) then
				local otherData = getPlayerData(otherPlayer)
				if not otherData.isDead then
					local otherRoot = otherPlayer.Character:FindFirstChild("HumanoidRootPart")
					if otherRoot then
						local toPlayer = otherRoot.Position - startPos
						-- project onto dash direction
						local projection = toPlayer:Dot(direction)

						if projection > 0 and projection < dashDistance then
							-- perpendicular distance
							local perpendicular = (toPlayer - direction * projection).Magnitude

							if perpendicular < 5 then
								table.insert(hitPlayers, {player = otherPlayer, root = otherRoot})
							end
						end
					end
				end
			end
		end

		for _, info in ipairs(hitPlayers) do
			if dealDamage(player, info.player, config.DAMAGE) then
				-- apply knockback with bodyvelocity
				local knockbackDir = direction + Vector3.new(0, 0.5, 0)
				local knockback = config.ATTACK_KNOCKBACK or 20

				local bodyVel = Instance.new("BodyVelocity")
				bodyVel.MaxForce = Vector3.new(math.huge, math.huge, math.huge)
				bodyVel.Velocity = knockbackDir.Unit * knockback
				bodyVel.Parent = info.root
				Debris:AddItem(bodyVel, 0.3)

				local hitFx = Instance.new("Part")
				hitFx.Name = "RamHitEffect"
				hitFx.Size = Vector3.new(4, 4, 4)
				hitFx.Shape = Enum.PartType.Ball
				hitFx.Position = info.root.Position
				hitFx.Anchored = true
				hitFx.CanCollide = false
				hitFx.Transparency = 0.3
				hitFx.Color = Color3.fromRGB(139, 90, 43)
				hitFx.Material = Enum.Material.Neon
				hitFx.Parent = workspace

				TweenService:Create(hitFx, TweenInfo.new(0.3), {
					Size = Vector3.new(8, 8, 8),
					Transparency = 1
				}):Play()
				Debris:AddItem(hitFx, 0.4)
			end
		end
		checkAndDamageClones(player, attackPos, dashDistance, config.DAMAGE)
	end

	-- PENGUIN: slide aoe around self
	if config.ATTACK_TYPE == "SLIDE" then
		local slideRadius = 12

		for _, otherPlayer in ipairs(Players:GetPlayers()) do
			if otherPlayer ~= player and otherPlayer.Character and areEnemies(player, otherPlayer) then
				local otherData = getPlayerData(otherPlayer)
				if not otherData.isDead then
					local otherRoot = otherPlayer.Character:FindFirstChild("HumanoidRootPart")
					if otherRoot then
						local distance = (otherRoot.Position - attackPos).Magnitude
						if distance <= slideRadius then
							if dealDamage(player, otherPlayer, config.DAMAGE) then
								local hitFx = Instance.new("Part")
								hitFx.Name = "SlideHitEffect"
								hitFx.Size = Vector3.new(4, 4, 4)
								hitFx.Shape = Enum.PartType.Ball
								hitFx.Position = otherRoot.Position
								hitFx.Anchored = true
								hitFx.CanCollide = false
								hitFx.Transparency = 0.3
								hitFx.Color = Color3.fromRGB(150, 220, 255)
								hitFx.Material = Enum.Material.Ice
								hitFx.Parent = workspace

								TweenService:Create(hitFx, TweenInfo.new(0.2), {
									Size = Vector3.new(10, 10, 10),
									Transparency = 1
								}):Play()
								Debris:AddItem(hitFx, 0.3)
							end
						end
					end
				end
			end
		end
		checkAndDamageClones(player, attackPos, 12, config.DAMAGE)
	end

	-- CROW: peck with backstab bonus
	if config.ATTACK_TYPE == "PECK" then
		local bestTarget = nil
		local bestDist = config.ATTACK_RANGE

		for _, otherPlayer in ipairs(Players:GetPlayers()) do
			if otherPlayer ~= player and otherPlayer.Character and areEnemies(player, otherPlayer) then
				local otherData = getPlayerData(otherPlayer)
				if not otherData.isDead then
					local otherRoot = otherPlayer.Character:FindFirstChild("HumanoidRootPart")
					if otherRoot then
						local toEnemy = otherRoot.Position - attackPos
						local distance = toEnemy.Magnitude

						if distance <= config.ATTACK_RANGE then
							local dot = direction:Dot(toEnemy.Unit)
							local angle = math.deg(math.acos(math.clamp(dot, -1, 1)))

							if angle <= config.ATTACK_ANGLE / 2 and distance < bestDist then
								bestTarget = otherPlayer
								bestDist = distance
							end
						end
					end
				end
			end
		end

		if bestTarget then
			local damage = config.DAMAGE

			-- backstab when invis
			if data.isInvisible then
				local bonus = math.floor(damage * (config.BACKSTAB_BONUS or 0.5))
				damage = damage + bonus
				forceRevealPlayer(player, "attacked")
			end

			if dealDamage(player, bestTarget, damage) then
				local victimRoot = bestTarget.Character:FindFirstChild("HumanoidRootPart")
				if victimRoot then
					local hitFx = Instance.new("Part")
					hitFx.Name = "PeckHitEffect"
					hitFx.Size = Vector3.new(2, 2, 2)
					hitFx.Shape = Enum.PartType.Ball
					hitFx.Position = victimRoot.Position
					hitFx.Anchored = true
					hitFx.CanCollide = false
					hitFx.Transparency = 0
					hitFx.Color = Color3.fromRGB(40, 40, 50)
					hitFx.Material = Enum.Material.Neon
					hitFx.Parent = workspace

					TweenService:Create(hitFx, TweenInfo.new(0.15), {
						Size = Vector3.new(6, 6, 6),
						Transparency = 1
					}):Play()
					Debris:AddItem(hitFx, 0.2)

					for i = 1, 5 do
						local feather = Instance.new("Part")
						feather.Name = "FeatherHitEffect"
						feather.Size = Vector3.new(0.4, 0.1, 0.8)
						feather.Position = victimRoot.Position + Vector3.new(
							(math.random() - 0.5) * 2,
							math.random() * 2,
							(math.random() - 0.5) * 2
						)
						feather.Anchored = false
						feather.CanCollide = false
						feather.Color = Color3.fromRGB(20, 20, 30)
						feather.Material = Enum.Material.SmoothPlastic
						feather.Parent = workspace

						feather.AssemblyLinearVelocity = Vector3.new(
							(math.random() - 0.5) * 20,
							math.random() * 15,
							(math.random() - 0.5) * 20
						)

						Debris:AddItem(feather, 1.5)
					end
				end
			end
		end
		checkAndDamageClones(player, attackPos, config.ATTACK_RANGE, config.DAMAGE)
	end

	-- FLAMINGO: beak attack
	if config.ATTACK_TYPE == "BEAK" then
		local bestTarget = nil
		local bestDist = config.ATTACK_RANGE

		for _, otherPlayer in ipairs(Players:GetPlayers()) do
			if otherPlayer ~= player and otherPlayer.Character and areEnemies(player, otherPlayer) then
				local otherData = getPlayerData(otherPlayer)
				if not otherData.isDead then
					local otherRoot = otherPlayer.Character:FindFirstChild("HumanoidRootPart")
					if otherRoot then
						local toEnemy = otherRoot.Position - attackPos
						local distance = toEnemy.Magnitude

						if distance <= config.ATTACK_RANGE then
							local dot = direction:Dot(toEnemy.Unit)
							local angle = math.deg(math.acos(math.clamp(dot, -1, 1)))

							if angle <= config.ATTACK_ANGLE / 2 and distance < bestDist then
								bestTarget = otherPlayer
								bestDist = distance
							end
						end
					end
				end
			end
		end

		if bestTarget then
			if dealDamage(player, bestTarget, config.DAMAGE) then
				local victimRoot = bestTarget.Character:FindFirstChild("HumanoidRootPart")
				if victimRoot then
					local hitFx = Instance.new("Part")
					hitFx.Name = "BeakHitEffect"
					hitFx.Size = Vector3.new(3, 3, 3)
					hitFx.Shape = Enum.PartType.Ball
					hitFx.Position = victimRoot.Position
					hitFx.Anchored = true
					hitFx.CanCollide = false
					hitFx.Transparency = 0
					hitFx.Color = Color3.fromRGB(255, 105, 180)
					hitFx.Material = Enum.Material.Neon
					hitFx.Parent = workspace

					TweenService:Create(hitFx, TweenInfo.new(0.15), {
						Size = Vector3.new(6, 6, 6),
						Transparency = 1
					}):Play()
					Debris:AddItem(hitFx, 0.2)

					for i = 1, 5 do
						local feather = Instance.new("Part")
						feather.Name = "PinkFeatherEffect"
						feather.Size = Vector3.new(0.4, 0.1, 0.8)
						feather.Position = victimRoot.Position + Vector3.new(
							(math.random() - 0.5) * 2,
							math.random() * 2,
							(math.random() - 0.5) * 2
						)
						feather.Anchored = false
						feather.CanCollide = false
						feather.Color = Color3.fromRGB(255, 150, 200)
						feather.Material = Enum.Material.SmoothPlastic
						feather.Parent = workspace

						feather.AssemblyLinearVelocity = Vector3.new(
							(math.random() - 0.5) * 20,
							math.random() * 15,
							(math.random() - 0.5) * 20
						)

						Debris:AddItem(feather, 1.5)
					end
				end
			end
		end
		checkAndDamageClones(player, attackPos, config.ATTACK_RANGE, config.DAMAGE)
	end
end)

-- ability handler
UseAbility.OnServerEvent:Connect(function(player, abilityType, ...)
	local data = getPlayerData(player)
	if data.isDead then return end

	if not canPlayerAttack(player) then
		return
	end

	local config = getBirdConfig(player)
	local args = {...}

	-- PIGEON: poop bomb drops and explodes, slows enemies
	if abilityType == "BOMBARDMENT" then
		local position = args[1]
		if not position then return end

		local poop = Instance.new("Part")
		poop.Name = "PoopBomb"
		poop.Size = Vector3.new(24, 24, 24)
		poop.Shape = Enum.PartType.Ball
		poop.Position = position
		poop.Color = Color3.fromRGB(101, 67, 33)
		poop.Material = Enum.Material.SmoothPlastic
		poop.CanCollide = false
		poop.Anchored = false
		poop.Parent = workspace

		poop.AssemblyLinearVelocity = Vector3.new(0, -120, 0)

		local hit = false
		local connection
		connection = poop.Touched:Connect(function(other)
			if hit then return end

			local char = player.Character
			if char and other:IsDescendantOf(char) then return end

			if other.Name:find("Poop") or other.Name:find("Effect") or other.Name:find("Splat") then return end

			local otherPlayer = Players:GetPlayerFromCharacter(other.Parent)
			if otherPlayer then return end

			local otherChar = other:FindFirstAncestorOfClass("Model")
			if otherChar then
				local checkPlayer = Players:GetPlayerFromCharacter(otherChar)
				if checkPlayer then return end
			end

			hit = true
			connection:Disconnect()

			local splatPos = poop.Position - Vector3.new(0, 10, 0)
			poop:Destroy()

			local explosion = Instance.new("Part")
			explosion.Name = "PoopExplosion"
			explosion.Size = Vector3.new(15, 15, 15)
			explosion.Shape = Enum.PartType.Ball
			explosion.Position = splatPos
			explosion.Anchored = true
			explosion.CanCollide = false
			explosion.Color = Color3.fromRGB(139, 90, 43)
			explosion.Material = Enum.Material.Neon
			explosion.Transparency = 0.3
			explosion.Parent = workspace

			TweenService:Create(explosion, TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				Size = Vector3.new(50, 50, 50),
				Transparency = 1
			}):Play()
			Debris:AddItem(explosion, 0.6)

			for i = 1, 12 do
				local splash = Instance.new("Part")
				splash.Name = "PoopSplash"
				splash.Size = Vector3.new(4, 4, 4)
				splash.Shape = Enum.PartType.Ball
				splash.Position = splatPos
				splash.Anchored = false
				splash.CanCollide = false
				splash.Color = Color3.fromRGB(101, 67, 33)
				splash.Material = Enum.Material.SmoothPlastic
				splash.Parent = workspace

				local angle = (i / 12) * math.pi * 2
				local force = Vector3.new(math.cos(angle) * 80, 40, math.sin(angle) * 80)
				splash.AssemblyLinearVelocity = force

				Debris:AddItem(splash, 2)
			end

			local nearby = getEnemiesInRadius(player, splatPos, 30)
			for _, info in ipairs(nearby) do
				dealDamage(player, info.player, config.ABILITY_DAMAGE)
				slowPlayer(info.player, BIRD_TYPES.PIGEON.ABILITY_SLOW_DURATION, BIRD_TYPES.PIGEON.ABILITY_SLOW_PERCENT)
			end
		end)

		Debris:AddItem(poop, 5)
	end

	-- HUMMINGBIRD: fast dash through enemies
	if abilityType == "DASH" then
		local startPos = args[1]
		local dashDir = args[2]
		local dashSpeed = args[3] or 250
		local dashDuration = args[4] or 0.3

		if not startPos or not dashDir then return end

		SpawnVFX:FireAllClients("DASH", player, startPos, dashDir, dashDuration)

		local char = player.Character
		if not char then return end
		local rootPart = char:FindFirstChild("HumanoidRootPart")
		if not rootPart then return end

		local damagedPlayers = {}

		local startTime = tick()
		local checkConnection
		checkConnection = RunService.Heartbeat:Connect(function()
			if tick() - startTime > dashDuration then
				checkConnection:Disconnect()
				return
			end

			if not rootPart.Parent then
				checkConnection:Disconnect()
				return
			end

			local currentPos = rootPart.Position

			for _, otherPlayer in ipairs(Players:GetPlayers()) do
				if otherPlayer ~= player and 
					otherPlayer.Character and 
					areEnemies(player, otherPlayer) and
					not damagedPlayers[otherPlayer] then

					local otherData = getPlayerData(otherPlayer)
					if not otherData.isDead then
						local otherRoot = otherPlayer.Character:FindFirstChild("HumanoidRootPart")
						if otherRoot then
							local distance = (otherRoot.Position - currentPos).Magnitude

							if distance < 8 then
								damagedPlayers[otherPlayer] = true

								if dealDamage(player, otherPlayer, config.ABILITY_DAMAGE) then
									local hitFx = Instance.new("Part")
									hitFx.Name = "DashHitEffect"
									hitFx.Size = Vector3.new(4, 4, 4)
									hitFx.Shape = Enum.PartType.Ball
									hitFx.Position = otherRoot.Position
									hitFx.Anchored = true
									hitFx.CanCollide = false
									hitFx.Transparency = 0.3
									hitFx.Color = Color3.fromRGB(100, 255, 180)
									hitFx.Material = Enum.Material.Neon
									hitFx.Parent = workspace

									TweenService:Create(hitFx, TweenInfo.new(0.2), {
										Size = Vector3.new(8, 8, 8),
										Transparency = 1
									}):Play()
									Debris:AddItem(hitFx, 0.3)
								end
							end
						end
					end
				end
			end
		end)

		task.delay(dashDuration + 0.1, function()
			if checkConnection.Connected then
				checkConnection:Disconnect()
			end
		end)
	end

	-- KIWI: ground stomp stuns nearby
	if abilityType == "EARTHQUAKE" then
		local position = args[1]
		if not position then return end

		SpawnVFX:FireAllClients("EARTHQUAKE", player, position)

		local victims = getEnemiesInRadius(player, position, config.ABILITY_RADIUS)

		for _, info in ipairs(victims) do
			if dealDamage(player, info.player, config.ABILITY_DAMAGE) then
				stunPlayer(info.player, BIRD_TYPES.KIWI.ABILITY_STUN_DURATION)
			end
		end
	end

	-- PENGUIN: icicle projectile freezes on hit
	if abilityType == "ICICLE" then
		local startPos = args[1]
		local direction = args[2]
		if not startPos or not direction then return end

		local icicleTemplate = SERVER_VFX.Penguin.Icicle
		local icicle

		if icicleTemplate then
			icicle = icicleTemplate:Clone()
			icicle.Name = "IcicleProjectile"
			if icicle:IsA("BasePart") then
				local baseCFrame = CFrame.lookAt(startPos + Vector3.new(0, 1, 0), startPos + Vector3.new(0, 1, 0) + direction)
				icicle.CFrame = baseCFrame * CFrame.Angles(math.rad(-90), 0, 0)
				icicle.CanCollide = false
				icicle.Anchored = false
			elseif icicle:IsA("Model") then
				local baseCFrame = CFrame.lookAt(startPos + Vector3.new(0, 1, 0), startPos + Vector3.new(0, 1, 0) + direction)
				icicle:PivotTo(baseCFrame * CFrame.Angles(math.rad(-90), 0, 0))
				for _, part in ipairs(icicle:GetDescendants()) do
					if part:IsA("BasePart") then
						part.CanCollide = false
						part.Anchored = false
					end
				end
			end
		else
			-- fallback simple icicle
			icicle = Instance.new("Part")
			icicle.Name = "IcicleProjectile"
			icicle.Size = Vector3.new(3, 3, 8)
			icicle.Position = startPos + Vector3.new(0, 1, 0)
			icicle.CFrame = CFrame.lookAt(startPos, startPos + direction)
			icicle.Color = Color3.fromRGB(100, 200, 255)
			icicle.Material = Enum.Material.Ice
			icicle.Transparency = 0.1
			icicle.CanCollide = false
			icicle.Anchored = false
		end

		icicle.Parent = workspace

		local icicleSpeed = BIRD_TYPES.PENGUIN.ABILITY_ICICLE_SPEED or 150

		-- move with bodyvelocity
		local bodyVel = Instance.new("BodyVelocity")
		bodyVel.MaxForce = Vector3.new(math.huge, math.huge, math.huge)
		bodyVel.Velocity = direction * icicleSpeed
		bodyVel.Parent = icicle

		-- keep orientation with bodygyro
		local bodyGyro = Instance.new("BodyGyro")
		bodyGyro.MaxTorque = Vector3.new(math.huge, math.huge, math.huge)
		bodyGyro.CFrame = icicle.CFrame
		bodyGyro.Parent = icicle

		local hit = false
		local hitPlayers = {}

		local checkConnection
		local startTime = tick()
		checkConnection = RunService.Heartbeat:Connect(function()
			if hit or tick() - startTime > 3 then
				checkConnection:Disconnect()
				if icicle.Parent then icicle:Destroy() end
				return
			end

			if not icicle.Parent then
				checkConnection:Disconnect()
				return
			end

			local iciclePos = icicle.Position

			for _, otherPlayer in ipairs(Players:GetPlayers()) do
				if otherPlayer ~= player and 
					otherPlayer.Character and 
					areEnemies(player, otherPlayer) and
					not hitPlayers[otherPlayer] then

					local otherData = getPlayerData(otherPlayer)
					if not otherData.isDead then
						local otherRoot = otherPlayer.Character:FindFirstChild("HumanoidRootPart")
						if otherRoot then
							local distance = (otherRoot.Position - iciclePos).Magnitude
							if distance < 6 then
								hitPlayers[otherPlayer] = true
								hit = true

								if dealDamage(player, otherPlayer, config.ABILITY_DAMAGE) then
									stunPlayer(otherPlayer, BIRD_TYPES.PENGUIN.ABILITY_FREEZE_DURATION)
									slowPlayer(otherPlayer, BIRD_TYPES.PENGUIN.ABILITY_FREEZE_DURATION, 0.7)
									
									if _G.SetPlayerFrozen then
										_G.SetPlayerFrozen(otherPlayer, true)
										task.delay(BIRD_TYPES.PENGUIN.ABILITY_FREEZE_DURATION, function()
											if _G.SetPlayerFrozen then
												_G.SetPlayerFrozen(otherPlayer, false)
											end
										end)
									end
									
									playWorldSound(otherPlayer.Character, SOUNDS.ICICLE_HIT, 1, 100)

									local iceFx = Instance.new("Part")
									iceFx.Name = "IceExplosion"
									iceFx.Size = Vector3.new(5, 5, 5)
									iceFx.Shape = Enum.PartType.Ball
									iceFx.Position = otherRoot.Position
									iceFx.Anchored = true
									iceFx.CanCollide = false
									iceFx.Transparency = 0.3
									iceFx.Color = Color3.fromRGB(150, 220, 255)
									iceFx.Material = Enum.Material.Ice
									iceFx.Parent = workspace

									TweenService:Create(iceFx, TweenInfo.new(0.4), {
										Size = Vector3.new(12, 12, 12),
										Transparency = 1
									}):Play()
									Debris:AddItem(iceFx, 0.5)

									local freezeTemplate = SERVER_VFX.Penguin.FreezeBlock
									local freezeBlock

									if freezeTemplate then
										freezeBlock = freezeTemplate:Clone()
										freezeBlock.Name = "FreezeEffect"
										if freezeBlock:IsA("BasePart") then
											freezeBlock.Position = otherRoot.Position
											freezeBlock.Anchored = true
											freezeBlock.CanCollide = false
										elseif freezeBlock:IsA("Model") then
											freezeBlock:PivotTo(CFrame.new(otherRoot.Position))
											for _, part in ipairs(freezeBlock:GetDescendants()) do
												if part:IsA("BasePart") then
													part.Anchored = true
													part.CanCollide = false
												end
											end
										end
									else
										freezeBlock = Instance.new("Part")
										freezeBlock.Name = "FreezeEffect"
										freezeBlock.Size = Vector3.new(5, 7, 5)
										freezeBlock.Position = otherRoot.Position
										freezeBlock.Anchored = true
										freezeBlock.CanCollide = false
										freezeBlock.Transparency = 0.5
										freezeBlock.Color = Color3.fromRGB(180, 230, 255)
										freezeBlock.Material = Enum.Material.Ice
									end

									freezeBlock.Parent = workspace
									Debris:AddItem(freezeBlock, BIRD_TYPES.PENGUIN.ABILITY_FREEZE_DURATION)
								end

								checkConnection:Disconnect()
								icicle:Destroy()
								return
							end
						end
					end
				end
			end

			-- wall collision
			if tick() - startTime > 0.1 then
				local rayParams = RaycastParams.new()
				rayParams.FilterDescendantsInstances = {player.Character, icicle}
				rayParams.FilterType = Enum.RaycastFilterType.Exclude

				local ray = workspace:Raycast(iciclePos, direction * 3, rayParams)
				if ray then
					local hitName = ray.Instance.Name:lower()
					local isEffect = hitName:find("effect") or hitName:find("trail") or 
						hitName:find("icicle") or hitName:find("ice") or
						hitName:find("visual") or hitName:find("spark")

					if not isEffect then
						hit = true
						checkConnection:Disconnect()

						-- shatter effect
						local shardTemplate = SERVER_VFX.Penguin.IceShard
						for i = 1, 8 do
							local shard
							local randomDir = Vector3.new(
								(math.random() - 0.5) * 2,
								math.random() * 0.8,
								(math.random() - 0.5) * 2
							).Unit

							if shardTemplate then
								shard = shardTemplate:Clone()
								shard.Name = "IceShardEffect"
								if shard:IsA("BasePart") then
									local shardCFrame = CFrame.lookAt(iciclePos, iciclePos + randomDir)
									shard.CFrame = shardCFrame * CFrame.Angles(math.rad(-90), 0, 0)
									shard.Anchored = false
									shard.CanCollide = false
									shard.AssemblyLinearVelocity = randomDir * 40
								end
							else
								shard = Instance.new("Part")
								shard.Name = "IceShardEffect"
								shard.Size = Vector3.new(1.5, 1.5, 3)
								local shardCFrame = CFrame.lookAt(iciclePos, iciclePos + randomDir)
								shard.CFrame = shardCFrame
								shard.Anchored = false
								shard.CanCollide = false
								shard.Color = Color3.fromRGB(150, 220, 255)
								shard.Material = Enum.Material.Ice
								shard.Transparency = 0.2
								shard.AssemblyLinearVelocity = randomDir * 40
							end

							shard.Parent = workspace
							Debris:AddItem(shard, 1.5)
						end

						icicle:Destroy()
					end
				end
			end
		end)

		Debris:AddItem(icicle, 4)
	end

	-- CROW: go invis
	if abilityType == "SHADOW" then
		local position = args[1]
		if not position then return end

		SpawnVFX:FireAllClients("SHADOW", player, position)

		data.isInvisible = true
		data.invisibleUntil = tick() + BIRD_TYPES.CROW.ABILITY_DURATION

		updateMorphVisibility(player, false)
		InvisibilityChanged:FireAllClients(player, true)

		local shadowBurst = Instance.new("Part")
		shadowBurst.Name = "ShadowBurstEffect"
		shadowBurst.Size = Vector3.new(8, 8, 8)
		shadowBurst.Shape = Enum.PartType.Ball
		shadowBurst.Position = position
		shadowBurst.Anchored = true
		shadowBurst.CanCollide = false
		shadowBurst.Color = Color3.fromRGB(20, 20, 30)
		shadowBurst.Material = Enum.Material.Neon
		shadowBurst.Transparency = 0.5
		shadowBurst.Parent = workspace

		TweenService:Create(shadowBurst, TweenInfo.new(0.5), {
			Size = Vector3.new(15, 15, 15),
			Transparency = 1
		}):Play()
		Debris:AddItem(shadowBurst, 0.6)

		for i = 1, 10 do
			local smoke = Instance.new("Part")
			smoke.Name = "ShadowSmokeEffect"
			smoke.Size = Vector3.new(2, 2, 2)
			smoke.Shape = Enum.PartType.Ball
			smoke.Position = position + Vector3.new(
				(math.random() - 0.5) * 6,
				math.random() * 4,
				(math.random() - 0.5) * 6
			)
			smoke.Anchored = true
			smoke.CanCollide = false
			smoke.Color = Color3.fromRGB(30, 30, 40)
			smoke.Material = Enum.Material.Neon
			smoke.Transparency = 0.4
			smoke.Parent = workspace

			TweenService:Create(smoke, TweenInfo.new(0.8), {
				Size = Vector3.new(4, 4, 4),
				Position = smoke.Position + Vector3.new(0, 3, 0),
				Transparency = 1
			}):Play()
			Debris:AddItem(smoke, 1)
		end

		task.delay(BIRD_TYPES.CROW.ABILITY_DURATION, function()
			if PlayerData[player] and PlayerData[player].isInvisible then
				PlayerData[player].isInvisible = false
				PlayerData[player].invisibleUntil = 0
				updateMorphVisibility(player, true)
				ForceReveal:FireClient(player, "expired")
				InvisibilityChanged:FireAllClients(player, false)
			end
		end)
	end

	-- FLAMINGO: healing pond, heals allies slows enemies
	if abilityType == "HEALING_POND" then
		local position = args[1]
		if not position then return end

		local char = player.Character
		if not char then return end
		local rootPart = char:FindFirstChild("HumanoidRootPart")
		if not rootPart then return end

		local flamingoConfig = BIRD_TYPES.FLAMINGO

		-- raycast to find ground
		local rayParams = RaycastParams.new()
		rayParams.FilterDescendantsInstances = {char}
		rayParams.FilterType = Enum.RaycastFilterType.Exclude

		local groundRay = workspace:Raycast(position, Vector3.new(0, -50, 0), rayParams)
		local groundPos = groundRay and groundRay.Position or (position - Vector3.new(0, 3, 0))

		local FlamingoVFX = BirdVFX and BirdVFX:FindFirstChild("Flamingo")
		local pondTemplate = FlamingoVFX and FlamingoVFX:FindFirstChild("HealingPond")

		local pondVFX = nil
		if pondTemplate then
			pondVFX = pondTemplate:Clone()
			pondVFX.Name = "HealingPondVFX"

			if pondVFX:IsA("BasePart") then
				pondVFX.Position = groundPos + Vector3.new(0, 0.5, 0)
				pondVFX.Anchored = true
				pondVFX.CanCollide = false
			elseif pondVFX:IsA("Model") then
				pondVFX:PivotTo(CFrame.new(groundPos + Vector3.new(0, 0.5, 0)))
				for _, part in ipairs(pondVFX:GetDescendants()) do
					if part:IsA("BasePart") then
						part.Anchored = true
						part.CanCollide = false
					end
				end
			end

			pondVFX.Parent = workspace
		end

		SpawnVFX:FireAllClients("HEALING_POND", player, groundPos)

		local pondDuration = flamingoConfig.ABILITY_DURATION
		local healPerSec = flamingoConfig.ABILITY_HEAL_PER_SEC
		local slowPercent = flamingoConfig.ABILITY_SLOW_PERCENT
		local radius = flamingoConfig.ABILITY_RADIUS

		local startTime = tick()
		local lastHealTick = tick()
		local playersInZone = {}

		local healConnection
		healConnection = RunService.Heartbeat:Connect(function()
			local elapsed = tick() - startTime
			if elapsed > pondDuration then
				healConnection:Disconnect()
				for inZonePlayer, _ in pairs(playersInZone) do
					if inZonePlayer.Parent then
						local HealingZoneRemote = BirdRemotes:FindFirstChild("HealingZoneEffect")
						if HealingZoneRemote then
							HealingZoneRemote:FireClient(inZonePlayer, false)
						end
					end
				end
				return
			end

			local currentInZone = {}

			for _, otherPlayer in ipairs(Players:GetPlayers()) do
				if otherPlayer.Character then
					local otherRoot = otherPlayer.Character:FindFirstChild("HumanoidRootPart")
					if otherRoot then
						local distance = (otherRoot.Position - groundPos).Magnitude
						if distance <= radius then
							local isAlly = not areEnemies(player, otherPlayer)

							if isAlly then
								currentInZone[otherPlayer] = true

								if not playersInZone[otherPlayer] then
									playersInZone[otherPlayer] = true
									local HealingZoneRemote = BirdRemotes:FindFirstChild("HealingZoneEffect")
									if HealingZoneRemote then
										HealingZoneRemote:FireClient(otherPlayer, true)
									end
								end
							end
						end
					end
				end
			end

			for inZonePlayer, _ in pairs(playersInZone) do
				if not currentInZone[inZonePlayer] then
					playersInZone[inZonePlayer] = nil
					if inZonePlayer.Parent then
						local HealingZoneRemote = BirdRemotes:FindFirstChild("HealingZoneEffect")
						if HealingZoneRemote then
							HealingZoneRemote:FireClient(inZonePlayer, false)
						end
					end
				end
			end

			-- tick heal every 0.5s
			if tick() - lastHealTick < 0.5 then return end
			lastHealTick = tick()

			for _, otherPlayer in ipairs(Players:GetPlayers()) do
				if otherPlayer.Character then
					local otherRoot = otherPlayer.Character:FindFirstChild("HumanoidRootPart")
					if otherRoot then
						local distance = (otherRoot.Position - groundPos).Magnitude
						if distance <= radius then
							if not areEnemies(player, otherPlayer) then
								if _G.HealPlayerHP then
									local healed = _G.HealPlayerHP(otherPlayer, healPerSec * 0.5)
									if healed > 0 then
										local healFx = Instance.new("Part")
										healFx.Name = "HealEffect"
										healFx.Size = Vector3.new(2, 2, 2)
										healFx.Shape = Enum.PartType.Ball
										healFx.Position = otherRoot.Position
										healFx.Anchored = true
										healFx.CanCollide = false
										healFx.Color = Color3.fromRGB(100, 255, 150)
										healFx.Material = Enum.Material.Neon
										healFx.Transparency = 0.3
										healFx.Parent = workspace

										TweenService:Create(healFx, TweenInfo.new(0.3), {
											Size = Vector3.new(5, 5, 5),
											Transparency = 1,
											Position = otherRoot.Position + Vector3.new(0, 3, 0)
										}):Play()
										Debris:AddItem(healFx, 0.4)
									end
								end
							else
								slowPlayer(otherPlayer, 0.6, slowPercent)
							end
						end
					end
				end
			end
		end)

		task.delay(pondDuration, function()
			if healConnection then healConnection:Disconnect() end

			for inZonePlayer, _ in pairs(playersInZone) do
				if inZonePlayer.Parent then
					local HealingZoneRemote = BirdRemotes:FindFirstChild("HealingZoneEffect")
					if HealingZoneRemote then
						HealingZoneRemote:FireClient(inZonePlayer, false)
					end
				end
			end

			if pondVFX and pondVFX.Parent then
				if pondVFX:IsA("BasePart") then
					TweenService:Create(pondVFX, TweenInfo.new(0.5), {
						Transparency = 1
					}):Play()
				elseif pondVFX:IsA("Model") then
					for _, part in ipairs(pondVFX:GetDescendants()) do
						if part:IsA("BasePart") then
							TweenService:Create(part, TweenInfo.new(0.5), {
								Transparency = 1
							}):Play()
						end
					end
				end
				Debris:AddItem(pondVFX, 0.6)
			end
		end)
	end
end)

-- team management
local function setPlayerTeam(player, team)
	local data = getPlayerData(player)
	local previousTeam = data.team
	data.team = team

	if team then
		data.inGame = true

		if data.hasSelectedBird and not data.combatEnabled and previousTeam == nil then
			local char = player.Character
			if char and not char:FindFirstChild("BirdMorph") then
				startHidingCharacter(player, char)
				applyBirdMorph(player, data.birdType)

				data.combatEnabled = true
				giveSpawnProtection(player, SPAWN_PROTECTION.FIRST_SPAWN_DURATION)

				task.delay(0.2, function()
					if player.Parent and _G.SetBillboardVisible then
						_G.SetBillboardVisible(player, true)
					end
				end)
			end
		end
	end
end

_G.SetPlayerTeamForCombat = setPlayerTeam
_G.GetPlayerTeamForCombat = function(player)
	return getPlayerTeam(player)
end

_G.SetPlayerInGame = function(player, inGame)
	local data = getPlayerData(player)
	data.inGame = inGame
	if not inGame then
		data.combatEnabled = false
	end
end

_G.EnablePlayerCombat = function(player)
	local data = getPlayerData(player)
	if not data then return end
	data.combatEnabled = true
	giveSpawnProtection(player, SPAWN_PROTECTION.FIRST_SPAWN_DURATION)
end

_G.IsPlayerCombatEnabled = function(player)
	local data = PlayerData[player]
	return data and data.combatEnabled or false
end

_G.ResetPlayerHP = function(player)
	local data = PlayerData[player]
	if data then
		local config = getBirdConfig(player)
		data.hp = config.MAX_HP
		data.isDead = false

		StunnedPlayers[player] = nil
		SlowedPlayers[player] = nil
		if _G.ClearPlayerStatuses then
			_G.ClearPlayerStatuses(player)
		end

		if data.isInvisible then
			data.isInvisible = false
			data.invisibleUntil = 0
			InvisibilityChanged:FireAllClients(player, false)
			if _G.SetBillboardVisible then
				_G.SetBillboardVisible(player, true)
			end
		end
	end
end

_G.SetInvincibility = function(player, value)
	local data = getPlayerData(player)
	if data then
		data.isInvincible = value
		if value then
			data.lastDamageTime = tick() + 7
		end
		if _G.SetPlayerInvulnerableStatus then
			_G.SetPlayerInvulnerableStatus(player, value)
		end
	end
end

-- hp regen loop, only heals if out of combat
task.spawn(function()
	while true do
		task.wait(1)

		local currentTime = tick()

		for player, data in pairs(PlayerData) do
			if player.Parent and not data.isDead then
				local config = getBirdConfig(player)
				local regenAmount = config.HP_REGEN or 2

				local timeSinceDamage = currentTime - (data.lastDamageTime or 0)

				if data.hp < config.MAX_HP and timeSinceDamage >= 3 then
					data.hp = math.min(data.hp + regenAmount, config.MAX_HP)
					syncHpToHumanoid(player)
					Heal:FireClient(player, regenAmount)
				end
			end
		end
	end
end)

-- keep enforcing hidden state
task.spawn(function()
	while true do
		task.wait(0.5)

		for player, _ in pairs(HiddenCharacters) do
			if player.Parent and player.Character then
				enforceCharacterHidden(player.Character)
			end
		end
	end
end)

Players.PlayerRemoving:Connect(function(player)
	PlayerFirstKill[player] = nil
	HiddenCharacters[player] = nil

	local data = PlayerData[player]
	if data and data.isInvisible then
		InvisibilityChanged:FireAllClients(player, false)
	end

	PlayerData[player] = nil
	StunnedPlayers[player] = nil
	SlowedPlayers[player] = nil
end)

Players.PlayerAdded:Connect(function(player)
	getPlayerData(player)

	player.CharacterAdded:Connect(function(char)
		local data = getPlayerData(player)
		local config = getBirdConfig(player)

		local wasInGame = data.inGame
		local wasCombatEnabled = data.combatEnabled
		local wasDead = data.isDead

		data.hp = config.MAX_HP
		data.isDead = false

		local timeSinceDeath = tick() - (data.lastDeathTime or 0)
		local recentlyDied = timeSinceDeath < 15

		if wasInGame and wasCombatEnabled and recentlyDied then
			data.isInvincible = true
			data.hasSpawnProtection = true
			data.spawnProtectionEndTime = tick() + SPAWN_PROTECTION.RESPAWN_DURATION

			task.delay(0.1, function()
				if player.Parent then
					SpawnShield:FireClient(player, SPAWN_PROTECTION.RESPAWN_DURATION)
				end
			end)
		else
			data.isInvincible = false
			data.hasSpawnProtection = false
			data.spawnProtectionEndTime = 0
		end

		StunnedPlayers[player] = nil
		SlowedPlayers[player] = nil
		if _G.ClearPlayerStatuses then
			_G.ClearPlayerStatuses(player)
		end

		if data.isInvisible then
			data.isInvisible = false
			data.invisibleUntil = 0
			InvisibilityChanged:FireAllClients(player, false)
			if _G.SetBillboardVisible then
				_G.SetBillboardVisible(player, true)
			end
		end

		local humanoid = char:WaitForChild("Humanoid", 5)
		if humanoid then
			humanoid.MaxHealth = config.MAX_HP
			humanoid.Health = config.MAX_HP
			humanoid.HealthDisplayDistance = 0
			humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff

			humanoid.HealthChanged:Connect(function(newHealth)
				if not data.isDead and math.abs(newHealth - data.hp) > 1 then
					local externalDamage = data.hp - newHealth
					if externalDamage > 0 then
						data.hp = newHealth
						if data.hp <= 0 then
							data.hp = 0
							data.isDead = true
						end
					end
				end
			end)
		end

		if wasInGame and wasCombatEnabled and wasDead then
			task.delay(0.1, function()
				if player.Parent and PlayerData[player] then
					SpawnShield:FireClient(player, SPAWN_PROTECTION.RESPAWN_DURATION)

					task.delay(SPAWN_PROTECTION.RESPAWN_DURATION, function()
						if PlayerData[player] and PlayerData[player].hasSpawnProtection then
							PlayerData[player].isInvincible = false
							PlayerData[player].hasSpawnProtection = false
							PlayerData[player].spawnProtectionEndTime = 0
						end
					end)
				end
			end)
		end

		task.delay(0.1, function()
			if char.Parent then
				if data.inGame then
					startHidingCharacter(player, char)
				else
					local inLobby = false
					if _G.IsPlayerInLobby then
						inLobby = _G.IsPlayerInLobby(player)
					end
					if not inLobby then
						startHidingCharacter(player, char)
					end
				end
			end
		end)

		task.delay(0.5, function()
			if char.Parent and data.birdType then
				if data.inGame then
					applyBirdMorph(player, data.birdType)
				else
					local inLobby = false
					if _G.IsPlayerInLobby then
						inLobby = _G.IsPlayerInLobby(player)
					end
					if not inLobby then
						applyBirdMorph(player, data.birdType)
					end
				end
			end
		end)
	end)
end)

-- init players already in game
for _, player in ipairs(Players:GetPlayers()) do
	getPlayerData(player)

	if player.Character then
		local data = getPlayerData(player)
		local config = getBirdConfig(player)
		data.hp = config.MAX_HP

		local humanoid = player.Character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid.MaxHealth = config.MAX_HP
			humanoid.Health = config.MAX_HP
			humanoid.HealthDisplayDistance = 0
			humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
		end

		local inLobby = false
		if _G.IsPlayerInLobby then
			inLobby = _G.IsPlayerInLobby(player)
		end

		if not inLobby then
			startHidingCharacter(player, player.Character)
		end

		task.delay(1, function()
			if player.Character and data.birdType then
				local inLobby2 = false
				if _G.IsPlayerInLobby then
					inLobby2 = _G.IsPlayerInLobby(player)
				end
				if not inLobby2 then
					applyBirdMorph(player, data.birdType)
				end
			end
		end)
	end
end

task.spawn(function()
	task.wait(1)
	loadBirdModels()
end)

_G.ApplyMorphAfterTeleport = function(player)
	local data = getPlayerData(player)
	if not data then return false end

	local char = player.Character
	if not char then return false end

	local birdType = data.birdType or "PIGEON"

	startHidingCharacter(player, char)
	applyBirdMorph(player, birdType)

	if not data.combatEnabled then
		data.combatEnabled = true
	end

	giveSpawnProtection(player, SPAWN_PROTECTION.FIRST_SPAWN_DURATION)

	task.delay(0.2, function()
		if player.Parent and _G.SetBillboardVisible then
			_G.SetBillboardVisible(player, true)
		end
	end)

	return true
end

_G.HasPlayerSelectedBird = function(player)
	local data = PlayerData[player]
	return data and data.hasSelectedBird == true
end

_G.GetPlayerSelectedBird = function(player)
	local data = PlayerData[player]
	return data and data.birdType or "PIGEON"
end

_G.ApplyBirdMorphToPlayer = function(player)
	local char = player.Character
	if not char then return end

	local data = getPlayerData(player)
	local birdType = data.birdType or "PIGEON"

	data.isDead = false
	data.isInvincible = false
	data.isInvisible = false
	data.invisibleUntil = 0
	data.inGame = true

	StunnedPlayers[player] = nil
	SlowedPlayers[player] = nil
	if _G.ClearPlayerStatuses then
		_G.ClearPlayerStatuses(player)
	end

	startHidingCharacter(player, char)
	applyBirdMorph(player, birdType)

	task.delay(0.2, function()
		if _G.SetBillboardVisible then
			_G.SetBillboardVisible(player, true)
		end
	end)
end

_G.RemoveBirdMorphFromPlayer = function(player)
	local char = player.Character
	if not char then return end

	HiddenCharacters[player] = nil
	removeBirdMorph(char)

	local data = PlayerData[player]
	if data then
		data.team = nil
		data.isDead = false
		data.isInvincible = false
		data.isInvisible = false
		data.invisibleUntil = 0
		data.inGame = false
		data.combatEnabled = false
		data.hasSpawnProtection = false
		data.hasSelectedBird = false
	end

	StunnedPlayers[player] = nil
	SlowedPlayers[player] = nil
	InvisibilityChanged:FireAllClients(player, false)
end

print("BirdCombat v3.3 loaded")
