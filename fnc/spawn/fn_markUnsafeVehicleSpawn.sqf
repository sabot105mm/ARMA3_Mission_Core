
// Flag a position as unsafe for future vehicle spawns (e.g. a transport truck destroyed there
// before it unloaded). Entries expire after _duration seconds. Used by findVehiclePos and
// mountInfantry so replacement vehicles never roll back into the same kill zone.
MISSION_CORE_fnc_markUnsafeVehicleSpawn = {
    params ["_pos", ["_radius", 60], ["_duration", 1200]];
    if (isNil "MISSION_CORE_UNSAFE_VEHICLE_SPAWNS") then { MISSION_CORE_UNSAFE_VEHICLE_SPAWNS = []; };
    MISSION_CORE_UNSAFE_VEHICLE_SPAWNS pushBack [_pos, time, _radius, _duration];
    // Prune expired entries so the registry never grows unbounded over a long session
    MISSION_CORE_UNSAFE_VEHICLE_SPAWNS = MISSION_CORE_UNSAFE_VEHICLE_SPAWNS select { time - (_x select 1) <= (_x select 3) };
    diag_log format ["AI COMMANDER: marked vehicle spawn unsafe at %1 (r=%2)", _pos, _radius];
};
