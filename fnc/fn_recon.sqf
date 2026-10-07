// =====================================================================
// RENOWN + FORCE RECON
// Team-wide renown currency earned from captures (importance-based) and
// destroyed supply convoys. It is spent at the HQ flag to unlock Marine
// Force Recon units. A recon unit is ABSTRACT: nothing is ever spawned in
// the world, it is a position the player assigns and it reports from there.
//
// Each unlocked unit can be given a MOVE ORDER: a line is drawn from the
// player's HQ to the chosen destination, steered around the edges of enemy
// markers, and the unit travels it at 30 mph. On arrival it does an
// above-sea-level test at that destination, and from then on that spot's
// height sets how far it can see. Spotting is not a flat roll: it is
// distance bands (90-99% inside 500m, down to 1-15% out to 9km, never
// beyond) interpolated by the observer's height, capped by the band.
//
// A detected convoy is DESIGNATED for fire support: the whole team gets a
// map marker + ETA. Fire support is a per-dealer dice roll with real rates
// per cargo type (paveway/mlrs/spg) - see reconDealerDamage. Intel is shared
// team-wide and convoys struck on a real (materialized) truck die through
// the normal convoy loop.
// =====================================================================

// Idempotent server broadcast of the full recon state. Safe to call any time (init, client
// pull requests, re-init) - publicVariable re-sends to all current clients harmlessly.
MISSION_CORE_fnc_reconPushState = {
    if (!isServer) exitWith {};
    if (isNil "MISSION_CORE_RENOWN") then { MISSION_CORE_RENOWN = 0; };
    if (isNil "MISSION_CORE_RECON_UNITS") then { MISSION_CORE_RECON_UNITS = []; };
    if (isNil "MISSION_CORE_RECON_UNIT_COSTS") then { MISSION_CORE_RECON_UNIT_COSTS = []; };
    if (isNil "MISSION_CORE_RECON_GEAR") then { MISSION_CORE_RECON_GEAR = []; };
    if (isNil "MISSION_CORE_RECON_MOVES") then { MISSION_CORE_RECON_MOVES = createHashMap; };
    if (isNil "MISSION_CORE_RECON_KILLS" || { typeName MISSION_CORE_RECON_KILLS != "ARRAY" }) then {
        if (!(isNil "MISSION_CORE_RECON_KILLS")) then { diag_log format ["RENOWN/RECON: RECON_KILLS invalid type %1 (%2) at push - reset", MISSION_CORE_RECON_KILLS, typeName MISSION_CORE_RECON_KILLS]; };
        MISSION_CORE_RECON_KILLS = [0, 0, 0];
    };
    publicVariable "MISSION_CORE_RENOWN";
    publicVariable "MISSION_CORE_RECON_UNITS";
    publicVariable "MISSION_CORE_RECON_UNIT_COSTS";
    publicVariable "MISSION_CORE_RECON_GEAR";
    publicVariable "MISSION_CORE_RECON_KILLS";
    publicVariable "MISSION_CORE_RECON_MOVES";
    diag_log format ["RENOWN/RECON: state pushed (renown=%1, units=%2, gear=%3)", MISSION_CORE_RENOWN, count MISSION_CORE_RECON_UNITS, count MISSION_CORE_RECON_GEAR];
};

MISSION_CORE_fnc_initRecon = {
    if (isNil "MISSION_CORE_RENOWN") then { MISSION_CORE_RENOWN = 0; };
    // Free renown for testing recon: granted once at init, on top of whatever the
    // pool already holds. Defaults to 0 so live balance is unaffected until set.
    private _freeRenown = ["renownFreeRecon", 0] call MISSION_CORE_fnc_tune;
    if (_freeRenown > 0) then {
        MISSION_CORE_RENOWN = MISSION_CORE_RENOWN + _freeRenown;
        diag_log format ["RENOWN/RECON: free testing grant +%1 (total %2)", _freeRenown, MISSION_CORE_RENOWN];
    };
    if (isNil "MISSION_CORE_RECON_UNITS") then {
        MISSION_CORE_RECON_UNITS = [];
        private _maxR = ["reconMaxUnits", 4] call MISSION_CORE_fnc_tune;
        MISSION_CORE_RECON_UNIT_COSTS = [];
        private _costBase = ["reconUnitCostBase", 100] call MISSION_CORE_fnc_tune;
        private _costStep = ["reconUnitCostStep", 75] call MISSION_CORE_fnc_tune;
        for "_i" from 0 to (_maxR - 1) do {
            MISSION_CORE_RECON_UNITS pushBack false;
            MISSION_CORE_RECON_UNIT_COSTS pushBack (_costBase + _i * _costStep);
        };
    };
    if (isNil "MISSION_CORE_RECON_MARKERS") then { MISSION_CORE_RECON_MARKERS = createHashMap; };
    if (isNil "MISSION_CORE_ROUTE_KNOWLEDGE") then { MISSION_CORE_ROUTE_KNOWLEDGE = createHashMap; };
    if (isNil "MISSION_CORE_RECON_ROUTES") then { MISSION_CORE_RECON_ROUTES = createHashMap; };
    if (isNil "MISSION_CORE_RECON_COOLDOWNS") then { MISSION_CORE_RECON_COOLDOWNS = createHashMap; }; // strike asset ready-times
    if (isNil "MISSION_CORE_RECON_KILLS" || { typeName MISSION_CORE_RECON_KILLS != "ARRAY" }) then {
        if (!(isNil "MISSION_CORE_RECON_KILLS")) then { diag_log format ["RENOWN/RECON: RECON_KILLS invalid type %1 (%2) at init - reset", MISSION_CORE_RECON_KILLS, typeName MISSION_CORE_RECON_KILLS]; };
        MISSION_CORE_RECON_KILLS = [0, 0, 0];
    }; // [ammo convoys, men, tanks] destroyed
    // [id, displayName, cost, [detect, strikeChance, destroyWeight]]
    MISSION_CORE_RECON_GEAR = [
        ["optics", "Long-Range Optics", 25, [8, 0, 0]],
        ["designator", "Target Designator", 30, [6, 10, 0]],
        ["spg", "SPG Fire Support", 40, [0, 20, 12]],
        ["mlrs", "MLRS Fire Support", 55, [0, 25, 22]],
        ["paveway", "Paveway LGB", 60, [0, 20, 30]]
    ];
    MISSION_CORE_RECON_INTEL_IDX = 0;
    MISSION_CORE_RECON_ROUTE_IDX = 0;
    call MISSION_CORE_fnc_reconPushState;
    diag_log format ["RENOWN/RECON: initialized (renown=%1, max units=%2)", MISSION_CORE_RENOWN, count MISSION_CORE_RECON_UNITS];
};

// Add renown to the shared pool and broadcast. Returns the new total.
MISSION_CORE_fnc_awardRenown = {
    params ["_amount"];
    if (isNil "MISSION_CORE_RENOWN") then { MISSION_CORE_RENOWN = 0; };
    if (_amount <= 0) exitWith { MISSION_CORE_RENOWN };
    MISSION_CORE_RENOWN = MISSION_CORE_RENOWN + _amount;
    publicVariable "MISSION_CORE_RENOWN";
    diag_log format ["RENOWN: +%1 -> %2 total", _amount, MISSION_CORE_RENOWN];
    MISSION_CORE_RENOWN
};

// Add [0] ammo / [1] men / [2] tanks to the interdiction ledger and broadcast.
// Clients repaint the Interdiction Log diary via a publicVariable handler.
MISSION_CORE_fnc_reconLogKill = {
    params ["_kind", ["_count", 1]];
    if (!(_kind isEqualType 0) || { _kind < 0 || { _kind >= 3 } }) exitWith {};
    _kind = floor _kind;
    if (!(_count isEqualType 0) || { !(_count >= 0) } || { _count >= 1e9 }) exitWith {};
    _count = round _count;
    if (_count <= 0) exitWith {};
    try {
        private _led = missionNamespace getVariable ["MISSION_CORE_RECON_KILLS", [0, 0, 0]];
        if (!(_led isEqualType []) || { count _led < 3 }) then {
            diag_log format ["RENOWN/RECON: RECON_KILLS invalid %1 (%2) at logKill - reset", _led, typeName _led];
            _led = [0, 0, 0];
        };
        private _old = _led select _kind;
        if (!(_old isEqualType 0) || { !(_old >= 0) } || { _old >= 1e9 }) then { _old = 0; };
        _led set [_kind, _old + _count];
        if (!((_led select _kind) isEqualType 0) || { !((_led select _kind) >= 0) } || { (_led select _kind) >= 1e9 }) then { _led set [_kind, 0]; };
        MISSION_CORE_RECON_KILLS = _led;
        publicVariable "MISSION_CORE_RECON_KILLS";
        diag_log format ["RENOWN/RECON: interdiction ledger -> ammo=%1 men=%2 tanks=%3",
            _led select 0, _led select 1, _led select 2];
    } catch {
        diag_log format ["RENOWN/RECON: reconLogKill exception: %1", _exception];
    };
};

// Fire-support cooldown window for a gear id (seconds). Fired gear sits on cooldown before it
// can launch again; spg is a solid 5 min, mlrs 15-20, paveway 5-20 (both randomly).
MISSION_CORE_fnc_reconStrikeCooldown = {
    params ["_gear"];
    switch (_gear) do {
        case "spg": { 300 };
        case "mlrs": { 900 + random 300 };
        case "paveway": { 300 + random 900 };
        default { 600 };
    }
};

// Consume one ready fire-support asset from the pool (passed by reference). Returns the gear id
// of the asset that fired (spg/mlrs/paveway) so the caller can apply that dealer's damage rates,
// or "" if the pool is dry (nothing left to fire).
MISSION_CORE_fnc_reconStrikeSpend = {
    params ["_assets"];
    if (count _assets == 0) exitWith { "" };
    private _use = _assets select 0;
    _assets deleteAt 0;
    private _key = format ["%1_%2", _use select 0, _use select 1];
    MISSION_CORE_RECON_COOLDOWNS set [_key, time + ([_use select 0] call MISSION_CORE_fnc_reconStrikeCooldown)];
    diag_log format ["RENOWN/RECON: %1 fire support spent (%2 min cooldown)", _use select 0, round (((MISSION_CORE_RECON_COOLDOWNS get _key) - time) / 60)];
    (_use select 0)
};

