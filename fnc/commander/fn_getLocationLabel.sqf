// Human-facing label for a location: the real map name ("Kavala", "Power Plant") when known,
// otherwise the internal marker id (loc_NameCity_3 / editor marker name). Reads from the cached
// record's index 10 label captured at scan time.
MISSION_CORE_fnc_getLocationLabel = {
    params ["_locName"];
    if (isNil "MISSION_CORE_CACHED_POSITIONS") exitWith { _locName };
    private _idx = MISSION_CORE_CACHED_POSITIONS findIf { (_x select 0) == _locName };
    if (_idx < 0) exitWith { _locName };
    private _loc = MISSION_CORE_CACHED_POSITIONS select _idx;
    if (count _loc > 10) then { _loc select 10 } else { _locName }
};
