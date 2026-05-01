--!strict

--== SERVICES ==--
local PathfindingService = game:GetService("PathfindingService")
local Players = game:GetService("Players")

--== CONSTANTS & TYPES ==--
type State = "Patrol" | "Hunt" | "Chase" | "Search"

-- AI Behavior configuration tuned for server performance and high-stakes gameplay
local CONFIG = {
	VIEW_DISTANCE = 50,    -- Spherical detection radius for player spotting
	HUNT_DISTANCE = 150,   -- Maximum range to maintain "indirect" awareness
	KILLER_FOV = 130,      -- Vision cone angle calculated via Dot Product
	ATTACK_DISTANCE = 5,   -- Effective melee hitbox range
	DAMAGE_AMOUNT = 15,    -- Damage applied per attack tick
	SCAN_RATE = 0.3,       -- Frequency of the perception loop (in seconds)
}

-- Physical agent constraints for the Pathfinding navigation engine
local AGENT_PARAMS = {
	AgentRadius = 4,
	AgentHeight = 5,
	AgentCanClimb = false,
	AgentCanJump = true,
}

--== REFERENCES ==--
local Slasher = workspace:WaitForChild("Ia") :: Model
local SlasherHRP = Slasher:WaitForChild("HumanoidRootPart") :: Part
local SlasherHum = Slasher:WaitForChild("Humanoid") :: Humanoid
local InterestPointsF = workspace:WaitForChild("InterestPoints") :: Folder

-- Set server network ownership to prevent client-side latency and "rubber-banding"
SlasherHRP:SetNetworkOwner(nil)

--== STATE VARIABLES ==--
local SpottedPlayers: {[string]: Player} = {}
local WhoIsChasing: Part? = nil
local LastPlayerPos: Vector3? = nil
local LastPlayerSaw: Player? = nil
local LoopConn: thread? = nil
local InterestPointsIndex = 1
local LastAttackTick = 0
local ClosestCharacter: Model? = nil

--== UTILITY FUNCTIONS ==--

-- Validates that a target model exists, is alive, and has necessary components
local function IsCharacterValid(char: Model?): boolean
	if not char then return false end
	local hum = char:FindFirstChildOfClass("Humanoid")
	return char.Parent ~= nil 
		and char:FindFirstChild("HumanoidRootPart") ~= nil 
		and hum ~= nil 
		and hum.Health > 0
end

-- Safely computes a path between two points with error handling via pcall
local function GetCalculatedPath(startPos: Vector3, endPos: Vector3): Path?
	local path = PathfindingService:CreatePath(AGENT_PARAMS)
	local success, _ = pcall(function()
		path:ComputeAsync(startPos, endPos)
	end)
	return (success and path.Status == Enum.PathStatus.Success) and path or nil
end

-- Checks for static environmental obstructions using Raycasting
local function HasVisualObstacle(targetHRP: Part): RaycastResult?
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = {Slasher, targetHRP.Parent}
	return workspace:Raycast(SlasherHRP.Position, (targetHRP.Position - SlasherHRP.Position), params)
end

--== PERCEPTION ENGINE ==--

-- Filters nearby players using Vector Algebra (Dot Product) and Line-of-Sight checks
local function GetPlayersInVision(): {[string]: Player}
	local visiblePlayers = {}
	local lookDir = SlasherHRP.CFrame.LookVector

	for _, plr in ipairs(Players:GetPlayers()) do
		local char = plr.Character
		if not IsCharacterValid(char) then continue end

		local targetHRP = char.HumanoidRootPart
		local offset = (targetHRP.Position - SlasherHRP.Position)
		
		-- Check 1: Radial Distance
		if offset.Magnitude > CONFIG.VIEW_DISTANCE then continue end

		-- Check 2: Angular Vision (Dot Product check)
		local unitDir = offset.Unit
		local dotResult = unitDir:Dot(lookDir)
		local angle = math.deg(math.acos(math.clamp(dotResult, -1, 1)))

		if angle <= CONFIG.KILLER_FOV / 2 then
			-- Check 3: Line of Sight (LOS)
			-- Uses a small Y-offset to prevent rays from clipping into floor geometry
			if not HasVisualObstacle(targetHRP) then
				visiblePlayers[plr.Name] = plr
			end
		end
	end
	return visiblePlayers
