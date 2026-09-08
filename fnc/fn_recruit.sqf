// =====================================================================
// RECRUIT MENU SYSTEM
//
// Tabbed interface (PLAYER | GARRISON | ATTACK) that replaces the old
// single-list recruit menu. Players spend manpower to recruit squads
// for their group, garrison BLUFOR markers, or launch attacks on
// enemy markers with full waypoint control.
// =====================================================================

// -------------------------------------------------------------------
// GLOBALS
// -------------------------------------------------------------------
MISSION_CORE_RECRUIT_ACTIVE_TAB = 0;
MISSION_CORE_RECRUIT_ATTACK_TARGET = "";
MISSION_CORE_RECRUIT_ATTACK_TARGET_POS = [0,0,0];
MISSION_CORE_RECRUIT_ATTACK_SQUAD_IDX = -1;
MISSION_CORE_RECRUIT_SAVED_WAYPOINTS = [];
MISSION_CORE_RECRUIT_WAYPOINT_MARKERS = [];
MISSION_CORE_RECRUIT_NEXT_GRP_ID = 0;

if (isNil "MISSION_CORE_ATTACK_GROUPS") then { MISSION_CORE_ATTACK_GROUPS = createHashMap; };

// Garrison tab state.
MISSION_CORE_RECRUIT_GARRISON_MARKER = "";
MISSION_CORE_RECRUIT_VEH_KIND = "tank";
MISSION_CORE_RECRUIT_LAST_RESULT = "";
MISSION_CORE_RECRUIT_VEH_KINDS = ["tank", "apc", "gunTruck", "mlrs_spg", "mortar"];
MISSION_CORE_RECRUIT_VEH_COSTS = createHashMapFromArray [
    ["tank", 4], ["apc", 3], ["gunTruck", 2], ["mlrs_spg", 80], ["mortar", 30]
];

// -------------------------------------------------------------------
// INITIALIZATION
// -------------------------------------------------------------------

// Proximity gate: true when the player is inside a BLUFOR marker.
MISSION_CORE_fnc_initRecruitment = {
    [] spawn {
        waitUntil { !isNull player };
        waitUntil { !isNil "MISSION_CORE_INITIALIZED" && { MISSION_CORE_INITIALIZED } };
        waitUntil { !isNil "MISSION_CORE_LOCATIONS" };
        while { true } do {
            sleep 3;
            if (!alive player) then {
                player setVariable ["MISSION_CAN_RECRUIT", false, true];
                continue;
            };
            private _near = false;
            {
                if ((_x select 5) == WEST) then {
                    // True marker-area membership: inArea respects the marker's real shape (ELLIPSE
                    // or RECTANGLE), its size and its rotation, so the menu opens anywhere inside the
                    // marker - including the corners of a rectangular/square marker, not just a circle
                    // around its center (the old distance check clipped rectangle corners).
                    if (player inArea (_x select 0)) exitWith { _near = true; };
                };
            } forEach MISSION_CORE_LOCATIONS;
            player setVariable ["MISSION_CAN_RECRUIT", _near, true];
        };
    };
};

// Monitor attack groups for wipes. When a group is wiped, mark it and notify the player.
// PERMANENT RULE: BLUFOR assault groups never go idle at a captured objective - once their target
// marker flips to BLUFOR, the surviving group is re-tasked to assault the nearest remaining enemy
// marker, so it keeps pressing the front instead of sitting at (or returning from) the old target.
MISSION_CORE_fnc_monitorAttackGroups = {
    [] spawn {
        waitUntil { !isNil "MISSION_CORE_INITIALIZED" && { MISSION_CORE_INITIALIZED } };
        while { true } do {
            sleep 5;
            {
                private _data = _y;
                _data params ["_grp", "_target", "_wps", "_tmpl", "_side", "_status", ["_targetPos", [0, 0, 0]]];
                if (_status == "active" && {isNull _grp || {count units _grp == 0}}) then {
                    _data set [5, "wiped"];
                    MISSION_CORE_ATTACK_GROUPS set [_x, _data];
                    hint format ["Attack group #%1 wiped out!\nOpen recruit menu (X) to re-recruit.", _x];
                } else {
                    if (_status == "active" && { !isNull _grp } && { count units _grp > 0 } && { !isNil "MISSION_CORE_LOCATIONS" }) then {
                        private _tLocIdx = MISSION_CORE_LOCATIONS findIf { (_x select 0) == _target };
                        private _flipped = _tLocIdx >= 0 && { ((MISSION_CORE_LOCATIONS select _tLocIdx) select 5) == WEST };
                        if (_flipped) then {
                            private _ldr = leader _grp;
                            private _newTarget = "";
                            private _newPos = [0, 0, 0];
                            private _bestD = 1e10;
                            {
                                private _l = _x;
                                if ((_l select 5) == EAST) then {
                                    private _lp = ((_l select 1) select 0);
                                    private _d = if (isNull _ldr) then { 1e10 } else { _ldr distance _lp };
                                    if (_d < _bestD) then { _bestD = _d; _newTarget = _l select 0; _newPos = _lp; };
                                };
                            } forEach MISSION_CORE_LOCATIONS;
                            if (_newTarget != "" && { _newTarget != _target }) then {
                                [_grp] call MISSION_CORE_fnc_clearGroupWaypoints;
                                _grp setBehaviour "AWARE";
                                _grp setCombatMode "YELLOW";
                                _grp setSpeedMode "FULL";
                                private _wp = _grp addWaypoint [_newPos, 50];
                                _wp setWaypointType "SAD";
                                _wp setWaypointCombatMode "YELLOW";
                                _wp setWaypointSpeed "FULL";
                                _wp setWaypointBehaviour "AWARE";
                                _grp setCurrentWaypoint _wp;
                                _grp setVariable ["MISSION_CORE_ATTACK_TARGET", _newPos];
                                _data set [1, _newTarget];
                                _data set [6, _newPos];
                                MISSION_CORE_ATTACK_GROUPS set [_x, _data];
                                hint format ["Attack group #%1 re-tasked: %2 captured - assaulting %3 now.", _x, _target, _newTarget];
                            };
                        };
                    };
                };
            } forEach MISSION_CORE_ATTACK_GROUPS;
        };
    };
};

// -------------------------------------------------------------------
// MAIN MENU
// -------------------------------------------------------------------

MISSION_CORE_fnc_openRecruitment = {
    if !(alive player) exitWith {};
    if !(player getVariable ["MISSION_CAN_RECRUIT", false]) exitWith { hint "No recruitment available here"; };
    if (!isNull (uiNamespace getVariable ["DYNOPS_RecruitMenu", objNull])) exitWith {};
    disableSerialization;
    createDialog "DYNOPS_RecruitMenu";
};

// Manual refresh (top-left REFRESH button). No auto-refresh: values only update on demand so the
// menu never churns selections underneath the player.
MISSION_CORE_fnc_recruitManualRefresh = {
    disableSerialization;
    if (isNull (uiNamespace getVariable ["DYNOPS_RecruitMenu", objNull])) exitWith {};
    call MISSION_CORE_fnc_recruitMenuUpdateMP;
    call MISSION_CORE_fnc_recruitMenuUpdatePortBtn;
    call MISSION_CORE_fnc_recruitMenuUpdateArmorPool;
    call MISSION_CORE_fnc_recruitMenuPopulatePlayer;
    call MISSION_CORE_fnc_recruitMenuPopulateAttack;
    if (MISSION_CORE_RECRUIT_ACTIVE_TAB == 1) then {
        call MISSION_CORE_fnc_recruitMenuPopulateDefend;
    };
    hintSilent "Recruit menu refreshed.";
};

// Called on dialog load (onLoad in description.ext).
MISSION_CORE_fnc_recruitMenuLoad = {
    disableSerialization;
    private _disp = uiNamespace getVariable "DYNOPS_RecruitMenu";
    _disp displaySetEventHandler ["KeyDown", "if (_this select 1 == 0x2D) then { closeDialog 0; };"];

    // Populate player tab
    call MISSION_CORE_fnc_recruitMenuPopulatePlayer;
    // Populate defend tab
    call MISSION_CORE_fnc_recruitMenuPopulateDefend;
    // Populate attack tab
    call MISSION_CORE_fnc_recruitMenuPopulateAttack;
    // Update manpower
    call MISSION_CORE_fnc_recruitMenuUpdateMP;
    // Reflect current port-priority state on the toggle button
    call MISSION_CORE_fnc_recruitMenuUpdatePortBtn;
    // Show the live armor pool on the note
    call MISSION_CORE_fnc_recruitMenuUpdateArmorPool;

    // Restore last tab or default to player
    private _tab = MISSION_CORE_RECRUIT_ACTIVE_TAB;
    _tab call MISSION_CORE_fnc_recruitMenuTab;
};

// Populate the player tab unit list.
MISSION_CORE_fnc_recruitMenuPopulatePlayer = {
    disableSerialization;
    private _disp = uiNamespace getVariable "DYNOPS_RecruitMenu";
    private _list = _disp displayCtrl 1612;
    lbClear _list;
    private _recruits = [];
    if (!isNil "MISSION_CORE_BLUFOR_DATA") then { _recruits = MISSION_CORE_BLUFOR_DATA select 19; };
    private _costPer = if (isNil "MISSION_CORE_MANPOWER_PER_UNIT") then { 10 } else { MISSION_CORE_MANPOWER_PER_UNIT };
    {
        private _cost = _costPer;
        private _idx = _list lbAdd format ["%1  [%2 MP]", _x, _cost];
        _list lbSetData [_idx, _x];
    } forEach _recruits;
    _list lbSetCurSel -1;
};

