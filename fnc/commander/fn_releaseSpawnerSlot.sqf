// Release a marker's spawn slot early (marker captured / no longer contested / exhausted).
// Slot keys are [_side, markerName] - see fn_spawnerSlotFree for the rationale.
MISSION_CORE_fnc_releaseSpawnerSlot = {
    params ["_markerName", "_side"];
    if (isNil "MISSION_CORE_ACTIVE_SPAWNERS") exitWith {};
    if (MISSION_CORE_ACTIVE_SPAWNERS deleteAt [_side, _markerName] != nil) then {
        // `select` is not valid on a HashMap - it must be read through keys + postfix forEach.
        private _held = 0;
        private _heldKeys = keys MISSION_CORE_ACTIVE_SPAWNERS;
        {
            private _k = _x;
            if (_k isEqualType []) then {
                if ((_k select 0) == _side) then { _held = _held + 1; };
            };
        } forEach _heldKeys;
        diag_log format ["DYNAMIC SPAWNER TRACK: %1 %2 released its spawn slot (%3 active on side)",
            _markerName, _side, _held];
    };
};