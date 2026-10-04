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

MISSION_CORE_fnc_initAmmo = {
    if (isNil "MISSION_CORE_LOCATION_AMMO") then { MISSION_CORE_LOCATION_AMMO = createHashMap; };
    if (isNil "MISSION_CORE_LOCATION_AMMO_MAX") then { MISSION_CORE_LOCATION_AMMO_MAX = createHashMap; };
    if (isNil "MISSION_CORE_PORT_AMMO_ACCUM") then { MISSION_CORE_PORT_AMMO_ACCUM = createHashMap; };
    if (isNil "MISSION_CORE_AMMO_REQUEST_CD") then { MISSION_CORE_AMMO_REQUEST_CD = createHashMap; };
    if (isNil "MISSION_CORE_AMMO_CONVOYS") then { MISSION_CORE_AMMO_CONVOYS = []; };
    if (isNil "MISSION_CORE_AMMO_CONVOY_ID") then { MISSION_CORE_AMMO_CONVOY_ID = 0; };
    // Ammo shipments draw from the SHARED convoy id counter. See the dispatch function for why
    // a private counter leaks map icons.
    if (isNil "MISSION_CORE_CONVOY_ID") then { MISSION_CORE_CONVOY_ID = 0; };
    private _base = ["ammoBasePerImp", 20] call MISSION_CORE_fnc_tune;
    {
        private _name = _x select 0;
        private _imp = _x select 7;
        private _area = _x select 8;
        private _sizeA = _area select 0;
        private _sizeB = _area select 1;
        private _sizeFactor = (sqrt (_sizeA * _sizeB) / 150) min 2;
        private _maxAmmo = floor (_imp * _base * _sizeFactor);
        MISSION_CORE_LOCATION_AMMO_MAX set [_name, _maxAmmo];
        MISSION_CORE_LOCATION_AMMO set [_name, floor (_maxAmmo * 0.5)];
    } forEach MISSION_CORE_CACHED_POSITIONS;
    publicVariable "MISSION_CORE_LOCATION_AMMO_MAX";
    publicVariable "MISSION_CORE_LOCATION_AMMO";
    diag_log format ["AMMO: initialized %1 markers (base=%2)", count MISSION_CORE_LOCATION_AMMO, _base];
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
    if (isNil "MISSION_CORE_AMMO_CONVOYS") then { MISSION_CORE_AMMO_CONVOYS = []; };
    if (isNil "MISSION_CORE_AMMO_CONVOY_ID") then { MISSION_CORE_AMMO_CONVOY_ID = 0; };
    private _speed = ["ammoConvoySpeed", 14] call MISSION_CORE_fnc_tune;
    // Ammo legs are marker-to-marker, so the "too short to ship" floor is the
    // road snapping base rather than a convoy-scale distance.
    private _plan = [_fromName, _toName, _speed, (["supplyRouteSnapBase", 300] call MISSION_CORE_fnc_tune)] call MISSION_CORE_fnc_routePlan;
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
// the threshold it is shipped abstractly to the nearest same-side DEPOT that has room.
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
            private _depots = MISSION_CORE_CACHED_POSITIONS select {
                (_x select 4) == _owner &&
                { (_x select 0) != _name } &&
                { toLower (_x select 2) in ["depot"] } &&
                { (MISSION_CORE_LOCATION_AMMO getOrDefault [_x select 0, 0]) < (MISSION_CORE_LOCATION_AMMO_MAX getOrDefault [_x select 0, 1]) }
            };
            if (count _depots > 0) then {
                private _portPos = _x select 1;
                _depots = [_depots, [], { (_x select 1) distance _portPos }, "ASCEND"] call BIS_fnc_sortBy;
                private _depot = _depots select 0;
                private _depotName = _depot select 0;
                private _depotMax = MISSION_CORE_LOCATION_AMMO_MAX getOrDefault [_depotName, 1];
                private _depotCur = MISSION_CORE_LOCATION_AMMO getOrDefault [_depotName, 0];
                private _room = _depotMax - _depotCur;
                private _toShip = (_threshold min _room) max 0;
                if (_toShip > 0) then {
                    // The port's accumulator is the cargo. Spend it now and put the batch on the
                    // road; the depot is credited when the convoy lands, not when it leaves.
                    MISSION_CORE_PORT_AMMO_ACCUM set [_name, _newAccum - _toShip];
                    if ([_name, _depotName, _toShip, "portDepot"] call MISSION_CORE_fnc_dispatchAmmoConvoy) then {
                        diag_log format ["AMMO: port %1 dispatched %2 to depot %3", _name, round _toShip, _depotName];
                    } else {
                        // No usable route: the batch never left the port, so give it back.
                        MISSION_CORE_PORT_AMMO_ACCUM set [_name, (MISSION_CORE_PORT_AMMO_ACCUM getOrDefault [_name, 0]) + _toShip];
                        diag_log format ["AMMO: port %1 could not route %2 to depot %3 - batch held", _name, round _toShip, _depotName];
                    };
                };
            };
        };
    } forEach MISSION_CORE_CACHED_POSITIONS;
};

