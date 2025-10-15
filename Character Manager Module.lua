--!strict
-- CharacterManager.lua

-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage") -- provides storage replicated to all clients, used for shared assets
local ServerStorage = game:GetService("ServerStorage") -- server-only storage, assets hidden from clients
local RunService = game:GetService("RunService") -- provides update loops like Heartbeat, Stepped, useful for continuous checks
local Players = game:GetService("Players") -- player service tracks joining/leaving players
local DebrisService = game:GetService("Debris") -- service that automatically removes objects after a set lifetime

-- Module references
local ServerModules = ServerStorage:WaitForChild("Modules") -- container for server-side modules
local ReplicatedModules = ReplicatedStorage:WaitForChild("Modules") -- container for shared modules between client & server

local ProfileStore = require(ServerModules.Services.ProfileStore) -- CRUD handler for player data
local RemoteProtecterService = require(ServerModules.Services.RemoteProtecterService) -- ensures remote calls are secure
local RarityService = require(ServerModules.Services.RarityService) -- generates random rarity-based values

local CosmeticManager = require(ServerModules.Core.CosmeticManager) -- manages player cosmetic appearance
local LostSoulManager = require(ServerModules.Core.LostSoulManager) -- race-specific setup logic
local HumanManager = require(ServerModules.Core.HumanManager) -- race-specific setup logic
local ShinigamiManager = require(ServerModules.Core.ShinigamiManager) -- race-specific setup logic
local ArrancarManager = require(ServerModules.Core.ArrancarManager) -- race-specific setup logic
local QuincyManager = require(ServerModules.Core.QuincyManager) -- race-specific setup logic
local FullbringerManager = require(ServerModules.Core.FullbringerManager) -- race-specific setup logic
local ServerManager = require(ServerModules.Core.ServerManager) -- manages metadata about the current server
local ReiatsuManager = require(ServerModules.Core.ReiatsuManager) -- manages energy/mana system
local TimeCycleService = require(ServerModules.Services.TimeCycleService) -- provides the current time-of-day info

local Debris = require(ReplicatedModules.Shared.Debris) -- utility wrapper for timed object removal
local AttributeHandler = require(ReplicatedModules.Shared.AttributeHandler) -- provides API for adding/removing character attributes

local UI = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("UI") -- remote events to communicate UI updates to clients
local FX = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("FX") -- remote events to trigger visual/audio effects

-- Module table
local module: {[string]: any} = {} -- container for exported functions

-- State containers
local originalStates: {[Player]: {WalkSpeed: number, JumpPower: number, AutoRotate: boolean}} = {} -- caches original humanoid states
local activeConnections: {[Player]: {[string]: RBXScriptConnection}} = {} -- tracks all connections for cleanup
local pendingTasks: {[Player]: {[number]: {Cancel: boolean}}} = {} -- stores delayed tasks with cancel flags
local effectsBeforeCleanup: {[string]: number} = {} -- snapshot of effect counts before removing player

-- Safe retrieval of character & humanoid
local function getCharacterAndHumanoid(player: Player)
	local char = player.Character -- attempt to retrieve the character
	if not char then return nil, nil end -- return nils if character not spawned
	local hum = char:FindFirstChildOfClass("Humanoid") -- search for Humanoid instance
	return char, hum -- return both for convenience
end

-- Capture and cache humanoid properties once per player
local function captureOriginalStateOnce(player: Player)
	if originalStates[player] then return originalStates[player] end -- return cached if exists
	local char, humanoid = getCharacterAndHumanoid(player) -- get current humanoid
	if not humanoid then return nil end -- abort if not available
	originalStates[player] = { -- store baseline WalkSpeed, JumpPower, AutoRotate for safe restoration
		WalkSpeed = humanoid.WalkSpeed,
		JumpPower = humanoid.JumpPower,
		AutoRotate = humanoid.AutoRotate
	}
	return originalStates[player] -- return stored state
end

