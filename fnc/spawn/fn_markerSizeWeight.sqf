//
// Marker size-weight: how much garrison a marker's footprint earns, tuned by its size AND
// its importance. Small markers spawn fewer, smaller groups; the bonus grows with AREA but
// ramps faster for HIGH-importance markers, so a vast-but-unimportant marker still fields a
// light garrison.
//
// Returns a weight 0..1 (0 = tiny/unimportant, 1 = huge + vital).
MISSION_CORE_fnc_markerSizeWeight = {
    params ["_loc"];
    private _size = if (count _loc > 8) then { _loc select 8 } else { [200, 200] };
    private _importance = _loc select 7;
    private _area = ((_size select 0) max 1) * ((_size select 1) max 1);
    private _minArea = ["sizeWeightMinArea", 20000] call MISSION_CORE_fnc_tune;
    private _maxArea = ["sizeWeightMaxArea", 250000] call MISSION_CORE_fnc_tune;
    private _areaFrac = ((_area - _minArea) / (_maxArea - _minArea)) min 1 max 0;
    private _impFloor = ["sizeWeightImpFloor", 0.2] call MISSION_CORE_fnc_tune;
    private _impCeil = ["sizeWeightImpCeil", 1.0] call MISSION_CORE_fnc_tune;
    private _impFrac = ((_importance - 1) / 4) min 1 max 0;
    private _ramp = _impFloor + (_impCeil - _impFloor) * _impFrac;
    (_areaFrac * _ramp) min 1 max 0
};

// Max squad size a marker's defenders may use, from the same size-weight: small markers keep
// their squads SHORT even when they field several; big markers reach full 12-man sections.
MISSION_CORE_fnc_markerSizeWeightMaxMen = {
    params ["_loc"];
    private _w = [_loc] call MISSION_CORE_fnc_markerSizeWeight;
    private _minMen = ["sizeWeightMinMen", 6] call MISSION_CORE_fnc_tune;
    private _maxMen = ["sizeWeightMaxMen", 12] call MISSION_CORE_fnc_tune;
    round (_minMen + (_maxMen - _minMen) * _w)
};