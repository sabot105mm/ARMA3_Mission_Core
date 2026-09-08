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
    publicVariable "MISSION_CORE_RENOWN";
    publicVariable "MISSION_CORE_RECON_UNITS";
    publicVariable "MISSION_CORE_RECON_UNIT_COSTS";
    publicVariable "MISSION_CORE_RECON_GEAR";
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
                private _gi = MISSION_CORE_RECON_GEAR findIf { (_x select 0) == _forEachValue };
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
MISSION_CORE_fnc_reconTickHousekeep = {
    if (isNil "MISSION_CORE_CONVOYS" || isNil "MISSION_CORE_RECON_MARKERS") then { MISSION_CORE_CONVOYS = []; MISSION_CORE_RECON_MARKERS = createHashMap; };
    private _cids = MISSION_CORE_CONVOYS apply { _x select 10 };
    {
        private _cid = _x;
        if (!(_cid in _cids)) then {
            private _mkr = MISSION_CORE_RECON_MARKERS getOrDefault [_cid, ""];
            if (_mkr != "") then { deleteMarker _mkr; };
            MISSION_CORE_RECON_MARKERS deleteAt _cid;
        } else {
            private _convoy = MISSION_CORE_CONVOYS select (_cids find _cid);
            private _mkr = MISSION_CORE_RECON_MARKERS getOrDefault [_cid, ""];
            if (_mkr != "") then {
                private _pos = if ((_convoy select 7) == 1 && { !isNull (_convoy select 8) } && { alive (_convoy select 8) }) then {
                    getPos (_convoy select 8)
                } else {
                    private _frac = ((time - (_convoy select 5)) / (_convoy select 4)) min 1;
                    [(_convoy select 2), (_convoy select 3), _frac] call MISSION_CORE_fnc_convoyPosAt
                };
                private _etaMin = ceil (((_convoy select 4) - (time - (_convoy select 5))) / 60) max 1;
                _mkr setMarkerPos _pos;
                _mkr setMarkerText format ["SUPPLY CONVOY: %1 -> %2 | ETA ~%3 min", _convoy select 0, _convoy select 1, _etaMin];
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
    private _cap = ["reconDetectCap", 85] call MISSION_CORE_fnc_tune;
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
            _mkr setMarkerType "mil_car";
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
MISSION_CORE_fnc_reconTickStrike = {
    private _totals = [] call MISSION_CORE_fnc_reconTotals;
    private _n = _totals select 0;
    if (_n == 0) exitWith {};
    if (isNil "MISSION_CORE_CONVOYS") exitWith {};
    private _base = ["reconStrikeBase", 15] call MISSION_CORE_fnc_tune;
    private _perUnit = ["reconStrikePerUnit", 10] call MISSION_CORE_fnc_tune;
    private _hitB = _totals select 2;
    private _cap = ["reconStrikeCap", 90] call MISSION_CORE_fnc_tune;
    private _chance = ((_base + _n * _perUnit + _hitB) min _cap) max 0;
    private _destroyW = 15 + (_totals select 3);
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
        if (random 100 >= _chance) then { continue; };
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
                ["DynOps_ConvoyDestroyed",
                    ["CONVOY DESTROYED", format ["Recon strike annihilated %1 -> %2. A supply box landed nearby!", _prov, _recv]]
                ] remoteExec ["BIS_fnc_showNotification", 0];
                diag_log format ["RENOWN/RECON: strike destroyed abstract convoy %1 -> %2 (+%3 renown)", _prov, _recv, _renownAmt];
            } else {
                // Materialized: kill the real truck - the convoy loop drops the box + awards renown.
                if (!(isNull _truck) && { alive _truck }) then { _truck setDamage 1; };
                ["DynOps_ReconStrike",
                    ["RECON STRIKE", format ["Fire support smashed the %1 -> %2 convoy!", _prov, _recv]]
                ] remoteExec ["BIS_fnc_showNotification", 0];
            };
        } else {
            if (_roll < _destroyW + 45) then {
                // Damaged: halt the convoy's supply and slow its remaining leg.
                _convoy set [6, floor (_amount * 0.5)];
                if (_state == 0) then { _convoy set [4, _travelTime * 1.3]; };
                ["DynOps_ReconStrike",
                    ["RECON STRIKE DAMAGED", format ["%1 -> %2 hit - supply halved and slowed", _prov, _recv]]
                ] remoteExec ["BIS_fnc_showNotification", 0];
                diag_log format ["RENOWN/RECON: strike damaged convoy %1 -> %2 (half supply)", _prov, _recv];
            };
        };
    };
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