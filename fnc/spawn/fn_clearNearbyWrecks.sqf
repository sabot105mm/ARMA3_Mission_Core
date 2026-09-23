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