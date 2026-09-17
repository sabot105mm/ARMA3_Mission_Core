waitUntil { !isNull player };

// Wait for mission init with timeout (30s)
private _timeout = time + 30;
waitUntil { !isNil "MISSION_CORE_INITIALIZED" && { MISSION_CORE_INITIALIZED || time > _timeout } };

if !(MISSION_CORE_INITIALIZED) exitWith {
    diag_log "DYNAMIC OPS: Client init timeout - mission core not ready";
};

// Initialize client-side systems
// Defense builder (Zeus-style overhead build camera, hotkey B)
call compile preprocessFileLineNumbers "fnc\fn_defenseBuilder.sqf";
MISSION_CORE_DEFENSE_POINTS_DEFAULT = getNumber (missionConfigFile >> "DEFENSE_BUILD_POINTS_DEFAULT");
MISSION_CORE_DEFENSE_POINTS_CAPTURE_REWARD = getNumber (missionConfigFile >> "DEFENSE_BUILD_POINTS_CAPTURE_REWARD");
// Register the hotkey once the mission display is actually available. Registering against a null
// display at init time silently drops the handler, which is why B can appear to "do nothing".
[] spawn {
    waitUntil { !isNull (findDisplay 46) };
    (findDisplay 46) displayAddEventHandler ["KeyDown", {
        if (_this select 1 == 0x30) then { // B key
            [] call MISSION_CORE_fnc_openDefenseBuilder;
        };
    }];
    diag_log "DEFENSE BUILDER: hotkey B registered on display 46";
};

// Recruitment system (tabbed menu: Player / Garrison / Attack)
// Road-column spawn helper for client-side recruit ATTACK deploys (BIS_fnc_spawnGroup paths
// reposition their vehicles onto a road through this file).
call compile preprocessFileLineNumbers "fnc\spawn\fn_findVehicleColumnPos.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_stopForDismount.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_playNoteSound.sqf";
call compile preprocessFileLineNumbers "fnc\fn_recruit.sqf";
call compile preprocessFileLineNumbers "fnc\fn_manpower.sqf";
[] call MISSION_CORE_fnc_initRecruitment;
[] spawn MISSION_CORE_fnc_monitorAttackGroups;
[] spawn MISSION_CORE_fnc_monitorBluforStaging;
// Actions on the unit are lost on respawn (new unit object), so (re)attach them via a wrapper
// callable from init AND from the Respawn event handler below.
MISSION_CORE_fnc_setupPlayerActions = {
    { player removeAction _x; } forEach (missionNamespace getVariable ["MISSION_CORE_PLAYER_ACTION_IDS", []]);
    MISSION_CORE_PLAYER_ACTION_IDS = [
        player addAction [
            "Recruit Forces",
            { [] call MISSION_CORE_fnc_openRecruitment; },
            [], 1, true, true, "", "side player == WEST"
        ],
        player addAction [
            "Marine Force Recon HQ",
            { [] call MISSION_CORE_fnc_openUnlockMenu; },
            [], 6, true, true, "", "[] call MISSION_CORE_fnc_reconActionVisible"
        ]
    ];
};
[] call MISSION_CORE_fnc_setupPlayerActions;

// Renown + Force Recon: unlocked units + gear bought at the HQ flag
call compile preprocessFileLineNumbers "fnc\fn_reconClient.sqf";
// Pre-fetch the recon state (join-in-progress clients miss the init broadcast).
[] spawn {
    waitUntil { !isNil "MISSION_CORE_INITIALIZED" && { MISSION_CORE_INITIALIZED } };
    sleep 1;
    [] call MISSION_CORE_fnc_reconPullState;
};

// Field manual (help menu, H key)
call compile preprocessFileLineNumbers "fnc\fn_helpMenu.sqf";

// Advanced hints (BIS_fnc_advHint contextual education + ESC Field Manual via CfgHints)
call compile preprocessFileLineNumbers "fnc\fn_advHints.sqf";
[] spawn MISSION_CORE_fnc_advHintDriver;

// Map diary (Notes tab, M key) built from the same topics as the H-key field manual
call compile preprocessFileLineNumbers "fnc\fn_diary.sqf";
[] spawn {
    waitUntil { !isNull player };
    [] call MISSION_CORE_fnc_setupDiary;
};

// Key handler for recruit menu (X key) + field manual (H key)
(findDisplay 46) displayAddEventHandler ["KeyDown", {
    if (_this select 1 == 0x2D) then { // X key
        [] call MISSION_CORE_fnc_openRecruitment;
    };
    if (_this select 1 == 0x23) then { // H key
        [] call MISSION_CORE_fnc_openHelpMenu;
    };
}];

// Re-attach unit menus across respawns (addActions do not survive a new unit object).
addMissionEventHandler ["EntityRespawned", {
    params ["_newEntity", "_oldEntity"];
    if (_newEntity == player) then {
        { _oldEntity removeAction _x; } forEach (missionNamespace getVariable ["MISSION_CORE_PLAYER_ACTION_IDS", []]);
        [] call MISSION_CORE_fnc_setupPlayerActions;
    };
}];

diag_log format ["DYNAMIC OPS: Player %1 initialized", name player];
