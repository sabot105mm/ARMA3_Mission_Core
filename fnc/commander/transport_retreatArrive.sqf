// transport_retreatArrive.sqf
// Fired by setWaypointScript when a retreating garrison (defense collapse or hunt contingent) reaches
// its retreat-destination MOVE waypoint. Despawns the group completely on arrival - replaces the old
// 5s polling loop that watched the leader close on the destination.
//
// _this = [groupLeader, waypointPos, targetObject]
// The first element may be the GROUP or its leader, per the engine waypointScript contract.
params ["_leader", "_wpPos", "_target"];

private _grp = if (typeName _leader == "GROUP") then { _leader } else { group _leader };
if (isNull _grp || { { alive _x } count units _grp == 0 }) exitWith {};

diag_log format ["TRANSPORT RETREAT ARRIVE: %1 reached %2 - despawning", groupId _grp, _wpPos];
[_grp] call MISSION_CORE_fnc_deleteGroupCompletely;