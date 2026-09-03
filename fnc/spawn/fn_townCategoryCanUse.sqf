
// True when a town may field/spawn this category: the side is under the cap, OR the town is
// ALREADY one of the counted towns. Refilling an existing garrison never adds a town to the cap,
// so a town holding infantry can always replenish its own losses even when 3 towns are fielding.
MISSION_CORE_fnc_townCategoryCanUse = {
    params ["_side", "_kind", "_home"];
    // Refuse non-WEST/non-EAST sides (transport/civilian Killed handlers can report them) before the
    // side-variable lookup, so getVariable never receives a non-string name.
    if !(_side in [WEST, EAST]) exitWith { true };
    if (isNil "MISSION_CORE_SPAWNED_GROUPS") exitWith { true };
    private _cap = if (_kind == "mech") then { 1 } else { 5 };
    private _sideVar = "MISSION_CORE_REDFOR";
    if (_side == WEST) then { _sideVar = "MISSION_CORE_BLUFOR"; };
    private _homes = [];
    {
        private _grp = _x;
        if (!isNull _grp && { _grp getVariable [_sideVar, false] } && { { alive _x } count units _grp > 0 }) then {
            private _sub = _grp getVariable ["MISSION_CORE_SUBCAT", ""];
            private _slot = _grp getVariable ["MISSION_CORE_ARMOR_SLOT", ""];
            private _match = if (_kind == "mech") then { _slot == "mech" } else { _sub find "inf" == 0 };
            if (_match) then {
                private _h = _grp getVariable ["MISSION_CORE_MARKER_CENTER", [0, 0, 0]];
                if ({ _x distance _h < 400 } count _homes == 0) then { _homes pushBack _h; };
            };
        };
    } forEach MISSION_CORE_SPAWNED_GROUPS;
    (count _homes < _cap) || { { _x distance _home < 400 } count _homes > 0 }
};
