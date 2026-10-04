
// Stray-group recovery (one tick of the group maintenance loop). For infantry or vehicle groups
// that have strayed off from attacking a contested area: a group committed to
// attack/counterattack/reinforce whose leader has wandered well outside its contested target (and
// lost its assault waypoints) is re-committed with the same sendCounterAttack logic - foot squads
// re-board trucks, vehicles re-drive to the fight.
MISSION_CORE_fnc_strayRecoveryTick = {
    if (isNil "MISSION_CORE_SPAWNED_GROUPS") exitWith {};
    {
        private _side = _x;
        private _sideVar = if (_side == WEST) then { "MISSION_CORE_BLUFOR" } else { "MISSION_CORE_REDFOR" };
        // "Is ANY marker contested?" - answered ONLY by MISSION_CORE_CONTESTED (written solely by
        // fn_isMarkerContested). This gate needs no geometry, just whether the map is empty.
        private _contested = if (isNil "MISSION_CORE_CONTESTED") then { [] } else { keys MISSION_CORE_CONTESTED };
        if (count _contested == 0) then { continue; };
        private _groups = MISSION_CORE_SPAWNED_GROUPS select {
            !isNull _x && { count units _x > 0 } && { _x getVariable [_sideVar, false] } &&
            { (_x getVariable ["MISSION_CORE_ORDER", ""]) in ["attack", "counterattack", "reinforce"] }
        };
        {
            private _grp = _x;
            private _at = _grp getVariable ["MISSION_CORE_ATTACK_TARGET", []];
            if (count _at == 0) then { continue; };
            // _contested holds NAMES (keys MISSION_CORE_CONTESTED), so it cannot be indexed - a name is a
            // string and `select 1` on it is a type error. Join to MISSION_CORE_CACHED_POSITIONS.
            private _mName = "";
            if (!isNil "MISSION_CORE_CACHED_POSITIONS") then {
                private _mIdx = _contested findIf {
                    private _n = _x;
                    private _mi = MISSION_CORE_CACHED_POSITIONS findIf { (_x select 0) == _n };
                    _mi >= 0 && { ((MISSION_CORE_CACHED_POSITIONS select _mi) select 1) distance2D _at < 100 }
                };
                // findIf returns an INDEX (-1 when nothing matched), never the element itself.
                // Assigning it straight into _mName left an integer there, and the `== ""`
                // comparison below threw "Error in expression" on every maintenance tick.
                if (_mIdx >= 0) then { _mName = _contested select _mIdx; };
            };
            if (_mName == "") then { continue; };
            private _ldr = leader _grp;
            if (isNull _ldr || { !(alive _ldr) }) then { continue; };
            private _d = _ldr distance2D _at;
            // Size is index 8 of a cached row (index 2 is typeName).
            private _mRow = MISSION_CORE_CACHED_POSITIONS select (MISSION_CORE_CACHED_POSITIONS findIf { (_x select 0) == _mName });
            private _sz = if (count _mRow > 8 && { ((_mRow select 8) isEqualType []) }) then { _mRow select 8 } else { [200, 200, 0] };
            private _reach = ((_sz select 0) max (_sz select 1)) + 150;
            if (_d <= _reach) then { continue; };

            private _strayed = false;
            // 1. Time-based: foot troops we spawned that are still outside the marker (beyond
            //    its edge + 500m) well after the expected travel time have stalled - re-commit
            private _outside500 = ((_sz select 0) max (_sz select 1)) + 500;
            if ({ !(_x isKindOf "Man") } count units _grp == 0) then {
                private _spawnTime = _grp getVariable ["MISSION_CORE_SPAWN_TIME", -1];
                if (_spawnTime > 0) then {
                    private _spawnPos = _grp getVariable ["MISSION_CORE_SPAWN_POS", _at];
                    private _travelDist = _spawnPos distance2D _at;
                    private _expected = (_travelDist / 5) * 1.5 + 30;
                    if ((time - _spawnTime > _expected) && { _d > _outside500 }) then { _strayed = true; };
                };
            };
            // 2. Waypoint-based: group lost its assault waypoints (current waypoint far from
            //    the target), so legitimately marching squads are never yanked mid-drive
            if (!_strayed) then {
                private _wps = waypoints _grp;
                private _curIdx = currentWaypoint _grp;
                private _nearTarget = false;
                if (_curIdx >= 0 && { _curIdx < count _wps }) then {
                    private _curWp = _wps select _curIdx;
                    if ((waypointPosition _curWp) distance2D _at < (_reach + 300)) then { _nearTarget = true; };
                };
                if (_nearTarget) then { continue; };
                _strayed = true;
            };
            if (!_strayed) then { continue; };
            private _last = _grp getVariable ["MISSION_CORE_STRAY_LAST", 0];
            if (time - _last < 90) then { continue; };
            _grp setVariable ["MISSION_CORE_STRAY_LAST", time];
            diag_log format ["AI STRAY: re-committing %1 %2 (%.0fm from contested %3)", _side, groupId _grp, _d, _mName];
            [_grp, _at, _sz] call MISSION_CORE_fnc_sendCounterAttack;
        } forEach _groups;
    } forEach [WEST, EAST];
};
