// =====================================================================
// TANK ORDERS & SHIPMENTS - production + delivery for the depot system
// (see fn_tankDepot.sqf for the warehouse / parking half).
//
// Factories BUILD tanks (1 per 10 min) into their own storage, then overflow
// into the nearest same-side base once the factory is at cap. Orders (MBT pool
// refills / counter-attack tanks) route to the nearest same-side depot - bases
// first, factories second - and are dispatched as road convoys of up to 3 tanks,
// gated at dispatch by the side-wide MBT cap. Columns travel abstractly and only
// materialize near players; on arrival the tanks deploy as defenders at the
// target marker and fill its pool.
// =====================================================================

// Global MBT allowance left after alive fielded tanks plus tanks still in flight.
MISSION_CORE_fnc_tankSlotsLeft = {
    params ["_side"];
    private _globalMax = if (_side == WEST) then { getNumber (missionConfigFile >> "B_MAX_TANKS") } else { getNumber (missionConfigFile >> "O_MAX_TANKS") };
    if (_globalMax <= 0) then { _globalMax = 4; };
    private _alive = {
        alive _x && { _x isKindOf "Tank" } && { !(_x isKindOf "StaticWeapon") } && { side _x == _side } && { !(_x getVariable ["MISSION_CORE_TANK_RESERVE", false]) }
    } count vehicles;
    private _inflight = MISSION_CORE_TANK_INFLIGHT getOrDefault [_side, 0];
    (_globalMax - _alive - _inflight) max 0
};

// Road path between two points, greedily following the road network (same model as
// supply convoys). Returns [_roadPath, _cum, _total] or [[], [], 0] if too short.
MISSION_CORE_fnc_tankRoadPath = {
    params ["_startPos", "_endPos"];
    private _roadPath = [_startPos, _endPos];
    private _startRoad = (_startPos nearRoads 400) param [0, objNull];
    private _endRoad = (_endPos nearRoads 400) param [0, objNull];
    if (!isNull _startRoad && { !isNull _endRoad }) then {
        private _cur = _startRoad;
        private _visited = [];
        private _trial = [];
        private _reached = false;
        for "_i" from 0 to 199 do {
            _trial pushBack (getPos _cur);
            _visited pushBack _cur;
            if ((_cur distance2D _endRoad) < 30) exitWith { _reached = true; };
            private _conn = roadsConnectedTo _cur;
            private _best = objNull;
            private _bestD = 1e10;
            {
                if (!(_x in _visited)) then {
                    private _d = _x distance2D _endRoad;
                    if (_d < _bestD) then { _bestD = _d; _best = _x; };
                };
            } forEach _conn;
            if (isNull _best) exitWith {};
            _cur = _best;
        };
        if (_reached && { count _trial >= 2 }) then {
            _trial pushBack (getPos _endRoad);
            _roadPath = _trial;
        };
    };
    private _cum = [];
    private _total = 0;
    for "_i" from 0 to (count _roadPath - 2) do {
        _total = _total + ((_roadPath select _i) distance2D (_roadPath select (_i + 1)));
        _cum pushBack _total;
    };
    if (_total < 50) exitWith { [[], [], 0] };
    [_roadPath, _cum, _total]
};

// Shared defender finalization for an arriving tank column: home center at the target
// (so it fills the marker's pool), defend order, MBT slot, and a Killed handler that
// opens a replacement order.
MISSION_CORE_fnc_tankFinalizeDefenders = {
    params ["_grp", "_vehs", "_side", "_targetPos", "_targetName", "_origin"];
    private _imp = 1;
    private _tl = MISSION_CORE_CACHED_POSITIONS select { (_x select 0) == _targetName };
    if (count _tl > 0) then { _imp = (_tl select 0) select 7; };
    _grp setVariable ["MISSION_CORE_MARKER_CENTER", _targetPos];
    _grp setVariable ["MISSION_CORE_ORDER", "defend"];
    _grp setVariable ["MISSION_CORE_IDLE", false];
    _grp setVariable ["MISSION_CORE_ARMOR_SLOT", "mbt"];
    _grp setVariable ["MISSION_CORE_IMPORTANCE", _imp];
    _grp setVariable ["MISSION_CORE_ORIGIN_MARKER", _origin];
    _grp setVariable ["MISSION_CORE_REDFOR", _side == EAST];
    _grp setVariable ["MISSION_CORE_BLUFOR", _side == WEST];
    // A delivered tank is a permanent garrison asset at its marker - flag it so the armor
    // commander never pulls it off to assault/counterattack enemy markers (players paid MP
    // for it to defend).
    _grp setVariable ["MISSION_CORE_GARRISON", true];
    _grp setBehaviour "AWARE";
    _grp setCombatMode "YELLOW";
    {
        _x setVariable ["MISSION_CORE_REINF_TARGET", _targetPos];
        _x setVariable ["MISSION_CORE_REINF_LOCNAME", _targetName];
        _x addEventHandler ["Killed", {
            params ["_v"];
            [_side, _targetPos, _targetName] call MISSION_CORE_fnc_requestArmorReinforcement;
        }];
    } forEach _vehs;
    if (isNil "MISSION_CORE_SPAWNED_GROUPS") then { MISSION_CORE_SPAWNED_GROUPS = []; };
    MISSION_CORE_SPAWNED_GROUPS pushBack _grp;
};

