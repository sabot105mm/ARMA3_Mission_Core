// =====================================================================
// RECRUIT SERVER (GARRISON MANAGEMENT)
//
// Server-authoritative spawning for the GARRISON recruit tab. Players
// send spawn/remove requests from the client menu via remoteExec; this
// file validates manpower + per-marker limits, spawns squads and
// vehicles with correct crew/origin tracking, keeps a per-marker garrison
// database, and registers player-placed artillery with the per-side arty
// controller (fnc\commander\fn_artyController.sqf).
//
// Runs ONLY on the server (compiled in fn_init.sqf).
// =====================================================================

if (isNil "MISSION_CORE_GARRISON_DB") then { MISSION_CORE_GARRISON_DB = createHashMap; };
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

// REAL SAFE SPAWN FOR A GARRISON SQUAD.
//
// Both recruit spawns used BIS_fnc_findSafePos with condition 0, which is weaker than it looks:
// waterMode 0 still PERMITS water inside the inner 50% radius, and the condition argument is what
// is supposed to say "and not on top of an enemy" - passing 0 says nothing. So a marker could be
// rebuilt straight into the assault that had just wiped it, or onto a shoreline, and the squad
// would die again on the next tick. That is the "[GARRISON] hq_4 UNDER ATTACK - 0 defender(s)"
// warning repeating forever: the rebuild happens, the squad dies, the marker never heals.
//
// A deterministic ring search around the marker, strictest rung first, so every rung states its
// own rule and the chosen spot is reproducible in the log. Dry test mirrors isDryPos - the spot
// itself plus 7 ring probes - because a spawn on the shoreline is a drowned spawn. Enemy
// definition matches garrisonWarnLoop (EAST against a BLUFOR garrison). The angle is jittered
// inside each 22.5 deg sector so repeat rebuilds do not stack on the identical spot.
MISSION_CORE_fnc_garrisonSafeSpawnPos = {
    params ["_center", ["_ring", 60], ["_minEnemyDist", 220]];
    private _enemies = allUnits select { side _x == EAST && { alive _x } };
    private _isDry = {
        params ["_p"];
        if !(_p isEqualType [] || { _p isEqualType objNull }) exitWith { false };
        private _ok = true;
        for "_i" from 0 to 7 do {
            if (surfaceIsWater (_p getPos [7, _i * 45])) then { _ok = false; };
        };
        // Dry ground is still not a place a man can stand: a boulder is CfgTerrain class HIDE, so
        // the old ROCK-style filters never saw one and garrisons kept spawning inside rock faces.
        if (_ok && { !([_p, 8] call MISSION_CORE_fnc_isClearOfTerrain) }) then { _ok = false; };
        _ok
    };
    // Rungs, strictest first: [radius, minEnemyDist, requireDry]. Rung 2 relaxes the enemy
    // distance because a marker under fire has no dry spot 220m from the enemy - insisting on it
    // would push the squad outside its own garrison. Rung 4 drops the dry test and lets
    // ensureLandPos have the final word.
    private _ladders = [[_ring, _minEnemyDist, true], [floor (_ring * 1.5), 60, true], [floor (_ring * 1.5), 0, true], [_ring * 2, 0, false]];
    private _pos = [];
    private _usedRung = -1;
    for "_l" from 0 to (count _ladders) - 1 do {
        if (count _pos >= 2) then { break; };
        private _r = _ladders select _l;
        private _rad = _r select 0;
        private _minE = _r select 1;
        private _needDry = _r select 2;
        for "_i" from 0 to 15 do {
            private _cand = _center getPos [_rad, (_i * 22.5) + random 22.5];
            private _ok = true;
            if (_needDry && { !(_cand call _isDry) }) then { _ok = false; };
            if (_ok && { count (_enemies select { _x distance _cand < _minE }) > 0 }) then { _ok = false; };
            if (_ok) then { _pos = _cand; _usedRung = _l; break; };
        };
    };
    if (count _pos < 2) then { _pos = [_center] call MISSION_CORE_fnc_ensureLandPos; _usedRung = 4; };
    if (count _pos == 2) then { _pos pushBack 0; };
    if (count _pos >= 3) then { _pos setDir (random 360); };
    diag_log format ["GARRISON SPAWN: safe pos rung %1 at %2 (enemies within %3m: %4)", _usedRung, mapGridPosition _pos, _minEnemyDist, count (_enemies select { _x distance _pos < _minEnemyDist })];
    _pos
};

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

