// ---------------------------------------------------------------------
// MISSION-NAMESPACE GLOBALS - DECLARED HERE, AT FILE SCOPE, ON PURPOSE.
//
// An assignment to an UNDECLARED name inside a function creates a FUNCTION-LOCAL, not a
// mission global: `MISSION_CORE_ABSTRACT_LEGS = []` written inside fnc_abstractLegStore
// would build a local array that dies with the call, and every pushBack would land in
// limbo. These three names are therefore initialised at the top level of this file (which
// fnc/fn_init.sqf `call compile preprocessFileLineNumbers`, so top level == mission
// namespace). This is the same pattern the port system uses for its lazy isNil-guards.
// Do NOT move these three lines inside a function.
//
// MISSION_CORE_ABSTRACT_LEGS     the leg store: rows, see the layout below
// MISSION_CORE_ABSTRACT_LEG_ID   monotonic id counter, so rows are found by id not index
// MISSION_CORE_ABSTRACT_HANDOFF re-entrancy flag, set only across a handoff callback
MISSION_CORE_ABSTRACT_LEGS = [];
MISSION_CORE_ABSTRACT_LEG_ID = 0;
MISSION_CORE_ABSTRACT_HANDOFF = false;

// ---------------------------------------------------------------------
// ABSTRACT TROOP LEGS
// ---------------------------------------------------------------------
//
// WHAT THIS IS: reinforcement / counter-attack foot squads travelling between markers
// that are 2000m+ apart are represented as an ABSTRACT LEG - a cargo-like record with no
// units in the world - and are only turned into real squads once a player is near enough
// to see them, or once they reach the final approach. Short hops are unaffected and keep
// dispatching exactly as before.
//
// THE THRESHOLD IS >= 2000m, measured between the two markers' positions in
// MISSION_CORE_CACHED_POSITIONS - the same pair of points routePlan uses. Under the
// threshold nothing here runs.
//
// SCOPE: the 3 troop dispatch paths ONLY - requestReinforcement, neighborCounterAttack
// (conjured branch) and queuedCounterAttackInf. No supply convoy, tank column, ammo
// shipment or manpower shipment is ever abstracted, and none of their economics change.
// This file has nothing to do with them.
//
// NOT IN SCOPE, DELIBERATELY:
//   - fn_replenishMarker / fn_queuedReplenish. Replenishment is the garrison topping up
//     its OWN men, not a neighbouring force marching to a fight, so it dispatches
//     concretely like any other garrison spawn.
//   - The assault wave. fn_aiAssaultLoop resolves its wave on a fixed 300s clock, so a
//     squad that does not exist cannot be counted as arrived and a late-materialised leg
//     would break the wave's own accounting.
//   - Staging. Release monitors wait on real groups, so an abstract squad would hang them.
//
// IRREVERSIBLE BY DESIGN. Once a leg exists it runs to completion. It is NOT
// cancelled and NOT refunded when:
//   - the destination marker changes owner,
//   - the destination stops being contested (MISSION_CORE_CONTESTED),
//   - the reinforcement zone/budget resets or is exhausted,
//   - the provider runs dry, is captured, or is pruned from the marker cache,
//   - the spawn position or the source garrison changes.
// This is deliberate. A leg that could be called off would have to either refund a pool
// or silently delete troops. Manpower and ammo are charged by the MATERIALIZE callback,
// not at dispatch, so a leg that never spawns costs the provider nothing at all.
// The destination POSITION is frozen into the row at dispatch for the same reason: a
// leg must not be re-resolved against live marker state that may have changed or
// disappeared underneath it.
//
// The only exit is SUCCESSFUL HANDOFF. A leg that reaches _frac >= 1 hands off
// anyway rather than completing into nothing - there is deliberately NO
// "arrived but spawned nothing" branch, because that is exactly the stranding bug
// this module exists to prevent.
//
// NOT RECON-VISIBLE. Abstract legs are deliberately absent from fn_recon.sqf.
// Once materialised the squad is an ordinary group and is killable as normal; only
// the abstract phase is untouchable.
//
// ROW LAYOUT (fixed indices - do not reorder, callers read them by number):
//   0  kind         string tag for the log
//   1  fromName     source marker name
//   2  toName       destination marker name ("" if none - e.g. a live player pos)
//   3  toPos        FROZEN destination position
//   4  toSize       destination marker size, for the handoff script
//   5  payload      caller-defined (templates, counts, importance, side)
//   6  path         stored road polyline (never re-planned)
//   7  cum          cumulative arc lengths for _path
//   8  travel       total travel seconds
//   9  depart       time the leg left
//   10 frac         0..1 progress
//   11 state        "abstract" (no units) | "rolling" (squad exists, driving)
//   12 grp          the group once materialised, else grpNull
//   13 handoff      code: params ["_grp","_row"] - finishes the job on arrival
//   14 materialize  code: params ["_row","_frac"] - returns the group it spawned
//   15 id           unique id - rows are looked up BY ID, never by array index

