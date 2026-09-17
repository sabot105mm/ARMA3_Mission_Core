// =====================================================================
// RENOWN + FORCE RECON
// Team-wide renown currency earned from captures (importance-based) and
// destroyed supply convoys. It is spent at the HQ flag to unlock Marine
// Force Recon units - ABSTRACT units, never spawned and never seeing the
// battlefield. Each unlocked recon unit rolls a detection die against
// every abstract supply convoy each cycle; more units (and better gear)
// raise that chance. A detected convoy is DESIGNATED for fire support:
// the whole team gets a map marker + ETA, and an imaginary SPG only
// exists as a strike-chance/damage dice multiplier. "See further" gear
// (optics/designator) boosts detection; Paveway/SPG/MLRS boost the
// strike dice only. Intel is shared team-wide and convoys struck on a
// real (materialized) truck die through the normal convoy loop.
// =====================================================================

// Idempotent server broadcast of the full recon state. Safe to call any time (init, client
// pull requests, re-init) - publicVariable re-sends to all current clients harmlessly.
MISSION_CORE_fnc_reconPushState = {
    if (!isServer) exitWith {};
    if (isNil "MISSION_CORE_RENOWN") then { MISSION_CORE_RENOWN = 0; };
    if (isNil "MISSION_CORE_RECON_UNITS") then { MISSION_CORE_RECON_UNITS = []; };
    if (isNil "MISSION_CORE_RECON_UNIT_COSTS") then { MISSION_CORE_RECON_UNIT_COSTS = []; };
    if (isNil "MISSION_CORE_RECON_GEAR") then { MISSION_CORE_RECON_GEAR = []; };
    if (isNil "MISSION_CORE_RECON_KILLS" || { typeName MISSION_CORE_RECON_KILLS != "ARRAY" }) then {
        if (!(isNil "MISSION_CORE_RECON_KILLS")) then { diag_log format ["RENOWN/RECON: RECON_KILLS invalid type %1 (%2) at push - reset", MISSION_CORE_RECON_KILLS, typeName MISSION_CORE_RECON_KILLS]; };
        MISSION_CORE_RECON_KILLS = [0, 0, 0];
    };
    publicVariable "MISSION_CORE_RENOWN";
    publicVariable "MISSION_CORE_RECON_UNITS";
    publicVariable "MISSION_CORE_RECON_UNIT_COSTS";
    publicVariable "MISSION_CORE_RECON_GEAR";
    publicVariable "MISSION_CORE_RECON_KILLS";
    diag_log format ["RENOWN/RECON: state pushed (renown=%1, units=%2, gear=%3)", MISSION_CORE_RENOWN, count MISSION_CORE_RECON_UNITS, count MISSION_CORE_RECON_GEAR];
};

MISSION_CORE_fnc_initRecon = {
    if (isNil "MISSION_CORE_RENOWN") then { MISSION_CORE_RENOWN = 0; };
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

// Consume one ready fire-support asset from the pool (passed by reference). Returns true if an
// asset was spent and put on cooldown, false if the pool is dry (nothing left to fire).
MISSION_CORE_fnc_reconStrikeSpend = {
    params ["_assets"];
    if (count _assets == 0) exitWith { false };
    private _use = _assets select 0;
    _assets deleteAt 0;
    private _key = format ["%1_%2", _use select 0, _use select 1];
    MISSION_CORE_RECON_COOLDOWNS set [_key, time + ([_use select 0] call MISSION_CORE_fnc_reconStrikeCooldown)];
    diag_log format ["RENOWN/RECON: %1 fire support spent (%2 min cooldown)", _use select 0, round (((MISSION_CORE_RECON_COOLDOWNS get _key) - time) / 60)];
    true
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
    private _live = _cids + _mpCids + _tkCids;
    {
        private _cid = _x;
        if (!(_cid in _live)) then {
            private _mkr = MISSION_CORE_RECON_MARKERS getOrDefault [_cid, ""];
            if (_mkr != "") then { deleteMarker _mkr; };
            MISSION_CORE_RECON_MARKERS deleteAt _cid;
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
                                private _eta = (_pPos distance2D _bPos) / (["manpowerConvoySpeed", 14] call MISSION_CORE_fnc_tune);
                                private _depart = _arrive - _eta;
                                private _frac = ((time - _depart) / _eta) min 1;
                                if (_frac < 0) then { _frac = 0; };
                                private _pos = [
                                    (_pPos select 0) + ((_bPos select 0) - (_pPos select 0)) * _frac,
                                    (_pPos select 1) + ((_bPos select 1) - (_pPos select 1)) * _frac,
                                    0
                                ];
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
                        };
                    };
                };
            };
        };
    } forEach (keys MISSION_CORE_RECON_MARKERS);
};

