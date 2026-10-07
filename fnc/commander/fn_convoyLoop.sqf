// =====================================================================
// SUPPLY CONVOYS
// Supply moves between REDFOR markers as physical trucks, not instant
// numeric credit. A convoy is first tracked ABSTRACTLY: its position is
// interpolated along the ROAD path connecting provider->recipient each
// tick. Only when a player is within 1200m of that position does it
// MATERIALIZE into real trucks driving the remaining road path. On arrival
// the recipient receives the supply; if destroyed the supply is lost and
// an ammo box drops for the player to loot.
// =====================================================================

// The road search, the polyline maths and the truck-count rule are NOT defined here. They live in
// fn_supplyRoutes.sqf, compiled early by fn_init and shared with the ammo shipments - one router,
// one route cache, so a route resolved for a supply convoy is already known to anything else moving
// goods. fn_recon and fn_tankOrderLoop call convoyPosAt from there too, so no consumer needs to
// know which file owns it.

// PERMANENT RULE (storage roles, see MISSION_RULES.md): only a BASE may be drained to supply
// another marker. Every marker keeps its own local pool for its own garrison, but a RESUPPLY
// ORDER can only ever leave a base. Takes the cached marker record, not the name, so the
// storers list can be filtered without a second lookup per marker.
MISSION_CORE_fnc_canSupplyConvoyMarker = {
    params ["_loc"];
    if (isNil "_loc" || { count _loc < 3 }) exitWith { false };
    (toLower (_loc select 2)) == "base"
};