// Return the leg array, creating it on first use.
MISSION_CORE_fnc_abstractLegStore = {
    params [];
    if (isNil "MISSION_CORE_ABSTRACT_LEGS") then { MISSION_CORE_ABSTRACT_LEGS = []; };
    if (isNil "MISSION_CORE_ABSTRACT_LEG_ID") then { MISSION_CORE_ABSTRACT_LEG_ID = 0; };
    if (isNil "MISSION_CORE_ABSTRACT_HANDOFF") then { MISSION_CORE_ABSTRACT_HANDOFF = false; };
    MISSION_CORE_ABSTRACT_LEGS
};

// Remove the row with this id. Safe to call with an id that is already gone.
// Returns true if a row was actually removed.
MISSION_CORE_fnc_abstractLegRemove = {
    params ["_id"];
    // exitWith, not `then { false }`: a bare false in a then block is computed and
    // discarded, so execution fell through to `_legs set [-1, []]` - which silently
    // writes to the LAST element and blanks a live leg.
    if (isNil "MISSION_CORE_ABSTRACT_LEGS") exitWith { false };
    private _legs = MISSION_CORE_ABSTRACT_LEGS;
    private _idx = _legs findIf { (_x select 15) == _id };
    if (_idx < 0) exitWith { false };
    _legs set [_idx, []];
    // Rebuild rather than deleteAt: this is called a handful of times a minute, and
    // the compaction keeps the array dense so later scans never see a hole.
    MISSION_CORE_ABSTRACT_LEGS = _legs select { count _x > 0 };
    true
};

