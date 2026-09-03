
MISSION_CORE_fnc_countTownCategory = {
    params ["_side", "_kind"];
    // Transport/civilian Killed handlers can report a non-WEST/non-EAST side - refuse those before
    // the side-variable lookup, otherwise getVariable receives a non-string name and spams errors.
    if !(_side in [WEST, EAST]) exitWith { 0 };
    private _sideVar = "MISSION_CORE_REDFOR";
    if (_side == WEST) then { _sideVar = "MISSION_CORE_BLUFOR"; };
    private _homes = [];
    if (isNil "MISSION_CORE_SPAWNED_GROUPS") exitWith { 0 };
    {
        private _grp = _x;
        if (!isNull _grp && { _grp getVariable [_sideVar, false] } && { { alive _x } count units _grp > 0 }) then {
            private _sub = _grp getVariable ["MISSION_CORE_SUBCAT", ""];
            private _slot = _grp getVariable ["MISSION_CORE_ARMOR_SLOT", ""];
            private _match = if (_kind == "mech") then { _slot == "mech" } else { _sub find "inf" == 0 };
            if (_match) then {
                private _home = _grp getVariable ["MISSION_CORE_MARKER_CENTER", [0, 0, 0]];
                if ({ _x distance _home < 400 } count _homes == 0) then { _homes pushBack _home; };
            };
        };
    } forEach MISSION_CORE_SPAWNED_GROUPS;
    count _homes
};
