// =====================================================================
// RECRUIT SERVER (GARRISON MANAGEMENT)
//
// Server-authoritative spawning for the GARRISON recruit tab. Players
// send spawn/remove requests from the client menu via remoteExec; this
// file validates manpower + per-marker limits, spawns squads and
// vehicles with correct crew/origin tracking, keeps a per-marker garrison
// database, and drives target-assignment for player-placed artillery.
//
// Runs ONLY on the server (compiled in fn_init.sqf).
// =====================================================================

if (isNil "MISSION_CORE_GARRISON_DB") then { MISSION_CORE_GARRISON_DB = createHashMap; };
if (isNil "MISSION_CORE_PLAYER_ARTY") then { MISSION_CORE_PLAYER_ARTY = createHashMap; };
// Pending recruit tank requests: [targetMarker, placedAt]. Kept so a depot or port can fill them.
if (isNil "MISSION_CORE_RECRUIT_TANK_ORDERS") then { MISSION_CORE_RECRUIT_TANK_ORDERS = []; };
// GARRISON REFILL: markers with the recruit-menu checkbox ON. When an entry of a refilled marker's
// garrison DB dies, it is queued and rebuilt at 4x the original manpower once no enemy is near.
// The list is publicVariable'd so every client's checkbox reflects live state (mirrors the per-marker
// INSTANT TANK DELIVERY list).
if (isNil "MISSION_CORE_GARRISON_REFILL") then { MISSION_CORE_GARRISON_REFILL = []; };
// Pending refill rebuild jobs. Each: [markerName, kind, payload, cost4x]
//   kind "sq":  payload [_faction,_catName,_grpName,_template]
//   kind "veh": payload [_vehClass,_kind]
//   kind "tank": payload _vehClass
if (isNil "MISSION_CORE_REFILL_PENDING") then { MISSION_CORE_REFILL_PENDING = []; };

// ---- helpers ----------------------------------------------------------

// Look up a marker's importance (index 7) and type name (index 2) from the
// cached positions (authoritative server list). Falls back to importance 1.
MISSION_CORE_fnc_garrisonMarkerInfo = {
    params ["_markerName"];
    private _imp = 1;
    private _type = "";
    if (!isNil "MISSION_CORE_CACHED_POSITIONS") then {
        private _idx = MISSION_CORE_CACHED_POSITIONS findIf { (_x select 0) == _markerName };
        if (_idx >= 0) then {
            _imp = (MISSION_CORE_CACHED_POSITIONS select _idx) select 7;
            _type = (MISSION_CORE_CACHED_POSITIONS select _idx) select 2;
        };
    };
    [_imp, _type]
};

// Current living count of a marker's garrison (men), groups, and vehicles.
MISSION_CORE_fnc_garrisonCounts = {
    params ["_markerName"];
    private _men = [_markerName, WEST] call MISSION_CORE_fnc_countMarkerGarrison;
    private _grpCount = 0;
    private _vehList = [];
    if (isNil "MISSION_CORE_SPAWNED_GROUPS") then { MISSION_CORE_SPAWNED_GROUPS = []; };
    {
        if (!isNull _x && { _x getVariable ["MISSION_CORE_BLUFOR", false] } && { (_x getVariable ["MISSION_CORE_ORIGIN_MARKER", ""]) == _markerName }) then {
            _grpCount = _grpCount + 1;
            {
                private _v = vehicle _x;
                if (_v != _x && { _v isKindOf "AllVehicles" } && { _vehList findIf { _x == _v } < 0 }) then {
                    _vehList pushBack _v;
                };
            } forEach (units _x);
        };
    } forEach MISSION_CORE_SPAWNED_GROUPS;
    private _vehCount = count _vehList;
    [_men, _grpCount, _vehCount]
};

// Per-marker delegation limits. Returns [allowed(bool), reason(string)].
MISSION_CORE_fnc_garrisonLimits = {
    params ["_markerName", "_kind"];
    private _info = [_markerName] call MISSION_CORE_fnc_garrisonMarkerInfo;
    private _imp = _info select 0;
    private _type = _info select 1;
    private _isHQ = _type == "HQ";
    private _counts = [_markerName] call MISSION_CORE_fnc_garrisonCounts;
    private _men = _counts select 0;

    // Manpower occupancy cap: HQ allows up to 60 men, lesser markers scale down.
    private _manCap = if (_isHQ) then { 60 } else { (30 + _imp * 6) min 45 };

    switch (_kind) do {
        case "squad": {
            if (_men >= _manCap) then { [false, format ["Marker at manpower cap (%1 men / %2 max)", _men, _manCap]] } else { [true, ""] }
        };
        case "tank": {
            if (_imp < 3) then { [false, "Tanks require a level 3+ marker"] } else {
                private _tankCap = if (_isHQ) then { 4 } else { if (_imp >= 5) then { 2 } else { 1 } };
                private _mbtHere = 0;
                if (isNil "MISSION_CORE_SPAWNED_GROUPS") then { MISSION_CORE_SPAWNED_GROUPS = []; };
                {
                    if (!isNull _x && { _x getVariable ["MISSION_CORE_BLUFOR", false] } && { (_x getVariable ["MISSION_CORE_ORIGIN_MARKER", ""]) == _markerName } && { (_x getVariable ["MISSION_CORE_ARMOR_SLOT", ""]) == "mbt" }) then {
                        _mbtHere = _mbtHere + 1;
                    };
                } forEach MISSION_CORE_SPAWNED_GROUPS;
                if (_mbtHere >= _tankCap) then { [false, format ["Tank cap for this marker (%1)", _tankCap]] } else { [true, ""] }
            }
        };
        case "apc": {
            private _apcHere = 0;
            if (isNil "MISSION_CORE_SPAWNED_GROUPS") then { MISSION_CORE_SPAWNED_GROUPS = []; };
            {
                if (!isNull _x && { _x getVariable ["MISSION_CORE_BLUFOR", false] } && { (_x getVariable ["MISSION_CORE_ORIGIN_MARKER", ""]) == _markerName } && { (_x getVariable ["MISSION_CORE_ARMOR_SLOT", ""]) in ["mech", "apc"] }) then {
                    _apcHere = _apcHere + 1;
                };
            } forEach MISSION_CORE_SPAWNED_GROUPS;
            if (_apcHere >= 1) then { [false, "APC cap for this marker (1 max)"] } else {
                if (_imp < 2) then { [false, "APCs require a level 2+ marker"] } else { [true, ""] }
            }
        };
        case "gunTruck": {
            if (_imp < 1) then { [false, "Gun trucks require a level 1+ marker"] } else { [true, ""] }
        };
        case "mlrs_spg": {
            if !(_isHQ) then { [false, "MLRS/SPG only deployable at HQ"] } else { [true, ""] }
        };
        case "mortar": {
            if (_imp < 1) then { [false, "Mortars require a level 1+ marker"] } else { [true, ""] }
        };
        default { [true, ""] };
    };
};

// ---- recruit tank orders (depot/port pipeline) ----------------------------