// Populate the attack tab (enemy markers + squad templates + re-recruit list).
MISSION_CORE_fnc_recruitMenuPopulateAttack = {
    disableSerialization;
    private _disp = uiNamespace getVariable "DYNOPS_RecruitMenu";

    // Enemy markers sorted closest to player first
    private _targetList = _disp displayCtrl 1632;
    lbClear _targetList;
    private _redLocs = MISSION_CORE_LOCATIONS select { (_x select 5) == EAST };
    _redLocs = [_redLocs, [], { player distance ((_x select 1) select 0) }, "ASCEND"] call BIS_fnc_sortBy;
    {
        private _name = _x select 0;
        private _label = if (count _x > 8 && {(_x select 8) != ""}) then { _x select 8 } else { _name };
        private _imp = _x select 7;
        private _dist = round (player distance ((_x select 1) select 0));
        _targetList lbAdd format ["%1 [Imp %2] %3m", _label, _imp, _dist];
        _targetList lbSetData [lbSize _targetList - 1, _name];
    } forEach _redLocs;
    _targetList lbSetCurSel -1;

    // Squad templates: infantry, motorized, mechanized, and armored groups
    private _squadList = _disp displayCtrl 1634;
    lbClear _squadList;
    private _groups = [];
    if (!isNil "MISSION_CORE_BLUFOR_DATA") then { _groups = MISSION_CORE_BLUFOR_DATA select 17; };
    private _attackCategories = ["Infantry","Motorized","Mechanized","Armored"];
    private _combatGroups = _groups select {
        private _cat = _x select 4;
        (_attackCategories findIf { _cat find _x > -1 } >= 0) &&
        {(_x select 2) >= 2 && (_x select 2) <= 20}
    };
    {
        private _name = _x select 0;
        private _count = _x select 2;
        private _cat = _x select 4;
        private _subCat = _x select 3;
        _squadList lbAdd format ["%1 (%2) - %3", _name, _count, _cat];
    } forEach _combatGroups;
    uiNamespace setVariable ["MISSION_CORE_RECRUIT_ATTACK_GROUPS", _combatGroups];
    _squadList lbSetCurSel -1;

    // Re-recruit list: wiped attack groups
    private _reList = _disp displayCtrl 1638;
    lbClear _reList;
    private _wiped = [];
    {
        private _data = _y;
        if ((_data select 5) == "wiped") then {
            _wiped pushBack [_x, _data];
        };
    } forEach MISSION_CORE_ATTACK_GROUPS;
    {
        private _id = _x select 0;
        private _data = _x select 1;
        _data params ["_grp", "_target", "_wps", "_tmpl"];
        private _wpCount = count _wps;
        _reList lbAdd format ["Group #%1 -> %2 (%3 WPs)", _id, _target, _wpCount];
        _reList lbSetData [lbSize _reList - 1, str _id];
    } forEach _wiped;
    _reList lbSetCurSel -1;
    uiNamespace setVariable ["MISSION_CORE_RECRUIT_REWIPED", _wiped];
};

// Tab switching.
MISSION_CORE_fnc_recruitMenuTab = {
    params [["_tab", 0]];
    MISSION_CORE_RECRUIT_ACTIVE_TAB = _tab;
    disableSerialization;
    private _disp = uiNamespace getVariable "DYNOPS_RecruitMenu";
    if (isNull _disp) exitWith {};

    // Player tab: 1610-1614
    { (_disp displayCtrl _x) ctrlShow (_tab == 0) } forEach [1610, 1611, 1612, 1613, 1614];
    // Defend tab: 1620-1625, 1641-1659
    { (_disp displayCtrl _x) ctrlShow (_tab == 1) } forEach [1620, 1621, 1622, 1623, 1624, 1625, 1641, 1642, 1645, 1646, 1647, 1648, 1650, 1651, 1652, 1653, 1654, 1655, 1659, 1660];
    // Attack tab: 1630-1640, 1661-1663
    { (_disp displayCtrl _x) ctrlShow (_tab == 2) } forEach [1630, 1631, 1632, 1633, 1634, 1635, 1636, 1637, 1638, 1639, 1640, 1661, 1664, 1663];

    // Tab button highlight
    private _tabColors = [
        [0.4,0.7,0.3,0.95],  // player active
        [0.3,0.5,0.2,0.95],  // player inactive
        [0.3,0.4,0.7,0.95],  // defend active
        [0.2,0.3,0.5,0.95],  // defend inactive
        [0.7,0.3,0.3,0.95],  // attack active
        [0.5,0.2,0.2,0.95]   // attack inactive
    ];
    (_disp displayCtrl 1601) ctrlSetBackgroundColor (_tabColors select (if (_tab == 0) then {0} else {1}));
    (_disp displayCtrl 1602) ctrlSetBackgroundColor (_tabColors select (if (_tab == 1) then {2} else {3}));
    (_disp displayCtrl 1603) ctrlSetBackgroundColor (_tabColors select (if (_tab == 2) then {4} else {5}));
};

// Update manpower display.
MISSION_CORE_fnc_recruitMenuUpdateMP = {
    disableSerialization;
    private _disp = uiNamespace getVariable ["DYNOPS_RecruitMenu", objNull];
    if (isNull _disp) exitWith {};
    private _mp = if (isNil "MISSION_CORE_BLUFOR_MANPOWER") then { 0 } else { MISSION_CORE_BLUFOR_MANPOWER };
    (_disp displayCtrl 1604) ctrlSetText format ["MANPOWER: %1", round _mp];
};

// Cleanup on dialog close.
MISSION_CORE_fnc_recruitMenuExit = {
    uiNamespace setVariable ["DYNOPS_RecruitMenu", objNull];
    // Kill any lingering waypoint editor handlers
    onMapSingleClick "";
    private _kid = missionNamespace getVariable ["MISSION_CORE_RECRUIT_WP_KEYHANDLER", -1];
    if (_kid >= 0) then {
        private _md = findDisplay 12;
        if (!isNull _md) then { _md displayRemoveEventHandler ["KeyDown", _kid]; };
    };
    missionNamespace setVariable ["MISSION_CORE_RECRUIT_WP_KEYHANDLER", -1];
    // Clean up HUD controls if the map is open
    if (visibleMap) then { call MISSION_CORE_fnc_wpEditorDestroyHUD; };
    // Clean up any WP markers
    { deleteMarkerLocal _x } forEach MISSION_CORE_RECRUIT_WAYPOINT_MARKERS;
    MISSION_CORE_RECRUIT_WAYPOINT_MARKERS = [];
};

// -------------------------------------------------------------------
// PLAYER TAB
// -------------------------------------------------------------------

// Update cost display when a unit is selected.
MISSION_CORE_fnc_recruitPlayerSelect = {
    params ["_ctrl", "_idx"];
    if (_idx < 0) exitWith {};
    disableSerialization;
    private _disp = uiNamespace getVariable "DYNOPS_RecruitMenu";
    private _costPer = if (isNil "MISSION_CORE_MANPOWER_PER_UNIT") then { 10 } else { MISSION_CORE_MANPOWER_PER_UNIT };
    (_disp displayCtrl 1614) ctrlSetText format ["COST: %1 MP", _costPer];
};

// Recruit the selected unit into the player's group.
MISSION_CORE_fnc_recruitPlayerUnit = {
    if !(alive player) exitWith {};
    if !(player getVariable ["MISSION_CAN_RECRUIT", false]) exitWith { hint "Too far from base."; };
    disableSerialization;
    private _disp = uiNamespace getVariable "DYNOPS_RecruitMenu";
    private _list = _disp displayCtrl 1612;
    private _idx = lbCurSel _list;
    if (_idx < 0) exitWith { hint "Select a unit first."; };
    private _class = _list lbData _idx;
    if (_class == "") exitWith {};

    private _costPer = if (isNil "MISSION_CORE_MANPOWER_PER_UNIT") then { 10 } else { MISSION_CORE_MANPOWER_PER_UNIT };
    if (isNil "MISSION_CORE_BLUFOR_MANPOWER") then { MISSION_CORE_BLUFOR_MANPOWER = 0; };
    if (MISSION_CORE_BLUFOR_MANPOWER < _costPer) exitWith { hint "Not enough manpower!"; };

    MISSION_CORE_BLUFOR_MANPOWER = MISSION_CORE_BLUFOR_MANPOWER - _costPer;
    publicVariable "MISSION_CORE_BLUFOR_MANPOWER";

    private _grp = group player;
    private _unit = _grp createUnit [_class, getPos player, [], 0, "FORM"];
    hint format ["Recruited %1 (-%2 MP)", _class, _costPer];
    call MISSION_CORE_fnc_recruitMenuUpdateMP;
};

// -------------------------------------------------------------------
// DEFEND TAB
// -------------------------------------------------------------------

// --- GARRISON MANAGER ---------------------------------------------------
// The GARRISON tab lets a player select any BLUFOR marker, inspect its
// current garrison, add additional squads / tanks / APCs / artillery
// (subject to per-marker limits), and remove existing groups/vehicles.
// All spawning is done server-side (remoteExec) for vehicle/crew authority.

