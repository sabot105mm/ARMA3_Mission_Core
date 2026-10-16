// REINFORCEMENT ACTIONS - every SIDE EFFECT of neighbor reinforcement lives here.
//
// The companion to fn_reinforceBudget.sqf, which is pure arithmetic. Keeping the two apart means
// the decision logic can be read, reproduced and logged without spawning a single unit, and each
// action below can be reasoned about (and changed) on its own.
//
// Companion state:
//   MISSION_CORE_REINF_SENT      men committed to a contested marker in THIS contest
//   MISSION_CORE_REINF_EXHAUSTED marker hit its ceiling and its support is done
//   MISSION_CORE_REINF_PROVIDER_BLOCKED  pair latches: [[provider, contested], true]

// Bring a marker's garrison up on the map now, instead of waiting for the proximity spawner's
// own async cycle. Used for the contested marker itself AND for each provider that is about to
// commit men, so a freshly contested marker does not answer with a half-built neighborhood.
//
// NEAR THE PLAYER ONLY. A reinforcement order can be legitimate while the fight itself is far away:
// the AI keeps contesting, dispatching and latching markers across the whole map, and force-spawning
// every garrison it touched built up whole neighborhoods the player never saw and would not have
// spawned by walking there. The proximity spawner remains the authority on what exists - this only
// brings the ordinary case forward, so it now requires a living player within reinfForceSpawnMaxDist
// of the marker CENTER. Outside that, the order is simply dropped this pass; if a player approaches
// later the spawner's own 10s cycle builds the garrison as normal, and the reinforcement flow keeps
// working against it.
MISSION_CORE_fnc_ensureMarkerActive = {
    params ["_locName"];
    if (isNil "MISSION_CORE_CACHED_POSITIONS") exitWith { false };
    if (isNil "MISSION_CORE_SPAWNED_LOCATIONS") then { MISSION_CORE_SPAWNED_LOCATIONS = createHashMap; };
    // Already on the map - nothing to force, and the distance gate must not report failure for a
    // garrison that is up.
    if (MISSION_CORE_SPAWNED_LOCATIONS getOrDefault [_locName, false]) exitWith { true };
    private _entry = (MISSION_CORE_CACHED_POSITIONS select { (_x select 0) == _locName }) param [0, []];
    if (count _entry == 0) exitWith { false };
    private _maxD = ["reinfForceSpawnMaxDist", 1000] call MISSION_CORE_fnc_tune;
    private _mPos = _entry select 1;
    if (allPlayers findIf { alive _x && { _x distance _mPos < _maxD } } == -1) exitWith { false };
    MISSION_CORE_SPAWNED_LOCATIONS set [_locName, true];
    [_entry] call MISSION_CORE_fnc_spawnLocation;
    diag_log format ["DYNAMIC REINF: %1 garrison force-spawned for reinforcement duty", _locName];
    true
};

// Latch a provider out of ONE contested marker's fight, permanently for that contest.
// Keyed per pair: the same marker can still help elsewhere afterwards.
//
// Giving up is exhaustion, so this also re-evaluates the spawn-slot pool. An exhausted provider
// used to hold its slot until the player walked away and the marker despawned, which meant a
// neighborhood of exhausted providers could sit on every slot while providers with men to spare
// were turned away. The re-eval is transition-guarded: it runs on the FIRST give-up for this pair,
// not on every subsequent sweep, so a latched provider cannot churn slots.
MISSION_CORE_fnc_markProviderBlocked = {
    params ["_provName", "_cName"];
    if (isNil "MISSION_CORE_REINF_PROVIDER_BLOCKED") then { MISSION_CORE_REINF_PROVIDER_BLOCKED = createHashMap; };
    private _pair = [_provName, _cName];
    private _wasBlocked = MISSION_CORE_REINF_PROVIDER_BLOCKED getOrDefault [_pair, false];
    MISSION_CORE_REINF_PROVIDER_BLOCKED set [_pair, true];
    if (!_wasBlocked) then {
        diag_log format ["DYNAMIC REINF: provider %1 gave up on contested %2 - re-evaluating spawn slots", _provName, _cName];
        ["provider gave up: " + _provName] call MISSION_CORE_fnc_reevalSpawnerSlots;
    };
};

