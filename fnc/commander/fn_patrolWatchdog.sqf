
// CYCLE-waypoint fix (one tick of the group maintenance loop). A CYCLE waypoint is not a movement
// waypoint - a group whose current waypoint is a CYCLE waits in place forever. When the engine
// fails to wrap a patrol back to its MOVE waypoints (which happens when waypoints are rebuilt
// around it), the group freezes and the engine spams "Cycle as first waypoint has no sense". This
// nudges any such group back onto its first MOVE waypoint.
MISSION_CORE_fnc_patrolWatchdogTick = {
    if (isNil "MISSION_CORE_SPAWNED_GROUPS") exitWith {};
    {
        if (!isNull _x && { count units _x > 0 } && { { alive _x } count units _x > 0 }) then {
            private _wps = waypoints _x;
            if (count _wps == 0) then { continue; };
            private _curIdx = currentWaypoint _x;
            if (_curIdx < 0 || { _curIdx >= count _wps }) then { continue; };
            private _curWp = _wps select _curIdx;
            if (waypointType _curWp == "CYCLE") then {
                private _next = _wps select 0;
                { if (waypointType _x != "CYCLE") exitWith { _next = _x; }; } forEach _wps;
                if (waypointType _next != "CYCLE") then {
                    _x setCurrentWaypoint _next;
                    diag_log format ["DYNAMIC PATROL: %1 reset off CYCLE waypoint", groupId _x];
                };
            };
        };
    } forEach MISSION_CORE_SPAWNED_GROUPS;
};
