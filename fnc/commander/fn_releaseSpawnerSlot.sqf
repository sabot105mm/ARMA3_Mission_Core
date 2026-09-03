
// Release a marker's spawn slot early (marker captured / no longer contested)
MISSION_CORE_fnc_releaseSpawnerSlot = {
    params ["_markerName"];
    if (isNil "MISSION_CORE_ACTIVE_SPAWNERS") exitWith {};
    if (MISSION_CORE_ACTIVE_SPAWNERS deleteAt _markerName != nil) then {
        diag_log format ["DYNAMIC SPAWNER TRACK: %1 released its spawn slot (%2/5 active)", _markerName, count MISSION_CORE_ACTIVE_SPAWNERS];
    };
};