// Per-dealer damage rates: [complete%, partial%].
// A partial of 0 means the dealer's result is binary - it kills or it does nothing.
// These are the design rates for each strike dealer against each cargo type.
MISSION_CORE_fnc_reconDealerDamage = {
    params ["_dealer", "_cargo"];
    private _d = toLower (if (_dealer isEqualType "") then { _dealer } else { "" });
    private _t = switch (toLower (if (_cargo isEqualType "") then { _cargo } else { "" })) do {
        // Tank: a hit that lands destroys the column. No partial, no slow.
        case "tank": { [["paveway", 95, 0], ["mlrs", 15, 0], ["spg", 10, 0]] };
        // Ammo convoy: a hit kills exactly one truck, or nothing. No partial ammo loss.
        case "ammo": { [["paveway", 99, 0], ["mlrs", 50, 0], ["spg", 30, 0]] };
        // Manpower: paveway kills outright; mlrs/spg can clip the batch.
        case "manpower": { [["paveway", 99, 0], ["mlrs", 20, 40], ["spg", 20, 20]] };
        default { [] };
    };
    if (count _t == 0) exitWith { [0, 0] };
    private _row = _t findIf { (_x select 0) == _d };
    if (_row < 0) exitWith { [0, 0] };
    [(_t select _row) select 1, (_t select _row) select 2]
};

// Aggregated recon power: [units, detectBonus, hitChanceBonus, destroyWeightBonus]
MISSION_CORE_fnc_reconTotals = {
    private _n = 0;
    private _det = 0;
    private _hit = 0;
    private _dest = 0;
    if (isNil "MISSION_CORE_RECON_UNITS" || isNil "MISSION_CORE_RECON_GEAR") exitWith { [0, 0, 0, 0] };
    {
        if (typeName _x == "ARRAY") then {
            _n = _n + 1;
            {
                private _gid = _x;
                private _gi = MISSION_CORE_RECON_GEAR findIf { (_x select 0) == _gid };
                if (_gi >= 0) then {
                    private _eff = (MISSION_CORE_RECON_GEAR select _gi) select 3;
                    _det = _det + (_eff select 0);
                    _hit = _hit + (_eff select 1);
                    _dest = _dest + (_eff select 2);
                };
            } forEach _x;
        };
    } forEach MISSION_CORE_RECON_UNITS;
    [_n, _det, _hit, _dest]
};

// Server-authoritative spend from the unlock menu (invoked via remoteExec).
MISSION_CORE_fnc_reconServerAction = {
    params ["_caller", "_kind", "_slot", ["_item", ""]];
    if (!isServer) exitWith {};
    if (isNull _caller || isNil "MISSION_CORE_RECON_UNITS") exitWith {};
    // Server-authoritative rank gate: only a COLONEL/GENERAL (CO) may spend renown. Runs on every
    // spend regardless of how the client came in (remoteExec is spoofable).
    if !(rank _caller in ["COLONEL", "GENERAL"]) exitWith {
        [format ["%1 (%2) tried Force Recon spend - access denied (COLONEL only).", name _caller, rank _caller]] remoteExec ["systemChat", 0];
    };
    private _maxR = count MISSION_CORE_RECON_UNITS;
    if (_slot < 0 || { _slot >= _maxR }) exitWith {};
    switch (_kind) do {
        case "unlock": {
            if (typeName (MISSION_CORE_RECON_UNITS select _slot) == "ARRAY") exitWith {};
            private _cost = (["reconUnitCostBase", 100] call MISSION_CORE_fnc_tune) + _slot * (["reconUnitCostStep", 75] call MISSION_CORE_fnc_tune);
            if (MISSION_CORE_RENOWN >= _cost) then {
                MISSION_CORE_RENOWN = MISSION_CORE_RENOWN - _cost;
                MISSION_CORE_RECON_UNITS set [_slot, []];
                publicVariable "MISSION_CORE_RECON_UNITS";
                publicVariable "MISSION_CORE_RENOWN";
                [format ["Recon unit %1 unlocked (-%2 renown)", _slot + 1, _cost]] remoteExec ["MISSION_CORE_fnc_reconHint", _caller];
            } else {
                [format ["Need %1 renown to unlock unit %2", _cost, _slot + 1]] remoteExec ["MISSION_CORE_fnc_reconHint", _caller];
            };
        };
        case "equip": {
            if (typeName (MISSION_CORE_RECON_UNITS select _slot) != "ARRAY") exitWith { ["Unlock this unit first"] remoteExec ["MISSION_CORE_fnc_reconHint", _caller]; };
            if (_item == "") exitWith {};
            private _gi = MISSION_CORE_RECON_GEAR findIf { (_x select 0) == _item };
            if (_gi < 0) exitWith {};
            private _g = MISSION_CORE_RECON_GEAR select _gi;
            private _cost = _g select 2;
            if (_item in (MISSION_CORE_RECON_UNITS select _slot)) exitWith { ["Equipment already installed"] remoteExec ["MISSION_CORE_fnc_reconHint", _caller]; };
            if (MISSION_CORE_RENOWN >= _cost) then {
                MISSION_CORE_RENOWN = MISSION_CORE_RENOWN - _cost;
                (MISSION_CORE_RECON_UNITS select _slot) pushBack _item;
                publicVariable "MISSION_CORE_RECON_UNITS";
                publicVariable "MISSION_CORE_RENOWN";
                [format ["%1 installed on unit %2 (-%3 renown)", _g select 1, _slot + 1, _cost]] remoteExec ["MISSION_CORE_fnc_reconHint", _caller];
            } else {
                [format ["Need %1 renown for %2", _cost, _g select 1]] remoteExec ["MISSION_CORE_fnc_reconHint", _caller];
            };
        };
    };
};

