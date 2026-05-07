--!strict

--[[
	STRICT STATE-MACHINE AI FRAMEWORK
	
	CONSTRUCTION OVERVIEW:
	This script implements a Finite State Machine (FSM) for a non-player character (Slasher).
	The architecture is decoupled into four primary layers:
	1. Perception Engine: Handles environment scanning using Vector Math (Dot Product) and Raycasting.
	2. Navigation Layer: Managed via PathfindingService and custom MoveTo wrappers with safety timeouts.
	3. State Handler: Asynchronous task management to ensure state transitions are clean and memory-efficient.
	4. Logic Layer: Determines target priority and physical reachability metrics.
]]

--== SERVICES ==--
-- PathfindingService is utilized for A* algorithm path computation across complex 3D navigation meshes.
local PathfindingService = game:GetService("PathfindingService")
-- Players service is required to iterate through active client sessions for entity targeting.
local Players = game:GetService("Players")

--== CONSTANTS & TYPES ==--
-- Custom Type Definition for the FSM to leverage Luau's static analysis for state safety.
type State = "Patrol" | "Hunt" | "Chase" | "Search"

-- Global Configuration Dictionary: Centralized tuning parameters for AI balancing.
local CONFIG = {
	VIEW_DISTANCE = 50,    -- Radial distance in Studs for the initial proximity trigger.
	HUNT_DISTANCE = 150,   -- Threshold for the "Awareness" state before returning to idle.
	KILLER_FOV = 130,      -- Field of View in degrees; converted to radians/dot product for vision checks.
	ATTACK_DISTANCE = 5,   -- Geometric range for melee damage execution.
	DAMAGE_AMOUNT = 15,    -- Damage payload delivered to the target's Humanoid.
	SCAN_RATE = 0.3,       -- Polling rate for the perception loop to optimize server performance (CPU cycles).
}

-- Navigation Parameters: Defines the physical hull and capabilities of the Pathfinding Agent.
local AGENT_PARAMS = {
	AgentRadius = 4,       -- Prevents the AI from clipping into corners during turns.
	AgentHeight = 5,       -- Ensures the path computed accounts for low ceilings.
	AgentCanClimb = false, -- Disables truss/ladder climbing for this specific entity class.
	AgentCanJump = true,   -- Allows the path solver to include Jump waypoints.
}

--== REFERENCES ==--
-- These references use 'WaitForChild' to ensure script execution doesn't fail during data-model streaming.
local Slasher = workspace:WaitForChild("Ia") :: Model
local SlasherHRP = Slasher:WaitForChild("HumanoidRootPart") :: Part
local SlasherHum = Slasher:WaitForChild("Humanoid") :: Humanoid
local InterestPointsF = workspace:WaitForChild("InterestPoints") :: Folder

-- PHYSICS OPTIMIZATION:
-- By setting NetworkOwner to nil, we force the server to calculate physics.
-- This prevents "rubber-banding" caused by network latency between the server and the nearest client.
SlasherHRP:SetNetworkOwner(nil)

--== STATE VARIABLES ==--
local SpottedPlayers: {[string]: Player} = {} -- Cache of players currently meeting visibility criteria.
local WhoIsChasing: Part? = nil               -- Direct reference to the current primary target's HRP.
local LastPlayerPos: Vector3? = nil           -- Spatial breadcrumb used for the 'Search' state transition.
local LastPlayerSaw: Player? = nil            -- Persistence reference for the target last engaged.
local LoopConn: thread? = nil                 -- Pointer to the active behavior thread for cleanup (garbage collection).
local InterestPointsIndex = 1                 -- Sequential index for the patrol circuit.
local LastAttackTick = 0                      -- Timestamp for debouncing damage applications (Attack Cooldown).
local ClosestCharacter: Model? = nil          -- Target selected for the 'Hunt' state based on proximity.

--== UTILITY FUNCTIONS ==--

--[[
	@function IsCharacterValid
	@desc Performs a multi-point validation on a potential target.
	Checks for existence, parentage (streaming safety), and biological state (Health > 0).
]]
local function IsCharacterValid(char: Model?): boolean
	if not char then return false end
	local hum = char:FindFirstChildOfClass("Humanoid")
	return char.Parent ~= nil 
		and char:FindFirstChild("HumanoidRootPart") ~= nil 
		and hum ~= nil 
		and hum.Health > 0
end

