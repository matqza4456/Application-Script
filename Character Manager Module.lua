--!strict
-- CharacterManager.lua

-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local DebrisService = game:GetService("Debris")

-- Module references (kept as requires to preserve existing architecture)
local ServerModules = ServerStorage:WaitForChild("Modules")
local ReplicatedModules = ReplicatedStorage:WaitForChild("Modules")

local ProfileStore = require(ServerModules.Services.ProfileStore)
local RemoteProtecterService = require(ServerModules.Services.RemoteProtecterService)
local RarityService = require(ServerModules.Services.RarityService)

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

local Debris = require(ReplicatedModules.Shared.Debris)
local AttributeHandler = require(ReplicatedModules.Shared.AttributeHandler)

local UI = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("UI")
local FX = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("FX")

-- Module table
local module: {[string]: any} = {}

-- State containers
local originalStates: {[Player]: {WalkSpeed: number, JumpPower: number, AutoRotate: boolean}} = {}
local activeConnections: {[Player]: {[string]: RBXScriptConnection}} = {}
local pendingTasks: {[Player]: {[number]: {Cancel: boolean}}} = {}
local effectsBeforeCleanup: {[string]: number} = {}

-- Safe get character & humanoid
local function getCharacterAndHumanoid(player: Player)
	local char = player.Character
	if not char then return nil, nil end
	local hum = char:FindFirstChildOfClass("Humanoid")
	return char, hum
end

-- Store original humanoid properties once
local function captureOriginalStateOnce(player: Player)
	if originalStates[player] then return originalStates[player] end
	local char, humanoid = getCharacterAndHumanoid(player)
	if not humanoid then return nil end
	originalStates[player] = {
		WalkSpeed = humanoid.WalkSpeed,
		JumpPower = humanoid.JumpPower,
		AutoRotate = humanoid.AutoRotate
	}
	return originalStates[player]
end

-- Setter wrapper for ProfileStore which reduces repeated anonymous functions
local function profileSet(player: Player, key: string, value: any)
	ProfileStore:Update(player, key, function()
		return value
	end)
end

-- Batched update for color components (reduces six separate updates into a loop)
local function profileSetColorRGB(player: Player, prefix: string, color: {R: number, G: number, B: number})
	for _, channel in ipairs({"R", "G", "B"}) do
		ProfileStore:Update(player, ("Character.%s%s"):format(prefix, channel), function()
			-- safe fallback to 0 if nil
			return color[channel] or 0
		end)
	end
end

-- Start client event sending for startup
local function sendStartupPackets(player: Player, extra: {[string]: any}?)
	-- Leaderboard
	UI:FireAllClients("Leaderboard", {
		Method = "Create",
		PlayerName = player.Name,
		Name = extra and extra.IngameName or ProfileStore:Get(player, "Name"),
		Faction = extra and extra.Faction or ProfileStore:Get(player, "Race")
	})

	-- Server metadata
	UI:FireClient(player, "ServerInfo", {
		ServerName = ServerManager.GetServerName(),
		ServerAge = ServerManager.GetUptimeFormatted(),
		ServerRegion = ServerManager.GetServerRegion()
	})

	-- Time of day
	FX:FireClient(player, "Client", "UpdateTime", {
		TOD = TimeCycleService.GetCurrentPeriod()
	})
end

-- Pending task manager (provides cancellation and removal)
local function createDelayedTask(player: Player, duration: number, callback: () -> ())
	if not pendingTasks[player] then pendingTasks[player] = {} end
	local taskData = {Cancel = false}
	table.insert(pendingTasks[player], taskData)
	local myIndex = #pendingTasks[player]

	task.delay(duration, function()
		local tasksList = pendingTasks[player]
		-- If player left or tasks cleared, tasksList may be nil
		if not tasksList or not tasksList[myIndex] then return end
		if not tasksList[myIndex].Cancel then
			callback()
		end
		-- remove this task entry safely
		if pendingTasks[player] then
			for i = myIndex, 1, -1 do
				if pendingTasks[player][i] == taskData then
					table.remove(pendingTasks[player], i)
					break
				end
			end
		end
	end)
	-- Return a cancellable handle
	return {
		Cancel = function()
			taskData.Cancel = true
		end
	}
end

