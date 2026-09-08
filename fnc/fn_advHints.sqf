// Client-side ADVANCED HINTS driver (BIS_fnc_advHint). Registered in initPlayerLocal.sqf.
// The full reference text for every mechanic lives in description.ext >> class CfgHints
// (class DynOps), which the engine also lists under "<Mission>" in the ESC Field Manual.
// This script only fires a handful of CONTEXTUAL hints, once per mission, at the moments
// they matter. dlc = -1 in the config stops diary-log spam when a hint is shown.

// Shows an advanced hint a maximum of once. Classes = ["DynOps", "<hint name>"] as configured.
MISSION_CORE_fnc_advHintOnce = {
    params ["_classes", ["_fullTime", 30], ["_onlyFull", false]];
    if (isNil "MISSION_CORE_ADVHINTS_SHOWN") then { MISSION_CORE_ADVHINTS_SHOWN = createHashMap; };
    private _key = "";
    {
        _key = _key + _x;
        if (_forEachIndex < (count _classes) - 1) then { _key = _key + "_"; };
    } forEach _classes;
    if (MISSION_CORE_ADVHINTS_SHOWN getOrDefault [_key, false]) exitWith {};
    MISSION_CORE_ADVHINTS_SHOWN set [_key, true];
    private _displayStr = "";
    {
        _displayStr = _displayStr + _x;
        if (_forEachIndex < (count _classes) - 1) then { _displayStr = _displayStr + " > "; };
    } forEach _classes;
    diag_log format ["ADV HINTS: showing %1", _displayStr];
    // [classes, shortDur, shortCond, fullDur, fullCond, showIfDisabled, onlyFull, onlyOnce, sound]
    // showIfDisabled=true: render even if the player disabled Advanced Hints in Options > Game
    // (otherwise the engine silently drops the hint and the contextual education never appears).
    [_classes, 12, "", _fullTime, "", true, _onlyFull, true, true] call BIS_fnc_advHint;
};

// Background driver: sleeps until the player exists, then fires the Welcome hint and starts a
// slow event loop that educates at teachable moments. Uses only client-visible data.
MISSION_CORE_fnc_advHintDriver = {
    waitUntil { !isNull player };
    sleep 6;
    if (isNil "MISSION_CORE_ADVHINTS_SHOWN") then { MISSION_CORE_ADVHINTS_SHOWN = createHashMap; };
    [["DynOps", "Welcome"], 30, true] call MISSION_CORE_fnc_advHintOnce;

    [] spawn {
        private _hostileSpotted = false;
        private _lightInfraSeen = false;
        while { true } do {
            sleep 15;
            if (isNull player || { !(alive player) } || { !(isNull (findDisplay 1570)) }) then { continue; };

            // 1) First hostile contact (REDFOR within 350m) -> the combat/counter-attack loop.
            if (!_hostileSpotted && { side player == WEST }) then {
                private _near = allUnits findIf { !isNull _x && { side _x == EAST } && { alive _x } && { _x distance2D player < 350 } };
                if (_near != -1) then {
                    _hostileSpotted = true;
                    [["DynOps", "EnemyAI"], 28, false] call MISSION_CORE_fnc_advHintOnce;
                };
            };

            // 2) First time a light-infrastructure marker enters the broadcast contested set
            //    (power_ / solar_ / outpost_ markers) -> they fight alone, no neighbours join.
            if (!_lightInfraSeen && !(isNil "MISSION_CORE_CONTESTED_MARKERS")) then {
                private _found = MISSION_CORE_CONTESTED_MARKERS findIf {
                    (_x find "power_" == 0) || { (_x find "solar_" == 0) } || { (_x find "outpost_" == 0) }
                };
                if (_found != -1) then {
                    _lightInfraSeen = true;
                    [["DynOps", "LightInfra"], 28, false] call MISSION_CORE_fnc_advHintOnce;
                };
            };
        };
    };
};