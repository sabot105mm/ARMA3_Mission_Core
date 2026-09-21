// =====================================================================
// SERVER-AUTHORITATIVE RECRUIT ASSAULT SYSTEM  (Milestone 1 of the MP conversion)
//
// The BLUFOR recruit ATTACK tab used to spawn its squads on the clicking client
// (BIS_fnc_spawnGroup inside fnc\fn_recruit.sqf). In multiplayer those groups only
// existed on one client - the server could not see them and every off-owner unit
// command silently failed. fn_assaultRelay.sqf patched VISIBILITY; this file is the
// real fix: every recruit attack group is now born, ordered, monitored and
// re-recruited HERE on the server, exactly like the garrison tab already is.
//
// Structure:
//   assaultServerRequestNew / RequestIdle / RERecruit  <- called by clients via
//        remoteExec target 2 (fnc\fn_recruit.sqf sends the button presses).
//   assaultServerReleaseStaged                          <- manual RELEASE STAGED + the
//        auto-advance monitor below.
//   serverMonitorAttackGroups / serverMonitorStaging   <- serverside lifecycle loops
//        (were client-side monitors; they cannot run on clients any more because the
//        groups they manage are no longer local to any client).
//   server* helpers                                    <- faithful serverside ports of
//        the old client helpers (staging, transport, arty, refill).
//   assaultServerHint                                  <- routes text to the right
//        player (the deployer is recorded per group in MISSION_CORE_ASSAULT_OWNERS).
//   assaultServerMirror                                <- broadcasts a netId-based copy
//        of the authoritative MISSION_CORE_ATTACK_GROUPS so EVERY client menu renders
//        the same map (groups/units are not serializable - netIds are).
//
// Hosted games: the host shares the server namespace, and fn_recruit.sqf's mirror
// loop skips isServer machines, so the host just uses the server-side map directly.
//
// Ownership/HC: every group touched here was spawned HERE, so it is server-local by
// construction. When the later headless-client step arrives (Milestone 4) every
// "act on a group" call sits inside this file, so routing them to the owning machine
// is a contained change.
//
// Naming: sorry, the FILE is fn_assaultServer.sqf but the 3000+ client functions it
// mirrors live in fn_recruit.sqf - which is NEVER compiled on the server (its client
// copies like applyAssaultWaypoints would collide with fn_snatch.sqf's server copy).
// Every function defined below therefore carries a strict server-only name.
// =====================================================================

if (isNil "MISSION_CORE_RECRUIT_NEXT_GRP_ID") then { MISSION_CORE_RECRUIT_NEXT_GRP_ID = 0; };
if (isNil "MISSION_CORE_RECRUIT_TRANSPORT_DIST") then { MISSION_CORE_RECRUIT_TRANSPORT_DIST = 800; };

// -------------------------------------------------------------------
// HINT ROUTING + MIRROR
// -------------------------------------------------------------------

// Send a recruit-system message to a specific player (remoteExec to that client's
// fn_assaultClientHint). objNull / non-player owners fall back to a lobby chat line.
MISSION_CORE_fnc_assaultServerHint = {
    params ["_owner", "_msg"];
    if (!isNull _owner && { isPlayer _owner }) then {
        [_msg] remoteExecCall ["MISSION_CORE_fnc_assaultClientHint", _owner, false];
    } else {
        _msg remoteExecCall ["systemChat", 0, false];
    };
};

// Owner object recorded for a group id (for hint routing only; never broadcast).
MISSION_CORE_fnc_assaultServerOwner = {
    params ["_gid"];
    if (!isNil "MISSION_CORE_ASSAULT_OWNERS") then {
        private _o = MISSION_CORE_ASSAULT_OWNERS getOrDefault [_gid, objNull];
        if (!isNull _o) exitWith { _o };
    };
    objNull
};

// Broadcast a netId-based snapshot of the authoritative attack-group map. Clients
// rebuild their menu map from this (fn_recruit.sqf assaultMirrorApply).
MISSION_CORE_fnc_assaultServerMirror = {
    MISSION_CORE_ASSAULT_MIRROR = [];
    if (!isNil "MISSION_CORE_ATTACK_GROUPS") then {
        {
            private _d = _y;
            _d params ["_grp", "_tgt", "_wps", "_tmpl", "_side", "_status", ["_tpos", [0, 0, 0]]];
            if (isNull _grp) then { continue; };
            MISSION_CORE_ASSAULT_MIRROR pushBack [_x, netId _grp, netId (leader _grp), _tgt, _wps, _tmpl, _status, _tpos];
        } forEach MISSION_CORE_ATTACK_GROUPS;
    };
    publicVariable "MISSION_CORE_ASSAULT_MIRROR";
};