// Populate the garrison tab: all BLUFOR markers with status + squad templates.
MISSION_CORE_fnc_recruitMenuPopulateDefend = {
    disableSerialization;
    private _disp = findDisplay 1600;
    if (isNull _disp) exitWith {};

    // Preserve the player's current squad selection across this refresh (the 5s live-refresh loop calls
    // this repeatedly; without this the squad selection would be reset to -1 each tick). The vehicle
    // list preserves its own selection inside recruitMenuPopulateVehList, and the marker list here.
    private _selSquad = "";
    if (!isNil "MISSION_CORE_RECRUIT_DEFEND_GROUPS") then {
        private _tmpList = _disp displayCtrl 1622;
        private _tmpIdx = lbCurSel _tmpList;
        if (_tmpIdx >= 0 && { _tmpIdx < count MISSION_CORE_RECRUIT_DEFEND_GROUPS }) then {
            _selSquad = (MISSION_CORE_RECRUIT_DEFEND_GROUPS select _tmpIdx) select 0;
        };
    };

    // All BLUFOR markers, flagged when contested or under AI assault.
    private _markerList = _disp displayCtrl 1623;
    lbClear _markerList;
    if (isNil "MISSION_CORE_CONTESTED_MARKERS") then { MISSION_CORE_CONTESTED_MARKERS = []; };
    if (isNil "MISSION_CORE_ASSAULT_TARGET") then { MISSION_CORE_ASSAULT_TARGET = ""; };
    private _bluLocs = MISSION_CORE_LOCATIONS select { (_x select 5) == WEST };
    _bluLocs = [_bluLocs, [], { player distance ((_x select 1) select 0) }, "ASCEND"] call BIS_fnc_sortBy;
    private _savedSel = MISSION_CORE_RECRUIT_GARRISON_MARKER;
    private _savedIdx = -1;
    {
        private _name = _x select 0;
        private _label = if (count _x > 8 && {(_x select 8) != ""}) then { _x select 8 } else { _name };
        private _imp = _x select 7;
        private _underAttack = (_name in MISSION_CORE_CONTESTED_MARKERS) || { _name == MISSION_CORE_ASSAULT_TARGET };
        private _suffix = if (_underAttack) then { "  [UNDER ATTACK]" } else { "" };
        private _idx = _markerList lbAdd format ["%1 [Imp %2]%3", _label, _imp, _suffix];
        _markerList lbSetData [_idx, _name];
        if (_name == _savedSel) then { _savedIdx = _idx; };
    } forEach _bluLocs;
    if (count _bluLocs == 0) then { _markerList lbAdd "No BLUFOR markers"; };
    uiNamespace setVariable ["MISSION_CORE_RECRUIT_GARRISON_LOCS", _bluLocs];
    if (_savedIdx >= 0) then {
        _markerList lbSetCurSel _savedIdx;
    } else {
        _markerList lbSetCurSel -1;
    };

    // Squad templates (infantry from CfgGroups).
    private _squadList = _disp displayCtrl 1622;
    lbClear _squadList;
    private _groups = [];
    if (!isNil "MISSION_CORE_BLUFOR_DATA") then { _groups = MISSION_CORE_BLUFOR_DATA select 17; };
    private _infGroups = _groups select {
        private _sub = _x select 3;
        (_sub == "inf" || {_sub find "inf" == 0}) &&
        {({[_x] call MISSION_CORE_fnc_isCombatMan} count (_x select 1)) == count (_x select 1)}
    };
    if (count _infGroups == 0) then { _infGroups = _groups select {
        ({[_x] call MISSION_CORE_fnc_isCombatMan} count (_x select 1)) == count (_x select 1) &&
        {(_x select 2) >= 3 && (_x select 2) <= 12}
    }; };
    {
        private _name = _x select 0;
        private _count = _x select 2;
        private _cat = _x select 4;
        _squadList lbAdd format ["%1 (%2) - %3", _name, _count, _cat];
    } forEach _infGroups;
    uiNamespace setVariable ["MISSION_CORE_RECRUIT_DEFEND_GROUPS", _infGroups];
    // Restore the previously selected squad template (matching by group name).
    private _restoreSquad = -1;
    if (_selSquad != "") then {
        { if (((_infGroups select _forEachIndex) select 0) == _selSquad) exitWith { _restoreSquad = _forEachIndex; }; } forEach _infGroups;
    };
    _squadList lbSetCurSel _restoreSquad;
    if (_restoreSquad < 0) then { _squadList lbSetCurSel -1; };

    call MISSION_CORE_fnc_recruitMenuUpdateDefendCost;
    call MISSION_CORE_fnc_recruitMenuPopulateVehList;
    call MISSION_CORE_fnc_recruitGarrisonRefreshDetail;
};

// Refresh garrison detail for the selected marker (asks server for a snapshot).
MISSION_CORE_fnc_recruitGarrisonRefreshDetail = {
    if (isNull (uiNamespace getVariable ["DYNOPS_RecruitMenu", objNull])) exitWith {};
    [] remoteExecCall ["MISSION_CORE_fnc_garrisonRefresh", 2];
    // Show any pending server result message.
    if !(isNil "MISSION_CORE_RECRUIT_RESULT") then {
        if (MISSION_CORE_RECRUIT_RESULT != MISSION_CORE_RECRUIT_LAST_RESULT) then {
            MISSION_CORE_RECRUIT_LAST_RESULT = MISSION_CORE_RECRUIT_RESULT;
            if (MISSION_CORE_RECRUIT_RESULT != "") then { hint MISSION_CORE_RECRUIT_RESULT; };
        };
    };
    call MISSION_CORE_fnc_recruitMenuPopulateGarrisonList;
};

// On marker selection: update the status text + garrison list.
MISSION_CORE_fnc_recruitGarrisonMarkerSelect = {
    params ["_ctrl", "_idx"];
    disableSerialization;
    private _disp = findDisplay 1600;
    if (isNull _disp) exitWith {};
    private _list = _disp displayCtrl 1623;
    if (_idx < 0) exitWith { MISSION_CORE_RECRUIT_GARRISON_MARKER = ""; };
    MISSION_CORE_RECRUIT_GARRISON_MARKER = _list lbData _idx;
    call MISSION_CORE_fnc_recruitMenuUpdateDefendCost;
    call MISSION_CORE_fnc_recruitMenuUpdatePortBtn;
    call MISSION_CORE_fnc_recruitGarrisonRefreshDetail;
};

// Update the squad cost display.
MISSION_CORE_fnc_recruitMenuUpdateDefendCost = {
    disableSerialization;
    private _disp = uiNamespace getVariable ["DYNOPS_RecruitMenu", objNull];
    if (isNull _disp) exitWith {};
    private _costPer = if (isNil "MISSION_CORE_MANPOWER_PER_UNIT") then { 10 } else { MISSION_CORE_MANPOWER_PER_UNIT };
    private _cost = 0;
    private _squadList = _disp displayCtrl 1622;
    private _sIdx = lbCurSel _squadList;
    private _templates = uiNamespace getVariable ["MISSION_CORE_RECRUIT_DEFEND_GROUPS", []];
    if (_sIdx >= 0 && { _sIdx < count _templates }) then {
        private _tc = (_templates select _sIdx) select 2;
        _cost = _tc * _costPer;
    };
    (_disp displayCtrl 1625) ctrlSetText format ["SQUAD COST: %1 MP", _cost];
};

// On squad template selection.
MISSION_CORE_fnc_recruitGarrisonSquadSelect = {
    call MISSION_CORE_fnc_recruitMenuUpdateDefendCost;
};

// Deploy a garrison squad (remoteExec to server).
MISSION_CORE_fnc_recruitGarrisonDeploy = {
    if !(alive player) exitWith {};
    if !(player getVariable ["MISSION_CAN_RECRUIT", false]) exitWith { hint "Too far from base."; };
    private _markerName = MISSION_CORE_RECRUIT_GARRISON_MARKER;
    if (_markerName == "") exitWith { hint "Select a marker first."; };
    disableSerialization;
    private _disp = findDisplay 1600;
    if (isNull _disp) exitWith {};
    private _squadList = _disp displayCtrl 1622;
    private _squadIdx = lbCurSel _squadList;
    if (_squadIdx < 0) exitWith { hint "Select a squad template."; };
    private _templates = uiNamespace getVariable ["MISSION_CORE_RECRUIT_DEFEND_GROUPS", []];
    if (_squadIdx >= count _templates) exitWith {};
    private _template = _templates select _squadIdx;
    _template params ["_grpName", "_grpUnits", "_unitCount", ["_subCat", ""], ["_catName", ""]];
    if (_catName == "" || _grpName == "") exitWith { hint "Invalid squad template."; };

    // Client-side manpower estimate (server re-validates + deducts).
    private _costPer = if (isNil "MISSION_CORE_MANPOWER_PER_UNIT") then { 10 } else { MISSION_CORE_MANPOWER_PER_UNIT };
    private _cost = _unitCount * _costPer;
    if (isNil "MISSION_CORE_BLUFOR_MANPOWER") then { MISSION_CORE_BLUFOR_MANPOWER = 0; };
    if (MISSION_CORE_BLUFOR_MANPOWER < _cost) exitWith { hint format ["Not enough manpower! Need %1 MP.", _cost]; };

    private _faction = MISSION_CORE_BLUFOR_DATA select 3;
    [player, _markerName, _template, _faction, _catName, _grpName, _cost] remoteExec ["MISSION_CORE_fnc_serverGarrisonDeploy", 2];
    MISSION_CORE_RECRUIT_LAST_RESULT = "";
};

// Cycle through vehicle kinds (tank/apc/gunTruck/mlrs_spg/mortar).
MISSION_CORE_fnc_recruitGarrisonCycleKind = {
    private _idx = MISSION_CORE_RECRUIT_VEH_KINDS find MISSION_CORE_RECRUIT_VEH_KIND;
    _idx = if (_idx >= count MISSION_CORE_RECRUIT_VEH_KINDS - 1) then { 0 } else { _idx + 1 };
    MISSION_CORE_RECRUIT_VEH_KIND = MISSION_CORE_RECRUIT_VEH_KINDS select _idx;
    call MISSION_CORE_fnc_recruitMenuPopulateVehList;
};

// Get the current list of vehicle classes for the selected kind.
MISSION_CORE_fnc_recruitVehClassesForKind = {
    params ["_kind"];
    private _arr = switch (_kind) do {
        case "tank": { if (isNil "MISSION_CORE_GARRISON_TANKS") then { [] } else { MISSION_CORE_GARRISON_TANKS }; };
        case "apc": { if (isNil "MISSION_CORE_GARRISON_APCS") then { [] } else { MISSION_CORE_GARRISON_APCS }; };
        case "gunTruck": { if (isNil "MISSION_CORE_GARRISON_GUNTRUCKS") then { [] } else { MISSION_CORE_GARRISON_GUNTRUCKS }; };
        case "mlrs_spg": { if (isNil "MISSION_CORE_GARRISON_ARTY") then { [] } else { MISSION_CORE_GARRISON_ARTY }; };
        case "mortar": { if (isNil "MISSION_CORE_GARRISON_MORTARS") then { [] } else { MISSION_CORE_GARRISON_MORTARS }; };
        default { [] };
    };
    _arr
};

