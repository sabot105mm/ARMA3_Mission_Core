
MISSION_CORE_fnc_getLocByPos = {
    params [["_pos", [0, 0, 0]]];
    if (isNil "MISSION_CORE_CACHED_POSITIONS") exitWith { [] };
    if (count MISSION_CORE_CACHED_POSITIONS == 0) exitWith { [] };
    if !(_pos isEqualType []) exitWith { [] };
    private _best = MISSION_CORE_CACHED_POSITIONS select 0;
    private _bestD = 999999;
    {
        if (count _x > 1 && { (_x select 1) isEqualType [] }) then {
            private _d = _pos distance (_x select 1);
            if (_d < _bestD) then { _bestD = _d; _best = _x; };
        };
    } forEach MISSION_CORE_CACHED_POSITIONS;
    _best
};
