
MISSION_CORE_fnc_queuedReinforce = {
    params ["_side", "_template", "_spawnPos", "_faction", "_importance", "_locPos", "_mSize", "_providerName"];
    if !([_side, "inf", _locPos] call MISSION_CORE_fnc_townCategoryCanUse) exitWith { false };
    if (([_side] call MISSION_CORE_fnc_countFootSquads) >= (["footSquadCapSquads", 10] call MISSION_CORE_fnc_tune)) exitWith { false };
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
    diag_log format ["DYNAMIC QUEUE: released queued reinforce %1 from %2", _template select 0, _providerName];
    true
};