// ---- RESUPPLY ORDERS ----
// A marker that has been used as a reinforcement sender (or has simply been ground down) can be
// ELIGIBLE for a resupply order from a storer. This is the channel the storage rule governs: it
// is the only path where "only a base may supply another marker" applies.
//
// It is deliberately SEPARATE from the reinforcement call in fn_requestReinforcement.sqf. That
// call pays the SENDER out of the sender's own pool and may use ANY marker as its sender, because
// reinforcement men walk there under their own power - they are not shipped. Gating that call on
// the storer rule would have made reinforcement free for every non-base sender.
MISSION_CORE_fnc_resupplyDispatch = {
    if (isNil "MISSION_CORE_CACHED_POSITIONS") exitWith {};
    if (isNil "MISSION_CORE_LOCATION_SUPPLY") then { MISSION_CORE_LOCATION_SUPPLY = createHashMap; };
    if (isNil "MISSION_CORE_RESUPPLY_CD") then { MISSION_CORE_RESUPPLY_CD = createHashMap; };
    private _side = if (!isNil "MISSION_CORE_REDFOR_SIDE") then { MISSION_CORE_REDFOR_SIDE } else { EAST };

    private _trigger = (["resupplyTriggerFrac", 0.35] call MISSION_CORE_fnc_tune);
    private _topUp = (["resupplyTopUpAmount", 60] call MISSION_CORE_fnc_tune);
    private _reserve = (["resupplyStorerReserve", 40] call MISSION_CORE_fnc_tune);
    private _cooldown = (["resupplyCooldown", 300] call MISSION_CORE_fnc_tune);
    // A storer below this keeps its stock for its own garrison instead of shipping it away.
    private _storerFloor = (["resupplyStorerFloor", 30] call MISSION_CORE_fnc_tune);
    // Request propensity: chance = worth * urgency * this, capped at requestChanceMax. worth comes
    // from the shared MISSION_CORE_fnc_markerWorth (own tier value x neighbour proximity, 1.0-4.0),
    // so a factory beside an HQ recovers almost every sweep while a minor outpost trickles.
    private _chanceK = (["resupplyChancePerWorth", 0.25] call MISSION_CORE_fnc_tune);
    private _chanceMax = (["requestChanceMax", 0.95] call MISSION_CORE_fnc_tune);
    if (_topUp < 1) then { _topUp = 60; };

    // Storers are resolved up front and are bases by construction, so a town can never be
    // promoted into a supplier further down.
    private _storers = MISSION_CORE_CACHED_POSITIONS select {
        ([_x] call MISSION_CORE_fnc_canSupplyConvoyMarker) &&
        { (_x select 4) == _side } &&
        { (MISSION_CORE_LOCATION_SUPPLY getOrDefault [_x select 0, 0]) >= (_reserve + _topUp) }
    };
    private _noStore = count _storers == 0;
    if (_noStore) then { diag_log "DYNAMIC RESUPPLY: no base storer holds enough stock to order"; };

    // Contested zone list derived ONCE per sweep for the assist edge below, not once per marker.
    private _zoneNames = if (isNil "MISSION_CORE_CONTESTED") then { [] } else { keys MISSION_CORE_CONTESTED };

    {
        private _loc = _x;
        private _name = _loc select 0;
        if (([_loc] call MISSION_CORE_fnc_canSupplyConvoyMarker)) then { continue; };
        if (_noStore) then { continue; };
        if (!isNil "MISSION_CORE_CONTESTED" && { _name in MISSION_CORE_CONTESTED }) then { continue; };

        // Low relative to what the marker is worth, so a trivial outpost is not ordering stock
        // while a major factory is starving.
        private _floor = (((_loc select 7) * _trigger * 100) max 1);
        private _stock = MISSION_CORE_LOCATION_SUPPLY getOrDefault [_name, 0];
        if (_stock > _floor) then { continue; };
        private _last = MISSION_CORE_RESUPPLY_CD getOrDefault [_name, -9999];
        if (time - _last < _cooldown) then { continue; };

        // ---- HOW BADLY does THIS marker want it? ----
        // Deliberately still the REQUESTER that decides everything: its own pool sets the floor,
        // its own shortfall sets the urgency, and its own worth sets how likely the roll is. The
        // storer below is only a place to buy from.
        //
        // urgency runs 0.1 at the floor to 1.0 when empty, and the 0.1 floor matters: the stock
        // test above only skips when _stock > _floor, so a marker sitting EXACTLY on its floor
        // does reach here. Without the baseline its chance would be 0 and it would never order.
        //
        // A failed roll costs nothing - the cooldown is stamped further down only when a convoy
        // really leaves, so the next sweep simply tries again.
        private _deficitFrac = ((_floor - _stock) / (_floor max 1)) min 1;
        private _urgency = 0.1 + (0.9 * _deficitFrac);
        private _worth = 1;
        // Guarded: the ammo/convoy loops are spawned at fn_init.sqf:235 but this file is not
        // compiled until :335, so on a slow init the helper can legitimately be missing here.
        // Neutral worth 1.0 is the conservative fallback - the marker simply keeps its old chance.
        if (!isNil "MISSION_CORE_fnc_markerWorth") then {
            _worth = ([_loc] call MISSION_CORE_fnc_markerWorth) select 2;
        };
        // Same contested-assist edge the ammo channel uses, resolved by the same helper so the two
        // channels cannot drift apart about who counts as helping a contested zone. Multiplier
        // applied BEFORE the cap, so it shifts volume and never rank.
        private _edge = [_loc, "resupplyContestedAssistEdge", _zoneNames] call MISSION_CORE_fnc_contestedAssistEdge;
        private _chance = (((_worth * _urgency * _chanceK * _edge) min _chanceMax) max 0);
        if (random 1 > _chance) then { continue; };

        private _cands = _storers select { (_x select 4) == (_loc select 4) };
        if (count _cands == 0) then { continue; };
        _cands = [_cands, [], { (_x select 1) distance (_loc select 1) }, "ASCEND"] call BIS_fnc_sortBy;
        private _amount = ((_floor - _stock) min _topUp) max 0;
        if (_amount <= 0) then { continue; };
        // MULTI-STORER RETRY, mirroring the ammo channel's ammoRetryDepots. The old code tried
        // ONLY the nearest storer and, when that exact pair could not route, simply continue'd -
        // the marker then cooled down and re-picked the SAME base forever. startConvoy already
        // straight-falls on its own (supplyRouteStraightFallback), so a refusal here is a
        // genuinely dead pair; the next nearest base may ship the same cargo fine. Walk up to
        // resupplyRetryStorers candidates, skipping any that have dropped below the floor since
        // this sweep's storer list was taken (an earlier marker in the same pass may have drained
        // one). startConvoy charges its cost itself and refunds on failure, so the walk stays
        // economically neutral between attempts.
        private _tryMax = (["resupplyRetryStorers", 3] call MISSION_CORE_fnc_tune) max 1;
        if !(_tryMax isEqualType 1) then { _tryMax = 3; };
        private _sent = false;
        private _usedStorer = "";
        private _i = 0;
        while { !_sent && { _i < count _cands } && { _i < _tryMax } } do {
            private _storerName = ((_cands select _i) select 0);
            if ((MISSION_CORE_LOCATION_SUPPLY getOrDefault [_storerName, 0]) >= _storerFloor) then {
                _sent = [_storerName, _name, _amount] call MISSION_CORE_fnc_startConvoy;
                if (_sent) then {
                    _usedStorer = _storerName;
                } else {
                    diag_log format ["DYNAMIC RESUPPLY: %1 could not route %2 supply from base %3 - trying next storer", _name, round _amount, _storerName];
                };
            };
            _i = _i + 1;
        };
        // Only start the real cooldown if a convoy actually exists. A refused order (contested
        // recipient, route too short, storer too poor) would otherwise burn the cooldown and
        // leave the marker waiting out the full delay for nothing.
        MISSION_CORE_RESUPPLY_CD set [_name, if (_sent) then { time } else { time - _cooldown + 30 }];
        if (_sent) then {
            // worth/chance are logged so the propensity curve can be tuned from the RPT instead of guessed at.
            diag_log format ["DYNAMIC RESUPPLY: %1 (stock %2, floor %3) ordered %4 supply from base %5 [worth %6, chance %7]", _name, _stock, round _floor, round _amount, _usedStorer, round (_worth * 10) / 10, round (_chance * 100) / 100];
        };
    } forEach MISSION_CORE_CACHED_POSITIONS;
};

