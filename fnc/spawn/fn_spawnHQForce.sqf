
MISSION_CORE_fnc_spawnHQForce = {
    params ["_targetPos", "_side", "_factionData", "_importance", ["_markerSize", [250, 250]], ["_originName", "HQ"], ["_tankPool", 0]];
    // HQ force MBTs must respect the HQ's tank pool on top of the global cap: count tanks
    // whose home center sits within the HQ extent, then only spawn while below the pool.
    private _pooled = _tankPool > 0;
    private _poolRadius = if (_pooled) then { ((_markerSize select 0) max (_markerSize select 1)) + 100 } else { 0 };
    private _dir = if (count _markerSize > 2) then { _markerSize select 2 } else { 0 };
    private _vehMap = _factionData select 7;
    private _mbtClasses = _vehMap getOrDefault ["mbt", []];
    private _apcClasses = _vehMap getOrDefault ["apc", []];
    private _unitPool = _factionData select 19;
    if (count _unitPool == 0) then { _unitPool = ["B_Soldier_F"]; };
    private _unitPoolCargo = _unitPool select { _x find "Officer" == -1 && _x find "SL" == -1 && _x find "Leader" == -1 && _x find "TL" == -1 && _x find "Crew" == -1 && _x find "Pilot" == -1 };
    if (count _unitPoolCargo == 0) then { _unitPoolCargo = _unitPool; };
    private _roles = _factionData select 5;
    private _atClasses = _roles getOrDefault ["at", []];
    private _crewClass = if (_side == WEST) then { "B_crew_F" } else { "O_crew_F" };
    private _isBLU = if (_side == WEST) then { "BLUFOR" } else { "REDFOR" };

    // Spawn MBT section (2 tanks, one group each) at HQ; per-marker + global cap.
    // Precompute a 2-tank road column so the section deploys in a line on the road.
    private _mbtCount = 2;
    private _mbtSpots = [_targetPos, _markerSize, _mbtCount, 20] call MISSION_CORE_fnc_findVehicleColumnPos;
    for "_t" from 1 to _mbtCount do {
        // Pooled HQ: stop spawning MBTs once the HQ's tank pool is filled.
        if (_pooled && { ([_targetPos, _poolRadius] call MISSION_CORE_fnc_countArmorByHome) select 0 >= _tankPool }) exitWith {
            diag_log format ["DYNAMIC SPAWN: HQ %1 tank force stopped - pool full (%2)", _originName, _tankPool];
        };
        if ([_side, "mbt", _targetPos, _importance] call MISSION_CORE_fnc_armorCapOpen && count _mbtClasses > 0) then {
            private _vehPos = if (_t - 1 < count _mbtSpots) then { _mbtSpots select (_t - 1) } else { [] };
            if (count _vehPos < 2) then { _vehPos = [_targetPos, _markerSize, 20, _dir] call MISSION_CORE_fnc_findVehiclePos; };
            if (count _vehPos < 2) then { _vehPos = [_targetPos] call MISSION_CORE_fnc_ensureLandPos; };
            if (count _vehPos == 2) then { _vehPos pushBack 0; };
            private _tank = createVehicle [selectRandom _mbtClasses, [_vehPos] call MISSION_CORE_fnc_liftSpawn, [], 5, "CAN_COLLIDE"];
            private _grp = createGroup _side;
            _grp addVehicle _tank;
            private _tc = [];
            for "_c" from 1 to 3 do { _tc pushBack (_grp createUnit [_crewClass, _vehPos, [], 0, "NONE"]); };
            _tc params [["_d", objNull], ["_g", objNull], ["_c", objNull]];
            if (!isNull _d && isNull (driver _tank)) then { _d moveInDriver _tank; };
            if (!isNull _g && isNull (gunner _tank)) then { _g moveInGunner _tank; };
            if (!isNull _c && isNull (commander _tank)) then { _c moveInCommander _tank; };
            [_tank] call MISSION_CORE_fnc_alignVehicleToRoad;
            _grp setBehaviour "AWARE"; _grp setCombatMode "YELLOW"; _grp setSpeedMode "FULL";
            _grp setVariable [format ["MISSION_CORE_%1", _isBLU], true];
            _grp setVariable ["MISSION_CORE_MARKER_CENTER", _targetPos];
            _grp setVariable ["MISSION_CORE_IDLE", false];
            _grp setVariable ["MISSION_CORE_ORDER", "defend"];
            _grp setVariable ["MISSION_CORE_IMPORTANCE", _importance];
            _grp setVariable ["MISSION_CORE_ORIGIN_MARKER", _originName];
            _grp setVariable ["MISSION_CORE_ARMOR_SLOT", "mbt"];
            _tank setVariable ["MISSION_CORE_REINF_TARGET", _targetPos];
            _tank addEventHandler ["Killed", {
                params ["_v"];
                private _s = _side;
                private _t = _v getVariable ["MISSION_CORE_REINF_TARGET", [0, 0, 0]];
                private _l = getPos _v call MISSION_CORE_fnc_getLocByPos;
                private _n = if (count _l > 0) then { _l select 0 } else { "" };
                [_s, _t, _n] call MISSION_CORE_fnc_requestArmorReinforcement;
            }];
            [_tank, _grp, _side] call MISSION_CORE_fnc_guardSpawnKill;
            MISSION_CORE_SPAWNED_GROUPS pushBack _grp;
        };
    };

    // Spawn 1 mech (APC + infantry squad) in its own group (per-marker cap: 1 mech alive)
    if ([_side, "mech", _targetPos, _importance] call MISSION_CORE_fnc_armorCapOpen && count _apcClasses > 0) then {
        private _apcPos = [_targetPos, _markerSize, 20, _dir] call MISSION_CORE_fnc_findVehiclePos;
        if (count _apcPos < 2) then { _apcPos = [_targetPos] call MISSION_CORE_fnc_ensureLandPos; };
        if (count _apcPos == 2) then { _apcPos pushBack 0; };
        private _apc = createVehicle [selectRandom _apcClasses, [_apcPos] call MISSION_CORE_fnc_liftSpawn, [], 5, "CAN_COLLIDE"];
        private _grp = createGroup _side;
        _grp addVehicle _apc;
        private _driver = _grp createUnit [_crewClass, _apcPos, [], 0, "NONE"];
        _driver moveInDriver _apc;
        if (isNull (gunner _apc)) then { private _g = _grp createUnit [_crewClass, _apcPos, [], 0, "NONE"]; _g moveInGunner _apc; };
        private _cargoSlots = _apc emptyPositions "cargo";
        private _infantry = [];
        for "_c" from 1 to (_cargoSlots min 8) do {
            private _unitClass = if (count _atClasses > 0 && {_c <= 4}) then { selectRandom _atClasses } else { selectRandom _unitPoolCargo };
            private _u = _grp createUnit [_unitClass, _apcPos, [], 0, "NONE"];
            _u moveInCargo _apc;
            _infantry pushBack _u;
        };
        [_apc] call MISSION_CORE_fnc_alignVehicleToRoad;
        _grp setBehaviour "AWARE"; _grp setCombatMode "YELLOW"; _grp setSpeedMode "FULL";
        _grp setVariable [format ["MISSION_CORE_%1", _isBLU], true];
        _grp setVariable ["MISSION_CORE_MARKER_CENTER", _targetPos];
        _grp setVariable ["MISSION_CORE_IDLE", false];
        _grp setVariable ["MISSION_CORE_ORDER", "defend"];
        _grp setVariable ["MISSION_CORE_IMPORTANCE", _importance];
        _grp setVariable ["MISSION_CORE_ORIGIN_MARKER", _originName];
        _grp setVariable ["MISSION_CORE_ARMOR_SLOT", "mech"];
        _apc setVariable ["MISSION_CORE_REINF_TARGET", _targetPos];
        _apc addEventHandler ["Killed", {
            params ["_v"];
            private _s = _side;
            private _t = _v getVariable ["MISSION_CORE_REINF_TARGET", [0, 0, 0]];
            private _l = getPos _v call MISSION_CORE_fnc_getLocByPos;
            private _n = if (count _l > 0) then { _l select 0 } else { "" };
            [_s, _t, _n] call MISSION_CORE_fnc_requestArmorReinforcement;
        }];
        [_apc, _grp, _side] call MISSION_CORE_fnc_guardSpawnKill;
        MISSION_CORE_SPAWNED_GROUPS pushBack _grp;

        // Mech dismount + alert script
        [_grp, _apc, _targetPos] spawn {
            params ["_grp", "_apc", "_basePos"];
            private _side = side _apc;
            private _alerted = false;
            while { alive _apc && {count units _grp > 0} } do {
                sleep 3;
                private _enemies = allUnits select { side _x != _side && { alive _x } && { _x distance _apc < 400 } };
                if (!_alerted && count _enemies > 0) then {
                    _alerted = true;
                    // Dismount cargo
                    {
                        if (_x != driver _apc && _x != gunner _apc) then {
                            unassignVehicle _x;
                            [_x] orderGetIn false;
                            _x action ["Eject", _apc];
                        };
                    } forEach units _grp;
                    _grp setCombatMode "RED";
                    _grp setBehaviour "COMBAT";
                    sleep 1;
                    // Infantry attacks nearest enemy
                    private _nearest = _enemies select 0;
                    { private _d = _x distance _apc; if (_d < _nearest distance _apc) then { _nearest = _x; }; } forEach _enemies;
                    { _x doWatch (getPos _nearest); } forEach units _grp;
                    private _wp = _grp addWaypoint [getPos _nearest, 50];
                    _wp setWaypointType "SAD";
                    _wp setWaypointSpeed "FULL";
                    _wp setWaypointBehaviour "COMBAT";
                    _grp setCurrentWaypoint _wp;
                    _grp setSpeedMode "FULL";
                };
            };
        };
    };
    // HQ alert script - puts all groups on high alert when enemies approach
    [_targetPos, _side] spawn {
        params ["_basePos", "_side"];
        sleep 10;
        while { true } do {
            sleep 5;
            private _enemies = allUnits select { side _x != _side && { alive _x } && { _x distance _basePos < 500 } };
            if (count _enemies > 0) then {
                private _allHQ = MISSION_CORE_SPAWNED_GROUPS select {
                    !isNull _x &&
                    { (_x getVariable ["MISSION_CORE_MARKER_CENTER", [0,0,0]]) distance _basePos < 300 } &&
                    { _x getVariable ["MISSION_CORE_ORDER", ""] == "" }
                };
                {
                    _x setVariable ["MISSION_CORE_ORDER", "engage"];
                    _x setBehaviour "COMBAT";
                    _x setCombatMode "RED";
                    _x setSpeedMode "FULL";
                    [_x] call MISSION_CORE_fnc_clearGroupWaypoints;
                    private _wp = _x addWaypoint [_basePos, 100];
                    _wp setWaypointType "SAD";
                    _wp setWaypointSpeed "FULL";
                    _wp setWaypointBehaviour "COMBAT";
                    _x setCurrentWaypoint _wp;
                } forEach _allHQ;
        };
    };
};

};
