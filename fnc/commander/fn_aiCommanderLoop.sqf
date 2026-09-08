
MISSION_CORE_fnc_aiCommanderLoop = {
    diag_log "AI COMMANDER: Started";
    while { true } do {
        sleep 8 + random 5;
        private _players = allPlayers select { alive _x };
        // Snapshot the live engine lists ONCE per tick and reuse them across every marker below.
        // Calling allUnits/allGroups per marker refetches + allocates a full list each time - a
        // major CPU cost on large maps. The snapshot is behavior-neutral: the lists only change
        // between frames, not while this loop-body runs.
        private _snapUnits = allUnits;
        private _snapGroups = allGroups;

        {
            private _loc = _x;
            private _markerName = _loc select 0;
            private _locPos = _loc select 1 select 0;
            private _locOwner = _loc select 5;
            // Importance is at index 7 in the location array - read it directly instead of doing
            // a per-tick linear findIf on CACHED_POSITIONS (both arrays carry importance at index 7).
            private _importance = _loc select 7;
            // BLU DEFEND order: blue units engaged very near their spawn point stop attacking and defend
            if (_locOwner == WEST) then {
                private _detectRadiusW = 600 + (_importance * 200);
                private _bluDefenders = [_locPos, _detectRadiusW, _snapGroups] call MISSION_CORE_fnc_getBluDefendersAt;
                private _bluEnemies = _snapUnits select { side _x == EAST && { _x distance _locPos < _detectRadiusW } };
                private _bluDetected = false;
                private _bluPlayer = objNull;
                private _maxKnows = 0;
                {
                    private _knows = if (count _bluEnemies > 0) then { _x knowsAbout (_bluEnemies select 0) } else { 0 };
                    if (_knows > _maxKnows) then { _maxKnows = _knows; _bluPlayer = _x; };
                    if (_knows > 1.2) then { _bluDetected = true; };
                } forEach _players;
                if (_bluDetected && !isNull _bluPlayer) then {
                    // Defend the MARKER, not the player's position - BLUFOR defenders hold their
                    // friendly marker center so they never run out into the open chasing a player.
                    {
                        if (_x getVariable ["MISSION_CORE_ORDER", ""] != "defendSpawn") then {
                            _x setVariable ["MISSION_CORE_ORDER", "defendSpawn"];
                            _x setVariable ["MISSION_CORE_IDLE", false];
                            _x setVariable ["MISSION_CORE_PATROLLING", false];
                            leader _x setVariable ["MISSION_CORE_PATROLLING", false];
                            [_x] call MISSION_CORE_fnc_clearGroupWaypoints;
                            if ([(vehicle (leader _x))] call MISSION_CORE_fnc_isSoftTransport && { !([(vehicle (leader _x))] call MISSION_CORE_fnc_hasMountedGun) }) then {
                                private _wpU = _x addWaypoint [_locPos, 100];
                                _wpU setWaypointType "GETOUT";
                                _wpU setWaypointSpeed "FULL";
                                _wpU setWaypointBehaviour "AWARE";
                            };
                            private _wp = _x addWaypoint [_locPos, 50];
                            _wp setWaypointType "SAD";
                            _wp setWaypointSpeed "FULL";
                            _wp setWaypointBehaviour "COMBAT";
                            _x setCurrentWaypoint _wp;
                            _x setCombatMode "RED";
                        };
                    } forEach _bluDefenders;
                } else {
                    {
                        if !(leader _x getVariable ["MISSION_CORE_PATROLLING", false]) then {
                            [_x] call MISSION_CORE_fnc_restartPatrol;
                        };
                    } forEach _bluDefenders;
                };
            };
            if (_locOwner != EAST) then {};
            private _detectRadius = 600 + (_importance * 200);
            private _engageRadius = 200 + (_importance * 100);
            private _reinforceRadius = 1200 + (_importance * 600);

            private _defenders = [_locPos, _detectRadius, _snapGroups] call MISSION_CORE_fnc_getDefendersAt;
            if (count _defenders == 0) then {};

            private _nearestEnemy = objNull;
            // The units a player would be ENGAGING at this EAST marker are the EAST garrison, not
            // their own WEST side - so player knowsAbout of these is the real "player is attacking"
            // signal. (Previously this selected WEST units, which a WEST player knows about at ~0,
            // so the proximity fallback below was doing all the work and firing battles constantly.)
            private _enemies = _snapUnits select { side _x == EAST && { _x distance _locPos < _detectRadius } };
            if (count _enemies > 0) then { _nearestEnemy = _enemies select 0; };

            private _detected = false;
            private _nearestPlayer = objNull;
            private _maxKnows = 0;
            // PERMANENT RULE: a battle only starts when a player has ACTUALLY engaged the garrison
            // (knowsAbout > 1.2 of any enemy unit near the marker). Proximity alone must never
            // count: a player standing near a spawned marker without attacking must not make the
            // AI counter-attack, truck reinforcements across the map, or build defenses there.
            {
                private _p = _x;
                private _knows = 0;
                { private _k = _p knowsAbout _x; if (_k > _knows) then { _knows = _k; }; } forEach _enemies;
                if (_knows > _maxKnows) then { _maxKnows = _knows; _nearestPlayer = _p; };
                if (_knows > 1.2) then { _detected = true; };
            } forEach _players;

            if (_detected && !isNull _nearestPlayer) then {
                // Track this marker as an active battle so contested targeting (replenish, commit)
                // keeps pointing at it even before the player "spots" the garrison. Newly spawned
                // patrols get committed on later ticks while the battle stays active.
                if (isNil "MISSION_CORE_ACTIVE_BATTLES") then { MISSION_CORE_ACTIVE_BATTLES = createHashMap; };
                if (side _nearestPlayer != _locOwner) then { MISSION_CORE_ACTIVE_BATTLES set [_markerName, time]; };
                // Battle grace memory: stamp how long this real detection keeps the quadrant
                // response alive. Once sight is lost the loop below still streams the staged foot
                // groups in for quadrantGraceTime instead of purging them the moment contact decays.
                if (isNil "MISSION_CORE_QUAD_GRACE") then { MISSION_CORE_QUAD_GRACE = createHashMap; };
                MISSION_CORE_QUAD_GRACE set [_markerName, time + floor (["quadrantGraceTime", 600] call MISSION_CORE_fnc_tune)];
                // Downstream counter-attack / assault armor still targets the nearest engaged player.
                private _targetPos = getPos _nearestPlayer;

                // QUADRANT ENGAGEMENT: collect EVERY player with real contact on this garrison (not
                // just the nearest) so multiple players spread around the marker split the defensive
                // foot force by quadrant instead of everyone chasing one point.
                private _engagedPlayers = [];
                {
                    private _p = _x;
                    private _k = 0;
                    { private _kk = _p knowsAbout _x; if (_kk > _k) then { _k = _kk; }; } forEach _enemies;
                    if (_k > 1.2) then { _engagedPlayers pushBack _p; };
                } forEach _players;

                [_loc, _engagedPlayers, _defenders, _markerName, _locPos, _engageRadius] call MISSION_CORE_fnc_quadrantEngage;

                // REINFORCEMENT - existing spawned groups are committed the moment battle starts,
                // never held back as if queued. Each fast-moves to the marker edge and
                // search-and-destroys the center (mirrors the HQ alert behavior).
                private _reinforceRadiusScaled = _reinforceRadius * (1 + (_importance - 1) * 0.25);
                private _mkrArea = _loc select 1;
                private _mkrSize = if (count _mkrArea > 1) then { _mkrArea select 1 } else { [200, 200] };
                // Commit every spawned group of the side regardless of distance - far AI must join too
                [EAST, _locPos, _mkrSize, 1e10] call MISSION_CORE_fnc_commitToBattle;

                // NEIGHBOR REINFORCE (PERMANENT RULE): the closest friendly markers dispatch
                // reinforcements to a marker under attack. Up to 3 markers send troops; the
                // neighbors do not need their own defenses spawned - they only send reinforcements.
                [_markerName, _locPos, _locOwner, _importance] call MISSION_CORE_fnc_neighborCounterAttack;

                // BLUFOR SUPPORT: while a player attacks this EAST marker (it is one of the side's contested
                // zones - one zone per player), BLUFOR AI assembles a support force from the closest
                // BLUFOR marker (foot + mech + tanks) and SADs that zone via the same
                // assemble/transport pipeline. 10min cooldown per zone.
                // PERMANENT RULE: every contested zone gets its OWN support force (one zone per
                // attacking player). A player's knowsAbout can leak to nearby non-zone markers,
                // so support is gated on zone membership, not "closest target".
                private _eastZones = [EAST] call MISSION_CORE_fnc_getContestedMarkers;
                private _isZone = (_eastZones findIf { (_x select 0) == _markerName } != -1);
                private _bluforAutoAttack = ["bluforAutoAttack", 0] call MISSION_CORE_fnc_tune;
                if (_bluforAutoAttack > 0 && { _locOwner == EAST && { _isZone } }) then {
                    if (isNil "MISSION_CORE_BLUFOR_SUPPORT_COOLDOWN") then { MISSION_CORE_BLUFOR_SUPPORT_COOLDOWN = createHashMap; };
                    private _bsLast = MISSION_CORE_BLUFOR_SUPPORT_COOLDOWN getOrDefault [_markerName, -99999];
                    if (time - _bsLast >= 600) then {
                        private _blu = MISSION_CORE_CACHED_POSITIONS select { (_x select 4) == WEST };
                        if (count _blu > 0) then {
                            private _bBest = _blu select 0;
                            private _bBestD = (_bBest select 1) distance2D _locPos;
                            {
                                private _bd = (_x select 1) distance2D _locPos;
                                if (_bd < _bBestD) then { _bBestD = _bd; _bBest = _x; };
                            } forEach _blu;
                            MISSION_CORE_BLUFOR_SUPPORT_COOLDOWN set [_markerName, time];
                            diag_log format ["AI COMMANDER: BLUFOR support assembling from %1 -> contested %2", _bBest select 0, _markerName];
                            [WEST, _bBest select 1, _locPos, _importance, _bBest select 0] call MISSION_CORE_fnc_assembleAssault;
                        };
                    };
                };

                // COUNTER-ATTACK (importance >= 3) - each contested zone mounts a full
                // counter-attack; non-zone markers just defend/patrol
                if (_importance >= 3 && _isZone) then {
                    // AMMO: a full counter-attack needs ammo. Zone markers without enough ammo
                    // stay on the defensive and do not mount the assault ("assembleAssault").
                    private _canCounter = [_markerName] call MISSION_CORE_fnc_ammoCanAttack;
                    // Full assault: free the cap, then spawn up to 2 tank markers + 1 inf marker
                    if (_locOwner == EAST && _canCounter) then {
                        if (isNil "MISSION_CORE_COUNTERATTACK_COOLDOWN") then { MISSION_CORE_COUNTERATTACK_COOLDOWN = createHashMap; };
                        if (time > (MISSION_CORE_COUNTERATTACK_COOLDOWN getOrDefault [_markerName, 0])) then {
                            MISSION_CORE_COUNTERATTACK_COOLDOWN set [_markerName, time + 600];
                            [_markerName, ["ammoCostCounterAttack", 2] call MISSION_CORE_fnc_tune] call MISSION_CORE_fnc_consumeAmmo;
                            [EAST, _locPos, _targetPos, _importance, _markerName] call MISSION_CORE_fnc_assembleAssault;
                        };
                    };

                    private _counterRadius = _reinforceRadiusScaled * 1.5;
                    private _counterGroups = _snapGroups select {
                        _x getVariable ["MISSION_CORE_REDFOR", false] &&
                        _x getVariable ["MISSION_CORE_ORDER", ""] == "" &&
                        { (leader _x) distance _locPos < _counterRadius } &&
                        { !(_x getVariable ["MISSION_CORE_IDLE", true]) }
                    };
                    {
                        private _cgImp = _x getVariable ["MISSION_CORE_IMPORTANCE", 1];
                        if (_canCounter && { random 1 < (_cgImp * 0.15) }) then {
                            diag_log format ["AI COMMANDER: counter-attack %1", groupId _x];
                            [_x, _targetPos] call MISSION_CORE_fnc_sendCounterAttack;
                        };
                    } forEach _counterGroups;

                    // Send vehicle groups (Mech/Armor) directly as assault force
                    private _vehGroups = _snapGroups select {
                        _x getVariable ["MISSION_CORE_REDFOR", false] &&
                        _x getVariable ["MISSION_CORE_IDLE", true] &&
                        _x getVariable ["MISSION_CORE_ORDER", ""] == "" &&
                        { (leader _x) distance _locPos < _counterRadius * 1.2 } &&
                        { count units _x > 0 && { vehicle (leader _x) != leader _x } }
                    };
                    {
                        if (_canCounter && { random 1 < 0.6 }) then {
                            diag_log format ["AI COMMANDER: vehicle assault %1", groupId _x];
                            [_x, _targetPos] call MISSION_CORE_fnc_sendCounterAttack;
                        };
                    } forEach _vehGroups;
                };

                // FAR REINFORCE (importance >= 4)
                if (_importance >= 4) then {
                    private _farRadius = _reinforceRadiusScaled * 2;
                    private _farReinforce = _snapGroups select {
                        _x getVariable ["MISSION_CORE_REDFOR", false] &&
                        _x getVariable ["MISSION_CORE_IDLE", true] &&
                        _x getVariable ["MISSION_CORE_ORDER", ""] == "" &&
                        { (leader _x) distance _locPos < _farRadius }
                    };
                    {
                        if (random 1 < 0.4) then {
                            diag_log format ["AI COMMANDER: far reinforce %1", groupId _x];
                            [_x, _locPos, "FULL"] call MISSION_CORE_fnc_sendReinforce;
                        };
                    } forEach _farReinforce;
                };
                // Supply drain while under detection (combat attrition)
                private _curSupply = MISSION_CORE_LOCATION_SUPPLY getOrDefault [_markerName, 0];
                if (_curSupply > 0) then {
                    MISSION_CORE_LOCATION_SUPPLY set [_markerName, _curSupply - 1];
                    if (_curSupply <= _importance * 5) then {
                        private _lastReinf = MISSION_CORE_SUPPLY_COOLDOWN getOrDefault [_markerName, -9999];
                        if (time - _lastReinf > 120) then {
                            MISSION_CORE_SUPPLY_COOLDOWN set [_markerName, time];
                            [_markerName] call MISSION_CORE_fnc_requestReinforcement;
                        };
                    };
                };
            } else {
                // No live detection this tick. A marker that was GENUINELY detected keeps its
                // quadrant response streaming for quadrantGraceTime after the last contact: the
                // staged foot groups still release (players still near the marker act as soft
                // targets until sight returns) instead of the force melting back to patrol the
                // instant the AI's knowsAbout decays below the contact threshold.
                if (isNil "MISSION_CORE_QUAD_GRACE") then { MISSION_CORE_QUAD_GRACE = createHashMap; };
                private _grEnd = MISSION_CORE_QUAD_GRACE getOrDefault [_markerName, -1e10];
                if (time < _grEnd) then {
                    private _gracePlayers = [];
                    {
                        if (_x distance _locPos < _engageRadius) then { _gracePlayers pushBack _x; };
                    } forEach _players;
                    if (count _gracePlayers > 0) then {
                        [_loc, _gracePlayers, _defenders, _markerName, _locPos, _engageRadius] call MISSION_CORE_fnc_quadrantEngage;
                    };
                } else {
                    MISSION_CORE_QUAD_GRACE deleteAt _markerName;
                    // Grace fully lapsed: groups return to patrol. Keep the battle flag for a 120s
                    // grace so a just-wiped garrison still reads as CONTESTED and the capture can
                    // fire. Also purge this marker's staged quadrant tasks so no stale SAD lingers.
                    if !(isNil "MISSION_CORE_QUAD_BACKLOG") then {
                        MISSION_CORE_QUAD_BACKLOG = MISSION_CORE_QUAD_BACKLOG select { (_x select 0) != _markerName };
                    };
                    if !(isNil "MISSION_CORE_ACTIVE_BATTLES") then {
                        private _b = MISSION_CORE_ACTIVE_BATTLES getOrDefault [_markerName, -1e10];
                        if (time - _b > 120) then { MISSION_CORE_ACTIVE_BATTLES deleteAt _markerName; };
                    };
                    {
                        if !(leader _x getVariable ["MISSION_CORE_PATROLLING", false]) then {
                            [_x] call MISSION_CORE_fnc_restartPatrol;
                        };
                    } forEach _defenders;
                };
            };
        } forEach MISSION_CORE_LOCATIONS;
    };
};
