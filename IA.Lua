local PathfindingService = game:GetService("PathfindingService")
local Players = game:GetService("Players")

local Slasher = game.Workspace.Ia
local SlasherHRP = Slasher.HumanoidRootPart

-- Force server-side ownership to prevent stuttering and network latency
SlasherHRP:SetNetworkOwner(nil) 

local SlasherHum = Slasher.Humanoid
local InterestPointsF = game.Workspace.InterestPoints

--== SETTINGS & CONFIGURATION ==--
-- Tuning these variables allows for easy gameplay balance updates
local AGENT_PARAMS = {
	AgentRadius = 4,
	AgentHeight = 5,
	AgentCanClimb = false,
	AgentCanJump = true,
}

local Config = {
	ViewDistance = 50,
	HuntDistance = 150,
	KillerFov = 130,
	AttackDistance = 5,
	Damage = 15,
}

-- Helper to safely compute navigation paths, handling potential failure states
local function FindPath(startPos, endPos)
	local path = PathfindingService:CreatePath(AGENT_PARAMS)
	local success, errorMessage = pcall(function()
		path:ComputeAsync(startPos, endPos)
	end)

	if success and path.Status == Enum.PathStatus.Success then
		return path
	else
		warn("Pathfinding failed: " .. (errorMessage or tostring(path.Status)))
		return nil
	end
end

