--!strict

local CommandRegistry = require(script.Parent.CommandRegistry)
local TextUtil = require(script.Parent.TextUtil)

export type Analysis = {
	raw: string,
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

local Brain = {}
Brain.__index = Brain

function Brain.new(recentTopicProvider: (any) -> string?)
	-- the brain does not own session storage directly
	-- it asks for recent topic through this callback so memory can stay in SessionStore
	return setmetatable({
		_recentTopicProvider = recentTopicProvider,
	}, Brain)
end

-- Analyze converts one chat message into a compact read of what the player means
-- this is the important part: movement code never parses raw text
-- it gets intent/direction/number/topic, which is way cleaner than making every
-- NPC action search strings by itself
function Brain:Analyze(message: string, session: any): Analysis
	local lower = string.lower(message)
	local list = TextUtil.words(message)
	local number = TextUtil.firstNumber(list)
	local intent = TextUtil.inferIntent(lower, list, CommandRegistry.IntentRules())

	-- jump has a small upgrade path because players say it in many ways
	-- "double jump", "triple jump", or "jump 4" all become the same action intent
	if intent == "jump" and (TextUtil.hasPhrase(lower, { "double", "triple", "quadruple" }) or (number and number > 1)) then
		intent = "multi_jump"
		if not number then
			-- no number was typed, so the common wording decides the count
			-- this keeps "triple jump" readable in chat without forcing "jump 3"
			number = if string.find(lower, "triple", 1, true) then 3 elseif string.find(lower, "quadruple", 1, true) then 4 else 2
		end
	end

	-- this return table is the whole contract between brain and controller
	-- raw/lower are kept for replies, the rest is cleaned data for action code
	return {
		raw = message,
		lower = lower,
		words = list,
		intent = intent,
		topic = TextUtil.topic(list) or self._recentTopicProvider(session),
		direction = TextUtil.direction(list),
		number = number,
		sentiment = TextUtil.sentiment(list),
		isQuestion = TextUtil.isQuestion(message, lower),
		isTechnical = TextUtil.isTechnical(lower, list),
	}
end

local function technicalFocus(analysis: Analysis): string
	-- choose a real technical word first, then fall back to the recent topic
	-- this makes "explain that" still useful after the player mentioned pathfinding
	for _, word in analysis.words do
		if TextUtil.isTechnicalWord(word) then
			return word
		end
	end
	return analysis.topic or "that system"
end

function Brain:_TechnicalReply(analysis: Analysis): string
	-- the technical reply is templated by concept, not by full sentence
	-- that keeps it local and cheap while still explaining the actual code split
	local subject = technicalFocus(analysis)
	local first = TextUtil.pick({
		"{subject} is easiest to understand by separating input, state, and output.",
		"The important part with {subject} is deciding what runs once, what runs every frame, and what stays server-owned.",
		"For {subject}, clean code means the decision logic and the Roblox action should not be mixed together.",
	}, analysis.lower)

	local second = TextUtil.pick({
		"That is why this dummy parses chat first, then movement methods execute using Humanoid, PathfindingService, raycasts, and CFrame math.",
		"If you recompute expensive work every frame, it may still work, but it will scale badly once more players or NPCs exist.",
		"That separation makes the behavior easier to test because a bad chat read cannot silently rewrite the movement system.",
	}, analysis.lower .. subject)

	return string.gsub(first, "{subject}", subject) .. " " .. second
end

function Brain:_CommandReply(analysis: Analysis): string?
	-- command replies come from the registry so the command meaning and wording
	-- are tied to one source
	return CommandRegistry.BuildCommandReply(analysis.intent, analysis.direction, analysis.lower)
end

function Brain:Reply(player: Player, analysis: Analysis): string
	-- reply priority matters
	-- actions answer first, then greetings, then technical explanations, then mood
	-- normal chat stays lightweight so the dummy does not overtalk every message
	local movementReply = self:_CommandReply(analysis)
	if movementReply then
		return movementReply
	end

	local playerName = player.DisplayName ~= "" and player.DisplayName or player.Name
	if TextUtil.hasAny(analysis.words, { yo = true, hi = true, hey = true, sup = true, wsg = true }) then
		-- greetings should feel quick and normal, not like a technical manual
		return TextUtil.pick({ "yo wsg " .. playerName, "sup, im listening.", "yoo, what we doing?", "what's good." }, analysis.lower)
	end
	if analysis.isTechnical then
		-- technical messages get longer answers because the player is asking to learn
		return self:_TechnicalReply(analysis)
	end
	if analysis.sentiment >= 2 then
		-- tone only changes wording, never movement authority
		return TextUtil.pick({ "yeah that is clean.", "real, that is a good idea.", "that sounds solid.", "i see the vision." }, analysis.lower)
	end
	if analysis.sentiment <= -2 then
		return TextUtil.pick({ "yeah, that sounds annoying.", "i get why that would be frustrating.", "that needs a cleaner fix.", "that is probably a logic issue." }, analysis.lower)
	end
	if analysis.isQuestion then
		return TextUtil.pick({ "depends on the exact setup.", "probably, but give me more context.", "i can help with that, explain the situation.", "what result are you trying to get?" }, analysis.lower)
	end
	return TextUtil.pick({ "yeah, keep going.", "i hear you.", "makes sense.", "alright, im tracking it.", "say more about " .. (analysis.topic or "that") .. "." }, analysis.lower)
end

return Brain
