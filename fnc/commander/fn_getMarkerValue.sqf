MISSION_CORE_fnc_getMarkerValue = {
    params ["_locName"];
    private _idx = MISSION_CORE_CACHED_POSITIONS findIf { (_x select 0) == _locName };
    if (_idx < 0) exitWith { 30 };
    private _loc = MISSION_CORE_CACHED_POSITIONS select _idx;
    private _typeName = _loc select 2;
    private _importance = _loc select 7;
    // Strategic value points per marker type (PERMANENT RULE): a Factory is worth far more
    // than an Outpost, and the HQ is the ultimate prize. Editor markers get a fixed tier;
    // auto-generated loc_* markers scale with their importance (5 -> 100).
    private _value = switch (toLower _typeName) do {
        case "hq": { 100 };
        case "airfield": { 90 };
        case "factory": { 80 };
        case "port": { 80 };
        case "base": { 75 };
        case "depot": { 70 };
        case "town": { 60 };
        case "compound": { 50 };
        case "outpost": { 30 };
        default { _importance * 20 };
    };
    _value
};