// ---- MARKER AMMO REQUEST ----
// When a marker's ammo drops below 30% of its max it requests from the nearest same-side depot.
// Any marker type may REQUEST; only a depot may give (PERMANENT RULE - storage roles, see
// MISSION_RULES.md). The port is deliberately NOT a donor: it is the creator and ships its
// production to depots, so treating it as a warehouse would double-count the same cargo.
MISSION_CORE_fnc_ammoRequestTick = {
    if (isNil "MISSION_CORE_LOCATION_AMMO") exitWith {};
    private _requestFrac = ["ammoRequestThreshold", 0.3] call MISSION_CORE_fnc_tune;
    private _maxPerReq = ["ammoMaxPerRequest", 20] call MISSION_CORE_fnc_tune;
    private _cooldown = ["ammoRequestCooldown", 120] call MISSION_CORE_fnc_tune;
    // Request propensity - the SAME curve the resupply channel uses (fn_convoyLoop.sqf), so both
    // resources answer "how important is this marker" with identical arithmetic.
    private _chanceK = ["ammoRequestChancePerWorth", 0.25] call MISSION_CORE_fnc_tune;
    private _chanceMax = ["requestChanceMax", 0.95] call MISSION_CORE_fnc_tune;
    private _skipProviders = (["requestSkipActiveProviders", 1] call MISSION_CORE_fnc_tune) > 0;
    // No depot on the map means there is nobody to request FROM. Without this the tick walks every
    // marker every 10 seconds only to select an empty donor list. This is a guard for a depot-less
    // map, NOT the Altis case: mission.sqm carries depot, depot_1..depot_12, and the bare "depot"
    // marker is the only one NOT registered (fn_markers.sqf only special-cases bare names for
    // Outpost/Powerplant/Solar), so Altis resolves 12 usable depots and this bail-out never fires.
    private _depotCount = count (MISSION_CORE_CACHED_POSITIONS select { toLower (_x select 2) in ["depot"] });
    // PERMANENT RULE: exitWith is NOT legal inside a then { } block - Arma reports it as a bogus
    // "Error Missing ;" pointing at the exitWith line, and it fails the WHOLE file, so every
    // MISSION_CORE_fnc_* defined below would go undefined downstream. See
    // SQF_MISTAKES_AND_FIXES.md section 3. The bail-out must sit at function scope.
    if (_depotCount == 0) exitWith {};
    {
        private _loc = _x;
        private _name = _x select 0;
        private _owner = _x select 4;
        private _pos = _x select 1;
        private _maxAmmo = MISSION_CORE_LOCATION_AMMO_MAX getOrDefault [_name, 1];
        private _current = MISSION_CORE_LOCATION_AMMO getOrDefault [_name, 0];
        private _fraction = if (_maxAmmo > 0) then { _current / _maxAmmo } else { 1 };
        if (_fraction >= _requestFrac) then { continue; };
        private _lastReq = MISSION_CORE_AMMO_REQUEST_CD getOrDefault [_name, -9999];
        if (time - _lastReq < _cooldown) then { continue; };

        // A marker with a shipment already on the road to another marker is PROVIDING, not
        // requesting. Rows are deleted on arrival and on recon loss, so an outbound row honestly
        // means "in transit right now" - the one reliable live-provider signal here. MISSION_CORE_COMMIT
        // is no use for this on the ammo side: it is cumulative and only clears when players take
        // the marker, so testing it would permanently mute any depot that had ever given once.
        // Restricted to the depot->marker kind on purpose: a port shipping a batch out to a depot
        // is production, not service to a requestor, and must not mute the port's own needs.
        if (_skipProviders && { !isNil "MISSION_CORE_AMMO_CONVOYS" }) then {
            private _busy = MISSION_CORE_AMMO_CONVOYS findIf {
                ((_x select 5) == "depotMarker") && { (_x select 0) == _name }
            };
            if (_busy >= 0) then { continue; };
        };

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
        private _chance = (((_worth * _urgency * _chanceK) min _chanceMax) max 0);
        if (random 1 > _chance) then { continue; };

        private _depots = MISSION_CORE_CACHED_POSITIONS select {
            (_x select 4) == _owner &&
            { (_x select 0) != _name } &&
            { toLower (_x select 2) in ["depot"] } &&
            { (MISSION_CORE_LOCATION_AMMO getOrDefault [_x select 0, 0]) > 10 }
        };
        if (count _depots == 0) then { continue; };
        _depots = [_depots, [], { (_x select 1) distance _pos }, "ASCEND"] call BIS_fnc_sortBy;
        private _depot = _depots select 0;
        private _depotName = _depot select 0;
        private _depotAmmo = MISSION_CORE_LOCATION_AMMO getOrDefault [_depotName, 0];
        private _deficit = _maxAmmo - _current;
        private _toGive = (_deficit min _maxPerReq min _depotAmmo) max 0;
        if (_toGive > 0) then {
            // Charge the depot NOW so its stock is committed while the cargo is in transit and
            // cannot be promised to a second requestor, then start the cooldown for the same
            // reason: a marker must not re-order every tick while its shipment is still on the road.
            MISSION_CORE_LOCATION_AMMO set [_depotName, _depotAmmo - _toGive];
            publicVariable "MISSION_CORE_LOCATION_AMMO";
            if ([_depotName, _name, _toGive, "depotMarker"] call MISSION_CORE_fnc_dispatchAmmoConvoy) then {
                MISSION_CORE_AMMO_REQUEST_CD set [_name, time];
                // worth/chance logged so the propensity curve is tunable from the RPT rather than by guesswork.
                diag_log format ["AMMO: %1 ordered %2 from depot %3 [worth %4, chance %5]", _name, round _toGive, _depotName, round (_worth * 10) / 10, round (_chance * 100) / 100];
            } else {
                // Unroutable: nothing moved, so the depot keeps its stock and the marker may
                // retry as soon as the cooldown allows.
                MISSION_CORE_LOCATION_AMMO set [_depotName, _depotAmmo];
                publicVariable "MISSION_CORE_LOCATION_AMMO";
            };
        };
    } forEach MISSION_CORE_CACHED_POSITIONS;
};

// ---- MAIN LOOP ----
MISSION_CORE_fnc_ammoLoop = {
    diag_log "AMMO: loop started";
    while { true } do {
        sleep 10;
        [] call MISSION_CORE_fnc_ammoPortProduction;
        [] call MISSION_CORE_fnc_ammoRequestTick;
        [] call MISSION_CORE_fnc_ammoConvoyTick;
    };
};