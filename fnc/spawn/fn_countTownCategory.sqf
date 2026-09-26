
MISSION_CORE_fnc_countTownCategory = {
    params ["_side", "_kind"];
    // Killed handlers / support callbacks can report sideUnknown (or an exotic side object), so a
    // non-WEST/EAST value must be refused BEFORE the side-variable lookup rather than reaching
    // getVariable with a bad key.
    //
    // Compare the SIDE VALUE, never its string form. Two reasons:
    //  (1) "switch (str _side) { case "EAST" }" never matches - A3 stringifies the enemy side as
    //      "ENEMY" and resistance as "GUER", so every EAST call fell through to default and the
    //      function refused to count REDFOR at all (silently reporting 0 outposts).
    //  (2) A switch-derived variable is typed Any by the compiler. getVariable then fails to
    //      resolve its [name, default] overload, falls back to the String-only form, and the
    //      whole function fails to compile: "Error Type Any, expected String". An
    //      if/then/else of string literals is inferred as String, which is what the 18 other
    //      files in this mission that build _sideVar do.
    private _sideVar = if (_side == WEST) then { "MISSION_CORE_BLUFOR" } else {
        if (_side == EAST) then { "MISSION_CORE_REDFOR" } else { "" }
    };
    if (_sideVar == "") exitWith {
        diag_log format ["ARMOR OUTPOSTS: countTownCategory refused side %1 (type %2)", _side, typeName _side];
        0
    };
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
