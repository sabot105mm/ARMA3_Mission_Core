
// When the player moves away from a contested marker (it stops being the marker they are fighting),
// neighbor counter-attack squads that are still marching toward it are despawned immediately. They
// would otherwise keep driving into an empty marker until the marker itself despawns on distance
// (3000m) - long after the fight has moved on. This mirrors the "marching here" cleanup already in
// fn_despawnLocation, but keys off the CONTESTED state instead of the despawn radius.
//
// "Neighbor" means a counter-attack squad that originates from a DIFFERENT marker (its
// MISSION_CORE_ORIGIN_MARKER is not the marker it is marching toward). The target marker's OWN
// garrison is never touched here - the battle loop already returns it to patrol on its own.
//
// One tick of the group maintenance loop.
MISSION_CORE_fnc_rerouteRetreating = {
    params ["_markerName", "_locPos", "_side"];
    if (_markerName == "") exitWith {};
    if (isNil "MISSION_CORE_SPAWNED_GROUPS") exitWith {};
    private _sideVar = if (_side == WEST) then { "MISSION_CORE_BLUFOR" } else { "MISSION_CORE_REDFOR" };
    private _size = [50, 50];
    private _idx = MISSION_CORE_CACHED_POSITIONS findIf { (_x select 0) == _markerName };
    if (_idx >= 0) then {
        private _sz = (MISSION_CORE_CACHED_POSITIONS select _idx) select 8;
        if (count _sz > 0) then { _size = [_sz select 0, _sz select 1]; };
    };
    {
        if (!isNull _x && { count units _x > 0 } &&
            { _x getVariable [_sideVar, false] } &&
            { (_x getVariable ["MISSION_CORE_ORDER", ""]) == "retreat" } &&
            { (_x getVariable ["MISSION_CORE_RETREAT_FROM", ""]) != _markerName }) then {
            _x setVariable ["MISSION_CORE_ORDER", "counterattack"];
            [_x, _locPos, _size] call MISSION_CORE_fnc_sendCounterAttack;
            diag_log format ["AI COMMANDER: %1 re-routed from retreat to newly-contested %2", groupId _x, _markerName];
        };
    } forEach MISSION_CORE_SPAWNED_GROUPS;
};

