MISSION_CORE_fnc_generateLocationMarkers = {
    private _worldCfg = configFile >> "CfgWorlds" >> worldName >> "Names";
    // Existing editor markers: check against their actual ellipse (center + size + dir), not just
    // their center point - a big BLUFOR marker must never have a dynamic loc_* marker generated
    // inside it. The 60m margin keeps a dynamic marker's own small spawn footprint out too.
    private _existingMarkers = allMapMarkers apply {
        [_x, getMarkerPos _x, getMarkerSize _x, markerDir _x]
    };
    private _created = 0;
    private _skipped = 0;
    for "_i" from 0 to (count _worldCfg - 1) do {
        private _entry = _worldCfg select _i;
        private _name = configName _entry;
        private _type = getText (_entry >> "type");
        private _pos = getArray (_entry >> "position");
        private _radiusA = getNumber (_entry >> "radiusA");
        private _radiusB = getNumber (_entry >> "radiusB");
        private _angle = getNumber (_entry >> "angle");
        if (_radiusA == 0) then { _radiusA = 100; };
        if (_radiusB == 0) then { _radiusB = 100; };
        if (count _pos >= 2 && _type != "") then {
            // Skip water locations - never create dynamic markers out at sea (PERMANENT RULE)
            if (surfaceIsWater [_pos select 0, _pos select 1]) then { _skipped = _skipped + 1; continue; };
            // Only land locations get markers, and those markers follow the land orientation
            // (the CfgWorlds angle rotates the ellipse to match the coastline/terrain) (PERMANENT RULE)
            // Skip if this location's footprint overlaps any existing editor marker (BLUFOR included)
            private _skip = [_pos, _radiusA, _radiusB, _angle] call MISSION_CORE_fnc_ellipseOverlapsMarkers;
            if (_skip) then { _skipped = _skipped + 1; };
            if (!_skip) then {
                private _markerName = format ["loc_%1_%2", _type, _created];
                private _mkr = createMarker [_markerName, _pos];
                _mkr setMarkerShape "ELLIPSE";
                _mkr setMarkerSize [_radiusA, _radiusB];
                _mkr setMarkerBrush "SolidBorder";
                _mkr setMarkerColor "ColorGrey";
                _mkr setMarkerAlpha 0;
                _mkr setMarkerDir _angle;
                // Keep the REAL map-facing label (e.g. "Kavala", "Power Plant") in a side-wide
                // map so scanMarkers reads it back for assault logs / broadcasts instead of the
                // internal "loc_NameCity_3" id. Markers are plain names (no setVariable), so the
                // label lives in a hashmap keyed by marker name. Falls back to the config key if
                // a location carries no display name.
                if (isNil "MISSION_CORE_LOC_LABELS") then { MISSION_CORE_LOC_LABELS = createHashMap; };
                private _mapLabel = getText (_entry >> "name");
                if (_mapLabel == "") then { _mapLabel = _name; };
                MISSION_CORE_LOC_LABELS set [_markerName, _mapLabel];
                _created = _created + 1;
            };
        };
    };
    diag_log format ["DYNAMIC MARKER: auto-generated %1, skipped %2 (near editor markers) from %3", _created, _skipped, worldName];
};

// True when the candidate ellipse (center, half-axes, dir) overlaps ANY existing editor marker's
// actual area (center + size + dir accounted for). Used so auto-generated dynamic loc_* markers
// never spawn inside a BLUFOR marker the user placed in the editor - a point-inside check with the
// existing marker's own radius is the key fix (a big marker would swallow points near its center
// that are nowhere near its center coordinate). Ellipse-over-ellipse overlap is detected by
// sampling the candidate's rim.
MISSION_CORE_fnc_ellipseOverlapsMarkers = {
    params ["_pos", "_rA", "_rB", "_dir", ["_margin", 60]];
    // Point-in-rotated-ellipse test
    private _inEllipse = {
        params ["_p", "_ePos", "_eA", "_eB", "_eDir"];
        private _dx = (_p select 0) - (_ePos select 0);
        private _dy = (_p select 1) - (_ePos select 1);
        private _rx = _dx * cos _eDir - _dy * sin _eDir;
        private _ry = _dx * sin _eDir + _dy * cos _eDir;
        ((_rx * _rx) / (_eA * _eA) + (_ry * _ry) / (_eB * _eB)) <= 1
    };
    private _hit = false;
    // Sample points along the candidate's rim and test each against every existing editor marker.
    // If any rim point is inside a marker, the areas overlap.
    {
        private _eMkr = _x;
        private _ePos = _eMkr param [1, [0, 0, 0]];
        if (count _ePos < 2) then { continue; };
        private _eSize = _eMkr param [2, [100, 100]];
        private _eA = (_eSize param [0, 100]) + _margin;
        private _eB = (_eSize param [1, 100]) + _margin;
        private _eDir = _eMkr param [3, 0];
        // Fast reject: candidate center is inside the existing marker (covers most big-marker cases)
        if ([_pos, _ePos, _eA, _eB, _eDir] call _inEllipse) exitWith { _hit = true; };
        // Rim-sample the candidate against this marker, walking the ACTUAL rotated ellipse edge
        // (radius at angle t of an ellipse of half-axes _rA,_rB, then rotated by candidate _dir).
        for "_i" from 0 to 15 do {
            private _t = (_i / 16) * 360;
            private _rad = (_rA max _rB) * (_rA min _rB) /
                sqrt (((_rB * cos _t) ^ 2) + ((_rA * sin _t) ^ 2));
            private _dirT = _t + _dir;
            private _p = _pos getPos [_rad, _dirT];
            if ([_p, _ePos, _eA, _eB, _eDir] call _inEllipse) exitWith { _hit = true; };
        };
        if (_hit) exitWith {};
    } forEach _existingMarkers;
    _hit
};

