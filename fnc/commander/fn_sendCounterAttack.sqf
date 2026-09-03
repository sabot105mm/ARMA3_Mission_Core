
MISSION_CORE_fnc_sendCounterAttack = {
    params ["_group", "_targetPos", ["_targetSize", [50, 50]], ["_combatMode", "RED"], ["_order", "counterattack"]];
    private _blocked = false;
    // PERMANENT RULE (BLUFOR GARRISONS): a player-recruited garrison (from the recruit menu) is a
    // fortification, not a maneuver unit. It defends and patrols ONLY its assigned marker and is
    // NEVER re-tasked by the AI commander to attack a different / contested marker. This keeps
    // the player's deployed squads and vehicles on the bases they were told to hold.
    // Config toggle "garrisonStaysHome" (default 1): set 0 in MISSION_CORE_TUNE to let AI pull
    // garrison tanks off-marker again (ally-defend / counter-attack / assault).
    private _staysHome = ["garrisonStaysHome", 1] call MISSION_CORE_fnc_tune;
    diag_log format ["SEND C/A: %1 order=%2 garrison=%3 blu=%4 staysHome=%5 target=%6", groupId _group, _group getVariable ["MISSION_CORE_ORDER", ""], _group getVariable ["MISSION_CORE_GARRISON", false], _group getVariable ["MISSION_CORE_BLUFOR", false], _staysHome, _targetPos];
    if (_staysHome > 0 && { _group getVariable ["MISSION_CORE_GARRISON", false] && { (_group getVariable ["MISSION_CORE_BLUFOR", false]) } }) then {
        private _home = _group getVariable ["MISSION_CORE_MARKER_CENTER", getPos (leader _group)];
        private _homeSize = _group getVariable ["MISSION_CORE_MARKER_SIZE", [200, 200]];
        private _r = ((_homeSize select 0) max (_homeSize select 1)) * 1.3;
        private _allow = (_targetPos distance2D _home) < (_r max 300);
        diag_log format ["SEND C/A: %1 garrison guard -> home=%2 allow=%3", groupId _group, _home, _allow];
        if (!_allow) then {
            _group setVariable ["MISSION_CORE_ORDER", "defend"];
            _group setVariable ["MISSION_CORE_IDLE", false];
            _group setVariable ["MISSION_CORE_PATROLLING", false];
            diag_log format ["GARRISON RULE: %1 stays defending its assigned marker (blocked off-marker re-task)", groupId _group];
            _blocked = true;
        };
    };
    // Never send the squad to the map origin [0,0,0] or into the sea.
    _targetPos = [_targetPos, getPos (leader _group)] call MISSION_CORE_fnc_safeWaypointPos;
    if (_blocked) exitWith {};
    _group setVariable ["MISSION_CORE_IDLE", false];
    _group setVariable ["MISSION_CORE_PATROLLING", false];
    _group setVariable ["MISSION_CORE_ORDER", _order];
    _group setVariable ["MISSION_CORE_ATTACK_TARGET", _targetPos];
    // 1. Delete the entire waypoint list (patrol cycle included)
    [_group] call MISSION_CORE_fnc_clearGroupWaypoints;
    private _ldr = leader _group;
    private _side = side _ldr;

    // Confidence drives the advance: low confidence rushes at full speed and pushes 40% into the
    // marker; high confidence advances at full speed too and stops at the marker edge. All
    // committed groups move at FULL speed to the contested marker, keeping WEDGE formation.
    private _originName = _group getVariable ["MISSION_CORE_ORIGIN_MARKER", ""];
    private _conf = MISSION_CORE_AI_CONFIDENCE getOrDefault [_originName, 5];
    private _lowConf = _conf < 5;
    private _advSpeed = "FULL";
    private _depth = if (_lowConf) then { 0.6 } else { 1.0 };

    private _origin = [_group getVariable ["MISSION_CORE_MARKER_CENTER", getPos _ldr], getPos _ldr] call MISSION_CORE_fnc_safeWaypointPos;
    private _dirIn = ((_targetPos select 0) - (_origin select 0)) atan2 ((_targetPos select 1) - (_origin select 1));
    private _a = _targetSize select 0;
    private _b = if (count _targetSize > 1) then { _targetSize select 1 } else { _a };
    private _mRot = if (count _targetSize > 2) then { _targetSize select 2 } else { 0 };
    // Troops ALREADY inside the target marker need no edge/advance waypoint - they are on the
    // objective. Collapse the advance point to the marker center so only a single SAD sits on it
    // (the required first MOVE is also placed there), instead of marching them out to an edge
    // point first and then back to the center - a useless back-and-forth inside their own line.
    private _lPos = getPosATL _ldr;
    private _ldx = (_lPos select 0) - (_targetPos select 0);
    private _ldy = (_lPos select 1) - (_targetPos select 1);
    private _lrx = _ldx * cos _mRot - _ldy * sin _mRot;
    private _lry = _ldx * sin _mRot + _ldy * cos _mRot;
    private _alreadyInside = (((_lrx * _lrx) / ((_a max 1) * (_a max 1))) + ((_lry * _lry) / ((_b max 1) * (_b max 1)))) <= 1;
    if (_alreadyInside) then { _depth = 0; };
    // Dismount/advance point: 40% inside the marker (low confidence) or at the edge (high confidence)
    private _dismountPos = [(_targetPos select 0) - (_depth * _a) * cos _dirIn, (_targetPos select 1) - (_depth * _b) * sin _dirIn, 0];
    // Truck-mounted foot squads disembark 100m OUTSIDE the contested marker's edge - never inside
    // the marker. For an elliptical marker of half-axes _a,_b the center-to-edge distance along the
    // approach bearing _dirIn is the ellipse radial distance; the unload waypoint sits at the
    // contested center with a completion radius equal to that edge distance + 100m, so the truck
    // stops (and disembarks) the moment it crosses the ring just outside the marker boundary.
    private _rad = _a * _b / sqrt (((_b * cos _dirIn) ^ 2) + ((_a * sin _dirIn) ^ 2));
    private _unloadDist = _rad + (["truckUnloadBuffer", 100] call MISSION_CORE_fnc_tune);
    private _truckKillStreak = {
        params ["_s"];
        if (isNil "MISSION_CORE_TRUCK_KILLS") then { MISSION_CORE_TRUCK_KILLS = [[0, -1e10], [0, -1e10]]; };
        private _kIdx = if (_s == WEST) then { 0 } else { 1 };
        (MISSION_CORE_TRUCK_KILLS select _kIdx) select 0
    };
    // Every time a foot truck is destroyed before it reaches the drop, push the unload ring 50m
    // further out (150m outside the edge on the first death), up to five pushes (+250m total).
    private _streak = [_side] call _truckKillStreak;
    if (_streak > 0) then {
        private _push = (_streak min (["truckUnloadMaxPushes", 5] call MISSION_CORE_fnc_tune)) * (["truckUnloadPush", 50] call MISSION_CORE_fnc_tune);
        _unloadDist = _rad + (["truckUnloadBuffer", 100] call MISSION_CORE_fnc_tune) + _push;
    };

    // 2. One MOVE waypoint to the advance point, then one SAD waypoint at the marker center.
    //    High alert (AWARE) and engage at will (RED combat mode) throughout.
    private _addAssaultWps = {
        params ["_grp", "_movePos", "_moveType", "_advSpeed", ["_fireMode", _combatMode], ["_wpRadius", 10]];
        // Keep the squad in WEDGE formation while advancing at full speed to the contested marker.
        // Set the group's own behaviour/speed explicitly (not just the waypoints) so the squad is
        // AWARE and at FULL speed from the moment the order is issued.
        _grp setFormation "WEDGE";
        _grp setBehaviour "AWARE";
        _grp setSpeedMode _advSpeed;
        // ALWAYS issue a MOVE as the very first waypoint (Arma < 1.22 groups refuse to leave the
        // start line unless their first waypoint is MOVE). For truck squads this MOVE drives the
        // truck to the unload ring; the engine GETOUT that follows then triggers the dismount.
        private _wpFirst = _grp addWaypoint [_movePos, _wpRadius];
        _wpFirst setWaypointType "MOVE";
        _wpFirst setWaypointSpeed _advSpeed;
        _wpFirst setWaypointBehaviour "AWARE";
        private _wpMove = _wpFirst;
        if (_moveType != "MOVE") then {
            _wpMove = _grp addWaypoint [_movePos, _wpRadius];
            _wpMove setWaypointType _moveType;
            _wpMove setWaypointSpeed _advSpeed;
            _wpMove setWaypointBehaviour "AWARE";
        };
        private _wpSad = _grp addWaypoint [_targetPos, 50];
        _wpSad setWaypointType "SAD";
        _wpSad setWaypointSpeed "FULL";
        _wpSad setWaypointBehaviour "COMBAT";
        _grp setCurrentWaypoint _wpFirst;
        _grp setCombatMode _fireMode;
    };

    // Unarmed foot-transport squad: the transported group gets a GETOUT waypoint (its own units
    // exit) while the truck's dedicated driver group gets a TRANSPORT UNLOAD waypoint - cargo of
    // OTHER groups disembarks at the drop point. Both waypoints sit at the contested center with a
    // completion radius of _unloadDist, so they complete when the truck crosses the stand-off ring.
    private _sendTruckSquad = {
        params ["_truck"];
        private _drvGrp = _truck getVariable ["MISSION_CORE_DRIVER_GROUP", grpNull];
        // Passengers stay seated until the drop point: AUTOCOMBAT off so they never bail out under
        // fire, combat mode GREEN so they hold fire while riding.
        {
            if (vehicle _x == _truck) then { _x disableAI "AUTOCOMBAT"; };
        } forEach units _group;
        [_group, _targetPos, "GETOUT", _advSpeed, "GREEN", _unloadDist] call _addAssaultWps;
        // The passenger group's own GETOUT (added first by _addAssaultWps) unloads them on arrival
        // via a waypoint script (matching the recruit menu) instead of a bare engine GETOUT.
        {
            if (waypointType _x == "GETOUT") then { _x setWaypointScript "transport_assaultUnload.sqf"; };
        } forEach (waypoints _group);
        if (!isNull _drvGrp) then {
            [_drvGrp] call MISSION_CORE_fnc_clearGroupWaypoints;
            // CARELESS + GREEN so the truck drives straight to the drop ring instead of stopping
            // to engage en route (a stationary truck gives passengers a chance to bail out early)
            _drvGrp setCombatMode "GREEN";
            _drvGrp setBehaviour "CARELESS";
            // MOVE first (pre-1.22 rule), then TRANSPORT UNLOAD at the same ring to drop cargo.
            private _wpDrvMove = _drvGrp addWaypoint [_targetPos, _unloadDist];
            _wpDrvMove setWaypointType "MOVE";
            _wpDrvMove setWaypointSpeed _advSpeed;
            _wpDrvMove setWaypointBehaviour "CARELESS";
            private _wpUnload = _drvGrp addWaypoint [_targetPos, _unloadDist];
            _wpUnload setWaypointType "TR UNLOAD";
            _wpUnload setWaypointSpeed _advSpeed;
            _wpUnload setWaypointBehaviour "CARELESS";
            _drvGrp setCurrentWaypoint _wpDrvMove;
        };
        [_group, _truck, _side, _targetPos, 1, _unloadDist] spawn MISSION_CORE_fnc_splitAfterDismount;
    };

    private _veh = vehicle _ldr;
    if (_veh != _ldr) then {
        // Already vehicle-mounted
        private _vehHasGun = [_veh] call MISSION_CORE_fnc_hasMountedGun;
        if (_vehHasGun || { !([_veh] call MISSION_CORE_fnc_isSoftTransport) }) then {
            // Gun vehicle or armor: crew stays in - MOVE to the advance point, then SAD
            [_group, _dismountPos, "MOVE", _advSpeed] call _addAssaultWps;
        } else {
            // Unarmed truck-mounted foot squad: move to 100m short of the contested center,
            // disembark (GETOUT + TRANSPORT UNLOAD), then SAD. GREEN (hold fire) while riding.
            [_veh] call _sendTruckSquad;
        };
    } else {
        // 3. Foot patrol: only squads 700m or farther from the contested area mount a truck to
        //    ride to the advance point, disembark, then assault on foot. Squads already inside
        //    700m just advance on foot. Never truck-mount toward a target no player is near -
        //    that only produces foot patrols driving to empty markers across the map.
        private _nearPlayers = allPlayers findIf { alive _x && { _x distance _targetPos < 2000 } } != -1;
        if ((leader _group) distance _targetPos >= 700 && { _nearPlayers }) then {
            private _truck = [_group, _side, getPos _ldr] call MISSION_CORE_fnc_mountInfantry;
            if (!isNull _truck) then {
                diag_log format ["AI COMMAND: %1 foot patrol (%2 men) from %3 boarding %4 -> contested %5", groupId _group, count units _group, _originName, typeOf _truck, _targetPos];
                if ([_truck] call MISSION_CORE_fnc_hasMountedGun) then {
                    // Gun truck - fight from the vehicle, crew stays in
                    [_group, _dismountPos, "MOVE", _advSpeed] call _addAssaultWps;
                } else {
                    // After everyone dismounts, split the foot infantry into a separate group so they
                    // never re-board; the driver stays with the truck and drives it away
                    [_truck] call _sendTruckSquad;
                };
            } else {
                // No transport available - advance on foot, then SAD
                diag_log format ["AI COMMAND: %1 foot patrol (%2 men) from %3 no transport - advancing on foot to %4", groupId _group, count units _group, _originName, _targetPos];
                [_group, _dismountPos, "MOVE", _advSpeed] call _addAssaultWps;
                [_group, _targetPos, _side] spawn MISSION_CORE_fnc_footSquadPostAssault;
            };
        } else {
            // Inside 700m of the contested area - advance on foot, then SAD
            diag_log format ["AI COMMAND: %1 foot patrol (%2 men) from %3 within 700m - advancing on foot to %4", groupId _group, count units _group, _originName, _targetPos];
            [_group, _dismountPos, "MOVE", _advSpeed] call _addAssaultWps;
            [_group, _targetPos, _side] spawn MISSION_CORE_fnc_footSquadPostAssault;
        };
    };
};
