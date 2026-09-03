
// Spawn a single group for the assault force and order it to attack the target
MISSION_CORE_fnc_spawnAssaultGroup = {
    params ["_templates", "_side", "_faction", "_importance", "_originPos", "_targetPos", ["_originName", ""]];
    if (count _templates == 0) exitWith { grpNull };
    private _tmpl = selectRandom _templates;
    private _spawnPos = [_originPos, [200, 200], 20, random 360] call MISSION_CORE_fnc_findVehiclePos;
    private _grp = [(_tmpl select 0), _spawnPos, _side, _faction, "AWARE", "FULL", _importance, _originPos, [200, 200]] call MISSION_CORE_fnc_spawnGroup;
    if (isNull _grp) exitWith { grpNull };
    _grp setVariable ["MISSION_CORE_ORDER", "attack"];
    _grp setVariable ["MISSION_CORE_IDLE", false];
    _grp setVariable ["MISSION_CORE_ORIGIN_MARKER", _originName];
    leader _grp setVariable ["MISSION_CORE_PATROLLING", false];
    private _subCat = _tmpl select 3;
    if (_subCat find "tank" > -1 && { _subCat find "_aa" == -1 }) then {
        _grp setVariable ["MISSION_CORE_ARMOR_SLOT", "mbt"];
        {
            private _v = vehicle _x;
            if (_v != _x && { _v isKindOf "Tank" }) then {
                _v setVariable ["MISSION_CORE_REINF_TARGET", _targetPos];
                _v addEventHandler ["Killed", {
                    params ["_kv"];
                    private _s = _side;
                    private _t = _kv getVariable ["MISSION_CORE_REINF_TARGET", [0, 0, 0]];
                    private _l = getPos _kv call MISSION_CORE_fnc_getLocByPos;
                    private _n = if (count _l > 0) then { _l select 0 } else { "" };
                    [_s, _t, _n] call MISSION_CORE_fnc_requestArmorReinforcement;
                }];
            };
        } forEach units _grp;
    };
    if (_subCat == "mech") then {
        _grp setVariable ["MISSION_CORE_ARMOR_SLOT", "mech"];
        {
            private _v = vehicle _x;
            if (_v != _x && { _v isKindOf "Wheeled_APC" || _v isKindOf "Tracked_APC" }) then {
                _v setVariable ["MISSION_CORE_REINF_TARGET", _targetPos];
                _v addEventHandler ["Killed", {
                    params ["_kv"];
                    private _s = _side;
                    private _t = _kv getVariable ["MISSION_CORE_REINF_TARGET", [0, 0, 0]];
                    private _l = getPos _kv call MISSION_CORE_fnc_getLocByPos;
                    private _n = if (count _l > 0) then { _l select 0 } else { "" };
                    [_s, _t, _n] call MISSION_CORE_fnc_requestArmorReinforcement;
                }];
            };
        } forEach units _grp;
    };
    // Motorized infantry: load foot squads into a side cargo truck so they drive to the attack zone
    if (_subCat find "inf" == 0) then {
        [_grp, _side, _spawnPos] call MISSION_CORE_fnc_mountInfantry;
    };
    [_grp] call MISSION_CORE_fnc_clearGroupWaypoints;
    // Unified assault: one MOVE (or GETOUT for truck-mounted foot squads) to the confidence-driven
    // advance point, then one SAD at the target center. Dismounted foot troops split into their own
    // group and lose ownership of the transport. Armor spawns engage (YELLOW) but not engage-at-will.
    private _assaultCombat = if (_subCat find "tank" > -1 || _subCat == "mech") then { "YELLOW" } else { "RED" };
    [_grp, _targetPos, [50, 50], _assaultCombat] call MISSION_CORE_fnc_sendCounterAttack;
    MISSION_CORE_SPAWNED_GROUPS pushBack _grp;
    _grp
};
