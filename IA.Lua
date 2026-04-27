local PathfindingService = game:GetService("PathfindingService")
local Players = game:GetService("Players")

-- Model References
local Slasher = workspace.Ia
local SlasherHRP = Slasher.HumanoidRootPart
local SlasherHum = Slasher.Humanoid

-- Ensure the server owns the physics to prevent client-side latency issues (rubber-banding)
SlasherHRP:SetNetworkOwner(nil)

-- Folder containing patrol waypoints
local InterestPointsF = workspace.InterestPoints

--== NAVIGATION & COMBAT CONFIGURATION ==--

-- Agent parameters define the physical limitations of the AI during Pathfinding
local AGENT_PARAMS = {
	AgentRadius = 4,
	AgentHeight = 5,
	AgentCanClimb = false,
	AgentCanJump = true,
}

local Config = {
	ViewDistance = 50,    -- Max distance the AI can "see"
	HuntDistance = 150,   -- Max tracking range for the "Hunt" state
	KillerFov = 130,      -- The angle of the vision cone in degrees
	AttackDistance = 5,   -- Melee attack range
	Damage = 15,          -- HP subtracted per hit
}

--== NAVIGATION LOGIC ==--

--[[
	Calculates a path between two points using PathfindingService.
	Utilizes pcall to safely handle potential service outages or computation errors.
]]
local function FindPath(startPos, endPos)
	local path = PathfindingService:CreatePath(AGENT_PARAMS)

	local success, errorMessage = pcall(function()
		path:ComputeAsync(startPos, endPos)
	end)

	if success and path.Status == Enum.PathStatus.Success then
		return path
	else
		warn("Pathfinding failed to compute: " .. (errorMessage or tostring(path.Status)))
		return nil
	end
end

--== PERCEPTION & SENSES ==--

--[[
	Filters players based on distance, viewing angle, and visual obstructions.
	
	The vision cone uses the Dot Product formula:
	$$\mathbf{a} \cdot \mathbf{b} = \cos(\theta)$$
	This allows us to determine the angle between the Slasher's face and the player's position.
]]
local function PlayersInFov()
	local fovPlayers = {}
	if not SlasherHRP then return end

	local HRPLookVector = SlasherHRP.CFrame.LookVector

	for _, plr in pairs(Players:GetPlayers()) do		
		local Char = plr.Character
		if not Char then continue end

		local HRP2 = Char:FindFirstChild("HumanoidRootPart")
		if not HRP2 then continue end

		-- Check 1: Radial Distance
		if (SlasherHRP.Position - HRP2.Position).Magnitude > Config.ViewDistance then continue end

		-- Check 2: Angular Vision (Dot Product)
		local UnitDirection = (HRP2.Position - SlasherHRP.Position).Unit
		local Dot = UnitDirection:Dot(HRPLookVector)
		Dot = math.clamp(Dot, -1, 1) -- Clamp to prevent precision errors in math.acos
		local angle = math.deg(math.acos(Dot))

		if angle <= Config.KillerFov / 2 then
			-- Check 3: Line of Sight (Raycasting to detect walls/objects)
			local Params = RaycastParams.new()
			Params.FilterType = Enum.RaycastFilterType.Exclude
			Params.FilterDescendantsInstances = {Slasher, Char}

			-- Raycast starts slightly above the torso to avoid clipping the floor
			local Raycast = workspace:Raycast(SlasherHRP.Position + Vector3.new(0, 2, 0), (HRP2.Position - SlasherHRP.Position), Params)

			if Raycast then continue end -- Something is blocking the view

			fovPlayers[plr.Name] = plr
		end
	end

	return fovPlayers
end

--== STATE MACHINE MANAGEMENT ==--

local SpottedPlayers = {} 
Slasher:SetAttribute("State", "Patrol") 

local WhoIsChasing = nil   -- Current chase target
local LastPlayerPos = nil  -- Stored for the "Search" state
local LastplayerSaw = nil  -- Reference to the last player spotted

-- Quick validation for target characters
local function IsCharacterValid(char)
	return char and char.Parent and char:FindFirstChild("HumanoidRootPart") and char:FindFirstChild("Humanoid") and char.Humanoid.Health > 0
end

-- Determines the highest priority target (closest) from the detected list
local function CheckPlayers(HasPlayers, fovPlayers)
	if not HasPlayers then return end

	local nearestHRP = nil
	local nearestDist = Config.ViewDistance + 1
	local NewTable = {}

	for _, plr in pairs(fovPlayers) do
		local Char = plr.Character
		if not IsCharacterValid(Char) then continue end

		local HRP2 = Char:FindFirstChild("HumanoidRootPart")
		local dist = (SlasherHRP.Position - HRP2.Position).Magnitude

		if dist < nearestDist then
			nearestDist = dist
			nearestHRP = HRP2
			LastplayerSaw = plr
		end
		NewTable[plr.Name] = plr
	end

	if nearestHRP then
		WhoIsChasing = nearestHRP
	end
	SpottedPlayers = NewTable