// Try to create an abstract leg. Returns TRUE when the caller must NOT dispatch
// directly (the leg owns the squad now), FALSE when the caller should carry on
// with its normal path.
//
// [_kind, _fromName, _toName, _fromPos, _toPos, _toSize, _payload, _materialize, _handoff]
//
// Returns false for anything it cannot own: under threshold, no position, a pair
// routePlan still refuses (missing endpoint, under its 50m floor, or the straight
// fallback disabled by tune), or a missing code block. Every one of those falls
// back to today's direct behaviour, which is what keeps this module additive
// rather than load-bearing.
MISSION_CORE_fnc_abstractLegDispatch = {
    params ["_kind", "_fromName", "_toName", "_fromPos", "_toPos", "_toSize", "_payload", "_materialize", "_handoff"];
    if !(_materialize isEqualType {}) exitWith { false };
    if !(_handoff isEqualType {}) exitWith { false };
    if !(_fromPos isEqualType []) exitWith { false };
    if !(_toPos isEqualType []) exitWith { false };
    // Handoff in progress: we are already INSIDE a dispatch script (see
    // MISSION_CORE_fnc_abstractLegHandoff). Abstraction is finished for this squad, so it
    // completes its journey for real. Re-abstracting here is the infinite-loop bug.
    if (!isNil "MISSION_CORE_ABSTRACT_HANDOFF" && { MISSION_CORE_ABSTRACT_HANDOFF }) exitWith { false };

    // routePlan is keyed on marker NAMES. With no destination name (a live player
    // position, as fn_assaultStaging uses) there is nothing to plan against, so the
    // leg declines and the caller dispatches directly. That is a deliberate gap, not
    // an oversight - a straight-line fallback here is the mountain-crossing path
    // fn_supplyRoutes routePlan exists to avoid.
    if (_fromName == "" || { _toName == "" }) then {
        diag_log format ["ABSTRACT LEG: %1 declined (%2 -> %3) - no marker name pair to route", _kind, _fromName, _toName];
    };
    if (_fromName == "" || { _toName == "" }) exitWith { false };

    // CANONICAL ENDPOINTS - THE THRESHOLD IS THE 2D STRAIGHT LINE, NEVER THE ARC.
    //
    // routePlan resolves BOTH markers from MISSION_CORE_CACHED_POSITIONS by name, so the
    // gate resolves those same two points instead of trusting the caller's coordinates:
    // fn_aiCommanderLoop reads _locPos out of MISSION_CORE_LOCATIONS (row 1, element 0)
    // while the provider side comes from the cache (row 1), and the two disagree. That
    // disagreement is what once let a 639m hop clear the gate and materialise - then hand
    // off - one second later, 639m from where it was supposed to be going.
    //
    // Distance is only a proxy for "is this a long haul", so it is tested on the straight
    // line and never on the solved arc. An arc is always >= the straight line but by an
    // arbitrary amount: backtracking turns a 650m hop into a 3108m "route". routePlan is
    // still called below, to get the PATH a leg follows - it never decides WHETHER a leg
    // exists.
    //
    // Both numbers stay in the dispatch log because arc >= straight line is still a hard
    // invariant. route < gate means the endpoint lookup has regressed.
    private _cache = if (isNil "MISSION_CORE_CACHED_POSITIONS") then { [] } else { MISSION_CORE_CACHED_POSITIONS };
    private _fi = _cache findIf { (_x select 0) == _fromName };
    private _ti = _cache findIf { (_x select 0) == _toName };
    if (_fi < 0 || { _ti < 0 }) then {
        diag_log format ["ABSTRACT LEG: %1 declined (%2 -> %3) - endpoint missing from the marker cache, distance unverifiable", _kind, _fromName, _toName];
    };
    if (_fi < 0 || { _ti < 0 }) exitWith { false };
    private _gateFrom = (_cache select _fi) select 1;
    private _gateTo = (_cache select _ti) select 1;
    if !(_gateFrom isEqualType []) exitWith { false };
    if !(_gateTo isEqualType []) exitWith { false };

    // THE RULE: 2000m or further abstracts. Under it, direct dispatch as before.
    // This test is on the 2D STRAIGHT LINE between the two markers, deliberately not on
    // the solved road arc: the arc is what the legs were being judged by when a 650m hop
    // produced a 3108m "route" and still abstracted. Distance is a proxy for "is this a
    // long haul", and backtracking arcs inflate it arbitrarily. routePlan is still
    // called below to get the PATH the leg follows, never to decide WHETHER to make one.
    private _minDist = ["reinforceAbstractMinDist", 2000] call MISSION_CORE_fnc_tune;
    if !(_minDist isEqualType 1) then { _minDist = 2000; };

    // STICKY GATE. The same provider/target pair is asked about repeatedly - every dispatch
    // attempt, every retry, every caller - and each ask re-walked both endpoints out of the live
    // cache and recomputed the straight-line distance. A row rewritten in place between two asks
    // (tier refresh, a capture flipping its owner) could therefore move the endpoint under the
    // test and re-decide an unchanged pair, so one sweep would abstract a haul and the next
    // would refuse it with no change in the actual geography.
    //
    // The memo stores only the immutable 2D DISTANCE for a named pair, never the verdict, so
    // changing reinforceAbstractMinDist still moves the threshold for every pair - this is not a
    // cached allow/deny list.
    //
    // SCOPE, stated precisely because it is narrower than "the decision is now stable":
    //   - It stabilises the REWRITTEN-row case above. Both endpoints resolve by name, so the
    //     memo answers even when the rows' contents changed.
    //   - It does NOT rescue a DELETED endpoint. The name lookup above still runs first and still
    //     declines with "endpoint missing" - distance is genuinely unverifiable then, and
    //     inventing one from a memo would route a leg to a marker that no longer exists.
    // Any pair whose endpoints stop resolving is rebuilt from scratch, which is the safe
    // direction: it re-decides rather than trusting a stale answer.
    if (isNil "MISSION_CORE_ABSTRACT_GATE") then { MISSION_CORE_ABSTRACT_GATE = createHashMap; };
    private _gateKey = format ["%1>%2", _fromName, _toName];
    private _gateDist = MISSION_CORE_ABSTRACT_GATE getOrDefault [_gateKey, -1];
    if (_gateDist < 0) then {
        _gateDist = _gateFrom distance2D _gateTo;
        MISSION_CORE_ABSTRACT_GATE set [_gateKey, _gateDist];
    };
    if (_gateDist < _minDist) exitWith { false };

    private _speed = ["reinforceAbstractSpeed", 14] call MISSION_CORE_fnc_tune;
    if !(_speed isEqualType 1) then { _speed = 14; };
    if (_speed <= 0) then { _speed = 14; };
    private _plan = [_fromName, _toName, _speed] call MISSION_CORE_fnc_routePlan;
    private _path = _plan select 0;
    private _cum = _plan select 1;
    private _travel = _plan select 3;
    // UNROUTABLE LONG HAUL, straight-line leg. routePlan already straight-falls when
    // supplyRouteStraightFallback is on, so this only catches the remainder (that tune turned
    // off, or a degenerate <1m plan). A leg is invisible until a player nears it
    // (abstractLegPlayerRadius) or it reaches the final ring (routeLegFinalRadius), and the
    // handoff re-routes the squad on real roads - a straight line crosses the gap without ever
    // marching the squad over it. Only a long haul (gate above already passed) earns this;
    // a short unrouteable hop still declines and falls back to a normal short dispatch.
    if ((count _path < 2 || { count _cum < 2 } || { _travel <= 0 }) && { _gateDist >= _minDist }) then {
        private _flat = [_gateFrom, _gateTo] call MISSION_CORE_fnc_straightPlan;
        if (count (_flat select 0) >= 2) then {
            _path = _flat select 0;
            _cum = _flat select 1;
            _travel = _flat select 2;
            diag_log format ["ABSTRACT LEG: %1 (%2 -> %3) no road route - straight-line leg (gate %4m)", _kind, _fromName, _toName, round _gateDist];
        };
    };
    if (count _path < 2 || { count _cum < 2 } || { _travel <= 0 }) then {
        diag_log format ["ABSTRACT LEG: %1 declined (%2 -> %3) - routePlan returned no usable path", _kind, _fromName, _toName];
        false
    } else {
        call MISSION_CORE_fnc_abstractLegStore;
        MISSION_CORE_ABSTRACT_LEG_ID = MISSION_CORE_ABSTRACT_LEG_ID + 1;
        private _id = MISSION_CORE_ABSTRACT_LEG_ID;
        private _row = [
            _kind, _fromName, _toName,
            // FROZEN copy of the destination: the whole point is that later marker
            // churn cannot move or delete the leg's goal. Frozen from the CANONICAL
            // position, not the caller's - this is the point routePlan's polyline
            // actually terminates on, so "distance to destination" in the materialize
            // and handoff logs is measured against the real end of the road, not a
            // second, disagreeing coordinate.
            [_gateTo select 0, _gateTo select 1, 0],
            _toSize, _payload, _path, _cum, _travel, time, 0, "abstract", grpNull, _handoff, _materialize, _id
        ];
            MISSION_CORE_ABSTRACT_LEGS pushBack _row;
            // Cap context on EVERY dispatch, from the one place all troop paths share.
            // A pending leg reserves a foot-squad slot, so a climbing `pending` against a
            // saturated `foot` is the signature of legs being created faster than they
            // materialise - which starves every dispatch gate in the mission and looks
            // identical to "the AI only queues" from the outside. Logged AFTER the pushBack so
            // the count includes the leg being created.
            //
            // `gate` is the straight line the threshold was tested against and `route` is the
            // solved arc length. route >= gate is a hard geometric invariant; if you ever see
            // route < gate, the endpoint lookup has regressed and every distance test in this
            // file is measuring the wrong pair of points.
            private _capOut = [] call MISSION_CORE_fnc_countAbstractLegs;
            diag_log format ["ABSTRACT LEG: %1 dispatched %2 -> %3 (gate %4m / route %5m, ETA %6s, id %7) | pending %8, rolling %9", _kind, _fromName, _toName, round _gateDist, round (_cum select ((count _cum) - 1)), round _travel, _id, _capOut select 0, _capOut select 1];
            true
        };
};