// Place a recruit tank request for a BLUFOR marker. The tank is NOT spawned instantly:
// a depot with parked stock (or a prioritized port) delivers one later. Each delivered tank
// consumes one pool point permanently and cost the player 4 MP (already deducted by caller).
MISSION_CORE_fnc_recruitTankToDepot = {
    params ["_markerName", "_markerPos", ["_vehClass", ""], ["_cost", 0]];
    if (isNil "MISSION_CORE_RECRUIT_TANK_ORDERS") then { MISSION_CORE_RECRUIT_TANK_ORDERS = []; };
    // Store the exact MBT class the player chose so delivery spawns THAT tank, not a random mbT.
    // The base recruit cost rides along so a refill rebuild knows what to charge (10s rebuild at 4x MP).
    // No dedup: each click queues one more tank for the marker (delivered one per 15s manager tick).
    MISSION_CORE_RECRUIT_TANK_ORDERS pushBack [_markerName, _markerPos, time, _vehClass, _cost];
    diag_log format ["RECRUIT TANK: request placed for %1 (%2) - total queued %3", _markerName, _vehClass, count MISSION_CORE_RECRUIT_TANK_ORDERS];
};

// Fill as many pending recruit tank requests as possible this tick from a same-side depot that
// has physical parked stock, or from a port tank budget when prioritized. Delivers by calling
// the normal orderTank convoy path (a tank drives to the marker and defends it).
MISSION_CORE_fnc_recruitTankManagerLoop = {
    diag_log "RECRUIT TANK: manager loop started";
    while { true } do {
        sleep 15;
        call MISSION_CORE_fnc_publishArmorPool;
        if (isNil "MISSION_CORE_RECRUIT_TANK_ORDERS") then { MISSION_CORE_RECRUIT_TANK_ORDERS = []; };
        if (count MISSION_CORE_RECRUIT_TANK_ORDERS == 0) then { continue; };
        if (isNil "MISSION_CORE_CACHED_POSITIONS") then { continue; };

        // BLUFOR depots with physical parked stock, sorted by stock desc then nearest to request.
        private _bluDepots = MISSION_CORE_CACHED_POSITIONS select {
            (_x select 4) == WEST && { [_x] call MISSION_CORE_fnc_tankDepotIsDepot } && { ([(_x select 0)] call MISSION_CORE_fnc_tankDepotStock) > 0 }
        };

        private _keep = [];
        {
            _x params ["_mName", "_mPos", "_t"];
            private _vCls = if (count _x > 3) then { _x select 3 } else { "" };
            private _cost = if (count _x > 4) then { _x select 4 } else { 0 };
            private _mLoc = [];
            {
                if ((_x select 0) == _mName) exitWith { _mLoc = _x; };
            } forEach MISSION_CORE_CACHED_POSITIONS;

            // The marker was captured away from BLUFOR while waiting - drop the request and refund.
            if (count _mLoc > 0 && { (_mLoc select 4) != WEST }) then {
                [4] call MISSION_CORE_fnc_refundManpower;
                diag_log format ["RECRUIT TANK: %1 lost to enemy - request cancelled, 4 MP refunded", _mName];
                continue;
            };

            private _filled = false;

            // 1) A BLUFOR depot with parked stock fills the request by consuming one armor-pool
            //    point and delivering a PHYSICAL tank that drives in to defend the marker. The old
            //    abstract-convoy path despawned the convoy into the pool on arrival, so a paid
            //    order never left a standing tank - players must SEE the tank they bought.
            if (count _bluDepots > 0) then {
                private _src = [WEST, _mPos] call MISSION_CORE_fnc_consumePoolTankForSide;
                if (_src != "") then {
                    private _spawnPos = _mPos getPos [300, random 360];
                    private _g = [WEST, _mPos, _mName, 1, _spawnPos, _vCls, _cost] call MISSION_CORE_fnc_tankDeployAbstract;
                    if (!isNull _g) then {
                        _filled = true;
                        diag_log format ["RECRUIT TANK: depot %1 delivered a tank to %2 (armor pool point consumed)", _src, _mName];
                    };
                };
            };

            // 2) Otherwise a port fills the request if it has a tank budget available.
            if (!_filled) then {
                if ([_mName, _mPos, _vCls, _cost] call MISSION_CORE_fnc_portFillTankRequest) then {
                    _filled = true;
                    diag_log format ["RECRUIT TANK: port filled request for %1", _mName];
                };
            };

            if (_filled) then {
                if (isNil "MISSION_CORE_RECRUIT_TANK_COMPLETED") then { MISSION_CORE_RECRUIT_TANK_COMPLETED = createHashMap; };
                MISSION_CORE_RECRUIT_TANK_COMPLETED set [_mName, time];
            } else {
                _keep pushBack _x;
            };
        } forEach MISSION_CORE_RECRUIT_TANK_ORDERS;
        MISSION_CORE_RECRUIT_TANK_ORDERS = _keep;
    };
};

// HQ action toggle: the INSTANT TANK DELIVERY switch for a marker. Clicking once turns instant
// delivery ON for that marker (tanks delivered immediately at 2x MP); clicking again turns it OFF
// (tanks queue at base cost). The state is publicVariable'd so every client's HQ menu can show ON/OFF.
MISSION_CORE_fnc_prioritizePort = {
    params ["_markerName"];
    // INSTANT TANK DELIVERY is now a per-marker switch LIST, not a single global marker - toggling
    // one marker must never silently flip another off, and each marker's switch survives menu
    // refreshes and the 5s live-refresh loop.
    if (isNil "MISSION_CORE_PORT_PRIORITY") then { MISSION_CORE_PORT_PRIORITY = []; };
    if (!isNil "_markerName" && _markerName != "") then {
        private _i = MISSION_CORE_PORT_PRIORITY find _markerName;
        if (_i >= 0) then {
            MISSION_CORE_PORT_PRIORITY deleteAt _i;
            diag_log format ["RECRUIT TANK: instant tank delivery turned OFF for %1", _markerName];
        } else {
            MISSION_CORE_PORT_PRIORITY pushBack _markerName;
            diag_log format ["RECRUIT TANK: instant tank delivery ON for %1 (2x MP)", _markerName];
        };
    };
    publicVariable "MISSION_CORE_PORT_PRIORITY";
    // Return whether the marker's instant switch is now ON to the calling client.
    _markerName in MISSION_CORE_PORT_PRIORITY
};

// ---- garrison squad deploy ---------------------------------------------

