// =====================================================================
// SHARED SUPPLY ROUTES
// One road-network router, shared by every supply movement system.
//
// SCOPE: supply only. Supply convoys and ammo shipments use this. Nothing
// else does - reinforcement walks its own way, tanks keep their own routing,
// and neither is refactored onto this uninvited. See MISSION_RULES.md.
//
// The road network is NOT prebuilt into a graph. `allRoads` /
// `roadsConnectedTo` ARE the graph, and enumerating them is the expensive
// part, so the design is:
//   - routes are resolved on demand, never up front
//   - each resolution is bounded by a node budget
//   - per-marker snapping is memoised lazily in fn_routeCaches.sqf, so the
//     engine is only ever asked once per marker
//   - results are cached per endpoint pair, quantised to 50m so two markers
//     that differ slightly still share one search
// A marker is the natural unit of travel in this mission, so the cache is
// keyed on marker NAMES wherever the caller has them, and on quantised
// positions only as a fallback for arbitrary points.
//
// NOTE: hashmaps here are keyed by STRING only. This build throws
// "Type Object, expected ..." on any Object key, so the BFS tracks seen
// roads and parents in plain identity arrays rather than hashmaps.
// =====================================================================

// ---------------------------------------------------------------------
// Polyline helpers. These take a path plus its cumulative-length array, and
// are deliberately generic: recon uses them for supply convoys, the player
// manpower convoys and the tank shipments, all of which store the same pair.
// ---------------------------------------------------------------------

// Cumulative segment lengths for a polyline. Returns [_cum, _total].
MISSION_CORE_fnc_routeCum = {
    params ["_path"];
    private _cum = [];
    private _total = 0;
    private _allGood = true;
    private _badAt = -1;
    private _badEl = objNull;
    private _goodSoFar = true;
    for "_i" from 0 to (count _path - 2) do {
        private _a = _path select _i;
        private _b = _path select (_i + 1);
        if ((_a isEqualType []) && { _b isEqualType [] }) then {
            if (_goodSoFar) then {
                _total = _total + (_a distance2D _b);
                _cum pushBack _total;
            };
        } else {
            if (_goodSoFar) then {
                _goodSoFar = false;
                _allGood = false;
                _badAt = _i;
                _badEl = if (_b isEqualType []) then { _a } else { _b };
            };
        };
    };
    if (!_allGood) then {
        if (isNil "MISSION_CORE_ROUTE_BADCUM_LOGGED") then { MISSION_CORE_ROUTE_BADCUM_LOGGED = false; };
        if (!MISSION_CORE_ROUTE_BADCUM_LOGGED) then {
            MISSION_CORE_ROUTE_BADCUM_LOGGED = true;
            private _head = [_path select [0, 5] apply { str _x }] joinString " | ";
            diag_log format ["SUPPLY ROUTE GUARD: routeCum non-array element at segment %1 (%2) in path of %3 - returning empty so the calling loop survives", _badAt, typeName _badEl, count _path];
            diag_log format ["SUPPLY ROUTE GUARD: path head: %1", _head];
        };
        [[], 0]
    } else {
        [_cum, _total]
    };
};

// Straight-line plan for a pair the road search refused. Returns
// [_path, _cum, _dist] or [[], [], 0] for a degenerate pair.
//
// THREE points, not two: routeCum over a 2-point path yields a cum of length
// 1, and both the abstract-leg guard (count _cum < 2) and routeLegWps would
// decline it, so the midpoint keeps every existing consumer working untouched.
// The midpoint is collinear, so the geometry is unchanged - this is the same
// straight line, just shaped like the polylines the rest of the code expects.
//
// Deliberately NOT cached anywhere: ROUTE_CACHE only ever holds solved road
// routes, and the caller keeps supplyRoute's fail backoff, so a later order
// re-searches and upgrades the pair to a real route once one exists.
MISSION_CORE_fnc_straightPlan = {
    params ["_startPos", "_endPos"];
    private _dist = _startPos distance2D _endPos;
    if (_dist < 1) exitWith { [[], [], 0] };
    private _mid = [
        ((_startPos select 0) + (_endPos select 0)) / 2,
        ((_startPos select 1) + (_endPos select 1)) / 2,
        0
    ];
    private _parts = [_startPos, _mid, _endPos] call MISSION_CORE_fnc_routeCum;
    [[_startPos, _mid, _endPos], (_parts select 0), (_parts select 1)]
};

// Position at fraction _frac (0..1) along a polyline. One linear walk.
MISSION_CORE_fnc_convoyPosAt = {
    params ["_path", "_cum", "_frac"];
    if (count _path < 2) exitWith { _path select 0 };
    private _total = _cum select (count _cum - 1);
    if (_total <= 0) exitWith { _path select 0 };
    private _target = _frac * _total;
    // Binary search for the first cumulative point >= _target. Called every
    // per-tick interpolation, so walk the array in log n, not n.
    private _idx = 0;
    if (count _cum > 0) then {
        private _lo = 0;
        private _hi = (count _cum) - 1;
        while { _lo < _hi } do {
            private _m = floor ((_lo + _hi) / 2);
            if ((_cum select _m) >= _target) then { _hi = _m; } else { _lo = _m + 1; };
        };
        _idx = _lo;
    };
    private _prev = if (_idx > 0) then { _cum select (_idx - 1) } else { 0 };
    private _seg = (_cum select _idx) - _prev;
    private _t = if (_seg > 0) then { (_target - _prev) / _seg } else { 0 };
    private _a = _path select _idx;
    private _b = _path select (_idx + 1);
    [
        (_a select 0) + ((_b select 0) - (_a select 0)) * _t,
        (_a select 1) + ((_b select 1) - (_a select 1)) * _t,
        0
    ]
};

// Index of the segment containing fraction _frac. A materialised column uses
// this to start its waypoint list at the NEXT node rather than the leg it is
// already halfway down, so it resumes the road instead of doubling back.
MISSION_CORE_fnc_routeSegAt = {
    params ["_cum", "_frac"];
    if (count _cum == 0) exitWith { 0 };
    private _total = _cum select (count _cum - 1);
    if (_total <= 0) exitWith { 0 };
    private _target = _frac * _total;
    private _lo = 0;
    private _hi = (count _cum) - 1;
    while { _lo < _hi } do {
        private _m = floor ((_lo + _hi) / 2);
        if ((_cum select _m) >= _target) then { _hi = _m; } else { _lo = _m + 1; };
    };
    _lo
};

// ---------------------------------------------------------------------
// Endpoint snapping
// ---------------------------------------------------------------------

// How far from a marker we will still accept a road as "its" road. A big
// marker with no road inside it is normal (a factory straddles a car park),
// so this scales with the footprint instead of using one flat radius.
MISSION_CORE_fnc_routeSnapRadius = {
    params ["_loc", ["_scale", 1]];
    private _base = (["supplyRouteSnapBase", 300] call MISSION_CORE_fnc_tune);
    // The retry ladder widens the snap on its later passes: a port whose only
    // road is 900m from the marker is unreachable at 300 and trivially reachable
    // once the radius grows, and which end is the awkward one is not knowable
    // in advance, so the scale is applied to both ends together.
    if (!(_scale isEqualType 1)) then { _scale = 1; };
    if (_scale < 1) then { _scale = 1; };
    _base = _base * _scale;
    if (isNil "_loc" || { count _loc < 9 }) exitWith { _base };
    private _size = _loc select 8;
    if (!(_size isEqualType [])) exitWith { _base };
    private _r = ((_size select 0) max (_size select 1));
    (_base + _r) max _base
};

// Nearest road to a point, or objNull. `nearRoads` is radius-bounded and
// returns them sorted by distance, so the first hit is the closest.
MISSION_CORE_fnc_routeSnapRoad = {
    params ["_pos", "_radius"];
    if (_radius < 1) then { _radius = 1; };
    ((_pos nearRoads _radius) param [0, objNull])
};

// ---------------------------------------------------------------------
// The search
// ---------------------------------------------------------------------

