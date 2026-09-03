
// Count alive foot (infantry) manpower for ONE side as a WEIGHTED squad count, hard-capped at 10
// per side by the callers. A "foot" group has no armor slot and is not tank/mech - men riding a
// transport truck still count, so the cap can't be bypassed by mounting everyone.
//
// The budget is MEN, not group count: 1.0 squad = 6 men (10 full squads = 60 men). A full 8-man
// squad counts ~1.33, a 3-man sentry counts 0.5, so the AI can field MANY more small sentries up
// to the same total manpower a set of full squads would have used.
MISSION_CORE_fnc_countFootSquads = {
    params ["_side"];
    private _sideVar = if (_side == WEST) then { "MISSION_CORE_BLUFOR" } else { "MISSION_CORE_REDFOR" };
    if (isNil "MISSION_CORE_SPAWNED_GROUPS") exitWith { 0 };
    private _c = 0;
    {
        if (!isNull _x && { count units _x > 0 }) then {
            if (_x getVariable [_sideVar, false]) then {
                private _slot = _x getVariable ["MISSION_CORE_ARMOR_SLOT", ""];
                private _sub = _x getVariable ["MISSION_CORE_SUBCAT", ""];
                if (_slot == "" && { _sub find "tank" == -1 } && { _sub != "mech" }) then {
                    private _alive = { alive _x } count units _x;
                    _c = _c + (_alive / (["footSquadRefMen", 6] call MISSION_CORE_fnc_tune));   // 6-man squad reference weight
                };
            };
        };
    } forEach MISSION_CORE_SPAWNED_GROUPS;
    _c
};
