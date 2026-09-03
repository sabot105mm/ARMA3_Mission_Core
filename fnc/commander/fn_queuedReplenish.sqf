
MISSION_CORE_fnc_queuedReplenish = {
    params ["_side", "_loc", "_importance", "_locPos", "_locName", "_farDir", "_edgeRadius"];
    if !([_side, "inf", _locPos] call MISSION_CORE_fnc_townCategoryCanUse) exitWith { false };
    if (([_side] call MISSION_CORE_fnc_countFootSquads) >= (["footSquadCapSquads", 10] call MISSION_CORE_fnc_tune)) exitWith { false };
    if ([_locName] call MISSION_CORE_fnc_countReplenishGroups >= (["replenishCapPerMarker", 5] call MISSION_CORE_fnc_tune)) exitWith { false };
    // The marker may have been captured while this spawn sat in the queue - never replenish
    // troops into a marker the players now own.
    private _locNow = (MISSION_CORE_CACHED_POSITIONS select { (_x select 0) == _locName });
    if (count _locNow > 0 && { (_locNow select 0) select 4 != _side }) exitWith { false };
    private _factionData = if (_side == WEST) then { MISSION_CORE_BLUFOR_DATA } else { MISSION_CORE_REDFOR_DATA };
    private _pool = [(_factionData select 17)] call MISSION_CORE_fnc_getInfTemplates;
    if (count _pool == 0) exitWith { false };
    private _template = selectRandom _pool;
    private _markerSize = if (count _loc > 8) then { _loc select 8 } else { [200, 200] };
    private _spawnPositions = [_locPos, _markerSize, _farDir, _edgeRadius, _side] call MISSION_CORE_fnc_findCoveredSpawns;
    private _total = MISSION_CORE_REPLENISH_SPAWN_INDEX getOrDefault [_locName, 0];
    MISSION_CORE_REPLENISH_SPAWN_INDEX set [_locName, _total + 1];
    private _spawnIdx = floor (_total / 5) mod (count _spawnPositions);
    private _spawnPos = (_spawnPositions select _spawnIdx) getPos [random 25, random 360];
    private _grp = [_template select 0, _spawnPos, _side, _factionData select 3, "AWARE", "NORMAL", _importance, _locPos, _markerSize] call MISSION_CORE_fnc_spawnGroup;
    if (isNull _grp) exitWith { false };
    _grp setVariable ["MISSION_CORE_ORIGIN_MARKER", _locName];
    _grp setVariable ["MISSION_CORE_REPLENISH_GROUP", true];
    if (isNil "MISSION_CORE_SPAWNED_GROUPS") then { MISSION_CORE_SPAWNED_GROUPS = []; };
    MISSION_CORE_SPAWNED_GROUPS pushBack _grp;
    // Deferred replenish squads also converge on the contested marker center (group pos ->
    // contested marker center), matching the immediate spawn path. The contested marker is the
    // one closest to a player; multiple players attacking different markers means multiple
    // contested markers.
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
    if (count _cTarget > 0) then {
        [_grp, _cTarget select 1, _cTarget select 2] call MISSION_CORE_fnc_sendCounterAttack;
        diag_log format ["DYNAMIC QUEUE: released queued replenish %1 +%2 men -> contested %3", _locName, _template select 2, _cTarget select 0];
    } else {
        [_grp] call MISSION_CORE_fnc_clearGroupWaypoints;
        private _wp = _grp addWaypoint [_locPos, 60];
        _wp setWaypointType "SAD";
        _wp setWaypointSpeed "NORMAL";
        _wp setWaypointBehaviour "COMBAT";
        _grp setCurrentWaypoint _wp;
        _grp setCombatMode "RED";
        diag_log format ["DYNAMIC QUEUE: released queued replenish %1 +%2 men", _locName, _template select 2];
    };
    true
};