// Breadth-first search between two road objects. Returns the chain of road
// positions in travel order, or [] if the budget runs out first.
//
// BFS rather than the greedy "hop to whichever road is nearest the target"
// walk this replaced: greedy stalls in local minima (a road that looks closer
// but dead-ends at a river), never backtracks, and after its hop cap just
// gives up. BFS returns a genuinely connected chain - the route a driver
// could actually take - and cannot be trapped.
//
// Costs are bounded: `_seen`/`_parentOf` are plain identity arrays (hashes
// in this build reject Object keys), the queue is walked with a head cursor
// instead of deleteAt-shifting the whole array on every pop, and the node
// budget caps both the frame time and the scan.
//
// The expansion is a nested `while` over a cursor rather than `forEach` with
// `break`. `break` out of a `forEach` that is nested inside a `while` leaves
// the loop-body scope in a state where callers can read the callee's results
// as undefined, which is exactly the failure this used to produce; the
// flag-plus-cursor form has no such jump.
// Registers one neighbour into the search frontier and reports whether it was
// the goal. The arrays are passed in and mutated in place, which keeps the
// flood itself free of nested blocks.
MISSION_CORE_fnc_routeVisit = {
    params ["_next", "_cur", "_seen", "_parentOf", "_queue", "_endRoad"];
    private _isGoal = false;
    if (!(_next in _seen)) then {
        _seen pushBack _next;
        _parentOf pushBack _cur;
        _queue pushBack _next;
        _isGoal = (_next == _endRoad);
    };
    _isGoal
};

// Breadth-first road flood. Returns [_seen, _parentOf, _found].
// Kept deliberately shallow: this engine loses `private` resolution once a
// single function nests code blocks too deeply, after which perfectly
// declared locals read back as undefined variables.
MISSION_CORE_fnc_routeExpand = {
    params ["_startRoad", "_endRoad", "_budget"];
    private _queue = [_startRoad];
    private _qi = 0;
    private _seen = [_startRoad];
    private _parentOf = [objNull];
    private _found = false;
    private _guard = 0;
    private _links = [];
    private _cur = objNull;
    private _next = objNull;
    // WALL-CLOCK BUDGET. A node budget of 25000 (times the retry ladder's grow cap
    // of 4) allows 100k road expansions - enough SQF to block a calling loop for
    // well over the 90s heartbeat the ammo/manpower/queue loops use to detect a
    // dead worker, so one unreachable pair froze those loops while every OTHER
    // loop kept logging (the 17:05:05 and 2026-10-06 live deaths). diag_tickTime
    // is the high-resolution wall clock, so this budget bounds a single search in
    // seconds no matter how large the node budget lets it get - a bail at the
    // tuned limit is still far more generous than a warm-cache hit needs, while
    // an unreachable pair can no longer stall every loop that asks for it. The
    // node budget stays as the place for map-topology-specific widening.
    private _timeBudget = (["supplyRouteTimeBudget", 5] call MISSION_CORE_fnc_tune);
    if (!(_timeBudget isEqualType 1) || { _timeBudget < 0.5 }) then { _timeBudget = 5; };
    private _t0 = diag_tickTime;
    while { !_found && { _qi < count _queue } && { _guard < _budget } && { diag_tickTime - _t0 < _timeBudget } } do {
        _guard = _guard + 1;
        _cur = _queue select _qi;
        _qi = _qi + 1;
        _links = roadsConnectedTo _cur;
        private _j = 0;
        while { !_found && { _j < count _links } } do {
            _next = _links select _j;
            _j = _j + 1;
            if ([_next, _cur, _seen, _parentOf, _queue, _endRoad] call MISSION_CORE_fnc_routeVisit) then { _found = true; };
        };
    };
    [_seen, _parentOf, _found]
};

// Walks the parent links back to the start road and returns the polyline in
// travel order, or [] if the chain is broken or over-long.
MISSION_CORE_fnc_routeChain = {
    params ["_seen", "_parentOf", "_startRoad", "_endRoad"];
    private _out = [];
    private _node = _endRoad;
    private _hops = 0;
    while { _node != _startRoad && { _hops < 500 } } do {
        _hops = _hops + 1;
        _out pushBack (getPos _node);
        private _pi = _seen find _node;
        if (_pi < 0) then { _out = []; } else { _node = _parentOf select _pi; };
    };
    private _final = [];
    if (count _out > 0 && { _node == _startRoad }) then {
        _out pushBack (getPos _startRoad);
        // Walk the parent chain backwards, so the polyline is built in travel
        // order here. The engine's "reverse" command returns a value that
        // leaves the target local undefined in this build, so the reversal is
        // done by index with count/select, which are verified working.
        private _idx = count _out - 1;
        while { _idx >= 0 } do {
            _final pushBack (_out select _idx);
            _idx = _idx - 1;
        };
    };
    _final
};

MISSION_CORE_fnc_routeSearch = {
    params ["_startRoad", "_endRoad", ["_budget", -1]];
    private _out = [];
    if (_budget < 0) then { _budget = (["supplyRouteNodeBudget", 1200] call MISSION_CORE_fnc_tune); };
    if (!(isNull _startRoad) && { !(isNull _endRoad) }) then {
        if (_startRoad == _endRoad) then {
            _out = [(getPos _startRoad), (getPos _endRoad)];
        } else {
            private _exp = [_startRoad, _endRoad, _budget] call MISSION_CORE_fnc_routeExpand;
            if (_exp select 2) then {
                _out = [_exp select 0, _exp select 1, _startRoad, _endRoad] call MISSION_CORE_fnc_routeChain;
            };
        };
    };
    _out
};

// Roads reachable from _startRoad within a bounded flood. Used to find a
// transfer point when two ends are not directly connected.
MISSION_CORE_fnc_routeComponent = {
    params ["_startRoad", ["_cap", 400]];
    private _out = [_startRoad];
    private _seen = [_startRoad];
    private _frontier = [_startRoad];
    private _qi = 0;
    private _n = 0;
    private _cur = objNull;
    private _links = [];
    private _j = 0;
    private _next = objNull;
    while { _qi < count _frontier && { _n < _cap } } do {
        _n = _n + 1;
        _cur = _frontier select _qi;
        _qi = _qi + 1;
        _links = roadsConnectedTo _cur;
        _j = 0;
        while { _j < count _links } do {
            _next = _links select _j;
            _j = _j + 1;
            if (!(_next in _seen)) then {
                _seen pushBack _next;
                _out pushBack _next;
                _frontier pushBack _next;
            };
        };
    };
    _out
};

// ---------------------------------------------------------------------
// Public resolver
// ---------------------------------------------------------------------

// Cache key. Marker names when both ends are known (stable, readable in the
// log), otherwise quantised positions. Quantising to 50m means two requests
// that differ by a few metres of float noise share one search.
MISSION_CORE_fnc_routeCacheKey = {
    params ["_startName", "_endName", "_startPos", "_endPos"];
    if (_startName != "" && { _endName != "" }) exitWith {
        format ["%1>%2", _startName, _endName]
    };
    format [
        "%1,%2>%3,%4",
        round ((_startPos select 0) / 50), round ((_startPos select 1) / 50),
        round ((_endPos select 0) / 50), round ((_endPos select 1) / 50)
    ]
};

// Resolve a road route between two markers (or two raw points).
//
// Returns [_roadPath, _routed, _cum, _dist] where _routed is true when the
// path genuinely follows connected roads. On failure the path is EMPTY and
// _routed is false - this function never returns a straight line, so callers
// that want to ship across open ground anyway build one themselves from the
// supplyRouteStraightFallback tune (routePlan, startConvoy, the port tick).
// _cum/_dist are the polyline's cumulative segment lengths and total, computed
// ONCE and cached with the path - a cache hit never re-walks the route.
//
// Optional detour: when the two ends share no connected road, look for a
// marker whose road sits inside the origin's road component and is a short
// hop away, then chain origin -> transfer -> destination. This is what makes
// an island, a bridge-less river or a divided map routable instead of giving
// up and handing the pair to the straight-line fallback.
// True when a cached location is usable as a transfer point for a detour.
MISSION_CORE_fnc_detourCandidate = {
    params ["_rec", "_startName", "_endName", "_startPos", "_range", "_component"];
    private _ok = false;
    private _name = _rec select 0;
    private _pos = _rec select 1;
    if (_name != _startName && { _name != _endName }) then {
        if (_pos isEqualType []) then {
            if ((_pos distance2D _startPos) <= _range) then {
                private _snap = [_rec] call MISSION_CORE_fnc_routeMarkerRoad;
                if (!(isNull _snap)) then { _ok = _snap in _component; };
            };
        };
    };
    _ok
};

