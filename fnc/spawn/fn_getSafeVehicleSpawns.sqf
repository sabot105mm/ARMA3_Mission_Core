
// Returns [markerName, spots] for the nearest cached location that has pre-computed flat vehicle
// spawn spots (and that this position actually belongs to), or ["", []] if none. Used by
// findVehiclePos so every vehicle spawn at a marker reuses the confirmed-safe positions instead
// of rolling a new random spot each time.
MISSION_CORE_fnc_getSafeVehicleSpawns = {
    params ["_pos"];
    if (isNil "MISSION_CORE_CACHED_POSITIONS") exitWith { ["", []] };
    if (isNil "MISSION_CORE_SAFE_VEHICLE_SPAWNS") exitWith { ["", []] };
    private _bestName = "";
    private _bestSpots = [];
    private _bestD = 999999;
    {
        if (count _x > 1 && { (_x select 1) isEqualType [] }) then {
            private _name = _x select 0;
            private _spots = MISSION_CORE_SAFE_VEHICLE_SPAWNS getOrDefault [_name, []];
            if (count _spots > 0) then {
                private _msize = if (count _x > 8) then { _x select 8 } else { [200, 200, 0] };
                private _reach = ((_msize select 0) max (_msize select 1)) + 100;
                private _d = _pos distance (_x select 1);
                // Only reuse cached spots when the position actually belongs to this marker -
                // otherwise an HQ or reinforcement base far from any town would pull spots from a
                // distant location and spawn vehicles kilometres away.
                if (_d < _bestD && { _d <= _reach }) then { _bestD = _d; _bestName = _name; _bestSpots = _spots; };
            };
        };
    } forEach MISSION_CORE_CACHED_POSITIONS;
    [_bestName, _bestSpots]
};
