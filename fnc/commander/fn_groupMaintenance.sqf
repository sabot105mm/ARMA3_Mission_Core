
// Single consolidated maintenance loop. Replaces the four group-watchdog loops (patrolWatchdog,
// strayRecovery, attackStuckWatchdog, despawnUncontestedNeighbors) and the statusLogger that each
// previously ran their own while{true} thread with a sleep at the top. They are all pure
// "inspect groups, maybe act" bodies with no internal sleeps, so they fold cleanly into one thread
// that gates each sub-task on its own cadence. This cuts five concurrent pollers down to one.
MISSION_CORE_fnc_groupMaintenance = {
    diag_log "AI COMMANDER: group maintenance loop started";
    private _nextPatrol = time;
    private _nextNeighbors = time + 5;
    private _nextStray = time + 10;
    private _nextStuck = time + 15;
    private _nextStatus = time + 20;
    private _nextLongRange = time + 8;
    while { true } do {
        sleep 4;
        if (isNil "MISSION_CORE_SPAWNED_GROUPS") then { continue; };
        // Nothing is on the field - no marker is active - so there is nothing to maintain. The
        // proximity spawner / battle loop put groups back on the map; until then every tick below
        // would only iterate an empty list. Skip until a marker becomes active.
        if (count MISSION_CORE_SPAWNED_GROUPS == 0) then { continue; };
        if (time >= _nextPatrol) then {
            [] call MISSION_CORE_fnc_patrolWatchdogTick;
            _nextPatrol = time + 12 + random 6;
        };
        if (time >= _nextNeighbors) then {
            [] call MISSION_CORE_fnc_despawnUncontestedNeighborsTick;
            _nextNeighbors = time + 15 + random 10;
        };
        if (time >= _nextLongRange) then {
            [] call MISSION_CORE_fnc_longRangeReactionTick;
            _nextLongRange = time + 15 + random 10;
        };
        if (time >= _nextStray) then {
            [] call MISSION_CORE_fnc_strayRecoveryTick;
            _nextStray = time + 35 + random 15;
        };
        if (time >= _nextStuck) then {
            [] call MISSION_CORE_fnc_attackStuckWatchdogTick;
            _nextStuck = time + 25 + random 15;
        };
        if (time >= _nextStatus) then {
            [] call MISSION_CORE_fnc_statusLoggerTick;
            _nextStatus = time + 300;
        };
    };
};
