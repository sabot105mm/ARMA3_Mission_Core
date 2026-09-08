call compile preprocessFileLineNumbers "fnc\fn_spawnSelector.sqf";

if (isServer) then {
    MISSION_CORE_INITIALIZED = false;
    MISSION_CORE_LOCATIONS = [];
    MISSION_CORE_BLUFOR_SPAWNS = [];
    MISSION_CORE_CACHED_POSITIONS = [];
    MISSION_CORE_FACTION_DATA = [];
    MISSION_CORE_DETECTION = [];

    // Balance tuning: read MISSION_CORE_TUNE into MISSION_CORE_SETTINGS before any loop starts.
    call compile preprocessFileLineNumbers "fnc\fn_tune.sqf";
    call MISSION_CORE_fnc_loadTune;

    diag_log "DYNAMIC OPS: Initializing mission core...";

    // 0. Init CfgLocationTypes for map region detection
    MISSION_CORE_fnc_initLocationTypes = {
        private _cfg = configFile >> "CfgLocationTypes";
        private _names = [];
        for "_i" from 0 to (count _cfg - 1) do {
            private _entry = _cfg select _i;
            private _cn = configName _entry;
            if (isText (_entry >> "name")) then { _names pushBack _cn; };
        };
        MISSION_CORE_LOCATION_TYPES = _names;
        diag_log format ["DYNAMIC CACHE: loaded %1 location types from CfgLocationTypes", count _names];
    };
    call MISSION_CORE_fnc_initLocationTypes;

    // Terrain analysis helpers (defined before use)
    MISSION_CORE_fnc_checkFlat = {
        private _pos = _this select 0;
        private _centerElev = getTerrainHeightASL _pos;
        private _flatCount = 0;
        for "_i" from 0 to 8 do {
            private _check = _pos getPos [10, (_i / 9) * 360];
            if ((abs ((_check select 2) - _centerElev)) < 1.5) then { _flatCount = _flatCount + 1; };
        };
        _flatCount / 9
    };
    MISSION_CORE_fnc_checkPOI = {
        private _pos = _this select 0;
        private _roads = nearestTerrainObjects [_pos, ["ROAD"], 300];
        private _towns = nearestLocations [_pos, MISSION_CORE_LOCATION_TYPES, 500];
        (count _roads > 0) || (count _towns > 0)
    };
    MISSION_CORE_fnc_checkElevated = {
        private _pos = _this select 0;
        private _roads = nearestTerrainObjects [_pos, ["ROAD"], 400];
        if (count _roads == 0) exitWith { false };
        private _road = _roads select 0;
        private _center = getPosASL _road;
        (getTerrainHeightASL _pos) > (_center select 2) + 5
    };
    MISSION_CORE_fnc_checkOverwatch = {
        params ["_testPos", "_centerElevASL"];
        private _elev = getTerrainHeightASL _testPos;
        if (_elev < _centerElevASL + 15) exitWith { false };
        private _flatCount = 0;
        for "_i" from 0 to 7 do {
            private _check = _testPos getPos [15, (_i / 8) * 360];
            private _checkElev = getTerrainHeightASL _check;
            if (abs (_checkElev - _elev) < 3) then { _flatCount = _flatCount + 1; };
        };
        _flatCount / 8 > 0.6
    };

    // Terrain caching function
    MISSION_CORE_fnc_cacheTerrain = {
        private _locations = _this;
        private _cached = [];
        {
            private _loc = _x;
            private _markerName = _loc select 0;
            private _typeName = _loc select 2;
            private _priority = _loc select 4;
            private _owner = _loc select 5;
            private _pos = getMarkerPos _markerName;
            private _size = getMarkerSize _markerName;
            private _a = _size select 0;
            private _b = _size select 1;
            private _mkrDir = markerDir _markerName;
            private _importance = _loc select 7;
            private _validPositions = [];
            private _step = 25;
            private _gridR = sqrt (_a * _a + _b * _b);
            for "_x" from (_pos select 0) - _gridR to (_pos select 0) + _gridR step _step do {
                for "_y" from (_pos select 1) - _gridR to (_pos select 1) + _gridR step _step do {
                    private _testPos = [_x, _y, 0];
                    private _dx = _x - (_pos select 0);
                    private _dy = _y - (_pos select 1);
                    private _rx = _dx * cos _mkrDir - _dy * sin _mkrDir;
                    private _ry = _dx * sin _mkrDir + _dy * cos _mkrDir;
                    if ((_rx*_rx)/(_a*_a) + (_ry*_ry)/(_b*_b) <= 1) then {
                        if (([_testPos] call MISSION_CORE_fnc_checkFlat) > 0.85 && { [_testPos] call MISSION_CORE_fnc_isDryPos }) then {
                            // Never pick a spot that sits inside or on top of a giant boulder -
                            // spawning infantry there wedges them in the rock.
                            private _nearRocks = nearestTerrainObjects [_testPos, ["ROCK", "ROCKS", "BOULDER"], 6];
                            if (count _nearRocks > 0) then { continue; };
                            private _hasPOI = [_testPos] call MISSION_CORE_fnc_checkPOI;
                            private _elevated = [_testPos] call MISSION_CORE_fnc_checkElevated;
                            if (_hasPOI || _elevated) then { _validPositions pushBack [_testPos, _hasPOI, _elevated]; };
                        };
                    };
                };
            };
            _validPositions = [_validPositions, [], { (_x select 0) distance _pos }, "ASCEND"] call BIS_fnc_sortBy;
            private _defense = _validPositions select { _x select 1 } apply { _x select 0 };
            private _ambush = _validPositions select { _x select 2 } apply { _x select 0 };
            private _overwatch = [];

            // For high-importance locations, scan nearby high ground for AA/AT/vehicle overwatch
            if (_importance >= 3) then {
                private _centerElevASL = getTerrainHeightASL _pos;
                private _scanRadius = 400 + (_importance * 100);
                for "_x" from (_pos select 0) - _scanRadius to (_pos select 0) + _scanRadius step 40 do {
                    for "_y" from (_pos select 1) - _scanRadius to (_pos select 1) + _scanRadius step 40 do {
                        private _testPos = [_x, _y];
                        if (_pos distance2D _testPos < _scanRadius && { _pos distance2D _testPos > ((_a min _b) * 0.5) }) then {
                            if ([_testPos, _centerElevASL] call MISSION_CORE_fnc_checkOverwatch) then {
                                _overwatch pushBack _testPos;
                            };
                        };
                    };
                };
                _overwatch = [_overwatch, [], { _x distance2D _pos }, "ASCEND"] call BIS_fnc_sortBy;
                _overwatch = _overwatch select [0, 3 min count _overwatch];
                diag_log format ["DYNAMIC CACHE: %1 overwatch positions=%2", _markerName, count _overwatch];
            };

            // Map facing label captured by scanMarkers (index 8; fall back to the marker id).
            private _mapLabel = if (count _loc > 8) then { _loc select 8 } else { _markerName };

            _cached pushBack [_markerName, _pos, _typeName, _priority, _owner, _defense, _ambush, _importance, [_size select 0, _size select 1, _mkrDir], _overwatch, _mapLabel];
        } forEach _locations;
        MISSION_CORE_CACHED_POSITIONS = _cached;
        _cached
    };

    // 1. Detect faction data from config
    call compile preprocessFileLineNumbers "fnc\fn_detect.sqf";
    MISSION_CORE_FACTION_DATA = [] call MISSION_CORE_fnc_detectFactions;
    MISSION_CORE_BLUFOR_DATA = MISSION_CORE_FACTION_DATA select 0;
    MISSION_CORE_REDFOR_DATA = MISSION_CORE_FACTION_DATA select 1;
    MISSION_CORE_BLUFOR_FACTION = MISSION_CORE_BLUFOR_DATA select 3;
    MISSION_CORE_REDFOR_FACTION = MISSION_CORE_REDFOR_DATA select 3;
    MISSION_CORE_BLUFOR_SIDE = MISSION_CORE_BLUFOR_DATA select 1;
    MISSION_CORE_REDFOR_SIDE = MISSION_CORE_REDFOR_DATA select 1;

    // Flat class lists for the client defense builder. The faction data's vehicle/static maps are
    // hashmaps, which do not reliably survive publicVariable, so broadcast plain [class, cost]
    // arrays instead.
    private _bluVehMap = MISSION_CORE_BLUFOR_DATA select 7;
    private _bluStaticMap = MISSION_CORE_BLUFOR_DATA select 9;
    // Tanks: only actual main battle tanks (proper turret/cannon inspection - no name blacklist).
    MISSION_CORE_BUILDER_TANKS = [];
    {
        if ([_x] call MISSION_CORE_fnc_isTank) then {
            MISSION_CORE_BUILDER_TANKS pushBack [_x, 200];
        };
    } forEach (_bluVehMap getOrDefault ["mbt", []]);
    // Emplacements: only actual static weapons.
    MISSION_CORE_BUILDER_STATICS = [];
    { if (_x isKindOf "StaticWeapon") then { MISSION_CORE_BUILDER_STATICS pushBack [_x, 50]; }; } forEach (_bluStaticMap getOrDefault ["hmg", []]);
    { if (_x isKindOf "StaticWeapon") then { MISSION_CORE_BUILDER_STATICS pushBack [_x, 80]; }; } forEach (_bluStaticMap getOrDefault ["at", []]);
    { if (_x isKindOf "StaticWeapon") then { MISSION_CORE_BUILDER_STATICS pushBack [_x, 90]; }; } forEach (_bluStaticMap getOrDefault ["aa", []]);
    { if (_x isKindOf "StaticWeapon") then { MISSION_CORE_BUILDER_STATICS pushBack [_x, 70]; }; } forEach (_bluStaticMap getOrDefault ["mortar", []]);
    publicVariable "MISSION_CORE_BUILDER_TANKS";
    publicVariable "MISSION_CORE_BUILDER_STATICS";

    MISSION_CORE_BLUFOR_TANKS_LEFT = getNumber (missionConfigFile >> "B_MAX_TANKS");
    MISSION_CORE_REDFOR_TANKS_LEFT = getNumber (missionConfigFile >> "O_MAX_TANKS");
    MISSION_CORE_BLUFOR_DATA pushBack MISSION_CORE_BLUFOR_TANKS_LEFT;
    MISSION_CORE_REDFOR_DATA pushBack MISSION_CORE_REDFOR_TANKS_LEFT;
    diag_log format ["DYNAMIC OPS: Max tanks BLUFOR=%1 REDFOR=%2", MISSION_CORE_BLUFOR_TANKS_LEFT, MISSION_CORE_REDFOR_TANKS_LEFT];

    diag_log format ["DYNAMIC OPS: BLUFOR=%1 (%2 groups)", MISSION_CORE_BLUFOR_FACTION, count (MISSION_CORE_BLUFOR_DATA select 17)];
    diag_log format ["DYNAMIC OPS: REDFOR=%1 (%2 groups)", MISSION_CORE_REDFOR_FACTION, count (MISSION_CORE_REDFOR_DATA select 17)];

    // 2. Auto-generate location markers from map data + scan all markers
    call compile preprocessFileLineNumbers "fnc\fn_markers.sqf";
    call MISSION_CORE_fnc_generateLocationMarkers;
    MISSION_CORE_LOCATIONS = [] call MISSION_CORE_fnc_scanMarkers;

    // 3. Analyze terrain and cache valid structure positions
    call compile preprocessFileLineNumbers "fnc\fn_spawn.sqf";
    MISSION_CORE_CACHED_POSITIONS = MISSION_CORE_LOCATIONS call MISSION_CORE_fnc_cacheTerrain;

    // 3b. Resolve ports: nest ports inside their host markers (hide + lock + host inherits
    // factory tier), keep isolated ports as factory-tier objectives, and register them for the
    // manpower economy. Must run AFTER cacheTerrain so the host-importance bump lands in the cache.
    // These globals are declared here (top-level scope) so the lazy isNil-guards inside the port
    // system functions write to real mission-namespace variables, not function-locals.
    MISSION_CORE_PORTS = createHashMap;
    MISSION_CORE_BASE_MANPOWER = createHashMap;
    MISSION_CORE_PORT_ACCUM = createHashMap;
    MISSION_CORE_MANPOWER_CONVOYS = [];
    call MISSION_CORE_fnc_resolvePorts;

    // Player manpower economy: shared BLUFOR pool, port income loop, capture awards
    call compile preprocessFileLineNumbers "fnc\fn_manpower.sqf";
    [] call MISSION_CORE_fnc_initManpower;

    // Renown + Force Recon: team currency from captures/convoys, abstract recon dice loops
    call compile preprocessFileLineNumbers "fnc\fn_recon.sqf";
    [] call MISSION_CORE_fnc_initRecon;

    // Ammunition system: per-marker ammo resource that drives AI aggression
    call compile preprocessFileLineNumbers "fnc\fn_ammo.sqf";
    [] call MISSION_CORE_fnc_initAmmo;
    [] spawn MISSION_CORE_fnc_ammoLoop;

    // 3a. Build the per-marker isFlatEmpty safe vehicle spawn cache (async - isFlatEmpty needs
    // a scheduled scope and is heavy enough that it must not block init). findVehiclePos will
    // start reusing these confirmed flat, clear spots as soon as they are ready.
    [] spawn MISSION_CORE_fnc_buildSafeVehicleSpawns;

    // 4. Initialize supply system for each location
    MISSION_CORE_LOCATION_SUPPLY = createHashMap;
    MISSION_CORE_SUPPLY_COOLDOWN = createHashMap;
    {
        private _locName = _x select 0;
        private _importance = _x select 7;
        MISSION_CORE_LOCATION_SUPPLY set [_locName, _importance * 30 + 50];
    } forEach MISSION_CORE_CACHED_POSITIONS;
    diag_log format ["DYNAMIC SUPPLY: initialized %1 locations", count MISSION_CORE_CACHED_POSITIONS];

    MISSION_CORE_DEFENSE_SCORE = createHashMap;
    MISSION_CORE_DEFENSE_ASSIGN = createHashMap;
    MISSION_CORE_DEFENSE_DECAY_TIME = time + 1200;
    MISSION_CORE_AI_CONFIDENCE = createHashMap;
    // PERMANENT RULE: markers that have fired their one all-out assault are exhausted and can
    // only defend for the rest of the mission. The instant the all-out is committed the marker
    // is flagged here so it never initiates an attack again.
    MISSION_CORE_EXHAUSTED_MARKERS = createHashMap;
    // PERMANENT RULE: exactly ONE REDFOR "zone" - the single marker the whole reinforcement /
    // counter-attack effort concentrates on. It anchors onto the marker a player is fighting (or
    // a just-captured marker being retaken) and stays there until the player leaves it and closes
    // on the NEXT enemy marker (near-approach). Switching focus retires the old marker instantly.
    MISSION_CORE_ZONE_FOCUS = "";
    MISSION_CORE_ZONE_FOCUS_TIME = 0;
    MISSION_CORE_COMMIT = createHashMap;
    MISSION_CORE_REINF_COOLDOWN = createHashMap;
    MISSION_CORE_MANPOWER = createHashMap;
    MISSION_CORE_MANPOWER_CUTOFF = createHashMap;
    MISSION_CORE_OCCUPATION = createHashMap;
    // Cumulative casualties per marker (incremented by the per-unit Killed handler in
    // fn_spawnGroup). Initialized here so fn_replenishLoop can read it before any kill occurs.
    MISSION_CORE_MARKER_CASUALTIES = createHashMap;
    MISSION_CORE_RETREATED = createHashMap;
    MISSION_CORE_REINF_EXHAUSTED = createHashMap;
    // DEBUG: draw marker names + capture ellipses + transport unload rings on the map.
    MISSION_CORE_DEBUG_VISUALS = true;
    MISSION_CORE_REPLENISH_SPAWN_INDEX = createHashMap;
    MISSION_CORE_SPAWN_QUEUE = [];
    // Timestamp of the most recent tracked-AI kill (set by the MPKilled mission event handler).
    // The spawn queue polls a cheap wake check against this so queued reinforcements/counter-attacks
    // pop immediately when a foot-squad or MBT cap slot frees, instead of waiting for the 30s poll.
    MISSION_CORE_QUEUE_WAKE = -1e10;
    MISSION_CORE_ARTY = createHashMap;
    // Track which markers are currently allowed to spawn troops. PERMANENT RULE: at most 4
    // markers spawn at once - the contested marker itself plus up to 3 of its closest neighbor
    // markers. No marker beyond those may spawn troops until an active spawner expires.
    MISSION_CORE_ACTIVE_SPAWNERS = createHashMap;
    MISSION_CORE_MBT_RESERVE = createHashMap;
    // Baseline garrison strength per marker - what ACTUALLY spawned (first spawn + replenish),
    // not the theoretical capacity. The 50% capture threshold compares against this so a marker
    // that spawned light is not born already-capturable.
    MISSION_CORE_GARRISON_BASELINE = createHashMap;

    // 5. Place Eden compositions at cached positions
    call compile preprocessFileLineNumbers "fnc\fn_compositions.sqf";
    MISSION_CORE_CACHED_POSITIONS call MISSION_CORE_fnc_placeLocationCompositions;

    // 5. Start proximity spawner (spawns defenses when players are near)
    [] spawn MISSION_CORE_fnc_proximitySpawner;

    // 5a. Defense builder (server): per-player points + placement validation/spawning
    call compile preprocessFileLineNumbers "fnc\fn_defenseBuilderServer.sqf";
    MISSION_CORE_DEFENSE_POINTS = createHashMap;
    MISSION_CORE_PLAYER_DEFENSES = [];
    MISSION_CORE_DEFENSE_POINTS_DEFAULT = getNumber (missionConfigFile >> "DEFENSE_BUILD_POINTS_DEFAULT");
    MISSION_CORE_DEFENSE_POINTS_CAPTURE_REWARD = getNumber (missionConfigFile >> "DEFENSE_BUILD_POINTS_CAPTURE_REWARD");
    publicVariable "MISSION_CORE_DEFENSE_POINTS";
    publicVariable "MISSION_CORE_DEFENSE_POINTS_DEFAULT";
    publicVariable "MISSION_CORE_DEFENSE_POINTS_CAPTURE_REWARD";
    // Manage placed player defenses: despawn when the player moves away, respawn when destroyed
    [] spawn MISSION_CORE_fnc_playerDefenseLoop;

    // 6. Start AI Commander system + assault planner
    call compile preprocessFileLineNumbers "fnc\fn_aiCommander.sqf";
    [] spawn MISSION_CORE_fnc_aiCommanderLoop;
    [] spawn MISSION_CORE_fnc_aiAssaultLoop;
    [] spawn MISSION_CORE_fnc_armorCommanderLoop;
    [] spawn MISSION_CORE_fnc_defenseCoordinator;
    [] spawn MISSION_CORE_fnc_replenishLoop;
    [] spawn MISSION_CORE_fnc_playerHunt;
    [] spawn MISSION_CORE_fnc_objectiveDirector;
    [] spawn MISSION_CORE_fnc_houseOccupationInit;
    [] spawn MISSION_CORE_fnc_spawnQueueLoop;
    [] spawn MISSION_CORE_fnc_groupMaintenance;
    [] spawn MISSION_CORE_fnc_defenseSpotLoop;
    [] spawn MISSION_CORE_fnc_truckCleanupLoop;
    [] spawn MISSION_CORE_fnc_orderedVehicleCleanupLoop;
    [] spawn MISSION_CORE_fnc_convoyLoop;
    [] spawn MISSION_CORE_fnc_reconLoop;
    [] spawn MISSION_CORE_fnc_tankOrderLoop;
    if (MISSION_CORE_DEBUG_VISUALS) then { [] spawn MISSION_CORE_fnc_debugVisuals; };

    // 6b. Kill event: when a tracked AI unit or vehicle is killed, a foot-squad or MBT cap slot
    // may have just freed. Stamp the wake timer (throttled to once per 15s) so the spawn queue
    // reprocesses immediately instead of waiting for its next 30s poll. EntityKilled is the
    // mission-level kill event (MPKilled is only an object event handler) - registered here on the
    // server only (where the queue lives), never per-client.
    addMissionEventHandler ["EntityKilled", {
        params ["_unit", "_killer", "_instigator", "_useEffects"];
        if (isNull _unit) exitWith {};
        private _grp = group _unit;
        if (isNull _grp) exitWith {};
        if (_grp getVariable ["MISSION_CORE_REDFOR", false] || { _grp getVariable ["MISSION_CORE_BLUFOR", false] }) then {
            if (time - MISSION_CORE_QUEUE_WAKE > 15) then { MISSION_CORE_QUEUE_WAKE = time; };
        };
    }];

    // 6a. AI artillery - one SPG (or mortar) per side that shells spotted enemy armor
    call compile preprocessFileLineNumbers "fnc\fn_artillery.sqf";
    if (isNil "MISSION_CORE_fnc_artilleryMonitor") then {
        diag_log "AI ARTY: fn_artillery.sqf not compiled (missing or stale copy) - artillery disabled";
    } else {
        [] spawn MISSION_CORE_fnc_artilleryMonitor;
    };

    // 7. Live map icons for all spawned units (disabled - markers removed)
    // call compile preprocessFileLineNumbers "fnc\fn_icons.sqf";
    // [] spawn MISSION_CORE_fnc_iconMarkers;

    // 7b. Garrison management (server-authoritative spawning for the GARRISON recruit tab).
    call compile preprocessFileLineNumbers "fnc\fn_recruitServer.sqf";
    // Plain-array vehicle pools for the client GARRISON tab menu (hashmaps don't survive
    // publicVariable reliably, so broadcast flat class lists like the defense builder does).
    private _bluVehMap2 = MISSION_CORE_BLUFOR_DATA select 7;
    private _bluStaticMap2 = MISSION_CORE_BLUFOR_DATA select 9;
    MISSION_CORE_GARRISON_TANKS = (_bluVehMap2 getOrDefault ["mbt", []]) select { [_x] call MISSION_CORE_fnc_isTank };
    MISSION_CORE_GARRISON_APCS = _bluVehMap2 getOrDefault ["apc", []];
    MISSION_CORE_GARRISON_ARTY = _bluVehMap2 getOrDefault ["artillery", []];
    MISSION_CORE_GARRISON_MORTARS = _bluStaticMap2 getOrDefault ["mortar", []];
    MISSION_CORE_GARRISON_GUNTRUCKS = _bluVehMap2 getOrDefault ["gunTruck", []];
    publicVariable "MISSION_CORE_GARRISON_TANKS";
    publicVariable "MISSION_CORE_GARRISON_APCS";
    publicVariable "MISSION_CORE_GARRISON_ARTY";
    publicVariable "MISSION_CORE_GARRISON_MORTARS";
    publicVariable "MISSION_CORE_GARRISON_GUNTRUCKS";
    diag_log format ["DYNAMIC GARRISON: tanks=%1 apc=%2 arty=%3 mortars=%4 gunTrucks=%5",
        count MISSION_CORE_GARRISON_TANKS, count MISSION_CORE_GARRISON_APCS,
        count MISSION_CORE_GARRISON_ARTY, count MISSION_CORE_GARRISON_MORTARS,
        count MISSION_CORE_GARRISON_GUNTRUCKS];

    // Recruit tanks are delivered via the depot/port pipeline (not conjured instantly). This
    // loop watches pending requests and fills them from a BLUFOR depot or port tank budget.
    if (!(isNil "MISSION_CORE_fnc_recruitTankManagerLoop")) then {
        [] spawn MISSION_CORE_fnc_recruitTankManagerLoop;
    };
    // Garrison refill (rebuild killed recruits at 4x MP when a marker's checkbox is ON) + the
    // lobby-wide under-attack notifier both live in fn_recruitServer.sqf.
    if (!(isNil "MISSION_CORE_fnc_garrisonRefillLoop")) then {
        [] spawn MISSION_CORE_fnc_garrisonRefillLoop;
        [] spawn MISSION_CORE_fnc_garrisonWarnLoop;
    };

    MISSION_CORE_INITIALIZED = true;
    publicVariable "MISSION_CORE_INITIALIZED";
    publicVariable "MISSION_CORE_LOCATIONS";
    publicVariable "MISSION_CORE_BLUFOR_SPAWNS";
    publicVariable "MISSION_CORE_BLUFOR_DATA";
    publicVariable "MISSION_CORE_REDFOR_DATA";
    publicVariable "MISSION_CORE_BLUFOR_FACTION";
    publicVariable "MISSION_CORE_REDFOR_FACTION";
    diag_log "DYNAMIC OPS: Mission core initialized successfully";
} else {
    [] spawn {
        waitUntil { !isNull player };
        waitUntil { MISSION_CORE_INITIALIZED };
        [] call MISSION_CORE_fnc_initSpawnSelector;
    };
};