// Abstract arrival: no player ever approached the route - deliver a crewed column at the
// target edge (facing away from the nearest player) that drives in to defend the marker.
MISSION_CORE_fnc_tankDeployAbstract = {
    params ["_side", "_targetPos", "_targetName", "_count", "_spawnPos", ["_vehClass", ""], ["_cost", 0]];
    private _factionData = if (_side == WEST) then { MISSION_CORE_BLUFOR_DATA } else { MISSION_CORE_REDFOR_DATA };
    private _mbtClasses = (_factionData select 7) getOrDefault ["mbt", []];
    if (count _mbtClasses == 0) exitWith { grpNull };
    // Players choose the exact MBT class they order (e.g. Slammer) - deliver THAT class, not a
    // random pick. Fall back to a random MBT only when no specific class was requested.
    if (_vehClass == "" || { !(_vehClass in _mbtClasses) }) then { _vehClass = selectRandom _mbtClasses; };
    private _crewClass = if (_side == WEST) then { "B_crew_F" } else { "O_crew_F" };
    private _spawn = [_spawnPos, 0, 100, 15, 0, 0.5, 0] call BIS_fnc_findSafePos;
    if (count _spawn < 2) then { _spawn = [_spawnPos] call MISSION_CORE_fnc_ensureLandPos; };
    if (count _spawn == 2) then { _spawn pushBack 0; };
    private _vehs = [];
    private _grp = createGroup _side;
    for "_i" from 1 to _count do {
        private _veh = createVehicle [_vehClass, [_spawn] call MISSION_CORE_fnc_liftSpawn, [], 5, "CAN_COLLIDE"];
        _vehs pushBack _veh;
        _grp addVehicle _veh;
        for "_c" from 1 to 3 do { _grp createUnit [_crewClass, _spawn, [], 0, "NONE"]; };
    };
    private _crewIdx = 0;
    {
        private _crewOf = units _grp select [_crewIdx, 3];
        _crewIdx = _crewIdx + 3;
        if (count _crewOf > 0 && { isNull (driver _x) }) then { (_crewOf select 0) moveInDriver _x; };
        if (count _crewOf > 1 && { isNull (gunner _x) }) then { (_crewOf select 1) moveInGunner _x; };
        if (count _crewOf > 2 && { isNull (commander _x) }) then { (_crewOf select 2) moveInCommander _x; };
    } forEach _vehs;
    _grp setBehaviour "AWARE"; _grp setCombatMode "YELLOW"; _grp setSpeedMode "FULL";
    private _wp = _grp addWaypoint [_targetPos, 100];
    _wp setWaypointType "MOVE";
    _wp setWaypointSpeed "FULL";
    _wp setWaypointBehaviour "AWARE";
    _grp setCurrentWaypoint _wp;
    [_grp, _vehs, _side, _targetPos, _targetName, _targetName] call MISSION_CORE_fnc_tankFinalizeDefenders;
    // Refill bookkeeping: base recruit cost + vehicle identity (used to rebuild a destroyed tank
    // at 4x MP). Only meaningful for player-ordered BLUFOR tanks - convoys pass 0.
    _grp setVariable ["MISSION_CORE_RECRUIT_COST", _cost];
    _grp setVariable ["MISSION_CORE_RECRUIT_VEH", [_vehClass, "tank"]];
    diag_log format ["DYNAMIC TANK: %1 abstract arrival - %2 tanks deployed at %3 (garrison=%4)", _side, _count, _targetName, _grp getVariable ["MISSION_CORE_GARRISON", false]];
    diag_log format ["DYNAMIC TANK: %1 grp=%2 targetPos=%3 spawnPos=%4 home=%5", _side, groupId _grp, _targetPos, _spawnPos, _grp getVariable ["MISSION_CORE_MARKER_CENTER", []]];
    _grp
};

