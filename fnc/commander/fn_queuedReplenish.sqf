
MISSION_CORE_fnc_queuedReplenish = {
    params ["_side", "_loc", "_importance", "_locPos", "_locName", "_farDir", "_edgeRadius"];
    if !([_side, "inf", _locPos] call MISSION_CORE_fnc_townCategoryCanUse) exitWith { false };
    // PENDING ABSTRACT LEGS COUNT IN THE CAP - otherwise a queue whose every job abstracts
    // sees a permanently empty fielded army and never stops.
    if ((([_side] call MISSION_CORE_fnc_countFootSquads) + ([] call MISSION_CORE_fnc_countPendingAbstractLegs)) >= (["footSquadCapSquads", 10] call MISSION_CORE_fnc_tune)) exitWith { false };
    if ([_locName] call MISSION_CORE_fnc_countReplenishGroups >= (["replenishCapPerMarker", 5] call MISSION_CORE_fnc_tune)) exitWith { false };
    // The marker may have been captured while this spawn sat in the queue - never replenish
    // troops into a marker the players now own.
    private _locNow = (MISSION_CORE_CACHED_POSITIONS select { (_x select 0) == _locName });
    if (count _locNow > 0 && { (_locNow select 0) select 4 != _side }) exitWith { false };
    private _factionData = if (_side == WEST) then { MISSION_CORE_BLUFOR_DATA } else { MISSION_CORE_REDFOR_DATA };
    private _pool = [(_factionData select 17)] call MISSION_CORE_fnc_getInfTemplates;
    if (count _pool == 0) exitWith { false };
    private _squadMax = [_loc] call MISSION_CORE_fnc_markerSizeWeightMaxMen;
    private _poolCapped = _pool select { (_x select 2) <= _squadMax };
    if (count _poolCapped > 0) then { _pool = _poolCapped; };
    private _template = selectRandom _pool;
    private _markerSize = if (count _loc > 8) then { _loc select 8 } else { [200, 200] };
    private _spawnPositions = [_locPos, _markerSize, _farDir, _edgeRadius, _side] call MISSION_CORE_fnc_findCoveredSpawns;
    // WHERE IS THIS SQUAD GOING? Resolved BEFORE the spawn, where fn_replenishMarker resolves it
    // after. It has to move: the abstract leg must know its destination at dispatch, and a leg
    // dispatched without one is just a squad that will never be created.
    //
    // Deferred squads also converge on the contested marker center (group pos -> contested marker
    // center), matching the immediate spawn path. The contested marker is the one closest to a
    // player; multiple players attacking different markers means multiple contested markers.
    private _contestedList = [_side] call MISSION_CORE_fnc_getContestedMarkers;
    private _cTarget = [];
    if (count _contestedList > 0) then {
        private _playersA = allPlayers select { alive _x };
        if (count _playersA > 0) then {
            private _bestPD = 1e10;
            {
                private _mPos = _x select 1;
                private _pd = 1e10;
                { private _d = _x distance _mPos; if (_d < _pd) then { _pd = _d; }; } forEach _playersA;
                if (_pd < _bestPD) then { _bestPD = _pd; _cTarget = _x; };
            // SELF-EXCLUSION: same rule as fn_replenishMarker - a marker only supports a NEIGHBOR's
            // fight, never its own. Empty candidate list falls through to SAD-to-own-center.
            } forEach (_contestedList select { (_x select 0) != _locName });
        };
    };
    // NON-COMBAT-EFFECTIVE MARKERS NEVER LAUNCH OFFENSIVE SUPPORT (Part A rule). fn_replenishMarker
    // enforces this on its immediate path, but the queue is a SEPARATE function and was not
    // re-checking it: a factory/depot/solar that ran dry and queued a replenish would resolve a
    // contested target here and march its garrison at the fight, which is exactly the support
    // launch Part A forbids. `_loc` is already a param, so the same helper decides it - no new
    // argument and no change to fn_replenishMarker's enqueue call.
    private _blockOffense = [_loc] call MISSION_CORE_fnc_isNonCombatEffective;
    if (_blockOffense && { count _cTarget > 0 }) then {
        diag_log format ["NON-COMBAT-EFFECTIVE RULE: queued replenish %1 replenishes its own garrison only - not sending it to contested %2", _locName, _cTarget select 0];
        _cTarget = [];
    };
// NO ABSTRACT LEG HERE, matching fn_replenishMarker. A queued replenish job is a garrison
    // re-fielding its own men: the squad spawns on this marker's edge and either walks to its
    // own centre or marches to a contested neighbour. Replenishment is not a neighbouring force
    // making a long haul to someone else's fight, so every journey out of this file is concrete.
    private _total = MISSION_CORE_REPLENISH_SPAWN_INDEX getOrDefault [_locName, 0];
    MISSION_CORE_REPLENISH_SPAWN_INDEX set [_locName, _total + 1];
    private _spawnIdx = floor (_total / 5) mod (count _spawnPositions);
    private _spawnPos = (_spawnPositions select _spawnIdx) getPos [random 25, random 360];
    private _grp = [_template select 0, _spawnPos, _side, _factionData select 3, "AWARE", "NORMAL", _importance, _locPos, _markerSize] call MISSION_CORE_fnc_spawnGroup;
    if (isNull _grp) exitWith { false };
    _grp setVariable ["MISSION_CORE_ORIGIN_MARKER", _locName];
    _grp setVariable ["MISSION_CORE_REPLENISH_GROUP", true];
    // GARRISON TAG: queued replenish squads are the marker's OWN garrison re-fielded - deaths
    // count against its retreat tally (dispatched squads never carry this tag).
    _grp setVariable ["MISSION_CORE_CASUALTY_MARKER", _locName];
    if (isNil "MISSION_CORE_SPAWNED_GROUPS") then { MISSION_CORE_SPAWNED_GROUPS = []; };
    MISSION_CORE_SPAWNED_GROUPS pushBack _grp;
// SUPPLY-REUSE HOOK (tried unconditionally, mirroring fn_replenishMarker): while a staged
    // counter-attack is still filling at this marker, its own supply squads BECOME the assault's
    // infantry - the arriving squad is rerouted to the staging edge and counted against the
    // assembly's manpower need instead of marching into the marker. If no assembly is open, route
    // to the contested center as usual (or SAD the marker center when nothing is contested).
    // Staging absorption is itself offensive support - it feeds an assembly that will attack -
    // so a non-combat-effective marker is excluded here too, mirroring fn_replenishMarker.
    if ((!_blockOffense) && { ([_grp, _locName, _locPos, _markerSize, _side] call MISSION_CORE_fnc_tryAbsorbSupply) }) then {
        diag_log format ["DYNAMIC QUEUE: absorbed +%2 men (%1) into staged counter-attack", _locName, _template select 2];
    } else {
        if (count _cTarget > 0) then {
            // _cTarget is a getContestedMarkers row [_name,_pos,_size,_owner], so size is index 2.
            [_grp, _cTarget select 1, _cTarget select 2] call MISSION_CORE_fnc_sendCounterAttack;
            diag_log format ["DYNAMIC QUEUE: released queued replenish %1 +%2 men -> contested %3", _locName, _template select 2, _cTarget select 0];
        } else {
            [_grp] call MISSION_CORE_fnc_clearGroupWaypoints;
            private _wp = _grp addWaypoint [_locPos, 60];
            _wp setWaypointType "SAD";
            _wp setWaypointSpeed "NORMAL";
            _wp setWaypointBehaviour "COMBAT";
            _grp setCurrentWaypoint _wp;
            _grp setCombatMode "RED";
            diag_log format ["DYNAMIC QUEUE: released queued replenish %1 +%2 men", _locName, _template select 2];
        };
    };
    true
};
