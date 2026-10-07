// =====================================================================
// AMMUNITION SYSTEM
// Per-marker ammo resource that drives AI aggression.  Ports produce
// ammo and ship it to depots (base/hq/factory) as an ABSTRACT ROAD
// CONVOY; markers then request from depots the same way.  Both legs
// resolve a real road route, expose a recon icon, and credit the
// recipient only when the convoy's ETA expires - so ammo in transit
// exists at neither end.  Offensive actions (attack, counter-attack,
// hunt, armor reinforcement) consume ammo.  Low ammo forces defensive
// behavior; empty ammo forces passivity.
// =====================================================================

// DEBUG: set false to silence the per-sweep request diagnostics in fn_ammoRequestTick. Follows the
// house convention (MISSION_CORE_DEBUG_CONTEST in fn_isMarkerContested.sqf): a plain global with an
// isNil default, so flipping this one line is the whole toggle. It gates LOGGING ONLY - the
// counters still accumulate either way, so switching it on or off cannot change behaviour or make
// the two paths drift apart later.
if (isNil "MISSION_CORE_DEBUG_AMMO") then { MISSION_CORE_DEBUG_AMMO = true; };

// ---- CONTESTED-ASSIST EDGE (shared by the ammo and manpower request channels) ----
// A marker that is ACTIVELY HELPING a contested zone gets a slight priority when it asks for
// supplies of its own - it is already spending men and materiel on that fight, so starving it is
// both bad tactics and self-defeating.
//
// "Helping" is NOT a proximity test. It is the existing neighbour set from
// MISSION_CORE_fnc_getMarkerNeighbors (fn_neighborCounterAttack.sqf:28), which is already the
// authoritative answer to "who may help this contested zone": same side, not the zone itself, not
// another contested zone, not light infrastructure, within neighborRange, overwatch-aware. Reusing
// it means the supply channels and the troop channels cannot drift apart about who counts as a
// helper. A marker merely standing near a contested zone, doing nothing, gets nothing.
//
// _excludeNonCombat is FALSE here, unlike in fnc_neighborCounterAttack (which passes true). That
// flag drops depots/factories/powerplants because they do not march in to help - but a factory is
// a perfectly valid supply REQUESTER, so excluding them would silently deny the edge to the very
// markers that stock the network. Only light infrastructure is excluded unconditionally inside the
// helper, and those are never requesters anyway.
//
// Never returns an edge for a CONTESTED marker. Those are refused supply outright by a permanent
// rule, and a multiplier must not become a back door around it.
//
// params:  [_selfLoc, _edgeKey, ["_zoneNames", []]]
// returns: the multiplier, or 1 when this marker is not helping anything.
MISSION_CORE_fnc_contestedAssistEdge = {
    params ["_selfLoc", "_edgeKey", ["_zoneNames", []]];
    if (isNil "MISSION_CORE_fnc_getMarkerNeighbors") exitWith { 1 };
    if (count _selfLoc == 0) exitWith { 1 };
    private _selfName = _selfLoc select 0;
    // Contested markers are refused supply outright, so they must never collect an edge.
    if (!isNil "MISSION_CORE_CONTESTED" && { _selfName in MISSION_CORE_CONTESTED }) exitWith { 1 };
    if (count _zoneNames == 0) then {
        if (isNil "MISSION_CORE_CONTESTED") exitWith { 1 };
        _zoneNames = keys MISSION_CORE_CONTESTED;
    };
    if (count _zoneNames == 0) exitWith { 1 };
    private _edge = [_edgeKey, 1] call MISSION_CORE_fnc_tune;
    if (_edge <= 1) exitWith { 1 };
    private _selfPos = _selfLoc select 1;
    private _side = _selfLoc select 4;
    {
        private _zoneName = _x;
        private _zoneIdx = MISSION_CORE_CACHED_POSITIONS findIf { (_x select 0) == _zoneName };
        if (_zoneIdx >= 0) then {
            private _zone = MISSION_CORE_CACHED_POSITIONS select _zoneIdx;
            // Same side only. A contested ENEMY zone is not a reason for our marker to resupply.
            if ((_zone select 4) == _side) then {
                private _neighbors = [_zoneName, (_zone select 1), _side, _zoneNames, false] call MISSION_CORE_fnc_getMarkerNeighbors;
                if (_selfName in (_neighbors apply { _x select 0 })) exitWith { _edge };
            };
        };
    } forEach _zoneNames;
    1
};

MISSION_CORE_fnc_initAmmo = {
    if (isNil "MISSION_CORE_LOCATION_AMMO") then { MISSION_CORE_LOCATION_AMMO = createHashMap; };
    if (isNil "MISSION_CORE_LOCATION_AMMO_MAX") then { MISSION_CORE_LOCATION_AMMO_MAX = createHashMap; };
    if (isNil "MISSION_CORE_PORT_AMMO_ACCUM") then { MISSION_CORE_PORT_AMMO_ACCUM = createHashMap; };
    if (isNil "MISSION_CORE_AMMO_REQUEST_CD") then { MISSION_CORE_AMMO_REQUEST_CD = createHashMap; };
    // Waiting list for requests that won the chance roll but found no donor with stock to give.
    // Row = [amount to give, time asked, asking marker, side that asked] - the asking marker is
    // APPENDED to the request fields. Serviced on every request sweep once any same-side depot
    // is back above its donor floor.
    if (isNil "MISSION_CORE_AMMO_WAITING") then { MISSION_CORE_AMMO_WAITING = []; };
    if (isNil "MISSION_CORE_AMMO_CONVOYS") then { MISSION_CORE_AMMO_CONVOYS = []; };
    if (isNil "MISSION_CORE_AMMO_CONVOY_ID") then { MISSION_CORE_AMMO_CONVOY_ID = 0; };
    // Ammo shipments draw from the SHARED convoy id counter. See the dispatch function for why
    // a private counter leaks map icons.
    if (isNil "MISSION_CORE_CONVOY_ID") then { MISSION_CORE_CONVOY_ID = 0; };
    private _base = ["ammoBasePerImp", 20] call MISSION_CORE_fnc_tune;
    private _depotMult = ["ammoDepotCapacityMult", 2] call MISSION_CORE_fnc_tune;
    private _startMin = ["ammoDepotStartFracMin", 0.4] call MISSION_CORE_fnc_tune;
    private _startMax = ["ammoDepotStartFracMax", 0.7] call MISSION_CORE_fnc_tune;
    private _startSpan = (_startMax - _startMin) max 0;
    {
        private _name = _x select 0;
        private _imp = _x select 7;
        private _area = _x select 8;
        private _sizeA = _area select 0;
        private _sizeB = _area select 1;
        private _sizeFactor = (sqrt (_sizeA * _sizeB) / 150) min 2;
        private _maxAmmo = floor (_imp * _base * _sizeFactor);
        // Depots get their own capacity and their own randomised opening stock. A depot's storage
        // is a warehouse property, not a garrison property: importance is combat value, and at
        // importance 1 the shared formula produced caps of roughly 9-13, small enough that the
        // donor floor sat at 80-100% of a FULL depot. Every other marker keeps the flat 50% start.
        private _startFrac = 0.5;
        if (toLower (_x select 2) in ["depot"]) then {
            _maxAmmo = floor (_maxAmmo * _depotMult);
            _startFrac = _startMin + (random _startSpan);
        };
        MISSION_CORE_LOCATION_AMMO_MAX set [_name, _maxAmmo];
        MISSION_CORE_LOCATION_AMMO set [_name, floor (_maxAmmo * _startFrac)];
    } forEach MISSION_CORE_CACHED_POSITIONS;
    publicVariable "MISSION_CORE_LOCATION_AMMO_MAX";
    publicVariable "MISSION_CORE_LOCATION_AMMO";
    diag_log format ["AMMO: initialized %1 markers (base=%2)", count MISSION_CORE_LOCATION_AMMO, _base];
    diag_log format ["AMMO: %1 depots at x%2 capacity, opening stock %3-%4 of max, donation floor %5 of max", count (MISSION_CORE_CACHED_POSITIONS select { toLower (_x select 2) in ["depot"] }), _depotMult, _startMin, _startMax, (["ammoDonorStockFrac", 0.3] call MISSION_CORE_fnc_tune)];
};