--== VISION & PERCEPTION ==--
-- Identifies players within the Slasher's vision cone
local function PlayersInFov()
	local fovPlayers = {}
	if not SlasherHRP then return end
	local HRPLookVector = SlasherHRP.CFrame.LookVector

	for _, plr in pairs(Players:GetPlayers()) do		
		local Char = plr.Character
		if not plr.Character then continue end

		local HRP2 = Char:FindFirstChild("HumanoidRootPart")
		if not HRP2 then continue end

		-- Ignore players outside the maximum view distance for performance
		if (SlasherHRP.Position - HRP2.Position).Magnitude > Config.ViewDistance then continue end

		-- Calculate Dot Product to verify if the player is within the FOV angle
		local Unit = (HRP2.Position - SlasherHRP.Position).Unit
		local Dot = Unit:Dot(HRPLookVector)
		local angle = math.deg(math.acos(Dot))

		if angle <= Config.KillerFov / 2 then
			-- Raycast to verify line-of-sight (ensures walls don't count as 'seeing' players)
			local Params = RaycastParams.new()
			Params.FilterType = Enum.RaycastFilterType.Exclude
			Params.FilterDescendantsInstances = {Slasher, Char}

			local Raycast = workspace:Raycast(SlasherHRP.Position + Vector3.new(0, 2, 0), (HRP2.Position - SlasherHRP.Position), Params)

			if Raycast then continue end

			fovPlayers[plr.Name] = plr
		end
	end
	return fovPlayers
end

--== MAIN PROCESSING LOOP ==--
local SpottedPlayers = {}
local State = Slasher:SetAttribute("State", "Patrol")
local WhoIsChasing = nil
local LastPlayerPos = nil
local LastplayerSaw = nil

-- Dedicated loop to handle AI perception (runs frequently to keep AI responsive)
local function KillerView()
	local fovPlayers = PlayersInFov()
	local HasPlayers = (next(fovPlayers) ~= nil)

	local Nearest
	local NearestDist = Config.ViewDistance + 1

	if HasPlayers then
		for _, plr in pairs(fovPlayers) do
			local Char = plr.Character
			if not plr.Character then continue end
			local HRP2 = Char:FindFirstChild("HumanoidRootPart")
			if not HRP2 then continue end

			if (HRP2.Position - SlasherHRP.Position).Magnitude < NearestDist then
				NearestDist = (HRP2.Position - SlasherHRP.Position).Magnitude
				Nearest = HRP2
				WhoIsChasing = HRP2
				LastplayerSaw = plr
				SpottedPlayers[plr.Name] = plr
			else
				if SpottedPlayers[plr.Name] then SpottedPlayers[plr.Name] = nil end
			end
		end
	end

	-- Logic for tracking visible and pathable players
	for _, plr in pairs(SpottedPlayers) do
		if not plr or not plr.Character or not plr.Parent then SpottedPlayers[plr.Name] = nil end
		local Char = plr.Character
		if not Char then continue end
		local HRP2 = Char:FindFirstChild("HumanoidRootPart")
		if not HRP2 then continue end

		local Distance = (HRP2.Position - SlasherHRP.Position).Magnitude
		if Distance < Config.ViewDistance then
			local Params = RaycastParams.new()
			Params.FilterType = Enum.RaycastFilterType.Exclude
			Params.FilterDescendantsInstances = {Slasher, Char}
			local Raycast = workspace:Raycast(SlasherHRP.Position + Vector3.new(0, 2, 0), (HRP2.Position - SlasherHRP.Position), Params)

			local WalkableDistance = 0
			if Raycast then
				-- If blocked, calculate path length instead of direct line distance
				local Path = FindPath(SlasherHRP.Position, HRP2.Position)
				if Path then
					local PathPoints = Path:GetWaypoints()
					for i, waypoint in pairs(PathPoints) do
						if i > 1 then WalkableDistance += (waypoint.Position - PathPoints[i - 1].Position).Magnitude end
					end
				end
			else
				WalkableDistance = (HRP2.Position - SlasherHRP.Position).Magnitude
			end

			if WalkableDistance > Config.ViewDistance / 3 then WalkableDistance = 100000 end
			if WalkableDistance < NearestDist then
				Nearest = HRP2
				NearestDist = Distance
			end
		end
	end

	-- Update State to Chase if a target is found
	if Nearest and Nearest.Parent then
		WhoIsChasing = Nearest
		Slasher:SetAttribute("State", "Chase")
	end
end

task.spawn(function()
	while true do
		task.wait(.3)
		KillerView()
	end
end)

--== HELPER FUNCTIONS ==--
-- Standardized movement to prevent AI from getting stuck
local function MoveToPoint(targetPos, stateToCheck, NeedToJump)
	if not targetPos then return end
	targetPos = targetPos + Vector3.new(0, 3, 0)
	
	local startT = tick()
	local Reached = false
	SlasherHum:MoveTo(targetPos)
	if NeedToJump then Slasher.Humanoid.Jump = true end
	
	local Conn = SlasherHum.MoveToFinished:Once(function() Reached = true end)
	
	-- Movement loop with timeout and state validation
	repeat
		task.wait(.1)
		local currentDistance = (SlasherHRP.Position - targetPos).Magnitude
	until Reached or currentDistance < 3.5 or (tick() - startT > 30) or State ~= stateToCheck
	if Conn then Conn:Disconnect() end
end

-- Reusable check for line-of-sight
local function CanSee(TargetHRP)
	local Params = RaycastParams.new()
	Params.FilterType = Enum.RaycastFilterType.Exclude
	Params.FilterDescendantsInstances = {Slasher, TargetHRP.Parent}
	return workspace:Raycast(SlasherHRP.Position, (TargetHRP.Position - SlasherHRP.Position), Params)
end

--== BEHAVIOR STATES ==--
local LoopConn
local InterestPointsIndex = 1
local ClosestCharacter

-- Patrol: Wandering between pre-defined interest points
local function PatrolBehavior()
	if LoopConn then task.cancel(LoopConn) end
	LoopConn = task.spawn(function()
		while Slasher:GetAttribute("State") == "Patrol" do
			local CurrentInterestPoint = InterestPointsF:FindFirstChild(InterestPointsIndex)
			if CurrentInterestPoint then
				local Distance = (CurrentInterestPoint.Position - SlasherHRP.Position).Magnitude
				if Distance < 10 then InterestPointsIndex += 1 return end
				local Path = FindPath(SlasherHRP.Position, CurrentInterestPoint.Position)
				if Path then
					local Waypoints = Path:GetWaypoints()
					for _, WPS in pairs(Waypoints) do
						if Slasher:GetAttribute("State") ~= "Patrol" then return end
						MoveToPoint(WPS.Position, "Patrol", WPS.Action == Enum.PathWaypointAction.Jump)
					end
					task.wait(math.random(1,3))
					InterestPointsIndex += 1
					
					-- Look for nearby players after reaching an interest point
					ClosestCharacter = nil
					local ClosestDistance = Config.HuntDistance
					for _, plrs in pairs(Players:GetPlayers()) do
						if plrs.Character and plrs.Character:FindFirstChild("HumanoidRootPart") and plrs.Character:FindFirstChild("Humanoid") then
							if plrs.Character.Humanoid.Health > 0 then
								local dist = (plrs.Character.HumanoidRootPart.Position - CurrentInterestPoint.Position).Magnitude
								if dist < ClosestDistance then
									ClosestCharacter = plrs.Character
									ClosestDistance = dist
								end
							end
						end
					end
					if ClosestCharacter and Slasher:GetAttribute("State") == "Patrol" then Slasher:SetAttribute("State", "Hunt") end
				end
			else
				task.wait(1)
				InterestPointsIndex = 1
			end
		end
	end)
end

-- Hunt: Tracking a target after being alerted
local function HuntBehavior()
	local Distance = (SlasherHRP.Position - ClosestCharacter.HumanoidRootPart.Position).Magnitude
	task.spawn(function()
		while Slasher:GetAttribute("State") == "Hunt" do
			if not ClosestCharacter or not ClosestCharacter.Parent then Slasher:SetAttribute("State", "Patrol") break end
			if Distance > Config.HuntDistance then Slasher:SetAttribute("State", "Patrol") return end
			if not ClosestCharacter:FindFirstChild("HumanoidRootPart") then Slasher:SetAttribute("State", "Patrol") break end
			Distance = (SlasherHRP.Position - ClosestCharacter.HumanoidRootPart.Position).Magnitude
			task.wait(0.5)
		end
	end)

	if LoopConn then task.cancel(LoopConn) end
	LoopConn = task.spawn(function()
		while Slasher:GetAttribute("State") == "Hunt" do
			if not ClosestCharacter or not ClosestCharacter.Parent then Slasher:SetAttribute("State", "Patrol") break end
			if Distance > Config.HuntDistance then Slasher:SetAttribute("State", "Patrol") return end
			if not ClosestCharacter:FindFirstChild("HumanoidRootPart") then Slasher:SetAttribute("State", "Patrol") break end
			
			local RayC = CanSee(ClosestCharacter.HumanoidRootPart)
			if not RayC then
				SlasherHum:MoveTo(ClosestCharacter.HumanoidRootPart.Position)
			else
				local path = FindPath(SlasherHRP.Position, ClosestCharacter.HumanoidRootPart.Position)
				if path then
					local WayPoints = path:GetWaypoints()
					for i, v in pairs(WayPoints) do
						MoveToPoint(v.Position, "Hunt", v.Action == Enum.PathWaypointAction.Jump)
					end
				end
			end
			task.wait(0.1)
		end
	end)
end

-- Chase: High-priority pursuit logic when target is visible
local function ChaseBehavior()
	if LoopConn then task.cancel(LoopConn) end
	LoopConn = task.spawn(function()
		while Slasher:GetAttribute("State") == "Chase" do
			if not WhoIsChasing then Slasher:SetAttribute("State", "Search") return end
			local Distance = (SlasherHRP.Position - WhoIsChasing.Position).Magnitude
			if Distance > Config.ViewDistance then Slasher:SetAttribute("State", "Search") return end
			
			local RayC = CanSee(WhoIsChasing)
			if RayC then
				local Path = FindPath(SlasherHRP.Position, WhoIsChasing.Position)
				if Path then
					local WayPoints = Path:GetWaypoints()
					if WayPoints[2] then MoveToPoint(WayPoints[2].Position, "Chase", WayPoints[2].Action == Enum.PathWaypointAction.Jump) end
				end
			else
				SlasherHum:MoveTo(WhoIsChasing.Position)
				task.wait(0.1)
			end
			
			-- Attack logic
			Distance = (SlasherHRP.Position - WhoIsChasing.Position).Magnitude
			if Distance < Config.AttackDistance then
				local Hum = WhoIsChasing.Parent:FindFirstChild("Humanoid")
				if Hum and Hum.Health > 0 then Hum:TakeDamage(Config.Damage) task.wait(0.5) end
			end
			LastPlayerPos = WhoIsChasing.Position
		end
	end)
end

-- Search: Area investigation when the target is lost
local function SearchBehavior()
	if State ~= "Search" then return end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = {Slasher}
	
	if LastPlayerPos and LastplayerSaw then
		if not LastplayerSaw.Character or not LastPlayerPos then return end
		params.FilterDescendantsInstances = {Slasher, LastplayerSaw.Character}
		local RayC = workspace:Raycast(SlasherHRP.Position, (LastPlayerPos - SlasherHRP.Position), params)
		if RayC then
			local Path = FindPath(SlasherHRP.Position, LastPlayerPos)
			if Path then
				local WayPoints = Path:GetWaypoints()
				if State ~= "Search" then return end	
				for i = 1, #WayPoints, 1 do MoveToPoint(WayPoints[i].Position, "Search", WayPoints[i].Action == Enum.PathWaypointAction.Jump) end
			end
		else
			MoveToPoint(LastPlayerPos, "Search")
		end
	end
	
	-- Random searching movement
	if State == "Search" then
		for i = 1, math.random(3,5), 1 do
			local RandomPos = Vector3.new(math.random(-15, 15), 0, math.random(-15, 15))
			local RandomPoint = SlasherHRP.Position + RandomPos
			params.FilterDescendantsInstances = {Slasher}
			local RayC = workspace:Raycast(SlasherHRP.Position, (RandomPoint - SlasherHRP.Position), params)
			if RayC then
				local Position = RayC.Position + (RayC.Normal * 2)
				MoveToPoint(Position, "Search")
			else
				MoveToPoint(RandomPoint, "Search")
			end
			task.wait(math.random(0.5, 1.5))
		end
	end
	
	if State == "Search" then Slasher:SetAttribute("State", "Patrol") end
end

-- State Dispatcher: Listens for changes to switch behaviors instantly
local function BehaviorChange()
	State = Slasher:GetAttribute("State")
	if State == "Patrol" then PatrolBehavior()
	elseif State == "Hunt" then HuntBehavior()
	elseif State == "Chase" then ChaseBehavior()
	elseif State == "Search" then SearchBehavior()
	end
end

Slasher:GetAttributeChangedSignal("State"):Connect(BehaviorChange)
BehaviorChange()
