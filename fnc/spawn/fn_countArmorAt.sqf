
MISSION_CORE_fnc_countArmorAt = {
    params ["_pos", "_radius"];
    private _mbt = 0;
    private _mech = 0;
    if (isNil "MISSION_CORE_SPAWNED_GROUPS") exitWith { [0, 0] };
    {
        private _grp = _x;
        if (!isNull _grp && { count units _grp > 0 }) then {
            private _slot = _grp getVariable ["MISSION_CORE_ARMOR_SLOT", ""];
            if (_slot != "" && { (leader _grp) distance _pos < _radius }) then {
                private _vehs = [];
                {
                    private _v = vehicle _x;
                    if (_v != _x && { alive _v } && { !(_v in _vehs) }) then { _vehs pushBack _v; };
                } forEach units _grp;
                if (_slot == "mbt") then { _mbt = _mbt + count _vehs; } else { _mech = _mech + count _vehs; };
            };
        };
    } forEach MISSION_CORE_SPAWNED_GROUPS;
    [_mbt, _mech]
};
