
MISSION_CORE_fnc_countArmorOutposts = {
    params ["_side"];
    // Killed handlers / support callbacks can report sideUnknown - refuse it before the side-variable
    // lookup so getVariable never receives a non-string name.
    if !(_side in [WEST, EAST]) exitWith { 0 };
    private _sideVar = if (_side == WEST) then { "MISSION_CORE_BLUFOR" } else { "MISSION_CORE_REDFOR" };
    private _homes = [];
    if (isNil "MISSION_CORE_SPAWNED_GROUPS") exitWith { 0 };
    {
        private _grp = _x;
        if (!isNull _grp && { _grp getVariable [_sideVar, false] }) then {
            private _slot = _grp getVariable ["MISSION_CORE_ARMOR_SLOT", ""];
            if (_slot == "mbt") then {
                private _home = _grp getVariable ["MISSION_CORE_MARKER_CENTER", [0, 0, 0]];
                if ({ _x distance _home < 400 } count _homes == 0) then {
                    private _aliveVeh = false;
                    {
                        private _v = vehicle _x;
                        if (_v != _x && { alive _v }) exitWith { _aliveVeh = true; };
                    } forEach units _grp;
                    if (_aliveVeh) then { _homes pushBack _home; };
                };
            };
        };
    } forEach MISSION_CORE_SPAWNED_GROUPS;
    count _homes
};
