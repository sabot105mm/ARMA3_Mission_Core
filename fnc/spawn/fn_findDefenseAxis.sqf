MISSION_CORE_fnc_findDefenseAxis = {
    params ["_pos", "_side"];
    private _enemySide = if (_side == WEST) then { EAST } else { WEST };
    private _enemyLocs = MISSION_CORE_CACHED_POSITIONS select { _x select 4 == _enemySide };
    if (count _enemyLocs == 0) exitWith { random 360 };
    private _nearest = objNull;
    private _nearestDist = 99999;
    {
        private _d = _pos distance (_x select 1);
        if (_d < _nearestDist) then { _nearestDist = _d; _nearest = _x; };
    } forEach _enemyLocs;
    if (isNil "_nearest") exitWith { random 360 };
    (_nearest select 1) getDir _pos
};
