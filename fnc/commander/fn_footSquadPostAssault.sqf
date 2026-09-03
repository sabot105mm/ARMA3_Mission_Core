
// Post-assault behavior for a committed FOOT squad (one-shot per commit). Continuously re-evaluates
// whether the target marker is still contested (isMarkerContested). While it is, the squad keeps its
// normal SAD on the target. Once the marker is no longer contested, the squad SADs the last known
// enemy position for up to 5 minutes; if it makes no contact in that window it returns to its origin
// (mounting a truck if far) and patrols.
MISSION_CORE_fnc_footSquadPostAssault = {
    params ["_grp", "_targetPos", "_side"];
    private _lastKnown = _targetPos;
    private _lastContact = time;
    private _done = false;
    while { !_done && { !isNull _grp } && { { alive _x } count units _grp > 0 } } do {
        sleep 5;
        private _ldr = leader _grp;
        if (isNull _ldr || { !alive _ldr }) then {
            _done = true;
        } else {
            // Enemy the squad is actually aware of (knowsAbout > 1.2)
            private _enemy = objNull;
            {
                if (_ldr knowsAbout _x > 1.2) exitWith { _enemy = _x; };
            } forEach (allUnits select { side _x getFriend _side < 0.6 && { alive _x } });
            private _contested = [_targetPos, _side, ""] call MISSION_CORE_fnc_isMarkerContested;
            if (!isNull _enemy) then {
                _lastKnown = getPos _enemy;
                _lastContact = time;
                // Only re-point to sweep the last known position once the marker is no longer contested.
                if (!_contested) then {
                    [_grp] call MISSION_CORE_fnc_clearGroupWaypoints;
                    private _wp = _grp addWaypoint [_lastKnown, 50];
                    _wp setWaypointType "SAD";
                    _wp setWaypointBehaviour "COMBAT";
                    _wp setWaypointSpeed "FULL";
                    _grp setCurrentWaypoint _wp;
                    _grp setCombatMode "RED";
                };
            } else {
                if (!_contested && { time - _lastContact >= 300 }) then {
                    diag_log format ["AI FOOT: %1 no longer contested + 5min no contact - returning to origin", groupId _grp];
                    _grp setVariable ["MISSION_CORE_ORDER", ""];
                    _grp setVariable ["MISSION_CORE_IDLE", true];
                    private _origin = _grp getVariable ["MISSION_CORE_MARKER_CENTER", getPos _ldr];
                    private _onFoot = { vehicle _x == _x } count units _grp == count units _grp;
                    if (_onFoot && { _ldr distance2D _origin > 700 }) then {
                        private _truck = [_grp, _side, getPos _ldr] call MISSION_CORE_fnc_mountInfantry;
                        if (!isNull _truck) then {
                            [_grp] call MISSION_CORE_fnc_clearGroupWaypoints;
                            private _wpBack = _grp addWaypoint [_origin, 100];
                            _wpBack setWaypointType "GETOUT";
                            _wpBack setWaypointSpeed "FULL";
                            _wpBack setWaypointBehaviour "CARELESS";
                            _grp setCurrentWaypoint _wpBack;
                            // Once they reach the origin and dismount, resume patrol.
                            [_grp, _origin] spawn {
                                params ["_g", "_o"];
                                private _t = time + 900;
                                waitUntil { sleep 3; isNull _g || { { alive _x } count units _g == 0 } || { (leader _g) distance2D _o < 150 } || { time > _t } };
                                if (!isNull _g) then { [_g] call MISSION_CORE_fnc_restartPatrol; };
                            };
                        } else {
                            [_grp] call MISSION_CORE_fnc_restartPatrol;
                        };
                    } else {
                        [_grp] call MISSION_CORE_fnc_restartPatrol;
                    };
                    _done = true;
                };
            };
        };
    };
};