// Charge ammo from a marker. Returns true if the marker had enough.
MISSION_CORE_fnc_consumeAmmo = {
    params ["_markerName", "_amount"];
    if (isNil "MISSION_CORE_LOCATION_AMMO") exitWith { false };
    private _cur = MISSION_CORE_LOCATION_AMMO getOrDefault [_markerName, 0];
    if (_cur < _amount) exitWith { false };
    MISSION_CORE_LOCATION_AMMO set [_markerName, _cur - _amount];
    publicVariable "MISSION_CORE_LOCATION_AMMO";
    true
};

// Ammo fraction (0..1) for a marker.
MISSION_CORE_fnc_getAmmoFraction = {
    params ["_markerName"];
    if (isNil "MISSION_CORE_LOCATION_AMMO" || isNil "MISSION_CORE_LOCATION_AMMO_MAX") exitWith { 1 };
    private _ammo = MISSION_CORE_LOCATION_AMMO getOrDefault [_markerName, 0];
    private _max = MISSION_CORE_LOCATION_AMMO_MAX getOrDefault [_markerName, 1];
    if (_max <= 0) exitWith { 0 };
    _ammo / _max
};

// Aggression multiplier from ammo level.  0 = passive, 0.3 = defensive, 0.5 = cautious, 1 = aggressive.
MISSION_CORE_fnc_ammoAggressionMult = {
    params ["_markerName"];
    private _frac = [_markerName] call MISSION_CORE_fnc_getAmmoFraction;
    if (_frac <= 0) exitWith { 0 };
    if (_frac < 0.3) exitWith { 0 };
    if (_frac < 0.7) exitWith { 0.5 };
    1.0
};

MISSION_CORE_fnc_ammoCanAttack = {
    params ["_markerName"];
    ([_markerName] call MISSION_CORE_fnc_getAmmoFraction) >= 0.3
};

MISSION_CORE_fnc_ammoCanHunt = {
    params ["_markerName"];
    ([_markerName] call MISSION_CORE_fnc_getAmmoFraction) >= 0.3
};

// ---- ABSTRACT AMMO CONVOYS ----
// Ammo moves on the same abstract road-routed conveyor as manpower: a dispatch
// records where the cargo is, how long the road takes, and the recipient is
// credited when the convoy's ETA expires. Nothing is handed over at dispatch
// time any more, so a shipment in transit is cargo that exists nowhere yet.
//
// Record layout (index: meaning):
//   0 from marker   1 to marker   2 amount   3 arrival time   4 convoy id
//   5 kind ("portDepot" | "depotMarker")   6 road path   7 cumulative distances
//   8 travel seconds
MISSION_CORE_fnc_dispatchAmmoConvoy = {
    params ["_fromName", "_toName", "_amount", "_kind"];
    if (_amount <= 0) exitWith { false };
    // PERMANENT RULE: a contested marker never receives supply of any kind, ammo included. The
    // truck would only drive its cargo straight into the zone the players are fighting over, and
    // the donor keeps its stock for quieter markers. This mirrors the identical guard in
    // fnc_startConvoy (fn_convoyLoop.sqf:148), which already enforces it for the manpower channel -
    // ammo had NO such check anywhere, so a contested outmarker could be resupplied.
    //
    // Guarded on the RECIPIENT only. A contested DONOR is still a valid place to ship from: it holds
    // stock and emptying it toward other markers is the behaviour we want. Only receiving is banned.
    //
    // Checked BEFORE routePlan so a refused shipment costs no road search, and before the convoys
    // array is touched so there is no half-built record to clean up.
    if (!isNil "MISSION_CORE_CONTESTED" && { _toName in MISSION_CORE_CONTESTED }) exitWith {
        diag_log format ["AMMO: %1 -> %2 ammo convoy skipped - recipient contested", _fromName, _toName];
        false
    };
    if (isNil "MISSION_CORE_AMMO_CONVOYS") then { MISSION_CORE_AMMO_CONVOYS = []; };
    if (isNil "MISSION_CORE_AMMO_CONVOY_ID") then { MISSION_CORE_AMMO_CONVOY_ID = 0; };
    private _speed = ["ammoConvoySpeed", 14] call MISSION_CORE_fnc_tune;
    // NO minimum-distance gate on ammo legs. There is no "too close to resupply" rule: a depot
    // next door is the cheapest possible resupply and must never be refused. This call used to
    // pass supplyRouteSnapBase (800m) as routePlan's _minDist argument, which is an ENDPOINT
    // ROAD-SNAPPING RADIUS being compared against the leg length - a unit mismatch. It rejected
    // outpost_2 -> depot_3 at 662m as TOO-CLOSE while logging "662m<800m", which reads like a
    // deliberate proximity rule but was never one. _minDist is now omitted so routePlan uses its
    // own 50m default, which only suppresses degenerate zero-length legs.
    private _plan = [_fromName, _toName, _speed] call MISSION_CORE_fnc_routePlan;
    private _roadPath = _plan select 0;
    private _cum = _plan select 1;
    private _eta = _plan select 3;
    if (_eta <= 0) exitWith { false };
    // CID GLOBAL ACROSS ALL CONVOY CLASSES. MISSION_CORE_RECON_MARKERS is keyed by cid ALONE and
    // the housekeep liveness test merges every convoy class's cids into one plain array, so a cid
    // is only unique if every producer draws from the same counter. Ammo used to keep a private
    // MISSION_CORE_AMMO_CONVOY_ID, which collided with the shared counter: ammo #5 and manpower #5
    // were indistinguishable, so a delivered manpower convoy kept a live-looking cid while an ammo
    // shipment was still in flight and its map icon was never dropped. A second reveal at the same
    // cid also overwrote the stored marker name, orphaning the earlier icon forever.
    if (isNil "MISSION_CORE_CONVOY_ID") then { MISSION_CORE_CONVOY_ID = 0; };
    MISSION_CORE_CONVOY_ID = MISSION_CORE_CONVOY_ID + 1;
    MISSION_CORE_AMMO_CONVOY_ID = MISSION_CORE_CONVOY_ID;
    MISSION_CORE_AMMO_CONVOYS pushBack [_fromName, _toName, _amount, (time + _eta), MISSION_CORE_CONVOY_ID, _kind, _roadPath, _cum, _eta];
    diag_log format ["AMMO: %1 convoy %2 %3 -> %4 carrying %5 (ETA %6s)", _kind, MISSION_CORE_CONVOY_ID, _fromName, _toName, round _amount, round _eta];
    true
};

