
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
    private _nextHeartbeat = time + 45;
    while { true } do {
        sleep 4;
        // LOOP LIVENESS CHECK. Placed BEFORE the two early continues below, deliberately: both of
        // them exit when the field is empty or uninitialised, and a halted convoy/queue thread is
        // exactly as dead during an empty field as a busy one. Gating this on marker activity
        // would mean the symptom only appears when there is already work to lose.
        //
        // Detection only - this writes no restart. The ammo loop has its own supervisor that
        // recovers it, so it is deliberately not listed here; two witnesses would disagree about
        // the same stall and only one of them acts. Reports age and the last stage reached, which
        // is what turns "the loop stopped" into "it stopped inside handler:queuedArmorReinf".
        if (time >= _nextHeartbeat) then {
            {
                _x params ["_tickVar", "_stageVar", "_label"];
                private _tick = missionNamespace getVariable [_tickVar, -1e10];
                private _stale = round (time - _tick);
                // The first check runs 45s in, long enough for every listed loop to have stamped at
                // least once. A negative age means the variable was never written at all - the
                // function was never spawned, which is a compile-order failure, not a stall, and
                // the stage reports "never-started" to say so.
                if (_stale > 90) then {
                    diag_log format ["HEARTBEAT: %1 silent for %2s (threshold %3s) - last stage: %4%5",
                        _label, _stale, 90,
                        missionNamespace getVariable [_stageVar, "never-started"],
                        if (_tick < 0) then { " [never stamped]" } else { "" }];
                };
            } forEach [
                ["MISSION_CORE_CONVOY_LOOP_TICK", "MISSION_CORE_CONVOY_STAGE", "DYNAMIC CONVOY loop"],
                ["MISSION_CORE_QUEUE_LOOP_TICK", "MISSION_CORE_QUEUE_STAGE", "DYNAMIC QUEUE loop"],
                // The supervisor, not the ammo loop. The supervisor already reports and recovers a
                // stalled ammo loop itself, so listing the loop here would mostly print noise right
                // before the supervisor's own line. What has no other watcher is the supervisor -
                // if it halts, ammo stops recovering silently. Its stage is always "running"; the
                // tick alone is the signal.
                ["MISSION_CORE_AMMO_SUPERVISOR_TICK", "MISSION_CORE_AMMO_SUPERVISOR_STAGE", "AMMO supervisor"]
            ];
            _nextHeartbeat = time + 30;
        };
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
