
MISSION_CORE_fnc_isUnsafeVehicleSpawn = {
    params ["_pos"];
    if (isNil "MISSION_CORE_UNSAFE_VEHICLE_SPAWNS") exitWith { false };
    private _unsafe = false;
    {
        _x params ["_uPos", "_uTime", "_uRad", "_uDur"];
        if (time - _uTime > _uDur) then { continue; };
        if (_pos distance _uPos < _uRad) exitWith { _unsafe = true; };
    } forEach MISSION_CORE_UNSAFE_VEHICLE_SPAWNS;
    _unsafe
};
