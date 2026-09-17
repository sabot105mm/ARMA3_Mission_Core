// Retreat destination for a squad that broke off its attack: the closest same-side cached marker
// ("next closest ally"), so retreating squads move AWAY from the contested marker toward the
// nearest friendly town.
//
// PERMANENT RULE: the closest friendly marker is skipped when the straight line from the squad's
// position to it would pass through an enemy-held marker (a squad retreating home must never drive
// straight through a hostile base to get there). The line is drawn from the retreat ORIGIN (the
// marker the squad is fleeing) to each candidate, and tested against every enemy cached marker -
// if it enters an enemy marker's footprint, that candidate is discarded and the next closest
// friendly marker is tried instead. Only marker POSITIONS on the straight line are considered; a
// path that merely passes near an enemy marker is fine.
//
// _exclude: an array of marker NAMES to skip - always pass the squad's OWN origin marker (and the
// target it was attacking) so a squad NEVER retreats back into its own town. The caller passes the
// squad's CURRENT position, and markers owned by the ENEMY are excluded. Returns [0,0,0] when no
// same-side marker exists.
//
// Returns the position of the closest friendly marker whose straight-line path from _pos does NOT
// cross an enemy marker; falls back to the plain closest friendly marker when every candidate is
// blocked (better to retreat somewhere than nowhere).
//
// Calling this from the retreat destination picker is what keeps retreating garrisons from driving
// home through a hostile base.
//
// Line-vs-marker test: returns TRUE when the straight 2D segment from _from to _to passes within an
// enemy marker's footprint. Only ENEMY-owned cached markers (index 4) are tested. The footprint is
// approximated by a circle of radius max(a, b) around the marker center (index 8 = [a, b, dir]).
// Circle is rotation-invariant, so rotated markers are handled correctly; [0,0]-sized markers
// ("sea gaps") never block.
MISSION_CORE_fnc_lineCrossesEnemy = {
    params ["_from", "_to", "_side"];
    if (isNil "MISSION_CORE_CACHED_POSITIONS") exitWith { false };
    private _enemySide = if (_side == EAST) then { WEST } else { EAST };
    private _fromX = _from select 0; private _fromY = _from select 1;
    private _toX = _to select 0;     private _toY = _to select 1;
    private _segDx = _toX - _fromX; private _segDy = _toY - _fromY;
    private _segLen2 = (_segDx * _segDx) + (_segDy * _segDy);
    if (_segLen2 < 1) exitWith { false };
    private _crosses = false;
    {
        if ((_x select 4) != _enemySide) then { continue; };
        private _px = (_x select 1) select 0; private _py = (_x select 1) select 1;
        // Closest point on the segment to the enemy marker center (t clamped to [0,1]).
        private _t = ((_px - _fromX) * _segDx + (_py - _fromY) * _segDy) / _segLen2;
        _t = _t max 0 min 1;
        private _cx = _fromX + (_t * _segDx);
        private _cy = _fromY + (_t * _segDy);
        private _dist = sqrt (((_px - _cx) * (_px - _cx)) + ((_py - _cy) * (_py - _cy)));
        private _sz = if (count _x > 8 && { (_x select 8) isEqualType [] }) then { _x select 8 } else { [200, 200, 0] };
        private _radius = ((_sz select 0) max (_sz select 1)) max 1;
        if (_dist < _radius) exitWith { _crosses = true; };
    } forEach MISSION_CORE_CACHED_POSITIONS;
    _crosses
};

MISSION_CORE_fnc_getRetreatDest = {
    params ["_pos", ["_side", sideUnknown], ["_exclude", []]];
    if (isNil "MISSION_CORE_CACHED_POSITIONS") exitWith { [0, 0, 0] };
    private _useSide = if (_side == sideUnknown) then { WEST } else { _side };
    // Gather all same-side, non-excluded markers, sorted by distance from the squad.
    private _cands = [];
    {
        if ((_x select 4) == _useSide && { !((_x select 0) in _exclude) }) then {
            private _d = (_x select 1) distance2D _pos;
            _cands pushBack [_d, _x];
        };
    } forEach MISSION_CORE_CACHED_POSITIONS;
    if (count _cands == 0) exitWith { [0, 0, 0] };
    _cands sort true;
    // Walk the closest candidates in order; take the first whose line to the squad does not cross
    // an enemy marker. The squad's own position is the start of the line, so it is never blocked.
    private _best = _cands select 0;
    private _foundDest = false;
    {
        private _destPos = (_x select 1) select 1;
        if (!([_pos, _destPos, _useSide] call MISSION_CORE_fnc_lineCrossesEnemy)) then {
            _best = _x;
            _foundDest = true;
        };
        if (_foundDest) exitWith {};
    } forEach _cands;
    (_best select 1) select 1
};