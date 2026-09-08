//
// HOUSE OCCUPATION - lazy urban garrison sprays.
//
// In any built-up marker (a town / village / compound or any marker whose ellipse contains roofed
// structures), house-sized buildings get a per-grid-cell marker (7.5m Altis grid) tiling their
// footprint - so a house that spans two cells gets two square markers. A GRID GARRISON is kept at
// the marker level, conceptually "a garrison squad occupying those houses":
//
//   - The unit physically does NOT exist until a player is near (per-house spawn radius), then it
//     spawns ADDITIVELY inside the house (1-2 occupants, priority-based) and HOLDs the spot (static
//     ambusher). It despawns once the player leaves (100m despawn radius).
//   - STATIC ambusher: disableAI "PATH", stands, FACES THE NEAREST WINDOW/OUTWALL when idle. If an
//     occupant in the same house is KILLED, the survivors turn to face the house center.
//   - Houses are POPULATED closest-first and priority-first. Priority (via structure name):
//     1=bunker, 2=military, 3=guard post (these populate from 2x the base 80m radius), 4=any
//     multistory house, 5=any other house. The closest filled house wins within a tier.
//   - 20m override: when a player is 20m or closer to a house it spawns REGARDLESS of the
//     active-house cap.
//   - Budget: EXEMPT from the 10-squad foot cap - a separate hard cap of active occupied houses
//     (default 6) keeps unit counts bounded.

