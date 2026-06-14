--!strict

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
	-- sessions are keyed by UserId, not Player object
	-- safer if Roblox swaps player instances around during join/leave edge cases
	return setmetatable({
		_sessions = {} :: { [number]: Session },
	}, SessionStore)
end

function SessionStore:Get(player: Player): Session
	-- lazy create keeps setup cheap
	-- a player only gets memory after they actually exist on the server
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
	-- cleanup matters because this table would otherwise keep old chat memory alive
	self._sessions[player.UserId] = nil
end

-- Memory is capped on purpose
-- the dummy only needs recent context for things like "explain that"
-- storing unlimited chat is wasted memory and not useful for this local brain
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
	-- newest topic wins
	-- if the latest stats are empty, scan memory backwards for a usable topic
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
	-- stats are kept small: total messages, command count, last intent, last topic
	-- enough for status/debug without making this a database
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
	-- repeated message detection is normalized, so whitespace/case changes do not bypass it
	-- the third repeat is where the dummy pushes back
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
