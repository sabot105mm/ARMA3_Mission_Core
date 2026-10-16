
// ---- recently-used safe-spot TEMP BAN -------------------------------------------------
// A spot that just produced a vehicle is held OUT of the safe-spawn list for a short window
// (30s) so the very next request rotates to a DIFFERENT spot instead of immediately reusing the
// one the fresh hull still sits on. Once the window elapses the spot enters the list again. State
// lives in MISSION_CORE_SAFE_SPOT_USE: spotKey -> time of last spawn. Detection is by rounded
// position so the same cached coordinate produces the same key every time.
MISSION_CORE_fnc_safeSpotKey = {
    params ["_p"];
    format ["%1_%2", round (_p select 0), round (_p select 1)]
};
MISSION_CORE_fnc_safeSpotBanned = {
    params ["_pos", ["_ban", 30]];
    if (isNil "MISSION_CORE_SAFE_SPOT_USE") exitWith { false };
    private _t = MISSION_CORE_SAFE_SPOT_USE getOrDefault [[_pos] call MISSION_CORE_fnc_safeSpotKey, -100000];
    (time - _t) < _ban
};
MISSION_CORE_fnc_markSafeSpotUsed = {
    params ["_pos"];
    if (isNil "MISSION_CORE_SAFE_SPOT_USE") then { MISSION_CORE_SAFE_SPOT_USE = createHashMap; };
    MISSION_CORE_SAFE_SPOT_USE set [[_pos] call MISSION_CORE_fnc_safeSpotKey, time];
};

// Returns [markerName, spots] for the nearest cached location that has pre-computed flat vehicle
// spawn spots (and that this position actually belongs to), or ["", []] if none. Used by
// findVehiclePos so every vehicle spawn at a marker reuses the confirmed-safe positions instead
// of rolling a new random spot each time. Spots still inside their post-spawn temp ban are
// dropped here; they re-enter automatically once the 30s window elapses.
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
                _spots = _spots select { !([_x] call MISSION_CORE_fnc_safeSpotBanned) };
            };
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
