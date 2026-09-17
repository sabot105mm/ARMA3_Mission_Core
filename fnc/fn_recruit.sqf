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
MISSION_CORE_RECRUIT_WPS_PER_MARKER = createHashMap;
MISSION_CORE_RECRUIT_NEXT_GRP_ID = 0;
MISSION_CORE_RECRUIT_WP_SPEED = "FULL";
MISSION_CORE_RECRUIT_WP_BEHAVIOUR = "AWARE";

if (isNil "MISSION_CORE_ATTACK_GROUPS") then { MISSION_CORE_ATTACK_GROUPS = createHashMap; };

// MULTIPLAYER: publish this client's assault groups to the server so the server-side systems that
// must react to an assault (marker contest, commander detection, counter-attack, assault artillery)
// can see squads spawned on a client. Skipped on the machine acting as server - there the groups
// already live in the shared MISSION_CORE_ATTACK_GROUPS and would otherwise be double-counted.
// See fnc\commander\fn_assaultRelay.sqf for the receiving side.
MISSION_CORE_fnc_reportAssaultGroups = {
    if (isServer) exitWith {};
    private _entries = [];
    {
        private _d = _y;
        if ((count _d) < 7) then { continue; };
        // A wiped group must not keep its target contested - drop it from the snapshot.
        if ((_d select 5) == "wiped") then { continue; };
        private _g = _d select 0;
        if (isNull _g) then { continue; };
        private _ldr = leader _g;
        if (isNull _ldr || { !(alive _ldr) }) then { continue; };
        private _tmpl = _d select 3;
        private _subCat = if ((count _tmpl) > 3) then { _tmpl select 3 } else { "" };
        private _catName = if ((count _tmpl) > 4) then { _tmpl select 4 } else { "" };
        private _isMM = _g getVariable ["MISSION_CORE_MECH_MOTOR", false];
        _entries pushBack [netId _g, netId _ldr, _d select 1, _d select 5, _d select 6, _isMM, _subCat, _catName];
    } forEach MISSION_CORE_ATTACK_GROUPS;
    [player, _entries] remoteExec ["MISSION_CORE_fnc_assaultRelayReceive", 2, false];
};

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
// Flip behavior: when an attack group's target marker is captured (flips to BLUFOR), the surviving
// group does NOT march off to the next enemy marker. It moves to the far boundary of the captured
// marker on the side facing the next target and HOLDS there (status "hold"), so the player can
// redeploy it at full strength from the assault menu's IDLE list.
MISSION_CORE_fnc_monitorAttackGroups = {
    [] spawn {
        waitUntil { !isNil "MISSION_CORE_INITIALIZED" && { MISSION_CORE_INITIALIZED } };
        while { true } do {
            sleep 5;
            {
                private _data = _y;
                _data params ["_grp", "_target", "_wps", "_tmpl", "_side", "_status", ["_targetPos", [0, 0, 0]]];
                if (_status in ["active", "hold", "staging"] && {isNull _grp || {count units _grp == 0}}) then {
                    _data set [5, "wiped"];
                    MISSION_CORE_ATTACK_GROUPS set [_x, _data];
                    hint format ["Attack group #%1 wiped out!\nOpen recruit menu (X) to re-recruit.", _x];
                } else {
                    if (_status == "hold" && { !isNull _grp } && { count units _grp > 0 }) then {
                        // Hold groups auto-refill toward full strength when resources allow.
                        MISSION_CORE_ATTACK_GROUPS set [_x, [_grp, _target, _wps, _tmpl, _side, "hold", _targetPos] call MISSION_CORE_fnc_attackGroupTryRefill];
                    } else {
                        if (_status == "active" && { !isNull _grp } && { count units _grp > 0 } && { !isNil "MISSION_CORE_LOCATIONS" }) then {
                            private _tLocIdx = MISSION_CORE_LOCATIONS findIf { (_x select 0) == _target };
                            private _flipped = _tLocIdx >= 0 && { ((MISSION_CORE_LOCATIONS select _tLocIdx) select 5) == WEST };
                            if (_flipped) then {
                                private _ldr = leader _grp;
                                private _nextTarget = "";
                                private _nextPos = [0, 0, 0];
                                private _bestD = 1e10;
                                {
                                    private _l = _x;
                                    if ((_l select 5) == EAST) then {
                                        private _lp = ((_l select 1) select 0);
                                        private _d = if (isNull _ldr) then { 1e10 } else { _ldr distance _lp };
                                        if (_d < _bestD) then { _bestD = _d; _nextTarget = _l select 0; _nextPos = _lp; };
                                    };
                                } forEach MISSION_CORE_LOCATIONS;
                                if (_nextTarget != _target) then {
                                    // Edge of the captured marker facing the next target. If no enemy
                                    // marker remains at all, hold at a fixed offset instead so the
                                    // group is not stranded standing on the captured objective.
                                    private _tLoc = MISSION_CORE_LOCATIONS select _tLocIdx;
                                    private _tPos = (_tLoc select 1) select 0;
                                    private _tSize = if (count (_tLoc select 1) > 1) then { (_tLoc select 1) select 1 } else { [200, 200] };
                                    private _rad = if (count _tSize > 0) then { (_tSize select 0) max 1 } else { 200 };
                                    private _holdDir = if (_nextTarget == "") then { (getDir _tPos) - 90 } else { _tPos getDir _nextPos };
                                    private _holdPos = _tPos getPos [_rad, _holdDir];
                                    if (_holdPos isEqualTo _tPos) then { _holdPos = _tPos getPos [250, _holdDir]; };
                                    [_grp] call MISSION_CORE_fnc_clearGroupWaypoints;
                                    _grp setBehaviour "SAFE";
                                    _grp setCombatMode "YELLOW";
                                    _grp setSpeedMode "LIMITED";
                                    private _wp = _grp addWaypoint [_holdPos, 50];
                                    _wp setWaypointType "MOVE";
                                    _wp setWaypointBehaviour "SAFE";
                                    _wp setWaypointCombatMode "YELLOW";
                                    _wp setWaypointSpeed "LIMITED";
                                    private _hwp = _grp addWaypoint [_holdPos, 0];
                                    _hwp setWaypointType "HOLD";
                                    _hwp setWaypointBehaviour "SAFE";
                                    _hwp setWaypointCombatMode "YELLOW";
                                    _hwp setWaypointSpeed "LIMITED";
                                    _grp setCurrentWaypoint _wp;
                                    _grp setVariable ["MISSION_CORE_ORDER", "hold"];
                                    _grp setVariable ["MISSION_CORE_ATTACK_TARGET", _holdPos];
                                    _data set [1, _target];
                                    _data set [5, "hold"];
                                    _data set [6, _holdPos];
                                    MISSION_CORE_ATTACK_GROUPS set [_x, _data];
                                    hint format ["Attack group #%1 captured %2!\nHolding at the captured edge%3. Redeploy it (IDLE list) when back at full strength.", _x, _target, if (_nextTarget == "") then { "." } else { format [" facing %1.", _nextTarget] }];
                                };
                            };
                        };
                    };
                };
            } forEach MISSION_CORE_ATTACK_GROUPS;
            // MULTIPLAYER: push the (possibly changed) snapshot to the server every loop tick.
            call MISSION_CORE_fnc_reportAssaultGroups;
        };
    };
};

// How many men an attack group is short of its template's full strength (0 = full).
MISSION_CORE_fnc_attackGroupMissing = {
    params ["_grp", "_tmpl"];
    if (isNull _grp) exitWith { 0 };
    private _unitCount = if (count _tmpl > 2) then { _tmpl select 2 } else { 0 };
    private _alive = { alive _x } count units _grp;
    ((_unitCount - _alive) max 0) min _unitCount
};