// Arrive abstract ammo convoys. The recipient is only credited here, and only
// up to the room it actually has - a depot that filled up while the cargo was on
// the road absorbs the remainder rather than exceeding its cap.
MISSION_CORE_fnc_ammoConvoyTick = {
    if (isNil "MISSION_CORE_AMMO_CONVOYS") exitWith {};
    if (isNil "MISSION_CORE_LOCATION_AMMO") exitWith {};
    {
        private _c = _x;
        if (time < (_c select 3)) then { continue; };
        private _toName = _c select 1;
        private _amount = _c select 2;
        private _kind = _c select 5;
        private _max = MISSION_CORE_LOCATION_AMMO_MAX getOrDefault [_toName, 1];
        private _cur = MISSION_CORE_LOCATION_AMMO getOrDefault [_toName, 0];
        private _give = ((_amount min (_max - _cur)) max 0);
        MISSION_CORE_LOCATION_AMMO set [_toName, (_cur + _give)];
        publicVariable "MISSION_CORE_LOCATION_AMMO";
        if (_give < _amount) then {
            diag_log format ["AMMO: convoy %1 %2 -> %3 delivered only %4 of %5 - recipient at cap", _c select 4, _c select 0, _toName, round _give, round _amount];
        } else {
            diag_log format ["AMMO: convoy %1 %2 -> %3 delivered %4", _c select 4, _kind, _toName, round _give];
        };
        MISSION_CORE_AMMO_CONVOYS set [_forEachIndex, []];
    } forEach MISSION_CORE_AMMO_CONVOYS;
    MISSION_CORE_AMMO_CONVOYS = MISSION_CORE_AMMO_CONVOYS select { count _x > 0 };
};

// Delivery runs on its OWN frequent loop, separate from the production/request sweeps. Those
// sweeps pay a bounded 25k-node road BFS per uncached pair and have occupied the ammo loop for
// minutes at a time (RPT: "AMMO: supervisor - loop BUSY 300s in stage portProduction/requestTick").
// The convoy tick is the LAST stage of that loop, so an arrival during a long sweep was not
// credited until the sweep finally yielded - convoy 35 (ETA 13:42) did not land until 14:09, and
// six convoys all credited in the same second once the loop freed up. Delivery needs no routing
// and touches only MISSION_CORE_AMMO_CONVOYS, so it is split out here and ticks every 5s no matter
// how long a sweep takes. The main loop still calls the same tick; the two can never interleave
// (no sleep inside the tick), so a double call is a harmless no-op on the second pass.
MISSION_CORE_fnc_ammoDeliveryLoop = {
    while { true } do {
        sleep 5;
        try {
            [] call MISSION_CORE_fnc_ammoConvoyTick;
        } catch {
            diag_log format ["AMMO: deliveryLoop exception - %1", _exception];
        };
    };
};

// Recon interdiction: a landing strike kills whole trucks off an abstract ammo convoy.
// The convoy is abstract (no live truck to blow up), so losing a truck is modelled as
// removing one truck-load of cargo. Killing the last truck destroys the whole convoy.
// Ammo is deliberately all-or-nothing per truck - there is no partial ammo loss.
//
// The ammo system owns the record; recon only tallies the strike. Returns true if at
// least one truck was lost, false if the convoy was already empty or the index is bad.
MISSION_CORE_fnc_ammoShipmentLoseTruck = {
    params ["_index", ["_trucks", 1]];
    if (isNil "MISSION_CORE_AMMO_CONVOYS") exitWith { false };
    if (!(_index isEqualType 0)) exitWith { false };
    if (_index < 0 || { _index >= count MISSION_CORE_AMMO_CONVOYS }) exitWith { false };
    private _convoy = MISSION_CORE_AMMO_CONVOYS select _index;
    if (count _convoy < 9) exitWith { false };
    private _amount = _convoy select 2;
    if (!(_amount isEqualType 1) || { _amount <= 0 }) exitWith { false };
    private _perTruck = ["ammoTruckLoad", 20] call MISSION_CORE_fnc_tune;
    if (!(_perTruck isEqualType 1) || { _perTruck <= 0 }) then { _perTruck = 20; };
    // max/min are INFIX in this engine - (a max b), never (max a b). Written the
    // other way round the whole file fails to parse.
    private _lost = (_perTruck * (_trucks max 1)) min _amount;
    if (_lost <= 0) exitWith { false };
    // Losing cargo angers the enemy - same policy the other logistics systems use.
    [_lost, "Recon strike"] call MISSION_CORE_fnc_convoyLossAggression;
    private _left = _amount - _lost;
    if (_left <= 0) then {
        MISSION_CORE_AMMO_CONVOYS set [_index, []];
        diag_log format ["AMMO: convoy %1 destroyed - all %2 of its ammo lost", _convoy select 4, round _amount];
    } else {
        _convoy set [2, _left];
        diag_log format ["AMMO: convoy %1 lost a truck - %2 of %3 remaining", _convoy select 4, round _left, round _amount];
    };
    true
};

