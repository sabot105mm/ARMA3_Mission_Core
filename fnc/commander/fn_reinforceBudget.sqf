// REINFORCEMENT BUDGET - PURE LOGIC ONLY.
//
// This file computes how many men each neighbor marker is willing to commit to ONE contested
// marker. It performs NO side effects: no spawn, no sleep, no ammo spend, no map writes. Every
// callable here takes marker records and current state and RETURNS numbers, so the whole
// per-provider decision table can be reproduced from the RPT alone.
//
// MODEL (per the design rules):
//   - Every contested marker has its OWN pool. There is no shared/global pool and no zone
//     handoff: a contested marker is evaluated entirely on its own.
//   - Each NEIGHBOR decides for itself how important that contested marker is to it, and
//     contributes its own budget. The marker's pool is the SUM of those independent decisions -
//     it is derived output, never an input.
//   - A neighbor may help several contested markers at once; each pairing is budgeted
//     independently and tracked per (provider, contested) pair.
//   - A provider that runs out is out for the REST OF THAT contested marker's fight and is not
//     replaced by another provider. It stays available to every other marker.
//
// usage - MISSION_CORE_fnc_providerBudget:
//   _prov   CACHED_POSITIONS entry for the contributing (provider) marker
//   _cLoc  CACHED_POSITIONS entry for the contested marker it would help
//   _side  the contested marker's side
// returns: [_budget, _usable, _cVal, _asset, _taper, _blockedReason]
//   _budget        men this provider may still commit to this marker (>= 0)
//   _usable        men it has above its own reserve floor, counting BOTH its un-fielded stock and
//                  the men it has already committed to marching (see fn_providerCanAfford)
//   _cVal          contested-value multiplier (lifelines are worth more)
//   _asset         asset-proximity multiplier from the nearest tier 0/1 marker
//   _taper         distance taper from provider to contested marker
//   _blockedReason "" when it may contribute, else a short reason for the log
MISSION_CORE_fnc_providerBudget = {
    params ["_prov", "_cLoc", "_side"];

    private _provName = _prov select 0;
    private _provPos = _prov select 1;
    private _provImp = _prov select 7;
    private _cName = _cLoc select 0;
    private _cPos = _cLoc select 1;

    // ---- 1. USABLE: real manpower above this marker's OWN reserve floor ----
    // The floor is the base is MISSION_CORE_LOCATION_SUPPLY, not the template capacity: that is
    // the wallet fn_spawnLocation / fn_replenishLoop actually debit, so a provider that looks
    // solvent against its capacity can still be broke in reality.
    if (isNil "MISSION_CORE_LOCATION_SUPPLY") then { MISSION_CORE_LOCATION_SUPPLY = createHashMap; };
    if (isNil "MISSION_CORE_COMMIT") then { MISSION_CORE_COMMIT = createHashMap; };
    private _cap = [_provImp] call MISSION_CORE_fnc_markerCapacity;
    private _det = [_prov] call MISSION_CORE_fnc_getMarkerDetermination;
    // getMarkerDetermination returns [tier, garrisonHoldFrac, neighborBudgetFrac]; select 1 is the
    // fraction of its OWN manpower this marker KEEPS fighting with before retreating.
    private _retreatAt = round (_cap * (_det select 1));
    private _stock = MISSION_CORE_LOCATION_SUPPLY getOrDefault [_provName, 0];
    // Men already committed to marching are SPENT men: they are not in _stock and are never
    // refunded. Charging them here is what makes this budget honest, and it is what makes a
    // FLICKERING contested marker re-evaluate its neighbours. When a zone leaves contention and
    // comes back, _stock is untouched by marching and MISSION_CORE_fnc_reinforceResetZone has just
    // cleared this provider's [provider, contested] pair latch - so without _committed every
    // neighbour would advertise byte-identical numbers to the wave it already paid for. COMMIT is
    // deliberately NOT reset there, so the second wave is genuinely smaller, and a provider that
    // spent itself on the first reads zero on the second.
    private _committed = MISSION_CORE_COMMIT getOrDefault [_provName, 0];
    private _usable = (_stock - _committed) - _retreatAt;

    if (_usable <= 0) exitWith {
        [0, 0, 1, 1, 1, format ["at reserve floor (stock=%1 committed=%2 retreatAt=%3)", _stock, _committed, _retreatAt]]
    };

    // ---- 1b. AMMO: the DISPATCHER's own magazine, never the target's ----
    // The contested marker is the RECIPIENT of this help, so its ammo is never consulted here.
    // It already has its own garrison fighting, and "it is dry" says nothing about whether its
    // neighbors can march. Gating the whole dispatch on the TARGET's ammo meant a dry marker denied
    // reinforcement to itself: every provider had men, the pool was full at the cap, and the zone
    // still received nothing - it had nothing left to shoot with, so it refused the help.
    //
    // A provider at ZERO ammo cannot march at all (nothing to sustain the move or the fight after
    // it). Below that it still marches, just on a reduced commitment - the same ladder
    // MISSION_CORE_fnc_ammoAggressionMult uses.
    private _ammoFrac = [_provName] call MISSION_CORE_fnc_getAmmoFraction;
    if (_ammoFrac <= 0) exitWith {
        [0, _usable, 1, 1, 1, "out of ammo - cannot march"]
    };

    // ---- 2 + 3. CONTESTED VALUE x ASSET PROXIMITY ----
    // Both terms now come from the one shared derivation (fn_markerWorth.sqf), which is where the
    // explanatory comments about tier values, nearest-only grading and non-stacking live.
    //
    // THIS IS A MOVE, NOT A REWRITE. _cVal is still the CONTESTED marker's own tier value and
    // _asset is still the PROVIDER's surroundings - which is exactly why the call hands _prov over
    // as _selfLoc and _cLoc over as _subjectLoc rather than passing one marker. The arithmetic and
    // the returned numbers are unchanged, so every provider budget on the map is identical to what
    // it was before the extraction. Do not "simplify" this into a single-argument call.
    private _worthParts = ([_prov, _cLoc, _side] call MISSION_CORE_fnc_markerWorth);
    private _cVal = _worthParts select 0;
    private _asset = _worthParts select 1;

    // ---- 4. DISTANCE TAPER: proximity to the fight ----
    // Replaces the old "3 closest providers win a slot" lottery. A provider is at full weight
    // inside the near band and decays linearly to zero at the edge of neighborRange, so distant
    // providers drop out on their own merit instead of being skipped by a spawn counter.
    private _range = ["neighborRange", 4000] call MISSION_CORE_fnc_tune;
    private _taperFrac = ["neighborTaperFrac", 0.5] call MISSION_CORE_fnc_tune;
    private _dist = _provPos distance2D _cPos;
    private _nearBand = _range * _taperFrac;
    // max/min are BINARY operators in SQF, spelled `a max b` - there is NO callable or array form.
    // Both `max 0.001 x` and `max [x, 0.001]` are parse errors. A parse error fails this whole file
    // at preprocess time, which leaves every callable defined in it undefined downstream.
    private _span = (_range - _nearBand) max 0.001;
    private _taper = if (_dist <= _nearBand) then { 1.0 } else { 1 - ((_dist - _nearBand) / _span) };
    _taper = (_taper max 0) min 1;

    // A thin magazine commits fewer men (mirrors MISSION_CORE_fnc_ammoAggressionMult).
    private _ammoFactor = if (_ammoFrac < 0.3) then { 0.3 } else { if (_ammoFrac < 0.7) then { 0.5 } else { 1.0 } };
    private _budget = round (_usable * _cVal * _asset * _taper * _ammoFactor);

    // ---- 5. PAIR LATCH: a spent provider stays spent for THIS marker ----
    // Keyed [provider, contested] so one provider can be finished off against one marker while
    // still contributing freely to another.
    if (isNil "MISSION_CORE_REINF_PROVIDER_BLOCKED") then { MISSION_CORE_REINF_PROVIDER_BLOCKED = createHashMap; };
    private _blocked = MISSION_CORE_REINF_PROVIDER_BLOCKED getOrDefault [[_provName, _cName], false];
    if (_blocked) exitWith {
        [0, _usable, _cVal, _asset, _taper, "already committed its limit to this marker"]
    };

    [_budget, _usable, _cVal, _asset, _taper, ""]
};

