// DRIVER waypoints for a transport truck carrying an assault squad to a target.
//
// Separate from the hunt builder (fn_buildHuntApproachWps) on purpose: a hunt is driven by the
// squad's own leader group, which needs only an approach LKP and a finish, while a counter-attack /
// reinforcement truck has a DEDICATED driver group (MISSION_CORE_DRIVER_GROUP) whose job ends at
// the drop ring with a scripted unload. They share fn_transportStagePos for the staging point and
// nothing else.
//
// The staging waypoint replaces the old fn_supplyRoute call, which computed a whole road route
// through the origin's neighborhood and then discarded it - the caller overwrote the driver's
// current waypoint with the drop ring, so the route nodes were never driven. One staging waypoint
// near the origin is enough to clear the marker being left; from there the driver goes straight for
// the ring at CARELESS/GREEN, which is the behaviour the single-MOVE version had before the route
// detour was introduced.
//
// Gun trucks and armor do NOT come through here: fn_mountInfantry gives them no dedicated driver
// group, so they self-drive on their own squad group and fn_sendCounterAttack stages them inline and
// then calls _addAssaultWps itself, keeping the GETOUT + SAD tail. Only trucks with a real
// MISSION_CORE_DRIVER_GROUP reach this builder, and that group's job ends at the drop ring.
MISSION_CORE_fnc_buildTruckDriverWps = {
    params ["_drvGrp", "_truckPos", "_targetPos", "_advSpeed", "_unloadDist"];
    if (isNull _drvGrp) exitWith {};
    [_drvGrp] call MISSION_CORE_fnc_clearGroupWaypoints;

    private _stage = [_truckPos, _targetPos] call MISSION_CORE_fnc_transportStagePos;

    // Staging: clear the origin marker before committing to the drive. No waypointScript here -
    // transport_assaultUnload performs the unload, and firing it on a staging node would drop the
    // squad at the staging point instead of the target.
    private _wpStage = _drvGrp addWaypoint [_stage, 15];
    _wpStage setWaypointType "MOVE";
    _wpStage setWaypointSpeed _advSpeed;
    _wpStage setWaypointBehaviour "CARELESS";

    // CARELESS + GREEN so the truck drives straight to the drop ring instead of stopping to engage
    // en route (a stationary truck gives passengers a chance to bail out early).
    _drvGrp setCombatMode "GREEN";
    _drvGrp setBehaviour "CARELESS";

    // MOVE first (pre-1.22 rule), then TRANSPORT UNLOAD at the same ring to drop cargo. The
    // waypoint script lives on the DRIVER's TR UNLOAD (not the passenger GETOUT) so the truck's own
    // unload event is script-driven and stays in sync with the dismount - a bare native TR UNLOAD on
    // the driver can desync from the passenger group's scripted dismount.
    private _wpDrvMove = _drvGrp addWaypoint [_targetPos, _unloadDist];
    _wpDrvMove setWaypointType "MOVE";
    _wpDrvMove setWaypointSpeed _advSpeed;
    _wpDrvMove setWaypointBehaviour "CARELESS";
    _wpDrvMove setWaypointScript "fnc\commander\transport_assaultUnload.sqf";
    private _wpUnload = _drvGrp addWaypoint [_targetPos, _unloadDist];
    _wpUnload setWaypointType "TR UNLOAD";
    _wpUnload setWaypointSpeed _advSpeed;
    _wpUnload setWaypointBehaviour "CARELESS";
    _wpUnload setWaypointScript "fnc\commander\transport_assaultUnload.sqf";

    // Start at the staging point so the truck clears its origin before the long drive.
    _drvGrp setCurrentWaypoint _wpStage;
    _wpUnload
};