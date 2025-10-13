-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

-- Module references
local ServerModules = ServerStorage:WaitForChild("Modules")
local ReplicatedModules = ReplicatedStorage:WaitForChild("Modules")
local ServerActionsModules = ServerModules.Actions

-- Service imports
local ProfileStore = require(ServerModules.Services.ProfileStore)
local RemoteProtecterService = require(ServerModules.Services.RemoteProtecterService)
local RarityService = require(ServerModules.Services.RarityService)

-- Core managers for different character races/types
local CosmeticManager = require(ServerModules.Core.CosmeticManager)
local LostSoulManager = require(ServerModules.Core.LostSoulManager)
local HumanManager = require(ServerModules.Core.HumanManager)
local ShinigamiManager = require(ServerModules.Core.ShinigamiManager)
local ArrancarManager = require(ServerModules.Core.ArrancarManager)
local QuincyManager = require(ServerModules.Core.QuincyManager)
local FullbringerManager = require(ServerModules.Core.FullbringerManager)
local ServerManager = require(ServerModules.Core.ServerManager)
local ReiatsuManager = require(ServerModules.Core.ReiatsuManager)
local TimeCycleService = require(ServerModules.Services.TimeCycleService)

-- Shared utilities
local Debris = require(ReplicatedModules.Shared.Debris)
local AttributeHandler = require(ReplicatedModules.Shared.AttributeHandler)

-- Remote events for client communication
local UI = ReplicatedStorage.Remotes.UI
local FX = ReplicatedStorage.Remotes.FX

-- Module setup
local module = {}

-- State management tables
local originalStates = {} -- Stores original humanoid properties (WalkSpeed, JumpPower, AutoRotate)
local activeConnections = {} -- Tracks active connections per player for cleanup
local pendingTasks = {} -- Tracks delayed tasks that can be cancelled

-- Effects that should be preserved before character cleanup
local effectsBeforeCleanup = {"Loaded", "Footsteps"}

-- Retrieves or initializes the original state for a player's humanoid
-- @param player: The player whose state to retrieve
-- @return: Table containing WalkSpeed, JumpPower, and AutoRotate values
local function getState(player)
	if not originalStates[player] then
		local char = player.Character
		if not char or not char:FindFirstChild("Humanoid") then return end

		local humanoid = char:FindFirstChild("Humanoid")
		originalStates[player] = {
			WalkSpeed = humanoid.WalkSpeed,
			JumpPower = humanoid.JumpPower,
			AutoRotate = humanoid.AutoRotate
		}
	end

	return originalStates[player]
end

-- Cleans up all player-related data when they leave
-- Disconnects connections, cancels pending tasks, removes state data
-- @param player: The player to clean up
local function cleanupPlayer(player)
	originalStates[player] = nil

	-- Disconnect all active connections
	if activeConnections[player] then
		for _, connection in pairs(activeConnections[player]) do
			if connection.Connected then
				connection:Disconnect()
			end
		end
		activeConnections[player] = nil
	end

	-- Cancel all pending tasks
	if pendingTasks[player] then
		for _, task in pairs(pendingTasks[player]) do
			task.Cancel = true
		end
		pendingTasks[player] = nil
	end
end

-- Cleanup when player leaves the game
Players.PlayerRemoving:Connect(cleanupPlayer)

-- Creates a delayed task that can be cancelled if player leaves
-- @param player: The player associated with this task
-- @param duration: Time in seconds before callback executes
-- @param callback: Function to execute after duration
local function createDelayedTask(player, duration, callback)
	if not pendingTasks[player] then
		pendingTasks[player] = {}
	end

	local taskData = {Cancel = false}
	table.insert(pendingTasks[player], taskData)

	task.delay(duration, function()
		-- Only execute if not cancelled
		if not taskData.Cancel then
			callback()
		end

		-- Remove task from pending list
		if pendingTasks[player] then
			for i, task in ipairs(pendingTasks[player]) do
				if task == taskData then
					table.remove(pendingTasks[player], i)
					break
				end
			end
		end
	end)
end

