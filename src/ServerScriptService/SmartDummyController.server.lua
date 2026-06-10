-- Connected Discord-GitHub
--!strict
local Players = game:GetService("Players")

local SmartDummy = script.Parent:WaitForChild("SmartDummy")
local Config = require(SmartDummy.Config)
local DummyController = require(SmartDummy.DummyController)
local LocalBrain = require(SmartDummy.LocalBrain)
local TextUtil = require(SmartDummy.TextUtil)

-- this script is the traffic control. it does not try to move the npc itself
-- and it does not try to be the whole brain. it checks chat, saves tiny memory,
-- asks LocalBrain what the player meant, then tells DummyController to do it.
type MemoryEntry = LocalBrain.MemoryEntry

type Session = {
	memory: { MemoryEntry },
	lastMessageAt: number,
	messageCount: number,
	commandCount: number,
	lastIntent: string,
}

type GuideEntry = {
	id: string,
	triggers: { string },
	lines: { string },
}

local sessions = {} :: { [number]: Session }
local brain = LocalBrain.new()
local dummy = DummyController.new()
local startedAt = os.clock()

-- quick help only. normal chat still goes through LocalBrain so the dummy is
-- not just a command menu with legs.
local GUIDE = {
	{
		id = "movement",
		triggers = { "help", "commands", "what can you do", "movement" },
		lines = {
			"i can follow, stop, come here, go there, move left or right, jump, sit, stand, spin, orbit, and change speed",
			"try: follow me | stop following | go there | move left 12 | triple jump | speed 24",
		},
	},
	{
		id = "technical",
		triggers = { "technical", "explain", "coding", "script" },
		lines = {
			"ask scripting questions too. i break the message into topic, tone, and intent before answering",
			"try: explain pathfinding | explain cframe | how do metatables work",
		},
	},
} :: { GuideEntry }

-- each player gets separate short memory. without this, one player could talk
-- about pathfinding and another player would accidentally inherit that topic.
local function sessionFor(player: Player): Session
	local session = sessions[player.UserId]
	if session then
		return session
	end

	session = {
		memory = {},
		lastMessageAt = 0,
		messageCount = 0,
		commandCount = 0,
		lastIntent = "none",
	}
	sessions[player.UserId] = session
	return session
end

-- memory is capped because the dummy only needs recent context. keeping every
-- message forever would be wasted table growth for no real gain.
local function pushMemory(session: Session, role: "user" | "dummy", text: string)
	table.insert(session.memory, {
		role = role,
		text = text,
	})

	while #session.memory > Config.MemoryLimit do
		table.remove(session.memory, 1)
	end
end

-- clean the message before the brain sees it. slash commands are ignored so
-- Roblox chat commands do not turn into npc commands by accident.
local function normalizeMessage(message: string): string?
	message = TextUtil.trim(message)
	if message == "" or string.sub(message, 1, 1) == "/" then
		return nil
	end

	if #message > Config.MaxMessageLength then
		message = string.sub(message, 1, Config.MaxMessageLength)
	end

	return message
end

-- guide matching is separate from brain analysis because help text should be
-- instant, but real questions should still get a real generated reply.
local function findGuide(message: string): GuideEntry?
	local lower = string.lower(message)
	for _, guide in GUIDE do
		for _, trigger in guide.triggers do
			if string.find(lower, trigger, 1, true) then
				return guide
			end
		end
	end
	return nil
end

-- only exact guide requests get swallowed. if someone says "explain scripting"
-- it should go to the brain, not open the help menu.
local function isGuideOnlyRequest(message: string): boolean
	local lower = string.lower(message)
	return lower == "help"
		or lower == "commands"
		or lower == "dummy help"
		or lower == "what can you do"
end

-- two guide bubbles are delayed a bit so they can actually be read.
local function sendGuide(player: Player, guide: GuideEntry)
	task.spawn(function()
		for _, line in guide.lines do
			if not player.Parent then
				return
			end
			dummy:say(player, line)
			task.wait(0.55)
		end
	end)
end

-- stats stay tiny. they help prove commands are being tracked without making
-- a datastore, remote event, or some oversized logging system.
local function shouldCountCommand(intent: string): boolean
	return intent ~= "chat"
end

local function updateSessionStats(session: Session, intent: string)
	session.messageCount += 1
	session.lastIntent = intent
	if shouldCountCommand(intent) then
		session.commandCount += 1
	end
end

-- rare pulse for longer tests. it is every 12 messages so it will not spam.
local function maybeReportSession(player: Player, session: Session)
	if session.messageCount > 0 and session.messageCount % 12 == 0 then
		task.delay(0.4, function()
			if player.Parent then
				dummy:say(player, "session check: " .. tostring(session.messageCount) .. " messages, " .. tostring(session.commandCount) .. " commands, " .. tostring(math.floor(os.clock() - startedAt)) .. "s awake")
			end
		end)
	end
end

-- delayed greeting avoids talking before the player's character exists.
local function greetPlayer(player: Player)
	task.delay(1.2, function()
		if player.Parent and dummy:distanceTo(player) then
			dummy:say(player, "yo " .. player.DisplayName .. ", say help if you want the command list")
		end
	end)
end

-- biggest optimization gate. if the player is too far, spamming, or behind a
-- wall, the dummy does not waste time doing brain analysis or movement work.
local function playerIsAllowed(player: Player, session: Session): boolean
	local now = os.clock()
	if now - session.lastMessageAt < Config.ReplyCooldown then
		return false
	end

	local distance = dummy:distanceTo(player)
	if not distance or distance > Config.ChatRange then
		return false
	end

	if distance > 28 and not dummy:canSee(player) then
		return false
	end

	session.lastMessageAt = now
	return true
end

-- fake thinking delay, clamped so long messages do not freeze the reply.
local function responseDelay(message: string): number
	return math.clamp(#message * 0.01, Config.ThinkingSecondsMin, Config.ThinkingSecondsMax)
end

-- returns true only if the guide fully handled the message. this keeps the
-- normal message path from double replying.
local function handleGuideIfNeeded(player: Player, message: string): boolean
	local guide = findGuide(message)
	if not guide then
		return false
	end

	if isGuideOnlyRequest(message) then
		sendGuide(player, guide)
		return true
	end

	return false
end

-- full flow is here: clean input, check session rules, remember text, analyze,
-- reply, then execute the command. brain and movement are split so this stays
-- readable instead of becoming one giant messy file.
local function handleMessage(player: Player, rawMessage: string)
	local message = normalizeMessage(rawMessage)
	if not message then
		return
	end

	local session = sessionFor(player)
	if not playerIsAllowed(player, session) then
		return
	end

	if handleGuideIfNeeded(player, message) then
		return
	end

	pushMemory(session, "user", message)

	local analysis = brain:analyze(message, session.memory)
	local reply = brain:reply(player, analysis)
	local command = brain:command(analysis)
	updateSessionStats(session, command.intent)

	task.delay(responseDelay(message), function()
		if not player.Parent then
			return
		end

		dummy:say(player, reply)
		dummy:execute(player, command, analysis.lower)
		pushMemory(session, "dummy", reply)
		maybeReportSession(player, session)
	end)
end

-- server owns chat binding and action authority. clients never directly tell
-- the dummy where to move.
local function bindPlayer(player: Player)
	sessionFor(player)
	greetPlayer(player)
	player.Chatted:Connect(function(message)
		handleMessage(player, message)
	end)
end

for _, player in Players:GetPlayers() do
	bindPlayer(player)
end

Players.PlayerAdded:Connect(bindPlayer)
Players.PlayerRemoving:Connect(function(player)
	sessions[player.UserId] = nil
end)