// Detection cycle: dice-roll every abstract convoy. More recon units + optics/designator = more chances.
MISSION_CORE_fnc_reconTickDetect = {
    private _totals = [] call MISSION_CORE_fnc_reconTotals;
    private _n = _totals select 0;
    if (_n == 0) exitWith {};
    if (isNil "MISSION_CORE_CONVOYS") exitWith {};
    private _base = ["reconDetectBase", 20] call MISSION_CORE_fnc_tune;
    private _perUnit = ["reconDetectPerUnit", 12] call MISSION_CORE_fnc_tune;
    private _detB = _totals select 1;
    private _cap = ["reconDetectCap", 70] call MISSION_CORE_fnc_tune;
    private _chance = ((_base + _n * _perUnit + _detB) min _cap) max 0;
    private _knownCap = ["reconRouteKnownReveals", 2] call MISSION_CORE_fnc_tune;
    {
        _x params ["_prov", "_recv", "_roadPath"];
        if (count _x < 13) then { continue; };
        if (_x select 12 != "") then { continue; };
        if (_x select 7 != 0) then { continue; };
        if (((time - (_x select 5)) / (_x select 4)) >= 1) then { continue; };
        private _pairKey = _prov + ">" + _recv;
        private _known = MISSION_CORE_ROUTE_KNOWLEDGE getOrDefault [_pairKey, 0];
        if (_known >= _knownCap || { random 100 < _chance }) then {
            if (_known < _knownCap) then {
                MISSION_CORE_ROUTE_KNOWLEDGE set [_pairKey, _known + 1];
                private _known2 = MISSION_CORE_ROUTE_KNOWLEDGE getOrDefault [_pairKey, 0];
                if (_known2 >= _knownCap) then { [(_x select 2)] call MISSION_CORE_fnc_reconDrawRoute; };
            };
            private _cid = _x select 10;
            private _frac = ((time - (_x select 5)) / (_x select 4)) min 1;
            private _curPos = [_roadPath, (_x select 3), _frac] call MISSION_CORE_fnc_convoyPosAt;
            private _mkr = format ["DynOps_Recon%1", MISSION_CORE_RECON_INTEL_IDX];
            MISSION_CORE_RECON_INTEL_IDX = MISSION_CORE_RECON_INTEL_IDX + 1;
            createMarker [_mkr, _curPos];
            _mkr setMarkerShape "ICON";
            _mkr setMarkerType "o_motorized";
            _mkr setMarkerColor "ColorOrange";
            _mkr setMarkerSize [0.9, 0.9];
            private _etaMin = ceil (((_x select 4) - (time - (_x select 5))) / 60) max 1;
            _mkr setMarkerText format ["SUPPLY CONVOY: %1 -> %2 | ETA ~%3 min", _prov, _recv, _etaMin];
            _x set [12, _mkr];
            MISSION_CORE_RECON_MARKERS set [_cid, _mkr];
            if (_known >= _knownCap) then {
                ["DynOps_ReconIntel",
                    ["ROUTINE SUPPLY ROUTE", format ["%1 -> %2, ETA ~%3 min", _prov, _recv, _etaMin]]
                ] remoteExec ["BIS_fnc_showNotification", 0];
            } else {
                ["DynOps_ReconIntel",
                    ["SUPPLY ROUTE REVEALED", format ["%1 -> %2, ETA ~%3 min", _prov, _recv, _etaMin]]
                ] remoteExec ["BIS_fnc_showNotification", 0];
            };
            diag_log format ["RENOWN/RECON: convoy %1 -> %2 revealed by recon (chance %3)", _prov, _recv, round _chance];
        };
    } forEach MISSION_CORE_CONVOYS;
    if (isNil "MISSION_CORE_MANPOWER_CONVOYS") then { MISSION_CORE_MANPOWER_CONVOYS = []; };
    if (isNil "MISSION_CORE_PORTS") then { MISSION_CORE_PORTS = createHashMap; };
    {
        if (count _x < 6) then { continue; };
        if (_x select 5 != "") then { continue; };
        if (time >= (_x select 3)) then { continue; };
        private _pInfo = MISSION_CORE_PORTS getOrDefault [(_x select 0), []];
        if (count _pInfo == 0) then { continue; };
        if ((_pInfo select 2) != EAST) then { continue; };
        private _pPos = _pInfo select 0;
        private _bName = _x select 1;
        private _bIdx = MISSION_CORE_CACHED_POSITIONS findIf { (_x select 0) == _bName };
        if (_bIdx < 0) then { continue; };
        private _bPos = MISSION_CORE_CACHED_POSITIONS select _bIdx;
        private _bPos2 = _bPos select 1;
        private _eta = (_pPos distance2D _bPos2) / (["manpowerConvoySpeed", 14] call MISSION_CORE_fnc_tune);
        private _depart = (_x select 3) - _eta;
        private _frac = ((time - _depart) / _eta) min 1;
        private _curPos = [
            (_pPos select 0) + ((_bPos2 select 0) - (_pPos select 0)) * _frac,
            (_pPos select 1) + ((_bPos2 select 1) - (_pPos select 1)) * _frac,
            0
        ];
        if (random 100 < _chance) then {
            private _cid = _x select 4;
            private _mkr = format ["DynOps_Recon%1", MISSION_CORE_RECON_INTEL_IDX];
            MISSION_CORE_RECON_INTEL_IDX = MISSION_CORE_RECON_INTEL_IDX + 1;
            createMarker [_mkr, _curPos];
            _mkr setMarkerShape "ICON";
            _mkr setMarkerType "o_inf";
            _mkr setMarkerColor "ColorYellow";
            _mkr setMarkerSize [0.9, 0.9];
            private _etaMin = ceil (((_x select 3) - time) / 60) max 1;
            _mkr setMarkerText format ["MANPOWER CONVOY: %1 -> %2 | ETA ~%3 min", _x select 0, _x select 1, _etaMin];
            _x set [5, _mkr];
            MISSION_CORE_RECON_MARKERS set [_cid, _mkr];
            ["DynOps_ReconIntel",
                ["MANPOWER ROUTE REVEALED", format ["%1 -> %2, ETA ~%3 min", _x select 0, _x select 1, _etaMin]]
            ] remoteExec ["BIS_fnc_showNotification", 0];
            diag_log format ["RENOWN/RECON: manpower convoy %1 -> %2 revealed by recon (chance %3)", _x select 0, _x select 1, round _chance];
        };
    } forEach MISSION_CORE_MANPOWER_CONVOYS;
    if (isNil "MISSION_CORE_TANK_SHIPMENTS") then { MISSION_CORE_TANK_SHIPMENTS = []; };
    {
        if (count _x < 14) then { continue; };
        if ((_x select 0) != EAST) then { continue; };
        if (_x select 13 != "") then { continue; };
        if (_x select 9 != 0) then { continue; };
        if (time >= ((_x select 8) + (_x select 7))) then { continue; };
        private _frac = ((time - (_x select 8)) / (_x select 7)) min 1;
        private _curPos = [(_x select 5), (_x select 6), _frac] call MISSION_CORE_fnc_convoyPosAt;
        if (random 100 < _chance) then {
            private _cid = _x select 12;
            private _mkr = format ["DynOps_Recon%1", MISSION_CORE_RECON_INTEL_IDX];
            MISSION_CORE_RECON_INTEL_IDX = MISSION_CORE_RECON_INTEL_IDX + 1;
            createMarker [_mkr, _curPos];
            _mkr setMarkerShape "ICON";
            _mkr setMarkerType "o_armor";
            _mkr setMarkerColor "ColorRed";
            _mkr setMarkerSize [0.9, 0.9];
            private _etaMin = ceil ((((_x select 8) + (_x select 7)) - time) / 60) max 1;
            _mkr setMarkerText format ["ARMOR CONVOY: %1 -> %2 | ETA ~%3 min", _x select 1, _x select 2, _etaMin];
            _x set [13, _mkr];
            MISSION_CORE_RECON_MARKERS set [_cid, _mkr];
            ["DynOps_ReconIntel",
                ["ARMOR ROUTE REVEALED", format ["%1 -> %2, ETA ~%3 min", _x select 1, _x select 2, _etaMin]]
            ] remoteExec ["BIS_fnc_showNotification", 0];
            diag_log format ["RENOWN/RECON: armor convoy %1 -> %2 revealed by recon (chance %3)", _x select 1, _x select 2, round _chance];
        };
    } forEach MISSION_CORE_TANK_SHIPMENTS;
};

