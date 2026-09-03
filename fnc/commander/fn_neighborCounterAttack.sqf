
MISSION_CORE_fnc_neighborCounterAttack = {
    params ["_locName", "_locPos", "_side", "_importance"];
    // PERMANENT RULE: one contested zone PER PLAYER. Only a marker that is one of the side's
    // contested zones (a player is actually engaging it) receives neighbor reinforcements -
    // a secondary marker a player merely brushed past never gets fed. Each zone is handled
    // independently with its own neighbor pool below.
    private _zoneList = [_side] call MISSION_CORE_fnc_getContestedMarkers;
    if (_zoneList findIf { (_x select 0) == _locName } == -1) exitWith {};
    if (isNil "MISSION_CORE_REINF_COOLDOWN") then { MISSION_CORE_REINF_COOLDOWN = createHashMap; };
    private _last = MISSION_CORE_REINF_COOLDOWN getOrDefault [_locName, -99999];
    if (time - _last < 300) exitWith {};
    MISSION_CORE_REINF_COOLDOWN set [_locName, time];
    // PERMANENT RULE: the contested marker's OWN garrison must be fully spawned before any
    // neighbor dispatches reinforcements. The proximity spawner spawns it on its own async
    // cycle, so a battle can start before the garrison exists. Force it now so the contested
    // marker's units are on the map first, then neighbors reinforce on top of it.
    if (isNil "MISSION_CORE_SPAWNED_LOCATIONS") then { MISSION_CORE_SPAWNED_LOCATIONS = createHashMap; };
    if !(MISSION_CORE_SPAWNED_LOCATIONS getOrDefault [_locName, false]) then {
        private _locEntry = (MISSION_CORE_CACHED_POSITIONS select { (_x select 0) == _locName }) param [0, []];
        if (count _locEntry > 0) then {
            MISSION_CORE_SPAWNED_LOCATIONS set [_locName, true];
            [_locEntry] call MISSION_CORE_fnc_spawnLocation;
            diag_log format ["DYNAMIC REINF: %1 forced garrison spawn before neighbors", _locName];
        };
    };
    // The contested marker itself claims the first of the 4 spawn slots (contested + 3 neighbors)
    [_locName] call MISSION_CORE_fnc_spawnerSlotFree;
    // PERMANENT RULE: a marker that is already FULL (garrison at/above its baseline) never receives
    // neighbor reinforcements or manpower credit - there is nothing to top up. Only a marker that
    // has actually lost men gets reinforced.
    if (isNil "MISSION_CORE_GARRISON_BASELINE") then { MISSION_CORE_GARRISON_BASELINE = createHashMap; };
    private _baseline = MISSION_CORE_GARRISON_BASELINE getOrDefault [_locName, [_importance] call MISSION_CORE_fnc_markerCapacity];
    private _aliveNow = [_locName, _side] call MISSION_CORE_fnc_countMarkerGarrison;
    if (_aliveNow >= _baseline) exitWith {
        diag_log format ["DYNAMIC REINF: %1 full (%2/%3) - no neighbors needed", _locName, _aliveNow, _baseline];
    };
    private _factionData = if (_side == WEST) then { MISSION_CORE_BLUFOR_DATA } else { MISSION_CORE_REDFOR_DATA };
    // PERMANENT RULE: a contested marker NEVER counter-attacks another contested marker. A zone's
    // own garrison must stay and defend its own fight - so contested markers are excluded from the
    // neighbor pool entirely (no troops dispatched, no manpower credit).
    private _zoneNames = _zoneList apply { _x select 0 };
    private _neighbors = MISSION_CORE_CACHED_POSITIONS select {
        (_x select 4) == _side &&
        { (_x select 0) != _locName } &&
        { !((_x select 0) in _zoneNames) } &&
        { ((_x select 1) distance _locPos) < (["neighborRange", 4000] call MISSION_CORE_fnc_tune) }
    };
    _neighbors = [_neighbors, [], { (_x select 1) distance _locPos }, "ASCEND"] call BIS_fnc_sortBy;
    if (count _neighbors == 0) exitWith {};
    // Overwatch rule: a contested overwatch (high-ground) marker may only be reinforced /
    // counter-attacked by OTHER overwatch markers - no other marker can help it.
    if ([_locName] call MISSION_CORE_fnc_isOverwatchMarker) then {
        _neighbors = _neighbors select { [(_x select 0)] call MISSION_CORE_fnc_isOverwatchMarker };
    };
    private _contestedIdx = MISSION_CORE_CACHED_POSITIONS findIf { (_x select 0) == _locName };
    private _targetSize = if (_contestedIdx >= 0) then { (MISSION_CORE_CACHED_POSITIONS select _contestedIdx) select 8 } else { [_importance, _importance] };
    private _totalSent = 0;
    // Pooled reinforcement budget: total manpower the whole zone will expend on this marker,
    // driven by the marker's determination (neighbor budget fraction).
    private _tier = 2;
    private _budgetFrac = 0.4;
    if (_contestedIdx >= 0) then {
        private _det = [(MISSION_CORE_CACHED_POSITIONS select _contestedIdx)] call MISSION_CORE_fnc_getMarkerDetermination;
        _tier = _det select 0;
        _budgetFrac = _det select 2;
    };
    // Tanks counter-attack, scaled by the contested marker's tier: more important = more tanks.
    private _maxTanks = ([3, 2, 1, 0] select _tier);
    // PERMANENT RULE: neighbors may counter-attack a contested marker with tanks (assault order,
    // so it bypasses the factory/contested gating), BUT the TOTAL tanks the whole side commits to
    // any single zone is capped by its importance and tier. Once a zone's cumulative counter-attack
    // tank budget is spent, no further tank orders are placed for it.
    private _tankBudget = round (([5, 4, 3, 2] select _tier) * (1 + (_importance - 1) * 0.25));
    private _pool = 0;
    {
        _pool = _pool + ([(_x select 7)] call MISSION_CORE_fnc_markerCapacity);
    } forEach _neighbors;
    _pool = round (_pool * _budgetFrac);
    if (isNil "MISSION_CORE_REINF_SENT") then { MISSION_CORE_REINF_SENT = createHashMap; };
    private _sentTotal = MISSION_CORE_REINF_SENT getOrDefault [_locName, 0];
    if (_sentTotal >= _pool) exitWith {
        if (isNil "MISSION_CORE_REINF_EXHAUSTED") then { MISSION_CORE_REINF_EXHAUSTED = createHashMap; };
        MISSION_CORE_REINF_EXHAUSTED set [_locName, true];
        diag_log format ["DYNAMIC REINF BUDGET: %1 pool exhausted (%2/%3)", _locName, _sentTotal, _pool];
        // PERMANENT RULE: the zone gave up - the whole neighborhood goes dormant with it.
        [_locName, _locPos, _side] call MISSION_CORE_fnc_deactivateNeighborMarkers;
    };
    diag_log format ["DYNAMIC REINF BUDGET: %1 pool=%2 budgetFrac=%3 sent=%4", _locName, _pool, _budgetFrac, _sentTotal];
    // PERMANENT RULE: counter-attack tanks come from the factory/depot system only - one
    // order for the tier-scaled budget, routed to the nearest warehouse with stock and
    // shipped as a convoy (deduplicated per side+target so it never stacks). Assault order
    // so it filters through to the contested marker; cumulative spend gated by budget.
    if (isNil "MISSION_CORE_REINF_TANK_BUDGET") then { MISSION_CORE_REINF_TANK_BUDGET = createHashMap; };
    private _spent = MISSION_CORE_REINF_TANK_BUDGET getOrDefault [_locName, 0];
    private _thisEvent = (_maxTanks min (_tankBudget - _spent)) max 0;
    if (_thisEvent > 0) then {
        MISSION_CORE_REINF_TANK_BUDGET set [_locName, _spent + _thisEvent];
        [_side, _locName, _locPos, _thisEvent, true] call MISSION_CORE_fnc_orderTank;
        diag_log format ["DYNAMIC REINF: counter-attack tank order placed for %1 (n=%2, budget %3/%4)", _locName, _thisEvent, _spent + _thisEvent, _tankBudget];
    };
    private _manpower = 0;
    if (isNil "MISSION_CORE_COMMIT") then { MISSION_CORE_COMMIT = createHashMap; };
    if (isNil "MISSION_CORE_MANPOWER") then { MISSION_CORE_MANPOWER = createHashMap; };
    private _avgSpeed = 8.0;
    private _spawnedProviders = 0;
    {
        private _prov = _x;
        private _provName = _prov select 0;
        private _provImp = _prov select 7;
        private _provPos = _prov select 1;
        private _provSize = if (count _prov > 8) then { _prov select 8 } else { [200, 200] };
        private _dist = _provPos distance _locPos;
        // Pooled budget: stop every provider once the zone's total reinforcement pool is spent.
        if (_sentTotal >= _pool) exitWith {};
        // The contested marker itself claims the first spawn slot. Up to 3 closest neighbors may
        // then send real troops (PERMANENT RULE - never reduce below 3). Any neighbor beyond the
        // 4-marker limit only grants manpower credit.
        private _canSpawn = (_spawnedProviders < 3) && { [_provName] call MISSION_CORE_fnc_spawnerSlotFree };
        if (_canSpawn) then {
            private _groups = _factionData select 17;
            // Stronger levels contribute more: 1 group per level, capped at 5
            private _infGroups = (_provImp max 1) min 5;
            // Diminishing retake: when the players capture a marker, fewer and fewer neighbor
            // counter-attack squads spawn to take it back. Scales down across the marker's 20-min
            // retake window; when it reaches zero, no more spawn and spawned units disengage to
            // patrol the next closest REDFOR marker instead of feeding a dead zone.
            if (!isNil "MISSION_CORE_CAPTURED_RETAKE" && { _locName in MISSION_CORE_CAPTURED_RETAKE }) then {
                private _rv = MISSION_CORE_CAPTURED_RETAKE get _locName;
                if (count _rv > 1 && { (_rv select 0) == _side }) then {
                    private _age = time - (_rv select 1);
                    private _frac = (1 - (_age / 1200)) max 0;
                    _infGroups = round (_infGroups * _frac);
                };
            };
            if (_infGroups <= 0) exitWith {
                if (_side == EAST) then { [_locName] call MISSION_CORE_fnc_disengageToNextMarker; };
                // PERMANENT RULE: the retake window has run out - the zone gave up and the
                // whole neighborhood goes dormant with it.
                [_locName, _locPos, _side] call MISSION_CORE_fnc_deactivateNeighborMarkers;
            };
            private _infPool = [_groups] call MISSION_CORE_fnc_getInfTemplates;
            private _sentMen = 0;
            for "_i" from 1 to _infGroups do {
                if (count _infPool == 0) exitWith {};
                private _template = selectRandom _infPool;
                // Reinforcements assemble INSIDE the provider's marker (the lax scan tolerates a
                // couple of minor obstacles so a spot in a dense town centre still resolves).
                private _strikeDir = _provPos getDir _locPos;
                private _spawnPos = [_provPos, _provSize, 30, _strikeDir, true] call MISSION_CORE_fnc_findVehiclePos;
                // Foot infantry cap: max 3 towns per side may field infantry, and total enemy
                // foot squads alive is hard-capped at 10 (PERMANENT RULE). Queue the squad when
                // either cap is full and release it when a slot frees.
                if (!([_side, "inf", _provPos] call MISSION_CORE_fnc_townCategoryCanUse) || { ([_side] call MISSION_CORE_fnc_countFootSquads) >= (["footSquadCapSquads", 10] call MISSION_CORE_fnc_tune) }) then {
                    ["MISSION_CORE_fnc_queuedCounterAttackInf", format ["cainf_%1_%2_%3", _provName, _locName, _i], [_side, _template, _spawnPos, _factionData select 3, _provImp, _provPos, _provSize, _provName, _locPos, _targetSize]] call MISSION_CORE_fnc_enqueueSpawn;
                    _sentMen = _sentMen + (_template select 2);
                } else {
                    private _grp = [_template select 0, _spawnPos, _side, _factionData select 3, "AWARE", "NORMAL", _provImp, _provPos, _provSize] call MISSION_CORE_fnc_spawnGroup;
                    if (isNull _grp) then { continue; };
                    _grp setVariable ["MISSION_CORE_ORIGIN_MARKER", _provName];
                    _grp setVariable ["MISSION_CORE_IMPORTANCE", _provImp];
                    if (isNil "MISSION_CORE_SPAWNED_GROUPS") then { MISSION_CORE_SPAWNED_GROUPS = []; };
                    MISSION_CORE_SPAWNED_GROUPS pushBack _grp;
                    [_grp, _locPos, _targetSize] call MISSION_CORE_fnc_sendCounterAttack;
                    _sentMen = _sentMen + (_template select 2);
                };
                // 0.4s gap between counter-attack squads so they don't all pop at once
                sleep 0.4;
            };
            // 0.4s gap between provider reinforcements so groups don't cluster
            sleep 0.4;
            // Giver only commits 0.1x of the men it shuttled to a friendly neighbor
            MISSION_CORE_COMMIT set [_provName, (MISSION_CORE_COMMIT getOrDefault [_provName, 0]) + ceil (_sentMen * 0.1)];
            _sentTotal = _sentTotal + _sentMen;
            MISSION_CORE_REINF_SENT set [_locName, _sentTotal];
            _totalSent = _totalSent + _sentMen;
            _spawnedProviders = _spawnedProviders + 1;
        } else {
            // Far neighbor: no marching units, just manpower credit that matures on travel time.
            // PERMANENT RULE: a marker NEVER accumulates more manpower than its initial capacity -
            // credits are capped so the pending total can never exceed what the marker started with.
            private _cap = [_importance] call MISSION_CORE_fnc_markerCapacity;
            private _pendingMen = 0;
            { _pendingMen = _pendingMen + (_x select 0); } forEach (MISSION_CORE_MANPOWER getOrDefault [_locName, []]);
            private _room = (_cap - _pendingMen) max 0;
            private _men = (_provImp * 10) min _room;
            if (_men > 0) then {
                private _credit = [_men, time + (_dist / _avgSpeed)];
                private _pending = MISSION_CORE_MANPOWER getOrDefault [_locName, []];
                _pending pushBack _credit;
                MISSION_CORE_MANPOWER set [_locName, _pending];
                _manpower = _manpower + _men;
            };
        };
    } forEach _neighbors;
    if (_totalSent > 0 || _manpower > 0) then {
        diag_log format ["DYNAMIC REINF: %1 (%2) reinforced by %3 neighbors (men=%4, manpower=%5, spawners=%6)", _locName, _side, count _neighbors, _totalSent, _manpower, _spawnedProviders];
    };
    // 5s gap after the contested marker's whole reinforcement set before any other spawn burst
    if (_totalSent > 0) then { sleep 5; };
};
