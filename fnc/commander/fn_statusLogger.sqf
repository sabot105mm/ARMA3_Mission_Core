
// Periodic status log (one tick of the group maintenance loop): report how many enemy (REDFOR)
// tanks and groups are alive, plus BLUFOR for comparison, and manpower left per contested marker.
// Lightweight diagnostic aid.
MISSION_CORE_fnc_statusLoggerTick = {
    private _enemyTanks = 0;
    private _enemyVehs = 0;
    private _bluTanks = 0;
    private _bluVehs = 0;
    private _enemyGroups = 0;
    private _bluGroups = 0;
    {
        private _v = _x;
        if (alive _v && { _v isKindOf "LandVehicle" }) then {
            if (side _v == EAST) then {
                _enemyVehs = _enemyVehs + 1;
                if (_v isKindOf "Tank") then { _enemyTanks = _enemyTanks + 1; };
            };
            if (side _v == WEST) then {
                _bluVehs = _bluVehs + 1;
                if (_v isKindOf "Tank") then { _bluTanks = _bluTanks + 1; };
            };
        };
    } forEach vehicles;
    {
        if (!isNull _x && { { alive _x } count units _x > 0 }) then {
            if (_x getVariable ["MISSION_CORE_REDFOR", false]) then { _enemyGroups = _enemyGroups + 1; };
            if (_x getVariable ["MISSION_CORE_BLUFOR", false]) then { _bluGroups = _bluGroups + 1; };
        };
    } forEach allGroups;
    diag_log format ["DYNAMIC STATUS: REDFOR tanks=%1 vehicles=%2 groups=%3 | BLUFOR tanks=%4 vehicles=%5 groups=%6", _enemyTanks, _enemyVehs, _enemyGroups, _bluTanks, _bluVehs, _bluGroups];

    // Manpower left per contested REDFOR marker: capacity minus commit, plus any manpower
    // credits still in flight, and the garrison still alive.
    // WHICH markers are contested comes ONLY from MISSION_CORE_CONTESTED (written solely by
    // fn_isMarkerContested); the per-marker row printed below - name, pos, size - is
    // MISSION_CORE_CACHED_POSITIONS, a separate var answering a separate question.
    if (isNil "MISSION_CORE_CONTESTED") exitWith {};
    if (isNil "MISSION_CORE_CACHED_POSITIONS") exitWith {};
    private _contestedRows = [];
    {
        private _n = _x;
        private _i = MISSION_CORE_CACHED_POSITIONS findIf { (_x select 0) == _n };
        if (_i >= 0) then {
            private _r = MISSION_CORE_CACHED_POSITIONS select _i;
            private _sz = if (count _r > 8) then { _r select 8 } else { [50, 50] };
            _contestedRows pushBack [_n, _r select 1, _sz, _r select 4];
        };
    } forEach (keys MISSION_CORE_CONTESTED);
    {
        _x params ["_mName", "_mPos", "_mSize", "_mOwner"]; // row assembled above from the cache
        private _cap = [([_mName] call MISSION_CORE_fnc_getCachedImportance)] call MISSION_CORE_fnc_markerCapacity;
        private _commit = MISSION_CORE_COMMIT getOrDefault [_mName, 0];
        private _credits = MISSION_CORE_MANPOWER getOrDefault [_mName, []];
        private _pendingMen = 0;
        { _pendingMen = _pendingMen + (_x select 0); } forEach _credits;
        private _alive = [_mName, EAST] call MISSION_CORE_fnc_countMarkerGarrison;
        diag_log format ["DYNAMIC STATUS: contested %1 cap=%2 commit=%3 pendingMen=%4 alive=%5", _mName, _cap, _commit, _pendingMen, _alive];
    } forEach _contestedRows;
};