// ---------------------------------------------------------------------
// CLAIMED (REAL) SQUAD LONG HAUL -> ABSTRACT LEG
// ---------------------------------------------------------------------
// fn_sendCounterAttack's foot long-haul gate. A squad that ALREADY exists (claimed off a
// garrison by fn_claimReinforcementSquad, or re-tasked by the ai commander) and is ordered to
// march reinforceAbstractMinDist or farther is turned into an abstract leg carrying that SAME
// squad - not refused, not replaced by a conjure. The squad is parked out of the world (hidden,
// simulation disabled) and its travel is interpolated along the road route from origin to target
// like any other leg. It materialises - the REAL men, no new manpower charged - once the leg is
// within routeLegFinalRadius (1000m) of the target, or earlier when a player gets within
// abstractLegPlayerRadius of the abstract position; the remaining route legs are laid and the
// normal final-approach assault (handoff -> sendCounterAttack) finishes the job on foot/truck.
//
// Returns TRUE when the leg took the squad (a repeat dispatch is accepted silently so it is
// never double-legged): the caller must NOT march it directly and may report it as re-tasked.
// Returns FALSE only when no leg could be built - then the caller must fall back (conjure).
MISSION_CORE_fnc_abstractClaimedSquad = {
    params ["_group", "_targetPos", ["_targetSize", [50, 50]], ["_combatMode", "RED"], ["_order", "counterattack"]];
    if (isNull _group || { count units _group == 0 }) exitWith { false };
    // Already in flight: a repeat dispatch for the same squad while its leg runs. Accept - the
    // existing leg owns it and will land it on the frozen target. Not a double leg.
    if (_group getVariable ["MISSION_CORE_ABSTRACT_CLAIMED", false]) exitWith { true };

    // The leg layer routes on marker NAMES. Resolve the target marker from the order position;
    // only adopt it when it really is the contested marker (within 1500m), so a live player
    // pickup point far from any marker takes the straight line instead of flying toward a
    // random marker. The origin name comes off the squad, as the conjure paths use it.
    private _fromName = _group getVariable ["MISSION_CORE_ORIGIN_MARKER", ""];
    private _toName = "";
    if (!isNil "MISSION_CORE_CACHED_POSITIONS" && { count MISSION_CORE_CACHED_POSITIONS > 0 }) then {
        private _best = 1e10;
        private _bestName = "";
        {
            private _d = _targetPos distance2D (_x select 1);
            if (_d < _best) then { _best = _d; _bestName = _x select 0; };
        } forEach MISSION_CORE_CACHED_POSITIONS;
        if (_best <= 1500) then { _toName = _bestName; };
    };

    private _startPos = getPos (leader _group);
    private _speed = ["reinforceAbstractSpeed", 14] call MISSION_CORE_fnc_tune;
    if !(_speed isEqualType 1) then { _speed = 14; };
    if (_speed <= 0) then { _speed = 14; };

    private _path = [];
    private _cum = [];
    private _dist = 0;
    private _travel = 0;
    if (_fromName != "" && { _toName != "" && { !isNil "MISSION_CORE_fnc_routePlan" } }) then {
        private _plan = [_fromName, _toName, _speed] call MISSION_CORE_fnc_routePlan;
        _path = _plan select 0;
        _cum = _plan select 1;
        _dist = _plan select 2;
        _travel = _plan select 3;
    };
    if (count _path < 2 || { count _cum < 2 } || { _travel <= 0 }) then {
        // No named-pair route (no target marker, or routePlan declined). A straight line crosses
        // the gap in abstract space - the handoff re-routes on real roads for the final approach,
        // so nothing ever marches the raw line overland.
        private _flat = [_startPos, _targetPos] call MISSION_CORE_fnc_straightPlan;
        if (count (_flat select 0) >= 2) then {
            _path = _flat select 0;
            _cum = _flat select 1;
            _dist = _flat select 2;
            _travel = _dist / _speed;
            diag_log format ["ABSTRACT CLAIM: %1 (%2 -> %3) no road route - straight-line leg (%4m, ETA %5s)", groupId _group, _fromName, _toName, round _dist, round _travel];
        };
    };
    if (count _path < 2 || { count _cum < 2 } || { _travel <= 0 }) exitWith { false };

    // PARK THE REAL SQUAD OUT OF THE WORLD. Hidden and de-simulated it is invisible, cannot
    // fight, cannot be targeted, and does not wander - but it keeps its identity, its group,
    // its place in MISSION_CORE_SPAWNED_GROUPS and its foot-cap slot, so nothing refunds it
    // and nothing re-charges it. MISSION_CORE_IDLE=false also keeps the claim filters from
    // re-claiming the same squad for a second march while it is in the air.
    { _x hideObjectGlobal true; _x enableSimulationGlobal false; } forEach units _group;
    _group setVariable ["MISSION_CORE_ABSTRACT_CLAIMED", true];
    _group setVariable ["MISSION_CORE_IDLE", false];
    _group setVariable ["MISSION_CORE_PATROLLING", false];
    _group setVariable ["MISSION_CORE_ORDER", _order];
    [_group] call MISSION_CORE_fnc_clearGroupWaypoints;

    call MISSION_CORE_fnc_abstractLegStore;
    MISSION_CORE_ABSTRACT_LEG_ID = MISSION_CORE_ABSTRACT_LEG_ID + 1;
    private _id = MISSION_CORE_ABSTRACT_LEG_ID;
    // SQF code blocks run in their own scope, so the callbacks cannot close over this caller's
    // locals - the squad and the assault parameters travel in the payload.
    private _payload = [_group, _combatMode, _order];
    // Materialise: drop the SAME squad back at the abstract position, unhidden and re-simulated.
    // The leg layer lays the remaining route legs from there; the handoff runs the final
    // approach on the target.
    private _mat = {
        params ["_row", "_frac"];
        private _g = (_row select 5) select 0;
        if (isNull _g || { count units _g == 0 }) exitWith { grpNull };
        private _at = [_row select 6, _row select 7, _frac] call MISSION_CORE_fnc_convoyPosAt;
        {
            _x hideObjectGlobal false;
            _x enableSimulationGlobal true;
            _x setPos [_at select 0, _at select 1, 0];
        } forEach units _g;
        _g setVariable ["MISSION_CORE_ABSTRACT_CLAIMED", nil];
        diag_log format ["ABSTRACT CLAIM: %1 materialised (id %2) at %3% of route, %4m from target", groupId _g, _row select 15, round (_frac * 100), round ((getPosATL (leader _g)) distance2D (_row select 3))];
        _g
    };
    // Handoff: the squad is now within routeLegFinalRadius (1000m) of the target - under the
    // abstraction threshold - so sendCounterAttack takes it from here with a normal assault.
    private _ho = {
        params ["_g", "_row"];
        if (isNull _g) exitWith {};
        private _pl = _row select 5;
        [_g, _row select 3, _row select 4, _pl select 1, _pl select 2] call MISSION_CORE_fnc_sendCounterAttack;
    };
    // FROZEN destination is the END OF THE PATH, not the raw order position: the polyline
    // terminates on the marker centre, and the tick's "route complete" materialize tests the
    // abstract position against this point. Freezing the order position instead would leave a
    // leg stuck abstract forever whenever the two disagree by more than routeLegFinalRadius.
    private _toPos = _path select ((count _path) - 1);
    MISSION_CORE_ABSTRACT_LEGS pushBack [
        "claimed", _fromName, _toName,
        [_toPos select 0, _toPos select 1, 0],
        _targetSize, _payload, _path, _cum, _travel, time, 0, "abstract", grpNull, _ho, _mat, _id
    ];
    private _capOut = [] call MISSION_CORE_fnc_countAbstractLegs;
    diag_log format ["ABSTRACT CLAIM: %1 from %2 abstracted -> %3 (%4m straight / %5m route, ETA %6s, id %7) | pending %8, rolling %9", groupId _group, _fromName, _toName, round (_startPos distance2D _targetPos), round ((_cum select ((count _cum) - 1))), round _travel, _id, _capOut select 0, _capOut select 1];
    true
};