end

-- The "Brain" tick: Runs continuously to monitor surroundings and trigger state changes
local function KillerView()
	local fovPlayers = PlayersInFov()
	local HasPlayers = (next(fovPlayers) ~= nil)

	CheckPlayers(HasPlayers, fovPlayers)

	for name, plr in pairs(SpottedPlayers) do
		if not plr or not plr.Character or not plr.Parent then
			SpottedPlayers[name] = nil
		end

		local Char = plr.Character
		if not IsCharacterValid(Char) then continue end

		local HRP2 = Char:FindFirstChild("HumanoidRootPart")
		local distance = (SlasherHRP.Position - HRP2.Position).Magnitude

		-- Verify if the path is physically reachable (prevents chasing through fences/glass)
		local walkableDistance = distance
		if HasObstacle(HRP2) then
			local path = FindPath(SlasherHRP.Position, HRP2.Position)
			if path then
				local points = path:GetWaypoints()
				walkableDistance = 0
				for i = 2, #points do
					walkableDistance += (points[i].Position - points[i - 1].Position).Magnitude
				end
			end
		end

		-- If the target is physically reachable within a reasonable distance, start the chase
		if walkableDistance < Config.ViewDistance then
			WhoIsChasing = HRP2
			Slasher:SetAttribute("State", "Chase")
		end
	end
end

-- Global Perception Loop
task.spawn(function()
	while Slasher and Slasher.Parent do
		task.wait(0.3) -- Scanning frequency balanced for server performance
		KillerView()
	end
end)

--== MOVEMENT HELPERS ==--

--[[
	Moves the NPC to a specific waypoint with jump support and a safety timeout.
	Movement is interrupted if the AI's state changes during transit.
]]
local function MoveToPoint(targetPos, stateToCheck, NeedToJump)
	if not targetPos then return end

	targetPos = targetPos + Vector3.new(0, 3, 0) -- Slight Y-offset for precision

	local startT = os.clock()
	local reached = false
	SlasherHum:MoveTo(targetPos)

	if NeedToJump then Slasher.Humanoid.Jump = true end

	local Conn = SlasherHum.MoveToFinished:Once(function()
		reached = true
	end)

	-- Wait loop with state-change cancellation and a 20-second stall timeout
	repeat
		task.wait(0.1)
		local currentDistance = (SlasherHRP.Position - targetPos).Magnitude
	until reached or currentDistance < 3.5 or (os.clock() - startT > 20) or Slasher:GetAttribute("State") ~= stateToCheck
	
	if Conn then Conn:Disconnect() end
end

-- Checks for physical obstructions between the Slasher and a target
local function HasObstacle(TargetHRP)
	local Params = RaycastParams.new()
	Params.FilterType = Enum.RaycastFilterType.Exclude
	Params.FilterDescendantsInstances = {Slasher, TargetHRP.Parent}
	return workspace:Raycast(SlasherHRP.Position, (TargetHRP.Position - SlasherHRP.Position), Params)
end

--== CORE BEHAVIORS ==--

local LoopConn -- Current behavior thread (cancelled on state transition)
local InterestPointsIndex = 1
local ClosestCharacter

-- STATE: Patrol - AI wanders between set interest points
local function PatrolBehavior()
	if LoopConn then task.cancel(LoopConn) LoopConn = nil end

	LoopConn = task.spawn(function()
		while Slasher:GetAttribute("State") == "Patrol" do
			local Point = InterestPointsF:FindFirstChild(InterestPointsIndex)

			if Point then
				local dist = (Point.Position - SlasherHRP.Position).Magnitude
				if dist < 10 then InterestPointsIndex += 1 continue end

				local path = FindPath(SlasherHRP.Position, Point.Position)
				if path then
					for _, wp in pairs(path:GetWaypoints()) do
						if Slasher:GetAttribute("State") ~= "Patrol" then return end
						MoveToPoint(wp.Position, "Patrol", wp.Action == Enum.PathWaypointAction.Jump)
					end
				end

				task.wait(math.random(1, 2)) -- Idle time at point
				InterestPointsIndex += 1

				-- Check if any player is close to the interest point to trigger a "Hunt"
				ClosestCharacter = nil
				local closestDist = Config.HuntDistance
				for _, plr in pairs(Players:GetPlayers()) do
					if IsCharacterValid(plr.Character) then
						local d = (plr.Character.HumanoidRootPart.Position - Point.Position).Magnitude
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
				InterestPointsIndex = 1 -- Loop back to start of patrol
			end
			task.wait(0.3)
		end
	end)
end

