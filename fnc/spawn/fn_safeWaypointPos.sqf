
// Sanitize a waypoint position so the AI is never sent to the map origin [0,0,0] (the bottom-left
// corner, usually water) or into the sea. When _pos is missing, not an array, or sits at the
// origin, it falls back to _fallback. The result is then snapped to the nearest dry land.
// Returns [0,0,0] only when BOTH inputs are unusable (callers should always pass a real fallback,
// e.g. a leader position or a marker center).
MISSION_CORE_fnc_safeWaypointPos = {
    params ["_pos", ["_fallback", []]];
    private _p = _pos;
    if (!(_p isEqualType []) || { count _p < 2 } || { (_p select 0) == 0 && { (_p select 1) == 0 } }) then {
        _p = _fallback;
    };
    if (!(_p isEqualType []) || { count _p < 2 } || { (_p select 0) == 0 && { (_p select 1) == 0 } }) exitWith { [0, 0, 0] };
    _p = [_p select 0, _p select 1, 0];
    if ([_p] call MISSION_CORE_fnc_isDryPos) exitWith { _p };
    [_p] call MISSION_CORE_fnc_ensureLandPos
};