-- Sets the player's walk speed, optionally reverting after a duration
-- @param player: Target player
-- @param speed: New walk speed value
-- @param duration: Optional time before reverting to original speed
function module:SetWalkSpeed(player: Player, speed: number, duration: number?)
	local char = player.Character
	if not char then return end

	local humanoid = char:FindFirstChild("Humanoid")
	if not humanoid then return end

	local state = getState(player)
	humanoid.WalkSpeed = speed

	-- Revert after duration if specified
	if duration then
		createDelayedTask(player, duration, function()
			if humanoid and humanoid.Parent and originalStates[player] then
				humanoid.WalkSpeed = state.WalkSpeed
			end
		end)
	end
end

-- Sets the player's jump power, optionally reverting after a duration
-- @param player: Target player
-- @param power: New jump power value
-- @param duration: Optional time before reverting to original power
function module:SetJumpPower(player: Player, power: number, duration: number?)
	local char = player.Character
	if not char then return end

	local humanoid = char:FindFirstChild("Humanoid")
	if not humanoid then return end

	local state = getState(player)
	humanoid.JumpPower = power

	-- Revert after duration if specified
	if duration then
		createDelayedTask(player, duration, function()
			if humanoid and humanoid.Parent and originalStates[player] then
				humanoid.JumpPower = state.JumpPower
			end
		end)
	end
end

-- Sets whether the humanoid auto-rotates to face movement direction
-- @param player: Target player
-- @param enabled: Whether auto-rotate should be enabled
-- @param duration: Optional time before reverting to original setting
function module:SetAutoRotate(player: Player, enabled: boolean, duration: number?)
	local char = player.Character
	if not char then return end

	local humanoid = char:FindFirstChild("Humanoid")
	if not humanoid then return end

	local state = getState(player)
	humanoid.AutoRotate = enabled

	-- Revert after duration if specified
	if duration then
		createDelayedTask(player, duration, function()
			if humanoid and humanoid.Parent and originalStates[player] then
				humanoid.AutoRotate = state.AutoRotate
			end
		end)
	end
end

-- Waits for the player's character appearance to load with timeout
-- @param player: Player to wait for
-- @param timeoutDuration: Maximum wait time in seconds (default: 10)
function module:WaitForCharacterAppearance(player, timeoutDuration)
	timeoutDuration = timeoutDuration or 10
	local startTime = tick()

	-- Wait until appearance loads or timeout
	while not player:HasAppearanceLoaded() and (tick() - startTime) < timeoutDuration do
		task.wait(0.1)
	end
end

-- Creates and plays a sound with automatic cleanup
-- @param player: Player (currently unused but available for future use)
-- @param params: Table containing SoundName, SoundLocation, SoundParent, Duration, PlaySound
-- @return: The created Sound instance or nil if failed
function module:CreateSound(player, params)
	local soundName = params.SoundName
	local soundLocation = params.SoundLocation
	local soundParent = params.SoundParent
	local duration = params.Duration
	local playSound = params.PlaySound

	-- Validate required parameters
	if not soundName or not soundLocation or not soundParent then
		warn("Invalid CreateSound Params")
		return
	end

	local soundObject

	-- Find sound in appropriate storage location
	if soundLocation == "Server" then
		soundObject = ServerStorage.Assets.Sounds:FindFirstChild(soundName, true)
	elseif soundLocation == "Replicated" then
		soundObject = ReplicatedStorage.Assets.Sounds:FindFirstChild(soundName, true)
	end

	if soundObject then
		local newSound : Sound = soundObject:Clone()
		newSound.Parent = soundParent

		-- Play sound if requested and set duration
		if playSound then
			newSound:Play()
			duration = duration or newSound.TimeLength + 0.1
		else
			duration = duration or 10
		end

		-- Auto-cleanup after duration
		Debris:AddItem(newSound, duration)
		return newSound
	end
end