// -------------------------------------------------------------------
// PORTED HELPERS (serverside copies of the old client helpers)
// -------------------------------------------------------------------

// Is an attack-tab template a self-propelled gun / MLRS / mortar battery?
MISSION_CORE_fnc_serverIsArtyTemplate = {
    params ["_tmpl"];
    _tmpl params ["", "_grpUnits", "", ["_subCat", ""], ""];
    if (_subCat == "artillery") exitWith { true };
    private _isArty = false;
    {
        private _cls = _x;
        if (isNil "_cls" || { _cls == "" }) then { continue; };
        private _ln = toLower _cls;
        if (_ln find "artillery" > -1 || { _ln find "arty" > -1 } || { _ln find "mlrs" > -1 } || { _ln find "scorcher" > -1 } || { _ln find "m270" > -1 } || { _ln find "grad" > -1 } || { _ln find "dana" > -1 } || { _cls isKindOf "StaticMortar" }) exitWith { _isArty = true; };
    } forEach _grpUnits;
    _isArty
};

// The strictest minimum ballistic range across a whole artillery platoon (mixed group).
MISSION_CORE_fnc_serverArtyGroupMinRange = {
    params ["_grp"];
    private _minR = 825;
    {
        private _v = vehicle _x;
        if (_v isKindOf "LandVehicle") then { _minR = _minR max ([_v] call MISSION_CORE_fnc_serverArtyMinRange); };
    } forEach units _grp;
    _minR
};

// Point an assault-arty group at a target: park at the best standoff (nearest friendly
// marker that still clears the guns' minimum range), tag it so no other AI system
// steals it, and register every piece into the player-arty fire loop (server-side).
MISSION_CORE_fnc_serverArtyDeploy = {
    params ["_grp", "_targetPos", "_spawnFallback"];
    private _minR = [_grp] call MISSION_CORE_fnc_serverArtyGroupMinRange;
    private _standoff = [_targetPos, _minR, [], 0] call MISSION_CORE_fnc_serverArtyStandoff;
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
    private _artys = [];
    {
        private _v = vehicle _x;
        if (_v isKindOf "LandVehicle" && { _artys findIf { _x == _v } == -1 }) then { _artys pushBack _v; };
    } forEach units _grp;
    if (count _artys > 0) then {
        {
            [netId _x, _targetPos] call MISSION_CORE_fnc_serverRegisterAssaultArty;
        } forEach _artys;
    };
};

// Staged-squad leader Killed EH: the staging "torch" passes to the next alive unit.
MISSION_CORE_fnc_serverStagedLeaderTorch = {
    params ["_dead", "_killer"];
    private _g = group _dead;
    if (isNull _g) exitWith {};
    if (_g getVariable ["MISSION_CORE_ORDER", ""] != "staging") exitWith {};
    private _alive = units _g select { alive _x };
    if (count _alive == 0) exitWith {};
    private _member = _alive select 0;
    _member addEventHandler ["Killed", { _this call MISSION_CORE_fnc_serverStagedLeaderTorch; }];
    diag_log format ["BLUFOR STAGED: %1 leader down - %2 takes over", groupId _g, name _member];
};

// Stage a recruited BLUFOR squad at its source edge on the bearing to an enemy target.
// Only the waypoint/order/EH setup happens here - map + staged register handled by caller.
MISSION_CORE_fnc_serverStageGroup = {
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
    (leader _grp) addEventHandler ["Killed", { _this call MISSION_CORE_fnc_serverStagedLeaderTorch; }];
    diag_log format ["BLUFOR STAGED: %1 staged at %2 on bearing %3 toward %4", groupId _grp, _stagePos, round _dir, _tgtName];
};

