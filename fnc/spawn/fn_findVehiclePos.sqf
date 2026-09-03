
MISSION_CORE_fnc_findVehiclePos = {
    params ["_center", ["_size", [200, 200]], ["_attempts", 20], ["_dir", 0], ["_lax", false]];
    private _a = _size select 0;
    private _b = _size select 1;
    private _pos = _center;
    private _clear = false;
    // Prefer pre-validated flat spawn spots cached per marker by the isFlatEmpty scan. Vehicles
    // then always land on confirmed flat, clear ground and rotate across up to 4 spots instead
    // of stacking on top of each other or spawning into geometry.
    if (isNil "MISSION_CORE_SAFE_VEHICLE_SPAWNS") then { MISSION_CORE_SAFE_VEHICLE_SPAWNS = createHashMap; };
    if (isNil "MISSION_CORE_SAFE_SPAWN_INDEX") then { MISSION_CORE_SAFE_SPAWN_INDEX = createHashMap; };
    private _spotInfo = [_center] call MISSION_CORE_fnc_getSafeVehicleSpawns;
    private _spots = _spotInfo select 1;
    if (count _spots > 0) then {
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
        // makes the vehicle explode on spawn) we remember the cleanest one found.
        private _best = _center;
        private _bestScore = 99999;
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
                private _nearTerrain = nearestTerrainObjects [_cand, ["TREE", "FOREST", "BUSH", "FENCE", "WALL", "HEDGE", "ROCK", "ROCKS"], _clearR];
                private _nearVeh = _existingVehs findIf { _cand distance _x < 40 } > -1;
                private _score = count _nearBuildings + count _nearTerrain;
                if (_score < _bestScore) then { _bestScore = _score; _best = _cand; };
                if (_score <= _acceptScore && { !_nearVeh } && { [_cand] call MISSION_CORE_fnc_isDryPos } && { !([_cand] call MISSION_CORE_fnc_isUnsafeVehicleSpawn) }) exitWith {
                    _pos = _cand;
                    _clear = true;
                };
            };
            if (_clear) exitWith {};
        };
        if (!_clear) then { _pos = _best; };
    };
    [_pos] call MISSION_CORE_fnc_ensureLandPos
};
