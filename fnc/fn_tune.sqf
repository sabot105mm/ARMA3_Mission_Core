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
        // Iterate EVERY config entry, not just subclasses: the tune keys are numeric PROPERTIES and
        // configClasses only walks child classes (which never exist here, so it always returned 0).
        for "_i" from 0 to (count _cfg - 1) do {
            private _entry = _cfg select _i;
            if (isNumber _entry) then {
                MISSION_CORE_SETTINGS set [configName _entry, getNumber _entry];
            };
        };
        diag_log format ["TUNE: loaded %1 values (quadrantReleasePerTick=%2, quadrantPerTargetMax=%3, quadrantBatchInterval=%4, quadrantGraceTime=%5)", count MISSION_CORE_SETTINGS,
            MISSION_CORE_SETTINGS getOrDefault ["quadrantReleasePerTick", "MISSING"],
            MISSION_CORE_SETTINGS getOrDefault ["quadrantPerTargetMax", "MISSING"],
            MISSION_CORE_SETTINGS getOrDefault ["quadrantBatchInterval", "MISSING"],
            MISSION_CORE_SETTINGS getOrDefault ["quadrantGraceTime", "MISSING"]];
    } else {
        diag_log "TUNE: MISSION_CORE_TUNE class NOT FOUND in missionConfigFile - defaults will be used";
    };
};

MISSION_CORE_fnc_tune = {
    params ["_key", ["_default", 0]];
    if (isNil "MISSION_CORE_SETTINGS") exitWith { _default };
    (MISSION_CORE_SETTINGS getOrDefault [_key, _default])
};
