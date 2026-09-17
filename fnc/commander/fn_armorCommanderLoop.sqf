
MISSION_CORE_fnc_armorCommanderLoop = {
    diag_log "AI ARMOR COMMANDER: Started";
    while { true } do {
        sleep 10 + random 5;
        // Snapshot the live engine unit/group lists ONCE per tick and reuse them across the side and
        // group loops below. Calling allUnits/allGroups repeatedly (per group, per location) refetches
        // and allocates a fresh list each time - a huge CPU cost on large maps. The snapshot is
        // behavior-neutral: allUnits/allGroups only change between frames, not mid-script.
        private _allUnits = allUnits;
        private _allGroups = allGroups;
        // PERMANENT RULE: gun vehicles keep their crew inside even when the hull is immobile. A few
        // blown tires or a lost track must never make the crew bail out and get cut down in the open
        // - tank, APC and gun-truck crews fight from the vehicle to the end. Covers every vehicle
        // regardless of which path spawned it (recruit, defense, reinforcement, patrol, escort).
        // PERF: rescan only when the server's vehicle list changed size (something spawned or died).
        // Crews are already-flagged once handled, so a stable battlefield costs ~nothing per tick
        // instead of iterating/hasMountedGun-ing the entire vehicle list every ~12s.
        if (isNil "MISSION_CORE_CREW_VEH_COUNT") then { MISSION_CORE_CREW_VEH_COUNT = -1; };
        private _vehCount = count vehicles;
        if (_vehCount != MISSION_CORE_CREW_VEH_COUNT) then {
            MISSION_CORE_CREW_VEH_COUNT = _vehCount;
            {
                if (!(_x getVariable ["MISSION_CORE_CREW_IN_IMMOBILE", false]) && { [_x] call MISSION_CORE_fnc_hasMountedGun }) then {
                    _x allowCrewInImmobile true;
                    _x setVariable ["MISSION_CORE_CREW_IN_IMMOBILE", true, true];
                };
            } forEach vehicles;
        };
        {
            private _side = _x;
            private _sideVar = if (_side == WEST) then { "MISSION_CORE_BLUFOR" } else { "MISSION_CORE_REDFOR" };
            private _enemySide = if (_side == WEST) then { EAST } else { WEST };
            private _armorGroups = _allGroups select {
                _x getVariable [_sideVar, false] &&
                { (_x getVariable ["MISSION_CORE_ARMOR_SLOT", ""]) in ["mbt", "mech"] } &&
                { count units _x > 0 }
                // Garrison-deployed armor (player GARRISON tab: delivered tanks + APC/vehicle recruits)
                // is INCLUDED so it defends in place and patrols its marker - but it never counter-
                // attacks or assaults an enemy location (skipped in P2/P3 below). Players decide when
                // those vehicles move.
            };

            // Free the cap: when this side is about to attack or counter-attack, despawn idle
            // armor not covering a player; kept armor attack-moves instead
            if (isNil "MISSION_CORE_OVERWATCH_DESPAWN_COOLDOWN") then { MISSION_CORE_OVERWATCH_DESPAWN_COOLDOWN = createHashMap; };
            if (time > (MISSION_CORE_OVERWATCH_DESPAWN_COOLDOWN getOrDefault [_side, 0])) then {
                private _enemyLocs = MISSION_CORE_LOCATIONS select { (_x select 5) == _enemySide };
                private _assaultTarget = [];
                {
                    private _home = _x getVariable ["MISSION_CORE_MARKER_CENTER", getPos leader _x];
                    {
                        private _lPos = (_x select 1) select 0;
                        if (_home distance _lPos < 2500) then { _assaultTarget = _lPos; };
                    } forEach _enemyLocs;
                } forEach _armorGroups;
                if (count _assaultTarget > 0) then {
                    MISSION_CORE_OVERWATCH_DESPAWN_COOLDOWN set [_side, time + 180];
                    [_side, _assaultTarget, 800] call MISSION_CORE_fnc_despawnOverwatchTanks;
                };
            };
            // Despawn AA overwatch tanks whenever this side is attacking (marker assault, armor attack, counter-attack)
            if (isNil "MISSION_CORE_AA_DESPAWN_COOLDOWN") then { MISSION_CORE_AA_DESPAWN_COOLDOWN = createHashMap; };
            if (time > (MISSION_CORE_AA_DESPAWN_COOLDOWN getOrDefault [_side, 0])) then {
                private _isAttacking = false;
                if (_side == EAST && !(isNil "MISSION_CORE_ASSAULT_ACTIVE")) then { _isAttacking = MISSION_CORE_ASSAULT_ACTIVE; };
                if (!_isAttacking) then {
                    _isAttacking = _allGroups findIf {
                        _x getVariable [_sideVar, false] &&
                        { (_x getVariable ["MISSION_CORE_ORDER", ""]) in ["attack", "counterattack"] }
                    } > -1;
                };
                if (_isAttacking) then {
                    MISSION_CORE_AA_DESPAWN_COOLDOWN set [_side, time + 60];
                    [_side] call MISSION_CORE_fnc_despawnAATanks;
                };
            };
            {
                private _grp = _x;
                private _homePos = _grp getVariable ["MISSION_CORE_MARKER_CENTER", getPos leader _grp];
                _homePos = [_homePos, getPos leader _grp] call MISSION_CORE_fnc_safeWaypointPos;
                private _cooldown = _grp getVariable ["MISSION_CORE_ARMOR_COOLDOWN", 0];

                // MECH IMMOBILE DISMOUNT: a mech APC that can no longer move stays behind and must not
                // trap its infantry. The riders split out into their OWN group (so the foot leader
                // takes over and they keep fighting on foot), while the APC + crew hold in place.
                // Runs once per vehicle - a variable flag stops re-ejection after the tractor settles.
                if ((_grp getVariable ["MISSION_CORE_ARMOR_SLOT", ""]) == "mech") then {
                    private _apc = objNull;
                    {
                        private _v = vehicle _x;
                        if (_v != _x && { (_v isKindOf "APC" || _v isKindOf "Wheeled_APC" || _v isKindOf "Tracked_APC") && { (_v getVariable ["MISSION_CORE_MECH_IMMOBILE_DISMOUNTED", false]) == false } }) exitWith { _apc = _v; };
                    } forEach units _grp;
                    if (!isNull _apc) then {
                        // Riders = cargo infantry (in the APC but not driving/gunning/commanding).
                        private _crewSet = [driver _apc, gunner _apc, commander _apc] select { !isNull _x };
                        private _riders = units _grp select {
                            if (vehicle _x != _apc || { !alive _x }) exitWith { false };
                            private _u = _x;
                            _crewSet findIf { _x == _u } < 0
                        };
                        if (count _riders > 0 && { !canMove _apc }) then {
                            _apc setVariable ["MISSION_CORE_MECH_IMMOBILE_DISMOUNTED", true];
                            private _side = side _grp;
                            private _newGrp = createGroup _side;
                            _riders joinSilent _newGrp;
                            {
                                private _v = _grp getVariable [_x, nil];
                                if (!isNil "_v") then { _newGrp setVariable [_x, _v]; };
                            } forEach ["MISSION_CORE_BLUFOR", "MISSION_CORE_REDFOR", "MISSION_CORE_ORIGIN_MARKER", "MISSION_CORE_MARKER_CENTER", "MISSION_CORE_IMPORTANCE", "MISSION_CORE_ORDER", "MISSION_CORE_ATTACK_TARGET"];
                            // Foot leader owns the new squad - clear persistent vars that would make the
                            // armor loop re-claim it as a riding APC group.
                            _newGrp setVariable ["MISSION_CORE_ARMOR_SLOT", ""];
                            _newGrp setVariable ["MISSION_CORE_IDLE", false];
                            _newGrp setVariable ["MISSION_CORE_PATROLLING", false];
                            leader _newGrp setVariable ["MISSION_CORE_PATROLLING", false];
                            _newGrp setBehaviour "AWARE";
                            _newGrp setCombatMode "RED";
                            _newGrp setSpeedMode "FULL";
                            if (isNil "MISSION_CORE_SPAWNED_GROUPS") then { MISSION_CORE_SPAWNED_GROUPS = []; };
                            MISSION_CORE_SPAWNED_GROUPS pushBack _newGrp;
                            // Continue the march: SAD the same target the APC was driving toward, so the
                            // dismounted squad still rolls onto the objective on foot.
                            private _driveTarget = _grp getVariable ["MISSION_CORE_ATTACK_TARGET", [0, 0, 0]];
                            if (count _driveTarget < 2) then {
                                private _cw = currentWaypoint _grp;
                                if (_cw >= 0) then { _driveTarget = waypointPosition [_grp, _cw]; };
                            };
                            [_newGrp] call MISSION_CORE_fnc_clearGroupWaypoints;
                            if (count _driveTarget >= 2) then {
                                private _wp = _newGrp addWaypoint [_driveTarget, 60];
                                _wp setWaypointType "SAD";
                                _wp setWaypointSpeed "FULL";
                                _wp setWaypointBehaviour "AWARE";
                                _newGrp setCurrentWaypoint _wp;
                            };
                            // The APC group now sits without riders - clear its march orders so it holds
                            // behind instead of trying to drive a broken hull against the target.
                            [_grp] call MISSION_CORE_fnc_clearGroupWaypoints;
                            _grp setVariable ["MISSION_CORE_ORDER", "defend"];
                            diag_log format ["AI ARMOR: %1 mech APC immobilised mid-march -> %2 riders dismounted to own foot group", groupId _grp, count _riders];
                        };
                    };
                };

                // Priority 1 - DEFEND: enemy units near home position
                private _defendEnemies = _allUnits select {
                    side _x == _enemySide && { alive _x } && { _x distance _homePos < 1000 }
                };
                if (count _defendEnemies > 0) then {
                    private _nearest = _defendEnemies select 0;
                    { if (_x distance _homePos < (_nearest distance _homePos)) then { _nearest = _x; }; } forEach _defendEnemies;
                    private _order = _grp getVariable ["MISSION_CORE_ORDER", ""];
                    // A group already committed to a battle keeps its orders - re-yanking it home
                    // every cycle is what made mech squads shuttle between "defending home" and
                    // the contested marker. "hunt" drivers are on a player-hunt sweep, never recalled.
                    if (_order in ["attack", "counterattack", "reinforce", "hunt"]) then { continue; };
                    if (_order != "defend") then {
                        diag_log format ["AI ARMOR: %1 %2 defending home", _side, groupId _grp];
                        _grp setVariable ["MISSION_CORE_ORDER", "defend"];
                        _grp setVariable ["MISSION_CORE_IDLE", false];
                        _grp setVariable ["MISSION_CORE_PATROLLING", false];
                        [_grp] call MISSION_CORE_fnc_clearGroupWaypoints;
                        private _wp = _grp addWaypoint [getPos _nearest, 50];
                        _wp setWaypointType "SAD";
                        _wp setWaypointSpeed "FULL";
                        _wp setWaypointBehaviour "COMBAT";
                        _grp setCurrentWaypoint _wp;
                        _grp setCombatMode "RED";
                    };
                    continue;
                };

                // Patrol: WEST armor that is idle and safe cycles the outer edge of its marker at
                // LIMITED speed instead of sitting parked. Garrison tanks (player-bought defenders)
                // follow the same ring around their own marker - they hold position but stay mobile.
                private _isGarrison = _grp getVariable ["MISSION_CORE_GARRISON", false];
                if (_side == WEST && time > _cooldown) then {
                    private _order = _grp getVariable ["MISSION_CORE_ORDER", ""];
                    if (!(_grp getVariable ["MISSION_CORE_PATROLLING", false]) && { !(_order in ["attack", "counterattack", "reinforce", "hunt"]) }) then {
                        private _oMkr = _grp getVariable ["MISSION_CORE_ORIGIN_MARKER", ""];
                        private _pMA = 200;
                        private _pMB = 200;
                        private _pDir = 0;
                        if (_oMkr != "" && { !(isNil "MISSION_CORE_CACHED_POSITIONS") }) then {
                            private _ploc = MISSION_CORE_CACHED_POSITIONS findIf { (_x select 0) == _oMkr };
                            if (_ploc >= 0) then {
                                private _sz = (MISSION_CORE_CACHED_POSITIONS select _ploc) select 8;
                                if (_sz isEqualType []) then {
                                    _pMA = (_sz select 0) max 100;
                                    _pMB = if (count _sz > 1) then { (_sz select 1) max 100 } else { _pMA };
                                    _pDir = if (count _sz > 2) then { _sz select 2 } else { 0 };
                                };
                            };
                        };
                        // Ring around the outer edge (0.85 of the half-extents), CYCLE to loop.
                        [_grp] call MISSION_CORE_fnc_clearGroupWaypoints;
                        for "_pi" from 0 to 3 do {
                            private _pang = 45 + (_pi * 90);
                            private _pox = 0.85 * _pMA * cos _pang;
                            private _poy = 0.85 * _pMB * sin _pang;
                            private _prx = _pox * cos _pDir - _poy * sin _pDir;
                            private _pry = _pox * sin _pDir + _poy * cos _pDir;
                            private _ppos = [(_homePos select 0) + _prx, (_homePos select 1) + _pry, 0];
                            private _pwp = _grp addWaypoint [_ppos, 0];
                            _pwp setWaypointType "MOVE";
                            _pwp setWaypointSpeed "LIMITED";
                            _pwp setWaypointBehaviour "SAFE";
                        };
                        private _cwp = _grp addWaypoint [_homePos, 0];
                        _cwp setWaypointType "CYCLE";
                        _cwp setWaypointSpeed "LIMITED";
                        _cwp setWaypointBehaviour "SAFE";
                        _grp setCurrentWaypoint [_grp, 0];
                        _grp setVariable ["MISSION_CORE_ORDER", "patrol"];
                        _grp setVariable ["MISSION_CORE_PATROLLING", true];
                        _grp setVariable ["MISSION_CORE_ARMOR_COOLDOWN", time + 300 + random 300];
                        diag_log format ["AI ARMOR: %1 %2 patrolling outer edge of %3", _side, groupId _grp, if (_oMkr == "") then { "home" } else { _oMkr }];
                    };
                };
                // Garrison-deployed armor defends its own marker only - the player decides when
                // those tanks leave. It never counter-attacks or assaults an enemy location.
                // Config "garrisonStaysHome" (default 1): set 0 to let garrison armor take part in
                // counter-attacks and assaults like any other armor.
                private _staysHome = ["garrisonStaysHome", 1] call MISSION_CORE_fnc_tune;
                diag_log format ["AIM ARMOR LOOP: %1 grp=%2 isGarrison=%3 staysHome=%4 order=%5", _side, groupId _grp, _isGarrison, _staysHome, _grp getVariable ["MISSION_CORE_ORDER", ""]];
                if (_isGarrison && { _staysHome > 0 }) then { continue; };

                // Priority 2 - COUNTER-ATTACK: friendly location under threat
                private _threatLoc = [0, 0, 0];
                private _foundThreat = false;
                private _threatDist = 999999;
                {
                    private _lOwner = _x select 5;
                    private _lPos = (_x select 1) select 0;
                    if (_lOwner == _side) then {
                        private _enemyNear = _allUnits select { side _x == _enemySide && { alive _x } && { _x distance _lPos < 900 } };
                        if (count _enemyNear > 0) then {
                            private _d = _homePos distance _lPos;
                            if (_d < _threatDist) then { _threatDist = _d; _threatLoc = _lPos; _foundThreat = true; };
                        };
                    };
                } forEach MISSION_CORE_LOCATIONS;
                if (_foundThreat && time > _cooldown) then {
                    private _order = _grp getVariable ["MISSION_CORE_ORDER", ""];
                    if (_order != "counterattack" && { _order != "hunt" }) then {
                        diag_log format ["AI ARMOR: %1 %2 counter-attacking to defend friendly loc", _side, groupId _grp];
                        _grp setVariable ["MISSION_CORE_ORDER", "counterattack"];
                        _grp setVariable ["MISSION_CORE_IDLE", false];
                        _grp setVariable ["MISSION_CORE_PATROLLING", false];
                        [_grp] call MISSION_CORE_fnc_clearGroupWaypoints;
                        private _wp = _grp addWaypoint [_threatLoc, 50];
                        _wp setWaypointType "SAD";
                        _wp setWaypointSpeed "FULL";
                        _wp setWaypointBehaviour "COMBAT";
                        _grp setCurrentWaypoint _wp;
                        _grp setCombatMode "RED";
                    };
                    continue;
                };

                // Priority 3 - ATTACK: nearest enemy location within range
                if (time > _cooldown) then {
                    private _enemyLocs = MISSION_CORE_LOCATIONS select { (_x select 5) == _enemySide };
                    if (count _enemyLocs > 0) then {
                        private _nearestLoc = _enemyLocs select 0;
                        private _nD = _homePos distance ((_nearestLoc select 1) select 0);
                        {
                            private _d = _homePos distance ((_x select 1) select 0);
                            if (_d < _nD) then { _nD = _d; _nearestLoc = _x; };
                        } forEach _enemyLocs;
                        private _order = _grp getVariable ["MISSION_CORE_ORDER", ""];
                        if (_nD < 2500 && !(_order in ["attack", "counterattack", "reinforce", "hunt"])) then {
                            diag_log format ["AI ARMOR: %1 %2 attacking %3", _side, groupId _grp, _nearestLoc select 0];
                            _grp setVariable ["MISSION_CORE_ORDER", "attack"];
                            _grp setVariable ["MISSION_CORE_IDLE", false];
                            _grp setVariable ["MISSION_CORE_PATROLLING", false];
                            [_grp] call MISSION_CORE_fnc_clearGroupWaypoints;
                            private _wp = _grp addWaypoint [(_nearestLoc select 1) select 0, 50];
                            _wp setWaypointType "SAD";
                            _wp setWaypointSpeed "FULL";
                            _wp setWaypointBehaviour "COMBAT";
                            _grp setCurrentWaypoint _wp;
                            _grp setCombatMode "RED";
                            _grp setVariable ["MISSION_CORE_ARMOR_COOLDOWN", time + 300 + random 300];
                        };
                    };
                };
            } forEach _armorGroups;
        } forEach [WEST, EAST];
    };
};
