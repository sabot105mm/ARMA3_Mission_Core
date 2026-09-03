// transport_tankWriteoff.sqf
// Fired by setWaypointScript when the bailed crew of a WRITE-OFF materialized tank reaches the
// nearest friendly marker. The tank itself was already removed and accounted by the shipment
// loop (inflight decremented, vehicle deleted); this script only despawns the runners.
// _this = [groupLeader, waypointPos, targetObject]
// The first element may be the GROUP or its leader, per the engine waypointScript contract.
// Runs on the owning machine (the server that runs fn_tankOrderLoop).
params ["_leader", "_wpPos", "_target"];

private _sGrp = if (typeName _leader == "GROUP") then { _leader } else { group _leader };
if (isNull _sGrp) exitWith {};

// Stop the group if it still has waypoints, then despawn the whole contingent.
[_sGrp] call MISSION_CORE_fnc_clearGroupWaypoints;
{ if (!isNull _x) then { deleteVehicle _x; }; } forEach units _sGrp;
deleteGroup _sGrp;