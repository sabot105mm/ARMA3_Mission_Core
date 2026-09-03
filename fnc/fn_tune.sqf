//
// BALANCE TUNING LOADER
//
// Reads the mission-config MISSION_CORE_TUNE class once at server init into the global
// MISSION_CORE_SETTINGS hashmap. Everything gameplay-critical (spawn radii, foot budget, armor
// caps, hunt/house radii, tank production, capture windows) is a number here - tweak
// description.ext / config\main.hpp and restart, no SQF edits needed.
//
// MISSION_CORE_fn_tune key default -> number from config, falling back to the SQF default so a
// missing key never silently zeroes a system.
MISSION_CORE_fnc_loadTune = {
    diag_log "TUNE: loading MISSION_CORE_TUNE";
    MISSION_CORE_SETTINGS = createHashMap;
    private _cfg = missionConfigFile >> "MISSION_CORE_TUNE";
    if (isClass _cfg) then {
        {
            private _key = configName _x;
            MISSION_CORE_SETTINGS set [_key, getNumber _x];
        } forEach ("true" configClasses _cfg);
    };
    diag_log format ["TUNE: loaded %1 values", count MISSION_CORE_SETTINGS];
};

MISSION_CORE_fnc_tune = {
    params ["_key", ["_default", 0]];
    if (isNil "MISSION_CORE_SETTINGS") exitWith { _default };
    (MISSION_CORE_SETTINGS getOrDefault [_key, _default])
};