MISSION_CORE_fnc_houseOccupationInit = {
    diag_log "HOUSE OCCUPATION: director started";
    if (isNil "MISSION_CORE_HOUSE_RECORDS") then { MISSION_CORE_HOUSE_RECORDS = createHashMap; };   // markerName -> array of house records
    if (isNil "MISSION_CORE_HOUSE_ACTIVE") then { MISSION_CORE_HOUSE_ACTIVE = createHashMap; };      // markerName -> count of LIVE occupants
    private _grid = getNumber (configFile >> "CfgWorlds" >> worldName >> "GridSize");
    if (_grid <= 0) then { _grid = 7.5; };

    private _spawnR = ["houseSpawnRadius", 80] call MISSION_CORE_fnc_tune;      // base: priority 4/5 houses
    private _despawnR = ["houseDespawnRadius", 100] call MISSION_CORE_fnc_tune; // uniform despawn (100m)
    private _maxActive = ["houseMaxActive", 6] call MISSION_CORE_fnc_tune;      // hard active-house cap (exempt from the foot budget)
    private _overrideR = ["houseOverrideRadius", 20] call MISSION_CORE_fnc_tune; // this close -> spawn even at cap
    private _prioMult = ["housePriorityRadiusMult", 2] call MISSION_CORE_fnc_tune; // bunker/military/guard-post use spawnR x this

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
        // Per-house upkeep (dead-occupant pruning, CLEARED squares, despawn) runs per house, but
        // SPAWNING is decided globally afterward: eligible empty houses are collected, sorted by
        // (priority, then nearest-player distance) so the closest / highest-value houses fill first,
        // and a 20m override spawns a house even when the active-house cap is already full.
        private _activeCount = 0;
        private _candidates = [];
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

            // Per-house upkeep.
            {
                private _rec = _x;
                _rec params ["_house", "_cellMarkers", "_interior", "_center", "_occUnits", ["_grp", grpNull], ["_cleared", false], ["_priority", 5]];
                private _nearest = 1e10;
                { private _d = (_house distance _x); if (_d < _nearest) then { _nearest = _d; }; } forEach _players;
                // Cargo towers: man them with the graduated garrison - first defenders on the top
                // deck at cargoTowerSpawnRadius m, more men at the 2nd/3rd-floor windows and the
                // ground as the player closes, up to cargoTowerMaxCount, EVERYONE facing the player.
                // Handled here inside the house-occupation director loop only - no extra polls.
                // PERMANENT RULE: Outposts / powerplants / solar are tiny static garrisons - no
                // tower garrison, no MGs (light-infrastructure markers).
                if (_house isKindOf "Land_Cargo_Tower_base_F" && { !([_loc] call MISSION_CORE_fnc_isLightInfrastructure) }) then {
                    [_rec, _nearest, _players] call MISSION_CORE_fnc_cargoTowerTick;
                    continue;
                };
                // Drop occupants that DIED - a dead occupant must not keep the house "occupied"
                // forever. When a house goes from "had occupants" to "zero alive", mark it CLEARED:
                // its squares turn green permanently and it never respawns.
                _occUnits = _occUnits select { !isNull _x && { alive _x } };
                private _hasOcc = count _occUnits > 0;
                private _prevOcc = _rec select 4;
                _rec set [4, _occUnits];
                if (count _prevOcc > 0 && { !_hasOcc }) then {
                    _rec set [6, true];
                    _house setVariable ["MISSION_CORE_HOUSE_CLEARED", true];
                    { if (_x in allMapMarkers) then { _x setMarkerColor "ColorGreen"; }; } forEach _cellMarkers;
                    diag_log format ["HOUSE OCCUPATION: %1 CLEARED (occupants eliminated) in %2", _mName, typeOf _house];
                };
                if (!isNull _grp && {{ alive _x } count units _grp == 0} && { _hasOcc == false }) then {
                    deleteGroup _grp;
                    _rec set [5, grpNull];
                };
                if (_rec select 6) then { continue; };
                if (_hasOcc) then {
                    // Uniform despawn radius (100m) regardless of priority once the player withdraws.
                    if (_nearest > _despawnR) then {
                        { if (!isNull _x) then { deleteVehicle _x; }; } forEach _occUnits;
                        _rec set [4, []];
                        if (!isNull _grp) then { deleteGroup _grp; _rec set [5, grpNull]; };
                        diag_log format ["HOUSE OCCUPATION: %1 despawned occupants in %2", _mName, typeOf _house];
                    } else {
                        _activeCount = _activeCount + count _occUnits;
                    };
                } else {
                    // Eligibility / spawning resolved in the global pass below.
                    _candidates pushBack [_rec, _mName, _nearest, _priority];
                };
            } forEach _records;
        } forEach MISSION_CORE_CACHED_POSITIONS;

        // ---- GLOBAL spawn pass: priority-first, then closest-first; 20m busts the cap ----
        _candidates = [_candidates, [], { ((_x select 3) - 1) * 1e6 + (_x select 2) }, "ASCEND"] call BIS_fnc_sortBy;
        {
            _x params ["_rec", "_mName", "_nearest", "_priority"];
            if (count _rec == 0) then { continue; };
            if (_rec select 6) then { continue; };            // cleared -> never respawns
            if (count (_rec select 4) > 0) then { continue; }; // already occupied
            private _override = _nearest <= _overrideR;        // 20m: spawn regardless of cap/radius
            // Eligible radius: bunker/military/guard-post (prio 1-3) populate from 2x the base radius.
            private _radius = if (_priority <= 3) then { _spawnR * _prioMult } else { _spawnR };
            if (!_override && { _nearest > _radius }) then { continue; };
            if (!_override && { _activeCount >= _maxActive }) then { continue; };
            private _house = _rec select 0;
            private _interior = _rec select 2;
            private _center = _rec select 3;
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
            _activeCount = _activeCount + count _occ;
            diag_log format ["HOUSE OCCUPATION: %1 spawned %2 occupants in %3 (prio %4, %5m)", _mName, count _occ, typeOf _house, _priority, round _nearest];
        } forEach _candidates;

        // Recompute per-marker live-occupant tallies (diagnostic; not read by gameplay).
        {
            private _mName = _x;
            private _sum = 0;
            {
                _sum = _sum + (count ((_x select 4) select { !isNull _x && { alive _x } }));
            } forEach (MISSION_CORE_HOUSE_RECORDS getOrDefault [_mName, []]);
            MISSION_CORE_HOUSE_ACTIVE set [_mName, _sum];
        } forEach (keys MISSION_CORE_HOUSE_RECORDS);
    };
};

// Pick a REDFOR house-tenant class (the faction's proper rifleman, not crew/placeholder).
MISSION_CORE_fnc_houseUnitPool = {
    private _unitPool = [MISSION_CORE_REDFOR_DATA, EAST] call MISSION_CORE_fnc_factionRiflemen;
    if (count _unitPool == 0) then { _unitPool = ["O_Soldier_F"]; };
    _unitPool
};

// Cargo towers (Land_Cargo_Tower_*) get a GRADUATED garrison that grows as the player closes:
//   - Top deck defenders spawn the moment the player is within cargoTowerSpawnRadius (600m).
//   - Crossing 0.7x the radius adds men at the floor below the deck (windows), 0.5x adds the next
//     floor down, and the ground floor posts a final man - up to cargoTowerMaxCount (8) total.
//   - EVERY defender faces the player: spots are picked top-down whose outward azimuth most closely
//     matches the player's bearing from the tower, so coming from the east mans the east-facing
//     deck/windows. Men hold position, re-face the player every director tick, and despawn once the
//     player withdraws beyond cargoTowerDespawnRadius. A wiped garrison marks the tower CLEARED.
//   - The per-tower floor layout (heights+spots) is computed ONCE and cached on the structure AND
//     in the MISSION_CORE_CARGO_LAYOUTS hashmap (keyed by object) so re-occupation reuses it.
//   - Runs inline in the house-occupation director loop - NO extra polling threads.

