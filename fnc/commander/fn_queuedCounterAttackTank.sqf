
MISSION_CORE_fnc_queuedCounterAttackTank = {
    params ["_side", "_template", "_spawnPos", "_faction", "_importance", "_provPos", "_provSize", "_provName", "_targetPos", "_targetSize"];
    // Drop a stale counter-attack whose target is no longer near any player
    if (allPlayers findIf { alive _x && { _x distance _targetPos < 2000 } } == -1) exitWith {
        diag_log format ["DYNAMIC QUEUE: dropped queued counter-attack tank %1 - target no longer near a player", _template select 0];
        true
    };
    if !([_side, "mbt", _provPos, _importance] call MISSION_CORE_fnc_armorCapOpen) exitWith { false };
    // The provider marker may have been captured while this spawn sat in the queue - never
    // spawn a counter-attack out of a marker the players now own.
    private _provNow = (MISSION_CORE_CACHED_POSITIONS select { (_x select 0) == _provName });
    if (count _provNow > 0 && { (_provNow select 0) select 4 != _side }) exitWith { false };
    // Tank pool: only a pool owner below its allowance lends a counter-attack tank. Re-checked
    // here so a queue that outlived the provider's pool does not push it past its allowance.
    if (count _provNow > 0) then {
        private _prvPool = [(_provNow select 0)] call MISSION_CORE_fnc_markerTankPool;
        if (_prvPool <= 0) exitWith { false };
        if (([(_provNow select 0)] call MISSION_CORE_fnc_countMBTByMarker) >= _prvPool) exitWith { false };
    };
    private _grp = [_template select 0, _spawnPos, _side, _faction, "AWARE", "FULL", _importance, _provPos, _provSize] call MISSION_CORE_fnc_spawnGroup;
    if (isNull _grp) exitWith { false };
    _grp setVariable ["MISSION_CORE_ORIGIN_MARKER", _provName];
    _grp setVariable ["MISSION_CORE_IMPORTANCE", _importance];
    if (isNil "MISSION_CORE_SPAWNED_GROUPS") then { MISSION_CORE_SPAWNED_GROUPS = []; };
    MISSION_CORE_SPAWNED_GROUPS pushBack _grp;
    [_grp, _targetPos, _targetSize, "YELLOW"] call MISSION_CORE_fnc_sendCounterAttack;
    MISSION_CORE_COMMIT set [_provName, (MISSION_CORE_COMMIT getOrDefault [_provName, 0]) + ceil ((_template select 2) * 0.1)];
    diag_log format ["DYNAMIC QUEUE: released queued counter-attack tank %1 from %2", _template select 0, _provName];
    true
};
