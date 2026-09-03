
// Count the living INITIAL garrison of a marker: alive units in spawned groups whose ORIGIN_MARKER
// name matches this marker, that are NOT replenish groups, and whose leader is still physically
// within 600m. Using the exact origin NAME (not a center-distance test) means two markers that sit
// within 600m of each other never cross-count each other's garrison.
MISSION_CORE_fnc_countInitialGarrison = {
    params ["_locName", "_locPos", "_side"];
    if (isNil "MISSION_CORE_SPAWNED_GROUPS") exitWith { 0 };
    private _sideVar = "MISSION_CORE_REDFOR";
    if (_side == WEST) then { _sideVar = "MISSION_CORE_BLUFOR"; };
    private _alive = 0;
    {
        private _ldr = if (!isNull _x) then { leader _x } else { objNull };
        if (!isNull _x &&
            { _x getVariable [_sideVar, false] } &&
            { !(_x getVariable ["MISSION_CORE_REPLENISH_GROUP", false]) } &&
            { (_x getVariable ["MISSION_CORE_ORIGIN_MARKER", ""]) == _locName } &&
            { !isNull _ldr } &&
            { _ldr distance2D _locPos < 600 }) then {
            _alive = _alive + ({ alive _x } count units _x);
        };
    } forEach MISSION_CORE_SPAWNED_GROUPS;
    _alive
};