// Compute + cache the floor clustering for a cargo tower. Returns [_floors, _center] where _floors
// is sorted ASCENDING by height (index 0 = ground, last = top deck).
MISSION_CORE_fnc_cargoTowerLayout = {
    params ["_house", "_center"];
    private _cached = _house getVariable ["MISSION_CORE_CARGO_LAYOUT", []];
    if (count _cached > 0) exitWith { _cached };
    private _spots = [];
    for "_i" from 0 to 39 do {
        private _p = _house buildingPos _i;
        if (count _p == 3 && { (_p select 2) > 0.05 }) then { _spots pushBack _p; };
    };
    _spots sort [true, [2]];
    private _floors = [];
    private _cur = [];
    private _prevZ = -1e10;
    {
        private _z = _x select 2;
        if (_z - _prevZ > 2.0) then {
            if (count _cur > 0) then { _floors pushBack _cur; };
            _cur = [_x];
        } else { _cur pushBack _x; };
        _prevZ = _z;
    } forEach _spots;
    if (count _cur > 0) then { _floors pushBack _cur; };
    private _layout = [_floors, _center];
    _house setVariable ["MISSION_CORE_CARGO_LAYOUT", _layout, true];
    if (isNil "MISSION_CORE_CARGO_LAYOUTS") then { MISSION_CORE_CARGO_LAYOUTS = createHashMap; };
    MISSION_CORE_CARGO_LAYOUTS set [str _house, _layout];
    _layout
};

// The graduated-garrison tick: called per cargo tower from the house-occupation director loop.
MISSION_CORE_fnc_cargoTowerTick = {
    params ["_rec", "_nearest", "_players"];
    _rec params ["_house", "_cellMarkers", "_interior", "_center", "_occUnits", ["_grp", grpNull], ["_cleared", false], ["_priority", 5]];
    // Drop dead occupants; flipping to zero-alive marks the tower CLEARED (green, never re-garrisoned).
    private _occLive = _occUnits select { !isNull _x && { alive _x } };
    if (count _occUnits > 0 && { count _occLive == 0 }) then {
        _rec set [6, true];
        _house setVariable ["MISSION_CORE_HOUSE_CLEARED", true];
        { if (_x in allMapMarkers) then { _x setMarkerColor "ColorGreen"; }; } forEach _cellMarkers;
        diag_log format ["HOUSE OCCUPATION: %1 CLEARED (cargo tower garrison eliminated)", typeOf _house];
    };
    _rec set [4, _occLive];
    if (_rec select 6) exitWith {};
    private _nearestP = objNull;
    {
        private _d = _house distance _x;
        if (_d < _nearest) then { _nearest = _d; };
        if (isNull _nearestP || { _d < (_house distance _nearestP) }) then { _nearestP = _x; };
    } forEach _players;
    private _despawnR = ["cargoTowerDespawnRadius", 800] call MISSION_CORE_fnc_tune;
    if (_nearest > _despawnR) then {
        { if (!isNull _x) then { deleteVehicle _x; }; } forEach _occLive;
        if (!isNull _grp) then { deleteGroup _grp; _rec set [5, grpNull]; };
        _rec set [4, []];
    } else {
        private _spawnR = ["cargoTowerSpawnRadius", 600] call MISSION_CORE_fnc_tune;
        private _maxC = ["cargoTowerMaxCount", 8] call MISSION_CORE_fnc_tune;
        private _c1 = ["cargoTowerCount1", 4] call MISSION_CORE_fnc_tune;
        private _c2 = ["cargoTowerCount2", 6] call MISSION_CORE_fnc_tune;
        private _c3 = ["cargoTowerCount3", 8] call MISSION_CORE_fnc_tune;
        if (_nearest <= _spawnR && { !isNull _nearestP }) then {
            private _target = _c1;
            if (_nearest <= _spawnR * 0.7) then { _target = _c2; };
            if (_nearest <= _spawnR * 0.5) then { _target = _c3; };
            _target = _target min _maxC;
            private _need = _target - count _occLive;
            if (_need > 0) then {
                private _floors = ([_house, _center] call MISSION_CORE_fnc_cargoTowerLayout) select 0;
                private _nF = count _floors;
                // Angular difference between two compass headings (smallest).
                private _angDiff = { abs ((((_this select 0) - (_this select 1) + 540) mod 360) - 180) };
                // Pick up to _cap spots whose outward azimuth (center->spot) best faces the player.
                private _bearing = _center getDir _nearestP;
                private _pick = {
                    params ["_floor", "_cap"];
                    if (count _floor == 0) exitWith { [] };
                    private _sorted = [_floor, [], { ([_center getDir _x, _bearing] call _angDiff) }, "ASCEND"] call BIS_fnc_sortBy;
                    if (count _sorted > _cap) then { _sorted resize _cap; };
                    _sorted
                };
                // Fill top-down: deck, then the two floors below, then the ground - facing the player.
                private _pool = [];
                if (_nF > 0) then { _pool append ([_floors select (_nF - 1), _c1] call _pick); };
                if (_nF > 1 && _target >= _c2) then { _pool append ([_floors select (_nF - 2), ((_c2 - _c1) min 4)] call _pick); };
                if (_nF > 2 && _target >= _c3) then { _pool append ([_floors select (_nF - 3), ((_c3 - _c2) min 4)] call _pick); };
                if (_nF > 3) then { _pool append ([_floors select 0, 1] call _pick); };
                if (count _pool > _need) then { _pool resize _need; };
                if (count _pool > 0) then {
                    if (isNull _grp) then { _grp = createGroup EAST; _rec set [5, _grp]; };
                    private _unitPool = call MISSION_CORE_fnc_houseUnitPool;
                    {
                        private _u = _grp createUnit [selectRandom _unitPool, _x, [], 0, "NONE"];
                        _u setPosATL _x;
                        _u disableAI "PATH";
                        _u disableAI "AUTOCOMBAT";
                        _u setUnitPos "UP";
                        _u setBehaviour "SAFE";
                        _u setCombatMode "RED";
                        _u setDir (_x getDir _nearestP);
                        _u doWatch _nearestP;
                        _occLive pushBack _u;
                    } forEach _pool;
                    _rec set [4, _occLive];
                    diag_log format ["HOUSE OCCUPATION: cargo tower garrison %1 +%2 -> %3 men at %4m (player %5)", typeOf _house, count _pool, count _occLive, round _nearest, _bearing];
                };
            };
            // Every tick, posted men re-aim at the player as he closes.
            {
                if (!isNull _x && { alive _x }) then {
                    _x setDir (_x getDir _nearestP);
                    _x doWatch _nearestP;
                };
            } forEach _occLive;
        };
    };
};

