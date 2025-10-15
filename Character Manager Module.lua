--!strict -- enables Luau type checking and stricter runtime expectations
-- CharacterManager.lua

-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage") -- obtains the ReplicatedStorage service (networked assets container)
local ServerStorage = game:GetService("ServerStorage") -- obtains the ServerStorage service (server-only assets container)
local RunService = game:GetService("RunService") -- obtains RunService for heartbeat/timing callbacks
local Players = game:GetService("Players") -- obtains Players service to manage player instances
local DebrisService = game:GetService("Debris") -- obtains Debris service to schedule automatic Instance cleanup

-- Module references
local ServerModules = ServerStorage:WaitForChild("Modules") -- yields to server Modules folder (synchronous lookup)
local ReplicatedModules = ReplicatedStorage:WaitForChild("Modules") -- yields to replicated Modules folder

local ProfileStore = require(ServerModules.Services.ProfileStore) -- imports profile persistence abstraction (expected API: Get/Update/OnProfileReady/etc.)
local RemoteProtecterService = require(ServerModules.Services.RemoteProtecterService) -- imports remote-protection utilities (anti-exploit)
local RarityService = require(ServerModules.Services.RarityService) -- imports rarity/color generation utilities

local CosmeticManager = require(ServerModules.Core.CosmeticManager) -- imports cosmetic handling module (hair/appearance changes)
local LostSoulManager = require(ServerModules.Core.LostSoulManager) -- imports race-specific manager
local HumanManager = require(ServerModules.Core.HumanManager) -- imports race-specific manager
local ShinigamiManager = require(ServerModules.Core.ShinigamiManager) -- imports race-specific manager
local ArrancarManager = require(ServerModules.Core.ArrancarManager) -- imports race-specific manager
local QuincyManager = require(ServerModules.Core.QuincyManager) -- imports race-specific manager
local FullbringerManager = require(ServerModules.Core.FullbringerManager) -- imports race-specific manager
local ServerManager = require(ServerModules.Core.ServerManager) -- imports server meta/info utilities
local ReiatsuManager = require(ServerModules.Core.ReiatsuManager) -- imports energy/recharge system manager
local TimeCycleService = require(ServerModules.Services.TimeCycleService) -- imports TOD system

local Debris = require(ReplicatedModules.Shared.Debris) -- imports a Debris wrapper (shared utilities)
local AttributeHandler = require(ReplicatedModules.Shared.AttributeHandler) -- imports attribute/effect management API

local UI = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("UI") -- fetches UI remote events (client communication)
local FX = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("FX") -- fetches FX remote events (client effects)

-- Module table
local module: {[string]: any} = {} -- primary module table to export functions

-- State containers
local originalStates: {[Player]: {WalkSpeed: number, JumpPower: number, AutoRotate: boolean}} = {} -- caches humanoid defaults per-player
local activeConnections: {[Player]: {[string]: RBXScriptConnection}} = {} -- stores connection handles per player for cleanup
local pendingTasks: {[Player]: {[number]: {Cancel: boolean}}} = {} -- tracks delayed tasks per player (cancellable)
local effectsBeforeCleanup: {[string]: number} = {} -- records counts of active effects before cleanup (debugging aid)

-- Safe get character & humanoid
local function getCharacterAndHumanoid(player: Player)
	local char = player.Character -- reads the player's Character reference
	if not char then return nil, nil end -- returns nils if no character present
	local hum = char:FindFirstChildOfClass("Humanoid") -- finds the Humanoid instance (class-based)
	return char, hum -- returns both references
end

-- Store original humanoid properties once
local function captureOriginalStateOnce(player: Player)
	if originalStates[player] then return originalStates[player] end -- idempotent return if cached
	local char, humanoid = getCharacterAndHumanoid(player) -- obtain current character & humanoid
	if not humanoid then return nil end -- bail if humanoid missing
	originalStates[player] = {
		WalkSpeed = humanoid.WalkSpeed, -- snapshot WalkSpeed numeric value
		JumpPower = humanoid.JumpPower, -- snapshot JumpPower numeric value
		AutoRotate = humanoid.AutoRotate -- snapshot AutoRotate boolean
	}
	return originalStates[player] -- return newly stored state
end

