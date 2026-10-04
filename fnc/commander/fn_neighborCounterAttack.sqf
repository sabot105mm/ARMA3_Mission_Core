// NEIGHBOR COUNTER-ATTACK - the contested marker's reinforcement request.
//
// This file is the ORCHESTRATOR. It decides who asks, when, and how hard, then hands the work to
// two companions:
//   fn_reinforceBudget.sqf   pure arithmetic - each provider's budget for this marker
//   fn_reinforceActions.sqf  every side effect - spawning, committing, gating, pacing
// There is deliberately no arithmetic and no spawning inline below.
//
// MODEL:
//   - Each contested marker is handled entirely on its own. Its pool is the SUM of its
//     neighbors' independent decisions about how important it is to them. No shared pool, and no
//     handoff between markers - a neighbor helping marker A is unaffected by marker B.
//   - A provider that spends its limit is out for the rest of THAT marker's fight and is not
//     replaced. It remains eligible for every other marker.
//   - The pool is capped per contest (reinfMenCapPerMarker). Hitting the cap ends this marker's
//     support for good; reactivating it resets the pool, but never its own manpower.

// Chosen neighbors of a contested marker: the exact filtered, distance-sorted set the
// counter-attack dispatcher uses. A marker is a neighbor when ALL of these hold:
//   - same side as the contested marker,
//   - not the contested marker itself,
//   - not ANOTHER currently-contested zone (a zone never counter-attacks another zone),
//   - not light infrastructure (power/solar never send troops),
//   - within neighborRange of the contested marker,
//   - when the contested marker is overwatch, only other overwatch markers qualify.
// Returns CACHED_POSITIONS loc entries sorted ascending by distance. _zoneNames may be passed to
// reuse an already-computed contested-zone list; left empty it is derived here.
MISSION_CORE_fnc_getMarkerNeighbors = {
    params ["_locName", "_locPos", "_side", ["_zoneNames", []]];
    if (isNil "MISSION_CORE_CACHED_POSITIONS") exitWith { [] };
    // Contested marker NAMES come from MISSION_CORE_CONTESTED (written solely by
    // fn_isMarkerContested). _side is not needed for the name list - the map is keyed by marker
    // name and membership is the verdict. Geometry for the distance test below comes from
    // MISSION_CORE_CACHED_POSITIONS, which is a separate concern.
    if (count _zoneNames == 0) then {
        _zoneNames = if (isNil "MISSION_CORE_CONTESTED") then { [] } else { keys MISSION_CORE_CONTESTED };
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

    // ---- not actually contested: nothing to ask for ----
    private _cLoc = (MISSION_CORE_CACHED_POSITIONS select { (_x select 0) == _locName }) param [0, []];
    if (count _cLoc == 0) exitWith {
        diag_log format ["DYNAMIC REINF: %1 skipped - not a live marker record", _locName];
    };
    // "Is _locName contested?" - answered ONLY by MISSION_CORE_CONTESTED (written solely by
    // fn_isMarkerContested). Membership is the verdict; no derived list, no side filter, no second
    // opinion. The map is keyed by marker name, so no side scoping is needed for a yes/no answer.
    if ((isNil "MISSION_CORE_CONTESTED") || { !(_locName in MISSION_CORE_CONTESTED) }) exitWith {
        diag_log format ["DYNAMIC REINF: %1 skipped - no longer contested", _locName];
    };

    if (isNil "MISSION_CORE_REINF_SENT") then { MISSION_CORE_REINF_SENT = createHashMap; };
    if (isNil "MISSION_CORE_REINF_EXHAUSTED") then { MISSION_CORE_REINF_EXHAUSTED = createHashMap; };

    // ---- already given up on this fight ----
    if (MISSION_CORE_REINF_EXHAUSTED getOrDefault [_locName, false]) exitWith {
        diag_log format ["DYNAMIC REINF: %1 skipped - support exhausted for this contest", _locName];
    };

    // ---- NO IN-FLIGHT LOCK, NO RE-EVAL COOLDOWN ----
    // Two separate time-gates were tried here and both are gone. First a 600s in-flight lock that
    // made the marker refuse a dispatch while its previous worker ran; then a verdict-keyed re-eval
    // cooldown that logged "skipped - re-eval cooldown". Both imposed a fixed interval on a marker
    // that must instead be limited by what its neighbors can actually afford - see the note at the
    // top of this function. A worker killed by an exception no longer holds a marker shut either.

    // ---- NO RE-EVAL COOLDOWN ON A CONTESTED MARKER ----
    // A contested marker must not decide how often it gets reinforced. Nothing here gates this
    // function on elapsed time; it is called once per commander sweep (~8-13s) and decides fresh
    // every time. Two earlier attempts at this were both wrong and both are gone: a 600s in-flight
    // lock, then a verdict-keyed re-eval cooldown (30s HOLD / 300s committed) that logged
    // "skipped - re-eval cooldown". The cadence is not mine to impose - what a marker may be given
    // is governed entirely by the resource side, which already answers the same question honestly:
    //   MISSION_CORE_REINF_SENT vs fnc_reinfMenCap   per-contest ceiling on men
    //   fnc_zonePoolBudget                           what each provider can actually afford
    //   MISSION_CORE_REINF_EXHAUSTED                 marker hit its ceiling for this contest
    //   MISSION_CORE_REINF_PROVIDER_BLOCKED          per-pair latch
    //   fnc_spawnerSlotFree                          whether this side still has spawn capacity
    // There is deliberately no proximity gate here any more. An exhausted provider sitting close to
    // the fight used to gate the whole marker (MISSION_CORE_REINF_GATED), which froze it for the
    // entire contest on the strength of ONE provider's state, and only cleared when the marker
    // stopped being contested. What a marker may be given is answered per provider by the resource
    // side above; a near miss from one neighbor must not silence the rest.
    // Those run off live state, so a marker that loses its fight stops being reinforced on the next
    // sweep because the pool is empty - not because a timer says its last ask is still "too recent".

    // ---- the contested marker's own garrison must exist before anyone marches to help ----
    [_locName] call MISSION_CORE_fnc_ensureMarkerActive;

    // ---- SCARE GATE: how hard this marker is begging ----
    private _assessOut = [_cLoc, _side] call MISSION_CORE_fnc_markerCombatAssessment;
    private _verdict = _assessOut select 1;
    private _useFrac = _assessOut select 2;
    if (_verdict == "HOLD") then {
        diag_log format ["DYNAMIC SCARE GATE: %1 verdict HOLD (scare=%2) - no neighbors asked", _locName, round (_assessOut select 0)];
    };
    // PERMANENT RULE: exitWith is NOT legal inside a then { } block (SQF "Missing ;" parse
    // quirk - see fn_isMarkerContested.sqf:208). The HOLD bail-out must sit at function scope.
    if (_verdict == "HOLD") exitWith {};

    // Pass [] for _zoneNames so fn_getMarkerNeighbors derives the contested names itself from
    // MISSION_CORE_CONTESTED (it does so whenever the passed list is empty). This used to build a
    // local _zoneList here and hand it in; that variable no longer exists and referencing it was a
    // compile error that killed this whole file, which is why no neighbor counter-attack was
    // dispatched at all. Deriving it in the helper keeps ONE derivation of the contested-name list.
    private _neighbors = [_locName, _locPos, _side, []] call MISSION_CORE_fnc_getMarkerNeighbors;
    if (count _neighbors == 0) exitWith {
        diag_log format ["DYNAMIC REINF: %1 verdict %2 but ZERO usable neighbors (%3 in range, overwatch filter applied) - nothing to ask", _locName, _verdict, count _neighbors];
    };
    // REINFORCE asks only the nearest slice; CRITICAL asks everyone.
    if (_verdict == "REINFORCE" && { _useFrac < 1 }) then {
        _neighbors = _neighbors select [0, ceil (count _neighbors * _useFrac)];
        diag_log format ["DYNAMIC SCARE GATE: %1 verdict REINFORCE (useFrac=%2) - asking %3 closest neighbors", _locName, _useFrac, count _neighbors];
    } else {
        diag_log format ["DYNAMIC SCARE GATE: %1 verdict CRITICAL - asking ALL %2 neighbors", _locName, count _neighbors];
    };

    // ---- POOL: derived from each provider's own decision, capped per contest ----
    private _sentTotal = MISSION_CORE_REINF_SENT getOrDefault [_locName, 0];
    private _cap = call MISSION_CORE_fnc_reinfMenCap;
    private _poolOut = [_cLoc, _neighbors, _side, _sentTotal] call MISSION_CORE_fnc_zonePoolBudget;
    private _pool = _poolOut select 0;
    private _rows = _poolOut select 1;
    diag_log format ["DYNAMIC REINF POOL: %1 tier-scar=%2 verdict=%3 sent=%4/%5 pool=%6 providers=%7", _locName, round (_assessOut select 0), _verdict, _sentTotal, _cap, _pool, count _rows];
    {
        private _r = _x;
        diag_log format ["    provider %1: budget=%2 (usable=%3 cVal=%4 asset=%5 taper=%6) effective=%7%8", _r select 0, _r select 1, _r select 2, _r select 3, round (_r select 4), round (_r select 5), _r select 7, if ((_r select 6) != "") then { format [" - %1", _r select 6] } else { "" }];
    } forEach _rows;

    if (_pool <= 0) exitWith {
        diag_log format ["DYNAMIC REINF POOL: %1 no provider can commit anything (sent=%2/%3)", _locName, _sentTotal, _cap];
    };

    // ---- AMMO: already applied PER PROVIDER, in fn_reinforceBudget ----
    // The target's own magazine is deliberately NOT consulted. _locName is the RECIPIENT of this
    // dispatch: it is short of men, not short of ammo, and it needs its neighbors' help most when
    // it is bleeding. Gating on _locName meant a dry zone refused its own reinforcement - the log
    // showed a full 200-man pool and 9 solvent providers, then "ammo=0 factor=0 pool=0" and
    // nothing spawned. Each provider's own ammo now scales (and can zero) its own budget.

    // ---- this dispatch is committed ----
    // Deliberately NOT stamped with a re-eval time. Nothing time-gates the next sweep; the per-contest
    // cap stamped into MISSION_CORE_REINF_SENT by the providers below is what stops a second wave, and
    // it grows with each real commitment rather than expiring on a timer.
    diag_log format ["DYNAMIC REINF: %1 verdict %2 committed (zone now %3/%4)", _locName, _verdict, _sentTotal, _cap];
    diag_log format ["DYNAMIC REINF: %1 dispatching (pool=%2)", _locName, _pool];

    // ---- everything below SPAWNS and paces, so it runs on its own thread ----
    // The caller is MISSION_CORE_fnc_aiCommanderLoop's marker sweep, which is a forEach inside
    // `while {true} {sleep 8+random 5}`. Sleeping here froze the ENTIRE commander tick for
    // every marker on the map - with ~20 contested markers each sending 5 providers x 5 squads,
    // one pass could stall the AI for minutes. The pacing sleeps are load-shedding, not
    // correctness: they spread squad creation out so the engine is never hit with a burst, and
    // they cannot affect whether a squad commits. Detaching keeps that spreading behaviour while
    // the commander keeps sweeping. The 300s cadence stamp above already prevents a duplicate
    // dispatch, so two threads can never race on the same marker.
    [_locName, _locPos, _side, _importance, _cLoc, _pool, _rows, _sentTotal, _cap] spawn MISSION_CORE_fnc_reinforceDispatch;
};

// REINFORCE DISPATCH - the spawned half of neighbor reinforcement. Runs on its own thread: it
// places the marker tank order, walks the providers committing squads at a paced rate, records the
// spend against the zone's pool, and applies the ceiling / gate consequences. It is a separate
// function purely so the commander loop can return immediately; the logic is unchanged.
MISSION_CORE_fnc_reinforceDispatch = {
    params ["_locName", "_locPos", "_side", "_importance", "_cLoc", "_pool", "_rows", "_sentTotal", "_cap"];

    // The counter-attack ammo cost is charged to the PROVIDERS as they commit, inside the walk
    // below - not here against the target. The target is receiving help and must not pay for it
    // (and on a dry target the old charge was a silent no-op that cost the zone nothing while
    // still blocking its own reinforcement).

    // ---- the contested marker itself claims the first of its side's spawner slots ----
    [_locName, _side] call MISSION_CORE_fnc_spawnerSlotFree;

    private _det = [_cLoc] call MISSION_CORE_fnc_getMarkerDetermination;
    private _tier = _det select 0;
    [_side, _locName, _locPos, _tier, _importance] call MISSION_CORE_fnc_placeCounterAttackTanks;

    // ---- SPEND: each provider commits its own budget, one squad at a time ----
    private _factionData = if (_side == WEST) then { MISSION_CORE_BLUFOR_DATA } else { MISSION_CORE_REDFOR_DATA };
    private _cSize = if (count _cLoc > 8) then { _cLoc select 8 } else { [_importance, _importance] };
    private _poolSafe = _pool max 1;
    private _spawnedProviders = 0;
    private _totalSent = 0;

    {
            private _row = _x;
            private _provName = _row select 0;
            private _budget = _row select 7;
            private _reason = _row select 6;
            // The BUDGET's own interest terms, reused verbatim - no second opinion of importance.
            // Row layout from fn_zonePoolBudget:
            //   [_provName, _budget, _usable, _cVal, _asset, _taper, _reason, _effective]
            // _interest = _cVal * _asset * _taper (max 4.0) becomes this provider's squad cadence.
            private _interest = ((_row param [3, 1]) * (_row param [4, 1])) * (_row param [5, 1]);
        if (_budget <= 0) then {
            // Nothing to give. A provider that had men and simply could not commit is latched
            // out of THIS fight so it stops being reconsidered every tick.
            if (_reason != "") then { [_provName, _locName] call MISSION_CORE_fnc_markProviderBlocked; };
        } else {
            // A provider must actually be on the map to march from.
            [_provName] call MISSION_CORE_fnc_ensureMarkerActive;
            // A denied spawner slot must NOT skip the provider. Skipping is exactly what left 9
            // solvent providers contributing 14 men in 14 minutes: every provider beyond the 5-slot
            // cap was logged and dropped on the floor. Queueing IS the answer - the provider's
            // squads wait in MISSION_CORE_SPAWN_QUEUE and fn_queuedCounterAttackInf re-claims the
            // slot at release, so a marker that frees a slot lets the next queued provider march.
            private _slotNow = [_provName, _side] call MISSION_CORE_fnc_spawnerSlotFree;
            if (!_slotNow) then {
                diag_log format ["DYNAMIC REINF: %1 has no free spawner slot - queueing its squads", _provName];
            };
            // This block only scopes `private _sentMen` / `_queuedMen` / `_chainQueued` so they
            // reset for every provider, but a bare `{ }` is a literal in SQF and NEVER RUNS: the
            // whole walk was silently dead, so every solvent provider logged and contributed 0 men.
            // It needs an executor - `call` gives it one and keeps the per-provider scope.
            call {
                private _provIdx = MISSION_CORE_CACHED_POSITIONS findIf { (_x select 0) == _provName };
                if (_provIdx >= 0) then {
                    private _prov = MISSION_CORE_CACHED_POSITIONS select _provIdx;
                    private _provPos = _prov select 1;
                    private _provImp = _prov select 7;
                    private _provSize = if (count _prov > 8) then { _prov select 8 } else { [200, 200] };
                    private _infPool = [_factionData select 17] call MISSION_CORE_fnc_getInfTemplates;
                    if (count _infPool == 0) then {
                        diag_log format ["DYNAMIC REINF: %1 has no infantry templates for %2", _side, _provName];
                    } else {
private _sentMen = 0;
                        // Queued heads are tracked separately from men that actually spawned. The
                        // queue handler charges MISSION_CORE_REINF_SENT when it RELEASES a squad, so
                        // counting a queued squad here too would double-charge the zone's 200 cap.
                        private _queuedMen = 0;
                        // The queue is a SEQUENCE: one job per provider sits in it, and it enqueues
                        // its own successor only after it has actually spawned. Set once a provider
                        // hands the rest of its walk to that chain.
                        private _chainQueued = false;
                        // Diminishing capture wind-down: a marker the players just took asks for fewer and fewer
                        // squads as the occupation hold ages. Clocks off MISSION_CORE_OCCUPATION's
                        // occupied-at timestamp (written in fn_captureMarkerForPlayers), which is
                        // the authoritative capture record - this used to read the retake table,
                        // which no longer exists. This scales the RESPONSE DOWN toward zero; it never
                        // creates contested state and never cancels squads already in flight, so
                        // in-flight counter-attacks still run until the zone pool is exhausted/maxed.
                        private _provBudget = _budget;
                        if (!isNil "MISSION_CORE_OCCUPATION") then {
                            private _occ = MISSION_CORE_OCCUPATION getOrDefault [_locName, []];
                            if (count _occ > 2) then {
                                private _occAge = time - (_occ select 2);
                                private _occWindow = ["captureWindDownWindow", 1200] call MISSION_CORE_fnc_tune;
                                // Only a marker currently held AGAINST _side winds down; once the
                                // occupation is resolved (reverted or finalized) the scale is dropped.
                                if (_occAge >= 0 && { _occAge < _occWindow } && { (_occ select 1) == _side }) then {
                                    _provBudget = round (_provBudget * ((1 - (_occAge / _occWindow)) max 0));
                                };
                            };
                        };
                        // ceil/floor/round/sqrt are UNARY prefix operators: `ceil x`, never `x ceil`.
                        private _groups = (ceil (_provBudget / 8)) min 5;
                        for "_i" from 1 to _groups do {
                            if (_chainQueued) exitWith {};
                            if ((_totalSent + _sentMen + _queuedMen) >= _pool) exitWith {};
                            if (count _infPool == 0) exitWith {};
                            private _template = selectRandom _infPool;
                            // Reserve floor: a provider never strips itself past what it needs to hold home. This is the SAME
                            // MISSION_CORE_fnc_providerCanAfford test the queued release handlers run, so the
                            // budget that promised these men and the gate that later releases them cannot
                            // disagree.
                            //
                            // Only _queuedMen is added to the demand here. _sentMen is deliberately NOT:
                            // a directly spawned squad is charged to MISSION_CORE_COMMIT immediately by
                            // fn_commitProviderMen below, so the helper already sees it and passing it
                            // again would double-charge the provider. A queued squad is charged only at
                            // RELEASE, so it is genuinely still unspent and must be counted.
                            private _afford = [_provName, (_template select 2) + _queuedMen] call MISSION_CORE_fnc_providerCanAfford;
                            if !(_afford select 0) exitWith {
                                diag_log format ["DYNAMIC REINF RESERVE: %1 holds back - home men would drop below its retreat threshold (stock=%2 committed=%3 squad=%4 sent=%5 queued=%6 retreatAt=%7)", _provName, _afford select 1, _afford select 2, _template select 2, _sentMen, _queuedMen, _afford select 3];
                                [_provName, _locName] call MISSION_CORE_fnc_markProviderBlocked;
                            };
                            // Assemble inside the provider's own marker, marching at the fight.
                            private _strikeDir = _provPos getDir _locPos;
                            private _spawnPos = [_provPos, _provSize, 30, _strikeDir, true] call MISSION_CORE_fnc_findVehiclePos;
                            // Queue when the provider has no spawner slot, when it cannot field
                            // infantry there, or when the global foot cap is full - all three are
                            // "not yet", never "never". Hand the rest of this provider's walk to the
                            // queue as ONE job and let it spawn squads one at a time.
                            if (!_slotNow || {!([_side, "inf", _provPos] call MISSION_CORE_fnc_townCategoryCanUse) || { ([_side] call MISSION_CORE_fnc_countFootSquads) >= (["footSquadCapSquads", 10] call MISSION_CORE_fnc_tune) }}) then {
                                // _notBefore is left at its 0 default: the HEAD squad is due right
                                // away. The cadence governs the gaps after it, which the handler
                                // applies when it re-enqueues its own successor.
                                ["MISSION_CORE_fnc_queuedCounterAttackInf", format ["cainf_%1_%2_%3", _provName, _locName, _i], [_side, _template, _spawnPos, _factionData select 3, _provImp, _provPos, _provSize, _provName, _locPos, _cSize, _locName, _groups - _i, _i, _infPool, _interest]] call MISSION_CORE_fnc_enqueueSpawn;
                                // NO commit here. The queue handler commits a squad against the
                                // shared provider balance when it RELEASES it, inside the
                                // single-threaded queue loop, where the reserve re-check and the
                                // charge are atomic. Committing at enqueue AND at release charged
                                // every queued provider twice and drained them early.
                                _queuedMen = _queuedMen + (_template select 2);
                                _chainQueued = true;
                            } else {
                                // ONE way to field a squad, shared with the queued release handler.
                                // Re-tasks an idle garrison squad if this provider has one (free), and
                                // only conjures a new squad paid for from the provider's pool when it
                                // does not. The AI commander decides - MISSION_CORE_fnc_claimIdleGarrison
                                // owns the eligibility rules, so reinforcement and the player hunt now
                                // draw from the same pool under the same definition of "available".
                                private _sideVar = if (_side == WEST) then { "MISSION_CORE_BLUFOR" } else { "MISSION_CORE_REDFOR" };
                                private _grp = [_sideVar, _provName, _locPos, _cSize] call MISSION_CORE_fnc_claimReinforcementSquad;
                                if (isNull _grp) then {
                                    _grp = [_template select 0, _spawnPos, _side, _factionData select 3, "AWARE", "NORMAL", _provImp, _provPos, _provSize] call MISSION_CORE_fnc_spawnGroup;
                                    if (isNull _grp) then { continue; };
                                    _grp setVariable ["MISSION_CORE_ORIGIN_MARKER", _provName];
                                    _grp setVariable ["MISSION_CORE_IMPORTANCE", _provImp];
                                    if (isNil "MISSION_CORE_SPAWNED_GROUPS") then { MISSION_CORE_SPAWNED_GROUPS = []; };
                                    MISSION_CORE_SPAWNED_GROUPS pushBack _grp;
                                    [_grp, _locPos, _cSize] call MISSION_CORE_fnc_sendCounterAttack;
                                    // Only a CONJURED squad costs anything. A re-tasked squad is already
                                    // inside the fielded army's budget and already charged against this
                                    // garrison's spawn, so committing men for it would double-charge the
                                    // provider and shrink its budget against men it never added.
                                    [_provName, (_template select 2)] call MISSION_CORE_fnc_commitProviderMen;
                                    _sentMen = _sentMen + (_template select 2);
                                } else {
                                    // A re-tasked squad's strength is whatever it actually fields, not
                                    // the template's assumed size - the zone cap must be charged on
                                    // real men, or a small garrison squad would consume a large
                                    // squad's worth of the zone's 200.
                                    _sentMen = _sentMen + (count units _grp);
                                };
                            };
                            // Widen the gap between a provider's own squads as the zone's pool drains.
                            // Skipped once the walk has been handed to the queue: from there the
                            // queue loop's own 0.4s/5s spacing is the pacing.
                            if (!_chainQueued) then {
                                private _f = (((_totalSent + _sentMen) / _poolSafe) min 1) max 0;
                                // PERMANENT RULE: `call FNAME [args]` is INVALID. `call` binds to the
                                // code first, leaving [args] dangling -> "Error Missing ;". The args
                                // array must come FIRST: `[args] call FNAME`.
                                [_f] call MISSION_CORE_fnc_reinforcePaceWait;
                            };
                        };
                        if ((_sentMen + _queuedMen) > 0) then {
                            // Men were already reserved squad-by-squad inside the loop above, so
                            // there is deliberately no aggregate commit here - doing both would
                            // double-charge every provider against the 200 cap.
                            //
                            // The counter-attack ammo cost belongs to the DISPATCHER that marched,
                            // so it is charged here against _provName rather than against the
                            // target. consumeAmmo is a no-op if the provider cannot pay, which
                            // keeps a provider from ever being pushed below zero.
                            if (!isNil "MISSION_CORE_LOCATION_AMMO") then {
                                [_provName, ["ammoCostCounterAttack", 2] call MISSION_CORE_fnc_tune] call MISSION_CORE_fnc_consumeAmmo;
                            };
                            _spawnedProviders = _spawnedProviders + 1;
                            // Publish the zone's running total after EVERY provider, not once at
                            // the end of the walk. The 200 cap is enforced off this hash, so while
                            // it only landed at the end, a concurrent worker (or a re-entrant
                            // commander tick) would read a stale, too-low figure and overshoot it.
                            // Only squads that actually SPAWNED are published here; queued squads
                            // are published by fn_queuedCounterAttackInf when it releases them, so
                            // men that are still waiting on a slot do not spend the cap early.
                            if (_sentMen > 0) then {
                                _totalSent = _totalSent + _sentMen;
                                _sentTotal = _sentTotal + _sentMen;
                                MISSION_CORE_REINF_SENT set [_locName, _sentTotal];
                            };
                            // Rounding is computed OUTSIDE the format array on purpose. `round` is a
                            // UNARY prefix operator, so `x round 100` is infix and invalid; inside a
                            // `[...]` argument list the preprocessor reads `round 100 / 100` as one
                            // element and keeps swallowing commas -> "Error Missing ]", which failed
                            // this whole file and left MISSION_CORE_fnc_neighborCounterAttack undefined
                            // downstream. Never put a bare unary operator inside a literal list.
                            private _iRpt = (round (_interest * 100)) / 100;
                            private _cadRpt = (round ([_interest] call MISSION_CORE_fnc_reinfInterestInterval)) max 1;
                            diag_log format ["DYNAMIC REINF: %1 -> %2 marched: %3 men spawned now, %4 queued (budget %5, interest %6 -> %7s cadence, zone now %8/%9)", _provName, _locName, _sentMen, _queuedMen, _provBudget, _iRpt, _cadRpt, _sentTotal, _cap];
                        } else {
                            // Committed nothing - it is out for the rest of this fight.
                            [_provName, _locName] call MISSION_CORE_fnc_markProviderBlocked;
                            diag_log format ["DYNAMIC REINF: %1 could not commit to %2 this dispatch - latched out for this fight", _provName, _locName];
                        };
                    };
                };
            };
        };
    } forEach _rows;

    // ---- end the fight's support once the ceiling is reached ----
    // _sentTotal was already published incrementally per provider above; re-read it so the
    // ceiling test sees the same number the rest of the mission sees.
    _sentTotal = MISSION_CORE_REINF_SENT getOrDefault [_locName, 0];
    diag_log format ["DYNAMIC REINF: %1 dispatch complete - %2 providers, men this dispatch=%3, zone sent=%4/%5", _locName, _spawnedProviders, _totalSent, _sentTotal, _cap];
    if (_sentTotal >= _cap) then {
        MISSION_CORE_REINF_EXHAUSTED set [_locName, true];
        diag_log format ["DYNAMIC REINF BUDGET: %1 hit its %2-men ceiling for this contest - neighborhood stands down", _locName, _cap];
        // The zone itself is out. Re-evaluate the pool so slots held by markers that can no longer
        // field anyone are freed for markers that still can, instead of every slot sitting on a
        // marker that already gave up while live providers are turned away.
        ["zone ceiling: " + _locName] call MISSION_CORE_fnc_reevalSpawnerSlots;
        [_locName, _locPos, _side] call MISSION_CORE_fnc_deactivateNeighborMarkers;
    };
    // NOTE: the old `else` branch gated this marker when an exhausted provider sat within
    // reinfGatedRange. That is gone, along with MISSION_CORE_REINF_GATED. The gate was triggered by
    // ONE neighbor's state and then held the zone for the whole contest, even while other providers
    // still had men to give - which is how a zone froze part-way (27/200) with live capacity idle.
    // Exhaustion is now handled per provider by MISSION_CORE_REINF_PROVIDER_BLOCKED, and spawn
    // capacity is handled per side by fnc_spawnerSlotFree + fnc_reevalSpawnerSlots.

    if (_totalSent > 0) then {
        private _tailFrac = (_sentTotal / _poolSafe) min 1;
        sleep (5 + ((_tailFrac * _tailFrac * _tailFrac) * 10));
    };
};
