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

// Marker routability table. Built ONCE after the warm pass has resolved every marker
// pair: ROUTE_CACHE then holds a routed entry for every reachable pair (and the warm
// queue resolved both directions), so the table is derived by one pass over its keys -
// never a fresh road search. The relay fallback (supplyRouteRelay) threads an unroutable
// pair through markers near the straight start->end line by chaining edges from this
// table, upgrading what would otherwise be a straight-line shortcut into a real road path.
//
// Keyed by marker NAME (String) -> array of reachable marker names. The build resolves
// both halves of each "A>B" cache key against the position cache, so quantised-position
// keys (arbitrary points, no names) and any stale names are skipped instead of polluting
// the table. Roads are bidirectional and the cache stores both directions anyway, but the
// dedupe keeps a single key from doubling an edge.
MISSION_CORE_fnc_routeAdjacencyBuild = {
    private _adj = createHashMap;
    if (isNil "MISSION_CORE_ROUTE_CACHE") exitWith { MISSION_CORE_MARKER_ADJACENCY = _adj; };
    if (isNil "MISSION_CORE_CACHED_POSITIONS") exitWith { MISSION_CORE_MARKER_ADJACENCY = _adj; };
    private _idx = call MISSION_CORE_fnc_locIndex;
    {
        private _key = _x;
        private _entry = MISSION_CORE_ROUTE_CACHE getOrDefault [_key, []];
        if (count _entry >= 4 && { (_entry select 1) isEqualType true } && { (_entry select 1) }) then {
            private _parts = _key splitString ">";
            if (count _parts == 2) then {
                private _a = _parts select 0;
                private _b = _parts select 1;
                if ((_idx getOrDefault [_a, -1] >= 0) && { (_idx getOrDefault [_b, -1] >= 0) }) then {
                    private _listA = _adj getOrDefault [_a, []];
                    if (!(_b in _listA)) then { _listA pushBack _b; _adj set [_a, _listA]; };
                    private _listB = _adj getOrDefault [_b, []];
                    if (!(_a in _listB)) then { _listB pushBack _a; _adj set [_b, _listB]; };
                };
            };
        };
    } forEach (keys MISSION_CORE_ROUTE_CACHE);
    MISSION_CORE_MARKER_ADJACENCY = _adj;
    diag_log format ["RELAY TABLE: %1 markers, %2 routable pairs indexed from the route cache", count _adj, count (keys MISSION_CORE_ROUTE_CACHE)];
};

// Is marker _b reachable from marker _a by road (single routed cache entry)? Nil-safe:
// before the warm pass builds the table this answers false, and the relay simply stands down.
MISSION_CORE_fnc_routeAdjacent = {
    params ["_aName", "_bName"];
    if (_aName == "" || { _bName == "" }) exitWith { false };
    if (_aName == _bName) exitWith { false };
    if (isNil "MISSION_CORE_MARKER_ADJACENCY") exitWith { false };
    private _list = MISSION_CORE_MARKER_ADJACENCY getOrDefault [_aName, []];
    (_list find _bName) >= 0
};

// Write-through seed: called from supplyRoute's cache-write sites after a pair resolves,
// so a formerly-refused pair that later becomes routable (a detour marker appeared) is
// indexed for future relay chains the moment it is cached. Existing table untouched when
// the warm build has not run yet.
MISSION_CORE_fnc_routeAdjacentSeed = {
    params ["_aName", "_bName"];
    if (_aName == "" || { _bName == "" }) exitWith {};
    if (_aName == _bName) exitWith {};
    if (isNil "MISSION_CORE_MARKER_ADJACENCY") exitWith {};
    private _listA = MISSION_CORE_MARKER_ADJACENCY getOrDefault [_aName, []];
    if (!(_bName in _listA)) then { _listA pushBack _bName; MISSION_CORE_MARKER_ADJACENCY set [_aName, _listA]; };
    private _listB = MISSION_CORE_MARKER_ADJACENCY getOrDefault [_bName, []];
    if (!(_aName in _listB)) then { _listB pushBack _aName; MISSION_CORE_MARKER_ADJACENCY set [_bName, _listB]; };
};