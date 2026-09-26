
// Spawn position is used as-is: the vehicle is created at rest on the ground instead of a few
// meters in the air. Lifting the spawn used to make crew seat on the vehicle's hull - when the
// vehicle is created airborne and the crew moveIn on the same frame, the seats aren't settled yet,
// so the crew end up standing on top of the tank. Spawning at the validated ground position (the
// callers all pass cleared/ATL spots) gives a settled vehicle the crew can board immediately.
MISSION_CORE_fnc_liftSpawn = {
    params ["_pos"];
    if !(_pos isEqualType []) exitWith { _pos };
    // VEHICLE-SPAWN DEAD SWEEP: every AI vehicle creation funnels through this position helper -
    // sweep the world's dead bodies/wrecks the moment a vehicle spawns (see fn_purgeDeadBodies).
    [_pos] call MISSION_CORE_fnc_purgeDeadBodies;
    [_pos param [0, 0, [0]], _pos param [1, 0, [0]], _pos param [2, 0, [0]]]
};
