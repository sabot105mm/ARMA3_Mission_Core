//
// HOUSE OCCUPATION - lazy urban garrison sprays.
//
// In any built-up marker (a town / village / compound or any marker whose ellipse contains roofed
// structures), house-sized buildings get a per-grid-cell marker (7.5m Altis grid) tiling their
// footprint - so a house that spans two cells gets two square markers. A GRID GARRISON is kept at
// the marker level, conceptually "a garrison squad occupying those houses":
//
//   - The unit physically does NOT exist until a player is near (spawn radius), then it spawns
//     ADDITIVELY inside the house (1-2 occupants at a random interior buildingPos) and HOLDs the
//     spot (static ambusher). It despawns once the player leaves (despawn radius).
//   - Static ambusher behavior: disableAI "PATH", stands, FACES THE NEAREST WINDOW/OUTWALL when
//     idle. If an occupant in the same house is KILLED, the survivors turn to face the house
//     center (they tracked the shot).
//   - Budget: EXEMPT from the 10-squad foot cap - a separate hard cap of active occupied houses
//     (default 6) keeps unit counts bounded.
//
// Radii have hysteresis (spawn 80m / despawn 140m) so units don't flutter in and out.

MISSION_CORE_fnc_houseOccupationInit = {
    diag_log "HOUSE OCCUPATION: director started";
    if (isNil "MISSION_CORE_HOUSE_RECORDS") then { MISSION_CORE_HOUSE_RECORDS = createHashMap; };   // markerName -> array of house records
    if (isNil "MISSION_CORE_HOUSE_ACTIVE") then { MISSION_CORE_HOUSE_ACTIVE = createHashMap; };      // markerName -> count of LIVE occupants
    private _grid = getNumber (configFile >> "CfgWorlds" >> worldName >> "GridSize");
    if (_grid <= 0) then { _grid = 7.5; };

    private _spawnR = ["houseSpawnRadius", 80] call MISSION_CORE_fnc_tune;
    private _despawnR = ["houseDespawnRadius", 140] call MISSION_CORE_fnc_tune;
    private _maxActive = ["houseMaxActive", 6] call MISSION_CORE_fnc_tune; // hard active-house cap (exempt from the foot budget)

    while { true } do {
        sleep 5 + random 3;
        if (isNil "MISSION_CORE_CACHED_POSITIONS") then { continue; };
        if (isNil "MISSION_CORE_SPAWNED_LOCATIONS") then { continue; };
        private _players = allPlayers select { alive _x };
        if (count _players == 0) then { continue; };

        // Prune records for markers that despawned - delete their occupants + house markers.
        {
            private _mName = _x;
            if (MISSION_CORE_SPAWNED_LOCATIONS getOrDefault [_mName, false]) then { continue; };
            private _recs = MISSION_CORE_HOUSE_RECORDS getOrDefault [_mName, []];
            if (count _recs == 0) then { continue; };
            {
                _x params ["_house", "_cellMarkers", "_interior", "_center", "_occUnits", ["_grp", grpNull]];
                { if (!isNull _x) then { deleteVehicle _x; }; } forEach _occUnits;
                if (!isNull _grp) then { deleteGroup _grp; };
                { if (_x in allMapMarkers) then { deleteMarker _x; }; } forEach _cellMarkers;
                // Release the house so a respawn of this marker (or a neighbor) can re-use it.
                if (!isNull _house) then { _house setVariable ["MISSION_CORE_HOUSE_USED", false]; };
            } forEach _recs;
            MISSION_CORE_HOUSE_RECORDS deleteAt _mName;
            MISSION_CORE_HOUSE_ACTIVE deleteAt _mName;
        } forEach (keys MISSION_CORE_HOUSE_RECORDS);

        // ---- Reconcile per-marker house records with the current player positions ----
        private _activeCount = 0;
        {
            private _loc = _x;
            if ((_loc select 4) != EAST) then { continue; }; // REDFOR garrison only - the player fights enemies
            private _mName = _loc select 0;
            private _isSpawned = MISSION_CORE_SPAWNED_LOCATIONS getOrDefault [_mName, false];
            if (!_isSpawned) then { continue; };

            // Build records lazily the first time the marker spawns.
            private _records = MISSION_CORE_HOUSE_RECORDS getOrDefault [_mName, []];
            if (count _records == 0) then {
                _records = [_loc, _grid] call MISSION_CORE_fnc_houseScan;
                MISSION_CORE_HOUSE_RECORDS set [_mName, _records];
            };

            // Update live occupants per house.
            private _aliveHere = 0;
            {
                private _rec = _x;
                _rec params ["_house", "_cellMarkers", "_interior", "_center", "_occUnits", ["_grp", grpNull], ["_cleared", false]];
                private _nearest = 1e10;
                { private _d = (_house distance _x); if (_d < _nearest) then { _nearest = _d; }; } forEach _players;
                // Drop occupants that DIED - a dead occupant must not keep the house "occupied"
                // forever. When a house goes from "had occupants" to "zero alive", mark it CLEARED:
                // its squares turn green permanently and it never respawns.
                _occUnits = _occUnits select { !isNull _x && { alive _x } };
                private _hasOcc = count _occUnits > 0;
                private _prevOcc = _rec select 4;
                _rec set [4, _occUnits];
                if (count _prevOcc > 0 && { !_hasOcc }) then {
                    _cleared = true;
                    _rec set [6, true];
                    _house setVariable ["MISSION_CORE_HOUSE_CLEARED", true];
                    { if (_x in allMapMarkers) then { _x setMarkerColor "ColorGreen"; }; } forEach _cellMarkers;
                    diag_log format ["HOUSE OCCUPATION: %1 CLEARED (occupants eliminated) in %2", _mName, typeOf _house];
                };
                if (!isNull _grp && {{ alive _x } count units _grp == 0} && { _hasOcc == false }) then {
                    deleteGroup _grp;
                    _rec set [5, grpNull];
                };
                if (_cleared) then { continue; };
                if (!_hasOcc && { _nearest <= _spawnR } && { _activeCount < _maxActive }) then {
                    // SPAWN additively: 1-2 occupants, static, facing a window/outwall.
                    private _n = 1 + (floor (random (["houseMaxPerHouse", 2] call MISSION_CORE_fnc_tune))); // 1..maxPerHouse
                    private _occ = [];
                    private _grp = createGroup EAST;
                    for "_i" from 1 to _n do {
                        if (count _interior == 0) exitWith {};
                        private _spot = selectRandom _interior;
                        private _u = _grp createUnit [selectRandom (call MISSION_CORE_fnc_houseUnitPool), _spot, [], 0, "NONE"];
                        _u setPosATL _spot;
                        _u disableAI "PATH";
                        _u disableAI "AUTOCOMBAT";
                        _u setUnitPos "UP";
                        _u setBehaviour "SAFE";
                        _u setCombatMode "RED";
                        // Face the nearest window/outwall: direction from house center outward past
                        // the interior point.
                        private _outDir = _center getDir _spot;
                        _u setDir _outDir;
                        _u doWatch (_spot getPos [10, _outDir]);
                        _occ pushBack _u;
                    };
                    // When any occupant in this house dies, survivors turn to face the house center.
                    [_house, _occ] spawn {
                        params ["_house", "_occ"];
                        private _t = time + 900; // check for ~15 min / house's lifetime
                        waitUntil { sleep 5; time > _t || { { alive _x } count _occ == 0 } || { { alive _x } count _occ < count _occ } };
                        // A shot was fired in the house (someone died) - survivors fixate on the center.
                        {
                            if (!isNull _x && { alive _x }) then {
                                _x doWatch (_house getPos [2, (_x getDir _house)]);
                                _x setDir (_x getDir _house);
                            };
                        } forEach _occ;
                    };
                    _rec set [4, _occ];
                    _rec set [5, _grp];
                    _aliveHere = _aliveHere + count _occ;
                    _activeCount = _activeCount + count _occ;
                    diag_log format ["HOUSE OCCUPATION: %1 spawned %2 occupants in %3", _mName, count _occ, typeOf _house];
                } else {
                    if (_hasOcc && { _nearest > _despawnR }) then {
                        // DESPAWN when the player leaves (hysteresis avoids fluttering).
                        { if (!isNull _x) then { deleteVehicle _x; }; } forEach _occUnits;
                        _rec set [4, []];
                        if (!isNull _grp) then { deleteGroup _grp; _rec set [5, grpNull]; };
                        diag_log format ["HOUSE OCCUPATION: %1 despawned occupants in %2", _mName, typeOf _house];
                    } else {
                        if (_hasOcc) then { _aliveHere = _aliveHere + count _occUnits; _activeCount = _activeCount + count _occUnits; };
                    };
                };
            } forEach _records;
            MISSION_CORE_HOUSE_ACTIVE set [_mName, _aliveHere];
        } forEach MISSION_CORE_CACHED_POSITIONS;
    };
};

