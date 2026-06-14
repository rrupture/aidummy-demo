--!strict

-- Central config keeps tuning values away from logic. Movement feel, cooldowns,
-- and chat limits can be changed without digging through controller methods.
local Config = {
	-- identity / default spawn
	-- if a custom rig named AIDummy exists, the controller uses it
	-- otherwise it creates a runtime R15 dummy at this CFrame
	DummyName = "AIDummy",
	DisplayName = "Roufox",
	SpawnCFrame = CFrame.new(0, 4, -14),

	-- chat authority limits
	-- range and line of sight stop far-away players from controlling the NPC
	-- cooldown keeps repeated chat from doing expensive parsing/action work
	ChatRange = 95,
	FaceRange = 90,
	LineOfSightRange = 105,
	ReplyCooldown = 0.55,
	MaxMessageLength = 190,
	MemoryLimit = 10,

	-- humanoid movement feel
	-- min/max caps matter because players can ask for speed changes through chat
	WalkSpeed = 13,
	MinWalkSpeed = 6,
	MaxWalkSpeed = 38,
	JumpPower = 52,

	-- spacing / directed movement
	-- follow uses two distances to avoid jitter around the exact stop distance
	FollowStopDistance = 10,
	FollowResumeDistance = 14,
	MoveStepDistance = 10,
	MaxDirectedMove = 48,
	GoThereDistance = 78,

	-- pathing and animation tuning
	-- refresh is not instant on purpose, PathfindingService should not run every frame
	PathRefreshSeconds = 0.42,
	PathGoalEpsilon = 3.5,
	IdleTurnResponsiveness = 8.5,
	MovingTurnResponsiveness = 5.8,

	-- reply pacing
	-- gives the dummy a short thinking beat without making chat feel delayed
	ThinkingSecondsMin = 0.16,
	ThinkingSecondsMax = 0.72,
}

return table.freeze(Config)