// One refill attempt for a holding attack group (status must be "hold"). Missing infantry are
// spawned into the group at its position for manpower; missing armored vehicles (tank/APC template
// slots) each consume one armor-pool point pulled from the nearest depot/port that has one, exactly
// like instant tank delivery. Returns the (possibly updated) attack-group entry.
MISSION_CORE_fnc_attackGroupTryRefill = {
    params ["_grp", "_target", "_wps", "_tmpl", "_side", "_status", "_targetPos"];
    if (isNull _grp) exitWith { [_grp, _target, _wps, _tmpl, _side, _status, _targetPos] };
    _tmpl params ["_grpName", "_grpUnits", "_unitCount", ["_subCat", ""], ["_catName", ""]];
    private _alive = { alive _x } count units _grp;
    if (_alive >= _unitCount) exitWith { [_grp, _target, _wps, _tmpl, _side, _status, _targetPos] };

    private _costPer = if (isNil "MISSION_CORE_MANPOWER_PER_UNIT") then { 10 } else { MISSION_CORE_MANPOWER_PER_UNIT };
    private _missing = (_unitCount - _alive) max 0;

    // Template armored slots still missing from the group (a destroyed tank/APC counts).
    private _missingVeh = [];
    {
        private _cls = _x;
        private _isArmor = _cls isKindOf "Tank" || _cls isKindOf "Wheeled_APC" || _cls isKindOf "Tracked_APC";
        if (_isArmor) then {
            private _found = false;
            {
                private _v = vehicle _x;
                if (_v != _x && { alive _v } && { typeOf _v == _cls }) exitWith { _found = true; };
            } forEach units _grp;
            if (!_found) then { _missingVeh pushBack _cls; };
        };
    } forEach _grpUnits;

    private _spawnPos = getPosATL (leader _grp);
    if (count _spawnPos == 2) then { _spawnPos pushBack 0; };

    // Pre-check both resources BEFORE consuming anything so a short pool/manpower never strands a
    // consumed pool point. Both helpers live on the server (fn_tankDepot.sqf); in hosted SP the
    // player machine holds both roles, but guard so a remote-client-only context just waits.
    if (isNil "MISSION_CORE_fnc_poolTanksForSide" || { isNil "MISSION_CORE_fnc_consumePoolTankForSide" }) exitWith {
        [_grp, _target, _wps, _tmpl, _side, _status, _targetPos]
    };
    private _poolAvail = [WEST, _spawnPos] call MISSION_CORE_fnc_poolTanksForSide;
    if (count _missingVeh > _poolAvail) exitWith {
        [_grp, _target, _wps, _tmpl, _side, _status, _targetPos]
    };
    private _mpCost = ((_missing - count _missingVeh) max 0) * _costPer;
    if (_mpCost > 0 && { !([_mpCost] call MISSION_CORE_fnc_drawManpower) }) exitWith {
        [_grp, _target, _wps, _tmpl, _side, _status, _targetPos]
    };

    // Now consume the pool points for the missing armored slots.
    private _vehGot = [];
    {
        private _src = [WEST, _spawnPos] call MISSION_CORE_fnc_consumePoolTankForSide;
        if (_src != "") then { _vehGot pushBack _x; };
    } forEach _missingVeh;

    // Spawn the missing armored vehicles + crew into the group.
    {
        private _v = createVehicle [_x, [_spawnPos] call MISSION_CORE_fnc_liftSpawn, [], 15, "CAN_COLLIDE"];
        private _vGrp = createVehicleCrew _v;
        { if (!isNull _x) then { [_x] joinSilent _grp; }; } forEach units _vGrp;
        [_v] joinSilent _grp;
        if (!isNull _vGrp) then { deleteGroup _vGrp; };
        _v setVariable ["MISSION_CORE_BLUFOR", true];
    } forEach _vehGot;

    // Spawn missing infantry to bring the group back up to template strength.
    private _needMen = ((_unitCount - ({ alive _x } count units _grp)) max 0) min _unitCount;
    private _menClasses = _grpUnits select { _x isKindOf "Man" };
    if (count _menClasses == 0) then { _menClasses = ["B_Soldier_F"]; };
    for "_i" from 1 to _needMen do {
        private _cls = _menClasses select ((_i - 1) mod (count _menClasses));
        if (_cls isKindOf "Man") then {
            _grp createUnit [_cls, _spawnPos, [], 10, "FORM"];
        };
    };

    if (_mpCost > 0 || { count _vehGot > 0 }) then {
        hint format ["Attack group refilled to full strength (-%1 MP, %2 armor-pool point(s)).", _mpCost, count _vehGot];
    };
    [_grp, _target, _wps, _tmpl, _side, _status, _targetPos]
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
    [] spawn MISSION_CORE_fnc_recruitMenuRefresh;
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
    if (MISSION_CORE_RECRUIT_ACTIVE_TAB == 3) then {
        call MISSION_CORE_fnc_recruitMenuPopulateCommander;
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
    // Populate commander tab (COLONEL / LIEUTENANT / GENERAL only)
    private _isCmd = rank player in ["COLONEL", "GENERAL", "LIEUTENANT"];
    (_disp displayCtrl 1608) ctrlShow _isCmd;
    if (_isCmd) then { call MISSION_CORE_fnc_recruitMenuPopulateCommander; };
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

// One-shot refresh right after the menu opens or a tab is clicked: pull the authoritative server
// state (garrison snapshot for GARRISON, fresh locations/manpower everywhere) and repopulate the
// active tab's lists once the broadcast lands. Mirrors the Force Recon unlock menu refresh.
MISSION_CORE_fnc_recruitMenuRefresh = {
    sleep 1.0;
    if (isNull (uiNamespace getVariable ["DYNOPS_RecruitMenu", objNull])) exitWith {};
    if (MISSION_CORE_RECRUIT_ACTIVE_TAB == 1) then {
        [] remoteExecCall ["MISSION_CORE_fnc_garrisonRefresh", 2];
    };
    sleep 1.0;
    if (isNull (uiNamespace getVariable ["DYNOPS_RecruitMenu", objNull])) exitWith {};
    call MISSION_CORE_fnc_recruitMenuUpdateMP;
    call MISSION_CORE_fnc_recruitMenuUpdatePortBtn;
    call MISSION_CORE_fnc_recruitMenuUpdateArmorPool;
    call MISSION_CORE_fnc_recruitMenuPopulatePlayer;
    call MISSION_CORE_fnc_recruitMenuPopulateAttack;
    if (MISSION_CORE_RECRUIT_ACTIVE_TAB == 1) then {
        call MISSION_CORE_fnc_recruitMenuPopulateDefend;
    };
    if (MISSION_CORE_RECRUIT_ACTIVE_TAB == 3) then {
        call MISSION_CORE_fnc_recruitMenuPopulateCommander;
    };
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

    // All markers sorted closest to player first: enemy targets first, then friendly markers (so an
    // idle group can be redeployed to any marker - enemy = assault, BLUFOR = move+hold there).
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
        _targetList lbSetColor [lbSize _targetList - 1, [1,0.55,0.55,1]];
    } forEach _redLocs;
    private _blueLocs = MISSION_CORE_LOCATIONS select { (_x select 5) == WEST };
    _blueLocs = [_blueLocs, [], { player distance ((_x select 1) select 0) }, "ASCEND"] call BIS_fnc_sortBy;
    {
        private _name = _x select 0;
        private _label = if (count _x > 8 && {(_x select 8) != ""}) then { _x select 8 } else { _name };
        private _imp = _x select 7;
        private _dist = round (player distance ((_x select 1) select 0));
        _targetList lbAdd format ["%1 [Imp %2] %3m", _label, _imp, _dist];
        _targetList lbSetData [lbSize _targetList - 1, _name];
        _targetList lbSetColor [lbSize _targetList - 1, [0.6,0.85,1,1]];
    } forEach _blueLocs;
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

    // Idle list: attack groups holding at a captured marker (status "hold"). Shows alive vs
    // template strength; under-strength entries are greyed out and can't be deployed until they
    // refill. The refill auto-runs in the monitor, but the deploy handler re-checks strength.
    private _idleList = _disp displayCtrl 1643;
    lbClear _idleList;
    private _idle = [];
    {
        private _data = _y;
        _data params ["_grp", "_target", "_wps", "_tmpl"];
        if ((_data select 5) == "hold" && { !isNull _grp }) then {
            private _alive = { alive _x } count units _grp;
            private _full = if (count _tmpl > 2) then { _tmpl select 2 } else { 0 };
            _idle pushBack [_x, _data, _alive, _full];
        };
    } forEach MISSION_CORE_ATTACK_GROUPS;
    {
        private _id = _x select 0;
        private _alive = _x select 2;
        private _full = _x select 3;
        private _note = if (_alive >= _full) then { "READY" } else { format ["%1/%2 REFILLING", _alive, _full] };
        private _lbIdx = _idleList lbAdd format ["Group #%1 -> %2 (%3)", _id, (_x select 1) select 1, _note];
        if (_alive < _full) then {
            _idleList lbSetColor [_lbIdx, [0.45, 0.45, 0.45, 1]];
        } else {
            _idleList lbSetColor [_lbIdx, [0.6, 1, 0.7, 1]];
        };
        _idleList lbSetData [_lbIdx, str _id];
    } forEach _idle;
    _idleList lbSetCurSel -1;
    uiNamespace setVariable ["MISSION_CORE_RECRUIT_IDLE_GROUPS", _idle];
};

// Tab switching.
MISSION_CORE_fnc_recruitMenuTab = {
    params [["_tab", 0]];
    if (!(rank player in ["COLONEL", "GENERAL", "LIEUTENANT"]) && { _tab == 3 }) then { _tab = 0; };
    MISSION_CORE_RECRUIT_ACTIVE_TAB = _tab;
    disableSerialization;
    private _disp = uiNamespace getVariable "DYNOPS_RecruitMenu";
    if (isNull _disp) exitWith {};

    // Player tab: 1610-1614
    { (_disp displayCtrl _x) ctrlShow (_tab == 0) } forEach [1610, 1611, 1612, 1613, 1614];
    // Defend tab: 1620-1625, 1641-1659
    { (_disp displayCtrl _x) ctrlShow (_tab == 1) } forEach [1620, 1621, 1622, 1623, 1624, 1625, 1641, 1642, 1645, 1646, 1647, 1648, 1650, 1651, 1652, 1653, 1654, 1655, 1659, 1660, 1662];
    // Attack tab: 1630-1640, 1661-1663, 1643/1644/1649
    { (_disp displayCtrl _x) ctrlShow (_tab == 2) } forEach [1630, 1631, 1632, 1633, 1634, 1635, 1636, 1637, 1638, 1639, 1640, 1643, 1644, 1649, 1661, 1664, 1663, 1665, 1666];
    // Commander tab: 1615-1619
    { (_disp displayCtrl _x) ctrlShow (_tab == 3) } forEach [1615, 1616, 1617, 1618, 1619];

    // Tab button highlight
    private _tabColors = [
        [0.4,0.7,0.3,0.95],  // player active
        [0.3,0.5,0.2,0.95],  // player inactive
        [0.3,0.4,0.7,0.95],  // defend active
        [0.2,0.3,0.5,0.95],  // defend inactive
        [0.7,0.3,0.3,0.95],  // attack active
        [0.5,0.2,0.2,0.95],  // attack inactive
        [0.65,0.6,0.25,0.95],// commander active
        [0.45,0.4,0.15,0.95] // commander inactive
    ];
    (_disp displayCtrl 1601) ctrlSetBackgroundColor (_tabColors select (if (_tab == 0) then {0} else {1}));
    (_disp displayCtrl 1602) ctrlSetBackgroundColor (_tabColors select (if (_tab == 1) then {2} else {3}));
    (_disp displayCtrl 1603) ctrlSetBackgroundColor (_tabColors select (if (_tab == 2) then {4} else {5}));
    (_disp displayCtrl 1608) ctrlSetBackgroundColor (_tabColors select (if (_tab == 3) then {6} else {7}));

    // Refresh the newly shown tab's data - the GARRISON (1), ATTACK (2) and COMMANDER (3) tabs
    // repull the latest server state so the lists never show stale markers/garrisons when the
    // player switches to them.
    if (_tab == 1 || { _tab == 2 || { _tab == 3 } }) then {
        [] spawn MISSION_CORE_fnc_recruitMenuRefresh;
    };
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
    // Abort any pending commander-WP apply (map closed via menu close before editor exit flow).
    MISSION_CORE_WP_DONE_TARGET = "";
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
    private _firstSpeed = "FULL";
    private _firstBeh = "AWARE";
    private _firstRoe = "YELLOW";
    {
        _x params ["_wpPos", "_wpType", "_wpRoe", ["_wpSpeed", "FULL"], ["_wpBeh", "AWARE"]];
        // Sanity: never apply a CYCLE to an assault group (the player's editor only allows
        // MOVE/SAD/UNLOAD/GUARD/HOLD, but guard against any stale CYCLE making it into the path).
        if (_wpType == "CYCLE") then { _wpType = "MOVE"; };
        private _wp = _grp addWaypoint [_wpPos, 10];
        _wp setWaypointType _wpType;
        _wp setWaypointCombatMode _wpRoe;
        _wp setWaypointSpeed _wpSpeed;
        _wp setWaypointBehaviour _wpBeh;
        if (count _firstWp == 0) then {
            _firstWp = _wp;
            _firstSpeed = _wpSpeed;
            _firstBeh = _wpBeh;
            _firstRoe = _wpRoe;
        };
    } forEach _wps;
    // If the player drew no waypoints, fall back to a single SAD at the target.
    if (count _wps == 0) then {
        _firstWp = _grp addWaypoint [_targetPos, 50];
        _firstWp setWaypointType "SAD";
        _firstWp setWaypointCombatMode "YELLOW";
        _firstWp setWaypointSpeed "FULL";
        _firstWp setWaypointBehaviour "AWARE";
    };
    if (count _firstWp > 0) then { _grp setCurrentWaypoint _firstWp; };
    // Set GROUP-LEVEL state to match the first waypoint so the squad moves correctly between
    // waypoints and when released before the staging area.
    _grp setBehaviour _firstBeh;
    _grp setCombatMode _firstRoe;
    _grp setSpeedMode _firstSpeed;
};

// -------------------------------------------------------------------
// COMMANDER TAB (4th tab, rank COLONEL+ only) + reroute approval dialog
// -------------------------------------------------------------------

// NetId variant of applyAssaultWaypoints for remote groups (applies where the group is local).
MISSION_CORE_fnc_applyAssaultWaypointsNet = {
    params ["_netId", "_wps", "_targetPos"];
    private _grp = objectFromNetId _netId;
    if (isNull _grp) exitWith {};
    if !(local _grp) exitWith {};
    [_grp, _wps, _targetPos] call MISSION_CORE_fnc_applyAssaultWaypoints;
    _grp setVariable ["MISSION_CORE_ORDER", "attack"];
    _grp setVariable ["MISSION_CORE_ATTACK_TARGET", _targetPos];
};

// Multi-select group list: click marks [X] (single), shift-click toggles extra groups on/off.
// Listboxes are single-select by design, so selection is tracked here as a persistent membership
// set of group objects. netIds are read back via groupFromNetId (objectFromNetId is objects only).
MISSION_CORE_fnc_recruitCommanderSelect = {
    params ["_ctrl", "_idx"];
    if (_idx < 0) exitWith {};
    private _netId = _ctrl lbData _idx;
    if (_netId == "") exitWith { _ctrl lbSetCurSel -1; };
    private _grp = groupFromNetId _netId;
    if (isNull _grp) then {
        private _obj = objectFromNetId _netId;
        if (!isNull _obj) then { _grp = group _obj; };
    };
    if (isNull _grp) exitWith { _ctrl lbSetCurSel -1; };
    private _sel = missionNamespace getVariable ["MISSION_CORE_COMMAND_SELECTED", []];
    private _shift = (keysDown find 42 != -1) || { (keysDown find 54 != -1) }; // L/R shift
    if (_shift) then {
        if (_grp in _sel) then { _sel = _sel - [_grp]; } else { _sel = _sel + [_grp]; };
    } else {
        _sel = if (_grp in _sel && { count _sel == 1 }) then { [] } else { [_grp] };
    };
    missionNamespace setVariable ["MISSION_CORE_COMMAND_SELECTED", _sel];
    _ctrl lbSetCurSel -1;
    call MISSION_CORE_fnc_recruitMenuPopulateCommander;
};

// Commander list contents: every tracked assault group (MISSION_CORE_ATTACK_GROUPS) plus the group
// of every alive WEST player (platoon/squad leaders). Deduplicated by group object.
MISSION_CORE_fnc_recruitMenuPopulateCommander = {
    disableSerialization;
    private _disp = uiNamespace getVariable "DYNOPS_RecruitMenu";
    if (isNull _disp) exitWith {};
    private _list = _disp displayCtrl 1616;
    lbClear _list;
    private _sel = missionNamespace getVariable ["MISSION_CORE_COMMAND_SELECTED", []];
    private _rows = [];
    if (!isNil "MISSION_CORE_ATTACK_GROUPS" && { count MISSION_CORE_ATTACK_GROUPS > 0 }) then {
        {
            private _data = _y;
            if (count _data < 7) then { continue; };
            private _ag = _data select 0;
            if (isNull _ag) then { continue; };
            private _mark = if (_ag in _sel) then { "[X] " } else { "[ ] " };
            private _label = format ["%1#%2 ASLT -> %3 (%4)", _mark, _x, _data select 1, _data select 5];
            _rows pushBack [_ag, _label];
        } forEach MISSION_CORE_ATTACK_GROUPS;
    };
    {
        if (alive _x && { side _x == WEST }) then {
            private _g = group _x;
            if (isNull _g) then { continue; };
            if (_rows findIf { (_x select 0) == _g } == -1) then {
                private _mark = if (_g in _sel) then { "[X] " } else { "[ ] " };
                private _label = format ["%1LEADER %2 (%3 men)", _mark, name _x, count units _g];
                _rows pushBack [_g, _label];
            };
        };
    } forEach allPlayers;
    {
        private _row = _x;
        private _lb = _list lbAdd (_row select 1);
        _list lbSetData [_lb, netId (_row select 0)];
    } forEach _rows;
    _list lbSetCurSel -1;
    uiNamespace setVariable ["MISSION_CORE_COMMAND_ROWS", _rows];
};

// Open the WP editor in COMMANDER mode: drawn waypoints are later applied to every selected group.
MISSION_CORE_fnc_recruitCommanderOpenWP = {
    if (count (missionNamespace getVariable ["MISSION_CORE_COMMAND_SELECTED", []]) == 0) exitWith { hint "Select at least one group first."; };
    MISSION_CORE_WP_DONE_TARGET = "COMMANDER";
    [] spawn MISSION_CORE_fnc_recruitAttackOpenWP;
};

// Called when the WP editor closes in commander mode: apply the drawn route to every selected group.
MISSION_CORE_fnc_commanderApplyWaypoints = {
    private _wps = +MISSION_CORE_RECRUIT_SAVED_WAYPOINTS;
    if (count _wps == 0) exitWith { hint "No waypoints drawn - groups keep their current path."; };
    private _sel = missionNamespace getVariable ["MISSION_CORE_COMMAND_SELECTED", []];
    if (count _sel == 0) exitWith { MISSION_CORE_RECRUIT_SAVED_WAYPOINTS = []; hint "No groups selected - nothing applied."; };
    private _targetPos = (_wps select (count _wps - 1)) select 0;
    private _applied = 0;
    {
        private _grp = _x;
        if (isNull _grp || { count units _grp == 0 }) then { continue; };
        if (local _grp) then {
            [_grp, _wps, _targetPos] call MISSION_CORE_fnc_applyAssaultWaypoints;
            _grp setVariable ["MISSION_CORE_ORDER", "attack"];
            _grp setVariable ["MISSION_CORE_ATTACK_TARGET", _targetPos];
        } else {
            [netId _grp, _wps, _targetPos] remoteExecCall ["MISSION_CORE_fnc_applyAssaultWaypointsNet", owner (leader _grp), false];
        };
        _applied = _applied + 1;
    } forEach _sel;
    MISSION_CORE_RECRUIT_SAVED_WAYPOINTS = [];
    hint format ["%1 group(s) routed to %2 waypoints.", _applied, count _wps];
};

// RemoteExec target on the commander client: pops up the approval dialog when the AI commander
// wants to reroute a player-side assault squad to a defend marker.
MISSION_CORE_fnc_showCommanderReroutePrompt = {
    params ["_key", "_grpId", "_markerName"];
    if !(hasInterface) exitWith {};
    if !(rank player in ["COLONEL", "GENERAL", "LIEUTENANT"]) exitWith {};
    uiNamespace setVariable ["DYNOPS_COMMANDER_REROUTE_KEY", _key];
    uiNamespace setVariable ["DYNOPS_COMMANDER_REROUTE_GRP", _grpId];
    uiNamespace setVariable ["DYNOPS_COMMANDER_REROUTE_MARKER", _markerName];
    if (!isNull (findDisplay 1610)) exitWith {};
    createDialog "DYNOPS_CommanderPrompt";
    private _disp = findDisplay 1610;
    if (!isNull _disp) then {
        (_disp displayCtrl 1672) ctrlSetText format ["Reroute squad %1 to defend %2?", _grpId, _markerName];
    };
};

MISSION_CORE_fnc_commanderRerouteYes = {
    private _key = uiNamespace getVariable ["DYNOPS_COMMANDER_REROUTE_KEY", ""];
    if (_key != "") then { [_key, true] remoteExecCall ["MISSION_CORE_fnc_commanderRerouteAnswer", 2]; };
    closeDialog 0;
};

MISSION_CORE_fnc_commanderRerouteNo = {
    private _key = uiNamespace getVariable ["DYNOPS_COMMANDER_REROUTE_KEY", ""];
    if (_key != "") then { [_key, false] remoteExecCall ["MISSION_CORE_fnc_commanderRerouteAnswer", 2]; };
    closeDialog 0;
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
        // Shared stop routine (see fn_stopForDismount.sqf).
        [_veh] call MISSION_CORE_fnc_stopForDismount;
        private _drv = driver _veh;
        // leaveVehicle (group + unit) kills the re-boarding loop; orderGetIn false alone leaves
        // the AI spamming "get back in" while lockCargo refuses them.
        _grp leaveVehicle _veh;
        if (!isNull _drv && { vehicle _drv == _veh }) then {
            unassignVehicle _drv;
            _drv leaveVehicle _veh;
            [_drv] orderGetIn false;
            moveOut _drv;
        };
        {
            if (vehicle _x == _veh) then {
                unassignVehicle _x;
                _x leaveVehicle _veh;
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

// Open the map to click-select a target marker (any marker; idle redeploys can hold at friendly).
MISSION_CORE_fnc_recruitAttackClickMap = {
    closeDialog 0;
    hint "Click on a marker on the map to select it as the target.";
    openMap true;
    [
        "missionNamespace",
        "onMapSingleClick",
        {
    private _allLocs = +MISSION_CORE_LOCATIONS;
    _allLocs = [_allLocs, [], { player distance ((_x select 1) select 0) }, "ASCEND"] call BIS_fnc_sortBy;
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
            } forEach _allLocs;

            if (!isNull _hit) then {
                MISSION_CORE_RECRUIT_ATTACK_TARGET = _hit select 0;
                MISSION_CORE_RECRUIT_ATTACK_TARGET_POS = (_hit select 1) select 0;
                hint format ["Target selected: %1", _hit select 0];
            } else {
                hint "No marker at that position. Try again.";
            };
            onMapSingleClick "";
            openMap false;
            [] spawn { sleep 0.5; [] call MISSION_CORE_fnc_openRecruitment; };
        }
    ] call BIS_fnc_addMissionEventHandle;
};

// RELEASE STAGED ASSAULT (recruit menu): orders every currently staged BLUFOR squad in.
// This applies to the PLAYER's own staged squads ONLY (bought against an enemy marker that was
// not yet contested). The AI commander's REDFOR staging is tank-wait only - this button never
// touches it and there is no manual release for enemy forces.
MISSION_CORE_fnc_recruitAssaultRelease = {
    if (isNil "MISSION_CORE_BLUFOR_STAGED") then { MISSION_CORE_BLUFOR_STAGED = []; };
    if (count MISSION_CORE_BLUFOR_STAGED == 0) exitWith { hint "No BLUFOR squads are staged."; };
    [] call MISSION_CORE_fnc_releaseBluforStaged;
};

// Staged-squad leader Killed EH: when the leader dies the staging torch passes to the next
// alive unit so the team keeps functioning (and the release logic continues) under the new leader.
MISSION_CORE_fnc_stagedLeaderTorch = {
    params ["_dead", "_killer"];
    private _g = group _dead;
    if (isNull _g) exitWith {};
    if (_g getVariable ["MISSION_CORE_ORDER", ""] != "staging") exitWith {};
    private _alive = units _g select { alive _x };
    if (count _alive == 0) exitWith {};
    private _member = _alive select 0;
    _member addEventHandler ["Killed", { _this call MISSION_CORE_fnc_stagedLeaderTorch; }];
    diag_log format ["BLUFOR STAGED: %1 leader down - %2 takes over", groupId _g, name _member];
};

// Stage a recruited BLUFOR squad at its source edge on the bearing to an enemy target. The squad
// holds until the player engages (contests) the target or presses RELEASE STAGED ASSAULT. Only the
// waypoint/order/EH setup happens here - ATTACK_GROUPS + the staged register are handled by the caller.
// [_grp, _srcPos, _srcSize, _tgtPos, _tgtName] call MISSION_CORE_fnc_stageBluforGroup;
MISSION_CORE_fnc_stageBluforGroup = {
    params ["_grp", "_srcPos", "_srcSize", "_tgtPos", ["_tgtName", ""]];
    if (count _srcSize == 0) then { _srcSize = [200, 200]; };
    private _rad = (_srcSize select 0) max 1;
    private _dir = _srcPos getDir _tgtPos;
    private _stagePos = _srcPos getPos [_rad, _dir];
    if (_stagePos isEqualTo _srcPos) then { _stagePos = _srcPos getPos [250, _dir]; };
    [_grp] call MISSION_CORE_fnc_clearGroupWaypoints;
    _grp setBehaviour "SAFE";
    _grp setCombatMode "YELLOW";
    _grp setSpeedMode "LIMITED";
    private _wp = _grp addWaypoint [_stagePos, 30];
    _wp setWaypointType "MOVE";
    _wp setWaypointBehaviour "SAFE";
    _wp setWaypointCombatMode "YELLOW";
    _wp setWaypointSpeed "LIMITED";
    private _hwp = _grp addWaypoint [_stagePos, 0];
    _hwp setWaypointType "HOLD";
    _hwp setWaypointBehaviour "SAFE";
    _hwp setWaypointCombatMode "YELLOW";
    _hwp setWaypointSpeed "LIMITED";
    _grp setCurrentWaypoint _wp;
    _grp setVariable ["MISSION_CORE_ORDER", "staging"];
    _grp setVariable ["MISSION_CORE_ATTACK_TARGET", _tgtPos];
    _grp setVariable ["MISSION_CORE_STAGE_POS", _stagePos];
    (leader _grp) addEventHandler ["Killed", { _this call MISSION_CORE_fnc_stagedLeaderTorch; }];
    diag_log format ["BLUFOR STAGED: %1 staged at %2 on bearing %3 toward %4", groupId _grp, _stagePos, round _dir, _tgtName];
};

// Order every staged BLUFOR squad toward its target with its saved (or default) waypoints.
// Optional _onlyTargets = array of marker names: only squads staged against those release, the
// rest stay staged. Client-side: the squads were spawned by this client's recruit flow.
// [_onlyTargets] call MISSION_CORE_fnc_releaseBluforStaged;
MISSION_CORE_fnc_releaseBluforStaged = {
    params [["_onlyTargets", []]];
    if (isNil "MISSION_CORE_BLUFOR_STAGED") exitWith { false };
    if (count MISSION_CORE_BLUFOR_STAGED == 0) exitWith { false };
    private _released = 0;
    private _keep = [];
    {
        _x params ["_grp", "_grpId", "_template", "_tgtName", "_tgtPos", "_wps"];
        if (isNull _grp || { count units _grp == 0 }) then { continue; };
        if (count _onlyTargets > 0 && { !(_tgtName in _onlyTargets) }) then { _keep pushBack _x; continue; };
        _grp setVariable ["MISSION_CORE_ORDER", "attack"];
        [_grp, _wps, _tgtPos] call MISSION_CORE_fnc_applyAssaultWaypoints;
        if (_grpId >= 0 && { !isNil "MISSION_CORE_ATTACK_GROUPS" }) then {
            private _data = MISSION_CORE_ATTACK_GROUPS getOrDefault [_grpId, []];
            if (count _data > 0) then {
                _data set [5, "active"];
                _data set [6, _tgtPos];
                MISSION_CORE_ATTACK_GROUPS set [_grpId, _data];
            };
        };
        _released = _released + 1;
        diag_log format ["BLUFOR STAGED: %1 released toward %2", groupId _grp, _tgtName];
    } forEach MISSION_CORE_BLUFOR_STAGED;
    MISSION_CORE_BLUFOR_STAGED = _keep;
    if (_released > 0) then {
        hint format ["Released %1 staged squad%2 - they are advancing.", _released, if (_released == 1) then { "" } else { "s" }];
        ["Staged squads released! They are advancing."] remoteExec ["systemChat", 0];
    };
    true
};

// Auto-advance: a staged BLUFOR squad pushes in the moment its target becomes contested (a player
// engages it) - staging is only for the "nobody is there yet" case. Manual release (button) is
// the override that orders everything in at once.
MISSION_CORE_fnc_monitorBluforStaging = {
    [] spawn {
        waitUntil { !isNil "MISSION_CORE_INITIALIZED" && { MISSION_CORE_INITIALIZED } };
        while { true } do {
            sleep 5;
            if (isNil "MISSION_CORE_BLUFOR_STAGED") then { continue; };
            if (count MISSION_CORE_BLUFOR_STAGED == 0) then { continue; };
            private _contested = if (!isNil "MISSION_CORE_CONTESTED_MARKERS") then { +MISSION_CORE_CONTESTED_MARKERS } else { [] };
            if (count _contested > 0) then {
                [_contested] call MISSION_CORE_fnc_releaseBluforStaged;
            };
        };
    };
};

// True when an attack-tab template is a self-propelled gun / MLRS / mortar battery. Identified by
// the role detector's "artillery" sub-category, or by a class-name/staticmethod fallback for
// addon groups the detector may not have re-categorised yet.
MISSION_CORE_fnc_isArtyTemplate = {
    params ["_tmpl"];
    _tmpl params ["", "_grpUnits", "", ["_subCat", ""], ""];
    if (_subCat == "artillery") exitWith { true };
    private _isArty = false;
    {
        private _cls = _x;
        if (isNil "_cls" || { _cls == "" }) then { continue; };
        private _ln = toLower _cls;
        if (_ln find "artillery" > -1 || { _ln find "arty" > -1 } || { _ln find "mlrs" > -1 } || { _ln find "scorcher" > -1 } || { _ln find "m270" > -1 } || { _ln find "grad" > -1 } || { _ln find "dana" > -1 } || { _cls isKindOf "StaticMortar" }) exitWith { _isArty = true; };
    } forEach (_grpUnits);
    _isArty
};

// Best standoff firing position for an assault-arty piece: the center of the nearest BLUFOR-held
// marker to the target. The piece parks there and shells - it never advances toward the objective.
// Optional _minDist is the weapon's minimum ballistic range: a marker closer than that to the target
// cannot lay the gun ("invalid coords / cease fire"), so when the nearest marker sits inside the
// minimum range the search returns the nearest marker that IS at least _minDist out. If no BLUFOR
// marker reaches the minimum range it returns [0,0,0] - the caller keeps the piece where it is.
// NAMED _bluforStandoff on purpose: fn_recruitServer.sqf also defines MISSION_CORE_fnc_assaultArtyStandoff
// (with a min-distance variant for run-away relocation); in a hosted game both files compile into the
// same namespace and the later one would overwrite the earlier - so the two sides never share a name.
MISSION_CORE_fnc_bluforStandoff = {
    params ["_targetPos", ["_minDist", 0]];
    private _best = [0, 0, 0];
    private _bestD = 1e10;
    private _ok = [0, 0, 0];
    private _okD = 1e10;
    {
        if ((_x select 5) == WEST) then {
            private _c = (_x select 1) select 0;
            private _d = _c distance2D _targetPos;
            if (_d < _bestD) then { _bestD = _d; _best = _c; };
            if (_d >= _minDist) then { if (_d < _okD) then { _okD = _d; _ok = _c; }; };
        };
    } forEach MISSION_CORE_LOCATIONS;
    if (_minDist <= 0) exitWith { _best };
    if (_okD < 1e10) then { _ok } else { [0, 0, 0] }
};

// Minimum ballistic range (m) an assault-arty platoon can lay its rounds at - the standoff must sit
// at least this far from the target or the gun barks "Invalid coordinates. Cease fire." MLRS rockets
// need 1000m; SPG howitzers 825m. Returns the strictest piece in the platoon so a mixed group is
// served. Heuristic mirrors fn_isArtyTemplate's class-name detection (mlrs / m270 / grad = rockets).
MISSION_CORE_fnc_assaultArtyMinRange = {
    params ["_grp"];
    private _minR = 825;
    {
        private _v = vehicle _x;
        if (_v isKindOf "LandVehicle") then {
            private _ln = toLower (typeOf _v);
            if (_ln find "mlrs" > -1 || { _ln find "m270" > -1 } || { _ln find "grad" > -1 }) then { _minR = _minR max 1000; };
        };
    } forEach units _grp;
    _minR
};

// Point an assault-arty group at a target: park it at the best standoff (nearest friendly marker to
// the objective) on a move+hold, tag it so no other AI system steals/moves it, and register it into
// the server player-arty fire loop so it shells the target and relocates after each barrage.
MISSION_CORE_fnc_assaultArtyDeploy = {
    params ["_grp", "_targetPos", "_spawnFallback"];
    // MLRS rounds need >= 1000m, SPG >= 825m between gun and target; never park a piece close
    // enough that its own minimum range prevents firing. The standoff picker enforces it per
    // platoon min range and falls back to the spawn position when every friendly marker is too
    // close to the target.
    private _minR = [_grp] call MISSION_CORE_fnc_assaultArtyMinRange;
    private _standoff = [_targetPos, _minR] call MISSION_CORE_fnc_bluforStandoff;
    if (_standoff distance [0, 0, 0] < 1) then { _standoff = _spawnFallback; };
    diag_log format ["PLAYER ARTY: group %1 standoff %2 for target %3 (min range %4)", _grp, _standoff, _targetPos, _minR];
    [_grp] call MISSION_CORE_fnc_clearGroupWaypoints;
    _grp setBehaviour "SAFE";
    _grp setCombatMode "YELLOW";
    _grp setSpeedMode "LIMITED";
    _grp setVariable ["MISSION_CORE_ORDER", "artillery"];
    _grp setVariable ["MISSION_CORE_ARMOR_SLOT", "arty"];
    _grp setVariable ["MISSION_CORE_ARTILLERY", true];
    _grp setVariable ["MISSION_CORE_ATTACK_TARGET", _targetPos];
    private _wp = _grp addWaypoint [_standoff, 50];
    _wp setWaypointType "MOVE";
    _wp setWaypointBehaviour "SAFE";
    _wp setWaypointCombatMode "YELLOW";
    _wp setWaypointSpeed "LIMITED";
    private _hwp = _grp addWaypoint [_standoff, 0];
    _hwp setWaypointType "HOLD";
    _hwp setWaypointBehaviour "SAFE";
    _hwp setWaypointCombatMode "YELLOW";
    _hwp setWaypointSpeed "LIMITED";
    _grp setCurrentWaypoint _wp;
    // Register EVERY gun vehicle in the group into the player-arty fire loop so it keeps shelling
    // its target while it sits at the standoff. SPG/MLRS recruit templates spawn as a GROUP of
    // several vehicles (a platoon), so this must iterate the group's vehicles - not just the first
    // land vehicle - or only one piece ever fires. Same netId keying server-side means each vehicle
    // becomes its own fire-loop entry.
    private _artys = [];
    {
        private _v = vehicle _x;
        if (_v isKindOf "LandVehicle" && { _artys findIf { _x == _v } == -1 }) then { _artys pushBack _v; };
    } forEach units _grp;
    if (count _artys > 0) then {
        {
            [netId _x, _targetPos] remoteExecCall ["MISSION_CORE_fnc_serverRegisterAssaultArty", 2];
        } forEach _artys;
    };
};

MISSION_CORE_fnc_recruitAttackDeploy = {
    if !(alive player) exitWith {};
    if !(player getVariable ["MISSION_CAN_RECRUIT", false]) exitWith { hint "Too far from base."; };
    disableSerialization;
    private _disp = uiNamespace getVariable "DYNOPS_RecruitMenu";

    // Get target (a fresh list selection wins; the click-map/WP-editor stored target is the fallback)
    private _targetList = _disp displayCtrl 1632;
    private _tIdx = lbCurSel _targetList;
    private _targetName = if (_tIdx >= 0) then { _targetList lbData _tIdx } else { MISSION_CORE_RECRUIT_ATTACK_TARGET };
    if (_targetName == "") exitWith { hint "Select a target first."; };

    // Find target position
    private _locIdx = MISSION_CORE_LOCATIONS findIf { (_x select 0) == _targetName };
    if (_locIdx < 0) exitWith { hint "Target marker not found."; };
    private _targetPos = (MISSION_CORE_LOCATIONS select _locIdx select 1) select 0;

    // IDLE REDEPLOY path: an idle (holding) group selected in 1643 overrides squad-template
    // selection. Free - the units already exist - but the group must be back at full strength;
    // the refill attempt below tops it up with MP + armor-pool points, or blocks with a note.
    private _idleList = _disp displayCtrl 1643;
    private _idleIdx = lbCurSel _idleList;
    private _idleHandled = false;
    if (_idleIdx >= 0) then {
        private _idleArr = uiNamespace getVariable ["MISSION_CORE_RECRUIT_IDLE_GROUPS", []];
        if (_idleIdx < count _idleArr) then {
            private _ie = _idleArr select _idleIdx;
            private _grpId = _ie select 0;
            private _data = _ie select 1;
            _data params ["_grp", "_oldTarget", "_oldWps", "_template", "_side", "_status", "_tpos"];
            _template params ["_grpName", "_grpUnits", "_unitCount", ["_subCat", ""], ["_catName", ""]];
            if (!isNull _grp) then {
                _idleHandled = true;

                // Refill first (MP + armor pool at the captured marker), then check battle readiness.
                _data = [_grp, _oldTarget, _oldWps, _template, WEST, "hold", _tpos] call MISSION_CORE_fnc_attackGroupTryRefill;
                private _alive = { alive _x } count units _grp;
                if (_alive < _unitCount) then {
                    hint format ["Group #%1 is not at full strength yet (%2/%3) - it must refill before the next assault. Waiting for manpower/tank pool.", _grpId, _alive, _unitCount];
                } else {
                    // Target owner decides the order: enemy = assault (back to "active"), friendly = held at that marker.
                    private _owner = (MISSION_CORE_LOCATIONS select _locIdx) select 5;
                    if (_owner == WEST) then {
                        [_grp] call MISSION_CORE_fnc_clearGroupWaypoints;
                        _grp setBehaviour "SAFE";
                        _grp setCombatMode "YELLOW";
                        _grp setSpeedMode "LIMITED";
                        private _wp = _grp addWaypoint [_targetPos, 50];
                        _wp setWaypointType "MOVE";
                        _wp setWaypointBehaviour "SAFE";
                        _wp setWaypointCombatMode "YELLOW";
                        _wp setWaypointSpeed "LIMITED";
                        private _hwp = _grp addWaypoint [_targetPos, 0];
                        _hwp setWaypointType "HOLD";
                        _hwp setWaypointBehaviour "SAFE";
                        _hwp setWaypointCombatMode "YELLOW";
                        _hwp setWaypointSpeed "LIMITED";
                        _grp setCurrentWaypoint _wp;
                        _grp setVariable ["MISSION_CORE_ORDER", "hold"];
                        _grp setVariable ["MISSION_CORE_ATTACK_TARGET", _targetPos];
                        MISSION_CORE_ATTACK_GROUPS set [_grpId, [_grp, _targetName, [], _template, WEST, "hold", _targetPos]];
                        hint format ["Group #%1 redeployed (free): holding at %2.", _grpId, _targetName];
                    } else {
                        // SPG/arty re-task to a new enemy target: never assault the marker. The piece
                        // repositions to the best standoff firing line (nearest BLUFOR marker to the new
                        // target) and keeps shelling - the fire loop is re-registered with the new aim point.
                        if ([_template] call MISSION_CORE_fnc_isArtyTemplate) then {
                            [_grp, _targetPos, _tpos] call MISSION_CORE_fnc_assaultArtyDeploy;
                            MISSION_CORE_ATTACK_GROUPS set [_grpId, [_grp, _targetName, [], _template, WEST, "hold", _targetPos]];
                            hint format ["Group #%1 (arty) repositioned to the best standoff line on %2.", _grpId, _targetName];
                        } else {
private _wps = +MISSION_CORE_RECRUIT_SAVED_WAYPOINTS;
    // PER-MARKER WAYPOINT LISTS (session): the last route drawn & used for a target marker is
    // remembered and shared across ALL squad types (motorized, mech, armored, infantry). If the
    // editor is empty, fall back to that marker's saved list so re-deploys (multiples of any
    // template) follow the same route. Empty -> recruit's default single-waypoint attack.
    if (count _wps == 0 && { !isNil "MISSION_CORE_RECRUIT_WPS_PER_MARKER" }) then {
        _wps = +((MISSION_CORE_RECRUIT_WPS_PER_MARKER getOrDefault [_targetName, []]));
        // IDLE-REDEPLOY BASE-LEG TRIM: this saved route was drawn once from the base, so its first
        // waypoints can sit behind where the squad actually is now (it redeploys from a captured
        // marker far from base). Keep only the waypoints at-or-ahead of the squad on the bearing to
        // the NEW target - otherwise every redeploy sends the squad marching back to the base-leg
        // waypoints before it ever advances (felt as 'the AI commander yanks my squad home'). Drop
        // behind-the-squad waypoints; an empty result = default straight-shot to the target.
        private _aim = (_targetPos vectorDiff (getPosASL (leader _grp)));
        private _len = vectorMagnitude _aim;
        if (_len > 0) then {
            _aim = _aim vectorMultiply (1 / _len);
            _wps = _wps select {
                private _proj = ((_x select 0) vectorDiff (getPosASL (leader _grp))) vectorDotProduct _aim;
                _proj >= 0
            };
        };
    };
                        _grp setBehaviour "AWARE";
                        _grp setCombatMode "YELLOW";
                        _grp setSpeedMode "FULL";
                        _grp setVariable ["MISSION_CORE_ORDER", "attack"];
                        [_grp, _wps, _targetPos] call MISSION_CORE_fnc_applyAssaultWaypoints;
                        MISSION_CORE_ATTACK_GROUPS set [_grpId, [_grp, _targetName, _wps, _template, WEST, "active", _targetPos]];
                        MISSION_CORE_RECRUIT_SAVED_WAYPOINTS = [];
                        hint format ["Group #%1 redeployed (free): %2 men assaulting %3.", _grpId, _alive, _targetName];
                        };
                    };
                };
            } else {
                hint "That group no longer exists.";
            };
        };
    };
    if (_idleHandled) exitWith {
        call MISSION_CORE_fnc_recruitMenuUpdateMP;
        call MISSION_CORE_fnc_recruitMenuPopulateAttack;
    };

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

    // Friendly target: this is an escort/guard deploy, not an assault - park them on the marker
    // with a move+hold so the monitor does not immediately misread it as a captured-assault flip.
    private _owner = (MISSION_CORE_LOCATIONS select _locIdx) select 5;
    private _status = "active";
    private _wps = +MISSION_CORE_RECRUIT_SAVED_WAYPOINTS;
    // Self-propelled guns / MLRS bought from the attack tab are FIRE SUPPORT, not assault units:
    // they park at the best standoff firing line (nearest BLUFOR marker to the objective), shell it,
    // and relocate back to a BLUFOR marker after each barrage. They never advance into the target.
    private _isArty = [_template] call MISSION_CORE_fnc_isArtyTemplate;
    if (_owner == WEST) then {
        _status = "hold";
        _wps = [];
        [_grp] call MISSION_CORE_fnc_clearGroupWaypoints;
        _grp setBehaviour "SAFE";
        _grp setCombatMode "YELLOW";
        _grp setSpeedMode "LIMITED";
        _grp setVariable ["MISSION_CORE_ORDER", "hold"];
        private _wp = _grp addWaypoint [_targetPos, 50];
        _wp setWaypointType "MOVE";
        _wp setWaypointBehaviour "SAFE";
        _wp setWaypointCombatMode "YELLOW";
        _wp setWaypointSpeed "LIMITED";
        private _hwp = _grp addWaypoint [_targetPos, 0];
        _hwp setWaypointType "HOLD";
        _hwp setWaypointBehaviour "SAFE";
        _hwp setWaypointCombatMode "YELLOW";
        _hwp setWaypointSpeed "LIMITED";
        _grp setCurrentWaypoint _wp;
        _grp setVariable ["MISSION_CORE_ATTACK_TARGET", _targetPos];
    } else {
        // EAST target: an arty piece gets the fire-support deploy (standoff + shelling, never advances).
        if (_isArty) then {
            [_grp, _targetPos, _spawnPos] call MISSION_CORE_fnc_assaultArtyDeploy;
            _status = "hold";
            _wps = [];
        } else {
            // EAST target: if a player is ALREADY engaging the marker the squad pushes in immediately;
            // otherwise it STAGES at its source edge and waits - it only advances once the marker is
            // engaged or the player presses RELEASE STAGED ASSAULT (recruit menu).
            if (!isNil "MISSION_CORE_CONTESTED_MARKERS" && { _targetName in MISSION_CORE_CONTESTED_MARKERS }) then {
                // Apply the player's saved assault waypoints (clear first -> follow exactly, no added-on
                // waypoints, no CYCLE ever). Foot infantry still ride a transport if the drop-off is far away.
                if (!(vehicle (leader _grp) != leader _grp) && { count _wps > 0 }) then {
                    // Foot infantry - hop on a transport if the first waypoint is a long way off.
                    private _usedTransport = [_grp, _wps, _targetPos] call MISSION_CORE_fnc_recruitSpawnTransport;
                    if (!_usedTransport) then {
                        [_grp, _wps, _targetPos] call MISSION_CORE_fnc_applyAssaultWaypoints;
                    };
                } else {
                    [_grp, _wps, _targetPos] call MISSION_CORE_fnc_applyAssaultWaypoints;
                };
            } else {
                _status = "staging";
                private _srcSize = [200, 200];
                {
                    if ((_x select 0) == _myMarker && { count (_x select 1) > 1 }) exitWith { _srcSize = ((_x select 1) select 1); };
                } forEach MISSION_CORE_LOCATIONS;
                [_grp, _spawnPos, _srcSize, _targetPos, _targetName] call MISSION_CORE_fnc_stageBluforGroup;
            };
        };
    };

    // Register the attack group
    private _grpId = MISSION_CORE_RECRUIT_NEXT_GRP_ID;
    MISSION_CORE_RECRUIT_NEXT_GRP_ID = MISSION_CORE_RECRUIT_NEXT_GRP_ID + 1;
    MISSION_CORE_ATTACK_GROUPS set [_grpId, [_grp, _targetName, _wps, _template, WEST, _status, _targetPos]];
    MISSION_CORE_SPAWNED_GROUPS pushBack _grp;

    // A staged squad is registered so the RELEASE STAGED ASSAULT button can order it in with its
    // saved waypoints and flip its ATTACK_GROUPS entry back to "active".
    if (_status == "staging") then {
        if (isNil "MISSION_CORE_BLUFOR_STAGED") then { MISSION_CORE_BLUFOR_STAGED = []; };
        MISSION_CORE_BLUFOR_STAGED pushBack [_grp, _grpId, _template, _targetName, _targetPos, _wps];
    };

    // Remember this waypoint list as the target marker's saved route (session) so any later deploy
    // of ANY squad type to the same target reuses it. Assault path only - friendly holds are not saved.
    if (_owner != WEST && { count _wps > 0 }) then {
        if (isNil "MISSION_CORE_RECRUIT_WPS_PER_MARKER") then { MISSION_CORE_RECRUIT_WPS_PER_MARKER = createHashMap; };
        MISSION_CORE_RECRUIT_WPS_PER_MARKER set [_targetName, +_wps];
    };

    // Clear temp waypoints (the per-marker saved list above remains the fallback for re-deploys)
    MISSION_CORE_RECRUIT_SAVED_WAYPOINTS = [];

    if (_status == "staging") then {
        hint format ["Attack group #%1 staged at the %2 edge! It holds until the marker is engaged or RELEASE STAGED ASSAULT is pressed. (-%4 MP)", _grpId, _targetName, _unitCount, _cost];
    } else {
        if (_isArty && { _owner != WEST }) then {
            hint format ["Artillery support #%1 deployed! It holds the best standoff line and shells %2 - it never advances into the marker. (-%3 MP)", _grpId, _targetName, _cost];
        } else {
            hint format ["Attack group #%1 deployed! %2 men -> %3 (%4 WPs) (-%5 MP)", _grpId, _unitCount, _targetName, count _wps, _cost];
        };
    };
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
// WP editor done-action: "" = normal attack deploy flow; "COMMANDER" = apply drawn route to the
// commander's selected groups instead. Set by recruitCommanderOpenWP, consumed at editor close.
MISSION_CORE_WP_DONE_TARGET = "";
// Commander tab selection membership (group objects), persists across menu open/close.
if (isNil "MISSION_CORE_COMMAND_SELECTED") then { MISSION_CORE_COMMAND_SELECTED = []; };

// Update HUD via titleText — renders above the map layer.
MISSION_CORE_fnc_wpPanelUpdateCount = {
    private _typeNames = ["Move","SAD","TR UNLOAD","Guard","Hold"];
    private _typeIdx = ["MOVE","SAD","UNLOAD","GUARD","HOLD"] find MISSION_CORE_RECRUIT_WP_TYPE;
    private _typeName = if (_typeIdx >= 0) then { _typeNames select _typeIdx } else { MISSION_CORE_RECRUIT_WP_TYPE };

    private _roeNames = ["Hold Fire","Open Fire","Fire at Will"];
    private _roeIdx = ["GREEN","YELLOW","RED"] find MISSION_CORE_RECRUIT_WP_ROE;
    private _roeName = if (_roeIdx >= 0) then { _roeNames select _roeIdx } else { MISSION_CORE_RECRUIT_WP_ROE };

    private _speedNames = ["Limited","Normal","Full"];
    private _speedIdx = ["LIMITED","NORMAL","FAST"] find MISSION_CORE_RECRUIT_WP_SPEED;
    private _speedName = if (_speedIdx >= 0) then { _speedNames select _speedIdx } else { MISSION_CORE_RECRUIT_WP_SPEED };

    private _behNames = ["Careless","Safe","Aware","Combat","Stealth"];
    private _behIdx = ["CARELESS","SAFE","AWARE","COMBAT","STEALTH"] find MISSION_CORE_RECRUIT_WP_BEHAVIOUR;
    private _behName = if (_behIdx >= 0) then { _behNames select _behIdx } else { MISSION_CORE_RECRUIT_WP_BEHAVIOUR };

    private _wpCount = count MISSION_CORE_RECRUIT_SAVED_WAYPOINTS;

    titleText [
        format ["<t size='1.2' color='#99CCFF'>WAYPOINT EDITOR</t><br/><br/><t size='1.0' color='#FFFFFF'>Type: %1  ROE: %2</t><br/><t size='1.0' color='#FFFFFF'>Speed: %3  Behaviour: %4</t><br/><t size='1.0' color='#80FF80'>Waypoints: %5</t><br/><br/><t size='0.8' color='#CCCCCC'>[ ] Cycle type | Q W Cycle ROE | E R Speed | T Y Behaviour | Z Undo | X Clear | Esc Done</t>", _typeName, _roeName, _speedName, _behName, _wpCount],
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
    MISSION_CORE_RECRUIT_WP_SPEED = "FULL";
    MISSION_CORE_RECRUIT_WP_BEHAVIOUR = "AWARE";

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
        MISSION_CORE_RECRUIT_SAVED_WAYPOINTS pushBack [_pos, MISSION_CORE_RECRUIT_WP_TYPE, MISSION_CORE_RECRUIT_WP_ROE, MISSION_CORE_RECRUIT_WP_SPEED, MISSION_CORE_RECRUIT_WP_BEHAVIOUR];
        [_pos, MISSION_CORE_RECRUIT_WP_TYPE, _wpIdx] call MISSION_CORE_fnc_wpEditorCreateMarker;
        call MISSION_CORE_fnc_wpPanelUpdateCount;
        hint format ["WP %1 placed: %2", _wpIdx + 1, MISSION_CORE_RECRUIT_WP_TYPE];
    };

    // Key handler on the map display (display 12)
    private _keyId = findDisplay 12 displayAddEventHandler ["KeyDown", {
        params ["_disp", "_key"];
        private _typeCycle = ["MOVE","SAD","UNLOAD","GUARD","HOLD"];
        private _roeCycle = ["GREEN","YELLOW","RED"];
        private _speedCycle = ["LIMITED","NORMAL","FAST"];
        private _behCycle = ["CARELESS","SAFE","AWARE","COMBAT","STEALTH"];
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
            case 18: { // E = previous speed
                private _idx = _speedCycle find MISSION_CORE_RECRUIT_WP_SPEED;
                _idx = if (_idx <= 0) then { count _speedCycle - 1 } else { _idx - 1 };
                MISSION_CORE_RECRUIT_WP_SPEED = _speedCycle select _idx;
                _handled = true;
            };
            case 19: { // R = next speed
                private _idx = _speedCycle find MISSION_CORE_RECRUIT_WP_SPEED;
                _idx = if (_idx >= count _speedCycle - 1) then { 0 } else { _idx + 1 };
                MISSION_CORE_RECRUIT_WP_SPEED = _speedCycle select _idx;
                _handled = true;
            };
            case 20: { // T = previous behaviour
                private _idx = _behCycle find MISSION_CORE_RECRUIT_WP_BEHAVIOUR;
                _idx = if (_idx <= 0) then { count _behCycle - 1 } else { _idx - 1 };
                MISSION_CORE_RECRUIT_WP_BEHAVIOUR = _behCycle select _idx;
                _handled = true;
            };
            case 22: { // Y = next behaviour
                private _idx = _behCycle find MISSION_CORE_RECRUIT_WP_BEHAVIOUR;
                _idx = if (_idx >= count _behCycle - 1) then { 0 } else { _idx + 1 };
                MISSION_CORE_RECRUIT_WP_BEHAVIOUR = _behCycle select _idx;
                _handled = true;
            };
            case 21: { call MISSION_CORE_fnc_wpEditorRemoveLast; _handled = true; }; // Z
            case 45: { call MISSION_CORE_fnc_wpEditorClear; _handled = true; }; // X
        };
        if (_handled) then { call MISSION_CORE_fnc_wpPanelUpdateCount; };
        _handled
    }];
    missionNamespace setVariable ["MISSION_CORE_RECRUIT_WP_KEYHANDLER", _keyId];

    // Wait for map to close (Escape), then clean up, run the done-action, and return to the menu.
    [] spawn {
        waitUntil { sleep 0.5; !visibleMap };
        onMapSingleClick "";
        private _kid = missionNamespace getVariable ["MISSION_CORE_RECRUIT_WP_KEYHANDLER", -1];
        if (_kid >= 0) then { findDisplay 12 displayRemoveEventHandler ["KeyDown", _kid]; };
        call MISSION_CORE_fnc_wpEditorDestroyHUD;
        { deleteMarkerLocal _x } forEach MISSION_CORE_RECRUIT_WAYPOINT_MARKERS;
        MISSION_CORE_RECRUIT_WAYPOINT_MARKERS = [];
        // Commander mode: apply the drawn route to every selected group instead of deploying a
        // fresh squad, then reopen on the COMMANDER (3) tab.
        if (MISSION_CORE_WP_DONE_TARGET == "COMMANDER") then {
            MISSION_CORE_WP_DONE_TARGET = "";
            MISSION_CORE_RECRUIT_ACTIVE_TAB = 3;
            sleep 0.3;
            call MISSION_CORE_fnc_commanderApplyWaypoints;
        };
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
    MISSION_CORE_RECRUIT_WP_SPEED = "FULL";
    MISSION_CORE_RECRUIT_WP_BEHAVIOUR = "AWARE";
    call MISSION_CORE_fnc_wpPanelUpdateCount;
};

// Done: close map + HUD, return to recruit menu.
MISSION_CORE_fnc_wpEditorDone = {
    openMap false;
};
