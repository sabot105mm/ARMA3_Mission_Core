// =====================================================================
// ROUTE CACHES
// Lazy, session-long caches that back the road router in
// fn_supplyRoutes.sqf. They exist because the engine work they memoise
// (nearRoads sweeps) is the expensive half of a resolution, and the
// inputs never change mid-mission: roads do not move or vanish, marker
// names are stable.
//
// NOTE: hashmaps in this build reject OBJECT keys (roads) - `set`/`get`
// with a road key throws "Type Object, expected ...". Everything here is
// keyed by marker NAME (a String), and anything that needs a per-road
// store stays in plain identity arrays.
//
// Kept out of fn_supplyRoutes.sqf so that file stays a router, not a
// grab-bag of caches.
// =====================================================================

// Snapped road for a LOCATION record, cached per marker name. The detour loop
// asks the same markers over and over (once per origin for every disconnected
// pair), and `nearRoads` is an engine sweep - so resolve each marker once and
// remember it.
MISSION_CORE_fnc_routeMarkerRoad = {
    params ["_loc"];
    private _name = _loc param [0, ""];
    private _pos = _loc param [1, []];
    if (_name == "") exitWith { objNull };
    if (isNil "MISSION_CORE_MARKER_ROADS") then { MISSION_CORE_MARKER_ROADS = createHashMap; };
    private _road = MISSION_CORE_MARKER_ROADS getOrDefault [_name, 12345];
    if (_road isEqualType 12345) then {
        _road = [_pos, ([_loc] call MISSION_CORE_fnc_routeSnapRadius)] call MISSION_CORE_fnc_routeSnapRoad;
        MISSION_CORE_MARKER_ROADS set [_name, _road];
    };
    _road
};

// Fast name -> record index into MISSION_CORE_CACHED_POSITIONS, so name lookups
// (route planning, recon, defense assignment, manpower) are hashmap hits instead
// of linear scans over the marker list. Built lazily on first use.
//
// This lived only in fnc\fn_cache.sqf, which NOTHING compiles - so every caller
// was calling an undefined variable and the function never existed at runtime.
// It is defined here because fn_routeCaches.sqf is compiled from fn_init.sqf:20,
// before the router that calls it at fn_supplyRoutes.sqf, and because it is a
// cache over a mission-long input, which is exactly this file's job.
//
// resolvePorts prunes nested ports and sets MISSION_CORE_NAME_INDEX back to nil
// (fn_portSystem.sqf), so the next call rebuilds the index from the final list
// rather than handing back stale indices.
MISSION_CORE_fnc_locIndex = {
    if (isNil "MISSION_CORE_CACHED_POSITIONS") exitWith { createHashMap; };
    if (isNil "MISSION_CORE_NAME_INDEX") then {
        MISSION_CORE_NAME_INDEX = createHashMap;
        {
            private _rec = _x;
            if ((_rec isEqualType []) && { count _rec >= 1 }) then {
                MISSION_CORE_NAME_INDEX set [_rec select 0, _forEachIndex];
            };
        } forEach MISSION_CORE_CACHED_POSITIONS;
    };
    MISSION_CORE_NAME_INDEX
};