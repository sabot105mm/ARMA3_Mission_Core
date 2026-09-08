// transport_truckArrive.sqf
// Fired by setWaypointScript when a transport truck's dedicated driver group reaches its home MOVE
// waypoint. Despawns driver + truck + driver group on arrival - replaces the old 3-5s polling loop
// that watched the truck close on the spawn point. The driver group arrives once the truck is
// within a few metres of home, so this fires exactly when the old waitUntil would have cleaned up.
//
// _this = [groupLeader, waypointPos, targetObject]
// The first element may be the GROUP or its leader, per the engine waypointScript contract.
params ["_leader", "_wpPos", "_target"];

private _grp = if (typeName _leader == "GROUP") then { _leader } else { group _leader };
if (isNull _grp) exitWith {};

// Resolve the truck: the driver is riding it on arrival (or was ejected/fell - then there is no
// truck left to clean up beyond the group itself).
private _veh = objNull;
{ if (!isNull _x && { alive _x } && { vehicle _x != _x }) exitWith { _veh = vehicle _x; }; } forEach units _grp;

{
    if (!isNull _x) then { deleteVehicle _x; };
} forEach units _grp;
if (!isNull _veh && { alive _veh }) then { deleteVehicle _veh; };
deleteGroup _grp;

diag_log format ["TRANSPORT TRUCK ARRIVE: driver group despawned truck %1 at %2", if (isNull _veh) then { "?" } else { typeOf _veh }, _wpPos];