// [_caller, _markerName, _template, _faction, _catName, _grpName, _unitCost]
MISSION_CORE_fnc_serverGarrisonDeploy = {
    params ["_caller", "_markerName", "_template", "_faction", "_catName", "_grpName", "_unitCost"];
    if (isNil "_caller" || { isNull _caller }) exitWith { };
    if (isNil "_unitCost") then { _unitCost = 0; };

    // Locate the marker in MISSION_CORE_LOCATIONS for its position + size.
    if (isNil "MISSION_CORE_LOCATIONS") exitWith { };
    private _locIdx = MISSION_CORE_LOCATIONS findIf { (_x select 0) == _markerName };
    if (_locIdx < 0) exitWith { };
    private _loc = MISSION_CORE_LOCATIONS select _locIdx;
    private _markerPos = (_loc select 1) select 0;
    private _markerSize = if (count (_loc select 1) > 1) then { (_loc select 1) select 1 } else { [200, 200, 0] };
    private _markerDir = if (count (_loc select 1) > 2) then { (_loc select 1) select 2 } else { 0 };
    private _markerShape = if (count (_loc select 1) > 3) then { (_loc select 1) select 3 } else { "ELLIPSE" };

    // Manpower + limit checks.
    private _proceed = true;
    if (!([_unitCost] call MISSION_CORE_fnc_drawManpower)) then {
        _proceed = false;
        MISSION_CORE_RECRUIT_RESULT = "Not enough manpower!";
        publicVariable "MISSION_CORE_RECRUIT_RESULT";
    };
    if (_proceed) then {
        private _lim = [_markerName, "squad"] call MISSION_CORE_fnc_garrisonLimits;
        if !(_lim select 0) then {
            _proceed = false;
            [_unitCost] call MISSION_CORE_fnc_refundManpower;
            MISSION_CORE_RECRUIT_RESULT = _lim select 1;
            publicVariable "MISSION_CORE_RECRUIT_RESULT";
        };
    };
    if (!_proceed) exitWith { };

    // Spawn the squad.
    private _spawnPos = [_markerPos, 0, 80, 10, 0, 0.5, 0] call BIS_fnc_findSafePos;
    if (count _spawnPos < 2) then { _spawnPos = _markerPos; };
    if (count _spawnPos == 2) then { _spawnPos pushBack 0; };
    private _cfgPath = configFile >> "CfgGroups" >> "West" >> _faction >> _catName >> _grpName;
    private _grp = [_spawnPos, WEST, _cfgPath] call BIS_fnc_spawnGroup;
    if (isNull _grp) then {
        // Fallback: manual createUnit from template units.
        _grp = createGroup WEST;
        {
            private _u = _grp createUnit [_x, _spawnPos, [], 10, "FORM"];
        } forEach (_template select 1);
    };
    if (isNull _grp) then {
        [_unitCost] call MISSION_CORE_fnc_refundManpower;
        MISSION_CORE_RECRUIT_RESULT = "Failed to spawn squad!";
        publicVariable "MISSION_CORE_RECRUIT_RESULT";
        _proceed = false;
    };
    if (!_proceed) exitWith { };

    // BIS_fnc_spawnGroup drops vehicles wherever the config formation lands - pull them back
    // onto a road column near the marker so recruited motorized/mech squads deploy on the road.
    [_grp, _markerPos, _markerSize] call MISSION_CORE_fnc_alignGroupVehiclesToRoad;

    // Tag + origin for garrison counting.
    _grp setVariable ["MISSION_CORE_BLUFOR", true];
    _grp setVariable ["MISSION_CORE_GARRISON", true];
    _grp setVariable ["MISSION_CORE_ORIGIN_MARKER", _markerName];
    _grp setVariable ["MISSION_CORE_MARKER_CENTER", _markerPos];
    _grp setVariable ["MISSION_CORE_MARKER_SIZE", _markerSize];
    _grp setVariable ["MISSION_CORE_IDLE", false];
    _grp setVariable ["MISSION_CORE_ORDER", "defend"];
    // Refill bookkeeping: original cost + squad identity so a wipe can be rebuilt at 4x MP.
    _grp setVariable ["MISSION_CORE_RECRUIT_COST", _unitCost];
    _grp setVariable ["MISSION_CORE_RECRUIT_SQUAD", [_faction, _catName, _grpName, _template]];
    _grp setBehaviour "SAFE";
    _grp setCombatMode "YELLOW";
    _grp setSpeedMode "LIMITED";
    if (isNil "MISSION_CORE_SPAWNED_GROUPS") then { MISSION_CORE_SPAWNED_GROUPS = []; };
    MISSION_CORE_SPAWNED_GROUPS pushBack _grp;

    // Patrol the entire marker area, ending in CYCLE.
    private _ma = if (count _markerSize > 0) then { (_markerSize select 0) max 50 } else { 200 };
    private _mb = if (count _markerSize > 1) then { (_markerSize select 1) max 50 } else { _ma };
    private _isRect = toUpper _markerShape == "RECTANGLE";
    // Real marker rotation lives in the location area (index 2), not the 2-element size array.
    private _mDir = _markerDir;
    [_grp] call MISSION_CORE_fnc_clearGroupWaypoints;
    private _unitCount = count units _grp;
    private _patrolCount = 3 + floor (_unitCount / 3);
    // Shape-aware patrol coverage: for a RECTANGLE/square marker, distribute positions uniformly
    // across the whole span (including the corners that a radial/circular pattern clips); ellipses
    // keep the radial spread. Both are rotated by the marker's true direction.
    for "_i" from 1 to _patrolCount do {
        private _ox = 0; private _oy = 0;
        if (_isRect) then {
            _ox = ((random 2) - 1) * _ma;
            _oy = ((random 2) - 1) * _mb;
        } else {
            private _ang = random 360;
            private _frac = (_i - 1) / (_patrolCount max 1);
            private _ratio = if (_frac < 0.25) then { 0.9 } else { if (_frac < 0.6) then { 0.6 + random 0.3 } else { random 0.5 } };
            _ox = _ratio * _ma * cos _ang;
            _oy = _ratio * _mb * sin _ang;
        };
        private _rx = _ox * cos _mDir - _oy * sin _mDir;
        private _ry = _ox * sin _mDir + _oy * cos _mDir;
        private _wpPos = [(_markerPos select 0) + _rx, (_markerPos select 1) + _ry, 0];
        private _wp = _grp addWaypoint [_wpPos, 30];
        _wp setWaypointType "MOVE";
        _wp setWaypointSpeed "LIMITED";
        _wp setWaypointBehaviour "SAFE";
        _wp setWaypointCombatMode "YELLOW";
    };
    private _cwp = _grp addWaypoint [_markerPos, 0];
    _cwp setWaypointType "CYCLE";
    _cwp setWaypointSpeed "LIMITED";
    _cwp setWaypointBehaviour "SAFE";
    _cwp setWaypointCombatMode "YELLOW";

    // Record in the garrison DB.
    private _entry = MISSION_CORE_GARRISON_DB getOrDefault [_markerName, [[], []]];
    (_entry select 0) pushBack _grp;
    MISSION_CORE_GARRISON_DB set [_markerName, _entry];

    MISSION_CORE_RECRUIT_RESULT = format ["Deployed %1 to %2 (-%3 MP)", _grpName, _markerName, _unitCost];
    publicVariable "MISSION_CORE_RECRUIT_RESULT";
};

// ---- vehicle add -------------------------------------------------------

