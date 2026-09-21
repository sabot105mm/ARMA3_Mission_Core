// Full "safe to spawn a vehicle here?" check, shared by every armored/truck spawn path (defense
// vehicles, HQ forces, tank orders, convoys, depot parks, foot transports). A vehicle must land
// on dry ground that is not a flagged-unsafe spawn, be free of any land vehicle still parked
// there, and be clear of hard geometry AND terrain objects (trees, rocks, forest) within 8m -
// so armor and trucks never materialize on a mountain slope or in a treeline they can't cross.
MISSION_CORE_fnc_isSafeVehicleSpawnPos = {
    params ["_pos"];
    if (!([_pos] call MISSION_CORE_fnc_isDryPos)) exitWith { false };
    if ([_pos] call MISSION_CORE_fnc_isUnsafeVehicleSpawn) exitWith { false };
    if ((vehicles select { alive _x && { _x isKindOf "LandVehicle" } }) findIf { _pos distance _x < 40 } > -1) exitWith { false };
    if (count (nearestObjects [_pos, ["Building", "House", "Strategic", "Fortress", "Wall", "Fence"], 8]) > 0) exitWith { false };
    if (count (nearestTerrainObjects [_pos, ["TREE", "FOREST", "BUSH", "FENCE", "WALL", "HEDGE", "ROCK", "ROCKS", "SMALL TREE", "FOREST BORDER", "FOREST SQUARE", "FOREST TRIANGLE"], 8]) > 0) exitWith { false };
    true
};

// Re-roll a candidate vehicle spawn position until it passes the full safe check above. When the
// given spot fails, re-roll through findVehiclePos (road-first, cached flats, 30m clear radius)
// around _center; if even that does not resolve, return the original spot rather than skipping
// the spawn - the guardSpawnKill watcher still backstops it in-game.
MISSION_CORE_fnc_safeVehicleSpawnPos = {
    params ["_pos", ["_center", []], ["_size", [150, 150]]];
    if (count _pos < 2) exitWith { _pos };
    if ([_pos] call MISSION_CORE_fnc_isSafeVehicleSpawnPos) exitWith { _pos };
    if (count _center < 2) then { _center = _pos; };
    private _retry = [_center, _size, 20, random 360] call MISSION_CORE_fnc_findVehiclePos;
    if (count _retry >= 2 && { [_retry] call MISSION_CORE_fnc_isSafeVehicleSpawnPos }) exitWith { _retry };
    _pos
};