// Chains the two road legs through one transfer road. Returns [] unless both
// legs resolve, so the caller can simply chain several of these together.
MISSION_CORE_fnc_detourLegs = {
    params ["_sRoad", "_viaRoad", "_eRoad"];
    private _out = [];
    private _legA = [_sRoad, _viaRoad] call MISSION_CORE_fnc_routeSearch;
    if (count _legA >= 2) then {
        private _legB = [_viaRoad, _eRoad] call MISSION_CORE_fnc_routeSearch;
        if (count _legB >= 2) then { _out = _legA + _legB; };
    };
    _out
};

// Attempts one transfer point. Returns the finished polyline or [].
MISSION_CORE_fnc_detourTry = {
    params ["_via", "_sRoad", "_eRoad", "_startPos", "_endPos"];
    private _out = [];
    private _viaRoad = [_via] call MISSION_CORE_fnc_routeMarkerRoad;
    if (!(isNull _viaRoad)) then {
        private _legs = [_sRoad, _viaRoad, _eRoad] call MISSION_CORE_fnc_detourLegs;
        if (count _legs >= 4) then {
            _out = [_startPos] + _legs;
            _out pushBack _endPos;
        };
    };
    _out
};

// Builds a road polyline between two ends that share no direct road chain, by
// transferring through a cached location inside the origin's road component.
MISSION_CORE_fnc_supplyDetour = {
    params ["_sRoad", "_eRoad", "_startPos", "_endPos", "_startName", "_endName", ["_hopScale", 1], ["_rangeScale", 1]];
    private _built = [];
    // Component flood memoised per origin. This walk visits up to 400 roads
    // through roadsConnectedTo on every call, and the retry ladder can reach
    // here three times for one pair, so an unmemoised flood was the same 400
    // roads re-walked for nothing. Keyed by marker name when the caller has one,
    // otherwise by the quantised position of the snapped origin road - the same
    // 50m convention routeCacheKey uses, and string keys because this build's
    // HashMaps reject Object keys.
    if (isNil "MISSION_CORE_ROUTE_COMPONENTS") then { MISSION_CORE_ROUTE_COMPONENTS = createHashMap; };
    private _sRoadPos = getPos _sRoad;
    private _compKey = if (_startName != "") then {
        _startName
    } else {
        format ["p%1,%2", round ((_sRoadPos select 0) / 50), round ((_sRoadPos select 1) / 50)]
    };
    private _component = MISSION_CORE_ROUTE_COMPONENTS getOrDefault [_compKey, []];
    if (count _component == 0) then {
        _component = [_sRoad] call MISSION_CORE_fnc_routeComponent;
        MISSION_CORE_ROUTE_COMPONENTS set [_compKey, _component];
    };
    private _hopCap = (["routeDetourMaxHops", 6] call MISSION_CORE_fnc_tune);
    private _range = (["routeDetourSearchRadius", 6000] call MISSION_CORE_fnc_tune);
    // Scaled by the caller's retry pass, so a hard pair that misses on the cheap
    // detour can reach a transfer point further along its component before the
    // resolver gives up. Both scales floor at 1: a pass must never narrow the
    // search below the tuned baseline.
    if (!(_hopScale isEqualType 1)) then { _hopScale = 1; };
    if (!(_rangeScale isEqualType 1)) then { _rangeScale = 1; };
    if (_hopScale < 1) then { _hopScale = 1; };
    if (_rangeScale < 1) then { _rangeScale = 1; };
    _hopCap = ceil (_hopCap * _hopScale);
    _range = _range * _rangeScale;
    // Built with an explicit forEach rather than a "select {}" filter: the
    // filter form made the six-argument call ambiguous to the engine, and it
    // silently accepted entries that were not [name, pos] pairs.
    private _cands = [];
    if (MISSION_CORE_CACHED_POSITIONS isEqualType []) then {
        {
            private _rec = _x;
            if ((_rec isEqualType []) && { count _rec >= 2 }) then {
                private _hit = [_rec, _startName, _endName, _startPos, _range, _component] call MISSION_CORE_fnc_detourCandidate;
                if (_hit) then { _cands pushBack _rec; };
            };
        } forEach MISSION_CORE_CACHED_POSITIONS;
    };
    if (count _cands > 0) then {
        _cands = [_cands, [], { (_x select 1) distance _startPos }, "ASCEND"] call BIS_fnc_sortBy;
        private _hop = 0;
        while { _hop < count _cands && { _hop < _hopCap } } do {
            // Capture the candidate before _hop is advanced, so the log can
            // name the transfer point without index compensation.
            private _rec = _cands select _hop;
            private _try = [_rec, _sRoad, _eRoad, _startPos, _endPos] call MISSION_CORE_fnc_detourTry;
            _hop = _hop + 1;
            if (count _try >= 2) then {
                _built = _try;
                _hop = _hopCap;
                diag_log format ["SUPPLY ROUTE: %1 -> %2 not directly connected, detour via %3 (%4 points)", _startName, _endName, (_rec select 0), count _built];
            };
        };
    };
    _built
};

// ---------------------------------------------------------------------
// Marker relay fallback
// ---------------------------------------------------------------------
//
// When the retry ladder AND the single-transfer detour both fail, a pair is still
// shippable if a chain of markers near the straight start->end line are road-adjacent
// to each other. Each such relayed hop is an already-cached route, so the thread is
// assembled from ROUTE_CACHE only - never a fresh BFS. This upgrades what would have
// been the callers' straight-line shortcut into a real road path.

// 2D distance from point _p to the segment [_a, _b]. Inline projection, no line
// intersection command: the engine's parametric methods are wordy here, and the plain
// AGL [x,y,0] projection is enough to rank marker centres against the start->end line.
MISSION_CORE_fnc_routePointSegDist = {
    params ["_p", "_a", "_b"];
    private _abx = (_b select 0) - (_a select 0);
    private _aby = (_b select 1) - (_a select 1);
    private _len = (_abx * _abx) + (_aby * _aby);
    private _d = 0;
    if (_len < 1) then {
        _d = _p distance2D _a;
    } else {
        private _apx = (_p select 0) - (_a select 0);
        private _apy = (_p select 1) - (_a select 1);
        private _t = (((_apx * _abx) + (_apy * _aby)) / _len);
        if (_t < 0) then { _t = 0; };
        if (_t > 1) then { _t = 1; };
        private _px = (_a select 0) + (_abx * _t);
        private _py = (_a select 1) + (_aby * _t);
        _d = _p distance2D [_px, _py, 0];
    };
    _d
};

// Marker names ranked by distance to the start->end segment, capped at
// supplyRouteRelayCandidates. Prefers the lateral band (supplyRouteRelayLateral); when
// no marker sits inside it - an ocean crossing, say - the closest few overall still
// qualify, because markers on opposite coasts can bridge via roads that follow the bay.
MISSION_CORE_fnc_routeCorridorMarkers = {
    params ["_startPos", "_endPos"];
    private _out = [];
    if (isNil "MISSION_CORE_CACHED_POSITIONS") exitWith { _out };
    if (!(MISSION_CORE_CACHED_POSITIONS isEqualType [])) exitWith { _out };
    private _scored = [];
    {
        private _rec = _x;
        if ((_rec isEqualType []) && { count _rec >= 2 }) then {
            private _d = [_rec select 1, _startPos, _endPos] call MISSION_CORE_fnc_routePointSegDist;
            _scored pushBack [_d, _rec select 0];
        };
    } forEach MISSION_CORE_CACHED_POSITIONS;
    if (count _scored == 0) exitWith { _out };
    _scored sort true;
    private _lateral = (["supplyRouteRelayLateral", 1500] call MISSION_CORE_fnc_tune);
    if (!(_lateral isEqualType 1) || { _lateral < 0 }) then { _lateral = 1500; };
    private _cap = (["supplyRouteRelayCandidates", 8] call MISSION_CORE_fnc_tune);
    if (!(_cap isEqualType 1) || { _cap < 1 }) then { _cap = 8; };
    private _band = _scored select { (_x select 0) <= _lateral };
    private _pool = if (count _band > 0) then { _band } else { _scored };
    private _n = count _pool;
    if (_n > _cap) then { _n = _cap; };
    for "_i" from 0 to (_n - 1) do { _out pushBack ((_pool select _i) select 1); };
    _out
};