// usage - MISSION_CORE_fnc_zonePoolBudget:
//   _cLoc      CACHED_POSITIONS entry for the contested marker
//   _neighbors its chosen neighbors (already filtered + distance sorted)
//   _side      the contested marker's side
//   _sentMen   men already committed to this marker in this contest
// returns: [_remainingPool, _rows]
//   _remainingPool  total men still available to this marker (capped by reinfMenCapPerMarker)
//   _rows           one row per provider for the diagnostic log:
//                   [_providerName, _budget, _usable, _cVal, _asset, _taper, _reason]
MISSION_CORE_fnc_zonePoolBudget = {
    params ["_cLoc", "_neighbors", "_side", "_sentMen"];

    private _cName = _cLoc select 0;
    private _cap = ["reinfMenCapPerMarker", 200] call MISSION_CORE_fnc_tune;
    private _remaining = _cap - _sentMen;
    if (_remaining < 0) then { _remaining = 0; };

    private _rows = [];
    private _total = 0;
    {
        private _b = [_x, _cLoc, _side] call MISSION_CORE_fnc_providerBudget;
        private _budget = _b select 0;
        private _usable = _b select 1;
        private _cVal = _b select 2;
        private _asset = _b select 3;
        private _taper = _b select 4;
        private _reason = _b select 5;
        // A provider can never promise more than the marker has left to give.
        private _effective = _budget min _remaining;
        _rows pushBack [_x select 0, _budget, _usable, _cVal, _asset, _taper, _reason, _effective];
        _total = _total + _effective;
    } forEach _neighbors;

    // The marker's pool is the sum of its providers' independent decisions, never more than the
    // per-marker ceiling.
    [_total min _remaining, _rows]
};

// usage - MISSION_CORE_fnc_reinfMenCap:
//   Hard ceiling on men a single contested marker may be reinforced with per contest.
MISSION_CORE_fnc_reinfMenCap = {
    ["reinfMenCapPerMarker", 200] call MISSION_CORE_fnc_tune
};