// Materialise the squad at fraction _frac, put the strided route legs on it, and flip
// the row to "rolling". Called only from the tick's APPLY pass.
// Returns the group, or grpNull if the squad could not be raised.
MISSION_CORE_fnc_abstractLegMaterialize = {
    params ["_row", "_frac"];
    private _id = _row select 15;
    private _grp = [_row, _frac] call (_row select 14);
    if (isNull _grp || { count units _grp == 0 }) then {
        // Nothing to command. Manpower and ammo are charged by the materialize callback
        // itself, so a callback that never produced a squad never charged anything either -
        // this is a genuine spawn failure and nothing is refunded or owed.
        //
        // diag_log, NOT error: `error` throws, which would abort the whole tick and take
        // every OTHER healthy leg's handoff down with it. A failed leg must not be able to
        // strand the rest of the column.
        diag_log format ["ABSTRACT LEG FAILED: %1 (id %2) materialise produced no squad - leg dropped, nothing was charged", _row select 0, _id];
        [_id] call MISSION_CORE_fnc_abstractLegRemove;
        grpNull
    } else {
        // MARK THE ROW "rolling" BEFORE LAYING DOWN ANY WAYPOINT. THIS ORDER IS LOAD-BEARING.
        //
        // The spawn above has already put a LIVE squad in the world and registered it in
        // MISSION_CORE_SPAWNED_GROUPS. If anything below throws, an ordering that updates the
        // row LAST leaves it in the "abstract" state while its squad is standing on the map -
        // and the tick materialises every abstract row near a player, so that row spawns
        // ANOTHER squad, throws again, and repeats once a second, per leg, unbounded. That is
        // not hypothetical: it is exactly what `isNull` on an addWaypoint result did, and it
        // saturated MISSION_CORE_SPAWNED_GROUPS past the foot cap so hard that every dispatch
        // gate in the mission failed and the AI could only queue.
        //
        // SQF has no try/catch, so the only available defence is to reach a consistent state
        // before doing anything that can fail. After this block the row is "rolling" and holds
        // its group, so a later throw costs that squad its leg waypoints - it still hands off
        // normally - instead of producing an unkillable respawn loop.
        private _legs = MISSION_CORE_ABSTRACT_LEGS;
        private _idx = _legs findIf { (_x select 15) == _id };
        if (_idx >= 0) then {
            private _new = +_row;
            _new set [10, _frac];
            _new set [11, "rolling"];
            _new set [12, _grp];
            _legs set [_idx, _new];
        } else {
            // The row is not in the store, so the tick cannot re-materialise it and there is no
            // respawn risk. The squad is simply untracked by the leg layer; it lives in the
            // world and in MISSION_CORE_SPAWNED_GROUPS like any other group.
            diag_log format ["ABSTRACT LEG: %1 (id %2) materialised but its row was already gone - squad is untracked by the leg layer", _row select 0, _id];
        };
        // Legs run on the route the abstract layer already stored - same _path/_cum, no re-plan.
        // The trailing target waypoint comes from applyRouteLegWps.
        [_grp, _row select 6, _row select 7, _frac, _row select 3] call MISSION_CORE_fnc_applyRouteLegWps;
        diag_log format ["ABSTRACT LEG: %1 materialised %2 (id %3) at %4% of route, %5m from destination", _row select 0, groupId _grp, _id, round (_frac * 100), round ((getPosATL (leader _grp)) distance2D (_row select 3))];
        _grp
    };
};