// Housekeeping: drop reveal markers whose convoy no longer exists, update live marker positions.
// Tracks all three convoy classes - supply (MISSION_CORE_CONVOYS), manpower (MISSION_CORE_MANPOWER_CONVOYS)
// and armor (MISSION_CORE_TANK_SHIPMENTS) - each record carrying its own _cid + marker field.
MISSION_CORE_fnc_reconTickHousekeep = {
    if (isNil "MISSION_CORE_RECON_MARKERS") then { MISSION_CORE_RECON_MARKERS = createHashMap; };
    if (isNil "MISSION_CORE_CONVOYS") then { MISSION_CORE_CONVOYS = []; };
    if (isNil "MISSION_CORE_MANPOWER_CONVOYS") then { MISSION_CORE_MANPOWER_CONVOYS = []; };
    if (isNil "MISSION_CORE_TANK_SHIPMENTS") then { MISSION_CORE_TANK_SHIPMENTS = []; };
    if (isNil "MISSION_CORE_PORTS") then { MISSION_CORE_PORTS = createHashMap; };
    private _cids = [];
    { if (count _x > 10) then { _cids pushBack (_x select 10); }; } forEach MISSION_CORE_CONVOYS;
    private _mpCids = [];
    { if (count _x > 4) then { _mpCids pushBack (_x select 4); }; } forEach MISSION_CORE_MANPOWER_CONVOYS;
    private _tkCids = [];
    { if (count _x > 12) then { _tkCids pushBack (_x select 12); }; } forEach MISSION_CORE_TANK_SHIPMENTS;
    if (isNil "MISSION_CORE_AMMO_CONVOYS") then { MISSION_CORE_AMMO_CONVOYS = []; };
    if (isNil "MISSION_CORE_ARMOR_ORDERS") then { MISSION_CORE_ARMOR_ORDERS = []; };
    private _amCids = [];
    { if (count _x > 4) then { _amCids pushBack (_x select 4); }; } forEach MISSION_CORE_AMMO_CONVOYS;
    private _aoCids = [];
    { if (count _x > 12) then { _aoCids pushBack (_x select 12); }; } forEach MISSION_CORE_ARMOR_ORDERS;
    private _live = _cids + _mpCids + _tkCids + _amCids + _aoCids;
    {
        private _cid = _x;
        if (!(_cid in _live)) then {
            // The convoy is gone: delivered, destroyed, or written off. Its intel
            // marker has to go with it, or the icon sits on the map forever.
            [_cid] call MISSION_CORE_fnc_reconDropMarker;
        } else {
            private _mkr = MISSION_CORE_RECON_MARKERS getOrDefault [_cid, ""];
            if (_mkr != "") then {
                private _si = _cids find _cid;
                if (_si >= 0) then {
                    private _convoy = MISSION_CORE_CONVOYS select _si;
                    private _pos = if ((_convoy select 7) == 1 && { !isNull (_convoy select 8) } && { alive (_convoy select 8) }) then {
                        getPos (_convoy select 8)
                    } else {
                        private _frac = ((time - (_convoy select 5)) / (_convoy select 4)) min 1;
                        [(_convoy select 2), (_convoy select 3), _frac] call MISSION_CORE_fnc_convoyPosAt
                    };
                    private _etaMin = ceil (((_convoy select 4) - (time - (_convoy select 5))) / 60) max 1;
                    _mkr setMarkerPos _pos;
                    _mkr setMarkerText format ["SUPPLY CONVOY: %1 -> %2 | ETA ~%3 min", _convoy select 0, _convoy select 1, _etaMin];
                } else {
                    private _mi = _mpCids find _cid;
                    if (_mi >= 0) then {
                        private _convoy = MISSION_CORE_MANPOWER_CONVOYS select _mi;
                        private _pName = _convoy select 0;
                        private _bName = _convoy select 1;
                        private _arrive = _convoy select 3;
                        private _pInfo = MISSION_CORE_PORTS getOrDefault [_pName, []];
                        if (count _pInfo > 0) then {
                            private _pPos = _pInfo select 0;
                            private _bIdx = MISSION_CORE_CACHED_POSITIONS findIf { (_x select 0) == _bName };
                            if (_bIdx >= 0) then {
                                private _bPos = (MISSION_CORE_CACHED_POSITIONS select _bIdx) select 1;
                                // Prefer the stored ROAD path. The straight-line lerp this replaced
                                // drew the icon over terrain the convoy was not on, and recomputed ETA
                                // from distance2D, so a road-winding trip was drawn as a short hop.
                                private _roadPath = _convoy param [6, []];
                                private _cum = _convoy param [7, []];
                                private _travel = _convoy param [8, 0];
                                private _pos = if (count _roadPath >= 2 && { _travel > 0 } && { count _cum > 0 }) then {
                                    private _frac = ((time - (_arrive - _travel)) / _travel) min 1;
                                    if (_frac < 0) then { _frac = 0; };
                                    [_roadPath, _cum, _frac] call MISSION_CORE_fnc_convoyPosAt
                                } else {
                                    // Entry predates the road path (or routing failed): old behaviour.
                                    private _eta = (_pPos distance2D _bPos) / (["manpowerConvoySpeed", 14] call MISSION_CORE_fnc_tune);
                                    private _frac = ((time - (_arrive - _eta)) / _eta) min 1;
                                    if (_frac < 0) then { _frac = 0; };
                                    [
                                        (_pPos select 0) + ((_bPos select 0) - (_pPos select 0)) * _frac,
                                        (_pPos select 1) + ((_bPos select 1) - (_pPos select 1)) * _frac,
                                        0
                                    ];
                                };
                                private _etaMin = ceil ((_arrive - time) / 60) max 1;
                                _mkr setMarkerPos _pos;
                                _mkr setMarkerText format ["MANPOWER CONVOY: %1 -> %2 | ETA ~%3 min", _pName, _bName, _etaMin];
                            };
                        };
                    } else {
                        private _ti = _tkCids find _cid;
                        if (_ti >= 0) then {
                            private _convoy = MISSION_CORE_TANK_SHIPMENTS select _ti;
                            private _pos = if ((_convoy select 9) == 1 && { count (_convoy select 10) > 0 }) then {
                                private _lead = (_convoy select 10) select 0;
                                if (isNull _lead) then { [0, 0, 0] } else { getPos _lead }
                            } else {
                                private _frac = ((time - (_convoy select 8)) / (_convoy select 7)) min 1;
                                [(_convoy select 5), (_convoy select 6), _frac] call MISSION_CORE_fnc_convoyPosAt
                            };
                            private _etaMin = ceil ((((_convoy select 8) + (_convoy select 7)) - time) / 60) max 1;
                            _mkr setMarkerPos _pos;
                            _mkr setMarkerText format ["ARMOR CONVOY: %1 -> %2 | ETA ~%3 min", _convoy select 1, _convoy select 2, _etaMin];
                        } else {
                            private _ami = _amCids find _cid;
                            if (_ami >= 0) then {
                                // Abstract ammo shipment: position is derived from the stored road
                                // path, never a straight line, so the icon follows the road it is
                                // credited along.
                                private _convoy = MISSION_CORE_AMMO_CONVOYS select _ami;
                                private _travel = _convoy param [8, 0];
                                private _pos = if (_travel > 0) then {
                                    private _frac = ((time - ((_convoy select 3) - _travel)) / _travel) min 1;
                                    if (_frac < 0) then { _frac = 0; };
                                    [(_convoy select 6), (_convoy select 7), _frac] call MISSION_CORE_fnc_deliveryPosAt
                                } else {
                                    [0, 0, 0]
                                };
                                private _etaMin = ceil (((_convoy select 3) - time) / 60) max 1;
                                _mkr setMarkerPos _pos;
                                _mkr setMarkerText format ["AMMO CONVOY: %1 -> %2 | %3 | ETA ~%4 min", _convoy select 0, _convoy select 1, _convoy select 5, _etaMin];
                            } else {
                                private _aoi = _aoCids find _cid;
                                if (_aoi >= 0) then {
                                    // Inbound armor order. The icon keeps walking the road route
                                    // after the order lands, until a player is close enough for the
                                    // vehicle to actually be created.
                                    private _order = MISSION_CORE_ARMOR_ORDERS select _aoi;
                                    private _travel = _order param [8, 0];
                                    private _pos = if (_travel > 0) then {
                                        private _frac = ((time - (_order select 9)) / _travel) min 1;
                                        if (_frac < 0) then { _frac = 0; };
                                        [(_order select 6), (_order select 7), _frac] call MISSION_CORE_fnc_deliveryPosAt
                                    } else {
                                        [0, 0, 0]
                                    };
                                    private _etaMin = ceil ((((_order select 9) + _travel) - time) / 60) max 1;
                                    _mkr setMarkerPos _pos;
                                    _mkr setMarkerText format ["ARMOR ORDER: %1 -> %2 | %3 | ETA ~%4 min", _order select 1, _order select 2, _order select 5, _etaMin];
                                };
                            };
                        };
                    };
                };
            };
        };
    } forEach (keys MISSION_CORE_RECON_MARKERS);
};

// Fraction of a journey completed, clamped to 0..1. Shared by every reveal block
// so the "min 1" and the negative-guard are not re-typed five times - three of
// the five had one, two did not, which is how a marker ends up behind its
// convoy after a long pause. Returns 0 for a non-positive span rather than
// dividing by it.
MISSION_CORE_fnc_reconFrac = {
    params [["_start", 0], ["_span", -1]];
    if (!(_span isEqualType 1) || { _span <= 0 }) exitWith { 0 };
    private _f = (time - _start) / _span;
    if (_f < 0) then { _f = 0; };
    if (_f > 1) then { _f = 1; };
    _f
};

// Create, label and register one revealed-convoy marker. Every cargo class did
// this inline and the copies had drifted: three marker sizes, four notification
// shapes, and the registration into MISSION_CORE_RECON_MARKERS was easy to forget
// (which leaks a marker forever, since housekeep only deletes what it can find).
// Returns the marker name so the caller can store it on its own record.
MISSION_CORE_fnc_reconReveal = {
    params ["_cid", "_pos", "_type", "_color", "_size", "_text", "_notifTitle", "_notifBody", "_log"];
    if (isNil "MISSION_CORE_RECON_INTEL_IDX") then { MISSION_CORE_RECON_INTEL_IDX = 0; };
    if (isNil "MISSION_CORE_RECON_MARKERS") then { MISSION_CORE_RECON_MARKERS = createHashMap; };
    private _mkr = format ["DynOps_Recon%1", MISSION_CORE_RECON_INTEL_IDX];
    MISSION_CORE_RECON_INTEL_IDX = MISSION_CORE_RECON_INTEL_IDX + 1;
    // ORPHAN GUARD. MISSION_CORE_RECON_MARKERS maps cid -> marker NAME, so overwriting an existing
    // entry would lose the only reference to that marker and it could never be deleted again. Every
    // producer now draws from one shared counter, so this should be unreachable - but dropping the
    // old marker costs nothing and turns a permanent leak into a visible warning.
    private _prev = MISSION_CORE_RECON_MARKERS getOrDefault [_cid, ""];
    if (_prev != "" && { _prev != _mkr }) then {
        diag_log format ["RENOWN/RECON: cid %1 already owned by %2 - dropping it before reusing for %3", _cid, _prev, _mkr];
        deleteMarker _prev;
    };
    createMarker [_mkr, _pos];
    _mkr setMarkerShape "ICON";
    _mkr setMarkerType _type;
    _mkr setMarkerColor _color;
    _mkr setMarkerSize [_size, _size];
    _mkr setMarkerText _text;
    MISSION_CORE_RECON_MARKERS set [_cid, _mkr];
    if (_notifTitle != "") then {
        ["DynOps_ReconIntel", [_notifTitle, _notifBody]] remoteExec ["BIS_fnc_showNotification", 0];
    };
    if (_log != "") then { diag_log _log; };
    _mkr
};

// Teardown counterpart to MISSION_CORE_fnc_reconReveal: forget the marker for _cid
// and delete it. The "is there even a marker" branch lives here so callers holding
// only a convoy id stop repeating it - forgetting the deleteAt leaves a stale entry
// that housekeep then iterates forever.
MISSION_CORE_fnc_reconDropMarker = {
    params ["_cid"];
    if (isNil "MISSION_CORE_RECON_MARKERS") then { MISSION_CORE_RECON_MARKERS = createHashMap; };
    private _mkr = MISSION_CORE_RECON_MARKERS getOrDefault [_cid, ""];
    if (_mkr != "") then {
        deleteMarker _mkr;
        diag_log format ["RENOWN/RECON: dropped intel marker %1 for cid %2", _mkr, _cid];
    };
    MISSION_CORE_RECON_MARKERS deleteAt [_cid];
};

// ---- MOVE ORDERS --------------------------------------------------------
// A recon unit is abstract: it has no body on the map, so instead of spawning
// anything the player sends it somewhere and the line is drawn. The spotter then
// reads the destination's position and above-sea-level height.
//
// 1 unlocked slot = 1 on-station observer. The line is drawn from the player's
// HQ to the chosen destination, steered around the edges of enemy (red) markers,
// and recon only starts spotting once it has arrived.

// Enemy ("red zone") markers the move line must steer around, as [centre, radius] pairs.
MISSION_CORE_fnc_reconEnemyZones = {
    private _zones = [];
    if (isNil "MISSION_CORE_LOCATIONS") exitWith { _zones };
    private _rad = ["reconRedZoneRadius", 250] call MISSION_CORE_fnc_tune;
    if (!(_rad isEqualType 1) || { _rad <= 0 }) then { _rad = 250; };
    {
        if ((_x select 5) != EAST) then { continue; };
        private _p = ((_x select 1) select 0);
        if (!(_p isEqualType []) || { count _p < 3 }) then { continue; };
        _zones pushBack [_p, _rad];
    } forEach MISSION_CORE_LOCATIONS;
    _zones
};

