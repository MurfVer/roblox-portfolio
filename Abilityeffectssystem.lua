--[[
    ABILITY EFFECTS SYSTEM - Server Script
    Version: 3.0
    
    A comprehensive ability effects system providing:
    - Flight-compatible slow and speed systems
    - Player buff tracking (shields, lifesteal, invisibility)
    - Area-of-effect abilities with physics integration
    - Clone/decoy system with damage handling
    - Combat integration with invulnerability checks
    
    Technical Highlights:
    - Global function exports (_G) for cross-script integration
    - BodyVelocity for physics-based movement abilities
    - RunService.Heartbeat for continuous effect updates
    - TweenService for smooth visual transitions
    - RemoteEvents for client-server communication
    
    Architecture:
    - Server tracks all slow/speed states
    - Client reads multipliers via _G.GetSlowMultiplier()
    - Movement abilities use RemoteEvents to notify client
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
local RunService = game:GetService("RunService")

-- Wait for dependencies to load
task.wait(0.5)


-- AUDIO HELPER FUNCTION


--[[
    Creates and plays a 3D positional sound with configurable parameters
    
    @param parent - Instance to attach sound to
    @param soundId - Roblox asset ID
    @param volume - Sound volume (0-1)
    @param playbackSpeed - Playback speed multiplier
    @param looped - Whether sound should loop
    @return Sound - The created sound instance
]]
local function playAbilitySound(parent, soundId, volume, playbackSpeed, looped)
    if not soundId or soundId == "" then return nil end

    local sound = Instance.new("Sound")
    sound.SoundId = soundId
    sound.Volume = volume or 0.8
    sound.PlaybackSpeed = playbackSpeed or 1
    sound.Looped = looped or false
    sound.RollOffMode = Enum.RollOffMode.Linear
    sound.RollOffMinDistance = 10
    sound.RollOffMaxDistance = 100
    sound.Parent = parent
    sound:Play()

    if not looped then
        Debris:AddItem(sound, 10)
    end

    return sound
end


-- REMOTE EVENTS SETUP


-- Get or create remotes folder
local BirdRemotes = ReplicatedStorage:WaitForChild("BirdRemotes", 10)
if not BirdRemotes then
    BirdRemotes = Instance.new("Folder")
    BirdRemotes.Name = "BirdRemotes"
    BirdRemotes.Parent = ReplicatedStorage
end

--[[
    Helper to get existing remote or create new one
    Prevents duplicate remotes across scripts
]]
local function getOrCreateRemote(name)
    local remote = BirdRemotes:FindFirstChild(name)
    if not remote then
        remote = Instance.new("RemoteEvent")
        remote.Name = name
        remote.Parent = BirdRemotes
    end
    return remote
end

-- Status effect remotes
local HealRemote = getOrCreateRemote("Heal")
local TakeDamageRemote = getOrCreateRemote("TakeDamage")
local StunnedRemote = getOrCreateRemote("Stunned")
local SlowedRemote = getOrCreateRemote("Slowed")
local InvulnerableRemote = getOrCreateRemote("Invulnerable")

-- Ability-specific remotes for client-side effects
local AbilityDashRemote = getOrCreateRemote("AbilityDash")
local AbilityLiftRemote = getOrCreateRemote("AbilityLift")
local FlightSlowUpdateRemote = getOrCreateRemote("FlightSlowUpdate")
local FlightSpeedUpdateRemote = getOrCreateRemote("FlightSpeedUpdate")
local StopFlightRemote = getOrCreateRemote("StopFlight")


-- PLAYER BUFF TRACKING SYSTEM
 

-- Stores active buffs/debuffs for each player
local PlayerBuffs = {}

--[[
    Retrieves or initializes buff data for a player
    Uses lazy initialization pattern
    
    @param player - Target player
    @return table - Player's buff state
]]
local function getPlayerBuffs(player)
    if not PlayerBuffs[player] then
        PlayerBuffs[player] = {
            speedMultiplier = 1,
            shield = 0,
            invisible = false,
            lifesteal = 0,
            invulnerable = false,
            damageTaken = 1,    -- Damage multiplier (for vulnerability effects)
        }
    end
    return PlayerBuffs[player]
end

 
-- FLIGHT SLOW SYSTEM
 

--[[
    Tracks slow multipliers for flying players
    Client reads this via _G.GetSlowMultiplier()
    Separate from ground slow (WalkSpeed) for flight compatibility
]]
local FlightSlowPlayers = {}

--[[
    Applies slow effect to player's flight speed
    
    @param player - Target player
    @param slowPercent - Slow amount (0.5 = 50% reduction)
    @param duration - Effect duration in seconds
    @param reason - Descriptive reason for debugging
]]
local function setFlightSlow(player, slowPercent, duration, reason)
    local multiplier = 1 - slowPercent

    -- Store slow with expiration time
    FlightSlowPlayers[player] = {
        multiplier = multiplier,
        endTime = tick() + duration,
        reason = reason or "Unknown",
    }

    -- Notify client for flight system integration
    FlightSlowUpdateRemote:FireClient(player, multiplier, duration, reason)

    -- Schedule automatic removal
    task.delay(duration, function()
        local data = FlightSlowPlayers[player]
        if data and tick() >= data.endTime then
            FlightSlowPlayers[player] = nil
            FlightSlowUpdateRemote:FireClient(player, 1, 0, "expired")
        end
    end)
end

--[[
    Immediately removes flight slow from player
    
    @param player - Target player
]]
local function removeFlightSlow(player)
    FlightSlowPlayers[player] = nil
    -- Send multiplier 1 with long duration to ensure application
    FlightSlowUpdateRemote:FireClient(player, 1, 9999, "removed")
end

-- Global accessor for client flight scripts
_G.GetSlowMultiplier = function(player)
    local data = FlightSlowPlayers[player]
    if data and tick() < data.endTime then
        return data.multiplier
    end
    return 1
end

-- Export functions for other scripts
_G.SetFlightSlow = setFlightSlow
_G.RemoveFlightSlow = removeFlightSlow
_G.FlightSlowPlayers = FlightSlowPlayers

 
-- FLIGHT SPEED BUFF SYSTEM
 

-- Tracks speed multipliers for flying players
local FlightSpeedBuffs = {}

-- Cleanup on player leave
Players.PlayerRemoving:Connect(function(player)
    PlayerBuffs[player] = nil
    FlightSlowPlayers[player] = nil
    FlightSpeedBuffs[player] = nil
end)

-- Global accessor for client flight scripts
_G.GetFlightSpeedMultiplier = function(player)
    local data = FlightSpeedBuffs[player]
    if data and tick() < data.endTime then
        return data.multiplier
    end
    return 1
end

--[[
    Applies speed buff to player's flight
    
    @param player - Target player
    @param multiplier - Speed multiplier (1.5 = 50% faster)
    @param duration - Effect duration in seconds
]]
_G.SetFlightSpeedBuff = function(player, multiplier, duration)
    FlightSpeedBuffs[player] = {
        multiplier = multiplier,
        endTime = tick() + duration,
    }

    -- Notify client
    FlightSpeedUpdateRemote:FireClient(player, multiplier, duration)

    if duration then
        task.delay(duration, function()
            local data = FlightSpeedBuffs[player]
            if data and tick() >= data.endTime then
                FlightSpeedBuffs[player] = nil
                FlightSpeedUpdateRemote:FireClient(player, 1, 0)
            end
        end)
    end
end

 
-- HELPER FUNCTIONS
 

--[[
    Finds all enemy players within radius of a position
    
    @param player - Reference player (excluded from results)
    @param position - Center point (Vector3)
    @param radius - Search radius in studs
    @return table - Array of enemy info {player, character, distance, rootPart, humanoid}
]]
local function getEnemiesInRadius(player, position, radius)
    local enemies = {}
    local playerTeam = player.Team

    for _, otherPlayer in ipairs(Players:GetPlayers()) do
        if otherPlayer ~= player then
            -- Determine enemy status based on team
            local isEnemy = (playerTeam == nil) or (otherPlayer.Team == nil) or (otherPlayer.Team ~= playerTeam)
            if isEnemy then
                local char = otherPlayer.Character
                if char then
                    local root = char:FindFirstChild("HumanoidRootPart")
                    local humanoid = char:FindFirstChildOfClass("Humanoid")
                    if root and humanoid and humanoid.Health > 0 then
                        local distance = (root.Position - position).Magnitude
                        if distance <= radius then
                            table.insert(enemies, {
                                player = otherPlayer,
                                character = char,
                                distance = distance,
                                rootPart = root,
                                humanoid = humanoid,
                            })
                        end
                    end
                end
            end
        end
    end
    return enemies
end

--[[
    Returns all enemy players regardless of distance
    Used for map-wide abilities
    
    @param player - Reference player
    @return table - Array of all enemy info
]]
local function getAllEnemies(player)
    local enemies = {}
    local playerTeam = player.Team

    for _, otherPlayer in ipairs(Players:GetPlayers()) do
        if otherPlayer ~= player then
            local isEnemy = (playerTeam == nil) or (otherPlayer.Team == nil) or (otherPlayer.Team ~= playerTeam)
            if isEnemy then
                local char = otherPlayer.Character
                if char then
                    local root = char:FindFirstChild("HumanoidRootPart")
                    local humanoid = char:FindFirstChildOfClass("Humanoid")
                    if root and humanoid and humanoid.Health > 0 then
                        table.insert(enemies, {
                            player = otherPlayer,
                            character = char,
                            rootPart = root,
                            humanoid = humanoid,
                        })
                    end
                end
            end
        end
    end
    return enemies
end

--[[
    Deals damage to a player, integrating with main combat system
    Falls back to direct humanoid damage if combat system unavailable
    
    @param attacker - Attacking player
    @param victim - Target player
    @param amount - Damage amount
    @return boolean - Whether damage was applied
]]
local function dealDamage(attacker, victim, amount)
    -- Try main combat system first
    if _G.DealDamageToPlayer then
        _G.DealDamageToPlayer(attacker, victim, amount)
        return true
    end
    
    -- Fallback to direct damage
    local char = victim.Character
    if char then
        local humanoid = char:FindFirstChildOfClass("Humanoid")
        if humanoid then
            humanoid:TakeDamage(amount)
            if TakeDamageRemote then
                TakeDamageRemote:FireClient(victim, amount, attacker.Name)
            end
            return true
        end
    end
    return false
end

--[[
    Heals a player, integrating with main combat system
    
    @param player - Target player
    @param amount - Heal amount
    @return boolean, number - Success status and actual heal amount
]]
local function healPlayer(player, amount)
    -- Try main combat system first
    if _G.HealPlayerHP then
        local actualHeal = _G.HealPlayerHP(player, amount)
        return true, actualHeal
    end
    
    -- Fallback to direct heal
    local char = player.Character
    if not char then return false, 0 end
    local humanoid = char:FindFirstChildOfClass("Humanoid")
    if not humanoid then return false, 0 end
    
    local oldHealth = humanoid.Health
    humanoid.Health = math.min(humanoid.Health + amount, humanoid.MaxHealth)
    local actualHeal = humanoid.Health - oldHealth
    
    if HealRemote and actualHeal > 0 then
        HealRemote:FireClient(player, actualHeal)
    end
    return true, actualHeal
end

--[[
    Applies stun effect to player
    Integrates with main combat system or applies directly
    
    @param player - Target player
    @param duration - Stun duration in seconds
    @return boolean - Whether stun was applied
]]
local function applyStun(player, duration)
    -- Try main combat system first
    if _G.StunPlayer then
        _G.StunPlayer(player, duration)
        return true
    end
    
    -- Fallback implementation
    local char = player.Character
    if char then
        local humanoid = char:FindFirstChildOfClass("Humanoid")
        if humanoid then
            local originalSpeed = humanoid.WalkSpeed
            local originalJump = humanoid.JumpPower
            humanoid.WalkSpeed = 0
            humanoid.JumpPower = 0
            
            if StunnedRemote then
                StunnedRemote:FireClient(player, duration)
            end
            
            task.delay(duration, function()
                if humanoid and humanoid.Parent then
                    humanoid.WalkSpeed = originalSpeed
                    humanoid.JumpPower = originalJump
                end
            end)
            return true
        end
    end
    return false
end

--[[
    Applies slow effect to both ground and flight movement
    
    @param player - Target player
    @param duration - Slow duration in seconds
    @param slowPercent - Slow amount (0.5 = 50% reduction)
    @return boolean - Whether slow was applied
]]
local function applySlow(player, duration, slowPercent)
    slowPercent = slowPercent or 0.5

    -- Apply ground slow (WalkSpeed)
    if _G.SlowPlayer then
        _G.SlowPlayer(player, duration, slowPercent)
    else
        local char = player.Character
        if char then
            local humanoid = char:FindFirstChildOfClass("Humanoid")
            if humanoid then
                local originalSpeed = humanoid.WalkSpeed
                humanoid.WalkSpeed = originalSpeed * (1 - slowPercent)
                
                if SlowedRemote then
                    SlowedRemote:FireClient(player, duration)
                end
                
                task.delay(duration, function()
                    if humanoid and humanoid.Parent then
                        humanoid.WalkSpeed = originalSpeed
                    end
                end)
            end
        end
    end

    -- Also apply flight slow
    setFlightSlow(player, slowPercent, duration, "Ability")

    return true
end

--[[
    Creates a visual effect sphere at a position
    
    @param position - Effect center (Vector3)
    @param color - Effect color (Color3)
    @param size - Initial size in studs
    @param duration - Effect duration in seconds
    @return Part - The created effect part
]]
local function createEffect(position, color, size, duration)
    local effect = Instance.new("Part")
    effect.Name = "AbilityEffect"
    effect.Shape = Enum.PartType.Ball
    effect.Size = Vector3.new(size, size, size)
    effect.Position = position
    effect.Anchored = true
    effect.CanCollide = false
    effect.CanQuery = false
    effect.CanTouch = false
    effect.Material = Enum.Material.Neon
    effect.Color = color
    effect.Transparency = 0.3
    effect.Parent = workspace
    
    -- Animate expansion and fade
    TweenService:Create(effect, TweenInfo.new(duration), {
        Size = Vector3.new(size * 2, size * 2, size * 2),
        Transparency = 1,
    }):Play()
    
    Debris:AddItem(effect, duration)
    return effect
end

--[[
    Creates a lightning bolt effect between two points
    Uses flickering animation for electric appearance
    
    @param startPos - Start position (Vector3)
    @param endPos - End position (Vector3)
    @param color - Bolt color (Color3)
    @return Part - The bolt part
]]
local function createLightningEffect(startPos, endPos, color)
    local distance = (endPos - startPos).Magnitude
    local midPoint = (startPos + endPos) / 2
    
    local bolt = Instance.new("Part")
    bolt.Name = "LightningBolt"
    bolt.Size = Vector3.new(0.5, 0.5, distance)
    -- CFrame.lookAt orients the bolt towards target
    bolt.CFrame = CFrame.lookAt(midPoint, endPos)
    bolt.Anchored = true
    bolt.CanCollide = false
    bolt.Material = Enum.Material.Neon
    bolt.Color = color or Color3.fromRGB(255, 255, 100)
    bolt.Parent = workspace
    
    -- Flicker animation
    task.spawn(function()
        for i = 1, 3 do
            bolt.Transparency = 0
            task.wait(0.05)
            bolt.Transparency = 0.5
            task.wait(0.05)
        end
        bolt:Destroy()
    end)
    
    return bolt
end

 
-- INVULNERABILITY SYSTEM
 

--[[
    Applies temporary invulnerability to player
    Notifies client for visual feedback
    
    @param player - Target player
    @param duration - Invulnerability duration in seconds
    @param reason - Descriptive reason for UI display
]]
local function applyInvulnerability(player, duration, reason)
    local buffs = getPlayerBuffs(player)
    buffs.invulnerable = true
    
    if InvulnerableRemote then
        InvulnerableRemote:FireClient(player, duration, reason or "Invulnerable")
    end
    
    if duration and duration > 0 then
        task.delay(duration, function()
            local currentBuffs = PlayerBuffs[player]
            if currentBuffs then
                currentBuffs.invulnerable = false
            end
        end)
    end
end

-- Export invulnerability functions
_G.ApplyInvulnerability = applyInvulnerability
_G.RemoveInvulnerability = function(player)
    local buffs = PlayerBuffs[player]
    if buffs then buffs.invulnerable = false end
end

 
-- SHIELD SYSTEM
 

--[[
    Applies damage-absorbing shield to player
    Creates visual shield sphere around character
    
    @param player - Target player
    @param amount - Shield HP
    @param duration - Shield duration in seconds
]]
_G.ApplyShield = function(player, amount, duration)
    local buffs = getPlayerBuffs(player)
    buffs.shield = amount
    
    local char = player.Character
    if char then
        local root = char:FindFirstChild("HumanoidRootPart")
        if root then
            playAbilitySound(root, "rbxassetid://118768758724040", 0.8, 1)
            
            -- Remove existing shield visual
            local oldShield = char:FindFirstChild("ShieldVisual")
            if oldShield then oldShield:Destroy() end
            
            -- Create shield visual sphere
            local shield = Instance.new("Part")
            shield.Name = "ShieldVisual"
            shield.Shape = Enum.PartType.Ball
            shield.Size = Vector3.new(8, 8, 8)
            shield.Transparency = 0.6
            shield.Color = Color3.fromRGB(100, 200, 255)
            shield.Material = Enum.Material.ForceField
            shield.CanCollide = false
            shield.Massless = true
            shield.Anchored = false
            shield.CFrame = root.CFrame
            shield.Parent = char
            
            -- Weld to character
            local weld = Instance.new("Weld")
            weld.Part0 = root
            weld.Part1 = shield
            weld.Parent = root
            
            Debris:AddItem(shield, duration)
        end
    end
    
    task.delay(duration, function()
        local currentBuffs = PlayerBuffs[player]
        if currentBuffs then currentBuffs.shield = 0 end
    end)
end

--[[
    Processes incoming damage against player's shield
    Returns remaining damage after shield absorption
    
    @param player - Target player
    @param incomingDamage - Damage amount
    @return number - Damage remaining after shield
]]
_G.CheckShield = function(player, incomingDamage)
    local buffs = PlayerBuffs[player]
    if buffs and buffs.shield > 0 then
        local blocked = math.min(buffs.shield, incomingDamage)
        buffs.shield = buffs.shield - blocked
        
        -- Remove visual when shield breaks
        if buffs.shield <= 0 then
            local char = player.Character
            if char then
                local shieldVisual = char:FindFirstChild("ShieldVisual")
                if shieldVisual then shieldVisual:Destroy() end
            end
        end
        
        return incomingDamage - blocked
    end
    return incomingDamage
end

 
-- GLOBAL EXPORTS FOR COMBAT INTEGRATION
 

_G.GetEnemiesInRadius = getEnemiesInRadius
_G.GetAllEnemies = getAllEnemies
_G.DealDamage = dealDamage
_G.HealPlayer = healPlayer

 
-- DECOY CLONE SYSTEM
 

-- Tracks active clones for damage routing
local ActiveClones = {}

--[[
    Registers a clone for the damage system
    Allows clones to receive and respond to damage
    
    @param clone - Clone model
    @param owner - Player who created the clone
    @param explosionDamage - Damage dealt on clone death
    @param explosionRadius - Explosion radius on death
]]
local function registerClone(clone, owner, explosionDamage, explosionRadius)
    ActiveClones[clone] = {
        owner = owner,
        explosionDamage = explosionDamage or 50,
        explosionRadius = explosionRadius or 20,
    }
end

-- Global function to damage clones from combat system
_G.DamageClone = function(attacker, cloneCharacter, damage)
    local cloneData = ActiveClones[cloneCharacter]
    if not cloneData then return false end

    local humanoid = cloneCharacter:FindFirstChildOfClass("Humanoid")
    if not humanoid or humanoid.Health <= 0 then return false end

    humanoid:TakeDamage(damage)
    return true
end

-- Find clone within radius (for area attacks)
_G.GetCloneInRadius = function(position, radius)
    for clone, data in pairs(ActiveClones) do
        if clone and clone.Parent then
            local root = clone:FindFirstChild("HumanoidRootPart")
            if root then
                local distance = (root.Position - position).Magnitude
                if distance <= radius then
                    return clone, data
                end
            end
        end
    end
    return nil, nil
end

-- Check if a character is a clone
_G.IsClone = function(character)
    return ActiveClones[character] ~= nil
end

 
-- ABILITY IMPLEMENTATIONS
 

 
-- QUICK DASH
-- High-speed dash with invulnerability frames
-- Works both on ground and in flight
 
_G.ExecuteQuickDash = function(player, dashSpeed, dashDistance)
    local char = player.Character
    if not char then return end
    local root = char:FindFirstChild("HumanoidRootPart")
    if not root then return end
    local humanoid = char:FindFirstChildOfClass("Humanoid")
    if not humanoid then return end

    playAbilitySound(root, "rbxassetid://105092970885783", 0.8, 1)

    local dashDuration = dashDistance / dashSpeed
    applyInvulnerability(player, dashDuration, "Quick Dash")

    local lookVector = root.CFrame.LookVector

    -- Check if player is flying (PlatformStand used for flight)
    local isFlying = humanoid.PlatformStand == true

    -- Notify client for flight dash handling
    AbilityDashRemote:FireClient(player, lookVector, dashSpeed, dashDuration)

    -- Server-side BodyVelocity only for ground dash
    if not isFlying then
        -- Flatten direction for ground movement (no Y force)
        local flatDirection = Vector3.new(lookVector.X, 0, lookVector.Z)
        if flatDirection.Magnitude > 0.1 then
            flatDirection = flatDirection.Unit
        else
            flatDirection = Vector3.new(0, 0, -1)
        end

        local bodyVel = Instance.new("BodyVelocity")
        bodyVel.MaxForce = Vector3.new(math.huge, 0, math.huge)
        bodyVel.Velocity = flatDirection * dashSpeed
        bodyVel.Parent = root
        Debris:AddItem(bodyVel, dashDuration)
    end

    -- Trail visual effect
    local attachment = Instance.new("Attachment")
    attachment.Parent = root
    local attachment2 = Instance.new("Attachment")
    attachment2.Position = Vector3.new(0, 0, 2)
    attachment2.Parent = root
    
    local trail = Instance.new("Trail")
    trail.Color = ColorSequence.new(Color3.fromRGB(150, 200, 255))
    trail.Transparency = NumberSequence.new(0, 1)
    trail.Lifetime = 0.3
    trail.Attachment0 = attachment
    trail.Attachment1 = attachment2
    trail.Parent = root
    
    Debris:AddItem(attachment, dashDuration + 0.5)
    Debris:AddItem(attachment2, dashDuration + 0.5)
end

 
-- HEAL PULSE
-- Instant self-heal ability
 
_G.ExecuteHealPulse = function(player, healAmount)
    local char = player.Character
    if not char then return end
    local root = char:FindFirstChild("HumanoidRootPart")
    if not root then return end

    healAmount = healAmount or 50
    playAbilitySound(root, "rbxassetid://80975042479131", 0.8, 1)
    healPlayer(player, healAmount)
    createEffect(root.Position, Color3.fromRGB(50, 255, 100), 4, 0.5)
end

 
-- SPEED BOOST
-- Temporary movement speed increase
-- Affects both ground and flight speed
 
_G.ApplySpeedBoost = function(player, multiplier, duration)
    local char = player.Character
    if not char then return end
    local humanoid = char:FindFirstChildOfClass("Humanoid")
    if not humanoid then return end
    local root = char:FindFirstChild("HumanoidRootPart")

    if root then
        playAbilitySound(root, "rbxassetid://122261530634300", 0.8, 1)
        createEffect(root.Position, Color3.fromRGB(100, 200, 255), 5, 0.5)
    end

    -- Ground speed boost
    local originalSpeed = humanoid.WalkSpeed
    humanoid.WalkSpeed = originalSpeed * multiplier

    -- Flight speed boost
    _G.SetFlightSpeedBuff(player, multiplier, duration)

    task.delay(duration, function()
        if humanoid and humanoid.Parent then
            humanoid.WalkSpeed = originalSpeed
        end
    end)
end

 
-- SHADOW FEATHERS (Invisibility)
-- Grants temporary invisibility with invulnerability
 
_G.ApplyInvisibility = function(player, duration, breakOnAttack)
    local char = player.Character
    if not char then return end
    
    duration = duration or 3
    local buffs = getPlayerBuffs(player)
    buffs.invisible = true
    
    local root = char:FindFirstChild("HumanoidRootPart")
    if root then
        playAbilitySound(root, "rbxassetid://110782986020100", 0.8, 1)
    end

    applyInvulnerability(player, duration, "Shadow Feathers")

    -- Check if Crow shadow is already active (don't double-hide)
    local isCrowInvisible = _G.IsPlayerInvisible and _G.IsPlayerInvisible(player)
    if isCrowInvisible then
        task.delay(duration, function()
            if buffs then buffs.invisible = false end
        end)
        return
    end

    -- Apply transparency to all parts
    local originalTransparency = {}
    for _, part in ipairs(char:GetDescendants()) do
        if part:IsA("BasePart") and part.Name ~= "HumanoidRootPart" then
            originalTransparency[part] = 0
            part.Transparency = 0.8
        end
    end

    -- Restore visibility after duration
    task.delay(duration, function()
        if buffs then buffs.invisible = false end

        -- Check Crow shadow again before restoring
        local isCrowInvisible = _G.IsPlayerInvisible and _G.IsPlayerInvisible(player)
        if isCrowInvisible then return end

        for part, transparency in pairs(originalTransparency) do
            if part and part.Parent then
                part.Transparency = transparency
            end
        end
    end)
end

 
-- VAMPIRIC TALONS (Lifesteal)
-- Grants temporary lifesteal on attacks
 
_G.ApplyLifesteal = function(player, percent, duration)
    local buffs = getPlayerBuffs(player)
    buffs.lifesteal = percent
    
    local char = player.Character
    if char then
        local root = char:FindFirstChild("HumanoidRootPart")
        if root then
            playAbilitySound(root, "rbxassetid://78148821066860", 0.8, 1)
            createEffect(root.Position, Color3.fromRGB(200, 50, 50), 4, 0.5)
        end
    end
    
    task.delay(duration, function()
        local currentBuffs = PlayerBuffs[player]
        if currentBuffs then currentBuffs.lifesteal = 0 end
    end)
end

-- Called by combat system when dealing damage
_G.GetLifestealAmount = function(player, damageDealt)
    local buffs = PlayerBuffs[player]
    if buffs and buffs.lifesteal > 0 then
        local healAmount = damageDealt * buffs.lifesteal
        healPlayer(player, healAmount)
        return healAmount
    end
    return 0
end

 
-- THERMAL LIFT
-- Launches player upward with optional damage
-- Works both on ground and in flight
 
_G.ExecuteThermalLift = function(player, launchForce, damage, damageRadius)
    local char = player.Character
    if not char then return end
    local root = char:FindFirstChild("HumanoidRootPart")
    if not root then return end

    local position = root.Position
    playAbilitySound(root, "rbxassetid://99466751377433", 0.8, 1)

    -- Notify client for flight integration
    AbilityLiftRemote:FireClient(player, launchForce)

    -- Server-side upward force
    local bodyVel = Instance.new("BodyVelocity")
    bodyVel.MaxForce = Vector3.new(0, math.huge, 0)
    bodyVel.Velocity = Vector3.new(0, launchForce, 0)
    bodyVel.Parent = root
    Debris:AddItem(bodyVel, 0.3)

    createEffect(position, Color3.fromRGB(255, 200, 100), 8, 0.5)

    -- Damage nearby enemies
    if damage and damage > 0 and damageRadius then
        local enemies = getEnemiesInRadius(player, position, damageRadius)
        for _, enemy in ipairs(enemies) do
            dealDamage(player, enemy.player, damage)
        end
    end
end

 
-- SONIC SCREECH
-- Area stun around player
 
_G.ExecuteSonicScreech = function(player, radius, stunDuration, damage)
    local char = player.Character
    if not char then return end
    local root = char:FindFirstChild("HumanoidRootPart")
    if not root then return end

    local position = root.Position
    playAbilitySound(root, "rbxassetid://70952658337172", 1, 1)
    createEffect(position, Color3.fromRGB(255, 100, 255), radius, 0.5)

    local enemies = getEnemiesInRadius(player, position, radius)
    for _, enemy in ipairs(enemies) do
        dealDamage(player, enemy.player, damage)
        applyStun(enemy.player, stunDuration)
    end
end

 
-- METEOR DIVE
-- Ground slam with knockback physics
 
_G.ExecuteMeteorDive = function(player, damage, radius, stunDuration)
    local char = player.Character
    if not char then return end
    local root = char:FindFirstChild("HumanoidRootPart")
    if not root then return end

    damage = damage or 50

    local position = root.Position
    playAbilitySound(root, "rbxassetid://125054730486866", 1, 1)
    createEffect(position, Color3.fromRGB(255, 100, 50), radius, 1)

    local enemies = getEnemiesInRadius(player, position, radius)
    for _, enemy in ipairs(enemies) do
        dealDamage(player, enemy.player, damage)
        applyStun(enemy.player, stunDuration)
        
        -- Apply knockback using BodyVelocity
        local direction = (enemy.rootPart.Position - position).Unit
        local knockback = Instance.new("BodyVelocity")
        knockback.MaxForce = Vector3.new(math.huge, math.huge, math.huge)
        knockback.Velocity = direction * 50 + Vector3.new(0, 30, 0)
        knockback.Parent = enemy.rootPart
        Debris:AddItem(knockback, 0.3)
    end
end

 
-- TIME FREEZE (Area Slow)
-- Creates persistent slow zone
-- Affects both ground and flight movement
 
_G.ApplyAreaSlow = function(player, position, radius, slowPercent, duration)
    local char = player.Character
    if char then
        local root = char:FindFirstChild("HumanoidRootPart")
        if root then
            playAbilitySound(root, "rbxassetid://108083056111560", 1, 1)
        end
    end

    -- Create visual zone sphere
    local freezeZone = Instance.new("Part")
    freezeZone.Name = "TimeFreezeZone"
    freezeZone.Shape = Enum.PartType.Ball
    freezeZone.Size = Vector3.new(radius * 2, radius * 2, radius * 2)
    freezeZone.Position = position
    freezeZone.Anchored = true
    freezeZone.CanCollide = false
    freezeZone.CanQuery = false
    freezeZone.CanTouch = false
    freezeZone.Material = Enum.Material.ForceField
    freezeZone.Color = Color3.fromRGB(100, 200, 255)
    freezeZone.Transparency = 0.7
    freezeZone.Parent = workspace

    local innerGlow = Instance.new("Part")
    innerGlow.Name = "TimeFreezeGlow"
    innerGlow.Shape = Enum.PartType.Ball
    innerGlow.Size = Vector3.new(radius * 1.5, radius * 1.5, radius * 1.5)
    innerGlow.Position = position
    innerGlow.Anchored = true
    innerGlow.CanCollide = false
    innerGlow.CanQuery = false
    innerGlow.CanTouch = false
    innerGlow.Material = Enum.Material.Neon
    innerGlow.Color = Color3.fromRGB(150, 220, 255)
    innerGlow.Transparency = 0.8
    innerGlow.Parent = workspace

    -- Track slowed players for cleanup
    local slowedPlayers = {}
    local startTime = tick()
    local connection

    -- Continuous zone effect using Heartbeat
    connection = RunService.Heartbeat:Connect(function()
        local elapsed = tick() - startTime

        if elapsed > duration then
            connection:Disconnect()

            -- Remove slow from all affected players
            for enemyPlayer, data in pairs(slowedPlayers) do
                local enemyChar = enemyPlayer.Character
                if enemyChar then
                    local humanoid = enemyChar:FindFirstChildOfClass("Humanoid")
                    if humanoid and humanoid.Parent then
                        humanoid.WalkSpeed = data.originalSpeed
                    end
                end
                removeFlightSlow(enemyPlayer)
            end

            -- Fade out visuals
            TweenService:Create(freezeZone, TweenInfo.new(0.5), {Transparency = 1}):Play()
            TweenService:Create(innerGlow, TweenInfo.new(0.5), {Transparency = 1}):Play()
            Debris:AddItem(freezeZone, 0.6)
            Debris:AddItem(innerGlow, 0.6)
            return
        end

        local enemies = getEnemiesInRadius(player, position, radius)
        local currentEnemiesInZone = {}

        -- Apply slow to enemies entering zone
        for _, enemy in ipairs(enemies) do
            currentEnemiesInZone[enemy.player] = true

            if not slowedPlayers[enemy.player] then
                local humanoid = enemy.humanoid
                if humanoid then
                    local originalSpeed = humanoid.WalkSpeed
                    slowedPlayers[enemy.player] = {
                        originalSpeed = originalSpeed,
                    }

                    -- Ground slow
                    local newSpeed = originalSpeed * (1 - slowPercent)
                    humanoid.WalkSpeed = newSpeed

                    -- Flight slow (with long duration to maintain while in zone)
                    FlightSlowPlayers[enemy.player] = {
                        multiplier = 1 - slowPercent,
                        endTime = tick() + 9999,
                        reason = "Time Freeze",
                    }
                    FlightSlowUpdateRemote:FireClient(enemy.player, 1 - slowPercent, 9999, "Time Freeze")

                    if SlowedRemote then
                        SlowedRemote:FireClient(enemy.player, duration - elapsed)
                    end
                end
            end
        end

        -- Remove slow from players leaving zone
        for enemyPlayer, data in pairs(slowedPlayers) do
            if not currentEnemiesInZone[enemyPlayer] then
                local enemyChar = enemyPlayer.Character
                if enemyChar then
                    local humanoid = enemyChar:FindFirstChildOfClass("Humanoid")
                    if humanoid and humanoid.Parent then
                        humanoid.WalkSpeed = data.originalSpeed
                    end
                end
                removeFlightSlow(enemyPlayer)
                slowedPlayers[enemyPlayer] = nil
            end
        end
    end)
end

 
-- DECOY CLONE
-- Creates attackable clone that explodes on death
 
_G.CreateDecoyClone = function(player, cloneDuration, cloneHP, explosionDamage)
    local char = player.Character
    if not char then return end
    local root = char:FindFirstChild("HumanoidRootPart")
    if not root then return end

    playAbilitySound(root, "rbxassetid://71010790745857", 0.8, 1)

    -- Enable cloning of character parts
    for _, part in ipairs(char:GetDescendants()) do
        if part:IsA("BasePart") or part:IsA("Decal") or part:IsA("Texture") then
            part.Archivable = true
        end
    end
    char.Archivable = true

    -- Clone character
    local clone = nil
    local success = pcall(function() clone = char:Clone() end)
    if not success or not clone then return end

    clone.Name = player.Name .. "_DecoyClone"

    -- Remove scripts from clone
    for _, child in ipairs(clone:GetDescendants()) do
        if child:IsA("Script") or child:IsA("LocalScript") or child:IsA("ModuleScript") then
            child:Destroy()
        end
    end

    -- Position clone behind player
    local offset = root.CFrame.LookVector * -5
    clone:PivotTo(root.CFrame + offset)
    clone.Parent = workspace

    local cloneHumanoid = clone:FindFirstChildOfClass("Humanoid")
    if cloneHumanoid then
        cloneHumanoid.MaxHealth = cloneHP
        cloneHumanoid.Health = cloneHP

        -- Register for damage system
        registerClone(clone, player, explosionDamage, 20)

        -- Handle clone death explosion
        cloneHumanoid.Died:Connect(function()
            ActiveClones[clone] = nil

            local explosionRoot = clone:FindFirstChild("HumanoidRootPart")
            if explosionRoot then
                createEffect(explosionRoot.Position, Color3.fromRGB(255, 150, 50), 10, 0.5)
                playAbilitySound(explosionRoot, "rbxassetid://125054730486866", 1, 1)

                -- Deal explosion damage
                local enemies = getEnemiesInRadius(player, explosionRoot.Position, 20)
                for _, enemy in ipairs(enemies) do
                    dealDamage(player, enemy.player, explosionDamage)
                end
            end
            clone:Destroy()
        end)
    end

    Debris:AddItem(clone, cloneDuration)

    -- Cleanup if not killed
    task.delay(cloneDuration, function()
        if clone and clone.Parent then
            ActiveClones[clone] = nil
            clone:Destroy()
        end
    end)
end

 
-- EAGLE EYE
-- Marks all enemies and increases damage to them
 
_G.ExecuteEagleEye = function(player, duration, damageAmplify)
    local char = player.Character
    local playerRoot = char and char:FindFirstChild("HumanoidRootPart")

    if playerRoot then
        playAbilitySound(playerRoot, "rbxassetid://139619948639438", 0.8, 1)
    end

    local enemies = getAllEnemies(player)
    for _, enemy in ipairs(enemies) do
        if enemy.rootPart and enemy.rootPart.Parent then
            -- Create mark visual
            local mark = Instance.new("BillboardGui")
            mark.Name = "EagleEyeMark"
            mark.Size = UDim2.new(0, 60, 0, 60)
            mark.StudsOffset = Vector3.new(0, 5, 0)
            mark.Adornee = enemy.rootPart
            mark.Parent = enemy.character
            
            local markImage = Instance.new("ImageLabel")
            markImage.Size = UDim2.new(1, 0, 1, 0)
            markImage.BackgroundTransparency = 1
            markImage.Image = "rbxassetid://6034287594"
            markImage.ImageColor3 = Color3.fromRGB(255, 50, 50)
            markImage.Parent = mark
            
            Debris:AddItem(mark, duration)

            -- Apply damage vulnerability
            local enemyBuffs = getPlayerBuffs(enemy.player)
            enemyBuffs.damageTaken = damageAmplify
            task.delay(duration, function()
                local buffs = PlayerBuffs[enemy.player]
                if buffs then buffs.damageTaken = 1 end
            end)
        end
    end
end

 
-- GRAVITY WELL
-- Creates pull zone that slows and damages enemies
-- Affects both ground and flight movement
 
_G.CreateGravityWell = function(player, position, radius, pullForce, damagePerSecond, duration)
    local effectsFolder = Instance.new("Folder")
    effectsFolder.Name = "GravityWellEffects"
    effectsFolder.Parent = workspace

    -- Core visual (black hole)
    local blackHole = Instance.new("Part")
    blackHole.Name = "GravityWell"
    blackHole.Shape = Enum.PartType.Ball
    blackHole.Size = Vector3.new(4, 4, 4)
    blackHole.Position = position
    blackHole.Anchored = true
    blackHole.CanCollide = false
    blackHole.CanQuery = false
    blackHole.CanTouch = false
    blackHole.Material = Enum.Material.Neon
    blackHole.Color = Color3.fromRGB(20, 0, 40)
    blackHole.Parent = effectsFolder

    local gravitySound = playAbilitySound(blackHole, "rbxassetid://101162412364121", 0.8, 1, true)

    -- Distortion sphere visual
    local distortionSphere = Instance.new("Part")
    distortionSphere.Shape = Enum.PartType.Ball
    distortionSphere.Size = Vector3.new(radius * 2, radius * 2, radius * 2)
    distortionSphere.Position = position
    distortionSphere.Anchored = true
    distortionSphere.CanCollide = false
    distortionSphere.CanQuery = false
    distortionSphere.CanTouch = false
    distortionSphere.Material = Enum.Material.ForceField
    distortionSphere.Color = Color3.fromRGB(100, 50, 150)
    distortionSphere.Transparency = 0.9
    distortionSphere.Parent = effectsFolder

    local startTime = tick()
    local lastDamageTime = tick()
    local connection

    local slowedPlayers = {}
    local SLOW_PERCENT = 0.7

    connection = RunService.Heartbeat:Connect(function()
        local elapsed = tick() - startTime

        if elapsed > duration then
            connection:Disconnect()

            if gravitySound then
                gravitySound:Stop()
                gravitySound:Destroy()
            end

            -- Remove slow from all affected players
            for enemyPlayer, data in pairs(slowedPlayers) do
                local enemyChar = enemyPlayer.Character
                if enemyChar then
                    local humanoid = enemyChar:FindFirstChildOfClass("Humanoid")
                    if humanoid and humanoid.Parent then
                        humanoid.WalkSpeed = data.originalSpeed
                    end
                end
                removeFlightSlow(enemyPlayer)
            end

            effectsFolder:Destroy()
            return
        end

        local enemies = getEnemiesInRadius(player, position, radius)
        local currentEnemiesInZone = {}

        for _, enemy in ipairs(enemies) do
            currentEnemiesInZone[enemy.player] = true

            if not slowedPlayers[enemy.player] then
                local humanoid = enemy.humanoid
                if humanoid then
                    local originalSpeed = humanoid.WalkSpeed
                    slowedPlayers[enemy.player] = {
                        originalSpeed = originalSpeed,
                    }

                    -- Ground slow
                    local newSpeed = originalSpeed * (1 - SLOW_PERCENT)
                    humanoid.WalkSpeed = newSpeed

                    -- Flight slow
                    FlightSlowPlayers[enemy.player] = {
                        multiplier = 1 - SLOW_PERCENT,
                        endTime = tick() + 9999,
                        reason = "Gravity Well",
                    }
                    FlightSlowUpdateRemote:FireClient(enemy.player, 1 - SLOW_PERCENT, 9999, "Gravity Well")

                    if SlowedRemote then
                        SlowedRemote:FireClient(enemy.player, duration - elapsed)
                    end
                end
            end
        end

        -- Remove slow from players leaving zone
        for enemyPlayer, data in pairs(slowedPlayers) do
            if not currentEnemiesInZone[enemyPlayer] then
                local enemyChar = enemyPlayer.Character
                if enemyChar then
                    local humanoid = enemyChar:FindFirstChildOfClass("Humanoid")
                    if humanoid and humanoid.Parent then
                        humanoid.WalkSpeed = data.originalSpeed
                    end
                end
                removeFlightSlow(enemyPlayer)
                slowedPlayers[enemyPlayer] = nil
            end
        end

        -- Damage tick (every 0.5 seconds)
        if tick() - lastDamageTime >= 0.5 then
            lastDamageTime = tick()
            for _, enemy in ipairs(enemies) do
                dealDamage(player, enemy.player, damagePerSecond * 0.5)
            end
        end
    end)
end

 
-- DIVINE WINGS
-- Ultimate ability with speed boost, invulnerability, and contact damage
-- Affects both ground and flight speed
 
_G.ExecuteDivineWings = function(player, duration, speedBoost, contactDamage)
    local char = player.Character
    if not char then return end
    local root = char:FindFirstChild("HumanoidRootPart")
    local humanoid = char:FindFirstChildOfClass("Humanoid")
    if not root or not humanoid then return end

    playAbilitySound(root, "rbxassetid://130372402697675", 1, 1)

    -- Ground speed boost
    local originalSpeed = humanoid.WalkSpeed
    humanoid.WalkSpeed = originalSpeed * speedBoost

    -- Flight speed boost
    _G.SetFlightSpeedBuff(player, speedBoost, duration)

    applyInvulnerability(player, duration, "Divine Wings")

    -- Create aura visual
    local aura = Instance.new("Part")
    aura.Name = "DivineAura"
    aura.Shape = Enum.PartType.Ball
    aura.Size = Vector3.new(12, 12, 12)
    aura.Transparency = 0.7
    aura.Material = Enum.Material.Neon
    aura.Color = Color3.fromRGB(255, 220, 100)
    aura.CanCollide = false
    aura.Massless = true
    aura.CFrame = root.CFrame
    aura.Parent = char

    local auraWeld = Instance.new("WeldConstraint")
    auraWeld.Part0 = root
    auraWeld.Part1 = aura
    auraWeld.Parent = aura

    -- Contact damage loop
    local damageConnection
    local hitPlayers = {}

    damageConnection = RunService.Heartbeat:Connect(function()
        if not root or not root.Parent then
            damageConnection:Disconnect()
            return
        end
        
        local enemies = getEnemiesInRadius(player, root.Position, 8)
        for _, enemy in ipairs(enemies) do
            local lastHit = hitPlayers[enemy.player]
            -- Damage cooldown per player (1 second)
            if not lastHit or tick() - lastHit > 1 then
                hitPlayers[enemy.player] = tick()
                dealDamage(player, enemy.player, contactDamage)
            end
        end
    end)

    task.delay(duration, function()
        damageConnection:Disconnect()
        if humanoid and humanoid.Parent then
            humanoid.WalkSpeed = originalSpeed
        end
        if aura then aura:Destroy() end
    end)
end

 
-- STORM EMPEROR
-- Map-wide lightning strikes on all enemies
 
_G.ExecuteStormEmperor = function(player, damage, stunDuration)
    local char = player.Character
    local playerRoot = char and char:FindFirstChild("HumanoidRootPart")
    if not playerRoot then return end

    playAbilitySound(playerRoot, "rbxassetid://108675109398654", 1, 1)

    local enemies = getAllEnemies(player)

    -- Expanding shockwave visual
    local shockwave = Instance.new("Part")
    shockwave.Shape = Enum.PartType.Cylinder
    shockwave.Size = Vector3.new(1, 5, 5)
    -- Rotate cylinder to be horizontal
    shockwave.CFrame = CFrame.new(playerRoot.Position) * CFrame.Angles(0, 0, math.rad(90))
    shockwave.Anchored = true
    shockwave.CanCollide = false
    shockwave.Material = Enum.Material.Neon
    shockwave.Color = Color3.fromRGB(255, 255, 100)
    shockwave.Transparency = 0.5
    shockwave.Parent = workspace

    TweenService:Create(shockwave, TweenInfo.new(1), {
        Size = Vector3.new(1, 200, 200),
        Transparency = 1
    }):Play()
    Debris:AddItem(shockwave, 1)

    -- Staggered lightning strikes on each enemy
    for i, enemy in ipairs(enemies) do
        task.delay(i * 0.15, function()
            if enemy.rootPart and enemy.rootPart.Parent then
                -- Lightning from sky
                local skyPos = enemy.rootPart.Position + Vector3.new(math.random(-10, 10), 100, math.random(-10, 10))
                createLightningEffect(skyPos, enemy.rootPart.Position, Color3.fromRGB(255, 255, 100))
                createEffect(enemy.rootPart.Position, Color3.fromRGB(255, 255, 150), 5, 0.4)
                dealDamage(player, enemy.player, damage)
                applyStun(enemy.player, stunDuration)
            end
        end)
    end
end

 
-- COMBAT SYSTEM INTEGRATION
 

-- Check if player has invulnerability buff
_G.IsPlayerInvulnerable = function(player)
    local buffs = PlayerBuffs[player]
    return buffs and buffs.invulnerable == true
end

-- Get damage amplifier for victim (from Eagle Eye, etc.)
_G.GetDamageAmplifier = function(victim)
    local buffs = PlayerBuffs[victim]
    if buffs and buffs.damageTaken and buffs.damageTaken > 1 then
        return buffs.damageTaken
    end
    return 1
end

--[[
    Full combat damage processing with all modifiers
    Called by main combat system for complete damage calculation
    
    @param attacker - Attacking player
    @param victim - Target player
    @param baseDamage - Pre-modifier damage
    @return number - Final damage after all modifiers
]]
_G.ProcessCombatDamage = function(attacker, victim, baseDamage)
    local victimBuffs = PlayerBuffs[victim]
    
    -- Check invulnerability
    if victimBuffs and victimBuffs.invulnerable then
        return 0
    end
    
    -- Apply shield
    local actualDamage = _G.CheckShield(victim, baseDamage)
    
    -- Apply damage amplification
    if victimBuffs and victimBuffs.damageTaken and victimBuffs.damageTaken > 1 then
        actualDamage = actualDamage * victimBuffs.damageTaken
    end
    
    -- Process lifesteal for attacker
    if actualDamage > 0 then
        _G.GetLifestealAmount(attacker, actualDamage)
    end
    
    return actualDamage
end
