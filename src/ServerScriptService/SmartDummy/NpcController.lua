-- Connected Discord-GitHub
--!strict

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

-- movement uses flattened vectors a lot because NPC steering should not tilt
-- upward/downward when the player is on a slope or jumping
local function flat(vector: Vector3): Vector3
	return Vector3.new(vector.X, 0, vector.Z)
end

local function flatUnit(vector: Vector3): Vector3?
	-- nil instead of Vector3.zero.Unit, because zero-length unit vectors throw bad math
	local value = flat(vector)
	if value.Magnitude < 0.001 then
		return nil
	end
	return value.Unit
end

local function getRoot(player: Player): BasePart?
	-- characters can respawn mid-command, so every public action resolves parts fresh
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
	-- raycasts ignore the dummy and target character so line checks hit real blockers
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignore
	params.IgnoreWater = true
	return params
end

function NpcController.new()
	-- this object owns one dummy rig and one runtime loop
	-- no per-player controllers, because the NPC is shared server state
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
	-- if the place owner did not drop in a custom AIDummy model, make a clean R15 one
	-- this keeps the demo publishable without forcing extra manual setup
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

-- Network ownership is forced to the server
-- NPC movement should not depend on whichever client happens to be closest
-- this matters for follow/path actions because client-owned physics can jitter
-- or desync when several players are near the dummy
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
	-- AutoRotate is disabled because this controller handles facing manually
	-- with CFrame.lookAt, otherwise Roblox humanoid rotation fights our smoothing
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

-- One Heartbeat loop owns persistent behavior: following, facing, and cleanup
-- commands only change state, this loop is what actually advances that state
-- cheaper and cleaner than spawning many loops per command
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
	-- path state is reused instead of replacing the table every time
	-- less garbage, and no old waypoint list accidentally survives
	self._path.active = false
	self._path.goal = nil
	table.clear(self._path.waypoints)
	self._path.index = 1
end

-- Pathfinding is throttled by target movement and time
-- recomputing every Heartbeat is expensive and usually worse because the
-- humanoid keeps getting a new route before it can finish the current one
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

	-- ComputeAsync can fail if the navmesh is not ready or the target is invalid
	-- pcall keeps one bad path request from killing the whole NPC controller
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
	-- MoveToFinished advances this index
	-- jump waypoints are handled here so pathfinding can climb simple obstacles
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
	-- all direct movement funnels through here
	-- pathfinding is preferred, but MoveTo fallback keeps simple flat moves responsive
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
	-- idle facing chooses the nearest player inside a capped radius
	-- small loop over Players is fine here because it runs once per Heartbeat
	-- and only compares root positions
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

-- CFrame.lookAt gives the target rotation
-- exponential Lerp makes the rotation smooth and frame-rate independent
-- so 30 fps and 144 fps clients see the same style of turn
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
	-- follow target wins, then recent speaker, then nearest player
	-- this makes the dummy feel aware without doing any client-side camera tricks
	if self._followPlayer then
		return self._followPlayer
	end
	if self._focusPlayer and os.clock() < self._focusUntil then
		return self._focusPlayer
	end
	return self:_nearestPlayer(Config.FaceRange)
end

function NpcController:_stepFollow()
	-- follow mode keeps a gap instead of walking into the player
	-- when close enough, it stops issuing MoveTo calls so it does not jitter
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
		-- already close enough, so stop pushing new goals
		-- this removes the common follow jitter where NPCs shuffle forever
		parts.humanoid:Move(Vector3.zero, false)
		self:_clearPath()
		return
	end

	if distance < Config.FollowResumeDistance and self._path.active then
		-- wait for current path to finish unless the player moved far enough away
		return
	end

	local away = flatUnit(parts.root.Position - playerRoot.Position) or flatUnit(-playerRoot.CFrame.LookVector) or Vector3.zAxis
	self._state = "following"
	parts.humanoid:MoveTo(playerRoot.Position + away * Config.FollowStopDistance)
end

