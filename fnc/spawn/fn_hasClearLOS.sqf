
MISSION_CORE_fnc_hasClearLOS = {
    params ["_from", "_dir", "_dist"];
    private _to = _from getPos [_dist, _dir];
    private _toASL = ATLToASL _to;
    private _fromASL = ATLToASL _from;
    !terrainIntersect [_fromASL, _toASL]
};