// [_caller, _markerName, _vehClass, _kind, _cost]
// _kind: "tank" | "apc" | "gunTruck" | "mlrs_spg" | "mortar"
MISSION_CORE_fnc_serverAddVehicle = {
    params ["_caller", "_markerName", "_vehClass", "_kind", "_cost"];
    if (isNil "_caller" || { isNull _caller }) exitWith { };
    if (isNil "_cost") then { _cost = 0; };
    if (_vehClass == "") exitWith { };

    private _locIdx = MISSION_CORE_LOCATIONS findIf { (_x select 0) == _markerName };
    if (_locIdx < 0) exitWith { };
    private _loc = MISSION_CORE_LOCATIONS select _locIdx;
    private _markerPos = (_loc select 1) select 0;

    // Limits.
    private _proceed = true;
    private _lim = [_markerName, _kind] call MISSION_CORE_fnc_garrisonLimits;
    if !(_lim select 0) then {
        _proceed = false;
        MISSION_CORE_RECRUIT_RESULT = _lim select 1;
        publicVariable "MISSION_CORE_RECRUIT_RESULT";
    };

    // Manpower.
    if (_proceed && !([_cost] call MISSION_CORE_fnc_drawManpower)) then {
        _proceed = false;
        MISSION_CORE_RECRUIT_RESULT = "Not enough manpower!";
        publicVariable "MISSION_CORE_RECRUIT_RESULT";
    };
    if (!_proceed) exitWith { };

    // Tanks: the HQ toggle ("INSTANT TANK DELIVERY") decides HOW the tank reaches the marker:
    //   OFF (default): the tank is placed as a queued depot/port ORDER at the base cost (_cost,
    //                   normally 4 MP); a depot with parked stock or a port fills it on a later tick.
    //   ON: the tank is delivered INSTANTLY - physically spawned at the marker right now - at the
    //       2x premium cost (the client sends _cost = base * 2, normally 8 MP). Either way, a tank
    //       MUST be available in the armor pool (depot stock / port budget) - nothing is conjured.
    if (_kind == "tank") then {
        private _instantOn = (_markerName in (missionNamespace getVariable ["MISSION_CORE_PORT_PRIORITY", []]));
        // Refill books the BASE tank cost (4 MP) regardless of delivery mode - a rebuild charges 4x that.
        private _baseCost = (missionNamespace getVariable ["MISSION_CORE_RECRUIT_VEH_COSTS", createHashMap]) getOrDefault ["tank", 4];
        if (_instantOn) then {
            // The base _cost (already the full 2x premium) was drawn above; refund + abort if the
            // armor pool has nothing available to deliver.
            if (([WEST] call MISSION_CORE_fnc_poolTanksForSide) < 1) then {
                [_cost] call MISSION_CORE_fnc_refundManpower;
                MISSION_CORE_RECRUIT_RESULT = "No tank available in the armor pool for INSTANT delivery - wait for factories/ports to build tank points (turn INSTANT off for queued delivery).";
                publicVariable "MISSION_CORE_RECRUIT_RESULT";
            } else {
                private _spawnPos = _markerPos getPos [300, random 360];
                private _g = [WEST, _markerPos, _markerName, 1, _spawnPos, _vehClass, _baseCost] call MISSION_CORE_fnc_tankDeployAbstract;
                if (isNull _g) then {
                    [_cost] call MISSION_CORE_fnc_refundManpower;
                    MISSION_CORE_RECRUIT_RESULT = "Instant tank delivery failed - manpower refunded!";
                    publicVariable "MISSION_CORE_RECRUIT_RESULT";
                } else {
                    private _src = [WEST, _markerPos] call MISSION_CORE_fnc_consumePoolTankForSide;
                    MISSION_CORE_RECRUIT_RESULT = "Tank delivered INSTANTLY to " + _markerName + " (-" + str _cost + " MP, drawn from " + _src + ").";
                    publicVariable "MISSION_CORE_RECRUIT_RESULT";
                };
            };
            call MISSION_CORE_fnc_publishArmorPool;
            _proceed = false;
        } else {
            [_markerName, _markerPos, _vehClass, _baseCost] call MISSION_CORE_fnc_recruitTankToDepot;
            MISSION_CORE_RECRUIT_RESULT = "Tank order placed for " + _markerName + " (armor pool: " + str ([WEST] call MISSION_CORE_fnc_poolTanksForSide) + ") - awaiting delivery from depot/port (-" + str _cost + " MP).";
            publicVariable "MISSION_CORE_RECRUIT_RESULT";
            call MISSION_CORE_fnc_publishArmorPool;
            _proceed = false;
        };
    };
    if (!_proceed) exitWith { };

    // Armor pool gate: APC / SPG / MLRS recruits draw one tank from the armor pool - a tank must
    // be available (depot parked stock or a port tank budget) or there is nothing to deploy them
    // from. The pool point is consumed AFTER a successful spawn below.
    if (_kind == "apc" || _kind == "mlrs_spg") then {
        if (([WEST] call MISSION_CORE_fnc_poolTanksForSide) < 1) then {
            [_cost] call MISSION_CORE_fnc_refundManpower;
            MISSION_CORE_RECRUIT_RESULT = "No tank available in the armor pool to deploy an " + _kind + " - wait for factories/ports to build tank points.";
            publicVariable "MISSION_CORE_RECRUIT_RESULT";
            _proceed = false;
        };
    };
    if (!_proceed) exitWith { };

    // Spawn position near the marker center - PERMANENT RULE: recruited armor rolls out ON the
    // nearest road inside the marker, facing along it, instead of sitting in a field.
    private _pos = [_markerPos, [120, 120], 15] call MISSION_CORE_fnc_findVehiclePos;
    if (count _pos < 2) then { _pos = [_markerPos] call MISSION_CORE_fnc_ensureLandPos; };
    if (count _pos == 2) then { _pos pushBack 0; };

    private _isStatic = _vehClass isKindOf "StaticWeapon";
    private _veh = objNull;
    private _grp = grpNull;
    if (_isStatic) then {
        // Mortars are static and crew light - spawn the piece + a small crew group.
        _veh = createVehicle [_vehClass, [_pos] call MISSION_CORE_fnc_liftSpawn, [], 5, "CAN_COLLIDE"];
        _veh setVehicleAmmo 1;
        _grp = createVehicleCrew _veh;
    } else {
        _veh = createVehicle [_vehClass, [_pos] call MISSION_CORE_fnc_liftSpawn, [], 5, "CAN_COLLIDE"];
        _veh setDir ((getDir _veh) + 180);
        [_veh] call MISSION_CORE_fnc_alignVehicleToRoad;
        _grp = createVehicleCrew _veh;
    };
    if (isNull _veh) then {
        MISSION_CORE_RECRUIT_RESULT = "Failed to spawn vehicle!";
        publicVariable "MISSION_CORE_RECRUIT_RESULT";
        _proceed = false;
    };
    if (!_proceed) exitWith { };

    // Tag + origin.
    _grp setVariable ["MISSION_CORE_BLUFOR", true];
    _grp setVariable ["MISSION_CORE_GARRISON", true];
    _grp setVariable ["MISSION_CORE_ORIGIN_MARKER", _markerName];
    _grp setVariable ["MISSION_CORE_MARKER_CENTER", _markerPos];
    _grp setVariable ["MISSION_CORE_IDLE", false];
    _grp setVariable ["MISSION_CORE_ORDER", "defend"];
    // Refill bookkeeping: original cost + vehicle identity so a destroyed vehicle can be rebuilt.
    _grp setVariable ["MISSION_CORE_RECRUIT_COST", _cost];
    _grp setVariable ["MISSION_CORE_RECRUIT_VEH", [_vehClass, _kind]];
    _grp setBehaviour "SAFE";
    _grp setCombatMode "RED";
    _grp setSpeedMode "LIMITED";
    if (_kind == "tank") then { _grp setVariable ["MISSION_CORE_ARMOR_SLOT", "mbt"]; };
    if (_kind == "apc") then { _grp setVariable ["MISSION_CORE_ARMOR_SLOT", "mech"]; };
    if (isNil "MISSION_CORE_SPAWNED_GROUPS") then { MISSION_CORE_SPAWNED_GROUPS = []; };
    MISSION_CORE_SPAWNED_GROUPS pushBack _grp;

    // Add a GUARD/HOLD waypoint at the marker so it holds position.
    [_grp] call MISSION_CORE_fnc_clearGroupWaypoints;
    private _wp = _grp addWaypoint [_markerPos, 50];
    _wp setWaypointType "GUARD";
    _wp setWaypointBehaviour "SAFE";
    _wp setWaypointCombatMode "RED";
    _grp setCurrentWaypoint _wp;

    // MLRS/SPG/mortar (player-placed artillery) get an arty AI controller.
    if (_kind == "mlrs_spg" || _kind == "mortar") then {
        MISSION_CORE_PLAYER_ARTY set [_markerName, [_veh, _grp]];
        if (!(MISSION_CORE_PLAYER_ARTY getOrDefault ["_LOOP_RUNNING", false])) then {
            MISSION_CORE_PLAYER_ARTY set ["_LOOP_RUNNING", true];
            [] spawn MISSION_CORE_fnc_playerArtyLoop;
        };
    };

    // Record in the garrison DB.
    private _entry = MISSION_CORE_GARRISON_DB getOrDefault [_markerName, [[], []]];
    (_entry select 1) pushBack _veh;
    MISSION_CORE_GARRISON_DB set [_markerName, _entry];

    // The APC / SPG / MLRS recruited successfully - consume the armor pool point it needs.
    if (_kind == "apc" || _kind == "mlrs_spg") then {
        private _src = [WEST, _markerPos] call MISSION_CORE_fnc_consumePoolTankForSide;
        MISSION_CORE_RECRUIT_RESULT = format ["Deployed %1 to %2 (-%3 MP, armor pool source %4)", getText (configFile >> "CfgVehicles" >> _vehClass >> "displayName"), _markerName, _cost, _src];
    } else {
        MISSION_CORE_RECRUIT_RESULT = format ["Deployed %1 to %2 (-%3 MP)", getText (configFile >> "CfgVehicles" >> _vehClass >> "displayName"), _markerName, _cost];
    };
    call MISSION_CORE_fnc_publishArmorPool;
    publicVariable "MISSION_CORE_RECRUIT_RESULT";
};

