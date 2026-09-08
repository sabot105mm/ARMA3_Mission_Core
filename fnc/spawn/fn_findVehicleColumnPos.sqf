// =====================================================================
// ROAD COLUMN SPAWN - place several vehicles of ONE group all on the SAME
// road instead of scattering them across fields, side roads and parking
// lots. Mirrors the "PERMANENT RULE" of findVehiclePos (spawn on the road)
// but for N vehicles: picks the cleanest road segment near the center and
// walks the connected road network so the whole column sits in a line.
//
// Returns an array of up to _count [x,y,z] positions (all on road, spaced
// >= 20m apart). Callers fall back to findVehiclePos / findSafePos when 0
// are found (no roads nearby).
//
// Self-contained (only core commands + guarded mission helpers) so it is
// safe to compile on BOTH server (fn_spawn.sqf) and client (initPlayerLocal.sqf)
// - the recruit ATTACK deploy runs on the client and repositions its spawned
// BIS groups onto a road through this file.
// =====================================================================

MISSION_CORE_fnc_findVehicleColumnPos = {
    params ["_center", ["_size", [200, 200]], ["_count", 1], ["_attempts", 30]];
    private _a = if (count _size > 0) then { _size select 0 } else { 200 };
    private _b = if (count _size > 1) then { _size select 1 } else { _a };
    private _radius = ((_a max _b) * 1.25) max 60;
    private _result = [];
    private _roads = _center nearRoads _radius;
    if (count _roads == 0) exitWith { _result };
    private _existingVehs = vehicles select { alive _x && { _x isKindOf "LandVehicle" } };
    // Score every road segment: dry, clear of geometry, not a flagged spawn-kill.
    private _good = [];
    {
        private _rp = getPosATL _x;
        if (surfaceIsWater _rp) then { continue; };
        private _nb = nearestObjects [_rp, ["Building", "House", "Strategic", "Fortress", "Wall", "Fence"], 8];
        private _nt = nearestTerrainObjects [_rp, ["TREE", "FOREST", "BUSH", "FENCE", "WALL", "HEDGE", "ROCK", "ROCKS"], 8];
        private _sc = count _nb + count _nt;
        if (!isNil "MISSION_CORE_fnc_isUnsafeVehicleSpawn" && { [_rp] call MISSION_CORE_fnc_isUnsafeVehicleSpawn }) then { _sc = _sc + 99; };
        _good pushBack [_sc, _rp, _x];
    } forEach _roads;
    if (count _good == 0) exitWith { _result };
    _good sort true;
    // Seed = first clean, dry, unused segment (score <= 1 means at most a minor obstacle).
    private _seedIdx = -1;
    for "_i" from 0 to ((count _good) - 1) do {
        private _e = _good select _i;
        if ((_e select 0) > 1) then { continue; };
        if (_existingVehs findIf { (_e select 1) distance _x < 40 } > -1) then { continue; };
        _seedIdx = _i;
        break;
    };
    if (_seedIdx < 0) then { _seedIdx = 0; };
    private _seedSeg = _good select _seedIdx select 2;
    private _spots = [(_good select _seedIdx select 1)];
    // Walk the road network outward from the seed, gathering spots >= 20m apart.
    private _visitedSegs = [_seedSeg];
    private _frontier = [_seedSeg];
    while { count _spots < _count && count _frontier > 0 } do {
        private _seg = _frontier deleteAt 0;
        if (isNull _seg) then { continue; };
        {
            if (isNull _x) then { continue; };
            if (_x in _visitedSegs) then { continue; };
            _visitedSegs pushBack _x;
            private _p = getPosATL _x;
            if (surfaceIsWater _p) then { continue; };
            if (count _spots >= _count) exitWith {};
            if (_spots findIf { _p distance2D _x < 20 } == -1) then {
                private _nb = nearestObjects [_p, ["Building", "House", "Strategic", "Fortress", "Wall", "Fence"], 8];
                private _nt = nearestTerrainObjects [_p, ["TREE", "FOREST", "BUSH", "FENCE", "WALL", "HEDGE", "ROCK", "ROCKS"], 8];
                if (count _nb + count _nt <= 1) then { _spots pushBack _p; };
            };
            _frontier pushBack _x;
        } forEach (roadsConnectedTo _seg);
    };
    if (count _spots == 0) exitWith { _result };
    _spots = _spots select [0, ((count _spots) min _count)];
    _spots apply { [(_x select 0), (_x select 1), 0] }
};

// Road-align a freshly placed vehicle (client-safe copy of the default helper, kept local to
// this file so the client-side recruit paths can align vehicles without fn_spawn.sqf).
if (isNil "MISSION_CORE_fnc_alignVehicleToRoad") then {
    MISSION_CORE_fnc_alignVehicleToRoad = {
        params ["_veh"];
        if (isNull _veh) exitWith {};
        private _roads = (getPosATL _veh) nearRoads 14;
        if (count _roads > 0) then { _veh setDir (getDir (_roads select 0)); };
    };
};

// Reposition every land vehicle of an already-spawned group onto a road column near _center.
// Used by recruit garrison/attack deploys that spawn via BIS_fnc_spawnGroup (which just drops
// vehicles wherever the config formation lands). Vehicles keep their crew; on-foot stragglers
// stay put.
MISSION_CORE_fnc_alignGroupVehiclesToRoad = {
    params ["_grp", "_center", ["_size", [200, 200]]];
    if (isNull _grp) exitWith {};
    private _vehs = [];
    {
        private _v = vehicle _x;
        if (_v != _x && { _v isKindOf "LandVehicle" } && { _vehs findIf { _x == _v } < 0 }) then { _vehs pushBack _v; };
    } forEach units _grp;
    if (count _vehs == 0) exitWith {};
    private _spots = [_center, _size, count _vehs, 30] call MISSION_CORE_fnc_findVehicleColumnPos;
    {
        private _veh = _x;
        private _spot = [];
        if (_forEachIndex < count _spots) then {
            _spot = _spots select _forEachIndex;
        } else {
            if (!isNil "MISSION_CORE_fnc_findVehiclePos") then { _spot = [_center, _size, 30, 0] call MISSION_CORE_fnc_findVehiclePos; };
        };
        if (count _spot >= 2) then { _veh setPosATL _spot; };
        [_veh] call MISSION_CORE_fnc_alignVehicleToRoad;
    } forEach _vehs;
};