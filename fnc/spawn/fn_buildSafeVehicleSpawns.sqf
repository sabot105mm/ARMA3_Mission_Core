
// Build the per-marker safe vehicle spawn cache. For every cached location, findFlatSpawns uses
// isFlatEmpty to resolve up to 4 clear, flat spots inside the marker ellipse. Spawn as a script -
// isFlatEmpty needs a scheduled environment and the scan is not free at init time.
MISSION_CORE_fnc_buildSafeVehicleSpawns = {
    MISSION_CORE_SAFE_VEHICLE_SPAWNS = createHashMap;
    MISSION_CORE_SAFE_SPAWN_INDEX = createHashMap;
    {
        private _loc = _x;
        private _name = _loc select 0;
        private _pos = _loc select 1;
        private _msize = if (count _loc > 8) then { _loc select 8 } else { [200, 200, 0] };
        private _spots = [_pos, _msize, 4, 45] call MISSION_CORE_fnc_findFlatSpawns;
        MISSION_CORE_SAFE_VEHICLE_SPAWNS set [_name, _spots];
        diag_log format ["DYNAMIC CACHE: %1 safe vehicle spawns=%2", _name, count _spots];
        sleep 0;
    } forEach MISSION_CORE_CACHED_POSITIONS;
    diag_log format ["DYNAMIC CACHE: built safe vehicle spawns for %1 markers", count MISSION_CORE_CACHED_POSITIONS];
};