// Hand a leg off to its arrival script. The row is REMOVED first so the tick can never
// watch a group the script has taken ownership of - double-watching is the stuck-
// watchdog bug class this mission already has history with.
MISSION_CORE_fnc_abstractLegHandoff = {
    params ["_row", "_reason"];
    private _id = _row select 15;
    private _grp = _row select 12;
    // Row is dropped unconditionally: handoff is the ONLY exit, successful or not.
    [_id] call MISSION_CORE_fnc_abstractLegRemove;
    if ((!isNull _grp) && { count units _grp > 0 }) then {
        diag_log format ["ABSTRACT LEG: %1 id %2 HANDOFF %3 -> %4 (%5)", _row select 0, _id, groupId _grp, _row select 3, _reason];
        // RE-ENTRANCY GUARD. The arrival scripts are the SAME functions the dispatch sites call
        // (fn_sendCounterAttack is both the handoff for a reinforcement leg AND its own dispatch
        // path). Without this, handing a leg off re-entered the very function that created it and
        // the squad would spawn a fresh abstract leg for a journey it had already made - forever.
        // Set for the duration of the callback only, and cleared below.
        MISSION_CORE_ABSTRACT_HANDOFF = true;
        [_grp, _row] call (_row select 13);
        MISSION_CORE_ABSTRACT_HANDOFF = false;
    } else {
        // Nothing left to command - the squad died en route, or never produced one. The row is
        // already removed, so the cap slot is released either way. Do NOT call the arrival
        // script: every current one opens with `if (isNull _g) exitWith {}`, but that is a
        // courtesy the layer should not depend on. A callback that touched _grp here would
        // throw inside the handoff and leave MISSION_CORE_ABSTRACT_HANDOFF stuck true, which
        // silently disables abstraction for the rest of the mission.
        diag_log format ["ABSTRACT LEG: %1 id %2 HANDOFF with no live squad (%3) - arrival script not called", _row select 0, _id, _reason];
    };
    true
};

