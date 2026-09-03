// Client-side Intel Panel (right-side persistent explanation box, Antistasi-style).
// Compiled on every client via initPlayerLocal.sqf. The server (objective director) writes the
// panel content to a per-player publicVariable MISSION_CORE_INTEL_<uid>; this file's poll loop
// watches it and shows/hides the panel. No remoteExec of custom functions (whitelist-safe).
MISSION_CORE_fnc_showIntelPanel = {
    params ["_title", "_badge", "_accent", "_bodyText"];
    private _d = uiNamespace getVariable ["DYNOPS_IntelPanel", displayNull];
    if (isNull _d) then {
        createDialog "DYNOPS_IntelPanel";
        _d = uiNamespace getVariable ["DYNOPS_IntelPanel", displayNull];
    };
    if (isNull _d) exitWith {};
    (_d displayCtrl 1561) ctrlSetText _title;
    (_d displayCtrl 1563) ctrlSetText _badge;
    (_d displayCtrl 1562) ctrlSetStructuredText parseText _bodyText;
    // Tint the title bar (1565), left accent edge (1564), and badge text (1563) to the type color.
    (_d displayCtrl 1565) ctrlSetBackgroundColor _accent;
    (_d displayCtrl 1564) ctrlSetBackgroundColor _accent;
    (_d displayCtrl 1563) ctrlSetTextColor _accent;
};

MISSION_CORE_fnc_hideIntelPanel = {
    private _d = uiNamespace getVariable ["DYNOPS_IntelPanel", displayNull];
    if (!isNull _d) then { _d closeDisplay 1; };
};

MISSION_CORE_fnc_intelPanelWatch = {
    private _uid = getPlayerUID player;
    private _var = format ["MISSION_CORE_INTEL_%1", _uid];
    diag_log format ["INTEL PANEL: client watch started (uid '%1', var %2)", _uid, _var];
    private _last = "___unset___";
    while { true } do {
        sleep 1;
        private _data = missionNamespace getVariable [_var, []];
        if (_data isEqualType [] && { count _data > 0 }) then {
            if (_data isNotEqualTo _last) then {
                _last = +_data;
                diag_log format ["INTEL PANEL: client show '%1'", _data select 0];
                _data call MISSION_CORE_fnc_showIntelPanel;
            };
        } else {
            if (!(_last isEqualTo "___unset___")) then {
                _last = "___unset___";
                diag_log "INTEL PANEL: client hide";
                call MISSION_CORE_fnc_hideIntelPanel;
            };
        };
    };
};
