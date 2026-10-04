// APPROACH waypoints for a player-hunt contingent driving to a last-known position.
//
// Separate from the truck driver builder (fn_buildTruckDriverWps) on purpose. A hunt is driven by
// the contingent's OWN leader group - there is no dedicated driver group and no scripted unload, so
// its job is just "get to the LKP and arrive combat-ready". A counter-attack truck instead needs a
// staging node and a drop ring that ends in TR UNLOAD. They share fn_transportStagePos for the
// staging point and nothing else.
//
// The staging waypoint is added for mounted contingents only: a hunt that is already on foot has no
// road to clear, and a staging detour would just delay it. On foot, the group goes straight to the
// LKP exactly as before.
//
// Arrival handling is deliberately NOT here - the caller keeps its existing waitUntil on the LKP,
// which is written against the final approach node, not the staging one.
MISSION_CORE_fnc_buildHuntApproachWps = {
    params ["_grp", "_from", "_lkp", ["_lkpRadius", 50]];
    if (isNull _grp) exitWith {};
    [_grp] call MISSION_CORE_fnc_clearGroupWaypoints;

    private _ldr = leader _grp;
    // isNull is unary and binds tighter than &&, so `!isNull _ldr && {...}` is a precedence trap.
    // Parenthesise the unary term.
    private _mounted = (!isNull _ldr) && { _ldr != vehicle _ldr };

    // Empty array means "no staging waypoint added". `private _x = nil` does not create a usable
    // variable - SQF raises "Undefined variable" when it is read - so the sentinel is [].
    private _wpFirst = [];
    if (_mounted) then {
        private _stage = [_from, _lkp] call MISSION_CORE_fnc_transportStagePos;
        private _wpStage = _grp addWaypoint [_stage, 15];
        _wpStage setWaypointType "MOVE";
        _wpStage setWaypointSpeed "FULL";
        _wpStage setWaypointBehaviour "AWARE";
        _wpFirst = _wpStage;
    };

    private _wp = _grp addWaypoint [_lkp, _lkpRadius];
    _wp setWaypointType "MOVE";
    _wp setWaypointSpeed "FULL";
    _grp setCurrentWaypoint (if (count _wpFirst > 0) then { _wpFirst } else { _wp });
    _grp setBehaviour "AWARE";
    _grp setCombatMode "RED";
    _wp
};