// Populate the vehicle class list for the current kind.
MISSION_CORE_fnc_recruitMenuPopulateVehList = {
    disableSerialization;
    private _disp = findDisplay 1600;
    if (isNull _disp) exitWith {};
    private _list = _disp displayCtrl 1645;
    private _selVeh = "";
    private _selIdx = lbCurSel _list;
    if (_selIdx >= 0) then { _selVeh = _list lbData _selIdx; };
    lbClear _list;
    private _classes = [MISSION_CORE_RECRUIT_VEH_KIND] call MISSION_CORE_fnc_recruitVehClassesForKind;
    {
        private _dn = getText (configFile >> "CfgVehicles" >> _x >> "displayName");
        if (_dn == "") then { _dn = _x; };
        private _idx = _list lbAdd format ["%1", _dn];
        _list lbSetData [_idx, _x];
    } forEach _classes;
    if (count _classes == 0) then { _list lbAdd "None available"; };
    // Restore the previously selected vehicle class (if it's still in this kind's list).
    private _restoreVeh = -1;
    if (_selVeh != "") then {
        { if ((_classes select _forEachIndex) == _selVeh) exitWith { _restoreVeh = _forEachIndex; }; } forEach _classes;
    };
    _list lbSetCurSel _restoreVeh;
    private _kindLabel = switch (MISSION_CORE_RECRUIT_VEH_KIND) do {
        case "tank": { "TANK" };
        case "apc": { "APC" };
        case "gunTruck": { "GUN TRUCK" };
        case "mlrs_spg": { "MLRS/SPG" };
        case "mortar": { "MORTAR" };
        default { "TANK" };
    };
    (_disp displayCtrl 1648) ctrlSetText format ["KIND: %1", _kindLabel];
};

// Add the selected vehicle (remoteExec to server).
MISSION_CORE_fnc_recruitGarrisonAddVeh = {
    if !(alive player) exitWith {};
    if !(player getVariable ["MISSION_CAN_RECRUIT", false]) exitWith { hint "Too far from base."; };
    private _markerName = MISSION_CORE_RECRUIT_GARRISON_MARKER;
    if (_markerName == "") exitWith { hint "Select a marker first."; };
    disableSerialization;
    private _disp = findDisplay 1600;
    if (isNull _disp) exitWith {};
    private _list = _disp displayCtrl 1645;
    private _idx = lbCurSel _list;
    if (_idx < 0) exitWith { hint "Select a vehicle."; };
    private _vehClass = _list lbData _idx;
    if (_vehClass == "") exitWith { };

    private _cost = MISSION_CORE_RECRUIT_VEH_COSTS getOrDefault [MISSION_CORE_RECRUIT_VEH_KIND, 40];
    if (MISSION_CORE_RECRUIT_VEH_KIND == "tank") then {
        _cost = [_markerName] call MISSION_CORE_fnc_recruitTankCost;
    };
    if (isNil "MISSION_CORE_BLUFOR_MANPOWER") then { MISSION_CORE_BLUFOR_MANPOWER = 0; };
    if (MISSION_CORE_BLUFOR_MANPOWER < _cost) exitWith {
        if (MISSION_CORE_RECRUIT_VEH_KIND == "tank" && { [_markerName] call MISSION_CORE_fnc_recruitTankCost > MISSION_CORE_RECRUIT_VEH_COSTS getOrDefault ["tank", 4] }) then {
            hint format ["Not enough manpower! INSTANT tank delivery needs %1 MP (2x premium). Turn INSTANT DELIVERY off for the base cost.", _cost];
        } else {
            hint format ["Not enough manpower! Need %1 MP.", _cost];
        };
    };

    // Armor pool pre-check: instant tanks and SPG/MLRS recruits require an available tank in the
    // armor pool (the server refuses + refunds otherwise, but a clear hint here is friendlier).
    private _instantTank = (MISSION_CORE_RECRUIT_VEH_KIND == "tank" && { [_markerName] call MISSION_CORE_fnc_recruitTankCost > MISSION_CORE_RECRUIT_VEH_COSTS getOrDefault ["tank", 4] });
    if (_instantTank || { MISSION_CORE_RECRUIT_VEH_KIND in ["apc", "mlrs_spg"] }) then {
        private _pool = missionNamespace getVariable ["MISSION_CORE_ARMOR_POOL", 0];
        if (_pool < 1) exitWith {
            if (_instantTank) then {
                hint "No tank available in the armor pool for INSTANT delivery - wait for factories/ports to build tank points (turn INSTANT off for queued delivery).";
            } else {
                hint "No tank available in the armor pool to deploy this vehicle - wait for factories/ports to build tank points.";
            };
        };
    };

    [player, _markerName, _vehClass, MISSION_CORE_RECRUIT_VEH_KIND, _cost] remoteExec ["MISSION_CORE_fnc_serverAddVehicle", 2];
    MISSION_CORE_RECRUIT_LAST_RESULT = "";
};

// HQ toggle: INSTANT TANK DELIVERY for the selected marker (2x MP, tank drawn from the armor
// pool immediately) vs standard queued depot/port delivery at base cost. Each click flips the
// switch for the selected marker. The button's label + color reflect the live state (also synced
// via the publicVariable MISSION_CORE_PORT_PRIORITY).
MISSION_CORE_fnc_recruitGarrisonPrioritizePort = {
    if !(alive player) exitWith {};
    if !(player getVariable ["MISSION_CAN_RECRUIT", false]) exitWith { hint "Too far from base."; };
    private _markerName = MISSION_CORE_RECRUIT_GARRISON_MARKER;
    if (_markerName == "") exitWith { hint "Select a marker first."; };
    // Toggle on the server; the resulting state is broadcast back via the publicVariable and the
    // 5s refresh loop keeps the button label in sync. INSTANT TANK DELIVERY is a per-marker switch
    // LIST so one marker's toggle never clobbers another and it survives menu refreshes. We also
    // flip the local view immediately so the switch responds instantly (the server publicVariable
    // corrects any mismatch on the next tick).
    private _cur = missionNamespace getVariable ["MISSION_CORE_PORT_PRIORITY", []];
    if (isNil "_cur") then { _cur = []; };
    private _i = _cur find _markerName;
    if (_i >= 0) then { _cur deleteAt _i; } else { _cur pushBack _markerName; };
    missionNamespace setVariable ["MISSION_CORE_PORT_PRIORITY", _cur];
    [_markerName] remoteExec ["MISSION_CORE_fnc_prioritizePort", 2];
    call MISSION_CORE_fnc_recruitMenuUpdatePortBtn;
};

// Refresh the INSTANT TANK DELIVERY toggle button's label/color to match the selected marker's
// current state. ON = tanks for this marker are delivered instantly at 2x MP; OFF = standard queued
// depot/port delivery at normal cost.
MISSION_CORE_fnc_recruitMenuUpdatePortBtn = {
    private _disp = uiNamespace getVariable ["DYNOPS_RecruitMenu", objNull];
    if (isNull _disp) exitWith {};
    private _btn = _disp displayCtrl 1660;
    if (isNull _btn) exitWith {};
    private _marker = MISSION_CORE_RECRUIT_GARRISON_MARKER;
    private _pri = missionNamespace getVariable ["MISSION_CORE_PORT_PRIORITY", []];
    if (isNil "_pri") then { _pri = []; };
    private _on = (_marker != "" && { _marker in _pri });
    if (_on) then {
        _btn ctrlSetText "INSTANT TANK DELIVERY: ON (2x MP, click to turn off)";
        _btn ctrlSetBackgroundColor [0.12, 0.32, 0.12, 0.95];
    } else {
        _btn ctrlSetText "INSTANT TANK DELIVERY: OFF";
        _btn ctrlSetBackgroundColor [0.3, 0.45, 0.3, 0.95];
    };
    call MISSION_CORE_fnc_recruitMenuUpdateRefillCheck;
};

// Refresh the REFILL GARRISON checkbox to match the selected marker's current state. ON = killed
// squads/vehicles at that marker are rebuilt at 4x MP once no enemy is close. Mirrors the INSTANT
// TANK DELIVERY toggle sync (same refresh loop + marker-select hooks).
MISSION_CORE_fnc_recruitMenuUpdateRefillCheck = {
    private _disp = uiNamespace getVariable ["DYNOPS_RecruitMenu", objNull];
    if (isNull _disp) exitWith {};
    private _cb = _disp displayCtrl 1662;
    if (isNull _cb) exitWith {};
    private _marker = MISSION_CORE_RECRUIT_GARRISON_MARKER;
    private _ref = missionNamespace getVariable ["MISSION_CORE_GARRISON_REFILL", []];
    if (isNil "_ref") then { _ref = []; };
    _cb cbSetChecked (_marker != "" && { _marker in _ref });
};

