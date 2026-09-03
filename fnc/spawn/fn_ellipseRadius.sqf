
MISSION_CORE_fnc_ellipseRadius = {
    params ["_a", "_b", "_angle", ["_dir", 0]];
    if (_a <= 0) then { _a = 1; };
    if (_b <= 0) then { _b = 1; };
    private _ang = _angle - _dir;
    private _c = cos _ang;
    private _s = sin _ang;
    if ((abs _c) < 0.001 && { abs _s < 0.001 }) exitWith { _a min _b };
    (_a * _b) / sqrt ((_b * _s) * (_b * _s) + (_a * _c) * (_a * _c))
};
