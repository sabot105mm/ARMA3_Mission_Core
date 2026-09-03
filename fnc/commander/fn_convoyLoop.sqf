// =====================================================================
// SUPPLY CONVOYS
// Supply moves between REDFOR markers as physical trucks, not instant
// numeric credit. A convoy is first tracked ABSTRACTLY: its position is
// interpolated along the ROAD path connecting provider->recipient each
// tick. Only when a player is within 1200m of that position does it
// MATERIALIZE into a real truck driving the remaining route. On arrival
// the recipient receives the supply; if destroyed the supply is lost and
// an ammo box drops for the player to loot.
// =====================================================================

// Position at fraction _frac (0..1) along a polyline given cumulative
// segment lengths. Cheap - one linear walk over a short array.
MISSION_CORE_fnc_convoyPosAt = {
    params ["_path", "_cum", "_frac"];
    if (count _path < 2) exitWith { _path select 0 };
    private _total = _cum select (count _cum - 1);
    if (_total <= 0) exitWith { _path select 0 };
    private _target = _frac * _total;
    private _idx = 0;
    { if (_x >= _target) exitWith { _idx = _forEachIndex; }; } forEach _cum;
    private _prev = if (_idx > 0) then { _cum select (_idx - 1) } else { 0 };
    private _seg = (_cum select _idx) - _prev;
    private _t = if (_seg > 0) then { (_target - _prev) / _seg } else { 0 };
    private _a = _path select _idx;
    private _b = _path select (_idx + 1);
    [
        (_a select 0) + ((_b select 0) - (_a select 0)) * _t,
        (_a select 1) + ((_b select 1) - (_a select 1)) * _t,
        0
    ]
};

// Start an abstract supply convoy along the road network. Provider is charged immediately; the
// recipient only receives supply when the truck actually arrives.
MISSION_CORE_fnc_startConvoy = {
    params ["_providerName", "_recipientName", "_supplyAmount", ["_cost", -1]];
    if (_supplyAmount <= 0) exitWith {};
    if (isNil "MISSION_CORE_CONVOYS") then { MISSION_CORE_CONVOYS = []; };
    private _provIdx = MISSION_CORE_CACHED_POSITIONS findIf { (_x select 0) == _providerName };
    private _recvIdx = MISSION_CORE_CACHED_POSITIONS findIf { (_x select 0) == _recipientName };
    if (_provIdx < 0 || { _recvIdx < 0 }) exitWith {};
    private _startPos = (MISSION_CORE_CACHED_POSITIONS select _provIdx) select 1;
    private _endPos = (MISSION_CORE_CACHED_POSITIONS select _recvIdx) select 1;
    if (_startPos distance2D _endPos < 50) exitWith {};
    if (_cost < 0) then { _cost = _supplyAmount + ceil (_supplyAmount * 0.1); };
    private _provSupply = MISSION_CORE_LOCATION_SUPPLY getOrDefault [_providerName, 0];
    MISSION_CORE_LOCATION_SUPPLY set [_providerName, _provSupply - _cost];

    // Build the road path: greedily follow connected roads from the provider's nearest road toward
    // the recipient's nearest road. Fall back to a straight line if the road network doesn't
    // connect them.
    private _roadPath = [_startPos, _endPos];
    private _startRoad = (_startPos nearRoads 400) param [0, objNull];
    private _endRoad = (_endPos nearRoads 400) param [0, objNull];
    if (!isNull _startRoad && { !isNull _endRoad }) then {
        private _cur = _startRoad;
        private _visited = [];
        private _trial = [];
        private _reached = false;
        for "_i" from 0 to 199 do {
            _trial pushBack (getPos _cur);
            _visited pushBack _cur;
            if ((_cur distance2D _endRoad) < 30) exitWith { _reached = true; };
            private _conn = roadsConnectedTo _cur;
            private _best = objNull;
            private _bestD = 1e10;
            {
                if (!(_x in _visited)) then {
                    private _d = _x distance2D _endRoad;
                    if (_d < _bestD) then { _bestD = _d; _best = _x; };
                };
            } forEach _conn;
            if (isNull _best) exitWith {};
            _cur = _best;
        };
        if (_reached && { count _trial >= 2 }) then {
            _trial pushBack (getPos _endRoad);
            _roadPath = _trial;
        };
    };
    // Cumulative segment lengths (for cheap per-tick interpolation)
    private _cum = [];
    private _total = 0;
    for "_i" from 0 to (count _roadPath - 2) do {
        _total = _total + ((_roadPath select _i) distance2D (_roadPath select (_i + 1)));
        _cum pushBack _total;
    };
    if (_total < 50) exitWith { MISSION_CORE_LOCATION_SUPPLY set [_providerName, _provSupply]; };
    private _speed = 14; // m/s ~ truck road speed
    private _travelTime = _total / _speed;
    // [_provider, _recipient, _roadPath, _cum, _travelTime, _departTime, _amount, _state, _truck, _grp]
    MISSION_CORE_CONVOYS pushBack [_providerName, _recipientName, _roadPath, _cum, _travelTime, time, _supplyAmount, 0, objNull, grpNull];
    diag_log format ["DYNAMIC CONVOY: %1 -> %2 (%3 supply, %4m via road, ETA %5s)", _providerName, _recipientName, _supplyAmount, round _total, round _travelTime];
};

