// PROVIDER AFFORDABILITY - one definition of "can this provider still afford to ship N men".
//
// This exists because the same question was being asked in four places with two different answers.
// fn_neighborCounterAttack's dispatch walk tested MISSION_CORE_LOCATION_SUPPLY as the base, while
// the three queued release handlers tested MISSION_CORE_fnc_markerCapacity as the base - and all
// three release handlers ALSO inverted the floor, reading (1 - holdFrac) where getMarkerDetermination
// returns holdFrac directly. A tier-3 provider whose garrison holds 85% therefore had a dispatch
// floor of cap*0.85 and a release floor of cap*0.15: the budget could promise men the release gate
// then let through, and men the dispatch refused were releasable after the fact. One helper, called
// by all four, is the only way that stays fixed.
//
// THE TWO LEDGERS (they are disjoint sets of men, so subtracting both is not double-counting):
//   _stock      MISSION_CORE_LOCATION_SUPPLY - men the marker has NOT yet fielded. Drained by its
//               own garrison (fn_spawnLocation), its replenish squads (fn_replenishLoop), conjured
//               player-hunt squads, convoys, and armour reinforcement.
//   _committed  MISSION_CORE_COMMIT - men it has ALREADY committed to marching elsewhere. Charged by
//               the queued counter-attack / reinforce handlers when they RELEASE, never refunded,
//               and crucially NEVER cleared by MISSION_CORE_fnc_reinforceResetZone.
//
// _committed surviving the zone reset is what makes a flickering contested marker genuinely
// re-evaluate its neighbours: when the zone drops out of contention and comes back, _stock is
// unchanged and the [provider, contested] pair latch has just been cleared, so without _committed
// every neighbour would advertise exactly the same budget it advertised the first time. With it,
// each neighbour's re-evaluated budget is smaller by the men it already has marching, and a
// provider that spent itself on the first wave reads zero on the second.
//
// usage - MISSION_CORE_fnc_providerCanAfford:
//   _provName  the PROVIDER marker's name
//   _men       how many more men it would like to commit
// returns: [_affordable, _stock, _committed, _retreatAt]
MISSION_CORE_fnc_providerCanAfford = {
    params ["_provName", "_men"];
    if (isNil "MISSION_CORE_LOCATION_SUPPLY") then { MISSION_CORE_LOCATION_SUPPLY = createHashMap; };
    if (isNil "MISSION_CORE_COMMIT") then { MISSION_CORE_COMMIT = createHashMap; };
    if (isNil "MISSION_CORE_CACHED_POSITIONS") then { MISSION_CORE_CACHED_POSITIONS = []; };

    private _rows = MISSION_CORE_CACHED_POSITIONS select { (_x select 0) == _provName };
    private _row = if (count _rows > 0) then { _rows select 0 } else { [] };

    // A provider absent from the cache cannot be costed, so it is given no floor rather than a
    // guessed one - denying here would silently deadlock its queue jobs. In practice every provider
    // reaches this through MISSION_CORE_CACHED_POSITIONS, so the empty row is a diagnostic case, not
    // a normal one; _stock will read 0 in it, which is visible in the log.
    private _det = [3, 0.85, 0.2];
    private _retreatAt = 0;
    if (count _row > 0) then {
        _det = [_row] call MISSION_CORE_fnc_getMarkerDetermination;
        // getMarkerDetermination returns [tier, garrisonHoldFrac, neighborBudgetFrac]. select 1 is
        // the fraction of its OWN manpower the marker KEEPS fighting with before it retreats - the
        // floor to protect. NOT its complement; complementing this was the bug.
        _retreatAt = round (([(_row select 7)] call MISSION_CORE_fnc_markerCapacity) * (_det select 1));
    };

    private _stock = MISSION_CORE_LOCATION_SUPPLY getOrDefault [_provName, 0];
    private _committed = MISSION_CORE_COMMIT getOrDefault [_provName, 0];
    private _affordable = ((_stock - _committed) - _men) >= _retreatAt;
    [_affordable, _stock, _committed, _retreatAt]
};