
MISSION_CORE_fnc_countArmorOutposts = {
    params ["_side"];
    // Killed handlers / support callbacks can report sideUnknown (or an exotic side object), so a
    // non-WEST/EAST value must be refused BEFORE the side-variable lookup rather than reaching
    // getVariable with a bad key.
    //
    // Compare the SIDE VALUE, never its string form. Two reasons:
    //  (1) "switch (str _side) { case "EAST" }" never matches - A3 stringifies the enemy side as
    //      "ENEMY" and resistance as "GUER", so every EAST call fell through to default and the
    //      function refused to count REDFOR at all (silently reporting 0 outposts).
    //  (2) getVariable [key, default] needs the key typed String, which is exactly what the flat
    //      two-branch if below produces. A NESTED if/else leaves the compiler unable to infer the
    //      String type - it reports "Error Type Any, expected String" at the getVariable call, so
    //      _sideVar is built one branch-at-a-time with a simple if. That is the same pattern the
    //      other files that build _sideVar use.
    if (_side != WEST && { _side != EAST }) exitWith {
        diag_log format ["ARMOR OUTPOSTS: countArmorOutposts refused side %1 (type %2)", _side, typeName _side];
        0
    };
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
