
// Spawn a batch of reinforcements at a covered spot (forest/building inside the marker, away from
// the nearest player) and march them to the marker center / contested area
MISSION_CORE_fnc_replenishMarker = {
    params ["_loc", "_side", "_importance", "_alive", "_capacity", ["_mpBudget", 1e9]];
    private _locName = _loc select 0;
    private _locPos = _loc select 1;
    private _markerSize = if (count _loc > 8) then { _loc select 8 } else { [200, 200] };
    private _factionData = if (_side == WEST) then { MISSION_CORE_BLUFOR_DATA } else { MISSION_CORE_REDFOR_DATA };
    private _allGroups = _factionData select 17;
    private _nearestP = objNull;
    private _nearestD = 999999;
    {
        private _d = _x distance _locPos;
        if (_d < _nearestD) then { _nearestD = _d; _nearestP = _x; };
    } forEach (allPlayers select { alive _x });
    private _farDir = if (!isNull _nearestP) then { (_nearestP getDir _locPos) + 180 } else { random 360 };
    // Spawn inside the marker at a forest/building spot when available (never popping into the
    // players' sight), otherwise just beyond the marker edge. Always on the side of the marker
    // that faces AWAY from the nearest player.
    private _edgeRadius = ((_markerSize select 0) max (_markerSize select 1)) + 75;
    private _missing = (_capacity - _alive) max 1;
    // Manpower is 1-for-1: a marker only fields the men its funding base actually delivered.
    private _toSpawn = ((_missing min 8) min _mpBudget) max 0;
    if (_toSpawn <= 0) exitWith { 0 };
    private _replCount = [_locName] call MISSION_CORE_fnc_countReplenishGroups;
    if (_replCount >= 5) exitWith {
        diag_log format ["DYNAMIC REPLENISH: %1 at dynamic replenish cap (%2/5 alive)", _locName, _replCount];
        0
    };
    private _pool = [_allGroups] call MISSION_CORE_fnc_getInfTemplates;
    if (count _pool == 0) exitWith { 0 };
    private _spawned = 0;
    // Global foot budget cap or town cap full: queue the replenish to spawn when men free up.
    if (!([_side, "inf", _locPos] call MISSION_CORE_fnc_townCategoryCanUse) || { ([_side] call MISSION_CORE_fnc_countFootSquads) >= (["footSquadCapSquads", 10] call MISSION_CORE_fnc_tune) }) then {
        ["MISSION_CORE_fnc_queuedReplenish", format ["repl_%1", _locName], [_side, _loc, _importance, _locPos, _locName, _farDir, _edgeRadius]] call MISSION_CORE_fnc_enqueueSpawn;
        diag_log format ["DYNAMIC REPLENISH: %1 queued (global foot %2/%3)", _locName, [_side] call MISSION_CORE_fnc_countFootSquads, ["footSquadCapSquads", 10] call MISSION_CORE_fnc_tune];
        0
    } else {
    // Replenished squads converge on the contested marker center (group pos -> contested marker
    // center). The contested marker is the one closest to a player; multiple players attacking
    // different markers means multiple contested markers.
    private _spawnPositions = [_locPos, _markerSize, _farDir, _edgeRadius, _side] call MISSION_CORE_fnc_findCoveredSpawns;
    private _contestedList = [_side] call MISSION_CORE_fnc_getContestedMarkers;
    private _cTarget = [];
    if (count _contestedList > 0) then {
        private _playersA = allPlayers select { alive _x };
        if (count _playersA > 0) then {
            private _bestPD = 1e10;
            {
                private _mPos = _x select 1;
                private _pd = 1e10;
                { private _d = _x distance _mPos; if (_d < _pd) then { _pd = _d; }; } forEach _playersA;
                if (_pd < _bestPD) then { _bestPD = _pd; _cTarget = _x; };
            } forEach _contestedList;
        };
    };
    while { _toSpawn > 0 } do {
        if (([_side] call MISSION_CORE_fnc_countFootSquads) >= (["footSquadCapSquads", 10] call MISSION_CORE_fnc_tune)) exitWith {};
        if ([_locName] call MISSION_CORE_fnc_countReplenishGroups >= (["replenishCapPerMarker", 5] call MISSION_CORE_fnc_tune)) exitWith {};
        private _template = selectRandom _pool;
        private _unitCount = _template select 2;
        private _total = MISSION_CORE_REPLENISH_SPAWN_INDEX getOrDefault [_locName, 0];
        MISSION_CORE_REPLENISH_SPAWN_INDEX set [_locName, _total + 1];
        private _spawnIdx = floor (_total / 5) mod (count _spawnPositions);
        private _spawnPos = (_spawnPositions select _spawnIdx) getPos [random 25, random 360];
        private _grp = [_template select 0, _spawnPos, _side, _factionData select 3, "AWARE", "NORMAL", _importance, _locPos, _markerSize] call MISSION_CORE_fnc_spawnGroup;
        if (isNull _grp) exitWith {};
        _grp setVariable ["MISSION_CORE_ORIGIN_MARKER", _locName];
        _grp setVariable ["MISSION_CORE_REPLENISH_GROUP", true];
        if (isNil "MISSION_CORE_SPAWNED_GROUPS") then { MISSION_CORE_SPAWNED_GROUPS = []; };
        MISSION_CORE_SPAWNED_GROUPS pushBack _grp;
        _spawned = _spawned + _unitCount;
        _toSpawn = _toSpawn - _unitCount;
        if (count _cTarget > 0) then {
            [_grp, _cTarget select 1, _cTarget select 2] call MISSION_CORE_fnc_sendCounterAttack;
            diag_log format ["DYNAMIC REPLENISH: %1 +%2 men (%3) -> contested %4 (%5m from group)", _locName, _unitCount, _template select 0, _cTarget select 0, round (_spawnPos distance (_cTarget select 1))];
        } else {
            [_grp] call MISSION_CORE_fnc_clearGroupWaypoints;
            private _wp = _grp addWaypoint [_locPos, 60];
            _wp setWaypointType "SAD";
            _wp setWaypointSpeed "NORMAL";
            _wp setWaypointBehaviour "COMBAT";
            _grp setCurrentWaypoint _wp;
            _grp setCombatMode "RED";
            diag_log format ["DYNAMIC REPLENISH: %1 +%2 men (%3) from %4m edge -> center", _locName, _unitCount, _template select 0, round _edgeRadius];
        };
        // 0.4s breathing room between squad spawns so the garrison trickles in instead of
        // popping several squads at once and the global foot/cap re-checks stay accurate.
        sleep 0.4;
    };
    _spawned
    };
};