// Breadth-first chain over the adjacency table, but only through corridor markers (plus
// the two endpoints). Returns [start, c0, ..., end] or []. Depth-capped at
// supplyRouteRelayMaxHops so a thread is a few real transfers, not a tour of the map.
// Flag-guarded loops in place of break/exitWith jumps: this build loses local scope on a
// forEach->break, so every advance sits behind a _found check instead.
MISSION_CORE_fnc_routeHopChain = {
    params ["_startName", "_endName", "_corridor"];
    private _chain = [];
    if (_startName == "" || { _endName == "" }) exitWith { _chain };
    if (_startName == _endName) exitWith { _chain };
    if (isNil "MISSION_CORE_MARKER_ADJACENCY") exitWith { _chain };
    private _cSet = createHashMap;
    { _cSet set [_x, true]; } forEach _corridor;
    _cSet set [_startName, true];
    _cSet set [_endName, true];
    private _visited = createHashMap;
    _visited set [_startName, true];
    private _parentOf = createHashMap;
    _parentOf set [_startName, ""];
    private _maxHops = (["supplyRouteRelayMaxHops", 3] call MISSION_CORE_fnc_tune);
    if (!(_maxHops isEqualType 1) || { _maxHops < 1 }) then { _maxHops = 3; };
    private _frontier = [_startName];
    private _depth = 0;
    private _found = false;
    while { !_found && { count _frontier > 0 } && { _depth < _maxHops } } do {
        _depth = _depth + 1;
        private _nextF = [];
        {
            private _cur = _x;
            private _links = MISSION_CORE_MARKER_ADJACENCY getOrDefault [_cur, []];
            private _li = 0;
            while { !_found && { _li < count _links } } do {
                private _nxt = _links select _li;
                _li = _li + 1;
                if ((_cSet getOrDefault [_nxt, false]) && { !(_visited getOrDefault [_nxt, false]) }) then {
                    _visited set [_nxt, true];
                    _parentOf set [_nxt, _cur];
                    if (_nxt == _endName) then { _found = true; } else { _nextF pushBack _nxt; };
                };
            };
        } forEach _frontier;
        _frontier = _nextF;
    };
    if (_found) then {
        private _rev = [];
        private _node = _endName;
        private _guardH = 0;
        while { _node != _startName && { _guardH < 500 } } do {
            _guardH = _guardH + 1;
            _rev pushBack _node;
            _node = _parentOf getOrDefault [_node, ""];
        };
        _rev pushBack _startName;
        private _idx = count _rev - 1;
        while { _idx >= 0 } do {
            _chain pushBack (_rev select _idx);
            _idx = _idx - 1;
        };
    };
    _chain
};

// Threads an unroutable pair through road-adjacent corridor markers. Returns the stitched
// polyline, or [] when the table is missing or no chain threads (caller keeps the refusal
// and straight-line fallback). Each leg is read straight out of ROUTE_CACHE - adjacency
// guarantees the entry exists - so this never re-searches and never recurses into
// supplyRoute. Legs already begin at their from-marker position and end at their to-marker
// position, so stitching drops each junction's duplicated point.
MISSION_CORE_fnc_supplyRouteRelay = {
    params ["_startName", "_endName", "_startPos", "_endPos"];
    private _out = [];
    if (_startName == "" || { _endName == "" }) exitWith { _out };
    if (isNil "MISSION_CORE_MARKER_ADJACENCY") exitWith { _out };
    if ((["supplyRouteRelayEnabled", 1] call MISSION_CORE_fnc_tune) <= 0) exitWith { _out };
    private _corridor = [_startPos, _endPos] call MISSION_CORE_fnc_routeCorridorMarkers;
    if (count _corridor == 0) exitWith { _out };
    private _chain = [_startName, _endName, _corridor] call MISSION_CORE_fnc_routeHopChain;
    if (count _chain < 3) exitWith { _out };
    if (isNil "MISSION_CORE_ROUTE_CACHE") exitWith { _out };
    private _legs = [];
    private _ok = true;
    private _ci = 0;
    while { _ci < (count _chain - 1) && { _ok } } do {
        private _a = _chain select _ci;
        private _b = _chain select (_ci + 1);
        private _key = [_a, _b, _startPos, _endPos] call MISSION_CORE_fnc_routeCacheKey;
        private _entry = MISSION_CORE_ROUTE_CACHE getOrDefault [_key, []];
        if (count _entry >= 4 && { (_entry select 1) isEqualType true } && { (_entry select 1) }) then {
            _legs pushBack (_entry select 0);
        } else {
            _ok = false;
        };
        _ci = _ci + 1;
    };
    if (!_ok || { count _legs == 0 }) exitWith { _out };
    private _path = _legs select 0;
    private _li = 1;
    while { _li < count _legs } do {
        private _seg = _legs select _li;
        private _si = 1;
        while { _si < count _seg } do {
            _path pushBack (_seg select _si);
            _si = _si + 1;
        };
        _li = _li + 1;
    };
    private _cumParts = [_path] call MISSION_CORE_fnc_routeCum;
    if (count (_cumParts select 0) == 0) exitWith { [] };
    diag_log format ["SUPPLY ROUTE: %1 -> %2 relayed via %3 (%4 legs, %5m, %6 points)", _startName, _endName, ([_chain select [1, (count _chain - 2)]] joinString ", "), count _legs, round (_cumParts select 1), count _path];
    _path
};