// Called when a contested marker stops being contested. Releases the OPERATIONAL state only:
// the in-flight lock, the give-up latch, and the per-pair provider latches, so this zone's
// providers are available again immediately.
//
// What it deliberately does NOT reset is the zone's spent reinforcement budget
// (MISSION_CORE_REINF_SENT) or its exhaustion latch (MISSION_CORE_REINF_EXHAUSTED) - see the
// note at the write site. The zone's OWN manpower is likewise untouched: a marker sitting on 20
// men keeps exactly 20 until resupply tops it back up.
MISSION_CORE_fnc_reinforceResetZone = {
    params ["_cName"];
    if (isNil "MISSION_CORE_REINF_SENT") then { MISSION_CORE_REINF_SENT = createHashMap; };
    if (isNil "MISSION_CORE_REINF_EXHAUSTED") then { MISSION_CORE_REINF_EXHAUSTED = createHashMap; };
    if (isNil "MISSION_CORE_REINF_PROVIDER_BLOCKED") then { MISSION_CORE_REINF_PROVIDER_BLOCKED = createHashMap; };
    if (isNil "MISSION_CORE_REINF_INFLIGHT") then { MISSION_CORE_REINF_INFLIGHT = createHashMap; };

    // Release the in-flight lock as well. A worker for this marker may still be sleeping off its
    // tail wait; clearing it here stops that straggler from holding the marker hostage, and the
    // pool it was spending against is reset underneath it anyway.
    MISSION_CORE_REINF_INFLIGHT deleteAt _cName;

    // The per-contest 200-men budget is RETAINED. It used to be zeroed here, and because this
    // function runs whenever a zone goes dormant - which includes the ceiling path at
    // fn_neighborCounterAttack.sqf:413 - a zone could never accumulate: it would top out at 122,
    // the give-up sweep would clear it, and the next latch would start over from 0 with a full 200.
    // The log read "sent=122/200", then two minutes later "sent=0/200" with 9 solvent providers
    // queued behind the cap. A contest that pauses for lack of activity now keeps what it spent.
    //
    // MISSION_CORE_REINF_EXHAUSTED is retained for the same reason, and the two MUST move together:
    // clearing exhausted while leaving sent at 200 would let the zone immediately hand out another
    // full 200, which is unbounded and worse than either policy on its own.
    private _prevSent = MISSION_CORE_REINF_SENT getOrDefault [_cName, 0];
    private _wasExhausted = MISSION_CORE_REINF_EXHAUSTED getOrDefault [_cName, false];
    if (!isNil "MISSION_CORE_NEIGHBOR_GIVEUP") then { MISSION_CORE_NEIGHBOR_GIVEUP deleteAt _cName; };
    // Drop every pair latch that pointed at this marker, so its providers are available again.
    {
        private _key = _x;
        if ((_key select 1) == _cName) then { MISSION_CORE_REINF_PROVIDER_BLOCKED deleteAt _key; };
    } forEach (keys MISSION_CORE_REINF_PROVIDER_BLOCKED);

    diag_log format ["DYNAMIC REINF: %1 no longer contested - reinforcement budget RETAINED (%2/%3 men, exhausted=%4), latches cleared, manpower retained", _cName, _prevSent, call MISSION_CORE_fnc_reinfMenCap, _wasExhausted];
};

