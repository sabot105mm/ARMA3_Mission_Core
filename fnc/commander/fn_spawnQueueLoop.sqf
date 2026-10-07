
MISSION_CORE_fnc_spawnQueueLoop = {
    diag_log "DYNAMIC QUEUE: started";
    private _lastRun = -1e10;
    MISSION_CORE_QUEUE_STAGE = "start";
    while { true } do {
        // Cheap wakeable wait. The next pass happens when the SOONEST job in the queue comes due -
        // each job's own interest decides its own deadline - rather than on one flat 300s for the
        // whole map. The 2s floor keeps the loop responsive, and an MPKilled event still wakes it
        // immediately; a freed cap slot does NOT bypass a job's due time, because the interval IS
        // the pacing. That is deliberate: a casual provider briefly idles a freed slot instead of
        // popping a burst, which is the entire point of the cadence.
        //
        // STAGE/HEARTBEAT DISCIPLINE: the tick is stamped BOTH here and on every pass of the idle
        // wait below. It has to be - this loop is designed to park in that wait for up to 300s when
        // nothing is queued, so a tick written only on entry would go stale during a legitimately
        // empty queue and the stale check would report a false death. The stage variable is what
        // distinguishes the two: "idle" means the wait is intentional or about to run real work,
        // any other value means that specific phase was in flight when the thread halted.
        MISSION_CORE_QUEUE_LOOP_TICK = time;
        MISSION_CORE_QUEUE_STAGE = "idle";
        while { true } do {
            sleep 2;
            if (isNil "MISSION_CORE_SPAWN_QUEUE") then { MISSION_CORE_SPAWN_QUEUE = []; };
            private _wake = if (isNil "MISSION_CORE_QUEUE_WAKE") then { -1e10 } else { MISSION_CORE_QUEUE_WAKE };
            private _soonest = 1e10;
            {
                private _due = _x param [4, 0];
                if (_due < _soonest) then { _soonest = _due };
            } forEach MISSION_CORE_SPAWN_QUEUE;
            // Not yet due -> wait until it is. Nothing due at all -> re-check in 300s.
            private _interval = if (_soonest > 1e9) then { 300 } else { ((_soonest - time) max 2) };
            if (time - _lastRun >= _interval || { _wake > _lastRun }) exitWith {};
            // Heartbeat inside the wait as well, otherwise a legitimately empty queue parks this
            // thread for 300s and the stale check reports a false death every time it looks.
            MISSION_CORE_QUEUE_LOOP_TICK = time;
        };
        if (isNil "MISSION_CORE_SPAWN_QUEUE") then { MISSION_CORE_SPAWN_QUEUE = []; };
        if (count MISSION_CORE_SPAWN_QUEUE == 0) then { _lastRun = time; continue; };
        MISSION_CORE_QUEUE_LOOP_TICK = time;
        MISSION_CORE_QUEUE_STAGE = "scoring";
        // Contested markers get first claim on the next freed foot slot. A queued armor job
        // whose side has zero armor left alive jumps the queue entirely (spawn it next). The
        // priority is computed into a scored list first - private variables are unreliable
        // inside sort comparators, which caused an "Undefined variable: _pos" error here.
        private _scored = [];
        {
            private _f = _x select 0;
            private _a = _x select 2;
            private _pos = [0, 0, 0];
            private _owner = WEST;
            switch (_f) do {
                case "MISSION_CORE_fnc_queuedReplenish": { _pos = _a param [3, [0,0,0]]; _owner = _a param [0, WEST]; };
                case "MISSION_CORE_fnc_queuedReinforce": { _pos = _a param [5, [0,0,0]]; _owner = _a param [0, WEST]; };
                case "MISSION_CORE_fnc_queuedCounterAttackInf": { _pos = _a param [8, [0,0,0]]; _owner = _a param [0, WEST]; };
                case "MISSION_CORE_fnc_queuedCounterAttackTank": { _pos = _a param [8, [0,0,0]]; _owner = _a param [0, WEST]; };
                case "MISSION_CORE_fnc_queuedArmorReinf": { _pos = _a param [1, [0,0,0]]; _owner = _a param [0, WEST]; };
                // Hunt: _pos/_owner are only used by the priority test, which a hunt is excluded
                // from. Still filled in truthfully for the logs.
                case "MISSION_CORE_fnc_queuedHuntContingent": { _pos = _a param [7, [0,0,0]]; _owner = _a param [3, WEST]; };
            };
            private _prio = 1;
            // A player hunt is strictly LAST. The sort below is ASCEND, so LOWER runs FIRST:
            // -1 armor-critical jump, 0 contested-marker work, 1 ordinary, 2 hunt. It used to be
            // -2, which ASCEND put at the very FRONT - hunts outranked the armor jump and every
            // marker job, the exact opposite of what the comment claimed. It is pinned here and
            // EXCLUDED from the contested-marker test below, because that test would otherwise
            // lift a hunt whose source marker is contested up to 0, i.e. above ordinary
            // replenish/reinforce work - also backwards. A hunt is never more urgent than the
            // marker work it would be stealing slots from.
            private _isHunt = _f == "MISSION_CORE_fnc_queuedHuntContingent";
            if (_isHunt) then { _prio = 2; };
            if (!_isHunt) then {
                if (_f == "MISSION_CORE_fnc_queuedArmorReinf" || _f == "MISSION_CORE_fnc_queuedCounterAttackTank") then {
                    private _armor = [_owner] call MISSION_CORE_fnc_countSideArmor;
                    if ((_armor select 0) == 0 && { (_armor select 1) == 0 }) then { _prio = -1; };
                };
                if (_prio == 1 && { [_pos, _owner, "", "spawnQueueLoop"] call MISSION_CORE_fnc_isMarkerContested }) then { _prio = 0; };
            };
            _scored pushBack [_prio, _x];
        } forEach MISSION_CORE_SPAWN_QUEUE;
        _scored = [_scored, [], { _x select 0 }, "ASCEND"] call BIS_fnc_sortBy;
        MISSION_CORE_SPAWN_QUEUE = _scored apply { _x select 1 };
        private _remaining = [];
        private _lastMarker = "";
        // Iterate a SNAPSHOT. fn_queuedCounterAttackInf enqueues its own successor while this pass
        // is still running, and the old `forEach MISSION_CORE_SPAWN_QUEUE` + `_remaining` overwrite
        // silently deleted every job added mid-pass - which truncated each provider's sequence to a
        // single squad and looked exactly like the queue "ignoring" the rest of a provider's men.
        private _pass = +MISSION_CORE_SPAWN_QUEUE;
        // Retry delay after a REAL cap denial. Without this a denied job is still "due", so the
        // wake interval would collapse to its 2s floor and it would be re-tested every 2s instead
        // of every 30s - 15x the countFootSquads/countSideArmor calls, and the 60-attempt budget
        // would expire in ~2 minutes rather than the intended half hour. Cadence paces the
        // SEQUENCE; this paces a job that is merely blocked.
        private _retryDelay = ["reinfQueueRetryDelay", 20] call MISSION_CORE_fnc_tune;
        MISSION_CORE_QUEUE_LOOP_TICK = time;
        MISSION_CORE_QUEUE_STAGE = "dispatch";
        {
            _x params ["_fncName", "_key", "_args", "_attempts"];
            if (isNil "_args") then { _args = []; };
            // INTEREST CADENCE GATE. Not due yet is NOT a denial: the job is returned to the queue
            // untouched, without calling the handler, without spending one of its 60 attempts, and
            // without consuming the inter-marker 5s gap. Only a real cap denial (the handler
            // returning false) increments _attempts, so a slow provider waits its turn without
            // slowly burning down its own retry budget and being dropped while it is merely early.
            private _due = _x param [4, 0];
            if (_due > time) then {
                _remaining pushBack _x;
                continue;
            };
            // Identify which marker this queued job belongs to so consecutive jobs from the same
            // marker spawn together and the 5s breathing gap lands between different markers.
            private _marker = switch (_fncName) do {
                case "MISSION_CORE_fnc_queuedReplenish": { _args param [4, ""] };
                case "MISSION_CORE_fnc_queuedReinforce": { _args param [7, ""] };
                case "MISSION_CORE_fnc_queuedCounterAttackInf": { _args param [7, ""] };
                case "MISSION_CORE_fnc_queuedCounterAttackTank": { _args param [7, ""] };
                case "MISSION_CORE_fnc_queuedArmorReinf": { _args param [2, ""] };
                case "MISSION_CORE_fnc_queuedHuntContingent": { _args param [6, ""] };
                default { "" };
            };
            // 5s pause after a marker's whole queue has spawned before the next marker's jobs run
            if (_marker != _lastMarker && { _lastMarker != "" }) then { sleep 5; };
            _lastMarker = _marker;
            private _fnc = missionNamespace getVariable [_fncName, {}];
            private _ok = false;
            MISSION_CORE_QUEUE_LOOP_TICK = time;
            MISSION_CORE_QUEUE_STAGE = format ["handler:%1", _fncName];
            try {
                _ok = _args call _fnc;
            } catch {
                diag_log format ["DYNAMIC QUEUE: dropped %1 (key %2) after error: %3", _fncName, _key, _exception];
                _ok = true;
            };
            if (_ok) then {
                diag_log format ["DYNAMIC QUEUE: spawned %1 (key %2)", _fncName, _key];
            } else {
                // A false result usually means "cap full, wait for KIA to free a slot" - keep the
                // job alive before giving up so counter-attacks and reinforcements don't evaporate
                // just because the cap is momentarily full. The wait between those attempts is
                // reinfQueueRetryDelay, NOT the interest cadence: interest paces how fast a willing
                // provider walks squads out, while this paces a job that is blocked. 60 attempts at
                // the 20s default is the ~20 minutes the drop threshold is meant to represent.
                _attempts = (_x param [3, 0]) + 1;
                if (_attempts >= 60) then {
                    diag_log format ["DYNAMIC QUEUE: dropped %1 (key %2) - gave up after %3 attempts", _fncName, _key, _attempts];
                } else {
                    _x set [3, _attempts];
                    _x set [4, time + _retryDelay];
                    _remaining pushBack _x;
                };
            };
            // 0.4s gap between queued group spawns so caps re-check accurately and the map never
            // pops a whole batch of groups in the same second.
            sleep 0.4;
        } forEach _pass;
        // Keep the jobs that denied a cap, PLUS anything enqueued during this pass. Matching on
        // key (not array equality) so a re-queued successor is never confused with a retained job.
        private _passKeys = _pass apply { _x select 1 };
        MISSION_CORE_SPAWN_QUEUE = _remaining + (MISSION_CORE_SPAWN_QUEUE select { !((_x select 1) in _passKeys) });
        _lastRun = time;
    };
};