// Serverside transport loader for foot squads deployed far from their drop point.
// Caller position (not `player`) anchors the spawn; the squad's own group drives.
MISSION_CORE_fnc_serverSpawnTransport = {
    params ["_grp", "_wps", "_targetPos", "_caller"];
    if (isNull _caller) then { _caller = leader _grp; };

    private _dropPos = _targetPos;
    if (count _wps > 0) then { _dropPos = (_wps select 0) select 0; };

    private _dist = _caller distance _dropPos;
    if (_dist < MISSION_CORE_RECRUIT_TRANSPORT_DIST) exitWith { false };

    private _unitCount = count units _grp;
    private _vehClass = if (_unitCount <= 4) then {
        "B_MRAP_01_F"
    } else {
        if (_unitCount <= 10) then { "B_T_Truck_01_covered_F" } else { "B_T_Truck_01_transport_F" };
    };

    private _dir = getDir _caller;
    private _vPos = _caller getPos [8, _dir];
    _vPos = _vPos findEmptyPosition [0, 30, _vehClass];
    if (count _vPos == 0) then { _vPos = _caller getPos [15, _dir]; };

    private _veh = createVehicle [_vehClass, _vPos, [], 0, "NONE"];
    _veh setDir _dir;

    private _units = units _grp;
    if (count _units > 0) then { (_units select 0) moveInDriver _veh; };
    {
        if (vehicle _x == _x && { _x != driver _veh }) then {
            _x moveInAny _veh;
        };
    } forEach _units;
    if (isNull (driver _veh)) then {
        _units findIf { if (vehicle _x == _x) exitWith { _x moveInDriver _veh; true }; false };
    };

    private _cargoCount = { vehicle _x != _x } count units _grp;
    if (_cargoCount == 0 && _unitCount > 0) exitWith {
        deleteVehicle _veh;
        false
    };

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

    _grp setVariable ["MISSION_CORE_TRANSPORT_WPS", _wps, true];
    _grp setVariable ["MISSION_CORE_TRANSPORT_TARGET", _targetPos, true];
    _vw2 setWaypointScript "fnc\commander\transport_unload.sqf";
    _grp setCurrentWaypoint _vw1;

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
        [_veh] call MISSION_CORE_fnc_stopForDismount;
        private _drv = driver _veh;
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

// One refill attempt for a holding attack group (status must be "hold"). Missing infantry
// are spawned in for manpower, missing armored slots consume one armor-pool point each.
MISSION_CORE_fnc_serverGroupTryRefill = {
    params ["_grp", "_target", "_wps", "_tmpl", "_side", "_status", "_targetPos"];
    if (isNull _grp) exitWith { [_grp, _target, _wps, _tmpl, _side, _status, _targetPos] };
    _tmpl params ["_grpName", "_grpUnits", "_unitCount", ["_subCat", ""], ["_catName", ""]];
    private _alive = { alive _x } count units _grp;
    if (_alive >= _unitCount) exitWith { [_grp, _target, _wps, _tmpl, _side, _status, _targetPos] };

    private _costPer = if (isNil "MISSION_CORE_MANPOWER_PER_UNIT") then { 10 } else { MISSION_CORE_MANPOWER_PER_UNIT };
    private _missing = (_unitCount - _alive) max 0;

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
    _spawnPos = [_spawnPos, _spawnPos, [60, 60]] call MISSION_CORE_fnc_safeVehicleSpawnPos;
    if (count _spawnPos == 2) then { _spawnPos pushBack 0; };

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

    private _vehGot = [];
    {
        private _src = [WEST, _spawnPos] call MISSION_CORE_fnc_consumePoolTankForSide;
        if (_src != "") then { _vehGot pushBack _x; };
    } forEach _missingVeh;

    {
        private _v = createVehicle [_x, [_spawnPos] call MISSION_CORE_fnc_liftSpawn, [], 15, "CAN_COLLIDE"];
        private _vGrp = createVehicleCrew _v;
        { if (!isNull _x) then { [_x] joinSilent _grp; }; } forEach units _vGrp;
        [_v] joinSilent _grp;
        if (!isNull _vGrp) then { deleteGroup _vGrp; };
        _v setVariable ["MISSION_CORE_BLUFOR", true];
    } forEach _vehGot;

    private _needMen = ((_unitCount - ({ alive _x } count units _grp)) max 0) min _unitCount;
    private _menClasses = _grpUnits select { _x isKindOf "Man" };
    if (count _menClasses == 0) then { _menClasses = ["B_Soldier_F"]; };
    for "_i" from 1 to _needMen do {
        private _cls = _menClasses select ((_i - 1) mod (count _menClasses));
        if (_cls isKindOf "Man") then {
            _grp createUnit [_cls, _spawnPos, [], 10, "FORM"];
        };
    };

    [_grp, _target, _wps, _tmpl, _side, _status, _targetPos]
};

// -------------------------------------------------------------------
// REQUEST HANDLERS (remoteExec'd from the client recruit menu)
// -------------------------------------------------------------------

// NEW-DEPLOY REQUEST: [player, template, targetName, drawnWaypoints]
MISSION_CORE_fnc_assaultServerRequestNew = {
    params ["_caller", "_template", "_targetName", "_wps"];
    if (isNull _caller) exitWith {};
    if !(alive _caller) exitWith {};
    if !([_caller] call MISSION_CORE_fnc_serverCallerCanRecruit) exitWith { [_caller, "Too far from base."] call MISSION_CORE_fnc_assaultServerHint; };
    _template params ["_grpName", "_grpUnits", "_unitCount", ["_subCat", ""], ["_catName", ""]];
    if (_unitCount <= 0) exitWith {};

    private _locIdx = MISSION_CORE_LOCATIONS findIf { (_x select 0) == _targetName };
    if (_locIdx < 0) exitWith { [_caller, format ["Target marker %1 not found.", _targetName]] call MISSION_CORE_fnc_assaultServerHint; };
    private _targetPos = ((MISSION_CORE_LOCATIONS select _locIdx) select 1) select 0;

    // Spawn at the WEST marker the CALLER is inside (server scan).
    private _spawnPos = getPosATL _caller;
    private _srcSize = [200, 200];
    {
        if ((_x select 5) == WEST) then {
            private _mPos = ((_x select 1) select 0);
            private _mSize = ((_x select 1) select 1);
            private _a = if (count _mSize > 0) then { _mSize select 0 } else { 200 };
            private _b = if (count _mSize > 1) then { _mSize select 1 } else { 200 };
            private _d = _caller distance _mPos;
            if (_d < ((_a max _b) * 0.5 + 100)) exitWith {
                _spawnPos = _mPos;
                if (count _mSize > 0) then { _srcSize = +_mSize; };
            };
        };
    } forEach MISSION_CORE_LOCATIONS;

    private _faction = MISSION_CORE_BLUFOR_DATA select 3;
    private _cfgPath = configFile >> "CfgGroups" >> "West" >> _faction >> _catName >> _grpName;
    if !(isClass _cfgPath) exitWith { [_caller, format ["CfgGroups entry %1 not found.", _grpName]] call MISSION_CORE_fnc_assaultServerHint; };

    private _costPer = if (isNil "MISSION_CORE_MANPOWER_PER_UNIT") then { 10 } else { MISSION_CORE_MANPOWER_PER_UNIT };
    private _cost = _unitCount * _costPer;
    if !([_cost] call MISSION_CORE_fnc_drawManpower) exitWith {
        [_caller, format ["Not enough manpower! Need %1 MP.", _cost]] call MISSION_CORE_fnc_assaultServerHint;
    };

    private _grp = [_spawnPos, side _caller, _cfgPath] call BIS_fnc_spawnGroup;
    if (isNull _grp) exitWith {
        [_cost] call MISSION_CORE_fnc_refundManpower;
        [_caller, "Failed to spawn group."] call MISSION_CORE_fnc_assaultServerHint;
    };

    [_grp, _spawnPos, [200, 200]] call MISSION_CORE_fnc_alignGroupVehiclesToRoad;
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

    _grp setBehaviour "AWARE";
    _grp setCombatMode "YELLOW";
    _grp setSpeedMode "FULL";
    _grp setVariable ["MISSION_CORE_BLUFOR", true];
    _grp setVariable ["MISSION_CORE_ORDER", "attack"];

    private _owner = (MISSION_CORE_LOCATIONS select _locIdx) select 5;
    private _status = "active";
    private _isArty = [_template] call MISSION_CORE_fnc_serverIsArtyTemplate;
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
        if (_isArty) then {
            [_grp, _targetPos, _spawnPos] call MISSION_CORE_fnc_serverArtyDeploy;
            _status = "hold";
            _wps = [];
        } else {
            if (!isNil "MISSION_CORE_CONTESTED_MARKERS" && { _targetName in MISSION_CORE_CONTESTED_MARKERS }) then {
                if (!(vehicle (leader _grp) != leader _grp) && { count _wps > 0 }) then {
                    private _usedTransport = [_grp, _wps, _targetPos, _caller] call MISSION_CORE_fnc_serverSpawnTransport;
                    if (!_usedTransport) then {
                        [netId _grp, _wps, _targetPos] call MISSION_CORE_fnc_applyAssaultWaypointsNet;
                    };
                } else {
                    [netId _grp, _wps, _targetPos] call MISSION_CORE_fnc_applyAssaultWaypointsNet;
                };
            } else {
                _status = "staging";
                [_grp, _spawnPos, _srcSize, _targetPos, _targetName] call MISSION_CORE_fnc_serverStageGroup;
            };
        };
    };

    private _grpId = MISSION_CORE_RECRUIT_NEXT_GRP_ID;
    MISSION_CORE_RECRUIT_NEXT_GRP_ID = _grpId + 1;
    if (isNil "MISSION_CORE_ATTACK_GROUPS") then { MISSION_CORE_ATTACK_GROUPS = createHashMap; };
    MISSION_CORE_ATTACK_GROUPS set [_grpId, [_grp, _targetName, _wps, _template, WEST, _status, _targetPos]];
    if (isNil "MISSION_CORE_SPAWNED_GROUPS") then { MISSION_CORE_SPAWNED_GROUPS = []; };
    MISSION_CORE_SPAWNED_GROUPS pushBack _grp;
    if (isNil "MISSION_CORE_ASSAULT_OWNERS") then { MISSION_CORE_ASSAULT_OWNERS = createHashMap; };
    MISSION_CORE_ASSAULT_OWNERS set [_grpId, _caller];

    if (_status == "staging") then {
        if (isNil "MISSION_CORE_BLUFOR_STAGED") then { MISSION_CORE_BLUFOR_STAGED = []; };
        MISSION_CORE_BLUFOR_STAGED pushBack [_grp, _grpId, _template, _targetName, _targetPos, _wps];
    };

    if (_owner != WEST && { count _wps > 0 }) then {
        if (isNil "MISSION_CORE_RECRUIT_WPS_PER_MARKER") then { MISSION_CORE_RECRUIT_WPS_PER_MARKER = createHashMap; };
        MISSION_CORE_RECRUIT_WPS_PER_MARKER set [_targetName, +_wps];
    };

    if (_status == "staging") then {
        [_caller, format ["Attack group #%1 staged at the %2 edge! It holds until the marker is engaged or RELEASE STAGED ASSAULT is pressed. (-%3 MP)", _grpId, _targetName, _cost]] call MISSION_CORE_fnc_assaultServerHint;
    } else {
        if (_isArty && { _owner != WEST }) then {
            [_caller, format ["Artillery support #%1 deployed! It holds the best standoff line and shells %2 - it never advances into the marker. (-%3 MP)", _grpId, _targetName, _cost]] call MISSION_CORE_fnc_assaultServerHint;
        } else {
            [_caller, format ["Attack group #%1 deployed! %2 men -> %3 (%4 WPs) (-%5 MP)", _grpId, _unitCount, _targetName, count _wps, _cost]] call MISSION_CORE_fnc_assaultServerHint;
        };
    };

    call MISSION_CORE_fnc_assaultServerMirror;
};