MISSION_CORE_fnc_tankOrderLoop = {
    diag_log "DYNAMIC TANK: order loop started";
    while { true } do {
        sleep 10;
        // Manpower economy shares this 10s tick (no second timer): ports accumulate -> ship to
        // bases -> bases distribute 1-for-1 to requesting markers.
        call MISSION_CORE_fnc_manpowerTick;
        if (isNil "MISSION_CORE_TANK_STOCK") then { MISSION_CORE_TANK_STOCK = createHashMap; };
        if (isNil "MISSION_CORE_TANK_PARK") then { MISSION_CORE_TANK_PARK = createHashMap; };
        if (isNil "MISSION_CORE_TANK_PARK_SIDE") then { MISSION_CORE_TANK_PARK_SIDE = createHashMap; };
        if (isNil "MISSION_CORE_TANK_ORDERS") then { MISSION_CORE_TANK_ORDERS = []; };
        if (isNil "MISSION_CORE_TANK_SHIPMENTS") then { MISSION_CORE_TANK_SHIPMENTS = []; };
        if (isNil "MISSION_CORE_TANK_INFLIGHT") then { MISSION_CORE_TANK_INFLIGHT = createHashMap; };
        if (isNil "MISSION_CORE_TANK_BUILD_AT") then { MISSION_CORE_TANK_BUILD_AT = createHashMap; };
        if (isNil "MISSION_CORE_TANK_DELIVERED") then { MISSION_CORE_TANK_DELIVERED = createHashMap; };
        if (isNil "MISSION_CORE_TANK_DELIVERED_GROUPS") then { MISSION_CORE_TANK_DELIVERED_GROUPS = createHashMap; };
// Track which markers have requested tanks for assault (but assault not yet started)
        if (isNil "MISSION_CORE_TANK_REQUESTED") then { MISSION_CORE_TANK_REQUESTED = createHashMap; };
// Track shipments that were destroyed en route
        if (isNil "MISSION_CORE_TANK_DESTROYED") then { MISSION_CORE_TANK_DESTROYED = createHashMap; };

        private _depots = MISSION_CORE_CACHED_POSITIONS select {
            ((_x select 4) in [WEST, EAST]) && { [_x] call MISSION_CORE_fnc_tankDepotIsDepot }
        };

        // Capture sweep: a depot that changed owner (or vanished) loses its parked battery
        // and its stock - the new owner gets a fresh empty warehouse.
        {
            private _n = _x;
            private _recordedSide = MISSION_CORE_TANK_PARK_SIDE getOrDefault [_n, -1];
            private _depotNow = _depots findIf { ((_x select 0) == _n) && { (_x select 4) == _recordedSide } };
            if (_depotNow == -1) then {
                { if (!isNull _x) then { deleteVehicle _x; }; } forEach (MISSION_CORE_TANK_PARK getOrDefault [_n, []]);
                MISSION_CORE_TANK_PARK deleteAt _n;
                MISSION_CORE_TANK_PARK_SIDE deleteAt _n;
                MISSION_CORE_TANK_STOCK deleteAt _n;
                diag_log format ["DYNAMIC TANK: purged captured/removed depot %1", _n];
            };
        } forEach (keys MISSION_CORE_TANK_PARK);

        // ---- Production: factories build 1 per 10 min into their own storage; at cap the
        // build overflows to the nearest same-side base with room. Idles when nowhere to
        // store; shipping drains stock, which re-opens room and production resumes.
        {
            private _loc = _x;
            private _side = _loc select 4;
            private _name = _loc select 0;
            if ([_loc] call MISSION_CORE_fnc_tankDepotIsProducer) then {
                private _last = MISSION_CORE_TANK_BUILD_AT getOrDefault [_name, -99999];
                // Powerplant-driven production: the effective interval is the base interval divided
                // by the factory's multiplier (0.2x per same-side powerplant, +0.5x per neighbor).
                private _mult = [_loc] call MISSION_CORE_fnc_tankFactoryMultiplier;
                private _interval = (["tankBuildInterval", 600] call MISSION_CORE_fnc_tune) / (_mult max 0.01);
                if (time - _last < _interval) then { continue; };
                MISSION_CORE_TANK_BUILD_AT set [_name, time];
                private _cap = [_loc] call MISSION_CORE_fnc_tankDepotCap;
                private _stock = [_name] call MISSION_CORE_fnc_tankDepotStock;
                if (_stock < _cap) then {
                    MISSION_CORE_TANK_STOCK set [_name, _stock + 1];
                    [_loc] call MISSION_CORE_fnc_tankParkReconcile;
                    diag_log format ["DYNAMIC TANK: %1 built a tank (stock %2/%3)", _name, _stock + 1, _cap];
                } else {
                    private _bases = _depots select {
                        !([_x] call MISSION_CORE_fnc_tankDepotIsProducer) &&
                        { (_x select 4) == _side } &&
                        { ([(_x select 0)] call MISSION_CORE_fnc_tankDepotStock) < ([_x] call MISSION_CORE_fnc_tankDepotCap) }
                    };
                    if (count _bases > 0) then {
                        _bases = [_bases, [], { (_x select 1) distance (_loc select 1) }, "ASCEND"] call BIS_fnc_sortBy;
                        private _tgt = _bases select 0;
                        private _tname = _tgt select 0;
                        MISSION_CORE_TANK_STOCK set [_tname, ([_tname] call MISSION_CORE_fnc_tankDepotStock) + 1];
                        [_tgt] call MISSION_CORE_fnc_tankParkReconcile;
                        diag_log format ["DYNAMIC TANK: %1 overflow -> %2 (stock %3)", _name, _tname, MISSION_CORE_TANK_STOCK getOrDefault [_tname, 0]];
                    };
                };
            };
        } forEach _depots;

        // ---- Orders: route to the nearest same-side depot with stock (bases first, then
        // factories) and dispatch a column of up to 3, gated by the MBT cap at dispatch.
        private _keepOrders = [];
        {
            _x params ["_orderSide", "_tName", "_tPos", "_placedAt", "_n", ["_isAssault", false]];
            if (_n <= 0) then { continue; };
            private _tImp = 1;
            private _tl = MISSION_CORE_CACHED_POSITIONS select { (_x select 0) == _tName };
            if (count _tl == 0) then { continue; };
            _tImp = (_tl select 0) select 7;
            private _cands = MISSION_CORE_CACHED_POSITIONS select {
                (_x select 4) == _orderSide &&
                { (_x select 0) != _tName } &&
                { [_x] call MISSION_CORE_fnc_tankDepotIsDepot } &&
                { ([(_x select 0)] call MISSION_CORE_fnc_tankDepotStock) > 0 }
            };
            // Pool all same-side depot candidates (factories AND bases) with stock and pull from
            // the nearest FIRST, then the next nearest, and so on - an order is never throttled by
            // a single empty nearby depot when a farther base/factory holds the tanks (factories
            // cap at 10, bases at 20). Bases are preferred within each distance band so stock sits
            // at the most meaningful hubs, but every same-side depot is eligible.
            if (count _cands == 0) then { _keepOrders pushBack _x; continue; };
            _cands = [_cands, [], { _tPos distance (_x select 1) }, "ASCEND"] call BIS_fnc_sortBy;
            private _pool = _cands select { !([_x] call MISSION_CORE_fnc_tankDepotIsProducer) };
            _pool append (_cands select { [_x] call MISSION_CORE_fnc_tankDepotIsProducer });
            if (count _pool == 0) then { _keepOrders pushBack _x; continue; };
            // Non-assault tank deliveries (recruit/HQ orders, pool refills) NEVER go into a
            // contested battle, and a FACTORY may only deliver to a NEIGHBOR marker (within
            // neighborRange). Assault/counter-attack tanks are the deliberate exception that
            // fights at contested markers, so they are excluded from this restriction.
            if (!_isAssault) then {
                if ([_tPos, _orderSide, _tName] call MISSION_CORE_fnc_isMarkerContested) then {
                    _keepOrders pushBack _x;
                    continue;
                };
                _pool = _pool select {
                    !([_x] call MISSION_CORE_fnc_tankDepotIsProducer) ||
                    { ((_x select 1) distance _tPos) <= (["neighborRange", 4000] call MISSION_CORE_fnc_tune) }
                };
                if (count _pool == 0) then { _keepOrders pushBack _x; continue; };
            };
            // Walk the depots nearest-first, drawing up to each one's stock, until the order's
            // count is filled. Respect the side-wide MBT cap across the whole dispatch: never
            // inflight more tanks than tankSlotsLeft allows.
            private _remaining = _n;
            private _shipped = 0;
            {
                if (_remaining <= 0) then { continue; };
                private _depot = _x;
                private _dName = _depot select 0;
                private _dStock = [_dName] call MISSION_CORE_fnc_tankDepotStock;
                if (_dStock <= 0) then { continue; };
                // A single column is capped for normal orders (tankShipColumnMax) but an ASSAULT
                // order ships a depot's full available stock in one column so the requested force
                // arrives together rather than dripping in one-per-tick.
                private _take = if (_isAssault) then { _dStock } else { ((_dStock min (["tankShipColumnMax", 3] call MISSION_CORE_fnc_tune)) max 1) };
                if (!_isAssault) then { _take = _take min _remaining; };
                private _slots = [_orderSide] call MISSION_CORE_fnc_tankSlotsLeft;
                if (_isAssault) then {
                    _take = _take min _remaining;
                    _take = _take min _slots;
                    if (_take <= 0) then { continue; };
                } else {
                    _take = _take min _remaining;
                    if (!([_orderSide, "mbt", _tPos, _tImp] call MISSION_CORE_fnc_armorCapOpen) || { _slots < _take }) then { continue; };
                };
                private _path = [(_depot select 1), _tPos] call MISSION_CORE_fnc_tankRoadPath;
                if ((_path select 2) <= 0) then { continue; };
                MISSION_CORE_TANK_STOCK set [_dName, _dStock - _take];
                [_depot] call MISSION_CORE_fnc_tankParkReconcile;
                MISSION_CORE_TANK_INFLIGHT set [_orderSide, (MISSION_CORE_TANK_INFLIGHT getOrDefault [_orderSide, 0]) + _take];
                private _travelTime = (_path select 2) / (["tankTravelSpeed", 18] call MISSION_CORE_fnc_tune);
                MISSION_CORE_TANK_SHIPMENTS pushBack [_orderSide, _dName, _tName, _tPos, _take, (_path select 0), (_path select 1), _travelTime, time, 0, [], grpNull];
                MISSION_CORE_TANK_DESTROYED set [count MISSION_CORE_TANK_SHIPMENTS - 1, false];
                diag_log format ["DYNAMIC TANK: dispatched %1 tanks %2 -> %3 (%4m, ETA %5s)", _take, _dName, _tName, round (_path select 2), round _travelTime];
                _remaining = _remaining - _take;
                _shipped = _shipped + _take;
            } forEach _pool;
            // Anything still unfilled waits for a future tick (production refills depot stock).
            if (_shipped > 0 && { _remaining > 0 }) then { _x set [4, _remaining]; _keepOrders pushBack _x; };
            if (_shipped == 0) then { _keepOrders pushBack _x; };
        } forEach MISSION_CORE_TANK_ORDERS;
        MISSION_CORE_TANK_ORDERS = _keepOrders;

        // ---- Advance shipments: abstract travel, materialize near players, deploy on arrival.
        private _players = allPlayers select { alive _x };
        private _keepShip = [];
        {
            _x params ["_sSide", "_sDepot", "_sTarget", "_sTPos", "_sCount", "_sPath", "_sCum", "_sTravel", "_sDepart", "_sState", "_sVehs", "_sGrp"];
            // Target was captured while the column was en route - the shipment is lost.
            private _sTL = MISSION_CORE_CACHED_POSITIONS select { (_x select 0) == _sTarget };
            if (count _sTL > 0 && { (_sTL select 0) select 4 != _sSide }) then {
                if (!isNull _sGrp) then { { deleteVehicle _x; } forEach units _sGrp; deleteGroup _sGrp; };
                MISSION_CORE_TANK_INFLIGHT set [_sSide, (MISSION_CORE_TANK_INFLIGHT getOrDefault [_sSide, 0]) - _sCount];
                continue;
            };
            // MATERIALIZED convoy (state 1): keep tracking it every cycle so a shipped tank can
            // NEVER be orphaned on the map. It is cleaned up here on arrival (or when past the
            // travel deadline), by the arrival waypoint script, or by the destroyed-en-route
            // handler - all routed through the same MISSION_CORE_TANK_ARRIVED guard so the pool
            // accounting happens exactly once no matter which path fires first.
            if (_sState >= 1) then {
                if (isNull _sGrp) then {
                    // Group already gone (waypoint/despawn script handled it) - sweep any leftover
                    // vehicles and stop tracking. No accounting: whichever path cleaned the convoy
                    // already updated the inflight/pool ledgers.
                    { if (!isNull _x && { alive _x }) then { deleteVehicle _x; }; } forEach _sVehs;
                    continue;
                };
                if (count units _sGrp == 0 || { { alive _x } count units _sGrp == 0 }) then {
                    // Crew is entirely gone but the group still exists, so no other path has run.
                    // The destroyed-en-route Killed handler only fires when the VEHICLES die, so a
                    // wiped crew with intact tanks must be written off here - refund the inflight
                    // slot without crediting the pool (a tank that died en route never delivered).
                    if (!(_sGrp getVariable ["MISSION_CORE_TANK_ARRIVED", false])) then {
                        _sGrp setVariable ["MISSION_CORE_TANK_ARRIVED", true];
                        MISSION_CORE_TANK_INFLIGHT set [_sSide, (MISSION_CORE_TANK_INFLIGHT getOrDefault [_sSide, 0]) - _sCount];
                        diag_log format ["DYNAMIC TANK: convoy %1 -> %2 lost in transit (crew wiped) - %3 tanks", _sDepot, _sTarget, _sCount];
                    };
                    { if (!isNull _x && { alive _x }) then { deleteVehicle _x; }; } forEach _sVehs;
                    { if (!isNull _x) then { deleteVehicle _x; }; } forEach units _sGrp;
                    deleteGroup _sGrp;
                    continue;
                };
                if (_sGrp getVariable ["MISSION_CORE_TANK_ARRIVED", false]) then {
                    // The destroyed-en-route Killed handler already accounted the convoy but left
                    // the shells in the world - clean them up, never double-account.
                    { if (!isNull _x) then { deleteVehicle _x; }; } forEach _sVehs;
                    { if (!isNull _x) then { deleteVehicle _x; }; } forEach units _sGrp;
                    deleteGroup _sGrp;
                    continue;
                };
                if ({ alive _x } count _sVehs == 0) then {
                    _sGrp setVariable ["MISSION_CORE_TANK_ARRIVED", true];
                    MISSION_CORE_TANK_INFLIGHT set [_sSide, (MISSION_CORE_TANK_INFLIGHT getOrDefault [_sSide, 0]) - _sCount];
                    diag_log format ["DYNAMIC TANK: convoy %1 -> %2 destroyed en route - lost (%3 tanks)", _sDepot, _sTarget, _sCount];
                    continue;
                };
                // Write-off: a materialized tank that is combat-crippled (can't move - both tracks hit -
                // OR its gun is destroyed OR its hull/turret took critical damage) is a write-off.
                // Its crew bails, runs to the nearest friendly marker, and despawns via a waypoint
                // script. The disabled tank is removed from the convoy so the healthy tanks keep
                // driving in and deliver normally.
                private _wro = [];
                {
                    if (!alive _x) then { continue; };
                    private _dmg = getDammage _x;
                    private _gunDown = (_x getHitPointDamage "HitGun") > 0.9;
                    private _tracksDown = ((_x getHitPointDamage "HitLTrack") > 0.5) && { ((_x getHitPointDamage "HitRTrack") > 0.5) };
                    // canMove covers any hull/locomotion damage even when the vehicle has no named
                    // track hitpoints (not every MBT variant exposes HitLTrack/HitRTrack).
                    private _crit = _dmg > 0.8;
                    if (_crit || _gunDown || _tracksDown || !(canMove _x)) then {
                        _wro pushBack _x;
                    };
                } forEach _sVehs;
                if (count _wro > 0) then {
                    private _went = 0;
                    {
                        private _tank = _x;
                        if (isNull _tank) then { continue; };
                        private _tankCrew = crew _tank;
                        if (count _tankCrew > 0) then {
                            { unassignVehicle _x; [_x] orderGetIn false; _x action ["getOut", _tank]; } forEach _tankCrew;
                            sleep 0.3;
                            private _runnerGrp = createGroup _sSide;
                            { if (!isNull _x) then { [_x] joinSilent _runnerGrp; }; } forEach _tankCrew;
                            if ({ alive _x } count units _runnerGrp > 0) then {
                                // Run to the NEAREST friendly marker (same side as the convoy).
                                private _frends = MISSION_CORE_CACHED_POSITIONS select { (_x select 4) == _sSide };
                                private _fb = [];
                                if (count _frends > 0) then {
                                    private _sb = [_frends, [], { (_x select 1) distance2D (getPos leader _runnerGrp) }, "ASCEND"] call BIS_fnc_sortBy;
                                    if (count _sb > 0) then { _fb = _sb select 0; };
                                };
                                private _targetPos = if (count _fb > 0) then { (_fb select 1) } else { getPos leader _runnerGrp };
                                _runnerGrp setVariable ["MISSION_CORE_WRITEOFF", true];
                                private _fwp = _runnerGrp addWaypoint [_targetPos, 40];
                                _fwp setWaypointType "MOVE";
                                _fwp setWaypointSpeed "NORMAL";
                                _fwp setWaypointBehaviour "CARELESS";
                                _fwp setWaypointScript "transport_tankWriteoff.sqf";
                                _runnerGrp setCurrentWaypoint _fwp;
                                diag_log format ["DYNAMIC TANK: %1 crew bailed (write-off) - running to %2", _sDepot, if (count _fb > 0) then { _fb select 0 } else { "home" }];
                            };
                        };
                        // Remove the disabled tank from the convoy (account it as one lost delivery).
                        if (!isNull _tank) then { _tank removeAllEventHandlers "Killed"; deleteVehicle _tank; };
                        _sVehs = _sVehs - [_tank];
                        _went = _went + 1;
                    } forEach _wro;
                    if (_went > 0) then {
                        _sGrp setVariable ["MISSION_CORE_TANK_SHIP_VEHS", _sVehs];
                        _x set [10, _sVehs];
                        _x set [4, _sCount - _went];
                        MISSION_CORE_TANK_INFLIGHT set [_sSide, (MISSION_CORE_TANK_INFLIGHT getOrDefault [_sSide, 0]) - _went];
                        if (count _sVehs == 0) then {
                            { if (!isNull _x) then { deleteVehicle _x; }; } forEach units _sGrp;
                            deleteGroup _sGrp;
                            _x set [11, grpNull];
                            continue;
                        };
                    };
                };
                // Arrival detection for the materialized convoy: it counts as arrived when its crew
                // leader reaches the target marker area (sized like the abstract materialize path), or
                // when it runs past its travel deadline plus a small grace window.
                private _arrLoc = MISSION_CORE_CACHED_POSITIONS select { (_x select 0) == _sTarget };
                private _arrSize = if (count _arrLoc > 0 && { count (_arrLoc select 0) > 8 }) then { (_arrLoc select 0) select 8 } else { [200, 200, 0] };
                private _arrRadius = (((_arrSize select 0) max (_arrSize select 1)) / 2) max 30;
                private _nearTarget = if (!isNull _sGrp && { count units _sGrp > 0 }) then { (leader _sGrp distance2D _sTPos) < _arrRadius } else { false };
                private _pastDeadline = time > (_sDepart + _sTravel + 120);
                if (_nearTarget || _pastDeadline) then {
                    _sGrp setVariable ["MISSION_CORE_TANK_ARRIVED", true];
                    // Shared accounting: credit inflight/DELIVERED once; keep the convoy live for an
                    // assault commit if pending, otherwise despawn it to pool.
                    [_sSide, _sTarget, _sCount, _sGrp, _sVehs] call MISSION_CORE_fnc_tankDeliverAccount;
                    continue;
                };
                _keepShip pushBack _x;
            };
            if (_sState == 0) then {
                private _frac = ((time - _sDepart) / _sTravel) min 1;
                if (_frac >= 1) then {
                    // ABSTRACT ARRIVAL - no player ever came within 1200m of the column during the
                    // trip, so it never materialized. Do NOT spawn any tank here: the delivery is
                    // recorded abstractly into the target marker's tank POOL. The pool count is what
                    // gates assault-wave launch; the tank itself is never physically placed on the map
                    // (avoids tanks sitting at a base, getting re-tasked to defend a neighbor, and never
                    // taking part in the fight they were ordered for).
                    MISSION_CORE_TANK_INFLIGHT set [_sSide, (MISSION_CORE_TANK_INFLIGHT getOrDefault [_sSide, 0]) - _sCount];
                    MISSION_CORE_TANK_DELIVERED set [_sTarget, (MISSION_CORE_TANK_DELIVERED getOrDefault [_sTarget, 0]) + _sCount];
                    diag_log format ["DYNAMIC TANK: %1 -> %2 arrived abstractly (no player near) - %3 tanks added to pool, none spawned", _sDepot, _sTarget, _sCount];
                } else {
                    private _curPos = [_sPath, _sCum, _frac] call MISSION_CORE_fnc_convoyPosAt;
                if (_players findIf { _x distance _curPos < 1200 } != -1) then {
                    // PLAYER-PROXIMITY MATERIALIZE: the column has come within 1200m of a player, so
                    // spawn the tanks so the player can SEE them arriving, give them a MOVE waypoint to
                    // the destination, and let them drive there. On arrival they DESPAWN back into the
                    // target's tank pool - they are never left standing as defenders (standing tanks
                    // were getting re-tasked to defend a neighbor and never taking part in their fight).
                    private _factionData = if (_sSide == WEST) then { MISSION_CORE_BLUFOR_DATA } else { MISSION_CORE_REDFOR_DATA };
                    private _mbtClasses = (_factionData select 7) getOrDefault ["mbt", []];
                    if (count _mbtClasses == 0) then { _keepShip pushBack _x; continue; };
                    private _crewClass = if (_sSide == WEST) then { "B_crew_F" } else { "O_crew_F" };
                    private _spawn = [_curPos, 0, 100, 15, 0, 0.5, 0] call BIS_fnc_findSafePos;
                    if (count _spawn < 2) then { _spawn = [_curPos] call MISSION_CORE_fnc_ensureLandPos; };
                    if (count _spawn == 2) then { _spawn pushBack 0; };
                    private _vehs = [];
                    private _grp = createGroup _sSide;
                    for "_i" from 1 to _sCount do {
                        private _veh = createVehicle [selectRandom _mbtClasses, [_spawn] call MISSION_CORE_fnc_liftSpawn, [], 5, "CAN_COLLIDE"];
                        _vehs pushBack _veh;
                        _grp addVehicle _veh;
                        for "_c" from 1 to 3 do { _grp createUnit [_crewClass, _spawn, [], 0, "NONE"]; };
                    };
                    private _crewIdx = 0;
                    {
                        private _crewOf = units _grp select [_crewIdx, 3];
                        _crewIdx = _crewIdx + 3;
                        if (count _crewOf > 0 && { isNull (driver _x) }) then { (_crewOf select 0) moveInDriver _x; };
                        if (count _crewOf > 1 && { isNull (gunner _x) }) then { (_crewOf select 1) moveInGunner _x; };
                        if (count _crewOf > 2 && { isNull (commander _x) }) then { (_crewOf select 2) moveInCommander _x; };
                    } forEach _vehs;
                    _grp setBehaviour "CARELESS"; _grp setCombatMode "GREEN"; _grp setSpeedMode "FULL";
                    // Completion radius = half the target marker's size, so the convoy "arrives" as
                    // soon as it enters the marker area instead of driving to the exact path end.
                    private _arrLoc = MISSION_CORE_CACHED_POSITIONS select { (_x select 0) == _sTarget };
                    private _arrSize = if (count _arrLoc > 0 && { count (_arrLoc select 0) > 8 }) then { (_arrLoc select 0) select 8 } else { [200, 200, 0] };
                    private _arrRadius = (((_arrSize select 0) max (_arrSize select 1)) / 2) max 30;
                    private _wp = _grp addWaypoint [(_sPath select (count _sPath - 1)), _arrRadius];
                    _wp setWaypointType "MOVE";
                    _wp setWaypointSpeed "FULL";
                    _wp setWaypointBehaviour "CARELESS";
                    _wp setWaypointScript "transport_tankArrival.sqf";
                    _grp setCurrentWaypoint _wp;
                    // Destroyed-en-route cleanup: if players kill the WHOLE convoy while it drives, the
                    // arrival waypoint never completes so transport_tankArrival.sqf can never write it
                    // off. Stamp the shipment onto the group and watch via a per-vehicle Killed handler -
                    // it refunds the MBT inflight count exactly once. The arrival script flicks the same
                    // guard flag, so the two paths can never double-account.
                    _grp setVariable ["MISSION_CORE_TANK_SHIP_SIDE", _sSide];
                    _grp setVariable ["MISSION_CORE_TANK_SHIP_COUNT", _sCount];
                    _grp setVariable ["MISSION_CORE_TANK_SHIP_DEPOT", _sDepot];
                    _grp setVariable ["MISSION_CORE_TANK_SHIP_TARGET", _sTarget];
                    _grp setVariable ["MISSION_CORE_TANK_SHIP_VEHS", _vehs];
                    {
                        _x addEventHandler ["Killed", {
                            params ["_unit"];
                            private _sg = group _unit;
                            if (isNull _sg) exitWith {};
                            if (_sg getVariable ["MISSION_CORE_TANK_ARRIVED", false]) exitWith {};
                            private _convVehs = _sg getVariable ["MISSION_CORE_TANK_SHIP_VEHS", []];
                            if (count _convVehs == 0) exitWith {};
                            if ({ alive _x } count _convVehs > 0) exitWith {};
                            _sg setVariable ["MISSION_CORE_TANK_ARRIVED", true];
                            private _side = _sg getVariable ["MISSION_CORE_TANK_SHIP_SIDE", WEST];
                            private _cnt = _sg getVariable ["MISSION_CORE_TANK_SHIP_COUNT", 0];
                            private _depot = _sg getVariable ["MISSION_CORE_TANK_SHIP_DEPOT", ""];
                            private _tgt = _sg getVariable ["MISSION_CORE_TANK_SHIP_TARGET", ""];
                            if (isNil "MISSION_CORE_TANK_INFLIGHT") then { MISSION_CORE_TANK_INFLIGHT = createHashMap; };
                            MISSION_CORE_TANK_INFLIGHT set [_side, (MISSION_CORE_TANK_INFLIGHT getOrDefault [_side, 0]) - _cnt];
                            diag_log format ["DYNAMIC TANK: materialized convoy %1 -> %2 destroyed en route - %3 tanks lost", _depot, _tgt, _cnt];
                        }];
                    } forEach _vehs;
                    _x set [9, 1];
                    _x set [10, _vehs];
                    _x set [11, _grp];
                    _keepShip pushBack _x;
                    diag_log format ["DYNAMIC TANK: player-proximity materialized %1 tanks near %2", _sCount, _curPos];
                } else {
                    // Abstract tank that was never physically spawned - keep it in flight. It must
                    // NOT be counted as "lost in transit" just because it was not materialized. A
                    // materialized (state 1) shipment is tracked and cleaned up in the state block
                    // above.
                    _keepShip pushBack _x;
                };
            };
            };
        } forEach MISSION_CORE_TANK_SHIPMENTS;
        MISSION_CORE_TANK_SHIPMENTS = _keepShip;
    };
};

