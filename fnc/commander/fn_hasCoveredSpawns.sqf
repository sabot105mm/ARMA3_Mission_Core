
// True when a marker has at least one safe covered spawn spot (a building inside the marker, or a
// tree/bush cluster of >= 3 within 25m), clear of giant boulders. Used by the replenish loop to
// decide whether a wiped marker can respawn its garrison or should be captured outright.
MISSION_CORE_fnc_hasCoveredSpawns = {
    params ["_locPos", "_markerSize"];
    private _a = if (count _markerSize > 0) then { _markerSize select 0 } else { 200 };
    private _b = if (count _markerSize > 1) then { _markerSize select 1 } else { 200 };
    private _mkrDir = if (count _markerSize > 2) then { _markerSize select 2 } else { 0 };
    private _searchR = ((_a max _b) * 1.4) + 50;
    private _objects = nearestTerrainObjects [_locPos, ["FOREST", "TREE", "BUSH"], _searchR];
    private _buildings = nearestObjects [_locPos, ["House", "Building", "Strategic", "Fortress"], _searchR];
    private _inside = {
        params ["_p"];
        private _dx = (_p select 0) - (_locPos select 0);
        private _dy = (_p select 1) - (_locPos select 1);
        private _rx = _dx * cos _mkrDir - _dy * sin _mkrDir;
        private _ry = _dx * sin _mkrDir + _dy * cos _mkrDir;
        (_rx*_rx)/(_a*_a) + (_ry*_ry)/(_b*_b) <= 1
    };
    private _clearOfRocks = {
        params ["_p"];
        count (nearestTerrainObjects [_p, ["ROCK", "ROCKS", "BOULDER"], 5]) == 0
    };
    // Any building inside the marker (clear of rocks) is a safe spawn spot
    {
        private _p = getPos _x;
        if ([_p] call _inside && { [_p] call _clearOfRocks }) exitWith { true };
    } forEach _buildings;
    // Any tree/bush cluster (>= 3 within 25m) inside the marker, clear of rocks
    {
        private _p = getPos _x;
        if ([_p] call _inside && { [_p] call _clearOfRocks }) then {
            private _near = _objects select { _x distance2D _p <= 25 };
            if (count _near >= 3) exitWith { true };
        };
    } forEach _objects;
    false
};