// IDLE-REDEPLOY REQUEST: [player, groupId, targetName, drawnWaypoints]
MISSION_CORE_fnc_assaultServerRequestIdle = {
    params ["_caller", "_grpId", "_targetName", "_freshWps"];
    if (isNull _caller) exitWith {};
    if !(alive _caller) exitWith {};
    if !([_caller] call MISSION_CORE_fnc_serverCallerCanRecruit) exitWith { [_caller, "Too far from base."] call MISSION_CORE_fnc_assaultServerHint; };
    if (isNil "MISSION_CORE_ATTACK_GROUPS") exitWith { [_caller, "That group no longer exists."] call MISSION_CORE_fnc_assaultServerHint; };
    private _data = MISSION_CORE_ATTACK_GROUPS getOrDefault [_grpId, []];
    if (count _data == 0) exitWith { [_caller, "That group no longer exists."] call MISSION_CORE_fnc_assaultServerHint; };
    _data params ["_grp", "_oldTarget", "_oldWps", "_template", "_side", "_status", "_tpos"];
    if (isNull _grp) exitWith { [_caller, "That group no longer exists."] call MISSION_CORE_fnc_assaultServerHint; };
    _template params ["_grpName", "_grpUnits", "_unitCount", ["_subCat", ""], ["_catName", ""]];

    private _locIdx = MISSION_CORE_LOCATIONS findIf { (_x select 0) == _targetName };
    if (_locIdx < 0) exitWith { [_caller, format ["Target marker %1 not found.", _targetName]] call MISSION_CORE_fnc_assaultServerHint; };
    private _targetPos = ((MISSION_CORE_LOCATIONS select _locIdx) select 1) select 0;

    _data = [_grp, _oldTarget, _oldWps, _template, WEST, "hold", _tpos] call MISSION_CORE_fnc_serverGroupTryRefill;
    private _alive = { alive _x } count units _grp;
    if (_alive < _unitCount) exitWith {
        [_caller, format ["Group #%1 is not at full strength yet (%2/%3) - it must refill before the next assault. Waiting for manpower/tank pool.", _grpId, _alive, _unitCount]] call MISSION_CORE_fnc_assaultServerHint;
    };

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
        [_caller, format ["Group #%1 redeployed (free): holding at %2.", _grpId, _targetName]] call MISSION_CORE_fnc_assaultServerHint;
    } else {
        if ([_template] call MISSION_CORE_fnc_serverIsArtyTemplate) then {
            [_grp, _targetPos, _tpos] call MISSION_CORE_fnc_serverArtyDeploy;
            MISSION_CORE_ATTACK_GROUPS set [_grpId, [_grp, _targetName, [], _template, WEST, "hold", _targetPos]];
            [_caller, format ["Group #%1 (arty) repositioned to the best standoff line on %2.", _grpId, _targetName]] call MISSION_CORE_fnc_assaultServerHint;
        } else {
            // Fresh editor drawing wins; otherwise the marker's saved session route (trimmed of
            // behind-the-squad base-leg waypoints so a redeploy never marches home first).
            private _wps = +_freshWps;
            if (count _wps == 0 && { !isNil "MISSION_CORE_RECRUIT_WPS_PER_MARKER" }) then {
                _wps = +((MISSION_CORE_RECRUIT_WPS_PER_MARKER getOrDefault [_targetName, []]));
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
            [netId _grp, _wps, _targetPos] call MISSION_CORE_fnc_applyAssaultWaypointsNet;
            MISSION_CORE_ATTACK_GROUPS set [_grpId, [_grp, _targetName, _wps, _template, WEST, "active", _targetPos]];
            [_caller, format ["Group #%1 redeployed (free): %2 men assaulting %3.", _grpId, _alive, _targetName]] call MISSION_CORE_fnc_assaultServerHint;
        };
    };
    call MISSION_CORE_fnc_assaultServerMirror;
};

