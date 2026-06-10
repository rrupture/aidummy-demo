--!strict

-- all tuning lives here so the controller code does not get full of random
-- magic numbers. changing npc feel should be one small config edit.
local Config = {
	DummyName = "AIDummy",
	DisplayName = "Roufox",
	SpawnCFrame = CFrame.new(0, 4, -14),

	ChatRange = 90,
	FaceRange = 85,
	LineOfSightRange = 100,
	ReplyCooldown = 0.65,
	MaxMessageLength = 180,
	MemoryLimit = 8,

	WalkSpeed = 12,
	MinWalkSpeed = 6,
	MaxWalkSpeed = 36,
	JumpPower = 50,
	MinJumpPower = 35,
	MaxJumpPower = 125,

	FollowStopDistance = 10,
	FollowResumeDistance = 14,
	PathRefreshSeconds = 0.45,
	PathGoalEpsilon = 3.5,
	PathWaypointEpsilon = 3.2,
	MoveStepDistance = 9,
	MaxDirectedMove = 45,
	GoThereDistance = 70,

	IdleTurnResponsiveness = 8.5,
	MovingTurnResponsiveness = 5.5,
	ThinkingSecondsMin = 0.18,
	ThinkingSecondsMax = 0.75,
}

return table.freeze(Config)