// ---- remove ------------------------------------------------------------

// [_caller, _grpNetId]
MISSION_CORE_fnc_serverRemoveGroup = {
    params ["_caller", "_grpNetId"];
    if (_grpNetId == "") exitWith { };
    private _grp = objectFromNetId _grpNetId;
    if (isNull _grp) exitWith {
        MISSION_CORE_RECRUIT_RESULT = "Group already gone.";
        publicVariable "MISSION_CORE_RECRUIT_RESULT";
    };
    private _origin = _grp getVariable ["MISSION_CORE_ORIGIN_MARKER", ""];
    if (_origin != "") then {
        private _entry = MISSION_CORE_GARRISON_DB getOrDefault [_origin, [[], []]];
        _entry set [0, ((_entry select 0) - [_grp])];
        MISSION_CORE_GARRISON_DB set [_origin, _entry];
    };
    if (isNil "MISSION_CORE_SPAWNED_GROUPS") then { MISSION_CORE_SPAWNED_GROUPS = []; };
    MISSION_CORE_SPAWNED_GROUPS = MISSION_CORE_SPAWNED_GROUPS - [_grp];
    { deleteVehicle _x; } forEach units _grp;
    deleteGroup _grp;
    MISSION_CORE_RECRUIT_RESULT = "Garrison squad removed.";
    publicVariable "MISSION_CORE_RECRUIT_RESULT";
};

// [_caller, _vehNetId]
MISSION_CORE_fnc_serverRemoveVehicle = {
    params ["_caller", "_vehNetId"];
    if (_vehNetId == "") exitWith { };
    private _veh = objectFromNetId _vehNetId;
    if (isNull _veh) exitWith {
        MISSION_CORE_RECRUIT_RESULT = "Vehicle already gone.";
        publicVariable "MISSION_CORE_RECRUIT_RESULT";
    };
    private _origin = "";
    private _grp = grpNull;
    if (!(isNull (driver _veh))) then { _grp = group (driver _veh); };
    if (isNull _grp && { !(isNull (gunner _veh)) }) then { _grp = group (gunner _veh); };
    // Never delete a group that contains a real player.
    if (!isNull _grp && { { isPlayer _x } count (units _grp) > 0 }) exitWith {
        MISSION_CORE_RECRUIT_RESULT = "Cannot remove: a player is in this vehicle.";
        publicVariable "MISSION_CORE_RECRUIT_RESULT";
    };
    if (!isNull _grp) then { _origin = _grp getVariable ["MISSION_CORE_ORIGIN_MARKER", ""]; };
    if (_origin != "") then {
        private _entry = MISSION_CORE_GARRISON_DB getOrDefault [_origin, [[], []]];
        _entry set [1, ((_entry select 1) - [_veh])];
        MISSION_CORE_GARRISON_DB set [_origin, _entry];
    };
    if (isNil "MISSION_CORE_SPAWNED_GROUPS") then { MISSION_CORE_SPAWNED_GROUPS = []; };
    if (!isNull _grp) then {
        MISSION_CORE_SPAWNED_GROUPS = MISSION_CORE_SPAWNED_GROUPS - [_grp];
        { deleteVehicle _x; } forEach units _grp;
        deleteGroup _grp;
    };
    if (!isNull _veh) then { deleteVehicle _veh; };
    MISSION_CORE_RECRUIT_RESULT = "Vehicle removed.";
    publicVariable "MISSION_CORE_RECRUIT_RESULT";
};

// ---- garrison snapshot (client view) -----------------------------------

// Build and broadcast a flat, serializable summary of every BLUFOR marker's
// current garrison: men / group count / vehicle count plus netId + label
// lists so the client can display and issue removals. Hashmaps don't survive
// publicVariable reliably, so this is a flat array of marker entries:
//   [ [marker, men, groups, vehs, [[grpNetId,label]...], [[vehNetId,label]...]], ... ]
MISSION_CORE_fnc_garrisonRefresh = {
    if (isNil "MISSION_CORE_SPAWNED_GROUPS") then { MISSION_CORE_SPAWNED_GROUPS = []; };
    private _snapshot = [];
    private _markerNames = [];
    if (!isNil "MISSION_CORE_CACHED_POSITIONS") then {
        _markerNames = MISSION_CORE_CACHED_POSITIONS select { (_x select 4) == WEST } apply { _x select 0 };
    };
    {
        private _markerName = _x;
        private _grpEntries = [];
        private _vehEntries = [];
        private _vehList = [];
        private _men = 0;
        {
            if (!isNull _x && { _x getVariable ["MISSION_CORE_BLUFOR", false] } && { (_x getVariable ["MISSION_CORE_ORIGIN_MARKER", ""]) == _markerName }) then {
                private _aliveUnits = units _x select { alive _x };
                _men = _men + count _aliveUnits;
                _grpEntries pushBack [netId _x, format ["%1 men", count _aliveUnits]];
                {
                    private _v = vehicle _x;
                    if (_v != _x && { _v isKindOf "AllVehicles" } && { _vehList findIf { _x == _v } < 0 }) then {
                        _vehList pushBack _v;
                    };
                } forEach _aliveUnits;
            };
        } forEach MISSION_CORE_SPAWNED_GROUPS;
        {
            private _v = _x;
            _vehEntries pushBack [netId _v, getText (configFile >> "CfgVehicles" >> typeOf _v >> "displayName")];
        } forEach _vehList;
        _snapshot pushBack [_markerName, _men, count _grpEntries, count _vehEntries, _grpEntries, _vehEntries];
    } forEach _markerNames;
    MISSION_CORE_GARRISON_SNAPSHOT = _snapshot;
    publicVariable "MISSION_CORE_GARRISON_SNAPSHOT";
};

// ---- garrison refill (auto-rebuild on death) ---------------------------

