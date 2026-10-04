// Pick a STAGING POSITION for a transport that is about to drive to a target.
//
// Counter-attack and reinforcement transports used to be given a road ROUTE through the origin's
// neighborhood (fn_supplyRoute). Two problems with that: the route planner is a supply-convoy
// system, and its caller then overwrote the driver's current waypoint anyway, so the route nodes
// were computed and discarded. A driver instead needs one waypoint to settle on just before
// committing to the drive - enough to clear the marker it is leaving without turning the trip into
// a supply-column crawl.
//
// Deterministic by design: the same origin and destination always yield the same staging point, and
// no random component is involved. nearRoads returns candidates nearest-first, so the scan below is
// already distance-ordered; candidates ahead of the driver are preferred so the staging point is on
// the way rather than behind it.
//
// SQF traps this file deliberately avoids:
//   - `vectorDir` is UNARY (object -> facing). `_a vectorDir _b` does not parse.
//   - `cosAngle` is avoided in favour of vectorDiff + vectorDotProduct, the idiom in fn_assaultServer.
//   - `getPosATL` needs an OBJECT. A position array is already ATL, so passing one throws
//     "getposatl: Type Array, expected Object".
//   - `private _x = nil` does NOT create a usable variable: SQF reports "Undefined variable" the
//     moment it is referenced. Empty arrays are used as the unset sentinel instead, since a real
//     position is never empty.
//
// Returns a position array (ATL). Never nil - the fallback is a fixed distance ahead of the origin.
MISSION_CORE_fnc_transportStagePos = {
    params [["_from", [0, 0, 0]], ["_to", [0, 0, 0]]];
    private _min = (["transportStageRoadMin", 10] call MISSION_CORE_fnc_tune);
    private _max = (["transportStageRoadMax", 300] call MISSION_CORE_fnc_tune);
    private _fallbackDist = (["transportStageFallbackDist", 50] call MISSION_CORE_fnc_tune);
    private _cap = (["transportStageCandidateCap", 24] call MISSION_CORE_fnc_tune);

    // Callers pass position arrays, but an object or garbage must not kill the trip.
    private _fromATL = [0, 0, 0];
    if (_from isEqualType []) then {
        if (count _from >= 2) then { _fromATL = _from; };
    } else {
        if (typeName _from == "OBJECT" && { !isNull _from }) then { _fromATL = getPosATL _from; };
    };
    private _toATL = [];
    if (_to isEqualType []) then {
        if (count _to >= 2) then { _toATL = _to; };
    } else {
        if (typeName _to == "OBJECT" && { !isNull _to }) then { _toATL = getPosATL _to; };
    };
    // No usable destination: aim north so the vector maths below stays well-defined.
    if (count _toATL == 0) then { _toATL = _fromATL vectorAdd [0, 100, 0]; };

    // The direction the transport will actually travel: from the origin toward the destination, so
    // the staging point is chosen relative to the trip rather than the map's north.
    private _fwd = _toATL vectorDiff _fromATL;
    private _fwdLen = vectorMagnitude _fwd;
    if (_fwdLen > 0.01) then {
        _fwd = _fwd vectorMultiply (1 / _fwdLen);
    } else {
        _fwd = [0, 1, 0];
    };

    // Empty array means "not found yet". See the note on private _x = nil above.
    private _ahead = [];
    private _any = [];
    private _roads = _fromATL nearRoads _max;
    if (count _roads > 0) then {
        private _rMax = ((count _roads) - 1) min _cap;
        for "_r" from 0 to _rMax do {
            private _cand = getPosATL (_roads select _r);
            // Inside the minimum the "road" is the marker the transport is leaving - staging there
            // is a no-op that just burns a waypoint.
            if (_cand distance2D _fromATL < _min) then { continue; };
            if (count _any == 0) then { _any = _cand; };
            // Prefer a road the transport reaches on the way, not one behind it. Dot product of two
            // unit vectors: ~1 straight ahead, 0 abeam, negative behind.
            private _cDir = _cand vectorDiff _fromATL;
            private _cLen = vectorMagnitude _cDir;
            private _dot = 0;
            if (_cLen > 0.01) then { _dot = _fwd vectorDotProduct (_cDir vectorMultiply (1 / _cLen)); };
            if ((count _ahead == 0) || { _dot > 0 }) then {
                _ahead = _cand;
                // A clearly forward road is good enough - stop widening the net. 0.34 is ~70 degrees.
                if (_dot > 0.34) then { break; };
            };
        };
    };

    private _chosen = if (count _ahead > 0) then { _ahead } else { _any };
    if (count _chosen > 0) exitWith { _chosen };

    // No usable road in range: stage a fixed distance ahead along the travel line.
    _fromATL vectorAdd (_fwd vectorMultiply _fallbackDist)
};