// Advance every abstract leg.
//
// Deliberately split into a READ-ONLY scan pass and an APPLY pass. The first version
// of this loop materialised and removed rows while iterating MISSION_CORE_ABSTRACT_LEGS
// itself; because forEach captures the array by value, a row removed mid-scan was still
// visited afterwards and got handed off twice. Nothing in the scan may mutate the store.
MISSION_CORE_fnc_abstractLegTick = {
    // Reset the re-entrancy flag BEFORE the early exits, not after them. The two guards
    // below return on an empty store - and an empty store is exactly the state a session
    // is left in once the LAST handoff's callback threw, because the row is removed before
    // the callback runs. A reset placed after these guards would never execute in that
    // state, so one broken arrival script would leave the flag stuck true and silently
    // disable abstraction for every dispatch for the rest of the mission.
    MISSION_CORE_ABSTRACT_HANDOFF = false;
    if (isNil "MISSION_CORE_ABSTRACT_LEGS") exitWith {};
    if (count MISSION_CORE_ABSTRACT_LEGS == 0) exitWith {};

    private _playerR = ["abstractLegPlayerRadius", 1200] call MISSION_CORE_fnc_tune;
    if !(_playerR isEqualType 1) then { _playerR = 1200; };
    // SAME tune as the leg cutoff in fn_routeLegWps. Sharing it is what guarantees a leg
    // is never emitted inside the radius at which we hand off.
    private _finalR = ["routeLegFinalRadius", 1000] call MISSION_CORE_fnc_tune;
    if !(_finalR isEqualType 1) then { _finalR = 1000; };
    // PENDING DEADLINE. A pending leg reserves a foot-squad slot, and the ONLY things that
    // ever release that slot are a materialise and a handoff. Both of those are driven from
    // this tick, so any leg this tick stops acting on holds its slot until the end of the
    // mission - and because the neighbouring dispatch gates test that cap, two stranded legs
    // are enough to push every later squad into the queue branch and make the AI look like
    // it has stopped reinforcing at all. Slack is generous (it exists only to catch legs
    // this tick has lost track of, never to pre-empt normal play); past it the leg is forced
    // into the world at frac 1, which is where it was going anyway.
    private _slack = ["abstractLegPendingSlack", 180] call MISSION_CORE_fnc_tune;
    if !(_slack isEqualType 1) then { _slack = 180; };
    private _players = allPlayers select { alive _x };

    // ---- PASS 1: decide. Read-only. ----
    private _actions = [];
    {
        private _row = _x;
        private _travel = _row select 8;
        private _frac = 0;
        if (_travel > 0) then { _frac = ((time - (_row select 9)) / _travel) max 0 min 1; };

        if ((_row select 11) == "abstract") then {
            // Still invisible - only a nearby player can bring it into the world.
            private _pos = [_row select 6, _row select 7, _frac] call MISSION_CORE_fnc_convoyPosAt;
            private _near = false;
            {
                if ((_pos distance2D (getPosATL _x)) < _playerR) then { _near = true; };
            } forEach _players;
            if (_near) then { _actions pushBack [_row, "materialize", _frac, ""]; } else {
                // A leg that has run out of route is standing ON the destination: the strided
                // waypoints in fn_routeLegWps stop emitting once they are inside
                // routeLegFinalRadius, so frac 1 is inside that ring by construction. Materialize
                // it whether or not a player is watching. Without this a destination no player ever
                // visits leaves the leg abstract at frac 1 FOREVER - it never spawns and never hands
                // off, and because pending legs count against footSquadCapSquads it holds its slot
                // until the end of the mission, which slowly freezes troop dispatch entirely.
                if ((_pos distance2D (_row select 3)) <= _finalR) then {
                    _actions pushBack [_row, "materialize", _frac, "route complete - no player in range"];
                } else {
                    // Last resort, and the only one that runs on time rather than position. Any
                    // leg still abstract this long past its own travel time has stopped being
                    // tracked by the logic above; put it in the world so it stops reserving a
                    // foot-squad slot. Frac is already 1 here, so it spawns at the destination
                    // and hands off normally on the next tick.
                    if ((time - (_row select 9)) > (_travel + _slack)) then {
                        diag_log format ["ABSTRACT LEG: %1 id %2 pending %3s past travel+slack - forcing it into the world to release its cap slot", _row select 0, _row select 15, round (time - (_row select 9))];
                        _actions pushBack [_row, "materialize", _frac, "pending deadline expired"];
                    };
                };
            };
        } else {
            // Rolling: the squad exists and is driving its legs.
            private _grp = _row select 12;
            if (isNull _grp || { count units _grp == 0 }) then {
                // Squad died en route. The march is over and the arrival script needs to
                // account for it. This is NOT a cancellation - nothing is refunded.
                _actions pushBack [_row, "handoff", 0, "squad destroyed en route"];
            } else {
                private _d = (getPosATL (leader _grp)) distance2D (_row select 3);
                if (_d <= _finalR) then {
                    _actions pushBack [_row, "handoff", 0, format ["reached final approach (%1m <= %2m)", round _d, _finalR]];
                } else {
                    // Force completion: a leg that has run out of route MUST hand off
                    // rather than sit at frac 1 forever. This is the anti-stranding
                    // guarantee, and it only applies to a squad that is still alive -
                    // the dead case already handed off above.
                    if (_frac >= 1) then {
                        _actions pushBack [_row, "handoff", 0, "route complete - forced handoff"];
                    };
                };
            };
        };
    } forEach MISSION_CORE_ABSTRACT_LEGS;

    // ---- PASS 2: apply. Each row carries at most one action, and rows are re-found by
    // id rather than index, so a removal here cannot shift an unprocessed action. ----
    {
        private _a = _x;
        private _row = _a select 0;
        if ((_a select 1) == "materialize") then {
            [_row, _a select 2] call MISSION_CORE_fnc_abstractLegMaterialize;
        } else {
            [_row, _a select 3] call MISSION_CORE_fnc_abstractLegHandoff;
        };
    } forEach _actions;
};

