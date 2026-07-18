-- Connected Discord-GitHub
--!strict

--[[ all settings for the dummy are kept here
this means i can change chat limits movement and reply timing without searching each module
NpcController uses the movement values and the main script uses the chat values ]]
local Config = {
	-- use this model name or make an R15 dummy at the spawn point if it is missing
	DummyName = "AIDummy",
	DisplayName = "Roufox",
	SpawnCFrame = CFrame.new(0, 4, -14),

	-- the server checks range sight cooldown and message size before Brain handles the chat
	ChatRange = 95,
	FaceRange = 90,
	LineOfSightRange = 105,
	ReplyCooldown = 0.55,
	MaxMessageLength = 190,
	MemoryLimit = 10,

	-- players can change speed through chat so i keep it between these two limits
	WalkSpeed = 13,
	MinWalkSpeed = 6,
	MaxWalkSpeed = 38,
	JumpPower = 52,

	-- follow stops at one distance and only starts again after the player moves farther away
	-- using two values stops the dummy from moving back and forth near the player
	FollowStopDistance = 10,
	FollowResumeDistance = 14,
	MoveStepDistance = 10,
	MaxDirectedMove = 48,
	GoThereDistance = 78,

	-- path refresh stops PathfindingService from running every frame
	-- the two turn values control looking while idle and while moving
	PathRefreshSeconds = 0.42,
	PathGoalEpsilon = 3.5,
	IdleTurnResponsiveness = 8.5,
	MovingTurnResponsiveness = 5.8,

	-- the reply delay is kept between these values so chat still feels quick
	ThinkingSecondsMin = 0.16,
	ThinkingSecondsMax = 0.72,
}

return table.freeze(Config)
