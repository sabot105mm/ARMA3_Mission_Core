
// Retreat settlement - the bookkeeping and the payout that every retreat path shares.
//
// Three paths order a retreat: a garrison whose defense collapsed (fn_retreatGarrison), a neighbor
// counter-attack column whose target stopped being contested (fn_despawnUncontestedNeighbors), and
// a player-hunt contingent whose sweep expired (fn_playerHunt). They used to disagree about the
// bookkeeping variables - the garrison and hunt paths set NONE of them, so the sweeper in
// fn_despawnUncontestedNeighbors measured their distance to [0,0,0] and compared it against a
// deadline of time+300 that it re-evaluated on every tick, i.e. a deadline that can never expire.
// There is now ONE definition of "retreating", and the survivors' manpower and tanks are settled
// into the retreat marker's pools on arrival instead of being deleted off the books.
//
// PAYOUT RECIPIENT: the friendly marker the squad actually reached (MISSION_CORE_RETREAT_TO_NAME,
// resolved from the retreat position when the caller did not set it). The cost was drawn from the
// ORIGIN marker's pool when the squad deployed, so crediting the marker it walked to is a transfer
// within the faction - the faction total is conserved, and the receiving marker gets the men and
// tanks it just absorbed. Crediting the origin instead would be pointless: that marker is the one
// being abandoned, and it can never field them again (MISSION_CORE_RETREATED is latched).

MISSION_CORE_fnc_retreatDeadline = {
    params ["_from", "_to"];
    // A flat 300s was sized for the old "nearest ally" destination. A retreat must now clear
    // retreatMinDistance (1500m) from the fight, so a foot column can still be halfway across the
    // map when a fixed budget runs out and would be deleted mid-walk. Scale the budget with the
    // distance actually being covered, at a deliberately pessimistic 2 m/s (a foot column that has
    // already taken casualties).
    private _d = _from distance2D _to;
    time + (["retreatBaseSeconds", 300] call MISSION_CORE_fnc_tune) + (_d / 2)
};

// Tag a group as retreating in the ONE way the despawn sweeper understands. Callers set
// MISSION_CORE_RETREAT_FROM themselves (it names different things per path).
MISSION_CORE_fnc_beginRetreat = {
    params ["_grp", "_dest", ["_toName", ""]];
    if (isNull _grp) exitWith {};
    _grp setVariable ["MISSION_CORE_ORDER", "retreat"];
    _grp setVariable ["MISSION_CORE_RETREAT_DEST", _dest];
    _grp setVariable ["MISSION_CORE_RETREAT_DEADLINE", [getPosATL (leader _grp), _dest] call MISSION_CORE_fnc_retreatDeadline];
    if (_toName != "") then { _grp setVariable ["MISSION_CORE_RETREAT_TO_NAME", _toName]; };
};