// RE-RECRUIT REQUEST: [player, wipedGroupId] - reuses the wiped id.
MISSION_CORE_fnc_assaultServerRERecruit = {
    params ["_caller", "_wipedId"];
    if (isNull _caller) exitWith {};
    if !(alive _caller) exitWith {};
    if !([_caller] call MISSION_CORE_fnc_serverCallerCanRecruit) exitWith { [_caller, "Too far from base."] call MISSION_CORE_fnc_assaultServerHint; };
    if (isNil "MISSION_CORE_ATTACK_GROUPS") exitWith { [_caller, "No wiped groups to re-recruit."] call MISSION_CORE_fnc_assaultServerHint; };
    private _data = MISSION_CORE_ATTACK_GROUPS getOrDefault [_wipedId, []];
    if (count _data == 0) exitWith { [_caller, "That group no longer exists."] call MISSION_CORE_fnc_assaultServerHint; };
    _data params ["_oldGrp", "_target", "_wps", "_template", "_side", "_status", "_targetPos"];
    if (_status != "wiped") exitWith {};

    private _locIdx = MISSION_CORE_LOCATIONS findIf { (_x select 0) == _target };
    if (_locIdx < 0) exitWith { [_caller, "Target no longer exists."] call MISSION_CORE_fnc_assaultServerHint; };
    if (((MISSION_CORE_LOCATIONS select _locIdx) select 5) == WEST) exitWith {
        [_caller, format ["%1 is already under BLUFOR control!", _target]] call MISSION_CORE_fnc_assaultServerHint;
    };

    _template params ["_grpName", "_grpUnits", "_unitCount", ["_subCat", ""], ["_catName", ""]];
    private _costPer = if (isNil "MISSION_CORE_MANPOWER_PER_UNIT") then { 10 } else { MISSION_CORE_MANPOWER_PER_UNIT };
    private _cost = _unitCount * _costPer;
    if !([_cost] call MISSION_CORE_fnc_drawManpower) exitWith {
        [_caller, format ["Not enough manpower! Need %1 MP.", _cost]] call MISSION_CORE_fnc_assaultServerHint;
    };

    private _spawnPos = getPosATL _caller;
    {
        if ((_x select 5) == WEST) then {
            private _mPos = ((_x select 1) select 0);
            private _mSize = ((_x select 1) select 1);
            private _a = if (count _mSize > 0) then { _mSize select 0 } else { 200 };
            private _b = if (count _mSize > 1) then { _mSize select 1 } else { 200 };
            private _d = _caller distance _mPos;
            if (_d < ((_a max _b) * 0.5 + 100)) exitWith { _spawnPos = _mPos; };
        };
    } forEach MISSION_CORE_LOCATIONS;

    private _faction = MISSION_CORE_BLUFOR_DATA select 3;
    private _cfgPath = configFile >> "CfgGroups" >> "West" >> _faction >> _catName >> _grpName;
    if !(isClass _cfgPath) exitWith {
        [_cost] call MISSION_CORE_fnc_refundManpower;
        [_caller, format ["CfgGroups entry %1 not found.", _grpName]] call MISSION_CORE_fnc_assaultServerHint;
    };
    private _grp = [_spawnPos, side _caller, _cfgPath] call BIS_fnc_spawnGroup;
    if (isNull _grp) exitWith {
        [_cost] call MISSION_CORE_fnc_refundManpower;
        [_caller, "Failed to spawn group."] call MISSION_CORE_fnc_assaultServerHint;
    };

    [_grp, _spawnPos, [200, 200]] call MISSION_CORE_fnc_alignGroupVehiclesToRoad;
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

    _grp setBehaviour "AWARE";
    _grp setCombatMode "YELLOW";
    _grp setSpeedMode "FULL";
    _grp setVariable ["MISSION_CORE_BLUFOR", true];
    _grp setVariable ["MISSION_CORE_ORDER", "attack"];

    if (!(vehicle (leader _grp) != leader _grp) && { count _wps > 0 }) then {
        private _usedTransport = [_grp, _wps, _targetPos, _caller] call MISSION_CORE_fnc_serverSpawnTransport;
        if (!_usedTransport) then {
            [netId _grp, _wps, _targetPos] call MISSION_CORE_fnc_applyAssaultWaypointsNet;
        };
    } else {
        [netId _grp, _wps, _targetPos] call MISSION_CORE_fnc_applyAssaultWaypointsNet;
    };

    MISSION_CORE_ATTACK_GROUPS set [_wipedId, [_grp, _target, _wps, _template, WEST, "active", _targetPos]];
    if (isNil "MISSION_CORE_SPAWNED_GROUPS") then { MISSION_CORE_SPAWNED_GROUPS = []; };
    MISSION_CORE_SPAWNED_GROUPS pushBack _grp;
    if (isNil "MISSION_CORE_ASSAULT_OWNERS") then { MISSION_CORE_ASSAULT_OWNERS = createHashMap; };
    MISSION_CORE_ASSAULT_OWNERS set [_wipedId, _caller];

    [_caller, format ["Group #%1 re-recruited! %2 men -> %3 (-%4 MP)", _wipedId, _unitCount, _target, _cost]] call MISSION_CORE_fnc_assaultServerHint;
    call MISSION_CORE_fnc_assaultServerMirror;
};