MISSION_CORE_fnc_supplyRoute = {
    params [
        "_startPos", "_endPos",
        ["_startName", ""], ["_endName", ""],
        ["_startLoc", []], ["_endLoc", []],
        ["_allowDetour", true]
    ];
    if (isNil "MISSION_CORE_ROUTE_CACHE") then { MISSION_CORE_ROUTE_CACHE = createHashMap; };
    if (isNil "MISSION_CORE_ROUTE_FAILS") then { MISSION_CORE_ROUTE_FAILS = createHashMap; };

    private _key = [_startName, _endName, _startPos, _endPos] call MISSION_CORE_fnc_routeCacheKey;
    private _hit = MISSION_CORE_ROUTE_CACHE getOrDefault [_key, []];
    // Only a routed plan is ever handed back from the cache. A cached entry that
    // is not routed is ignored and the search runs again: a variable that
    // survived a hot reload can still hold a straight line from the old code.
    private _hitRouted = false;
    if (count _hit >= 4 && { (_hit select 1) isEqualType true }) then { _hitRouted = _hit select 1; };
    if (_hitRouted) exitWith { _hit };

    // Negative cache, and this is NOT the straight-line cache the old code had.
    // It stores no path at all - only "this pair was searched at T, try again
    // after T', N times so far". It exists because the router is called every
    // tick for every port, and pass 3 of the ladder below expands over 150k nodes:
    // without a backoff a single disconnected pair re-paid that whole search on
    // every tick forever. The entry expires, and each expiry searches HARDER than
    // the last, so a pair blocked by an out-of-range detour marker still resolves
    // as soon as that marker is reachable. Nothing is ever stored here but that
    // deadline - the straight-line fallback, when enabled, lives in routePlan and
    // the two direct callers, and is rebuilt fresh on every dispatch.
    private _fail = MISSION_CORE_ROUTE_FAILS getOrDefault [_key, []];
    private _attempts = if (count _fail >= 2) then { _fail select 1 } else { 0 };
    private _failValid = false;
    if (count _fail >= 2) then { _failValid = time < (_fail select 0); };
    private _direct = [];
    private _routed = false;
    if (_failValid) then {
        // The search is deferred on backoff, but the relay is NOT a search: it ranks
        // corridor markers and reads already-cached leg routes, so a pair refused during
        // the warm pass (now sitting in backoff) can still be threaded the moment its
        // corridor routes exist. Without this it would stay refused until the backoff
        // expires - up to 10 minutes - even though a relay appeared in the meantime.
        _direct = [_startName, _endName, _startPos, _endPos] call MISSION_CORE_fnc_supplyRouteRelay;
        if (count _direct >= 2) then { _routed = true; };
        if (!_routed) exitWith { [[], false, [], 0] };
    };

    // Attempt ladder. A pair that misses the cheap pass is retried with a wider
    // snap radius, a deeper node budget and a longer detour reach before it is
    // declared unreachable. Growing the search on failure is the entire point of
    // this change: the old code searched once and cached whatever came back, so
    // one unlucky first try permanently condemned a pair to "no route" and made
    // the budget tuning below appear to do nothing on a warm cache.
    //
    // The grow factor also steps up on every expiry, so a pair that stays
    // unreachable degrades into a slow background retry rather than either
    // hammering the search or being written off.
    //
    // It is clamped, and the clamp is not cosmetic. Left uncapped, 2.5 raised to
    // the third step is 15.6, and pass 3 scaling the budget by that SQUARED is
    // 244x the base - 6.1 million node expansions for one pair on one tick. The
    // ladder is meant to try harder, not to eventually hang the server.
    private _grow = (["supplyRouteRetryGrow", 2.5] call MISSION_CORE_fnc_tune);
    if (!(_grow isEqualType 1)) then { _grow = 2.5; };
    private _maxGrowSteps = (["supplyRouteRetryGrowSteps", 3] call MISSION_CORE_fnc_tune);
    if (_maxGrowSteps < 0) then { _maxGrowSteps = 0; };
    if (_attempts > _maxGrowSteps) then { _attempts = _maxGrowSteps; };
    _grow = _grow ^ _attempts;
    if (_grow < 1) then { _grow = 1; };
    private _growMax = (["supplyRouteRetryGrowMax", 4] call MISSION_CORE_fnc_tune);
    if (!(_growMax isEqualType 1) || { _growMax < 1 }) then { _growMax = 4; };
    if (_grow > _growMax) then { _grow = _growMax; };
    private _tuneBase = (["supplyRouteSnapBase", 300] call MISSION_CORE_fnc_tune);
    private _tuneBudget = (["supplyRouteNodeBudget", 1200] call MISSION_CORE_fnc_tune);
    // [snap scale, node budget scale, detour hop scale, detour range scale].
    // Pass 1 is the normal route. Pass 2 widens snap and budget together, which
    // is what rescues an endpoint sitting off the road network. Pass 3 keeps
    // the snap at baseline and only deepens the flood, so a pair that needs a
    // long chain is not penalised by an over-wide snap picking a worse road.
    // Budget scales LINEARLY with _grow, never with its square: at the tuned
    // base of 25000 a squared scale reaches 6.1M nodes and stalls the tick.
    private _passes = [
        [1, 1, 1, 1],
        [_grow, _grow, _grow, 1],
        [1, _grow, 1, _grow]
    ];
    // Cursor plus flag rather than break, matching the search helpers: a break
    // out of a nested loop left callers reading locals as undefined in this build.
    private _pi = 0;
    while { _pi < count _passes && { !_routed } } do {
        private _pass = _passes select _pi;
        _pi = _pi + 1;
        private _sRad = [_startLoc, (_pass select 0)] call MISSION_CORE_fnc_routeSnapRadius;
        private _eRad = [_endLoc, (_pass select 0)] call MISSION_CORE_fnc_routeSnapRadius;
        private _sRoad = [_startPos, _sRad] call MISSION_CORE_fnc_routeSnapRoad;
        private _eRoad = [_endPos, _eRad] call MISSION_CORE_fnc_routeSnapRoad;
        if (!isNull _sRoad && { !isNull _eRoad }) then {
            private _chain = [_sRoad, _eRoad, (_tuneBudget * (_pass select 1))] call MISSION_CORE_fnc_routeSearch;
            if (count _chain >= 2) then {
                private _route = [_startPos] + _chain;
                _route pushBack _endPos;
                _direct = _route;
                _routed = true;
            } else {
                // No direct chain. Detour resolution lives in its own shallow
                // helpers; inlining it here is what pushed this function past the
                // nesting depth at which the engine loses local variable scope.
                if (_allowDetour) then {
                    private _detour = [_sRoad, _eRoad, _startPos, _endPos, _startName, _endName, (_pass select 2), (_pass select 3)] call MISSION_CORE_fnc_supplyDetour;
                    if (count _detour >= 2) then {
                        _direct = _detour;
                        _routed = true;
                    };
                };
            };
        };
    };

    // A straight line is not a ROAD answer, so this function never returns one.
    // Unreachable pairs return an explicit failure here, and the failure is never
    // cached AS a route. What is recorded is only a backoff deadline, so the next
    // request in the same tick is cheap while a later one still gets a fresh,
    // wider search. Callers that want to ship anyway take the empty path and
    // build their own straight line (supplyRouteStraightFallback): routePlan does
    // it for abstract ammo/legs/armor, startConvoy for supply trucks, and the port
    // tick for manpower - each one independently, so this stays the pure router.
    // Marker relay fallback. The retry ladder and the single-transfer detour both failed;
    // before writing the pair off, try threading it through markers near the straight
    // start->end line that are road-adjacent to each other (the warm pass's adjacency
    // table). Only runs once that table exists - during the warm pass it is nil, so a
    // refused pair keeps today's behaviour until the warm pass finishes. Legs are read
    // from ROUTE_CACHE, never re-searched, so the attempt is cheap. A pair this cannot
    // thread falls through to the refusal below and the callers' straight-line fallback.
    if (!_routed) then {
        _direct = [_startName, _endName, _startPos, _endPos] call MISSION_CORE_fnc_supplyRouteRelay;
        if (count _direct >= 2) then { _routed = true; };
    };
    if (!_routed) exitWith {
        private _backoff = (["supplyRouteFailBackoff", 30] call MISSION_CORE_fnc_tune);
        if (!(_backoff isEqualType 1) || { _backoff < 5 }) then { _backoff = 30; };
        private _cap = (["supplyRouteFailBackoffMax", 600] call MISSION_CORE_fnc_tune);
        if (!(_cap isEqualType 1) || { _cap < _backoff }) then { _cap = _backoff; };
        private _wait = _backoff * (_attempts + 1) min _cap;
        MISSION_CORE_ROUTE_FAILS set [_key, [time + _wait, _attempts + 1]];
        // Each unroutable pair logs exactly once per run: its first refusal puts
        // it on the fail backoff, so warm (or a live loop) does not re-log it on
        // the next tick. That one line is the pair that was freezing the ammo and
        // manpower loops for 90s+ - the wall-clock guard bounds the search, but a
        // blocked-for-minutes loop is only diagnosable if the reason is visible.
        diag_log format ["SUPPLY ROUTE: %1 -> %2 no connected road route after %3 passes - refused, retrying in %4s", _startName, _endName, count _passes, round _wait];
        [[], false, [], 0]
    };

    private _cumParts = [_direct] call MISSION_CORE_fnc_routeCum;
    private _cum = _cumParts select 0;
    private _dist = _cumParts select 1;
    if (count _direct >= 2 && { count _cum == 0 }) exitWith {
        diag_log format ["SUPPLY ROUTE: %1 -> %2 corrupt path rejected (%3 points)", _startName, _endName, count _direct];
        [[], false, [], 0]
    };
    MISSION_CORE_ROUTE_CACHE set [_key, [_direct, true, _cum, _dist]];
    MISSION_CORE_ROUTE_FAILS deleteAt _key;
    [_startName, _endName] call MISSION_CORE_fnc_routeAdjacentSeed;

    // Store the opposite direction from the same search. Roads are bidirectional,
    // so the reverse of a solved A->B polyline IS a valid B->A plan. That halves
    // the pre-warmer's search count and means a return convoy hits a warm cache
    // without ever searching. Rebuilt with an explicit index walk for the same
    // reason routeChain does: reverse is not dependable in this build. An
    // existing reverse entry is left alone - it was either solved independently
    // or written by an earlier pass, and both are equally correct.
    private _rkey = [_endName, _startName, _endPos, _startPos] call MISSION_CORE_fnc_routeCacheKey;
    private _rExisting = MISSION_CORE_ROUTE_CACHE getOrDefault [_rkey, []];
    private _rOk = false;
    if (count _rExisting >= 4 && { (_rExisting select 1) isEqualType true }) then { _rOk = _rExisting select 1; };
    if (!_rOk) then {
        private _pts = count _direct;
        private _rev = [];
        private _ri = _pts - 1;
        while { _ri >= 0 } do {
            _rev pushBack (_direct select _ri);
            _ri = _ri - 1;
        };
        private _revCumParts = [_rev] call MISSION_CORE_fnc_routeCum;
        MISSION_CORE_ROUTE_CACHE set [_rkey, [_rev, true, (_revCumParts select 0), (_revCumParts select 1)]];
        [_endName, _startName] call MISSION_CORE_fnc_routeAdjacentSeed;
    };
    [_direct, true, _cum, _dist]
};

