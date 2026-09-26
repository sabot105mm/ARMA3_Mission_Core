// Scoped dead-vehicle scan: delete wrecked vehicles ONLY inside the given safe spawn footprint
// (center + radius) so a fresh vehicle never materializes on a burned-out hull from an earlier
// fight. Never deletes dead vehicles elsewhere on the map. Shared by every vehicle spawn path
// (findVehiclePos, tank depot parks, armor reinforcement fallbacks, HQ forces, recruit parking).
// Pass [_center, _radius] to scope the sweep, or [] for a single-position sweep (80m).
MISSION_CORE_fnc_clearNearbyWrecks = {
    params ["_center", "_radius"];
    if (isNil "_radius") then { _radius = 80; };
    if (count _center < 2) exitWith {};
    {
        // allDead holds both wrecked vehicles and dead soldiers; filter to vehicles only.
        // "LandVehicle" is the umbrella for Car/Tank/Motorcycle (all the classes that spawn in a
        // ground footprint); CAManBase soldiers are NOT included.
        if (_x isKindOf "LandVehicle") then {
            private _dist = (getPosATL _x) distance2D _center;
            if (_dist <= _radius) then {
                deleteVehicle _x;
            };
        };
    } forEach allDead;
};

// Global dead-unit + wreck purge at vehicle-spawn time: the shared vehicle-spawn choke point
// (fn_liftSpawn) runs this the MOMENT any vehicle spawns, so every AI vehicle path -- patrol
// columns, tank depots, armor reinforcement, HQ forces, assaults, convoys, artillery, recruit
// transports -- clears all accumulated dead soldiers and destroyed-vehicle wrecks mission-wide
// (the literal allDead sweep). A fresh vehicle never materializes over old wreckage and the
// corpse pile is drained each time a vehicle hits the world.
MISSION_CORE_fnc_purgeDeadBodies = {
    params ["_spawnPos"];
    if (count allDead == 0) exitWith {};
    { deleteVehicle _x; } forEach allDead;
    diag_log format ["PURGE DEAD: swept all dead bodies/wrecks on vehicle spawn at %1", _spawnPos];
};