--[[
	@function GetCalculatedPath
	@desc Encapsulates the Pathfinding logic within a pcall to prevent async errors from crashing the FSM.
	Returns a Path object only if the Status is 'Success' (i.e., a valid route exists).
]]
local function GetCalculatedPath(startPos: Vector3, endPos: Vector3): Path?
	local path = PathfindingService:CreatePath(AGENT_PARAMS)
	local success, _ = pcall(function()
		path:ComputeAsync(startPos, endPos)
	end)
	return (success and path.Status == Enum.PathStatus.Success) and path or nil
end

--[[
	@function HasVisualObstacle
	@desc Uses WorldRoot:Raycast to determine Line-of-Sight (LOS).
	Filters out the AI and the Target to check exclusively for environmental occlusions.
]]
local function HasVisualObstacle(targetHRP: Part): RaycastResult?
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = {Slasher, targetHRP.Parent}
	return workspace:Raycast(SlasherHRP.Position, (targetHRP.Position - SlasherHRP.Position), params)
end

--== PERCEPTION ENGINE ==--

--[[
	@function GetPlayersInVision
	@desc The core sensory logic.
	Step 1: Radial check (Magnitude) to ignore distant players.
	Step 2: Angular check (Dot Product). We compare the AI's LookVector with the Unit Vector to the target.
	Step 3: Occlusion check (Raycast) to ensure the AI cannot "see through walls".
]]
local function GetPlayersInVision(): {[string]: Player}
	local visiblePlayers = {}
	local lookDir = SlasherHRP.CFrame.LookVector

	for _, plr in ipairs(Players:GetPlayers()) do
		local char = plr.Character
		if not IsCharacterValid(char) then continue end

		local targetHRP = char.HumanoidRootPart
		local offset = (targetHRP.Position - SlasherHRP.Position)
		
		-- Spatial Filtering
		if offset.Magnitude > CONFIG.VIEW_DISTANCE then continue end

		-- Mathematical Vision Cone Logic
		local unitDir = offset.Unit
		local dotResult = unitDir:Dot(lookDir) -- Returns cosine of the angle between vectors.
		local angle = math.deg(math.acos(math.clamp(dotResult, -1, 1)))

		if angle <= CONFIG.KILLER_FOV / 2 then
			-- Raycasting LOS check with a small Y-offset to avoid the ray hitting the floor.
			if not HasVisualObstacle(targetHRP) then
				visiblePlayers[plr.Name] = plr
			end
		end
	end
	return visiblePlayers
end

--== MOVEMENT CORE ==--

--[[
	@function ExecuteMove
	@desc A robust wrapper for Humanoid:MoveTo.
	Logic: Since MoveTo is "fire and forget", this function yields using a custom loop.
	Reasoning: We yield until the target is reached OR a 20s timeout occurs (stuck prevention) 
	OR the AI state changes (immediate interrupt responsiveness).
]]
local function ExecuteMove(targetPos: Vector3, requiredState: State, jump: boolean)
	local startTime = os.clock()
	local reached = false
	
	-- Vertical correction to ensure waypoints are solved effectively on irregular terrain.
	local adjustedPos = targetPos + Vector3.new(0, 3, 0)
	
	SlasherHum:MoveTo(adjustedPos)
	if jump then SlasherHum.Jump = true end

	local connection = SlasherHum.MoveToFinished:Once(function() reached = true end)

	repeat
		task.wait(0.1)
		local currentDist = (SlasherHRP.Position - adjustedPos).Magnitude
	until reached or currentDist < 3.5 or (os.clock() - startTime > 20) or Slasher:GetAttribute("State") ~= requiredState
	
	if connection then connection:Disconnect() end
end

--== BEHAVIOR LOGIC ==--

--[[
	@function UpdateTargetPriority
	@desc Evaluates the 'SpottedPlayers' list and selects the nearest threat as the primary 'WhoIsChasing' target.
]]
local function UpdateTargetPriority(fovPlayers: {[string]: Player})
	local nearestDist = CONFIG.VIEW_DISTANCE + 1
	
	for _, plr in pairs(fovPlayers) do
		local char = plr.Character
		if not IsCharacterValid(char) then continue end

		local hrp = char.HumanoidRootPart
		local dist = (SlasherHRP.Position - hrp.Position).Magnitude

		if dist < nearestDist then
			nearestDist = dist
			WhoIsChasing = hrp
			LastPlayerSaw = plr
		end
	end
	SpottedPlayers = fovPlayers
end