// ---------------------------------------------------------------------
// Pre-warm pass
// ---------------------------------------------------------------------

// Resolve every marker pair up front so the first convoy order of the session is
// a cache hit instead of a BFS.
//
// This does not make the search cheaper, it moves it. A BFS bounded at 25k nodes
// costs real milliseconds no matter when it runs; what changes is WHEN. Paying
// it here, before players are engaged and spread over a sleep between batches,
// is the difference between a warm cache and a stutter the first time someone
// orders a convoy between two markers nobody has driven yet.
//
// Spread deliberately: routeWarmPairsPerWake pairs, then sleep. A batch big
// enough to drain the queue in one pass would just relocate the hitch to init.
// Opposite directions come free from supplyRoute's reverse cache, so warming
// A->B also warms B->A and half the queue resolves without a second search.
MISSION_CORE_fnc_routeWarmLoop = {
    private _enabled = ["routeWarmEnabled", true] call MISSION_CORE_fnc_tune;
    if (!_enabled) exitWith {};

    // The router reads CACHED_POSITIONS; if init is still building it, wait
    // rather than warming an empty list and reporting success.
    private _waited = 0;
    while {
        (isNil "MISSION_CORE_CACHED_POSITIONS" || { !(MISSION_CORE_CACHED_POSITIONS isEqualType []) })
        && { _waited < 120 }
    } do {
        sleep 1;
        _waited = _waited + 1;
    };
    if (isNil "MISSION_CORE_CACHED_POSITIONS" || { !(MISSION_CORE_CACHED_POSITIONS isEqualType []) }) exitWith {
        diag_log "ROUTE WARM: no position cache after 120s - skipping pre-warm";
    };

    private _names = [];
    {
        private _rec = _x;
        if ((_rec isEqualType []) && { count _rec >= 2 }) then { _names pushBack (_rec select 0); };
    } forEach MISSION_CORE_CACHED_POSITIONS;
    private _n = count _names;
    if (_n < 2) exitWith { diag_log format ["ROUTE WARM: only %1 marker(s) - nothing to pre-resolve", _n] };

    // Flat queue of ordered pairs. Ordered, not unordered: supplyRoute stores
    // the opposite direction from a solved search, so the second half of the
    // queue is nearly all cache hits and costs almost nothing.
    private _queue = [];
    for "_i" from 0 to (_n - 1) do {
        for "_j" from 0 to (_n - 1) do {
            if (_i != _j) then { _queue pushBack [_names select _i, _names select _j]; };
        };
    };

    private _perWake = ["routeWarmPairsPerWake", 2] call MISSION_CORE_fnc_tune;
    if (!(_perWake isEqualType 1) || { _perWake < 1 }) then { _perWake = 2; };
    private _rest = ["routeWarmSleep", 0.5] call MISSION_CORE_fnc_tune;
    if (!(_rest isEqualType 1) || { _rest < 0.05 }) then { _rest = 0.5; };

    private _total = count _queue;
    private _idx = call MISSION_CORE_fnc_locIndex;
    private _t0 = diag_tickTime;
    private _resolved = 0; private _routedN = 0; private _failedN = 0; private _skipped = 0;
    private _qi = 0; private _batchNo = 0;
    diag_log format ["ROUTE WARM: %1 markers, %2 ordered pairs, %3 per wake", _n, _total, _perWake];
    while { _qi < _total } do {
        private _batch = [];
        private _b = 0;
        while { _b < _perWake && { _qi < _total } } do {
            _batch pushBack (_queue select _qi);
            _qi = _qi + 1;
            _b = _b + 1;
        };
        {
            private _pair = _x;
            if (!(_pair isEqualType [])) then { continue; };
            private _aN = _pair select 0;
            private _bN = _pair select 1;
            private _aI = _idx getOrDefault [_aN, -1];
            private _bI = _idx getOrDefault [_bN, -1];
            if (_aI < 0 || { _bI < 0 }) then {
                _skipped = _skipped + 1;
            } else {
                private _aRec = MISSION_CORE_CACHED_POSITIONS select _aI;
                private _bRec = MISSION_CORE_CACHED_POSITIONS select _bI;
                private _res = [(_aRec select 1), (_bRec select 1), _aN, _bN, _aRec, _bRec] call MISSION_CORE_fnc_supplyRoute;
                _resolved = _resolved + 1;
                if (_res select 1) then { _routedN = _routedN + 1; } else { _failedN = _failedN + 1; };
            };
        } forEach _batch;
        _batchNo = _batchNo + 1;
        if (_batchNo mod 20 == 0) then {
            diag_log format ["ROUTE WARM: %1/%2 pairs (%3 routed, %4 unroutable)", _resolved, _total, _routedN, _failedN];
        };
        sleep _rest;
    };
    diag_log format [
        "ROUTE WARM: done - %1/%2 pairs resolved (%3 routed, %4 unroutable, %5 skipped) in %6s",
        _resolved, _total, _routedN, _failedN, _skipped,
        round ((diag_tickTime - _t0) / 1000)
    ];
    // A disconnected island pair is worth seeing explicitly once the pass ends.
    if (_failedN > 0) then {
        diag_log format ["ROUTE WARM: %1 pair(s) have no connected road route - they relay through near-line markers (or refuse) once the table below is built", _failedN];
    };
    // Marker relay table. Every pair now has a verdict in the route cache or the fail
    // backoff, so this pass is the moment the reachable-marker index is FINAL. Built
    // here so relay routes the warm itself produced are in the table too: from now on a
    // live refusal can thread through near-line markers instead of shipping straight.
    call MISSION_CORE_fnc_routeAdjacencyBuild;
};

// ---------------------------------------------------------------------
// Cargo presentation
// ---------------------------------------------------------------------

// Trucks needed for a load. Authored as tune keys so column length stays a
// balance decision rather than a number buried in a spawn loop.
MISSION_CORE_fnc_supplyTruckCount = {
    params ["_amount", ["_perTruck", -1]];
    if (_perTruck < 0) then { _perTruck = (["convoySupplyPerTruck", 100] call MISSION_CORE_fnc_tune); };
    if (_perTruck <= 0) then { _perTruck = 100; };
    private _max = (["convoyColumnMax", 6] call MISSION_CORE_fnc_tune);
    if (_max < 1) then { _max = 1; };
    ((ceil (_amount / _perTruck)) max 1) min _max
};

// Truck class for a cargo kind. Supply keeps its existing behaviour of taking
// whatever Truck_F the REDFOR transport pool offers (so a modpack that ships a
// different truck still drives the supply run) and falls back to the vanilla
// covered cargo truck. Ammo and manpower get their own vehicles so the three
// cargo classes are readable on the map at a glance.
//
// Every class is config-checked before it is used. A class that does not exist
// would otherwise fail deep inside safeVehicleSpawn and refund the whole
// shipment, which reads as a spawn bug rather than a missing entry in a config.
MISSION_CORE_fnc_convoyTruckClass = {
    params [["_kind", "supply"]];
    private _kind = toLower _kind;
    private _pick = "";
    if (_kind == "ammo") then {
        _pick = (["convoyTruckAmmo", "O_Truck_02_reammo_F"] call MISSION_CORE_fnc_tune);
    } else {
        if (_kind == "manpower") then {
            _pick = (["convoyTruckManpower", "O_Truck_01_transport_F"] call MISSION_CORE_fnc_tune);
        } else {
            {
                private _c = _x;
                if (_c isKindOf "Truck_F") exitWith { _pick = _c; };
            } forEach ((MISSION_CORE_REDFOR_DATA select 7) getOrDefault ["transport", []]);
        };
    };
    private _fallback = (["convoyTruckSupply", "O_Truck_02_covered_F"] call MISSION_CORE_fnc_tune);
    if (_pick != "" && { isClass (configFile >> "CfgVehicles" >> _pick) }) exitWith { _pick };
    if (_fallback != "" && { isClass (configFile >> "CfgVehicles" >> _fallback) }) exitWith { _fallback };
    "O_Truck_02_covered_F"
};

