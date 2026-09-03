
// Count alive dynamic-replenish squads assigned to a marker. Dynamic replenish never spawns
// more than 5 alive squads per marker at a given time.
MISSION_CORE_fnc_countReplenishGroups = {
    params ["_locName"];
    if (isNil "MISSION_CORE_SPAWNED_GROUPS") exitWith { 0 };
    private _c = 0;
    {
        if (!isNull _x &&
            { _x getVariable ["MISSION_CORE_REPLENISH_GROUP", false] } &&
            { (_x getVariable ["MISSION_CORE_ORIGIN_MARKER", ""]) == _locName } &&
            { { alive _x } count units _x > 0 }) then {
            _c = _c + 1;
        };
    } forEach MISSION_CORE_SPAWNED_GROUPS;
    _c
};
