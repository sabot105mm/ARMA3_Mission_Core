
MISSION_CORE_fnc_requestArmorReinforcement = {
    params ["_side", "_targetPos", "_targetName", ["_fromQueue", false]];
    // Transport trucks / civilian-class vehicles share a Killed handler with armor and can report a
    // non-WEST/non-EAST side. Refuse those outright: they must never queue a foot "replenish", touch
    // the BLUFOR/REDFOR cooldown map, or spawn a job with an empty target key like "repl_".
    if !(_side in [WEST, EAST]) exitWith {
        diag_log format ["DYNAMIC ARMOR REINF: rejected side %1 (target %2)", _side, _targetName];
        false
    };
    if (!(_targetPos isEqualType [])) then { _targetPos = [0, 0, 0]; };
    // A killed vehicle near a marker should always carry its marker name; resolve it if missing so
    // reinforcement keys are never empty (e.g. "repl_").
    if (_targetName == "" && { !(_targetPos isEqualTo [0, 0, 0]) }) then {
        private _tlr = _targetPos call MISSION_CORE_fnc_getLocByPos;
        if (count _tlr > 0) then { _targetName = _tlr select 0; };
    };
    if (isNil "MISSION_CORE_ARMOR_REINF_COOLDOWN") then { MISSION_CORE_ARMOR_REINF_COOLDOWN = createHashMap; };
    private _sideKey = if (_side == WEST) then { "BLUFOR" } else { "REDFOR" };
    private _lastReinf = MISSION_CORE_ARMOR_REINF_COOLDOWN getOrDefault [_sideKey, -99999];
    if (!_fromQueue && { time - _lastReinf < 300 }) exitWith {
        diag_log format ["DYNAMIC ARMOR REINF: %1 reinforcement on cooldown (last=%2)", _sideKey, _lastReinf];
    };
    if (!_fromQueue) then { MISSION_CORE_ARMOR_REINF_COOLDOWN set [_sideKey, time]; };
    private _factionData = if (_side == WEST) then { MISSION_CORE_BLUFOR_DATA } else { MISSION_CORE_REDFOR_DATA };
    private _vehMap = _factionData select 7;
    private _mbtClasses = _vehMap getOrDefault ["mbt", []];
    private _apcClasses = _vehMap getOrDefault ["apc", []];
    private _targetImportance = 1;
    private _tl = MISSION_CORE_CACHED_POSITIONS select { (_x select 0) == _targetName };
    if (count _tl > 0) then { _targetImportance = (_tl select 0) select 7; };
    // Tank pool refill: if the target marker owns a tank pool and is BELOW it (a tank died),
    // the replacement MUST be an MBT - the pool drives the slot, not the 3:1 mech/inf bias.
    private _poolRefill = false;
    if (count _tl > 0) then {
        private _tPool = [(_tl select 0)] call MISSION_CORE_fnc_markerTankPool;
        if (_tPool > 0 && { ([(_tl select 0)] call MISSION_CORE_fnc_countMBTByMarker) < _tPool }) then {
            _poolRefill = true;
        };
    };

    private _slot = "";
    private _vehClass = "";
    private _tlEntry = if (count _tl > 0) then { _tl select 0 } else { _targetPos };
    // Does this side control any OTHER marker at all? A contested city with no friendly neighbor
    // cannot be replenished from the nearest-marker fallback, so it gets doctrine reinforcements
    // spawned 1500m out instead of an edge-of-marker foot squad.
    private _hasFriend = false;
    {
        if ((_x select 4) == _side && { (_x select 0) != _targetName }) exitWith { _hasFriend = true; };
    } forEach MISSION_CORE_CACHED_POSITIONS;
    // Reinforcement mix is biased 3:1 toward mech + infantry over MBT armor, so a front line that
    // loses a tank is replenished with combined-arms (APC or a foot squad) more often than a new tank.
    // A marker BELOW its tank pool is the exception: refill the pool with an MBT first.
    private _mechOpen = { ([_side, "mech", _targetPos, _targetImportance] call MISSION_CORE_fnc_armorCapOpen) && { count _apcClasses > 0 } };
    private _mbtOpen = { ([_side, "mbt", _targetPos, _targetImportance] call MISSION_CORE_fnc_armorCapOpen) && { count _mbtClasses > 0 } };
    // The edge-of-marker foot "replenish" fallback only makes sense when a friendly neighbor exists
    // to funnel reinforcements through; with no neighbor, keep the armor/mech doctrine slots.
    private _infOpen = { _hasFriend && { ([_side, "inf"] call MISSION_CORE_fnc_countTownCategory) < 3 } };
    if (_poolRefill) then {
        if (call _mbtOpen) then {
            _slot = "mbt"; _vehClass = selectRandom _mbtClasses;
        };
    } else {
        if ((random 1) < 0.75) then {
            if (call _mechOpen) then {
                _slot = "mech"; _vehClass = selectRandom _apcClasses;
            } else {
                if (call _infOpen) then {
                    _slot = "inf";
                } else {
                    if (call _mbtOpen) then {
                        _slot = "mbt"; _vehClass = selectRandom _mbtClasses;
                    };
                };
            };
        } else {
            if (call _mbtOpen) then {
                _slot = "mbt"; _vehClass = selectRandom _mbtClasses;
            } else {
                if (call _mechOpen) then {
                    _slot = "mech"; _vehClass = selectRandom _apcClasses;
                } else {
                    if (call _infOpen) then {
                        _slot = "inf";
                    };
                };
            };
        };
    };
    if (_slot == "inf") exitWith {
        private _mSize = if (count _tlEntry > 8) then { _tlEntry select 8 } else { [200, 200] };
        // Spawn beyond the marker edge, on the side facing away from the nearest player, so the
        // foot squad never appears inside the players' sightlines
        private _edgeRadius = ((_mSize select 0) max (_mSize select 1)) + 75;
        private _players = allPlayers select { alive _x };
        private _farDir = random 360;
        if (count _players > 0) then {
            private _nearestP = _players select 0;
            private _bestD = _nearestP distance _targetPos;
            { private _d = _x distance _targetPos; if (_d < _bestD) then { _bestD = _d; _nearestP = _x; }; } forEach _players;
            _farDir = (_nearestP getDir _targetPos) + 180;
        };
        ["MISSION_CORE_fnc_queuedReplenish", format ["repl_%1", _targetName], [_side, _tlEntry, _targetImportance, _targetPos, _targetName, _farDir, _edgeRadius]] call MISSION_CORE_fnc_enqueueSpawn;
        diag_log format ["DYNAMIC ARMOR REINF: %1 infantry reinforcement queued for %2 (combined-arms bias)", _side, _targetName];
    };
    // Caps are full: queue the armor request to spawn when a tank/APC is KIA and frees a slot
    if (_vehClass == "") exitWith {
        if (!_fromQueue) then {
            ["MISSION_CORE_fnc_queuedArmorReinf", format ["armor_%1_%2", _sideKey, _targetName], [_side, _targetPos, _targetName]] call MISSION_CORE_fnc_enqueueSpawn;
        };
    };

    // MBT reinforcements come from the factory/depot system ONLY - the depot order loop routes
    // them to the nearest warehouse with stock and ships them as a road convoy. MBTs are never
    // provider-spawned (the old nearest-neighbor cascade).
    if (_slot == "mbt") exitWith {
        private _orderN = 1;
        if (count _tl > 0) then {
            private _tPool = [(_tl select 0)] call MISSION_CORE_fnc_markerTankPool;
            if (_tPool > 0) then {
                _orderN = ((_tPool - [(_tl select 0)] call MISSION_CORE_fnc_countMBTByMarker) max 0);
            };
        };
        if (_orderN > 0) then {
            [_side, _targetName, _targetPos, _orderN] call MISSION_CORE_fnc_orderTank;
            diag_log format ["DYNAMIC ARMOR REINF: %1 MBT reinforcement to factory order for %2 (n=%3)", _side, _targetName, _orderN];
        };
        true
    };

    private _providers = MISSION_CORE_CACHED_POSITIONS select {
        (_x select 4) == _side &&
        { (_x select 0) != _targetName } &&
        { (MISSION_CORE_LOCATION_SUPPLY getOrDefault [_x select 0, 0]) > (_x select 7) * 10 }
    };
    private _providerName = "";
    private _providerImportance = 1;
    private _spawnPos = _targetPos;
    if (count _providers > 0) then {
        private _provider = _providers select 0;
        private _bestD = _targetPos distance (_provider select 1);
        {
            private _d = _targetPos distance (_x select 1);
            if (_d < _bestD) then { _bestD = _d; _provider = _x; };
        } forEach _providers;
        _providerName = _provider select 0;
        _providerImportance = _provider select 7;
        private _pSize = if (count _provider > 8) then { _provider select 8 } else { [250, 250] };
        private _pDir = if (count _pSize > 2) then { _pSize select 2 } else { 0 };
        _spawnPos = [_provider select 1, _pSize, 20, _pDir] call MISSION_CORE_fnc_findVehiclePos;
    } else {
        // No provider with supply: still spawn at the nearest friendly marker so armor always
        // arrives from a neighbor and never materializes inside the contested area
        private _nearestFriend = [];
        private _nearestFriendD = 999999;
        {
            if ((_x select 4) == _side && { (_x select 0) != _targetName }) then {
                private _d = _targetPos distance (_x select 1);
                if (_d < _nearestFriendD) then { _nearestFriendD = _d; _nearestFriend = _x; };
            };
        } forEach MISSION_CORE_CACHED_POSITIONS;
        if (count _nearestFriend > 0) then {
            _providerName = _nearestFriend select 0;
            _providerImportance = _nearestFriend select 7;
            private _fSize = if (count _nearestFriend > 8) then { _nearestFriend select 8 } else { [250, 250] };
            private _fDir = if (count _fSize > 2) then { _fSize select 2 } else { 0 };
            _spawnPos = [_nearestFriend select 1, _fSize, 20, _fDir] call MISSION_CORE_fnc_findVehiclePos;
        } else {
            // No friendly marker exists at all: spawn the reinforcement 1500m out from the
            // contested center following the doctrine (armor drives in as a proper assault force
            // instead of materializing on top of the fight). The tank/APC rides a full move order
            // to the target set below.
            _spawnPos = _targetPos getPos [1500, random 360];
            _providerImportance = 1;
        };
    };

    private _grp = createGroup _side;
    _spawnPos = [_spawnPos, 0, 100, 10, 0, 0.5, 0] call BIS_fnc_findSafePos;
    if (count _spawnPos < 2) then { _spawnPos = [_spawnPos] call MISSION_CORE_fnc_ensureLandPos; };
    if (count _spawnPos == 2) then { _spawnPos pushBack 0; };
    private _veh = createVehicle [_vehClass, [_spawnPos] call MISSION_CORE_fnc_liftSpawn, [], 5, "CAN_COLLIDE"];
    _grp addVehicle _veh;
    private _crewClass = if (_side == WEST) then { "B_crew_F" } else { "O_crew_F" };
    private _crewList = [];
    for "_c" from 1 to 3 do { _crewList pushBack (_grp createUnit [_crewClass, _spawnPos, [], 0, "NONE"]); };
    _crewList params [["_d", objNull], ["_g", objNull], ["_c", objNull]];
    if (!isNull _d && isNull (driver _veh)) then { _d moveInDriver _veh; };
    if (!isNull _g && isNull (gunner _veh)) then { _g moveInGunner _veh; };
    if (!isNull _c && isNull (commander _veh)) then { _c moveInCommander _veh; };
    _veh setVariable ["MISSION_CORE_REINF_TARGET", _targetPos];
    _veh setVariable ["MISSION_CORE_REINF_LOCNAME", _targetName];
    _veh addEventHandler ["Killed", {
        params ["_v"];
        private _s = _side;
        private _t = _v getVariable ["MISSION_CORE_REINF_TARGET", [0, 0, 0]];
        private _tn = _v getVariable ["MISSION_CORE_REINF_LOCNAME", ""];
        if (_t isEqualTo [0, 0, 0] && _tn == "") exitWith {};
        [_s, _t, _tn] call MISSION_CORE_fnc_requestArmorReinforcement;
    }];
    [_veh, _grp, _side] call MISSION_CORE_fnc_guardSpawnKill;
    _grp setBehaviour "AWARE"; _grp setCombatMode "YELLOW"; _grp setSpeedMode "FULL";
    private _isBLU = if (_side == WEST) then { "BLUFOR" } else { "REDFOR" };
    _grp setVariable [format ["MISSION_CORE_%1", _isBLU], true];
    _grp setVariable ["MISSION_CORE_MARKER_CENTER", _targetPos];
    _grp setVariable ["MISSION_CORE_IDLE", false];
    _grp setVariable ["MISSION_CORE_ORDER", "defend"];
    _grp setVariable ["MISSION_CORE_IMPORTANCE", _providerImportance];
    _grp setVariable ["MISSION_CORE_ORIGIN_MARKER", if (_providerName != "") then { _providerName } else { _targetName }];
    if (_slot == "mbt" || _slot == "mech") then { _grp setVariable ["MISSION_CORE_ARMOR_SLOT", _slot]; };
    if (isNil "MISSION_CORE_SPAWNED_GROUPS") then { MISSION_CORE_SPAWNED_GROUPS = []; };
    MISSION_CORE_SPAWNED_GROUPS pushBack _grp;
    private _wp = _grp addWaypoint [_targetPos, 100];
    _wp setWaypointType "MOVE";
    _wp setWaypointSpeed "FULL";
    _wp setWaypointBehaviour "AWARE";
    _grp setCurrentWaypoint _wp;
    private _cost = 8;
    if (_providerName != "") then {
        private _cur = MISSION_CORE_LOCATION_SUPPLY getOrDefault [_providerName, 0];
        MISSION_CORE_LOCATION_SUPPLY set [_providerName, _cur - _cost];
    };
    diag_log format ["DYNAMIC ARMOR REINF: %1 %2 from %3 -> %4 (cost %5)", _side, _slot, _providerName, _targetName, _cost];
};
