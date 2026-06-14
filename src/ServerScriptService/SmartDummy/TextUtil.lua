--!strict

export type Intent = {
	name: string,
	phrases: { string },
	words: { string }?,
}

local TextUtil = {}

local function makeSet(values: { string }): { [string]: boolean }
	-- frozen sets make membership checks cheap and stop accidental runtime edits
	local set = {}
	for _, value in values do
		set[value] = true
	end
	return table.freeze(set)
end

-- These dictionaries are intentionally small
-- this is not pretending to be a real LLM
-- they provide cheap local signals for intent, tone, and topic
local STOP_WORDS = makeSet({
	"a", "about", "am", "an", "and", "are", "at", "be", "bro", "bruh", "can", "do", "for",
	"from", "how", "i", "in", "is", "it", "me", "my", "of", "on", "or", "so", "that",
	"the", "this", "to", "u", "what", "when", "where", "who", "why", "with", "you", "your",
})

local TECH_WORDS = makeSet({
	"cframe", "code", "event", "humanoid", "lerp", "lua", "luau", "metatable", "metatables",
	"module", "pathfinding", "physics", "raycast", "roblox", "server", "signal", "script",
	"scripting", "state", "tween",
})

local POSITIVE_WORDS = table.freeze({
	clean = 1,
	cool = 2,
	fire = 2,
	good = 1,
	great = 2,
	love = 2,
	nice = 1,
	smart = 2,
	tuff = 2,
	w = 1,
})

local NEGATIVE_WORDS = table.freeze({
	annoying = -1,
	ass = -2,
	bad = -1,
	broke = -2,
	broken = -2,
	dumb = -2,
	hate = -2,
	lag = -1,
	laggy = -2,
	mad = -1,
	stupid = -2,
	trash = -2,
	wrong = -1,
})

function TextUtil.trim(text: string): string
	-- Roblox chat can include leading/trailing spaces, strip them before gates run
	text = string.gsub(text, "^%s+", "")
	text = string.gsub(text, "%s+$", "")
	return text
end

-- All parsing starts with normalized word tokens
-- the rest of the system avoids repeatedly searching raw strings,
-- which keeps command behavior predictable
function TextUtil.words(text: string): { string }
	local list = {}
	for word in string.gmatch(string.lower(text), "[%w_']+") do
		table.insert(list, word)
	end
	return list
end

function TextUtil.hasPhrase(lower: string, phrases: { string }): boolean
	-- phrase checks use plain search, no pattern magic
	-- player text should not accidentally become a Lua pattern
	for _, phrase in phrases do
		if string.find(lower, phrase, 1, true) then
			return true
		end
	end
	return false
end

function TextUtil.hasWord(list: { string }, target: string): boolean
	for _, word in list do
		if word == target then
			return true
		end
	end
	return false
end

function TextUtil.hasAny(list: { string }, dictionary: { [string]: any }): boolean
	for _, word in list do
		if dictionary[word] then
			return true
		end
	end
	return false
end

function TextUtil.firstNumber(list: { string }): number?
	for _, word in list do
		local number = tonumber(word)
		if number then
			return number
		end
	end
	return nil
end

function TextUtil.clampNumber(value: number?, fallback: number, minValue: number, maxValue: number): number
	-- every number from chat goes through one clamp helper
	-- protects movement distance, jump count, orbit time, and speed
	if typeof(value) ~= "number" or value ~= value then
		value = fallback
	end
	return math.clamp(value, minValue, maxValue)
end

-- Deterministic selection gives variety without random state
-- the same message chooses the same reply, which feels stable and easier to debug
function TextUtil.pick(options: { string }, seedText: string): string
	local seed = 0
	for index = 1, #seedText do
		seed += string.byte(seedText, index) * index
	end
	return options[(seed % #options) + 1]
end

function TextUtil.sentiment(list: { string }): number
	-- simple tone score
	-- it only decides reply style, never physical NPC behavior
	local score = 0
	for _, word in list do
		score += POSITIVE_WORDS[word] or 0
		score += NEGATIVE_WORDS[word] or 0
	end
	return score
end

function TextUtil.topic(list: { string }): string?
	-- first useful word becomes the topic
	-- not perfect language understanding, but good enough for short chat context
	for _, word in list do
		if #word >= 4 and not STOP_WORDS[word] then
			return word
		end
	end
	return nil
end

function TextUtil.direction(list: { string }): string?
	-- direction is separated from intent because several commands can use it
	if TextUtil.hasWord(list, "left") then
		return "left"
	elseif TextUtil.hasWord(list, "right") then
		return "right"
	elseif TextUtil.hasWord(list, "forward") or TextUtil.hasWord(list, "ahead") then
		return "forward"
	elseif TextUtil.hasWord(list, "back") or TextUtil.hasWord(list, "backward") or TextUtil.hasWord(list, "backwards") then
		return "back"
	end
	return nil
end

-- Phrase rules run before word rules, but phrase priority also matters
-- longest matching phrase wins, so "stop following" beats the shorter "follow"
-- this fixes command overlap without relying on fragile command order
function TextUtil.inferIntent(lower: string, list: { string }, intents: { Intent }): string
	local bestIntent = nil :: string?
	local bestLength = 0

	for _, intent in intents do
		for _, phrase in intent.phrases do
			if string.find(lower, phrase, 1, true) and #phrase > bestLength then
				bestIntent = intent.name
				bestLength = #phrase
			end
		end
	end

	if bestIntent then
		return bestIntent
	end

	for _, intent in intents do
		if intent.words then
			for _, word in intent.words do
				if TextUtil.hasWord(list, word) then
					return intent.name
				end
			end
		end
	end
	return "chat"
end

function TextUtil.isQuestion(raw: string, lower: string): boolean
	-- question marks and common question starts both count
	return string.find(raw, "?", 1, true) ~= nil
		or TextUtil.hasPhrase(lower, { "how ", "what ", "why ", "where ", "can you", "do you" })
end

function TextUtil.isTechnical(lower: string, list: { string }): boolean
	-- technical detection routes to explanation style replies
	-- it does not change movement permissions or server gates
	return TextUtil.hasAny(list, TECH_WORDS)
		or TextUtil.hasPhrase(lower, { "explain ", "teach me", "how do i", "how does" })
end

function TextUtil.isTechnicalWord(word: string): boolean
	return TECH_WORDS[word] == true
end

return TextUtil