// Pending abstract legs - committed men that do not exist in the world yet.
//
// THIS IS THE ACCOUNTING HOOK, and it exists because of a hole the abstraction would
// otherwise open. fn_requestReinforcement and its siblings gate spawning on
// fnc_countFootSquads, which counts REAL groups. An abstract leg has no group, so it
// was invisible to that cap - a provider would keep creating legs for free, forever,
// because nothing was ever debited and nothing was ever counted. Adding the pending
// legs to the cap closes it WITHOUT costing anything: these squads reserve a slot in
// the budget, but no manpower and no ammo move until they actually spawn.
//
// Only legs still in the "abstract" state are counted. Once a leg has materialised its
// squad is a real group and fnc_countFootSquads already sees it - counting both would
// charge every squad twice for the last leg of its journey.
//
// Returns [pending, rolling] so a caller can log the split if it wants to.
MISSION_CORE_fnc_countAbstractLegs = {
    params [];
    private _pending = 0;
    private _rolling = 0;
    if (!isNil "MISSION_CORE_ABSTRACT_LEGS") then {
        {
            if ((_x select 11) == "abstract") then { _pending = _pending + 1 } else { _rolling = _rolling + 1 };
        } forEach MISSION_CORE_ABSTRACT_LEGS;
    };
    [_pending, _rolling]
};

// Pending abstract legs only - the number to add to a foot-squad cap.
MISSION_CORE_fnc_countPendingAbstractLegs = {
    params [];
    (call MISSION_CORE_fnc_countAbstractLegs) select 0
};

// The scheduler. One scan a second, which is plenty: a leg lives for minutes, and the
// only time-sensitive moment is materialising in front of a player. While no leg
// exists the tick returns on its first two guards, so an idle server pays one array
// length check a second.
MISSION_CORE_fnc_abstractLegLoop = {
    diag_log "ABSTRACT LEGS: loop started";
    waitUntil { !isNil "MISSION_CORE_fnc_routePlan" };
    private _nextScan = 0;
    while { true } do {
        sleep 1;
        if (time >= _nextScan) then {
            _nextScan = time + 1;
            [] call MISSION_CORE_fnc_abstractLegTick;
        };
    };
};