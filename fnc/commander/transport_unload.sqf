// transport_unload.sqf
// Fired by setWaypointScript when a recruited transport reaches its UNLOAD waypoint.
// _this = [groupLeader, waypointPos, targetObject, ...userArgs]
// Runs on the machine that owns the group (the client that spawned the transport), where the
// recruitment functions are compiled, so MISSION_CORE_fnc_applyAssaultWaypoints is available.
params ["_leader", "_wpPos", "_target"];

private _grp = group _leader;
if (isNull _grp || { count units _grp == 0 }) exitWith {};

private _veh = vehicle _leader;
if (isNull _veh) exitWith {};

// Bring the truck to a FULL STOP before ejecting anyone: the UNLOAD waypoint completes against a
// tight radius while the truck is still rolling, and ejecting from a moving vehicle throws men out
// at speed and kills them on landing. Order the driver to stop and wait until the wheels actually
// stop, then eject. New waypoints assigned later cancel the doStop so the truck can drive on.
if (alive _veh) then {
    _veh setSpeedMode "LIMITED";
    private _drvStop = driver _veh;
    if (!isNull _drvStop) then { doStop _drvStop; };
    private _stopBy = time + 6;
    waitUntil { sleep 0.2; isNull _veh || { !(alive _veh) } || { speed _veh < 2 } || { time > _stopBy } };
};

// Unlock the transport first: moveOut (like action "Eject") respects the vehicle's lock state, so
// a locked vehicle would silently stop the driver from being forced out. We unlock, dismount
// everyone, then re-lock cargo afterwards to keep the on-foot squad from re-boarding.
_veh lock false;

// Order every squad member still mounted to disembark. orderGetIn false makes AI leave even while
// seats are locked; action getOut ejects them immediately.
{
    if (vehicle _x == _veh) then {
        unassignVehicle _x;
        [_x] orderGetIn false;
        _x action ["getOut", _veh];
    };
} forEach units _grp;

// Force the driver out and keep retrying until he is really out. doGetOut ignores the vehicle lock
// state (unlike moveOut) and works on local AI; moveOut is used as a hard fallback. The loop guards
// against the driver re-seating himself before the assault waypoints take over.
private _drv = driver _veh;
private _retry = 0;
while { !isNull _drv && { vehicle _drv == _veh } && _retry < 25 } do {
    unassignVehicle _drv;
    [_drv] orderGetIn false;
    doGetOut _drv;
    moveOut _drv;
    sleep 0.4;
    _drv = driver _veh;
    _retry = _retry + 1;
};

// Re-lock cargo so the on-foot squad can never re-board the transport.
_veh lockCargo true;

// Hand the squad over to their saved assault waypoint chain.
private _wps = _grp getVariable ["MISSION_CORE_TRANSPORT_WPS", []];
private _targetPos = _grp getVariable ["MISSION_CORE_TRANSPORT_TARGET", _wpPos];
[_grp, _wps, _targetPos] call MISSION_CORE_fnc_applyAssaultWaypoints;

_grp setBehaviour "AWARE";
_grp setCombatMode "YELLOW";

diag_log format ["DYNOPS TRANSPORT: %1 squad dismounted at UNLOAD waypoint", groupId _grp];