// Server side of the REFILL checkbox. Sets the marker's membership so two rapid clicks / a menu
// refresh race can never desync the button and the server (absolute set, not flip).
MISSION_CORE_fnc_garrisonRefillSet = {
    params ["_caller", "_markerName", "_state"];
    if (isNil "_markerName" || _markerName == "") exitWith {};
    if (isNil "MISSION_CORE_GARRISON_REFILL") then { MISSION_CORE_GARRISON_REFILL = []; };
    _state = if (_state isEqualType true) then { _state } else { _state > 0 };
    private _i = MISSION_CORE_GARRISON_REFILL find _markerName;
    private _on = _i >= 0;
    if (_state && { !_on }) then {
        MISSION_CORE_GARRISON_REFILL pushBack _markerName;
        diag_log format ["GARRISON REFILL: ON for %1", _markerName];
    };
    if (!_state && { _on }) then {
        MISSION_CORE_GARRISON_REFILL deleteAt _i;
        diag_log format ["GARRISON REFILL: OFF for %1", _markerName];
    };
    publicVariable "MISSION_CORE_GARRISON_REFILL";
};

// Rebuild a wiped recruited squad at its marker (mirrors the spawn/tag/patrol block of
// serverGarrisonDeploy; no manpower/limit checks - refill already billed).
MISSION_CORE_fnc_garrisonRefillRespawnSquad = {
    params ["_markerName", "_loc", "_meta", "_cost"];
    _meta params ["_faction", "_catName", "_grpName", "_template"];
    private _markerPos = (_loc select 1) select 0;
    private _markerSize = if (count (_loc select 1) > 1) then { (_loc select 1) select 1 } else { [200, 200, 0] };
    private _markerDir = if (count (_loc select 1) > 2) then { (_loc select 1) select 2 } else { 0 };
    private _markerShape = if (count (_loc select 1) > 3) then { (_loc select 1) select 3 } else { "ELLIPSE" };
    private _spawnPos = [_markerPos, 0, 80, 10, 0, 0.5, 0] call BIS_fnc_findSafePos;
    if (count _spawnPos < 2) then { _spawnPos = _markerPos; };
    if (count _spawnPos == 2) then { _spawnPos pushBack 0; };
    private _cfgPath = configFile >> "CfgGroups" >> "West" >> _faction >> _catName >> _grpName;
    private _grp = [_spawnPos, WEST, _cfgPath] call BIS_fnc_spawnGroup;
    if (isNull _grp) then {
        _grp = createGroup WEST;
        { _grp createUnit [_x, _spawnPos, [], 10, "FORM"]; } forEach (_template select 1);
    };
    if (isNull _grp) exitWith { grpNull };
    // Pull the spawned squad's vehicles onto a road column near the marker.
    [_grp, _markerPos, _markerSize] call MISSION_CORE_fnc_alignGroupVehiclesToRoad;
    _grp setVariable ["MISSION_CORE_BLUFOR", true];
    _grp setVariable ["MISSION_CORE_GARRISON", true];
    _grp setVariable ["MISSION_CORE_ORIGIN_MARKER", _markerName];
    _grp setVariable ["MISSION_CORE_MARKER_CENTER", _markerPos];
    _grp setVariable ["MISSION_CORE_MARKER_SIZE", _markerSize];
    _grp setVariable ["MISSION_CORE_IDLE", false];
    _grp setVariable ["MISSION_CORE_ORDER", "defend"];
    _grp setVariable ["MISSION_CORE_RECRUIT_COST", _cost];
    _grp setVariable ["MISSION_CORE_RECRUIT_SQUAD", _meta];
    _grp setBehaviour "SAFE";
    _grp setCombatMode "YELLOW";
    _grp setSpeedMode "LIMITED";
    if (isNil "MISSION_CORE_SPAWNED_GROUPS") then { MISSION_CORE_SPAWNED_GROUPS = []; };
    MISSION_CORE_SPAWNED_GROUPS pushBack _grp;
    private _ma = if (count _markerSize > 0) then { (_markerSize select 0) max 50 } else { 200 };
    private _mb = if (count _markerSize > 1) then { (_markerSize select 1) max 50 } else { _ma };
    private _isRect = toUpper _markerShape == "RECTANGLE";
    // Real marker rotation lives in the location area (index 2), not the 2-element size array.
    private _mDir = _markerDir;
    [_grp] call MISSION_CORE_fnc_clearGroupWaypoints;
    private _unitCount = count units _grp;
    private _patrolCount = 3 + floor (_unitCount / 3);
    // Shape-aware patrol coverage: for a RECTANGLE/square marker, distribute positions uniformly
    // across the whole span (including the corners that a radial/circular pattern clips); ellipses
    // keep the radial spread. Both are rotated by the marker's true direction.
    for "_i" from 1 to _patrolCount do {
        private _ox = 0; private _oy = 0;
        if (_isRect) then {
            _ox = ((random 2) - 1) * _ma;
            _oy = ((random 2) - 1) * _mb;
        } else {
            private _ang = random 360;
            private _frac = (_i - 1) / (_patrolCount max 1);
            private _ratio = if (_frac < 0.25) then { 0.9 } else { if (_frac < 0.6) then { 0.6 + random 0.3 } else { random 0.5 } };
            _ox = _ratio * _ma * cos _ang;
            _oy = _ratio * _mb * sin _ang;
        };
        private _rx = _ox * cos _mDir - _oy * sin _mDir;
        private _ry = _ox * sin _mDir + _oy * cos _mDir;
        private _wpPos = [(_markerPos select 0) + _rx, (_markerPos select 1) + _ry, 0];
        private _wp = _grp addWaypoint [_wpPos, 30];
        _wp setWaypointType "MOVE";
        _wp setWaypointSpeed "LIMITED";
        _wp setWaypointBehaviour "SAFE";
        _wp setWaypointCombatMode "YELLOW";
    };
    private _cwp = _grp addWaypoint [_markerPos, 0];
    _cwp setWaypointType "CYCLE";
    _cwp setWaypointSpeed "LIMITED";
    _cwp setWaypointBehaviour "SAFE";
    _cwp setWaypointCombatMode "YELLOW";
    private _entry = MISSION_CORE_GARRISON_DB getOrDefault [_markerName, [[], []]];
    (_entry select 0) pushBack _grp;
    MISSION_CORE_GARRISON_DB set [_markerName, _entry];
    _grp
};

