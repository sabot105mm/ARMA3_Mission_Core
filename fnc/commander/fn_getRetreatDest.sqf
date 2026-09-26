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
// _farFrom: the CONTESTED marker the squad is breaking off from. The separation rule below is
// measured from it, NOT from _pos - those are different places. A neighbor column turns around
// while still short of the target, so measuring from its own position would happily pick a village
// 400m from the fight and the rule would do nothing. Defaults to _pos, which is already correct for
// a garrison (its _pos IS the marker it lost) and for a player-hunt contingent (its _pos is where
// the player was last seen).
//
// RETREAT SEPARATION (PERMANENT RULE): a candidate must be at least retreatMinDistance (1500m)
// from the contested marker. Without it a broken-off column re-forms at the next village over and
// the same fight simply restarts, because the AI never really left. The squad walks to the next
// genuinely DISTANT friendly marker instead of the merely closest one.
//
// Returns the nearest friendly marker that is BOTH far enough from the fight and line-clear; falls
// back to the FARTHEST line-clear marker when the map holds nothing that far away, and to the
// farthest marker outright when every path is blocked. The fallback is deliberate: a garrison must
// never be stranded, because MISSION_CORE_RETREATED is already latched by the time it retreats, so a
// garrison that failed to leave could neither respawn nor be captured.
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
    params ["_pos", ["_side", sideUnknown], ["_exclude", []], ["_farFrom", []]];
    // _farFrom defaults to _pos when the caller does not name the contested marker. It is resolved
    // here rather than written as a params default of "_pos": referencing an earlier parameter from
    // inside a params default left _farFrom unbound on the 3-argument call path, and the first
    // distance2D against it then failed with "Undefined variable in expression: _farFrom". A
    // sentinel is unambiguous, and a caller that hands over anything that is not a 3-number position
    // is treated as having named nothing, which is the same answer _pos gives.
    if (count _farFrom != 3 || { !(_farFrom isEqualType []) } || { count (_farFrom select { _x isEqualType 0 }) != 3 }) then {
        _farFrom = _pos;
    };
    // _pos is measured against all through this function, so validate it once up front rather than
    // letting a malformed call fail deep inside a forEach.
    if (count _pos != 3 || { !(_pos isEqualType []) } || { count (_pos select { _x isEqualType 0 }) != 3 }) exitWith { [0, 0, 0] };
    if (isNil "MISSION_CORE_CACHED_POSITIONS") exitWith { [0, 0, 0] };
    private _useSide = if (_side == sideUnknown) then { WEST } else { _side };
    private _minDist = ["retreatMinDistance", 1500] call MISSION_CORE_fnc_tune;
    // [distance from the squad, distance from the contested marker, marker row]
    private _cands = [];
    {
        if ((_x select 4) == _useSide && { !((_x select 0) in _exclude) }) then {
            _cands pushBack [(_x select 1) distance2D _pos, (_x select 1) distance2D _farFrom, _x];
        };
    } forEach MISSION_CORE_CACHED_POSITIONS;
    if (count _cands == 0) exitWith { [0, 0, 0] };
    _cands sort true;
    // PASS 1: nearest candidate that is BOTH far enough from the contested marker and line-clear.
    private _dest = [];
    {
        if ((_x select 1) >= _minDist) then {
            private _cPos = (_x select 2) select 1;
            if !([_pos, _cPos, _useSide] call MISSION_CORE_fnc_lineCrossesEnemy) then { _dest = _cPos; };
        };
        if (count _dest > 0) exitWith {};
    } forEach _cands;
    // PASS 2: the map holds nothing that far away - take the FARTHEST line-clear marker, so the
    // squad still maximizes its separation instead of walking 200m and re-entering the fight.
    private _bestFar = -1;
    if (count _dest == 0) then {
        {
            private _cPos = (_x select 2) select 1;
            if ((_x select 1) > _bestFar) then {
                if !([_pos, _cPos, _useSide] call MISSION_CORE_fnc_lineCrossesEnemy) then {
                    _bestFar = _x select 1;
                    _dest = _cPos;
                };
            };
        } forEach _cands;
    };
    // PASS 3: every straight path is blocked by an enemy marker - go to the farthest one anyway.
    // Arriving somewhere bad beats never leaving, and the arrival despawn clears them either way.
    if (count _dest == 0) then {
        {
            if ((_x select 1) > _bestFar) then {
                _bestFar = _x select 1;
                _dest = (_x select 2) select 1;
            };
        } forEach _cands;
    };
    // Log only when the map genuinely holds nothing that far away - NOT when the chosen marker is
    // near, or every ordinary retreat would report a fallback that never happened.
    if (_cands findIf { (_x select 1) >= _minDist } == -1) then {
        diag_log format ["RETREAT DEST: no friendly marker is %1m from the contested marker - using the farthest (%2m) instead", _minDist, round _bestFar];
    };
    // One shape check at the boundary. Every caller either measures the answer with distance or
    // hands it straight to addWaypoint, and three of them broke on a value that was not a position.
    // A cached row that is not a full [x,y,z] must not escape as a bare coordinate, so a malformed
    // candidate degrades to "nowhere to go" - the same answer the no-marker case already returns,
    // and every caller already has a defined path for it.
    if (count _dest != 3 || { !(_dest isEqualType []) } || { count (_dest select { _x isEqualType 0 }) != 3 }) exitWith { [0, 0, 0] };
    _dest
};