// Priority classification for a house's occupants, 1 (highest) -> 5 (lowest), based on the
// building's structure/display name and floor layout:
//   1 = name contains "bunker"; 2 = "military"; 3 = "guard post";
//   4 = multistory (interior spots at >= 2 distinct floor heights); 5 = any other house.
// Tiers 1-3 are populated from 2x the base spawn radius by the caller (they ambush from far off).
MISSION_CORE_fnc_housePriority = {
    params ["_b", "_interior"];
    private _t = toLower (typeOf _b);
    private _display = toLower (getText (configFile >> "CfgVehicles" >> typeOf _b >> "displayName"));
    private _ln = _t + " " + _display;
    if (_ln find "bunker" > -1) exitWith { 1 };
    if (_ln find "military" > -1) exitWith { 2 };
    if (_ln find "guardpost" > -1 || { _ln find "guard_post" > -1 } || { _ln find "guard post" > -1 }) exitWith { 3 };
    if (_ln find "watchtower" > -1 || { _ln find "watch_tower" > -1 } || { _ln find "watch tower" > -1 } ||
        { _ln find "cargo_patrol" > -1 } || { _ln find "cargo patrol" > -1 } ||
        { _ln find "cargo_tower" > -1 } || { _ln find "cargo tower" > -1 }) exitWith { 3 };
    if (count _interior > 0) then {
        private _heights = _interior apply { round ((_x select 2) / 2.5) };  // bucket into ~2.5m floors
        _heights = _heights arrayIntersect _heights;
        if (count _heights >= 2) exitWith { 4 };  // >= 2 distinct floors -> multistory
    };
    5
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
        // Priority drives who spawns first + how far away (bunker/military/guard-post use 2x radius).
        private _priority = [_b, _interior] call MISSION_CORE_fnc_housePriority;
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
        _records pushBack [_b, _cellMarkers, _interior, _center, [], grpNull, _bCleared, _priority];
    } forEach _houses;
    _records
};