// ---- DORMANT-ZONE BUDGET BLEED-BACK ----
// A zone's spent per-contest budget (MISSION_CORE_REINF_SENT) is not hard-reset to zero any more.
// It bleeds back here while the zone is DORMANT, at a rate set by the marker's STATIC importance.
//
// This exists because the instant reset was the actual defect, not a tuning choice. The 45s
// give-up sweep (fn_despawnUncontestedNeighbors) called fn_reinforceResetZone, which zeroed the
// counter, so the SAME zone could never accumulate: it would stop at 122, fall dormant, be zeroed,
// and re-latch with a full 200. The log showed "sent=122/200" at 15:38:22 and "sent=0/200" at
// 15:41:12 with nine solvent providers queued behind the cap. A zone that also hit its ceiling had
// its MISSION_CORE_REINF_EXHAUSTED latch cleared by that same call, so the latch could never hold.
//
// Rate is in men per commander tick (the commander sleeps 8-13s):
//   importance 1  reinfDecayOrdinary  - very slow, the budget stays effectively spent
//   importance 2  reinfDecayImportant - about twice as fast
//   importance 3+ reinfDecayCritical  - fastest, so a high-value marker can be re-fought
//
// TWO PRESENCE SIGNALS, AND ONLY THOSE, KEY the bleed. Membership in MISSION_CORE_CONTESTED is NOT
// a gate: a marker whose contest latch flickered off is not "over", and one still latched is not
// automatically held. (The only remaining use of the latch is the cosmetic 45s flicker grace below.)
//   1. ASSAULT PRESENCE - the existing give-up-sweep test: a RELEASED assault group with a living man
//      on the marker (the _heldNow set built below). While it holds, the fight is not over. Once its
//      men are DEAD / KIA it is gone. Re-arms the quiet pause while it holds.
//   2. PLAYER PRESENCE - a living player within reinfDecayPlayerRadius of the marker center. Re-arms
//      the same quiet pause.
// The zone bleeds ONLY when BOTH are gone, and only after the quiet pause below:
// QUIET PAUSE - decay starts only once the marker has had NEITHER a held assault group NOR a living
// player near it for reinfDecayPauseSeconds (5 minutes). Any assault that returns, or any player who
// comes back, re-stamps the pause and stops the bleed from exactly where it left it.
MISSION_CORE_fnc_reinforceDecayBudget = {
    if (isNil "MISSION_CORE_REINF_SENT") exitWith {};
    private _keys = keys MISSION_CORE_REINF_SENT;
    if (count _keys == 0) exitWith {};
    if (isNil "MISSION_CORE_REINF_EXHAUSTED") then { MISSION_CORE_REINF_EXHAUSTED = createHashMap; };
    if (isNil "MISSION_CORE_CONTESTED") then { MISSION_CORE_CONTESTED = createHashMap; };
    if (isNil "MISSION_CORE_CONTESTED_LAST") then { MISSION_CORE_CONTESTED_LAST = createHashMap; };
    if (isNil "MISSION_CORE_REINF_DECAY_ASSAULT_LAST") then { MISSION_CORE_REINF_DECAY_ASSAULT_LAST = createHashMap; };

    private _grace = ["contestedGraceSeconds", 45] call MISSION_CORE_fnc_tune;
    private _rateOrdinary = ["reinfDecayOrdinary", 1] call MISSION_CORE_fnc_tune;
    private _rateImportant = ["reinfDecayImportant", 2] call MISSION_CORE_fnc_tune;
    private _rateCritical = ["reinfDecayCritical", 6] call MISSION_CORE_fnc_tune;
    private _cap = call MISSION_CORE_fnc_reinfMenCap;
    private _pause = ["reinfDecayPauseSeconds", 300] call MISSION_CORE_fnc_tune;

    // ONE sweep over both assault registers for the whole call, not a per-marker walk: build the
    // set of marker names that currently have a RELEASED assault group with a living man within
    // assaultHoldContestedRadius of the marker center - the same presence test the give-up sweep
    // uses (fn_markerHeldByLiveAssault), batched here so ~N decay keys cost one register pass.
    // A group whose men are all DEAD / KIA is no longer present, so this is also the "assault is
    // gone" signal the bleed waits on.
    private _heldNow = createHashMap;
    if (!isNil "MISSION_CORE_CACHED_POSITIONS") then {
        private _holdR = ["assaultHoldContestedRadius", 800] call MISSION_CORE_fnc_tune;
        {
            private _grpVar = _x;
            if (isNil _grpVar) then { continue; };
            private _tracked = missionNamespace getVariable [_grpVar, objNull];
            if !(_tracked isEqualType createHashMap) then { continue; };
            {
                private _gKey = _x;
                private _adata = _tracked getOrDefault [_gKey, []];
                if ((_adata isEqualType [])) then {
                    if (count _adata < 7) then { continue; };
                    // Only a RELEASED (advancing) group contests - staging / hold / wiped groups do not.
                    if ((_adata select 5) != "active") then { continue; };
                    private _heldName = _adata select 1;
                    if (_heldNow getOrDefault [_heldName, false]) then { continue; };
                    private _entry = (MISSION_CORE_CACHED_POSITIONS select { (_x select 0) == _heldName }) param [0, []];
                    if (count _entry == 0) then { continue; };
                    private _heldPos = _entry select 1;
                    private _heldOwner = _entry select 4;
                    private _attackerSide = _adata select 4;
                    if ((_heldOwner getFriend _attackerSide) >= 0.6) then { continue; };
                    private _ag = _adata select 0;
                    if (isNull _ag) then { continue; };
                    if ((units _ag findIf { !isNull _x && { alive _x } && { (_x distance2D _heldPos) < _holdR } }) == -1) then { continue; };
                    _heldNow set [_heldName, true];
                };
            } forEach (keys _tracked);
        } forEach ["MISSION_CORE_ATTACK_GROUPS", "MISSION_CORE_ATTACK_GROUPS_RELAY"];
    };

    {
        private _cName = _x;
        private _sent = MISSION_CORE_REINF_SENT getOrDefault [_cName, 0];
        if (_sent <= 0) then {
            MISSION_CORE_REINF_SENT deleteAt _cName;
            continue;
        };
        // NO CONTESTED GATE. The spend predicate is the fight itself, not the contest latch: a
        // marker whose latch flickered off (player stepped into a different marker, garrison
        // momentarily silent) must NOT be treated as over. The bleed is keyed off the two REAL
        // presence signals below only.
        // ASSAULT PRESENCE - a released assault group with a living man on the marker (the
        // _heldNow set built above). While it holds, the fight is not over and the budget stays
        // hard; the clock is re-armed so the bleed waits for the group to be DEAD / KIA.
        if (_heldNow getOrDefault [_cName, false]) then {
            MISSION_CORE_REINF_DECAY_ASSAULT_LAST set [_cName, time];
            continue;
        };
        // PLAYER PRESENCE - the SECOND "the fight is still on" signal, a peer of the assault check
        // above. A living player near the marker CENTER re-arms the SAME quiet clock, so the bleed
        // only begins after BOTH the assault groups are dead AND no player is left around for
        // reinfDecayPauseSeconds. Both terms matter: dropping either one is what let a marker that
        // had merely gone quiet bleed its spent budget back under the fight.
        if (!isNil "MISSION_CORE_CACHED_POSITIONS") then {
            private _pEntry = (MISSION_CORE_CACHED_POSITIONS select { (_x select 0) == _cName }) param [0, []];
            if (count _pEntry > 0) then {
                private _pPos = _pEntry select 1;
                private _pR = ["reinfDecayPlayerRadius", 800] call MISSION_CORE_fnc_tune;
                if (allPlayers findIf { alive _x && { _x distance2D _pPos < _pR } } != -1) then {
                    MISSION_CORE_REINF_DECAY_ASSAULT_LAST set [_cName, time];
                    continue;
                };
            };
        };
        // 5-MINUTE QUIET PAUSE. Decay starts only once the marker has had NEITHER a released assault
        // group NOR a living player near it for reinfDecayPauseSeconds. First sighting starts the
        // window now; any assault OR player that returns on a later tick re-stamps _lastNear above,
        // so the bleed stops and the pause runs again from then. (The contestedGraceSeconds check
        // that follows is the player-driven flicker guard; the pause is strictly longer, so it is the
        // one that actually bites.)
        private _lastNear = MISSION_CORE_REINF_DECAY_ASSAULT_LAST getOrDefault [_cName, -1];
        if (_lastNear < 0) then {
            MISSION_CORE_REINF_DECAY_ASSAULT_LAST set [_cName, time];
            continue;
        };
        if (time - _lastNear < _pause) then { continue; };
        // Same grace window as the give-up sweep: not quiet for long enough yet, so a marker
        // flickering between contested and dormant never bleeds.
        private _last = MISSION_CORE_CONTESTED_LAST getOrDefault [_cName, -1e10];
        if (_last > 0 && { time - _last < _grace }) then { continue; };

        // Static importance, not the current tier/scar verdict: an ordinary outpost that happens to
        // be fought hard should still bleed slowest. Falls back to the slowest rate if the position
        // cache is not up yet - bleeding slowly is the conservative failure here.
        private _imp = if (!isNil "MISSION_CORE_CACHED_POSITIONS") then { [_cName] call MISSION_CORE_fnc_getCachedImportance } else { 1 };
        private _rate = _rateCritical;
        if (_imp <= 1) then { _rate = _rateOrdinary; };
        if (_imp == 2) then { _rate = _rateImportant; };

        private _now = 0;
        if (_sent > _rate) then { _now = _sent - _rate; };
        if (_now > 0) then {
            MISSION_CORE_REINF_SENT set [_cName, _now];
        } else {
            MISSION_CORE_REINF_SENT deleteAt _cName;
        };

        // Once the zone is back under its ceiling it may fight again. This is the ONLY place the
        // exhaustion latch is lifted now that fn_reinforceResetZone no longer clears it - if it were
        // never lifted, a zone that spent 200 could never defend again for the rest of the mission.
        if ((_now > 0) && { _now < _cap } && { MISSION_CORE_REINF_EXHAUSTED getOrDefault [_cName, false] }) then {
            MISSION_CORE_REINF_EXHAUSTED deleteAt _cName;
            diag_log format ["DYNAMIC REINF BUDGET: %1 exhaustion lifted - bled back to %2/%3 (importance %4)", _cName, _now, _cap, _imp];
        };
    } forEach _keys;
};

