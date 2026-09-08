
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

    // Find nearest friendly REDFOR location with positive supply. PERMANENT RULE: outposts /
    // powerplants / solar are static tiny garrisons - they never act as reinforcement GIVERS
    // (no supply dispatched).
    private _providers = MISSION_CORE_CACHED_POSITIONS select {
        (_x select 4) == EAST &&
        { (_x select 0) != _locName } &&
        { !([_x] call MISSION_CORE_fnc_isLightInfrastructure) } &&
        { (MISSION_CORE_LOCATION_SUPPLY getOrDefault [_x select 0, 0]) > (_x select 7) * 10 }
    };
    // AMMO-aware provider: when the requesting marker is low on ammo, prefer a provider that also
    // has ammo stock (a stocked depot) so the reinforcement can pair an ammo top-up. A provider
    // with >= 10 ammo ranks first; suppliers with none still field men but are de-prioritized.
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
    // Diminishing retake: when the players capture a marker, fewer and fewer reinforcements spawn
    // to take it back. The response scales down across the marker's 20-min retake window until it
    // reaches zero - then nothing more spawns here and the units already spawned disengage and go
    // patrol the next closest REDFOR marker instead of feeding a dead zone.
    if (!isNil "MISSION_CORE_CAPTURED_RETAKE" && { _locName in MISSION_CORE_CAPTURED_RETAKE }) then {
        private _rv = MISSION_CORE_CAPTURED_RETAKE get _locName;
        if (count _rv > 1 && { (_rv select 0) == EAST }) then {
            private _age = time - (_rv select 1);
            private _frac = (1 - (_age / 1200)) max 0;
            _groupCount = round (_groupCount * _frac);
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
        if !([EAST, "inf", _locPos] call MISSION_CORE_fnc_townCategoryCanUse) then {
            ["MISSION_CORE_fnc_queuedReinforce", format ["reinf_%1_%2", _providerName, _locName], [EAST, _x, _spawnPos, _factionData select 3, _importance, _locPos, _mSize, _providerName]] call MISSION_CORE_fnc_enqueueSpawn;
        } else {
            private _grp = [_x select 0, _spawnPos, EAST, _factionData select 3, "AWARE", "LIMITED", _importance, _locPos, _mSize] call MISSION_CORE_fnc_spawnGroup;
            if (!isNull _grp) then {
                _grp setVariable ["MISSION_CORE_MARKER_CENTER", _locPos];
                [_grp] call MISSION_CORE_fnc_clearGroupWaypoints;
                private _wp = _grp addWaypoint [_locPos, 100];
                _wp setWaypointType "MOVE";
                _wp setWaypointSpeed "NORMAL";
                _wp setWaypointBehaviour "AWARE";
                _grp setCurrentWaypoint _wp;
                _supplyGiven = _supplyGiven + 1;
                if (isNil "MISSION_CORE_SPAWNED_GROUPS") then { MISSION_CORE_SPAWNED_GROUPS = []; };
                MISSION_CORE_SPAWNED_GROUPS pushBack _grp;
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
    [_providerName, _locName, _supplyGiven] call MISSION_CORE_fnc_startConvoy;

    diag_log format ["DYNAMIC SUPPLY REINF: %1 -> %2 convoy dispatched (%3 supply)", _providerName, _locName, _supplyGiven];
};
