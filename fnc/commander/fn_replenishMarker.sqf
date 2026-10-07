
// Spawn a batch of reinforcements at a covered spot (forest/building inside the marker, away from
// the nearest player) and march them to the marker center / contested area
MISSION_CORE_fnc_replenishMarker = {
    params ["_loc", "_side", "_importance", "_alive", "_capacity", ["_mpBudget", 1e9]];
    private _locName = _loc select 0;
    private _locPos = _loc select 1;
    private _markerSize = if (count _loc > 8) then { _loc select 8 } else { [200, 200] };
    private _sizeWeight = [_loc] call MISSION_CORE_fnc_markerSizeWeight;
    private _squadMax = [_loc] call MISSION_CORE_fnc_markerSizeWeightMaxMen;
    private _factionData = if (_side == WEST) then { MISSION_CORE_BLUFOR_DATA } else { MISSION_CORE_REDFOR_DATA };
    private _allGroups = _factionData select 17;
    // PERMANENT RULE (NON-COMBAT-EFFECTIVE MARKERS): a factory / powerplant / solar / depot still
    // refills its OWN garrison (the defensive branch below - it must be able to hold what it has),
    // but it never contributes that garrison to a neighbor's fight and never feeds a staged
    // counter-attack. This flag gates ONLY those two offensive branches; it deliberately does NOT
    // exit early, because an early exit would also strip the marker's self-defense.
    private _blockOffense = [_loc] call MISSION_CORE_fnc_isNonCombatEffective;
    private _nearestP = objNull;
    private _nearestD = 999999;
    {
        private _d = _x distance _locPos;
        if (_d < _nearestD) then { _nearestD = _d; _nearestP = _x; };
    } forEach (allPlayers select { alive _x });
    private _farDir = if (!isNull _nearestP) then { (_nearestP getDir _locPos) + 180 } else { random 360 };
    // Spawn inside the marker at a forest/building spot when available (never popping into the
    // players' sight), otherwise just beyond the marker edge. Always on the side of the marker
    // that faces AWAY from the nearest player.
    // SMALL MARKER REPLENISH: a tiny marker has no tree cover inside its footprint - stretch the
    // spawn search well outside the marker so replenish squads materialize in real terrain cover
    // (tree clusters) and then march in, instead of popping inside the small open box.
    private _edgeRadius = ((_markerSize select 0) max (_markerSize select 1)) + 75;
    private _minEdge = ["replenishMinEdgeRadius", 350] call MISSION_CORE_fnc_tune;
    if (_edgeRadius < _minEdge) then { _edgeRadius = _minEdge; };
    private _missing = (_capacity - _alive) max 1;
    // Manpower is 1-for-1: a marker only fields the men its funding base actually delivered.
    // MARKER SIZE WEIGHT: small / low-importance markers refill in smaller batches - scale the
    // per-call spawn cap down with the size weight (min 2 so tiny markers still top up).
    private _batchCap = ((round (8 * (0.3 + 0.7 * _sizeWeight))) max 2) min 8;
    private _toSpawn = ((_missing min _batchCap) min _mpBudget) max 0;
    if (_toSpawn <= 0) exitWith { 0 };
    private _replCount = [_locName] call MISSION_CORE_fnc_countReplenishGroups;
    if (_replCount >= 5) exitWith {
        diag_log format ["DYNAMIC REPLENISH: %1 at dynamic replenish cap (%2/5 alive)", _locName, _replCount];
        0
    };
    private _pool = [_allGroups] call MISSION_CORE_fnc_getInfTemplates;
    if (count _pool == 0) exitWith { 0 };
    // MARKER SIZE WEIGHT: small markers refill with SHORT squads - prefer templates at/below
    // the squad cap, falling back to the full pool when nothing fits.
    private _poolCapped = _pool select { (_x select 2) <= _squadMax };
    if (count _poolCapped > 0) then { _pool = _poolCapped; };
    private _spawned = 0;
    // Global foot budget cap or town cap full: queue the replenish to spawn when men free up.
    // Pending abstract legs count toward the cap - they have already reserved their slot, so a
    // marker must not start a fresh squad on top of them.
    if (!([_side, "inf", _locPos] call MISSION_CORE_fnc_townCategoryCanUse) || { ((([_side] call MISSION_CORE_fnc_countFootSquads) + ([] call MISSION_CORE_fnc_countPendingAbstractLegs)) >= (["footSquadCapSquads", 10] call MISSION_CORE_fnc_tune)) }) then {
        ["MISSION_CORE_fnc_queuedReplenish", format ["repl_%1", _locName], [_side, _loc, _importance, _locPos, _locName, _farDir, _edgeRadius]] call MISSION_CORE_fnc_enqueueSpawn;
        diag_log format ["DYNAMIC REPLENISH: %1 queued (global foot %2/%3, abstract legs pending %4)", _locName, [_side] call MISSION_CORE_fnc_countFootSquads, ["footSquadCapSquads", 10] call MISSION_CORE_fnc_tune, [] call MISSION_CORE_fnc_countPendingAbstractLegs];
        0
    } else {
    // Replenished squads converge on the contested marker center (group pos -> contested marker
    // center). The contested marker is the one closest to a player; multiple players attacking
    // different markers means multiple contested markers.
    // SELF-EXCLUSION (no marker reinforces or counter-attacks itself): a marker may only support a
    // NEIGHBOR's fight. If this marker's own name is the contested one nearest a player, it must not
    // be picked - its garrison is already there, defending it. fn_getMarkerNeighbors enforces the
    // same rule twice (not _locName, and not any contested zone) but this path bypasses that helper
    // entirely, so it has to exclude itself here. With the origin marker removed, an empty
    // candidate list correctly falls through to the SAD-to-own-center branch below.
    private _spawnPositions = [_locPos, _markerSize, _farDir, _edgeRadius, _side] call MISSION_CORE_fnc_findCoveredSpawns;
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
            } forEach (_contestedList select { (_x select 0) != _locName });
        };
    };
    // Non-combat-effective marker: clear the offensive destination so the branch below falls
    // through to the own-center SAD instead of marching the garrison to a neighbor. Clearing the
    // target rather than duplicating the branch keeps ONE copy of the defensive path.
    if (_blockOffense && { count _cTarget > 0 }) then {
        diag_log format ["NON-COMBAT-EFFECTIVE RULE: %1 replenishes its own garrison only - not sending it to contested %2", _locName, _cTarget select 0];
        _cTarget = [];
    };
    while { _toSpawn > 0 } do {
        // Re-checked every iteration, not hoisted: the pending-leg count is GLOBAL, so it moves as
        // OTHER paths create and materialise abstract legs mid-loop, not just this one's.
        if ((([_side] call MISSION_CORE_fnc_countFootSquads) + ([] call MISSION_CORE_fnc_countPendingAbstractLegs)) >= (["footSquadCapSquads", 10] call MISSION_CORE_fnc_tune)) exitWith {};
        if ([_locName] call MISSION_CORE_fnc_countReplenishGroups >= (["replenishCapPerMarker", 5] call MISSION_CORE_fnc_tune)) exitWith {};
        private _template = selectRandom _pool;
        private _unitCount = _template select 2;
        // NO ABSTRACT LEG HERE. Replenishment is a garrison re-fielding its OWN men - the squad
        // spawns on this marker's own edge and either walks tens of metres to its own centre
        // or marches to a contested neighbour. It is not a neighbouring force making a long
        // haul to someone else's fight, and it was never abstracted. Every journey out of
        // this function is concrete, handled by the direct path below.
        private _total = MISSION_CORE_REPLENISH_SPAWN_INDEX getOrDefault [_locName, 0];
        MISSION_CORE_REPLENISH_SPAWN_INDEX set [_locName, _total + 1];
        private _spawnIdx = floor (_total / 5) mod (count _spawnPositions);
        private _spawnPos = (_spawnPositions select _spawnIdx) getPos [random 25, random 360];
        private _grp = [_template select 0, _spawnPos, _side, _factionData select 3, "AWARE", "NORMAL", _importance, _locPos, _markerSize] call MISSION_CORE_fnc_spawnGroup;
        if (isNull _grp) exitWith {};
        _grp setVariable ["MISSION_CORE_ORIGIN_MARKER", _locName];
        _grp setVariable ["MISSION_CORE_REPLENISH_GROUP", true];
        // GARRISON TAG: replenish squads are the marker's OWN garrison re-fielded - deaths count
        // against its retreat tally (dispatched squads never carry this tag).
        _grp setVariable ["MISSION_CORE_CASUALTY_MARKER", _locName];
        if (isNil "MISSION_CORE_SPAWNED_GROUPS") then { MISSION_CORE_SPAWNED_GROUPS = []; };
        MISSION_CORE_SPAWNED_GROUPS pushBack _grp;
        _spawned = _spawned + _unitCount;
        _toSpawn = _toSpawn - _unitCount;
        // SUPPLY-REUSE HOOK: while a staged counter-attack is still filling at this marker (an
        // active MISSION_CORE_STAGING_BUDGET entry), its own supply squads BECOME the assault's
        // infantry - the arriving squad is rerouted to the staging edge and counted against the
        // assembly's manpower need instead of marching to the contested center. Such a squad keeps
        // its ORIGIN/GARRISON accounting; tryAbsorbSupply clears CASUALTY_MARKER so deaths during
        // the counter-attack never drain the marker's retreat tally (dispatched-squad rule).
        if ((!_blockOffense) && { ([_grp, _locName, _locPos, _markerSize, _side] call MISSION_CORE_fnc_tryAbsorbSupply) }) then {
            diag_log format ["DYNAMIC REPLENISH: %1 absorbed +%2 men (%3) into staged counter-attack", _locName, _unitCount, _template select 0];
        } else {
        if (count _cTarget > 0) then {
            // _cTarget is a getContestedMarkers row [_name,_pos,_size,_owner], so size is index 2.
            [_grp, _cTarget select 1, _cTarget select 2] call MISSION_CORE_fnc_sendCounterAttack;
            diag_log format ["DYNAMIC REPLENISH: %1 +%2 men (%3) -> contested %4 (%5m from group)", _locName, _unitCount, _template select 0, _cTarget select 0, round (_spawnPos distance (_cTarget select 1))];
        } else {
            [_grp] call MISSION_CORE_fnc_clearGroupWaypoints;
            private _wp = _grp addWaypoint [_locPos, 60];
            _wp setWaypointType "SAD";
            _wp setWaypointSpeed "NORMAL";
            _wp setWaypointBehaviour "COMBAT";
            _grp setCurrentWaypoint _wp;
            _grp setCombatMode "RED";
            diag_log format ["DYNAMIC REPLENISH: %1 +%2 men (%3) from %4m edge -> center", _locName, _unitCount, _template select 0, round _edgeRadius];
        };
        };
        // 0.4s breathing room between squad spawns so the garrison trickles in instead of
        // popping several squads at once and the global foot/cap re-checks stay accurate.
        sleep 0.4;
    };
    _spawned
    };
};
