//
// Per-marker tank pool: how many MBTs a marker may field at once, computed from its
// strategic determination tier (tiers 0-1 own a pool; 2-3 field no MBTs at all) and its
// config capacity (importance -> men). The pool is the local allowance for a marker; the
// side-wide MBT cap (armorCapOpen) remains the hard ceiling on top of it.
//
// Returns the pool maximum. 0 = the marker owns no tank pool.
MISSION_CORE_fnc_markerTankPool = {
    params ["_loc"];
    private _det = [_loc] call MISSION_CORE_fnc_getMarkerDetermination;
    private _tier = _det select 0;
    if (_tier > 1) exitWith { 0 };
    private _imp = _loc select 7;
    private _capacity = [_imp] call MISSION_CORE_fnc_markerCapacity;
    private _pool = floor (_capacity / 40);
    if (_tier == 0) then { _pool = _pool + 1; };
    _pool
};

// Current MBT count "owned" by a marker: alive MBT vehicles in groups whose home center
// sits within the marker's extent. Feeds the pool check so a marker can never exceed its
// allowance at spawn AND knows when a killed tank dropped it below the pool (refill hook).
MISSION_CORE_fnc_countMBTByMarker = {
    params ["_loc"];
    private _size = if (count _loc > 8) then { _loc select 8 } else { [200, 200] };
    private _radius = ((_size select 0) max (_size select 1)) + 100;
    ([_loc select 1, _radius] call MISSION_CORE_fnc_countArmorByHome) select 0
};