
MISSION_CORE_fnc_defenseCoordinator = {
    diag_log "DYNAMIC DEFENSE: coordinator started";
    if (isNil "MISSION_CORE_DEFENSE_ASSIGN") then { MISSION_CORE_DEFENSE_ASSIGN = createHashMap; };
    if (isNil "MISSION_CORE_DEFENSE_LOCKED") then { MISSION_CORE_DEFENSE_LOCKED = createHashMap; };
    if (isNil "MISSION_CORE_SPAWNED_LOCATIONS") then { MISSION_CORE_SPAWNED_LOCATIONS = createHashMap; };
    private _slotsPerSide = ["defenseRingsPerSide", 2] call MISSION_CORE_fnc_tune;
    private _defenseRadius = ["defenseRadius", 1800] call MISSION_CORE_fnc_tune;
    while { true } do {
        sleep 8 + random 5;
        private _players = allPlayers select { alive _x };
        private _playerSides = _players apply { side _x };
        {
            private _side = _x;
            // The player's own side is NOT managed here - its defenses are spawned and renewed by
            // the assault system (fn_aiAssaultLoop) and would otherwise be torn down the instant
            // this coordinator's prune runs (a BLUFOR marker is never "contested" when there is no
            // REDFOR player).
            if (_side in _playerSides) then { continue; };
            private _factionData = if (_side == WEST) then { MISSION_CORE_BLUFOR_DATA } else { MISSION_CORE_REDFOR_DATA };

            // --- Prune defenses that no longer qualify ---
            {
                private _markerName = _x;
                private _defGrp = MISSION_CORE_DEFENSE_ASSIGN get _markerName;
                if (isNull _defGrp) then { MISSION_CORE_DEFENSE_ASSIGN deleteAt _markerName; continue; };
                if (side _defGrp != _side) then { continue; };
                private _loc = MISSION_CORE_CACHED_POSITIONS select { (_x select 0) == _markerName };
                private _locEntry = if (count _loc > 0) then { _loc select 0 } else { [] };
                private _locPos = if (count _locEntry > 1) then { _locEntry select 1 } else { getPos leader _defGrp };
                private _keep = false;
                if (count _locEntry > 0) then {
                    if ((_locEntry select 4) == _side) then {
                        private _spawned = MISSION_CORE_SPAWNED_LOCATIONS getOrDefault [_markerName, false];
                        // Defenses stay while the player is approaching or fighting this marker:
                        // either the marker is actively contested, or a player is still within the
                        // defense radius of it. Once the player leaves both, the ring is despawned.
                        private _contested = [_locPos, _side, _markerName] call MISSION_CORE_fnc_isMarkerContested;
                        private _nearPlayer = _players findIf { _x distance _locPos < _defenseRadius } != -1;
                        if (_spawned && { _contested || _nearPlayer }) then {
                            if ({ alive _x } count units _defGrp > 0) then { _keep = true; };
                        };
                    };
                };
                if (!_keep) then {
                    diag_log format ["DYNAMIC DEFENSE: releasing defenses at %1", _markerName];
                    // No-respawn lock: once a defense group here is gone (killed or released),
                    // don't replace it while the player is still attacking the marker.
                    MISSION_CORE_DEFENSE_LOCKED set [_markerName, time];
                    private _toDelete = [];
                    {
                        if (!isNull _x && { _x getVariable ["MISSION_CORE_DEFENSE_GROUP", false] } && { (_x getVariable ["MISSION_CORE_MARKER_CENTER", [0, 0, 0]]) distance _locPos < 500 }) then {
                            private _vehs = [];
                            { private _v = vehicle _x; if (_v != _x && { alive _v } && { !(_v in _vehs) }) then { _vehs pushBack _v; }; } forEach units _x;
                            { deleteVehicle _x; } forEach units _x;
                            { deleteVehicle _x; } forEach _vehs;
                            deleteGroup _x;
                            _toDelete pushBack _forEachIndex;
                        };
                    } forEach MISSION_CORE_SPAWNED_GROUPS;
                    _toDelete sort false;
                    { MISSION_CORE_SPAWNED_GROUPS deleteAt _x; } forEach _toDelete;
                    MISSION_CORE_DEFENSE_ASSIGN deleteAt _markerName;
                };
            } forEach (keys MISSION_CORE_DEFENSE_ASSIGN);

            // --- Clear no-respawn locks for markers the player has left (no longer contested) ---
            {
                private _lName = _x;
                private _lEntry = (MISSION_CORE_CACHED_POSITIONS select { (_x select 0) == _lName });
                private _lPos = if (count _lEntry > 0) then { (_lEntry select 0) select 1 } else { [0, 0, 0] };
                if (!([_lPos, _side, _lName] call MISSION_CORE_fnc_isMarkerContested)) then { MISSION_CORE_DEFENSE_LOCKED deleteAt _lName; };
            } forEach (keys MISSION_CORE_DEFENSE_LOCKED);

            // --- Assign defenses to the markers a player is approaching or fighting, up to the per-side limit ---
            private _have = (keys MISSION_CORE_DEFENSE_ASSIGN) select {
                !isNull (MISSION_CORE_DEFENSE_ASSIGN get _x) && { side (MISSION_CORE_DEFENSE_ASSIGN get _x) == _side }
            };
            if (count _have >= _slotsPerSide) then { continue; };
            private _candidates = [];
            {
                private _locEntry = _x;
                private _mName = _locEntry select 0;
                if ((_locEntry select 4) == _side && { !(_mName in _have) }) then {
                    // PERMANENT RULE: outposts / powerplants / solar are static tiny garrisons -
                    // they get NO static defenses (bunkers / MG nests / AT) under any path.
                    if ([_locEntry] call MISSION_CORE_fnc_isLightInfrastructure) then { continue; };
                    // Do not re-spawn defenses for a marker the player already cleared while still
                    // attacking it - the enemy can be killed, not replaced.
                    if (_mName in MISSION_CORE_DEFENSE_LOCKED) then { continue; };
                    private _spawned = MISSION_CORE_SPAWNED_LOCATIONS getOrDefault [_mName, false];
                    if (_spawned) then {
                        private _locPos = _locEntry select 1;
                        // Arm the marker's defenses the moment a player gets near - not only after the
                        // player has entered and started engaging. The ring is placed on approach so
                        // the objective looks garrisoned from the start; the prune path releases it
                        // once the player leaves the radius or the fight ends.
                        private _playerNear = _players select { _x distance _locPos < _defenseRadius };
                        if (count _playerNear == 0 && { !([_locPos, _side, _mName] call MISSION_CORE_fnc_isMarkerContested) }) then { continue; };
                        private _aliveDefenders = MISSION_CORE_SPAWNED_GROUPS select {
                            !isNull _x &&
                            { (_x getVariable ["MISSION_CORE_REDFOR", false] || _x getVariable ["MISSION_CORE_BLUFOR", false]) } &&
                            { !(_x getVariable ["MISSION_CORE_DEFENSE_GROUP", false]) } &&
                            { (_x getVariable ["MISSION_CORE_MARKER_CENTER", [0, 0, 0]]) distance _locPos < 500 } &&
                            { { alive _x } count units _x > 0 }
                        };
                        if (count _aliveDefenders > 0 && { count _playerNear > 0 }) then {
                            _candidates pushBack [_locEntry, count _playerNear];
                        };
                    };
                };
            } forEach MISSION_CORE_CACHED_POSITIONS;
            _candidates = [_candidates, [], { (_x select 1) * 5 + ((_x select 0) select 7) }, "DESCEND"] call BIS_fnc_sortBy;
            while { count _have < _slotsPerSide && { count _candidates > 0 } } do {
                private _cand = _candidates select 0;
                _candidates deleteAt 0;
                private _locEntry = _cand select 0;
                private _mName = _locEntry select 0;
                private _locPos = _locEntry select 1;
                private _size = if (count _locEntry > 8) then { _locEntry select 8 } else { [200, 200] };
                private _imp = _locEntry select 7;
                diag_log format ["DYNAMIC DEFENSE: assigning defenses to contested %1 (imp=%2)", _mName, _imp];
                private _defGrp = [_locPos, _size, _side, _factionData, _imp] call MISSION_CORE_fnc_spawnDefenses;
                if (!isNull _defGrp) then {
                    MISSION_CORE_DEFENSE_ASSIGN set [_mName, _defGrp];
                    MISSION_CORE_SPAWNED_GROUPS pushBack _defGrp;
                };
                _have = (keys MISSION_CORE_DEFENSE_ASSIGN) select {
                    !isNull (MISSION_CORE_DEFENSE_ASSIGN get _x) && { side (MISSION_CORE_DEFENSE_ASSIGN get _x) == _side }
                };
            };
        } forEach [WEST, EAST];
    };
};
