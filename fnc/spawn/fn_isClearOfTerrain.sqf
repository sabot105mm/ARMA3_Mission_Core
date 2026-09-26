// SHARED TERRAIN-COLLISION BLOCKLIST - the single source of truth for "is this ground occupied".
//
// Every "can something spawn here" check in the mission used to carry its own inline
// nearestTerrainObjects list, and each one was wrong the same way: the lists were written from the
// classes that are OBVIOUS. A boulder is CfgTerrain class HIDE, not ROCK, so a rock-filter matches
// nothing at all, and the one place that did try to guard rocks asked for "BOULDER" - which is not
// a CfgTerrain class either, so that guard had never matched anything in the mission's life.
// Rocks, junk piles, shipwrecks, wrecks, bunker walls and container stacks all walked straight
// through every spawn check and units kept materializing inside them.
//
// One list, every path, so a class can never be remembered in one spawn check and forgotten in the
// next. Type names are matched case-insensitively by nearestTerrainObjects; upper case here to
// match the existing call sites.
//
// WEDGED OUT - flat painted ground with no collision, which can never clip a spawn:
//   "ROAD", "MAIN ROAD", "RAILWAY", "TRACK", "TRAIL", "TOURISM"
//   A road is precisely where a tank SHOULD land (the road-first spawn ladder depends on it), so
//   filtering on these would break the ladder rather than protect it.
//
// KEPT even though they look like grid metadata, on the "keep anything that might collide" rule:
//   "POWER LINES", "POWERSOLAR", "POWERWAVE", "POWERWIND"
//   A false reject only costs one more rung of a spawn ladder; a false accept puts a tank inside a
//   pylon. Cheap failure beats invisible failure, so they stay until proven harmless.
MISSION_CORE_TERRAIN_BLOCKERS = [
    "BUILDING", "BUNKER", "BUSH", "BUSSTOP", "CHAPEL", "CHURCH", "CROSS", "FENCE",
    "FOREST", "FOREST BORDER", "FOREST SQUARE", "FOREST TRIANGLE", "FORTRESS", "FOUNTAIN",
    "FUELSTATION", "HIDE", "HOSPITAL", "HOUSE", "LIGHTHOUSE", "POWER LINES", "POWERSOLAR",
    "POWERWAVE", "POWERWIND", "QUAY", "ROCK", "ROCKS", "RUIN", "SHIPWRECK", "SMALL TREE", "STACK"
];

// Trees and undergrowth are the flip side of this check: fn_findCoveredSpawns and
// fn_hasCoveredSpawns want a spot NEXT TO a tree, so those two must subtract this set or every
// spot they consider would be rejected by their own cover.
MISSION_CORE_TERRAIN_COVER = ["FOREST", "FOREST BORDER", "FOREST SQUARE", "FOREST TRIANGLE", "TREE", "SMALL TREE", "BUSH"];

// How much terrain collision sits within _radius of _pos. The counting form exists for the scoring
// ladders (findVehiclePos, findVehicleColumnPos), which pick the candidate with the FEWEST
// obstacles - they need a number, not a verdict, or "fewest obstacles" would stop being comparable
// between candidates once one path counted HIDE and another did not.
MISSION_CORE_fnc_countTerrainBlockers = {
    params ["_pos", ["_radius", 8], ["_ignore", []]];
    private _types = if (count _ignore > 0) then { MISSION_CORE_TERRAIN_BLOCKERS - _ignore } else { MISSION_CORE_TERRAIN_BLOCKERS };
    count (nearestTerrainObjects [_pos, _types, _radius])
};

// Pass/fail form for the hard spawn gates.
MISSION_CORE_fnc_isClearOfTerrain = {
    params ["_pos", ["_radius", 8], ["_ignore", []]];
    ([_pos, _radius, _ignore] call MISSION_CORE_fnc_countTerrainBlockers) == 0
};
