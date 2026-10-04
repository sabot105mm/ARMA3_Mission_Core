
MISSION_CORE_fnc_queuedReinforce = {
    params ["_side", "_template", "_spawnPos", "_faction", "_importance", "_locPos", "_mSize", "_providerName"];
    if !([_side, "inf", _locPos] call MISSION_CORE_fnc_townCategoryCanUse) exitWith { false };
    if (([_side] call MISSION_CORE_fnc_countFootSquads) >= (["footSquadCapSquads", 10] call MISSION_CORE_fnc_tune)) exitWith { false };
    // PROVIDER NOT EXHAUSTED (PERMANENT RULE). This job is allowed to reach a marker the players
    // just captured - it is part of the retake - but only while the PROVIDER can still pay for it.
    // Re-checked here rather than at enqueue, because a queue outlives the provider's manpower: a
    // marker can be drained, or lost to the players, while this job waits its turn. Both conditions
    // are terminal - a provider that is gone or spent will not recover inside this queue pass, and
    // leaving the job queued would just spin it until the 60-attempt limit for nothing.
    private _provNow = (MISSION_CORE_CACHED_POSITIONS select { (_x select 0) == _providerName });
    if (count _provNow > 0 && { (_provNow select 0) select 4 != _side }) exitWith {
        diag_log format ["DYNAMIC QUEUE: dropped queued reinforce %1 - provider %2 is now player-held", _template select 0, _providerName];
        true
    };
    // MANPOWER RESERVE: never ship men that would leave the provider's home below its own retreat
    // threshold. Uses the shared helper, which reads the PROVIDER's own cached row for capacity and
    // hold fraction - _importance here is the TARGET marker's (fn_requestReinforcement passes the
    // requesting marker's value), so using it would have costed the provider off the wrong marker.
    private _afford = [_providerName, (_template select 2)] call MISSION_CORE_fnc_providerCanAfford;
    if !(_afford select 0) exitWith {
        diag_log format ["DYNAMIC QUEUE: dropped queued reinforce %1 from %2 - provider exhausted (stock=%3 committed=%4 squad=%5 retreatAt=%6)", _template select 0, _providerName, _afford select 1, _afford select 2, _template select 2, _afford select 3];
        true
    };
    private _grp = [_template select 0, _spawnPos, _side, _faction, "AWARE", "LIMITED", _importance, _locPos, _mSize] call MISSION_CORE_fnc_spawnGroup;
    if (isNull _grp) exitWith { false };
    _grp setVariable ["MISSION_CORE_ORIGIN_MARKER", _providerName];
    _grp setVariable ["MISSION_CORE_MARKER_CENTER", _locPos];
    [_grp] call MISSION_CORE_fnc_clearGroupWaypoints;
    private _wp = _grp addWaypoint [_locPos, 100];
    _wp setWaypointType "SAD";
    _wp setWaypointSpeed "NORMAL";
    _wp setWaypointBehaviour "COMBAT";
    _grp setCurrentWaypoint _wp;
    _grp setCombatMode "RED";
    if (isNil "MISSION_CORE_SPAWNED_GROUPS") then { MISSION_CORE_SPAWNED_GROUPS = []; };
    MISSION_CORE_SPAWNED_GROUPS pushBack _grp;
    // The squad exists now, so it is paid for now - the reserve gate above tested against this.
    MISSION_CORE_COMMIT set [_providerName, (MISSION_CORE_COMMIT getOrDefault [_providerName, 0]) + (_template select 2)];
    diag_log format ["DYNAMIC QUEUE: released queued reinforce %1 from %2", _template select 0, _providerName];
    true
};
