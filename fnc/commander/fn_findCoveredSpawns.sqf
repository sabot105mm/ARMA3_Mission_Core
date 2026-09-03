
// Find covered spawn points for foot squads: prefer tree/bush clusters (>= 3 within 25m) and
// buildings NEAR the marker (within the edge radius - not strictly inside the ellipse, so trees
// just outside the edge still count as cover). Every candidate is evaluated against nearby
// enemies before use: a spot within 150m of an enemy is skipped and another is chosen. Spawning
// on the marker edge is the LAST resort - only when no safe covered spot exists at all.
MISSION_CORE_fnc_findCoveredSpawns = {
    params ["_locPos", "_markerSize", "_farDir", "_edgeRadius", ["_side", WEST]];
    private _a = if (count _markerSize > 0) then { _markerSize select 0 } else { 200 };
    private _b = if (count _markerSize > 1) then { _markerSize select 1 } else { 200 };
    private _searchR = (((_a max _b) * 1.4) + 150) max (_edgeRadius + 100);
    private _objects = nearestTerrainObjects [_locPos, ["FOREST", "TREE", "BUSH"], _searchR];
    private _buildings = nearestObjects [_locPos, ["House", "Building", "Strategic", "Fortress"], _searchR];
    // A spot is usable if it sits near the marker (within the edge radius) - it need not be
    // strictly inside the ellipse, so trees/buildings just outside the edge still count.
    private _nearMarker = {
        params ["_p"];
        (_p distance2D _locPos) <= _edgeRadius
    };
    // A spot that sits inside or on top of a giant boulder is unusable - infantry would spawn
    // wedged in the rock.
    private _clearOfRocks = {
        params ["_p"];
        count (nearestTerrainObjects [_p, ["ROCK", "ROCKS", "BOULDER"], 5]) == 0
    };
    private _houseSpots = [];
    private _treeSpots = [];
    {
        private _p = getPos _x;
        if ([_p] call _nearMarker && { [_p] call _clearOfRocks }) then { _houseSpots pushBack _p; };
    } forEach _buildings;
    {
        private _p = getPos _x;
        if ([_p] call _nearMarker) then {
            private _near = nearestTerrainObjects [_p, ["TREE", "BUSH"], 25];
            if (count _near >= 3 && { [_p] call _clearOfRocks }) then { _treeSpots pushBack _p; };
        };
    } forEach _objects;
    if (count _treeSpots == 0 && { count _houseSpots == 0 }) exitWith { [_locPos getPos [_edgeRadius, _farDir]] };
    // Enemy units anywhere near the marker - a spawn next to an enemy is a death trap.
    private _enemies = _locPos nearEntities ["Man", _searchR] select { alive _x && { side _x getFriend _side < 0.6 } };
    private _sortByPlayerDist = {
        params ["_spots"];
        private _playersA = allPlayers select { alive _x };
        private _res = _spots apply {
            private _p = _x;
            private _pd = 1e10;
            { private _d = _p distance _x; if (_d < _pd) then { _pd = _d; }; } forEach _playersA;
            [_pd, _p]
        };
        _res sort false;
        _res apply { _x select 1 }
    };
    // Evaluate each candidate against enemy proximity before it is used: skip any spot within
    // 150m of an enemy. Trees are preferred first, then buildings.
    private _safeTrees = _treeSpots select { private _p = _x; _enemies findIf { _x distance2D _p <= 150 } == -1 };
    if (count _safeTrees > 0) exitWith { [_safeTrees] call _sortByPlayerDist };
    private _safeHouses = _houseSpots select { private _p = _x; _enemies findIf { _x distance2D _p <= 150 } == -1 };
    if (count _safeHouses > 0) exitWith { [_safeHouses] call _sortByPlayerDist };
    [_locPos getPos [_edgeRadius, _farDir]]
};
