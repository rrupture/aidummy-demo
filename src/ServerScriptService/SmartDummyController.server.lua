--!strict

--[[
	SmartDummyController

	This script is the server entry point for the dummy. It does not contain the
	entire NPC implementation because that would make the file harder to maintain.
	Instead, it coordinates the modules under ServerScriptService/SmartDummy:

	- Config controls tuning values.
	- TextUtil handles low-level text parsing helpers.
	- SessionStore owns per-player memory and spam tracking.
	- Brain turns player chat into structured intent data and a reply.
	- NpcController owns Roblox actions: Humanoid movement, pathfinding, raycasts,
	  smooth CFrame facing, jumping, orbiting, and chat bubbles.

	The important design rule is server authority. Players can type chat, but the
	client never directly tells the NPC where to move. The server validates range,
	cooldown, and line of sight before any expensive or physical action runs.

	This is not a real LLM inside Roblox. It is a local procedural brain:
	command metadata, text parsing, recent memory, and Roblox action execution.
	The point is to make the dummy feel responsive without HTTP, hidden backend
	state, or unsafe client control.
]]

local Players = game:GetService("Players")

local Modules = script.Parent:WaitForChild("SmartDummy")
local Brain = require(Modules.Brain)
local CommandRegistry = require(Modules.CommandRegistry)
local Config = require(Modules.Config)
local NpcController = require(Modules.NpcController)
local SessionStore = require(Modules.SessionStore)
local TextUtil = require(Modules.TextUtil)

type Session = {
	memory: { any },
	lastMessageAt: number,
	lastNormalized: string,
	repeatCount: number,
	messageCount: number,
	commandCount: number,
	lastIntent: string,
	lastTopic: string?,
}

type GateResult = {
	ok: boolean,
	reason: string?,
	distance: number?,
}

type SpecialRequest = "none" | "help" | "status" | "memory" | "demo" | "about" | "internals"

local HELP_DELAY = 0.55
local GREETING_DELAY = 1.2
local FAR_VISIBILITY_DISTANCE = 28

local STATUS_PREFIX = "status:"
local MEMORY_PREFIX = "memory:"

local sessions = SessionStore.new()
local dummy = NpcController.new()

local brain = Brain.new(function(session)
	return sessions:RecentTopic(session)
end)

local function now(): number
	-- os.clock is monotonic enough for cooldowns and timed focus windows
	return os.clock()
end

local function playerStillValid(player: Player): boolean
	-- delayed replies can fire after a player leaves, so every delayed path checks this
	return player.Parent == Players
end

local function lower(text: string): string
	return string.lower(text)
end

