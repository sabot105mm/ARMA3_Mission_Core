
// Called by sendCounterAttack: waits for the truck to reach the marker edge and dismount. Foot
// infantry are split into their own group so they can never re-board near the contested edge;
// the driver is ungrouped and drives the truck 500m back toward its origin spawn, then the
// truck despawns. Nobody rides the truck into the fight.
MISSION_CORE_fnc_splitAfterDismount = {
    params ["_grp", "_truck", "_side", "_targetPos", "_getoutIdx", ["_unloadDist", 100]];
    if (isNull _grp || { isNull _truck }) exitWith {};
    // Force every passenger out the moment the truck crosses the stand-off ring (which may be
    // pushed further out after repeated truck kills), even if the waypoint hasn't completed -
    // nobody rides the truck past the ring into the fight, but nobody leaves early either. The
    // truck itself stays driveable (driver kept for the retreat below); only foot cargo is ejected.
    [_truck, _targetPos, _unloadDist, _grp] spawn {
        params ["_veh", "_tgt", "_unloadDist", "_grpRef"];
        private _deadline = time + 600;
        while { time < _deadline && { alive _veh } && { !(isNull _grpRef) } && { { vehicle _x == _veh } count units _grpRef > 0 } } do {
            if ((_veh distance2D _tgt <= _unloadDist) || { _veh distance2D _tgt <= 50 }) then {
                private _crew = crew _veh select { vehicle _x == _veh && { alive _x } };
                _crew = _crew - [driver _veh];
                { unassignVehicle _x } forEach _crew;
                _grpRef leaveVehicle _veh;
                { _x action ["getOut", _veh] } forEach _crew;
                // Block the cargo seats the foot squad boarded so they never re-board the truck as
                // it retreats; the driver seat stays open for the retreat driver. lockCargo is
                // used instead of allowGetIn because the latter needs an array sized to the exact
                // seat count of every truck variant (e.g. 8 for O_Truck_03_transport).
                _veh lockCargo true;
                sleep 1;
            };
            sleep 1;
        };
    };
    private _timeout = time + 300;
    waitUntil {
        sleep 3;
        if (isNull _grp || { isNull _truck }) exitWith { true };
        private _onFoot = { vehicle _x == _x && { alive _x } } count units _grp;
        private _reachedDrop = (_truck distance2D _targetPos) < _unloadDist;
        // Only count as "dismounted" once the truck has actually crossed the drop ring, so a
        // soldier bailing out early never sends the truck retreating (and despawning) early
        (((_onFoot >= (count units _grp) - 1) && { _reachedDrop }) || { currentWaypoint _grp > _getoutIdx } || { time > _timeout })
    };
    if (isNull _grp || { isNull _truck }) exitWith {};
    private _dismounted = units _grp select { vehicle _x == _x && { alive _x } };
    if (count _dismounted == 0) exitWith {};
    { _x enableAI "AUTOCOMBAT"; } forEach _dismounted;
    // A truck actually unloaded - reset the destruction streak so the drop point stops retreating
    private _kIdx = if (_side == WEST) then { 0 } else { 1 };
    if (isNil "MISSION_CORE_TRUCK_KILLS") then { MISSION_CORE_TRUCK_KILLS = [[0, -1e10], [0, -1e10]]; };
    (MISSION_CORE_TRUCK_KILLS select _kIdx) set [0, 0];
    private _oldId = groupId _grp;
    private _truckType = typeOf _truck;
    // The driver may have gotten out with everyone else at the GETOUT waypoint - reseat one foot
    // soldier as driver so the truck can drive itself back and despawn
    private _drv = driver _truck;
    if (isNull _drv || { !(alive _drv) }) then {
        _drv = _dismounted select 0;
        _drv moveInDriver _truck;
    };
    // Separate group - never boards the truck again
    private _assaultFoot = _dismounted - [_drv];
    private _newGrp = grpNull;
    if (count _assaultFoot > 0) then {
        _newGrp = createGroup _side;
        _assaultFoot joinSilent _newGrp;
        {
            private _v = _grp getVariable [_x, nil];
            if (!isNil "_v") then { _newGrp setVariable [_x, _v]; };
        } forEach ["MISSION_CORE_BLUFOR", "MISSION_CORE_REDFOR", "MISSION_CORE_ORIGIN_MARKER", "MISSION_CORE_IMPORTANCE", "MISSION_CORE_MARKER_CENTER", "MISSION_CORE_GROUP_TYPE", "MISSION_CORE_SUBCAT"];
        _newGrp setVariable ["MISSION_CORE_IDLE", false];
        _newGrp setVariable ["MISSION_CORE_PATROLLING", false];
        leader _newGrp setVariable ["MISSION_CORE_PATROLLING", false];
        _newGrp setVariable ["MISSION_CORE_ORDER", "attack"];
        _newGrp setBehaviour "AWARE";
        _newGrp setSpeedMode "FULL";
        _newGrp setCombatMode "YELLOW";
        _newGrp setFormation "WEDGE";
        [_newGrp] call MISSION_CORE_fnc_clearGroupWaypoints;
        private _wp = _newGrp addWaypoint [_targetPos, 50];
        _wp setWaypointType "SAD";
        _wp setWaypointSpeed "FULL";
        _wp setWaypointBehaviour "COMBAT";
        _newGrp setCurrentWaypoint _wp;
        if (isNil "MISSION_CORE_SPAWNED_GROUPS") then { MISSION_CORE_SPAWNED_GROUPS = []; };
        MISSION_CORE_SPAWNED_GROUPS pushBack _newGrp;
        // One-shot post-assault re-eval: sweep the last known enemy once the marker is no longer
        // contested, then return to origin and patrol (no separate system - same transport flow).
        [_newGrp, _targetPos, _side] spawn MISSION_CORE_fnc_footSquadPostAssault;
        // Foot troops ride to the drop point on GREEN, go YELLOW once dismounted (set above), then
        // switch to RED (engage at will) once the squad is inside the contested marker.
        [_newGrp, _targetPos] spawn {
            params ["_grp", "_tgt"];
            private _t = time + 600;
            while { time < _t && { !isNull _grp } && { { alive _x } count units _grp > 0 } } do {
                if ((leader _grp) distance2D _tgt < 100) exitWith { _grp setCombatMode "RED"; };
                sleep 2;
            };
        };
    };
    private _newId = if (!isNull _newGrp) then { groupId _newGrp } else { _oldId };
    // Drive the empty transport back to the truck's SPAWN point and despawn it there, clearing
    // the road and never lingering at the fight. The truck does NOT turn back early at the moment
    // it crosses the ring - the driver holds just long enough for the foot squad to clear the
    // stand-off ring, then drives home to its spawn to despawn.
    private _spawnHome = _truck getVariable ["MISSION_CORE_TRUCK_ORIGIN", getPos _truck];
    if (!isNull _drv && { alive _drv }) then {
        private _drvGrp = _truck getVariable ["MISSION_CORE_DRIVER_GROUP", grpNull];
        if (isNull _drvGrp || { !(_drv in (units _drvGrp)) }) then {
            _drvGrp = createGroup _side;
            [_drv] joinSilent _drvGrp;
        };
        _drvGrp addVehicle _truck;
        // Truck clearly drove past the ring - send it back to its spawn at full speed, CARELESS,
        // despawn on arrival. doMove leaves immediately instead of idling where foot could re-board.
        _drvGrp setBehaviour "CARELESS";
        _drvGrp setSpeedMode "FULL";
        _drv doMove _spawnHome;
        diag_log format ["AI COMMANDER: truck %1 sent back to spawn %2 (despawn on arrival)", typeOf _truck, _spawnHome];
        // Wait for arrival at the spawn point (or timeout / wreck), then remove crew + truck + group.
        [_drvGrp, _truck, _spawnHome] spawn {
            params ["_drvGrp", "_truck", "_spawnHome"];
            private _t = time + 300;
            waitUntil { sleep 3;
                isNull _truck || { !(alive _truck) } ||
                { (getPos _truck) distance2D _spawnHome < 25 } ||
                { time > _t }
            };
            if (!isNull _truck && { alive _truck }) then {
                { if (!isNull _x) then { deleteVehicle _x; }; } forEach units _drvGrp;
                deleteVehicle _truck;
            };
            deleteGroup _drvGrp;
        };
    } else {
        diag_log format ["AI COMMANDER: truck %1 no driver, despawning", typeOf _truck];
        deleteVehicle _truck;
    };
    // The original group is now empty (foot + driver moved out) - drop it
    if (count units _grp == 0) then { deleteGroup _grp; };
    diag_log format ["AI COMMANDER: assault dismount %1 -> separate group %2 (truck %3 removed)", _oldId, _newId, _truckType];
};
