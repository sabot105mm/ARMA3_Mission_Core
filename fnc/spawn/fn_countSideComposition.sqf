
// Global foot/mech composition count for a side: returns [aa, at, weapons, inf] - the number of
// alive foot or mech (non-tank) groups per role. Tanks/APC-only armor are excluded. Used to
// enforce "max 1 AA team, 4 AT teams, 2 weapons squads, the rest riflemen" per side.
MISSION_CORE_fnc_countSideComposition = {
    params ["_side"];
    if (isNil "MISSION_CORE_SPAWNED_GROUPS") exitWith { [0, 0, 0, 0] };
    private _sideVar = if (_side == WEST) then { "MISSION_CORE_BLUFOR" } else { "MISSION_CORE_REDFOR" };
    private _out = [0, 0, 0, 0];
    {
        private _grp = _x;
        if (!isNull _grp && { _grp getVariable [_sideVar, false] } && { { alive _x } count units _grp > 0 }) then {
            private _sub = _grp getVariable ["MISSION_CORE_SUBCAT", ""];
            if (_sub == "") then { continue; };
            if (_sub find "tank" == 0) then { continue; };
            private _idx = -1;
            if (_sub find "_aa" > -1) then { _idx = 0; }
            else {
                if (_sub find "_at" > -1) then { _idx = 1; }
                else {
                    if (_sub == "inf_weapons") then { _idx = 2; }
                    else {
                        if (_sub == "inf") then { _idx = 3; };
                    };
                };
            };
            if (_idx >= 0) then { _out set [_idx, (_out select _idx) + 1]; };
        };
    } forEach MISSION_CORE_SPAWNED_GROUPS;
    _out
};
