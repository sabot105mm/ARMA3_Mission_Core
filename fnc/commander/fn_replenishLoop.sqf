
// Periodically replenish each marker's garrison up to its baseline (the "manpower" the player
// grinds through). When the marker's INITIAL garrison is wiped while an enemy player is inside,
// the marker flips to the player as TEMP owner (occupied). Markers owned by players are left alone.
MISSION_CORE_fnc_replenishLoop = {
    diag_log "DYNAMIC REPLENISH: started";
    while { true } do {
        sleep 45;
        private _players = allPlayers select { alive _x };
        private _playerSides = _players apply { side _x };
        private _candidates = MISSION_CORE_CACHED_POSITIONS select {
            !((_x select 4) in _playerSides) &&
            { private _lp = _x select 1; _players findIf { _x distance _lp < (["replenishRange", 2500] call MISSION_CORE_fnc_tune) } != -1 }
        };
        private _has70 = { (_x select 0) == "loc_NameLocal_70" } count _candidates > 0;
        diag_log format ["DYNAMIC CAPTURE FILTER: players=%1 candidates=%2 has70=%3", count _players, count _candidates, _has70];
        // Contested markers (player actively engaging the garrison) get replenished first
        _candidates = [_candidates, [], { if ([(_x select 1), (_x select 4), (_x select 0)] call MISSION_CORE_fnc_isMarkerContested) then { 0 } else { 1 } }, "ASCEND"] call BIS_fnc_sortBy;
        {
            private _loc = _x;
            private _locName = _loc select 0;
            private _locPos = _loc select 1;
            private _owner = _loc select 4;
            private _importance = _loc select 7;
            private _nearPD = 99999;
            { private _d = _x distance _locPos; if (_d < _nearPD) then { _nearPD = _d; }; } forEach _players;
            private _spawnedNow = MISSION_CORE_SPAWNED_LOCATIONS getOrDefault [_locName, false];
            diag_log format ["DYNAMIC CAPTURE GATE: %1 owner=%2 dist=%3 spawned=%4", _locName, _owner, round _nearPD, _spawnedNow];
            // Never touch markers owned by the players - they defend their own marker
            if (_owner in _playerSides) then { continue; };
            // Only markers near a player are contested / replenished
            if (_players findIf { _x distance _locPos < 2500 } == -1) then { continue; };
            // Deactivated (despawned) markers are not replenished - only their counter-attack /
            // reinforce units matter and those spawn on demand from the queue
            if (!(MISSION_CORE_SPAWNED_LOCATIONS getOrDefault [_locName, false])) then { continue; };
            private _capacity = [_importance] call MISSION_CORE_fnc_markerCapacity;
            if (isNil "MISSION_CORE_COMMIT") then { MISSION_CORE_COMMIT = createHashMap; };
            // Manpower credit from far neighbors matures here (average travel time based)
            if (isNil "MISSION_CORE_MANPOWER") then { MISSION_CORE_MANPOWER = createHashMap; };
            if (isNil "MISSION_CORE_MANPOWER_CUTOFF") then { MISSION_CORE_MANPOWER_CUTOFF = createHashMap; };
            private _matured = 0;
            private _pending = [];
            // Markers cut off after a neighbor's capture no longer receive manpower from
            // neighbors - void any credits still in flight until the marker is deactivated.
            if (MISSION_CORE_MANPOWER_CUTOFF getOrDefault [_locName, false]) then {
                MISSION_CORE_MANPOWER set [_locName, []];
            } else {
                private _credits = MISSION_CORE_MANPOWER getOrDefault [_locName, []];
                {
                    if (time >= (_x select 1)) then { _matured = _matured + (_x select 0); }
                    else { _pending pushBack _x; };
                } forEach _credits;
                MISSION_CORE_MANPOWER set [_locName, _pending];
            };
            // Neighbor manpower credit matures into the effective cap, but it can NEVER push a
            // marker past its importance capacity (its initial manpower) - neighbors resupply only
            // toward what the marker originally rated, never above it.
            private _effectiveCap = (((_capacity - (MISSION_CORE_COMMIT getOrDefault [_locName, 0])) + _matured) min _capacity) max 0;
            // Baseline = the marker's BASE supply: what it actually fields on first spawn, never the
            // theoretical capacity. Replenishment only restores losses back up to this baseline and
            // never pushes the garrison past it.
            if (isNil "MISSION_CORE_GARRISON_BASELINE") then { MISSION_CORE_GARRISON_BASELINE = createHashMap; };
            private _baseline = MISSION_CORE_GARRISON_BASELINE getOrDefault [_locName, _effectiveCap];
            private _alive = [_locName, _owner] call MISSION_CORE_fnc_countMarkerGarrison;
            private _mSize = if (count _loc > 8) then { _loc select 8 } else { [200, 200, 0] };
            private _ma = _mSize select 0;
            private _mb = _mSize select 1;
            private _md = if (count _mSize > 2) then { _mSize select 2 } else { 0 };
            // An ENEMY player must be physically INSIDE the marker ellipse for capture to be
            // possible - proximity alone is never enough.
            private _enemyInside = _players findIf {
                side _x getFriend _owner < 0.6 && {
                    private _p = getPos _x;
                    private _dx = (_p select 0) - (_locPos select 0);
                    private _dy = (_p select 1) - (_locPos select 1);
                    private _rx = _dx * cos _md - _dy * sin _md;
                    private _ry = _dx * sin _md + _dy * cos _md;
                    (_rx*_rx)/(_ma*_ma) + (_ry*_ry)/(_mb*_mb) <= 1
                }
            } != -1;
            // ASSAULT SQUAD THREAT: released/active BLUFOR assault groups whose units are
            // physically inside the marker ellipse count as "enemy inside" - under the new
            // contested model they are REAL threats (they scare the marker and keep it contested
            // even with no player present), and they can walk into an abandoned marker to capture
            // it just like a player can.
            if (!_enemyInside && { ["assaultSquadCapture", 1] call MISSION_CORE_fnc_tune > 0 } && { !isNil "MISSION_CORE_ATTACK_GROUPS" }) then {
                {
                    private _data = _y;
                    if ((_data select 5) != "active") then { continue; };
                    private _ag = _data select 0;
                    if (isNull _ag) then { continue; };
                    {
                        if (alive _x) then {
                            private _p = getPos _x;
                            private _dx = (_p select 0) - (_locPos select 0);
                            private _dy = (_p select 1) - (_locPos select 1);
                            private _rx = _dx * cos _md - _dy * sin _md;
                            private _ry = _dx * sin _md + _dy * cos _md;
                            if ((_rx*_rx)/(_ma*_ma) + (_ry*_ry)/(_mb*_mb) <= 1) exitWith { _enemyInside = true; };
                        };
                    } forEach units _ag;
                    if (_enemyInside) exitWith {};
                } forEach MISSION_CORE_ATTACK_GROUPS;
            };
            // MULTIPLAYER RELAY: client-spawned assault groups also threaten (same ellipse test).
            if (!_enemyInside && { ["assaultSquadCapture", 1] call MISSION_CORE_fnc_tune > 0 } && { !isNil "MISSION_CORE_ATTACK_GROUPS_RELAY" }) then {
                {
                    private _data = _y;
                    if ((_data select 5) != "active") then { continue; };
                    private _ag = _data select 0;
                    if (isNull _ag) then { continue; };
                    {
                        if (alive _x) then {
                            private _p = getPos _x;
                            private _dx = (_p select 0) - (_locPos select 0);
                            private _dy = (_p select 1) - (_locPos select 1);
                            private _rx = _dx * cos _md - _dy * sin _md;
                            private _ry = _dx * sin _md + _dy * cos _md;
                            if ((_rx*_rx)/(_ma*_ma) + (_ry*_ry)/(_mb*_mb) <= 1) exitWith { _enemyInside = true; };
                        };
                    } forEach units _ag;
                    if (_enemyInside) exitWith {};
                } forEach MISSION_CORE_ATTACK_GROUPS_RELAY;
            };
            // SUPPLY + CONTESTED MODEL. A marker with ANY BLUFOR threat present (any player
            // approaching/inside, or any assault squad targeting it) is contested from the moment
            // the threat appears, garrison-independent. The contested marker itself replenishes to
            // full template strength during the fight. Its same-side NEIGHBORS hold manpower while
            // the fight runs (zoneBlock) - they are reinforcement sources, not grind-fodder.
            // PERMANENT RULE: every actually-contested marker is a zone with its own replenish
            // cycle (fn_getContestedMarkers returns all of them, no per-player cap).
            private _zoneList = [_owner] call MISSION_CORE_fnc_getContestedMarkers;
            private _contested = (_zoneList findIf { (_x select 0) == _locName } != -1);
            // A zone freezes its whole neighborhood: same-side markers within reinforce range of a
            // contested marker also hold their manpower until that fight ends + quiet period.
            private _zoneBlock = (_zoneList findIf { (_x select 0) != _locName && { ((_x select 1) distance _locPos) < (["neighborRange", 4000] call MISSION_CORE_fnc_tune) } }) != -1;
            diag_log format ["DYNAMIC REPLENISH GATE: %1 zone=%2 contested=%3 zoneBlock=%4", _locName, _locName, _contested, _zoneBlock];
            // Replenishment grace clock: a marker that is contested (or neighbor to a contested
            // zone) records the moment it last fought, so supplies resume only after the full quiet
            // period has elapsed since the fight ended.
            if (isNil "MISSION_CORE_REPLENISH_GRACE") then { MISSION_CORE_REPLENISH_GRACE = createHashMap; };
            private _quiet = ["replenishQuietPeriod", 120] call MISSION_CORE_fnc_tune;
            if (_contested || _zoneBlock) then {
                MISSION_CORE_REPLENISH_GRACE set [_locName, time];
            };
            private _grace = MISSION_CORE_REPLENISH_GRACE getOrDefault [_locName, -1e10];
            // SUPPLY GATE (new contested model): a marker that is CONTESTED self-replenishes to
            // its full template strength DURING the fight - the garrison never runs dry while a
            // threat is present, so it can only be beaten down to its retreat threshold, not
            // quietly wiped. Its same-side NEIGHBORS stay manpower-blocked (zoneBlock) for the
            // whole fight. Exception: a marker that was a handoff's new supporting neighbor gets
            // a one-time top-up back to its own capacity FIRST, then it is manpower-blocked.
            // PERMANENT RULE: no more one-zone-per-player cap - supplies flow to whatever is
            // actually contested (bounded only by the max-spawned-troops limits).
            private _supplyOpen = _contested;
            if (!_supplyOpen) then {
                if (isNil "MISSION_CORE_HANDOFF_TOPUP") then { MISSION_CORE_HANDOFF_TOPUP = []; };
                if (_locName in MISSION_CORE_HANDOFF_TOPUP) then {
                    if (_alive >= _baseline) then {
                        // Reached full strength: the one-time top-up is spent - go manpower-blocked.
                        MISSION_CORE_HANDOFF_TOPUP = MISSION_CORE_HANDOFF_TOPUP - [_locName];
                    } else {
                        _supplyOpen = true;
                    };
                };
            };
            if (!_supplyOpen && { !_zoneBlock && { _grace != -1e10 } && { (time - _grace) >= _quiet } }) then {
                _supplyOpen = true;
            };
            // DETERMINATION-BASED RETREAT + FLIP.
            // - The garrison retreats once it has lost (1 - holdFrac) of its capacity (holdFrac from
            //   the marker's strategic value). It runs to the closest ally and despawns.
            // - The marker flips to the player when a hostile player walks INTO the empty marker.
            private _det = [_loc] call MISSION_CORE_fnc_getMarkerDetermination;
            private _holdFrac = _det select 1;
            if (isNil "MISSION_CORE_MARKER_CASUALTIES") then { MISSION_CORE_MARKER_CASUALTIES = createHashMap; };
            private _casualties = MISSION_CORE_MARKER_CASUALTIES getOrDefault [_locName, 0];
            private _retreatAt = round (_capacity * (1 - _holdFrac));
            if (isNil "MISSION_CORE_RETREATED") then { MISSION_CORE_RETREATED = createHashMap; };
            private _retreated = MISSION_CORE_RETREATED getOrDefault [_locName, false];
            diag_log format ["DYNAMIC CAPTURE DEBUG: %1 alive=%2 cap=%3 casualties=%4 retreatAt=%5 hold=%6 retreated=%7 enemyInside=%8", _locName, round _alive, _capacity, _casualties, _retreatAt, _holdFrac, _retreated, _enemyInside];
            // Retreat: the garrison gives up at the determination threshold and runs away. The
            // latch is tied to CASUALTIES ALONE - a garrison wiped to 0 before the threshold does
            // not slip through: it keeps self-reinforcing (replenish is open while contested) and
            // the instant cumulative losses cross retreatAt it retreats / flips to abandoned.
            if (_casualties >= _retreatAt && { !_retreated }) then {
                MISSION_CORE_RETREATED set [_locName, true];
                diag_log format ["DYNAMIC RETREAT: %1 lost %2/%3 - garrison retreating", _locName, _casualties, _retreatAt];
                [_locName, _locPos, _owner] call MISSION_CORE_fnc_retreatGarrison;
            };
            // PERMANENT RULE (new contested model): contested NEVER clears because the marker
            // "gave up" - contested only ends when the marker is captured fully, or all threats
            // died / walked away (both handled by the capture / despawn paths). Even when its
            // neighbors exhaust their reinforcement budget the marker stays contested: its own
            // garrison keeps self-replenishing to full template strength while a threat is
            // present. The neighbor-give-up teardown (budget spent) is handled inside
            // fn_neighborCounterAttack / fn_deactivateNeighborMarkers, and only quiets the
            // SUPPORTING neighborhood, never the marker's own fight.
            // Flip: walk into the marker AFTER it has abandoned the fight to occupy it. The garrison
            // must have RETREATED (crossed its determination casualty threshold) AND be gone from
            // the map (alive == 0) - it is never "captured by wiping", because the garrison
            // self-replenishes to full template strength while contested and only retreats at
            // retreatAt. The garrison must ALSO have actually SPAWNED at least once (a baseline
            // entry is only written after men field) - a player walking into a marker that never
            // spawned its garrison cannot capture it.
            private _garrisonFielded = _locName in MISSION_CORE_GARRISON_BASELINE;
            if (_enemyInside && { _alive == 0 } && { _retreated } && { _garrisonFielded }) then {
                diag_log format ["DYNAMIC CAPTURE: %1 garrison retreated - OCCUPYING", _locName];
                [_locName, _locPos, _owner, _importance] call MISSION_CORE_fnc_captureMarkerForPlayers;
                continue;
            };
            // GIVE-UP FLIP (local manpower model): the marker bought its garrison out of its OWN
            // local allotment. Once that pool is SPENT and the neighbors have exhausted their
            // allotted reinforcement budget, there is nothing left to field - the marker has truly
            // given up. It flips outright once no enemy is near (within double the marker footprint),
            // with no walk-in required (the fight is over and nobody is even contesting it).
            if (_alive == 0 && { _garrisonFielded } && { !_retreated } && { (MISSION_CORE_LOCATION_SUPPLY getOrDefault [_locName, 0]) <= 0 } && { (MISSION_CORE_REINF_EXHAUSTED getOrDefault [_locName, false]) }) then {
                private _armDist = 2 * ((_ma max _mb) max 10);
                private _enemyNear = _players findIf { side _x getFriend _owner < 0.6 && { _x distance _locPos < _armDist } } != -1;
                if (!_enemyNear) then {
                    diag_log format ["DYNAMIC CAPTURE: %1 manpower spent + neighbors exhausted - GIVING UP (no enemy within %2m)", _locName, round _armDist];
                    [_locName, _locPos, _owner, _importance] call MISSION_CORE_fnc_captureMarkerForPlayers;
                    continue;
                };
            };
            // Replenish the garrison (manpower flows to the marker) while below baseline, until it
            // retreats. Supplies run while the marker is CONTESTED (full template strength during
            // the fight), or once it and its neighborhood are not contested and the quiet period
            // since the last fight has elapsed.
            if (_supplyOpen && { _alive > 0 } && { _alive < _baseline } && { !_retreated }) then {
                // The replenishing marker counts as one of the 4 active spawners while it refills
                [_locName] call MISSION_CORE_fnc_spawnerSlotFree;
                // PERMANENT RULE (local manpower model): a garrison re-fields ONLY from the marker's
                // OWN local manpower pool (MISSION_CORE_LOCATION_SUPPLY), 1-for-1 - a marker never
                // draws base manpower for day-to-day replenish. A contested marker or an ACTIVE
                // neighbor CANNOT request resupply - it grinds its own allotment. The ONLY base draw
                // is the handoff top-up EXCEPTION neighbor (a new supporting marker refilled once).
                if (isNil "MISSION_CORE_LOCATION_SUPPLY") then { MISSION_CORE_LOCATION_SUPPLY = createHashMap; };
                private _want = ((_baseline - _alive) min 8) max 1;
                private _funded = 0;
                private _baseName = "";
                if (isNil "MISSION_CORE_HANDOFF_TOPUP") then { MISSION_CORE_HANDOFF_TOPUP = []; };
                if (_locName in MISSION_CORE_HANDOFF_TOPUP) then {
                    private _draw = [_owner, _locPos, _want] call MISSION_CORE_fnc_drawBaseManpower;
                    _funded = _draw select 0;
                    _baseName = _draw select 1;
                } else {
                    private _local = MISSION_CORE_LOCATION_SUPPLY getOrDefault [_locName, 0];
                    _funded = _local min _want;
                    if (_funded > 0) then { MISSION_CORE_LOCATION_SUPPLY set [_locName, _local - _funded]; };
                };
                if (_funded > 0) then {
                    private _replenished = [_loc, _owner, _importance, _alive, _baseline, _funded] call MISSION_CORE_fnc_replenishMarker;
                    if (_replenished < _funded) then {
                        if (_baseName == "") then { MISSION_CORE_LOCATION_SUPPLY set [_locName, (MISSION_CORE_LOCATION_SUPPLY getOrDefault [_locName, 0]) + (_funded - _replenished)]; }
                        else { [_baseName, _funded - _replenished] call MISSION_CORE_fnc_refundBaseManpower; };
                    };
                    // 5s gap after a marker finishes its whole spawn set before the next marker
                    // replenishes, so the AI never spawns several towns' garrisons back-to-back.
                    if (_replenished > 0) then { sleep 5; };
                };
            };
            // Respawn the garrison when wiped, until it retreats. A contested marker self-replenishes
            // even mid-fight, so a garrison that was beaten to 0 before reaching its retreat
            // threshold re-fields and keeps fighting - it is never quietly wiped away.
            if (_supplyOpen && { _alive == 0 } && { !_retreated }) then {
                diag_log format ["DYNAMIC CAPTURE DEBUG: %1 alive=0 enemyInside=%2", _locName, _enemyInside];
                [_locName] call MISSION_CORE_fnc_spawnerSlotFree;
                // Same local-manpower rule as above: a wiped garrison re-fields ONLY from the
                // marker's OWN local pool, or the handoff top-up EXCEPTION neighbor's base draw.
                if (isNil "MISSION_CORE_LOCATION_SUPPLY") then { MISSION_CORE_LOCATION_SUPPLY = createHashMap; };
                private _want = ((_baseline - 0) min 8) max 1;
                private _funded = 0;
                private _baseName = "";
                if (isNil "MISSION_CORE_HANDOFF_TOPUP") then { MISSION_CORE_HANDOFF_TOPUP = []; };
                if (_locName in MISSION_CORE_HANDOFF_TOPUP) then {
                    private _draw = [_owner, _locPos, _want] call MISSION_CORE_fnc_drawBaseManpower;
                    _funded = _draw select 0;
                    _baseName = _draw select 1;
                } else {
                    private _local = MISSION_CORE_LOCATION_SUPPLY getOrDefault [_locName, 0];
                    _funded = _local min _want;
                    if (_funded > 0) then { MISSION_CORE_LOCATION_SUPPLY set [_locName, _local - _funded]; };
                };
                if (_funded > 0) then {
                    private _replenished = [_loc, _owner, _importance, 0, _baseline, _funded] call MISSION_CORE_fnc_replenishMarker;
                    if (_replenished < _funded) then {
                        if (_baseName == "") then { MISSION_CORE_LOCATION_SUPPLY set [_locName, (MISSION_CORE_LOCATION_SUPPLY getOrDefault [_locName, 0]) + (_funded - _replenished)]; }
                        else { [_baseName, _funded - _replenished] call MISSION_CORE_fnc_refundBaseManpower; };
                    };
                    if (_replenished > 0) then { sleep 5; };
                };
            };
        } forEach _candidates;
    };
};