-- Wrapper to safely update ProfileStore with reduced function repetition
local function profileSet(player: Player, key: string, value: any)
	ProfileStore:Update(player, key, function()
		return value -- returns the desired value for profile update
	end)
end

-- Batched update for RGB color components
local function profileSetColorRGB(player: Player, prefix: string, color: {R: number, G: number, B: number})
	for _, channel in ipairs({"R", "G", "B"}) do -- iterate each color component
		ProfileStore:Update(player, ("Character.%s%s"):format(prefix, channel), function()
			return color[channel] or 0 -- fallback to 0 if value missing
		end)
	end
end

-- Sends initialization packets to client
local function sendStartupPackets(player: Player, extra: {[string]: any}?)
	UI:FireAllClients("Leaderboard", { -- update leaderboard info
		Method = "Create",
		PlayerName = player.Name,
		Name = extra and extra.IngameName or ProfileStore:Get(player, "Name"),
		Faction = extra and extra.Faction or ProfileStore:Get(player, "Race")
	})

	UI:FireClient(player, "ServerInfo", { -- provide metadata for server info display
		ServerName = ServerManager.GetServerName(),
		ServerAge = ServerManager.GetUptimeFormatted(),
		ServerRegion = ServerManager.GetServerRegion()
	})

	FX:FireClient(player, "Client", "UpdateTime", { -- synchronize client time-of-day visuals
		TOD = TimeCycleService.GetCurrentPeriod()
	})
end

-- Creates a delayed task with cancellation support
local function createDelayedTask(player: Player, duration: number, callback: () -> ())
	if not pendingTasks[player] then pendingTasks[player] = {} end -- ensure table exists
	local taskData = {Cancel = false} -- flag to cancel execution
	table.insert(pendingTasks[player], taskData) -- append to task list
	local myIndex = #pendingTasks[player] -- store index for safe removal

	task.delay(duration, function() -- execute callback after duration
		local tasksList = pendingTasks[player]
		if not tasksList or not tasksList[myIndex] then return end -- skip if task removed
		if not tasksList[myIndex].Cancel then -- execute only if not canceled
			callback()
		end
		if pendingTasks[player] then -- cleanup this task
			for i = myIndex, 1, -1 do
				if pendingTasks[player][i] == taskData then
					table.remove(pendingTasks[player], i) -- remove from list safely
					break
				end
			end
		end
	end)

	return { -- return handle to allow cancellation externally
		Cancel = function()
			taskData.Cancel = true
		end
	}
end

-- Disconnect all active event connections for a player
local function disconnectAllConnectionsForPlayer(player: Player)
	if activeConnections[player] then
		for _, conn in pairs(activeConnections[player]) do
			if conn and conn.Connected then
				conn:Disconnect() -- terminate connection safely
			end
		end
		activeConnections[player] = nil -- clear reference
	end
end

-- Cancel all pending delayed tasks for a player
local function cancelAllPendingTasksForPlayer(player: Player)
	if pendingTasks[player] then
		for _, t in ipairs(pendingTasks[player]) do
			t.Cancel = true -- mark each task canceled
		end
		pendingTasks[player] = nil -- clear reference
	end
end

-- Performs full cleanup of player state and resources
local function cleanupPlayer(player: Player)
	originalStates[player] = nil -- remove cached humanoid properties
	disconnectAllConnectionsForPlayer(player) -- disconnect all bound events
	cancelAllPendingTasksForPlayer(player) -- cancel any delayed executions
end

-- Connect cleanup to player leaving event
Players.PlayerRemoving:Connect(cleanupPlayer) -- automatically cleanup when player leaves

