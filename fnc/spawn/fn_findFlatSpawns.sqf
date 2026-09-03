
// Use isFlatEmpty to hunt for flat, obstacle-free vehicle spawn positions around _center inside
// an ellipse of _size. Finds up to _count spots, keeps them at least _minSpread apart, and keeps
// trying (widening the search radius every 40 misses) until the target count is reached or the
// attempt budget runs out. Returns an array of [x, y, 0] positions. Must run in scheduled scope
// (isFlatEmpty is expensive, and the loop yields with sleep so it never freezes the game).
MISSION_CORE_fnc_findFlatSpawns = {
    params ["_center", ["_size", [200, 200]], ["_count", 4], ["_minSpread", 45]];
    private _a = _size select 0;
    private _b = _size select 1;
    private _mkrDir = if (count _size > 2) then { _size select 2 } else { 0 };
    private _found = [];
    private _attempts = 0;
    private _radiusMult = 1.0;
    while { count _found < _count && _attempts < 160 } do {
        _attempts = _attempts + 1;
        private _ang = random 360;
        private _maxR = [_a * _radiusMult, _b * _radiusMult, _ang, _mkrDir] call MISSION_CORE_fnc_ellipseRadius;
        private _r = _maxR * (0.2 + random 0.8);
        private _cand = _center getPos [_r, _ang];
        // isFlatEmpty checks the candidate point: at least 6m from any object, terrain no steeper
        // than 0.25 gradient across 16m, and not over water. Returns [x, y, zASL] on success.
        private _flat = _cand isFlatEmpty [6, -1, 0.25, 16, 0, false, objNull];
        if (count _flat == 3) then {
            private _spot = [_flat select 0, _flat select 1, 0];
            private _within = _center distance _spot < ((_a max _b) * _radiusMult) + 60;
            if (_within && { [_spot] call MISSION_CORE_fnc_isDryPos }) then {
                private _crowded = _found findIf { _spot distance _x < _minSpread } > -1;
                if (!_crowded && { !([_spot] call MISSION_CORE_fnc_isUnsafeVehicleSpawn) }) then {
                    _found pushBack _spot;
                };
            };
        };
        if (_attempts % 40 == 0) then { _radiusMult = _radiusMult + 0.5; };
        if (_attempts % 20 == 0) then { sleep 0; };
    };
    _found
};
