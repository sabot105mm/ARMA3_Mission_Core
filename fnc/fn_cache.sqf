MISSION_CORE_fnc_initLocationTypes = {
    private _cfg = configFile >> "CfgLocationTypes";
    private _names = [];
    for "_i" from 0 to (count _cfg - 1) do {
        private _entry = _cfg select _i;
        private _cn = configName _entry;
        if (isText (_entry >> "name")) then { _names pushBack _cn; };
    };
    MISSION_CORE_LOCATION_TYPES = _names;
    diag_log format ["DYNAMIC CACHE: loaded %1 location types from CfgLocationTypes", count _names];
};

MISSION_CORE_fnc_cacheTerrain = {
    private _locations = _this;
    private _cached = [];
    {
        private _loc = _x;
        private _markerName = _loc select 0;
        private _typeName = _loc select 2;
        private _priority = _loc select 4;
        private _owner = _loc select 5;
        private _pos = getMarkerPos _markerName;
        private _size = getMarkerSize _markerName;
        private _a = _size select 0;
        private _b = _size select 1;
        private _importance = _loc select 7;
        private _validPositions = [];
        private _step = 25;
        for "_x" from (_pos select 0) - _a to (_pos select 0) + _a step _step do {
            for "_y" from (_pos select 1) - _b to (_pos select 1) + _b step _step do {
                private _testPos = [_x, _y, 0];
                private _dx = _x - (_pos select 0);
                private _dy = _y - (_pos select 1);
                private _cos = cos 0;
                private _sin = sin 0;
                private _rx = _dx * _cos + _dy * _sin;
                private _ry = -_dx * _sin + _dy * _cos;
                if ((_rx*_rx)/(_a*_a) + (_ry*_ry)/(_b*_b) <= 1) then {
                    if (([_testPos] call MISSION_CORE_fnc_checkFlat) > 0.85) then {
                        private _hasPOI = [_testPos] call MISSION_CORE_fnc_checkPOI;
                        private _elevated = [_testPos] call MISSION_CORE_fnc_checkElevated;
                        if (_hasPOI || _elevated) then { _validPositions pushBack [_testPos, _hasPOI, _elevated]; };
                    };
                };
            };
        };
        _validPositions sortWith { (_x select 0) distance _pos < (_y select 0) distance _pos };
        private _defense = _validPositions select { _x select 1 } apply { _x select 0 };
        private _ambush = _validPositions select { _x select 2 } apply { _x select 0 };
        _cached pushBack [_markerName, _pos, _typeName, _priority, _owner, _defense, _ambush, _importance];
    } forEach _locations;
    MISSION_CORE_CACHED_POSITIONS = _cached;
    _cached
};

MISSION_CORE_fnc_checkFlat = {
    private _pos = _this select 0;
    private _flatCount = 0;
    for "_i" from 0 to 8 do {
        private _check = _pos getPos [10, (_i / 9) * 360];
        if ((abs ((_check select 2) - (_pos select 2))) < 1.5) then { _flatCount = _flatCount + 1; };
    };
    _flatCount / 9
};

MISSION_CORE_fnc_checkPOI = {
    private _pos = _this select 0;
    private _roads = nearestTerrainObjects [_pos, ["ROAD"], 300];
    private _towns = nearestLocations [_pos, MISSION_CORE_LOCATION_TYPES, 500];
    (count _roads > 0) || (count _towns > 0)
};

MISSION_CORE_fnc_checkElevated = {
    private _pos = _this select 0;
    private _roads = nearestTerrainObjects [_pos, ["ROAD"], 400];
    if (count _roads == 0) exitWith { false };
    private _road = _roads select 0;
    private _center = getPos _road;
    (_pos select 2) > (_center select 2) + 5
};