
// Foot-transport stuck recovery - the ladder that frees a truck that has stopped moving en route.
//
// THE BUG THIS FIXES: a foot-transport truck that wedges (tree, wall, wreck, another truck) is never
// detected. fn_attackStuckWatchdog only tests a leader still within 25m of its SPAWN point, and
// fn_mountInfantry never tags its trucks for fn_orderedVehicleCleanup's 90s delete+refund sweeper -
// so a truck that stalls 2km down the road is invisible forever. The result is the pile-up the user
// reported: one truck stalls, the ones behind stack onto it, and the whole attack stops arriving.
//
// DETECTION is the two-sample rule, not a fixed dwell time: record the position on one tick, compare
// on the next. Below the move threshold in a full tick = stuck. It is deliberately far more
// sensitive than the 90s window the non-truck sweeper uses, because a queued column behind a stalled
// truck is already lost by then.
//
// THE LADDER, one rung per turn (a turn = one maintenance tick, 8-13s):
//   0 -> order a MOVE waypoint to a validated road spot
//   1 -> still stuck: teleport onto that spot and re-issue the route
//   2 -> still stuck: re-validate the spot; if unsafe, find a NEW one and go back to rung 0
//   3 -> nothing safe left: unload, delete the truck, the cargo walks on
// One rung per turn and a map-wide lock mean a single recovery can never become a pile-up of its
// own, and other stalled trucks get their turn in between.
//
// ROAD SPOTS ARE CACHED PER (origin -> target) PAIR, not globally. The same neighbor feeding the
// same contested marker keeps jamming on the same stretch of road, so the first recovery's spot is
// remembered and every later reinforcement to that lane reuses it instead of re-discovering it.
//
// A spot that keeps recurring gets its TREES CLEARED before the truck is moved (50m radius), since
// foliage wedging a truck is the common case and re-discovering the same blocked road forever helps
// nobody.

// Is this vehicle a foot-transport attack truck that this system should own? Deliberately narrow:
// gun trucks keep their crew and are not a cargo problem, self-drive hunt trucks have no dedicated
// driver group, and a truck whose cargo has already dismounted has nothing left to save.
MISSION_CORE_fnc_isWatchedFootTransport = {
    params ["_veh"];
    if (isNull _veh || { !(alive _veh) }) exitWith { false };
    if (!(_veh isKindOf "LandVehicle")) exitWith { false };
    private _drvGrp = _veh getVariable ["MISSION_CORE_DRIVER_GROUP", grpNull];
    if (isNull _drvGrp) exitWith { false };
    if ([_veh] call MISSION_CORE_fnc_hasMountedGun) exitWith { false };
    if (count (crew _veh) == 0) exitWith { false };
    // The transported squad is every crew member who is not the dedicated driver.
    private _cargo = (crew _veh) select { _x != driver _veh };
    if (count _cargo == 0) exitWith { false };
    private _cargoGrp = group (_cargo select 0);
    if (isNull _cargoGrp || { count units _cargoGrp == 0 }) exitWith { false };
    // Only troops on the way to a fight. A retreating, defending or patrolling squad that happens to
    // be aboard is already going where it intends to go, and the user scoped this to attack
    // transports only. These are the real order strings in use - there is no "reinforce" order.
    if ((_cargoGrp getVariable ["MISSION_CORE_ORDER", ""]) in ["attack", "counterattack", "engage", "staging"]) then { true } else { false }
};

// Delete the trees around a point so a truck cannot wedge on them again. deleteVehicle is the only
// thing that actually removes foliage from pathfinding; hideObject is the fallback for anything the
// engine refuses. Scoped to a 50m radius around the destination, never a map-wide sweep.
MISSION_CORE_fnc_clearTreesNear = {
    params ["_pos", ["_radius", 50]];
    if (count _pos < 2) exitWith { 0 };
    private _trees = nearestObjects [_pos, ["Tree", "Forest", "Bush"], _radius];
    private _n = 0;
    {
        private _t = _x;
        if (!isNull _t) then {
            _t hideObject true;
            try { deleteVehicle _t; _n = _n + 1; } catch { };
        };
    } forEach _trees;
    _n
};

