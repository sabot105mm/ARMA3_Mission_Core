
MISSION_CORE_fnc_spawnDefenses = {
    params ["_targetPos", "_targetSize", "_side", "_factionData", "_importance", ["_axisPos", []]];
    private _axisDir = if (count _axisPos > 0) then { _axisPos getDir _targetPos } else { [_targetPos, _side] call MISSION_CORE_fnc_findDefenseAxis };
    private _sa = _targetSize select 0;
    private _sb = if (count _targetSize > 1) then { _targetSize select 1 } else { _sa };
    private _dir = if (count _targetSize > 2) then { _targetSize select 2 } else { 0 };
    private _defGroup = createGroup _side;
    private _unitPool = [_factionData, _side] call MISSION_CORE_fnc_factionRiflemen;
    if (count _unitPool == 0) then { _unitPool = ["B_Soldier_F"]; };
    private _crewClass = _unitPool;

    private _bunkerComps = ["BunkerGM", "BunkerMG_1", "RoundSBMissle"];
    private _stepAngles = [90, 85, 75, 65, 55];
    private _stepAngle = _stepAngles select ((_importance - 1) min 4);
    private _bunkerCount = floor (360 / _stepAngle);
    private _placedAny = false;
    private _placedPos = [];
    private _minSpacing = 25;

    // One big editor-saved bunker on the axis facing the attacking marker
    private _bigFaceDir = (_axisDir + 180) mod 360;
    private _bigGrp = [_targetPos, _targetSize, _bigFaceDir, _side, _factionData] call MISSION_CORE_fnc_spawnBigBunker;
    if (!isNull _bigGrp) then {
        _placedAny = true;
        _placedPos pushBack (_bigGrp getVariable ["MISSION_CORE_SPAWN_POS", _targetPos]);
    };

    // Arm any cargo towers inside the marker with rooftop static MGs
    private _towerMGs = [_targetPos, _targetSize, _side, _factionData] call MISSION_CORE_fnc_placeTowerMGs;
    if (_towerMGs > 0) then { _placedAny = true; };

    for "_i" from 0 to (_bunkerCount - 1) do {
        private _angle = _i * _stepAngle + random 5;
        private _maxR = ([_sa, _sb, _angle, _dir] call MISSION_CORE_fnc_ellipseRadius) * 0.85;
        private _pos = _targetPos getPos [_maxR, _angle];
        private _nearFriendly = false;
        if (_side == EAST) then {
            {
                if ((_x select 4) == WEST && { _pos distance (_x select 1) < ((_x select 8 select 0) max (_x select 8 select 1)) }) exitWith { _nearFriendly = true; };
            } forEach MISSION_CORE_CACHED_POSITIONS;
        };
        if (!_nearFriendly && { _placedPos findIf { _pos distance _x < _minSpacing } == -1 } && { [_pos, _angle, 200] call MISSION_CORE_fnc_hasClearLOS }) then {
            private _compName = if (random 1 < 0.9) then { selectRandom ["BunkerGM", "BunkerMG_1"] } else { "RoundSBMissle" };
            private _compObjs = [_compName, _pos, _angle, _side] call MISSION_CORE_fnc_placeComposition;
            private _wep = objNull;
            {
                if (_x isKindOf "StaticWeapon") then { _wep = _x; };
            } forEach _compObjs;
            if (!isNull _wep) then {
                _defGroup addVehicle _wep;
                private _gunner = _defGroup createUnit [selectRandom _crewClass, getPos _wep, [], 0, "NONE"];
                _gunner moveInGunner _wep;
                [_wep, _angle] call MISSION_CORE_fnc_faceWeapon;
                _placedAny = true;
                _placedPos pushBack _pos;
            } else { _placedAny = true; _placedPos pushBack _pos; };
        };
    };

    private _atCount = if (_importance >= 2) then { _importance - 1 } else { 0 };
    if (_atCount > 0) then {
        private _atStep = 360 / _atCount;
        private _atStart = random 360;
        for "_i" from 0 to (_atCount - 1) do {
            private _angle = _atStart + _i * _atStep;
            private _maxR = ([_sa, _sb, _angle, _dir] call MISSION_CORE_fnc_ellipseRadius) * 0.63;
            private _pos = _targetPos getPos [_maxR, _angle];
            private _nearFriendly = false;
            if (_side == EAST) then {
                {
                    if ((_x select 4) == WEST && { _pos distance (_x select 1) < ((_x select 8 select 0) max (_x select 8 select 1)) }) exitWith { _nearFriendly = true; };
                } forEach MISSION_CORE_CACHED_POSITIONS;
            };
            if (!_nearFriendly && { _placedPos findIf { _pos distance _x < _minSpacing } == -1 } && { [_pos, _angle, 300] call MISSION_CORE_fnc_hasClearLOS }) then {
                private _compObjs = ["RoundSBMissle", _pos, _angle, _side] call MISSION_CORE_fnc_placeComposition;
                // AT emplacement = an AT-missile soldier. He spawns at the marker center, RUNS out to
                // his sandbag, then kneels and holds that spot (no walking off).
                private _atClass = selectRandom (_factionData select 5 getOrDefault ["at", []]);
                if (isNil "_atClass" || { _atClass == "" }) then { _atClass = if (_side == WEST) then { "B_soldier_AT_F" } else { "O_soldier_AT_F" }; };
                private _spawnAt = _targetPos getPos [10 + random 20, random 360];
                private _atSoldier = _defGroup createUnit [_atClass, _spawnAt, [], 0, "NONE"];
                if (!isNull _atSoldier) then {
                    _atSoldier doMove _pos;
                    _placedAny = true;
                    _placedPos pushBack _pos;
                    // Watch until he reaches the sandbag, then pin him in place kneeling
                    [_atSoldier, _pos, _angle] spawn {
                        params ["_s", "_pos", "_angle"];
                        private _t = time + 120;
                        waitUntil { sleep 1; (!alive _s) || { _s distance2D _pos < 4 } || { time > _t } };
                        if (!alive _s) exitWith {};
                        doStop _s;
                        // Snap him into the emplacement spot, just behind the sandbag facing the approach
                        private _slot = _pos getPos [1.2, (_angle + 180)];
                        _slot = [_slot] call MISSION_CORE_fnc_ensureLandPos;
                        _s setPosATL _slot;
                        _s setDir _angle;
                        _s setUnitPos "MIDDLE";
                        _s disableAI "PATH";
                        _s disableAI "AUTOCOMBAT";
                        _s doWatch (_pos getPos [300, _angle]);
                        _s setVariable ["MISSION_CORE_STATIC_GUARD", true];
                    };
                } else { _placedAny = true; _placedPos pushBack _pos; };
            };
        };
    };

    // No armor is spawned to DEFEND a contested marker beyond the initial spawn - tanks/APCs are
    // reserved for the initial garrison and for neighbor counter-attacks (scaled by tier). A soft
    // transport is still placed for low-importance markers.
    private _vehMap = _factionData select 7;
    private _trClasses = _vehMap getOrDefault ["transport", []];
    if (_importance >= 2 && count _trClasses > 0) then {
        private _vPos = [_targetPos, _targetSize, 20, _dir] call MISSION_CORE_fnc_findVehiclePos;
        [_side, selectRandom _trClasses, "transport", _vPos, 0, _importance, _targetPos] call MISSION_CORE_fnc_spawnDefenseVehicle;
    };

    if (_placedAny) then {
        _defGroup setBehaviour "SAFE";
        _defGroup setCombatMode "RED";
        private _isBLU = if (_side == WEST) then { "BLUFOR" } else { "REDFOR" };
        _defGroup setVariable [format ["MISSION_CORE_%1", _isBLU], true];
        _defGroup setVariable ["MISSION_CORE_DEFENSE_GROUP", true];
        _defGroup setVariable ["MISSION_CORE_MARKER_CENTER", _targetPos];
        diag_log format ["DYNAMIC DEFENSE: %1 %2 bunkers (step=%3) + %4 AT at %5m imp=%6", _isBLU, _bunkerCount, _stepAngle, _atCount, floor ((_sa min _sb) * 0.6), _importance];
        [_defGroup] spawn MISSION_CORE_fnc_monitorCrew;
    };
    diag_log format ["SPAWN DEBUG: defense group=%1 side=%2", groupId _defGroup, _side];
    _defGroup
};