// Spend one squad's worth of men against a marker. Debits the provider's commitment 1:1 (troops
// are never subsidized) and returns the men actually committed, or 0 if the squad could not be
// fielded for any reason - the caller keeps looping while this keeps returning men.
MISSION_CORE_fnc_commitProviderMen = {
    params ["_provName", "_men"];
    if (isNil "MISSION_CORE_COMMIT") then { MISSION_CORE_COMMIT = createHashMap; };
    MISSION_CORE_COMMIT set [_provName, (MISSION_CORE_COMMIT getOrDefault [_provName, 0]) + _men];
    _men
};

// Place the marker-scaled counter-attack tank order. Bypasses the factory/contested gating by
// using the assault-order path, and is bounded by the zone's cumulative tank budget.
MISSION_CORE_fnc_placeCounterAttackTanks = {
    params ["_side", "_cName", "_cPos", "_tier", "_importance"];

    if (isNil "MISSION_CORE_REINF_TANK_BUDGET") then { MISSION_CORE_REINF_TANK_BUDGET = createHashMap; };
    private _maxTanks = ([3, 2, 1, 0] select ((_tier max 0) min 3));
    private _tankBudget = round (([5, 4, 3, 2] select ((_tier max 0) min 3)) * (1 + (_importance - 1) * 0.25));
    private _spent = MISSION_CORE_REINF_TANK_BUDGET getOrDefault [_cName, 0];
    private _thisEvent = (_maxTanks min (_tankBudget - _spent)) max 0;
    if (_thisEvent <= 0) exitWith { 0 };
    MISSION_CORE_REINF_TANK_BUDGET set [_cName, _spent + _thisEvent];
    [_side, _cName, _cPos, _thisEvent, true] call MISSION_CORE_fnc_orderTank;
    diag_log format ["DYNAMIC REINF: counter-attack tank order placed for %1 (n=%2, budget %3/%4)", _cName, _thisEvent, _spent + _thisEvent, _tankBudget];
    _thisEvent
};

