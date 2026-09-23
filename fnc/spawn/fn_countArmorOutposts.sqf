
MISSION_CORE_fnc_countArmorOutposts = {
    params ["_side"];
    // Killed handlers / support callbacks can report sideUnknown (or an exotic side object) - the
    // side-variable lookup must never receive a non-string name. Derive it via STRING comparison
    // with a guaranteed "" default, so a non-WEST/EAST value exits BEFORE the loop (and is logged)
    // instead of ever reaching getVariable with a bad key.
    private _sideVar = switch (str _side) do {
        case "WEST": { "MISSION_CORE_BLUFOR" };
        case "EAST": { "MISSION_CORE_REDFOR" };
        default { "" };
    };
    if (_sideVar == "") exitWith {
        diag_log format ["ARMOR OUTPOSTS: countArmorOutposts refused side %1 (type %2)", _side, typeName _side];
        0
    };
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