// Rebuild a destroyed recruited vehicle (mirrors the spawn/tag block of serverAddVehicle).
MISSION_CORE_fnc_garrisonRefillRespawnVehicle = {
    params ["_markerName", "_loc", "_vehClass", "_kind", "_cost"];
    private _markerPos = (_loc select 1) select 0;
    private _pos = [_markerPos, [120, 120], 15] call MISSION_CORE_fnc_findVehiclePos;
    if (count _pos < 2) then { _pos = [_markerPos] call MISSION_CORE_fnc_ensureLandPos; };
    if (count _pos == 2) then { _pos pushBack 0; };
    private _isStatic = _vehClass isKindOf "StaticWeapon";
    private _veh = objNull;
    private _grp = grpNull;
    if (_isStatic) then {
        _veh = createVehicle [_vehClass, [_pos] call MISSION_CORE_fnc_liftSpawn, [], 5, "CAN_COLLIDE"];
        _veh setVehicleAmmo 1;
        _grp = createVehicleCrew _veh;
    } else {
        _veh = createVehicle [_vehClass, [_pos] call MISSION_CORE_fnc_liftSpawn, [], 5, "CAN_COLLIDE"];
        _veh setDir ((getDir _veh) + 180);
        [_veh] call MISSION_CORE_fnc_alignVehicleToRoad;
        _grp = createVehicleCrew _veh;
    };
    if (isNull _veh || isNull _grp) exitWith { objNull };
    _grp setVariable ["MISSION_CORE_BLUFOR", true];
    _grp setVariable ["MISSION_CORE_GARRISON", true];
    _grp setVariable ["MISSION_CORE_ORIGIN_MARKER", _markerName];
    _grp setVariable ["MISSION_CORE_MARKER_CENTER", _markerPos];
    _grp setVariable ["MISSION_CORE_IDLE", false];
    _grp setVariable ["MISSION_CORE_ORDER", "defend"];
    _grp setVariable ["MISSION_CORE_RECRUIT_COST", _cost];
    _grp setVariable ["MISSION_CORE_RECRUIT_VEH", [_vehClass, _kind]];
    if (_kind == "tank") then { _grp setVariable ["MISSION_CORE_ARMOR_SLOT", "mbt"]; };
    if (_kind == "apc") then { _grp setVariable ["MISSION_CORE_ARMOR_SLOT", "mech"]; };
    _grp setBehaviour "SAFE";
    _grp setCombatMode "RED";
    _grp setSpeedMode "LIMITED";
    if (isNil "MISSION_CORE_SPAWNED_GROUPS") then { MISSION_CORE_SPAWNED_GROUPS = []; };
    MISSION_CORE_SPAWNED_GROUPS pushBack _grp;
    [_grp] call MISSION_CORE_fnc_clearGroupWaypoints;
    private _wp = _grp addWaypoint [_markerPos, 50];
    _wp setWaypointType "GUARD";
    _wp setWaypointBehaviour "SAFE";
    _wp setWaypointCombatMode "RED";
    _grp setCurrentWaypoint _wp;
    if (_kind == "mlrs_spg" || _kind == "mortar") then {
        if (isNil "MISSION_CORE_PLAYER_ARTY") then { MISSION_CORE_PLAYER_ARTY = createHashMap; };
        MISSION_CORE_PLAYER_ARTY set [_markerName, [_veh, _grp]];
        if (!(MISSION_CORE_PLAYER_ARTY getOrDefault ["_LOOP_RUNNING", false])) then {
            MISSION_CORE_PLAYER_ARTY set ["_LOOP_RUNNING", true];
            [] spawn MISSION_CORE_fnc_playerArtyLoop;
        };
    };
    private _entry = MISSION_CORE_GARRISON_DB getOrDefault [_markerName, [[], []]];
    (_entry select 1) pushBack _veh;
    MISSION_CORE_GARRISON_DB set [_markerName, _entry];
    _veh
};

// Rebuild a destroyed delivered tank via the normal deploy path (no armor-pool point consumed -
// the replacement was already paid for once; refill only bills 4x manpower). The deploy helper adds
// a Killed -> requestArmorReinforcement handler; REFILL owns this tank's replacement already, so
// that handler is stripped to avoid a second, free replacement stacking on top of the paid rebuild.
MISSION_CORE_fnc_garrisonRefillRespawnTank = {
    params ["_markerName", "_loc", "_vehClass", "_cost"];
    private _markerPos = (_loc select 1) select 0;
    private _grp = [WEST, _markerPos, _markerName, 1, (_markerPos getPos [300, random 360]), _vehClass, _cost] call MISSION_CORE_fnc_tankDeployAbstract;
    if (!isNull _grp) then {
        {
            private _v = vehicle _x;
            if (_v != _x && { _v isKindOf "AllVehicles" }) then { _v removeAllEventHandlers "Killed"; };
        } forEach units _grp;
    };
    _grp
};

// One 10s tick: sweep refilled markers for wiped squads / destroyed vehicles, queue rebuild jobs,
// then process the queue (respawn only when no enemy is within 1000m, paying 4x MP silently).
MISSION_CORE_fnc_garrisonRefillLoop = {
    diag_log "GARRISON REFILL: loop started";
    while { true } do {
        sleep 10;
        if (isNil "MISSION_CORE_GARRISON_REFILL") then { MISSION_CORE_GARRISON_REFILL = []; };
        if (isNil "MISSION_CORE_REFILL_PENDING") then { MISSION_CORE_REFILL_PENDING = []; };
        if (isNil "MISSION_CORE_GARRISON_DB") then { MISSION_CORE_GARRISON_DB = createHashMap; };
        if (isNil "MISSION_CORE_SPAWNED_GROUPS") then { MISSION_CORE_SPAWNED_GROUPS = []; };
        if (isNil "MISSION_CORE_LOCATIONS") then { continue; };
        if (count MISSION_CORE_GARRISON_REFILL == 0) then { continue; };

        // ---- sweep refilled markers for wiped squads + dead vehicles ----
        {
            private _mName = _x;
            private _entry = MISSION_CORE_GARRISON_DB getOrDefault [_mName, []];
            if (count _entry < 2) then { continue; };
            for "_gi" from (count (_entry select 0) - 1) to 0 step -1 do {
                private _grp = (_entry select 0) select _gi;
                if (isNull _grp) then { (_entry select 0) deleteAt _gi; continue; };
                if (({ alive _x } count units _grp) > 0) then { continue; };
                private _meta = _grp getVariable ["MISSION_CORE_RECRUIT_SQUAD", []];
                private _cost = _grp getVariable ["MISSION_CORE_RECRUIT_COST", 0];
                (_entry select 0) deleteAt _gi;
                if (count _meta < 4) then { continue; };
                MISSION_CORE_SPAWNED_GROUPS = MISSION_CORE_SPAWNED_GROUPS - [_grp];
                { deleteVehicle _x; } forEach units _grp;
                deleteGroup _grp;
                MISSION_CORE_REFILL_PENDING pushBack [_mName, "sq", _meta, round (_cost * 4)];
                diag_log format ["GARRISON REFILL: %1 squad wiped - queued rebuild (4x %2 MP)", _mName, _cost];
            };
            for "_vi" from (count (_entry select 1) - 1) to 0 step -1 do {
                private _v = (_entry select 1) select _vi;
                if (isNull _v) then { (_entry select 1) deleteAt _vi; continue; };
                if (alive _v) then { continue; };
                private _vGrp = grpNull;
                if (!(isNull (driver _v))) then { _vGrp = group (driver _v); };
                if (isNull _vGrp && { !(isNull (gunner _v)) }) then { _vGrp = group (gunner _v); };
                private _meta = if (!isNull _vGrp) then { _vGrp getVariable ["MISSION_CORE_RECRUIT_VEH", []] } else { [] };
                private _cost = if (!isNull _vGrp) then { _vGrp getVariable ["MISSION_CORE_RECRUIT_COST", 0] } else { 0 };
                (_entry select 1) deleteAt _vi;
                if (count _meta == 0) then { continue; };
                MISSION_CORE_REFILL_PENDING pushBack [_mName, _meta select 1, _meta select 0, round (_cost * 4)];
                diag_log format ["GARRISON REFILL: %1 %2 destroyed - queued rebuild (4x %3 MP)", _mName, _meta select 1, _cost];
            };
        } forEach MISSION_CORE_GARRISON_REFILL;

        // ---- process queued rebuild jobs ----
        if (count MISSION_CORE_REFILL_PENDING == 0) then { continue; };
        private _keep = [];
        {
            _x params ["_mName", "_kind", "_payload", "_cost4"];
            if !(_mName in MISSION_CORE_GARRISON_REFILL) then { continue; };
            private _locIdx = MISSION_CORE_LOCATIONS findIf { (_x select 0) == _mName };
            if (_locIdx < 0) then { continue; };
            private _loc = MISSION_CORE_LOCATIONS select _locIdx;
            private _markerPos = (_loc select 1) select 0;
            // Only rebuild when the marker is far from any enemy so units don't materialize mid-fight.
            if (allUnits findIf { side _x == EAST && { alive _x } && { _x distance _markerPos < 1000 } } >= 0) then {
                _keep pushBack _x;
                continue;
            };
            // Pay / wait: charge the 4x upfront, retry silently while short.
            if !([_cost4 max 0] call MISSION_CORE_fnc_drawManpower) then { _keep pushBack _x; continue; };
            private _done = false;
            private _baseCost = round ((_cost4 max 0) / 4);
            switch (_kind) do {
                case "sq": {
                    _done = !isNull ([_mName, _loc, _payload, _baseCost] call MISSION_CORE_fnc_garrisonRefillRespawnSquad);
                };
                case "tank": {
                    _done = !isNull ([_mName, _loc, _payload, _baseCost] call MISSION_CORE_fnc_garrisonRefillRespawnTank);
                };
                default {
                    _done = !isNull ([_mName, _loc, _payload, _kind, _baseCost] call MISSION_CORE_fnc_garrisonRefillRespawnVehicle);
                };
            };
            if (_done) then {
                diag_log format ["GARRISON REFILL: %1 rebuilt a %2 (-%3 MP)", _mName, _kind, _cost4];
            } else {
                [_cost4] call MISSION_CORE_fnc_refundManpower;
                _keep pushBack _x;
            };
        } forEach MISSION_CORE_REFILL_PENDING;
        MISSION_CORE_REFILL_PENDING = _keep;
    };
};

