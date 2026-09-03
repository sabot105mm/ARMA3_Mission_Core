
// Count the living garrison of a marker by its ORIGIN name (not center distance), so two markers
// that sit within 600m of each other never cross-count each other's units.
MISSION_CORE_fnc_countMarkerGarrison = {
    params ["_locName", "_side"];
    if (isNil "MISSION_CORE_SPAWNED_GROUPS") exitWith { 0 };
    private _sideVar = "MISSION_CORE_REDFOR";
    if (_side == WEST) then { _sideVar = "MISSION_CORE_BLUFOR"; };
    private _alive = 0;
    {
        if (!isNull _x && { _x getVariable [_sideVar, false] } && { (_x getVariable ["MISSION_CORE_ORIGIN_MARKER", ""]) == _locName }) then {
            _alive = _alive + ({ alive _x } count units _x);
        };
    } forEach MISSION_CORE_SPAWNED_GROUPS;
    _alive
};
