-- Connected Discord-GitHub
--!strict

--[[
	this is the main server script for the dummy

	when a player chats the message goes through a few steps
	first it gets trimmed and the server checks cooldown range and line of sight
	then Brain reads it once and returns the intent and reply
	NpcController gets that intent and handles the actual Roblox movement

	Config has settings TextUtil checks words CommandRegistry has all commands
	and SessionStore keeps the recent messages for each player
	i kept these jobs separate so changing chat does not also mean changing movement code

	the client only sends normal chat and the server does every check and action
	this is a rule based system and does not use an ai api
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
	-- i use the same clock for cooldowns and all the small action timers
	return os.clock()
end

local function playerStillValid(player: Player): boolean
	-- delayed replies can run after someone leaves so i check they are still in Players
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
	-- cut very long messages before they can fill a chat bubble or memory entry
	if #message <= Config.MaxMessageLength then
		return message
	end

	return string.sub(message, 1, Config.MaxMessageLength)
end

--[[ this is the first step for every message
empty text and Roblox slash commands are ignored before a session or world check is used ]]
local function normalizeMessage(rawMessage: string): string?
	local message = TextUtil.trim(rawMessage)
	if message == "" or isSlashCommand(message) then
		-- slash commands belong to normal Roblox chat and should not wake the dummy
		return nil
	end

	return trimToChatLimit(message)
end

local function classifySpecialRequest(message: string): SpecialRequest
	-- help status memory and other info requests skip Brain and never move the dummy
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
	-- studs are rounded because a long decimal is not useful in the status reply
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
	-- message length adds a small wait but Config stops the reply from feeling slow
	return math.clamp(#message * 0.009, Config.ThinkingSecondsMin, Config.ThinkingSecondsMax)
end

--[[ some info replies need more than one chat bubble
this sends them in order with the same delay and stops if the player leaves ]]
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
	-- status uses the real session counts and the current distance from the dummy
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
	-- only shorten the text shown in the memory bubble and keep the saved entry as it was
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
	-- only the last four entries are shown because each entry needs its own bubble
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

-- cooldown is checked first because it is cheaper than getting distance or doing a raycast
local function passesCooldown(session: Session): boolean
	return now() - session.lastMessageAt >= Config.ReplyCooldown
end

local function passesRange(player: Player): (boolean, number?)
	-- return distance with the result so the sight check can reuse it
	local distance = dummy:DistanceTo(player)
	if not distance then
		return false, nil
	end

	return distance <= Config.ChatRange, distance
end

-- close players can talk without a ray but farther players must be visible to the dummy
local function passesVisibility(player: Player, distance: number): boolean
	if distance <= FAR_VISIBILITY_DISTANCE then
		return true
	end

	return dummy:CanSee(player)
end

local function authorizePlayer(player: Player, session: Session): GateResult
	--[[ this is the main server check before a message can do anything
if one check fails the message is not saved replied to or sent to NpcController ]]
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
		-- line of sight is last because it needs a raycast and the other checks are cheaper
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
	-- repeated chat is stopped here so it does not fill memory with the same message
	if not sessions:IsRepeated(session, message) then
		return false
	end

	dummy:Say(player, "you already said that. give me a new command.")
	return true
end

local function handleSpecialRequest(player: Player, session: Session, request: SpecialRequest): boolean
	-- send the matching info reply and return true so normal Brain chat is skipped
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
	-- save the players message together with the intent and topic Brain found
	sessions:UpdateStats(session, analysis.intent, analysis.topic)
	sessions:Push(session, "user", message, analysis.intent, analysis.topic)
end

local function recordDummyReply(session: Session, reply: string, analysis)
	-- save the dummy reply too so the memory command can show both sides of the chat
	sessions:Push(session, "dummy", reply, "chat", analysis.topic)
end

--[[ a player can respawn or lose a target while an action is starting
pcall keeps that one movement error from stopping the rest of the chat system ]]
local function executeAnalysis(player: Player, analysis)
	local ok = pcall(function()
		dummy:Execute(player, analysis)
	end)

	if not ok and playerStillValid(player) then
		dummy:Say(player, "that command failed during movement. try again when your character is stable.")
	end
end

local function scheduleReply(player: Player, session: Session, reply: string, analysis)
	-- the reply and action wait together then check the player is still in the server
	task.delay(responseDelay(analysis.raw), function()
		if not playerStillValid(player) then
			return
		end

		-- say the confirmation first then run the action it is talking about
		dummy:Say(player, reply)
		executeAnalysis(player, analysis)
		recordDummyReply(session, reply, analysis)
	end)
end

local function analyzeAndRespond(player: Player, session: Session, message: string)
	-- Brain reads the message once and the same result is used for reply and movement
	local analysis = brain:Analyze(message, session)
	local reply = brain:Reply(player, analysis)

	recordUserMessage(session, message, analysis)
	scheduleReply(player, session, reply, analysis)
end

--[[ every message follows this order
clean text server checks repeated text info commands then Brain reply and action ]]
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
	-- wait for the character to load before checking distance and sending the greeting
	task.delay(GREETING_DELAY, function()
		if playerStillValid(player) and dummy:DistanceTo(player) then
			dummy:Say(player, "yo " .. player.DisplayName .. ", say help if you want the command list.")
		end
	end)
end

local function connectChat(player: Player)
	-- Player.Chatted gives the text but all replies checks and actions stay on the server
	player.Chatted:Connect(function(message)
		-- every message goes through handleMessage so there is no second unvalidated route
		handleMessage(player, message)
	end)
end

local function bindPlayer(player: Player)
	-- make the session first so memory is ready before the first chat message
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
	-- remove the players session when they leave so the table does not keep old memory
	sessions:Forget(player)
end

bindExistingPlayers()
Players.PlayerAdded:Connect(bindPlayer)
Players.PlayerRemoving:Connect(removePlayer)