// Draw a polyline from _from to _to that steers around the edges of enemy markers.
// Zones the straight line passes through get a waypoint just outside their edge,
// on whichever side reaches the destination with the shorter detour.
MISSION_CORE_fnc_reconSteerLine = {
    params ["_from", "_to"];
    if (!(_from isEqualType []) || { !(_to isEqualType []) }) exitWith { [] };
    if (count _from < 3 || { count _to < 3 }) exitWith { [] };
    private _zones = [] call MISSION_CORE_fnc_reconEnemyZones;
    // Unit direction along the line, 2D. Written out rather than using a BIS
    // vector helper: this build rejects the infix/prefix operator forms, and the
    // equivalent in plain arithmetic has no such dependency.
    private _dx = (_to select 0) - (_from select 0);
    private _dy = (_to select 1) - (_from select 1);
    private _lineLen = sqrt (_dx * _dx + _dy * _dy);
    if (_lineLen <= 0) exitWith { [_from, _to] };
    private _ux = _dx / _lineLen;
    private _uy = _dy / _lineLen;
    private _pts = [_from];
    // Walk the line in travel order so detours are inserted in sequence.
    private _blocks = [];
    {
        private _c = _x select 0;
        private _r = _x select 1;
        // Projection of the zone centre onto the line, as a distance along it.
        private _t = ((_c select 0) - (_from select 0)) * _ux + ((_c select 1) - (_from select 1)) * _uy;
        if (_t <= 0 || { _t >= _lineLen }) then { continue; };
        private _closest = [(_from select 0) + (_ux * _t), (_from select 1) + (_uy * _t), 0];
        if ((_closest distance2D _c) >= _r) then { continue; };
        // Perpendicular unit, used to step just outside the zone edge. Both sides
        // are built as full 3-element positions: a polyline marker and the 3D
        // `distance` in reconPathLength both reject 2-element points, and a
        // polyline whose points are a mix of 2 and 3 is what produced
        // "3 elements provided, 4 expected" on setMarkerPolyline.
        private _sideA = [(_c select 0) - (_uy * _r * 1.15), (_c select 1) + (_ux * _r * 1.15), 0];
        private _sideB = [(_c select 0) + (_uy * _r * 1.15), (_c select 1) - (_ux * _r * 1.15), 0];
        // Whichever side is nearer the destination is the shorter detour.
        private _wp = if ((_sideA distance2D _to) <= (_sideB distance2D _to)) then { _sideA } else { _sideB };
        _blocks pushBack [_t, _wp];
    } forEach _zones;
    // Sorted by projection along the line so detour waypoints are inserted in
    // travel order. Uses the BIS helper rather than the bare `sortBy` command -
    // sortBy is not dependable in this build, the same way `reverse` is not.
    _blocks = [_blocks, [], { (_x select 0) }, "ASCEND"] call BIS_fnc_sortBy;
    {
        private _wp = _x select 1;
        if (count _pts > 0) then {
            private _last = _pts select ((count _pts) - 1);
            if ((_last distance _wp) < 1) then { continue; };
        };
        _pts pushBack _wp;
    } forEach _blocks;
    _pts pushBack _to;
    _pts
};

// Total ground length of a polyline.
MISSION_CORE_fnc_reconPathLength = {
    params ["_pts"];
    if (!(_pts isEqualType []) || { count _pts < 2 }) exitWith { 0 };
    private _sum = 0;
    private _prev = _pts select 0;
    // forEach + _forEachIndex, not a C-style for loop - this engine has neither
    // `for (init; cond; incr)` nor ++, and the mission uses this form throughout.
    {
        if (_forEachIndex == 0) then { continue; };
        private _p = _x;
        if (_p isEqualType [] && { count _p >= 3 }) then {
            _sum = _sum + (_prev distance _p);
            _prev = _p;
        };
    } forEach _pts;
    _sum
};

// Validate a move order. Returns [errorString, hqPos]. errorString is "" when the
// order is valid. hqPos is only meaningful on success.
MISSION_CORE_fnc_reconSetMoveValidate = {
    params ["_caller", "_slot", "_dest"];
    if (isNil "MISSION_CORE_RECON_UNITS") exitWith { ["no recon state", []] };
    if (isNil "MISSION_CORE_LOCATIONS") exitWith { ["no locations", []] };
    if (isNull _caller) exitWith { ["no caller", []] };
    if (!(rank _caller in ["COLONEL", "GENERAL"])) exitWith { ["CO only", []] };
    if (!(_slot isEqualType 0) || { _slot < 0 || { _slot >= count MISSION_CORE_RECON_UNITS } }) exitWith { ["bad slot", []] };
    if (typeName (MISSION_CORE_RECON_UNITS select _slot) != "ARRAY") exitWith { ["slot not unlocked", []] };
    if (!(_dest isEqualType []) || { count _dest < 3 }) exitWith { ["bad destination", []] };
    private _hq = MISSION_CORE_LOCATIONS findIf { (_x select 5) == WEST && { toLower (_x select 2) == "hq" } };
    if (_hq < 0) exitWith { ["no HQ", []] };
    private _from = ((MISSION_CORE_LOCATIONS select _hq) select 1) select 0;
    if (!(_from isEqualType []) || { count _from < 3 }) exitWith { ["bad HQ", []] };
    ["", _from]
};

// Server action: send an unlocked recon slot to a destination. Draws the steered
// line from the issuing player's HQ and starts the travel clock.
// Tell the issuing player their order was refused, and log why.
MISSION_CORE_fnc_reconMoveReject = {
    params ["_caller", "_err"];
    if (!isNull _caller) then { [_caller, [_err]] remoteExec ["MISSION_CORE_fnc_reconMoveResult", _caller]; };
    diag_log format ["RENOWN/RECON: move order rejected - %1", _err];
};

MISSION_CORE_fnc_reconSetMove = {
    params ["_caller", "_slot", "_dest"];
    if (!isServer) exitWith {};
    private _v = [_caller, _slot, _dest] call MISSION_CORE_fnc_reconSetMoveValidate;
    if ((_v select 0) != "") then {
        [_caller, (_v select 0)] call MISSION_CORE_fnc_reconMoveReject;
    } else {
        private _from = _v select 1;
        private _line = [_from, _dest] call MISSION_CORE_fnc_reconSteerLine;
        if (count _line < 2) then {
            diag_log "RENOWN/RECON: move order produced no line";
        } else {
            private _dist = [_line] call MISSION_CORE_fnc_reconPathLength;
            // 30 mph = 13.411 m/s, over the drawn line length.
            private _speed = ["reconMoveSpeed", 13.411] call MISSION_CORE_fnc_tune;
            if (!(_speed isEqualType 1) || { _speed <= 0 }) then { _speed = 13.411; };
            private _travel = _dist / _speed;
            if (isNil "MISSION_CORE_RECON_MOVES") then { MISSION_CORE_RECON_MOVES = createHashMap; };
            private _name = format ["DynOps_ReconMove_%1_%2", _caller, diag_tickTime];
            MISSION_CORE_RECON_MOVES set [_slot, [_dest, _line, _travel, (time + _travel), false, 0, _name]];
            publicVariable "MISSION_CORE_RECON_MOVES";
            // Draw the move line so the player can see where recon is headed.
            // Mirrors the routine route drawing at the bottom of this file: a
            // GLOBAL marker with the GLOBAL set commands. createMarkerLocal on
            // the server is never propagated to clients.
            //
            // setMarkerPolyline does NOT take an array of positions. It wants a
            // FLAT array of coordinate pairs - [x1, y1, x2, y2, ...] - with
            // count >= 4 and an even count. Passing an array of 3-element
            // positions is what produced "3 elements provided, 4 expected", and
            // the steepest line here only has 2 points, i.e. 2 elements, which is
            // below the minimum of 4. Z is dropped: polyline markers are 2D.
            private _flat = [];
            {
                if (_x isEqualType [] && { count _x >= 2 }) then {
                    _flat append [_x select 0, _x select 1];
                };
            } forEach _line;
            if ((count _flat >= 4) && { (count _flat mod 2) == 0 }) then {
                private _m = createMarker [_name, [(_flat select 0), (_flat select 1), 0]];
                _m setMarkerShape "POLYLINE";
                _m setMarkerPolyline _flat;
                _m setMarkerColor "ColorGreen";
                _m setMarkerSize [1.5, 1.5];
                _m setMarkerText format ["RECON %1 -> move point (%2m, ~%3s)", _slot + 1, round _dist, round _travel];
            } else {
                // A straight HQ-to-destination leg with no zone to steer around is
                // only 2 points. A 2-point polyline marker cannot be expressed, so
                // draw a small marker at the destination instead of nothing.
                diag_log format ["RENOWN/RECON: slot %1 line too short for a polyline (%2 flat elements)", _slot, count _flat];
                if (count _flat >= 2) then {
                    private _m = createMarker [_name, [(_flat select (count _flat - 2)), (_flat select (count _flat - 1)), 0]];
                    _m setMarkerType "Milestone";
                    _m setMarkerColor "ColorGreen";
                    _m setMarkerText format ["RECON %1 move point (%2m, ~%3s)", _slot + 1, round _dist, round _travel];
                };
            };
            diag_log format ["RENOWN/RECON: slot %1 move order - line %2m, travel %3s", _slot, round _dist, round _travel];
            // Tell the issuing player it worked. Send an explicit empty string, not
            // an empty params array - with [] as the whole argument list the
            // receiving function's params default is not applied and the client
            // throws "Generic error in expression" on the comparison.
            [_caller, [""]] remoteExec ["MISSION_CORE_fnc_reconMoveResult", _caller];
        };
    };
};