// ---- PORT PRODUCTION ----
// Every tick each port accumulates importance * rate * sizeMult ammo.  When the batch reaches
// the threshold it is shipped abstractly to the EMPTIEST same-side DEPOT that still has room
// (distance only breaks ties).
// PERMANENT RULE (storage roles): the port is the CREATOR; only a depot STORES ammo for
// requestors. See MISSION_RULES.md. Requires depot_ markers to be placed on the map.
MISSION_CORE_fnc_ammoPortProduction = {
    if (isNil "MISSION_CORE_LOCATION_AMMO") exitWith {};
    private _rate = ["ammoPortRatePerImp", 0.5] call MISSION_CORE_fnc_tune;
    private _threshold = ["ammoPortShipThreshold", 20] call MISSION_CORE_fnc_tune;
    {
        private _name = _x select 0;
        private _type = _x select 2;
        private _imp = _x select 7;
        private _owner = _x select 4;
        if (toLower _type != "port") then { continue; };
        private _sizeMult = if (!isNil "MISSION_CORE_PORTS" && { _name in MISSION_CORE_PORTS }) then {
            (MISSION_CORE_PORTS get _name) select 3
        } else { 1.0 };
        private _accum = MISSION_CORE_PORT_AMMO_ACCUM getOrDefault [_name, 0];
        MISSION_CORE_PORT_AMMO_ACCUM set [_name, _accum + (_imp * _rate * _sizeMult)];
        private _newAccum = MISSION_CORE_PORT_AMMO_ACCUM getOrDefault [_name, 0];
        if (_newAccum >= _threshold) then {
            private _candidates = MISSION_CORE_CACHED_POSITIONS select {
                (_x select 4) == _owner &&
                { (_x select 0) != _name } &&
                { toLower (_x select 2) in ["depot"] }
            };
            private _portPos = _x select 1;
            // Emptiest depot first, distance only as a tie-break. Sorting by distance picked the
            // same two depots forever: the nearest ones spend a couple of ammo per own offensive,
            // so they always retained room and always won the sort, while the other ten received
            // nothing at all. Room decides now, so a port's output spreads across the network.
            private _pool = [];
            {
                private _dName = _x select 0;
                private _dRoom = (MISSION_CORE_LOCATION_AMMO_MAX getOrDefault [_dName, 1]) - (MISSION_CORE_LOCATION_AMMO getOrDefault [_dName, 0]);
                if (_dRoom > 0) then {
                    _pool pushBack [_x, _dRoom, (_x select 1) distance _portPos];
                };
            } forEach _candidates;
            // Room DESC then distance ASC: a negative first key so array compare sorts room-first
            // (biggest room = smallest negative) and uses distance only to break ties.
            _pool = [_pool, [], { [-(_x select 1), (_x select 2)] }, "ASCEND"] call BIS_fnc_sortBy;
            // NO BATCH HELD ON A SINGLE PICK. routePlan straight-falls on its own when
            // supplyRouteStraightFallback is on (the default), so a pair that still fails is a
            // genuinely dead one: an endpoint the index does not know, or a degenerate plan. The
            // old code re-picked the SAME emptiest depot every tick and held the batch forever
            // against it, while the next-emptiest depot could have shipped the cargo fine. Walk up
            // to ammoRetryDepots candidates on THIS tick, spending the accumulator only when a
            // dispatch lands and refunding it between attempts.
            private _tryMax = (["ammoRetryDepots", 3] call MISSION_CORE_fnc_tune) max 1;
            if !(_tryMax isEqualType 1) then { _tryMax = 3; };
            private _done = false;
            private _toShip = 0;
            private _i = 0;
            while { !_done && { _i < count _pool } && { _i < _tryMax } } do {
                private _row = _pool select _i;
                private _depotName = (_row select 0) select 0;
                _toShip = ((_threshold min (_row select 1)) max 0);
                // The port's accumulator is the cargo. Spend it for this attempt; the depot is
                // credited only when the convoy lands, and a failed pair gets the batch refunded
                // so the next depot on the list sees the same whole accumulator.
                MISSION_CORE_PORT_AMMO_ACCUM set [_name, _newAccum - _toShip];
                if ([_name, _depotName, _toShip, "portDepot"] call MISSION_CORE_fnc_dispatchAmmoConvoy) then {
                    _done = true;
                    diag_log format ["AMMO: port %1 dispatched %2 to depot %3", _name, round _toShip, _depotName];
                } else {
                    // No usable route to THIS depot: give the batch back and try the next one.
                    MISSION_CORE_PORT_AMMO_ACCUM set [_name, (MISSION_CORE_PORT_AMMO_ACCUM getOrDefault [_name, 0]) + _toShip];
                    diag_log format ["AMMO: port %1 could not route %2 to depot %3 - trying next depot", _name, round _toShip, _depotName];
                };
                _i = _i + 1;
            };
            if (!_done && { count _pool > 0 }) then {
                diag_log format ["AMMO: port %1 could not route %2 to any candidate - batch held", _name, round _toShip];
            };
        };
    } forEach MISSION_CORE_CACHED_POSITIONS;
};

// ---- MULTI-DONOR SHIPMENT ----
// A single "nearest donor" pick retried forever is a deadlock: if the nearest stocked depot
// cannot take the route, the next one over may ship the same cargo fine. This helper walks a
// donor list nearest-first, charging a donor when its convoy is committed and refunding its
// stock unchanged on a failed pair, until one dispatch lands or the list (capped by _tryMax) is
// exhausted. routePlan already straight-falls (supplyRouteStraightFallback), so a pair that
// reaches the "could not route" branch here is a genuinely dead one - endpoint-missing or a
// degenerate plan - and the failure to ship is NOT a reason to hold the cargo hostage.
//
// returns: [true, donorName, shippedAmount] on success, [false, "", 0] when
// every tried donor failed.
// params:  [_depots, _toName, _toGive, _kind, ["_tryMax", 3]]  (_depots: marker records, near->far)
MISSION_CORE_fnc_ammoTryDonors = {
    params ["_depots", "_toName", "_toGive", "_kind", ["_tryMax", 3]];
    private _ok = false;
    private _used = "";
    private _sent = 0;
    private _i = 0;
    private _n = ((count _depots) min (_tryMax max 1));
    while { !_ok && { _i < _n } } do {
        private _depot = _depots select _i;
        private _depotName = _depot select 0;
        private _stock = MISSION_CORE_LOCATION_AMMO getOrDefault [_depotName, 0];
        private _give = (_toGive min _stock) max 0;
        if (_give <= 0) then {
            // Donor cannot cover even a fraction of the ask; the next may. Not a route failure -
            // the stock test in the caller already ran, this is just the shrink-to-fit.
            _i = _i + 1;
            continue;
        };
        // Charge the depot NOW so its stock is committed while the cargo is in transit and
        // cannot be promised to a second requestor. On a failed pair it is refunded whole.
        MISSION_CORE_LOCATION_AMMO set [_depotName, _stock - _give];
        publicVariable "MISSION_CORE_LOCATION_AMMO";
        if ([_depotName, _toName, _give, _kind] call MISSION_CORE_fnc_dispatchAmmoConvoy) then {
            _ok = true;
            _used = _depotName;
            _sent = _give;
            diag_log format ["AMMO: %1 -> %2 shipped %3 from depot %4 [try %5 of %6]", _kind, _toName, round _give, _depotName, _i + 1, _n];
        } else {
            // Unroutable pair - the depot keeps its stock and the walk moves on to the next.
            MISSION_CORE_LOCATION_AMMO set [_depotName, _stock];
            publicVariable "MISSION_CORE_LOCATION_AMMO";
            diag_log format ["AMMO: %1 -> %2 could not route from depot %3 - trying next donor", _kind, _toName, _depotName];
        };
        _i = _i + 1;
    };
    [_ok, _used, _sent]
};

