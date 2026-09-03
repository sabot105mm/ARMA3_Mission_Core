// transport_assaultUnload.sqf
// Fired by setWaypointScript on a troop-transport's UNLOAD waypoint (AI assault waves,
// counter-attack transports, and player-hunt trucks). Dismounts every rider - including the
// driver - unlocks then relocks cargo so nobody can re-board, re-enables AUTOCOMBAT, and sets
// combat mode to attack. It deliberately does NOT touch the group's waypoints: each path keeps
// its own existing post-unload plan (SAD at the contested marker, assault chain, or hunt sweep).
// _this = [groupLeader, waypointPos, targetObject]
// The first element may be the GROUP or its leader, per the engine waypointScript contract.
// Runs on the machine that owns the group (the server running the assault/commander loops).
params ["_leader", "_wpPos", "_target"];

private _grp = if (typeName _leader == "GROUP") then { _leader } else { group _leader };
if (isNull _grp || { count units _grp == 0 }) exitWith {};

private _veh = objNull;
// Prefer the vehicle the group leader is actually riding; fall back to whichever transport the
// squad is mounted in (a transport column uses the driver's vehicle, which may differ from the
// leader's if several trucks were spawned).
{
    if (!isNull _x && { alive _x } && { vehicle _x != _x }) exitWith { _veh = vehicle _x; };
} forEach units _grp;
if (isNull _veh) exitWith {};

// Unlock so moveOut can force the driver out, dismount everyone, then re-lock so the on-foot
// squad can never climb back aboard while the fight is on.
_veh lock false;
{
    if (vehicle _x == _veh) then {
        unassignVehicle _x;
        [_x] orderGetIn false;
        _x action ["getOut", _veh];
    };
} forEach units _grp;

// Force the driver out only when he is part of THIS group (recruit / assault-wave transports
// ride with their own driver). When a separate dedicated driver group owns the truck (counter-
// attack and player-hunt transports), we leave that driver alone - his own group's TR UNLOAD
// handles the truck, and yanking him here would strand the transport mid-route. doGetOut ignores
// the lock, moveOut is a hard fallback, and the loop guards against re-seating before combat mode.
private _drv = driver _veh;
private _retry = 0;
while { !isNull _drv && { group _drv == _grp } && { vehicle _drv == _veh } && _retry < 25 } do {
    unassignVehicle _drv;
    [_drv] orderGetIn false;
    doGetOut _drv;
    moveOut _drv;
    sleep 0.4;
    _drv = driver _veh;
    _retry = _retry + 1;
};

_veh lockCargo true;

// Re-enable combat and let them fight - the group's existing next waypoint(s) take over.
{
    if (vehicle _x == _x) then { _x enableAI "AUTOCOMBAT"; };
} forEach units _grp;
_grp setCombatMode "RED";
_grp setBehaviour "AWARE";

diag_log format ["DYNOPS TRANSPORT UNLOAD: %1 squad dismounted via waypoint script", groupId _grp];