// Server action: recall a slot to HQ. It stops being an observer immediately.
MISSION_CORE_fnc_reconClearMove = {
    params ["_caller", "_slot"];
    if (!isServer) exitWith {};
    if (isNil "MISSION_CORE_RECON_MOVES") exitWith {};
    if (isNull _caller) exitWith {};
    if (!(rank _caller in ["COLONEL", "GENERAL"])) exitWith {};
    if (!(_slot isEqualType 0) || { _slot < 0 }) exitWith {};
    private _m = MISSION_CORE_RECON_MOVES getOrDefault [_slot, []];
    if (!(_m isEqualType []) || { count _m < 7 }) exitWith {};
    private _name = _m select 6;
    // deleteMarker, not deleteMarkerLocal - the move line is created with
    // createMarker so clients can see it, and it has to be removed the same way.
    if (_name isEqualType "" && { _name != "" }) then { deleteMarker _name; };
    MISSION_CORE_RECON_MOVES deleteAt _slot;
    publicVariable "MISSION_CORE_RECON_MOVES";
    diag_log format ["RENOWN/RECON: slot %1 recalled to HQ", _slot];
};

// Advance move orders: recon that has arrived becomes an on-station observer and
// gets its above-sea-level test at the destination.
MISSION_CORE_fnc_reconTickMoves = {
    if (isNil "MISSION_CORE_RECON_MOVES") exitWith {};
    if (isNil "MISSION_CORE_RECON_UNITS") exitWith {};
    {
        private _slot = _x;
        private _m = MISSION_CORE_RECON_MOVES getOrDefault [_slot, []];
        if (!(_m isEqualType []) || { count _m < 7 }) then { continue; };
        // Index 3 is the arrival timestamp, index 4 the arrived flag. Testing the
        // timestamp for truthiness skipped every order (a time is never 0), so a
        // move could never arrive.
        if (_m select 4) then { continue; };
        if (time < (_m select 3)) then { continue; };
        // Arrived. Re-read the destination's height above sea level.
        private _dest = _m select 0;
        private _h = 0;
        if (_dest isEqualType [] && { count _dest >= 3 }) then { _h = ((getTerrainHeightASL _dest) max 0) min 4000; };
        _m set [3, time];
        _m set [4, true];
        _m set [5, _h];
        // The move line has served its purpose once recon is on target, so take it
        // off the map. deleteMarker, because the line was drawn with createMarker
        // for clients to see. Index 6 is cleared afterwards so a later recall does
        // not try to delete the same marker a second time.
        private _name = _m select 6;
        if (_name isEqualType "" && { _name != "" }) then {
            deleteMarker _name;
            _m set [6, ""];
        };
        MISSION_CORE_RECON_MOVES set [_slot, _m];
        diag_log format ["RENOWN/RECON: slot %1 arrived on station, ASL %2m", _slot, round _h];
    // keys + getOrDefault, the pattern the rest of the mission uses on every
    // HashMap walk. `copyFromKeys` and a `toArray` method are both unavailable
    // in this build - the first is a parse error, the second an unexpected ')'.
    } forEach (keys MISSION_CORE_RECON_MOVES);
};

// On-station observers: the destination ASL of every arrived move order. Each is
// a position, not a unit, so this feeds the spotter's range/altitude bands.
MISSION_CORE_fnc_reconEyes = {
    private _eyes = [];
    if (isNil "MISSION_CORE_RECON_MOVES") exitWith { _eyes };
    if (isNil "MISSION_CORE_RECON_UNITS") exitWith { _eyes };
        {
            private _slot = _x;
            private _m = MISSION_CORE_RECON_MOVES getOrDefault [_slot, []];
            if (!(_m isEqualType []) || { count _m < 7 }) then { continue; };
            if (!(_m select 4)) then { continue; };
            if (_slot >= count MISSION_CORE_RECON_UNITS) then { continue; };
            // An unlocked slot IS an observer, gear or no gear. The old test was
            // "is this slot an ARRAY with gear in it", so a recon unit that had
            // been unlocked but not yet given optics never contributed a position.
            // That left _eyes empty, and reconSpotChance answers an empty _eyes with
            // the flat fallback roll - a constant that ignored the range/altitude
            // bands entirely, which is why the reported chance was always the same
            // number regardless of how far away the convoy was.
            //
            // The test is on TYPE, not truth: an unlocked slot with no gear holds [],
            // and [] is falsy in SQF, so a truthiness check would skip it too.
            // Locked is the boolean false (see the init that pushBacks false);
            // unlocked is always an array, empty or not.
            if (typeName (MISSION_CORE_RECON_UNITS select _slot) == "BOOL") then { continue; };
        // The observer is the destination at the height measured on arrival -
        // index 5 of the record, already ASL. No conversion helper needed, and
        // nothing that could return a non-array into the range/altitude bands.
        private _dest = _m select 0;
        if (!(_dest isEqualType []) || { count _dest < 2 }) then { continue; };
        private _h = if ((_m select 5) isEqualType 1) then { _m select 5 } else { 0 };
        _eyes pushBack [_dest select 0, _dest select 1, _h];
    } forEach (keys MISSION_CORE_RECON_MOVES);
    _eyes
};

// Range from _targetPos to the nearest on-station observer, or -1 when there are
// none. Diagnostics only: the chance itself is computed inside reconSpotChance.
// Printed alongside every reveal so a reveal can be read as banded (graph applied)
// or FLAT FALLBACK (no observers, distance ignored).
MISSION_CORE_fnc_reconEyeRange = {
    params ["_targetPos"];
    if (!(_targetPos isEqualType []) || { count _targetPos < 2 }) exitWith { -1 };
    private _eyes = [] call MISSION_CORE_fnc_reconEyes;
    if (count _eyes == 0) exitWith { -1 };
    private _best = 1e12;
    {
        if (_x isEqualType [] && { count _x >= 2 }) then {
            private _d = _targetPos distance2D [_x select 0, _x select 1];
            if (_d < _best) then { _best = _d; };
        };
    } forEach _eyes;
    round _best
};

// Chance that recon spots a convoy at _targetPos, as a percentage.
//
// Driven by how far away the convoy is and how high the observer is looking from,
// not by a single flat number. The range bands are the design:
//
//     0 - 500 m    90 - 99 %
//     500 m - 1 km 70 - 90 %
//     1 - 2 km     40 - 80 %
//     2 - 5 km     10 - 40 %
//     5 - 9 km      1 - 15 %
//     over 9 km     never
//
// Altitude interpolates inside whichever band the convoy falls in, from the
// floor at ground level to the ceiling at 300 m ASL. A higher recon point sees
// further, but it can never lift the roll above the ceiling for that range - so
// climbing buys you the top of the band and nothing beyond it.
//
// _skill and _bonus are the existing recon-strength terms (unit count, optics,
// designators). They scale the roll up toward the ceiling and stop there, which
// keeps more recon assets worth fielding without letting a swarm of optics
// reveal a convoy from across the map.
//
// Every unit is scored separately and the best one wins, because one spotter
// seeing a convoy is all it takes - a high-far observer does not mask a
// low-close one.
//
// _fallback is the legacy flat roll. With no deployed recon units there is no
// position or altitude to read, so the band model has nothing to work from and the
// flat roll is returned instead. That keeps detection alive until real units exist.
MISSION_CORE_fnc_reconSpotChance = {
    params ["_targetPos", "_units", ["_skill", 1], ["_bonus", 0], ["_fallback", -1]];
    if (!(_targetPos isEqualType [])) exitWith { if (_fallback >= 0) then { _fallback } else { 0 } };
    if (!(_units isEqualType [])) exitWith { if (_fallback >= 0) then { _fallback } else { 0 } };
    if (count _units == 0) exitWith { if (_fallback >= 0) then { ((_fallback min 100) max 0) } else { 0 } };
    private _altMax = ["reconSpotAltMax", 300] call MISSION_CORE_fnc_tune;
    if (!(_altMax isEqualType 1) || { _altMax <= 0 }) then { _altMax = 300; };
    private _bestRoll = 0;
    private _bestCeiling = 0;
    {
        // Observers are positions, not units: a move order contributes the ASL of
        // its destination. Anything that is not a 3-vector is skipped rather than
        // handed to getPosASL.
        if (!(_x isEqualType [])) then { continue; };
        if (count _x < 3) then { continue; };
        private _p = _x;
        private _d = _targetPos distance2D _p;
        private _lo = -1;
        private _hi = 0;
        {
            if (_d <= (_x select 0)) exitWith { _lo = _x select 1; _hi = _x select 2; };
        } forEach [
            [500, 90, 99],
            [1000, 70, 90],
            [2000, 40, 80],
            [5000, 10, 40],
            [9000, 1, 15]
        ];
        // Out of every band: past 9 km nothing is ever spotted, so the ceiling
        // stays 0 and this unit contributes nothing.
        if (_lo < 0) then { continue; };
        private _alt = ((_p select 2) max 0) min _altMax;
        private _roll = _lo + ((_hi - _lo) * (_alt / _altMax));
        if (_roll > _bestRoll) then {
            _bestRoll = _roll;
            _bestCeiling = _hi;
        };
    } forEach _units;
    if (_bestRoll <= 0) exitWith { 0 };
    private _out = (_bestRoll * _skill) + _bonus;
    if (_out > _bestCeiling) then { _out = _bestCeiling; };
    if (_out < 0) then { _out = 0; };
    _out
};

