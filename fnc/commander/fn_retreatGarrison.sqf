// Retreat a marker's surviving garrison once its defense collapses. Every unit keeps firing while
// it withdraws (RED combat mode), holds formation (WEDGE + AWARE), stands up (UP) and runs (FULL)
// toward the closest friendly marker, then despawns on arrival. The despawn is what removes them
// from the map - they are never left patrolling their abandoned home.
//
// The retreat destination comes from fn_getRetreatDest, so the garrison NEVER retreats to a marker
// whose line of retreat passes through an enemy-held base - it falls back to the next closest
// friendly marker instead of driving home through hostile territory.
MISSION_CORE_fnc_retreatGarrison = {
    params ["_locName", "_locPos", "_side"];
    // The retreat destination comes from fn_getRetreatDest, which returns the closest friendly
    // marker whose path from the LOST marker does not cross an enemy-held base. Drawn from _locPos
    // (marker WE LOST), not the squad's mid-retreat position, so the whole escape route stays out
    // of enemy territory.
    private _allyPos = [_locPos, _side, [_locName]] call MISSION_CORE_fnc_getRetreatDest;
    if (_allyPos distance [0, 0, 0] < 1) exitWith {};
    private _allyIdx = MISSION_CORE_CACHED_POSITIONS findIf { ((_x select 1) isEqualTo _allyPos) && { (_x select 4) == _side } };
    private _ally = if (_allyIdx >= 0) then { (MISSION_CORE_CACHED_POSITIONS select _allyIdx) select 0 } else { "" };
    {
        if (!isNull _x && { (_x getVariable ["MISSION_CORE_ORIGIN_MARKER", ""]) == _locName } && { { alive _x } count units _x > 0 }) then {
            _x setVariable ["MISSION_CORE_ORDER", "retreat"];
            _x setCombatMode "GREEN";  // hold fire (return fire only) while withdrawing
            _x setBehaviour "AWARE";   // stay in formation (CARELESS breaks ranks and lies down)
            _x setFormation "WEDGE";   // stay in formation
            _x setSpeedMode "FULL";    // run
            { _x setUnitPos "UP"; } forEach units _x; // stand up
            // Never send the retreat toward the map origin [0,0,0] or into the sea.
            private _dest = [_allyPos, _locPos] call MISSION_CORE_fnc_safeWaypointPos;
            [_x] call MISSION_CORE_fnc_clearGroupWaypoints;
            private _wp = _x addWaypoint [_dest, 100];
            _wp setWaypointType "MOVE";
            _wp setWaypointSpeed "FULL";
            _wp setWaypointBehaviour "AWARE";
            // Despawn when the squad reaches the closest friendly marker - transport_retreatArrive.sqf
            // fires on the MOVE waypoint's completion, no 5s polling loop.
            _wp setWaypointScript "fnc\commander\transport_retreatArrive.sqf";
            _x setCurrentWaypoint _wp;
        };
    } forEach MISSION_CORE_SPAWNED_GROUPS;
    diag_log format ["DYNAMIC RETREAT: %1 garrison retreating to %2", _locName, _ally];
};