// A road spot that is known to work for one (origin -> target) lane, validated with the SAME
// full findVehiclePos pass that spawns trucks: road-first, terrain-clear, dry, not in the
// unsafe-spawn registry, and clear of other vehicles. Returns [] when nothing nearby is safe.
MISSION_CORE_fnc_getSafeRoadSpot = {
    params ["_truck", "_origin", "_tgtName", "_tgtPos", "_tgtSize"];
    if (isNil "MISSION_CORE_ROAD_SPOTS") then { MISSION_CORE_ROAD_SPOTS = createHashMap; };
    private _lane = format ["%1>%2", _origin, _tgtName];
    private _cached = MISSION_CORE_ROAD_SPOTS getOrDefault [_lane, []];
    private _spot = [];
    private _hits = 0;
    if (count _cached >= 2) then {
        _spot = _cached select 0;
        _hits = _cached select 1;
        // A cached spot is re-validated, never trusted blindly: the recovery that created it may
        // have left a wreck on it, or a spawn-kill may have flagged it since.
        private _stale = ([_spot] call MISSION_CORE_fnc_isUnsafeVehicleSpawn) || { !([_spot] call MISSION_CORE_fnc_isDryPos) };
        if (_stale) then { _spot = []; } else { MISSION_CORE_ROAD_SPOTS set [_lane, [_spot, _hits]]; };
    };
    if (count _spot == 0) then {
        // Search around the truck, not around the target: the jam is where the truck already is.
        private _near = getPosATL _truck;
        private _size = [120, 120];
        _spot = [_near, _size, 24, random 360] call MISSION_CORE_fnc_findVehiclePos;
        if (count _spot >= 2) then {
            if (([_spot] call MISSION_CORE_fnc_isUnsafeVehicleSpawn) || { !([_spot] call MISSION_CORE_fnc_isDryPos) }) then { _spot = []; };
        } else {
            _spot = [];
        };
        if (count _spot > 0) then {
            MISSION_CORE_ROAD_SPOTS set [_lane, [_spot, 1]];
            _hits = 1;
        } else {
            MISSION_CORE_ROAD_SPOTS set [_lane, []];
        };
    };
    if (count _spot == 0) exitWith { [[], 0] };
    [_spot, _hits]
};

// Dismount every rider, keep the cargo as a foot squad, delete the truck and its driver group, then
// hand the squad back to the commander so it presses on to the same target. This is the end of the
// ladder: the men are NOT lost because their ride gave up.
MISSION_CORE_fnc_unloadTransportAbandonTruck = {
    params ["_truck", "_tgtPos", "_tgtSize"];
    if (isNull _truck || { !(alive _truck) }) exitWith {};
    private _cargo = (crew _truck) select { _x != driver _truck };
    private _cargoGrp = if (count _cargo > 0) then { group (_cargo select 0) } else { grpNull };
    private _drop = getPosATL _truck;
    private _placed = [];
    {
        if (alive _x) then {
            unassignVehicle _x;
            // Put them on the ground beside the truck, spread out so they do not land in a heap.
            _drop = _drop getPos [6 + random 8, random 360];
            _x setUnitPos "UP";
            _x setPos _drop;
            _placed pushBack _x;
        };
    } forEach _cargo;
    private _cargoCount = count _placed;
    // The driver group and the truck go away together, exactly like every other truck teardown.
    private _drvGrp = _truck getVariable ["MISSION_CORE_DRIVER_GROUP", grpNull];
    {
        if (!isNull _x) then { deleteVehicle _x; };
    } forEach (crew _truck);
    deleteVehicle _truck;
    if (!isNull _drvGrp) then {
        { if (!isNull _x) then { deleteVehicle _x; }; } forEach units _drvGrp;
        deleteGroup _drvGrp;
    };
    if (!isNil "MISSION_CORE_WATCHED_TRANSPORTS") then { MISSION_CORE_WATCHED_TRANSPORTS = MISSION_CORE_WATCHED_TRANSPORTS - [_truck]; };
    diag_log format ["TRANSPORT RECOVERY: truck abandoned at %1 - %2 men put on foot and pressing on", mapGridPosition (getPosATL _truck), _cargoCount];
    // Re-tasking is best-effort. A squad mounted straight from an assault spawn has no
    // MISSION_CORE_ATTACK_TARGET, and there is nothing to hand it back to - but its own order is
    // still set, so the normal commander logic re-tasks it on foot without any help from here.
    if (!isNull _cargoGrp && { count units _cargoGrp > 0 }) then {
        _cargoGrp setVariable ["MISSION_CORE_EARLY_UNLOADED", true];
        if (count _tgtPos >= 2) then {
            _cargoGrp setVariable ["MISSION_CORE_ORDER", "counterattack"];
            [_cargoGrp, _tgtPos, _tgtSize] call MISSION_CORE_fnc_sendCounterAttack;
            diag_log format ["TRANSPORT RECOVERY: %1 re-tasked to %2 on foot", groupId _cargoGrp, mapGridPosition _tgtPos];
        } else {
            diag_log format ["TRANSPORT RECOVERY: %1 has no attack target on record - left on its own %2 order to walk on", groupId _cargoGrp, _cargoGrp getVariable ["MISSION_CORE_ORDER", "?"]];
        };
    };
};

