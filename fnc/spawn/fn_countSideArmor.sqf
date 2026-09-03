
MISSION_CORE_fnc_countSideArmor = {
    params ["_side"];
    private _sideVar = if (_side == WEST) then { "MISSION_CORE_BLUFOR" } else { "MISSION_CORE_REDFOR" };
    private _mbt = 0;
    private _mech = 0;
    if (isNil "MISSION_CORE_SPAWNED_GROUPS") exitWith { [0, 0] };
    {
        private _grp = _x;
        if (!isNull _grp && { _grp getVariable [_sideVar, false] }) then {
            private _slot = _grp getVariable ["MISSION_CORE_ARMOR_SLOT", ""];
            private _isAA = _grp getVariable ["MISSION_CORE_AA_DEFENSE", false];
            if (_slot != "" || _isAA) then {
                private _vehs = [];
                {
                    private _v = vehicle _x;
                    if (_v != _x && { alive _v } && { !(_v in _vehs) }) then { _vehs pushBack _v; };
                } forEach units _grp;
                if (_slot == "mbt" || (_slot == "" && _isAA)) then { _mbt = _mbt + count _vehs; } else { _mech = _mech + count _vehs; };
            };
        };
    } forEach MISSION_CORE_SPAWNED_GROUPS;
    [_mbt, _mech]
};
