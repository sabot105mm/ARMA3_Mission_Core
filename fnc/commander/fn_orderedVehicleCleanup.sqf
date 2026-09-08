// Ordered-vehicle cleanup: when a freshly spawned vehicle is handed a REAL movement order (a MOVE
// / SAD / patrol advance to somewhere else), tag it with its spawn position, its destination, the
// time it spawned and how paid for. A sweeper loop watches those vehicles and flags any one that
// STOPS MOVING (parks below the move threshold): the first stop check marks it, and once it has
// sat in the same spot for the stuck window it is recycled - its Killed handlers are stripped
// first (a deliberate despawn must never spawn a replacement), any supply paid to field it is
// refunded, every unit riding it is returned to its origin marker's manpower, a tank gets a tank
// (armor stock) refunded, then the vehicle + its crew + any group left empty are deleted
// (releasing the count-based armor slot).
//
// A vehicle that keeps moving past any stuck window is doing its order and is never flagged.
// Vehicles without an away-order (stationary defenses, HQ armor, parked truck crews, player
// deliveries) are never tagged and never touched. Tank-depot convoys are excluded too - they
// already self-account on their travel deadline and deliver/despawn through their own arrival +
// write-off paths.
MISSION_CORE_fnc_tagOrderedVehicle = {
    params ["_veh", "_targetPos", ["_refund", []]];
    if (isNull _veh) exitWith {};
    if (isNil "MISSION_CORE_VEH_ORDERS") then { MISSION_CORE_VEH_ORDERS = []; };
    private _posNow = getPosATL _veh;
    _veh setVariable ["MISSION_CORE_VEH_ORDER", [_posNow, _targetPos, time, _refund, _posNow, -1]];
    MISSION_CORE_VEH_ORDERS pushBack _veh;
};

MISSION_CORE_fnc_untagOrderedVehicle = {
    params ["_veh"];
    if (isNull _veh) exitWith {};
    _veh setVariable ["MISSION_CORE_VEH_ORDER", nil];
    if (!isNil "MISSION_CORE_VEH_ORDERS") then { MISSION_CORE_VEH_ORDERS = MISSION_CORE_VEH_ORDERS - [_veh]; };
};

MISSION_CORE_fnc_refundOrderedVehicle = {
    params ["_refund"];
    if (count _refund == 0) exitWith {};
    switch (_refund select 0) do {
        // Reinforcement armor was paid for from a provider's supply pool - give it back so the
        // stuck vehicle does not burn the provider's economy.
        case "supply": {
            _refund params ["_kind", ["_provider", ""], ["_amount", 0]];
            if (_provider == "" || _amount <= 0) exitWith {};
            if (isNil "MISSION_CORE_LOCATION_SUPPLY") then { MISSION_CORE_LOCATION_SUPPLY = createHashMap; };
            private _cur = MISSION_CORE_LOCATION_SUPPLY getOrDefault [_provider, 0];
            MISSION_CORE_LOCATION_SUPPLY set [_provider, _cur + _amount];
            diag_log format ["VEHICLE CLEANUP: refunded %1 supply to %2 (ordered vehicle stuck at spawn)", _amount, _provider];
        };
    };
};

// Refund what a recycled vehicle ACTUALLY contained, before the delete happens:
//  - every unit riding it is manpower: return them to their origin marker's pending credit (the
//    same mechanism neighbor counter-attacks use), capped by the marker's capacity, so the
//    economy does not lose men to a pathing/collision bug.
//  - a tank is refunded a tank: +1 armor stock on the nearest depot of the vehicle's side.
MISSION_CORE_fnc_refundOrderedVehContents = {
    params ["_veh"];
    if (isNull _veh) exitWith {};
    private _occupants = crew _veh;
    private _grp = grpNull;
    if (count _occupants > 0) then { _grp = group (_occupants select 0); };
    private _origin = "";
    if (!isNull _grp && { (_grp getVariable ["MISSION_CORE_ORIGIN_MARKER", ""]) != "" }) then {
        _origin = _grp getVariable ["MISSION_CORE_ORIGIN_MARKER", ""];
    };
    if (_origin == "") then {
        private _rel = getPos _veh call MISSION_CORE_fnc_getLocByPos;
        if (count _rel > 0) then { _origin = _rel select 0; };
    };
    private _men = count _occupants;
    if (_men > 0 && _origin != "") then {
        if (isNil "MISSION_CORE_MANPOWER") then { MISSION_CORE_MANPOWER = createHashMap; };
        private _imp = 1;
        private _li = MISSION_CORE_CACHED_POSITIONS findIf { (_x select 0) == _origin };
        if (_li >= 0) then { _imp = (MISSION_CORE_CACHED_POSITIONS select _li) select 7; };
        private _cap = [_imp] call MISSION_CORE_fnc_markerCapacity;
        private _pending = MISSION_CORE_MANPOWER getOrDefault [_origin, []];
        private _pendingMen = 0;
        { _pendingMen = _pendingMen + (_x select 0); } forEach _pending;
        private _credit = (_men min ((_cap - _pendingMen) max 0));
        if (_credit > 0) then {
            _pending pushBack [_credit, time];
            MISSION_CORE_MANPOWER set [_origin, _pending];
            diag_log format ["VEHICLE CLEANUP: refunded %1 manpower to %2 (%3 riding units)", _credit, _origin, _men];
        };
    };
    if (_veh isKindOf "Tank") then {
        if (isNil "MISSION_CORE_TANK_STOCK") then { MISSION_CORE_TANK_STOCK = createHashMap; };
        private _s = side _veh;
        private _depots = MISSION_CORE_CACHED_POSITIONS select {
            (_x select 4) == _s && { [(_x select 0)] call MISSION_CORE_fnc_tankDepotIsDepot }
        };
        private _dn = "";
        if (count _depots > 0) then {
            private _best = _depots select 0;
            private _bv = _veh distance (_best select 1);
            {
                private _d = _veh distance (_x select 1);
                if (_d < _bv) then { _bv = _d; _best = _x; };
            } forEach _depots;
            _dn = _best select 0;
        };
        if (_dn == "") then { _dn = _origin; };
        if (_dn != "") then {
            MISSION_CORE_TANK_STOCK set [_dn, ([_dn] call MISSION_CORE_fnc_tankDepotStock) + 1];
            diag_log format ["VEHICLE CLEANUP: refunded a tank to %1 (stock now %2)", _dn, ([_dn] call MISSION_CORE_fnc_tankDepotStock)];
        };
    };
};

