// transport_returnOrigin.sqf
// Fired by setWaypointScript when a returning foot squad reaches its origin GETOUT waypoint
// (footSquadPostAssault). Two jobs, all on arrival - no polling loops:
//   1. Resume the squad's marker patrol (restartPatrol).
//   2. Send the return truck's dedicated driver group back to the truck's spawn; the driver's home
//      MOVE carries transport_truckArrive.sqf, which despawns crew + truck + group on arrival.
//
// _this = [groupLeader, waypointPos, targetObject]
// The first element may be the GROUP or its leader, per the engine waypointScript contract.
params ["_leader", "_wpPos", "_target"];

private _grp = if (typeName _leader == "GROUP") then { _leader } else { group _leader };
if (isNull _grp) exitWith {};

// The squad reached home - resume its normal marker patrol (safe, limited, WHITE).
[_grp] call MISSION_CORE_fnc_restartPatrol;

// The return ride's truck and dedicated driver group were handed over by the caller.
private _veh = _grp getVariable ["MISSION_CORE_RETURN_TRUCK", objNull];
private _dg = _grp getVariable ["MISSION_CORE_RETURN_DRV", grpNull];
if (isNull _veh || { !(alive _veh) }) exitWith {};
if (isNull _dg) then {
    // No driver group to ride it home - just clear the vehicle.
    { if (!isNull _x) then { deleteVehicle _x; }; } forEach units _veh;
    deleteVehicle _veh;
} else {
    private _home = _veh getVariable ["MISSION_CORE_TRUCK_ORIGIN", getPos _veh];
    _dg setBehaviour "CARELESS";
    _dg setSpeedMode "FULL";
    [_dg] call MISSION_CORE_fnc_clearGroupWaypoints;
    private _wpHome = _dg addWaypoint [_home, 20];
    _wpHome setWaypointType "MOVE";
    _wpHome setWaypointSpeed "FULL";
    _wpHome setWaypointBehaviour "CARELESS";
    _wpHome setWaypointScript "fnc\commander\transport_truckArrive.sqf";
    _dg setCurrentWaypoint _wpHome;
};