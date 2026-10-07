//
// BALANCE TUNING LOADER
//
// Reads the mission-config MISSION_CORE_TUNE class once at server init into the global
// MISSION_CORE_SETTINGS hashmap. Everything gameplay-critical (spawn radii, foot budget, armor
// caps, hunt/house radii, tank production, capture windows) is a number here - tweak
// config\missionVars.hpp and restart, no SQF edits needed.
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
        // Array properties are loaded too (e.g. nonCombatEffectiveMarkers). Without the isArray
        // branch a string-array key was silently DROPPED here - not an error, just absent - so the
        // SQF fallback always won and the value could never be tuned from config. An empty property
        // reads back as [] and is skipped so it cannot shadow a caller's own default.
        private _numCount = 0;
        private _arrCount = 0;
        for "_i" from 0 to (count _cfg - 1) do {
            private _entry = _cfg select _i;
            if (isNumber _entry) then {
                MISSION_CORE_SETTINGS set [configName _entry, getNumber _entry];
                _numCount = _numCount + 1;
            };
            if (isArray _entry) then {
                private _arr = getArray _entry;
                if (count _arr > 0) then {
                    MISSION_CORE_SETTINGS set [configName _entry, _arr];
                    _arrCount = _arrCount + 1;
                };
            };
        };
        diag_log format ["TUNE: loaded %1 values (%2 numeric, %3 array) (quadrantReleasePerTick=%4, quadrantPerTargetMax=%5, quadrantBatchInterval=%6, quadrantGraceTime=%7)", count MISSION_CORE_SETTINGS, _numCount, _arrCount,
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
