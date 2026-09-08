
// Hit-event reaction for foot squads and defense vehicles. Registered per-unit at spawn
// (addMPEventHandler ["MPHit", ...]). A unit actually being HIT triggers one of two reactions,
// each debounced so it fires ONCE per group's life:
//   - Defense patrol (order "", "defend", "engage"): stop patrolling and SAD the friendly marker.
//   - Attacking / counter-attacking foot troops riding a truck within 700m of their drop point:
//     bail out under fire instead of driving into it.
MISSION_CORE_fnc_onSuppressed = {
    params ["_unit", "_causedBy", "_damage", "_instigator"];
    if (isNull _unit || { !(alive _unit) }) exitWith { false };
    private _grp = group _unit;
    if (isNull _grp || { { alive _x } count units _grp == 0 }) exitWith { false };
    private _order = _grp getVariable ["MISSION_CORE_ORDER", ""];

    // --- Foot troops riding a truck on an attack/counter-attack/reinforce: unload early ---
    if (_order in ["attack", "counterattack", "reinforce"]) then {
        private _veh = vehicle _unit;
        if (isNull _veh || { _veh == _unit }) exitWith { false };
        private _at = _grp getVariable ["MISSION_CORE_ATTACK_TARGET", [0, 0, 0]];
        if (count _at == 0) exitWith { false };
        if (_veh distance2D _at > 700) exitWith { false };
        if (_grp getVariable ["MISSION_CORE_EARLY_UNLOADED", false]) exitWith { false };
        _grp setVariable ["MISSION_CORE_EARLY_UNLOADED", true];
        private _crew = crew _veh select { alive _x && { vehicle _x == _veh } };
        _crew = _crew - [driver _veh];
        { unassignVehicle _x; } forEach _crew;
        _grp leaveVehicle _veh;
        { _x action ["getOut", _veh]; } forEach _crew;
        _veh lockCargo true;
        diag_log format ["AI DEFENSE: %1 suppressed in truck - unloading early under fire", groupId _grp];
        false
    } else {
        // --- Defense patrol hit: NEVER SAD the marker center and NEVER override the quadrant /
        // --- patrol ownership. A suppressed patrol just snaps alert (AWARE/RED) and keeps its
        // --- existing patrol sweeping the area - the commander's quadrant engine and the foot
        // --- patrol/defense loop own engagement, not this per-hit handler.
        if (!(_order in ["", "defend", "engage"])) exitWith { false };
    if ((_grp getVariable ["MISSION_CORE_HUNT_KEY", ""]) != "") exitWith { false };
    if ([_grp] call MISSION_CORE_fnc_isQuadrantStaged) exitWith { false };
        if (_grp getVariable ["MISSION_CORE_AA_DEFENSE", false]) exitWith { false };
        if (_grp getVariable ["MISSION_CORE_AA_TANK", false]) exitWith { false };
        if (_grp getVariable ["MISSION_CORE_SUPPRESSED_REACTED", false]) exitWith { false };
        // Leave quadrants/committed groups alone - they already have a plan.
        if (_grp getVariable ["MISSION_CORE_ORDER", ""] == "engage" && { !((_grp getVariable ["MISSION_CORE_QUAD_MARKER", ""]) == "") }) exitWith { false };
        _grp setVariable ["MISSION_CORE_SUPPRESSED_REACTED", true];
        _grp setVariable ["MISSION_CORE_IDLE", false];
        _grp setBehaviour "AWARE";
        _grp setCombatMode "RED";
        // Keep whatever patrol waypoints exist; only nudge off a frozen CYCLE so it keeps moving.
        private _wps = waypoints _grp;
        if (count _wps > 0) then {
            private _curIdx = (currentWaypoint _grp) min (count _wps - 1);
            if (waypointType (_wps select _curIdx) == "CYCLE") then {
                private _nx = _wps select 0;
                { if (waypointType _x != "CYCLE") exitWith { _nx = _x; }; } forEach _wps;
                _grp setCurrentWaypoint _nx;
            };
        } else {
            [_grp, _grp getVariable ["MISSION_CORE_MARKER_CENTER", getPos (leader _grp)], _grp getVariable ["MISSION_CORE_MARKER_SIZE", [200, 200]]] call MISSION_CORE_fnc_issuePatrolAware;
        };
        diag_log format ["AI DEFENSE: %1 suppressed - alert (AWARE/RED) keeping patrol", groupId _grp];
        false
    };
};
