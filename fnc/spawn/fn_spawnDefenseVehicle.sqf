
MISSION_CORE_fnc_spawnDefenseVehicle = {
    params ["_side", "_vehClass", "_vehSlot", "_pos", "_angle", "_importance", "_targetPos"];
    if (_vehClass == "") exitWith { grpNull };
    if !([_side, _vehSlot, _targetPos, _importance] call MISSION_CORE_fnc_armorCapOpen) exitWith { grpNull };
    _pos = [_pos, 0, 100, 10, 0, 0.5, 0] call BIS_fnc_findSafePos;
    if (count _pos < 2) then { _pos = [_pos] call MISSION_CORE_fnc_ensureLandPos; };
    if (count _pos == 2) then { _pos pushBack 0; };
    private _crewClass = if (_side == WEST) then { "B_crew_F" } else { "O_crew_F" };
    private _veh = createVehicle [_vehClass, [_pos] call MISSION_CORE_fnc_liftSpawn, [], 5, "CAN_COLLIDE"];
    _veh setVariable ["MISSION_CORE_REINF_TARGET", _targetPos];
    _veh addEventHandler ["Killed", {
        params ["_v"];
        private _s = _side;
        private _t = _v getVariable ["MISSION_CORE_REINF_TARGET", [0, 0, 0]];
        private _l = getPos _v call MISSION_CORE_fnc_getLocByPos;
        private _n = if (count _l > 0) then { _l select 0 } else { "" };
        [_s, _t, _n] call MISSION_CORE_fnc_requestArmorReinforcement;
    }];
    private _grp = createGroup _side;
    _grp addVehicle _veh;
    private _vehCrew = [];
    for "_c" from 1 to 3 do {
        private _crew = _grp createUnit [_crewClass, _pos, [], 0, "NONE"];
        _crew addMPEventHandler ["MPHit", { _this call MISSION_CORE_fnc_onSuppressed; }];
        _vehCrew pushBack _crew;
    };
    _vehCrew params [["_d", objNull], ["_g", objNull], ["_c", objNull]];
    if (!isNull _d && isNull (driver _veh)) then { _d moveInDriver _veh; };
    if (!isNull _g && isNull (gunner _veh)) then { _g moveInGunner _veh; };
    if (!isNull _c && isNull (commander _veh)) then { _c moveInCommander _veh; };
    _veh setDir (_angle + 180);
    _grp setBehaviour "SAFE";
    _grp setCombatMode "RED";
    private _isBLU = if (_side == WEST) then { "BLUFOR" } else { "REDFOR" };
    _grp setVariable [format ["MISSION_CORE_%1", _isBLU], true];
    _grp setVariable ["MISSION_CORE_DEFENSE_GROUP", true];
    _grp setVariable ["MISSION_CORE_MARKER_CENTER", _targetPos];
    _grp setVariable ["MISSION_CORE_IDLE", false];
    _grp setVariable ["MISSION_CORE_ORDER", "defend"];
    _grp setVariable ["MISSION_CORE_IMPORTANCE", _importance];
    if (_vehSlot == "mbt" || _vehSlot == "mech") then { _grp setVariable ["MISSION_CORE_ARMOR_SLOT", _vehSlot]; };
    if (isNil "MISSION_CORE_SPAWNED_GROUPS") then { MISSION_CORE_SPAWNED_GROUPS = []; };
    MISSION_CORE_SPAWNED_GROUPS pushBack _grp;
    [_veh, _grp, _side] call MISSION_CORE_fnc_guardSpawnKill;
    _grp
};
