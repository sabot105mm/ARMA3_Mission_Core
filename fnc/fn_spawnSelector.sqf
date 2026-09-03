MISSION_CORE_fnc_initSpawnSelector = {
    waitUntil { !isNull player };
    waitUntil { MISSION_CORE_INITIALIZED };
    diag_log format ["DYNAMIC SPAWN: total locations=%1", count MISSION_CORE_LOCATIONS];
    {
        diag_log format ["DYNAMIC SPAWN:   loc: %1 owner=%2", _x select 0, _x select 5];
    } forEach MISSION_CORE_LOCATIONS;

    private _spawnLocs = MISSION_CORE_LOCATIONS select { _x select 5 == WEST };
    diag_log format ["DYNAMIC SPAWN: BLUFOR locations=%1", count _spawnLocs];
    if (count _spawnLocs == 0) then {
        diag_log "DYNAMIC SPAWN: No BLUFOR locations - using fallback";
        _spawnLocs = [["hq_fallback", [getPos player, [0,0], 0, "ELLIPSE"], "HQ", "hq_", 1, WEST, []]];
    };

    MISSION_CORE_BLUFOR_SPAWNS = _spawnLocs apply { [_x select 0, _x select 1, _x select 2] };

    // Populate dialog list
    createDialog "DYNOPS_SpawnSelector";
    private _display = findDisplay 1500;
    private _list = _display displayCtrl 1502;
    {
        _list lbAdd format ["%1 (%2)", _x select 2, _x select 0];
    } forEach _spawnLocs;
    _list lbSetCurSel 0;
};

MISSION_CORE_fnc_onSpawnSelect = {
    private _display = findDisplay 1500;
    if (isNull _display) exitWith {};
    private _list = _display displayCtrl 1502;
    private _index = lbCurSel _list;
    if (_index >= 0 && {count MISSION_CORE_BLUFOR_SPAWNS > _index}) then {
        private _spawn = MISSION_CORE_BLUFOR_SPAWNS select _index;
        private _pos = (_spawn select 1) select 0;
        player setPos _pos;
        closeDialog 0;
    };
};
