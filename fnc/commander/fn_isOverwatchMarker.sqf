
// Overwatch markers are high-ground map locations (Hill, Mount, RockArea, Strategic,
// StrongpointArea). A contested overwatch marker may only be reinforced / counter-attacked by
// other overwatch markers - no other marker can help it.
MISSION_CORE_fnc_isOverwatchMarker = {
    params ["_markerName"];
    private _owTypes = ["Hill", "Mount", "RockArea", "Strategic", "StrongpointArea"];
    private _idx = MISSION_CORE_CACHED_POSITIONS findIf { (_x select 0) == _markerName };
    if (_idx < 0) exitWith { false };
    ((MISSION_CORE_CACHED_POSITIONS select _idx) select 2) in _owTypes
};
