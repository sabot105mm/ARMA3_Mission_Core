
// True when a position is on land and not near water (a ring of dry terrain surrounds it)
MISSION_CORE_fnc_isDryPos = {
    params ["_pos"];
    if (surfaceIsWater _pos) exitWith { false };
    private _dry = true;
    for "_i" from 0 to 7 do {
        if (surfaceIsWater (_pos getPos [20, _i * 45])) exitWith { _dry = false; };
    };
    _dry
};