// RELEASE STAGED REQUEST: [player|objNull, onlyTargets]. objNull caller = auto-advance
// by the staging monitor (no per-player hint, just the lobby announcement).
MISSION_CORE_fnc_assaultServerReleaseStaged = {
    params ["_caller", ["_onlyTargets", []]];
    if (!(isNull _caller) && { !([_caller] call MISSION_CORE_fnc_serverCallerCanRecruit) }) exitWith { [_caller, "Too far from base."] call MISSION_CORE_fnc_assaultServerHint; };
    if (isNil "MISSION_CORE_BLUFOR_STAGED") then { MISSION_CORE_BLUFOR_STAGED = []; };
    if (count MISSION_CORE_BLUFOR_STAGED == 0) exitWith { if !(isNull _caller) then { [_caller, "No BLUFOR squads are staged."] call MISSION_CORE_fnc_assaultServerHint; }; };
    private _released = 0;
    private _keep = [];
    {
        _x params ["_grp", "_grpId", "_template", "_tgtName", "_tgtPos", "_wps"];
        if (isNull _grp || { count units _grp == 0 }) then { continue; };
        if (count _onlyTargets > 0 && { !(_tgtName in _onlyTargets) }) then { _keep pushBack _x; continue; };
        _grp setVariable ["MISSION_CORE_ORDER", "attack"];
        [netId _grp, _wps, _tgtPos] call MISSION_CORE_fnc_applyAssaultWaypointsNet;
        if (_grpId >= 0 && { !isNil "MISSION_CORE_ATTACK_GROUPS" }) then {
            private _adata = MISSION_CORE_ATTACK_GROUPS getOrDefault [_grpId, []];
            if (count _adata > 0) then {
                _adata set [5, "active"];
                _adata set [6, _tgtPos];
                MISSION_CORE_ATTACK_GROUPS set [_grpId, _adata];
            };
        };
        _released = _released + 1;
        diag_log format ["BLUFOR STAGED: %1 released toward %2", groupId _grp, _tgtName];
    } forEach MISSION_CORE_BLUFOR_STAGED;
    MISSION_CORE_BLUFOR_STAGED = _keep;
    if (_released > 0) then {
        if !(isNull _caller) then {
            [_caller, format ["Released %1 staged squad%2 - they are advancing.", _released, if (_released == 1) then { "" } else { "s" }]] call MISSION_CORE_fnc_assaultServerHint;
        };
        ["Staged squads released! They are advancing."] remoteExec ["systemChat", 0];
    } else {
        if !(isNull _caller) then { [_caller, "No BLUFOR squads are staged."] call MISSION_CORE_fnc_assaultServerHint; };
    };
    call MISSION_CORE_fnc_assaultServerMirror;
};