// Checkbox handler (onCheckedChanged passes 1/0). Local list flips immediately so the UI responds;
// the server is told the absolute end-state with remotExec (flip is NOT used server-side - Set is
// idempotent against the 5s refresh race).
MISSION_CORE_fnc_recruitGarrisonRefillToggle = {
    params ["_state"];
    if !(alive player) exitWith {};
    if !(player getVariable ["MISSION_CAN_RECRUIT", false]) exitWith { hint "Too far from base."; };
    private _markerName = MISSION_CORE_RECRUIT_GARRISON_MARKER;
    if (_markerName == "") exitWith { hint "Select a marker first."; };
    _state = if (_state isEqualType true) then { _state } else { _state > 0 };
    private _ref = missionNamespace getVariable ["MISSION_CORE_GARRISON_REFILL", []];
    if (isNil "_ref") then { _ref = []; };
    _state = _state > 0;
    private _i = _ref find _markerName;
    private _on = _i >= 0;
    if (_state && { !_on }) then {
        _ref pushBack _markerName;
        systemChat format ["[GARRISON] Refill ON for %1 - killed units rebuild at 4x MP when the marker is clear", _markerName];
    };
    if (!_state && { _on }) then {
        _ref deleteAt _i;
        systemChat format ["[GARRISON] Refill OFF for %1", _markerName];
    };
    missionNamespace setVariable ["MISSION_CORE_GARRISON_REFILL", _ref];
    [player, _markerName, _state] remoteExec ["MISSION_CORE_fnc_garrisonRefillSet", 2];
    call MISSION_CORE_fnc_recruitMenuUpdateRefillCheck;
};

// Effective manpower cost of buying a tank for the given marker. Base cost is MISSION_CORE_RECRUIT_VEH_COSTS
// under "tank"; when the INSTANT TANK DELIVERY toggle is ON for that marker it is 2x (spawned immediately).
MISSION_CORE_fnc_recruitTankCost = {
    params ["_markerName"];
    private _base = MISSION_CORE_RECRUIT_VEH_COSTS getOrDefault ["tank", 4];
    private _pri = missionNamespace getVariable ["MISSION_CORE_PORT_PRIORITY", []];
    if (isNil "_pri") then { _pri = []; };
    if (_markerName != "" && { _markerName in _pri }) then {
        _base * 2
    } else {
        _base
    };
};

// Show the live BLUFOR armor-pool count on the menu note (how many tanks are available to
// recruit from). Tank / APC / SPG / MLRS recruits all draw on this pool.
MISSION_CORE_fnc_recruitMenuUpdateArmorPool = {
    private _disp = uiNamespace getVariable ["DYNOPS_RecruitMenu", objNull];
    if (isNull _disp) exitWith {};
    private _note = _disp displayCtrl 1655;
    if (isNull _note) exitWith {};
    private _pool = missionNamespace getVariable ["MISSION_CORE_ARMOR_POOL", 0];
    _note ctrlSetText format ["ARMOR POOL: %1 tank(s) available to recruit (tank 4 MP / instant 8, APC 3, SPG/MLRS, gun truck 2)", _pool];
};

// Populate the current garrison list for the selected marker from the snapshot.
MISSION_CORE_fnc_recruitMenuPopulateGarrisonList = {
    disableSerialization;
    private _disp = uiNamespace getVariable ["DYNOPS_RecruitMenu", objNull];
    if (isNull _disp) exitWith {};
    private _markerName = MISSION_CORE_RECRUIT_GARRISON_MARKER;
    private _list = _disp displayCtrl 1641;
    // Preserve the currently selected garrison item across this repopulate - the 5s live-refresh
    // loop calls this repeatedly, and a hard reset (selection + scroll to top) each tick made the
    // list appear to "deselect everything" while the user was working with it.
    private _selNet = "";
    private _selPrevIdx = lbCurSel _list;
    if (_selPrevIdx >= 0) then { _selNet = _list lbData _selPrevIdx; };
    lbClear _list;
    private _statusCtrl = _disp displayCtrl 1650;
    _statusCtrl ctrlSetText "";
    if (_markerName == "") exitWith {};
    private _snapshot = if (isNil "MISSION_CORE_GARRISON_SNAPSHOT") then { [] } else { MISSION_CORE_GARRISON_SNAPSHOT };
    private _entry = [];
    {
        if ((_x select 0) == _markerName) exitWith { _entry = _x; };
    } forEach _snapshot;
    if (count _entry == 0) exitWith { _statusCtrl ctrlSetText "No garrison data (pending)"; };
    _entry params ["_mName", "_men", "_grpN", "_vehN", "_grpEntries", "_vehEntries"];
    _statusCtrl ctrlSetText format ["%1 men | %2 groups | %3 vehicles", _men, _grpN, _vehN];
    {
        _x params ["_gNet", "_gLabel"];
        private _i = _list lbAdd format ["SQUAD: %1", _gLabel];
        _list lbSetData [_i, "G|" + _gNet];
    } forEach _grpEntries;
    {
        _x params ["_vNet", "_vLabel"];
        private _i = _list lbAdd format ["VEH: %1", _vLabel];
        _list lbSetData [_i, "V|" + _vNet];
    } forEach _vehEntries;
    if (count _grpEntries == 0 && count _vehEntries == 0) then {
        _list lbAdd "Empty - deploy a squad";
    };
    // Restore the previously selected row (lbSetCurSel auto-scrolls it into view), keeping the
    // user's selection + scroll position across the 5s refresh instead of snapping to the top.
    private _restoreIdx = -1;
    if (_selNet != "") then {
        for "_i" from 0 to (lbSize _list - 1) do {
            if (_list lbData _i == _selNet) exitWith { _restoreIdx = _i; };
        };
    };
    _list lbSetCurSel _restoreIdx;
};

// Remove the selected group or vehicle from the garrison list (remoteExec to server).
MISSION_CORE_fnc_recruitGarrisonRemove = {
    if !(alive player) exitWith {};
    private _disp = uiNamespace getVariable ["DYNOPS_RecruitMenu", objNull];
    if (isNull _disp) exitWith {};
    private _list = _disp displayCtrl 1641;
    private _idx = lbCurSel _list;
    if (_idx < 0) exitWith { hint "Select a garrison item to remove."; };
    private _data = _list lbData _idx;
    if (_data == "") exitWith {};
    private _prefix = _data select [0, 2];
    private _netId = _data select [2, count _data - 2];
    if (_prefix == "G|") then {
        [player, _netId] remoteExec ["MISSION_CORE_fnc_serverRemoveGroup", 2];
    } else {
        if (_prefix == "V|") then {
            [player, _netId] remoteExec ["MISSION_CORE_fnc_serverRemoveVehicle", 2];
        };
    };
    MISSION_CORE_RECRUIT_LAST_RESULT = "";
};

// -------------------------------------------------------------------
// TRANSPORT VEHICLE HELPER
// -------------------------------------------------------------------
// Distance threshold (meters) beyond which a transport is auto-spawned.
MISSION_CORE_RECRUIT_TRANSPORT_DIST = 800;

// Apply the player's saved assault waypoints to an attack group.
// PERMANENT RULE: the group must follow EXACTLY the waypoints the player drew - they are applied
// to a clean waypoint list (anything pre-existing on the group is cleared first, so prior/manager
// waypoints are never added on top). No CYCLE waypoint is ever applied: the path runs once in the
// order drawn and stops at the last waypoint (the assault reaches its target and the group holds).
MISSION_CORE_fnc_applyAssaultWaypoints = {
    params ["_grp", "_wps", "_targetPos"];
    [_grp] call MISSION_CORE_fnc_clearGroupWaypoints;
    // Waypoints in Arma are Arrays (not Objects), so isNull cannot be used on them. Track the
    // first waypoint with an empty-array sentinel instead (a real waypoint array is never empty).
    private _firstWp = [];
    {
        _x params ["_wpPos", "_wpType", "_wpRoe"];
        // Sanity: never apply a CYCLE to an assault group (the player's editor only allows
        // MOVE/SAD/UNLOAD/GUARD/HOLD, but guard against any stale CYCLE making it into the path).
        if (_wpType == "CYCLE") then { _wpType = "MOVE"; };
        private _wp = _grp addWaypoint [_wpPos, 10];
        _wp setWaypointType _wpType;
        _wp setWaypointCombatMode _wpRoe;
        _wp setWaypointSpeed "FULL";
        _wp setWaypointBehaviour "AWARE";
        if (count _firstWp == 0) then { _firstWp = _wp; };
    } forEach _wps;
    // If the player drew no waypoints, fall back to a single SAD at the target.
    if (count _wps == 0) then {
        _firstWp = _grp addWaypoint [_targetPos, 50];
        _firstWp setWaypointType "SAD";
        _firstWp setWaypointCombatMode "YELLOW";
        _firstWp setWaypointSpeed "FULL";
    };
    if (count _firstWp > 0) then { _grp setCurrentWaypoint _firstWp; };
};