-- Spawns the player's character at the appropriate location
-- Sets up spawn protection, visual effects, and race-specific setup
-- @param player: The player to spawn
-- @param character: The character model to spawn
function module:SpawnCharacter(player, character)
	local humanoid = character.Humanoid
	local rootPart = character.HumanoidRootPart

	-- Determine spawn location based on player's saved location
	local spawns = workspace.Spawns.Players
	local location = ProfileStore:Get(player, "Location")
	local spawnFolder = spawns:FindFirstChild(location)

	-- Fallback to any valid spawn if saved location doesn't exist
	if not spawnFolder or #spawnFolder:GetChildren() == 0 then
		for _, container in pairs(spawns:GetChildren()) do
			if #container:GetChildren() ~= 0 and container:FindFirstChildOfClass("Part") then
				spawnFolder = container
				break
			end
		end
	end

	-- Choose random spawn point and teleport character
	local randomSpawn = spawnFolder:GetChildren()[math.random(1, #spawnFolder:GetChildren())]
	character:PivotTo(randomSpawn.CFrame)

	-- Remove any existing ForceFields
	for _, item in pairs(character:GetChildren()) do
		if item:IsA("ForceField") then
			item:Destroy()
		end
	end

	-- Add female body part if applicable
	if ProfileStore:Get(player, "Character.Gender") == "Female" and not character:FindFirstChild("WomanTorso") then
		local WomanTorso = ServerStorage.Assets.Models.WomanTorso:Clone()
		WomanTorso.Parent = character
	end

	-- Create spawn protection forcefield (invisible)
	local ForceField = Instance.new("ForceField")
	ForceField.Parent = character
	ForceField.Name = "SpawnProtection"
	ForceField.Visible = false

	-- Trigger spawn effect on client
	FX:FireClient(player, "Client", "SpawnEffect", {
		["Method"] = "Add",
		["Duration"] = 5
	})

	-- Initialize reiatsu (energy system)
	ReiatsuManager:SetReiatsu(player, 40)
	
	-- Set default movement values if not running
	if not AttributeHandler:Find(character, "Run") then
		self:SetWalkSpeed(player, 16)
		self:SetJumpPower(player, 40)
	end

	local race = ProfileStore:Get(player, "Character.Race")

	-- Wait for character appearance to load
	self:WaitForCharacterAppearance(player, 5)

	-- Setup race-specific features and UI visibility
	if race == "LostSoul" then
		LostSoulManager:SetupCharacter(player, character)
		
		UI:FireClient(player, "SetUIVisible", {
			UIName = "Flashstep",
			ParentName = "Bars",
			IsVisible = false
		})
	elseif race == "Human" then
		HumanManager:SetupCharacter(player, character)
		
		UI:FireClient(player, "SetUIVisible", {
			UIName = "Flashstep",
			ParentName = "Bars",
			IsVisible = false
		})
	elseif race == "Shinigami" then
		ShinigamiManager:SetupCharacter(player, character)
		
		UI:FireClient(player, "SetUIVisible", {
			UIName = "Flashstep",
			ParentName = "Bars",
			IsVisible = true
		})
	elseif race == "Arrancar" then
		ArrancarManager:SetupCharacter(player, character)
		
		UI:FireClient(player, "SetUIVisible", {
			UIName = "Flashstep",
			ParentName = "Bars",
			IsVisible = true
		})
	elseif race == "Quincy" then
		QuincyManager:SetupCharacter(player, character)
		
		UI:FireClient(player, "SetUIVisible", {
			UIName = "Flashstep",
			ParentName = "Bars",
			IsVisible = true
		})
	elseif race == "Fullbringer" then
		FullbringerManager:SetupCharacter(player, character)
		
		UI:FireClient(player, "SetUIVisible", {
			UIName = "Flashstep",
			ParentName = "Bars",
			IsVisible = true
		})
	end

	-- Check and apply character attributes
	self:CheckAttributes(player, character)

	-- Apply saved hair color
	local HairColorR = ProfileStore:Get(player, "Character.HairColorR")
	local HairColorG = ProfileStore:Get(player, "Character.HairColorG")
	local HairColorB = ProfileStore:Get(player, "Character.HairColorB")

	CosmeticManager:Hair(player, {
		["Method"] = "ChangeColor",
		["R"] = HairColorR,
		["G"] = HairColorG,
		["B"] = HairColorB
	})
	
	-- Apply footstep settings
	local Footsteps = ProfileStore:Get(player, "Settings.Footsteps")
	if Footsteps then
		AttributeHandler:Remove(character, "Footsteps")
		AttributeHandler:Add(character, "Footsteps")
	end
	
	-- Apply player settings
	local ambienceVolume = ProfileStore:Get(player, "Settings.Volume")
	local hideNames = ProfileStore:Get(player, "Settings.HideNames")
	
	if hideNames then
		FX:FireClient(player, "Client", "Settings", {
			["SettingType"] = "HideNames",
			["Status"] = true
		})
	end
		
	FX:FireClient(player, "Client", "Settings", {
		["SettingType"] = "Ambience",
		["Volume"] = ambienceVolume
	})

	-- Remove spawn protection after 6 seconds
	Debris:AddItem(ForceField, 6)
end

-- Checks and initializes player data, creates new character if needed
-- Updates leaderboard and sends server info to client
-- @param player: Player whose data to check
function module:CheckData(player)	
	local data = ProfileStore:GetCurrentSlotData(player)

	-- Initialize new player data if first time playing
	if not data.Character.Created and data.Character.Clan == "" then
		ProfileStore:Update(player, "Character.Created", function()
			return true
		end)

		-- Show character creation UI
		UI:FireClient(player, "NewGame", {
			["Method"] = "Enable"
		})

		-- Generate random hair and eye colors
		local HairColors = RarityService:RollColor()
		local EyeColors = RarityService:RollColor()

		-- Save hair color RGB values
		ProfileStore:Update(player, "Character.HairColorR", function()
			return HairColors.R
		end)

		ProfileStore:Update(player, "Character.HairColorG", function()
			return HairColors.G
		end)

		ProfileStore:Update(player, "Character.HairColorB", function()
			return HairColors.B
		end)

		-- Save eye color RGB values
		ProfileStore:Update(player, "Character.EyeColorR", function()
			return EyeColors.R
		end)

		ProfileStore:Update(player, "Character.EyeColorG", function()
			return EyeColors.G
		end)

		ProfileStore:Update(player, "Character.EyeColorB", function()
			return EyeColors.B
		end)
	end

	-- Build display name with clan if applicable
	local ingameName = ProfileStore:Get(player, "Name")
	local faction = ProfileStore:Get(player, "Race")
	if data.Character.Clan then
		ingameName = ingameName .. " " .. data.Character.Clan
	end

	-- Update leaderboard for all clients
	UI:FireAllClients("Leaderboard", {
		["Method"] = "Create",
		["PlayerName"] = player.Name,
		["Name"] = ingameName,
		["Faction"] = faction
	})

	-- Send server info to player
	UI:FireClient(player, "ServerInfo", {
		["ServerName"] = ServerManager.GetServerName(),
		["ServerAge"] = ServerManager.GetUptimeFormatted(),
		["ServerRegion"] = ServerManager.GetServerRegion()
	})
	
	-- Send current time of day to player
	FX:FireClient(player, "Client", "UpdateTime", {
		["TOD"] = TimeCycleService.GetCurrentPeriod()
	})
end

-- Placeholder for checking and applying character attributes
-- @param player: The player
-- @param character: The character model
function module:CheckAttributes(player : Player, character : Model)
	-- Implementation to be added
end

-- Called when a player's character is added to the game
-- Sets up the character model, fake head, and spawning logic
-- @param player: The player whose character was added
-- @param character: The character model that was added
module.OnCharacterAdded = function(player, character)
	local humanoid = character.Humanoid
	local rootPart = character.HumanoidRootPart
	local head = character.Head

	-- Create fake head for animations/effects
	local FakeHead = ServerStorage.Assets.Models.FakeHead:Clone()
	local FakeHead6D = ServerStorage.Assets.Models.FakeHeadWeld:Clone()

	-- Weld fake head to real head
	FakeHead6D.Part0 = head
	FakeHead6D.Part1 = FakeHead
	FakeHead6D.Parent = head
	FakeHead.Parent = character
	FakeHead:PivotTo(head.CFrame)

	-- Initialize attribute system for this character
	AttributeHandler:Create(character)

	-- Show loading state for non-studio environments if not loaded
	if not player:GetAttribute("Loaded") and not RunService:IsStudio() then
		AttributeHandler:Add(character, "Loading")
	else
		-- Wait for player profile to be ready
		ProfileStore:OnProfileReady(player, false):await()

		-- Initialize connection tracking for this player
		if not activeConnections[player] then
			activeConnections[player] = {}
		end

		local hasSpawned = false

		task.wait(0.2)

		-- Helper to clean up all connections for this player
		local function cleanupConnections()
			if activeConnections[player] then
				for _, connection in pairs(activeConnections[player]) do
					if connection.Connected then
						connection:Disconnect()
					end
				end
				activeConnections[player] = {}
			end
		end

		-- Monitor character state and spawn when ready
		activeConnections[player].heartbeat = RunService.Heartbeat:Connect(function()
			if not player.Parent or humanoid.Health == 0 then
				cleanupConnections()
			else
				if not hasSpawned then
					hasSpawned = true
					module:SpawnCharacter(player, character)
					cleanupConnections()
				end
			end
		end)

		-- Cleanup if player leaves
		activeConnections[player].playerRemoving = Players.PlayerRemoving:Connect(function(leavingPlayer)
			if leavingPlayer == player then
				cleanupConnections()
			end
		end)

		-- Cleanup on death
		activeConnections[player].died = humanoid.Died:Connect(function()
			cleanupConnections()
		end)
	end
	
	-- Update hide names setting for other players who have it enabled
	for _, otherPlayer in pairs(Players:GetPlayers()) do
		if otherPlayer == player then
			continue
		end

		local otherCharacter = otherPlayer.Character
		if not otherCharacter then
			continue
		end

		-- Refresh hide names setting for players who have it enabled
		if 
			ProfileStore:IsProfileLoaded(otherPlayer) and
			ProfileStore:Get(otherPlayer, "Settings.HideNames")
		then
			FX:FireClient(otherPlayer, "Client", "Settings", {
				["SettingType"] = "HideNames",
				["Status"] = true
			})
		end
	end
end

-- Called when a player's character is being removed
-- Cleans up attributes, effects, and connections
-- @param player: The player whose character is being removed
-- @param character: The character model being removed
module.OnCharacterRemoving = function(player, character)
	-- Get debug info about active effects
	local debugInfo = AttributeHandler:GetDebugInfo(character)

	-- Store effect counts before cleanup for debugging
	if debugInfo and debugInfo.Effects then
		for effectName, effectData in pairs(debugInfo.Effects) do
			if effectData.Count > 0 then
				effectsBeforeCleanup[effectName] = effectData.Count
			end
		end
	end

	-- Safely cleanup all effects and attributes
	local cleanupSuccess = pcall(function()
		AttributeHandler:RemoveAllEffects(character)
		AttributeHandler:RemoveProfile(character)
	end)

	-- Log cleanup status
	if not cleanupSuccess then
		warn("Cleanup failed for character:", character.Name)
	else
		-- Log which effects were cleaned up (for debugging)
		if next(effectsBeforeCleanup) then
			local effectNames = {}
			for effectName, count in pairs(effectsBeforeCleanup) do
				table.insert(effectNames, effectName .. "(" .. count .. ")")
			end
		end
	end

	-- Clean up player-specific data
	cleanupPlayer(player)
end

-- Called when character appearance finishes loading
-- Resets the character's appearance to default (removes accessories, clothing, etc.)
-- @param player: The player whose appearance loaded
-- @param character: The character model
module.OnCharacterAppearanceLoaded = function(player, character)
	local humanoid = character:WaitForChild("Humanoid")
	local currentDescription = humanoid:GetAppliedDescription():Clone()

	-- Body parts to reset to default
	local partsToReset = {"Head", "Torso", "RightArm", "LeftArm", "RightLeg", "LeftLeg"}
	local clothes = {"ShirtGraphic"}
	
	-- Accessory types to remove
	local accessoriesToReset = {
		"FaceAccessory", "NeckAccessory", "ShouldersAccessory",
		"FrontAccessory", "BackAccessory", "WaistAccessory",
		"HatAccessory"
	}

	-- Reset body part IDs to 0 (default)
	for _, part in ipairs(partsToReset) do
		currentDescription[part] = 0
	end

	-- Clear accessory IDs
	for _, accessory in ipairs(accessoriesToReset) do
		currentDescription[accessory] = ""
	end

	-- Remove clothing items
	for _, item in pairs(character:GetChildren()) do
		if table.find(clothes, item.ClassName) then
			item:Destroy()
		end

		-- Replace hair textures with default
		if item:IsA("Accessory") and item.AccessoryType == Enum.AccessoryType.Hair then
			for _, hairItem in pairs(item:GetDescendants()) do
				if hairItem:IsA("SpecialMesh") then
					hairItem.TextureId = "rbxassetid://4486606505"
				end
			end
		end
	end

	-- Remove face decal
	local head = character:FindFirstChild("Head")
	if head then
		local faceDecal = head:FindFirstChildOfClass("Decal")
		if faceDecal then
			faceDecal:Destroy()
		end
	end

	-- Apply the cleaned description
	humanoid:ApplyDescription(currentDescription)

	-- Move character to alive players folder
	character.Parent = workspace.Alive.Players
end

return module
