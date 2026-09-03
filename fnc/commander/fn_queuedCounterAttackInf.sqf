
// Queued spawn jobs (called by the queue loop, return true when the spawn actually happened)

MISSION_CORE_fnc_queuedCounterAttackInf = {
    params ["_side", "_template", "_spawnPos", "_faction", "_importance", "_provPos", "_provSize", "_provName", "_targetPos", "_targetSize"];
    // The player may have left the target area while this sat in the queue - a counter-attack to
    // a marker nobody is near just becomes a truck convoy to nowhere. Drop it.
    if (allPlayers findIf { alive _x && { _x distance _targetPos < 2000 } } == -1) exitWith {
        diag_log format ["DYNAMIC QUEUE: dropped queued counter-attack inf %1 - target no longer near a player", _template select 0];
        true
    };
    if !([_side, "inf", _provPos] call MISSION_CORE_fnc_townCategoryCanUse) exitWith { false };
    // Global foot-squad cap is hard at 10 enemy groups (PERMANENT RULE) - never bypass it,
    // even for an active battle. A queued squad waits for a slot to free up.
    if (([_side] call MISSION_CORE_fnc_countFootSquads) >= (["footSquadCapSquads", 10] call MISSION_CORE_fnc_tune)) exitWith { false };
    // The provider marker may have been captured while this spawn sat in the queue - never
    // spawn a counter-attack out of a marker the players now own.
    private _provNow = (MISSION_CORE_CACHED_POSITIONS select { (_x select 0) == _provName });
    if (count _provNow > 0 && { (_provNow select 0) select 4 != _side }) exitWith { false };
    private _grp = [_template select 0, _spawnPos, _side, _faction, "AWARE", "NORMAL", _importance, _provPos, _provSize] call MISSION_CORE_fnc_spawnGroup;
    if (isNull _grp) exitWith { false };
    _grp setVariable ["MISSION_CORE_ORIGIN_MARKER", _provName];
    _grp setVariable ["MISSION_CORE_IMPORTANCE", _importance];
    if (isNil "MISSION_CORE_SPAWNED_GROUPS") then { MISSION_CORE_SPAWNED_GROUPS = []; };
    MISSION_CORE_SPAWNED_GROUPS pushBack _grp;
    [_grp, _targetPos, _targetSize] call MISSION_CORE_fnc_sendCounterAttack;
    MISSION_CORE_COMMIT set [_provName, (MISSION_CORE_COMMIT getOrDefault [_provName, 0]) + ceil ((_template select 2) * 0.1)];
    diag_log format ["DYNAMIC QUEUE: released queued counter-attack inf %1 from %2", _template select 0, _provName];
    true
};
