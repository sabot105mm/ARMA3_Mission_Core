// REDFOR RECAPTURE: a player-held marker that sits UNGUARDED - zero living player-side
// units (garrison or player) inside its footprint - can be taken back by the enemy
// once an ORDERED attack squad physically walks into it. Mirrors the occupation-revert
// test in fn_occupationMonitor (counterattack/attack order aimed at the marker center
// within neighborRange); random patrols and retreat columns never flip a point.
//
// Why it exists: the deactivation teardown (fn_deactivateNeighborMarkers ->
// fn_despawnLocation) puts a marker's neighborhood to sleep. The marker itself now
// STAYS on the map (despawn no longer hides it), and this loop keeps it CAPTURABLE -
// "if no one is guarding it the enemy takes it back" - instead of a deactivated marker
// being untouchable by both sides forever.
//
// Guards, deliberately strict:
//   - The marker must be owned by a PLAYER side. AI-vs-AI markers are decided by the
//     replenish loop / assaults, not here.
//   - It must NOT be in the occupation hold phase (fn_occupationMonitor owns that).
//   - ZERO living player-side units inside the ellipse - a player standing on their own
//     point can never be stolen from under them.
//   - An ordered enemy counter-attack/assault squad must be physically inside the
//     ellipse. Only that counts as "trying to take it back".
// A direct flip (no occupation hold): the marker reverts to the enemy with zero
// manpower/commit, exactly like the occupation monitor's revert. The player retakes by
// fighting normally again - the garrison respawns the moment a player approaches.
MISSION_CORE_fnc_redforRecaptureLoop = {
    while { true } do {
        sleep 8;
        [] call MISSION_CORE_fnc_redforRecaptureTick;
    };
};

MISSION_CORE_fnc_redforRecaptureTick = {
    if (isNil "MISSION_CORE_CACHED_POSITIONS") exitWith {};
    if (!(MISSION_CORE_CACHED_POSITIONS isEqualType [])) exitWith {};
    if (isNil "MISSION_CORE_OCCUPATION") then { MISSION_CORE_OCCUPATION = createHashMap; };
    if (isNil "MISSION_CORE_MANPOWER") then { MISSION_CORE_MANPOWER = createHashMap; };
    if (isNil "MISSION_CORE_COMMIT") then { MISSION_CORE_COMMIT = createHashMap; };
    if (isNil "MISSION_CORE_MANPOWER_CUTOFF") then { MISSION_CORE_MANPOWER_CUTOFF = createHashMap; };
    if (isNil "MISSION_CORE_SPAWNED_LOCATIONS") then { MISSION_CORE_SPAWNED_LOCATIONS = createHashMap; };
    // This mission pits BLUFOR players against REDFOR AI. With nobody connected the
    // empty list must not silently disable the whole feature, so default to BLUFOR.
    private _playerSides = (allPlayers select { alive _x }) apply { side _x };
    if (count _playerSides == 0) then { _playerSides = [WEST]; };
    {
        private _rec = _x;
        if (!(_rec isEqualType [])) then { continue; };
        if (count _rec < 9) then { continue; };
        private _locName = _rec select 0;
        if !(_locName isEqualType "") then { continue; };
        private _locPos = _rec select 1;
        private _owner = _rec select 4;
        // Only player-held markers can be given back - this never judges AI-vs-AI ground.
        if (!(_owner in _playerSides)) then { continue; };
        // Occupation hold has its own revert logic in fn_occupationMonitor.
        if (_locName in MISSION_CORE_OCCUPATION) then { continue; };
        private _mSize = _rec select 8;
        private _ma = (_mSize param [0, 200]) max 1;
        private _mb = (_mSize param [1, 200]) max 1;
        private _md = _mSize param [2, 0];
        private _inside = {
            params ["_p"];
            private _dx = (_p select 0) - (_locPos select 0);
            private _dy = (_p select 1) - (_locPos select 1);
            private _rx = _dx * cos _md - _dy * sin _md;
            private _ry = _dx * sin _md + _dy * cos _md;
            ((_rx * _rx) / (_ma * _ma)) + ((_ry * _ry) / (_mb * _mb)) <= 1
        };
        // NO ONE GUARDING: any living player-side unit - garrison soldier or player -
        // inside the ellipse blocks the flip instantly.
        private _defended = false;
        {
            if (alive _x && { side _x == _owner }) then {
                if ([getPos _x] call _inside) exitWith { _defended = true; };
            };
        } forEach allUnits;
        if (_defended) then { continue; };
        // ONLY ORDERED ATTACK SQUADS COUNT: counterattack/attack order aimed at this
        // marker within neighbor range, physically inside. Same test the occupation
        // monitor uses for its revert - a random patrol or a retreating column never
        // takes a point.
        private _enemySide = if (_owner == WEST) then { EAST } else { WEST };
        private _attackerIn = false;
        {
            if (side _x != _enemySide) then { continue; };
            if !((_x getVariable ["MISSION_CORE_ORDER", ""]) in ["counterattack", "attack"]) then { continue; };
            private _at = _x getVariable ["MISSION_CORE_ATTACK_TARGET", [0, 0, 0]];
            if (count _at < 2) then { continue; };
            if (_at distance2D _locPos > (["neighborRange", 4000] call MISSION_CORE_fnc_tune)) then { continue; };
            if ({ alive _x && { [getPos _x] call _inside } } count units _x > 0) exitWith { _attackerIn = true; };
        } forEach allGroups;
        if (!_attackerIn) then { continue; };
        // Flip. Direct, like the occupation revert: no hold phase, no defender spawns,
        // empty budget - the point is the enemy's again and the player must walk back in.
        diag_log format ["DYNAMIC CAPTURE: %1 recaptured by %2 (unguarded + ordered attack squad inside)", _locName, _enemySide];
        [_locName, _enemySide] call MISSION_CORE_fnc_setMarkerOwner;
        MISSION_CORE_SPAWNED_LOCATIONS set [_locName, false];
        MISSION_CORE_MANPOWER set [_locName, []];
        MISSION_CORE_COMMIT set [_locName, 0];
        MISSION_CORE_MANPOWER_CUTOFF deleteAt _locName;
        ["DynOps_MarkerLost",
            ["MARKER LOST", format ["%1 was recaptured by the enemy.", _locName]]
        ] remoteExec ["BIS_fnc_showNotification", 0];
    } forEach MISSION_CORE_CACHED_POSITIONS;
};