-- Connected Discord-GitHub
--!strict

--[[ session store

each player gets their own small table with recent chat and a few stats
the main script saves messages here and Brain asks for the last topic
the sessions stay here so Brain only has to focus on reading text ]]

local Config = require(script.Parent.Config)
local TextUtil = require(script.Parent.TextUtil)

export type MemoryEntry = {
	role: "user" | "dummy",
	text: string,
	intent: string,
	topic: string?,
}

export type Session = {
	memory: { MemoryEntry },
	lastMessageAt: number,
	lastNormalized: string,
	repeatCount: number,
	messageCount: number,
	commandCount: number,
	lastIntent: string,
	lastTopic: string?,
}

local SessionStore = {}
SessionStore.__index = SessionStore

function SessionStore.new()
	-- UserId is used as the key so every player has a separate session
	return setmetatable({
		_sessions = {} :: { [number]: Session },
	}, SessionStore)
end

function SessionStore:Get(player: Player): Session
	-- only make a new session if this player does not already have one
	local session = self._sessions[player.UserId]
	if session then
		return session
	end

	session = {
		memory = {},
		lastMessageAt = 0,
		lastNormalized = "",
		repeatCount = 0,
		messageCount = 0,
		commandCount = 0,
		lastIntent = "chat",
		lastTopic = nil,
	}
	self._sessions[player.UserId] = session
	return session
end

function SessionStore:Forget(player: Player)
	-- forget the session when the player leaves so old memory does not stay in the table
	self._sessions[player.UserId] = nil
end

--[[ recent messages are enough for follow up chat like "explain that"
when the limit is passed i remove the oldest entry so memory cannot keep growing ]]
function SessionStore:Push(session: Session, role: "user" | "dummy", text: string, intent: string, topic: string?)
	table.insert(session.memory, {
		role = role,
		text = text,
		intent = intent,
		topic = topic,
	})

	while #session.memory > Config.MemoryLimit do
		table.remove(session.memory, 1)
	end
end

function SessionStore:RecentTopic(session: Session): string?
	-- lastTopic is normally used but older memory is checked if it is empty
	if session.lastTopic then
		return session.lastTopic
	end

	for index = #session.memory, 1, -1 do
		local entry = session.memory[index]
		if entry.topic then
			return entry.topic
		end
	end
	return nil
end

function SessionStore:UpdateStats(session: Session, intent: string, topic: string?)
	-- these are the only stats needed for the status reply and recent topic
	session.messageCount += 1
	session.lastIntent = intent
	if topic then
		session.lastTopic = topic
	end
	if intent ~= "chat" then
		session.commandCount += 1
	end
end

function SessionStore:IsRepeated(session: Session, message: string): boolean
	-- lowercase and trim the message so changing capitals or outside spaces is still a repeat
	-- the third copy returns true and the main script blocks it
	local normalized = string.lower(TextUtil.trim(message))
	if normalized == session.lastNormalized then
		session.repeatCount += 1
	else
		session.lastNormalized = normalized
		session.repeatCount = 1
	end
	return session.repeatCount >= 3
end

return SessionStore
