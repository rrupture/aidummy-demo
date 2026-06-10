--!strict

export type Intent = {
	name: string,
	phrases: { string },
	words: { string }?,
}

local TextUtil = {}

-- words like "the" and "you" do not tell us the topic. removing them makes
-- the local brain pick useful words instead of random filler.
local STOP_WORDS = table.freeze({
	a = true,
	about = true,
	am = true,
	an = true,
	["and"] = true,
	are = true,
	at = true,
	be = true,
	bro = true,
	bruh = true,
	can = true,
	["do"] = true,
	["for"] = true,
	from = true,
	how = true,
	i = true,
	["in"] = true,
	is = true,
	it = true,
	me = true,
	my = true,
	of = true,
	on = true,
	["or"] = true,
	so = true,
	that = true,
	the = true,
	this = true,
	to = true,
	u = true,
	what = true,
	when = true,
	where = true,
	who = true,
	why = true,
	with = true,
	you = true,
	your = true,
})

-- tiny sentiment tables. this is cheap, local, and good enough to change the
-- dummy tone without calling an api.
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

-- technical words make the dummy switch from normal chat into explanation mode.
-- this is how one brain can answer both "yo" and "explain cframe".
local TECH_WORDS = table.freeze({
	cframe = true,
	code = true,
	["function"] = true,
	humanoid = true,
	lua = true,
	luau = true,
	metatable = true,
	metatables = true,
	module = true,
	pathfinding = true,
	physics = true,
	raycast = true,
	roblox = true,
	script = true,
	scripting = true,
	server = true,
	studio = true,
})

function TextUtil.trim(text: string): string
	text = string.gsub(text, "^%s+", "")
	text = string.gsub(text, "%s+$", "")
	return text
end

-- turns any message into lowercase word tokens. every other helper uses this,
-- so parsing happens once in one simple format.
function TextUtil.words(text: string): { string }
	local words = {}
	for word in string.gmatch(string.lower(text), "[%w_']+") do
		table.insert(words, word)
	end
	return words
end

-- phrase checks run before single-word checks because "stop following" should
-- mean stop, not follow.
function TextUtil.hasPhrase(lower: string, phrases: { string }): boolean
	for _, phrase in phrases do
		if string.find(lower, phrase, 1, true) then
			return true
		end
	end
	return false
end

function TextUtil.hasWord(words: { string }, target: string): boolean
	for _, word in words do
		if word == target then
			return true
		end
	end
	return false
end

function TextUtil.hasAny(words: { string }, dictionary: { [string]: any }): boolean
	for _, word in words do
		if dictionary[word] then
			return true
		end
	end
	return false
end

function TextUtil.firstNumber(words: { string }): number?
	for _, word in words do
		local number = tonumber(word)
		if number then
			return number
		end
	end
	return nil
end

-- score is not trying to be deep ai. it only helps the reply feel less flat
-- when the player sounds hyped or annoyed.
function TextUtil.sentiment(words: { string }): number
	local score = 0
	for _, word in words do
		score += POSITIVE_WORDS[word] or 0
		score += NEGATIVE_WORDS[word] or 0
	end
	return score
end

-- first non-filler long word becomes the topic. short memory can reuse it if
-- the next message says "yeah explain that".
function TextUtil.topic(words: { string }): string?
	for _, word in words do
		if #word >= 4 and not STOP_WORDS[word] then
			return word
		end
	end
	return nil
end

-- direction words are normalized here so movement code only has to handle four
-- clean directions.
function TextUtil.direction(words: { string }): string?
	if TextUtil.hasWord(words, "left") then
		return "left"
	elseif TextUtil.hasWord(words, "right") then
		return "right"
	elseif TextUtil.hasWord(words, "forward") or TextUtil.hasWord(words, "ahead") then
		return "forward"
	elseif TextUtil.hasWord(words, "back") or TextUtil.hasWord(words, "backward") or TextUtil.hasWord(words, "backwards") then
		return "back"
	end
	return nil
end

-- intent detection is data-driven. LocalBrain passes in intent rules, this just
-- runs the matching in a stable order.
function TextUtil.inferIntent(lower: string, words: { string }, intents: { Intent }): string
	for _, intent in intents do
		if TextUtil.hasPhrase(lower, intent.phrases) then
			return intent.name
		end
		if intent.words then
			for _, word in intent.words do
				if TextUtil.hasWord(words, word) then
					return intent.name
				end
			end
		end
	end
	return "chat"
end

function TextUtil.isQuestion(message: string, lower: string): boolean
	return string.find(message, "?", 1, true) ~= nil or TextUtil.hasPhrase(lower, { "how ", "what ", "why ", "where ", "can you" })
end

function TextUtil.isTechnical(lower: string, words: { string }): boolean
	return TextUtil.hasAny(words, TECH_WORDS) or TextUtil.hasPhrase(lower, { "explain ", "teach me", "how do i", "how does" })
end

-- deterministic picker. same input gives same answer, so it feels stable, but
-- different messages still get different wording.
function TextUtil.pick(options: { string }, seedText: string): string
	local seed = 0
	for index = 1, #seedText do
		seed += string.byte(seedText, index) * index
	end
	return options[(seed % #options) + 1]
end

-- all numeric commands go through this clamp so nobody can ask for speed 9999
-- and break the humanoid.
function TextUtil.clampNumber(value: number?, fallback: number, minValue: number, maxValue: number): number
	if typeof(value) ~= "number" or value ~= value then
		value = fallback
	end
	return math.clamp(value, minValue, maxValue)
end

function TextUtil.isTechnicalWord(word: string): boolean
	return TECH_WORDS[word] == true
end

return TextUtil