// Shared delivery accounting for a tank shipment that reached its target. Credits the inflight
// ledger down and the DELIVERED count up (exactly once - callers guard with MISSION_CORE_TANK_ARRIVED).
// When the target marker is awaiting an assault (MISSION_CORE_TANK_REQUESTED) and the convoy is
// still alive (a player-proximity materialized group, not an abstract delivery), the group is KEPT
// ALIVE and registered under MISSION_CORE_TANK_DELIVERED_GROUPS so the assault commit in
// fn_aiAssaultLoop can physically order it into the push. Abstract deliveries (no live group) and
// non-assault deliveries despawn to the pool as before - no tanks are ever conjured.
MISSION_CORE_fnc_tankDeliverAccount = {
    params ["_sSide", "_sTarget", "_sCount", ["_grp", grpNull], ["_sVehs", []]];
    if (isNil "MISSION_CORE_TANK_INFLIGHT") then { MISSION_CORE_TANK_INFLIGHT = createHashMap; };
    if (isNil "MISSION_CORE_TANK_DELIVERED") then { MISSION_CORE_TANK_DELIVERED = createHashMap; };
    if (isNil "MISSION_CORE_TANK_DELIVERED_GROUPS") then { MISSION_CORE_TANK_DELIVERED_GROUPS = createHashMap; };
    if (isNil "MISSION_CORE_TANK_REQUESTED") then { MISSION_CORE_TANK_REQUESTED = createHashMap; };
    MISSION_CORE_TANK_INFLIGHT set [_sSide, (MISSION_CORE_TANK_INFLIGHT getOrDefault [_sSide, 0]) - _sCount];
    // The target flipped owner en route - never credit an enemy marker it does not own.
    private _tl = MISSION_CORE_CACHED_POSITIONS select { (_x select 0) == _sTarget };
    if (count _tl > 0 && { (_tl select 0) select 4 != _sSide }) exitWith {
        diag_log format ["DYNAMIC TANK: shipment to %1 arrived after capture - %2 tanks lost", _sTarget, _sCount];
    };
    MISSION_CORE_TANK_DELIVERED set [_sTarget, (MISSION_CORE_TANK_DELIVERED getOrDefault [_sTarget, 0]) + _sCount];
    private _assaultPending = MISSION_CORE_TANK_REQUESTED getOrDefault [_sTarget, false];
    if (_assaultPending && { !isNull _grp } && { count units _grp > 0 }) then {
        // Bound for an active assault and still materialized - keep the column alive so the assault
        // commit orders it into the push. The assault owns it from here (sendCounterAttack re-tasks it).
        // MISSION_CORE_TANK_ARRIVED stays true so the destroyed-en-route Killed handler and this helper
        // never double-account; the group is a committed assault column from this point.
        MISSION_CORE_TANK_DELIVERED_GROUPS set [_sTarget, (MISSION_CORE_TANK_DELIVERED_GROUPS getOrDefault [_sTarget, []]) + [_grp]];
        diag_log format ["DYNAMIC TANK: %1 -> %2 delivered %3 tanks - held live for assault commit", _sSide, _sTarget, _sCount];
    } else {
        if (count _sVehs > 0) then { { if (!isNull _x) then { deleteVehicle _x; }; } forEach _sVehs; };
        if (!isNull _grp) then { { if (!isNull _x) then { deleteVehicle _x; }; } forEach units _grp; deleteGroup _grp; };
        diag_log format ["DYNAMIC TANK: %1 -> %2 delivered %3 tanks (despawned to pool)", _sSide, _sTarget, _sCount];
    };
};