function NpcController:_step(deltaTime: number)
	-- one frame step for all persistent behavior
	-- no command code should connect its own endless Heartbeat loop
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
	-- server-side line of sight blocks far-away chat through walls
	-- close players are handled by SmartDummyController so small props do not feel annoying
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
	-- focus is just a timed look target
	-- it gives replies physical direction without permanently locking onto someone
	self._focusPlayer = player
	self._focusUntil = os.clock() + (seconds or 7)
end

function NpcController:Say(player: Player, text: string)
	-- chat bubbles come from the dummy head, not a custom client UI
	-- simple, replicated, and easy to read in normal play
	local parts = self._parts :: RigParts
	self:Focus(player, 7)
	Chat:Chat(parts.head, text, Enum.ChatColor.White)
end

function NpcController:Follow(player: Player)
	-- follow starts state only
	-- actual distance control happens in _stepFollow so it updates as player moves
	local parts = self._parts :: RigParts
	self._followPlayer = player
	self._state = "following"
	parts.humanoid.Sit = false
	self:_clearPath()
	self:Focus(player, 10)
end

function NpcController:Stop()
	-- clearing follow and path is important
	-- otherwise a previous MoveTo/path callback could keep pulling the dummy around
	local parts = self._parts :: RigParts
	self._followPlayer = nil
	self._state = "idle"
	self:_clearPath()
	parts.humanoid:Move(Vector3.zero, false)
	parts.humanoid:MoveTo(parts.root.Position)
end

function NpcController:ComeTo(player: Player)
	-- "come here" is a one-shot move, different from follow
	-- the target point is offset from the player so the dummy stops like a pet would
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
	-- relative movement uses the player's facing direction when possible
	-- so "move right" means the player's right, not world +X
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

-- "go there" raycasts from the player's facing direction
-- that gives target selection without trusting a client RemoteEvent or mouse hit
-- if the ray hits nothing, the fallback point is still in front of the player
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

	-- forward plus a downward bias makes "go there" hit floors/ramps more often
	-- instead of firing a perfectly flat ray over the target surface
	local result = Workspace:Raycast(origin, root.CFrame.LookVector * Config.GoThereDistance - Vector3.yAxis * 12, makeRayParams(ignore))
	local goal = if result then result.Position else root.Position + root.CFrame.LookVector * 24
	self._followPlayer = nil
	self:_moveTo(goal, "moving")
	self:Focus(player, 8)
end

function NpcController:Jump(count: number)
	-- jump count is clamped so "jump 999" cannot create a long task spam chain
	-- the small velocity boost makes the jump visibly clear even on default rigs
	local parts = self._parts :: RigParts
	count = math.clamp(math.floor(count), 1, 6)
	self._state = "performing"
	self._focusUntil = os.clock() + count * 0.28 + 0.4

	task.spawn(function()
		for _ = 1, count do
			-- Sit has to be cleared before jumping or the humanoid may ignore the impulse
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
	-- sitting cancels movement because Humanoid.Sit and path movement do not mix cleanly
	local parts = self._parts :: RigParts
	self._followPlayer = nil
	self:_clearPath()
	parts.humanoid.Sit = shouldSit
	self._state = if shouldSit then "sitting" else "idle"
end

function NpcController:Spin(seconds: number)
	-- timed cosmetic action
	-- CFrame rotation is done server side so every player sees the same spin
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
	-- orbit is not physics based
	-- it samples positions around the player and sends short MoveTo/path goals
	-- this stays simple and avoids constraints or body movers fighting the humanoid
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
			-- circular offset is sampled over time
			-- pathing still handles obstacles if the orbit point is not directly reachable
			local angle = (os.clock() - started) * math.pi * 1.35
			local offset = Vector3.new(math.cos(angle) * Config.FollowStopDistance, 0, math.sin(angle) * Config.FollowStopDistance)
			self:_moveTo(root.Position + offset, "performing")
			task.wait(0.22)
		end
	end)
end

function NpcController:SetSpeed(message: string, number: number?)
	-- speed accepts direct numbers and soft language like faster/slower/normal
	-- final value is clamped so the dummy cannot be made unusably slow or insane fast
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
	-- dispatcher from parsed intent to Roblox action
	-- Brain decides what the player meant, this module decides what the dummy does
	-- no raw phrase matching belongs here
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
