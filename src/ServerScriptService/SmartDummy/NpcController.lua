-- Connected Discord-GitHub
--!strict

--[[ npc controller

this module owns the dummy rig and all Roblox movement
the main script gives Execute an intent that Brain already found
then this module handles following paths jumping sitting spinning and orbiting

one Heartbeat loop updates follow movement and looking
commands mostly change the current state instead of making permanent new loops ]]

local Chat = game:GetService("Chat")
local PathfindingService = game:GetService("PathfindingService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Config = require(script.Parent.Config)
local TextUtil = require(script.Parent.TextUtil)

type RigParts = {
	model: Model,
	root: BasePart,
	head: BasePart,
	humanoid: Humanoid,
}

type PathState = {
	active: boolean,
	goal: Vector3?,
	waypoints: { PathWaypoint },
	index: number,
	nextComputeAt: number,
}

type DummyState = "idle" | "following" | "moving" | "sitting" | "performing"

local NpcController = {}
NpcController.__index = NpcController

-- movement uses flat vectors because player height should not tilt the dummy up or down
local function flat(vector: Vector3): Vector3
	return Vector3.new(vector.X, 0, vector.Z)
end

local function flatUnit(vector: Vector3): Vector3?
	-- a zero vector has no direction so i return nil instead of using its Unit
	local value = flat(vector)
	if value.Magnitude < 0.001 then
		return nil
	end
	return value.Unit
end

local function getRoot(player: Player): BasePart?
	-- players can respawn between commands so i get the current character and root each time
	local character = player.Character
	if not character then
		return nil
	end
	return character:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function getHead(player: Player): BasePart?
	local character = player.Character
	if not character then
		return nil
	end
	return character:FindFirstChild("Head") :: BasePart?
end

local function makeRayParams(ignore: { Instance }): RaycastParams
	-- the ray ignores these models so it only finds a real wall or object between them
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignore
	params.IgnoreWater = true
	return params
end

function NpcController.new()
	-- there is one controller because every player talks to the same dummy
	-- this table holds the current movement look target path and connections
	local self = setmetatable({
		_parts = nil :: RigParts?,
		_state = "idle" :: DummyState,
		_focusPlayer = nil :: Player?,
		_focusUntil = 0,
		_followPlayer = nil :: Player?,
		_walkSpeed = Config.WalkSpeed,
		_path = {
			active = false,
			goal = nil,
			waypoints = {},
			index = 1,
			nextComputeAt = 0,
		} :: PathState,
		_connections = {} :: { RBXScriptConnection },
	}, NpcController)

	self._parts = self:_resolveRig()
	self:_configureHumanoid()
	self:_connectRuntime()
	return self
end

function NpcController:_createRuntimeRig(): Model
	-- if there is no custom AIDummy in Workspace i make a normal R15 one here
	local description = Instance.new("HumanoidDescription")
	local ok, generated = pcall(function()
		return Players:CreateHumanoidModelFromDescription(description, Enum.HumanoidRigType.R15)
	end)
	if not ok or not generated then
		error("failed to create runtime dummy")
	end

	generated.Name = Config.DummyName
	generated:PivotTo(Config.SpawnCFrame)
	generated.Parent = Workspace
	return generated
end

--[[ the server gets network ownership of every rig part
the server is deciding the movement so a nearby player should not take over its physics
this also keeps the dummy movement the same for everyone ]]
function NpcController:_resolveRig(): RigParts
	local model = Workspace:FindFirstChild(Config.DummyName)
	if not model or not model:IsA("Model") then
		model = self:_createRuntimeRig()
	end

	local root = model:FindFirstChild("HumanoidRootPart")
	local head = model:FindFirstChild("Head")
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if not root or not root:IsA("BasePart") or not head or not head:IsA("BasePart") or not humanoid then
		error("AIDummy must be a Model with HumanoidRootPart, Head, and Humanoid")
	end

	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = false
			if descendant.Name == "HumanoidRootPart" then
				descendant.CanCollide = false
				descendant.Massless = true
			end
			pcall(function()
				descendant:SetNetworkOwner(nil)
			end)
		end
	end

	return { model = model, root = root, head = head, humanoid = humanoid }
end

function NpcController:_configureHumanoid()
	-- AutoRotate is off because _facePosition handles the smooth turning itself
	local parts = self._parts :: RigParts
	parts.humanoid.AutoRotate = false
	parts.humanoid.WalkSpeed = self._walkSpeed
	parts.humanoid.BreakJointsOnDeath = false
	parts.humanoid.MaxHealth = 1_000_000
	parts.humanoid.Health = parts.humanoid.MaxHealth
	parts.humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
	pcall(function()
		parts.humanoid.UseJumpPower = true
		parts.humanoid.JumpPower = Config.JumpPower
	end)
end

--[[ these are the three runtime connections
HealthChanged keeps the demo dummy alive MoveToFinished changes waypoints
and Heartbeat updates following looking and finished action state ]]
function NpcController:_connectRuntime()
	local parts = self._parts :: RigParts
	table.insert(self._connections, parts.humanoid.HealthChanged:Connect(function()
		if parts.humanoid.Health < parts.humanoid.MaxHealth then
			parts.humanoid.Health = parts.humanoid.MaxHealth
		end
	end))

	table.insert(self._connections, parts.humanoid.MoveToFinished:Connect(function(reached)
		if reached and self._path.active then
			self._path.index += 1
			self:_advancePath()
		end
	end))

	table.insert(self._connections, RunService.Heartbeat:Connect(function(deltaTime)
		self:_step(deltaTime)
	end))
end

function NpcController:_clearPath()
	-- clear every path value so an old waypoint cannot affect the next move
	-- i reuse the table because following can clear paths many times
	self._path.active = false
	self._path.goal = nil
	table.clear(self._path.waypoints)
	self._path.index = 1
end

--[[ paths are not made every frame because that would waste work and restart the route
the old path is reused until enough time passes or the goal moves far enough ]]
function NpcController:_computePath(goal: Vector3): boolean
	local parts = self._parts :: RigParts
	local now = os.clock()
	if self._path.goal and (self._path.goal - goal).Magnitude < Config.PathGoalEpsilon and now < self._path.nextComputeAt then
		return self._path.active
	end

	self._path.nextComputeAt = now + Config.PathRefreshSeconds
	self._path.goal = goal

	local path = PathfindingService:CreatePath({
		AgentRadius = 2,
		AgentHeight = 5,
		AgentCanJump = true,
		WaypointSpacing = 4,
	})

	-- ComputeAsync can fail for a bad goal or navmesh so pcall keeps the controller running
	local ok = pcall(function()
		path:ComputeAsync(parts.root.Position, goal)
	end)
	if not ok or path.Status ~= Enum.PathStatus.Success then
		self:_clearPath()
		return false
	end

	self._path.waypoints = path:GetWaypoints()
	self._path.index = 1
	self._path.active = true
	return true
end

function NpcController:_advancePath()
	-- MoveToFinished moves the index then calls this for the next waypoint
	-- if that waypoint needs a jump the Humanoid jumps before moving to it
	local parts = self._parts :: RigParts
	local waypoint = self._path.waypoints[self._path.index]
	if not waypoint then
		self:_clearPath()
		if self._state == "moving" then
			self._state = "idle"
		end
		return
	end

	if waypoint.Action == Enum.PathWaypointAction.Jump then
		parts.humanoid.Jump = true
	end
	parts.humanoid:MoveTo(waypoint.Position)
end

function NpcController:_moveTo(goal: Vector3, state: DummyState?)
	-- all move commands use this so path and fallback behavior stays in one place
	-- a good path is used first and direct MoveTo is the fallback
	local parts = self._parts :: RigParts
	if flat(goal - parts.root.Position).Magnitude < 1 then
		return
	end

	self._state = state or "moving"
	if self:_computePath(goal) then
		self:_advancePath()
	else
		parts.humanoid:MoveTo(goal)
	end
end

function NpcController:_nearestPlayer(maxDistance: number): Player?
	-- when there is no main target i find the closest player in FaceRange to look at
	local parts = self._parts :: RigParts
	local bestPlayer = nil :: Player?
	local bestDistance = maxDistance
	for _, player in Players:GetPlayers() do
		local root = getRoot(player)
		if root then
			local distance = (root.Position - parts.root.Position).Magnitude
			if distance < bestDistance then
				bestDistance = distance
				bestPlayer = player
			end
		end
	end
	return bestPlayer
end

--[[ CFrame.lookAt gets the rotation toward the player and Lerp smooths the turn
deltaTime is used in alpha so the turn speed stays similar at different frame rates ]]
function NpcController:_facePosition(position: Vector3, deltaTime: number, responsiveness: number)
	local parts = self._parts :: RigParts
	local target = Vector3.new(position.X, parts.root.Position.Y, position.Z)
	if (target - parts.root.Position).Magnitude < 0.05 then
		return
	end

	local desired = CFrame.lookAt(parts.root.Position, target)
	local alpha = 1 - math.exp(-responsiveness * deltaTime)
	parts.root.CFrame = parts.root.CFrame:Lerp(desired, alpha)
end

function NpcController:_focusTarget(): Player?
	-- follow target comes first then the recent speaker and then the closest player
	if self._followPlayer then
		return self._followPlayer
	end
	if self._focusPlayer and os.clock() < self._focusUntil then
		return self._focusPlayer
	end
	return self:_nearestPlayer(Config.FaceRange)
end

function NpcController:_stepFollow()
	-- follow mode keeps a gap and stops sending goals when the dummy is close enough
	local player = self._followPlayer
	if not player then
		return
	end

	local playerRoot = getRoot(player)
	if not playerRoot then
		self._followPlayer = nil
		self._state = "idle"
		self:_clearPath()
		return
	end

	local parts = self._parts :: RigParts
	local distance = flat(playerRoot.Position - parts.root.Position).Magnitude
	if distance <= Config.FollowStopDistance then
		-- clear the path here so the dummy does not keep shuffling near the player
		parts.humanoid:Move(Vector3.zero, false)
		self:_clearPath()
		return
	end

	if distance < Config.FollowResumeDistance and self._path.active then
		-- keep finishing the current path until the player passes the resume distance
		return
	end

	local away = flatUnit(parts.root.Position - playerRoot.Position) or flatUnit(-playerRoot.CFrame.LookVector) or Vector3.zAxis
	self._state = "following"
	parts.humanoid:MoveTo(playerRoot.Position + away * Config.FollowStopDistance)
end

function NpcController:_step(deltaTime: number)
	-- this one frame step handles all behavior that needs to keep updating
	if self._state == "following" then
		self:_stepFollow()
	end

	local targetPlayer = self:_focusTarget()
	local targetRoot = if targetPlayer then getRoot(targetPlayer) else nil
	if targetRoot then
		local responsiveness = if self._state == "idle" or self._state == "sitting" then Config.IdleTurnResponsiveness else Config.MovingTurnResponsiveness
		self:_facePosition(targetRoot.Position, deltaTime, responsiveness)
	end

	if self._state == "performing" and os.clock() > self._focusUntil then
		self._state = if self._followPlayer then "following" else "idle"
	end
end

function NpcController:CanSee(player: Player): boolean
	--[[ for a far player i raycast from the dummy head to the players root
the main script skips this at close range so a small nearby part does not block chat ]]
	local parts = self._parts :: RigParts
	local root = getRoot(player)
	if not root then
		return false
	end

	local direction = root.Position - parts.head.Position
	if direction.Magnitude > Config.LineOfSightRange then
		return false
	end

	local ignore = { parts.model }
	if player.Character then
		table.insert(ignore, player.Character)
	end
	local result = Workspace:Raycast(parts.head.Position, direction, makeRayParams(ignore))
	return result == nil or result.Instance:IsDescendantOf(root.Parent)
end

function NpcController:DistanceTo(player: Player): number?
	local parts = self._parts :: RigParts
	local root = getRoot(player)
	return if root then (root.Position - parts.root.Position).Magnitude else nil
end

function NpcController:Focus(player: Player, seconds: number?)
	-- save this player as the look target until the timer ends
	self._focusPlayer = player
	self._focusUntil = os.clock() + (seconds or 7)
end

function NpcController:Say(player: Player, text: string)
	-- use Roblox Chat on the dummy head so every player sees the same reply bubble
	local parts = self._parts :: RigParts
	self:Focus(player, 7)
	Chat:Chat(parts.head, text, Enum.ChatColor.White)
end

function NpcController:Follow(player: Player)
	-- this starts follow state and _stepFollow keeps updating it as the player moves
	local parts = self._parts :: RigParts
	self._followPlayer = player
	self._state = "following"
	parts.humanoid.Sit = false
	self:_clearPath()
	self:Focus(player, 10)
end

function NpcController:Stop()
	-- clear follow path and Humanoid movement so an old command cannot keep moving it
	local parts = self._parts :: RigParts
	self._followPlayer = nil
	self._state = "idle"
	self:_clearPath()
	parts.humanoid:Move(Vector3.zero, false)
	parts.humanoid:MoveTo(parts.root.Position)
end

function NpcController:ComeTo(player: Player)
	-- come here is one move instead of follow and the offset leaves a gap by the player
	local parts = self._parts :: RigParts
	local root = getRoot(player)
	if not root then
		return
	end

	local offset = flatUnit(parts.root.Position - root.Position) or flatUnit(-root.CFrame.LookVector) or Vector3.zAxis
	self._followPlayer = nil
	self:_moveTo(root.Position + offset * Config.FollowStopDistance, "moving")
	self:Focus(player, 9)
end

function NpcController:MoveRelative(player: Player, direction: string?, distance: number?)
	-- use the players CFrame so left right forward and back are from their view
	local parts = self._parts :: RigParts
	local playerRoot = getRoot(player)
	local basis = if playerRoot then playerRoot.CFrame else parts.root.CFrame
	local amount = TextUtil.clampNumber(distance, Config.MoveStepDistance, 3, Config.MaxDirectedMove)
	local vector = basis.LookVector

	if direction == "left" then
		vector = -basis.RightVector
	elseif direction == "right" then
		vector = basis.RightVector
	elseif direction == "back" then
		vector = -basis.LookVector
	end

	local unit = flatUnit(vector)
	if unit then
		self._followPlayer = nil
		self:_moveTo(parts.root.Position + unit * amount, "moving")
		self:Focus(player, 8)
	end
end

--[[ go there uses a server ray from the direction the player is facing
the client does not send a mouse position and if nothing is hit i use a point in front ]]
function NpcController:GoThere(player: Player)
	local parts = self._parts :: RigParts
	local root = getRoot(player)
	if not root then
		return
	end

	local head = getHead(player)
	local origin = if head then head.Position else root.Position + Vector3.yAxis * 3
	local ignore = { parts.model }
	if player.Character then
		table.insert(ignore, player.Character)
	end

	-- the ray points down a little so it can hit a floor or ramp instead of going over it
	local result = Workspace:Raycast(origin, root.CFrame.LookVector * Config.GoThereDistance - Vector3.yAxis * 12, makeRayParams(ignore))
	local goal = if result then result.Position else root.Position + root.CFrame.LookVector * 24
	self._followPlayer = nil
	self:_moveTo(goal, "moving")
	self:Focus(player, 8)
end

function NpcController:Jump(count: number)
	-- the count is limited to six so one message cannot start a very long jump task
	-- i also add upward speed so each jump is clear on the R15 rig
	local parts = self._parts :: RigParts
	count = math.clamp(math.floor(count), 1, 6)
	self._state = "performing"
	self._focusUntil = os.clock() + count * 0.28 + 0.4

	task.spawn(function()
		for _ = 1, count do
			-- clear Sit first because a sitting Humanoid may ignore the jump
			parts.humanoid.Sit = false
			parts.humanoid.Jump = true
			parts.root.AssemblyLinearVelocity += Vector3.new(0, 18, 0)
			pcall(function()
				parts.humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
			end)
			task.wait(0.28)
		end
	end)
end

function NpcController:Sit(shouldSit: boolean)
	-- sitting clears follow and path movement first because they should not run together
	local parts = self._parts :: RigParts
	self._followPlayer = nil
	self:_clearPath()
	parts.humanoid.Sit = shouldSit
	self._state = if shouldSit then "sitting" else "idle"
end

function NpcController:Spin(seconds: number)
	-- spin turns the root on the server for a limited time so everyone sees it
	local parts = self._parts :: RigParts
	seconds = TextUtil.clampNumber(seconds, 1.6, 0.5, 5)
	self._state = "performing"
	self._focusUntil = os.clock() + seconds

	task.spawn(function()
		local started = os.clock()
		while parts.root.Parent and os.clock() - started < seconds do
			local deltaTime = RunService.Heartbeat:Wait()
			parts.root.CFrame *= CFrame.Angles(0, math.rad(720) * deltaTime, 0)
		end
	end)
end

function NpcController:Orbit(player: Player, seconds: number)
	--[[ orbit makes points in a circle around the player and moves between them
it still uses _moveTo so normal pathfinding can handle things in the way ]]
	seconds = TextUtil.clampNumber(seconds, 4, 1.5, 8)
	self._followPlayer = nil
	self._state = "performing"
	self._focusUntil = os.clock() + seconds

	task.spawn(function()
		local started = os.clock()
		while os.clock() - started < seconds do
			local root = getRoot(player)
			if not root then
				break
			end
			-- sin and cos turn the timer into the next position around the circle
			local angle = (os.clock() - started) * math.pi * 1.35
			local offset = Vector3.new(math.cos(angle) * Config.FollowStopDistance, 0, math.sin(angle) * Config.FollowStopDistance)
			self:_moveTo(root.Position + offset, "performing")
			task.wait(0.22)
		end
	end)
end

function NpcController:SetSpeed(message: string, number: number?)
	-- speed accepts a number or words like faster slower and normal
	-- the final value is always kept inside the min and max from Config
	local parts = self._parts :: RigParts
	local speed = self._walkSpeed
	if number then
		speed = number
	elseif string.find(message, "slower", 1, true) then
		speed *= 0.65
	elseif string.find(message, "faster", 1, true) then
		speed *= 1.5
	elseif string.find(message, "normal", 1, true) then
		speed = Config.WalkSpeed
	end

	self._walkSpeed = TextUtil.clampNumber(speed, Config.WalkSpeed, Config.MinWalkSpeed, Config.MaxWalkSpeed)
	parts.humanoid.WalkSpeed = self._walkSpeed
end

function NpcController:Execute(player: Player, analysis)
	-- Brain already read the text so this only runs the action for its finished intent
	if analysis.intent == "follow" then
		self:Follow(player)
	elseif analysis.intent == "stop" then
		self:Stop()
	elseif analysis.intent == "come" then
		self:ComeTo(player)
	elseif analysis.intent == "go_there" then
		self:GoThere(player)
	elseif analysis.intent == "move" then
		self:MoveRelative(player, analysis.direction, analysis.number)
	elseif analysis.intent == "jump" then
		self:Jump(analysis.number or 1)
	elseif analysis.intent == "multi_jump" then
		self:Jump(analysis.number or 2)
	elseif analysis.intent == "sit" then
		self:Sit(true)
	elseif analysis.intent == "stand" then
		self:Sit(false)
	elseif analysis.intent == "spin" then
		self:Spin(analysis.number or 1.6)
	elseif analysis.intent == "orbit" then
		self:Orbit(player, analysis.number or 4)
	elseif analysis.intent == "speed" then
		self:SetSpeed(analysis.lower, analysis.number)
	end
end

return NpcController