// Start an abstract supply convoy along the road network. Provider is charged immediately; the
// recipient only receives supply when the truck actually arrives.
MISSION_CORE_fnc_startConvoy = {
    params ["_providerName", "_recipientName", "_supplyAmount", ["_cost", -1]];
    if (_supplyAmount <= 0) exitWith { false };
    if (isNil "MISSION_CORE_CONVOYS") then { MISSION_CORE_CONVOYS = []; };
    private _provIdx = MISSION_CORE_CACHED_POSITIONS findIf { (_x select 0) == _providerName };
    private _recvIdx = MISSION_CORE_CACHED_POSITIONS findIf { (_x select 0) == _recipientName };
    if (_provIdx < 0 || { _recvIdx < 0 }) exitWith { false };
    private _provRec = MISSION_CORE_CACHED_POSITIONS select _provIdx;
    private _startPos = _provRec select 1;
    private _recvRec = MISSION_CORE_CACHED_POSITIONS select _recvIdx;
    private _endPos = _recvRec select 1;
    if (_startPos distance2D _endPos < 50) exitWith { false };
    // NOTE: this is a neutral primitive - "ship _supplyAmount from A to B". It applies NO rule
    // about what may be a sender, because two different channels share it:
    //   1. Reinforcement pays for the squads it fields out of the SENDER's own pool, and any
    //      marker may be a sender.
    //   2. A resupply order ships stock to a needy marker, and only a storer may do that.
    // The storer restriction therefore lives in MISSION_CORE_fnc_resupplyDispatch, NOT here.
    // Putting it here made reinforcement free for every non-base sender.
    // PERMANENT RULE: never ship supply to a marker the players are fighting over. The truck would
    // only drive its cargo straight into the contested zone; the provider keeps its supply for
    // quieter markers. Uses the broadcast contested union (friendly zones + enemy targets).
    if (!isNil "MISSION_CORE_CONTESTED" && { _recipientName in MISSION_CORE_CONTESTED }) exitWith {
        diag_log format ["DYNAMIC CONVOY: %1 -> %2 supply convoy skipped - recipient contested", _providerName, _recipientName];
        false
    };
    if (_cost < 0) then { _cost = _supplyAmount + ceil (_supplyAmount * 0.1); };
    private _provSupply = MISSION_CORE_LOCATION_SUPPLY getOrDefault [_providerName, 0];
    MISSION_CORE_LOCATION_SUPPLY set [_providerName, _provSupply - _cost];

    // Refund onto the CURRENT pool value, not the snapshot taken before the debit: anything the
    // provider earned between dispatch and this failure is its own and must survive the rollback.
    private _refund = {
        params ["_name", "_back"];
        if (isNil "MISSION_CORE_LOCATION_SUPPLY") then { MISSION_CORE_LOCATION_SUPPLY = createHashMap; };
        MISSION_CORE_LOCATION_SUPPLY set [_name, (MISSION_CORE_LOCATION_SUPPLY getOrDefault [_name, 0]) + _back];
    };

    // Shared road route. The provider/recipient marker records are passed in so each end snaps to
    // the roads that actually serve that marker, and so the pair is cached by NAME - a resupply order
    // for the same two markers never re-walks the road network. If the two ends share no connected
    // network the resolver tries a transfer marker, then retries with a wider snap, a deeper node
    // budget and a longer detour reach before giving up. A pair that still cannot be routed takes
    // the straight-line fallback below (or is refused and refunded when that is tuned off), and
    // never gets cached, so a later order searches again.
      private _route = [_startPos, _endPos, _providerName, _recipientName, _provRec, _recvRec] call MISSION_CORE_fnc_supplyRoute;
      private _roadPath = _route select 0;
      private _straight = false;
      if !(_route select 1) then {
          // Unroutable: fall back to a straight line when the tune allows it, so the
          // order still ships instead of being refunded into a cooldown. Nothing is
          // cached, and supplyRoute's fail backoff still runs, so a later order for
          // the same pair searches again and upgrades to a real route if one opens.
          if ((["supplyRouteStraightFallback", 1] call MISSION_CORE_fnc_tune) > 0) then {
              private _flat = [_startPos, _endPos] call MISSION_CORE_fnc_straightPlan;
              if (count (_flat select 0) >= 2) then {
                  _roadPath = _flat select 0;
                  _route = [_roadPath, false, (_flat select 1), (_flat select 2)];
                  _straight = true;
              };
          };
      };
    if (count _roadPath < 2) exitWith {
        diag_log format ["DYNAMIC CONVOY: %1 -> %2 no connected road route - order refused and refunded", _providerName, _recipientName];
        [_providerName, _cost] call _refund;
        false
    };

    // Solved routes carry their length from the cache - the resolver computed it once, so a
    // resupply order between the same two markers never pays for this walk again. Straight
    // fallbacks carry the 2D distance instead, which is what makes their ETA short.
    private _cum = _route select 2;
    private _total = _route select 3;
    if (_total < 50) exitWith { [_providerName, _cost] call _refund; false };
    private _speed = 14; // m/s ~ truck road speed
    private _travelTime = _total / _speed;
    // [_provider, _recipient, _roadPath, _cum, _travelTime, _departTime, _amount, _state,
    //  _leadTruck, _leadGroup, _cid, _killed, _marker, _trucks, _groups, _leaderArrivedAt, _cost]
    if (isNil "MISSION_CORE_CONVOY_ID") then { MISSION_CORE_CONVOY_ID = 0; };
    MISSION_CORE_CONVOY_ID = MISSION_CORE_CONVOY_ID + 1;
    MISSION_CORE_CONVOYS pushBack [_providerName, _recipientName, _roadPath, _cum, _travelTime, time, _supplyAmount, 0, objNull, grpNull, MISSION_CORE_CONVOY_ID, false, "", [], [], -1, _cost];
    if (_straight) then {
        diag_log format ["DYNAMIC CONVOY: %1 -> %2 (%3 supply, %4m straight-line fallback, ETA %5s)", _providerName, _recipientName, _supplyAmount, round _total, round _travelTime];
    } else {
        diag_log format ["DYNAMIC CONVOY: %1 -> %2 (%3 supply, %4m via road, ETA %5s)", _providerName, _recipientName, _supplyAmount, round _total, round _travelTime];
    };
    // Reports whether a convoy actually exists, so a caller like resupplyDispatch can tell a real
    // order from a refused one instead of cooling down a marker that got nothing.
    true
};