-- STATE: Hunt - Tracking a target's general location (indirect awareness)
local function HuntBehavior()
	if LoopConn then task.cancel(LoopConn) LoopConn = nil end

	LoopConn = task.spawn(function()
		while Slasher:GetAttribute("State") == "Hunt" do
			if not IsCharacterValid(ClosestCharacter) then Slasher:SetAttribute("State", "Patrol") break end
			
			local dist = (SlasherHRP.Position - ClosestCharacter.HumanoidRootPart.Position).Magnitude
			if dist > Config.HuntDistance then Slasher:SetAttribute("State", "Patrol") return end

			if not HasObstacle(ClosestCharacter.HumanoidRootPart) then
				SlasherHum:MoveTo(ClosestCharacter.HumanoidRootPart.Position)
			else
				local path = FindPath(SlasherHRP.Position, ClosestCharacter.HumanoidRootPart.Position)
				if path then
					for _, wp in pairs(path:GetWaypoints()) do
						MoveToPoint(wp.Position, "Hunt", wp.Action == Enum.PathWaypointAction.Jump)
					end
				end
			end
			task.wait(0.3)
		end
	end)
end

-- STATE: Chase - Active pursuit with direct line of sight and combat logic
local LastAttackTick = 0
local function ChaseBehavior()
	if LoopConn then task.cancel(LoopConn) LoopConn = nil end

	LoopConn = task.spawn(function()
		while Slasher:GetAttribute("State") == "Chase" do
			if not WhoIsChasing then Slasher:SetAttribute("State", "Search") return end

			local dist = (SlasherHRP.Position - WhoIsChasing.Position).Magnitude
			if dist > Config.ViewDistance then Slasher:SetAttribute("State", "Search") return end

			if HasObstacle(WhoIsChasing) then
				-- Target lost behind cover; use pathfinding for the next waypoint
				local path = FindPath(SlasherHRP.Position, WhoIsChasing.Position)
				if path then
					local wp = path:GetWaypoints()
					local nextPt = wp[2] or wp[1]
					MoveToPoint(nextPt.Position, "Chase", nextPt.Action == Enum.PathWaypointAction.Jump)
				end
			else
				-- Target visible; charge directly
				SlasherHum:MoveTo(WhoIsChasing.Position)
			end
			
			-- Melee Attack Logic
			if dist < Config.AttackDistance then
				local hum = WhoIsChasing.Parent:FindFirstChild("Humanoid")
				if hum and hum.Health > 0 and os.clock() - LastAttackTick > 1 then
					LastAttackTick = os.clock()
					hum:TakeDamage(Config.Damage)
				end
			end

			LastPlayerPos = WhoIsChasing.Position -- Store location in case they escape
			task.wait(0.2)
		end
	end)
end

-- STATE: Search - AI investigates the last known location and searches nearby random spots
local function SearchBehavior()
	if Slasher:GetAttribute("State") ~= "Search" then return end
	if not LastPlayerPos or not LastplayerSaw then Slasher:SetAttribute("State", "Patrol") return end

	-- Phase 1: Move to the last seen coordinate
	if HasObstacle(LastplayerSaw.Character.HumanoidRootPart) then
		local path = FindPath(SlasherHRP.Position, LastPlayerPos)
		if path then
			for _, wp in pairs(path:GetWaypoints()) do
				if Slasher:GetAttribute("State") ~= "Search" then return end
				MoveToPoint(wp.Position, "Search", wp.Action == Enum.PathWaypointAction.Jump)
			end
		end
	else
		MoveToPoint(LastPlayerPos, "Search")
	end

	-- Phase 2: Search random nearby vectors (simulating investigation)
	for i = 1, math.random(3, 5) do
		if Slasher:GetAttribute("State") ~= "Search" then break end
		local offset = Vector3.new(math.random(-15, 15), 0, math.random(-15, 15))
		local searchTarget = SlasherHRP.Position + offset

		-- Simple raycast to ensure we aren't searching inside a wall
		local p = RaycastParams.new()
		p.FilterType = Enum.RaycastFilterType.Exclude
		p.FilterDescendantsInstances = {Slasher}
		local ray = workspace:Raycast(SlasherHRP.Position, (searchTarget - SlasherHRP.Position), p)

		if ray then
			MoveToPoint(ray.Position + (ray.Normal * 2), "Search")
		else
			MoveToPoint(searchTarget, "Search")
		end
		task.wait(math.random(0.5, 1.5))
	end

	task.wait(1)
	if Slasher:GetAttribute("State") == "Search" then
		Slasher:SetAttribute("State", "Patrol")
	end
end

--== INITIALIZATION ==--

local function BehaviorChange()
	local currentState = Slasher:GetAttribute("State")
	
	-- Clean up existing behavior threads before starting a new state
	if LoopConn then
		task.cancel(LoopConn)
		LoopConn = nil
	end
	
	if currentState == "Patrol" then PatrolBehavior()
	elseif currentState == "Hunt" then HuntBehavior()
	elseif currentState == "Chase" then ChaseBehavior()
	elseif currentState == "Search" then SearchBehavior()
	end
end

-- Connect state changes and initialize the machine
Slasher:GetAttributeChangedSignal("State"):Connect(BehaviorChange)
BehaviorChange()
