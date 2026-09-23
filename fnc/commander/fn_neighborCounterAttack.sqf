
// Chosen neighbors of a contested marker: the exact filtered, distance-sorted set the
// counter-attack dispatcher uses. A marker is a neighbor when ALL of these hold:
//   - same side as the contested marker,
//   - not the contested marker itself,
//   - not another currently-contested zone (a zone never counter-attacks another zone),
//   - not light infrastructure (power/solar never send troops),
//   - within neighborRange (4000m) of the contested marker,
//   - when the contested marker is overwatch, only other overwatch markers qualify.
// Returns CACHED_POSITIONS loc entries, sorted ascending by distance. Pass _zoneNames to reuse an
// already-computed contested-zone name list (avoids a second getContestedMarkers pass per tick).
MISSION_CORE_fnc_getMarkerNeighbors = {
    params ["_locName", "_locPos", "_side", ["_zoneNames", []]];
    if (isNil "MISSION_CORE_CACHED_POSITIONS") exitWith { [] };
    if (count _zoneNames == 0) then {
        _zoneNames = ([_side] call MISSION_CORE_fnc_getContestedMarkers) apply { _x select 0 };
    };
    private _neighbors = MISSION_CORE_CACHED_POSITIONS select {
        (_x select 4) == _side &&
        { (_x select 0) != _locName } &&
        { !((_x select 0) in _zoneNames) } &&
        { !([_x] call MISSION_CORE_fnc_isLightInfrastructure) } &&
        { ((_x select 1) distance _locPos) < (["neighborRange", 4000] call MISSION_CORE_fnc_tune) }
    };
    _neighbors = [_neighbors, [], { (_x select 1) distance _locPos }, "ASCEND"] call BIS_fnc_sortBy;
    // Overwatch rule: a contested overwatch (high-ground) marker may only be reinforced /
    // counter-attacked by OTHER overwatch markers - no other marker can help it.
    if ([_locName] call MISSION_CORE_fnc_isOverwatchMarker) then {
        _neighbors = _neighbors select { [(_x select 0)] call MISSION_CORE_fnc_isOverwatchMarker };
    };
    _neighbors
};