// Spawn a transport that fits the squad and send them to the first waypoint.
// [_grp, _wps, _targetPos] call MISSION_CORE_fnc_recruitSpawnTransport;
// Returns true if transport was used, false if squad walks.
MISSION_CORE_fnc_recruitSpawnTransport = {
    params ["_grp", "_wps", "_targetPos"];

    // Determine drop-off point: first WP if any, otherwise target
    private _dropPos = _targetPos;
    if (count _wps > 0) then { _dropPos = (_wps select 0) select 0; };

    private _dist = player distance _dropPos;
    if (_dist < MISSION_CORE_RECRUIT_TRANSPORT_DIST) exitWith { false };

    // Pick vehicle by squad size
    private _unitCount = count units _grp;
    private _vehClass = if (_unitCount <= 4) then {
        "B_MRAP_01_F"
    } else {
        if (_unitCount <= 10) then { "B_T_Truck_01_covered_F" } else { "B_T_Truck_01_transport_F" };
    };

    // Spawn the vehicle in front of the player
    private _dir = getDir player;
    private _vPos = player getPos [8, _dir];
    _vPos = _vPos findEmptyPosition [0, 30, _vehClass];
    if (count _vPos == 0) then { _vPos = player getPos [15, _dir]; };

    private _veh = createVehicle [_vehClass, _vPos, [], 0, "NONE"];
    _veh setDir _dir;

    // No separate driver crew: the squad's own group drives the transport. One member takes the
    // driver seat, the rest fill the cargo seats. Because the squad group itself is driving, an
    // UNLOAD waypoint applied to that group reliably makes every member get out at the drop point.
    private _units = units _grp;
    if (count _units > 0) then { (_units select 0) moveInDriver _veh; };
    {
        if (vehicle _x == _x && { _x != driver _veh }) then {
            _x moveInAny _veh;
        };
    } forEach _units;
    // Safety: if the driver seat assignment did not take, force the first free unit to drive.
    if (isNull (driver _veh)) then {
        _units findIf { if (vehicle _x == _x) exitWith { _x moveInDriver _veh; true }; false };
    };

    // Count how many actually got into the vehicle
    private _cargoCount = { vehicle _x != _x } count units _grp;

    // If nobody got in (vehicle too small or pathing issue), give up and return false
    if (_cargoCount == 0 && _unitCount > 0) exitWith {
        deleteVehicle _veh;
        false
    };

    // Vehicle waypoints (on the SQUAD's own group): drive to area, then UNLOAD at drop point.
    // A waypoint Script is attached to the UNLOAD waypoint so that the dismount (and the handover
    // to the assault plan) runs exactly when the transport reaches the drop point.
    private _approachPos = _dropPos getPos [40 + random 20, random 360];
    _approachPos = _approachPos findEmptyPosition [0, 50];
    if (count _approachPos == 0) then { _approachPos = _dropPos getPos [30, 0]; };

    private _vw1 = _grp addWaypoint [_approachPos, 0];
    _vw1 setWaypointType "MOVE";
    _vw1 setWaypointSpeed "LIMITED";
    _vw1 setWaypointCombatMode "GREEN";
    _vw1 setWaypointBehaviour "CARELESS";

    private _vw2 = _grp addWaypoint [_dropPos, 10];
    _vw2 setWaypointType "UNLOAD";
    _vw2 setWaypointSpeed "LIMITED";
    _vw2 setWaypointCombatMode "GREEN";
    _vw2 setWaypointBehaviour "CARELESS";

    // Stash the assault plan on the group so transport_unload.sqf can hand it over on arrival.
    _grp setVariable ["MISSION_CORE_TRANSPORT_WPS", _wps, true];
    _grp setVariable ["MISSION_CORE_TRANSPORT_TARGET", _targetPos, true];

    // Run transport_unload.sqf the moment the group reaches the UNLOAD waypoint: it kicks every
    // member (including the driver) out, locks the transport, and applies the assault waypoints.
    _vw2 setWaypointScript "fnc\commander\transport_unload.sqf";

    _grp setCurrentWaypoint _vw1;

    hint format ["Transport spawned! %1 (%2 men) -> drop-off at %3m", _vehClass, _unitCount, round _dist];

    // Fallback safety net: independent of the waypoint script, once the vehicle reaches the drop
    // area make sure EVERY member (including the driver) has gotten out and that re-boarding is
    // locked. It deliberately does NOT touch the group's waypoints - the hand-drawn waypoints are
    // applied exactly once, and only by transport_unload.sqf when the UNLOAD waypoint fires.
    [_grp, _veh, _dropPos] spawn {
        params ["_grp", "_veh", "_dropPos"];
        private _timeout = time + 300;
        waitUntil {
            sleep 2;
            private _arrived = alive _veh && { _veh distance2D _dropPos < 70 };
            _arrived || { !alive _veh } || { { alive _x } count units _grp == 0 } || { time > _timeout }
        };
        if (!alive _veh || { { alive _x } count units _grp == 0 }) exitWith {};
        _veh lock false;
        // Stop the truck before forcing anyone out - this fallback can fire while the truck is still
        // rolling toward the drop area, and moveOut/getOut from a moving vehicle kills the ejected men.
        if (alive _veh) then {
            _veh setSpeedMode "LIMITED";
            private _drvStop = driver _veh;
            if (!isNull _drvStop) then { _drvStop doStop; };
            private _stopBy = time + 6;
            waitUntil { sleep 0.2; isNull _veh || { !(alive _veh) } || { speed _veh < 2 } || { time > _stopBy } };
        };
        private _drv = driver _veh;
        if (!isNull _drv && { vehicle _drv == _veh }) then {
            unassignVehicle _drv;
            [_drv] orderGetIn false;
            moveOut _drv;
        };
        {
            if (vehicle _x == _veh) then {
                unassignVehicle _x;
                [_x] orderGetIn false;
                _x action ["getOut", _veh];
            };
        } forEach units _grp;
        _veh lockCargo true;
    };

    true
};

// -------------------------------------------------------------------
// ATTACK TAB
// -------------------------------------------------------------------

// Open the map to click-select an enemy target marker.
MISSION_CORE_fnc_recruitAttackClickMap = {
    closeDialog 0;
    hint "Click on an enemy marker on the map to select it as the target.";
    openMap true;
    [
        "missionNamespace",
        "onMapSingleClick",
        {
    private _redLocs = MISSION_CORE_LOCATIONS select { (_x select 5) == EAST };
    _redLocs = [_redLocs, [], { player distance ((_x select 1) select 0) }, "ASCEND"] call BIS_fnc_sortBy;
            private _hit = objNull;
            {
                private _c = (_x select 1) select 0;
                private _sz = if (count (_x select 1) > 1) then { (_x select 1) select 1 } else { [200,200,0] };
                private _a = (_sz select 0) max 1;
                private _b = if (count _sz > 1) then { (_sz select 1) max 1 } else { _a };
                private _d = if (count _sz > 2) then { _sz select 2 } else { 0 };
                private _dx = (_pos select 0) - (_c select 0);
                private _dy = (_pos select 1) - (_c select 1);
                private _rx = _dx * cos _d - _dy * sin _d;
                private _ry = _dx * sin _d + _dy * cos _d;
                if ((_rx*_rx)/(_a*_a) + (_ry*_ry)/(_b*_b) <= 1) exitWith { _hit = _x; };
            } forEach _redLocs;

            if (!isNull _hit) then {
                MISSION_CORE_RECRUIT_ATTACK_TARGET = _hit select 0;
                MISSION_CORE_RECRUIT_ATTACK_TARGET_POS = (_hit select 1) select 0;
                hint format ["Target selected: %1", _hit select 0];
            } else {
                hint "No enemy marker at that position. Try again.";
            };
            onMapSingleClick "";
            openMap false;
            [] spawn { sleep 0.5; [] call MISSION_CORE_fnc_openRecruitment; };
        }
    ] call BIS_fnc_addMissionEventHandle;
};