MISSION_CORE_fnc_getLocationImportance = {
    params ["_pos", "_typeName"];
    // PERMANENT RULE: an Outpost is a very small garrison - always importance 1, never boosted
    // by the terrain tier around it (an outpost inside a city zone sweeps up imp 5 otherwise).
    if (toLower _typeName == "outpost") exitWith { 1 };
    private _tiers = [
        [5, ["NameCityCapital", "NameCity", "NameVillage", "NameLocal", "NameMarine", "Mount", "CityCenter"]],
        [4, ["Airport", "Area", "BorderCrossing"]],
        [3, ["Hill", "HistoricalSite", "RockArea", "SafetyZone"]],
        [2, ["Strategic", "StrongpointArea"]]
    ];
    {
        _x params ["_tier", "_types"];
        private _locs = nearestLocations [_pos, _types, 800];
        if (count _locs > 0) exitWith { _tier };
    } forEach _tiers;

    // Airport detection: check for runways if CfgLocationTypes didn't match
    private _runways = nearestTerrainObjects [_pos, ["RUNWAY"], 600];
    if (count _runways > 0) exitWith { 4 };

    // Marker type itself boosts importance: Airfield/Base/HQ = 4, Factory/Compound/Town = 3
    // A Powerplant is captured for the tank economy - Factory-tier importance (light garrison,
    // contested objective). A Solar gets a lighter tier (smaller contribution to production).
    private _typeBoost = switch (toLower _typeName) do {
        case "airfield": { 4 };
        case "base": { 4 };
        case "hq": { 5 };
        case "factory": { 3 };
        case "port": { 3 };
        case "compound": { 3 };
        case "town": { 3 };
        case "powerplant": { 3 };
        case "solar": { 2 };
        default { 1 };
    };
    _typeBoost
};

// Light-infrastructure markers (Outpost, Powerplant, Solar): a very small garrison that fields
// NO hunt orders, NO quadrant engagement and NO static defenses (MG bunkers/emplacements).
// Everything else about the marker (capture, value, light infantry garrison) still functions.
MISSION_CORE_fnc_isLightInfrastructure = {
    params ["_loc"];
    if (isNil "_loc" || count _loc < 3) exitWith { false };
    private _t = toLower (_loc select 2);
    (_t == "outpost" || _t == "powerplant" || _t == "solar")
};