MISSION_CORE_fnc_despawnOrderedVehicle = {
    params ["_veh"];
    if (isNull _veh) exitWith {};
    // Strip Killed handlers BEFORE deleting: reinforcement/assault armor requests a replacement on
    // death - recycling a stuck tank must free the slot, not queue another.
    _veh removeAllEventHandlers "Killed";
    private _crew = crew _veh;
    private _owningGroup = if (count _crew > 0) then { group (_crew select 0) } else { grpNull };
    { if (!isNull _x) then { deleteVehicle _x; }; } forEach _crew;
    deleteVehicle _veh;
    if (!isNull _owningGroup && { count units _owningGroup == 0 }) then {
        if (!isNil "MISSION_CORE_SPAWNED_GROUPS") then { MISSION_CORE_SPAWNED_GROUPS = MISSION_CORE_SPAWNED_GROUPS - [_owningGroup]; };
        deleteGroup _owningGroup;
    };
};

MISSION_CORE_fnc_orderedVehicleCleanupLoop = {
    diag_log "VEHICLE CLEANUP: ordered-vehicle sweeper started";
    if (isNil "MISSION_CORE_VEH_ORDERS") then { MISSION_CORE_VEH_ORDERS = []; };
    private _tick = ["stuckVehicleTick", 30] call MISSION_CORE_fnc_tune;
    while { true } do {
        sleep _tick;
        private _timeWindow = ["stuckVehicleTime", 90] call MISSION_CORE_fnc_tune;
        private _moveThreshold = ["stuckVehicleMove", 5] call MISSION_CORE_fnc_tune;
        private _keep = [];
        {
            private _veh = _x;
            if (isNull _veh || { !(alive _veh) }) then { continue; };
            private _tag = _veh getVariable ["MISSION_CORE_VEH_ORDER", []];
            if (count _tag < 6) then { continue; };
            _tag params ["_spawnPos", "_targetPos", "_spawnTime", "_refund", "_lastPos", "_stoppedSince"];
            // Two-phase stop detection: a vehicle that has NOT moved since the last sweep is marked
            // as stopped (its stop time is recorded once); if it is STILL parked in the same spot
            // when the stuck window elapses it is recycled. Any movement resets the mark - a vehicle
            // that keeps driving (even slowly) is doing its order and is never flagged.
            private _posNow = getPosATL _veh;
            if ((_posNow distance2D _lastPos) > _moveThreshold) then {
                _stoppedSince = -1;
            } else {
                if (_stoppedSince < 0) then { _stoppedSince = time; };
            };
            _tag set [4, _posNow];
            _tag set [5, _stoppedSince];
            _veh setVariable ["MISSION_CORE_VEH_ORDER", _tag];
            if (_stoppedSince < 0 || { time - _stoppedSince < _timeWindow }) then { _keep pushBack _veh; continue; };
            diag_log format ["VEHICLE CLEANUP: %1 at %2 stopped since %3 (moved < %4m) - despawn, refund men/tank/supply", typeOf _veh, mapGridPosition (getPos _veh), round _stoppedSince, round _moveThreshold];
            [_refund] call MISSION_CORE_fnc_refundOrderedVehicle;
            [_veh] call MISSION_CORE_fnc_refundOrderedVehContents;
            [_veh] call MISSION_CORE_fnc_despawnOrderedVehicle;
        } forEach MISSION_CORE_VEH_ORDERS;
        MISSION_CORE_VEH_ORDERS = _keep;
    };
};