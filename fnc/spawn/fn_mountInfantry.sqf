
// Mount a foot infantry group into a transport that fits - armored 4x4 (prefer gun mount) for
// small squads, a cargo truck with enough space for larger ones. Never an APC.
// _selfDrive (opt, default false): the squad crews its own truck instead of a spawned driver /
// dedicated driver group. Used by the player hunt, where the contingent drives itself and the
// leader must stay on foot after dismount (see fn_playerHunt).
MISSION_CORE_fnc_mountInfantry = {
    params ["_grp", "_side", "_pos", ["_selfDrive", false]];
    if (isNull _grp || { count units _grp == 0 }) exitWith { objNull };
    private _passCount = { vehicle _x == _x } count units _grp;
    if (_passCount == 0) exitWith { objNull };
    private _factionData = if (_side == WEST) then { MISSION_CORE_BLUFOR_DATA } else { MISSION_CORE_REDFOR_DATA };
    private _vehMap = _factionData select 7;
    // Ground transports only - never helicopters, ships, APCs, or tanks
    private _transPool = (_vehMap getOrDefault ["transport", []]) select {
        _x isKindOf "Car" &&
        { !(_x isKindOf "Wheeled_APC") } &&
        { !(_x isKindOf "Tracked_APC") } &&
        { !(_x isKindOf "Tank") }
    };
    private _isMRAP = { (_this select 0) isKindOf "MRAP_01_Base_F" || { (_this select 0) isKindOf "MRAP_02_Base_F" } || { (_this select 0) isKindOf "MRAP_03_Base_F" } };
    private _mrapPool = _transPool select { [_x] call _isMRAP };
    private _truckPool = _transPool select { !([_x] call _isMRAP) };
    private _capOf = { getNumber (configFile >> "CfgVehicles" >> (_this select 0) >> "transportSoldier") };
    private _fbMraps = (switch (true) do {
        case (_side == WEST): { ["B_MRAP_01_gmg_F", "B_MRAP_01_hmg_F", "B_MRAP_01_F"] };
        case (_side == EAST): { ["O_MRAP_02_gmg_F", "O_MRAP_02_hmg_F", "O_MRAP_02_F"] };
        default { ["I_MRAP_03_gmg_F", "I_MRAP_03_hmg_F", "I_MRAP_03_F"] };
    }) select { isClass (configFile >> "CfgVehicles" >> _x) };
    private _fbTrucks = (switch (true) do {
        case (_side == WEST): { ["B_Truck_01_transport_F", "B_Truck_01_covered_F"] };
        case (_side == EAST): { ["O_Truck_03_transport_F", "O_Truck_03_covered_F"] };
        default { ["I_Truck_02_transport_F", "I_Truck_02_covered_F"] };
    }) select { isClass (configFile >> "CfgVehicles" >> _x) };
    private _vehClass = "";
    if (_passCount <= 4) then {
        // Armored 4x4, prefer a gun-mounted variant that fits the squad
        private _gunMraps = _mrapPool select { (toLower _x) find "gmg" > -1 || { (toLower _x) find "hmg" > -1 } };
        private _pool = if (count _gunMraps > 0) then { _gunMraps } else { _mrapPool };
        private _fit = _pool select { ([_x] call _capOf) >= _passCount };
        if (count _fit > 0) then { _vehClass = selectRandom _fit; }
        else {
            if (count _pool > 0) then { _vehClass = selectRandom _pool; }
            else {
                private _fbFit = _fbMraps select { ([_x] call _capOf) >= _passCount };
                if (count _fbFit > 0) then { _vehClass = selectRandom _fbFit; }
                else { if (count _fbMraps > 0) then { _vehClass = selectRandom _fbMraps; }; };
            };
        };
    };
    if (_vehClass == "") then {
        // More than 4 passengers - use a cargo truck with enough space
        private _fit = _truckPool select { ([_x] call _capOf) >= _passCount };
        if (count _fit > 0) then { _vehClass = selectRandom _fit; }
        else {
            if (count _truckPool > 0) then { _vehClass = selectRandom _truckPool; }
            else {
                private _fbFit = _fbTrucks select { ([_x] call _capOf) >= _passCount };
                if (count _fbFit > 0) then { _vehClass = selectRandom _fbFit; }
                else { _vehClass = selectRandom _fbTrucks; };
            };
        };
    };
    // PERMANENT RULE: no cap on concurrent foot-transport trucks. Every committed squad that is
    // far enough out mounts a truck and rides to the battle - never forced to advance on foot.
    // PERMANENT RULE: transports mount ON the nearest road when one is available (a truck rolls
    // out along the road, facing it); fall back to the nearest flat clear spot otherwise. Every
    // candidate must pass the same safe-spawn check as normal vehicles: dry ground, not a
    // flagged-unsafe spawn, free of any vehicle still parked at the spot, and clear of hard
    // geometry AND terrain objects (trees, rocks, forest) within 8m - so a truck never
    // materializes on a mountain slope or in a treeline it physically can't cross.
    //
    // SAVED SPOTS: confirmed-clear mount points are cached per side and re-used for further
    // spawns, so a wave of trucks keeps rolling out of the same proven road pockets instead of
    // scattering into fresh random spots. Every spawn quick-checks each saved spot ("is anything
    // still parked here?"); any that has a vehicle on it is dropped from the cache, and a fresh
    // safe location is found and saved in its place.
    if (isNil "MISSION_CORE_TRUCK_SAFE_SPOTS") then { MISSION_CORE_TRUCK_SAFE_SPOTS = createHashMap; };
    if (isNil "MISSION_CORE_TRUCK_LAST_POS") then { MISSION_CORE_TRUCK_LAST_POS = createHashMap; };
    _pos = [_pos] call MISSION_CORE_fnc_ensureLandPos;
    private _existingVehs = vehicles select { alive _x && { _x isKindOf "LandVehicle" } };
    private _spotFree = {
        params ["_p"];
        _existingVehs findIf { _p distance _x < 40 } == -1
    };
    // The regular "safe-to-spawn" check used everywhere else, extended for trucks: isDryPos, not
    // a spawn-kill flagged spot, no vehicle parked on it, and clear of geometry. findVehiclePos
    // only excluded config-class objects; the nearestTerrainObjects filter here also clears
    // terrain-placed trees/rocks/forest so a road pocket in a treeline or on a slope is rejected.
    private _spotSafe = {
        params ["_p"];
        ([_p] call MISSION_CORE_fnc_isDryPos)
        && { !([_p] call MISSION_CORE_fnc_isUnsafeVehicleSpawn) }
        && { [_p] call _spotFree }
        && { count (nearestObjects [_p, ["Building", "House", "Strategic", "Fortress", "Wall", "Fence"], 8]) == 0 }
        && { count (nearestTerrainObjects [_p, ["TREE", "FOREST", "BUSH", "FENCE", "WALL", "HEDGE", "ROCK", "ROCKS", "SMALL TREE", "FOREST BORDER", "FOREST SQUARE", "FOREST TRIANGLE"], 8]) == 0 }
    };
    private _lastTruckPos = MISSION_CORE_TRUCK_LAST_POS getOrDefault [str _side, [0, 0, 0]];
    private _savedKey = str _side;
    private _savedSpots = MISSION_CORE_TRUCK_SAFE_SPOTS getOrDefault [_savedKey, []];
    // Drop occluded saved spots (a truck still on them) and keep only ones near this squad, then
    // reuse the closest. Nearest-first sort: [distance, pos] so sort true does numeric ordering.
    _savedSpots = _savedSpots select { ([_x] call _spotSafe) && { _x distance2D _pos <= 400 } };
    private _near = _savedSpots apply { [_x distance2D _pos, _x] };
    _near sort true;
    private _mount = _pos;
    private _mountOnRoad = false;
    private _mountFound = false;
    if (count _near > 0) then {
        _mount = (_near select 0) select 1;
        _mountFound = true;
    };
    if (!_mountFound) then {
        // Nearest usable road within 300m.
        private _roads = _pos nearRoads 300;
        if (count _roads > 0) then {
            private _rMax = ((count _roads) - 1) min 24;
            for "_r" from 0 to _rMax do {
                private _cand = getPosATL (_roads select _r);
                private _tooCloseLast = (count _lastTruckPos > 2) && { _cand distance _lastTruckPos < 35 };
                if ([_cand] call _spotSafe && { !_tooCloseLast }) exitWith { _mount = _cand; _mountOnRoad = true; _mountFound = true; };
            };
        };
    };
    if (!_mountFound) then {
        // No usable road: nearest flat, clear ground. Trucks need level ground a raw clear spot can
        // still lack, so probe isFlatEmpty for the gradient and prefer a Flat position when one
        // resolves (count _flat == 3); a clear non-flat spot is the last-ditch fallback.
        for "_i" from 1 to 12 do {
            private _cand = _pos getPos [30 + random 50, random 360];
            private _tooCloseLast = (count _lastTruckPos > 2) && { _cand distance _lastTruckPos < 35 };
            if (_tooCloseLast) then { continue; };
            if ([_cand] call _spotSafe) then {
                _mount = _cand;
                _mountFound = true;
                private _flat = _cand isFlatEmpty [6, -1, 0.25, 16, 0, false, objNull];
                if (count _flat == 3) then { _mount = [_flat select 0, _flat select 1, 0]; };
                break;
            };
        };
    };
    _pos = _mount;
    // Save the confirmed mount point for further spawns (cap a few per side; skip duplicates).
    if (!(_pos in _savedSpots)) then {
        if (count _savedSpots >= 6) then { _savedSpots = _savedSpots select [count _savedSpots - 5, 5]; };
        _savedSpots pushBack _pos;
        MISSION_CORE_TRUCK_SAFE_SPOTS set [_savedKey, _savedSpots];
    };
    MISSION_CORE_TRUCK_LAST_POS set [_savedKey, _pos];
    private _truck = createVehicle [_vehClass, [_pos] call MISSION_CORE_fnc_liftSpawn, [], 5, "CAN_COLLIDE"];
    _grp addVehicle _truck;
    [_truck] call MISSION_CORE_fnc_alignVehicleToRoad;
    _truck setVariable ["MISSION_CORE_TRUCK_ORIGIN", _pos];
    private _hasGun = [_truck] call MISSION_CORE_fnc_hasMountedGun;
    if (!_hasGun) then {
        // Count foot-transport trucks destroyed before they unload. Three in quick succession
        // (within 90s of each other) push the unload waypoint 50m further back, repeating up to
        // three times (150m total) so replacements stop rolling straight into the kill zone.
        if (isNil "MISSION_CORE_TRUCK_KILLS") then { MISSION_CORE_TRUCK_KILLS = [[0, -1e10], [0, -1e10]]; };
        _truck addEventHandler ["Killed", {
            params ["_v"];
            private _kIdx = if (_side == WEST) then { 0 } else { 1 };
            if (isNil "MISSION_CORE_TRUCK_KILLS") then { MISSION_CORE_TRUCK_KILLS = [[0, -1e10], [0, -1e10]]; };
            private _e = MISSION_CORE_TRUCK_KILLS select _kIdx;
            if (time - (_e select 1) > 90) then { _e set [0, 0]; };
            _e set [0, (_e select 0) + 1];
            _e set [1, time];
            // This truck died before unloading. Flag its spawn point (origin) and its death spot
            // (the kill zone) as unsafe so the next truck mounts/unloads somewhere else instead of
            // rolling straight back into the same kill pocket.
            private _o = _v getVariable ["MISSION_CORE_TRUCK_ORIGIN", [0, 0, 0]];
            if (count _o > 2) then { [_o] call MISSION_CORE_fnc_markUnsafeVehicleSpawn; };
            [getPos _v] call MISSION_CORE_fnc_markUnsafeVehicleSpawn;
            diag_log format ["AI COMMANDER: foot truck %1 destroyed (streak %2) - unload point pushed further back", typeOf _v, (_e select 0)];
        }];
    };
    private _crewClass = (switch (true) do {
        case (_side == WEST): { "B_crew_F" };
        case (_side == EAST): { "O_crew_F" };
        default { "I_crew_F" };
    });
    if (isNull (driver _truck)) then {
        if (_selfDrive) then {
            // SELF-DRIVE (player hunt): no spawned driver and no dedicated driver group - the squad
            // crews its own truck. Prefer NON-leader men for the seats that may stay mounted on a gun
            // truck (driver, gunner) so the group leader still leads the foot sweep after dismount. A
            // plain truck needs only a driver; on it everyone (driver included) dismounts later.
            private _ldr = leader _grp;
            private _men = units _grp select { alive _x && { vehicle _x == _x } };
            private _pool = _men select { _x != _ldr };
            if (count _pool == 0) then { _pool = +_men; };
            if (count _pool > 0) then { (_pool deleteAt 0) moveInDriver _truck; };
            if (_hasGun && { isNull (gunner _truck) } && { count (fullCrew [_truck, "Gunner", true]) > 0 } && { count _pool > 0 }) then {
                (_pool deleteAt 0) moveInGunner _truck;
            };
        } else {
            private _drv = grpNull;
            if (!_hasGun) then {
                // Foot transport: the driver rides in a dedicated group so the truck can use a
                // TRANSPORT UNLOAD waypoint - cargo of OTHER groups disembarks at the drop point.
                // The transported squad never owns the truck, so its leader never tries to drive it.
                private _drvGrp = createGroup _side;
                _drvGrp addVehicle _truck;
                _truck setVariable ["MISSION_CORE_DRIVER_GROUP", _drvGrp];
                _drv = _drvGrp createUnit [_crewClass, _pos, [], 0, "NONE"];
            } else {
                _drv = _grp createUnit [_crewClass, _pos, [], 0, "NONE"];
            };
            _drv moveInDriver _truck;
        };
    };
    {
        if (vehicle _x == _x) then {
            // Self-drive fills the gunner seat up front with a non-leader; everyone else (leader
            // included) rides as cargo so a kept gunner never strands the group leader in the truck.
            if (!_selfDrive && { isNull (gunner _truck) } && { count (fullCrew [_truck, "Gunner", true]) > 0 }) then {
                _x moveInGunner _truck;
            } else {
                _x moveInCargo _truck;
            };
        };
    } forEach units _grp;
    diag_log format ["DYNAMIC TRANSPORT: mounted %1 foot squad (%2 men) into %3 for %4%5", groupId _grp, count units _grp, _vehClass, _grp getVariable ["MISSION_CORE_ORIGIN_MARKER", "?"], if (_selfDrive) then { " (self-drive)" } else { "" }];
    _truck
};
