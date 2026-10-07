// ---------------------------------------------------------------------
// Route leg waypoints - the shared "stride walk" used by every materialised
// convoy and by every troop leg that has just left the abstract layer.
// ---------------------------------------------------------------------
//
// WHY THIS EXISTS: a materialised convoy used to take the REMAINING ROAD NODES
// of its route as its waypoint list (fn_supplyRoutes.sqf spawnConvoyColumn).
// Waypoint density was therefore whatever the road network happened to produce
// for that particular pair of markers - two waypoints on one route, forty on the
// next - so long legs crawled and short ones snapped. This walks the route in a
// fixed stride instead, which is what makes travel time predictable.
//
// THE ALGORITHM (one stride at a time along the SAME route the abstract layer
// used - no re-plan, no re-route):
//   1. Take the stored _path / _cum the leg or shipment already holds.
//   2. Step routeLegSpacing metres along it and emit that point as a waypoint.
//   3. Repeat until the NEXT candidate would land within routeLegFinalRadius of
//      the destination, then stop - the caller appends a normal waypoint to the
//      target so the group keeps driving and the final approach still happens.
//
// WHY THE TRAILING TARGET WAYPOINT IS NOT OPTIONAL: by construction the last
// emitted leg is FURTHER than routeLegFinalRadius from the destination, so a
// group given only the legs would exhaust its waypoint list and idle short of
// the objective. applyRouteLegWps always appends the target.
//
// WHY BOTH CUTOFFS SHARE ONE TUNE (routeLegFinalRadius): it is simultaneously
// "stop emitting legs inside this radius" and, for troop legs, the handoff ring.
// Two separate values could drift - a leg emitted at 1200m with a handoff ring at
// 800m hands the group off before it reaches its leg; the reverse leaves it idling
// past the ring. One definition, two call sites, drift is impossible.
//
// BOTH the cutoff here and the handoff test use distance2D to the destination,
// never arc-length-remaining, so the two always agree.
//
// NOTE: the tune reads are deliberately inlined rather than hoisted into file-scope
// private helpers. SQF code blocks do NOT close over the scope they were defined in,
// so a file-scope `private _fn = {...}` referenced from a function called later would
// resolve to an undefined variable.

// Positions only. [_path, _cum, _fromFrac, _targetPos] -> [[x,y,z], ...]
// Returns evenly strided positions ALONG the route, EXCLUDING the destination.
// Callers append the destination waypoint themselves - use applyRouteLegWps below
// unless you specifically need the raw list (fn_supplyRoutes.sqf does, because it
// reads _wps select 0 to orient the truck column echelon).
MISSION_CORE_fnc_routeLegWps = {
    params ["_path", "_cum", "_fromFrac", "_targetPos"];
    private _legs = [];
    if (count _path < 2) exitWith { _legs };
    if (count _cum < 2) exitWith { _legs };
    private _total = _cum select (count _cum - 1);
    if (_total <= 0) exitWith { _legs };
    if !(_fromFrac isEqualType 1) then { _fromFrac = 0; };
    if (_fromFrac < 0) then { _fromFrac = 0; };
    if (_fromFrac >= 1) exitWith { _legs };

    private _stride = ["routeLegSpacing", 700] call MISSION_CORE_fnc_tune;
    if !(_stride isEqualType 1) then { _stride = 700; };
    if (_stride < 50) then { _stride = 50; };
    private _stopDist = ["routeLegFinalRadius", 1000] call MISSION_CORE_fnc_tune;
    if !(_stopDist isEqualType 1) then { _stopDist = 1000; };
    if (_stopDist < 0) then { _stopDist = 0; };

    // Both route helpers share one arc-length parameterisation: _frac * _total is
    // metres, so a stride in metres converts straight into a stride in fraction space.
    private _step = _stride / _total;

    // No exitWith inside the loop body: a bare exitWith at this block depth is this
    // mission's documented parse-error trap (fn_isMarkerContested.sqf:208) and its
    // scope behaviour inside a while body is not worth relying on. A _done flag is
    // unambiguous. _guard bounds a pathological switchback route.
    private _f = _fromFrac;
    private _done = false;
    private _guard = 0;
    while { !_done && { _guard < 64 } } do {
        _guard = _guard + 1;
        private _next = _f + _step;
        if (_next >= 1) then {
            _done = true;
        } else {
            private _pos = [_path, _cum, _next] call MISSION_CORE_fnc_convoyPosAt;
            if !(_pos isEqualType []) then {
                _done = true;
            } else {
                if ((_pos distance2D _targetPos) <= _stopDist) then {
                    _done = true;
                } else {
                    _legs pushBack _pos;
                    _f = _next;
                };
            };
        };
    };
    _legs
};

// Build the FULL waypoint list on a group: the strided legs plus a normal waypoint
// to the target, first waypoint current. Returns the leg count.
//
// [_grp, _path, _cum, _fromFrac, _targetPos, [_radius, [_speed, [_behaviour]]]]
//
// The trailing waypoint is always added, so callers cannot forget it. The first
// waypoint is always MOVE (Arma < 1.22 groups refuse to leave the start line
// otherwise - the same reason fn_sendCounterAttack's _addAssaultWps always emits a
// MOVE first).
MISSION_CORE_fnc_applyRouteLegWps = {
    params ["_grp", "_path", "_cum", "_fromFrac", "_targetPos", ["_radius", 10], ["_speed", "FULL"], ["_behaviour", "CARELESS"]];
    if (isNull _grp) exitWith { 0 };
    private _legs = [_path, _cum, _fromFrac, _targetPos] call MISSION_CORE_fnc_routeLegWps;
    [_grp] call MISSION_CORE_fnc_clearGroupWaypoints;
    // A "no waypoint yet" sentinel, counted with a NUMBER. `addWaypoint` returns an ARRAY in
    // this engine, not an Object, so isNull is a hard type error on it -
    // "isnull: Type Array, expected Object,Group,..." - and it fires the moment the route was
    // too short to emit a single leg. Track the first waypoint by COUNT instead.
    private _first = objNull;
    private _legCount = 0;
    {
        if (_x isEqualType []) then {
            private _wp = _grp addWaypoint [_x, _radius];
            _wp setWaypointType "MOVE";
            _wp setWaypointSpeed _speed;
            _wp setWaypointBehaviour _behaviour;
            _legCount = _legCount + 1;
            if (_legCount == 1) then { _first = _wp; };
        };
    } forEach _legs;
    private _wpEnd = _grp addWaypoint [_targetPos, _radius];
    _wpEnd setWaypointType "MOVE";
    _wpEnd setWaypointSpeed _speed;
    _wpEnd setWaypointBehaviour _behaviour;
    // The arrival waypoint is always the fallback, so _first is never null here and the
    // setCurrentWaypoint call needs no guard at all.
    if (_legCount == 0) then { _first = _wpEnd; };
    _grp setCurrentWaypoint _first;
    _legCount
};