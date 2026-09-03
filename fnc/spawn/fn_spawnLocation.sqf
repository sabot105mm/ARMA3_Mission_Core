
MISSION_CORE_fnc_spawnLocation = {
    params ["_loc"];
    private _owner = _loc select 4;
    private _factionData = if (_owner == WEST) then { MISSION_CORE_BLUFOR_DATA } else { MISSION_CORE_REDFOR_DATA };
    private _faction = _factionData select 3;
    private _importance = _loc select 7;
    // Per-marker tank pool: max MBTs this marker may field (0 = no pool, no MBT).
    private _tankPool = if (_owner in [WEST, EAST]) then { [_loc] call MISSION_CORE_fnc_markerTankPool } else { 0 };
    private _markerCenter = _loc select 1;
    private _markerSize = if (count _loc > 8) then { _loc select 8 } else { [200, 200] };
    private _allGroups = _factionData select 17;
    private _locName = _loc select 0;
    private _locMkr = _locName;
    if (_locMkr in allMapMarkers) then {
        _locMkr setMarkerAlpha 0.6;
        _locMkr setMarkerText _locName;
        _locMkr setMarkerBrush "SolidBorder";
    };

    // BLUFOR markers are 100% player-driven - the GARRISON recruit tab owns everything that spawns
    // at a BLUFOR marker. Skip the auto-defender generation entirely (both the cache restore and the
    // preset spawner): the old behavior conjured riflemen/teams out of thin air, which the player has
    // made clear must never happen. Baseline flat 0 keeps capture + assault scaling honest.
    if (_owner == WEST) then {
        diag_log format ["DYNAMIC SPAWN: %1 BLUFOR - player-controlled, skipping auto defenders", _locName];
        if (isNil "MISSION_CORE_GARRISON_BASELINE") then { MISSION_CORE_GARRISON_BASELINE = createHashMap; };
        MISSION_CORE_GARRISON_BASELINE set [_locName, 0];
        MISSION_CORE_SPAWNED_CACHE set [_locName, []];
    } else {
    // Check for cached state first
    private _cached = MISSION_CORE_SPAWNED_CACHE getOrDefault [_locName, []];
    if (count _cached > 0) then {
        diag_log format ["DYNAMIC SPAWN: restoring %1 from cache (%2 groups)", _locName, count _cached];
        {
            private _grp = [_x, _markerCenter, _owner, _faction, _importance, _markerCenter, _markerSize] call MISSION_CORE_fnc_deserializeGroup;
            private _cSlot = _grp getVariable ["MISSION_CORE_ARMOR_SLOT", ""];
            private _cIsAA = _grp getVariable ["MISSION_CORE_AA_DEFENSE", false];
            if (_cSlot == "mbt" || _cSlot == "mech" || (_cSlot == "" && _cIsAA)) then {
                private _capSlot = if (_cSlot == "") then { "mbt" } else { _cSlot };
                if !([_owner, _capSlot, _markerCenter, _importance] call MISSION_CORE_fnc_armorCapOpen) then {
                    diag_log format ["DYNAMIC SPAWN: %1 cache restore blocked - %2 cap full", _locName, _capSlot];
                    private _vehs = [];
                    { private _v = vehicle _x; if (_v != _x && { alive _v } && { !(_v in _vehs) }) then { _vehs pushBack _v; }; } forEach units _grp;
                    { deleteVehicle _x; } forEach units _grp;
                    { deleteVehicle _x; } forEach _vehs;
                    deleteGroup _grp;
                    continue;
                };
                // Pooled marker: a restored MBT must not push the marker past its own tank
                // pool on top of the global cap - the pool is the marker's local allowance.
                // AA overwatch tanks (slot "" + AA flag) never draw from the pool.
                if (_cSlot == "mbt" && _tankPool > 0 && { ([_loc] call MISSION_CORE_fnc_countMBTByMarker) >= _tankPool }) then {
                    diag_log format ["DYNAMIC SPAWN: %1 cache restore blocked - tank pool full (%2)", _locName, _tankPool];
                    private _vehs = [];
                    { private _v = vehicle _x; if (_v != _x && { alive _v } && { !(_v in _vehs) }) then { _vehs pushBack _v; }; } forEach units _grp;
                    { deleteVehicle _x; } forEach units _grp;
                    { deleteVehicle _x; } forEach _vehs;
                    deleteGroup _grp;
                    continue;
                };
            };
            private _cSub = _grp getVariable ["MISSION_CORE_SUBCAT", ""];
            if (_cSub find "inf" == 0 && { !([_owner, "inf", _markerCenter] call MISSION_CORE_fnc_townCategoryCanUse) }) then {
                diag_log format ["DYNAMIC SPAWN: %1 cache restore blocked - foot infantry town cap full", _locName];
                { deleteVehicle _x; } forEach units _grp;
                deleteGroup _grp;
                continue;
            };
            MISSION_CORE_SPAWNED_GROUPS pushBack _grp;
        } forEach _cached;
        MISSION_CORE_SPAWNED_CACHE set [_locName, []];
        // Baseline = what actually got restored to the map, not theoretical capacity
        if (isNil "MISSION_CORE_GARRISON_BASELINE") then { MISSION_CORE_GARRISON_BASELINE = createHashMap; };
        private _restoredAlive = 0;
        {
            if (!isNull _x && { _x getVariable ["MISSION_CORE_MARKER_CENTER", [0,0,0]] distance _markerCenter < 600 }) then {
                _restoredAlive = _restoredAlive + ({ alive _x } count units _x);
            };
        } forEach MISSION_CORE_SPAWNED_GROUPS;
        MISSION_CORE_GARRISON_BASELINE set [_locName, _restoredAlive];
    } else {
        private _pos = _loc select 1;
        private _hasRunway = count (nearestTerrainObjects [_pos, ["RUNWAY"], 600]) > 0;

        private _defenseCandidates = [];
        private _gName = "";

        // Weighted infantry defender pools: AA 10% / AT 40% / inf squad 40% / weapons squad 10%
        private _aaPool = _allGroups select { (_x select 3) find "_aa" > -1 || (_x select 3) == "tank_aa" };
        private _atPool = _allGroups select { (_x select 3) find "_at" > -1 };
        private _infPool = [_allGroups] call MISSION_CORE_fnc_getInfTemplates;
        // Mech/motorized infantry (a couple of vehicles) also feed the defender pool
        {
            if ((_x select 3) == "mech" && { ({ !(_x isKindOf "Man") } count (_x select 1)) <= 2 }) then { _infPool pushBack _x; };
        } forEach _allGroups;
        private _weaponsPool = _allGroups select { (_x select 3) == "inf_weapons" };

        private _pickWeighted = {
            params ["_pools", "_weights"];
            private _chosen = [];
            private _validIdx = [];
            private _total = 0;
            {
                if (count (_pools select _forEachIndex) > 0) then { _validIdx pushBack _forEachIndex; _total = _total + (_weights select _forEachIndex); };
            } forEach _pools;
            if (_total > 0) then {
                private _roll = random _total;
                private _acc = 0;
                {
                    private _idx = _x;
                    _acc = _acc + (_weights select _idx);
                    if (_roll < _acc) exitWith { _chosen = _pools select _idx; };
                } forEach _validIdx;
            };
            _chosen
        };

        private _presetGroups = [];
        private _chosenNames = [];
        private _freshGroups = [];
        private _defenderCount = 1 + _importance;
        if (_importance >= 5) then { _defenderCount = _defenderCount + 1; };
        private _defenderPools = [_aaPool, _atPool, _infPool, _weaponsPool];
        private _defenderWeights = [1, 4, 4, 1];
        // Foot/mech composition caps (global per side): at most 1 AA team, 4 AT teams, 2 weapons
        // squads - the rest are riflemen. A pick that would exceed its cap falls back to rifle.
        private _compNow = [_owner] call MISSION_CORE_fnc_countSideComposition;
        private _capLimits = [1, 4, 1e10, 2];
        private _capBase = [_compNow select 0, _compNow select 1, 0, _compNow select 3];
        for "_s" from 1 to _defenderCount do {
            private _pool = [_defenderPools, _defenderWeights] call _pickWeighted;
            if (count _pool == 0) then { continue; };
            private _poolIdx = _defenderPools find _pool;
            if (_poolIdx < 0) then { _poolIdx = 2; };
            // Foot AA/AT/weapons checks: tank_aa is armor (slot mbt), so the AA cap only applies
            // to the foot pool. inf pool = riflemen, no cap.
            if ((_capBase select _poolIdx) >= (_capLimits select _poolIdx)) then {
                _pool = _infPool;
                _poolIdx = 2;
            };
            if (count _pool == 0) then { continue; };
            private _avail = _pool select { !((_x select 0) in _chosenNames) };
            // Few addon factions expose many unique group templates - fall back to reusing a
            // template so the marker still fields its full defenderCount instead of going quiet.
            if (count _avail == 0) then { _avail = _pool; };
            private _pick = _avail select floor (random (count _avail));
            _chosenNames pushBack (_pick select 0);
            _presetGroups pushBack _pick;
            if (_poolIdx < 3) then { _capBase set [_poolIdx, (_capBase select _poolIdx) + 1]; };
        };
        // Low-importance locations keep a recon element
        if (_importance <= 1) then {
            private _reconPool = _allGroups select { (_x select 3) == "recon" && { !((_x select 0) in _chosenNames) } };
            {
                _chosenNames pushBack (_x select 0);
                _presetGroups pushBack _x;
            } forEach (_reconPool select [0, 2 min count _reconPool]);
        };
        // High-importance heavy support bonuses
        if (_importance >= 4) then {
            {
                if ((_x select 3) find "mech" > -1 && { (_x select 3) find "_aa" == -1 } && { !((_x select 0) in _chosenNames) } && { ({ !(_x isKindOf "Man") } count (_x select 1)) <= 2 }) then {
                    _chosenNames pushBack (_x select 0);
                    _presetGroups pushBack _x;
                };
            } forEach _allGroups;
        };
        // Tank presets come from the per-marker pool: only pool owners (tiers 0-1) field MBTs,
        // and only up to their pool size - importance no longer gates armor directly.
        if (_tankPool > 0) then {
            private _tankAdded = 0;
            {
                if ((_x select 3) find "tank" > -1 && { (_x select 3) find "_aa" == -1 } && { !((_x select 0) in _chosenNames) } && { ({ !(_x isKindOf "Man") } count (_x select 1)) <= 2 }) then {
                    _chosenNames pushBack (_x select 0);
                    _presetGroups pushBack _x;
                    _tankAdded = _tankAdded + 1;
                    if (_tankAdded >= _tankPool) exitWith {};
                };
            } forEach _allGroups;
        };

        diag_log format ["DYNAMIC SPAWN: %1 imp=%2 allGroups=%3 pools aa=%4 at=%5 inf=%6 wps=%7", _locName, _importance, count _allGroups, count _aaPool, count _atPool, count _infPool, count _weaponsPool];
        diag_log format ["DYNAMIC SPAWN: %1 defenderCount=%2 presetGroups=%3", _locName, _defenderCount, count _presetGroups];
        {
            diag_log format ["DYNAMIC SPAWN:   candidate: %1 cat=%2 sub=%3 cnt=%4", _x select 0, _x select 4, _x select 3, _x select 2];
        } forEach _presetGroups;
        private _defensePositions = _loc select 5;
        private _overwatchPositions = if (count _loc > 9) then { _loc select 9 } else { [] };
        // First spawns go to the defense positions CLOSEST to the nearest player (the one who
        // triggered the spawn) so enemies materialize in front of the attacker instead of the
        // far side of the marker. Overwatch high-ground stays reserved for vehicles.
        private _playersA = allPlayers select { alive _x };
        private _nearP = objNull;
        private _nearD = 1e10;
        {
            private _pp = _x;
            private _d = _pp distance _markerCenter;
            if (_d < _nearD) then { _nearD = _d; _nearP = _pp; };
        } forEach _playersA;
        if (!isNull _nearP && { count _defensePositions > 1 }) then {
            private _ranked = _defensePositions apply { [_x distance _nearP, _x] };
            _ranked sort true;
            _defensePositions = _ranked apply { _x select 1 };
        };
        // Vehicles (AA/AT/tank/mech) get first claim on overwatch; infantry fill the rest
        private _vehNeed = 0;
        {
            if ((_x select 3) find "_aa" > -1 || (_x select 3) find "_at" > -1 || (_x select 3) find "tank" > -1 || (_x select 3) find "mech" > -1 || (_x select 4) in ["Mechanized", "Armored", "Motorized"]) then { _vehNeed = _vehNeed + 1; };
        } forEach _presetGroups;
        private _infOverwatchLimit = ((count _overwatchPositions) - _vehNeed) max 0;
        private _spawnIdx = 0;
        private _overwatchIdx = 0;
        {
            private _grpType = _x select 0;
            private _spawnPos = [0,0,0];
            private _posFound = false;
            private _subCat = _x select 3;
            private _isAAVehicle = _subCat == "tank_aa" || (_subCat find "_aa" > -1 && { _subCat find "inf" == -1 });
            private _isArty = _subCat == "artillery";

            // Artillery (SPG/MLRS/self-propelled guns) only ever spawns on overwatch markers -
            // the high-ground Hill/Mount/RockArea positions where a piece can lob shells over
            // the valley. No other marker type fields artillery.
            if (_isArty && { !([_locName] call MISSION_CORE_fnc_isOverwatchMarker) }) then {
                diag_log format ["DYNAMIC SPAWN: skipping %1 at %2 - artillery only on overwatch markers", _grpType, _locName];
                continue;
            };

            // Foot infantry town cap: only 3 towns per side may field foot infantry at once.
            // Towns already fielding infantry can always spawn more (refill).
            if (_subCat find "inf" == 0 && { !([_owner, "inf", _markerCenter] call MISSION_CORE_fnc_townCategoryCanUse) }) then {
                diag_log format ["DYNAMIC SPAWN: skipping %1 at %2 - foot infantry town cap full", _grpType, _locName];
                continue;
            };
            // Global foot budget cap: max footSquadCapSquads squad-equivalents across the map
            if ({ !(_x isKindOf "Man") } count (_x select 1) == 0 && { [_owner] call MISSION_CORE_fnc_countFootSquads >= (["footSquadCapSquads", 10] call MISSION_CORE_fnc_tune) }) then {
                diag_log format ["DYNAMIC SPAWN: skipping %1 at %2 - global foot squad cap full", _grpType, _locName];
                continue;
            };

            if (_subCat find "_aa" > -1 || _subCat find "_at" > -1 || _subCat find "tank" > -1 || _subCat find "mech" > -1 || _subCat == "artillery" || (_x select 4) in ["Mechanized", "Armored", "Motorized"]) then {
                if (count _overwatchPositions > _overwatchIdx) then {
                    _spawnPos = _overwatchPositions select _overwatchIdx;
                    _overwatchIdx = _overwatchIdx + 1;
                    _posFound = true;
                };
            } else {
                if (_subCat find "inf" == 0 && _overwatchIdx < _infOverwatchLimit) then {
                    _spawnPos = _overwatchPositions select _overwatchIdx;
                    _overwatchIdx = _overwatchIdx + 1;
                    _posFound = true;
                };
            };
            if (!_posFound && { _isAAVehicle || _isArty }) then {
                diag_log format ["DYNAMIC SPAWN: skipping %1 at %2 - %3 requires overwatch position", _grpType, _locName, if (_isArty) then { "artillery" } else { "AA vehicle" }];
                continue;
            };
            if (!_posFound) then {
                if (count _defensePositions > 0) then {
                    _spawnPos = _defensePositions select (_spawnIdx min (count _defensePositions - 1));
                    _spawnIdx = _spawnIdx + 1;
                    _posFound = true;
                } else {
                    private _mDir = if (count _markerSize > 2) then { _markerSize select 2 } else { 0 };
                    _spawnPos = [_markerCenter, _markerSize, 20, _mDir] call MISSION_CORE_fnc_findVehiclePos;
                    _posFound = true;
                };
            };
            if (_posFound) then {
                private _isArmorSpawn = (_subCat find "tank" > -1 || _subCat find "mech" > -1) && { _subCat find "_aa" == -1 };
                // AA overwatch tanks also count against the max tank cap
                if (_isArmorSpawn || _subCat == "tank_aa") then {
                    private _slot = if (_subCat == "tank_aa") then { "mbt" } else { if (_subCat find "tank" > -1) then { "mbt" } else { "mech" } };
                    if !([_owner, _slot, _markerCenter, _importance] call MISSION_CORE_fnc_armorCapOpen) then {
                        diag_log format ["DYNAMIC SPAWN: skipping %1 at %2 - %3 cap full", _grpType, _locName, _slot];
                        continue;
                    };
                    // Pooled marker: never spawn more MBTs than its tank pool allows, even if
                    // the global cap is open - the pool is the marker's own local allowance.
                    // AA overwatch tanks (tank_aa) never draw from the pool.
                    if (_slot == "mbt" && _subCat != "tank_aa" && _tankPool > 0 && { ([_loc] call MISSION_CORE_fnc_countMBTByMarker) >= _tankPool }) then {
                        diag_log format ["DYNAMIC SPAWN: skipping %1 at %2 - tank pool full (%3)", _grpType, _locName, _tankPool];
                        continue;
                    };
                };
                private _grp = [_grpType, _spawnPos, _owner, _faction, "AWARE", "LIMITED", _importance, _markerCenter, _markerSize] call MISSION_CORE_fnc_spawnGroup;
                if (!isNull _grp) then {
                    _grp setVariable ["MISSION_CORE_ORIGIN_MARKER", _locName];
                    diag_log format ["DYNAMIC SPAWN: %1 spawned at %2 imp=%3 (group %4, wps=%5)", _grpType, _loc select 0, _importance, groupId _grp, count (waypoints _grp)];
                } else {
                    diag_log format ["DYNAMIC SPAWN: %1 at %2 FAILED to spawn", _grpType, _loc select 0];
                };
                if (_isArmorSpawn) then {
                    private _slot = if (_subCat find "tank" > -1) then { "mbt" } else { "mech" };
                    _grp setVariable ["MISSION_CORE_ARMOR_SLOT", _slot];
                    _grp setVariable ["MISSION_CORE_ORDER", "defend"];
                    _grp setVariable ["MISSION_CORE_IDLE", false];
                    leader _grp setVariable ["MISSION_CORE_PATROLLING", false];
                    {
                        private _v = vehicle _x;
                        if (_v != _x && { _v isKindOf "Tank" || _v isKindOf "Wheeled_APC" || _v isKindOf "Tracked_APC" }) then {
                            _v addEventHandler ["Killed", {
                                params ["_killerVeh"];
                                private _s = _owner;
                                private _l = getPos _killerVeh call MISSION_CORE_fnc_getLocByPos;
                                private _n = if (count _l > 0) then { _l select 0 } else { "" };
                                [_s, _markerCenter, _n] call MISSION_CORE_fnc_requestArmorReinforcement;
                            }];
                        };
                    } forEach units _grp;
                } else {
                    if (_subCat find "_aa" > -1) then {
                        // AA stays on defense/overwatch - never pulled into assaults
                        _grp setVariable ["MISSION_CORE_ORDER", "defend"];
                        _grp setVariable ["MISSION_CORE_IDLE", false];
                        _grp setVariable ["MISSION_CORE_AA_DEFENSE", true];
                        if (_subCat == "tank_aa") then { _grp setVariable ["MISSION_CORE_AA_TANK", true]; };
                        leader _grp setVariable ["MISSION_CORE_PATROLLING", false];
                    };
                    if (_isArty) then {
                        // Overwatch artillery holds its marker and shells spotted enemy armor.
                        _grp setVariable ["MISSION_CORE_ORDER", "artillery"];
                        _grp setVariable ["MISSION_CORE_ARMOR_SLOT", "arty"];
                        _grp setVariable ["MISSION_CORE_ARTILLERY", true];
                        private _veh = vehicle (leader _grp);
                        if (!isNull _veh && { _veh != leader _grp }) then {
                            [_grp, _veh, _owner] spawn MISSION_CORE_fnc_overwatchArtillery;
                            diag_log format ["DYNAMIC SPAWN: overwatch artillery %1 armed", groupId _grp];
                        };
                    };
                };
                MISSION_CORE_SPAWNED_GROUPS pushBack _grp;
                _freshGroups pushBack _grp;
            };
        } forEach _presetGroups;

        // Freshly spawned garrison units are committed to the contested area immediately: a
        // marker that spawns into an active battle (player attacking a nearby marker) feeds its
        // new groups straight into the fight instead of leaving them patrolling their own marker.
        // PERMANENT RULE: a marker that is itself a contested zone NEVER marches its own garrison
        // to a DIFFERENT zone - it defends its own fight (its fresh groups target its own center).
        if (count _freshGroups > 0 && _owner in [WEST, EAST]) then {
            private _contestedList = [_owner] call MISSION_CORE_fnc_getContestedMarkers;
            if (count _contestedList > 0) then {
                private _playersA = allPlayers select { alive _x };
                private _selfZone = _contestedList select { (_x select 0) == _locName } param [0, []];
                // A zone's own garrison holds the line at home. Otherwise commit toward the
                // contested zone that's a player is fighting (the relative "own fight" for this marker).
                private _cTarget = if (count _selfZone > 0) then { _selfZone } else { _contestedList select 0 };
                private _bestPD = 1e10;
                if (count _selfZone == 0 && { count _playersA > 0 }) then {
                    {
                        private _mPos = _x select 1;
                        private _pd = 1e10;
                        { private _d = _x distance _mPos; if (_d < _pd) then { _pd = _d; }; } forEach _playersA;
                        if (_pd < _bestPD) then { _bestPD = _pd; _cTarget = _x; };
                    } forEach _contestedList;
                };
                private _committed = 0;
                {
                    if (!isNull _x &&
                        { count units _x > 0 } &&
                        { !(_x getVariable ["MISSION_CORE_AA_DEFENSE", false]) } &&
                        { !(_x getVariable ["MISSION_CORE_ARTILLERY", false]) } &&
                        { !(_x getVariable ["MISSION_CORE_REPLENISH_GROUP", false]) }) then {
                        [_x, _cTarget select 1, _cTarget select 2] call MISSION_CORE_fnc_sendCounterAttack;
                        _committed = _committed + 1;
                    };
                } forEach _freshGroups;
                diag_log format ["DYNAMIC SPAWN: %1 committed %2/%3 fresh groups to contested %4", _locName, _committed, count _freshGroups, _cTarget select 0];
            };
        };

        // BLUFOR HQ forces are now player-driven via the recruit menu (X key).
        // The old automatic 2 MBT + 1 mech HQ force has been removed.

        // Deduct supply for fresh spawn - only for groups that actually spawned. Candidates
        // skipped by the caps must not drain the location's supply (previously a full skip still
        // cost (count _presetGroups) * 3 + 5, pushing supply deep negative while spawning nothing).
        private _spawnedNow = count _freshGroups;
        if (_spawnedNow > 0) then {
            private _supplyCost = _spawnedNow * 3 + 5;
            private _curSupply = MISSION_CORE_LOCATION_SUPPLY getOrDefault [_locName, 0];
            MISSION_CORE_LOCATION_SUPPLY set [_locName, _curSupply - _supplyCost];
            diag_log format ["DYNAMIC SUPPLY: %1 fresh spawn cost %2 (remain=%3)", _locName, _supplyCost, _curSupply - _supplyCost];
        } else {
            diag_log format ["DYNAMIC SUPPLY: %1 fresh spawn skipped all candidates - no supply charged", _locName];
        };
        // Baseline = the men that actually spawned (fresh groups, not theoretical capacity).
        // The 50% capture threshold is measured against this so a light first spawn is never
        // born already-capturable.
        if (isNil "MISSION_CORE_GARRISON_BASELINE") then { MISSION_CORE_GARRISON_BASELINE = createHashMap; };
        private _freshMen = 0;
        { if (!isNull _x) then { _freshMen = _freshMen + ({ alive _x } count units _x); }; } forEach _freshGroups;
        MISSION_CORE_GARRISON_BASELINE set [_locName, _freshMen];
        };
    };
    // Per-marker tank depot: reconcile the physical parked battery with current stock so a
    // freshly activated factory/base shows what it has in the warehouse.
    if ([_loc] call MISSION_CORE_fnc_tankDepotIsDepot) then {
        [_loc] call MISSION_CORE_fnc_tankParkReconcile;
    };
};
