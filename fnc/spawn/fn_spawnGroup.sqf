
MISSION_CORE_fnc_spawnGroup = {
    private _params = _this;
    private _groupType = _params select 0;
    private _position = _params select 1;
    private _side = _params select 2;
    private _faction = _params select 3;
    private _behavior = if (count _params > 4) then { _params select 4 } else { "AWARE" };
    private _speed = if (count _params > 5) then { _params select 5 } else { "LIMITED" };
    private _importance = if (count _params > 6) then { _params select 6 } else { 1 };
    private _markerCenter = if (count _params > 7) then { _params select 7 } else { _position };
    private _markerSize = if (count _params > 8) then { _params select 8 } else { [200, 200] };
    // Patrol waypoints must never land at the map origin [0,0,0] or in water.
    _markerCenter = [_markerCenter, _position] call MISSION_CORE_fnc_safeWaypointPos;

    private _factionData = if (_side == WEST) then { MISSION_CORE_BLUFOR_DATA } else { MISSION_CORE_REDFOR_DATA };
    private _groups = _factionData select 17;
    private _groupConfig = _groups select { (_x select 0) == _groupType };
    if (count _groupConfig == 0) exitWith { grpNull };
    private _template = _groupConfig select 0;
    private _units = _template select 1;
    private _count = _template select 2;

    // Tanks and land units never spawn in or near water
    _position = [_position] call MISSION_CORE_fnc_ensureLandPos;

    private _crewClass = if (_side == WEST) then { "B_crew_F" } else { "O_crew_F" };

    private _grp = createGroup _side;
    if (count _units == 0) exitWith { _grp };
    private _vehList = [];
    {
        private _uClass = _x;
        if (_uClass isKindOf "Man") then {
            private _u = _grp createUnit [_uClass, _position, [], 0, "FORM"];
            _u addMPEventHandler ["MPHit", { _this call MISSION_CORE_fnc_onSuppressed; }];
            _u addEventHandler ["Killed", {
                params ["_unit"];
                private _g = group _unit;
                if (!isNull _g) then {
                    private _m = _g getVariable ["MISSION_CORE_ORIGIN_MARKER", ""];
                    if (_m != "") then {
                        if (isNil "MISSION_CORE_MARKER_CASUALTIES") then { MISSION_CORE_MARKER_CASUALTIES = createHashMap; };
                        MISSION_CORE_MARKER_CASUALTIES set [_m, (MISSION_CORE_MARKER_CASUALTIES getOrDefault [_m, 0]) + 1];
                    };
                };
            }];
        } else {
            if (_uClass isKindOf "AllVehicles") then {
                // A group may carry several vehicles in one template (tank section, mech platoon,
                // etc). Never stack them all on the same spot - each vehicle gets its own clear
                // position inside the big clearing so the group deploys spread out, not piled up.
                private _vehPos = [_position, 0, 100, 10, 0, 0.5, 0] call BIS_fnc_findSafePos;
                if (count _vehPos < 2) then { _vehPos = [_position, _markerSize, 30, random 360] call MISSION_CORE_fnc_findVehiclePos; };
                if (count _vehPos == 2) then { _vehPos pushBack 0; };
                private _veh = _uClass createVehicle ([_vehPos] call MISSION_CORE_fnc_liftSpawn);
                _grp addVehicle _veh;
                _vehList pushBack _veh;
            };
        };
    } forEach _units;
    {
        if (count (crew _x) == 0) then {
            for "_c" from 1 to 3 do {
                private _crew = _grp createUnit [_crewClass, _position, [], 0, "NONE"];
                _crew moveInAny _x;
            };
        };
    } forEach _vehList;
    // Watch every spawned group vehicle: if one explodes on spawn (bad spot), it is rebuilt at a
    // safe clearing since these templates have no armor-reinforcement self-replacement.
    { [_x, _grp, _side] call MISSION_CORE_fnc_guardSpawnKill; } forEach _vehList;

    _grp setBehaviour _behavior;
    _grp setSpeedMode _speed;
    _grp setCombatMode "WHITE";

    if (_side == WEST) then { _grp setVariable ["MISSION_CORE_BLUFOR", true]; };
    if (_side == EAST) then { _grp setVariable ["MISSION_CORE_REDFOR", true]; };
    _grp setVariable ["MISSION_CORE_IDLE", true];
    _grp setVariable ["MISSION_CORE_IMPORTANCE", _importance];
    _grp setVariable ["MISSION_CORE_MARKER_CENTER", _markerCenter];
    _grp setVariable ["MISSION_CORE_MARKER_SIZE", _markerSize];
    _grp setVariable ["MISSION_CORE_SPAWN_POS", _position];
    _grp setVariable ["MISSION_CORE_SPAWN_TIME", time];
    _grp setVariable ["MISSION_CORE_GROUP_TYPE", _groupType];
    _grp setVariable ["MISSION_CORE_SUBCAT", _groupConfig select 0 select 3];
    _grp setVariable ["MISSION_CORE_ORDER", ""];

    private _bluforPatrol = ["bluforPatrolMarkers", 0] call MISSION_CORE_fnc_tune;
    private _doPatrol = _side != WEST || _bluforPatrol > 0;
    private _patrolCount = if (_doPatrol) then { [2, 2, 3, 4, 5, 6] select _importance } else { 0 };
    private _isFoot = { !(_x isKindOf "Man") } count _units == 0;
    private _patrolSpeed = if (_isFoot) then { "LIMITED" } else { ["LIMITED", "LIMITED", "LIMITED", "NORMAL", "NORMAL", "FULL"] select _importance };
    if (_isFoot) then { _grp setSpeedMode "LIMITED"; };
    if (_patrolCount > 0) then {
        // Drop the engine's auto-created initial waypoint so the patrol list is a clean set of
        // MOVE waypoints ending in CYCLE (avoids the auto waypoint being mistaken as the cycle target)
        [_grp] call MISSION_CORE_fnc_clearGroupWaypoints;
        private _ma = _markerSize select 0;
        private _mb = _markerSize select 1;
        private _mDir = if (count _markerSize > 2) then { _markerSize select 2 } else { 0 };
        for "_i" from 1 to _patrolCount do {
            private _ang = random 360;
            // Patrol INSIDE the marker only. Distribution: 25% of waypoints on the outer 90% ring,
            // 25% on the 75% ring, 50% deeper inside the 75% ring (never at/outside the edge).
            private _frac = (_i - 1) / (_patrolCount max 1);
            private _ratio = if (_frac < 0.25) then { 0.9 } else { if (_frac < 0.5) then { 0.75 } else { 0.15 + random 0.55 } };
            private _ox = _ratio * _ma * cos _ang;
            private _oy = _ratio * _mb * sin _ang;
            private _rx = _ox * cos _mDir - _oy * sin _mDir;
            private _ry = _ox * sin _mDir + _oy * cos _mDir;
            private _wpPos = [
                (_markerCenter select 0) + _rx,
                (_markerCenter select 1) + _ry,
                0
            ];
            _wpPos = [_wpPos, _markerCenter] call MISSION_CORE_fnc_safeWaypointPos;
            private _wp = _grp addWaypoint [_wpPos, 30];
            _wp setWaypointType "MOVE";
            _wp setWaypointSpeed _patrolSpeed;
            _wp setWaypointBehaviour "SAFE";
        };
        private _wp = _grp addWaypoint [_markerCenter, 0];
        _wp setWaypointType "CYCLE";
        _wp setWaypointSpeed _patrolSpeed;
        _wp setWaypointBehaviour "SAFE";
        private _wps = waypoints _grp;
        if (count _wps > 0) then {
            private _startWp = _wps select 0;
            { if (waypointType _x != "CYCLE") exitWith { _startWp = _x; }; } forEach _wps;
            _grp setCurrentWaypoint _startWp;
        };
        leader _grp setVariable ["MISSION_CORE_PATROLLING", true];
    };
    diag_log format ["SPAWN DEBUG: group=%1 type=%2 side=%3 imp=%4 foot=%5", groupId _grp, _groupType, _side, _importance, _isFoot];
    _grp
};