// The ladder itself. ONE truck, ONE rung, per call. Returns true when it actually did something, so
// the caller can enforce the map-wide one-at-a-time rule.
//
// State lives on the truck as MISSION_CORE_TRUCK_STUCK = [rung, lastPos, lastTick, spot, tries].
MISSION_CORE_fnc_transportStuckStep = {
    params ["_truck", "_minTick"];
    if (!([_truck] call MISSION_CORE_fnc_isWatchedFootTransport)) exitWith { false };
    private _state = _truck getVariable ["MISSION_CORE_TRUCK_STUCK", []];
    private _now = getPosATL _truck;
    if (count _state < 5) then {
        // First sample. A single position proves nothing, so record it and wait for the next tick.
        _truck setVariable ["MISSION_CORE_TRUCK_STUCK", [0, _now, time, [], 0]];
    };
    if (count _state < 5) exitWith { false };
    _state params ["_rung", "_lastPos", "_lastTick", "_spot", "_tries"];
    if (time - _lastTick < _minTick) exitWith { false };
    // Moved far enough this tick - not stuck, drop any ladder progress and keep watching.
    private _thresh = ["transportStuckMove", 3] call MISSION_CORE_fnc_tune;
    if ((_now distance2D _lastPos) > _thresh) exitWith {
        _truck setVariable ["MISSION_CORE_TRUCK_STUCK", nil];
        false
    };
    // Stalled again. Always resample first, so the NEXT turn compares against where it is now.
    _truck setVariable ["MISSION_CORE_TRUCK_STUCK", [_rung, _now, time, _spot, _tries]];

    private _cargo = (crew _truck) select { _x != driver _truck };
    private _cargoGrp = if (count _cargo > 0) then { group (_cargo select 0) } else { grpNull };
    private _origin = if (!isNull _cargoGrp) then { _cargoGrp getVariable ["MISSION_CORE_ORIGIN_MARKER", ""] } else { "" };
    private _tgt = if (!isNull _cargoGrp) then { _cargoGrp getVariable ["MISSION_CORE_ATTACK_TARGET", []] } else { [] };
    // The target is OPTIONAL. Detection and road-finding do not need it, and only 5 files in the
    // mission ever set MISSION_CORE_ATTACK_TARGET - fn_aiAssaultLoop and fn_spawnAssaultGroup only
    // read it. So a wave truck mounted straight from an assault spawn has none, and treating that as
    // a reason to stand down would disable the recovery for exactly the trucks that pile up. With no
    // target the lane falls back to the squad's own order, and at the end of the ladder the cargo
    // keeps its existing order instead of being re-tasked.
    if (count _tgt < 2) then { _tgt = []; };
    // TWO SEPARATE QUESTIONS, TWO SEPARATE VARS.
    // (1) which markers are contested - MISSION_CORE_CONTESTED, written solely by fn_isMarkerContested.
    // (2) their positions - MISSION_CORE_CACHED_POSITIONS. The 100m match and the size lookup below
    //     are geometry, not contested state, so the cache answers them.
    private _entry = [];
    if (count _tgt >= 2 && { !isNil "MISSION_CORE_CONTESTED" } && { !isNil "MISSION_CORE_CACHED_POSITIONS" }) then {
        {
            private _n = _x;
            private _i = MISSION_CORE_CACHED_POSITIONS findIf { (_x select 0) == _n };
            if (_i >= 0) then {
                private _row = MISSION_CORE_CACHED_POSITIONS select _i;
                if ((_row select 1) distance2D _tgt <= 100) then {
                    _entry = [_row select 0, _row select 1, (if (count _row > 8) then { _row select 8 } else { [200, 200] })];
                };
            };
        } forEach (keys MISSION_CORE_CONTESTED);
    };
    private _tgtName = if (count _entry > 0) then { _entry select 0 } else { "" };
    private _tgtSize = if (count _entry > 2 && { (_entry select 2) isEqualType [] }) then { _entry select 2 } else { [200, 200] };
    private _tgtPos = if (count _tgt >= 2) then { _tgt } else { [] };
    // The lane key has to identify a route even with no marker to name, so fall back to the order.
    private _laneKey = if (_tgtName != "") then { _tgtName } else { "order:" + (if (!isNull _cargoGrp) then { _cargoGrp getVariable ["MISSION_CORE_ORDER", "?"] } else { "?" }) };
    private _lane = format ["%1>%2", _origin, _laneKey];

    private _r = ["transportStuckRadius", 400] call MISSION_CORE_fnc_tune;
    if (_rung == 0) then {
        private _res = [_truck, _origin, _laneKey, _tgtPos, _tgtSize] call MISSION_CORE_fnc_getSafeRoadSpot;
        _spot = _res select 0;
        private _hits = _res select 1;
        if (count _spot == 0) then {
            // No road anywhere near here that a truck can stand on - stop wasting turns on it.
            diag_log format ["TRANSPORT RECOVERY: %1 has no safe road spot within %2m - unloading now", groupId _cargoGrp, _r];
            [_truck, _tgtPos, _tgtSize] call MISSION_CORE_fnc_unloadTransportAbandonTruck;
        };
        if (count _spot == 0) exitWith { true };
        // Same lane, same jam, second time round: the road is probably choked with trees.
        if (_hits >= 2) then {
            private _cut = [_spot, 50] call MISSION_CORE_fnc_clearTreesNear;
            if (_cut > 0) then {
                diag_log format ["TRANSPORT RECOVERY: lane %1 jammed again - cleared %2 trees in 50m at %3", _lane, _cut, mapGridPosition _spot];
            };
        };
        private _drvGrp = _truck getVariable ["MISSION_CORE_DRIVER_GROUP", grpNull];
        private _mover = if (!isNull _drvGrp && { count units _drvGrp > 0 }) then { _drvGrp } else { _cargoGrp };
        [_mover] call MISSION_CORE_fnc_clearGroupWaypoints;
        private _wp = _mover addWaypoint [_spot, 15];
        _wp setWaypointType "MOVE";
        _wp setWaypointSpeed "FULL";
        _wp setWaypointBehaviour "SAFE";
        _mover setCurrentWaypoint _wp;
        _truck setVariable ["MISSION_CORE_TRUCK_STUCK", [1, _now, time, _spot, _tries]];
        diag_log format ["TRANSPORT RECOVERY: %1 stalled at %2 - ordered a move to road spot %3 (%4m)", groupId _cargoGrp, mapGridPosition _now, mapGridPosition _spot, round (_now distance2D _spot)];
        true
    };
    if (_rung == 1) then {
        if (count _spot == 0) exitWith { false };
        if (_now distance2D _spot < 25) exitWith {
            // It actually got itself onto the road spot; give the order a turn to show results.
            _truck setVariable ["MISSION_CORE_TRUCK_STUCK", nil];
            false
        };
        // The waypoint did not free it. Lift it onto the road directly - the only thing that
        // unwedges a truck that is physically pinning the ones behind it.
        _truck setPos _spot;
        _truck setPosATL _spot;
        _truck setVectorUp surfaceNormal _spot;
        [_truck] call MISSION_CORE_fnc_alignVehicleToRoad;
        diag_log format ["TRANSPORT RECOVERY: %1 ignored the road order - teleported to %2", groupId _cargoGrp, mapGridPosition _spot];
        _truck setVariable ["MISSION_CORE_TRUCK_STUCK", [2, _now, time, _spot, _tries]];
        true
    };
    if (_rung == 2) then {
        // The truck is sitting where we put it but still has not moved, so it is wedged on
        // something a position check cannot see. Re-validate the spot: if the ground itself has
        // become unusable (wreck, flagged kill zone) go hunting for another one, otherwise the
        // spot stands and the ladder moves on to walking.
        private _spotOk = (count _spot >= 2) && { !([_spot] call MISSION_CORE_fnc_isUnsafeVehicleSpawn) } && { [_spot] call MISSION_CORE_fnc_isDryPos };
        if (_spotOk) exitWith {
            _truck setVariable ["MISSION_CORE_TRUCK_STUCK", [3, _now, time, _spot, _tries]];
            true
        };
        private _tries2 = _tries + 1;
        diag_log format ["TRANSPORT RECOVERY: %1 - spot %2 is no longer usable, looking for a new one (try %3)", groupId _cargoGrp, mapGridPosition _spot, _tries2];
        if (_tries2 > (["transportStuckMaxTries", 2] call MISSION_CORE_fnc_tune)) exitWith {
            diag_log format ["TRANSPORT RECOVERY: %1 - no usable spot after %2 tries, unloading", groupId _cargoGrp, _tries2];
            [_truck, _tgtPos, _tgtSize] call MISSION_CORE_fnc_unloadTransportAbandonTruck;
            true
        };
        _truck setVariable ["MISSION_CORE_TRUCK_STUCK", [0, _now, time, [], _tries2]];
        true
    };
    if (_rung == 3) then {
        diag_log format ["TRANSPORT RECOVERY: %1 - ladder exhausted, unloading and deleting the truck", groupId _cargoGrp];
        [_truck, _tgtPos, _tgtSize] call MISSION_CORE_fnc_unloadTransportAbandonTruck;
        true
    };
    false
};