end

--== MOVEMENT CORE ==--

-- Robust movement function with state-based interruption and safety timeouts
local function ExecuteMove(targetPos: Vector3, requiredState: State, jump: boolean)
	local startTime = os.clock()
	local reached = false
	
	-- Y-offset ensures the Humanoid attempts to reach a point slightly above the floor
	local adjustedPos = targetPos + Vector3.new(0, 3, 0)
	
	SlasherHum:MoveTo(adjustedPos)
	if jump then SlasherHum.Jump = true end

	local connection = SlasherHum.MoveToFinished:Once(function() reached = true end)

	-- Break loop if destination reached, 20s timeout hit, or AI state changes
	repeat
		task.wait(0.1)
		local currentDist = (SlasherHRP.Position - adjustedPos).Magnitude
	until reached or currentDist < 3.5 or (os.clock() - startTime > 20) or Slasher:GetAttribute("State") ~= requiredState
	
	if connection then connection:Disconnect() end
end

--== BEHAVIOR LOGIC ==--

-- Determines the highest priority target from visible players
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

-- Central Perception Loop (The Brain)
local function BrainTick()
	local fovPlayers = GetPlayersInVision()
	UpdateTargetPriority(fovPlayers)

	for _, plr in pairs(SpottedPlayers) do
		local char = plr.Character
		if not IsCharacterValid(char) then continue end

		local hrp = char.HumanoidRootPart
		local distance = (SlasherHRP.Position - hrp.Position).Magnitude

		-- Verify path distance to prevent AI from seeing through thin reachable obstacles
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

				task.wait(math.random(1, 2)) -- Idle pause
				InterestPointsIndex += 1

				-- Hunt check: Triggered if a player is within the interest point radius
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

local function ChaseBehavior()
	LoopConn = task.spawn(function()
		while Slasher:GetAttribute("State") == "Chase" do
			if not WhoIsChasing or not WhoIsChasing.Parent then 
				Slasher:SetAttribute("State", "Search") 
				return 
			end

			local dist = (SlasherHRP.Position - WhoIsChasing.Position).Magnitude
			if dist > CONFIG.VIEW_DISTANCE then Slasher:SetAttribute("State", "Search") return end

			-- Melee Attack Logic: Server-side clock prevents cooldown bypass
			if dist < CONFIG.ATTACK_DISTANCE and (os.clock() - LastAttackTick > 1) then
				local hum = WhoIsChasing.Parent:FindFirstChild("Humanoid") :: Humanoid?
				if hum and hum.Health > 0 then
					LastAttackTick = os.clock()
					hum:TakeDamage(CONFIG.DAMAGE_AMOUNT)
				end
			end

			-- Navigation: Direct charge if visible, Pathfinding if occluded
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

local function SearchBehavior()
	if not LastPlayerPos or not LastPlayerSaw then 
		Slasher:SetAttribute("State", "Patrol") 
		return 
	end

	-- Move to the last known coordinate
	local path = GetCalculatedPath(SlasherHRP.Position, LastPlayerPos)
	if path then
		for _, wp in ipairs(path:GetWaypoints()) do
			if Slasher:GetAttribute("State") ~= "Search" then return end
			ExecuteMove(wp.Position, "Search", wp.Action == Enum.PathWaypointAction.Jump)
		end
	end

	-- Secondary phase: Search random vectors around the last known position
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

--== INITIALIZATION ==--

-- Cleanly switches behavior threads based on state changes to prevent memory leaks
local function OnBehaviorChange()
	if LoopConn then task.cancel(LoopConn); LoopConn = nil end
	
	local state = Slasher:GetAttribute("State") :: State
	if state == "Patrol" then PatrolBehavior()
	elseif state == "Hunt" then HuntBehavior()
	elseif state == "Chase" then ChaseBehavior()
	elseif state == "Search" then task.spawn(SearchBehavior) end
end

-- Global Perception Heartbeat
task.spawn(function()
	while Slasher.Parent do
		BrainTick()
		task.wait(CONFIG.SCAN_RATE)
	end
end)

Slasher:GetAttributeChangedSignal("State"):Connect(OnBehaviorChange)
OnBehaviorChange() -- Init