// Deploy an attack squad with saved waypoints.
MISSION_CORE_fnc_recruitAttackDeploy = {
    if !(alive player) exitWith {};
    if !(player getVariable ["MISSION_CAN_RECRUIT", false]) exitWith { hint "Too far from base."; };
    disableSerialization;
    private _disp = uiNamespace getVariable "DYNOPS_RecruitMenu";

    // Get target
    private _targetName = MISSION_CORE_RECRUIT_ATTACK_TARGET;
    if (_targetName == "") then {
        // Try from list selection
        private _targetList = _disp displayCtrl 1632;
        private _tIdx = lbCurSel _targetList;
        if (_tIdx >= 0) then {
            _targetName = _targetList lbData _tIdx;
        };
    };
    if (_targetName == "") exitWith { hint "Select a target first."; };

    // Find target position
    private _locIdx = MISSION_CORE_LOCATIONS findIf { (_x select 0) == _targetName };
    if (_locIdx < 0) exitWith { hint "Target marker not found."; };
    private _targetPos = (MISSION_CORE_LOCATIONS select _locIdx select 1) select 0;

    // Get squad template
    private _squadList = _disp displayCtrl 1634;
    private _squadIdx = lbCurSel _squadList;
    if (_squadIdx < 0) exitWith { hint "Select a squad template."; };
    private _templates = uiNamespace getVariable ["MISSION_CORE_RECRUIT_ATTACK_GROUPS", []];
    if (_squadIdx >= count _templates) exitWith {};
    private _template = _templates select _squadIdx;
    _template params ["_grpName", "_grpUnits", "_unitCount", ["_subCat", ""], ["_catName", ""]];

    // Check manpower
    private _costPer = if (isNil "MISSION_CORE_MANPOWER_PER_UNIT") then { 10 } else { MISSION_CORE_MANPOWER_PER_UNIT };
    private _cost = _unitCount * _costPer;
    if (isNil "MISSION_CORE_BLUFOR_MANPOWER") then { MISSION_CORE_BLUFOR_MANPOWER = 0; };
    if (MISSION_CORE_BLUFOR_MANPOWER < _cost) exitWith { hint format ["Not enough manpower! Need %1 MP.", _cost]; };

    // Deduct manpower
    MISSION_CORE_BLUFOR_MANPOWER = MISSION_CORE_BLUFOR_MANPOWER - _cost;
    publicVariable "MISSION_CORE_BLUFOR_MANPOWER";

    // Spawn group via BIS_fnc_spawnGroup — follows CfgGroups config strictly
    // Spawn at the BLUFOR marker the player is in
    private _spawnPos = getPosATL player;
    private _myMarker = "";
    {
        if ((_x select 5) == WEST) then {
            private _mPos = ((_x select 1) select 0);
            private _mSize = ((_x select 1) select 1);
            private _a = if (count _mSize > 0) then { _mSize select 0 } else { 200 };
            private _b = if (count _mSize > 1) then { _mSize select 1 } else { 200 };
            private _d = player distance _mPos;
            if (_d < ((_a max _b) * 0.5 + 100)) exitWith { _myMarker = _x select 0; _spawnPos = _mPos; };
        };
    } forEach MISSION_CORE_LOCATIONS;
    private _faction = MISSION_CORE_BLUFOR_DATA select 3;
    private _cfgPath = configFile >> "CfgGroups" >> "West" >> _faction >> _catName >> _grpName;
    private _grp = [_spawnPos, side player, _cfgPath] call BIS_fnc_spawnGroup;
    if (isNull _grp) exitWith { hint "Failed to spawn group."; };

    // BIS_fnc_spawnGroup drops vehicles wherever the config formation lands - pull them back
    // onto a road column near the deploy point so recruited attack armor deploys on the road.
    [_grp, _spawnPos, [200, 200]] call MISSION_CORE_fnc_alignGroupVehiclesToRoad;

    // Auto-load dismounted infantry into transport for mech/motor groups
    private _isMotorized = _catName find "Motorized" > -1 || _subCat find "motor" > -1;
    private _isMechanized = _catName find "Mechanized" > -1 || _subCat find "mech" > -1;
    if (_isMotorized || _isMechanized) then {
        private _transports = [];
        { private _v = vehicle _x; if (_v != _x && {_v isKindOf "Car" || _v isKindOf "APC"} && {_transports findIf {_x == _v} < 0}) then { _transports pushBack _v; }; } forEach (units _grp);
        { if (vehicle _x == _x) then {
            private _cargoVeh = objNull;
            private _unit = _x;
            private _veh = objNull;
            for "_t" from 0 to (count _transports - 1) do {
                _veh = _transports select _t;
                if (_veh emptyPositions "cargo" > 0) exitWith { _cargoVeh = _veh; };
            };
            if (!isNull _cargoVeh) then { _unit moveInCargo _cargoVeh; };
        }; } forEach (units _grp);
    };

    // Set attack mode
    _grp setBehaviour "AWARE";
    _grp setCombatMode "YELLOW";
    _grp setSpeedMode "FULL";
    _grp setVariable ["MISSION_CORE_BLUFOR", true];
    _grp setVariable ["MISSION_CORE_ORDER", "attack"];

    // Apply the player's saved assault waypoints (clear first -> follow exactly, no added-on waypoints,
    // no CYCLE ever). Foot infantry still ride a transport if the drop-off is far away.
    private _wps = +MISSION_CORE_RECRUIT_SAVED_WAYPOINTS;
    if (!(vehicle (leader _grp) != leader _grp) && { count _wps > 0 }) then {
        // Foot infantry - hop on a transport if the first waypoint is a long way off.
        private _usedTransport = [_grp, _wps, _targetPos] call MISSION_CORE_fnc_recruitSpawnTransport;
        if (!_usedTransport) then {
            [_grp, _wps, _targetPos] call MISSION_CORE_fnc_applyAssaultWaypoints;
        };
    } else {
        [_grp, _wps, _targetPos] call MISSION_CORE_fnc_applyAssaultWaypoints;
    };

    // Register the attack group
    private _grpId = MISSION_CORE_RECRUIT_NEXT_GRP_ID;
    MISSION_CORE_RECRUIT_NEXT_GRP_ID = MISSION_CORE_RECRUIT_NEXT_GRP_ID + 1;
    MISSION_CORE_ATTACK_GROUPS set [_grpId, [_grp, _targetName, _wps, _template, WEST, "active", _targetPos]];
    MISSION_CORE_SPAWNED_GROUPS pushBack _grp;

    // Clear temp waypoints
    MISSION_CORE_RECRUIT_SAVED_WAYPOINTS = [];

    hint format ["Attack group #%1 deployed! %2 men -> %3 (%4 WPs) (-%5 MP)", _grpId, _unitCount, _targetName, count _wps, _cost];
    call MISSION_CORE_fnc_recruitMenuUpdateMP;
    call MISSION_CORE_fnc_recruitMenuPopulateAttack;
};

// Re-recruit a wiped attack group with the same template and waypoints.
MISSION_CORE_fnc_recruitAttackRERecruit = {
    if !(alive player) exitWith {};
    if !(player getVariable ["MISSION_CAN_RECRUIT", false]) exitWith { hint "Too far from base."; };
    disableSerialization;
    private _disp = uiNamespace getVariable "DYNOPS_RecruitMenu";
    private _reList = _disp displayCtrl 1638;
    private _idx = lbCurSel _reList;
    if (_idx < 0) exitWith { hint "Select a wiped group to re-recruit."; };
    private _rewiped = uiNamespace getVariable ["MISSION_CORE_RECRUIT_REWIPED", []];
    if (_idx >= count _rewiped) exitWith {};
    private _entry = _rewiped select _idx;
    private _grpId = _entry select 0;
    private _data = _entry select 1;
    _data params ["_oldGrp", "_target", "_wps", "_template", "_side", "_status", "_targetPos"];

    // Check if target is still enemy-held
    private _locIdx = MISSION_CORE_LOCATIONS findIf { (_x select 0) == _target };
    if (_locIdx < 0) exitWith { hint "Target no longer exists."; };
    private _owner = (MISSION_CORE_LOCATIONS select _locIdx) select 5;
    if (_owner == WEST) exitWith { hint format ["%1 is already under BLUFOR control!", _target]; };

    _template params ["_grpName", "_grpUnits", "_unitCount", ["_subCat", ""], ["_catName", ""]];

    // Check manpower
    private _costPer = if (isNil "MISSION_CORE_MANPOWER_PER_UNIT") then { 10 } else { MISSION_CORE_MANPOWER_PER_UNIT };
    private _cost = _unitCount * _costPer;
    if (isNil "MISSION_CORE_BLUFOR_MANPOWER") then { MISSION_CORE_BLUFOR_MANPOWER = 0; };
    if (MISSION_CORE_BLUFOR_MANPOWER < _cost) exitWith { hint format ["Not enough manpower! Need %1 MP.", _cost]; };

    // Deduct manpower
    MISSION_CORE_BLUFOR_MANPOWER = MISSION_CORE_BLUFOR_MANPOWER - _cost;
    publicVariable "MISSION_CORE_BLUFOR_MANPOWER";

    // Spawn group via BIS_fnc_spawnGroup — follows CfgGroups config strictly
    // Spawn at the BLUFOR marker the player is in
    private _spawnPos = getPosATL player;
    private _myMarker = "";
    {
        if ((_x select 5) == WEST) then {
            private _mPos = ((_x select 1) select 0);
            private _mSize = ((_x select 1) select 1);
            private _a = if (count _mSize > 0) then { _mSize select 0 } else { 200 };
            private _b = if (count _mSize > 1) then { _mSize select 1 } else { 200 };
            private _d = player distance _mPos;
            if (_d < ((_a max _b) * 0.5 + 100)) exitWith { _myMarker = _x select 0; _spawnPos = _mPos; };
        };
    } forEach MISSION_CORE_LOCATIONS;
    private _faction = MISSION_CORE_BLUFOR_DATA select 3;
    private _cfgPath = configFile >> "CfgGroups" >> "West" >> _faction >> _catName >> _grpName;
    private _grp = [_spawnPos, side player, _cfgPath] call BIS_fnc_spawnGroup;
    if (isNull _grp) exitWith { hint "Failed to spawn group."; };

    // BIS_fnc_spawnGroup drops vehicles wherever the config formation lands - pull them back
    // onto a road column near the deploy point so recruited attack armor deploys on the road.
    [_grp, _spawnPos, [200, 200]] call MISSION_CORE_fnc_alignGroupVehiclesToRoad;

    // Auto-load dismounted infantry into transport for mech/motor groups
    private _isMotorized = _catName find "Motorized" > -1 || _subCat find "motor" > -1;
    private _isMechanized = _catName find "Mechanized" > -1 || _subCat find "mech" > -1;
    if (_isMotorized || _isMechanized) then {
        private _transports = [];
        { private _v = vehicle _x; if (_v != _x && { (_v isKindOf "Car" || _v isKindOf "APC") && _transports findIf {_x == _v} < 0 }) then { _transports pushBack _v; }; } forEach (units _grp);
        { if (vehicle _x == _x) then {
            private _cargoVeh = objNull;
            private _unit = _x;
            private _veh = objNull;
            for "_t" from 0 to (count _transports - 1) do {
                _veh = _transports select _t;
                if (_veh emptyPositions "cargo" > 0) exitWith { _cargoVeh = _veh; };
            };
            if (!isNull _cargoVeh) then { _unit moveInCargo _cargoVeh; };
        }; } forEach (units _grp);
    };

    // Set attack mode
    _grp setBehaviour "AWARE";
    _grp setCombatMode "YELLOW";
    _grp setSpeedMode "FULL";
    _grp setVariable ["MISSION_CORE_BLUFOR", true];
    _grp setVariable ["MISSION_CORE_ORDER", "attack"];

    // Apply the player's saved assault waypoints (clear first -> follow exactly, no added-on waypoints,
    // no CYCLE ever). Foot infantry still ride a transport if the drop-off is far away.
    if (!(vehicle (leader _grp) != leader _grp) && { count _wps > 0 }) then {
        // Foot infantry - hop on a transport if the first waypoint is a long way off.
        private _usedTransport = [_grp, _wps, _targetPos] call MISSION_CORE_fnc_recruitSpawnTransport;
        if (!_usedTransport) then {
            [_grp, _wps, _targetPos] call MISSION_CORE_fnc_applyAssaultWaypoints;
        };
    } else {
        [_grp, _wps, _targetPos] call MISSION_CORE_fnc_applyAssaultWaypoints;
    };

    // Update the attack group entry
    MISSION_CORE_ATTACK_GROUPS set [_grpId, [_grp, _target, _wps, _template, WEST, "active", _targetPos]];
    MISSION_CORE_SPAWNED_GROUPS pushBack _grp;

    hint format ["Group #%1 re-recruited! %2 men -> %3 (-%4 MP)", _grpId, _unitCount, _target, _cost];
    call MISSION_CORE_fnc_recruitMenuUpdateMP;
    call MISSION_CORE_fnc_recruitMenuPopulateAttack;
};

// -------------------------------------------------------------------
// WAYPOINT EDITOR (openMap + titleText HUD)
// -------------------------------------------------------------------