// SERVER-SIDE recruit gate. The client broadcasts MISSION_CAN_RECRUIT only to grey its own menu;
// the server recomputes the same test here so a client cannot authorize a spawn/spend by flipping
// its own variable. True when the unit is inside a BLUFOR marker area (marker real shape/rotation).
// [_unit] call MISSION_CORE_fnc_serverCallerCanRecruit;
MISSION_CORE_fnc_serverCallerCanRecruit = {
    params ["_unit"];
    if (isNull _unit) exitWith { false };
    if (isNil "MISSION_CORE_LOCATIONS") exitWith { false };
    private _near = false;
    {
        if ((_x select 5) == WEST) then {
            if (_unit inArea (_x select 0)) exitWith { _near = true; };
        };
    } forEach MISSION_CORE_LOCATIONS;
    _near
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
            //    The start-pool bonus (startTanks tune key) also fills here, so a fresh mission with
            //    no depot stock yet still delivers queued orders from the testing pool.
            if (([WEST] call MISSION_CORE_fnc_poolTanksForSide) >= 1) then {
                private _src = [WEST, _mPos] call MISSION_CORE_fnc_consumePoolTankForSide;
                if (_src != "") then {
                    private _spawnPos = _mPos getPos [300, random 360];
                    private _g = [WEST, _mPos, _mName, 1, _spawnPos, _vCls, _cost] call MISSION_CORE_fnc_tankDeployAbstract;
                    if (!isNull _g) then {
                        _filled = true;
                        diag_log format ["RECRUIT TANK: %1 delivered a tank to %2 (armor pool point consumed)", _src, _mName];
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
    if !([_caller] call MISSION_CORE_fnc_serverCallerCanRecruit) exitWith {
        MISSION_CORE_RECRUIT_RESULT = "Too far from base.";
        publicVariable "MISSION_CORE_RECRUIT_RESULT";
    };

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
    private _spawnPos = [_markerPos] call MISSION_CORE_fnc_garrisonSafeSpawnPos;
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

// ---- player squad recruit ----------------------------------------------

// Spawn ONE recruited soldier into the CALLER's own group, server-side. The recruit PLAYER
// tab used to createUnit on the clicking client and deduct manpower with a client-side
// publicVariable; both are server-owned now, so nothing is spawned by a client any more.
// The unit is born in a throwaway group on the server and joined to the player group - the
// join moves it into a player-owned group, which transfers its locality to the player's
// client so they can command it normally. [player, className]
MISSION_CORE_fnc_serverRecruitPlayerUnit = {
    params ["_caller", "_class"];
    if (isNil "_caller" || { isNull _caller } || { !isPlayer _caller } || { !(alive _caller) }) exitWith {};
    if (_class == "") exitWith {};
    if !([_caller] call MISSION_CORE_fnc_serverCallerCanRecruit) exitWith {
        [_caller, "Too far from base."] call MISSION_CORE_fnc_assaultServerHint;
    };

    private _costPer = if (isNil "MISSION_CORE_MANPOWER_PER_UNIT") then { 10 } else { MISSION_CORE_MANPOWER_PER_UNIT };
    if (!([_costPer] call MISSION_CORE_fnc_drawManpower)) exitWith {
        [_caller, "Not enough manpower!"] call MISSION_CORE_fnc_assaultServerHint;
    };

    private _spawnPos = getPosATL _caller;
    if (count _spawnPos == 2) then { _spawnPos pushBack 0; };
    private _tmpGrp = createGroup (side _caller);
    private _unit = _tmpGrp createUnit [_class, _spawnPos, [], 0, "FORM"];

    private _pGrp = group _caller;
    if (isNull _unit || { isNull _pGrp }) exitWith {
        [_costPer] call MISSION_CORE_fnc_refundManpower;
        if (!isNull _tmpGrp) then { deleteGroup _tmpGrp; };
        [_caller, "Failed to spawn unit."] call MISSION_CORE_fnc_assaultServerHint;
    };

    [_unit] joinSilent _pGrp;
    if (count units _tmpGrp == 0) then { deleteGroup _tmpGrp; };
    [_caller, format ["Recruited %1 (-%2 MP)", _class, _costPer]] call MISSION_CORE_fnc_assaultServerHint;
};

// ---- vehicle add -------------------------------------------------------

// The actual marker spawn for a recruited vehicle (the old tail of serverAddVehicle). Called either
// immediately by serverAddVehicle or later by the recruit spawn queue once a safe spot frees.
// Manpower was already charged by the caller; a failed spawn refunds it here.
MISSION_CORE_fnc_serverAddVehicleSpawnNow = {
    params ["_caller", "_markerName", "_markerPos", "_vehClass", "_kind", "_cost"];
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
        _veh = [_vehClass, _pos] call MISSION_CORE_fnc_safeVehicleSpawn;
        if (!isNull _veh) then { _veh setVehicleAmmo 1; };
    } else {
        _veh = [_vehClass, _pos] call MISSION_CORE_fnc_safeVehicleSpawn;
    };
    if (isNull _veh) exitWith {
        // No clean spot right now - do NOT force a stacked spawn. Put the request back on the
        // marker's waiting list so it deploys the moment a spot frees. Manpower stays charged.
        if (isNil "MISSION_CORE_RECRUIT_VEH_QUEUE") then { MISSION_CORE_RECRUIT_VEH_QUEUE = createHashMap; };
        private _q = MISSION_CORE_RECRUIT_VEH_QUEUE getOrDefault [_markerName, []];
        _q pushBack ["MISSION_CORE_fnc_serverAddVehicleSpawnNow", [_caller, _markerName, _markerPos, _vehClass, _kind, _cost], _caller, time, "MISSION_CORE_fnc_recruitMarkerSpotClear", [_markerName]];
        MISSION_CORE_RECRUIT_VEH_QUEUE set [_markerName, _q];
        MISSION_CORE_RECRUIT_RESULT = format ["No safe spawn spot free at %1 - the %2 is still queued.", _markerName, _kind];
        publicVariable "MISSION_CORE_RECRUIT_RESULT";
    };
    _grp = createVehicleCrew _veh;
    if (isNull _grp) exitWith { objNull };

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

    // MLRS/SPG/mortar (player-placed artillery) join the per-side arty controller as a GARRISON
    // piece defending this marker (fires only on known enemies inside its footprint).
    if (_kind == "mlrs_spg" || _kind == "mortar") then {
        [_veh, _grp, WEST, "garrison", _markerName, []] call MISSION_CORE_fnc_artyRegister;
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

// [_caller, _markerName, _vehClass, _kind, _cost]
// _kind: "tank" | "apc" | "gunTruck" | "mlrs_spg" | "mortar"
MISSION_CORE_fnc_serverAddVehicle = {
    params ["_caller", "_markerName", "_vehClass", "_kind", "_cost"];
    if (isNil "_caller" || { isNull _caller }) exitWith { };
    if (isNil "_cost") then { _cost = 0; };
    if (_vehClass == "") exitWith { };
    if !([_caller] call MISSION_CORE_fnc_serverCallerCanRecruit) exitWith {
        MISSION_CORE_RECRUIT_RESULT = "Too far from base.";
        publicVariable "MISSION_CORE_RECRUIT_RESULT";
    };

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

    // Queue gate: if every cached safe spot for this marker has armor on or around it, defer the
    // spawn onto the marker's waiting list instead of stacking a new vehicle on an occupied spot.
    // Manpower is already charged; the queue drains one vehicle at a time as spots free up.
    private _spawned = [_markerName, "MISSION_CORE_fnc_serverAddVehicleSpawnNow", [_caller, _markerName, _markerPos, _vehClass, _kind, _cost], _caller] call MISSION_CORE_fnc_queueRecruitVehicleSpawn;
    if (!_spawned) then {
        MISSION_CORE_RECRUIT_RESULT = format ["Safe spawn spots at %1 are occupied - the %2 is queued and will deploy when one frees.", _markerName, _kind];
        publicVariable "MISSION_CORE_RECRUIT_RESULT";
    };
};

// ---- remove ------------------------------------------------------------

// [_caller, _grpNetId]
MISSION_CORE_fnc_serverRemoveGroup = {
    params ["_caller", "_grpNetId"];
    if (_grpNetId == "") exitWith { };
    if !([_caller] call MISSION_CORE_fnc_serverCallerCanRecruit) exitWith {
        MISSION_CORE_RECRUIT_RESULT = "Too far from base.";
        publicVariable "MISSION_CORE_RECRUIT_RESULT";
    };
    private _grp = groupFromNetId _grpNetId;
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
    if !([_caller] call MISSION_CORE_fnc_serverCallerCanRecruit) exitWith {
        MISSION_CORE_RECRUIT_RESULT = "Too far from base.";
        publicVariable "MISSION_CORE_RECRUIT_RESULT";
    };
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
    private _spawnPos = [_markerPos] call MISSION_CORE_fnc_garrisonSafeSpawnPos;
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
        _veh = [_vehClass, _pos] call MISSION_CORE_fnc_safeVehicleSpawn;
        if (!isNull _veh) then { _veh setVehicleAmmo 1; };
    } else {
        _veh = [_vehClass, _pos] call MISSION_CORE_fnc_safeVehicleSpawn;
    };
    if (isNull _veh) exitWith { objNull };
    _grp = createVehicleCrew _veh;
    if (isNull _grp) exitWith { objNull };
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
        [_veh, _grp, WEST, "garrison", _markerName, []] call MISSION_CORE_fnc_artyRegister;
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

// Register an assault-tab SPG/MLRS piece into the per-side arty controller as an ASSAULT piece
// with an explicit target. _veh arrives as a netId string from the client (the deploy happens
// client-side); resolve it here.
MISSION_CORE_fnc_serverRegisterAssaultArty = {
    params ["_veh", "_targetPos"];
    if (_veh isEqualType "") then { _veh = objectFromNetId _veh; };
    if (isNull _veh) exitWith {};
    private _crew = crew _veh;
    if (count _crew == 0) then {
        private _cmdr = driver _veh;
        if (isNull _cmdr) then { _cmdr = gunner _veh; };
        if (isNull _cmdr) exitWith {};
        _crew = units _cmdr;
    };
    if (count _crew == 0) exitWith {};

    private _grp = group (_crew select 0);
    if (isNull _grp) exitWith {};
    [_veh, _grp, WEST, "assault", "", _targetPos] call MISSION_CORE_fnc_artyRegister;
    diag_log format ["ARTY CTRL: assault piece %1 registered on target %2", _veh, _targetPos];
};

// Server-safe copies of the client standoff helpers (the loop runs on the server only; fn_recruit.sqf
// copies are not compiled there). Same behavior: an assault piece wants a real 2D aim position.
MISSION_CORE_fnc_isValidArtyAim = {
    params ["_aimAt"];
    if (isNil "_aimAt" || { typeName _aimAt != "ARRAY" }) exitWith { false };
    private _c = count _aimAt;
    if (_c < 2) exitWith { false };
    private _fake = _aimAt findIf { !(_x isEqualType 0) };
    _fake == -1
};

// Nearest BLUFOR marker (owner == WEST) to a reference position - the "best standoff" a piece parks
// on. Mirrors the client fn_recruit.sqf helper using the server-visible MISSION_CORE_LOCATIONS.
// Optional _minDist skips the reference's own marker so run-away relocation actually displaces.
// NAMED distinct from the client helper (MISSION_CORE_fnc_bluforStandoff) so a hosted game's single
// namespace never gets one copy silently overwriting the other.
MISSION_CORE_fnc_serverArtyStandoff = {
    params ["_refPos", ["_minDist", -1], ["_aimAt", []], ["_aimMinR", 0]];
    private _best = [0, 0, 0];
    private _bestD = 1e10;
    if (isNil "MISSION_CORE_LOCATIONS") exitWith { _best };
    {
        if ((_x select 5) == WEST) then {
            private _c = (_x select 1) select 0;
            if (_minDist > 0 && { _c distance2D _refPos < _minDist }) then { continue; };
            // The relocated spot must also keep the piece's minimum ballistic range from the aim
            // target, or the next salvo would be refused again. No qualifying marker -> stay put.
            if (_aimMinR > 0 && { count _aimAt >= 2 && { _c distance2D _aimAt < _aimMinR } }) then { continue; };
            private _d = _c distance2D _refPos;
            if (_d < _bestD) then { _bestD = _d; _best = _c; };
        };
    } forEach MISSION_CORE_LOCATIONS;
    _best
};

// Server-side mirror of the client fn_assaultArtyMinRange: the minimum ballistic range a single
// artillery piece can lay its rounds at - the standoff must sit at least this far from the target
// or the gun barks "Invalid coordinates. Cease fire." MLRS/rocket pieces need >= 1000m; SPG
// howitzers 825m. Unlike class-name heuristics, the split is read from the ROUNDS the vehicle
// actually carries: resolve each magazine's CfgAmmo via the same turret-walk as the laser/GPS mag
// finders, and any rocket/missile round (simulation Rocket*/Missile*) marks the piece as
// long-minimum-range - classified by what it throws, never by its model string.
MISSION_CORE_fnc_serverArtyMinRange = {
    params ["_veh"];
    private _found = false;
    private _scanTurret = {
        params ["_turretCfg"];
        {
            private _weap = configFile >> "CfgWeapons" >> _x;
            {
                private _ammoClass = getText (configFile >> "CfgMagazines" >> _x >> "ammo");
                if (_ammoClass != "") then {
                    private _sim = toLower (getText (configFile >> "CfgAmmo" >> _ammoClass >> "simulation"));
                    if (_sim find "rocket" > -1 || { _sim find "missile" > -1 }) exitWith { _found = true; };
                };
            } forEach (getArray (_weap >> "magazines"));
            if (_found) exitWith {};
        } forEach (getArray (_turretCfg >> "weapons"));
        if (_found) exitWith {};
        {
            [_x] call _scanTurret;
            if (_found) exitWith {};
        } forEach ("true" configClasses (_turretCfg >> "turrets"));
    };
    {
        [_x] call _scanTurret;
        if (_found) exitWith {};
    } forEach ("true" configClasses (configFile >> "CfgVehicles" >> typeOf _veh >> "turrets"));
    if (_found) then { 1000 } else { 825 }
};
// the nearest SPG-eligible enemy target that an ASSAULT GROUP currently marching on the same target
// marker has spotted (knowsAbout > 0.7) and that is inside the target marker's footprint. Target
// priority: stationary TANKS before stationary APCs, and infantry ONLY when the enemy is all-moving
// (so its foot elements are the only reachable targets) or there is no armor at all. MOVING vehicles
// are never engaged by area fire - a laser-designated target (handled separately) is the only way the
// piece fires at something that moves. Returns a position, or [] when nothing is spotted. An assault
// piece shells the squads' actual enemy contacts - not the bare marker - so fire support follows the
// infantry's eyes instead of hammering empty ground. Optional _minRange (default: the piece's minimum
// ballistic range) skips targets too close to hit.
MISSION_CORE_fnc_assaultArtySpotTarget = {
    params ["_veh", "_aimAt", ["_minRange", -1]];
    private _enemy = if (side _veh == WEST) then { EAST } else { WEST };
    // Resolve which target marker this aim point belongs to (assigned target).
    private _aimName = "";
    if (!(isNil "MISSION_CORE_LOCATIONS") && { (typeName _aimAt) == "ARRAY" && { count _aimAt >= 2 } }) then {
        private _li = MISSION_CORE_LOCATIONS findIf { ((_x select 1) select 0) distance2D _aimAt < 150 };
        if (_li >= 0) then { _aimName = (MISSION_CORE_LOCATIONS select _li) select 0; };
    };
    // Collect every unit of every assault group assigned to THIS marker as spotters.
    private _spotters = [];
    if (!(isNil "MISSION_CORE_ATTACK_GROUPS") && { _aimName != "" }) then {
        {
            private _adata = _y;
            if (count _adata < 7) then { continue; };
            if ((_adata select 1) != _aimName) then { continue; };
            private _ag = _adata select 0;
            if (isNull _ag) then { continue; };
            // _ag is a GROUP (the attack group assigned to this marker) - alive only accepts
            // Objects, so a group must be tested via its units. A direct "alive _ag" here threw
            // "Type Group, expected Object", killing the whole spawned arty tick (the loop heartbeat
            // would go stale, so the per-side controller respawns it - but for one tick this
            // piece's fire decision never completes).
            if ({ alive _x } count units _ag > 0) then { _spotters pushBack _ag; };
        } forEach MISSION_CORE_ATTACK_GROUPS;
    };
    // MULTIPLAYER RELAY: client-spawned assault groups reported to the server also act as spotters.
    if (!(isNil "MISSION_CORE_ATTACK_GROUPS_RELAY") && { _aimName != "" }) then {
        {
            private _adata = _y;
            if (count _adata < 7) then { continue; };
            if ((_adata select 1) != _aimName) then { continue; };
            private _ag = _adata select 0;
            if (isNull _ag) then { continue; };
            if ({ alive _x } count units _ag > 0) then { _spotters pushBack _ag; };
        } forEach MISSION_CORE_ATTACK_GROUPS_RELAY;
    };
    // The piece's OWN crew are spotters too: anything the SPG can actually SEE or detect becomes a
    // live contact. Bracketing a marker is always the LAST RESORT - even mid-rake, a barrel-up target
    // preempts the shared mark barrage and the rake simply stalls (it only advances when every piece
    // fires the current step), resuming only when no contact remains.
    {
        if (alive _x && { side _x == side _veh }) then { _spotters pushBack _x; };
    } forEach (crew _veh);
    if (count _spotters == 0) exitWith { [] };
    // Search a radius that matches the marker footprint (largest half-axis + belt), never tiny.
    private _mSearch = 800;
    if (!(isNil "MISSION_CORE_CACHED_POSITIONS") && { _aimName != "" }) then {
        private _mi = MISSION_CORE_CACHED_POSITIONS findIf { (_x select 0) == _aimName };
        if (_mi >= 0) then {
            private _sz = (MISSION_CORE_CACHED_POSITIONS select _mi) select 8;
            private _ma = if (count _sz > 0) then { _sz select 0 } else { 200 };
            private _mb = if (count _sz > 1) then { _sz select 1 } else { _ma };
            _mSearch = (((_ma max _mb) max 300) + 150) min 2000;
        };
    };
    private _rangeCap = if (_veh isKindOf "StaticMortar") then { 1700 } else { 10000 };
    if (_minRange <= 0) then { _minRange = _veh call MISSION_CORE_fnc_serverArtyMinRange; };
    // SPG target priority buckets. Moving vehicles are EXCLUDED entirely: area fire can't track them
    // (only a laser-designated dot - handled separately - ever engages something in motion). Stationary
    // TANKS before stationary APCs; infantry is last resort, valid when the enemy has only moving
    // armor (no parked armor to hit) or no armor at all.
    private _tanks = [];
    private _apcs = [];
    private _infantry = [];
    {
        private _u = _x;
        if (!(alive _u) || { side _u != _enemy }) then { continue; };
        if (_u distance2D _aimAt > _mSearch) then { continue; };
        private _spotted = _spotters findIf { _x knowsAbout _u > 0.7 } != -1;
        if (!_spotted) then { continue; };
        private _d = _u distance2D _veh;
        if (_d >= _rangeCap || { _d < _minRange }) then { continue; };
        if (_u isKindOf "Man") then { _infantry pushBack _u; continue; };
        if (_u isKindOf "LandVehicle") then {
            if (speed _u > 2) then { continue; };
            if (_u isKindOf "Wheeled_APC" || { _u isKindOf "Tracked_APC" }) then { _apcs pushBack _u; }
            else {
                if (_u isKindOf "Tank" || { _u isKindOf "Tank_F" }) then { _tanks pushBack _u; };
            };
        };
    } forEach (allUnits + vehicles);
    // Pick the nearest eligible target: armor is resolved back to the exact vehicle's position so each
    // volley lands on the enemy's armor, not on the centroid of a unit's feet.
    private _pickNearest = {
        params ["_list"];
        if (count _list == 0) exitWith { [] };
        private _best = _list select 0;
        private _bestD = _best distance2D _veh;
        {
            private _d = _x distance2D _veh;
            if (_d < _bestD) then { _bestD = _d; _best = _x; };
        } forEach _list;
        getPos _best
    };
    private _best = [_tanks] call _pickNearest;
    if (count _best == 0) then { _best = [_apcs] call _pickNearest; };
    if (count _best == 0) then { _best = [_infantry] call _pickNearest; };
    _best
};

// True only when the assigned AIM marker may be used as a last-resort barrage target. The piece may
// shell the bare marker ONLY when it is still an ENEMY objective (owner is not our side) AND still
// ACTIVE - an alive assault squad is still pressing this exact marker (or a player relay patrol is),
// or the player themself is fighting there. A captured or fully-fallen marker never draws indirect
// fire: it would only shell ground we own.
MISSION_CORE_fnc_assaultArtyMarkerFireable = {
    params ["_veh", "_aimAt"];
    if (isNil "MISSION_CORE_LOCATIONS") exitWith { false };
    private _aimLoc = MISSION_CORE_LOCATIONS findIf { ((_x select 1) select 0) distance2D _aimAt < 150 };
    if (_aimLoc < 0) exitWith { false };
    private _mPos = ((MISSION_CORE_LOCATIONS select _aimLoc) select 1) select 0;
    private _aimName = (MISSION_CORE_LOCATIONS select _aimLoc) select 0;
    private _owner = (MISSION_CORE_LOCATIONS select _aimLoc) select 5;
    if (_owner == side _veh) exitWith { false };
    private _pressing = false;
    if (!(isNil "MISSION_CORE_ATTACK_GROUPS")) then {
        {
            private _adata = _y;
            if (count _adata < 7) then { continue; };
            if ((_adata select 1) != _aimName) then { continue; };
            private _ag = _adata select 0;
            if (isNull _ag) then { continue; };
            if ({ alive _x } count units _ag > 0) exitWith { _pressing = true; };
        } forEach MISSION_CORE_ATTACK_GROUPS;
    };
    if (!_pressing && { !(isNil "MISSION_CORE_ATTACK_GROUPS_RELAY") }) then {
        {
            private _adata = _y;
            if (count _adata < 7) then { continue; };
            if ((_adata select 1) != _aimName) then { continue; };
            private _ag = _adata select 0;
            if (isNull _ag) then { continue; };
            if ({ alive _x } count units _ag > 0) exitWith { _pressing = true; };
        } forEach MISSION_CORE_ATTACK_GROUPS_RELAY;
    };
    // A player physically pressing the objective keeps it ACTIVE too, even after the assault squads
    // are wiped or spent - the fight is still on, so the piece keeps supporting that marker.
    if (!_pressing) then {
        _pressing = allPlayers findIf { alive _x && { side _x == side _veh && { _x distance2D _mPos < 1200 } } } != -1;
    };
    _pressing
};

// BRACKET-RAKE LINE: the set of volley positions that sweep a target marker's footprint from its
// NEAR side to its FAR side, as seen from a reference firing position (_refPos). The line is the
// chord of the marker's rotated ELLIPSE (half-axes _a/_b, rotation _dir - a square marker is just
// _a == _b) that runs from the marker edge closest to _refPos through the center to the farthest
// edge. That is how "start barrage from the closest side to the furthest side" is computed for any
// square OR elliptical footprint. Returns the step positions (near -> far, inclusive) or [] when no
// chord can be built (piece basically inside / degenerate).
MISSION_CORE_fnc_artyRakeLine = {
    params ["_refPos", "_aimAt", ["_a", 200], ["_b", 200], ["_dir", 0], ["_stepsN", 4]];
    if (typeName _aimAt != "ARRAY" || { count _aimAt < 2 }) exitWith { [] };
    private _center = [_aimAt select 0, _aimAt select 1, 0];
    private _p = if (typeName _refPos == "ARRAY" && { count _refPos >= 2 }) then { [_refPos select 0, _refPos select 1, 0] } else { _center };
    private _dx = (_center select 0) - (_p select 0);
    private _dy = (_center select 1) - (_p select 1);
    private _ds = sqrt ((_dx * _dx) + (_dy * _dy));
    if (_ds < 1) exitWith { [] };
    private _ux = _dx / _ds;
    private _uy = _dy / _ds;
    private _a2 = _a * _a;
    private _b2 = _b * _b;
    private _ca = cos _dir;
    private _sa = sin _dir;
    // Local (rotated) ellipse frame: local x along (_ca,_sa), local y along (-_sa,_ca).
    private _rx0 = (_p select 0) - (_center select 0);
    private _ry0 = (_p select 1) - (_center select 1);
    private _lx0 = (_rx0 * _ca) + (_ry0 * _sa);
    private _ly0 = (-_rx0 * _sa) + (_ry0 * _ca);
    private _dlu = (_ux * _ca) + (_uy * _sa);
    private _dlv = (-_ux * _sa) + (_uy * _ca);
    // Ray P + s*d intersects the ellipse when (lx(s)^2/a^2) + (ly(s)^2/b^2) = 1: quadratic in s.
    private _aq = ((_dlu * _dlu) / _a2) + ((_dlv * _dlv) / _b2);
    private _bq = 2 * (((_lx0 * _dlu) / _a2) + ((_ly0 * _dlv) / _b2));
    private _cq = (((_lx0 * _lx0) / _a2) + ((_ly0 * _ly0) / _b2)) - 1;
    private _disc = (_bq * _bq) - (4 * _aq * _cq);
    if (_aq <= 0) exitWith { [] };
    if (_disc < 0) exitWith { [] };
    private _sq = sqrt _disc;
    private _s1 = (-_bq - _sq) / (2 * _aq);
    private _s2 = (-_bq + _sq) / (2 * _aq);
    if (_s1 > _s2) then { private _t = _s1; _s1 = _s2; _s2 = _t; };
    if (_s2 < 1) exitWith { [] };
    if (_s1 < 1) then { _s1 = 1; };
    private _nx = (_p select 0) + (_ux * _s1);
    private _ny = (_p select 1) + (_uy * _s1);
    private _fx = (_p select 0) + (_ux * _s2);
    private _fy = (_p select 1) + (_uy * _s2);
    private _steps = [];
    private _count = _stepsN max 1;
    for "_i" from 0 to _count do {
        private _f = _i / _count;
        _steps pushBack [(_nx + ((_fx - _nx) * _f)), (_ny + ((_fy - _ny) * _f)), 0];
    };
    _steps
};

// Shared bracket-rake step for the CURRENT volley of an assault-arty group firing on its assigned
// active target marker. Every member of the group gets the SAME bracket location (the rake steps are
// built once from the group leader's line of sight and stored per group+marker), and the rake only
// advances when every registered live piece in the group has fired at the current step. After the
// LAST bracket location the member is set for this marker ownership: the piece ceases firing on the
// marker location itself - further fire missions are limited to spotted contacts and laser dots.
// Returns the shared step position, or [] when no marker barrage may be delivered (already raked,
// or no valid rake line could be built).
MISSION_CORE_fnc_assaultArtyBracketStep = {
    params ["_veh", "_grp", "_aimAt"];
    if (isNull _grp) exitWith { [] };
    // Resolve the aim marker: name, center, footprint shape (a, b, rotation).
    private _aimName = "";
    private _aimCenter = _aimAt;
    private _sz = [200, 200, 0];
    if (!(isNil "MISSION_CORE_LOCATIONS") && { (typeName _aimAt) == "ARRAY" && { count _aimAt >= 2 } }) then {
        private _li = MISSION_CORE_LOCATIONS findIf { ((_x select 1) select 0) distance2D _aimAt < 150 };
        if (_li >= 0) then {
            _aimName = (MISSION_CORE_LOCATIONS select _li) select 0;
            _aimCenter = ((MISSION_CORE_LOCATIONS select _li) select 1) select 0;
        };
    };
    if (!(isNil "MISSION_CORE_CACHED_POSITIONS") && { _aimName != "" }) then {
        private _ci = MISSION_CORE_CACHED_POSITIONS findIf { (_x select 0) == _aimName };
        if (_ci >= 0) then {
            private _cs = (MISSION_CORE_CACHED_POSITIONS select _ci) select 8;
            if (count _cs > 0) then { _sz set [0, _cs select 0]; };
            if (count _cs > 1) then { _sz set [1, _cs select 1]; };
            if (count _cs > 2) then { _sz set [2, _cs select 2]; };
        };
    };
    private _owner = WEST;
    if (!(isNil "MISSION_CORE_LOCATIONS") && { _aimName != "" }) then {
        private _li = MISSION_CORE_LOCATIONS findIf { (_x select 0) == _aimName };
        if (_li >= 0) then { _owner = (MISSION_CORE_LOCATIONS select _li) select 5; };
    };
    // CEASE-FIRE LATCH: once the rake has swept this marker under this ownership, the bare marker
    // never draws fire again - only spotted contacts or laser dots. A later re-capture/re-ownership
    // of the marker re-arms the rake.
    if (isNil "MISSION_CORE_ARTY_BARRAGE_DONE") then { MISSION_CORE_ARTY_BARRAGE_DONE = createHashMap; };
    private _done = MISSION_CORE_ARTY_BARRAGE_DONE getOrDefault [_aimName, []];
    if (count _done > 0 && { (_done select 0) == _owner }) exitWith { [] };
    // Shared per-group, per-marker rake plan.
    if (isNil "MISSION_CORE_ARTY_BRACKETS") then { MISSION_CORE_ARTY_BRACKETS = createHashMap; };
    private _key = format ["%1|%2", str _grp, _aimName];
    private _plan = MISSION_CORE_ARTY_BRACKETS getOrDefault [_key, []];
    if (count _plan == 0) then {
        private _ref = getPosATL (leader _grp);
        if (typeName _ref != "ARRAY" || { count _ref < 2 }) then { _ref = getPosATL _veh; };
        private _steps = [_ref, _aimCenter, _sz select 0, _sz select 1, _sz select 2, ["artyBracketSteps", 4] call MISSION_CORE_fnc_tune] call MISSION_CORE_fnc_artyRakeLine;
        if (count _steps == 0) exitWith { [] };
        _plan = [0, _steps];
        MISSION_CORE_ARTY_BRACKETS set [_key, _plan];
        diag_log format ["PLAYER ARTY: bracket rake built for group %1 across %2 (%3 positions near->far)", _grp, _aimName, count _steps];
    };
    private _idx = _plan select 0;
    private _steps = _plan select 1;
    if (_idx >= count _steps) exitWith {
        MISSION_CORE_ARTY_BARRAGE_DONE set [_aimName, [_owner, true]];
        MISSION_CORE_ARTY_BRACKETS deleteAt _key;
        diag_log format ["PLAYER ARTY: bracket rake for %1 complete - ceasing fire on marker location", _aimName];
        []
    };
    private _stepPos = _steps select _idx;
    // Same bracket location for every member of the artillery group.
    _veh setVariable ["MISSION_CORE_ARTY_BRACKET_STEP", _idx];
    // Advance the shared rake only when EVERY registered live piece in the group has fired at the
    // current step - no member skips a bracket location.
    private _allFired = true;
    if (!(isNil "MISSION_CORE_ARTY_CTRL")) then {
        {
            private _d2 = MISSION_CORE_ARTY_CTRL get _x;
            if (isNil "_d2") then { continue; };
            if ((_d2 select 1) != _grp) then { continue; };
            private _v2 = _d2 select 0;
            if (isNull _v2 || { !(alive _v2) }) then { continue; };
            if ((_v2 getVariable ["MISSION_CORE_ARTY_BRACKET_STEP", -1]) < _idx) then { _allFired = false; };
        } forEach (keys MISSION_CORE_ARTY_CTRL);
    };
    if (_allFired) then {
        _idx = _idx + 1;
        _plan set [0, _idx];
        MISSION_CORE_ARTY_BRACKETS set [_key, _plan];
        if (_idx >= count _steps) then {
            MISSION_CORE_ARTY_BARRAGE_DONE set [_aimName, [_owner, true]];
            MISSION_CORE_ARTY_BRACKETS deleteAt _key;
            diag_log format ["PLAYER ARTY: bracket rake for %1 complete at last bracket - ceasing fire on marker location", _aimName];
        };
    };
    _stepPos
};
