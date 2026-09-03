
MISSION_CORE_fnc_spawnQueueLoop = {
    diag_log "DYNAMIC QUEUE: started";
    private _lastRun = -1e10;
    while { true } do {
        // Cheap wakeable wait: run the queue every 30s, or immediately when an MPKilled event
        // stamped MISSION_CORE_QUEUE_WAKE (a foot-squad/MBT cap slot may have just freed).
        while { true } do {
            sleep 2;
            private _wake = if (isNil "MISSION_CORE_QUEUE_WAKE") then { -1e10 } else { MISSION_CORE_QUEUE_WAKE };
            if (time - _lastRun >= 30 || { _wake > _lastRun }) exitWith {};
        };
        if (isNil "MISSION_CORE_SPAWN_QUEUE") then { MISSION_CORE_SPAWN_QUEUE = []; };
        if (count MISSION_CORE_SPAWN_QUEUE == 0) then { _lastRun = time; continue; };
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
            };
            private _prio = 1;
            if (_f == "MISSION_CORE_fnc_queuedArmorReinf" || _f == "MISSION_CORE_fnc_queuedCounterAttackTank") then {
                private _armor = [_owner] call MISSION_CORE_fnc_countSideArmor;
                if ((_armor select 0) == 0 && { (_armor select 1) == 0 }) then { _prio = -1; };
            };
            if (_prio == 1 && { [_pos, _owner] call MISSION_CORE_fnc_isMarkerContested }) then { _prio = 0; };
            _scored pushBack [_prio, _x];
        } forEach MISSION_CORE_SPAWN_QUEUE;
        _scored = [_scored, [], { _x select 0 }, "ASCEND"] call BIS_fnc_sortBy;
        MISSION_CORE_SPAWN_QUEUE = _scored apply { _x select 1 };
        private _remaining = [];
        private _lastMarker = "";
        {
            _x params ["_fncName", "_key", "_args", "_attempts"];
            if (isNil "_args") then { _args = []; };
            // Identify which marker this queued job belongs to so consecutive jobs from the same
            // marker spawn together and the 5s breathing gap lands between different markers.
            private _marker = switch (_fncName) do {
                case "MISSION_CORE_fnc_queuedReplenish": { _args param [4, ""] };
                case "MISSION_CORE_fnc_queuedReinforce": { _args param [7, ""] };
                case "MISSION_CORE_fnc_queuedCounterAttackInf": { _args param [7, ""] };
                case "MISSION_CORE_fnc_queuedCounterAttackTank": { _args param [7, ""] };
                case "MISSION_CORE_fnc_queuedArmorReinf": { _args param [2, ""] };
                default { "" };
            };
            // 5s pause after a marker's whole queue has spawned before the next marker's jobs run
            if (_marker != _lastMarker && { _lastMarker != "" }) then { sleep 5; };
            _lastMarker = _marker;
            private _fnc = missionNamespace getVariable [_fncName, {}];
            private _ok = false;
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
                // job alive up to 30 minutes (60 tries x 30s) before giving up so counter-attacks
                // and reinforcements don't evaporate just because the cap is momentarily full.
                _attempts = (_x param [3, 0]) + 1;
                if (_attempts >= 60) then {
                    diag_log format ["DYNAMIC QUEUE: dropped %1 (key %2) - gave up after %3 attempts", _fncName, _key, _attempts];
                } else {
                    _x set [3, _attempts];
                    _remaining pushBack _x;
                };
            };
            // 0.4s gap between queued group spawns so caps re-check accurately and the map never
            // pops a whole batch of groups in the same second.
            sleep 0.4;
        } forEach MISSION_CORE_SPAWN_QUEUE;
        MISSION_CORE_SPAWN_QUEUE = _remaining;
        _lastRun = time;
    };
};