MISSION_CORE_fnc_convoyLoop = {
    diag_log "DYNAMIC CONVOY: loop started";
    if (isNil "MISSION_CORE_RESUPPLY_CD") then { MISSION_CORE_RESUPPLY_CD = createHashMap; };
    // Resupply ordering is on a slow cadence of its own - it is a stock decision, not a
    // per-tick reaction, and it must not run every 5s convoy tick.
    private _resupplyCounter = 0;
    private _resupplyEvery = (["resupplyDispatchEveryTicks", 12] call MISSION_CORE_fnc_tune);
    if (_resupplyEvery < 1) then { _resupplyEvery = 12; };
    MISSION_CORE_CONVOY_STAGE = "start";
    while { true } do {
        // Heartbeat BEFORE the 5s sleep, stage markers written before the work that owns them.
        // If this thread is ever halted by an SQF error, the maintenance loop reports both the
        // age and the last stage reached - the same blind spot that made the 17:05:05 ammo death
        // undiagnosable, where only the final line of the last successful pass existed.
        MISSION_CORE_CONVOY_LOOP_TICK = time;
        // Boundary marker: without it a halt at the sleep reports the PREVIOUS pass's phase, which
        // points the investigation at work that already finished. "wait" means the prior pass
        // completed cleanly and the thread stopped entering the next one.
        MISSION_CORE_CONVOY_STAGE = "wait";
        sleep 5;
        if (isNil "MISSION_CORE_CONVOYS") then { MISSION_CORE_CONVOYS = []; };
        _resupplyCounter = _resupplyCounter + 1;
        if (_resupplyCounter >= _resupplyEvery) then {
            _resupplyCounter = 0;
            MISSION_CORE_CONVOY_STAGE = "resupplyDispatch";
            [] call MISSION_CORE_fnc_resupplyDispatch;
        };
        MISSION_CORE_CONVOY_STAGE = "advance";
        private _players = allPlayers select { alive _x };
        private _keep = [];
        {
            _x params ["_prov", "_recv", "_roadPath", "_cum", "_travelTime", "_departTime", "_amount", "_state", "_truck", "_grp"];
            // Force Recon abstract kill: the recon system already resolved it (ammo box dropped,
            // renown paid, marker removed). An abstract convoy owns no vehicle, so there is
            // nothing to tear down - just drop it from the queue.
            if (count _x > 11 && { _x select 11 }) then { continue; };
            if (_state == 0) then {
                private _frac = ((time - _departTime) / _travelTime) min 1;
                if (_frac >= 1) then {
                    private _recvSupply = MISSION_CORE_LOCATION_SUPPLY getOrDefault [_recv, 0];
                    MISSION_CORE_LOCATION_SUPPLY set [_recv, _recvSupply + _amount];
                    // Not pushing this record onto _keep retires it, which is what lets
                    // reconTickHousekeep see the cid go stale and drop the intel marker.
                    diag_log format ["DYNAMIC CONVOY: %1 -> %2 delivered %3 supply (abstract), record retired cid %4", _prov, _recv, _amount, _x select 10];
                    if (!isNil "MISSION_CORE_fnc_reconDropRoute") then { [_roadPath] call MISSION_CORE_fnc_reconDropRoute; };
                } else {
                    private _curPos = [_roadPath, _cum, _frac] call MISSION_CORE_fnc_convoyPosAt;
                    private _nearPlayer = _players findIf { _x distance _curPos < 1200 } != -1;
                    if (_nearPlayer) then {
                        // Column materialisation is shared with manpower and ammo via
                        // spawnConvoyColumn, so every cargo class follows the road polyline it
                        // was routed along and spawns echeloned behind the leader. Supply keeps
                        // its own REDFOR Truck_F preference for the class.
                        private _col = [_roadPath, _cum, _frac, _amount, "supply"] call MISSION_CORE_fnc_spawnConvoyColumn;
                        private _trucks = _col select 0;
                        private _groups = _col select 1;
                        private _truckClass = _col select 2;
                        private _live = _trucks select { !isNull _x };
                        if (count _live == 0) then {
                            // Nothing took the road, so the cargo never left. Refund the exact
                            // amount that was debited - the caller may have passed its own _cost,
                            // so recomputing the 10% fee here would hand back the wrong number.
                            [_prov, (_x select 16)] call {
                                params ["_n", "_back"];
                                MISSION_CORE_LOCATION_SUPPLY set [_n, (MISSION_CORE_LOCATION_SUPPLY getOrDefault [_n, 0]) + _back];
                            };
                            diag_log format ["DYNAMIC CONVOY: %1 -> %2 materialization failed - %3 supply refunded", _prov, _recv, _amount];
                        } else {
                            private _leadIdx = _trucks find (_live select 0);
                            _x set [7, 1];
                            _x set [8, (_live select 0)];
                            _x set [9, (_groups select _leadIdx)];
                            _x set [13, _trucks];
                            _x set [14, _groups];
                            _x set [15, -1];
                            _keep pushBack _x;
                            diag_log format ["DYNAMIC CONVOY: %1 -> %2 materialized %3 x %4 at %5", _prov, _recv, count _live, _truckClass, (_col select 3)];
                        };
                    } else {
                        _keep pushBack _x;
                    };
                };
            } else {
                private _trucks = _x select 13;
                private _groups = _x select 14;
                if (count _trucks == 0) then { _trucks = [_truck]; };
                if (count _groups == 0) then { _groups = [_grp]; };

                // Lose the whole shipment if ANY truck in it is destroyed. One shipment is one
                // abstracted cargo record, so splitting the loss per truck would mean changing
                // what the recipient is owed halfway across the map.
                private _wrecked = false;
                { if (isNull _x || { !(alive _x) }) then { _wrecked = true; }; } forEach _trucks;

                if (_wrecked) then {
                    // Player-killed or Force Recon-struck convoy: renown for the team + loot.
                    private _renownGain = [["renownPerConvoy", 15] call MISSION_CORE_fnc_tune] call MISSION_CORE_fnc_awardRenown;
                    // Each lost convoy angers the enemy proportionally to the supply it carried.
                    private _aggGain = _amount * (["aggressionConvoyPerSupply", 0.25] call MISSION_CORE_fnc_tune);
                    [_aggGain] call MISSION_CORE_fnc_aggressionAdd;
                    diag_log format ["AGGRESSION: convoy %1 -> %2 lost +%3 (supply %4)", _prov, _recv, round _aggGain, _amount];
                    ["DynOps_ConvoyDestroyed",
                        ["CONVOY DESTROYED", format ["Supply convoy %1 -> %2 lost! Renown +%3", _prov, _recv, _renownGain]]
                    ] remoteExec ["BIS_fnc_showNotification", 0];
                      private _boxClass = call MISSION_CORE_fnc_convoyLootBoxClass;
                    // One box per wrecked truck, capped so a big column cannot carpet the map.
                    private _boxCap = (["convoyLootBoxMax", 3] call MISSION_CORE_fnc_tune);
                    private _dropped = 0;
                    {
                        if (_dropped >= _boxCap) then { break; };
                        if (!isNull _x) then {
                            createVehicle [_boxClass, getPos _x, [], 0, "CAN_COLLIDE"];
                            _dropped = _dropped + 1;
                        };
                    } forEach _trucks;
                    diag_log format ["DYNAMIC CONVOY: %1 -> %2 destroyed - %3 supply lost, %4 box(es) dropped", _prov, _recv, _amount, _dropped];
                    { if (!isNull _x) then { { deleteVehicle _y; } forEach crew _x; deleteVehicle _x; }; } forEach _trucks;
                    { if (!isNull _x) then { { if (!isNull _y) then { deleteVehicle _y; }; } forEach units _x; deleteGroup _x; }; } forEach _groups;
                } else {
                    private _endPos = _roadPath select (count _roadPath - 1);
                    private _rad = (["convoyArriveRadius", 150] call MISSION_CORE_fnc_tune);
                    private _lead = _truck;
                    if (!isNull _lead && { alive _lead } && { _lead distance2D _endPos < _rad } && { ((_x select 15) < 0) }) then {
                        _x set [15, time];
                    };
                    // Deliver when the column has closed up, or when the leader has arrived and the
                    // stragglers have had their grace window. Waiting for every truck forever lets
                    // one wedged lorry hold a whole shipment hostage.
                    private _allClose = true;
                    { if (_x distance2D _endPos > (_rad * 2.5)) then { _allClose = false; }; } forEach _trucks;
                    private _leadIn = ((_x select 15) >= 0);
                    private _grace = (["convoyStragglerGrace", 90] call MISSION_CORE_fnc_tune);
                    if (_allClose || { _leadIn && { time - (_x select 15) > _grace } }) then {
                        private _recvSupply = MISSION_CORE_LOCATION_SUPPLY getOrDefault [_recv, 0];
                        MISSION_CORE_LOCATION_SUPPLY set [_recv, _recvSupply + _amount];
                        // Also retires the record (not pushed onto _keep) so the intel
                        // marker is dropped by reconTickHousekeep on its next pass, and
                        // retires the blue routine route polyline if recon drew one for it.
                        diag_log format ["DYNAMIC CONVOY: %1 -> %2 delivered %3 supply, record retired cid %4", _prov, _recv, _amount, _x select 10];
                        if (!isNil "MISSION_CORE_fnc_reconDropRoute") then { [_roadPath] call MISSION_CORE_fnc_reconDropRoute; };
                        { if (!isNull _x) then { { deleteVehicle _y; } forEach crew _x; deleteVehicle _x; }; } forEach _trucks;
                        { if (!isNull _x) then { { if (!isNull _y) then { deleteVehicle _y; }; } forEach units _x; deleteGroup _x; }; } forEach _groups;
                    } else {
                        _keep pushBack _x;
                    };
                };
            };
        } forEach MISSION_CORE_CONVOYS;
        MISSION_CORE_CONVOYS = _keep;
    };
};
