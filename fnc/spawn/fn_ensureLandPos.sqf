
// Snap a position to the nearest dry land spot - used so tanks and land units never spawn in or
// near water. Searches outward in expanding rings up to 250m.
MISSION_CORE_fnc_ensureLandPos = {
    params ["_pos"];
    if !(_pos isEqualType []) exitWith { [0, 0, 0] };
    if (count _pos < 2) exitWith { [0, 0, 0] };
    private _p = [_pos select 0, _pos select 1, 0];
    if ([_p] call MISSION_CORE_fnc_isDryPos) exitWith { _p };
    private _searchR = 25;
    while { _searchR <= 250 } do {
        private _best = [0, 0, 0];
        private _bestD = 999999;
        for "_i" from 0 to 11 do {
            private _cand = _p getPos [_searchR, _i * 30];
            if ([_cand] call MISSION_CORE_fnc_isDryPos) then {
                private _d = _cand distance _p;
                if (_d < _bestD) then { _bestD = _d; _best = _cand; };
            };
        };
        if (_bestD < 999999) exitWith { _p = _best; };
        _searchR = _searchR + 25;
    };
    _p
};