// ---- MARKER AMMO REQUEST ----
// When a marker's ammo drops below 30% of its max it requests from the same-side depots. Any
// marker type may REQUEST except a depot (PERMANENT RULE - see below); only a depot may give
// (storage roles, see MISSION_RULES.md). The port is deliberately NOT a donor: it is the creator
// and ships its production to depots, so treating it as a warehouse would double-count the same
// cargo. Requests are unlimited and law-driven (no cap on parallelism), and a request that wins
// its chance roll while every depot is below the donor floor joins the MISSION_CORE_AMMO_WAITING
// list, which the service pass at the top of this tick drains as soon as any depot has stock.
MISSION_CORE_fnc_ammoRequestTick = {
    if (isNil "MISSION_CORE_LOCATION_AMMO") exitWith {};
    private _requestFrac = ["ammoRequestThreshold", 0.3] call MISSION_CORE_fnc_tune;
    private _maxPerReq = ["ammoMaxPerRequest", 20] call MISSION_CORE_fnc_tune;
    private _cooldown = ["ammoRequestCooldown", 120] call MISSION_CORE_fnc_tune;
    // Request propensity - the SAME curve the resupply channel uses (fn_convoyLoop.sqf), so both
    // resources answer "how important is this marker" with identical arithmetic.
    private _chanceK = ["ammoRequestChancePerWorth", 0.25] call MISSION_CORE_fnc_tune;
    private _chanceMax = ["requestChanceMax", 0.95] call MISSION_CORE_fnc_tune;
    // Donor floor: a depot donates only while it is above this fraction of its own cap (absolute
    // floor for very small depots). Read ONCE per sweep - it gates both the waiting-list service
    // pass and every marker's donor search below.
    private _donorFrac = ["ammoDonorStockFrac", 0.3] call MISSION_CORE_fnc_tune;
    private _donorMin = ["ammoDonorStockMin", 3] call MISSION_CORE_fnc_tune;
    private _retryDepots = (["ammoRetryDepots", 3] call MISSION_CORE_fnc_tune) max 1;
    if !(_retryDepots isEqualType 1) then { _retryDepots = 3; };
    // No depot on the map means there is nobody to request FROM. Without this the tick walks every
    // marker every 10 seconds only to select an empty donor list. This is a guard for a depot-less
    // map, NOT the Altis case: mission.sqm carries depot, depot_1..depot_13, and the bare "depot"
    // marker is the only one NOT registered (fn_markers.sqf only special-cases bare names for
    // Outpost/Powerplant/Solar), so Altis resolves 13 usable depots and this bail-out never fires.
    // The count is read live rather than hardcoded precisely so an editor addition like a new
    // depot_13 shows up here on the next restart instead of leaving a stale number in a comment.
    private _depotCount = count (MISSION_CORE_CACHED_POSITIONS select { toLower (_x select 2) in ["depot"] });
    // PERMANENT RULE: exitWith is NOT legal inside a then { } block - Arma reports it as a bogus
    // "Error Missing ;" pointing at the exitWith line, and it fails the WHOLE file, so every
    // MISSION_CORE_fnc_* defined below would go undefined downstream. See
    // SQF_MISTAKES_AND_FIXES.md section 3. The bail-out must sit at function scope.
    if (_depotCount == 0) exitWith {
        if (MISSION_CORE_DEBUG_AMMO) then {
            diag_log "AMMO REQUEST SWEEP: FAILED - 0 depot markers on the map, depot->marker resupply is impossible";
        };
    };
    // DIAGNOSTICS. The depot->marker half of this channel failed SILENTLY for an entire live
    // session: zero `ordered` lines, zero `depotMarker` convoys, while ports shipped to depots
    // without complaint. Three exits below used to `continue` or return with no log at all, so
    // "no depot on my side", "every depot on my side is under the stock floor" and "routePlan
    // refused" were indistinguishable in the RPT. Every one now records its reason. Counters are
    // exact; exemplar lists are capped at 3 so a 101-marker sweep stays one readable line.
    private _nBelow = 0;
    private _cNoSideDepot = 0;
    private _cNoDonor = 0;
    private _cNoGive = 0;
    private _cRouteFail = 0;
    private _shipped = 0;
    // These gates sit ABOVE every other counter and used to `continue` silently, so a sweep
    // could show below30=3 with every visible reason at zero and no way to tell a chance miss
    // from a queued marker. Every one is now counted so the next run attributes a zero-shipment
    // sweep to a specific gate instead of guessing.
    private _cChanceMiss = 0;
    private _cDepotAsked = 0;   // depots below the trigger, refused by the permanent depot rule
    private _cQueued = 0;       // no-donor markers parked on the waiting list
    private _cServed = 0;       // waiting list entries shipped this sweep
    private _cWaiting = 0;      // markers still parked (kept) after this sweep's service pass
    private _cCooldown = 0;
    private _cContested = 0;
    private _exContested = [];
    private _cEdgeBoost = 0;
    private _exChanceMiss = [];
    // Contested zone list derived ONCE per sweep. The assist edge needs it for every candidate
    // marker, and rebuilding it per marker would mean re-walking MISSION_CORE_CONTESTED 180 times
    // every ten seconds. Empty is a legitimate answer (no zones contested) and the helper treats
    // it as "no edge", so it must NOT be treated as a signal to derive its own.
    private _zoneNames = if (isNil "MISSION_CORE_CONTESTED") then { [] } else { keys MISSION_CORE_CONTESTED };
    private _exNoSideDepot = [];
    private _exNoDonor = [];
    private _exNoGive = [];
    private _exRouteFail = [];
    // WAITING-LIST SERVICE. Rows are markers that won the chance roll but found no donor with
    // stock to give at ask time; they park here rather than being silently dropped, and this pass
    // clears the backlog on every sweep as soon as any same-side depot is back above its donor
    // floor (a port arrival tops the emptiest depot up first, which is usually the one a marker
    // is waiting on). A row is dropped when the marker is gone, was captured (side changed),
    // turned contested, or recovered above the request trigger - a request is not an obligation
    // to dump cargo into a place that no longer wants it. The amount is RE-computed at service
    // time from the marker's current deficit, so a stale ask never over-delivers. The queue is
    // serviced before the fresh rolls below, and a marker that survives this pass is skipped by
    // the roll so it cannot double-ask.
    if (isNil "MISSION_CORE_AMMO_WAITING") then { MISSION_CORE_AMMO_WAITING = []; };
    private _kept = [];
    {
        private _wName = _x select 2;
        private _wSide = _x select 3;
        private _wIdx = MISSION_CORE_CACHED_POSITIONS findIf { (_x select 0) == _wName };
        if (_wIdx < 0) then { continue; };
        private _wLoc = MISSION_CORE_CACHED_POSITIONS select _wIdx;
        if ((_wLoc select 4) != _wSide) then { continue; };
        if (!isNil "MISSION_CORE_CONTESTED" && { _wName in MISSION_CORE_CONTESTED }) then { continue; };
        private _wMax = MISSION_CORE_LOCATION_AMMO_MAX getOrDefault [_wName, 1];
        private _wCur = MISSION_CORE_LOCATION_AMMO getOrDefault [_wName, 0];
        if (_wMax > 0 && { (_wCur / _wMax) >= _requestFrac }) then { continue; };
        private _wDonors = MISSION_CORE_CACHED_POSITIONS select {
            (_x select 4) == (_wLoc select 4) &&
            { (_x select 0) != _wName } &&
            { toLower (_x select 2) in ["depot"] } &&
            { (MISSION_CORE_LOCATION_AMMO getOrDefault [_x select 0, 0]) > (((MISSION_CORE_LOCATION_AMMO_MAX getOrDefault [_x select 0, 1]) * _donorFrac) max _donorMin) }
        };
        if (count _wDonors == 0) then {
            // No donor has stock yet - keep waiting.
            _kept pushBack _x;
            continue;
        };
        _wDonors = [_wDonors, [], { (_x select 1) distance2D (_wLoc select 1) }, "ASCEND"] call BIS_fnc_sortBy;
        private _wGive = ((_wMax - _wCur) min _maxPerReq) max 0;
        if (_wGive <= 0) then { continue; };
        private _done = [_wDonors, _wName, _wGive, "depotMarker", _retryDepots] call MISSION_CORE_fnc_ammoTryDonors;
        if (_done select 0) then {
            MISSION_CORE_AMMO_REQUEST_CD set [_wName, time];
            _shipped = _shipped + 1;
            _cServed = _cServed + 1;
            diag_log format ["AMMO WAITING: %1 served %2 from depot %3", _wName, round (_done select 2), _done select 1];
        } else {
            // Donors exist but none could take the route this sweep - keep the row, retry later.
            _kept pushBack _x;
        };
    } forEach MISSION_CORE_AMMO_WAITING;
    MISSION_CORE_AMMO_WAITING = _kept;
    private _waitingNames = _kept apply { _x select 2 };
    {
        private _loc = _x;
        private _name = _x select 0;
        private _owner = _x select 4;
        private _pos = _x select 1;
        private _maxAmmo = MISSION_CORE_LOCATION_AMMO_MAX getOrDefault [_name, 1];
        private _current = MISSION_CORE_LOCATION_AMMO getOrDefault [_name, 0];
        private _fraction = if (_maxAmmo > 0) then { _current / _maxAmmo } else { 1 };
        if (_fraction >= _requestFrac) then { continue; };
        _nBelow = _nBelow + 1;
        // PERMANENT RULE: a depot NEVER requests ammo. Depots are the warehouses of the network -
        // port production fills them (portDepot) and every other marker drains them (depotMarker).
        // A depot that is low asking a depot for ammo would shuffle the same stock sideways while
        // the marker that actually fires stays dry. Counted so a hungry depot is visible in the
        // sweep line instead of being an invisible skip.
        if (toLower (_x select 2) in ["depot"]) then {
            _cDepotAsked = _cDepotAsked + 1;
            continue;
        };
        // PERMANENT RULE: a contested marker is never resupplied, on either channel. Counted here so
        // the ban is visible in the sweep instead of being an invisible exclusion - a marker sitting
        // below the trigger while contested would otherwise look exactly like one that was ignored.
        // Counted BEFORE the cooldown test so it reports the true number of refused markers.
        if (!isNil "MISSION_CORE_CONTESTED" && { _name in MISSION_CORE_CONTESTED }) then {
            _cContested = _cContested + 1;
            if (count _exContested < 3) then { _exContested pushBack _name; };
            continue;
        };
        private _lastReq = MISSION_CORE_AMMO_REQUEST_CD getOrDefault [_name, -9999];
        if (time - _lastReq < _cooldown) then { _cCooldown = _cCooldown + 1; continue; };
        // Already parked on the waiting list - its request is on file and the service pass at the
        // top of this sweep just re-evaluated it. Letting the roll also fire would re-queue the
        // same marker or double-count a route failure, so a queued marker is skipped and the queue
        // stays the single source of truth until stock shows up or the row expires.
        if (_name in _waitingNames) then { _cWaiting = _cWaiting + 1; continue; };

        // Worth scales the roll, exactly as in the resupply channel: the REQUESTER stays in charge
        // of its own request (its shortfall sets urgency, its worth sets the odds) and the depot
        // below is only where the goods come from.
        private _deficitFrac = ((_requestFrac - _fraction) / (_requestFrac max 0.01)) min 1;
        private _urgency = 0.1 + (0.9 * _deficitFrac);
        private _worth = 1;
        // Guarded: fn_aiCommander.sqf compiles the helper but is not preprocessed until
        // fn_init.sqf:335, while this loop is spawned at :235 and first ticks at t+10s. Neutral
        // worth 1.0 keeps the old flat behaviour for that window instead of erroring.
        if (!isNil "MISSION_CORE_fnc_markerWorth") then {
            _worth = ([_loc] call MISSION_CORE_fnc_markerWorth) select 2;
        };
        // Slight priority for a marker actively helping a contested zone. Applied as a multiplier
        // BEFORE the cap, so it can never lift a starving marker above a comfortable one - it
        // shifts volume, not rank. _zoneNames is derived once per sweep below, not per marker.
        private _edge = [_loc, "ammoContestedAssistEdge", _zoneNames] call MISSION_CORE_fnc_contestedAssistEdge;
        if (_edge > 1) then { _cEdgeBoost = _cEdgeBoost + 1; };
        private _chance = (((_worth * _urgency * _chanceK * _edge) min _chanceMax) max 0);
        if (random 1 > _chance) then {
            _cChanceMiss = _cChanceMiss + 1;
            if (count _exChanceMiss < 3) then { _exChanceMiss pushBack format ["%1(chance %2 edge %3)", _name, round (_chance * 100) / 100, round (_edge * 100) / 100]; };
            continue;
        };

        // The side/type filters and the donor stock floor used to be ONE `select`, so an empty
        // donor list could mean either "this side has no depot at all" or "all of them are under
        // the stock floor". Those need different fixes, so they are split apart here to name the
        // cause. The floor itself is a fraction of each depot's OWN cap rather than the absolute
        // 10 it used to be: 10 was 80-100% of a full depot on this map, which excluded every depot
        // of 10 or less even when completely stocked. Proven on a live RPT: caps vary by marker
        // (roughly 9-13 before the x2 multiplier) and the best-stocked depot on the whole side
        // still read 6/13, so no depot ever cleared an absolute floor of 10.
        private _sameSide = MISSION_CORE_CACHED_POSITIONS select {
            (_x select 4) == _owner &&
            { (_x select 0) != _name } &&
            { toLower (_x select 2) in ["depot"] }
        };
        private _depots = _sameSide select {
            (MISSION_CORE_LOCATION_AMMO getOrDefault [_x select 0, 0]) >
                (((MISSION_CORE_LOCATION_AMMO_MAX getOrDefault [_x select 0, 1]) * _donorFrac) max _donorMin)
        };
        if (count _depots == 0) then {
            if (count _sameSide == 0) then {
                // No waiting-list entry here: a side with zero depots has no door for stock to
                // appear through, so a parked request could never be served and would just leak.
                _cNoSideDepot = _cNoSideDepot + 1;
                if (count _exNoSideDepot < 3) then { _exNoSideDepot pushBack _name; };
            } else {
                _cNoDonor = _cNoDonor + 1;
                // Report the BEST-stocked same-side depot and how far it is. If it sits at or under
                // its own donor floor the stock floor is the wall; if it is well over, the floor is
                // not the problem and the next gate is.
                private _bestName = ""; private _bestAmmo = -1; private _bestDist = 0;
                {
                    private _a = MISSION_CORE_LOCATION_AMMO getOrDefault [_x select 0, 0];
                    if (_a > _bestAmmo) then {
                        _bestAmmo = _a;
                        _bestName = _x select 0;
                        _bestDist = _pos distance2D (_x select 1);
                    };
                } forEach _sameSide;
                if (MISSION_CORE_DEBUG_AMMO && { count _exNoDonor < 3 }) then {
                    _exNoDonor pushBack format ["%1(best %2 ammo=%3/%4 at %5m)", _name, _bestName, _bestAmmo, (MISSION_CORE_LOCATION_AMMO_MAX getOrDefault [_bestName, 0]), round _bestDist];
                };
                // PARK IT, DO NOT DROP IT. The marker won the chance roll above but no same-side
                // depot currently has stock to give - a temporary state that a port arrival fixes.
                // Instead of a silent skip (which threw the win away and re-rolled the dead end
                // every sweep), queue the request with the asking marker APPENDED to the row:
                // [give, whenAsked, askingMarker, side]. Deduped by marker - a marker that keeps
                // rolling while it waits refreshes its amount, not its identity.
                private _wRow = [(((_maxAmmo - _current) min _maxPerReq) max 0), time, _name, _owner];
                private _wAt = MISSION_CORE_AMMO_WAITING findIf { (_x select 2) == _name };
                if (_wAt >= 0) then {
                    MISSION_CORE_AMMO_WAITING set [_wAt, _wRow];
                } else {
                    MISSION_CORE_AMMO_WAITING pushBack _wRow;
                };
                _cQueued = _cQueued + 1;
            };
            continue;
        };
        _depots = [_depots, [], { (_x select 1) distance _pos }, "ASCEND"] call BIS_fnc_sortBy;
        private _deficit = _maxAmmo - _current;
        private _toGive = (_deficit min _maxPerReq) max 0;
        if (_toGive <= 0) then {
            // A stocked donor was found and still nothing to move: the requester's deficit
            // rounded to zero. Previously invisible.
            _cNoGive = _cNoGive + 1;
            if (count _exNoGive < 3) then {
                _exNoGive pushBack format ["%1 deficit=%2", _name, round _deficit];
            };
        } else {
            // Try the nearest stocked donors in turn, not just the single nearest one. routePlan
            // straight-falls on its own when supplyRouteStraightFallback is on (the default), so
            // a pair that reaches the "could not route" branch is a genuinely dead one: an
            // endpoint the index does not know, or a leg shorter than routePlan's 50m floor. The
            // old code retried that one impossible pair forever while the next depot over could
            // have shipped the same cargo. On success the cooldown starts here for the same reason
            // as before: a marker must not re-order every tick while its shipment is on the road.
            private _done = [_depots, _name, _toGive, "depotMarker", _retryDepots] call MISSION_CORE_fnc_ammoTryDonors;
            if (_done select 0) then {
                MISSION_CORE_AMMO_REQUEST_CD set [_name, time];
                _shipped = _shipped + 1;
                // worth/chance logged so the propensity curve is tunable from the RPT rather than by guesswork.
                diag_log format ["AMMO: %1 ordered %2 from depot %3 [worth %4, chance %5]", _name, round (_done select 2), _done select 1, round (_worth * 10) / 10, round (_chance * 100) / 100];
            } else {
                // Name WHY against the nearest donor. supplyRoute is memoised, so re-asking for
                // the classification is a cache hit, not a second search. With
                // supplyRouteStraightFallback on (the default) an unroutable pair still SHIPS on a
                // straight line and never reaches this branch - what lands here is a genuinely
                // dead pair: an endpoint the index does not know, or a leg shorter than routePlan's
                // 50m floor, or the fallback disabled by tune. There is deliberately NO proximity
                // branch - ammo has no "too close to resupply" rule, so a short leg can never be
                // the reason (it was previously mislabelled TOO-CLOSE against supplyRouteSnapBase).
                private _idx = call MISSION_CORE_fnc_locIndex;
                private _firstDonor = (_depots select 0) select 0;
                private _why = if ((_idx getOrDefault [_name, -1]) < 0 || { (_idx getOrDefault [_firstDonor, -1]) < 0 }) then { "ENDPOINT-MISSING" } else { "UNROUTABLE" };
                _cRouteFail = _cRouteFail + 1;
                if (count _exRouteFail < 3) then { _exRouteFail pushBack format ["%1<-%2 %3", _name, _firstDonor, _why]; };
            };
        };
    } forEach MISSION_CORE_CACHED_POSITIONS;
    // One line per sweep, so the shape of the failure is legible without a full log dump.
    if (MISSION_CORE_DEBUG_AMMO) then {
        diag_log format ["AMMO REQUEST SWEEP: markers=%1 below30=%2 depots=%3 | chanceMiss=%4[%5] depotReq=%6 queued=%7 served=%8 waiting=%9 | cooldown=%10 contested=%11[%12] edgeBoost=%13 | noSideDepot=%14[%15] noDonorUnderFloor=%16[%17] noGive=%18[%19] routeFail=%20[%21] shipped=%22", count MISSION_CORE_CACHED_POSITIONS, _nBelow, _depotCount, _cChanceMiss, (_exChanceMiss joinString " "), _cDepotAsked, _cQueued, _cServed, _cWaiting, _cCooldown, _cContested, (_exContested joinString " "), _cEdgeBoost, _cNoSideDepot, (_exNoSideDepot joinString " "), _cNoDonor, (_exNoDonor joinString " "), _cNoGive, (_exNoGive joinString " "), _cRouteFail, (_exRouteFail joinString " "), _shipped];
    };
};