// -------------------------------------------------------------------
// SERVERSIDE LIFECYCLE MONITORS (replaced the old client-side monitors -
// they now run here because the groups they manage belong to the server)
// -------------------------------------------------------------------

MISSION_CORE_fnc_serverMonitorAttackGroups = {
    [] spawn {
        if (isNil "MISSION_CORE_ATTACK_GROUPS") then { MISSION_CORE_ATTACK_GROUPS = createHashMap; };
        waitUntil { !isNil "MISSION_CORE_INITIALIZED" && { MISSION_CORE_INITIALIZED } };
        while { true } do {
            sleep 5;
            private _changed = false;
            {
                private _data = _y;
                _data params ["_grp", "_target", "_wps", "_tmpl", "_side", "_status", ["_targetPos", [0, 0, 0]]];
                if (_status in ["active", "hold", "staging"] && { isNull _grp || { count units _grp == 0 } }) then {
                    _data set [5, "wiped"];
                    MISSION_CORE_ATTACK_GROUPS set [_x, _data];
                    _changed = true;
                    private _owner = _x call MISSION_CORE_fnc_assaultServerOwner;
                    [_owner, format ["Attack group #%1 wiped out!\nOpen recruit menu (X) to re-recruit.", _x]] call MISSION_CORE_fnc_assaultServerHint;
                } else {
                    if (_status == "hold" && { !isNull _grp } && { count units _grp > 0 }) then {
                        private _before = { alive _x } count units _grp;
                        MISSION_CORE_ATTACK_GROUPS set [_x, [_grp, _target, _wps, _tmpl, _side, "hold", _targetPos] call MISSION_CORE_fnc_serverGroupTryRefill];
                        if ({ alive _x } count units _grp > _before) then {
                            _changed = true;
                            private _owner = _x call MISSION_CORE_fnc_assaultServerOwner;
                            [_owner, format ["Attack group #%1 refilled to full strength.", _x]] call MISSION_CORE_fnc_assaultServerHint;
                        };
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
                                    _changed = true;
                                    private _owner = _x call MISSION_CORE_fnc_assaultServerOwner;
                                    [_owner, format ["Attack group #%1 captured %2!\nHolding at the captured edge%3. Redeploy it (IDLE list) when back at full strength.", _x, _target, if (_nextTarget == "") then { "." } else { format [" facing %1.", _nextTarget] }]] call MISSION_CORE_fnc_assaultServerHint;
                                };
                            };
                        };
                    };
                };
            } forEach MISSION_CORE_ATTACK_GROUPS;
            if (_changed) then { call MISSION_CORE_fnc_assaultServerMirror; };
        };
    };
};

// Auto-advance: a staged BLUFOR squad pushes in the moment its target becomes contested.
MISSION_CORE_fnc_serverMonitorStaging = {
    [] spawn {
        waitUntil { !isNil "MISSION_CORE_INITIALIZED" && { MISSION_CORE_INITIALIZED } };
        while { true } do {
            sleep 5;
            if (isNil "MISSION_CORE_BLUFOR_STAGED") then { continue; };
            if (count MISSION_CORE_BLUFOR_STAGED == 0) then { continue; };
            private _contested = if (!isNil "MISSION_CORE_CONTESTED_MARKERS") then { +MISSION_CORE_CONTESTED_MARKERS } else { [] };
            if (count _contested > 0) then {
                [objNull, _contested] spawn MISSION_CORE_fnc_assaultServerReleaseStaged;
            };
        };
    };
};