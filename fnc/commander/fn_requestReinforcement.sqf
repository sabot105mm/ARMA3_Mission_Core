
MISSION_CORE_fnc_requestReinforcement = {
    params ["_locName"];
    private _idx = MISSION_CORE_CACHED_POSITIONS findIf { (_x select 0) == _locName };
    if (_idx < 0) exitWith {};
    private _loc = MISSION_CORE_CACHED_POSITIONS select _idx;
    private _locPos = _loc select 1;
    private _importance = _loc select 7;
    private _factionData = MISSION_CORE_REDFOR_DATA;
    private _allGroups = _factionData select 17;

    // Current supply
    private _curSupply = MISSION_CORE_LOCATION_SUPPLY getOrDefault [_locName, 0];
    if (_curSupply > _importance * 5) exitWith {};

    // PERMANENT RULE: the AI fights exactly ONE contested zone at a time. While a zone is locked
    // (a captured marker being retaken, or a player-engaged marker), REDFOR markers within ~4km of
    // it do NOT get re-supplied from neighbors - all manpower goes to the zone itself. Only when
    // the player moves out and closes on the next marker does the zone (and its supply) follow.
    private _zoneFocus = [EAST] call MISSION_CORE_fnc_getAIZoneFocus;
    if (_zoneFocus != "" && { _locName != _zoneFocus }) then {
        private _zIdx = MISSION_CORE_CACHED_POSITIONS findIf { (_x select 0) == _zoneFocus };
        if (_zIdx >= 0 && { _locPos distance ((MISSION_CORE_CACHED_POSITIONS select _zIdx) select 1) < 4000 }) exitWith {};
    };

    // Find nearest friendly REDFOR location with positive supply. PERMANENT RULE: non-combat-effective
    // markers (Factory / Powerplant / Solar / Depot) never act as reinforcement GIVERS - they are
    // production and logistics sites whose garrison holds in place. They can still RECEIVE
    // reinforcements. Note this is the WIDER rule; the older light-infrastructure half (which also
    // withheld static defenses) is unchanged and still enforced separately.
    private _providers = MISSION_CORE_CACHED_POSITIONS select {
        (_x select 4) == EAST &&
        { (_x select 0) != _locName } &&
        { !([_x] call MISSION_CORE_fnc_isNonCombatEffective) } &&
        { (MISSION_CORE_LOCATION_SUPPLY getOrDefault [_x select 0, 0]) > (_x select 7) * 10 }
    };
    // AMMO-aware provider: when the requesting marker is low on ammo, prefer a provider that also
    // has ammo stock so the reinforcement can pair an ammo top-up. A neighbor with no ammo cannot
    // fight, so this ranking is what keeps a supplied-but-unarmed marker from being picked as the
    // giver. A provider with >= 10 ammo ranks first; suppliers with none still field men but are
    // de-prioritized. (Was worded "a stocked depot" - depots are non-combat-effective now, so the
    // qualifying provider is any armed marker. fn_ammo.sqf seeds ammo for every marker.)
    if ([_locName] call MISSION_CORE_fnc_getAmmoFraction < 0.3) then {
        private _stocked = _providers select { MISSION_CORE_LOCATION_AMMO getOrDefault [(_x select 0), 0] >= 10 };
        if (count _stocked > 0) then { _providers = _stocked; } else { diag_log format ["DYNAMIC REINF: %1 low on ammo but no stocked provider found", _locName]; };
    };
    if (count _providers == 0) exitWith {};
    private _provider = _providers select 0;
    private _nearestDist = _locPos distance (_provider select 1);
    {
        private _d = _locPos distance (_x select 1);
        if (_d < _nearestDist) then { _nearestDist = _d; _provider = _x; };
    } forEach _providers;
    private _providerName = _provider select 0;
    private _providerSupply = MISSION_CORE_LOCATION_SUPPLY getOrDefault [_providerName, 0];
    private _providerImportance = _provider select 7;

    // Select candidate group templates from provider's location (proper infantry first, all-men last resort)
    private _defenseCandidates = [_allGroups] call MISSION_CORE_fnc_getInfTemplates;
    // Sender cap scales with the provider's OWN strategic value: a higher-level sender (HQ 100,
    // Factory 80) can donate more supplies than a low-value one (Outpost 30). Base capacity is
    // value/20 so a factory can field ~4 reinforcement squads, an outpost ~2.
    private _providerValue = [_providerName] call MISSION_CORE_fnc_getMarkerValue;
    private _senderCap = ((_providerValue / 20) max 1) min 6;
    // Recipient reward scales with the best target it can actually press against. Valuable
    // targets (Factory/HQ) pull more supply than capturable ones (Outpost), and a target that
    // keeps being defended (high defense score) sheds priority - so supply follows value, not
    // just proximity to an easy win.
    private _receiverPrio = 0;
    {
        if ((_x select 4) == WEST && { ((_x select 1) distance _locPos) < 1500 + (_importance * 400) }) then {
            private _tp = [_x select 0] call MISSION_CORE_fnc_getTargetPriority;
            if (_tp > _receiverPrio) then { _receiverPrio = _tp; };
        };
    } forEach MISSION_CORE_CACHED_POSITIONS;
    private _receiverBonus = ((_receiverPrio / 100) * 0.5) max 0;
    private _groupCount = (((_importance min _providerImportance) + 1) * (0.5 + _receiverBonus)) min _senderCap;
    _groupCount = round _groupCount;
    // Diminishing capture wind-down: when the players take a marker, fewer and fewer reinforcements
    // spawn to take it back. The response scales down across the occupation hold until it reaches
    // zero - then nothing more spawns here and the units already spawned disengage and go patrol the
    // next closest REDFOR marker instead of feeding a dead zone. Clocks off
    // MISSION_CORE_OCCUPATION's occupied-at timestamp (the authoritative capture record, written in
    // fn_captureMarkerForPlayers); this used to read the retake table, which no longer exists. It
    // scales the response DOWN only - it does not create contested state and does not cancel squads
    // already in flight, so those still run until the zone pool is exhausted or maxed.
    if (!isNil "MISSION_CORE_OCCUPATION") then {
        private _occ = MISSION_CORE_OCCUPATION getOrDefault [_locName, []];
        if (count _occ > 2) then {
            private _occAge = time - (_occ select 2);
            private _occWindow = ["captureWindDownWindow", 1200] call MISSION_CORE_fnc_tune;
            if (_occAge >= 0 && { _occAge < _occWindow } && { (_occ select 1) == EAST }) then {
                _groupCount = round (_groupCount * ((1 - (_occAge / _occWindow)) max 0));
            };
        };
    };
    if (_groupCount > count _defenseCandidates) then { _groupCount = count _defenseCandidates; };
    if (_groupCount <= 0) exitWith { [_locName] call MISSION_CORE_fnc_disengageToNextMarker; };
    private _selectedTemplates = _defenseCandidates select [0, _groupCount];

    // Spawn at provider position and send toward exhausted location
    private _supplyGiven = 0;
    {
        private _spawnPos = [(_provider select 1) select 0, (_provider select 1) select 1, 0];
        private _mSize = if (count _loc > 8) then { _loc select 8 } else { [250, 250] };
        // Foot infantry cap: max 3 towns per side may field infantry. Queue the rest to spawn
        // when a squad is KIA and frees a slot.
        // PERMANENT RULE (global foot budget): the sender cap also respects the per-side foot-squad
        // cap - a reinforcement arm NEVER floats the map over footSquadCapSquads.
        // PENDING ABSTRACT LEGS COUNT IN THE CAP. An abstract leg has no group yet, so
        // fnc_countFootSquads cannot see it, and without this term a provider would mint free
        // squads indefinitely - nothing debited, nothing counted. This reserves the budget
        // slot WITHOUT costing anything: no manpower and no ammo move until the squad spawns.
        // Re-evaluated EVERY iteration, not hoisted: each leg that is accepted adds to the
        // pending count, so a burst that hoisted this would mint _groupCount legs in one go.
        private _footCap = ["footSquadCapSquads", 10] call MISSION_CORE_fnc_tune;
        if (!([EAST, "inf", _locPos] call MISSION_CORE_fnc_townCategoryCanUse) || { (([EAST] call MISSION_CORE_fnc_countFootSquads) + ([] call MISSION_CORE_fnc_countPendingAbstractLegs)) >= _footCap }) then {
            ["MISSION_CORE_fnc_queuedReinforce", format ["reinf_%1_%2", _providerName, _locName], [EAST, _x, _spawnPos, _factionData select 3, _importance, _locPos, _mSize, _providerName]] call MISSION_CORE_fnc_enqueueSpawn;
        } else {
// LONG HAUL? Send it as an abstract leg instead of putting a squad on the map.
            // Only trips at 1500m+ (reinforceAbstractMinDist) and only when both ends are named
            // markers the road router can plan between; anything else returns false and falls
            // through to the normal spawn below, unchanged.
            //
            // NOT counted in _supplyGiven, because _supplyGiven sizes a convoy that is
            // dispatched at the END of this function - a leg's squad does not exist yet, and
            // charging the provider now would take manpower for men still on the road. The
            // convoy is dispatched from the materialize block below instead, so the supply
            // follows the squad: nothing is spent until the squad actually spawns.
            private _legTaken = [
                "reinf", _providerName, _locName,
                (_provider select 1), _locPos, _mSize,
                // payload: everything materialize needs, since an SQF code block does not
                // close over this scope. 0 template, 1 recipient importance, 2 side,
                // 3 faction templates, 4 provider name (convoy payer), 5 recipient name
                // (convoy payee).
                [_x select 0, _importance, EAST, _factionData select 3, _providerName, _locName],
                // materialize: raise the squad at the leg's CURRENT point on the route, not
                // at the provider - that is the whole point of the abstract phase.
                {
                    params ["_row", "_frac"];
                    private _pl = _row select 5;
                    private _at = [_row select 6, _row select 7, _frac] call MISSION_CORE_fnc_convoyPosAt;
                    private _g = [_pl select 0, [_at select 0, _at select 1, 0], _pl select 2, _pl select 3, "AWARE", "LIMITED", _pl select 1, _row select 3, _row select 4] call MISSION_CORE_fnc_spawnGroup;
                    if (!isNull _g) then {
                        _g setVariable ["MISSION_CORE_MARKER_CENTER", _row select 3];
                        if (isNil "MISSION_CORE_SPAWNED_GROUPS") then { MISSION_CORE_SPAWNED_GROUPS = []; };
                        MISSION_CORE_SPAWNED_GROUPS pushBack _g;
                        // THE SUPPLY FOLLOWS THE MEN. startConvoy debits the provider, so for a
                        // leg it runs HERE - when the squad exists - and not at leg dispatch.
                        // One convoy of one, exactly what the direct path contributes per squad
                        // via _supplyGiven. PERMANENT RULE preserved: a recipient that is
                        // CONTESTED when the squad appears still gets men but no truck.
                        // startConvoy returns false and debits nothing if it cannot create a
                        // record, so a provider whose pool moved on in the meantime simply
                        // gets no truck - it is never pushed below zero.
                        if (!isNil "MISSION_CORE_CONTESTED" && { !((_pl select 5) in MISSION_CORE_CONTESTED) }) then {
                            [_pl select 4, _pl select 5, 1] call MISSION_CORE_fnc_startConvoy;
                            diag_log format ["ABSTRACT LEG: reinf %1 -> %2 convoy dispatched (1 supply) - squad spawned", _pl select 4, _pl select 5];
                        } else {
                            diag_log format ["ABSTRACT LEG: reinf %1 -> %2 supply convoy skipped - recipient contested", _pl select 4, _pl select 5];
                        };
                    };
                    _g
                },
                // arrival: hand the last stretch to the same path neighborCounterAttack uses.
                // It clears the leg waypoints and re-issues the truck / dismount-outside-edge
                // approach, which is correct - the leg only ever drove the group as far as the
                // final-approach ring.
                {
                    params ["_g", "_row"];
                    if (isNull _g) exitWith {};
                    [_g, _row select 3, _row select 4] call MISSION_CORE_fnc_sendCounterAttack;
                }
            ] call MISSION_CORE_fnc_abstractLegDispatch;
            if (!_legTaken) then {
                // LONG-HAUL GATE: a foot haul at/over the abstraction threshold belongs to the
                // leg system, not to a truck ride or a multi-km foot slog. If the abstract
                // dispatch (straight-line fallback included) still declined, skip the conjure -
                // the pair stays uncounted and a later sweep retries it. Spending a squad on a
                // doomed ride helps no one.
                private _skipConjure = false;
                private _minG = ["reinforceAbstractMinDist", 2000] call MISSION_CORE_fnc_tune;
                if !(_minG isEqualType 1) then { _minG = 2000; };
                if (((_provider select 1) distance2D _locPos) >= _minG) then {
                    _skipConjure = true;
                    diag_log format ["LONG HAUL REINF: %1 -> %2 is %3m (>= %4m); abstract declined - skipping conjure", _providerName, _locName, round ((_provider select 1) distance2D _locPos), _minG];
                };
                if (!_skipConjure) then {
                private _grp = [_x select 0, _spawnPos, EAST, _factionData select 3, "AWARE", "LIMITED", _importance, _locPos, _mSize] call MISSION_CORE_fnc_spawnGroup;
                if (!isNull _grp) then {
                    _grp setVariable ["MISSION_CORE_MARKER_CENTER", _locPos];
                    [_grp] call MISSION_CORE_fnc_clearGroupWaypoints;
                    // Delegate the movement decision to the same path neighborCounterAttack uses.
                    // sendCounterAttack trucks the squad when it is 700m+ out AND a player is actually
                    // near the target, dismounts 100m OUTSIDE the marker edge, drives the road route,
                    // and falls back to a foot advance when either condition fails. The single MOVE
                    // waypoint this replaced walked the whole way - through water, across walls - and
                    // delivered the squad on top of the players instead of onto the approach.
                    //
                    // Side effect worth knowing: on arrival these squads now run footArrival +
                    // footSquadPostAssault, so they patrol and take part in quadrant engagement rather
                    // than sitting on the marker. That is the intended consequence of sharing one path.
                    [_grp, _locPos, _mSize] call MISSION_CORE_fnc_sendCounterAttack;
                    _supplyGiven = _supplyGiven + 1;
                    if (isNil "MISSION_CORE_SPAWNED_GROUPS") then { MISSION_CORE_SPAWNED_GROUPS = []; };
                    MISSION_CORE_SPAWNED_GROUPS pushBack _grp;
                };
                };
            };
        };
        // 0.4s gap between reinforcement squads so they arrive staggered
        sleep 0.4;
    } forEach _selectedTemplates;

    if (_supplyGiven == 0) exitWith {};
    // 5s gap after this marker's whole reinforcement set before the next spawn burst
    sleep 5;

    // Supply now moves as a PHYSICAL convoy, not instant credit. The provider is charged, and the
    // recipient only receives supply when the truck actually arrives (or it is lost if destroyed).
    // PERMANENT RULE: a contested recipient never gets a convoy - reinforcements still field men, but
    // no supply trucks roll into a zone the players are actively fighting over (see fn_startConvoy).
    if (!isNil "MISSION_CORE_CONTESTED" && { _locName in MISSION_CORE_CONTESTED }) then {
        diag_log format ["DYNAMIC SUPPLY REINF: %1 -> %2 supply convoy skipped - recipient contested", _providerName, _locName];
    } else {
        [_providerName, _locName, _supplyGiven] call MISSION_CORE_fnc_startConvoy;
        diag_log format ["DYNAMIC SUPPLY REINF: %1 -> %2 convoy dispatched (%3 supply)", _providerName, _locName, _supplyGiven];
    };
};
