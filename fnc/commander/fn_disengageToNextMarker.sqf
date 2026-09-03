// When a REDFOR zone marker is finally abandoned (players capture it and move on, or the retake
// window expires), any REDFOR groups that were still heading there must NOT keep marching into a
// dead zone. They disengage and go patrol / defend the next closest REDFOR marker instead.
MISSION_CORE_fnc_disengageToNextMarker = {
    params ["_fromName"];
    private _idx = MISSION_CORE_CACHED_POSITIONS findIf { (_x select 0) == _fromName };
    if (_idx < 0) exitWith {};
    private _fromPos = (MISSION_CORE_CACHED_POSITIONS select _idx) select 1;

    // Next closest REDFOR marker to the abandoned one (never itself)
    private _next = [];
    private _nextD = 1e10;
    {
        if ((_x select 4) == EAST && { (_x select 0) != _fromName }) then {
            private _d = (_x select 1) distance _fromPos;
            if (_d < _nextD) then { _nextD = _d; _next = _x; };
        };
    } forEach MISSION_CORE_CACHED_POSITIONS;
    if (count _next == 0) exitWith {};
    private _nextName = _next select 0;
    private _nextPos = _next select 1;
    private _nextSize = if (count _next > 8) then { _next select 8 } else { [200, 200] };

    private _disengaged = 0;
    {
        if (_x getVariable ["MISSION_CORE_REDFOR", false]) then {
            private _order = _x getVariable ["MISSION_CORE_ORDER", ""];
            // Groups still committed to the abandoned marker (assault target near its center)
            private _tgt = _x getVariable ["MISSION_CORE_ATTACK_TARGET", [0, 0, 0]];
            private _headingThere = _order in ["counterattack", "reinforce", "attack"] && { _tgt distance _fromPos < 800 };
            if (_headingThere) then {
                [_x] call MISSION_CORE_fnc_clearGroupWaypoints;
                _x setVariable ["MISSION_CORE_ORDER", ""];
                _x setVariable ["MISSION_CORE_ATTACK_TARGET", _nextPos];
                _x setVariable ["MISSION_CORE_MARKER_CENTER", _nextPos];
                _x setVariable ["MISSION_CORE_MARKER_SIZE", _nextSize];
                _x setVariable ["MISSION_CORE_ORIGIN_MARKER", _nextName];
                [_x] call MISSION_CORE_fnc_restartPatrol;
                _disengaged = _disengaged + 1;
            };
        };
    } forEach allGroups;

    if (_disengaged > 0) then {
        diag_log format ["AI ZONE: %1 disengaged %2 group(s) to patrol %3", _fromName, _disengaged, _nextName];
    };
};