MISSION_CORE_fnc_scanMarkers = {
    private _locationTypes = missionConfigFile >> "LOCATION_TYPES";
    private _allMarkers = allMapMarkers;
    private _results = [];

    // The player's spawn position: only an HQ marker that CONTAINS this position is the player's
    // own (WEST). Every other correctly-named editor marker is enemy territory (EAST) - the
    // framework never assumes a marker belongs to the player just because it is named right
    // (PERMANENT RULE).
    private _playerStartPos = if (isMultiplayer) then {
        private _p = allPlayers select { alive _x };
        if (count _p > 0) then { getPos (_p select 0) } else { [0,0,0] };
    } else {
        if (isNull player) then { [0,0,0] } else { getPos player };
    };

    // Process manually placed markers from description.ext LOCATION_TYPES
    for "_i" from 0 to (count _locationTypes - 1) do {
        private _type = _locationTypes select _i;
        private _prefix = getText (_type >> "prefix");
        private _typeName = getText (_type >> "type");
        private _priority = getNumber (_type >> "priority");

        private _markers = _allMarkers select { toLower _x find _prefix == 0 };
        // A bare editor marker whose name equals the type's base prefix (e.g. "outpost" from
        // prefix "outpost_") is still that location type - the prefix scan only matches the
        // suffixed "_N" markers against the trailing-underscore prefix.
        private _base = _prefix select [0, ((count _prefix) - 1)];
        if ((_typeName in ["Outpost", "Powerplant", "Solar"]) && { _base != "" }) then {
            _markers = _allMarkers select { toLower _x find _prefix == 0 || { toLower _x == _base } };
        };

        {
            private _mkr = _x;
            private _pos = getMarkerPos _mkr;
            private _size = getMarkerSize _mkr;
            private _dir = markerDir _mkr;
            private _shape = markerShape _mkr;
            // Default: every correctly-named editor marker is ENEMY territory. The single
            // exception is an HQ marker the player is standing inside at spawn - that HQ is the
            // player's own and becomes their spawn location.
            private _owner = EAST;
            if (_typeName == "HQ" && { _playerStartPos inArea _mkr }) then {
                _owner = WEST;
            };
            private _colorName = if (_owner == WEST) then { "ColorBLUFOR" } else { "ColorOPFOR" };
            _mkr setMarkerColor _colorName;

            private _importance = [_pos, _typeName] call MISSION_CORE_fnc_getLocationImportance;

            private _area = [_pos, _size, _dir, _shape];

            private _mapLabel = _mkr;  // for editor markers the marker name IS the town label

            _results pushBack [
                _x, _area, _typeName, _prefix,
                _priority, _owner, [], _importance, _mapLabel
            ];
            diag_log format ["DYNAMIC MARKER: %1 label=%2 type=%3 owner=%4 importance=%5", _mkr, _mapLabel, _typeName, _owner, _importance];

            if (_owner == WEST) then {
                MISSION_CORE_BLUFOR_SPAWNS pushBack [_x, _area];
            };
        } forEach _markers;
    };

    // Process auto-generated "loc_*" markers from CfgWorlds map locations
    private _locMarkers = _allMarkers select { toLower _x find "loc_" == 0 && { _x find "loc_mission" != 0 } };
    {
        private _mkr = _x;
        private _parts = _mkr splitString "_";
        private _locType = "";
        if (count _parts >= 3) then {
            _locType = _parts select 1;
            for "_i" from 2 to (count _parts - 2) do {
                _locType = _locType + "_" + (_parts select _i);
            };
        };
        if (_locType != "") then {
            private _pos = getMarkerPos _mkr;
            private _size = getMarkerSize _mkr;
            private _owner = EAST;
            private _colorName = "ColorOPFOR";
            _mkr setMarkerColor _colorName;
            _mkr setMarkerAlpha 0;

            private _importance = [_pos, _locType] call MISSION_CORE_fnc_getLocationImportance;
            // Override: use the CfgLocationTypes importance directly
            private _locTypes = [
                ["NameCityCapital", 5], ["NameCity", 5], ["NameVillage", 5], ["NameLocal", 5],
                ["NameMarine", 5], ["Mount", 5], ["CityCenter", 5],
                ["Airport", 4], ["Area", 4], ["BorderCrossing", 4],
                ["Hill", 3], ["HistoricalSite", 3], ["RockArea", 3], ["SafetyZone", 3],
                ["Strategic", 2], ["StrongpointArea", 2]
            ];
            {
                if (_locType == _x select 0) exitWith { _importance = _x select 1; };
            } forEach _locTypes;

            private _area = [_pos, _size, markerDir _mkr, "ELLIPSE"];

            // Real map-facing label ("Kavala" / "Power Plant") stored by generateLocationMarkers
            // in the MISSION_CORE_LOC_LABELS map (markers are names, not objects - no setVariable).
            private _mapLabel = if (isNil "MISSION_CORE_LOC_LABELS") then { _locType } else { MISSION_CORE_LOC_LABELS getOrDefault [_mkr, _locType] };

            _results pushBack [
                _mkr, _area, _locType, "loc_",
                _importance, _owner, [], _importance, _mapLabel
            ];
            diag_log format ["DYNAMIC MARKER: %1 label=%2 type=%3 (auto) importance=%4", _mkr, _mapLabel, _locType, _importance];
        };
    } forEach _locMarkers;

    _results
};