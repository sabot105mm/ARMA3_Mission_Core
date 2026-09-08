
// spawnDefenses moved to fn_spawn.sqf for cross-file access

MISSION_CORE_fnc_aiAssaultLoop = {
    diag_log "AI ASSAULT: Started";
    MISSION_CORE_ASSAULT_COOLDOWN = 0;
    MISSION_CORE_ASSAULT_ACTIVE = false;
    MISSION_CORE_ASSAULT_TARGET = "";
    publicVariable "MISSION_CORE_ASSAULT_TARGET";
    while { true } do {
        sleep 25 + random 15;
        // Slowly decay defense scores so hardened markers eventually return to the target pool
        if (time >= MISSION_CORE_DEFENSE_DECAY_TIME) then {
            MISSION_CORE_DEFENSE_DECAY_TIME = time + 1200;
            { MISSION_CORE_DEFENSE_SCORE set [_x, ((MISSION_CORE_DEFENSE_SCORE getOrDefault [_x, 0]) - 1) max 0]; } forEach (keys MISSION_CORE_DEFENSE_SCORE);
            // Confidence NEVER drifts back up: it only drains on repel so the hand-off of a
            // marker from "fresh/first attacker" down to its one all-out attack stays honest.
            // Methods once used to restore confidence are deliberately removed.
        };
        if (!MISSION_CORE_ASSAULT_ACTIVE && time >= MISSION_CORE_ASSAULT_COOLDOWN) then {
        private _redLocs = MISSION_CORE_LOCATIONS select { _x select 5 == EAST && { toLower (_x select 2) find "factory" == -1 && { !([_x] call MISSION_CORE_fnc_isLightInfrastructure) } } };
        private _bluLocs = MISSION_CORE_LOCATIONS select { _x select 5 == WEST };
        {
            private _loc = _x;
            private _locPos = (_loc select 1) select 0;
            private _locName = _loc select 0;
            private _importance = _loc select 7;

            // Confidence of this marker (5 = fresh, 0 = rock bottom). Fresh markers are HIGHLY
            // likely to attack but NOT guaranteed; every repel drains confidence and further
            // attacks drop a lot; confidence 0 fires the marker's ONE all-out attack and then
            // it is permanently exhausted (defend only).
            private _conf = MISSION_CORE_AI_CONFIDENCE getOrDefault [_locName, 5];

            private _assaultRange = 1200 + (_importance * 400);
            private _targets = _bluLocs select {
                private _tName = _x select 0;
                private _tScore = MISSION_CORE_DEFENSE_SCORE getOrDefault [_tName, 0];
                private _tPos = (_x select 1) select 0;
                // Never attack a BLUFOR marker unless a player is near it
                private _playerNear = allPlayers select { alive _x && { _x distance _tPos < 1500 } };
                // Desperation (low confidence) ignores hardened-target restrictions
                count _playerNear > 0 && { (_conf <= 2 || _tScore < 2) && { _tPos distance _locPos < _assaultRange } }
            };
            if (count _targets == 0) then {};

            private _supportRange = (["assaultSupportRange", 1500] call MISSION_CORE_fnc_tune) + (_importance * 200);
            private _friendlyNearby = _redLocs select {
                (_x select 0) != (_loc select 0) && { ((_x select 1) select 0) distance _locPos < _supportRange }
            };

            private _assaultChance = 0;
            // PERMANENT RULE: once a marker has fired its one all-out assault (confidence 0),
            // it becomes exhausted and can NEVER attack again for the entire mission - it can
            // only defend from then on.
            if (MISSION_CORE_EXHAUSTED_MARKERS getOrDefault [_locName, false]) then {
                _assaultChance = 0;
            } else {
                // PERMANENT RULE: exactly ONE contested zone per side. While a zone is locked
                // (a captured marker being retaken, or a player-engaged marker), NO other REDFOR
                // marker may launch a separate assault on an unrelated target - all effort is
                // concentrated on the zone. Only the zone marker itself may press an attack.
                private _zoneFocus = if (isNil "MISSION_CORE_ZONE_FOCUS") then { "" } else { MISSION_CORE_ZONE_FOCUS };
                if (_zoneFocus != "" && { _locName != _zoneFocus }) then {
                    _assaultChance = 0;
                } else {
                // Support quality: a marker needs friendly nearby markers to press a real attack.
                // This sets the quality of the push; willingness itself is driven by confidence.
                private _supportFactor = 0;
                switch (true) do {
                    case (_importance == 1): {
                        private _allyNearby = _friendlyNearby select { (_x select 7) >= 1 };
                        if (count _allyNearby > 0) then { _supportFactor = 1; };
                    };
                    case (_importance >= 2 && _importance <= 4): {
                        private _higherNearby = _friendlyNearby select { (_x select 7) >= _importance + 1 };
                        if (count _higherNearby >= 2) then {
                            _supportFactor = 1;
                        } else {
                            _supportFactor = 0.4;
                        };
                    };
                    case (_importance >= 5): {
                        private _lvl5Nearby = _friendlyNearby select { (_x select 7) >= 5 };
                        if (count _lvl5Nearby >= 2) then { _supportFactor = 1; };
                    };
                };
                // Confidence drives willingness. A fresh marker (confidence 5, never attacked) is
                // HIGHLY likely to attack but NOT guaranteed. Being repelled drains confidence and
                // every further attack becomes far less likely. Only when confidence bottoms out
                // at 0 does the marker commit to its ONE all-out attack before becoming exhausted.
                private _willingChance = switch (_conf) do {
                    case 5: { 0.8 };   // first attack: highly likely but not guaranteed
                    case 4: { 0.25 };  // after 1 repel - drops a lot
                    case 3: { 0.12 };  // after 2 repels
                    case 2: { 0.06 };  // after 3 repels
                    case 1: { 0.03 };  // after 4 repels - almost never attacks
                    default { 1 };     // confidence 0: the single all-out attack
                };
                // AMMO is the primary driver of aggression. Ammo-scare markers hold back:
                // <70% halves the chance, <30% goes fully defensive (no attack), 0% passive.
                // The one all-out assault still requires confidence 0 AND enough ammo to fight.
                private _ammoMult = [_locName] call MISSION_CORE_fnc_ammoAggressionMult;
                if (_ammoMult > 0) then {
                    _willingChance = _willingChance * _ammoMult;
                };
                _assaultChance = (_willingChance * (if (_conf <= 0) then { 1 } else { _supportFactor })) min 0.95;
                };
            };

            if (random 1 < _assaultChance && count _targets > 0 && !MISSION_CORE_ASSAULT_ACTIVE && time >= MISSION_CORE_ASSAULT_COOLDOWN) then {
                // Value-driven target pick: score every candidate and attack the highest-value one.
                // A valuable target (Factory/HQ) trumps an easily-captured one (Outpost) - but a
                // target that keeps being defended (high defense score) sheds priority until it is
                // no longer worth the blood. Falls back to the first candidate if all tie at 0.
                private _target = _targets select 0;
                private _bestScore = -1;
                {
                    private _tScore = [_x select 0] call MISSION_CORE_fnc_getTargetPriority;
                    if (_tScore > _bestScore) then { _bestScore = _tScore; _target = _x; };
                } forEach _targets;
                private _targetPos = (_target select 1) select 0;
                private _targetArea = _target select 1;
                private _targetSize = (_targetArea select 1);
                if (count _targetArea > 2) then { _targetSize = _targetSize + [(_targetArea select 2)]; };
                private _targetName = _target select 0;

                // Repeated enemy defeats reduce the chance of hitting a hardened target,
                // but a marker that has lost a lot of confidence attacks anyway (desperation)
                private _tScore = MISSION_CORE_DEFENSE_SCORE getOrDefault [_targetName, 0];
                if (_conf > 2 && { _tScore >= 1 } && { random 1 < 0.5 }) then {
                    diag_log format ["AI ASSAULT: %1 target %2 defended %3x before - assault called off", _locName, _targetName, _tScore];
                    continue;
                };

                MISSION_CORE_ASSAULT_ACTIVE = true;
                MISSION_CORE_ASSAULT_COOLDOWN = time + (["assaultCooldown", 2400] call MISSION_CORE_fnc_tune);
                // Broadcast the marker under AI assault so the client garrison tab can flag it
                // as defensible (deploy gate: contested by a player OR under AI assault).
                MISSION_CORE_ASSAULT_TARGET = _targetName;
                publicVariable "MISSION_CORE_ASSAULT_TARGET";
                // PERMANENT RULE: a confidence-0 assault is the marker's ONE all-out attack.
                // The instant it is committed the marker is exhausted and can never attack again
                // for the whole mission - it can only defend from now on. Ensured exactly once.
                if (_conf <= 0) then {
                    MISSION_CORE_EXHAUSTED_MARKERS set [_locName, true];
                    diag_log format ["AI ASSAULT: %1 commits ALL-OUT assault on %2 - exhausted forever after", _locName, _targetName];
                };
                // AMMO: mounting a full assault wave costs ammo from the attacking marker.
                [_locName, ["ammoCostAssaultWave", 3] call MISSION_CORE_fnc_tune] call MISSION_CORE_fnc_consumeAmmo;

                // Armor support: the assault marker requests up to 4 factory-built MBTs and HOLDS
                // the attack until they arrive. Reset the delivery ledger to 0 (only tanks arriving
                // after this moment count for THIS assault), order the tanks to the marker itself,
                // then the wave scope below waits for DELIVERED to hit the request and commits the
                // delivered columns to the push. If no stock exists the waves roll in anyway after
                // the timeout.
                private _assaultTanks = ((["assaultTankBase", 2] call MISSION_CORE_fnc_tune) + floor (_importance * (["assaultTankPerImp", 0.5] call MISSION_CORE_fnc_tune))) min (["assaultTankMax", 4] call MISSION_CORE_fnc_tune);
                if (isNil "MISSION_CORE_TANK_DELIVERED") then { MISSION_CORE_TANK_DELIVERED = createHashMap; };
                if (isNil "MISSION_CORE_TANK_DELIVERED_GROUPS") then { MISSION_CORE_TANK_DELIVERED_GROUPS = createHashMap; };
                if (isNil "MISSION_CORE_TANK_REQUESTED") then { MISSION_CORE_TANK_REQUESTED = createHashMap; };
                MISSION_CORE_TANK_DELIVERED set [_locName, 0];
                MISSION_CORE_TANK_DELIVERED_GROUPS set [_locName, []];
                [EAST, _locName, _locPos, _assaultTanks, true] call MISSION_CORE_fnc_orderTank;
                MISSION_CORE_TANK_REQUESTED set [_locName, true];
                diag_log format ["AI ASSAULT: %1 requested %2 factory tanks for the push on %3", _locName, _assaultTanks, _targetName];

                // Every spawned foot patrol drops patrol and joins the assault, regardless of distance.
                // Groups way too far from the target (beyond 6000m) are despawned instead.
                private _despawnTooFar = [];
                {
                    if (!(_x getVariable ["MISSION_CORE_REDFOR", false])) then {
                        if ((leader _x) distance _locPos < 3000) then { diag_log format ["AI ASSAULT: %1 skip (not redfor)", groupId _x]; };
                    } else {
                        private _skip = "";
                        // PERMANENT RULE: a squad whose home marker sits inside the assault target's
                        // area holds that ground - it is never routed back to "attack" its own
                        // position (garrisons of an enemy town overlapping a BLUFOR target must not
                        // board trucks and drive back into their own yard).
                        if (count _targetSize >= 2) then {
                            private _hc = _x getVariable ["MISSION_CORE_MARKER_CENTER", getPos leader _x];
                            private _tA = (_targetSize select 0) max 1;
                            private _tB = (_targetSize select 1) max 1;
                            private _tD = if (count _targetSize > 2) then { _targetSize select 2 } else { 0 };
                            private _dx = (_hc select 0) - (_targetPos select 0);
                            private _dy = (_hc select 1) - (_targetPos select 1);
                            private _rx = (_dx * cos _tD) - (_dy * sin _tD);
                            private _ry = (_dx * sin _tD) + (_dy * cos _tD);
                            if ((_rx * _rx) / (_tA * _tA) + (_ry * _ry) / (_tB * _tB) <= 1) then { _skip = "home is target area"; };
                        };
                        if (_skip == "" && { (_x getVariable ["MISSION_CORE_ORDER", ""]) != "" }) then { _skip = format ["order=%1", _x getVariable ["MISSION_CORE_ORDER", ""]]; }
                        else {
                            if ((_x getVariable ["MISSION_CORE_ARMOR_SLOT", ""]) != "") then { _skip = "armor slot"; }
                            else {
                                if (_x getVariable ["MISSION_CORE_AA_TANK", false]) then { _skip = "AA tank"; }
                                else {
                                    if (_x getVariable ["MISSION_CORE_AA_DEFENSE", false]) then { _skip = "AA defense"; }
                                    else {
                                        if (_x getVariable ["MISSION_CORE_DEFENSE_GROUP", false]) then { _skip = "defense group"; }
                                        else {
                                            if ((leader _x) distance _targetPos > 6000) then {
                                                _skip = "way too far";
                                                _despawnTooFar pushBack _x;
                                            };
                                        };
                                    };
                                };
                            };
                        };
                        if (_skip == "") then {
                            diag_log format ["AI ASSAULT: marker patrol %1 joins assault", groupId _x];
                            // Committed to the assault - the "target no longer contested" neighbor
                            // cleanup must never retreat/despawn these groups mid-assault.
                            _x setVariable ["MISSION_CORE_ASSAULT_GROUP", true];
                            [_x, _targetPos, _targetSize] call MISSION_CORE_fnc_sendCounterAttack;
                        } else {
                            diag_log format ["AI ASSAULT: %1 skip (%2)", groupId _x, _skip];
                        };
                    };
                } forEach allGroups;

                {
                    diag_log format ["AI ASSAULT: despawning %1 (way too far from target)", groupId _x];
                    private _vehs = [];
                    { private _v = vehicle _x; if (_v != _x && { alive _v } && { !(_v in _vehs) }) then { _vehs pushBack _v; }; } forEach units _x;
                    { deleteVehicle _x; } forEach units _x;
                    { deleteVehicle _x; } forEach _vehs;
                    deleteGroup _x;
                    if (!isNil "MISSION_CORE_SPAWNED_GROUPS") then { MISSION_CORE_SPAWNED_GROUPS = MISSION_CORE_SPAWNED_GROUPS - [_x]; };
                } forEach _despawnTooFar;

                private _srcLabel = [_locName] call MISSION_CORE_fnc_getLocationLabel;
                private _tgtLabel = [_targetName] call MISSION_CORE_fnc_getLocationLabel;
                diag_log format ["AI ASSAULT CALLED: %1 (lvl%2) -> %3 (%4m)", _srcLabel, _importance, _tgtLabel, round(_locPos distance _targetPos)];
                ["DynOps_Assault",
                    ["ENEMY ASSAULT", format ["%1 is launching an attack on %2!\nETA 10 minutes", _srcLabel, _tgtLabel]]
                ] remoteExec ["BIS_fnc_showNotification", 0];
                ["Enemy assault detected at %1! ETA 10 minutes!", _tgtLabel] remoteExec ["systemChat", 0];

                if (isNil "MISSION_CORE_SPAWNED_GROUPS") then { MISSION_CORE_SPAWNED_GROUPS = []; };
                // PERMANENT RULE: never spawn BLUFOR defenses inside a marker the player JUST
                // captured (still in its 10-minute occupied/hold phase). The occupier must hold it
                // with their own units; BLUFOR bunkers materialize only the NEXT time it is defended.
                private _defGrp = grpNull;
                if (!([_targetName] call MISSION_CORE_fnc_isOccupied)) then {
                    _defGrp = [_targetPos, _targetSize, WEST, MISSION_CORE_BLUFOR_DATA, _target select 7, _locPos] call MISSION_CORE_fnc_spawnDefenses;
                    if (!isNull _defGrp) then { MISSION_CORE_SPAWNED_GROUPS pushBack _defGrp; };
                    if (isNil "MISSION_CORE_DEFENSE_ASSIGN") then { MISSION_CORE_DEFENSE_ASSIGN = createHashMap; };
                    if (!isNull _defGrp) then { MISSION_CORE_DEFENSE_ASSIGN set [_targetName, _defGrp]; };
                } else {
                    diag_log format ["AI ASSAULT: %1 target %2 still occupied - no BLUFOR defenses spawned", _locName, _targetName];
                };

                [_targetPos, _locPos, _locName, _targetName, _importance, _defGrp, _targetSize, _assaultTanks] spawn {
                    params ["_targetPos", "_sourcePos", "_sourceName", "_targetName", "_importance", "_defGrp", "_targetSize", "_assaultTanks"];
                    // Assault waves use proper CfgGroups infantry squad templates (real combat
                    // riflemen); all-men combat groups only as a last resort.
                    private _infPool = [(MISSION_CORE_REDFOR_DATA select 17)] call MISSION_CORE_fnc_getInfTemplates;
                    // The assault waits for the requested factory/base tanks to be built and
                    // delivered to the marker before launching. The wait scales with the request so
                    // the tank economy (tankBuildInterval seconds per tank) actually has time to
                    // produce them all; a 2-tank request waits ~2 build-cycles, 3 ~3, 4 ~4. If the
                    // tanks still never materialize the all-out waves roll in regardless.
                    private _buildPeriod = ["tankBuildInterval", 600] call MISSION_CORE_fnc_tune;
                    private _tankDeadline = time + (_assaultTanks * _buildPeriod) + 60;
                    private _tanksArrived = false;
                    while { time < _tankDeadline } do {
                        if ((MISSION_CORE_TANK_DELIVERED getOrDefault [_sourceName, 0]) >= _assaultTanks) exitWith { _tanksArrived = true; };
                        sleep 10;
                    };
                    if (_tanksArrived) then {
                        private _held = MISSION_CORE_TANK_DELIVERED_GROUPS getOrDefault [_sourceName, []];
                        private _delivered = MISSION_CORE_TANK_DELIVERED getOrDefault [_sourceName, 0];
                        // Any tanks that were delivered ABSTRACTLY (never materialized - no player was
                        // near enough to see the convoy) have no live column to commit. Spawn them now
                        // so the assault still gets its full factory-built tank force on the ground.
                        private _missing = (_delivered - (count _held)) max 0;
                        private _tankGroups = +_held;
                        if (_missing > 0) then {
                            private _mbtClasses = (MISSION_CORE_REDFOR_DATA select 7) getOrDefault ["mbt", []];
                            if (count _mbtClasses > 0) then {
                                private _col = createGroup EAST;
                                private _colVehs = [];
                                private _spawnPos = [_sourcePos, [150, 150], 15] call MISSION_CORE_fnc_findVehiclePos;
                                if (count _spawnPos < 2) then { _spawnPos = _sourcePos; };
                                if (count _spawnPos == 2) then { _spawnPos pushBack 0; };
                                // Column the abstract-delivered tanks on the road so the assault force
                                // appears as a line of armor driving in, not a stack on one spot.
                                private _colSpots = [_spawnPos, [150, 150], _missing, 20] call MISSION_CORE_fnc_findVehicleColumnPos;
                                for "_mc" from 1 to _missing do {
                                    private _spot = if (_mc - 1 < count _colSpots) then { _colSpots select (_mc - 1) } else { _spawnPos };
                                    if (count _spot == 2) then { _spot pushBack 0; };
                                    private _tv = createVehicle [selectRandom _mbtClasses, [_spot] call MISSION_CORE_fnc_liftSpawn, [], 5, "CAN_COLLIDE"];
                                    _col addVehicle _tv;
                                    _colVehs pushBack _tv;
                                    for "_tc" from 1 to 3 do { _col createUnit ["O_crew_F", _spot, [], 0, "NONE"]; };
                                    [_tv] call MISSION_CORE_fnc_alignVehicleToRoad;
                                };
                                private _crew1 = units _col;
                                private _ci = 0;
                                {
                                    private _cg = _crew1 select [_ci, 3]; _ci = _ci + 3;
                                    if (count _cg > 0 && { isNull (driver _x) }) then { (_cg select 0) moveInDriver _x; };
                                    if (count _cg > 1 && { isNull (gunner _x) }) then { (_cg select 1) moveInGunner _x; };
                                    if (count _cg > 2 && { isNull (commander _x) }) then { (_cg select 2) moveInCommander _x; };
                                } forEach _colVehs;
                                _col setBehaviour "AWARE"; _col setCombatMode "RED"; _col setSpeedMode "FULL";
                                _col setVariable ["MISSION_CORE_REDFOR", true];
                                _col setVariable ["MISSION_CORE_ORIGIN_MARKER", _sourceName];
                                if (isNil "MISSION_CORE_SPAWNED_GROUPS") then { MISSION_CORE_SPAWNED_GROUPS = []; };
                                MISSION_CORE_SPAWNED_GROUPS pushBack _col;
                                // Track the assault tanks under the ordered-vehicle cleanup: they are
                                // ordered (sendCounterAttack below) to leave spawn for _targetPos; one
                                // that never leaves is recycled and its slot freed.
                                { [_x, _targetPos] call MISSION_CORE_fnc_tagOrderedVehicle; } forEach _colVehs;
                                _tankGroups pushBack _col;
                                diag_log format ["AI ASSAULT: %1 spawned %2 abstract-delivered tanks into the assault on %3", _sourceName, _missing, _targetName];
                            };
                        };
                        {
                            if (!isNull _x && { count units _x > 0 } && { alive leader _x }) then {
                                _x setVariable ["MISSION_CORE_ORDER", "counterattack"];
                                // Committed to the assault - exempt from the "target no longer
                                // contested" neighbor cleanup (same rule as joined foot patrols).
                                _x setVariable ["MISSION_CORE_ASSAULT_GROUP", true];
                                [_x, _targetPos, _targetSize, "YELLOW", "counterattack"] call MISSION_CORE_fnc_sendCounterAttack;
                            };
                        } forEach _tankGroups;
                        MISSION_CORE_TANK_DELIVERED_GROUPS set [_sourceName, []];
                        diag_log format ["AI ASSAULT: %1 committing %2 tank columns to %3", _sourceName, count _tankGroups, _targetName];
                    } else {
                        diag_log format ["AI ASSAULT: %1 no factory tanks delivered - waves launch anyway", _sourceName];
                    };
                    private _srcLbl2 = [_sourceName] call MISSION_CORE_fnc_getLocationLabel;
                    private _tgtLbl2 = [_targetName] call MISSION_CORE_fnc_getLocationLabel;
                    diag_log format ["AI ASSAULT WAVE: %1 -> %2 arriving now", _srcLbl2, _tgtLbl2];
                    ["DynOps_AssaultWarn",
                        ["ASSAULT UNDERWAY", format ["Enemy forces from %1 are attacking %2!\nDefend the position!", _srcLbl2, _tgtLbl2]]
                    ] remoteExec ["BIS_fnc_showNotification", 0];

                    private _assaultWaves = [];
                    private _waveTrucks = [];
                    private _waveDrvGroups = [];
                    for "_w" from 1 to (1 + _importance) do {
                        // Respect the per-side foot-squad cap: stop spawning waves once 10 alive
                        // foot squads exist for this side (the assault never floods past the cap).
                        if (([EAST] call MISSION_CORE_fnc_countFootSquads) >= (["footSquadCapSquads", 10] call MISSION_CORE_fnc_tune)) exitWith {};
                        private _wavePos = [_sourcePos getPos [300 + random 200, random 360]] call MISSION_CORE_fnc_ensureLandPos;
                        private _waveGrp = grpNull;
                        if (count _infPool > 0) then {
                            private _tmpl = _infPool select floor (random (count _infPool));
                            _waveGrp = [(_tmpl select 0), _wavePos, EAST, MISSION_CORE_REDFOR_DATA select 3, "AWARE", "FULL", _importance, _sourcePos, [200, 200]] call MISSION_CORE_fnc_spawnGroup;
                        } else {
                            _waveGrp = createGroup EAST;
                            private _unitPool = (MISSION_CORE_REDFOR_DATA select 19) select { [_x] call MISSION_CORE_fnc_isCombatMan };
                            if (count _unitPool == 0) then { _unitPool = ["O_Soldier_F"]; };
                            for "_u" from 1 to (4 + _importance) do {
                                _waveGrp createUnit [selectRandom _unitPool, _wavePos, [], 0, "FORM"];
                            };
                        };
                        if (isNull _waveGrp) then { continue; };
                        _waveGrp setVariable ["MISSION_CORE_REDFOR", true];
                        _waveGrp setVariable ["MISSION_CORE_ORIGIN_MARKER", _sourceName];
                        _waveGrp setBehaviour "AWARE";
                        _waveGrp setCombatMode "RED";
                        _waveGrp setSpeedMode "FULL";
                        // Foot waves ride a wheeled truck to the target, then pause at the stand-off
                        // ring just OUTSIDE the marker's edge and EJECT to assault on foot. Gun
                        // mounts fight from the vehicle and never eject (crew stays in). The truck's
                        // dedicated driver group STOPS at the ring (TRANSPORT UNLOAD) so the pause
                        // is a real halt; a per-wave controller waits for the truck to cross the
                        // ring, holds 1.5s, then ejects everyone. No GETOUT waypoint - ejection is
                        // timed by the controller, and AUTOCOMBAT is off while riding so nobody
                        // bails out mid-ride.
                        [_waveGrp, EAST, _wavePos] call MISSION_CORE_fnc_mountInfantry;
                        private _waveTruck = vehicle leader _waveGrp;
                        private _waveDrvGrp = _waveTruck getVariable ["MISSION_CORE_DRIVER_GROUP", grpNull];
                        private _wa2 = _targetSize select 0;
                        private _wb2 = if (count _targetSize > 1) then { _targetSize select 1 } else { _wa2 };
                        // Completion radius = the marker's biggest axis (half of its largest
                        // dimension) for BOTH square and ellipse markers. For a square that is
                        // simply the larger half-edge; for an ellipse it equals the semi-major
                        // axis. Either way it is an upper bound on the per-direction edge
                        // distance, so trucks stop comfortably outside the whole marker area.
                        private _wRad = _wa2 max _wb2;
                        private _wUnload = _wRad + 100;
                        if ([_waveTruck] call MISSION_CORE_fnc_hasMountedGun) then {
                            // Gun truck - crew stays in, drives to the edge ring, then SAD
                            private _wpM = _waveGrp addWaypoint [_targetPos, _wUnload];
                            _wpM setWaypointType "MOVE";
                            _wpM setWaypointSpeed "FULL";
                            _wpM setWaypointBehaviour "AWARE";
                            private _wpS = _waveGrp addWaypoint [_targetPos, 100];
                            _wpS setWaypointType "SAD";
                            _wpS setWaypointSpeed "FULL";
                            _wpS setWaypointBehaviour "COMBAT";
                            _waveGrp setCurrentWaypoint _wpM;
                        } else {
                            // Soft cargo truck - ride to the stand-off ring, then dismount on arrival.
                            // The unload fires via a waypoint script (matching the recruit menu): the
                            // moment the group reaches the ring waypoint, transport_assaultUnload.sqf
                            // ejects every rider, relocks cargo, and lets the SAD waypoint take over.
                            _waveGrp setCombatMode "GREEN";
                            { if (vehicle _x == _waveTruck) then { _x disableAI "AUTOCOMBAT"; }; } forEach units _waveGrp;
                            private _wpRing = _waveGrp addWaypoint [_targetPos, _wUnload];
                            _wpRing setWaypointType "MOVE";
                            _wpRing setWaypointSpeed "FULL";
                            _wpRing setWaypointBehaviour "AWARE";
                            _wpRing setWaypointScript "fnc\commander\transport_assaultUnload.sqf";
                            if (!isNull _waveDrvGrp) then {
                                // MOVE first (pre-1.22 rule), then TRANSPORT UNLOAD at the ring.
                                private _wpDrvMove = _waveDrvGrp addWaypoint [_targetPos, _wUnload];
                                _wpDrvMove setWaypointType "MOVE";
                                _wpDrvMove setWaypointSpeed "FULL";
                                _wpDrvMove setWaypointBehaviour "CARELESS";
                                private _wpTUnload = _waveDrvGrp addWaypoint [_targetPos, _wUnload];
                                _wpTUnload setWaypointType "TR UNLOAD";
                                _wpTUnload setWaypointSpeed "FULL";
                                _wpTUnload setWaypointBehaviour "CARELESS";
                                _waveDrvGrp setCombatMode "GREEN";
                                _waveDrvGrp setBehaviour "CARELESS";
                                _waveDrvGrp setCurrentWaypoint _wpDrvMove;
                                _waveTrucks pushBack _waveTruck;
                                _waveDrvGroups pushBack _waveDrvGrp;
                            };
                            private _wpS = _waveGrp addWaypoint [_targetPos, 100];
                            _wpS setWaypointType "SAD";
                            _wpS setWaypointSpeed "FULL";
                            _wpS setWaypointBehaviour "COMBAT";
                            _waveGrp setCurrentWaypoint _wpRing;
                        };
                        _assaultWaves pushBack _waveGrp;
                        // Register the wave in the global spawn registry so the per-side foot-squad
                        // cap (countFootSquads) counts this wave before the loop spawns the next one,
                        // and so the wave obeys normal cleanup. Without this the cap check at the top
                        // of the loop never saw waves 2+, letting one assault overshoot the cap.
                        if (isNil "MISSION_CORE_SPAWNED_GROUPS") then { MISSION_CORE_SPAWNED_GROUPS = []; };
                        MISSION_CORE_SPAWNED_GROUPS pushBack _waveGrp;
                    };

                    sleep 300;
                    private _totalKilled = 0;
                    private _totalUnits = 0;
                    {
                        if (!isNull _x) then {
                            private _units = units _x;
                            _totalUnits = _totalUnits + count _units;
                            private _toKill = floor (count _units * 0.8);
                            for "_i" from 1 to _toKill do {
                                if (count _units > 0 && {alive (_units select 0)}) then {
                                    (_units select 0) setDamage 1;
                                    _totalKilled = _totalKilled + 1;
                                };
                            };
                        };
                    } forEach _assaultWaves;
                    // Wave resolution complete - clear the trucks and their dedicated driver groups
                    {
                        private _drvGrp = _x;
                        if (!isNull _drvGrp) then { { deleteVehicle _x; } forEach (units _drvGrp); };
                    } forEach _waveDrvGroups;
                    { if (!isNull _x) then { deleteVehicle _x; }; } forEach _waveTrucks;
                    { if (!isNull _x) then { deleteGroup _x; }; } forEach _waveDrvGroups;
                    // Wave infantry groups were registered in MISSION_CORE_SPAWNED_GROUPS to count
                    // toward the foot cap. They are now resolved (killed) - drop them from the global
                    // registry so the cap isn't cluttered with dead residue.
                    if (!isNil "MISSION_CORE_SPAWNED_GROUPS") then { MISSION_CORE_SPAWNED_GROUPS = MISSION_CORE_SPAWNED_GROUPS - _assaultWaves; };
                    private _tgtLbl3 = [_targetName] call MISSION_CORE_fnc_getLocationLabel;
                    diag_log format ["AI ASSAULT ENDED: %1/%2 OPFOR killed (80%% resolution)", _totalKilled, _totalUnits];
                    ["DynOps_AssaultRepelled",
                        ["ASSAULT REPELLED", format ["%1 OPFOR eliminated at %2.\nNext assault window opens in 40 minutes.", _totalKilled, _tgtLbl3]]
                    ] remoteExec ["BIS_fnc_showNotification", 0];
                    MISSION_CORE_ASSAULT_ACTIVE = false;
                    MISSION_CORE_ASSAULT_TARGET = "";
                    publicVariable "MISSION_CORE_ASSAULT_TARGET";
                    [_targetPos] call MISSION_CORE_fnc_renewDefenses;
                    if (!isNull _defGrp && { !(isNil "MISSION_CORE_DEFENSE_ASSIGN") }) then { MISSION_CORE_DEFENSE_ASSIGN deleteAt _targetName; };

                    // PERMANENT RULE: ownership NEVER flips through an assault resolution. A marker
                    // is captured only in the replenish loop (active + BLUFOR inside + 50% manpower
                    // loss). Winning an assault only hardens the defense score and drains confidence.
                    private _score = MISSION_CORE_DEFENSE_SCORE getOrDefault [_targetName, 0];
                    MISSION_CORE_DEFENSE_SCORE set [_targetName, _score + 1];
                    diag_log format ["AI ASSAULT: %1 defended (score now %2) - future assaults on it reduced", _targetName, _score + 1];
                    // Being repelled drains the SOURCE marker's confidence. Fresh markers (conf 5)
                    // are highly likely to attack on their first try, but every repel drops that
                    // chance hard until confidence bottoms out at 0, which fires the marker's ONE
                    // all-out attack and then permanently exhausts it (defend only).
                    if !(isNil "MISSION_CORE_AI_CONFIDENCE") then {
                        private _cv = MISSION_CORE_AI_CONFIDENCE getOrDefault [_sourceName, 5];
                        MISSION_CORE_AI_CONFIDENCE set [_sourceName, (_cv - 1) max 0];
                    };
                };
            };
        } forEach _redLocs;
        };
    };
};