// Diminishing-returns pacing between squads and providers. A fresh pool dispatches quickly and
// visibly loses steam as it drains, so a long reinforcement wave reads as an effort rather than a
// firehose. _fraction is how far the zone's pool is spent (0 = fresh, 1 = dry).
MISSION_CORE_fnc_reinforcePaceWait = {
    params [["_fraction", 0]];
    private _f = _fraction max 0;
    sleep (0.2 + ((_f * _f * _f) * 4.8));
};

// INTEREST CADENCE - how long a provider waits between its own counter-attack squads.
//
// The BUDGET curve already answers "how much does this neighbour care about this zone?":
//     _interest = _cVal * _asset * _taper
//       _cVal   2.0 if the contested zone is tier 0/1 (an HQ/port/factory lifeline), else 1.0
//       _asset  up to 2.0 when the PROVIDER sits within 800m of a tier 0 marker, 1.35 for tier 1
//       _taper  1.0 within the near band, decaying linearly to 0 at neighborRange
// That product is already computed per provider by fn_reinforceBudget and logged in the provider
// rows, so this does not invent a second opinion of importance - it reuses the exact same terms.
//
// The BUDGET decided how many men. This decides how FAST they walk out, which used to be a flat
// 30s for every provider on the map. An urgent fight (zone is a lifeline, provider beside an HQ,
// close by) now releases a squad every few seconds; a distant casual one is slower than the old
// flat 30s, so the spread is real rather than everything being 30s.
//
// Pure function: interest in, seconds out. Owns the whole mapping so it stays tunable in one place.
MISSION_CORE_fnc_reinfInterestInterval = {
    params [["_interest", 0]];
    private _urgent = ["reinfQueueTickUrgent", 4] call MISSION_CORE_fnc_tune;
    private _casual = ["reinfQueueTickCasual", 45] call MISSION_CORE_fnc_tune;
    private _maxInterest = ["reinfQueueInterestMax", 4.0] call MISSION_CORE_fnc_tune;
    if (!(_interest isEqualType 0)) exitWith { _urgent };
    if (!(_maxInterest isEqualType 0) || { _maxInterest <= 0 }) exitWith { _urgent };
    // max/min are BINARY: ((x max 0) min 1). Never `max x 0` and never `max [x, 0]`.
    private _u = ((_interest / _maxInterest) max 0) min 1;
    private _secs = _casual - ((_casual - _urgent) * _u);
    (_secs max 1) min 3600
};

