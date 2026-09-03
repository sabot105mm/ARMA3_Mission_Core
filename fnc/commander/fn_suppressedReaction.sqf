
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
        // --- Defense patrol: stop patrol and SAD the friendly marker center (once ever) ---
        if (!(_order in ["", "defend", "engage"])) exitWith { false };
        if (_grp getVariable ["MISSION_CORE_AA_DEFENSE", false]) exitWith { false };
        if (_grp getVariable ["MISSION_CORE_AA_TANK", false]) exitWith { false };
        if (_grp getVariable ["MISSION_CORE_SUPPRESSED_REACTED", false]) exitWith { false };
        _grp setVariable ["MISSION_CORE_SUPPRESSED_REACTED", true];
        private _home = _grp getVariable ["MISSION_CORE_MARKER_CENTER", getPos (leader _grp)];
        _grp setVariable ["MISSION_CORE_ORDER", "defend"];
        _grp setVariable ["MISSION_CORE_IDLE", false];
        _grp setVariable ["MISSION_CORE_PATROLLING", false];
        (leader _grp) setVariable ["MISSION_CORE_PATROLLING", false];
        _grp setBehaviour "AWARE";
        _grp setCombatMode "RED";
        [_grp] call MISSION_CORE_fnc_clearGroupWaypoints;
        private _wp = _grp addWaypoint [_home, 80];
        _wp setWaypointType "SAD";
        _wp setWaypointSpeed "FULL";
        _wp setWaypointBehaviour "COMBAT";
        _grp setCurrentWaypoint _wp;
        diag_log format ["AI DEFENSE: %1 suppressed - defending friendly marker", groupId _grp];
        false
    };
};
