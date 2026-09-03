
MISSION_CORE_fnc_deserializeGroup = {
    params ["_data", "_center", "_side", "_faction", "_importance", "_markerCenter", "_markerSize"];
    _data params ["_unitsData", "_wpData", "_currentWpIdx", "_behaviour", "_combatMode", "_speed", "_patrolling", "_idle", "_groupType", ["_armorSlot", ""], ["_aaDefense", false], ["_subCat", ""]];

    private _grp = createGroup _side;
    private _first = true;
    {
        _x params ["_class", "_relPos", "_unitDamage"];
        private _pos = [_center getPos _relPos] call MISSION_CORE_fnc_ensureLandPos;
        if (_first) then {
            _grp createUnit [_class, _pos, [], 0, "FORM"];
            _first = false;
        } else {
            _grp createUnit [_class, _pos, [], 0, "FORM"];
        };
    } forEach _unitsData;
    {
        _x setDamage (_unitsData select _forEachIndex select 2);
    } forEach units _grp;

    // Restore waypoints
    [_grp] call MISSION_CORE_fnc_clearGroupWaypoints;
    {
        _x params ["_wpPos", "_wpType", "_wpSpeed", "_wpBehav"];
        _wpBehav = if (_wpBehav in ["CARELESS", "SAFE", "AWARE", "COMBAT", "STEALTH"]) then { _wpBehav } else { "AWARE" };
        private _wp = _grp addWaypoint [_wpPos, 30];
        _wp setWaypointType _wpType;
        _wp setWaypointSpeed _wpSpeed;
        _wp setWaypointBehaviour _wpBehav;
    } forEach _wpData;
    private _restoredWps = waypoints _grp;
    private _currentIsCycle = (_currentWpIdx >= 0) && { _currentWpIdx < count _wpData } && { ((_wpData select _currentWpIdx) select 1) == "CYCLE" };
    private _useIdx = -1;
    if (!_currentIsCycle && { _currentWpIdx >= 0 && { _currentWpIdx < count _restoredWps } }) then {
        _useIdx = _currentWpIdx;
    } else {
        { if (((_x select 1)) != "CYCLE") exitWith { _useIdx = _forEachIndex; }; } forEach _wpData;
    };
    if (_useIdx >= 0 && _useIdx < count _restoredWps) then {
        _grp setCurrentWaypoint (_restoredWps select _useIdx);
    };

    _behaviour = if (_behaviour in ["CARELESS", "SAFE", "AWARE", "COMBAT", "STEALTH"]) then { _behaviour } else { "AWARE" };
    _grp setBehaviour _behaviour;
    _grp setCombatMode _combatMode;
    _grp setSpeedMode _speed;

    _grp setVariable ["MISSION_CORE_REDFOR", true];
    _grp setVariable ["MISSION_CORE_IDLE", _idle];
    _grp setVariable ["MISSION_CORE_IMPORTANCE", _importance];
    _grp setVariable ["MISSION_CORE_MARKER_CENTER", _markerCenter];
    _grp setVariable ["MISSION_CORE_MARKER_SIZE", _markerSize];
    _grp setVariable ["MISSION_CORE_SPAWN_POS", _center];
    _grp setVariable ["MISSION_CORE_GROUP_TYPE", _groupType];
    if (_subCat != "") then { _grp setVariable ["MISSION_CORE_SUBCAT", _subCat]; };
    if (_armorSlot != "") then { _grp setVariable ["MISSION_CORE_ARMOR_SLOT", _armorSlot]; };
    if (_aaDefense) then { _grp setVariable ["MISSION_CORE_AA_DEFENSE", true]; };

    if (_patrolling) then {
        leader _grp setVariable ["MISSION_CORE_PATROLLING", true];
    };

    _grp
};
