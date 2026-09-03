
// Mount a foot infantry group into a transport that fits - armored 4x4 (prefer gun mount) for
// small squads, a cargo truck with enough space for larger ones. Never an APC.
MISSION_CORE_fnc_mountInfantry = {
    params ["_grp", "_side", "_pos"];
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
    // Pick a spread-out mount point: away from any flagged-unsafe spawn and at least 35m from the
    // last truck(s) mounted at this location, so a wave of trucks never clusters into one pocket.
    if (isNil "MISSION_CORE_TRUCK_LAST_POS") then { MISSION_CORE_TRUCK_LAST_POS = createHashMap; };
    // PERMANENT RULE: no cap on concurrent foot-transport trucks. Every committed squad that is
    // far enough out mounts a truck and rides to the battle - never forced to advance on foot.
    _pos = [_pos] call MISSION_CORE_fnc_ensureLandPos;
    private _lastTruckPos = MISSION_CORE_TRUCK_LAST_POS getOrDefault [str _side, [0, 0, 0]];
    private _mount = _pos;
    for "_i" from 1 to 12 do {
        private _cand = _pos getPos [30 + random 50, random 360];
        private _tooCloseLast = (count _lastTruckPos > 2) && { _cand distance _lastTruckPos < 35 };
        if ([_cand] call MISSION_CORE_fnc_isDryPos && { !([_cand] call MISSION_CORE_fnc_isUnsafeVehicleSpawn) } && { !_tooCloseLast }) exitWith { _mount = _cand; };
    };
    _pos = _mount;
    MISSION_CORE_TRUCK_LAST_POS set [str _side, _pos];
    private _truck = createVehicle [_vehClass, [_pos] call MISSION_CORE_fnc_liftSpawn, [], 5, "CAN_COLLIDE"];
    _grp addVehicle _truck;
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
    {
        if (vehicle _x == _x) then {
            if (isNull (gunner _truck) && { count (fullCrew [_truck, "Gunner", true]) > 0 }) then {
                _x moveInGunner _truck;
            } else {
                _x moveInCargo _truck;
            };
        };
    } forEach units _grp;
    diag_log format ["DYNAMIC TRANSPORT: mounted %1 foot squad (%2 men) into %3 for %4", groupId _grp, count units _grp, _vehClass, _grp getVariable ["MISSION_CORE_ORIGIN_MARKER", "?"]];
    _truck
};