// Detection cycle: dice-roll every abstract convoy. More recon units + optics/designator = more chances.
MISSION_CORE_fnc_reconTickDetect = {
    private _totals = [] call MISSION_CORE_fnc_reconTotals;
    private _n = _totals select 0;
    if (_n == 0) exitWith {};
    if (isNil "MISSION_CORE_CONVOYS") exitWith {};
    if (isNil "MISSION_CORE_RECON_UNITS") then { MISSION_CORE_RECON_UNITS = []; };
    private _base = ["reconDetectBase", 20] call MISSION_CORE_fnc_tune;
    private _perUnit = ["reconDetectPerUnit", 12] call MISSION_CORE_fnc_tune;
    private _detB = _totals select 1;
    // Deployed observers drive the banded spotter. An observer needs an unlocked
    // slot AND an arrived move order, so this list is empty while recon is still
    // en route or sitting at HQ - in which case _flat below is the fallback.
    private _eyes = [] call MISSION_CORE_fnc_reconEyes;
    private _cap = ["reconDetectCap", 70] call MISSION_CORE_fnc_tune;
    private _flat = ((_base + _n * _perUnit + _detB) min _cap) max 0;
    // With no observers the banded spotter has nothing to work from and every roll
    // collapses onto the flat fallback, so say so once per tick rather than letting
    // a constant chance read as a working detection model.
    if (count _eyes == 0) then {
        diag_log format ["RENOWN/RECON: detect tick - no observers on station, using flat roll %1 for %2 recon unit(s)", round _flat, _n];
    };
    // Strength terms, applied by reconSpotChance on top of the range/altitude
    // bands and clamped to the band ceiling, not to the flat cap.
    private _skill = 1 + ((_n * _perUnit) / 100);
    private _chanceBonus = _base + _detB;
    private _knownCap = ["reconRouteKnownReveals", 2] call MISSION_CORE_fnc_tune;
      {
          _x params ["_prov", "_recv", "_roadPath"];
          if (count _x < 11) then { continue; };
          private _cid = _x select 10;
          // "Already spotted" is recon's own knowledge, so it is read from recon's own
          // map. The convoy record used to carry a duplicate marker name in a slot that
          // no supply system ever read - the only thing recon still wrote into a
          // supply-owned record.
          if ((MISSION_CORE_RECON_MARKERS getOrDefault [_cid, ""]) != "") then { continue; };
          if (_x select 7 != 0) then { continue; };
          // Explicit positive-span guard. The old completion test divided by this
          // span without checking it, and dividing by zero happened to skip the
          // convoy; reconFrac returns 0 for a non-positive span instead, so
          // without this a zero-length convoy would read as 0% complete and get
          // revealed after it had already arrived.
          if (!((_x select 4) isEqualType 1) || { (_x select 4) <= 0 }) then { continue; };
          if ([(_x select 5), (_x select 4)] call MISSION_CORE_fnc_reconFrac >= 1) then { continue; };
          private _pairKey = _prov + ">" + _recv;
          private _known = MISSION_CORE_ROUTE_KNOWLEDGE getOrDefault [_pairKey, 0];
          // Position first, then chance: the roll now depends on where the convoy
          // is relative to recon, so it cannot be computed before the convoy's own
          // position on its road is known.
          private _frac = [(_x select 5), (_x select 4)] call MISSION_CORE_fnc_reconFrac;
          private _curPos = [_roadPath, (_x select 3), _frac] call MISSION_CORE_fnc_convoyPosAt;
          private _chance = [_curPos, _eyes, _skill, _chanceBonus, _flat] call MISSION_CORE_fnc_reconSpotChance;
          if (_known >= _knownCap || { random 100 < _chance }) then {
              if (_known < _knownCap) then {
                  MISSION_CORE_ROUTE_KNOWLEDGE set [_pairKey, _known + 1];
                  private _known2 = MISSION_CORE_ROUTE_KNOWLEDGE getOrDefault [_pairKey, 0];
                  if (_known2 >= _knownCap) then { [(_x select 2)] call MISSION_CORE_fnc_reconDrawRoute; };
              };
              private _etaMin = ceil (((_x select 4) - (time - (_x select 5))) / 60) max 1;
              // A route seen enough times counts as routine, which is a stronger
              // notification than a fresh sighting - passed in rather than
              // re-branched here, so this block matches the other four.
              private _routine = _known >= _knownCap;
              [
                  _cid, _curPos, "o_motorized", "ColorOrange", 0.9,
                  format ["SUPPLY CONVOY: %1 -> %2 | ETA ~%3 min", _prov, _recv, _etaMin],
                  if (_routine) then { "ROUTINE SUPPLY ROUTE" } else { "SUPPLY ROUTE REVEALED" },
                  format ["%1 -> %2, ETA ~%3 min", _prov, _recv, _etaMin],
                  format ["RENOWN/RECON: convoy %1 -> %2 revealed by recon (chance %3, %4 observer(s), nearest %5m, %6)", _prov, _recv, round _chance, count _eyes, [_curPos] call MISSION_CORE_fnc_reconEyeRange, if (count _eyes == 0) then { "FLAT FALLBACK" } else { "banded" }]
              ] call MISSION_CORE_fnc_reconReveal;
          };
      } forEach MISSION_CORE_CONVOYS;
    if (isNil "MISSION_CORE_MANPOWER_CONVOYS") then { MISSION_CORE_MANPOWER_CONVOYS = []; };
    if (isNil "MISSION_CORE_PORTS") then { MISSION_CORE_PORTS = createHashMap; };
      {
          if (count _x < 6) then { continue; };
          private _cid = _x select 4;
          if ((MISSION_CORE_RECON_MARKERS getOrDefault [_cid, ""]) != "") then { continue; };
          if (time >= (_x select 3)) then { continue; };
          private _pInfo = MISSION_CORE_PORTS getOrDefault [(_x select 0), []];
          if (count _pInfo == 0) then { continue; };
          if ((_pInfo select 2) != EAST) then { continue; };
          // The road path and its cumulative segments are stored on the record at
          // dispatch (indices 6-8), so the icon is placed along the road the batch
          // actually drives. This block used to rebuild a straight line from port
          // to base and lerp across it, which slid the marker through terrain the
          // convoy was not on, and it looked the base up with a findIf whose _x was
          // the convoy record - comparing the PORT name against the base name, so it
          // never matched. Both now go through the shared functions.
          private _bName = _x select 1;
          private _bIdx = (call MISSION_CORE_fnc_locIndex) getOrDefault [_bName, -1];
          if (_bIdx < 0) then { continue; };
          private _roadPath = _x param [6, []];
          if (!(_roadPath isEqualType []) || { count _roadPath < 2 }) then { continue; };
          private _travel = _x param [8, 0];
          if (!(_travel isEqualType 1) || { _travel <= 0 }) then { continue; };
          private _frac = [((_x select 3) - _travel), _travel] call MISSION_CORE_fnc_reconFrac;
          private _curPos = [_roadPath, (_x select 7), _frac] call MISSION_CORE_fnc_deliveryPosAt;
            private _chance = [_curPos, _eyes, _skill, _chanceBonus, _flat] call MISSION_CORE_fnc_reconSpotChance;
            if (random 100 < _chance) then {
                private _etaMin = ceil (((_x select 3) - time) / 60) max 1;
                [
                    _cid, _curPos, "o_inf", "ColorYellow", 0.9,
                    format ["MANPOWER CONVOY: %1 -> %2 | ETA ~%3 min", _x select 0, _bName, _etaMin],
                    "MANPOWER ROUTE REVEALED",
                    format ["%1 -> %2, ETA ~%3 min", _x select 0, _bName, _etaMin],
                    format ["RENOWN/RECON: manpower convoy %1 -> %2 revealed by recon (chance %3, %4 observer(s), nearest %5m, %6)", _x select 0, _bName, round _chance, count _eyes, [_curPos] call MISSION_CORE_fnc_reconEyeRange, if (count _eyes == 0) then { "FLAT FALLBACK" } else { "banded" }]
              ] call MISSION_CORE_fnc_reconReveal;
          };
      } forEach MISSION_CORE_MANPOWER_CONVOYS;
    if (isNil "MISSION_CORE_TANK_SHIPMENTS") then { MISSION_CORE_TANK_SHIPMENTS = []; };
      {
          if (count _x < 13) then { continue; };
          if ((_x select 0) != EAST) then { continue; };
          private _cid = _x select 12;
          if ((MISSION_CORE_RECON_MARKERS getOrDefault [_cid, ""]) != "") then { continue; };
          if (_x select 9 != 0) then { continue; };
          if (time >= ((_x select 8) + (_x select 7))) then { continue; };
          private _frac = [(_x select 8), (_x select 7)] call MISSION_CORE_fnc_reconFrac;
          private _curPos = [(_x select 5), (_x select 6), _frac] call MISSION_CORE_fnc_convoyPosAt;
          private _chance = [_curPos, _eyes, _skill, _chanceBonus, _flat] call MISSION_CORE_fnc_reconSpotChance;
          if (random 100 < _chance) then {
              private _etaMin = ceil ((((_x select 8) + (_x select 7)) - time) / 60) max 1;
              [
                  _cid, _curPos, "o_armor", "ColorRed", 0.9,
                  format ["ARMOR CONVOY: %1 -> %2 | ETA ~%3 min", _x select 1, _x select 2, _etaMin],
                  "ARMOR ROUTE REVEALED",
                  format ["%1 -> %2, ETA ~%3 min", _x select 1, _x select 2, _etaMin],
                  format ["RENOWN/RECON: armor convoy %1 -> %2 revealed by recon (chance %3, %4 observer(s), nearest %5m, %6)", _x select 1, _x select 2, round _chance, count _eyes, [_curPos] call MISSION_CORE_fnc_reconEyeRange, if (count _eyes == 0) then { "FLAT FALLBACK" } else { "banded" }]
              ] call MISSION_CORE_fnc_reconReveal;
          };
      } forEach MISSION_CORE_TANK_SHIPMENTS;
    if (isNil "MISSION_CORE_AMMO_CONVOYS") then { MISSION_CORE_AMMO_CONVOYS = []; };
      {
          if (count _x < 9) then { continue; };
          private _cid = _x select 4;
          if ((MISSION_CORE_RECON_MARKERS getOrDefault [_cid, ""]) != "") then { continue; };
          if (time >= (_x select 3)) then { continue; };
          private _travel = _x select 8;
          if (_travel <= 0) then { continue; };
          private _frac = [((_x select 3) - _travel), _travel] call MISSION_CORE_fnc_reconFrac;
          private _curPos = [(_x select 6), (_x select 7), _frac] call MISSION_CORE_fnc_deliveryPosAt;
          private _chance = [_curPos, _eyes, _skill, _chanceBonus, _flat] call MISSION_CORE_fnc_reconSpotChance;
          if (random 100 < _chance) then {
              private _etaMin = ceil (((_x select 3) - time) / 60) max 1;
              [
                  _cid, _curPos, "o_supply", "ColorOrange", 0.8,
                  format ["AMMO CONVOY: %1 -> %2 | ETA ~%3 min", _x select 0, _x select 1, _etaMin],
                  "AMMO ROUTE REVEALED",
                  format ["%1 -> %2, ETA ~%3 min", _x select 0, _x select 1, _etaMin],
                  format ["RENOWN/RECON: ammo convoy %1 -> %2 revealed by recon (chance %3, %4 observer(s), nearest %5m, %6)", _x select 0, _x select 1, round _chance, count _eyes, [_curPos] call MISSION_CORE_fnc_reconEyeRange, if (count _eyes == 0) then { "FLAT FALLBACK" } else { "banded" }]
              ] call MISSION_CORE_fnc_reconReveal;
          };
      } forEach MISSION_CORE_AMMO_CONVOYS;
    if (isNil "MISSION_CORE_ARMOR_ORDERS") then { MISSION_CORE_ARMOR_ORDERS = []; };
      {
          if (count _x < 13) then { continue; };
          private _cid = _x select 12;
          if ((MISSION_CORE_RECON_MARKERS getOrDefault [_cid, ""]) != "") then { continue; };
          if ((_x select 0) != EAST) then { continue; };
          if (time >= ((_x select 9) + (_x select 8))) then { continue; };
          private _frac = [(_x select 9), (_x select 8)] call MISSION_CORE_fnc_reconFrac;
          private _curPos = [(_x select 6), (_x select 7), _frac] call MISSION_CORE_fnc_deliveryPosAt;
          private _chance = [_curPos, _eyes, _skill, _chanceBonus, _flat] call MISSION_CORE_fnc_reconSpotChance;
          if (random 100 < _chance) then {
              private _etaMin = ceil ((((_x select 9) + (_x select 8)) - time) / 60) max 1;
              [
                  _cid, _curPos, "o_armor", "ColorRed", 0.9,
                  format ["ARMOR ORDER: %1 -> %2 | %3 | ETA ~%4 min", _x select 1, _x select 2, _x select 5, _etaMin],
                  "ARMOR ORDER REVEALED",
                  format ["%1 -> %2, ETA ~%3 min", _x select 1, _x select 2, _etaMin],
                  format ["RENOWN/RECON: armor order %1 -> %2 revealed by recon (chance %3, %4 observer(s), nearest %5m, %6)", _x select 1, _x select 2, round _chance, count _eyes, [_curPos] call MISSION_CORE_fnc_reconEyeRange, if (count _eyes == 0) then { "FLAT FALLBACK" } else { "banded" }]
              ] call MISSION_CORE_fnc_reconReveal;
          };
      } forEach MISSION_CORE_ARMOR_ORDERS;
};