-- Choose a random spawn CFrame from a folder of spawns
local function chooseSpawnCFrame(spawnFolder: Instance)
	local children = spawnFolder:GetChildren() -- fetch all possible spawn points
	if #children == 0 then -- fallback if no spawns exist
		return workspace:FindFirstChild("SpawnLocation") and workspace.SpawnLocation.CFrame or CFrame.new(Vector3.new(0, 5, 0))
	end
	local idx = math.random(1, #children) -- select a random index
	local chosen = children[idx]
	if chosen:IsA("BasePart") then
		local offset = Vector3.new(
			(math.random() - 0.5) * 2, -- random X offset in [-1,1]
			0, -- no Y offset
			(math.random() - 0.5) * 2 -- random Z offset in [-1,1]
		)
		local rot = CFrame.Angles(0, math.rad(math.random(0, 360)), 0) -- random Y rotation
		return CFrame.new(chosen.Position + offset) * rot -- combine position and rotation
	elseif chosen:IsA("Model") and chosen:FindFirstChildOfClass("BasePart") then
		local part = chosen:FindFirstChildOfClass("BasePart")
		local offset = Vector3.new((math.random() - 0.5) * 2, 0, (math.random() - 0.5) * 2)
		local rot = CFrame.Angles(0, math.rad(math.random(0, 360)), 0)
		return part.CFrame * CFrame.new(offset) * rot -- apply model basepart as spawn reference
	else
		return chosen.CFrame or CFrame.new(Vector3.new(0, 5, 0)) -- fallback to default CFrame
	end
end

-- Safely sets WalkSpeed and optionally reverts after duration
function module:SetWalkSpeed(player: Player, speed: number, duration: number?)
	local char, humanoid = getCharacterAndHumanoid(player)
	if not humanoid then return end -- skip if humanoid missing
	local state = captureOriginalStateOnce(player) -- cache original state
	humanoid.WalkSpeed = speed -- set new speed immediately
	if type(duration) == "number" and duration > 0 then
		createDelayedTask(player, duration, function() -- schedule reversion
			local c, h = getCharacterAndHumanoid(player)
			if h and originalStates[player] then
				h.WalkSpeed = state.WalkSpeed -- revert safely
			end
		end)
	end
end

-- Safely sets JumpPower and optionally reverts after duration
function module:SetJumpPower(player: Player, power: number, duration: number?)
	local char, humanoid = getCharacterAndHumanoid(player)
	if not humanoid then return end
	local state = captureOriginalStateOnce(player)
	humanoid.JumpPower = power
	if type(duration) == "number" and duration > 0 then
		createDelayedTask(player, duration, function()
			local c, h = getCharacterAndHumanoid(player)
			if h and originalStates[player] then
				h.JumpPower = state.JumpPower
			end
		end)
	end
end

-- Safely sets AutoRotate and optionally reverts after duration
function module:SetAutoRotate(player: Player, enabled: boolean, duration: number?)
	local char, humanoid = getCharacterAndHumanoid(player)
	if not humanoid then return end
	local state = captureOriginalStateOnce(player)
	humanoid.AutoRotate = enabled
	if type(duration) == "number" and duration > 0 then
		createDelayedTask(player, duration, function()
			local c, h = getCharacterAndHumanoid(player)
			if h and originalStates[player] then
				h.AutoRotate = state.AutoRotate
			end
		end)
	end
end

-- Non-blocking wait for character appearance, returns true if loaded within timeout
function module:WaitForCharacterAppearance(player: Player, timeoutDuration: number?)
	timeoutDuration = timeoutDuration or 10 -- default timeout
	local start = os.clock() -- capture start time
	while not player:HasAppearanceLoaded() and (os.clock() - start) < timeoutDuration do
		task.wait(0.1) -- yield to avoid blocking
	end
	return player:HasAppearanceLoaded() -- return final appearance state
end

-- Creates and optionally plays a sound with auto cleanup
function module:CreateSound(player: Player, params: {SoundName: string?, SoundLocation: string?, SoundParent: Instance?, Duration: number?, PlaySound: boolean?})
	if not params then return nil end -- require params table
	local name = params.SoundName
	local location = params.SoundLocation
	local parent = params.SoundParent
	local duration = params.Duration
	local play = params.PlaySound
	if not name or not location or not parent then
		warn("[CreateSound] missing params")
		return nil
	end

	local soundObject: Sound? = nil
	if location == "Server" then
		soundObject = ServerStorage:FindFirstChild("Assets") and ServerStorage.Assets:FindFirstChild("Sounds") and ServerStorage.Assets.Sounds:FindFirstChild(name, true)
	elseif location == "Replicated" then
		soundObject = ReplicatedStorage:FindFirstChild("Assets") and ReplicatedStorage.Assets:FindFirstChild("Sounds") and ReplicatedStorage.Assets.Sounds:FindFirstChild(name, true)
	end

	if not soundObject then
		warn("[CreateSound] sound not found:", name, location)
		return nil
	end

	local newSound = soundObject:Clone() -- clone to avoid modifying original asset
	newSound.Parent = parent -- attach to target parent
	if play then
		newSound:Play() -- start playing immediately
		duration = duration or (newSound.TimeLength + 0.1) -- auto remove after sound length
	else
		duration = duration or 10 -- default lifetime if not playing
	end

	Debris:AddItem(newSound, duration) -- ensure auto cleanup
	return newSound -- return reference for optional further manipulation
end

-- Main function to spawn and setup a character
function module:SpawnCharacter(player: Player, character: Model)
	if not player or not character then return end
	local humanoid = character:FindFirstChildOfClass("Humanoid") -- retrieve humanoid
	local root = character:FindFirstChild("HumanoidRootPart") -- retrieve root for positioning
	if not humanoid or not root then return end

	-- Determine spawn location from saved data
	local spawns = workspace:FindFirstChild("Spawns") and workspace.Spawns:FindFirstChild("Players")
	local loc = ProfileStore:Get(player, "Location")
	local spawnFolder = nil
	if spawns and loc then
		spawnFolder = spawns:FindFirstChild(loc)
	end
	if not spawnFolder or #spawnFolder:GetChildren() == 0 then
		for _, container in ipairs(spawns:GetChildren()) do
			if #container:GetChildren() > 0 and container:FindFirstChildOfClass("BasePart") then
				spawnFolder = container -- pick first valid container
				break
			end
		end
	end

	-- fallback if no spawn found
	local targetCFrame = chooseSpawnCFrame(spawnFolder or workspace)
	character:PivotTo(targetCFrame + Vector3.new(0, 2.2, 0)) -- apply spawn position with Y offset

	-- Defensive removal of existing ForceFields
	for _, item in ipairs(character:GetChildren()) do
		if item:IsA("ForceField") then
			item:Destroy()
		end
	end

	-- Female-specific body part addition
	if ProfileStore:Get(player, "Character.Gender") == "Female" and not character:FindFirstChild("WomanTorso") then
		local torsoTemplate = ServerStorage:FindFirstChild("Assets") and ServerStorage.Assets.Models:FindFirstChild("WomanTorso")
		if torsoTemplate then
			local WomanTorso = torsoTemplate:Clone() -- clone template to add torso
			WomanTorso.Parent = character
		end
	end

	-- Invisible spawn protection
	local ff = Instance.new("ForceField")
	ff.Name = "SpawnProtection"
	ff.Visible = false -- invisible for aesthetics
	ff.Parent = character
	DebrisService:AddItem(ff, 6) -- automatically remove after 6 seconds

	-- Trigger spawn visual effect on client
	FX:FireClient(player, "Client", "SpawnEffect", {Method = "Add", Duration = 5})

	-- Initialize energy and movement defaults
	ReiatsuManager:SetReiatsu(player, 40) -- set initial energy
	if not AttributeHandler:Find(character, "Run") then
		self:SetWalkSpeed(player, 16) -- default movement
		self:SetJumpPower(player, 40)
	end

	local race = ProfileStore:Get(player, "Character.Race") -- retrieve race for specialized setup
	-- Wait for the player’s avatar appearance to load before doing heavy modifications
	self:WaitForCharacterAppearance(player, 5) -- non-blocking wait for character appearance

	-- Setup race-specific behaviors using a manager lookup
	local raceToManager = {
		LostSoul = LostSoulManager,
		Human = HumanManager,
		Shinigami = ShinigamiManager,
		Arrancar = ArrancarManager,
		Quincy = QuincyManager,
		Fullbringer = FullbringerManager
	}
	local manager = raceToManager[race] -- retrieve manager for current race
	if manager and manager.SetupCharacter then
		manager:SetupCharacter(player, character) -- call race-specific setup
	end

	-- Control Flashstep UI visibility for ranged races
	local flashVisible = (race == "Shinigami" or race == "Arrancar" or race == "Quincy" or race == "Fullbringer")
	UI:FireClient(player, "SetUIVisible", {UIName = "Flashstep", ParentName = "Bars", IsVisible = flashVisible}) -- update UI state

	-- Check and apply default attributes if required
	if module.CheckAttributes then
		module:CheckAttributes(player, character) -- ensure essential attribute flags exist
	end

	-- Apply saved hair color efficiently
	local hairR = ProfileStore:Get(player, "Character.HairColorR") or 0 -- default to 0 if nil
	local hairG = ProfileStore:Get(player, "Character.HairColorG") or 0
	local hairB = ProfileStore:Get(player, "Character.HairColorB") or 0
	CosmeticManager:Hair(player, {Method = "ChangeColor", R = hairR, G = hairG, B = hairB}) -- apply color via cosmetic manager

	-- Apply footstep settings
	if ProfileStore:Get(player, "Settings.Footsteps") then
		AttributeHandler:Remove(character, "Footsteps") -- clear existing flag
		AttributeHandler:Add(character, "Footsteps") -- add attribute for footsteps effect
	end

	-- Apply general client settings
	local ambienceVolume = ProfileStore:Get(player, "Settings.Volume") -- read ambience volume
	local hideNames = ProfileStore:Get(player, "Settings.HideNames") -- check hide-names flag
	if hideNames then
		FX:FireClient(player, "Client", "Settings", {SettingType = "HideNames", Status = true}) -- instruct client to hide names
	end
	FX:FireClient(player, "Client", "Settings", {SettingType = "Ambience", Volume = ambienceVolume}) -- update ambience volume

	-- Compute ingame name including clan if present
	local ingameName = ProfileStore:Get(player, "Name")
	local clan = ProfileStore:Get(player, "Character.Clan")
	if clan and clan ~= "" then
		ingameName = ingameName .. " " .. clan -- append clan for full display
	end

	-- Send startup packets to client (leaderboard, server info, time)
	sendStartupPackets(player, {IngameName = ingameName, Faction = ProfileStore:Get(player, "Race")})
end

-- Efficiently checks and initializes player data
function module:CheckData(player: Player)
	local data = ProfileStore:GetCurrentSlotData(player) -- fetch slot data
	if not data then return end

	-- Initialize default values for first-time players
	if not data.Character.Created and (data.Character.Clan == "" or data.Character.Clan == nil) then
		profileSet(player, "Character.Created", true) -- mark as created
		UI:FireClient(player, "NewGame", {Method = "Enable"}) -- open character creation UI

		-- Generate and apply random hair/eye colors in batch
		local hairColor = RarityService:RollColor()
		local eyeColor = RarityService:RollColor()
		profileSetColorRGB(player, "HairColor", hairColor)
		profileSetColorRGB(player, "EyeColor", eyeColor)
	end

	-- Build display name from cached data
	local ingameName = data.Name or ProfileStore:Get(player, "Name")
	local faction = data.Race or ProfileStore:Get(player, "Race")
	if data.Character and data.Character.Clan and data.Character.Clan ~= "" then
		ingameName = ingameName .. " " .. data.Character.Clan -- append clan if available
	end

	-- Send consolidated startup packets
	sendStartupPackets(player, {IngameName = ingameName, Faction = faction}) -- reduce redundant ProfileStore:Get calls
end

-- Attribute initialization example
function module:CheckAttributes(player: Player, character: Model)
	if not character then return end
	if not AttributeHandler:Find(character, "InitializedAttributes") then
		AttributeHandler:Add(character, "InitializedAttributes") -- mark character as having initialized attributes
		if not AttributeHandler:Find(character, "StaminaRegen") then
			AttributeHandler:Add(character, "StaminaRegen") -- add stamina regeneration attribute
			if character:GetAttribute("StaminaRegen") == nil then
				character:SetAttribute("StaminaRegen", 1.0) -- set default numeric value
			end
		end
	end
end

-- Handles character added events
module.OnCharacterAdded = function(player: Player, character: Model)
	if not player or not character then return end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then return end

	-- Setup fake head if templates exist
	local fakeHeadTemplate = ServerStorage:FindFirstChild("Assets") and ServerStorage.Assets.Models:FindFirstChild("FakeHead")
	local fakeWeldTemplate = ServerStorage:FindFirstChild("Assets") and ServerStorage.Assets.Models:FindFirstChild("FakeHeadWeld")
	if fakeHeadTemplate and fakeWeldTemplate and character:FindFirstChild("Head") then
		local head = character.Head
		local FakeHead = fakeHeadTemplate:Clone()
		local FakeHead6D = fakeWeldTemplate:Clone()
		FakeHead6D.Part0 = head -- weld primary part
		FakeHead6D.Part1 = FakeHead -- weld secondary part
		FakeHead6D.Parent = head -- parent weld to head
		FakeHead.Parent = character -- parent fake head to character
		FakeHead:PivotTo(head.CFrame) -- align fake head to real head
	end

	-- Ensure attribute system exists
	AttributeHandler:Create(character) -- initialize attribute storage

	-- Add Loading attribute if profile not yet loaded (non-studio)
	if not player:GetAttribute("Loaded") and not RunService:IsStudio() then
		AttributeHandler:Add(character, "Loading") -- flag for pending load
		return
	end

	-- Wait for profile readiness before continuing
	ProfileStore:OnProfileReady(player, false):await() -- block until profile ready

	activeConnections[player] = activeConnections[player] or {} -- ensure connection tracking table

	local hasSpawned = false -- debounce spawn logic
	task.wait(0.2) -- small yield for other systems

	-- Local cleanup function for this character
	local function cleanupConnections()
		disconnectAllConnectionsForPlayer(player) -- disconnect all tracked connections
	end

	-- Heartbeat connection to monitor humanoid health and trigger spawn
	activeConnections[player].heartbeat = RunService.Heartbeat:Connect(function()
		if not player.Parent or not humanoid or humanoid.Health <= 0 then
			cleanupConnections() -- remove connections if player left or humanoid dead
		else
			if not hasSpawned then
				hasSpawned = true -- debounce
				local ok, err = pcall(function()
					module:SpawnCharacter(player, character) -- spawn safely
				end)
				if not ok then
					warn("SpawnCharacter failed for", player.Name, err)
				end
				cleanupConnections()
			end
		end
	end)

	-- Handle player leaving events
	activeConnections[player].playerRemoving = Players.PlayerRemoving:Connect(function(leaving)
		if leaving == player then
			cleanupConnections()
		end
	end)

	-- Handle humanoid death
	activeConnections[player].died = humanoid.Died:Connect(function()
		cleanupConnections()
	end)

	-- Refresh other players’ hide-name settings immediately
	for _, other in ipairs(Players:GetPlayers()) do
		if other ~= player and ProfileStore:IsProfileLoaded(other) and ProfileStore:Get(other, "Settings.HideNames") then
			FX:FireClient(other, "Client", "Settings", {SettingType = "HideNames", Status = true})
		end
	end
end