// ---- MAIN LOOP ----
// HEARTBEAT-FIRST. MISSION_CORE_AMMO_LOOP_TICK is written at the TOP of every iteration, before
// any work, so a tick that errors partway through still leaves a fresh timestamp behind: the
// supervisor then cannot confuse "this loop crashed" with "this loop is busy". Same idiom and
// same 90s threshold as MISSION_CORE_PLAYER_ARTY in fn_recruitServer.sqf.
//
// WHY A SUPERVISOR IS REQUIRED AND try/catch IS NOT. The loop died for real on 17:05:05 with no
// restart until 17:21:48 and no AMMO line for sixteen minutes, while every other loop kept
// logging. There is no script error anywhere near it in the RPT. The three blocks below cannot
// have been the fix, for two independent reasons:
//   1. try/catch only catches an explicit `throw`, and this mission contains ZERO throw
//      statements - the catch arms were unreachable.
//   2. Per the wiki, SQF runtime faults (zero divisor, ill-typed argument, undefined variable)
//      raise a COMPILATION exception that this try/catch structure cannot catch at all. They
//      halt the running script, which is precisely the failure being defended against.
// So the isolation was decorative. An SQF error halts the scheduled script outright, and the
// only recovery is to notice it stopped and start it again - hence the supervisor below.
MISSION_CORE_fnc_ammoLoop = {
    diag_log "AMMO: loop started";
    MISSION_CORE_AMMO_STAGE = "start";
    while { true } do {
        MISSION_CORE_AMMO_LOOP_TICK = time;
        sleep 10;
        // These three stay separated rather than merged into one shared try: production runs
        // BEFORE the request tick, so a single block would still let a fault in the first stage
        // mask the sweep line. Kept for explicit throws should any ever be added.
        //
        // STAGE MARKERS, written before each call and NEVER logged here. The 17:05:05 death left
        // only the sweep line - the END of the request tick - as evidence, so it was impossible to
        // tell which of the three stages actually halted. The supervisor prints this variable when
        // it detects staleness, which names the stage for free without adding three log lines to
        // every 10s pass. Write-then-call, so a stage that throws has already stamped its name.
        MISSION_CORE_AMMO_STAGE = "portProduction";
        try {
            [] call MISSION_CORE_fnc_ammoPortProduction;
        } catch {
            diag_log format ["AMMO: portProduction exception - %1", _exception];
        };
        MISSION_CORE_AMMO_STAGE = "requestTick";
        try {
            [] call MISSION_CORE_fnc_ammoRequestTick;
        } catch {
            diag_log format ["AMMO: requestTick exception - %1", _exception];
        };
        MISSION_CORE_AMMO_STAGE = "convoyTick";
        try {
            [] call MISSION_CORE_fnc_ammoConvoyTick;
        } catch {
            diag_log format ["AMMO: convoyTick exception - %1", _exception];
        };
        MISSION_CORE_AMMO_STAGE = "idle";
    };
};

