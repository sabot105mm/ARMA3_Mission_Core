
MISSION_CORE_fnc_armorCapOpen = {
    params ["_side", "_slot", "_pos", "_importance"];
    if (isNil "_pos") exitWith { false };
    private _local = [_pos, 400] call MISSION_CORE_fnc_countArmorByHome;
    if (_slot == "mbt") exitWith {
        private _maxLocal = if (_importance >= 3) then { ["armorLocalMbtImp3", 2] call MISSION_CORE_fnc_tune } else { ["armorLocalMbtLo", 1] call MISSION_CORE_fnc_tune };
        if ((_local select 0) >= _maxLocal) exitWith { false };
        // Only N outposts per side may field MBT at once; a new outpost must wait
        if ((_local select 0) == 0 && { [_side] call MISSION_CORE_fnc_countArmorOutposts >= (["armorOutpostMbtMax", 2] call MISSION_CORE_fnc_tune) }) exitWith { false };
        private _globalMax = if (_side == WEST) then { getNumber (missionConfigFile >> "B_MAX_TANKS") } else { getNumber (missionConfigFile >> "O_MAX_TANKS") };
        if (_globalMax <= 0) then { _globalMax = ["armorGlobalFallback", 4] call MISSION_CORE_fnc_tune; };
        // Count REAL tank-kind vehicles of this side, not just groups with a slot flag - a tank
        // section template spawns 2 tanks in one group, and AA/arty tanks would otherwise slip
        // under the group-flag count. Parked depot reserve tanks (empty, uncrewed) are never
        // fielded armor and are excluded so the global budget only caps deployed MBTs.
        private _tanks = { alive _x && { _x isKindOf "Tank" } && { !(_x isKindOf "StaticWeapon") } && { side _x == _side } && { !(_x getVariable ["MISSION_CORE_TANK_RESERVE", false]) } } count vehicles;
        // Atomic reservation: pending spawns hold a slot (timestamped) so two concurrent loops can
        // never both pass the cap before either commits. Holds expire after 20s if a spawn dies
        // before its tank exists.
        if (isNil "MISSION_CORE_MBT_RESERVE") then { MISSION_CORE_MBT_RESERVE = createHashMap; };
        private _holds = MISSION_CORE_MBT_RESERVE getOrDefault [_side, []];
        _holds = _holds select { _x > time };
        if ((_tanks + (count _holds)) >= _globalMax) exitWith {
            MISSION_CORE_MBT_RESERVE set [_side, _holds];
            false
        };
        _holds pushBack (time + (["armorReserveHold", 20] call MISSION_CORE_fnc_tune));
        MISSION_CORE_MBT_RESERVE set [_side, _holds];
        true
    };
    // Mech/motorized infantry: max 1 per marker locally AND only 1 town per side may field it at once
    if ((_local select 1) >= 1) exitWith { false };
    if ([_side, "mech"] call MISSION_CORE_fnc_countTownCategory >= 1) exitWith { false };
    true
};