-- Setter wrapper for ProfileStore which reduces repeated anonymous functions
local function profileSet(player: Player, key: string, value: any)
	ProfileStore:Update(player, key, function() -- calls ProfileStore:Update with a function to return the new value
		return value -- returns the supplied value (closure captures value)
	end)
end

-- Batched update for color components (reduces six separate updates into a loop)
local function profileSetColorRGB(player: Player, prefix: string, color: {R: number, G: number, B: number})
	for _, channel in ipairs({"R", "G", "B"}) do -- iterates color channels in order R,G,B
		ProfileStore:Update(player, ("Character.%s%s"):format(prefix, channel), function() -- formats key like "Character.HairColorR"
			-- safe fallback to 0 if nil
			return color[channel] or 0 -- returns numeric channel or 0 when absent (defensive)
		end)
	end
end

-- Start client event sending for startup
local function sendStartupPackets(player: Player, extra: {[string]: any}?)
	-- Leaderboard
	UI:FireAllClients("Leaderboard", { -- fires an event to all clients to update leaderboard display
		Method = "Create", -- method field indicates a creation action
		PlayerName = player.Name, -- supplies server username (not display name)
		Name = extra and extra.IngameName or ProfileStore:Get(player, "Name"), -- uses computed display name if provided, else falls back to stored Name
		Faction = extra and extra.Faction or ProfileStore:Get(player, "Race") -- uses computed faction if provided, else stored Race
	})

	-- Server metadata
	UI:FireClient(player, "ServerInfo", { -- fires a single client event to the joining player with server info
		ServerName = ServerManager.GetServerName(), -- reads server name from ServerManager API
		ServerAge = ServerManager.GetUptimeFormatted(), -- formatted uptime string
		ServerRegion = ServerManager.GetServerRegion() -- region identifier
	})

	-- Time of day
	FX:FireClient(player, "Client", "UpdateTime", { -- uses FX remotes to notify client of current TOD (time-of-day)
		TOD = TimeCycleService.GetCurrentPeriod() -- queries TimeCycleService for the current TOD enum/string
	})
end

