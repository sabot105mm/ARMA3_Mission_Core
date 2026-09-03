MISSION_CORE_fnc_getCachedImportance = {
    params ["_markerName"];
    private _idx = MISSION_CORE_CACHED_POSITIONS findIf { (_x select 0) == _markerName };
    if (_idx < 0) exitWith { 1 };
    (MISSION_CORE_CACHED_POSITIONS select _idx) select 7
};
