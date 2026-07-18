-- Connected Discord-GitHub
--!strict

--[[ text helper module

Brain uses these functions to split messages and find numbers topics directions and tone
CommandRegistry also uses them when matching commands
keeping the checks here means both modules read text the same way ]]

export type Intent = {
	name: string,
	phrases: { string },
	words: { string }?,
}

local TextUtil = {}

local function makeSet(values: { string }): { [string]: boolean }
	-- i turn word lists into sets so checking one word does not need another loop
	local set = {}
	for _, value in values do
		set[value] = true
	end
	return table.freeze(set)
end

-- these lists are small because they only give Brain a basic topic and tone
-- this is still a rule based system and does not call an ai service
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
	-- remove spaces from both ends before the main script checks the message
	text = string.gsub(text, "^%s+", "")
	text = string.gsub(text, "%s+$", "")
	return text
end

-- make one lowercase word list that all the other checks can reuse
function TextUtil.words(text: string): { string }
	local list = {}
	for word in string.gmatch(string.lower(text), "[%w_']+") do
		table.insert(list, word)
	end
	return list
end

local function isTokenChar(character: string): boolean
	return character ~= "" and string.match(character, "[%w_']") ~= nil
end

local function hasPhraseBoundary(lower: string, phrase: string): boolean
	phrase = TextUtil.trim(phrase)
	if phrase == "" then
		return false
	end

	local searchFrom = 1
	while true do
		local startIndex, endIndex = string.find(lower, phrase, searchFrom, true)
		if not startIndex or not endIndex then
			return false
		end

		local before = string.sub(lower, startIndex - 1, startIndex - 1)
		local after = string.sub(lower, endIndex + 1, endIndex + 1)
		if not isTokenChar(before) and not isTokenChar(after) then
			return true
		end

		searchFrom = startIndex + 1
	end
end

function TextUtil.hasPhrase(lower: string, phrases: { string }): boolean
	-- check both sides so jump matches "jump now" but not a fake word like "jumpabc"
	for _, phrase in phrases do
		if hasPhraseBoundary(lower, phrase) then
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
	--[[ every number from chat comes here before it changes movement
missing or bad numbers use the fallback and real numbers stay inside the limits ]]
	if typeof(value) ~= "number" or value ~= value then
		value = fallback
	end
	return math.clamp(value, minValue, maxValue)
end

-- use the message letters to pick a reply so the same message gets the same choice
function TextUtil.pick(options: { string }, seedText: string): string
	local seed = 0
	for index = 1, #seedText do
		seed += string.byte(seedText, index) * index
	end
	return options[(seed % #options) + 1]
end

function TextUtil.sentiment(list: { string }): number
	-- add the known word scores to get a simple positive or negative tone
	local score = 0
	for _, word in list do
		score += POSITIVE_WORDS[word] or 0
		score += NEGATIVE_WORDS[word] or 0
	end
	return score
end

function TextUtil.topic(list: { string }): string?
	-- skip common words and keep the first useful word as the message topic
	for _, word in list do
		if #word >= 4 and not STOP_WORDS[word] then
			return word
		end
	end
	return nil
end

function TextUtil.direction(list: { string }): string?
	-- direction is found separately because the move command needs it with the intent
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

--[[ full phrases are checked before single words and the longest match wins
this is why "stop following" becomes stop instead of matching the word follow ]]
function TextUtil.inferIntent(lower: string, list: { string }, intents: { Intent }): string
	local bestIntent = nil :: string?
	local bestLength = 0

	for _, intent in intents do
		for _, phrase in intent.phrases do
			if hasPhraseBoundary(lower, phrase) and #phrase > bestLength then
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
	-- check common question starts too because players do not always type a question mark
	return string.find(raw, "?", 1, true) ~= nil
		or TextUtil.hasPhrase(lower, { "how", "what", "why", "where", "can you", "do you" })
end

function TextUtil.isTechnical(lower: string, list: { string }): boolean
	-- this only tells Brain to use a tech reply and does not run an action
	return TextUtil.hasAny(list, TECH_WORDS)
		or TextUtil.hasPhrase(lower, { "explain", "teach me", "how do i", "how does" })
end

function TextUtil.isTechnicalWord(word: string): boolean
	return TECH_WORDS[word] == true
end

return TextUtil