--[[
	@function BrainTick
	@desc The high-level decision maker. Integrates perception with state transition logic.
	It verifies if a path is physically reachable before committing to the 'Chase' state.
]]
local function BrainTick()
	local fovPlayers = GetPlayersInVision()
	UpdateTargetPriority(fovPlayers)

	for _, plr in pairs(SpottedPlayers) do
		local char = plr.Character
		if not IsCharacterValid(char) then continue end

		local hrp = char.HumanoidRootPart
		local distance = (SlasherHRP.Position - hrp.Position).Magnitude

		-- PHYSICAL REACHABILITY CHECK:
		-- Uses A* path length vs Euclidean distance to ensure the target isn't behind a thin but long fence.
		local walkableDistance = distance
		if HasVisualObstacle(hrp) then
			local path = GetCalculatedPath(SlasherHRP.Position, hrp.Position)
			if path then
				walkableDistance = 0
				local points = path:GetWaypoints()
				for i = 2, #points do
					walkableDistance += (points[i].Position - points[i - 1].Position).Magnitude
				end
			end
		end

		if walkableDistance < CONFIG.VIEW_DISTANCE then
			WhoIsChasing = hrp
			Slasher:SetAttribute("State", "Chase")
		end
	end
end

--== STATE HANDLERS ==--

--[[
	@behavior Patrol
	@desc Circuit-based movement. Iterates through a folder of parts.
	Incorporates a secondary proximity check to trigger 'Hunt' even if the player isn't in FOV (Environmental Awareness).
]]
local function PatrolBehavior()
	LoopConn = task.spawn(function()
		while Slasher:GetAttribute("State") == "Patrol" do
			local point = InterestPointsF:FindFirstChild(tostring(InterestPointsIndex)) :: Part?
			
			if point then
				local dist = (point.Position - SlasherHRP.Position).Magnitude
				if dist < 10 then InterestPointsIndex += 1 continue end

				local path = GetCalculatedPath(SlasherHRP.Position, point.Position)
				if path then
					for _, wp in ipairs(path:GetWaypoints()) do
						if Slasher:GetAttribute("State") ~= "Patrol" then return end
						ExecuteMove(wp.Position, "Patrol", wp.Action == Enum.PathWaypointAction.Jump)
					end
				end

				task.wait(math.random(1, 2)) -- Behavioral pause at patrol nodes.
				InterestPointsIndex += 1

				-- Proximity-based awareness trigger (Hunting).
				ClosestCharacter = nil
				local closestDist = CONFIG.HUNT_DISTANCE
				for _, plr in ipairs(Players:GetPlayers()) do
					if IsCharacterValid(plr.Character) then
						local d = (plr.Character.HumanoidRootPart.Position - point.Position).Magnitude
						if d < closestDist then
							ClosestCharacter = plr.Character
							closestDist = d
						end
					end
				end

				if ClosestCharacter and Slasher:GetAttribute("State") == "Patrol" then
					Slasher:SetAttribute("State", "Hunt")
				end
			else
				task.wait(1)
				InterestPointsIndex = 1
			end
			task.wait(0.3)
		end
	end)
end

--[[
	@behavior Hunt
	@desc Soft-tracking state. The AI moves toward a target's position without direct LOS, 
	simulating an AI that "heard" or "guessed" the player's location.
]]
local function HuntBehavior()
	LoopConn = task.spawn(function()
		while Slasher:GetAttribute("State") == "Hunt" do
			if not IsCharacterValid(ClosestCharacter) then 
				Slasher:SetAttribute("State", "Patrol") 
				break 
			end
			
			local targetHRP = ClosestCharacter.HumanoidRootPart
			local dist = (SlasherHRP.Position - targetHRP.Position).Magnitude
			if dist > CONFIG.HUNT_DISTANCE then Slasher:SetAttribute("State", "Patrol") return end

			if not HasVisualObstacle(targetHRP) then
				SlasherHum:MoveTo(targetHRP.Position)
			else
				local path = GetCalculatedPath(SlasherHRP.Position, targetHRP.Position)
				if path then
					for _, wp in ipairs(path:GetWaypoints()) do
						ExecuteMove(wp.Position, "Hunt", wp.Action == Enum.PathWaypointAction.Jump)
					end
				end
			end
			task.wait(0.3)
		end
	end)
end