// Draw a persistent blue polyline for a "routine" supply route (its actual road path).
MISSION_CORE_fnc_reconDrawRoute = {
    params ["_roadPath"];
    if (count _roadPath < 2) exitWith {};
    if (isNil "MISSION_CORE_RECON_ROUTES") then { MISSION_CORE_RECON_ROUTES = createHashMap; };
    private _cap = ["reconRouteCap", 8] call MISSION_CORE_fnc_tune;
    if (count MISSION_CORE_RECON_ROUTES >= _cap) exitWith {};
    // setMarkerPolyline wants a FLAT array of coordinate pairs - [x1, y1, x2,
    // y2, ...] - not the array of positions the router returns. Count must be
    // >= 4 and even. Built and validated BEFORE a marker name is consumed, so a
    // path too short to draw does not burn a name from the index.
    private _flat = [];
    {
        if (_x isEqualType [] && { count _x >= 2 }) then {
            _flat append [_x select 0, _x select 1];
        };
    } forEach _roadPath;
    if ((count _flat < 4) || { (count _flat mod 2) != 0 }) exitWith {
        diag_log format ["RENOWN/RECON: route not drawable (%1 flat elements)", count _flat];
    };
    private _mkr = format ["DynOps_Route%1", MISSION_CORE_RECON_ROUTE_IDX];
    MISSION_CORE_RECON_ROUTE_IDX = MISSION_CORE_RECON_ROUTE_IDX + 1;
    createMarker [_mkr, [(_flat select 0), (_flat select 1), 0]];
    _mkr setMarkerShape "POLYLINE";
    _mkr setMarkerPolyline _flat;
    _mkr setMarkerColor "ColorBlue";
    _mkr setMarkerSize [2, 2];
    MISSION_CORE_RECON_ROUTES set [(str _roadPath), _mkr];
    diag_log format ["RENOWN/RECON: routine supply route drawn (%1 waypoints)", count _roadPath];
    _mkr
};

// Teardown counterpart to reconDrawRoute. These blue polylines are keyed by road path
// rather than convoy id, so reconTickHousekeep cannot see them and they used to live on
// the map until the cap was reached. Call it when the run they described is over.
MISSION_CORE_fnc_reconDropRoute = {
    params ["_roadPath"];
    if (isNil "MISSION_CORE_RECON_ROUTES") then { MISSION_CORE_RECON_ROUTES = createHashMap; };
    private _key = str _roadPath;
    private _mkr = MISSION_CORE_RECON_ROUTES getOrDefault [_key, ""];
    if (_mkr != "") then {
        deleteMarker _mkr;
        diag_log format ["RENOWN/RECON: routine route marker %1 deleted", _mkr];
    };
    MISSION_CORE_RECON_ROUTES deleteAt [_key];
};

