--!strict

local Chat = game:GetService("Chat")
local PathfindingService = game:GetService("PathfindingService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Config = require(script.Parent.Config)
local TextUtil = require(script.Parent.TextUtil)

export type Command = {
	intent: string,
	direction: string?,
	number: number?,
}

type CharacterParts = {
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

local DummyController = {}
DummyController.__index = DummyController

-- movement decisions use flat distance most of the time. y height should not
-- make the dummy think the player is farther away on a normal baseplate.
local function flat(vector: Vector3): Vector3
	return Vector3.new(vector.X, 0, vector.Z)
end

local function flatUnit(vector: Vector3): Vector3?
	local value = flat(vector)
	if value.Magnitude < 0.001 then
		return nil
	end
	return value.Unit
end

-- root/head helpers keep every player character check nil-safe. players can
-- respawn while the dummy is thinking, so direct indexing would be sloppy.
local function getRoot(player: Player): BasePart?
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
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignore
	params.IgnoreWater = true
	return params
end

local function createPart(name: string, size: Vector3, color: Color3, cframe: CFrame): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Color = color
	part.Material = Enum.Material.SmoothPlastic
	part.CFrame = cframe
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.CanCollide = true
	part.Anchored = false
	return part
end

local function weld(part0: BasePart, part1: BasePart, c0: CFrame)
	local joint = Instance.new("Motor6D")
	joint.Name = part1.Name .. "Joint"
	joint.Part0 = part0
	joint.Part1 = part1
	joint.C0 = c0
	joint.Parent = part0
end

-- fallback rig only exists so the demo still works if the place has no dummy
-- model already placed. normal Roblox humanoid generation is tried first.
local function createRuntimeDummy(): Model
	local description = Instance.new("HumanoidDescription")
	local ok, generated = pcall(function()
		return Players:CreateHumanoidModelFromDescription(description, Enum.HumanoidRigType.R15)
	end)

	if ok and generated then
		generated.Name = Config.DummyName
		generated:PivotTo(Config.SpawnCFrame)
		local humanoid = generated:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid.DisplayName = Config.DisplayName
			humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
		end
		generated.Parent = Workspace
		return generated
	end

	local model = Instance.new("Model")
	model.Name = Config.DummyName

	local parts = {} :: { [string]: BasePart }
	local specs = {
		{ "HumanoidRootPart", Vector3.new(2, 2, 1), Color3.fromRGB(35, 35, 42), CFrame.identity, 1, false },
		{ "Torso", Vector3.new(2, 2, 1), Color3.fromRGB(55, 83, 142), CFrame.identity, 0, false },
		{ "Head", Vector3.new(1.35, 1.35, 1.35), Color3.fromRGB(248, 217, 164), CFrame.new(0, 1.75, 0), 0, true },
		{ "Left Arm", Vector3.new(0.65, 2, 0.65), Color3.fromRGB(248, 217, 164), CFrame.new(-1.35, 0, 0), 0, false },
		{ "Right Arm", Vector3.new(0.65, 2, 0.65), Color3.fromRGB(248, 217, 164), CFrame.new(1.35, 0, 0), 0, false },
		{ "Left Leg", Vector3.new(0.75, 2, 0.75), Color3.fromRGB(38, 38, 46), CFrame.new(-0.5, -2, 0), 0, false },
		{ "Right Leg", Vector3.new(0.75, 2, 0.75), Color3.fromRGB(38, 38, 46), CFrame.new(0.5, -2, 0), 0, false },
	}

	for _, spec in specs do
		local part = createPart(spec[1] :: string, spec[2] :: Vector3, spec[3] :: Color3, Config.SpawnCFrame * (spec[4] :: CFrame))
		part.Transparency = spec[5] :: number
		if spec[6] then
			part.Shape = Enum.PartType.Ball
		end
		if part.Name == "HumanoidRootPart" then
			part.CanCollide = false
			part.Massless = true
		end
		part.Parent = model
		parts[part.Name] = part
	end

	local humanoid = Instance.new("Humanoid")
	humanoid.Name = "Humanoid"
	humanoid.DisplayName = Config.DisplayName
	humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
	humanoid.Parent = model

	weld(parts.HumanoidRootPart, parts.Torso, CFrame.identity)
	for _, spec in specs do
		local name = spec[1] :: string
		if name ~= "HumanoidRootPart" and name ~= "Torso" then
			weld(parts.Torso, parts[name], spec[4] :: CFrame)
		end
	end

	model.PrimaryPart = parts.HumanoidRootPart
	model.Parent = Workspace
	return model
end

-- resolves the one npc the server controls. it also forces server ownership so
-- movement stays smooth and not player-client dependent.
local function resolveDummy(): CharacterParts
	local model = Workspace:FindFirstChild(Config.DummyName)
	if not model or not model:IsA("Model") then
		model = createRuntimeDummy()
	end

	local root = model:FindFirstChild("HumanoidRootPart")
	local head = model:FindFirstChild("Head")
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if not root or not root:IsA("BasePart") or not head or not head:IsA("BasePart") or not humanoid then
		error("AIDummy must be a Model with HumanoidRootPart, Head, and Humanoid")
	end

	humanoid.AutoRotate = false
	humanoid.WalkSpeed = Config.WalkSpeed
	pcall(function()
		humanoid.UseJumpPower = true
		humanoid.JumpPower = Config.JumpPower
	end)

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

	return {
		model = model,
		root = root,
		head = head,
		humanoid = humanoid,
	}
end

function DummyController.new()
	local self = setmetatable({
		_parts = resolveDummy(),
		_state = "idle" :: DummyState,
		_focusPlayer = nil :: Player?,
		_focusUntil = 0,
		_followPlayer = nil :: Player?,
		_path = {
			active = false,
			goal = nil,
			waypoints = {},
			index = 1,
			nextComputeAt = 0,
		} :: PathState,
		_walkSpeed = Config.WalkSpeed,
		_connections = {} :: { RBXScriptConnection },
	}, DummyController)

	self:_configureHumanoid()
	self:_connect()
	return self
end

function DummyController:_configureHumanoid()
	local humanoid = self._parts.humanoid
	humanoid.AutoRotate = false
	humanoid.WalkSpeed = self._walkSpeed
	humanoid.BreakJointsOnDeath = false
	humanoid.MaxHealth = 1_000_000
	humanoid.Health = humanoid.MaxHealth
end

-- one Heartbeat loop handles follow and facing. no per-command loops except
-- short actions like spin/jump, so idle cost stays tiny.
function DummyController:_connect()
	table.insert(self._connections, self._parts.humanoid.HealthChanged:Connect(function()
		local humanoid = self._parts.humanoid
		if humanoid.Health < humanoid.MaxHealth then
			humanoid.Health = humanoid.MaxHealth
		end
	end))

	table.insert(self._connections, self._parts.humanoid.MoveToFinished:Connect(function(reached)
		if reached and self._path.active then
			self._path.index += 1
			self:_advancePath()
		end
	end))

	table.insert(self._connections, RunService.Heartbeat:Connect(function(deltaTime)
		self:_step(deltaTime)
	end))
end

function DummyController:_clearPath()
	self._path.active = false
	self._path.goal = nil
	table.clear(self._path.waypoints)
	self._path.index = 1
end

-- pathfinding is throttled by goal and time. recomputing every frame would be
-- expensive and would make the npc stutter.
function DummyController:_computePath(goal: Vector3): boolean
	local now = os.clock()
	local path = self._path
	if path.goal and (path.goal - goal).Magnitude < Config.PathGoalEpsilon and now < path.nextComputeAt then
		return true
	end

	path.nextComputeAt = now + Config.PathRefreshSeconds
	path.goal = goal

	local computed = PathfindingService:CreatePath({
		AgentRadius = 2,
		AgentHeight = 5,
		AgentCanJump = true,
		WaypointSpacing = 4,
	})

	local ok = pcall(function()
		computed:ComputeAsync(self._parts.root.Position, goal)
	end)
	if not ok or computed.Status ~= Enum.PathStatus.Success then
		table.clear(path.waypoints)
		path.index = 1
		return false
	end

	path.waypoints = computed:GetWaypoints()
	path.index = 1
	path.active = true
	return true
end

function DummyController:_advancePath()
	local waypoint = self._path.waypoints[self._path.index]
	if not waypoint then
		self:_clearPath()
		if self._state == "moving" then
			self._state = "idle"
		end
		return
	end

	if waypoint.Action == Enum.PathWaypointAction.Jump then
		self._parts.humanoid.Jump = true
	end
	self._parts.humanoid:MoveTo(waypoint.Position)
end

-- MoveTo uses pathfinding when it can, and falls back to direct MoveTo when
-- Roblox cannot build a path. that keeps commands responsive.
function DummyController:_moveTo(goal: Vector3, state: DummyState?)
	local root = self._parts.root
	local groundedGoal = Vector3.new(goal.X, goal.Y, goal.Z)
	if (flat(groundedGoal - root.Position)).Magnitude < 1 then
		return
	end

	self._state = state or "moving"
	if self:_computePath(groundedGoal) then
		self:_advancePath()
	else
		self._parts.humanoid:MoveTo(groundedGoal)
	end
end

function DummyController:_nearestPlayer(maxDistance: number): Player?
	local rootPosition = self._parts.root.Position
	local bestPlayer = nil :: Player?
	local bestDistance = maxDistance

	for _, player in Players:GetPlayers() do
		local root = getRoot(player)
		if root then
			local distance = (root.Position - rootPosition).Magnitude
			if distance < bestDistance then
				bestDistance = distance
				bestPlayer = player
			end
		end
	end

	return bestPlayer
end

-- smooth facing is separate from walking. the dummy can look at the player
-- while idle, following, or doing a small action.
function DummyController:_facePosition(position: Vector3, deltaTime: number, responsiveness: number)
	local root = self._parts.root
	local target = Vector3.new(position.X, root.Position.Y, position.Z)
	if (target - root.Position).Magnitude < 0.05 then
		return
	end

	local desired = CFrame.lookAt(root.Position, target)
	local alpha = 1 - math.exp(-responsiveness * deltaTime)
	root.CFrame = root.CFrame:Lerp(desired, alpha)
end

function DummyController:_focusTarget(): Player?
	if self._followPlayer then
		return self._followPlayer
	end
	if self._focusPlayer and os.clock() < self._focusUntil then
		return self._focusPlayer
	end
	return self:_nearestPlayer(Config.FaceRange)
end

function DummyController:_stepFollow()
	local player = self._followPlayer
	if not player then
		return
	end

	local playerRoot = getRoot(player)
	if not playerRoot then
		self._followPlayer = nil
		self._state = "idle"
		return
	end

	local root = self._parts.root
	local distance = flat(playerRoot.Position - root.Position).Magnitude
	if distance <= Config.FollowStopDistance then
		self._parts.humanoid:Move(Vector3.zero, false)
		self:_clearPath()
		return
	end
	if distance < Config.FollowResumeDistance and self._path.active then
		return
	end

	local away = flatUnit(root.Position - playerRoot.Position) or flatUnit(-playerRoot.CFrame.LookVector) or Vector3.zAxis
	local goal = playerRoot.Position + away * Config.FollowStopDistance
	self._state = "following"
	self._parts.humanoid:MoveTo(goal)
end

-- per-frame work stays small: follow if needed, face a target, and clean up
-- temporary action state when the timer ends.
function DummyController:_step(deltaTime: number)
	if self._state == "following" then
		self:_stepFollow()
	end

	local targetPlayer = self:_focusTarget()
	if not targetPlayer then
		return
	end

	local targetRoot = getRoot(targetPlayer)
	if targetRoot then
		local responsiveness = if self._state == "idle" or self._state == "sitting" then Config.IdleTurnResponsiveness else Config.MovingTurnResponsiveness
		self:_facePosition(targetRoot.Position, deltaTime, responsiveness)
	end

	if self._state == "performing" and os.clock() > self._focusUntil then
		self._state = if self._followPlayer then "following" else "idle"
	end
end

-- line of sight prevents far players behind walls from talking to the dummy.
-- close players are still allowed by the main controller for better gameplay.
function DummyController:canSee(player: Player): boolean
	local root = getRoot(player)
	if not root then
		return false
	end
	local direction = root.Position - self._parts.head.Position
	if direction.Magnitude > Config.LineOfSightRange then
		return false
	end
	local result = Workspace:Raycast(self._parts.head.Position, direction, makeRayParams({ self._parts.model }))
	return result == nil or result.Instance:IsDescendantOf(root.Parent)
end

function DummyController:distanceTo(player: Player): number?
	local root = getRoot(player)
	if not root then
		return nil
	end
	return (root.Position - self._parts.root.Position).Magnitude
end

function DummyController:focus(player: Player)
	self._focusPlayer = player
	self._focusUntil = os.clock() + 7
end

function DummyController:say(player: Player, text: string)
	self:focus(player)
	Chat:Chat(self._parts.head, text, Enum.ChatColor.White)
end

-- follow mode keeps about ten studs of space, so the npc acts like a pet and
-- does not stand inside the player.
function DummyController:follow(player: Player)
	self._followPlayer = player
	self._state = "following"
	self._parts.humanoid.Sit = false
	self:_clearPath()
	self:focus(player)
end

function DummyController:stop()
	self._followPlayer = nil
	self._state = "idle"
	self:_clearPath()
	self._parts.humanoid:Move(Vector3.zero, false)
	self._parts.humanoid:MoveTo(self._parts.root.Position)
end

function DummyController:comeTo(player: Player)
	local root = getRoot(player)
	if not root then
		return
	end
	local offset = flatUnit(self._parts.root.Position - root.Position) or flatUnit(-root.CFrame.LookVector) or Vector3.zAxis
	self._followPlayer = nil
	self:_moveTo(root.Position + offset * Config.FollowStopDistance, "moving")
	self:focus(player)
end

-- relative movement uses the player's facing direction. "move right" means
-- right from the player view, not world +X.
function DummyController:moveRelative(player: Player, direction: string?, distance: number?)
	local root = self._parts.root
	local playerRoot = getRoot(player)
	local basis = if playerRoot then playerRoot.CFrame else root.CFrame
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
		self:_moveTo(root.Position + unit * amount, "moving")
		self:focus(player)
	end
end

-- go there raycasts from the player's view. that lets normal chat point the
-- dummy at a real spot without any client remote.
function DummyController:goThere(player: Player)
	local root = getRoot(player)
	if not root then
		return
	end

	local head = getHead(player)
	local origin = if head then head.Position else root.Position + Vector3.yAxis * 3
	local result = Workspace:Raycast(origin, root.CFrame.LookVector * Config.GoThereDistance - Vector3.yAxis * 10, makeRayParams({ self._parts.model, player.Character :: any }))
	local goal = if result then result.Position else root.Position + root.CFrame.LookVector * 24

	self._followPlayer = nil
	self:_moveTo(goal, "moving")
	self:focus(player)
end

function DummyController:jump(count: number)
	count = math.clamp(math.floor(count), 1, 6)
	self._state = "performing"
	self._focusUntil = os.clock() + count * 0.28 + 0.4
	task.spawn(function()
		for _ = 1, count do
			self._parts.humanoid.Sit = false
			self._parts.humanoid.Jump = true
			self._parts.root.AssemblyLinearVelocity += Vector3.new(0, 18, 0)
			pcall(function()
				self._parts.humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
			end)
			task.wait(0.28)
		end
	end)
end

function DummyController:sit(shouldSit: boolean)
	self._followPlayer = nil
	self:_clearPath()
	self._parts.humanoid.Sit = shouldSit
	self._state = if shouldSit then "sitting" else "idle"
end

function DummyController:spin(seconds: number)
	seconds = TextUtil.clampNumber(seconds, 1.6, 0.5, 5)
	self._state = "performing"
	self._focusUntil = os.clock() + seconds
	task.spawn(function()
		local started = os.clock()
		while self._parts.root.Parent and os.clock() - started < seconds do
			local deltaTime = RunService.Heartbeat:Wait()
			self._parts.root.CFrame *= CFrame.Angles(0, math.rad(720) * deltaTime, 0)
		end
	end)
end

function DummyController:orbit(player: Player, seconds: number)
	seconds = TextUtil.clampNumber(seconds, 4, 1.5, 8)
	self._followPlayer = nil
	self._state = "performing"
	self._focusUntil = os.clock() + seconds

	task.spawn(function()
		local started = os.clock()
		while self._parts.root.Parent and os.clock() - started < seconds do
			local currentRoot = getRoot(player)
			if not currentRoot then
				break
			end
			local angle = (os.clock() - started) * math.pi * 1.35
			local offset = Vector3.new(math.cos(angle) * Config.FollowStopDistance, 0, math.sin(angle) * Config.FollowStopDistance)
			self:_moveTo(currentRoot.Position + offset, "performing")
			task.wait(0.22)
		end
	end)
end

function DummyController:setSpeed(message: string, number: number?)
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
	self._parts.humanoid.WalkSpeed = self._walkSpeed
end

-- execute is intentionally boring: it maps clean intents to actions. all smart
-- text decisions already happened in LocalBrain.
function DummyController:execute(player: Player, command: Command, originalMessage: string)
	if command.intent == "follow" then
		self:follow(player)
	elseif command.intent == "stop" then
		self:stop()
	elseif command.intent == "come" then
		self:comeTo(player)
	elseif command.intent == "go_there" then
		self:goThere(player)
	elseif command.intent == "move" then
		self:moveRelative(player, command.direction, command.number)
	elseif command.intent == "jump" then
		self:jump(1)
	elseif command.intent == "multi_jump" then
		self:jump(command.number or 2)
	elseif command.intent == "sit" then
		self:sit(true)
	elseif command.intent == "stand" then
		self:sit(false)
	elseif command.intent == "spin" then
		self:spin(command.number or 1.6)
	elseif command.intent == "orbit" then
		self:orbit(player, command.number or 4)
	elseif command.intent == "speed" then
		self:setSpeed(originalMessage, command.number)
	end
end

function DummyController:destroy()
	for _, connection in self._connections do
		connection:Disconnect()
	end
	table.clear(self._connections)
end

return DummyController
