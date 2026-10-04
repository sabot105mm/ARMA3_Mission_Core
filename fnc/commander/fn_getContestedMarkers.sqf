// PURE PROJECTION over the canonical contested map. This function contains NO verdict logic of its
// own - it cannot decide whether a marker is contested, and it cannot disagree with the authority.
//
// The distinction that matters:
//
//   "Is marker X contested?"  ->  X in MISSION_CORE_CONTESTED
//                                 MISSION_CORE_CONTESTED is written in exactly one place,
//                                 fn_isMarkerContested.sqf, and nothing else. That is the answer.
//
//   "Give me the contested markers WITH their position, size and owner"  ->  THIS FUNCTION.
//
// The second question is a join, not a judgement. It reads the keys of the canonical map (so the
// membership set is the authority's, unmodified) and pulls position/size/owner out of
// MISSION_CORE_CACHED_POSITIONS, which is a separate var answering a separate question. Callers that
// only need a yes/no should NOT come here - they should test membership directly, which is cheaper
// and impossible to get wrong.
//
// RETURNS: rows of [_name, _pos, _size, _owner], one per contested marker that has a cached row.
// Optional _side narrows to markers OWNED by that side. That filter is an OWNERSHIP question, not a
// contested question: a marker stays contested after it flips sides, so the side that should be
// retaking it is precisely the side its owner filter would hide. Pass nothing for "all contested
// markers regardless of owner" - the default.
//
// Note this deliberately does NOT call fn_isMarkerContested. That function is a query with side
// effects (it refreshes the assault-contest map and may set or clear a key), so calling it from a
// getter would mean merely ASKING for geometry could mutate contest state. The map already holds
// the answer; read it.
//
// Cached rows are [name, pos, typeName, ..., owner, ..., importance, size] - SIZE IS INDEX 8.
// Index 2 is typeName. Every size this returns goes through a type guard, because a bare `select 2`
// here previously handed a typeName string to fn_sendCounterAttack as _targetSize.

MISSION_CORE_fnc_getContestedMarkers = {
    params [["_side", sideUnknown]];
    private _out = [];
    if (isNil "MISSION_CORE_CONTESTED") exitWith { _out };
    private _names = keys MISSION_CORE_CONTESTED;
    if (count _names == 0) exitWith { _out };
    if (isNil "MISSION_CORE_CACHED_POSITIONS") exitWith { _out };
    {
        private _name = _x;
        private _i = MISSION_CORE_CACHED_POSITIONS findIf { (_x select 0) == _name };
        if (_i >= 0) then {
            private _row = MISSION_CORE_CACHED_POSITIONS select _i;
            private _owner = _row select 4;
            if (_side == sideUnknown || { _owner == _side }) then {
                private _size = if (count _row > 8 && { ((_row select 8) isEqualType []) }) then { _row select 8 } else { [200, 200, 0] };
                _out pushBack [_name, _row select 1, _size, _owner];
            };
        };
    } forEach _names;
    _out
};