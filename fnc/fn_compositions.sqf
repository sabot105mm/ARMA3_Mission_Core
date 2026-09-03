MISSION_CORE_fnc_loadComposition = {
    private _compName = _this;
    private _compPath = "comps\" + _compName + ".sqf";
    if !(fileExists _compPath) exitWith { diag_log format ["COMP: File not found: %1", _compPath]; [] };
    call compile preprocessFileLineNumbers _compPath;
};

MISSION_CORE_fnc_placeComposition = {
    private _params = _this;
    private _compName = _params select 0;
    private _position = _params select 1;
    private _dir = if (count _params > 2) then { _params select 2 } else { 0 };
    private _side = if (count _params > 3) then { _params select 3 } else { WEST };
    private _compData = _compName call MISSION_CORE_fnc_loadComposition;
    if (count _compData == 0) exitWith {};
    private _objects = [];
    {
        private _objData = _x;
        private _class = _objData select 0;
        private _relPos = _objData select 1;
        private _relDir = _objData select 2;
        if (_side == EAST && { _class select [0, 2] == "B_" }) then { _class = "O_" + (_class select [2, 99]); };
        if (_side == WEST && { _class select [0, 2] == "O_" }) then { _class = "B_" + (_class select [2, 99]); };
        private _pos = _position getPos [_relPos distance [0,0,0], ((_relPos select 1) atan2 (_relPos select 0)) + _dir];
        private _obj = _class createVehicle _pos;
        _obj setDir (_relDir + _dir);
        _obj setPos _pos;
        if (_side != WEST) then { _obj setCaptive false; };
        _objects pushBack _obj;
    } forEach _compData;
    _objects
};

MISSION_CORE_fnc_placeLocationCompositions = {
    private _cached = _this;
    {
        private _loc = _x;
        private _cfgComps = missionConfigFile >> "LOCATION_PRESETS" >> (_loc select 2) >> "compositions";
        private _comps = if (isClass _cfgComps) then { getArray _cfgComps } else { [] };
        {
            private _defPositions = _loc select 5;
            if (count _defPositions > 0) then {
                [_x, _defPositions select 0, 0, _loc select 4] call MISSION_CORE_fnc_placeComposition;
            };
        } forEach _comps;
    } forEach _cached;
};

// Scan for a level, object-free spot near _center to place a large bunker
MISSION_CORE_fnc_findFlatSpot = {
    params ["_center", ["_minR", 5], ["_maxR", 45], ["_clearDist", 14]];
    private _result = [0, 0, 0];
    private _tries = 24;
    for "_i" from 1 to _tries do {
        private _ang = random 360;
        private _r = _minR + random ((_maxR - _minR) max 1);
        private _p = _center getPos [_r, _ang];
        if (surfaceIsWater _p) then { continue; };
        private _blocked = count (_p nearObjects ["Building", _clearDist]) > 0 ||
            { count (_p nearObjects ["Wall_F", _clearDist]) > 0 } ||
            { count (_p nearObjects ["LandVehicle", _clearDist]) > 0 } ||
            { count (_p nearObjects ["BagBunker_Base_F", _clearDist]) > 0 };
        if (_blocked) then { continue; };
        private _flat = true;
        {
            private _n = surfaceNormal _x;
            if ((_n select 2) < 0.92) exitWith { _flat = false; };
        } forEach [_p, _p getPos [7, 0], _p getPos [7, 90], _p getPos [7, 180], _p getPos [7, 270]];
        if (_flat) then { _result = _p; break; };
    };
    _result
};