MISSION_CORE_fnc_convoyLoop = {
    diag_log "DYNAMIC CONVOY: loop started";
    while { true } do {
        sleep 5;
        if (isNil "MISSION_CORE_CONVOYS") then { MISSION_CORE_CONVOYS = []; };
        private _players = allPlayers select { alive _x };
        private _keep = [];
        {
            _x params ["_prov", "_recv", "_roadPath", "_cum", "_travelTime", "_departTime", "_amount", "_state", "_truck", "_grp"];
            if (_state == 0) then {
                private _frac = ((time - _departTime) / _travelTime) min 1;
                if (_frac >= 1) then {
                    private _recvSupply = MISSION_CORE_LOCATION_SUPPLY getOrDefault [_recv, 0];
                    MISSION_CORE_LOCATION_SUPPLY set [_recv, _recvSupply + _amount];
                    diag_log format ["DYNAMIC CONVOY: %1 -> %2 delivered %3 supply (abstract)", _prov, _recv, _amount];
                } else {
                    private _curPos = [_roadPath, _cum, _frac] call MISSION_CORE_fnc_convoyPosAt;
                    private _nearPlayer = _players findIf { _x distance _curPos < 1200 } != -1;
                    if (_nearPlayer) then {
                        private _truckClass = "";
                        {
                            private _c = _x;
                            if (_c isKindOf "Truck_F") exitWith { _truckClass = _c; };
                        } forEach ((MISSION_CORE_REDFOR_DATA select 7) getOrDefault ["transport", []]);
                        if (_truckClass == "") then { _truckClass = "O_Truck_02_covered_F"; };
                        private _spawn = [_curPos] call MISSION_CORE_fnc_ensureLandPos;
                        private _truck = createVehicle [_truckClass, [_spawn] call MISSION_CORE_fnc_liftSpawn, [], 0, "CAN_COLLIDE"];
                        _truck setVariable ["MISSION_CORE_CONVOY_TRUCK", true];
                        _truck setVariable ["MISSION_CORE_TRUCK_ORIGIN", _spawn];
                        private _drvGrp = createGroup EAST;
                        _drvGrp addVehicle _truck;
                        private _drv = _drvGrp createUnit ["O_crew_F", _spawn, [], 0, "NONE"];
                        _drv moveInDriver _truck;
                        _drvGrp setBehaviour "CARELESS";
                        _drvGrp setCombatMode "GREEN";
                        _drvGrp setSpeedMode "FULL";
                        private _wp = _drvGrp addWaypoint [(_roadPath select (count _roadPath - 1)), 0];
                        _wp setWaypointType "MOVE";
                        _wp setWaypointSpeed "FULL";
                        _wp setWaypointBehaviour "CARELESS";
                        _drvGrp setCurrentWaypoint _wp;
                        _x set [7, 1];
                        _x set [8, _truck];
                        _x set [9, _drvGrp];
                        _keep pushBack _x;
                        diag_log format ["DYNAMIC CONVOY: %1 -> %2 materialized %3 at %4", _prov, _recv, _truckClass, _curPos];
                    } else {
                        _keep pushBack _x;
                    };
                };
            } else {
                if (isNull _truck || { !(alive _truck) }) then {
                    if (!isNull _truck) then {
                        private _boxClass = "";
                        {
                            if (!isNil "_x" && { _x != "" }) exitWith { _boxClass = _x; };
                        } forEach ((MISSION_CORE_REDFOR_DATA select 11) select { true });
                        if (_boxClass == "") then { _boxClass = "Box_East_Ammo_F"; };
                        createVehicle [_boxClass, getPos _truck, [], 0, "CAN_COLLIDE"];
                        diag_log format ["DYNAMIC CONVOY: %1 -> %2 destroyed - %3 supply lost, ammo box dropped", _prov, _recv, _amount];
                    };
                    if (!isNull _grp) then { { deleteVehicle _x; } forEach units _grp; deleteGroup _grp; };
                } else {
                    private _endPos = _roadPath select (count _roadPath - 1);
                    if (_truck distance2D _endPos < 150) then {
                        private _recvSupply = MISSION_CORE_LOCATION_SUPPLY getOrDefault [_recv, 0];
                        MISSION_CORE_LOCATION_SUPPLY set [_recv, _recvSupply + _amount];
                        diag_log format ["DYNAMIC CONVOY: %1 -> %2 delivered %3 supply", _prov, _recv, _amount];
                        { deleteVehicle _x; } forEach units _grp;
                        deleteGroup _grp;
                        deleteVehicle _truck;
                    } else {
                        _keep pushBack _x;
                    };
                };
            };
        } forEach MISSION_CORE_CONVOYS;
        MISSION_CORE_CONVOYS = _keep;
    };
};
