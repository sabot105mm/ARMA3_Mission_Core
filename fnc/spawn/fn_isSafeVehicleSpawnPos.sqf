// Full "safe to spawn a vehicle here?" check, shared by every armored/truck spawn path (defense
// vehicles, HQ forces, tank orders, convoys, depot parks, foot transports). A vehicle must land
// on dry ground that is not a flagged-unsafe spawn, be free of any land vehicle still parked
// there, and be clear of hard geometry AND terrain objects (trees, rocks, forest, boulders,
// wrecks, ruins) within 8m - so armor and trucks never materialize on a mountain slope, in a
// treeline they can't cross, or inside a boulder (class HIDE, which no ROCK filter ever caught).
// Land vehicles (tanks, APCs, cars, trucks) within _radius of a point - DEAD wrecks AND living
// hulls alike, so a spawn never lands on top of a burned-out tank. Uses nearEntities' AREA syntax
// with aliveOnly = false: one spatial query (far cheaper than scanning the global vehicles array
// per candidate, and unlike the plain nearEntities form it DOES return destroyed hulls). Shared by
// every safe-spawn occupancy test so detection lives in exactly one place.
MISSION_CORE_fnc_landVehiclesNear = {
    params ["_pos", ["_radius", 40]];
    if (count _pos < 2) exitWith { [] };
    private _area = [[_pos select 0, _pos select 1], _radius, _radius, 0, false];
    _area nearEntities [["LandVehicle"], false, false, true]
};

MISSION_CORE_fnc_isSafeVehicleSpawnPos = {
    params ["_pos"];
    if (count _pos < 2) exitWith { false };
    if (!([_pos] call MISSION_CORE_fnc_isDryPos)) exitWith { false };
    if ([_pos] call MISSION_CORE_fnc_isUnsafeVehicleSpawn) exitWith { false };
    if (count ([_pos, 40] call MISSION_CORE_fnc_landVehiclesNear) > 0) exitWith { false };
    if (count (nearestObjects [_pos, ["Building", "House", "Strategic", "Fortress", "Wall", "Fence"], 8]) > 0) exitWith { false };
    if (!([_pos] call MISSION_CORE_fnc_isClearOfTerrain)) exitWith { false };
    true
};

// Re-roll a candidate vehicle spawn position until it passes the full safe check above. When the
// given spot fails, re-roll through findVehiclePos (road-first, cached flats, 30m clear radius)
// around _center. Returns [] when NO clean spot resolves - the caller must then WAIT and retry; we
// never hand back the original occupied spot to be force-spawned.
MISSION_CORE_fnc_safeVehicleSpawnPos = {
    params ["_pos", ["_center", []], ["_size", [150, 150]]];
    if (count _pos < 2) exitWith { [] };
    if ([_pos] call MISSION_CORE_fnc_isSafeVehicleSpawnPos) exitWith { _pos };
    if (count _center < 2) then { _center = _pos; };
    private _retry = [_center, _size, 20, random 360] call MISSION_CORE_fnc_findVehiclePos;
    if (count _retry >= 2 && { [_retry] call MISSION_CORE_fnc_isSafeVehicleSpawnPos }) exitWith { _retry };
    []
};