// Loot crate class for a lost supply shipment, read from the REDFOR cargo data
// instead of being hardcoded. Extracted from the convoy loop, which had it inline
// while recon strike had a private "Box_East_Ammo_F" copy that ignored the modpack
// entirely - so a REDFOR install got the wrong crate whenever recon killed a
// shipment. One resolver, one behaviour.
MISSION_CORE_fnc_convoyLootBoxClass = {
    private _boxClass = "";
    {
        // Ammo-box entries are class-name strings in some builds and [class, ...]
        // pairs in others - normalise whichever way it is stored.
        private _cand = _x;
        private _bName = if (_cand isEqualType "") then { _cand } else {
            if (_cand isEqualType [] && { count _cand > 0 }) then { _cand select 0 } else { "" };
        };
        if (_bName != "") exitWith { _boxClass = _bName; };
    } forEach ((MISSION_CORE_REDFOR_DATA select 11) select { true });
    if (_boxClass == "") then { _boxClass = "Box_East_Ammo_F"; };
    _boxClass
};

// Anger the enemy for cargo that will never arrive, in one place.
//
// Every loss path has to go through this: a convoy lost to a player, to a broken
// axle, or to recon fire support all shorten the enemy's logistics the same amount,
// so the cost is derived only from what was lost. Recon previously had three
// private copies of this and none of them applied it at all, which made fire
// support a free damage source.
//
// _lostAmount is in whatever unit that cargo class counts (supply, men, vehicles).
MISSION_CORE_fnc_convoyLossAggression = {
    params ["_lostAmount", "_cause"];
    if (!(_lostAmount isEqualType 1) || { _lostAmount <= 0 }) exitWith {};
    private _aggGain = _lostAmount * (["aggressionConvoyPerSupply", 0.25] call MISSION_CORE_fnc_tune);
    if (_aggGain <= 0) exitWith {};
    [_aggGain] call MISSION_CORE_fnc_aggressionAdd;
    diag_log format ["AGGRESSION: %1 lost cargo +%2 anger (amount %3)", _cause, round _aggGain, round _lostAmount];
    _aggGain
};

// Drop tombstoned records from a shipment array, in place.
//
// SQF arrays are reference types, so resizing and re-appending updates whichever
// global holds this array - the caller does not have to name it, which is what
// keeps array ownership with the system that declared it.
MISSION_CORE_fnc_shipmentCompact = {
    params ["_array"];
    if (!(_array isEqualType [])) exitWith {};
    private _keep = _array select { count _x > 0 };
    if (count _keep == count _array) exitWith {};
    _array resize 0;
    _array append _keep;
    count _array
};

// A convoy that was hit but survived: it keeps part of its cargo and, while still
// abstract, is slowed. Loss is scored on what actually failed to arrive, not on
// the shipment's full value, so a strike that only clips a convoy is worth less
// anger than one that kills it.
MISSION_CORE_fnc_convoyShipmentDamage = {
    params ["_record", ["_keepFactor", 0.5], ["_slowFactor", 1.3]];
    if (!(_record isEqualType []) || { count _record < 9 }) exitWith { 0 };
    _record params ["_prov", "_recv", "_roadPath", "_cum", "_travelTime", "_departTime", "_amount", "_state"];
    if (!(_amount isEqualType 1) || { _amount <= 0 }) exitWith { 0 };
    private _surviving = floor (_amount * _keepFactor);
    private _lost = _amount - _surviving;
    _record set [6, _surviving];
    // Only an abstract convoy can be slowed - a live column is already on the road
    // and its ETA is owned by the driving code.
    if (_state == 0) then { _record set [4, _travelTime * _slowFactor]; };
    [_lost, format ["convoy %1 -> %2", _prov, _recv]] call MISSION_CORE_fnc_convoyLossAggression;
    _lost
};

// Resolve a convoy that was lost before it ever had a vehicle - the abstract case.
// The convoy loop already owns this outcome for materialised shipments (kill the
// truck, the loop notices, drops loot, pays renown, angers the enemy); an abstract
// shipment has no truck for anyone to damage, so whichever cause loses it has to ask
// supply to apply the same policy here.
//
// Lives on the supply side deliberately. Recon strike used to resolve this itself:
// it hardcoded the crate, skipped the aggression cost, skipped the loot cap, and
// wrote a dead flag into a supply-owned record. Supply must keep working with the
// whole recon system absent, so nothing in a convoy record is defined by recon.
//
// Returns true if this call resolved the shipment, false if it was already dead or
// had already been revealed as arrived (so a double-strike cannot pay out twice).
MISSION_CORE_fnc_convoyDisbandAbstract = {
    params ["_record", ["_cause", "SUPPLY ROUTE LOST"]];
    if (!(_record isEqualType [])) exitWith { false };
    if (_record param [11, false]) exitWith { false };
    if (!(_record param [12, ""] isEqualType "")) exitWith { false };
    _record params ["_prov", "_recv", "_roadPath", "_cum", "_travelTime", "_departTime", "_amount"];
    private _renownGain = [["renownPerConvoy", 15] call MISSION_CORE_fnc_tune] call MISSION_CORE_fnc_awardRenown;
    [_amount, format ["convoy %1 -> %2", _prov, _recv]] call MISSION_CORE_fnc_convoyLossAggression;
    // An abstract shipment is a single cargo record, so there is exactly one crate
    // to drop. The cap still applies: it bounds total loot, not crates per shipment.
    // Clamped in place rather than via a recon helper: supply must not call back
    // into the system that calls into it.
    private _frac = 0;
    if (_travelTime isEqualType 1 && { _travelTime > 0 }) then {
        _frac = ((time - _departTime) / _travelTime) min 1;
        if (_frac < 0) then { _frac = 0; };
    };
    private _curPos = [_roadPath, _cum, _frac] call MISSION_CORE_fnc_convoyPosAt;
    private _boxClass = call MISSION_CORE_fnc_convoyLootBoxClass;
    createVehicle [_boxClass, _curPos, [], 0, "CAN_COLLIDE"];
    _record set [11, true];
    ["DynOps_ConvoyDestroyed",
        ["CONVOY DESTROYED", format ["%1 -> %2 lost! Renown +%3", _prov, _recv, _renownGain]]
    ] remoteExec ["BIS_fnc_showNotification", 0];
    diag_log format ["DYNAMIC CONVOY: %1 -> %2 lost before arrival (%3) - 1 box dropped", _prov, _recv, _cause];
    true
};