// Shared release gate for a queued counter-attack. Returns true when the target still has a live
// fight worth reinforcing: EITHER a living player OR any currently contested marker sits within
// counterAttackSpawnGateRadius of it.
//
// The previous rule required a player within 2000m. That silently discarded valid orders whenever
// two AI squads were fighting with no player nearby - the order was placed and logged, then the
// queued spawn dropped it, so the player watching the fight saw reinforcements never arrive. A
// contested marker is proof there is a real battle at that position; player presence is not
// required for the fight to matter.
MISSION_CORE_fnc_counterAttackWorthReleasing = {
    params ["_targetPos"];
    if (isNil "_targetPos" || { _targetPos isEqualTo [] }) exitWith { false };
    private _r = ["counterAttackSpawnGateRadius", 2000] call MISSION_CORE_fnc_tune;

    // Any living player near the target.
    if (allPlayers findIf { alive _x && { _x distance _targetPos < _r } } != -1) exitWith { true };

    // Otherwise: any currently contested marker near the target. MISSION_CORE_CONTESTED is a
    // name-keyed map maintained by fn_isMarkerContested, and MISSION_CORE_CACHED_POSITIONS row
    // layout is [name, pos, ...], so resolve name -> position through it rather than calling
    // fn_getContestedMarkers (which is a heavy per-tick sweep and would recurse from here).
    if (isNil "MISSION_CORE_CONTESTED" || { count MISSION_CORE_CONTESTED == 0 }) exitWith { false };
    if (isNil "MISSION_CORE_CACHED_POSITIONS") exitWith { false };
    private _hit = MISSION_CORE_CACHED_POSITIONS findIf {
        (_x select 0) in MISSION_CORE_CONTESTED && { (_x select 1) distance _targetPos < _r }
    };
    _hit != -1
};

// Keep-alive check for a marker about to be torn down: a RELEASED (active) assault group still
// engaging NEAR the marker means the fight is not over just because the defending player died.
// Returns true when such a group exists, so the caller holds the marker open instead of releasing
// its reinforcement neighborhood.
//
// The presence test here is deliberately a generous radius, NOT the strict 1.2x-ellipse used by
// fn_getContestedMarkers. That ellipse is right for zone bookkeeping (it keeps a group still back
// at its staging marker from freezing a target from across the map) but far too tight to decide
// "the fight is over" - a squad suppressing from just past the edge, or holding a treeline on the
// marker's boundary, is dropped by it. Because the group's assignment already names this exact
// marker as its target, a man within assaultHoldContestedRadius of the marker center is genuinely
// at the objective.
MISSION_CORE_fnc_markerHeldByLiveAssault = {
    params ["_mName", "_mPos", "_side"];
    private _r = ["assaultHoldContestedRadius", 800] call MISSION_CORE_fnc_tune;
    private _held = false;
    {
        if (_held) then { break; };
        private _grpVar = _x;
        if (isNil _grpVar) then { continue; };
        private _tracked = missionNamespace getVariable [_grpVar, objNull];
        if !(_tracked isEqualType createHashMap) then { continue; };
        {
            if (_held) then { break; };
            private _adata = _y;
            if (count _adata < 7) then { continue; };
            // Only a RELEASED (advancing) group contests - staging / hold / wiped groups do not.
            if ((_adata select 5) != "active") then { continue; };
            if ((_adata select 1) != _mName) then { continue; };
            private _attackerSide = _adata select 4;
            if ((_side getFriend _attackerSide) >= 0.6) then { continue; };
            private _ag = _adata select 0;
            if (isNull _ag) then { continue; };
            if ((units _ag findIf { !isNull _x && { alive _x } && { (_x distance2D _mPos) < _r } }) == -1) then { continue; };
            _held = true;
        } forEach _tracked;
    } forEach ["MISSION_CORE_ATTACK_GROUPS", "MISSION_CORE_ATTACK_GROUPS_RELAY"];
    _held
};
