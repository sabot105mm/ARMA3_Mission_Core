
// Keep only the nearest N spawned markers active per enemy side. The furthest spawned markers are
// fully despawned (garrison + defenses + any counter-attack / reinforce groups launched from or
// marching to them). A deactivated marker no longer acts as a counter-attack / reinforce source.
MISSION_CORE_fnc_deactivateFarMarkers = {
    private _players = allPlayers select { alive _x };
    if (count _players == 0) exitWith {};
    if (isNil "MISSION_CORE_SPAWNED_LOCATIONS") exitWith {};
    if (isNil "MISSION_CORE_SPAWNED_GROUPS") exitWith { MISSION_CORE_SPAWNED_GROUPS = []; };
    private _maxActive = 6;
    private _playerSides = _players apply { side _x };
    {
        private _side = _x;
        // Skip the player's own side - players defend their own markers
        if (_side in _playerSides) then { continue; };
        private _spawned = MISSION_CORE_CACHED_POSITIONS select {
            (_x select 4) == _side &&
            { MISSION_CORE_SPAWNED_LOCATIONS getOrDefault [_x select 0, false] }
        };
        if (count _spawned <= _maxActive) then { continue; };
        private _withDist = _spawned apply {
            private _locPos2 = _x select 1;
            private _d = 99999;
            { _d = _d min (_x distance _locPos2); } forEach _players;
            [_x, _d]
        };
        _withDist = [_withDist, [], { _x select 1 }, "ASCEND"] call BIS_fnc_sortBy;
        for "_i" from _maxActive to (count _withDist - 1) do {
            private _loc = (_withDist select _i) select 0;
            private _locName = _loc select 0;
            private _locPos = _loc select 1;
            diag_log format ["DYNAMIC SPAWN: deactivating %1 (too far, %2 active)", _locName, _maxActive];
            [_locName, _locPos] call MISSION_CORE_fnc_despawnLocation;
        };
    } forEach [WEST, EAST];
};