-- Pending task manager (provides cancellation and removal)
local function createDelayedTask(player: Player, duration: number, callback: () -> ())
	if not pendingTasks[player] then pendingTasks[player] = {} end -- initializes pendingTasks list for player if absent
	local taskData = {Cancel = false} -- creates a task record with a Cancel boolean flag
	table.insert(pendingTasks[player], taskData) -- appends to the player's pendingTasks array
	local myIndex = #pendingTasks[player] -- captures the index (used later to identify task entry)

	task.delay(duration, function() -- schedules a delayed execution on the task scheduler
		local tasksList = pendingTasks[player] -- reads the potentially-modified pendingTasks table
		-- If player left or tasks cleared, tasksList may be nil
		if not tasksList or not tasksList[myIndex] then return end -- defensive: bail if task entry missing
		if not tasksList[myIndex].Cancel then -- checks cancellation flag prior to invoking callback
			callback() -- executes provided callback function
		end
		-- remove this task entry safely
		if pendingTasks[player] then -- ensures the container still exists
			for i = myIndex, 1, -1 do -- iterate backwards from captured index for safe removal
				if pendingTasks[player][i] == taskData then -- identity check to find the exact entry
					table.remove(pendingTasks[player], i) -- removes the entry to avoid memory leak
					break -- stops loop after removal
				end
			end
		end
	end)
	-- Return a cancellable handle
	return {
		Cancel = function() -- exposes Cancel function to caller
			taskData.Cancel = true -- sets cancellation flag to true (callback won't run if not already fired)
		end
	}
end

-- Cleanup helpers
local function disconnectAllConnectionsForPlayer(player: Player)
	if activeConnections[player] then -- existence check for player's connection table
		for _, conn in pairs(activeConnections[player]) do -- iterate stored connections
			if conn and conn.Connected then -- verify connection object and its Connected state
				conn:Disconnect() -- disconnect the event to prevent memory leaks and callbacks after leave
			end
		end
		activeConnections[player] = nil -- clear the container reference for GC
	end
end

local function cancelAllPendingTasksForPlayer(player: Player)
	if pendingTasks[player] then -- check if there are pending tasks for this player
		for _, t in ipairs(pendingTasks[player]) do -- iterate task entries
			t.Cancel = true -- mark each as canceled to prevent callback execution
		end
		pendingTasks[player] = nil -- clear the list so delayed closures see nil and bail out
	end
end

local function cleanupPlayer(player: Player)
	originalStates[player] = nil -- clear cached original humanoid state for GC
	disconnectAllConnectionsForPlayer(player) -- disconnect event connections
	cancelAllPendingTasksForPlayer(player) -- cancel any delayed tasks
end

-- Connect PlayerRemoving to cleanup
Players.PlayerRemoving:Connect(cleanupPlayer) -- attaches cleanup to PlayerRemoving event

-- Safe random spawn chooser using CFrame math for slight variation
local function chooseSpawnCFrame(spawnFolder: Instance)
	local children = spawnFolder:GetChildren() -- gathers children under the spawnFolder container
	if #children == 0 then -- checks empty children list
		-- fallback to workspace spawn location
		return workspace:FindFirstChild("SpawnLocation") and workspace.SpawnLocation.CFrame or CFrame.new(Vector3.new(0, 5, 0)) -- fallback CFrame selection
	end
	local idx = math.random(1, #children) -- picks a random index using math.random (inclusive)
	local chosen = children[idx] -- selects the child at the random index
	if chosen:IsA("BasePart") then -- branch if chosen object is a BasePart
		-- Slight random offset & rotation to avoid stacking
		local offset = Vector3.new( -- constructs a small positional jitter vector
			(math.random() - 0.5) * 2, -- generates float in approx [-1,1] for X jitter
			0, -- Y jitter 0 to avoid vertical clipping
			(math.random() - 0.5) * 2  -- generates float in approx [-1,1] for Z jitter
		)
		local rot = CFrame.Angles(0, math.rad(math.random(0, 360)), 0) -- random Y rotation converted to radians then to CFrame
		return CFrame.new(chosen.Position + offset) * rot -- returns composed CFrame with position + rotation (order: translation then rotation)
	elseif chosen:IsA("Model") and chosen:FindFirstChildOfClass("BasePart") then -- branch if model containing a BasePart
		local part = chosen:FindFirstChildOfClass("BasePart") -- grabs representative part from model
		local offset = Vector3.new((math.random() - 0.5) * 2, 0, (math.random() - 0.5) * 2) -- small jitter vector
		local rot = CFrame.Angles(0, math.rad(math.random(0, 360)), 0) -- randomized rotation around Y axis
		return part.CFrame * CFrame.new(offset) * rot -- composes model's part CFrame with translation and rotation (relative transform)
	else
		return chosen.CFrame or CFrame.new(Vector3.new(0, 5, 0)) -- fallback to child's CFrame or default if absent
	end
end

-- Sets humanoid WalkSpeed safely and caches original state if not already stored
function module:SetWalkSpeed(player: Player, value: number)
	local _, humanoid = getCharacterAndHumanoid(player) -- retrieves humanoid reference
	if humanoid then -- ensures humanoid exists before applying changes
		captureOriginalStateOnce(player) -- caches default humanoid state if not already done
		humanoid.WalkSpeed = value -- applies new WalkSpeed value to humanoid
	end
end -- end of SetWalkSpeed

-- Restores default humanoid WalkSpeed value
function module:ResetWalkSpeed(player: Player)
	local _, humanoid = getCharacterAndHumanoid(player) -- gets humanoid again
	local state = captureOriginalStateOnce(player) -- fetches original state snapshot
	if humanoid and state then -- both must exist
		humanoid.WalkSpeed = state.WalkSpeed -- restores cached WalkSpeed
	end
end -- end of ResetWalkSpeed

-- Same logic pattern for JumpPower
function module:SetJumpPower(player: Player, value: number)
	local _, humanoid = getCharacterAndHumanoid(player) -- retrieves humanoid reference
	if humanoid then
		captureOriginalStateOnce(player)
		humanoid.JumpPower = value -- updates JumpPower attribute
	end
end

-- Restore JumpPower
function module:ResetJumpPower(player: Player)
	local _, humanoid = getCharacterAndHumanoid(player)
	local state = captureOriginalStateOnce(player)
	if humanoid and state then
		humanoid.JumpPower = state.JumpPower -- restores saved JumpPower
	end
end

-- Toggle AutoRotate
function module:SetAutoRotate(player: Player, value: boolean)
	local _, humanoid = getCharacterAndHumanoid(player)
	if humanoid then
		captureOriginalStateOnce(player)
		humanoid.AutoRotate = value -- enables/disables AutoRotate (affects turn-to-face direction)
	end
end

-- Reset AutoRotate to stored default
function module:ResetAutoRotate(player: Player)
	local _, humanoid = getCharacterAndHumanoid(player)
	local state = captureOriginalStateOnce(player)
	if humanoid and state then
		humanoid.AutoRotate = state.AutoRotate
	end
end

-- Waits for character appearance and accessories to load before proceeding
function module:WaitForCharacterAppearance(player: Player)
	local char = player.Character or player.CharacterAdded:Wait() -- wait until Character exists
	local humanoid = char:WaitForChild("Humanoid") -- ensures Humanoid child is present

	if not humanoid then return end -- early exit if humanoid is somehow nil
	local descLoaded = false -- flag for description loaded
	local con -- placeholder for connection object

	con = humanoid.DescendantAdded:Connect(function() -- listen for new descendants
		descLoaded = true -- mark description loaded when something added (proxy for appearance loaded)
	end)

	task.wait(1) -- short delay to allow accessories/bodyparts to replicate
	if con then con:Disconnect() end -- disconnect temporary connection
end

-- Create a sound instance under the player's character
function module:CreateSound(player: Player, soundId: string, volume: number?, pitch: number?)
	local char = player.Character -- character reference
	if not char then return end -- bail if no character exists
	local sound = Instance.new("Sound") -- create new Sound instance
	sound.SoundId = soundId -- assign SoundId (expects rbxassetid or ID string)
	sound.Volume = volume or 1 -- default volume 1 if not given
	sound.PlaybackSpeed = pitch or 1 -- default pitch 1 if not given
	sound.Parent = char -- parent to character for 3D positioning
	sound:Play() -- plays the sound
	DebrisService:AddItem(sound, sound.TimeLength + 1) -- removes the sound automatically after playback finishes
end

-- Main spawn function for initializing character and setting up environment
function module:SpawnCharacter(player: Player)
	local data = ProfileStore:GetCurrentSlotData(player) -- retrieve current profile data slot
	if not data then return end -- exit if no data found (failsafe)

	-- Reset and prepare environment for spawn
	cleanupPlayer(player) -- ensure any leftover state is cleared
	captureOriginalStateOnce(player) -- store initial humanoid state

	-- Spawn location selection
	local spawnFolder = workspace:FindFirstChild("Spawns") -- look for global Spawns folder
	local spawnCF = spawnFolder and chooseSpawnCFrame(spawnFolder) or CFrame.new(0, 5, 0) -- compute spawn CFrame fallback to default

	-- Load character model
	player:LoadCharacter() -- respawn the player’s character (Roblox default respawn method)
	local char = player.Character or player.CharacterAdded:Wait() -- wait until character fully spawns
	char:WaitForChild("HumanoidRootPart") -- ensure HumanoidRootPart is loaded
	char:WaitForChild("Humanoid") -- ensure Humanoid exists

	-- Apply spawn position
	char:MoveTo(spawnCF.Position) -- teleport to spawn position (simple move)
	char:SetPrimaryPartCFrame(spawnCF) -- ensure correct facing and alignment (applies CFrame directly)

	-- Wait for appearance data
	self:WaitForCharacterAppearance(player) -- ensure visual data loaded

	-- Race-specific initialization
	local race = ProfileStore:Get(player, "Race") -- read Race value from profile
	if race == "LostSoul" then
		LostSoulManager:Init(player, char)
	elseif race == "Human" then
		HumanManager:Init(player, char)
	elseif race == "Shinigami" then
		ShinigamiManager:Init(player, char)
	elseif race == "Arrancar" then
		ArrancarManager:Init(player, char)
	elseif race == "Quincy" then
		QuincyManager:Init(player, char)
	elseif race == "Fullbringer" then
		FullbringerManager:Init(player, char)
	end -- end race branches

	-- Reapply cosmetic data (hair, eye colors)
	CosmeticManager:ApplyCosmetics(player) -- updates hair/eye/body colors from profile

	-- Initialize Reiatsu/Aura system
	ReiatsuManager:Setup(player) -- prepares aura/recharge system

	-- Play spawn sound for atmosphere
	self:CreateSound(player, "rbxassetid://123456789", 0.8) -- uses placeholder asset ID for spawn cue

	-- Display name build (adds clan suffix if any)
	local displayName = ProfileStore:Get(player, "Name") or player.Name -- fallback to player.Name
	local clan = data.Character.Clan
	if clan and clan ~= "" then
		displayName = displayName .. " " .. clan -- append clan if not empty
	end

	-- Broadcast spawn event to other clients
	sendStartupPackets(player, {
		IngameName = displayName, -- name displayed in leaderboard
		Faction = race -- player's race used for faction display
	})

	-- Fire UI for respawn
	UI:FireClient(player, "Spawn", {Method = "Complete"}) -- notify client spawn finished
end

-- Checks and initializes player data upon joining or profile ready
function module:CheckData(player: Player)
	local data = ProfileStore:GetCurrentSlotData(player) -- retrieves the player's currently loaded data slot

	-- Initialize new player data if first time playing
	if not data.Character.Created and data.Character.Clan == "" then -- checks if player is new (no character created + no clan)
		profileSet(player, "Character.Created", true) -- marks character as created in profile

		-- Show character creation UI on client
		UI:FireClient(player, "NewGame", {Method = "Enable"}) -- triggers NewGame UI for customization

		-- Generate random hair and eye colors via rarity system
		local HairColors = RarityService:RollColor() -- returns color object/table {R,G,B}
		local EyeColors = RarityService:RollColor() -- returns color object/table {R,G,B}

		-- Save hair color RGB values efficiently
		profileSetColorRGB(player, "HairColor", HairColors)

		-- Save eye color RGB values efficiently
		profileSetColorRGB(player, "EyeColor", EyeColors)
	end -- end of new player check

	-- Build display name with clan if applicable
	local ingameName = ProfileStore:Get(player, "Name") or player.Name -- gets stored name or fallback
	local faction = ProfileStore:Get(player, "Race") or "Unknown" -- gets race (for leaderboard)
	if data.Character.Clan and data.Character.Clan ~= "" then -- check for valid clan
		ingameName = ingameName .. " " .. data.Character.Clan -- append clan to name
	end

	-- Update leaderboard for all clients
	UI:FireAllClients("Leaderboard", { -- sends leaderboard entry to all clients
		Method = "Create", -- method flag: Create means add new player entry
		PlayerName = player.Name, -- Roblox username
		Name = ingameName, -- display name + clan
		Faction = faction -- player’s race/faction
	})

	-- Send server info to player (so their UI updates with metadata)
	UI:FireClient(player, "ServerInfo", {
		ServerName = ServerManager.GetServerName(), -- get readable server name
		ServerAge = ServerManager.GetUptimeFormatted(), -- formatted uptime
		ServerRegion = ServerManager.GetServerRegion() -- e.g. “US-East”
	})

	-- Send current time of day to player (for lighting sync)
	FX:FireClient(player, "Client", "UpdateTime", {
		TOD = TimeCycleService.GetCurrentPeriod() -- e.g. “Morning”, “Night”, etc.
	})
end -- end of CheckData

-- Connect profile ready event to initialize CheckData and SpawnCharacter
ProfileStore.OnProfileReady:Connect(function(player: Player)
	-- When the player's data profile is ready, this fires.
	module:CheckData(player) -- perform data validation + initialization
	module:SpawnCharacter(player) -- spawn their character into the world
end)

-- Cleanup when player leaves to prevent memory leaks
Players.PlayerRemoving:Connect(function(player: Player)
	cleanupPlayer(player) -- disconnect events, cancel tasks, clear cached states
end)

-- Defensive cleanup when server shutting down (only if RunService:IsStudio or similar)
if RunService:IsStudio() then
	game:BindToClose(function()
		for _, player in ipairs(Players:GetPlayers()) do
			cleanupPlayer(player) -- ensure cleanup runs for all active players
		end
	end)
end

return module -- exports module table to be required elsewhere
