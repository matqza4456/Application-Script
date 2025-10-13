local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local ServerModules = ServerStorage:WaitForChild("Modules")
local ReplicatedModules = ReplicatedStorage:WaitForChild("Modules")
local ServerActionsModules = ServerModules.Actions

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

local UI = ReplicatedStorage.Remotes.UI
local FX = ReplicatedStorage.Remotes.FX

local module = {}
local originalStates = {}
local activeConnections = {}
local pendingTasks = {}

local effectsBeforeCleanup = {"Loaded", "Footsteps"}

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

local function cleanupPlayer(player)
	originalStates[player] = nil

	if activeConnections[player] then
		for _, connection in pairs(activeConnections[player]) do
			if connection.Connected then
				connection:Disconnect()
			end
		end
		activeConnections[player] = nil
	end

	if pendingTasks[player] then
		for _, task in pairs(pendingTasks[player]) do
			task.Cancel = true
		end
		pendingTasks[player] = nil
	end
end

Players.PlayerRemoving:Connect(cleanupPlayer)

local function createDelayedTask(player, duration, callback)
	if not pendingTasks[player] then
		pendingTasks[player] = {}
	end

	local taskData = {Cancel = false}
	table.insert(pendingTasks[player], taskData)

	task.delay(duration, function()
		if not taskData.Cancel then
			callback()
		end

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

function module:SetWalkSpeed(player: Player, speed: number, duration: number?)
	local char = player.Character
	if not char then return end

	local humanoid = char:FindFirstChild("Humanoid")
	if not humanoid then return end

	local state = getState(player)
	humanoid.WalkSpeed = speed

	if duration then
		createDelayedTask(player, duration, function()
			if humanoid and humanoid.Parent and originalStates[player] then
				humanoid.WalkSpeed = state.WalkSpeed
			end
		end)
	end
end

function module:SetJumpPower(player: Player, power: number, duration: number?)
	local char = player.Character
	if not char then return end

	local humanoid = char:FindFirstChild("Humanoid")
	if not humanoid then return end

	local state = getState(player)
	humanoid.JumpPower = power

	if duration then
		createDelayedTask(player, duration, function()
			if humanoid and humanoid.Parent and originalStates[player] then
				humanoid.JumpPower = state.JumpPower
			end
		end)
	end
end

function module:SetAutoRotate(player: Player, enabled: boolean, duration: number?)
	local char = player.Character
	if not char then return end

	local humanoid = char:FindFirstChild("Humanoid")
	if not humanoid then return end

	local state = getState(player)
	humanoid.AutoRotate = enabled

	if duration then
		createDelayedTask(player, duration, function()
			if humanoid and humanoid.Parent and originalStates[player] then
				humanoid.AutoRotate = state.AutoRotate
			end
		end)
	end
end

function module:WaitForCharacterAppearance(player, timeoutDuration)
	timeoutDuration = timeoutDuration or 10
	local startTime = tick()

	while not player:HasAppearanceLoaded() and (tick() - startTime) < timeoutDuration do
		task.wait(0.1)
	end
end

function module:CreateSound(player, params)
	local soundName = params.SoundName
	local soundLocation = params.SoundLocation
	local soundParent = params.SoundParent
	local duration = params.Duration
	local playSound = params.PlaySound

	if not soundName or not soundLocation or not soundParent then
		warn("Invalid CreateSound Params")
		return
	end

	local soundObject

	if soundLocation == "Server" then
		soundObject = ServerStorage.Assets.Sounds:FindFirstChild(soundName, true)
	elseif soundLocation == "Replicated" then
		soundObject = ReplicatedStorage.Assets.Sounds:FindFirstChild(soundName, true)
	end

	if soundObject then
		local newSound : Sound = soundObject:Clone()
		newSound.Parent = soundParent

		if playSound then
			newSound:Play()
			duration = duration or newSound.TimeLength + 0.1
		else
			duration = duration or 10
		end

		Debris:AddItem(newSound, duration)
		return newSound
	end
end

function module:SpawnCharacter(player, character)
	local humanoid = character.Humanoid
	local rootPart = character.HumanoidRootPart

	local spawns = workspace.Spawns.Players
	local location = ProfileStore:Get(player, "Location")
	local spawnFolder = spawns:FindFirstChild(location)

	if not spawnFolder or #spawnFolder:GetChildren() == 0 then
		for _, container in pairs(spawns:GetChildren()) do
			if #container:GetChildren() ~= 0 and container:FindFirstChildOfClass("Part") then
				spawnFolder = container
				break
			end
		end
	end

	local randomSpawn = spawnFolder:GetChildren()[math.random(1, #spawnFolder:GetChildren())]

	character:PivotTo(randomSpawn.CFrame)

	for _, item in pairs(character:GetChildren()) do
		if item:IsA("ForceField") then
			item:Destroy()
		end
	end

	if ProfileStore:Get(player, "Character.Gender") == "Female" and not character:FindFirstChild("WomanTorso") then
		local WomanTorso = ServerStorage.Assets.Models.WomanTorso:Clone()
		WomanTorso.Parent = character
	end

	local ForceField = Instance.new("ForceField")
	ForceField.Parent = character
	ForceField.Name = "SpawnProtection"
	ForceField.Visible = false

	FX:FireClient(player, "Client", "SpawnEffect", {
		["Method"] = "Add",
		["Duration"] = 5
	})

	ReiatsuManager:SetReiatsu(player, 40)
	if not AttributeHandler:Find(character, "Run") then
		self:SetWalkSpeed(player, 16)
		self:SetJumpPower(player, 40)
	end

	local race = ProfileStore:Get(player, "Character.Race")

	self:WaitForCharacterAppearance(player, 5)

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

	self:CheckAttributes(player, character)

	local HairColorR = ProfileStore:Get(player, "Character.HairColorR")
	local HairColorG = ProfileStore:Get(player, "Character.HairColorG")
	local HairColorB = ProfileStore:Get(player, "Character.HairColorB")

	CosmeticManager:Hair(player, {
		["Method"] = "ChangeColor",
		["R"] = HairColorR,
		["G"] = HairColorG,
		["B"] = HairColorB
	})
	
	local Footsteps = ProfileStore:Get(player, "Settings.Footsteps")
	if Footsteps then
		AttributeHandler:Remove(character, "Footsteps")
		AttributeHandler:Add(character, "Footsteps")
	end
	
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

	Debris:AddItem(ForceField, 6)
end

function module:CheckData(player)	
	local data = ProfileStore:GetCurrentSlotData(player)

	if not data.Character.Created and data.Character.Clan == "" then
		ProfileStore:Update(player, "Character.Created", function()
			return true
		end)

		UI:FireClient(player, "NewGame", {
			["Method"] = "Enable"
		})

		local HairColors = RarityService:RollColor()
		local EyeColors = RarityService:RollColor()

		ProfileStore:Update(player, "Character.HairColorR", function()
			return HairColors.R
		end)

		ProfileStore:Update(player, "Character.HairColorG", function()
			return HairColors.G
		end)

		ProfileStore:Update(player, "Character.HairColorB", function()
			return HairColors.B
		end)

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

	local ingameName = ProfileStore:Get(player, "Name")
	local faction = ProfileStore:Get(player, "Race")
	if data.Character.Clan then
		ingameName = ingameName .. " " .. data.Character.Clan
	end

	UI:FireAllClients("Leaderboard", {
		["Method"] = "Create",
		["PlayerName"] = player.Name,
		["Name"] = ingameName,
		["Faction"] = faction
	})

	UI:FireClient(player, "ServerInfo", {
		["ServerName"] = ServerManager.GetServerName(),
		["ServerAge"] = ServerManager.GetUptimeFormatted(),
		["ServerRegion"] = ServerManager.GetServerRegion()
	})
		
	FX:FireClient(player, "Client", "UpdateTime", {
		["TOD"] = TimeCycleService.GetCurrentPeriod()
	})
end

function module:CheckAttributes(player : Player, character : Model)

end

module.OnCharacterAdded = function(player, character)
	local humanoid = character.Humanoid
	local rootPart = character.HumanoidRootPart
	local head = character.Head

	local FakeHead = ServerStorage.Assets.Models.FakeHead:Clone()
	local FakeHead6D = ServerStorage.Assets.Models.FakeHeadWeld:Clone()

	FakeHead6D.Part0 = head
	FakeHead6D.Part1 = FakeHead
	FakeHead6D.Parent = head
	FakeHead.Parent = character
	FakeHead:PivotTo(head.CFrame)

	AttributeHandler:Create(character)

	if not player:GetAttribute("Loaded") and not RunService:IsStudio() then
		AttributeHandler:Add(character, "Loading")
	else
		ProfileStore:OnProfileReady(player, false):await()

		if not activeConnections[player] then
			activeConnections[player] = {}
		end

		local hasSpawned = false

		task.wait(0.2)

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

		activeConnections[player].playerRemoving = Players.PlayerRemoving:Connect(function(leavingPlayer)
			if leavingPlayer == player then
				cleanupConnections()
			end
		end)

		activeConnections[player].died = humanoid.Died:Connect(function()
			cleanupConnections()
		end)
	end
	
	for _, otherPlayer in pairs(Players:GetPlayers()) do
		if otherPlayer == player then
			continue
		end

		local otherCharacter = otherPlayer.Character
		if not otherCharacter then
			continue
		end

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

module.OnCharacterRemoving = function(player, character)
	local debugInfo = AttributeHandler:GetDebugInfo(character)

	if debugInfo and debugInfo.Effects then
		for effectName, effectData in pairs(debugInfo.Effects) do
			if effectData.Count > 0 then
				effectsBeforeCleanup[effectName] = effectData.Count
			end
		end
	end

	local cleanupSuccess = pcall(function()
		AttributeHandler:RemoveAllEffects(character)
		AttributeHandler:RemoveProfile(character)
	end)

	if not cleanupSuccess then
		warn("Cleanup failed for character:", character.Name)
	else
		if next(effectsBeforeCleanup) then
			local effectNames = {}
			for effectName, count in pairs(effectsBeforeCleanup) do
				table.insert(effectNames, effectName .. "(" .. count .. ")")
			end
		end
	end

	cleanupPlayer(player)
end

module.OnCharacterAppearanceLoaded = function(player, character)
	local humanoid = character:WaitForChild("Humanoid")
	local currentDescription = humanoid:GetAppliedDescription():Clone()

	local partsToReset = {"Head", "Torso", "RightArm", "LeftArm", "RightLeg", "LeftLeg"}
	local clothes = {"ShirtGraphic"}
	local accessoriesToReset = {
		"FaceAccessory", "NeckAccessory", "ShouldersAccessory",
		"FrontAccessory", "BackAccessory", "WaistAccessory",
		"HatAccessory"
	}

	for _, part in ipairs(partsToReset) do
		currentDescription[part] = 0
	end

	for _, accessory in ipairs(accessoriesToReset) do
		currentDescription[accessory] = ""
	end

	for _, item in pairs(character:GetChildren()) do
		if table.find(clothes, item.ClassName) then
			item:Destroy()
		end

		if item:IsA("Accessory") and item.AccessoryType == Enum.AccessoryType.Hair then
			for _, hairItem in pairs(item:GetDescendants()) do
				if hairItem:IsA("SpecialMesh") then
					hairItem.TextureId = "rbxassetid://4486606505"
				end
			end
		end
	end

	local head = character:FindFirstChild("Head")
	if head then
		local faceDecal = head:FindFirstChildOfClass("Decal")
		if faceDecal then
			faceDecal:Destroy()
		end
	end

	humanoid:ApplyDescription(currentDescription)

	character.Parent = workspace.Alive.Players
end

return module