MISSION_CORE_fnc_despawnUncontestedNeighborsTick = {
    if (isNil "MISSION_CORE_SPAWNED_GROUPS") exitWith {};
    if (isNil "MISSION_CORE_CACHED_POSITIONS") exitWith {};
    if (isNil "MISSION_CORE_CONTESTED_LAST") then { MISSION_CORE_CONTESTED_LAST = createHashMap; };
    {
        private _side = _x;
        private _sideVar = if (_side == WEST) then { "MISSION_CORE_BLUFOR" } else { "MISSION_CORE_REDFOR" };
        private _contested = [_side] call MISSION_CORE_fnc_getContestedMarkers;
        // Remember the last time each still-contested marker was contested, so a player briefly
        // stepping out of the ellipse (and back) does not instantly yank every marching squad.
        {
            MISSION_CORE_CONTESTED_LAST set [_x select 0, time];
        } forEach _contested;
        private _removed = [];
        {
            private _grp = _x;
            if (isNull _grp || { count units _grp == 0 }) then { continue; };
            if (!(_grp getVariable [_sideVar, false])) then { continue; };
            if ((_grp getVariable ["MISSION_CORE_ORDER", ""]) != "counterattack") then { continue; };
            // Squads committed to an AI assault are exempt: the assault has its own lifecycle and
            // its target is never player-contested, so this cleanup would yank them mid-march.
            if (_grp getVariable ["MISSION_CORE_ASSAULT_GROUP", false]) then { continue; };
            // Long-range shooter strikes are exempt: their attack target is the shooter's position,
            // not a contested marker, so "marker no longer contested" never applies to them.
            if (_grp getVariable ["MISSION_CORE_LONG_RANGE_STRIKE", false]) then { continue; };
            private _at = _grp getVariable ["MISSION_CORE_ATTACK_TARGET", []];
            if (count _at == 0) then { continue; };
            // Which marker is this squad marching toward? Resolve to the NEAREST cached center
            // within 500m (not the first) - overlapping markers (outpost_1 vs town_8) must never
            // mis-resolve a squad's target to the wrong town and yank it mid-march.
            private _tgtIdx = -1;
            private _tgtBest = 500;
            {
                private _d = (_x select 1) distance2D _at;
                if (_d < _tgtBest) then { _tgtBest = _d; _tgtIdx = _forEachIndex; };
            } forEach MISSION_CORE_CACHED_POSITIONS;
            if (_tgtIdx < 0) then { continue; };
            private _tgtName = (MISSION_CORE_CACHED_POSITIONS select _tgtIdx) select 0;
            // Only a squad from a DIFFERENT marker is a "neighbor" - leave the target's own
            // garrison (committed to its own defense) alone.
            private _origin = _grp getVariable ["MISSION_CORE_ORIGIN_MARKER", ""];
            if (_origin == _tgtName) then { continue; };
            // Still contested (or was moments ago): keep marching.
            private _lastContested = MISSION_CORE_CONTESTED_LAST getOrDefault [_tgtName, -1e10];
            if (time - _lastContested < (["contestedGraceSeconds", 45] call MISSION_CORE_fnc_tune)) then { continue; };
        // Retreat destination = the closest SAME-SIDE cached marker (the "next closest ally"),
        // not the squad's origin town - squads move away from where the fight was, toward the
        // closest friendly marker. PERMANENT RULE: never retreat to the marker they're in / the
        // target they were attacking.
        private _dest = [getPosATL (leader _grp), _side, [_origin, _tgtName]] call MISSION_CORE_fnc_getRetreatDest;
        if (_dest distance [0, 0, 0] < 1) then {
                diag_log format ["AI COMMANDER: despawning neighbor %1 (from %2) - target %3 no longer contested", groupId _grp, _origin, _tgtName];
                [_grp] call MISSION_CORE_fnc_deleteGroupCompletely;
                _removed pushBack _grp;
                continue;
        };
        diag_log format ["AI COMMANDER: neighbor %1 (from %2) retreating to closest %3 - target %4 no longer contested", groupId _grp, _origin, _dest, _tgtName];
            _grp setVariable ["MISSION_CORE_ORDER", "retreat"];
            _grp setVariable ["MISSION_CORE_RETREAT_FROM", _tgtName];
            _grp setVariable ["MISSION_CORE_RETREAT_DEST", _dest];
            _grp setVariable ["MISSION_CORE_RETREAT_DEADLINE", time + 300];
            _grp setCombatMode "GREEN";   // hold fire (return fire only) while withdrawing
            _grp setBehaviour "AWARE";    // stay in formation (CARELESS breaks ranks and lies down)
            _grp setFormation "WEDGE";    // stay in formation
            _grp setSpeedMode "FULL";     // run/drive
            { _x setUnitPos "UP"; } forEach units _grp; // stand up
            [_grp] call MISSION_CORE_fnc_clearGroupWaypoints;
            private _wp = _grp addWaypoint [_dest, 100];
            _wp setWaypointType "MOVE";
            _wp setWaypointSpeed "FULL";
            _wp setWaypointBehaviour "AWARE";
            _grp setCurrentWaypoint _wp;
        } forEach +MISSION_CORE_SPAWNED_GROUPS;
        // Despawn any retreating squad that reached its retreat marker or timed out. (Re-routing to
        // a newly-contested marker is event-driven - see isMarkerContested -> rerouteRetreating.)
        {
            private _grp = _x;
            if (isNull _grp || { count units _grp == 0 }) then { continue; };
            if (!(_grp getVariable [_sideVar, false])) then { continue; };
            if ((_grp getVariable ["MISSION_CORE_ORDER", ""]) != "retreat") then { continue; };
            private _dest = _grp getVariable ["MISSION_CORE_RETREAT_DEST", [0, 0, 0]];
            private _deadline = _grp getVariable ["MISSION_CORE_RETREAT_DEADLINE", time + 300];
            if ((leader _grp) distance2D _dest < 150 || { time > _deadline } || { { alive _x } count units _grp == 0 }) then {
                diag_log format ["AI COMMANDER: despawning neighbor %1 after retreat", groupId _grp];
                [_grp] call MISSION_CORE_fnc_deleteGroupCompletely;
                _removed pushBack _grp;
            };
        } forEach +MISSION_CORE_SPAWNED_GROUPS;
        if (count _removed > 0) then {
            MISSION_CORE_SPAWNED_GROUPS = MISSION_CORE_SPAWNED_GROUPS - _removed;
        };
        // PERMANENT RULE: when a player DIES or WALKS AWAY, the marker stops being contested
        // (isMarkerContested deletes the flag) - and its whole supporting neighborhood must go
        // dormant with it. Same 45s grace as the squad retreat, so a brief step-out-and-back
        // never nukes everything. Deactivation is on-demand: any marker respawns the moment a
        // player approaches again, and far markers can still dispatch reinforcements on demand.
        if (isNil "MISSION_CORE_NEIGHBOR_GIVEUP") then { MISSION_CORE_NEIGHBOR_GIVEUP = createHashMap; };
        {
            private _cName = _x select 0;
            if ((_x select 4) != _side) then { continue; };
            if (_contested findIf { (_x select 0) == _cName } != -1) then {
                // Still an active fight - a later give-up must be allowed to fire again.
                MISSION_CORE_NEIGHBOR_GIVEUP deleteAt _cName;
                continue;
            };
            private _last = MISSION_CORE_CONTESTED_LAST getOrDefault [_cName, -1e10];
            // Markers never contested have no entry; only teardown once the fight has been quiet
            // past the grace period and the marker was actually fought recently at all.
            if (_last <= 0 || { time - _last < (["contestedGraceSeconds", 45] call MISSION_CORE_fnc_tune) }) then { continue; };
            if (MISSION_CORE_NEIGHBOR_GIVEUP getOrDefault [_cName, false]) then { continue; };
            MISSION_CORE_NEIGHBOR_GIVEUP set [_cName, true];
            if (isNil "MISSION_CORE_CONTESTED") then { MISSION_CORE_CONTESTED = createHashMap; };
            MISSION_CORE_CONTESTED deleteAt _cName;
            diag_log format ["AI COMMANDER: %1 contested ended (player died / walked away) - deactivating neighborhood", _cName];
            [_cName, _x select 1, _side] call MISSION_CORE_fnc_deactivateNeighborMarkers;
        } forEach MISSION_CORE_CACHED_POSITIONS;
    } forEach [WEST, EAST];
};
