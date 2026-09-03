// Retreat destination for a squad that broke off its attack: the closest same-side cached marker
// ("next closest ally"), so retreating squads move AWAY from the contested marker toward the
// nearest friendly town.
//
// _exclude: an array of marker NAMES to skip - always pass the squad's OWN origin marker (and the
// target it was attacking) so a squad NEVER retreats back into its own town. The caller passes the
// squad's CURRENT position, and markers owned by the ENEMY are excluded. Returns [0,0,0] when no
// same-side marker exists.
MISSION_CORE_fnc_getRetreatDest = {
    params ["_pos", ["_side", sideUnknown], ["_exclude", []]];
    if (isNil "MISSION_CORE_CACHED_POSITIONS") exitWith { [0, 0, 0] };
    private _useSide = if (_side == sideUnknown) then { WEST } else { _side };
    private _best = [0, 0, 0];
    private _bestD = 1e10;
    {
        if ((_x select 4) == _useSide && { !((_x select 0) in _exclude) }) then {
            private _d = (_x select 1) distance2D _pos;
            if (_d < _bestD) then { _bestD = _d; _best = _x select 1; };
        };
    } forEach MISSION_CORE_CACHED_POSITIONS;
    if (_bestD >= 1e10) exitWith { [0, 0, 0] };
    _best
};