// Materialise one cargo column on the road at fraction _frac of its journey.
// Shared by all three cargo classes so supply, manpower and ammo all drive the
// road polyline they were routed along and spawn behind the leader in echelon.
//
// Returns [_trucks, _groups, _truckClass, _curPos, _requested]. Trucks/groups are
// positionally aligned and may contain objNull/grpNull where a spawn failed, so
// callers must filter for live vehicles rather than trusting the count.
MISSION_CORE_fnc_spawnConvoyColumn = {
    params ["_path", "_cum", "_frac", "_amount", ["_kind", "supply"], ["_perTruck", -1]];
    private _trucks = [];
    private _groups = [];
    private _curPos = [_path, _cum, _frac] call MISSION_CORE_fnc_convoyPosAt;
    private _truckClass = [_kind] call MISSION_CORE_fnc_convoyTruckClass;
    private _nTrucks = [_amount, _perTruck] call MISSION_CORE_fnc_supplyTruckCount;
    if (count _path < 2) exitWith { [_trucks, _groups, _truckClass, _curPos, _nTrucks] };

    // The REMAINDER of the road path from where the convoy is right now. A
    // single waypoint at the destination (the old behaviour) made the whole
    // road search cosmetic - the truck drove straight at the target and crossed
    // whatever lay in the way. Taking the remaining ROAD NODES fixed that, but
    // left waypoint density at the mercy of the road network: two waypoints on one
    // route and forty on the next, so long shipments crawled while short ones
    // snapped. A fixed stride walk gives every shipment the same comfortable pace.
    private _dest = _path select (count _path - 1);
    private _wps = [_path, _cum, _frac, _dest] call MISSION_CORE_fnc_routeLegWps;
    // routeLegWps stops emitting legs once the NEXT one lands inside
    // routeLegFinalRadius, so by construction the destination is never in _wps. It is
    // always appended as the trailing waypoint - without it the truck exhausts its
    // waypoint list short of the target and sits there. Appending it also guarantees
    // _wps is non-empty, which is what _legA below relies on.
    _wps pushBack _dest;

    // Column: a heavy load is split over several trucks echeloned back along
    // the road behind the leader, so a long shipment reads as a real convoy.
    private _gap = (["convoyColumnSpacing", 14] call MISSION_CORE_fnc_tune);
    if (_gap < 4) then { _gap = 4; };
    private _legA = _wps select 0;
    private _dx = (_legA select 0) - (_curPos select 0);
    private _dy = (_legA select 1) - (_curPos select 1);
    private _legLen = sqrt (_dx * _dx + _dy * _dy);
    private _ux = if (_legLen > 0.1) then { _dx / _legLen } else { 1 };
    private _uy = if (_legLen > 0.1) then { _dy / _legLen } else { 0 };

    for "_t" from 0 to (_nTrucks - 1) do {
        private _row = floor (_t / 2);
        private _lateral = (if ((_t - (_row * 2)) == 0) then { 1 } else { -1 }) * _row * _gap;
        private _rear = _t * _gap;
        private _spot = [
            (_curPos select 0) - (_ux * _rear) - (_uy * _lateral),
            (_curPos select 1) - (_uy * _rear) + (_ux * _lateral),
            0
        ];
        private _land = [_spot] call MISSION_CORE_fnc_ensureLandPos;
        private _spawn = [_land, _spot, [60, 60]] call MISSION_CORE_fnc_safeVehicleSpawnPos;
        if (count _spawn == 2) then { _spawn pushBack 0; };
        if (count _spawn < 3) then { _trucks pushBack objNull; _groups pushBack grpNull; continue; };
        private _newTruck = [_truckClass, _spawn] call MISSION_CORE_fnc_safeVehicleSpawn;
        if (isNull _newTruck) then { _trucks pushBack objNull; _groups pushBack grpNull; continue; };
        _newTruck setVariable ["MISSION_CORE_CONVOY_TRUCK", true];
        _newTruck setVariable ["MISSION_CORE_TRUCK_ORIGIN", _spawn];
        private _drvGrp = createGroup EAST;
        _drvGrp addVehicle _newTruck;
        private _drv = _drvGrp createUnit ["O_crew_F", _spawn, [], 0, "NONE"];
        _drv moveInDriver _newTruck;
        _drvGrp setBehaviour "CARELESS";
        _drvGrp setCombatMode "GREEN";
        _drvGrp setSpeedMode "FULL";
        // Counted, not isNull-tested: `addWaypoint` returns an ARRAY here, so isNull on a
        // waypoint is a hard type error ("Type Array, expected Object,Group,..."). The
        // first waypoint is what the driver group sets current on, so it must be captured,
        // and _wps is guaranteed non-empty (the destination is always appended above).
        private _firstWp = [];
        private _wpCount = 0;
        {
            private _wp = _drvGrp addWaypoint [_x, -1];
            _wp setWaypointType "MOVE";
            _wp setWaypointSpeed "FULL";
            _wp setWaypointBehaviour "CARELESS";
            _wpCount = _wpCount + 1;
            if (_wpCount == 1) then { _firstWp = _wp; };
        } forEach _wps;
        if (count _firstWp > 0) then { _drvGrp setCurrentWaypoint _firstWp; };
        _trucks pushBack _newTruck;
        _groups pushBack _drvGrp;
    };
    [_trucks, _groups, _truckClass, _curPos, _nTrucks]
};

// ---------------------------------------------------------------------
// Shared delivery plan
// ---------------------------------------------------------------------

// Build a road-routed delivery plan between two NAMED markers. Returns
// [_roadPath, _cum, _dist, _eta, _routed].
//
// Every abstract convoy (manpower, ammo, armor orders) needs the same four
// things, and each one had its own inline copy of this: resolve a road route,
// walk it for cumulative distances, and derive an ETA from real road length.
// That duplication is how the manpower ETA and the ammo ETA drift apart, so it
// lives here once.
//
// _minDist is the "too short to bother shipping" threshold in metres. Below it
// the caller gets an empty plan and should skip the delivery.
//
// A pair the road search refused degrades to a straight-line plan (see
// MISSION_CORE_fnc_straightPlan) when supplyRouteStraightFallback is on, so the
// caller still gets a drawable path and a positive ETA. supplyRoute's fail
// backoff keeps running untouched, so a later order re-searches and upgrades
// the pair to a real route; nothing about the straight line is cached. With the
// tune off the failure is reported as an empty plan, exactly as it was before.
MISSION_CORE_fnc_routePlan = {
    params ["_fromName", "_toName", "_speed", ["_minDist", 50]];
    if (_speed <= 0) then { _speed = 14; };
    private _idx = call MISSION_CORE_fnc_locIndex;
    private _fromIdx = _idx getOrDefault [_fromName, -1];
    private _toIdx = _idx getOrDefault [_toName, -1];
    if (_fromIdx < 0 || { _toIdx < 0 }) exitWith { [[], [], 0, 0, false] };
    private _fromRec = MISSION_CORE_CACHED_POSITIONS select _fromIdx;
    private _toRec = MISSION_CORE_CACHED_POSITIONS select _toIdx;
    private _startPos = _fromRec select 1;
    private _endPos = _toRec select 1;
    if (_startPos distance2D _endPos < _minDist) exitWith { [[], [], 0, 0, false] };
    private _planResult = [_startPos, _endPos, _fromName, _toName, _fromRec, _toRec] call MISSION_CORE_fnc_supplyRoute;
    private _roadPath = _planResult select 0;
    private _wasRouted = _planResult select 1;
    private _cum = _planResult select 2;
    private _dist = _planResult select 3;
    private _straight = false;
    if (!_wasRouted || { _dist < 1 }) then {
        // Degenerate is also caught here: a routed plan shorter than 1m would
        // deliver on the dispatch tick, so it falls back or fails like an
        // unrouted one rather than shipping instantly.
        if ((["supplyRouteStraightFallback", 1] call MISSION_CORE_fnc_tune) > 0) then {
            private _flat = [_startPos, _endPos] call MISSION_CORE_fnc_straightPlan;
            if (count (_flat select 0) >= 2) then {
                _roadPath = _flat select 0;
                _cum = _flat select 1;
                _dist = _flat select 2;
                _straight = true;
            };
        };
    };
    if (count _roadPath < 2 || { _dist < 1 }) exitWith { [[], [], 0, 0, false] };
    if (_straight) then {
        diag_log format ["ROUTE PLAN: %1 -> %2 unroutable - straight-line fallback (%3m, ETA %4s)", _fromName, _toName, round _dist, round (_dist / _speed)];
    };
    [_roadPath, _cum, _dist, (_dist / _speed), _wasRouted]
};

// Draw position of an abstract delivery at fraction _frac (0..1) of its journey.
// Shared by every convoy icon so manpower, ammo and armor orders all animate the
// same way along their stored road path.
MISSION_CORE_fnc_deliveryPosAt = {
    params ["_roadPath", "_cum", "_frac"];
    if (count _roadPath >= 2 && { count _cum > 0 }) then {
        [_roadPath, _cum, _frac] call MISSION_CORE_fnc_convoyPosAt
    } else {
        private _from = _roadPath param [0, [0, 0, 0]];
        private _to = _roadPath param [1, _from];
        [
            (_from select 0) + ((_to select 0) - (_from select 0)) * _frac,
            (_from select 1) + ((_to select 1) - (_from select 1)) * _frac,
            0
        ]
    }
};