--[[
	@behavior Chase
	@desc Aggressive engagement. 
	Implements melee damage logic with a debounced clock to prevent frame-rate dependent damage spikes.
	Combines LOS charging with Pathfinding waypoint solving for occlusion handling.
]]
local function ChaseBehavior()
	LoopConn = task.spawn(function()
		while Slasher:GetAttribute("State") == "Chase" do
			if not WhoIsChasing or not WhoIsChasing.Parent then 
				Slasher:SetAttribute("State", "Search") 
				return 
			end

			local dist = (SlasherHRP.Position - WhoIsChasing.Position).Magnitude
			if dist > CONFIG.VIEW_DISTANCE then Slasher:SetAttribute("State", "Search") return end

			-- Attack Sub-routine
			if dist < CONFIG.ATTACK_DISTANCE and (os.clock() - LastAttackTick > 1) then
				local hum = WhoIsChasing.Parent:FindFirstChild("Humanoid") :: Humanoid?
				if hum and hum.Health > 0 then
					LastAttackTick = os.clock()
					hum:TakeDamage(CONFIG.DAMAGE_AMOUNT)
				end
			end

			-- Navigation logic: Beeline for visible targets, solve waypoints for hidden ones.
			if not HasVisualObstacle(WhoIsChasing) then
				SlasherHum:MoveTo(WhoIsChasing.Position)
			else
				local path = GetCalculatedPath(SlasherHRP.Position, WhoIsChasing.Position)
				if path then
					local wp = path:GetWaypoints()
					local nextPt = wp[2] or wp[1]
					if nextPt then ExecuteMove(nextPt.Position, "Chase", nextPt.Action == Enum.PathWaypointAction.Jump) end
				end
			end

			LastPlayerPos = WhoIsChasing.Position
			task.wait(0.2)
		end
	end)
end

--[[
	@behavior Search
	@desc Investigative logic.
	Phase 1: Navigate to the 'LastPlayerPos' (breadcrumb).
	Phase 2: Perform random spatial sampling (random offsets) to simulate a search pattern.
]]
local function SearchBehavior()
	if not LastPlayerPos or not LastPlayerSaw then 
		Slasher:SetAttribute("State", "Patrol") 
		return 
	end

	-- Move to last known spatial coordinate.
	local path = GetCalculatedPath(SlasherHRP.Position, LastPlayerPos)
	if path then
		for _, wp in ipairs(path:GetWaypoints()) do
			if Slasher:GetAttribute("State") ~= "Search" then return end
			ExecuteMove(wp.Position, "Search", wp.Action == Enum.PathWaypointAction.Jump)
		end
	end

	-- Random Spatial Sampling (Search Pattern).
	for i = 1, math.random(3, 5) do
		if Slasher:GetAttribute("State") ~= "Search" then break end
		local offset = Vector3.new(math.random(-15, 15), 0, math.random(-15, 15))
		local searchTarget = SlasherHRP.Position + offset

		local p = RaycastParams.new()
		p.FilterType = Enum.RaycastFilterType.Exclude
		p.FilterDescendantsInstances = {Slasher}
		local ray = workspace:Raycast(SlasherHRP.Position, (searchTarget - SlasherHRP.Position), p)

		local finalPos = ray and (ray.Position + (ray.Normal * 2)) or searchTarget
		ExecuteMove(finalPos, "Search", false)
		task.wait(math.random(0.5, 1.5))
	end

	if Slasher:GetAttribute("State") == "Search" then
		Slasher:SetAttribute("State", "Patrol")
	end
end

--== INITIALIZATION & EVENT MAPPING ==--

--[[
	@function OnBehaviorChange
	@desc Central dispatcher for the FSM. 
	CRITICAL: This function cancels the existing thread (task.cancel) to prevent 'Thread Overlap'.
	This ensures that only one behavior loop is active at any given time, preventing CPU overhead and buggy movement.
]]
local function OnBehaviorChange()
	if LoopConn then task.cancel(LoopConn); LoopConn = nil end
	
	local state = Slasher:GetAttribute("State") :: State
	if state == "Patrol" then PatrolBehavior()
	elseif state == "Hunt" then HuntBehavior()
	elseif state == "Chase" then ChaseBehavior()
	elseif state == "Search" then task.spawn(SearchBehavior) end
end

-- STARTUP: Global Perception Heartbeat.
-- This loop runs independently of behaviors to ensure the AI's "senses" are always active.
task.spawn(function()
	while Slasher.Parent do
		BrainTick()
		task.wait(CONFIG.SCAN_RATE)
	end
end)

-- Event Binding: Link the Slasher's 'State' Attribute to the FSM dispatcher.
Slasher:GetAttributeChangedSignal("State"):Connect(OnBehaviorChange)

-- Initialize the AI in the Patrol state.
OnBehaviorChange()