-- Cleanup helpers
local function disconnectAllConnectionsForPlayer(player: Player)
	if activeConnections[player] then
		for _, conn in pairs(activeConnections[player]) do
			if conn and conn.Connected then
				conn:Disconnect()
			end
		end
		activeConnections[player] = nil
	end
end

local function cancelAllPendingTasksForPlayer(player: Player)
	if pendingTasks[player] then
		for _, t in ipairs(pendingTasks[player]) do
			t.Cancel = true
		end
		pendingTasks[player] = nil
	end
end

local function cleanupPlayer(player: Player)
	originalStates[player] = nil
	disconnectAllConnectionsForPlayer(player)
	cancelAllPendingTasksForPlayer(player)
end

-- Connect PlayerRemoving to cleanup
Players.PlayerRemoving:Connect(cleanupPlayer)

-- Safe random spawn chooser using CFrame math for slight variation
local function chooseSpawnCFrame(spawnFolder: Instance)
	local children = spawnFolder:GetChildren()
	if #children == 0 then
		-- fallback to workspace spawn location
		return workspace:FindFirstChild("SpawnLocation") and workspace.SpawnLocation.CFrame or CFrame.new(Vector3.new(0, 5, 0))
	end
	local idx = math.random(1, #children)
	local chosen = children[idx]
	if chosen:IsA("BasePart") then
		-- Slight random offset & rotation to avoid stacking
		local offset = Vector3.new(
			(math.random() - 0.5) * 2, -- x in [-1,1]
			0,
			(math.random() - 0.5) * 2  -- z in [-1,1]
		)
		local rot = CFrame.Angles(0, math.rad(math.random(0, 360)), 0)
		return CFrame.new(chosen.Position + offset) * rot
	elseif chosen:IsA("Model") and chosen:FindFirstChildOfClass("BasePart") then
		local part = chosen:FindFirstChildOfClass("BasePart")
		local offset = Vector3.new((math.random() - 0.5) * 2, 0, (math.random() - 0.5) * 2)
		local rot = CFrame.Angles(0, math.rad(math.random(0, 360)), 0)
		return part.CFrame * CFrame.new(offset) * rot
	else
		return chosen.CFrame or CFrame.new(Vector3.new(0, 5, 0))
	end
end

-- SetWalkSpeed with safe revert logic
function module:SetWalkSpeed(player: Player, speed: number, duration: number?)
	local char, humanoid = getCharacterAndHumanoid(player)
	if not humanoid then return end
	local state = captureOriginalStateOnce(player)
	-- set immediately
	humanoid.WalkSpeed = speed
	-- revert if duration provided
	if type(duration) == "number" and duration > 0 then
		createDelayedTask(player, duration, function()
			local c, h = getCharacterAndHumanoid(player)
			if h and originalStates[player] then
				h.WalkSpeed = state.WalkSpeed
			end
		end)
	end
end

-- SetJumpPower with safe revert logic
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

-- SetAutoRotate with safe revert logic
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

-- Wait for appearance (non-blocking pattern, returns true if loaded before timeout)
function module:WaitForCharacterAppearance(player: Player, timeoutDuration: number?)
	timeoutDuration = timeoutDuration or 10
	local start = os.clock()
	while not player:HasAppearanceLoaded() and (os.clock() - start) < timeoutDuration do
		task.wait(0.1)
	end
	return player:HasAppearanceLoaded()
end

-- Safer cloning and optional remote fallback
function module:CreateSound(player: Player, params: {SoundName: string?, SoundLocation: string?, SoundParent: Instance?, Duration: number?, PlaySound: boolean?})
	if not params then return nil end
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

	local newSound = soundObject:Clone()
	newSound.Parent = parent
	if play then
		newSound:Play()
		duration = duration or (newSound.TimeLength + 0.1)
	else
		duration = duration or 10
	end

	Debris:AddItem(newSound, duration)
	return newSound
end

-- Main function to spawn and setup the character
function module:SpawnCharacter(player: Player, character: Model)
	if not player or not character then return end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root then return end

	-- Select spawn folder from saved location; fallback to any valid spawn
	local spawns = workspace:FindFirstChild("Spawns") and workspace.Spawns:FindFirstChild("Players")
	local loc = ProfileStore:Get(player, "Location")
	local spawnFolder = nil
	if spawns and loc then
		spawnFolder = spawns:FindFirstChild(loc)
	end
	if not spawnFolder or #spawnFolder:GetChildren() == 0 then
		for _, container in ipairs(spawns:GetChildren()) do
			if #container:GetChildren() > 0 and container:FindFirstChildOfClass("BasePart") then
				spawnFolder = container
				break
			end
		end
	end
	-- If still nil, fallback to workspace SpawnLocation CFrame.
	local targetCFrame = chooseSpawnCFrame(spawnFolder or workspace)
	-- pivot to a CFrame with clear Y offset to avoid floor clipping
	character:PivotTo(targetCFrame + Vector3.new(0, 2.2, 0))

	-- Remove existing ForceFields (defensive)
	for _, item in ipairs(character:GetChildren()) do
		if item:IsA("ForceField") then
			item:Destroy()
		end
	end

	-- Female body part addition (only if required)
	if ProfileStore:Get(player, "Character.Gender") == "Female" and not character:FindFirstChild("WomanTorso") then
		local torsoTemplate = ServerStorage:FindFirstChild("Assets") and ServerStorage.Assets.Models:FindFirstChild("WomanTorso")
		if torsoTemplate then
			local WomanTorso = torsoTemplate:Clone()
			WomanTorso.Parent = character
		end
	end

	-- Invisible spawn protection
	local ff = Instance.new("ForceField")
	ff.Name = "SpawnProtection"
	ff.Visible = false
	ff.Parent = character
	DebrisService:AddItem(ff, 6) -- removes after 6 seconds

	-- Trigger client spawn effect
	FX:FireClient(player, "Client", "SpawnEffect", {Method = "Add", Duration = 5})

	-- Initialize energy & movement defaults
	ReiatsuManager:SetReiatsu(player, 40)
	if not AttributeHandler:Find(character, "Run") then
		self:SetWalkSpeed(player, 16)
		self:SetJumpPower(player, 40)
	end

	local race = ProfileStore:Get(player, "Character.Race")

	-- Wait for appearance before doing heavy modifications
	self:WaitForCharacterAppearance(player, 5)

	-- Spawn race-specific setup and UI visibility (consolidated pattern)
	local raceToManager = {
		LostSoul = LostSoulManager,
		Human = HumanManager,
		Shinigami = ShinigamiManager,
		Arrancar = ArrancarManager,
		Quincy = QuincyManager,
		Fullbringer = FullbringerManager
	}
	local manager = raceToManager[race]
	if manager and manager.SetupCharacter then
		manager:SetupCharacter(player, character)
	end

	-- Flashstep UI visibility: visible for ranged races, false for basic races
	local flashVisible = (race == "Shinigami" or race == "Arrancar" or race == "Quincy" or race == "Fullbringer")
	UI:FireClient(player, "SetUIVisible", {UIName = "Flashstep", ParentName = "Bars", IsVisible = flashVisible})

	-- Check and apply character attributes (placeholder: implement as needed)
	if module.CheckAttributes then
		module:CheckAttributes(player, character)
	end

	-- Apply saved hair color and avoid multiple ProfileStore:Get calls by reading once
	local hairR = ProfileStore:Get(player, "Character.HairColorR") or 0
	local hairG = ProfileStore:Get(player, "Character.HairColorG") or 0
	local hairB = ProfileStore:Get(player, "Character.HairColorB") or 0
	CosmeticManager:Hair(player, {Method = "ChangeColor", R = hairR, G = hairG, B = hairB})

	-- Apply footstep setting (single toggle)
	if ProfileStore:Get(player, "Settings.Footsteps") then
		AttributeHandler:Remove(character, "Footsteps")
		AttributeHandler:Add(character, "Footsteps")
	end

	-- Apply settings (consolidated)
	local ambienceVolume = ProfileStore:Get(player, "Settings.Volume")
	local hideNames = ProfileStore:Get(player, "Settings.HideNames")
	if hideNames then
		FX:FireClient(player, "Client", "Settings", {SettingType = "HideNames", Status = true})
	end
	FX:FireClient(player, "Client", "Settings", {SettingType = "Ambience", Volume = ambienceVolume})

	-- A final startup packet to update leaderboard & server info (pass computed values to avoid re-getting)
	local ingameName = ProfileStore:Get(player, "Name")
	local clan = ProfileStore:Get(player, "Character.Clan")
	if clan and clan ~= "" then
		ingameName = ingameName .. " " .. clan
	end
	sendStartupPackets(player, {IngameName = ingameName, Faction = ProfileStore:Get(player, "Race")})
end

-- Avoids redundant ProfileStore:Get calls and batches color updates
function module:CheckData(player: Player)
	local data = ProfileStore:GetCurrentSlotData(player)
	if not data then return end

	-- If first-time player (Created false AND empty clan), initialize defaults in a concise way
	if not data.Character.Created and (data.Character.Clan == "" or data.Character.Clan == nil) then
		profileSet(player, "Character.Created", true)
		UI:FireClient(player, "NewGame", {Method = "Enable"}) -- show character creation UI once

		-- Generate colors once and batch update
		local hairColor = RarityService:RollColor()
		local eyeColor = RarityService:RollColor()
		profileSetColorRGB(player, "HairColor", hairColor)
		profileSetColorRGB(player, "EyeColor", eyeColor)
	end

	-- Build ingame name from cached data (use data instead of extra ProfileStore:Get calls)
	local ingameName = data.Name or ProfileStore:Get(player, "Name")
	local faction = data.Race or ProfileStore:Get(player, "Race")
	if data.Character and data.Character.Clan and data.Character.Clan ~= "" then
		ingameName = ingameName .. " " .. data.Character.Clan
	end

	-- Send startup packets (leaderboard + server info + time) using consolidated function
	sendStartupPackets(player, {IngameName = ingameName, Faction = faction})
end

-- Example implementation demonstrates attribute scanning
function module:CheckAttributes(player: Player, character: Model)
	-- Example: ensure certain attribute flags exist and apply basic adjustments
	if not character then return end
	if not AttributeHandler:Find(character, "InitializedAttributes") then
		-- Example attributes: "StaminaRegen" as number attribute inside AttributeHandler system
		AttributeHandler:Add(character, "InitializedAttributes")
		-- Add a default stamina regen attribute if not present (demonstration)
		if not AttributeHandler:Find(character, "StaminaRegen") then
			AttributeHandler:Add(character, "StaminaRegen")
			-- store numeric value on the character as a convenience (some frameworks use Attributes)
			if character:GetAttribute("StaminaRegen") == nil then
				character:SetAttribute("StaminaRegen", 1.0)
			end
		end
	end
end

-- Character added handler: sets up fake head, attribute initialization, and robust connection management
module.OnCharacterAdded = function(player: Player, character: Model)
	if not player or not character then return end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then return end

	-- create fake head with weld if templates exist
	local fakeHeadTemplate = ServerStorage:FindFirstChild("Assets") and ServerStorage.Assets.Models:FindFirstChild("FakeHead")
	local fakeWeldTemplate = ServerStorage:FindFirstChild("Assets") and ServerStorage.Assets.Models:FindFirstChild("FakeHeadWeld")
	if fakeHeadTemplate and fakeWeldTemplate and character:FindFirstChild("Head") then
		local head = character.Head
		local FakeHead = fakeHeadTemplate:Clone()
		local FakeHead6D = fakeWeldTemplate:Clone()
		FakeHead6D.Part0 = head
		FakeHead6D.Part1 = FakeHead
		FakeHead6D.Parent = head
		FakeHead.Parent = character
		FakeHead:PivotTo(head.CFrame)
	end

	-- Ensure attribute system exists
	AttributeHandler:Create(character)

	-- If player hasn't finished loading in non-studio, show Loading attribute
	if not player:GetAttribute("Loaded") and not RunService:IsStudio() then
		AttributeHandler:Add(character, "Loading")
		return
	end

	-- Wait for profile readiness (blocking until profile ready)
	ProfileStore:OnProfileReady(player, false):await()

	-- Initialize connection tracking container
	activeConnections[player] = activeConnections[player] or {}

	-- Debounce spawn logic
	local hasSpawned = false
	-- Small yield to allow other systems to ready
	task.wait(0.2)

	-- Cleanup function specific to this player's OnCharacterAdded scope
	local function cleanupConnections()
		disconnectAllConnectionsForPlayer(player)
	end

	-- Heartbeat connection to check health/spawn
	activeConnections[player].heartbeat = RunService.Heartbeat:Connect(function()
		if not player.Parent or not humanoid or humanoid.Health <= 0 then
			cleanupConnections()
		else
			if not hasSpawned then
				hasSpawned = true
				-- call SpawnCharacter safely in protected call
				local ok, err = pcall(function()
					module:SpawnCharacter(player, character)
				end)
				if not ok then
					warn("SpawnCharacter failed for", player.Name, err)
				end
				cleanupConnections()
			end
		end
	end)

	-- Player leaving
	activeConnections[player].playerRemoving = Players.PlayerRemoving:Connect(function(leaving)
		if leaving == player then
			cleanupConnections()
		end
	end)

	-- On death cleanup
	activeConnections[player].died = humanoid.Died:Connect(function()
		cleanupConnections()
	end)

	-- Refresh other players' hide-name settings immediately (only those with profile loaded)
	for _, other in ipairs(Players:GetPlayers()) do
		if other ~= player and ProfileStore:IsProfileLoaded(other) and ProfileStore:Get(other, "Settings.HideNames") then
			FX:FireClient(other, "Client", "Settings", {SettingType = "HideNames", Status = true})
		end
	end
end

-- Character removing handler: safe cleanup of effects and attributes
module.OnCharacterRemoving = function(player: Player, character: Model)
	if not character then return end
	-- gather debug/effect info from AttributeHandler safely
	local ok, debugInfo = pcall(function()
		return AttributeHandler:GetDebugInfo(character)
	end)

	if ok and debugInfo and debugInfo.Effects then
		for effectName, effectData in pairs(debugInfo.Effects) do
			if effectData.Count and effectData.Count > 0 then
				effectsBeforeCleanup[effectName] = effectData.Count
			end
		end
	end

	-- Remove all effects and profile reference safely
	local success = pcall(function()
		AttributeHandler:RemoveAllEffects(character)
		AttributeHandler:RemoveProfile(character)
	end)

	if not success then
		warn("Failed to clean attributes for:", character.Name)
	end

	-- debug logging can be added here if needed (kept minimal for performance)
	cleanupPlayer(player)
end

-- Character appearance loaded handler: reset to default appearance minimally & efficiently
module.OnCharacterAppearanceLoaded = function(player: Player, character: Model)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then return end
	local ok, currentDescription = pcall(function()
		return humanoid:GetAppliedDescription():Clone()
	end)
	if not ok or not currentDescription then return end

	-- Reset body part ids to 0
	local partsToReset = {"Head","Torso","RightArm","LeftArm","RightLeg","LeftLeg"}
	for _, part in ipairs(partsToReset) do
		currentDescription[part] = 0
	end

	-- Clear accessory slots to default
	local accessorySlots = {
		"FaceAccessory","NeckAccessory","ShouldersAccessory",
		"FrontAccessory","BackAccessory","WaistAccessory","HatAccessory"
	}
	for _, slot in ipairs(accessorySlots) do
		currentDescription[slot] = ""
	end

	-- Remove clothing items and normalize hair textures in one pass
	for _, item in ipairs(character:GetChildren()) do
		if item.ClassName == "ShirtGraphic" or item.ClassName == "Shirt" or item.ClassName == "Pants" then
			item:Destroy()
		elseif item:IsA("Accessory") and item.AccessoryType == Enum.AccessoryType.Hair then
			for _, desc in ipairs(item:GetDescendants()) do
				if desc:IsA("SpecialMesh") then
					-- Use a known default hair texture id to ensure uniform look (example id)
					desc.TextureId = "rbxassetid://4486606505"
				end
			end
		end
	end

	-- Remove face decal
	local headPart = character:FindFirstChild("Head")
	if headPart then
		local face = headPart:FindFirstChildOfClass("Decal")
		if face then face:Destroy() end
	end

	-- Apply cleaned description and move to Alive.Players
	pcall(function()
		humanoid:ApplyDescription(currentDescription)
	end)

	local alivePlayersFolder = workspace:FindFirstChild("Alive") and workspace.Alive:FindFirstChild("Players")
	if alivePlayersFolder then
		character.Parent = alivePlayersFolder
	end
end

-- Export module
return module