// Settle a retreating group into the retreat marker's economy, then let the caller delete it.
// Safe to call from BOTH despawn routes (the arrival waypoint script and the sweeper tick): the
// MISSION_CORE_RETREAT_PAID latch credits the economy exactly once per group.
MISSION_CORE_fnc_retreatPayout = {
    params ["_grp", ["_destPos", [0, 0, 0]], ["_toNameOverride", ""]];
    if (isNull _grp) exitWith {};
    if (_grp getVariable ["MISSION_CORE_RETREAT_PAID", false]) exitWith {};
    _grp setVariable ["MISSION_CORE_RETREAT_PAID", true];

    // --- resolve the recipient marker -------------------------------------------------
    // Priority: the caller's explicit choice (a column with no retreat destination goes back to
    // the marker that supplied it) > the name recorded when the retreat was ordered > the nearest
    // cached marker to the destination.
    private _toName = _toNameOverride;
    if (_toName == "") then { _toName = _grp getVariable ["MISSION_CORE_RETREAT_TO_NAME", ""]; };
    private _pos = _grp getVariable ["MISSION_CORE_RETREAT_DEST", _destPos];
    if (count _pos < 2) then { _pos = _destPos; };
    if (_toName == "" && { count _pos >= 2 } && { !isNil "MISSION_CORE_CACHED_POSITIONS" }) then {
        // The destination was picked straight out of the cached list, so the nearest cached
        // position to it IS the retreat marker. getLocByPos is the fallback if that lookup misses.
        // Index 1 of a CACHED_POSITIONS entry is the marker POSITION, flat (fn_init.sqf:70), so it is
        // compared directly. Do NOT use the MISSION_CORE_LOCATIONS accessor ((_x select 1) select 0/1)
        // here - that array nests pos/size under index 1 and the extra select yields a scalar, which
        // is what threw "distance2d: Type Number, expected Array,Object". See fn_defendGate.sqf:24.
        private _ti = MISSION_CORE_CACHED_POSITIONS findIf { (count (_x select 1) >= 2) && { ((_x select 1) distance2D _pos) < 400 } };
        if (_ti >= 0) then { _toName = (MISSION_CORE_CACHED_POSITIONS select _ti) select 0; }
        else {
            if (!isNil "MISSION_CORE_fnc_getLocByPos") then {
                private _rel = _pos call MISSION_CORE_fnc_getLocByPos;
                if (count _rel > 0) then { _toName = _rel select 0; };
            };
        };
    };
    if (_toName == "") then {
        diag_log format ["RETREAT PAYOUT: %1 despawned with no resolvable retreat marker - survivors not credited", groupId _grp];
    };
    if (_toName == "") exitWith {};
    if (isNil "MISSION_CORE_CACHED_POSITIONS") exitWith {};
    private _li = MISSION_CORE_CACHED_POSITIONS findIf { (_x select 0) == _toName };
    if (_li < 0) then {
        diag_log format ["RETREAT PAYOUT: %1 reached %2, which is no longer a live marker - survivors not credited", groupId _grp, _toName];
    };
    if (_li < 0) exitWith {};

    private _side = if (_grp getVariable ["MISSION_CORE_BLUFOR", false]) then { WEST } else { EAST };
    // Only the SURVIVORS are settled. The dead were already charged to the origin marker's
    // casualty tally when they died, so crediting them again would invent manpower.
    private _men = { !isNull _x && { alive _x } } count units _grp;
    private _tankList = [];
    {
        private _v = vehicle _x;
        if (!isNull _v && { alive _v } && { _v isKindOf "Tank" } && { !(_v in _tankList) }) then { _tankList pushBack _v; };
    } forEach units _grp;
    private _tanks = count _tankList;

    // --- manpower: pending credit, not a direct pool write ----------------------------
    // MISSION_CORE_MANPOWER entries are [amount, matureTime] and mature into the marker's
    // fieldable cap, which fn_replenishLoop already clamps to the marker's importance capacity -
    // so crediting a full squad can never inflate a marker past what it originally rated. Cap the
    // credit by the headroom already pending, the same way fn_orderedVehicleCleanup does.
    if (_men > 0) then {
        if (isNil "MISSION_CORE_fnc_markerCapacity") then {
            diag_log format ["RETREAT PAYOUT: %1 - markerCapacity missing, %2 men not credited to %3", groupId _grp, _men, _toName];
        } else {
            if (isNil "MISSION_CORE_MANPOWER") then { MISSION_CORE_MANPOWER = createHashMap; };
            private _imp = (MISSION_CORE_CACHED_POSITIONS select _li) select 7;
            private _cap = [_imp] call MISSION_CORE_fnc_markerCapacity;
            private _pending = MISSION_CORE_MANPOWER getOrDefault [_toName, []];
            private _pendingMen = 0;
            { _pendingMen = _pendingMen + (_x select 0); } forEach _pending;
            private _credit = _men min ((_cap - _pendingMen) max 0);
            if (_credit > 0) then {
                _pending pushBack [_credit, time + 30];
                MISSION_CORE_MANPOWER set [_toName, _pending];
                diag_log format ["RETREAT PAYOUT: %1 credited %2 men to %3 (survivors %4, cap %5)", groupId _grp, _credit, _toName, _men, _cap];
            } else {
                diag_log format ["RETREAT PAYOUT: %1 - %2 already has %3 men pending against a cap of %4, no credit for %5 survivors", groupId _grp, _toName, _pendingMen, _cap, _men];
            };
        };
    };

    // --- armor: +1 depot stock per surviving tank --------------------------------------
    if (_tanks > 0) then {
        if (isNil "MISSION_CORE_fnc_tankDepotIsDepot") then {
            diag_log format ["RETREAT PAYOUT: %1 - fn_tankDepot.sqf did not compile, %2 tanks not refunded", groupId _grp, _tanks];
        } else {
            if (isNil "MISSION_CORE_TANK_STOCK") then { MISSION_CORE_TANK_STOCK = createHashMap; };
            private _depots = MISSION_CORE_CACHED_POSITIONS select {
                (_x select 4) == _side && { [_x] call MISSION_CORE_fnc_tankDepotIsDepot }
            };
            if (count _depots == 0) then {
                diag_log format ["RETREAT PAYOUT: %1 reached %2 but its side has no tank depot - %3 tanks not refunded", groupId _grp, _toName, _tanks];
            } else {
                private _best = _depots select 0;
                private _bv = _pos distance (_best select 1);
                {
                    private _d = _pos distance (_x select 1);
                    if (_d < _bv) then { _bv = _d; _best = _x; };
                } forEach _depots;
                private _dn = _best select 0;
                MISSION_CORE_TANK_STOCK set [_dn, ([_dn] call MISSION_CORE_fnc_tankDepotStock) + _tanks];
                diag_log format ["RETREAT PAYOUT: %1 refunded %2 tanks to depot %3 (stock now %4)", groupId _grp, _tanks, _dn, ([_dn] call MISSION_CORE_fnc_tankDepotStock)];
            };
            // Detach the retiring tanks from the Killed-replacement machinery BEFORE the caller
            // deletes them. Reinforcement/assault armor requests a replacement when it dies, so
            // deleting a tank that is retiring would spawn a fresh one - and the +1 credited just
            // above would pay for that replacement a second time.
            { _x removeAllEventHandlers "Killed"; } forEach _tankList;
        };
    };
};
