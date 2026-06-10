--!strict

local TextUtil = require(script.Parent.TextUtil)

export type MemoryEntry = {
	role: "user" | "dummy",
	text: string,
}

export type Analysis = {
	lower: string,
	words: { string },
	intent: string,
	topic: string?,
	direction: string?,
	number: number?,
	sentiment: number,
	isQuestion: boolean,
	isTechnical: boolean,
}

export type Command = {
	intent: string,
	direction: string?,
	number: number?,
}

local LocalBrain = {}
LocalBrain.__index = LocalBrain

-- intents are data, not a pile of random if statements. adding a new command
-- means adding words/phrases here, then teaching DummyController how to run it.
local INTENTS = {
	{ name = "stop", phrases = { "stop follow", "stop following", "stay there", "stay here", "dont follow", "don't follow" } },
	{ name = "follow", phrases = { "follow me", "come with me", "come follow", "walk with me", "stick with me" } },
	{ name = "come", phrases = { "come here", "come to me", "get over here" } },
	{ name = "go_there", phrases = { "go there", "move there", "walk there" } },
	{ name = "orbit", phrases = { "orbit", "circle me" }, words = { "orbit" } },
	{ name = "sit", phrases = { "sit" }, words = { "sit" } },
	{ name = "stand", phrases = { "stand", "get up" }, words = { "stand" } },
	{ name = "spin", phrases = { "spin" }, words = { "spin" } },
	{ name = "speed", phrases = { "speed", "faster", "slower" }, words = { "speed", "faster", "slower" } },
	{ name = "jump", phrases = { "jump", "hop", "leap" }, words = { "jump", "hop", "leap" } },
	{ name = "move", phrases = { "left", "right", "forward", "back" }, words = { "left", "right", "forward", "back" } },
} :: { TextUtil.Intent }

local COMMAND_REPLIES = {
	follow = { "bet, im following but keeping space", "got you, companion mode on", "say less, im with you" },
	stop = { "alright, parking right here", "stopping. im not glued to you anymore", "copy, holding position" },
	come = { "coming over", "on my way, dont run laps", "moving to you now" },
	go_there = { "i see the direction, moving there", "going there now", "target point read, walking" },
	move = { "moving {direction}", "shifting {direction}, clean", "small move {direction}, done" },
	jump = { "jumping", "easy hop", "watch the vertical tech" },
	sit = { "sitting. very professional", "down i go", "parked" },
	stand = { "back up. locked in", "standing again", "upright mode restored" },
	spin = { "spinning like a paid feature", "rotation mode, sure", "doing the dramatic spin" },
	orbit = { "orbiting you, bodyguard mode", "circling up", "moving around you now" },
	speed = { "speed adjusted", "movement tuned", "speed setting changed" },
} :: { [string]: { string } }

-- tiny class style object. metatable here keeps the public brain api clean:
-- analyze -> reply -> command.
function LocalBrain.new()
	return setmetatable({}, LocalBrain)
end

-- recent topic is pulled from short memory, not from a global value. that keeps
-- each player conversation separate.
function LocalBrain:_recentTopic(memory: { MemoryEntry }): string?
	for index = #memory, 1, -1 do
		local entry = memory[index]
		if entry.role == "user" then
			local topic = TextUtil.topic(TextUtil.words(entry.text))
			if topic then
				return topic
			end
		end
	end
	return nil
end

-- analysis turns messy player chat into clean fields the rest of the system can
-- use. this is where "follow me", "speed 24", and normal talking become data.
function LocalBrain:analyze(message: string, memory: { MemoryEntry }): Analysis
	local lower = string.lower(message)
	local words = TextUtil.words(message)
	local number = TextUtil.firstNumber(words)
	local intent = TextUtil.inferIntent(lower, words, INTENTS)

	if intent == "jump" and (TextUtil.hasPhrase(lower, { "double", "triple", "quadruple" }) or (number and number > 1)) then
		intent = "multi_jump"
	end

	return {
		lower = lower,
		words = words,
		intent = intent,
		topic = TextUtil.topic(words) or self:_recentTopic(memory),
		direction = TextUtil.direction(words),
		number = number,
		sentiment = TextUtil.sentiment(words),
		isQuestion = TextUtil.isQuestion(message, lower),
		isTechnical = TextUtil.isTechnical(lower, words),
	}
end

-- technical replies are built from detected topic and wording. it is still
-- local logic, but not "if cframe then exact paragraph forever".
function LocalBrain:_explain(analysis: Analysis): string
	local topic = analysis.topic or "that system"
	local techFocus = nil :: string?

	for _, word in analysis.words do
		if TextUtil.isTechnicalWord(word) then
			techFocus = word
			break
		end
	end

	local subject = techFocus or topic
	local frame = TextUtil.pick({
		"{subject} is easiest to understand by splitting it into input, state, and output.",
		"The clean way to think about {subject} is purpose first, implementation second, edge cases third.",
		"For {subject}, the important part is not just making it work, it's controlling when and why it runs.",
	}, analysis.lower)

	local detail = TextUtil.pick({
		"Roblox code gets strong when expensive work is throttled, ownership is clear, and runtime behavior is predictable.",
		"I would build it with small functions, explicit state, and checks around anything that touches characters, physics, or networking.",
		"Most bugs come from mixing decisions with execution. Keep analysis separate from movement, UI, or server authority.",
	}, analysis.lower .. subject)

	return string.gsub(frame, "{subject}", subject) .. " " .. detail
end

-- command replies stay separate so movement commands can sound natural without
-- mixing speech text with movement execution.
function LocalBrain:_commandReply(analysis: Analysis): string?
	local replies = COMMAND_REPLIES[analysis.intent]
	if not replies then
		return nil
	end

	local reply = TextUtil.pick(replies, analysis.lower)
	reply = string.gsub(reply, "{direction}", analysis.direction or "there")
	return reply
end

function LocalBrain:reply(player: Player, analysis: Analysis): string
	local name = player.DisplayName ~= "" and player.DisplayName or player.Name
	local commandReply = self:_commandReply(analysis)
	if commandReply then
		return commandReply
	end

	if TextUtil.hasAny(analysis.words, { yo = true, hi = true, hey = true, sup = true, wsg = true }) then
		return TextUtil.pick({ "yo wsg gng", "sup bro, im right here", "yoo, talk to me", "what's good " .. name }, analysis.lower)
	end

	if analysis.isTechnical then
		return self:_explain(analysis)
	end

	if analysis.sentiment >= 2 then
		return TextUtil.pick({ "nah that's actually fire", "real, thats a W", "you cooked with that", "i mess with " .. (analysis.topic or "that") }, analysis.lower)
	end

	if analysis.sentiment <= -2 then
		return TextUtil.pick({ "yeah that's rough bro", "that sounds annoying ngl", "i see why you're mad", (analysis.topic or "that") .. " is not behaving clearly" }, analysis.lower)
	end

	if analysis.isQuestion then
		return TextUtil.pick({ "depends, give me the exact situation", "probably, but i need more context", "i can help with that, explain it cleaner", "maybe. what are we trying to build?" }, analysis.lower)
	end

	return TextUtil.pick({ "yeah i hear you", "real, keep going", "im listening", "say more, im locked in", "okay, " .. (analysis.topic or "that") .. " is the thing rn" }, analysis.lower)
end

function LocalBrain:command(analysis: Analysis): Command
	return {
		intent = analysis.intent,
		direction = analysis.direction,
		number = analysis.number,
	}
end

return LocalBrain
