// Safety net for foot-transport trucks (fn_mountInfantry). The normal counter-attack / assault /
// hunt / return paths each drive their dedicated driver group back to spawn and despawn the truck
// + driver on arrival. If any of those paths is interrupted (a squad wiped mid-ride, a timeout, a
// script abort), the empty truck + its driver group can be left idling and never cleaned up.
//
// This sweeper finds the abandoned ones: a foot-transport truck is identified by the
// MISSION_CORE_DRIVER_GROUP handle (set ONLY on non-gun transports by fn_mountInfantry). It is
// abandoned when the truck is alive, has no living non-driver passengers, and its driver group has
// been sitting idle (not moving) for the idle window. Those are recycled: driver deleted, truck
// deleted, driver group deleted. Conservatively never touches a truck that is moving (still en
// route home) or one that still carries passengers (still mid-ride).
MISSION_CORE_fnc_truckCleanupLoop = {
    diag_log "TRUCK CLEANUP: sweeper started";
    if (isNil "MISSION_CORE_TRUCK_IDLE_SINCE") then { MISSION_CORE_TRUCK_IDLE_SINCE = createHashMap; };
    private _idleWindow = ["truckCleanupIdleWindow", 60] call MISSION_CORE_fnc_tune;
    private _stuckWindow = ["stuckVehicleTime", 90] call MISSION_CORE_fnc_tune;
    while { true } do {
        sleep 30;
        {
            private _veh = _x;
            if (isNull _veh || { !(alive _veh) }) then { continue; };
            // Only non-gun foot-transport trucks carry the driver-group handle - skip everything else.
            private _drvGrp = _veh getVariable ["MISSION_CORE_DRIVER_GROUP", grpNull];
            if (isNull _drvGrp) then { continue; };
            // Driver must exist and be driving, otherwise the truck is just an orphan without a crew.
            private _drv = driver _veh;
            if (isNull _drv || { !(alive _drv) }) then { continue; };
            private _pax = (crew _veh) select { alive _x && { _x != _drv } };
            private _key = str _veh;
            // A truck that is MOVING (back to spawn, en route, or recovering from a pause) is doing
            // its route - reset its idle clock so a short pause never accumulates toward a recycle.
            if (speed _veh > 1) then { MISSION_CORE_TRUCK_IDLE_SINCE deleteAt _key; continue; };
            // Require the truck to sit idle for the whole window before recycling, so a truck paused
            // for a beat (or one that just dropped cargo) is never deleted prematurely.
            private _firstSeen = MISSION_CORE_TRUCK_IDLE_SINCE getOrDefault [_key, nil];
            if (isNil "_firstSeen") then {
                MISSION_CORE_TRUCK_IDLE_SINCE set [_key, [time, _veh]];
                continue;
            };
            private _idleFor = time - (_firstSeen select 0);
            // STUCK mid-ride: a truck that still carries its squad but has NOT moved for the stuck
            // window (wedged on a rock or into geometry, trying to drive but cannot) is recycled too
            // - the squad is dismounted onto foot FIRST so the ride continues as infantry, then the
            // driver + truck + driver group are deleted.
            if (count _pax > 0) then {
                if (_idleFor < _stuckWindow) then { continue; };
                diag_log format ["TRUCK CLEANUP: recycling STUCK foot-transport %1 (stuck %2s, dismounting %3 passengers)", typeOf _veh, round _idleFor, count _pax];
                { moveOut _x; } forEach _pax;
            } else {
                if (_idleFor < _idleWindow) then { continue; };
                diag_log format ["TRUCK CLEANUP: recycling abandoned foot-transport %1 (idle %2s, no passengers)", typeOf _veh, round _idleFor];
            };
            { if (!isNull _x) then { deleteVehicle _x; }; } forEach (units _drvGrp);
            deleteVehicle _veh;
            deleteGroup _drvGrp;
            MISSION_CORE_TRUCK_IDLE_SINCE deleteAt _key;
        } forEach vehicles;
        // Drop stale entries whose tracked truck no longer exists (cleaned by the normal paths too).
        private _toDrop = [];
        {
            private _k = _x;
            private _entry = MISSION_CORE_TRUCK_IDLE_SINCE get _k;
            if (isNil "_entry" || { isNull (_entry select 1) } || { !(alive (_entry select 1)) }) then {
                _toDrop pushBack _k;
            };
        } forEach (keys MISSION_CORE_TRUCK_IDLE_SINCE);
        { MISSION_CORE_TRUCK_IDLE_SINCE deleteAt _x; } forEach _toDrop;
    };
};