MISSION_CORE_fnc_neighborCounterAttack = {
    params ["_locName", "_locPos", "_side", "_importance"];
    // PERMANENT RULE: every actually-contested marker is a zone (no per-player cap). A marker
    // must be one of the side's contested zones (a player is actually engaging it) to receive
    // neighbor reinforcements - a secondary marker a player merely brushed past never gets fed.
    // Each zone is handled independently with its own neighbor pool below.
    private _zoneList = [_side] call MISSION_CORE_fnc_getContestedMarkers;
    if (_zoneList findIf { (_x select 0) == _locName } == -1) exitWith {};
    if (isNil "MISSION_CORE_REINF_COOLDOWN") then { MISSION_CORE_REINF_COOLDOWN = createHashMap; };
    private _last = MISSION_CORE_REINF_COOLDOWN getOrDefault [_locName, -99999];
    // VERDICT CADENCE: the gate is a SHORT window (a marker may re-evaluate frequently). The
    // verdict decides what gets stamped below: HOLD stamps a short re-eval window so a quiet
    // marker keeps re-checking until it climbs to CRITICAL; REINFORCE/CRITICAL stamp the long
    // 300s dispatch window after actually spending. Keeping the gate short means a HOLD marker
    // never burns a long cooldown and skips the moment the fight shifts.
    if (_last != -99999 && { time - _last < 30 }) exitWith {};
    // PERMANENT RULE: the contested marker's OWN garrison must be fully spawned before any
    // neighbor dispatches reinforcements. The proximity spawner spawns it on its own async
    // cycle, so a battle can start before the garrison exists. Force it now so the contested
    // marker's units are on the map first, then neighbors reinforce on top of it.
    if (isNil "MISSION_CORE_SPAWNED_LOCATIONS") then { MISSION_CORE_SPAWNED_LOCATIONS = createHashMap; };
    if !(MISSION_CORE_SPAWNED_LOCATIONS getOrDefault [_locName, false]) then {
        private _locEntry = (MISSION_CORE_CACHED_POSITIONS select { (_x select 0) == _locName }) param [0, []];
        if (count _locEntry > 0) then {
            MISSION_CORE_SPAWNED_LOCATIONS set [_locName, true];
            [_locEntry] call MISSION_CORE_fnc_spawnLocation;
            diag_log format ["DYNAMIC REINF: %1 forced garrison spawn before neighbors", _locName];
        };
    };
    // The contested marker itself claims the first of the 4 spawn slots (contested + 3 neighbors)
    [_locName] call MISSION_CORE_fnc_spawnerSlotFree;
    // SCARE GATE: the marker only begs for help when its combat assessment says so. The verdict
    // decides how hard and how often:
    //   HOLD      - not scared enough - NO neighbor is asked. Marker re-evaluates on a short
    //               cadence and keeps re-checking until the verdict climbs to CRITICAL.
    //   REINFORCE - asks a FEW neighbors (the tier-scaled ask-some fraction).
    //   CRITICAL  - asks ALL neighbors and keeps re-asking; no further re-eval is needed, it is
    //               already at max distress (factories/power/bases hit this almost instantly).
    private _locEntry2 = (MISSION_CORE_CACHED_POSITIONS select { (_x select 0) == _locName }) param [0, []];
    private _assessOut = if (count _locEntry2 > 0) then { [_locEntry2, _side] call MISSION_CORE_fnc_markerCombatAssessment } else { [0, "HOLD", 0] };
    private _scare = _assessOut select 0;
    private _verdict = _assessOut select 1;
    private _useFrac = _assessOut select 2;
    if (_verdict == "HOLD") then {
        diag_log format ["DYNAMIC SCARE GATE: %1 verdict HOLD (scare=%2) - no neighbors asked, re-eval later", _locName, round _scare];
        // Re-eval cadence: stamp time, the 30s gate above blocks re-checks until the window
        // passes, then this marker re-evaluates and the moment its garrison is beaten down
        // enough it climbs to REINFORCE/CRITICAL. Once CRITICAL it stays asking all neighbors
        // on the long 300s dispatch window - no re-eval needed, it is already wide awake.
        MISSION_CORE_REINF_COOLDOWN set [_locName, time];
    };
    // PERMANENT RULE: exitWith is NOT legal inside a then { } block (SQF "Missing ;" parse
    // quirk - see fn_isMarkerContested) - the HOLD bail-out must sit at function scope.
    if (_verdict == "HOLD") exitWith {};
    if (isNil "MISSION_CORE_GARRISON_BASELINE") then { MISSION_CORE_GARRISON_BASELINE = createHashMap; };
    private _baseline = MISSION_CORE_GARRISON_BASELINE getOrDefault [_locName, [_importance] call MISSION_CORE_fnc_markerCapacity];
    private _aliveNow = [_locName, _side] call MISSION_CORE_fnc_countMarkerGarrison;
    if (_aliveNow >= _baseline) then {
        diag_log format ["DYNAMIC REINF: %1 full (%2/%3) but %4 - calling neighbors anyway", _locName, _aliveNow, _baseline, _verdict];
    };
    // Committed to dispatching neighbors: stamp the long 300s window now. REINFORCE is a measured
    // burst on this cadence; CRITICAL keeps re-asking ALL neighbors on it too - the marker is at
    // max distress, so it stays wide awake instead of re-evaluating from a cold HOLD.
    MISSION_CORE_REINF_COOLDOWN set [_locName, time];
    private _factionData = if (_side == WEST) then { MISSION_CORE_BLUFOR_DATA } else { MISSION_CORE_REDFOR_DATA };
    // PERMANENT RULE: a contested marker NEVER counter-attacks another contested marker. A zone's
    // own garrison must stay and defend its own fight - so contested markers are excluded from the
    // neighbor pool entirely (no troops dispatched, no manpower credit).
    private _zoneNames = _zoneList apply { _x select 0 };
    // PERMANENT RULE: powerplants / solar are static tiny garrisons - they never
    // send counter-attacks to a neighbor marker (no troops dispatched, no manpower credit).
    // The chosen-neighbor set (same filters + overwatch rule) is shared with the zone-handoff
    // re-evaluation so both paths always agree on who "normally" supports a marker.
    private _neighbors = [_locName, _locPos, _side, _zoneNames] call MISSION_CORE_fnc_getMarkerNeighbors;
    if (count _neighbors == 0) exitWith {};
    // SCARE GATE: only the verdict-sanctioned SLICE of the neighbor pool is dispatched. REINFORCE
    // uses the nearest few (distance-sorted above, so this keeps the CLOSEST providers); CRITICAL
    // uses all of them. This is the "a FEW" vs "ALL" difference from the assessment.
    if (_verdict == "REINFORCE" && { _useFrac < 1 }) then {
        _neighbors = _neighbors select [0, ceil (count _neighbors * _useFrac)];
        diag_log format ["DYNAMIC SCARE GATE: %1 verdict REINFORCE (useFrac=%2) - asking %3 closest neighbors", _locName, _useFrac, count _neighbors];
    } else {
        diag_log format ["DYNAMIC SCARE GATE: %1 verdict CRITICAL - asking ALL %2 neighbors", _locName, count _neighbors];
    };
    private _contestedIdx = MISSION_CORE_CACHED_POSITIONS findIf { (_x select 0) == _locName };
    private _targetSize = if (_contestedIdx >= 0) then { (MISSION_CORE_CACHED_POSITIONS select _contestedIdx) select 8 } else { [_importance, _importance] };
    private _totalSent = 0;
    // Pooled reinforcement budget: total manpower the whole zone will expend on this marker,
    // driven by the marker's determination (neighbor budget fraction).
    private _tier = 2;
    private _budgetFrac = 0.4;
    if (_contestedIdx >= 0) then {
        private _det = [(MISSION_CORE_CACHED_POSITIONS select _contestedIdx)] call MISSION_CORE_fnc_getMarkerDetermination;
        _tier = _det select 0;
        _budgetFrac = _det select 2;
    };
    // Tanks counter-attack, scaled by the contested marker's tier: more important = more tanks.
    private _maxTanks = ([3, 2, 1, 0] select _tier);
    // PERMANENT RULE: neighbors may counter-attack a contested marker with tanks (assault order,
    // so it bypasses the factory/contested gating), BUT the TOTAL tanks the whole side commits to
    // any single zone is capped by its importance and tier. Once a zone's cumulative counter-attack
    // tank budget is spent, no further tank orders are placed for it.
    private _tankBudget = round (([5, 4, 3, 2] select _tier) * (1 + (_importance - 1) * 0.25));
    private _pool = 0;
    {
        _pool = _pool + ([(_x select 7)] call MISSION_CORE_fnc_markerCapacity);
    } forEach _neighbors;
    _pool = round (_pool * _budgetFrac);
    if (isNil "MISSION_CORE_REINF_SENT") then { MISSION_CORE_REINF_SENT = createHashMap; };
    private _sentTotal = MISSION_CORE_REINF_SENT getOrDefault [_locName, 0];
    // AMMO: a low-ammo zone is directly threatened (it is contested) but fights at only 0.3x
    // budget - it stays mostly on the defensive. At 0 ammo it is fully passive: no counter-attack
    // at all (budget 0 makes the pool check below exit).
    private _ammoFrac = [_locName] call MISSION_CORE_fnc_getAmmoFraction;
    private _ammoFactor = if (_ammoFrac <= 0) then { 0 } else { if (_ammoFrac < 0.3) then { 0.3 } else { [1.0, 0.5] select (_ammoFrac < 0.7) } };
    _pool = _pool * _ammoFactor;
    private _poolSafe = _pool max 1;

    if (_sentTotal >= _pool) exitWith {
        if (isNil "MISSION_CORE_REINF_EXHAUSTED") then { MISSION_CORE_REINF_EXHAUSTED = createHashMap; };
        MISSION_CORE_REINF_EXHAUSTED set [_locName, true];
        diag_log format ["DYNAMIC REINF BUDGET: %1 pool exhausted (%2/%3)", _locName, _sentTotal, _pool];
        // PERMANENT RULE: the supporting neighborhood gives up - it goes dormant so it stops
        // feeding this fight. The contested marker ITSELF stays contested and keeps fighting with
        // its own self-replenishing garrison (contested never clears on give-up).
        [_locName, _locPos, _side] call MISSION_CORE_fnc_deactivateNeighborMarkers;
    };
    diag_log format ["DYNAMIC REINF BUDGET: %1 pool=%2 budgetFrac=%3 sent=%4", _locName, _pool, _budgetFrac, _sentTotal];
    // AMMO: mounting this counter-attack costs the contested marker ammo.
    [_locName, ["ammoCostCounterAttack", 2] call MISSION_CORE_fnc_tune] call MISSION_CORE_fnc_consumeAmmo;

    // PERMANENT RULE: counter-attack tanks come from the factory/depot system only - one
    // order for the tier-scaled budget, routed to the nearest warehouse with stock and
    // shipped as a convoy (deduplicated per side+target so it never stacks). Assault order
    // so it filters through to the contested marker; cumulative spend gated by budget.
    if (isNil "MISSION_CORE_REINF_TANK_BUDGET") then { MISSION_CORE_REINF_TANK_BUDGET = createHashMap; };
    private _spent = MISSION_CORE_REINF_TANK_BUDGET getOrDefault [_locName, 0];
    private _thisEvent = (_maxTanks min (_tankBudget - _spent)) max 0;
    if (_thisEvent > 0) then {
        MISSION_CORE_REINF_TANK_BUDGET set [_locName, _spent + _thisEvent];
        [_side, _locName, _locPos, _thisEvent, true] call MISSION_CORE_fnc_orderTank;
        diag_log format ["DYNAMIC REINF: counter-attack tank order placed for %1 (n=%2, budget %3/%4)", _locName, _thisEvent, _spent + _thisEvent, _tankBudget];
    };
    private _spawnedProviders = 0;
    if (isNil "MISSION_CORE_COMMIT") then { MISSION_CORE_COMMIT = createHashMap; };
    {
        private _prov = _x;
        private _provName = _prov select 0;
        private _provImp = _prov select 7;
        private _provPos = _prov select 1;
        private _provSize = if (count _prov > 8) then { _prov select 8 } else { [200, 200] };
        // Pooled budget: stop every provider once the zone's total reinforcement pool is spent.
        if (_sentTotal >= _pool) exitWith {};
        // The contested marker itself claims the first spawn slot. Up to 3 closest neighbors may
        // then send real troops (PERMANENT RULE - never reduce below 3). Any neighbor beyond the
        // 4-marker limit only grants manpower credit.
        private _canSpawn = (_spawnedProviders < 3) && { [_provName] call MISSION_CORE_fnc_spawnerSlotFree };
        if (_canSpawn) then {
            private _groups = _factionData select 17;
            // Stronger levels contribute more: 1 group per level, capped at 5
            private _infGroups = (_provImp max 1) min 5;
            // Diminishing retake: when the players capture a marker, fewer and fewer neighbor
            // counter-attack squads spawn to take it back. Scales down across the marker's 20-min
            // retake window; when it reaches zero, no more spawn and spawned units disengage to
            // patrol the next closest REDFOR marker instead of feeding a dead zone.
            if (!isNil "MISSION_CORE_CAPTURED_RETAKE" && { _locName in MISSION_CORE_CAPTURED_RETAKE }) then {
                private _rv = MISSION_CORE_CAPTURED_RETAKE get _locName;
                if (count _rv > 1 && { (_rv select 0) == _side }) then {
                    private _age = time - (_rv select 1);
                    private _frac = (1 - (_age / 1200)) max 0;
                    _infGroups = round (_infGroups * _frac);
                };
            };
            if (_infGroups <= 0) exitWith {
                if (_side == EAST) then { [_locName] call MISSION_CORE_fnc_disengageToNextMarker; };
                // PERMANENT RULE: the retake window has run out - the supporting neighborhood
                // goes dormant with it (contested itself never clears on give-up).
                [_locName, _locPos, _side] call MISSION_CORE_fnc_deactivateNeighborMarkers;
            };
            private _infPool = [_groups] call MISSION_CORE_fnc_getInfTemplates;
            private _sentMen = 0;
            for "_i" from 1 to _infGroups do {
                if (count _infPool == 0) exitWith {};
                // INTENSITY CURVE + HARD CAP (PERMANENT RULE): never commit a squad once the
                // running cumulative (sent before this call + this provider's batch so far)
                // reaches the pool - so a single provider can never overshoot the budget. The
                // inter-squad gap widens as the pool drains: 0.2s at a fresh pool ramping
                // exponentially (pow 3) to 5s near exhausted, so the wave visibly loses steam.
                if ((_sentTotal + _sentMen) >= _pool) exitWith {};
                private _template = selectRandom _infPool;
                private _frac = ((_sentTotal + _sentMen) / _poolSafe) min 1;
                private _gap = 0.2 + ((_frac * _frac * _frac) * 4.8);
                // Reinforcements assemble INSIDE the provider's marker (the lax scan tolerates a
                // couple of minor obstacles so a spot in a dense town centre still resolves).
                private _strikeDir = _provPos getDir _locPos;
                private _spawnPos = [_provPos, _provSize, 30, _strikeDir, true] call MISSION_CORE_fnc_findVehiclePos;
                // Foot infantry cap: max 3 towns per side may field infantry, and total enemy
                // foot squads alive is hard-capped at 10 (PERMANENT RULE). Queue the squad when
                // either cap is full and release it when a slot frees.
                if (!([_side, "inf", _provPos] call MISSION_CORE_fnc_townCategoryCanUse) || { ([_side] call MISSION_CORE_fnc_countFootSquads) >= (["footSquadCapSquads", 10] call MISSION_CORE_fnc_tune) }) then {
                    ["MISSION_CORE_fnc_queuedCounterAttackInf", format ["cainf_%1_%2_%3", _provName, _locName, _i], [_side, _template, _spawnPos, _factionData select 3, _provImp, _provPos, _provSize, _provName, _locPos, _targetSize, _locName]] call MISSION_CORE_fnc_enqueueSpawn;
                    _sentMen = _sentMen + (_template select 2);
                } else {
                    private _grp = [_template select 0, _spawnPos, _side, _factionData select 3, "AWARE", "NORMAL", _provImp, _provPos, _provSize] call MISSION_CORE_fnc_spawnGroup;
                    if (isNull _grp) then { continue; };
                    _grp setVariable ["MISSION_CORE_ORIGIN_MARKER", _provName];
                    _grp setVariable ["MISSION_CORE_IMPORTANCE", _provImp];
                    if (isNil "MISSION_CORE_SPAWNED_GROUPS") then { MISSION_CORE_SPAWNED_GROUPS = []; };
                    MISSION_CORE_SPAWNED_GROUPS pushBack _grp;
                    [_grp, _locPos, _targetSize] call MISSION_CORE_fnc_sendCounterAttack;
                    _sentMen = _sentMen + (_template select 2);
                };
                // Curve-driven gap between counter-attack squads: fast when the pool is fresh,
                // widening as it drains (computed before each squad, so a mid-batch drain slows
                // the tail of the same provider).
                sleep _gap;
            };
            // Curve-driven gap between provider reinforcements so groups don't cluster.
            // Recomputes the gap at this scope (the squad-level _gap is private to the loop).
            private _provFrac = (_sentTotal / _poolSafe) min 1;
            sleep (0.2 + ((_provFrac * _provFrac * _provFrac) * 4.8));
            // COMMIT 1:1 (PERMANENT RULE): every man a provider marches to a counter-attack is
            // debited from ITS OWN manpower pool - troops are paid for 1 for 1, never subsidized.
            MISSION_CORE_COMMIT set [_provName, (MISSION_CORE_COMMIT getOrDefault [_provName, 0]) + _sentMen];
            _sentTotal = _sentTotal + _sentMen;
            MISSION_CORE_REINF_SENT set [_locName, _sentTotal];
            _totalSent = _totalSent + _sentMen;
            _spawnedProviders = _spawnedProviders + 1;
        } else {
            // Far neighbor: no marching units, no manpower credit. PERMANENT RULE: a neighbor's
            // manpower is NEVER credited to another marker - a contested marker cannot request
            // manpower, so there is no credit path at all.
        };
    } forEach _neighbors;
    if (_totalSent > 0) then {
        diag_log format ["DYNAMIC REINF: %1 (%2) reinforced by %3 neighbors (men=%4, spawners=%5)", _locName, _side, count _neighbors, _totalSent, _spawnedProviders];
    };
    // Curve-driven gap after the contested marker's whole reinforcement set before any other
    // spawn burst: 5s at a fresh pool scaling to ~15s when nearly exhausted (matches the
    // squad/provider slowdown so a drained zone literally stops asking for a while).
    if (_totalSent > 0) then {
        private _tailFrac = (_sentTotal / _poolSafe) min 1;
        sleep (5 + ((_tailFrac * _tailFrac * _tailFrac) * 10));
    };
};