// Draw a persistent blue polyline for a "routine" supply route (its actual road path).
MISSION_CORE_fnc_reconDrawRoute = {
    params ["_roadPath"];
    if (count _roadPath < 2) exitWith {};
    if (isNil "MISSION_CORE_RECON_ROUTES") then { MISSION_CORE_RECON_ROUTES = createHashMap; };
    private _cap = ["reconRouteCap", 8] call MISSION_CORE_fnc_tune;
    if (count MISSION_CORE_RECON_ROUTES >= _cap) exitWith {};
    private _mkr = format ["DynOps_Route%1", MISSION_CORE_RECON_ROUTE_IDX];
    MISSION_CORE_RECON_ROUTE_IDX = MISSION_CORE_RECON_ROUTE_IDX + 1;
    createMarker [_mkr, _roadPath select 0];
    _mkr setMarkerShape "POLYLINE";
    _mkr setMarkerPolyline _roadPath;
    _mkr setMarkerColor "ColorBlue";
    _mkr setMarkerSize [2, 2];
    MISSION_CORE_RECON_ROUTES set [(str _roadPath), _mkr];
    diag_log format ["RENOWN/RECON: routine supply route drawn (%1 waypoints)", count _roadPath];
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
        if (_convoy select 12 == "") then { continue; };
        if (_convoy select 11) then { continue; };
        if (((time - _departTime) / _travelTime) >= 1) then { continue; };
        if (count _assets == 0) then { continue; };
        if (random 100 >= _chance) then { continue; };
        [_assets] call MISSION_CORE_fnc_reconStrikeSpend;
        private _roll = random 100;
        if (_roll < _destroyW) then {
            // Destroyed
            if (_state == 0) then {
                // Abstract kill: drop the ammo box here for players, flag the convoy dead.
                private _frac = ((time - _departTime) / _travelTime) min 1;
                private _curPos = [_roadPath, _cum, _frac] call MISSION_CORE_fnc_convoyPosAt;
                private _box = createVehicle ["Box_East_Ammo_F", _curPos, [], 0, "CAN_COLLIDE"];
                _convoy set [11, true];
                private _cid = _convoy select 10;
                private _mkr = MISSION_CORE_RECON_MARKERS getOrDefault [_cid, ""];
                if (_mkr != "") then { deleteMarker _mkr; MISSION_CORE_RECON_MARKERS deleteAt _cid; };
                [_renownAmt] call MISSION_CORE_fnc_awardRenown;
                [0, _amount] call MISSION_CORE_fnc_reconLogKill;
                ["DynOps_ConvoyDestroyed",
                    ["CONVOY DESTROYED", format ["Recon strike annihilated %1 -> %2. A supply box landed nearby!", _prov, _recv]]
                ] remoteExec ["BIS_fnc_showNotification", 0];
                diag_log format ["RENOWN/RECON: strike destroyed abstract convoy %1 -> %2 (+%3 renown)", _prov, _recv, _renownAmt];
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
                // Damaged: cut the convoy's cargo in half and tally the lost amount.
                private _surviving = floor (_amount * 0.5);
                _convoy set [6, _surviving];
                [0, _amount - _surviving] call MISSION_CORE_fnc_reconLogKill;
                if (_state == 0) then { _convoy set [4, _travelTime * 1.3]; };
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
        if (_convoy select 5 == "") then { _mi = _mi + 1; continue; };
        if (time >= (_convoy select 3)) then { _mi = _mi + 1; continue; };
        if (random 100 >= _chance) then { _mi = _mi + 1; continue; };
        if (count _assets == 0) then { _mi = _mi + 1; continue; };
        [_assets] call MISSION_CORE_fnc_reconStrikeSpend;
        private _roll2 = random 100;
        if (_roll2 < _destroyW) then {
            private _cid = _convoy select 4;
            private _mkr = MISSION_CORE_RECON_MARKERS getOrDefault [_cid, ""];
            if (_mkr != "") then { deleteMarker _mkr; MISSION_CORE_RECON_MARKERS deleteAt _cid; };
            private _batch = _convoy select 2;
            private _killed = floor (_batch * (0.5 + random 0.5));
            if (_killed >= _batch) then {
                [_mpRenown] call MISSION_CORE_fnc_awardRenown;
                [1, round _batch] call MISSION_CORE_fnc_reconLogKill;
                MISSION_CORE_MANPOWER_CONVOYS deleteAt _mi;
            } else {
                _convoy set [2, _batch - _killed];
                [1, round _killed] call MISSION_CORE_fnc_reconLogKill;
                [floor (_mpRenown * (_killed / _batch))] call MISSION_CORE_fnc_awardRenown;
                _mi = _mi + 1;
            };
            diag_log format ["RENOWN/RECON: strike destroyed manpower convoy %1 -> %2 (%3 of %4 men remaining)", _convoy select 0, _convoy select 1, if (_killed >= _batch) then { 0 } else { round (_batch - _killed) }, round _batch];
        } else {
            if (_roll2 < _destroyW + 45) then {
                private _oldB = _convoy select 2;
                private _newB = floor (_oldB * 0.5);
                _convoy set [2, _newB];
                [1, _oldB - _newB] call MISSION_CORE_fnc_reconLogKill;
                ["DynOps_ReconStrike",
                    ["RECON STRIKE DAMAGED", format ["%1 -> %2 manpower hit - batch halved", _convoy select 0, _convoy select 1]]
                ] remoteExec ["BIS_fnc_showNotification", 0];
                diag_log format ["RENOWN/RECON: strike damaged manpower convoy %1 -> %2 (half batch)", _convoy select 0, _convoy select 1];
            };
            _mi = _mi + 1;
        };
    };
    MISSION_CORE_MANPOWER_CONVOYS = MISSION_CORE_MANPOWER_CONVOYS select { count _x > 0 };

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
        if (_convoy select 13 == "") then { _ti = _ti + 1; continue; };
        if (time >= ((_convoy select 8) + (_convoy select 7))) then { _ti = _ti + 1; continue; };
        if (random 100 >= _tankChance) then { _ti = _ti + 1; continue; };
        if (count _assets == 0) then { _ti = _ti + 1; continue; };
        [_assets] call MISSION_CORE_fnc_reconStrikeSpend;
        private _roll3 = random 100;
        if (_roll3 < _destroyW) then {
            private _cid = _convoy select 12;
            private _mkr = MISSION_CORE_RECON_MARKERS getOrDefault [_cid, ""];
            if (_mkr != "") then { deleteMarker _mkr; MISSION_CORE_RECON_MARKERS deleteAt _cid; };
            private _colCount = _convoy select 4;
            if ((_convoy select 9) == 0) then {
                MISSION_CORE_TANK_INFLIGHT set [(_convoy select 0), ((MISSION_CORE_TANK_INFLIGHT getOrDefault [(_convoy select 0), 0]) - _colCount) max 0];
                MISSION_CORE_TANK_SHIPMENTS deleteAt _ti;
            } else {
                { if (!isNull _x && { alive _x }) then { _x setDamage 1; }; } forEach (_convoy select 10);
                _ti = _ti + 1;
            };
            [2, _colCount] call MISSION_CORE_fnc_reconLogKill;
            [_tkRenown] call MISSION_CORE_fnc_awardRenown;
            diag_log format ["RENOWN/RECON: strike destroyed armor convoy %1 -> %2 (column of %3 tanks)", _convoy select 1, _convoy select 2, _colCount];
        } else {
            if (_roll3 < _destroyW + 45) then {
                _convoy set [7, (_convoy select 7) * 1.3];
                ["DynOps_ReconStrike",
                    ["RECON STRIKE DAMAGED", format ["%1 -> %2 armor hit - slowed", _convoy select 1, _convoy select 2]]
                ] remoteExec ["BIS_fnc_showNotification", 0];
                diag_log format ["RENOWN/RECON: strike damaged armor convoy %1 -> %2 (slowed)", _convoy select 1, _convoy select 2];
            };
            _ti = _ti + 1;
        };
    };
    MISSION_CORE_TANK_SHIPMENTS = MISSION_CORE_TANK_SHIPMENTS select { count _x > 0 };
};

MISSION_CORE_fnc_reconLoop = {
    diag_log "RENOWN/RECON: loop started";
    waitUntil { !isNil "MISSION_CORE_fnc_convoyPosAt" };
    private _nextDetect = time + 10;
    private _nextStrike = time + 20;
    while { true } do {
        sleep 10;
        [] call MISSION_CORE_fnc_reconTickHousekeep;
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