// One map-wide recovery per tick. Picks the single most-stalled watched truck and advances its
// ladder by exactly one rung, so two trucks are never being rescued at the same moment - which is
// the failure mode that created the pile-up in the first place.
MISSION_CORE_fnc_recoverOneFootTransport = {
    if (isNil "MISSION_CORE_WATCHED_TRANSPORTS") exitWith { false };
    // Compact the watch list here rather than only on the abandon path: trucks destroyed in a normal
    // battle would otherwise linger as dead references for the length of the session, and this
    // filter runs once a tick anyway.
    private _cands = MISSION_CORE_WATCHED_TRANSPORTS select {
        !isNull _x && { alive _x } && { [_x] call MISSION_CORE_fnc_isWatchedFootTransport }
    };
    MISSION_CORE_WATCHED_TRANSPORTS = _cands;
    if (count _cands == 0) exitWith { false };
    // Oldest stalled first, so nobody waits behind a queue.
    private _bestTruck = objNull;
    private _bestAge = -1;
    {
        private _st = _x getVariable ["MISSION_CORE_TRUCK_STUCK", []];
        if (count _st >= 3) then {
            private _age = time - (_st select 2);
            if (_age > _bestAge) then { _bestAge = _age; _bestTruck = _x; };
        };
    } forEach _cands;
    if (isNull _bestTruck) exitWith { false };
    // A much tighter sample than the old sweeper's 30s: a column stacked behind a stalled truck is
    // already lost by the time a 30s cadence lands its first rescue.
    private _minTick = ["transportStuckTick", 10] call MISSION_CORE_fnc_tune;
    [_bestTruck, _minTick] call MISSION_CORE_fnc_transportStuckStep
};

// Register a freshly mounted foot transport for stuck watching. Called by fn_mountInfantry.
MISSION_CORE_fnc_watchFootTransport = {
    params ["_truck"];
    if (isNull _truck) exitWith {};
    if (isNil "MISSION_CORE_WATCHED_TRANSPORTS") then { MISSION_CORE_WATCHED_TRANSPORTS = []; };
    if !(_truck in MISSION_CORE_WATCHED_TRANSPORTS) then { MISSION_CORE_WATCHED_TRANSPORTS pushBack _truck; };
};
