--!strict

local TextUtil = require(script.Parent.TextUtil)

export type CommandCategory = "movement" | "action" | "utility"

export type CommandSpec = {
	id: string,
	category: CommandCategory,
	phrases: { string },
	words: { string }?,
	example: string,
	summary: string,
	apiNotes: { string },
	response: string,
}

local CommandRegistry = {}

-- this is the main line between "hardcoded bot" and "local command system"
-- the table below describes commands, but it does not run them
-- Brain reads this metadata to understand chat, SmartDummyController uses it
-- for help/debug text, and NpcController is the only module that touches the
-- actual Humanoid, CFrame, raycast, and pathfinding behavior
-- so if i tune a command later, the parser and the player-facing docs stay in sync
local COMMANDS = {
	{
		id = "follow",
		category = "movement",
		phrases = { "follow me", "come with me", "walk with me", "stick with me", "follow" },
		words = { "follow" },
		example = "follow me",
		summary = "follows the player while keeping a fixed gap",
		apiNotes = { "Humanoid:MoveTo", "server network ownership", "distance checks" },
		response = "following with spacing",
	},
	{
		id = "stop",
		category = "movement",
		phrases = { "stop follow", "stop following", "stay there", "stay here", "dont follow", "don't follow" },
		words = { "stop" },
		example = "stop following",
		summary = "clears follow/path state and stops humanoid movement",
		apiNotes = { "Humanoid:Move", "Humanoid:MoveTo", "state reset" },
		response = "holding position",
	},
	{
		id = "come",
		category = "movement",
		phrases = { "come here", "come to me", "get over here" },
		words = { "come" },
		example = "come here",
		summary = "moves near the player without standing inside them",
		apiNotes = { "CFrame look vector", "flat vector math", "PathfindingService" },
		response = "moving to you",
	},
	{
		id = "go_there",
		category = "movement",
		phrases = { "go there", "move there", "walk there" },
		example = "go there",
		summary = "raycasts from the player direction and moves to the hit point",
		apiNotes = { "Workspace:Raycast", "RaycastParams", "PathfindingService" },
		response = "moving to the raycast target",
	},
	{
		id = "move",
		category = "movement",
		phrases = { "move left", "move right", "move forward", "move back", "left", "right", "forward", "back" },
		words = { "left", "right", "forward", "back" },
		example = "move left 12",
		summary = "moves relative to the player's facing direction",
		apiNotes = { "CFrame.RightVector", "CFrame.LookVector", "number clamping" },
		response = "moving {direction}",
	},
	{
		id = "jump",
		category = "action",
		phrases = { "jump", "hop", "leap" },
		words = { "jump", "hop", "leap" },
		example = "jump",
		summary = "forces a humanoid jump action",
		apiNotes = { "Humanoid.Jump", "ChangeState", "AssemblyLinearVelocity" },
		response = "jumping",
	},
	{
		id = "multi_jump",
		category = "action",
		phrases = { "double jump", "triple jump", "quadruple jump" },
		example = "triple jump",
		summary = "queues multiple timed jump impulses",
		apiNotes = { "task.spawn", "HumanoidStateType.Jumping", "clamped repeat count" },
		response = "running jump chain",
	},
	{
		id = "speed",
		category = "action",
		phrases = { "speed", "faster", "slower", "walkspeed" },
		words = { "speed", "faster", "slower", "walkspeed" },
		example = "speed 24",
		summary = "changes humanoid walkspeed inside safe limits",
		apiNotes = { "Humanoid.WalkSpeed", "math.clamp", "numeric parsing" },
		response = "adjusting walkspeed",
	},
	{
		id = "orbit",
		category = "action",
		phrases = { "orbit me", "circle me", "orbit" },
		words = { "orbit" },
		example = "orbit me",
		summary = "moves around the player using a timed circular offset",
		apiNotes = { "math.sin/cos", "RunService timing", "PathfindingService fallback" },
		response = "orbiting around you",
	},
	{
		id = "sit",
		category = "action",
		phrases = { "sit down", "sit" },
		words = { "sit" },
		example = "sit",
		summary = "sets the humanoid sitting state and stops follow mode",
		apiNotes = { "Humanoid.Sit", "state cleanup" },
		response = "sitting",
	},
	{
		id = "stand",
		category = "action",
		phrases = { "stand up", "get up", "stand" },
		words = { "stand" },
		example = "stand up",
		summary = "clears the humanoid sitting state",
		apiNotes = { "Humanoid.Sit", "state cleanup" },
		response = "standing",
	},
	{
		id = "spin",
		category = "action",
		phrases = { "spin around", "spin" },
		words = { "spin" },
		example = "spin",
		summary = "temporarily rotates the root part with CFrame math",
		apiNotes = { "CFrame.Angles", "RunService.Heartbeat", "timed action state" },
		response = "spinning",
	},
} :: { CommandSpec }