// Supervisor: restart ammo if the loop has not heartbeat in 5 minutes. The loop writes its tick
// at the top of each pass, and its work (road search, not waits) can legitimately outlast a pass,
// so a stale tick alone cannot distinguish a dead script from a busy one. The handle decides:
// scriptDone true means the scheduled script halted (SQF error or other) and needs a restart;
// scriptDone false means it is still alive but blocked on CPU work, which belongs to it, not to a
// duplicate - spawning a second worker while the first is mid-search doubles the same search and
// makes the slowdown that caused the staleness worse. The tick is refreshed on BOTH branches so
// the supervisor stands down for another 5 minutes and does not re-log on its own 30s cadence;
// the BUSY line is then a 5-minute heartbeat of truth rather than a repeated noise.
MISSION_CORE_fnc_ammoSupervisor = {
    while { true } do {
        sleep 30;
        // Its own stamp, written before the check. Without it a supervisor that halts is
        // indistinguishable from a healthy one that simply found nothing to do - both produce
        // silence - and the ammo loop would then die for good with no one left to recover it.
        // groupMaintenance reads this stamp and reports it, so the regress stops here rather
        // than needing a supervisor for the supervisor.
        missionNamespace setVariable ["MISSION_CORE_AMMO_SUPERVISOR_TICK", time];
        // Stamped separately from MISSION_CORE_AMMO_STAGE on purpose: that one names the LOOP's
        // phase, and reading it under a supervisor label would claim the supervisor died inside
        // "requestTick" when the supervisor has no such phase at all.
        missionNamespace setVariable ["MISSION_CORE_AMMO_SUPERVISOR_STAGE", "running"];
        private _stale = time - (missionNamespace getVariable ["MISSION_CORE_AMMO_LOOP_TICK", -1e10]);
        if (_stale > 300) then {
            private _h = missionNamespace getVariable ["MISSION_CORE_AMMO_LOOP_HANDLE", scriptNull];
            if (scriptDone _h) then {
                diag_log format ["AMMO: supervisor - loop DEAD after %1s, restarting (last stage: %2)", round _stale, missionNamespace getVariable ["MISSION_CORE_AMMO_STAGE", "unknown"]];
                missionNamespace setVariable ["MISSION_CORE_AMMO_LOOP_TICK", time];
                MISSION_CORE_AMMO_LOOP_HANDLE = [] spawn MISSION_CORE_fnc_ammoLoop;
            } else {
                diag_log format ["AMMO: supervisor - loop BUSY %1s in stage %2, not restarting", round _stale, missionNamespace getVariable ["MISSION_CORE_AMMO_STAGE", "unknown"]];
                missionNamespace setVariable ["MISSION_CORE_AMMO_LOOP_TICK", time];
            };
        };
    };
};