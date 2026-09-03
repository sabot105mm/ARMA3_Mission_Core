
MISSION_CORE_fnc_restartPatrol = {
    params ["_group"];
    // Groups on a one-way attack task never revert to their old patrol waypoints - they stay on
    // the task. Defend/engage groups are temporary combat states and may resume patrol.
    if ((_group getVariable ["MISSION_CORE_ORDER", ""]) in ["attack", "counterattack", "reinforce"]) exitWith {};
    // Skip BLUFOR patrols if disabled
    private _side = side _group;
    private _bluforPatrol = ["bluforPatrolMarkers", 0] call MISSION_CORE_fnc_tune;
    if (_side == WEST && _bluforPatrol == 0) exitWith {};
    private _imp = _group getVariable ["MISSION_CORE_IMPORTANCE", 1];
    private _markerCenter = _group getVariable ["MISSION_CORE_MARKER_CENTER", _group getVariable ["MISSION_CORE_SPAWN_POS", [0,0,0]]];
    // Patrol waypoints must never land at the map origin [0,0,0] or in water.
    _markerCenter = [_markerCenter, getPos (leader _group)] call MISSION_CORE_fnc_safeWaypointPos;
    private _markerSize = _group getVariable ["MISSION_CORE_MARKER_SIZE", [200, 200]];
    private _ma = _markerSize select 0;
    private _mb = _markerSize select 1;
    private _mDir = if (count _markerSize > 2) then { _markerSize select 2 } else { 0 };
    private _count = [2, 2, 3, 4, 5, 6] select _imp;
    private _isFoot = { vehicle _x == _x } count units _group == count units _group;
    private _speed = if (_isFoot) then { "LIMITED" } else { ["LIMITED", "LIMITED", "LIMITED", "LIMITED", "NORMAL", "FULL"] select _imp };
    _group setVariable ["MISSION_CORE_ORDER", ""];
    _group setCombatMode "WHITE";
    [_group] call MISSION_CORE_fnc_clearGroupWaypoints;
    if (_count > 0) then {
        for "_i" from 1 to _count do {
            private _ang = random 360;
            // Patrol INSIDE the marker only. 25% on the outer 90% ring, 25% on the 75% ring, 50%
            // deeper inside the 75% ring (never at/outside the edge).
            private _frac = (_i - 1) / (_count max 1);
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
            private _wp = _group addWaypoint [_wpPos, 30];
            _wp setWaypointType "MOVE";
            _wp setWaypointSpeed _speed;
            _wp setWaypointBehaviour "SAFE";
        };
        private _wp = _group addWaypoint [_markerCenter, 0];
        _wp setWaypointType "CYCLE";
        _wp setWaypointSpeed _speed;
        _wp setWaypointBehaviour "SAFE";
        private _wps = waypoints _group;
        if (count _wps > 0) then {
            private _startWp = _wps select 0;
            { if (waypointType _x != "CYCLE") exitWith { _startWp = _x; }; } forEach _wps;
            _group setCurrentWaypoint _startWp;
        };
        leader _group setVariable ["MISSION_CORE_PATROLLING", true];
    } else {
        _group setBehaviour "SAFE";
        _group setCombatMode "GREEN";
        leader _group setVariable ["MISSION_CORE_PATROLLING", true];
    };
};
