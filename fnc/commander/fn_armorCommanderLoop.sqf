
MISSION_CORE_fnc_armorCommanderLoop = {
    diag_log "AI ARMOR COMMANDER: Started";
    while { true } do {
        sleep 10 + random 5;
        {
            private _side = _x;
            private _sideVar = if (_side == WEST) then { "MISSION_CORE_BLUFOR" } else { "MISSION_CORE_REDFOR" };
            private _enemySide = if (_side == WEST) then { EAST } else { WEST };
            private _armorGroups = allGroups select {
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
                    _isAttacking = allGroups findIf {
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

                // Priority 1 - DEFEND: enemy units near home position
                private _defendEnemies = allUnits select {
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
                        private _enemyNear = allUnits select { side _x == _enemySide && { alive _x } && { _x distance _lPos < 900 } };
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