MISSION_CORE_RECRUIT_WP_TYPE = "MOVE";
MISSION_CORE_RECRUIT_WP_ROE = "YELLOW";
MISSION_CORE_RECRUIT_WP_KEYHANDLER = -1;

// Update HUD via titleText — renders above the map layer.
MISSION_CORE_fnc_wpPanelUpdateCount = {
    private _typeNames = ["Move","SAD","TR UNLOAD","Guard","Hold"];
    private _typeIdx = ["MOVE","SAD","UNLOAD","GUARD","HOLD"] find MISSION_CORE_RECRUIT_WP_TYPE;
    private _typeName = if (_typeIdx >= 0) then { _typeNames select _typeIdx } else { MISSION_CORE_RECRUIT_WP_TYPE };

    private _roeNames = ["Hold Fire","Open Fire","Fire at Will"];
    private _roeIdx = ["GREEN","YELLOW","RED"] find MISSION_CORE_RECRUIT_WP_ROE;
    private _roeName = if (_roeIdx >= 0) then { _roeNames select _roeIdx } else { MISSION_CORE_RECRUIT_WP_ROE };

    private _wpCount = count MISSION_CORE_RECRUIT_SAVED_WAYPOINTS;

    titleText [
        format ["<t size='1.2' color='#99CCFF'>WAYPOINT EDITOR</t><br/><br/><t size='1.0' color='#FFFFFF'>Type: %1  ROE: %2</t><br/><t size='1.0' color='#80FF80'>Waypoints: %3</t><br/><br/><t size='0.8' color='#CCCCCC'>[ ] Cycle type | Q W Cycle ROE | Z Undo | X Clear | Esc Done</t>", _typeName, _roeName, _wpCount],
        "PLAIN", -1, true, true
    ];
};

// Clean up HUD.
MISSION_CORE_fnc_wpEditorDestroyHUD = {
    titleText ["", "plain", -1];
};

// Open the waypoint editor: map + HUD overlay.
MISSION_CORE_fnc_recruitAttackOpenWP = {
    disableSerialization;
    private _disp = uiNamespace getVariable ["DYNOPS_RecruitMenu", objNull];
    if (!isNull _disp) then {
        private _targetList = _disp displayCtrl 1632;
        private _tIdx = lbCurSel _targetList;
        if (_tIdx >= 0) then {
            MISSION_CORE_RECRUIT_ATTACK_TARGET = _targetList lbData _tIdx;
            private _locIdx = MISSION_CORE_LOCATIONS findIf { (_x select 0) == MISSION_CORE_RECRUIT_ATTACK_TARGET };
            if (_locIdx >= 0) then {
                MISSION_CORE_RECRUIT_ATTACK_TARGET_POS = (MISSION_CORE_LOCATIONS select _locIdx select 1) select 0;
            };
        };
    };
    closeDialog 0;

    // Reset defaults
    MISSION_CORE_RECRUIT_WP_TYPE = "MOVE";
    MISSION_CORE_RECRUIT_WP_ROE = "YELLOW";

    // Re-create markers for any existing waypoints
    { deleteMarkerLocal _x } forEach MISSION_CORE_RECRUIT_WAYPOINT_MARKERS;
    MISSION_CORE_RECRUIT_WAYPOINT_MARKERS = [];
    { [_x select 0, _x select 1, _forEachIndex] call MISSION_CORE_fnc_wpEditorCreateMarker; } forEach MISSION_CORE_RECRUIT_SAVED_WAYPOINTS;

    openMap true;
    waitUntil { sleep 0.1; visibleMap };

    // Build HUD
    call MISSION_CORE_fnc_wpPanelUpdateCount;

    // Map click handler
    onMapSingleClick {
        private _wpIdx = count MISSION_CORE_RECRUIT_SAVED_WAYPOINTS;
        MISSION_CORE_RECRUIT_SAVED_WAYPOINTS pushBack [_pos, MISSION_CORE_RECRUIT_WP_TYPE, MISSION_CORE_RECRUIT_WP_ROE];
        [_pos, MISSION_CORE_RECRUIT_WP_TYPE, _wpIdx] call MISSION_CORE_fnc_wpEditorCreateMarker;
        call MISSION_CORE_fnc_wpPanelUpdateCount;
        hint format ["WP %1 placed: %2", _wpIdx + 1, MISSION_CORE_RECRUIT_WP_TYPE];
    };

    // Key handler on the map display (display 12)
    private _keyId = findDisplay 12 displayAddEventHandler ["KeyDown", {
        params ["_disp", "_key"];
        private _typeCycle = ["MOVE","SAD","UNLOAD","GUARD","HOLD"];
        private _roeCycle = ["GREEN","YELLOW","RED"];
        private _handled = false;
        switch (_key) do {
            case 26: { // [ = previous type
                private _idx = _typeCycle find MISSION_CORE_RECRUIT_WP_TYPE;
                _idx = if (_idx <= 0) then { count _typeCycle - 1 } else { _idx - 1 };
                MISSION_CORE_RECRUIT_WP_TYPE = _typeCycle select _idx;
                _handled = true;
            };
            case 27: { // ] = next type
                private _idx = _typeCycle find MISSION_CORE_RECRUIT_WP_TYPE;
                _idx = if (_idx >= count _typeCycle - 1) then { 0 } else { _idx + 1 };
                MISSION_CORE_RECRUIT_WP_TYPE = _typeCycle select _idx;
                _handled = true;
            };
            case 16: { // Q = previous ROE
                private _idx = _roeCycle find MISSION_CORE_RECRUIT_WP_ROE;
                _idx = if (_idx <= 0) then { count _roeCycle - 1 } else { _idx - 1 };
                MISSION_CORE_RECRUIT_WP_ROE = _roeCycle select _idx;
                _handled = true;
            };
            case 17: { // W = next ROE
                private _idx = _roeCycle find MISSION_CORE_RECRUIT_WP_ROE;
                _idx = if (_idx >= count _roeCycle - 1) then { 0 } else { _idx + 1 };
                MISSION_CORE_RECRUIT_WP_ROE = _roeCycle select _idx;
                _handled = true;
            };
            case 21: { call MISSION_CORE_fnc_wpEditorRemoveLast; _handled = true; }; // Z
            case 45: { call MISSION_CORE_fnc_wpEditorClear; _handled = true; }; // X
        };
        if (_handled) then { call MISSION_CORE_fnc_wpPanelUpdateCount; };
        _handled
    }];
    missionNamespace setVariable ["MISSION_CORE_RECRUIT_WP_KEYHANDLER", _keyId];

    // Wait for map to close (Escape), then clean up and return to recruit menu
    [] spawn {
        waitUntil { sleep 0.5; !visibleMap };
        onMapSingleClick "";
        private _kid = missionNamespace getVariable ["MISSION_CORE_RECRUIT_WP_KEYHANDLER", -1];
        if (_kid >= 0) then { findDisplay 12 displayRemoveEventHandler ["KeyDown", _kid]; };
        call MISSION_CORE_fnc_wpEditorDestroyHUD;
        { deleteMarkerLocal _x } forEach MISSION_CORE_RECRUIT_WAYPOINT_MARKERS;
        MISSION_CORE_RECRUIT_WAYPOINT_MARKERS = [];
        sleep 0.3;
        [] call MISSION_CORE_fnc_openRecruitment;
    };
};

// Create a local marker for a waypoint.
MISSION_CORE_fnc_wpEditorCreateMarker = {
    params ["_pos", "_type", "_idx"];
    private _color = switch (_type) do {
        case "MOVE": { "ColorBlue" };
        case "SAD": { "ColorRed" };
        case "UNLOAD": { "ColorYellow" };
        case "GUARD": { "ColorGreen" };
        case "HOLD": { "ColorWhite" };
        default { "ColorBlue" };
    };
    private _icon = if (_type == "SAD") then { "mil_flag" } else { "mil_dot" };
    private _mkr = createMarkerLocal [format ["DynOps_WP_%1", _idx], _pos];
    _mkr setMarkerShapeLocal "ICON";
    _mkr setMarkerTypeLocal _icon;
    _mkr setMarkerColorLocal _color;
    _mkr setMarkerTextLocal format ["%1 %2", _idx + 1, _type];
    _mkr setMarkerSizeLocal [0.8, 0.8];
    MISSION_CORE_RECRUIT_WAYPOINT_MARKERS pushBack _mkr;
};

// Remove the last waypoint.
MISSION_CORE_fnc_wpEditorRemoveLast = {
    if (count MISSION_CORE_RECRUIT_SAVED_WAYPOINTS == 0) exitWith {};
    private _lastIdx = count MISSION_CORE_RECRUIT_SAVED_WAYPOINTS - 1;
    MISSION_CORE_RECRUIT_SAVED_WAYPOINTS deleteAt _lastIdx;
    if (_lastIdx < count MISSION_CORE_RECRUIT_WAYPOINT_MARKERS) then {
        deleteMarkerLocal (MISSION_CORE_RECRUIT_WAYPOINT_MARKERS select _lastIdx);
        MISSION_CORE_RECRUIT_WAYPOINT_MARKERS deleteAt _lastIdx;
    };
    call MISSION_CORE_fnc_wpPanelUpdateCount;
};

// Clear all waypoints.
MISSION_CORE_fnc_wpEditorClear = {
    { deleteMarkerLocal _x } forEach MISSION_CORE_RECRUIT_WAYPOINT_MARKERS;
    MISSION_CORE_RECRUIT_WAYPOINT_MARKERS = [];
    MISSION_CORE_RECRUIT_SAVED_WAYPOINTS = [];
    call MISSION_CORE_fnc_wpPanelUpdateCount;
};

// Done: close map + HUD, return to recruit menu.
MISSION_CORE_fnc_wpEditorDone = {
    openMap false;
};
