
MISSION_CORE_fnc_findVehiclePos = {
    params ["_center", ["_size", [200, 200]], ["_attempts", 20], ["_dir", 0], ["_lax", false]];
    private _a = _size select 0;
    private _b = _size select 1;
    private _pos = _center;
    private _clear = false;
    // DEAD-VEHICLE SCAN: sweep wrecks inside the safe spawn area (the marker footprint + 25%
    // safety net) and delete ONLY those - never every dead vehicle on the map. A fresh vehicle
    // must never materialize on top of / beside a burned-out hull from an earlier fight.
    [_center, ((_a max _b) * 1.25)] call MISSION_CORE_fnc_clearNearbyWrecks;
    // PERMANENT RULE: anything spawned inside a marker spawns ON the road, facing along it. Tanks,
    // APCs, trucks and transports roll out of a town along its roads instead of materializing in a
    // field. Prefer the best road segment inside the marker footprint (dry, not a flagged-unsafe
    // spawn, clear of hard geometry, >=40m away from parked land vehicles); fall back to the
    // cached flat spots / random scan below when there is no usable road.
    private _roads = _center nearRoads ((_a max _b) * 1.25);
    if (count _roads > 0) then {
        private _existingVehs = vehicles select { alive _x && { _x isKindOf "LandVehicle" } };
        private _roadBest = _center;
        private _roadScore = 99999;
        // Track the best road that is ALSO >=40m from any parked land vehicle. Repeated spawns to
        // the same marker (re-purchased vehicles, reinforcements) must never re-land on the exact
        // road spot the previous vehicle sits on - the plain _roadBest fallback below ignored
        // vehicles entirely and re-picked the same deterministic road every time, stacking spawns.
        private _roadBestClear = _center;
        private _roadScoreClear = 99999;
        private _rMax = ((count _roads) - 1) min (_attempts - 1);
        for "_r" from 0 to _rMax do {
            private _rcand = getPosATL (_roads select _r);
            private _nearBuildings = nearestObjects [_rcand, ["Building", "House", "Strategic", "Fortress", "Wall", "Fence"], 8];
            private _nTerrain = [_rcand, 8] call MISSION_CORE_fnc_countTerrainBlockers;
            private _nearVeh = _existingVehs findIf { _rcand distance _x < 40 } > -1;
            private _roadScoreNow = count _nearBuildings + _nTerrain;
            if (_roadScoreNow < _roadScore) then { _roadScore = _roadScoreNow; _roadBest = _rcand; };
            if (!_nearVeh && _roadScoreNow < _roadScoreClear) then { _roadScoreClear = _roadScoreNow; _roadBestClear = _rcand; };
            if (_roadScoreNow <= 1 && { !_nearVeh } && { [_rcand] call MISSION_CORE_fnc_isDryPos } && { !([_rcand] call MISSION_CORE_fnc_isUnsafeVehicleSpawn) }) exitWith {
                _pos = _rcand;
                _clear = true;
            };
        };
        // Prefer the best road that is ALSO clear of parked armor (never restart a spawn on top of
        // the previous vehicle). Only when NO road clears them does the geometry-only best road
        // (stray armor parked in the middle of a town) resolve the spawn as a true last resort.
        if (!_clear && _roadScoreClear <= 1 && { !([_roadBestClear] call MISSION_CORE_fnc_isUnsafeVehicleSpawn) }) then {
            _pos = _roadBestClear;
            _clear = true;
        } else {
            if (!_clear && _roadScore <= 1 && { !([_roadBest] call MISSION_CORE_fnc_isUnsafeVehicleSpawn) }) then {
                _pos = _roadBest;
                _clear = true;
            };
        };
    };
    // Prefer pre-validated flat spawn spots cached per marker by the isFlatEmpty scan. Vehicles
    // then always land on confirmed flat, clear ground and rotate across up to 4 spots instead
    // of stacking on top of each other or spawning into geometry.
    if (isNil "MISSION_CORE_SAFE_VEHICLE_SPAWNS") then { MISSION_CORE_SAFE_VEHICLE_SPAWNS = createHashMap; };
    if (isNil "MISSION_CORE_SAFE_SPAWN_INDEX") then { MISSION_CORE_SAFE_SPAWN_INDEX = createHashMap; };
    private _spotInfo = [_center] call MISSION_CORE_fnc_getSafeVehicleSpawns;
    private _spots = _spotInfo select 1;
    if (!_clear && count _spots > 0) then {
        private _key = _spotInfo select 0;
        private _idx = MISSION_CORE_SAFE_SPAWN_INDEX getOrDefault [_key, 0];
        MISSION_CORE_SAFE_SPAWN_INDEX set [_key, (_idx + 1) mod count _spots];
        private _spot = _spots select _idx;
        // A cached spot can still be temporarily unsafe (a recent spawn-kill marked it); in that
        // case fall through to the random scan this one time.
        if (!([_spot] call MISSION_CORE_fnc_isUnsafeVehicleSpawn)) then {
            _pos = _spot;
            _clear = true;
        };
    };
    if (!_clear) then {
        // Spread new vehicles at least 40m from any existing land vehicle so defense/reinforcement
        // squads never stack on top of each other in a single kill pocket.
        private _existingVehs = vehicles select { alive _x && { _x isKindOf "LandVehicle" } };
        // Track the least-obstructed candidate as a fallback: a spawn should never land inside
        // geometry, so instead of returning the last random attempt (which can be a bad spot that
        // makes the vehicle explode on spawn) we remember the cleanest one found. A SEPARATE
        // best-clear tracks the cleanest candidate that is ALSO >=40m away from parked land
        // vehicles - repeated spawns to a tight marker must spread out, never stack on the last
        // vehicle. Vehicles ignore the building score entirely (score 0 = no geometry at all).
        private _best = _center;
        private _bestScore = 99999;
        private _bestClear = _center;
        private _bestClearScore = 99999;
        private _foundClearCand = false;
        // Stay INSIDE the marker: pass 1 is the marker ellipse itself, pass 2 a 1.25x safety net.
        // The old 1.6x/3.2x expansion flung troops and vehicles well outside their town. Troops
        // (_lax) tolerate minor obstacles (a building or trees nearby) so a spot inside a dense
        // town centre still resolves; armor keeps a wider clear radius.
        private _clearR = if (_lax) then { 15 } else { 30 };
        private _acceptScore = if (_lax) then { 3 } else { 0 };
        for "_pass" from 1 to 2 do {
            private _passA = _a * (if (_pass == 1) then { 1.0 } else { 1.25 });
            private _passB = _b * (if (_pass == 1) then { 1.0 } else { 1.25 });
            for "_i" from 1 to _attempts do {
                private _ang = random 360;
                private _maxR = ([_passA, _passB, _ang, _dir] call MISSION_CORE_fnc_ellipseRadius) * 0.9;
                private _r = 0.2 * _maxR + random (0.6 * _maxR);
                private _cand = _center getPos [_r, _ang];
                // Obstacle check: buildings, trees/forest, fences/walls and rocks must stay clear
                // of the spawn so vehicles never appear inside geometry or wedged against an
                // obstacle. Troops may spawn next to a couple of minor objects.
                private _nearBuildings = nearestObjects [_cand, ["Building", "House", "Strategic", "Fortress", "Wall", "Fence"], _clearR];
                private _nTerrain = [_cand, _clearR] call MISSION_CORE_fnc_countTerrainBlockers;
                private _nearVeh = _existingVehs findIf { _cand distance _x < 40 } > -1;
                private _score = count _nearBuildings + _nTerrain;
                if (_score < _bestScore) then { _bestScore = _score; _best = _cand; };
                if (!_nearVeh && _score < _bestClearScore) then { _bestClearScore = _score; _bestClear = _cand; _foundClearCand = true; };
                if (_score <= _acceptScore && { !_nearVeh } && { [_cand] call MISSION_CORE_fnc_isDryPos } && { !([_cand] call MISSION_CORE_fnc_isUnsafeVehicleSpawn) }) exitWith {
                    _pos = _cand;
                    _clear = true;
                };
            };
            if (_clear) exitWith {};
        };
        if (!_clear) then { _pos = if (_foundClearCand) then { _bestClear } else { _best }; };
    };
    [_pos] call MISSION_CORE_fnc_ensureLandPos
};

// Face a freshly spawned land vehicle along the road it sits on. PERMANENT RULE: tanks, APCs,
// trucks and transports must roll out facing the road, not sideways across it. No nearby road:
// leave the default spawn heading untouched.
MISSION_CORE_fnc_alignVehicleToRoad = {
    params ["_veh"];
    if (isNull _veh) exitWith {};
    private _roads = (getPosATL _veh) nearRoads 14;
    if (count _roads > 0) then { _veh setDir (getDir (_roads select 0)); };
};
