
// Assemble an attack force when a marker decides to attack: free the cap, then ensure
// up to 2 tank markers (MBT + mech + 2 foot inf squads) and 1 infantry marker (3 squads)
MISSION_CORE_fnc_assembleAssault = {
    params ["_side", "_originPos", "_targetPos", "_importance", ["_originName", ""]];
    private _sideVar = if (_side == WEST) then { "MISSION_CORE_BLUFOR" } else { "MISSION_CORE_REDFOR" };
    private _factionData = if (_side == WEST) then { MISSION_CORE_BLUFOR_DATA } else { MISSION_CORE_REDFOR_DATA };
    private _allGroups = _factionData select 17;
    private _faction = _factionData select 3;
    if (isNil "MISSION_CORE_SPAWNED_GROUPS") then { MISSION_CORE_SPAWNED_GROUPS = []; };

    // Free the cap and pull kept armor into the attack
    [_side, _targetPos, 800] call MISSION_CORE_fnc_despawnOverwatchTanks;

    // Count existing usable forces near the origin (kept armor + standing infantry)
    private _existingMBT = 0;
    private _existingMech = 0;
    private _existingInf = 0;
    {
        if (_x getVariable [_sideVar, false] && { count units _x > 0 } && { !(_x getVariable ["MISSION_CORE_DEFENSE_GROUP", false]) }) then {
            if ((leader _x) distance _originPos < 1500) then {
                if (_x getVariable ["MISSION_CORE_AA_TANK", false] || { (_x getVariable ["MISSION_CORE_ARMOR_SLOT", ""]) == "mbt" }) then {
                    _existingMBT = _existingMBT + 1;
                } else {
                    if (_x getVariable ["MISSION_CORE_ARMOR_SLOT", ""] == "mech") then {
                        _existingMech = _existingMech + 1;
                    } else {
                        if (_x getVariable ["MISSION_CORE_ORDER", ""] == "attack" || { (_x getVariable ["MISSION_CORE_SUBCAT", ""]) find "inf" == 0 }) then { _existingInf = _existingInf + 1; };
                    };
                };
            };
        };
    } forEach MISSION_CORE_SPAWNED_GROUPS;

    private _mbtTemplates = _allGroups select { (_x select 3) find "tank" > -1 && { (_x select 3) find "_aa" == -1 } && { ({ !(_x isKindOf "Man") } count (_x select 1)) <= 2 } };
    private _mechTemplates = _allGroups select { (_x select 3) == "mech" && { ({ !(_x isKindOf "Man") } count (_x select 1)) <= 2 } };
    // Foot infantry: proper CfgGroups infantry squads first, all-men combat groups as last resort
    private _infTemplates = [_allGroups] call MISSION_CORE_fnc_getInfTemplates;

    private _spawned = 0;
    // Up to 2 tank markers: MBT each
    private _targetMBT = 2;
    while { _existingMBT < _targetMBT && count _mbtTemplates > 0 } do {
        if ([_side, "mbt", _originPos, _importance] call MISSION_CORE_fnc_armorCapOpen) then {
            if (isNull ([_mbtTemplates, _side, _faction, _importance, _originPos, _targetPos, _originName] call MISSION_CORE_fnc_spawnAssaultGroup)) then { break; };
            _existingMBT = _existingMBT + 1;
            _spawned = _spawned + 1;
            sleep 0.4;
        } else { break; };
    };
    // Each tank marker carries 1 mech; +1 so combined-arms (mech+inf) outweighs MBT armor ~3:1
    private _targetMech = _targetMBT + 1;
    while { _existingMech < _targetMech && count _mechTemplates > 0 } do {
        if ([_side, "mech", _originPos, _importance] call MISSION_CORE_fnc_armorCapOpen) then {
            if (isNull ([_mechTemplates, _side, _faction, _importance, _originPos, _targetPos, _originName] call MISSION_CORE_fnc_spawnAssaultGroup)) then { break; };
            _existingMech = _existingMech + 1;
            _spawned = _spawned + 1;
            sleep 0.4;
        } else { break; };
    };
    // 1 infantry marker: 3 foot inf squads
    private _targetInf = 3;
    while { _existingInf < _targetInf && count _infTemplates > 0 } do {
        if (isNull ([_infTemplates, _side, _faction, _importance, _originPos, _targetPos, _originName] call MISSION_CORE_fnc_spawnAssaultGroup)) then { break; };
        _existingInf = _existingInf + 1;
        _spawned = _spawned + 1;
        sleep 0.4;
    };
    diag_log format ["AI COMMANDER: %1 assault from %2 vs %3 -> mbt=%4 mech=%5 inf=%6 spawned=%7", _side, _originPos, _targetPos, _existingMBT, _existingMech, _existingInf, _spawned];
    // 5s gap after the assault force finishes assembling before the next spawn burst
    if (_spawned > 0) then { sleep 5; };
};