// Randomly spawn one of the editor-saved big bunkers (BigBunkerMG / TallBunkerMG)
// on level, clear ground, men on the MGs, facing the attacking marker
MISSION_CORE_fnc_spawnBigBunker = {
    params ["_targetPos", "_targetSize", "_faceDir", "_side", "_factionData"];
    private _compName = selectRandom ["BigBunkerMG", "TallBunkerMG"];
    private _compData = _compName call MISSION_CORE_fnc_loadComposition;
    if (count _compData == 0) exitWith { grpNull };
    // The comp's "front" must be where the weapon actually aims, not the base model's editor
    // default dir. In TallBunkerMG the HMG was authored 184deg from the tower's dir (136.1), so
    // rotating the tower's front to face the attacker left the embrasure + gun pointing away.
    private _compFacing = if (_compName == "TallBunkerMG") then { 320.5 } else { 135.3 };
    private _basePos = _targetPos getPos [((_targetSize select 0) * 0.6), _faceDir];
    private _spot = [_basePos, 5, 45, 14] call MISSION_CORE_fnc_findFlatSpot;
    if (_spot distance [0, 0, 0] < 1) exitWith { diag_log "BIG BUNKER: no flat clear spot found"; grpNull };
    private _dir = _faceDir - _compFacing;
    private _grp = createGroup _side;
    private _unitPool = [_factionData, _side] call MISSION_CORE_fnc_factionRiflemen;
    if (count _unitPool == 0) then { _unitPool = if (_side == WEST) then { ["B_Soldier_F"] } else { ["O_Soldier_F"] }; };
    private _isBLU = if (_side == WEST) then { "BLUFOR" } else { "REDFOR" };
    // The composition layout is ground truth - the editor author decided where each static weapon
    // sits (bag-bunker embrasure, tall tower, or cargo-building rooftop deck). Elevation is honored
    // whenever the comp carries a height; no host-type whitelist (a cargo bunker's roof gun needs
    // its height as much as a sandbag bunker's slit gun does).
    {
        private _class = _x select 0;
        private _rel = _x select 1;
        private _relDir = _x select 2;
        if (_side == EAST && { _class select [0, 2] == "B_" }) then { _class = "O_" + (_class select [2, 99]); };
        if (_side == WEST && { _class select [0, 2] == "O_" }) then { _class = "B_" + (_class select [2, 99]); };
        private _relX = _rel select 0;
        private _relZ = _rel select 1;
        private _relH = if (count _rel > 2) then { _rel select 2 } else { 0 };
        private _ang = ((_relZ atan2 _relX) + _dir);
        private _d = sqrt ((_relX * _relX) + (_relZ * _relZ));
        private _pos = _spot getPos [_d, _ang];
        private _obj = _class createVehicle _pos;
        _obj setDir (_relDir + _dir);
        if (_obj isKindOf "StaticWeapon") then {
            // Seat the gun at its editor-defined embrasure/deck height above the host base so it
            // covers through firing slits, open parapets or rooftop decks instead of being snapped
            // to the ground. Guns without a comp height still rest on the ground.
            _pos set [2, if (_relH > 0) then { _relH } else { 0.15 }];
            _obj setPosATL _pos;
            _obj setVectorUp [0, 0, 1];
            _obj setDir _faceDir;
            // Static gun on a solid embrasure - direct placement only. attachTo is NOT used: its
            // offset is applied to the object CENTER in the parent's model space, which displaces
            // the gun off its seat (hovering just above the surface).
            _grp addVehicle _obj;
            private _gunner = _grp createUnit [selectRandom _unitPool, _pos, [], 0, "NONE"];
            _gunner moveInGunner _obj;
        } else {
            _pos set [2, 0];
            _obj setPos _pos;
        };
    } forEach _compData;
    _grp setBehaviour "SAFE";
    _grp setCombatMode "RED";
    _grp setVariable [format ["MISSION_CORE_%1", _isBLU], true];
    _grp setVariable ["MISSION_CORE_DEFENSE_GROUP", true];
    _grp setVariable ["MISSION_CORE_ORDER", "defend"];
    _grp setVariable ["MISSION_CORE_IDLE", false];
    _grp setVariable ["MISSION_CORE_MARKER_CENTER", _targetPos];
    _grp setVariable ["MISSION_CORE_SPAWN_POS", _spot];
    if (isNil "MISSION_CORE_SPAWNED_GROUPS") then { MISSION_CORE_SPAWNED_GROUPS = []; };
    MISSION_CORE_SPAWNED_GROUPS pushBack _grp;
    [_grp] spawn MISSION_CORE_fnc_monitorCrew;
    diag_log format ["BIG BUNKER: %1 spawned at %2 facing %3", _compName, _spot, _faceDir];
    _grp
};