// Designate + strike cycle: imaginary fire support rolls dice on revealed convoys only.
// Each owned strike-capable gear (spg/mlrs/paveway) is a real asset on a per-instance
// cooldown. If every such asset is cooling down we skip strikes entirely - the team just
// keeps spotting. Owned gear is pooled from every unlocked unit's gear list.
MISSION_CORE_fnc_reconTickStrike = {
    private _totals = [] call MISSION_CORE_fnc_reconTotals;
    private _n = _totals select 0;
    if (_n == 0) exitWith {};
    if (isNil "MISSION_CORE_CONVOYS") exitWith {};
    if (isNil "MISSION_CORE_RECON_COOLDOWNS") then { MISSION_CORE_RECON_COOLDOWNS = createHashMap; };
    private _assets = [];
    {
        if (typeName _x == "ARRAY") then {
            private _slot = _forEachIndex;
            {
                if (_x in ["spg", "mlrs", "paveway"]) then {
                    private _key = format ["%1_%2", _x, _slot];
                    if ((MISSION_CORE_RECON_COOLDOWNS getOrDefault [_key, 0]) <= time) then {
                        _assets pushBack [_x, _slot];
                    };
                };
            } forEach _x;
        };
    } forEach MISSION_CORE_RECON_UNITS;
    if (count _assets == 0) exitWith { diag_log "RENOWN/RECON: all fire support on cooldown - spotting only"; };
    private _base = ["reconStrikeBase", 15] call MISSION_CORE_fnc_tune;
    private _perUnit = ["reconStrikePerUnit", 10] call MISSION_CORE_fnc_tune;
    private _hitB = _totals select 2;
    private _cap = ["reconStrikeCap", 65] call MISSION_CORE_fnc_tune;
    private _chance = ((_base + _n * _perUnit + _hitB) min _cap) max 0;
    private _destroyW = (15 + (_totals select 3)) min (["reconDestroyCap", 45] call MISSION_CORE_fnc_tune);
    private _renownAmt = ["renownPerConvoy", 15] call MISSION_CORE_fnc_tune;
    private _i = 0;
    while { _i < count MISSION_CORE_CONVOYS } do {
        private _convoy = MISSION_CORE_CONVOYS select _i;
        _i = _i + 1;
        _convoy params ["_prov", "_recv", "_roadPath", "_cum", "_travelTime", "_departTime", "_amount", "_state", "_truck"];
        if (count _convoy < 13) then { continue; };
        if ((MISSION_CORE_RECON_MARKERS getOrDefault [(_convoy select 10), ""]) == "") then { continue; };
        if (_convoy select 11) then { continue; };
        if (((time - _departTime) / _travelTime) >= 1) then { continue; };
        if (count _assets == 0) then { continue; };
        if (random 100 >= _chance) then { continue; };
        [_assets] call MISSION_CORE_fnc_reconStrikeSpend;
        private _roll = random 100;
        if (_roll < _destroyW) then {
            // Destroyed
            if (_state == 0) then {
                // Abstract kill: ask supply to apply its own lost-shipment policy.
                // This used to be an inline copy of that policy - crate, renown, dead
                // flag and marker teardown - with the crate hardcoded and the
                // aggression cost omitted. Supply owns the outcome; recon keeps only
                // its own kill tally, and the marker it drew.
                //
                // The cid comes from _convoy, never from _x. This is a `while` loop
                // over MISSION_CORE_CONVOYS, so there is no _x in scope - referring
                // to it threw "Undefined variable in expression: _x", which aborted
                // the dropMarker call below it and leaked the intel marker. The other
                // three cargo loops already bind a local _cid the same way.
                private _cid = _convoy select 10;
                if ([_convoy, "Recon strike"] call MISSION_CORE_fnc_convoyDisbandAbstract) then {
                    [_cid] call MISSION_CORE_fnc_reconDropMarker;
                  [0, _amount] call MISSION_CORE_fnc_reconLogKill;
                  diag_log format ["RENOWN/RECON: strike destroyed abstract convoy %1 -> %2", _prov, _recv];
              };
            } else {
                // Materialized: kill the real truck - the convoy loop drops the box + awards renown.
                if (!(isNull _truck) && { alive _truck }) then {
                    [0, _amount] call MISSION_CORE_fnc_reconLogKill;
                    _truck setDamage 1;
                };
                ["DynOps_ReconStrike",
                    ["RECON STRIKE", format ["Fire support smashed the %1 -> %2 convoy!", _prov, _recv]]
                ] remoteExec ["BIS_fnc_showNotification", 0];
            };
        } else {
            if (_roll < _destroyW + 45) then {
                // Damaged: supply is halved and an abstract column is slowed. Both the
                // record edit and the anger belong to supply; recon keeps its tally.
                private _lost = [_convoy, 0.5, 1.3] call MISSION_CORE_fnc_convoyShipmentDamage;
                [0, _lost] call MISSION_CORE_fnc_reconLogKill;
                ["DynOps_ReconStrike",
                    ["RECON STRIKE DAMAGED", format ["%1 -> %2 hit - supply halved and slowed", _prov, _recv]]
                ] remoteExec ["BIS_fnc_showNotification", 0];
                diag_log format ["RENOWN/RECON: strike damaged convoy %1 -> %2 (half supply)", _prov, _recv];
            };
        };
    };

    // Manpower shipments (port -> base): killed = the batch never arrives.
    if (isNil "MISSION_CORE_MANPOWER_CONVOYS") then { MISSION_CORE_MANPOWER_CONVOYS = []; };
    if (isNil "MISSION_CORE_PORTS") then { MISSION_CORE_PORTS = createHashMap; };
    private _mpRenown = floor (_renownAmt * (["reconManpowerRenownMult", 0.5] call MISSION_CORE_fnc_tune));
    private _mi = 0;
    while { _mi < count MISSION_CORE_MANPOWER_CONVOYS } do {
        private _convoy = MISSION_CORE_MANPOWER_CONVOYS select _mi;
        if (count _convoy < 6) then { _mi = _mi + 1; continue; };
        private _pInfo = MISSION_CORE_PORTS getOrDefault [(_convoy select 0), []];
        if (count _pInfo == 0) then { _mi = _mi + 1; continue; };
        if ((_pInfo select 2) != EAST) then { _mi = _mi + 1; continue; };
        if ((MISSION_CORE_RECON_MARKERS getOrDefault [(_convoy select 4), ""]) == "") then { _mi = _mi + 1; continue; };
        if (time >= (_convoy select 3)) then { _mi = _mi + 1; continue; };
        if (random 100 >= _chance) then { _mi = _mi + 1; continue; };
        if (count _assets == 0) then { _mi = _mi + 1; continue; };
        private _dealer = [_assets] call MISSION_CORE_fnc_reconStrikeSpend;
        if (_dealer == "") then { _mi = _mi + 1; continue; };
        // Per-dealer result: complete kill, or a clipped batch, or nothing.
        private _dmg = [_dealer, "manpower"] call MISSION_CORE_fnc_reconDealerDamage;
        private _roll2 = random 100;
        private _cid = _convoy select 4;
        private _label = format ["%1 -> %2", _convoy select 0, _convoy select 1];
        private _batch = _convoy select 2;
        if (_roll2 < (_dmg select 0)) then {
            // Complete kill: the truck is lost, the batch never arrives.
            private _killed = _batch;
            // The port system owns the record, the renown terms and the anger; recon
            // keeps only its strike tally. Read every field before the call - a total
            // loss tombstones the record, leaving _convoy empty.
            if ([_mi, _killed, _mpRenown] call MISSION_CORE_fnc_manpowerShipmentLose) then {
                [_cid] call MISSION_CORE_fnc_reconDropMarker;
                [1, round _killed] call MISSION_CORE_fnc_reconLogKill;
                diag_log format ["RENOWN/RECON: %1 killed manpower convoy %2 (%3 men lost)", _dealer, _label, round _killed];
            };
        } else {
            if ((_dmg select 1) > 0 && { _roll2 < ((_dmg select 0) + (_dmg select 1)) }) then {
                private _oldB = _batch;
                // Clipped batch: a partial convoy loss, anger but no bounty.
                if ([_mi, (_oldB - floor (_oldB * 0.5)), 0] call MISSION_CORE_fnc_manpowerShipmentLose) then {
                    [1, (_oldB - floor (_oldB * 0.5))] call MISSION_CORE_fnc_reconLogKill;
                    ["DynOps_ReconStrike",
                        ["RECON STRIKE DAMAGED", format ["%1 manpower hit by %2 - batch halved", _label, _dealer]]
                    ] remoteExec ["BIS_fnc_showNotification", 0];
                    diag_log format ["RENOWN/RECON: %1 clipped manpower convoy %2 (half batch)", _dealer, _label];
                };
            };
        };
        _mi = _mi + 1;
    };
    [MISSION_CORE_MANPOWER_CONVOYS] call MISSION_CORE_fnc_shipmentCompact;

    // Tank shipments (depot -> target): armor columns shrug off some strikes.
    if (isNil "MISSION_CORE_TANK_SHIPMENTS") then { MISSION_CORE_TANK_SHIPMENTS = []; };
    if (isNil "MISSION_CORE_TANK_INFLIGHT") then { MISSION_CORE_TANK_INFLIGHT = createHashMap; };
    private _tankRem = ["reconTankStrikeMult", 0.6] call MISSION_CORE_fnc_tune;
    private _tankChance = (_chance * _tankRem) max 5;
    private _tkRenown = floor (_renownAmt * (["reconTankRenownMult", 1.2] call MISSION_CORE_fnc_tune));
    private _ti = 0;
    while { _ti < count MISSION_CORE_TANK_SHIPMENTS } do {
        private _convoy = MISSION_CORE_TANK_SHIPMENTS select _ti;
        if (count _convoy < 14) then { _ti = _ti + 1; continue; };
        if ((_convoy select 0) != EAST) then { _ti = _ti + 1; continue; };
        if ((MISSION_CORE_RECON_MARKERS getOrDefault [(_convoy select 12), ""]) == "") then { _ti = _ti + 1; continue; };
        if (time >= ((_convoy select 8) + (_convoy select 7))) then { _ti = _ti + 1; continue; };
        if (random 100 >= _tankChance) then { _ti = _ti + 1; continue; };
        if (count _assets == 0) then { _ti = _ti + 1; continue; };
        private _dealer = [_assets] call MISSION_CORE_fnc_reconStrikeSpend;
        if (_dealer == "") then { _ti = _ti + 1; continue; };
        // A tank hit that lands destroys the column; otherwise nothing happens.
        private _dmg = [_dealer, "tank"] call MISSION_CORE_fnc_reconDealerDamage;
        if ((random 100) < (_dmg select 0)) then {
            private _cid = _convoy select 12;
            private _colCount = _convoy select 4;
            private _label = format ["%1 -> %2", _convoy select 1, _convoy select 2];
            // The depot owns the record, the TANK_INFLIGHT reservation taken when the
            // order was placed, and the renown and anger terms. Recon only tallies
            // the strike - fields are read before the call because an abstract loss
            // tombstones the record.
            if ([_ti, _tkRenown] call MISSION_CORE_fnc_armorShipmentLose) then {
                [_cid] call MISSION_CORE_fnc_reconDropMarker;
                [2, _colCount] call MISSION_CORE_fnc_reconLogKill;
                diag_log format ["RENOWN/RECON: %1 destroyed armor convoy %2 (column of %3 tanks)", _dealer, _label, _colCount];
            };
        } else {
            diag_log format ["RENOWN/RECON: %1 strike on armor convoy %2 failed to destroy", _dealer, _convoy select 1];
        };
        _ti = _ti + 1;
    };
    [MISSION_CORE_TANK_SHIPMENTS] call MISSION_CORE_fnc_shipmentCompact;

    // Ammo convoys: a landing hit kills exactly one truck, or nothing. No partial ammo loss.
    if (isNil "MISSION_CORE_AMMO_CONVOYS") then { MISSION_CORE_AMMO_CONVOYS = []; };
    private _ai = 0;
    while { _ai < count MISSION_CORE_AMMO_CONVOYS } do {
        private _convoy = MISSION_CORE_AMMO_CONVOYS select _ai;
        if (count _convoy < 9) then { _ai = _ai + 1; continue; };
        if ((MISSION_CORE_RECON_MARKERS getOrDefault [(_convoy select 4), ""]) == "") then { _ai = _ai + 1; continue; };
        if (time >= (_convoy select 3)) then { _ai = _ai + 1; continue; };
        if (random 100 >= _chance) then { _ai = _ai + 1; continue; };
        if (count _assets == 0) then { _ai = _ai + 1; continue; };
        private _dealer = [_assets] call MISSION_CORE_fnc_reconStrikeSpend;
        if (_dealer == "") then { _ai = _ai + 1; continue; };
        private _dmg = [_dealer, "ammo"] call MISSION_CORE_fnc_reconDealerDamage;
        if ((random 100) < (_dmg select 0)) then {
            private _label = format ["%1 -> %2", _convoy select 0, _convoy select 1];
            // The ammo system owns the shipment; recon only tallies the strike.
            if ([_ai, 1] call MISSION_CORE_fnc_ammoShipmentLoseTruck) then {
                [_convoy select 4] call MISSION_CORE_fnc_reconDropMarker;
                [0, 1] call MISSION_CORE_fnc_reconLogKill;
                diag_log format ["RENOWN/RECON: %1 killed an ammo truck on convoy %2", _dealer, _label];
            };
        };
        _ai = _ai + 1;
    };
    [MISSION_CORE_AMMO_CONVOYS] call MISSION_CORE_fnc_shipmentCompact;
};

MISSION_CORE_fnc_reconLoop = {
    diag_log "RENOWN/RECON: loop started";
    waitUntil { !isNil "MISSION_CORE_fnc_convoyPosAt" };
    private _nextDetect = time + 10;
    private _nextStrike = time + 20;
    while { true } do {
        sleep 10;
        [] call MISSION_CORE_fnc_reconTickHousekeep;
        [] call MISSION_CORE_fnc_reconTickMoves;
        if (time >= _nextDetect) then {
            [] call MISSION_CORE_fnc_reconTickDetect;
            _nextDetect = time + (["reconDetectEvery", 30] call MISSION_CORE_fnc_tune);
        };
        if (time >= _nextStrike) then {
            [] call MISSION_CORE_fnc_reconTickStrike;
            _nextStrike = time + (["reconStrikeEvery", 60] call MISSION_CORE_fnc_tune);
        };
    };
};