-- these are utility requests, not NPC actions
-- they are exact aliases because commands like "status" and "memory" should be
-- predictable and not fight the normal brain response logic
local UTILITY_ALIASES = {
	help = { "help", "commands", "what can you do", "dummy help" },
	status = { "status", "stats", "session", "what are you doing" },
	memory = { "memory", "recent memory", "what did i say", "what do you remember" },
	demo = { "demo", "demo plan", "show demo" },
	architecture = { "about", "about system", "how are you built", "architecture" },
	internals = { "internals", "technical internals", "how does it work", "api usage" },
} :: { [string]: { string } }

local byId = {}
for _, command in COMMANDS do
	-- id map makes command lookup O(1) and avoids scanning COMMANDS everywhere
	byId[command.id] = command
end

function CommandRegistry.IntentRules(): { TextUtil.Intent }
	-- TextUtil only needs phrase/word rules, not the full command object
	-- this keeps the text parser small and stops it from knowing about UI/help data
	local rules = {}
	for _, command in COMMANDS do
		table.insert(rules, {
			name = command.id,
			phrases = command.phrases,
			words = command.words,
		})
	end
	return rules
end

function CommandRegistry.Get(id: string): CommandSpec?
	-- constant lookup by id, used when other modules need command details
	return byId[id]
end

function CommandRegistry.Commands(): { CommandSpec }
	-- returns the canonical command list, never rebuild separate command arrays
	return COMMANDS
end

function CommandRegistry.MatchUtility(lowerMessage: string): string?
	-- utility commands are only matched when the whole message is the alias
	-- this avoids random words inside normal chat accidentally opening status/help
	for id, aliases in UTILITY_ALIASES do
		for _, alias in aliases do
			-- exact match is intentional here
			-- "can you explain memory" should be a normal technical reply,
			-- not the memory dump command
			if lowerMessage == alias then
				return id
			end
		end
	end
	return nil
end

local function collectExamples(category: CommandCategory): { string }
	-- examples are generated from the command specs so help never goes stale
	local examples = {}
	for _, command in COMMANDS do
		if command.category == category then
			table.insert(examples, command.example)
		end
	end
	return examples
end

local function uniqueApiNotes(): { string }
	-- used by the internals response to show which Roblox APIs the system uses
	-- duplicate notes get collapsed so the output stays readable
	local seen = {}
	local notes = {}
	for _, command in COMMANDS do
		for _, note in command.apiNotes do
			if not seen[note] then
				seen[note] = true
				table.insert(notes, note)
			end
		end
	end
	return notes
end

local function joinFirst(values: { string }, limit: number): string
	-- chat bubbles should be short, so only expose the first few examples
	local clipped = {}
	for index = 1, math.min(#values, limit) do
		table.insert(clipped, values[index])
	end
	return table.concat(clipped, " | ")
end

function CommandRegistry.BuildHelpLines(): { string }
	-- help is built from metadata, not a second manual list
	local movement = collectExamples("movement")
	local actions = collectExamples("action")
	return {
		"movement: " .. joinFirst(movement, 5),
		"actions: " .. joinFirst(actions, 6),
		"ask technical questions too, like explain pathfinding, cframe, raycasts, metatables, or server ownership.",
	}
end

function CommandRegistry.BuildDemoLines(): { string }
	-- the demo chain is intentionally ordered to show movement, pathing, action,
	-- speed tuning, orbiting, then cleanup
	local sequence = {}
	for _, id in { "follow", "move", "go_there", "multi_jump", "speed", "orbit", "stop" } do
		local command = byId[id]
		if command then
			table.insert(sequence, command.example)
		end
	end
	return {
		"demo chain: " .. table.concat(sequence, " -> "),
		"technical chain: explain pathfinding -> explain cframe -> explain raycasts -> what do you remember.",
	}
end

function CommandRegistry.BuildArchitectureLines(): { string }
	-- this explains the actual module split in-game without exposing code noise
	return {
		"architecture: Brain parses chat, SessionStore tracks memory, NpcController owns Roblox movement.",
		"authority: the server validates range, cooldown, and line of sight before any NPC action runs.",
		"reason: parsing and execution stay separated, so changing chat logic does not rewrite movement code.",
	}
end

function CommandRegistry.BuildInternalsLines(): { string }
	-- this is the technical version of help, useful for showing API coverage
	local apiNotes = uniqueApiNotes()
	return {
		"api surface: " .. joinFirst(apiNotes, 6),
		"movement: pathfinding is throttled, and direct MoveTo is used only as fallback when a path fails.",
		"rotation: CFrame.lookAt plus exponential Lerp gives smooth facing without client control.",
	}
end

function CommandRegistry.BuildCommandReply(id: string, direction: string?, seedText: string): string?
	-- replies are generated from the command spec plus deterministic variation
	-- not a huge phrase-by-phrase response table
	local command = byId[id]
	if not command then
		return nil
	end

	local suffix = TextUtil.pick({
		" server checked.",
		" command accepted.",
		" running now.",
		" handled cleanly.",
	}, seedText .. id)

	local reply = string.gsub(command.response, "{direction}", direction or "there")
	return reply .. suffix
end

return CommandRegistry
