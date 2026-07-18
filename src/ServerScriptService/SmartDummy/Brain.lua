-- Connected Discord-GitHub
--!strict

--[[ brain module

this module reads the players message and turns it into simple values like
intent direction number and topic
it also makes the reply but it never moves the dummy
NpcController gets the finished values and handles the actual action ]]

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
	-- i pass this function in so Brain can use memory without storing sessions itself
	return setmetatable({
		_recentTopicProvider = recentTopicProvider,
	}, Brain)
end

--[[ the message only gets read once here
first it is turned into lowercase words then the helpers find the command and extra values
the main script can use one result for both the reply and the npc action ]]
function Brain:Analyze(message: string, session: any): Analysis
	local lower = string.lower(message)
	local list = TextUtil.words(message)
	local number = TextUtil.firstNumber(list)
	local intent = TextUtil.inferIntent(lower, list, CommandRegistry.IntentRules())

	-- all ways of asking for more than one jump go through the same action
	if intent == "jump" and (TextUtil.hasPhrase(lower, { "double", "triple", "quadruple" }) or (number and number > 1)) then
		intent = "multi_jump"
		if not number then
			-- if they said triple or quadruple without a number i get the amount from that word
			number = if string.find(lower, "triple", 1, true) then 3 elseif string.find(lower, "quadruple", 1, true) then 4 else 2
		end
	end

	-- raw and lower are useful for replies and the other values are used by NpcController
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
	-- use a tech word from this message first then fall back to the topic in memory
	for _, word in analysis.words do
		if TextUtil.isTechnicalWord(word) then
			return word
		end
	end
	return analysis.topic or "that system"
end

function Brain:_TechnicalReply(analysis: Analysis): string
	-- these replies explain the topic without needing any http or outside ai
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
	-- command replies come from the same entry that Brain used to match the command
	return CommandRegistry.BuildCommandReply(analysis.intent, analysis.direction, analysis.lower)
end

function Brain:Reply(player: Player, analysis: Analysis): string
	--[[ command replies come first because they confirm an action
	after that i check greetings tech questions tone questions and then normal chat ]]
	local movementReply = self:_CommandReply(analysis)
	if movementReply then
		return movementReply
	end

	local playerName = player.DisplayName ~= "" and player.DisplayName or player.Name
	if TextUtil.hasAny(analysis.words, { yo = true, hi = true, hey = true, sup = true, wsg = true }) then
		-- greetings do not need the longer reply system
		return TextUtil.pick({ "yo wsg " .. playerName, "sup, im listening.", "yoo, what we doing?", "what's good." }, analysis.lower)
	end
	if analysis.isTechnical then
		-- tech questions use _TechnicalReply because they need more detail
		return self:_TechnicalReply(analysis)
	end
	if analysis.sentiment >= 2 then
		-- tone only changes what the dummy says and can never start an action
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
