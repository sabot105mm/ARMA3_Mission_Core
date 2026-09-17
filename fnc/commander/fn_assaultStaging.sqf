// -------------------------------------------------------------------
// STAGED ASSAULT SYSTEM
// -------------------------------------------------------------------
// PERMANENT RULE (REDFOR STAGING): committed REDFOR assault groups never drive
// straight at their target the moment the assault is announced. They first move to
// the EDGE of their own (source) marker area, on the compass bearing from the source
// center toward the target marker, and HOLD there (the same edge-hold pattern the
// recruit attack groups use when their captured marker flips). The assault force
// only advances once the requested factory tanks are built and delivered to the
// source marker (or the build deadline passes and the waves roll in regardless).
// There is NO contested/manual/auto release path for REDFOR: the AI commander
// presses the attack itself the moment its armor is on the ground.
// BLUFOR staging (player-purchased squads staged at their source edge until the
// target is engaged or the player releases them) lives in fn_recruit.sqf.

// Reset all REDFOR staging state between assaults.
MISSION_CORE_fnc_resetStagedAssault = {
    MISSION_CORE_ASSAULT_STAGED = createHashMap;
};

// Stage a single committed group at its source edge, facing the target.
// [_grp, _srcPos, _srcSize, _tgtPos, _tgtSize, _tgtName] call MISSION_CORE_fnc_stageAssaultGroup;
MISSION_CORE_fnc_stageAssaultGroup = {
    params ["_grp", "_srcPos", "_srcSize", "_tgtPos", "_tgtSize", ["_tgtName", ""]];
    if (isNil "MISSION_CORE_ASSAULT_STAGED") then { call MISSION_CORE_fnc_resetStagedAssault; };
    private _rad = if (count _srcSize > 0) then { (_srcSize select 0) max 1 } else { 200 };
    private _dir = _srcPos getDir _tgtPos;
    private _stagePos = _srcPos getPos [_rad, _dir];
    if (_stagePos isEqualTo _srcPos) then { _stagePos = _srcPos getPos [250, _dir]; };
    _stagePos = [_stagePos, _srcPos] call MISSION_CORE_fnc_safeWaypointPos;
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
    _grp setVariable ["MISSION_CORE_ASSAULT_GROUP", true];
    // PERMANENT RULE (STAGED ARMOR FORMATION): vehicle-mounted groups hold their formation on the
    // leader while parked at the staging edge and roll out in column behind him once released. Each
    // driver/gunner follows the leader's slot (doFollow = "follow as my formation leader"), so tanks
    // arrive in a line instead of each free-driving. Skip the leader himself.
    if (({ objectParent _x != _x } count units _grp) > 0) then {
        private _fLdr = leader _grp;
        { if (_x != _fLdr) then { _x doFollow _fLdr; }; } forEach units _grp;
    };
    MISSION_CORE_ASSAULT_STAGED set [groupId _grp, [_grp, _tgtPos, _tgtSize, _tgtName]];
    diag_log format ["STAGED ASSAULT: %1 staging at %2 on bearing %3 toward %4", groupId _grp, _stagePos, round _dir, _tgtName];
    _grp
};

// Release every staged group on the current assault toward the target.
// [_tgtPos, _tgtSize, _tgtName] call MISSION_CORE_fnc_releaseStagedAssault;
MISSION_CORE_fnc_releaseStagedAssault = {
    params ["_tgtPos", "_tgtSize", ["_tgtName", ""]];
    if (isNil "MISSION_CORE_ASSAULT_STAGED") exitWith {};
    private _staged = values MISSION_CORE_ASSAULT_STAGED;
    MISSION_CORE_ASSAULT_STAGED = createHashMap;
    {
        private _grp = _x select 0;
        if (isNull _grp || { count units _grp == 0 }) then { continue; };
        _grp setVariable ["MISSION_CORE_ORDER", "counterattack"];
        [_grp, _tgtPos, _tgtSize] call MISSION_CORE_fnc_sendCounterAttack;
        diag_log format ["STAGED ASSAULT: %1 released toward %2", groupId _grp, _tgtName];
    } forEach _staged;
};