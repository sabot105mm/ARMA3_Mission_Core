
// Strategic "determination" of a marker: returns [garrisonHoldFrac, neighborBudgetFrac].
//   garrisonHoldFrac   = fraction of its OWN manpower it keeps fighting for before retreating
//                        (0.0 = fight to the last man, 0.85 = retreat after a few losses).
//   neighborBudgetFrac = fraction of each neighbor's manpower the neighbors collectively POOL
//                        to reinforce this marker.
// Type is primary; a marker within 800m of a port/factory/HQ bumps up one tier (it is a stepping
// stone to the real objective, so the enemy values it more than its raw type suggests).
MISSION_CORE_fnc_getMarkerDetermination = {
    params ["_loc"];
    if (isNil "_loc" || { count _loc < 3 }) exitWith { [3, 0.85, 0.2] };
    private _t = toLower (_loc select 2);
    private _tier = 3;
    if (_t find "hq" > -1) then { _tier = 0; }
    else {
        if (_t find "factory" > -1 || _t find "port" > -1 || _t find "base" > -1 || _t find "airfield" > -1 || _t find "airport" > -1 || _t find "marine" > -1) then { _tier = 1; }
        else {
            if (_t find "city" > -1 || _t find "village" > -1 || _t find "capital" > -1 || _t find "center" > -1 || _t find "town" > -1 || _t find "compound" > -1) then { _tier = 2; }
            else { _tier = 3; };
        };
    };
    // Context boost: near a high-value (tier 0/1) marker -> one tier more important.
    private _name = _loc select 0;
    private _pos = _loc select 1;
    {
        if ((_x select 0) != _name) then {
            private _nt = toLower (_x select 2);
            private _isHigh = (_nt find "hq" > -1) || (_nt find "factory" > -1) || (_nt find "port" > -1) || (_nt find "base" > -1) || (_nt find "airfield" > -1) || (_nt find "airport" > -1) || (_nt find "marine" > -1);
            if (_isHigh && { (_x select 1) distance _pos < 800 }) exitWith { _tier = (_tier - 1) max 0; };
        };
    } forEach MISSION_CORE_CACHED_POSITIONS;
    // [tier, holdFrac, budgetFrac]
    private _row = ([ [0.0, 1.0], [0.25, 0.5], [0.6, 0.4], [0.85, 0.2] ] select _tier);
    [_tier, _row select 0, _row select 1]
};