// ---- under-attack notifier --------------------------------------------

// Watches every BLUFOR marker. When enemy units are within 800m AND the marker's ALIVE recruited
// defenders have dropped below 2, the whole lobby gets a systemChat warning (throttled to once per
// 120s per marker). Purely informational - BLUFOR defense is 100% player-driven.
MISSION_CORE_fnc_garrisonWarnLoop = {
    diag_log "GARRISON WATCH: under-attack notifier started";
    if (isNil "MISSION_CORE_UNDER_ATTACK_COOLDOWN") then { MISSION_CORE_UNDER_ATTACK_COOLDOWN = createHashMap; };
    while { true } do {
        sleep 8;
        if (isNil "MISSION_CORE_LOCATIONS") then { continue; };
        if (isNil "MISSION_CORE_SPAWNED_GROUPS") then { MISSION_CORE_SPAWNED_GROUPS = []; };
        // Snapshot enemy units once per tick instead of per WEST marker below.
        private _snapEnemies = allUnits select { side _x == EAST && { alive _x } };
        {
            private _loc = _x;
            if ((_loc select 5) != WEST) then { continue; };
            private _mName = _loc select 0;
            private _mPos = ((_x select 1) select 0);
            private _enemy = _snapEnemies select { _x distance _mPos < 800 };
            if (count _enemy == 0) then { continue; };
            private _aliveDef = 0;
            {
                if (!isNull _x && { _x getVariable ["MISSION_CORE_BLUFOR", false] } && { (_x getVariable ["MISSION_CORE_ORIGIN_MARKER", ""]) == _mName }) then {
                    _aliveDef = _aliveDef + ({ alive _x } count units _x);
                };
            } forEach MISSION_CORE_SPAWNED_GROUPS;
            if (_aliveDef >= 2) then { continue; };
            if (time >= (MISSION_CORE_UNDER_ATTACK_COOLDOWN getOrDefault [_mName, 0])) then {
                MISSION_CORE_UNDER_ATTACK_COOLDOWN set [_mName, time + 120];
                private _msg = format ["[GARRISON] %1 UNDER ATTACK - %2 defender(s) vs %3 enemy nearby!", _mName, _aliveDef, count _enemy];
                systemChat _msg;
                diag_log _msg;
            };
        } forEach MISSION_CORE_LOCATIONS;
    };
};

// ---- player artillery AI ----------------------------------------------

// One loop monitors every player-placed artillery piece and shells the
// nearest spotted enemy near its marker's range. Reuses fn_artillery targets.
MISSION_CORE_fnc_playerArtyLoop = {
    private _running = true;
    while { _running } do {
        sleep 8;
        if (isNil "MISSION_CORE_PLAYER_ARTY") then { MISSION_CORE_PLAYER_ARTY = createHashMap; };
        private _anyLive = false;
        {
            private _key = _x;
            if (_key find "_LOOP" == 0) then { continue; };
            private _data = _y;
            _data params ["_veh", "_grp"];
            if (isNull _veh || { !(alive _veh) } || { isNull _grp } || { { alive _x } count units _grp == 0 }) then {
                MISSION_CORE_PLAYER_ARTY deleteAt _key;
                continue;
            };
            _anyLive = true;
            // Very light engagement: shell a spotted enemy target within weapon range. An SPG/MLRS
            // that carries a laser-guided round (weaponLockSystem flag 4) fires it at whatever laser
            // dot a friendly designator is painting - exact dot, single shot. Mortars never do this.
            private _lastFire = _veh getVariable ["MISSION_CORE_ARTY_LAST_FIRE", 0];
            if (time - _lastFire > 120) then {
                private _enemy = if (side _veh == WEST) then { EAST } else { WEST };
                private _laserMags = [];
                if (!(_veh isKindOf "StaticMortar")) then { _laserMags = [_veh] call MISSION_CORE_fnc_artilleryLaserMags; };
                private _laserTarget = if (count _laserMags > 0) then {
                    [side _veh, _veh, 10000] call MISSION_CORE_fnc_artilleryLaserTarget;
                } else { [] };
                private _preferLaser = count _laserTarget > 0;
                private _target = if (_preferLaser) then { _laserTarget } else { [_veh, _enemy] call MISSION_CORE_fnc_artilleryTarget; };
                if (!_preferLaser && { count _target == 0 }) then {
                    // Fall back to shelling an enemy-held marker.
                    _target = [_veh, _enemy] call MISSION_CORE_fnc_artilleryMarkerTarget;
                };
                if (count _target > 0) then {
                    private _mag = [_veh, _preferLaser] call MISSION_CORE_fnc_pickArtilleryMag;
                    if (count _mag > 0) then {
                        private _cmdr = leader _grp;
                        if (!(isNull _cmdr) && { alive _cmdr }) then {
                            _cmdr doArtilleryFire [_target, _mag select 0, if (_preferLaser) then { 1 } else { 3 }];
                            _veh setVariable ["MISSION_CORE_ARTY_LAST_FIRE", time];
                            diag_log format ["PLAYER ARTY: %1 fired at %2 (%3)", _veh, _target, if (_preferLaser) then { "laser-adjusted" } else { "spot/marker" }];
                        };
                    };
                };
            };
        } forEach MISSION_CORE_PLAYER_ARTY;
        if (!_anyLive) then {
            MISSION_CORE_PLAYER_ARTY set ["_LOOP_RUNNING", false];
            _running = false;
        };
    };
};