// Pick a REDFOR house-tenant class (the faction's proper rifleman, not crew/placeholder).
MISSION_CORE_fnc_houseUnitPool = {
    private _unitPool = [MISSION_CORE_REDFOR_DATA, EAST] call MISSION_CORE_fnc_factionRiflemen;
    if (count _unitPool == 0) then { _unitPool = ["O_Soldier_F"]; };
    _unitPool
};

// Scan a marker's footprint for house-sized roofed structures. For each house:
//   - compute the grid-cell footprint (tiling a 1-cell square per covered cell, so a 2-cell-wide
//     house gets 2 cell markers)
//   - collect interior buildingPos as spawn spots
//   - record the house center for the "face outward / face center on kill" logic.
// Marks only REDFOR spawnable houses. Returns the records array.
MISSION_CORE_fnc_houseScan = {
    params ["_loc", "_grid"];
    private _mName = _loc select 0;
    private _mPos = _loc select 1;
    private _mSize = if (count _loc > 8) then { _loc select 8 } else { [200, 200] };
    private _r = ((_mSize select 0) max (_mSize select 1)) * 1.1;
    private _houses = nearestObjects [_mPos, ["House", "Building", "Strategic", "Fortress"], _r] select {
        private _b = _x;
        // Real structures with an interior (has building positions) - skip open scaffolding,
        // walls, and pure facades. Anything with walls+roof and >=1 interior spot is fair game.
        private _hasInterior = false;
        for "_i" from 0 to 3 do {
            private _p = _b buildingPos _i;
            if (count _p == 3 && { (_p select 2) > 0.01 }) exitWith { _hasInterior = true; };
        };
        _hasInterior &&
        { !(_b isKindOf "Wall_F") } &&
        { !(_b isKindOf "Land_Net_Fence_pole_F") } &&
        { !(_b getVariable ["MISSION_CORE_HOUSE_USED", false]) }
    };
    private _records = [];
    {
        private _b = _x;
        _b setVariable ["MISSION_CORE_HOUSE_USED", true];
        private _bCleared = _b getVariable ["MISSION_CORE_HOUSE_CLEARED", false];
        private _center = getPosATL _b;
        // Interior positions only (above ground level, meaningful z).
        private _interior = [];
        for "_i" from 0 to 39 do {
            private _p = _b buildingPos _i;
            if (_p isEqualTo [0, 0, 0]) exitWith {};
            if ((_p select 2) > 0.05) then { _interior pushBack _p; };
        };
        if (count _interior == 0) then { continue; };
        // Grid-cell footprint: the house's bounding box mapped onto 7.5m cells.
        private _bbMin = boundingBoxReal _b select 0;
        private _bbMax = boundingBoxReal _b select 1;
        private _dir = getDir _b;
        private _rad = _dir * (pi / 180);
        private _cos = cos _dir;
        private _sin = sin _dir;
        private _corners = [
            [_bbMin select 0, _bbMin select 1],
            [_bbMax select 0, _bbMin select 1],
            [_bbMin select 0, _bbMax select 1],
            [_bbMax select 0, _bbMax select 1]
        ];
        private _minX = 1e10; private _maxX = -1e10; private _minY = 1e10; private _maxY = -1e10;
        {
            private _wx = (_x select 0) * _cos - (_x select 1) * _sin;
            private _wy = (_x select 0) * _sin + (_x select 1) * _cos;
            private _px = (_center select 0) + _wx;
            private _py = (_center select 1) + _wy;
            if (_px < _minX) then { _minX = _px; };
            if (_px > _maxX) then { _maxX = _px; };
            if (_py < _minY) then { _minY = _py; };
            if (_py > _maxY) then { _maxY = _py; };
        } forEach _corners;
        private _col0 = floor (_minX / _grid);
        private _col1 = floor (_maxX / _grid);
        private _row0 = floor (_minY / _grid);
        private _row1 = floor (_maxY / _grid);
        // One square marker per covered cell (aligned to the grid), flush, small.
        private _cellMarkers = [];
        for "_c" from _col0 to _col1 do {
            for "_rr" from _row0 to _row1 do {
                private _cx = (_c + 0.5) * _grid;
                private _cy = (_rr + 0.5) * _grid;
                private _mkName = format ["DynOpsHouse_%1_%2_%3", _mName, _c, _rr];
                private _mk = createMarker [_mkName, [_cx, _cy, 0]];
                _mk setMarkerShape "RECTANGLE";
                _mk setMarkerSize [_grid * 0.48, _grid * 0.48];
                _mk setMarkerBrush "SolidBorder";
                _mk setMarkerColor (if (_bCleared) then { "ColorGreen" } else { "ColorRed" });
                _mk setMarkerAlpha 0.5;
                _cellMarkers pushBack _mkName;
            };
        };
        _records pushBack [_b, _cellMarkers, _interior, _center, [], grpNull, _bCleared];
    } forEach _houses;
    _records
};