local function startsWith(text: string, prefix: string): boolean
	return string.sub(text, 1, #prefix) == prefix
end

local function isSlashCommand(message: string): boolean
	return startsWith(message, "/")
end

local function trimToChatLimit(message: string): string
	-- protect chat bubbles and memory from massive pasted messages
	if #message <= Config.MaxMessageLength then
		return message
	end

	return string.sub(message, 1, Config.MaxMessageLength)
end

-- Normalization is done before every other check. Empty messages and Roblox slash
-- commands should not wake the dummy or modify session state.
local function normalizeMessage(rawMessage: string): string?
	local message = TextUtil.trim(rawMessage)
	if message == "" or isSlashCommand(message) then
		-- slash commands belong to Roblox chat, not the dummy brain
		return nil
	end

	return trimToChatLimit(message)
end

local function classifySpecialRequest(message: string): SpecialRequest
	-- utility requests skip the normal brain because they are exact system queries
	-- help/status/memory should never accidentally become movement commands
	local utility = CommandRegistry.MatchUtility(lower(message))
	if utility == "help" then
		return "help"
	elseif utility == "status" then
		return "status"
	elseif utility == "memory" then
		return "memory"
	elseif utility == "demo" then
		return "demo"
	elseif utility == "architecture" then
		return "about"
	elseif utility == "internals" then
		return "internals"
	end

	return "none"
end

local function formatDistance(distance: number?): string
	-- keep player-facing status readable, no decimals needed for studs here
	if not distance then
		return "unknown"
	end

	return tostring(math.floor(distance + 0.5)) .. " studs"
end

local function formatTopic(topic: string?): string
	return topic or "none"
end

local function formatIntent(intent: string): string
	if intent == "" then
		return "chat"
	end

	return intent
end

local function formatCount(value: number, singular: string, plural: string): string
	if value == 1 then
		return "1 " .. singular
	end

	return tostring(value) .. " " .. plural
end

local function responseDelay(message: string): number
	-- tiny fake thinking delay based on message length
	-- clamped so replies feel paced but never slow
	return math.clamp(#message * 0.009, Config.ThinkingSecondsMin, Config.ThinkingSecondsMax)
end

-- Sending several chat bubbles in sequence is wrapped in one helper
-- every multi-line response gets player removal checks and consistent timing
local function sendLines(player: Player, lines: { string }, delaySeconds: number?)
	task.spawn(function()
		for _, line in lines do
			if not playerStillValid(player) then
				return
			end

			dummy:Say(player, line)
			task.wait(delaySeconds or HELP_DELAY)
		end
	end)
end

local function sendHelp(player: Player)
	sendLines(player, CommandRegistry.BuildHelpLines(), HELP_DELAY)
end

local function sendDemo(player: Player)
	sendLines(player, CommandRegistry.BuildDemoLines(), HELP_DELAY)
end

local function sendAbout(player: Player)
	sendLines(player, CommandRegistry.BuildArchitectureLines(), HELP_DELAY)
end

local function sendInternals(player: Player)
	sendLines(player, CommandRegistry.BuildInternalsLines(), HELP_DELAY)
end

local function buildStatusLines(player: Player, session: Session): { string }
	-- status is generated from live session + NPC distance
	-- useful for showing memory and command counters are actual runtime state
	local distance = dummy:DistanceTo(player)
	local messageCount = formatCount(session.messageCount, "message", "messages")
	local commandCount = formatCount(session.commandCount, "command", "commands")
	local lastIntent = formatIntent(session.lastIntent)
	local topic = formatTopic(session.lastTopic)

	return {
		STATUS_PREFIX .. " " .. messageCount .. ", " .. commandCount .. ", last intent " .. lastIntent .. ".",
		"distance " .. formatDistance(distance) .. ", recent topic " .. topic .. ".",
	}
end

local function sendStatus(player: Player, session: Session)
	sendLines(player, buildStatusLines(player, session), HELP_DELAY)
end

local function memoryLineFromEntry(index: number, entry: any): string
	-- memory output is clipped because chat bubbles are small
	-- the full text is still stored in the session ring buffer
	local role = tostring(entry.role or "unknown")
	local intent = tostring(entry.intent or "chat")
	local topic = entry.topic and (" topic=" .. tostring(entry.topic)) or ""
	local text = tostring(entry.text or "")

	if #text > 58 then
		text = string.sub(text, 1, 58) .. "..."
	end

	return tostring(index) .. ". " .. role .. " [" .. intent .. topic .. "] " .. text
end

local function buildMemoryLines(session: Session): { string }
	-- only show the most recent entries
	-- the dummy is meant to feel contextual, not dump a wall of chat
	if #session.memory == 0 then
		return { MEMORY_PREFIX .. " nothing stored yet." }
	end

	local lines = {
		MEMORY_PREFIX .. " last " .. tostring(math.min(#session.memory, 4)) .. " entries.",
	}

	local startIndex = math.max(1, #session.memory - 3)
	for index = startIndex, #session.memory do
		table.insert(lines, memoryLineFromEntry(index, session.memory[index]))
	end

	return lines
end

local function sendMemory(player: Player, session: Session)
	sendLines(player, buildMemoryLines(session), HELP_DELAY)
end

-- Cooldown is checked before distance or line of sight
-- it is the cheapest gate and blocks spam before any world queries run
local function passesCooldown(session: Session): boolean
	return now() - session.lastMessageAt >= Config.ReplyCooldown
end

local function passesRange(player: Player): (boolean, number?)
	-- distance is returned with the bool so status/debug can reuse it
	-- without asking NpcController for the same value again
	local distance = dummy:DistanceTo(player)
	if not distance then
		return false, nil
	end

	return distance <= Config.ChatRange, distance
end

-- Line of sight is only required for farther players
-- nearby players can still interact naturally if a tiny part blocks the raycast
local function passesVisibility(player: Player, distance: number): boolean
	if distance <= FAR_VISIBILITY_DISTANCE then
		return true
	end

	return dummy:CanSee(player)
end

local function authorizePlayer(player: Player, session: Session): GateResult
	-- this is the server authority gate
	-- if it returns false, the message does not affect memory, chat, or movement
	if not passesCooldown(session) then
		return {
			ok = false,
			reason = "cooldown",
		}
	end

	local inRange, distance = passesRange(player)
	if not inRange then
		return {
			ok = false,
			reason = "range",
			distance = distance,
		}
	end

	if distance and not passesVisibility(player, distance) then
		-- line of sight check is last because it raycasts
		-- cooldown and range are cheaper and can reject most bad messages first
		return {
			ok = false,
			reason = "visibility",
			distance = distance,
		}
	end

	session.lastMessageAt = now()
	return {
		ok = true,
		distance = distance,
	}
end

local function handleRepeatedMessage(player: Player, session: Session, message: string): boolean
	-- repeated spam is handled before analysis so it does not poison recent topic memory
	if not sessions:IsRepeated(session, message) then
		return false
	end

	dummy:Say(player, "you already said that. give me a new command.")
	return true
end

local function handleSpecialRequest(player: Player, session: Session, request: SpecialRequest): boolean
	-- utility commands answer immediately and do not run physical NPC actions
	if request == "none" then
		return false
	end

	if request == "help" then
		sendHelp(player)
	elseif request == "status" then
		sendStatus(player, session)
	elseif request == "memory" then
		sendMemory(player, session)
	elseif request == "demo" then
		sendDemo(player)
	elseif request == "about" then
		sendAbout(player)
	elseif request == "internals" then
		sendInternals(player)
	end

	return true
end

local function recordUserMessage(session: Session, message: string, analysis)
	-- user message is stored after analysis so memory includes intent/topic metadata
	sessions:UpdateStats(session, analysis.intent, analysis.topic)
	sessions:Push(session, "user", message, analysis.intent, analysis.topic)
end

local function recordDummyReply(session: Session, reply: string, analysis)
	-- dummy replies are stored too, which gives the memory command a full short context
	sessions:Push(session, "dummy", reply, "chat", analysis.topic)
end

-- NPC actions are isolated from reply generation
-- if an action fails because a character respawned or target disappeared,
-- chat memory still remains valid and the server does not break the chat loop
local function executeAnalysis(player: Player, analysis)
	local ok = pcall(function()
		dummy:Execute(player, analysis)
	end)

	if not ok and playerStillValid(player) then
		dummy:Say(player, "that command failed during movement. try again when your character is stable.")
	end
end

local function scheduleReply(player: Player, session: Session, reply: string, analysis)
	-- reply and action are delayed together so the dummy feels like it processed chat
	-- player validity is checked again because task.delay can outlive the player
	task.delay(responseDelay(analysis.raw), function()
		if not playerStillValid(player) then
			return
		end

		-- reply first, action second
		-- the player hears confirmation before the dummy starts walking/jumping
		dummy:Say(player, reply)
		executeAnalysis(player, analysis)
		recordDummyReply(session, reply, analysis)
	end)
end

local function analyzeAndRespond(player: Player, session: Session, message: string)
	-- one analysis pass creates both the reply and the action command
	-- no second parser later in movement code
	local analysis = brain:Analyze(message, session)
	local reply = brain:Reply(player, analysis)

	recordUserMessage(session, message, analysis)
	scheduleReply(player, session, reply, analysis)
end

-- The message pipeline is intentionally ordered:
-- 1. normalize cheap input
-- 2. validate server authority gates
-- 3. handle built-in utility requests
-- 4. analyze the message once
-- 5. reply and execute the resulting action
local function handleMessage(player: Player, rawMessage: string)
	local message = normalizeMessage(rawMessage)
	if not message then
		return
	end

	local session = sessions:Get(player)
	local gate = authorizePlayer(player, session)
	if not gate.ok then
		return
	end

	if handleRepeatedMessage(player, session, message) then
		return
	end

	local specialRequest = classifySpecialRequest(message)
	if handleSpecialRequest(player, session, specialRequest) then
		return
	end

	analyzeAndRespond(player, session, message)
end

local function sendGreeting(player: Player)
	-- greeting is delayed so character replication has time to finish
	task.delay(GREETING_DELAY, function()
		if playerStillValid(player) and dummy:DistanceTo(player) then
			dummy:Say(player, "yo " .. player.DisplayName .. ", say help if you want the command list.")
		end
	end)
end

local function connectChat(player: Player)
	-- using Player.Chatted keeps the demo simple and publishable
	-- the server still owns every response and action
	player.Chatted:Connect(function(message)
		-- all chat enters the same pipeline, no side routes
		handleMessage(player, message)
	end)
end

local function bindPlayer(player: Player)
	-- session is created before chat binding so the first message has state ready
	sessions:Get(player)
	connectChat(player)
	sendGreeting(player)
end

local function bindExistingPlayers()
	for _, player in Players:GetPlayers() do
		bindPlayer(player)
	end
end

local function removePlayer(player: Player)
	-- per-player memory is released when they leave
	sessions:Forget(player)
end

bindExistingPlayers()
Players.PlayerAdded:Connect(bindPlayer)
Players.PlayerRemoving:Connect(removePlayer)
