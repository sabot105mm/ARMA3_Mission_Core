// transport_assaultUnload.sqf
// Fired by setWaypointScript on a troop-transport's UNLOAD waypoint (AI assault waves,
// counter-attack transports, and player-hunt trucks). Dismounts every rider - EXCEPT the truck's
// driver, who keeps the truck to drive it away - unlocks then relocks cargo so nobody can re-board,
// re-enables AUTOCOMBAT on the dismounted foot, and sets combat mode to attack. It deliberately
// does NOT touch the groups' waypoints: each path keeps its own existing post-unload plan (SAD at
// the contested marker, assault chain, or hunt sweep).
//
// The script is attached to whatever waypoint pauses at the unload ring - the passenger group's
// GETOUT/MOVE (assault waves, player hunt) OR the dedicated driver group's TR UNLOAD (counter-
// attack). Either way the DRIVER always stays seated and all riders dismount, so a counter-attack
// truck (script on the driver group) unloads its passengers just as reliably as a wave truck
// (script on the passenger group), and never strands or doubles the driver.
//
// _this = [groupLeader, waypointPos, targetObject]
// The first element may be the GROUP or its leader, per the engine waypointScript contract.
// Runs on the machine that owns the group (the server running the assault/commander loops).
params ["_leader", "_wpPos", "_target"];

private _grp = if (typeName _leader == "GROUP") then { _leader } else { group _leader };
if (isNull _grp || { count units _grp == 0 }) exitWith {};

// Resolve the transport: the group leader may be the driver (driver-group attachment) or a rider
// (passenger-group attachment). Fall back to whichever vehicle any unit of the group is riding.
private _veh = objNull;
{
    if (!isNull _x && { alive _x } && { vehicle _x != _x }) exitWith { _veh = vehicle _x; };
} forEach units _grp;
if (isNull _veh) exitWith {};

private _drv = driver _veh;

// Unlock so moveOut/getOut can force riders out, then re-lock so the on-foot squad can never
// climb back aboard while the fight is on. Bring the truck to a FULL STOP first: the unload ring
// completes while the truck can still be moving, and ejecting from a moving vehicle kills the men.
// New waypoints assigned after the drop cancel the doStop so the truck can drive on.
_veh lock false;
if (alive _veh) then {
    _veh setSpeedMode "LIMITED";
    private _drvStop = driver _veh;
    if (!isNull _drvStop) then { doStop _drvStop; };
    private _stopBy = time + 6;
    waitUntil { sleep 0.2; isNull _veh || { !(alive _veh) } || { speed _veh < 2 } || { time > _stopBy } };
};
private _riders = crew _veh;
{
    if (_x isEqualTo _drv) then { continue; };
    if (vehicle _x != _veh) then { continue; };
    unassignVehicle _x;
    [_x] orderGetIn false;
    _x action ["getOut", _veh];
} forEach _riders;

// Give the engine a beat to finish the getOut animation before relocking cargo.
sleep 0.6;

_veh lockCargo true;

// Re-enable combat and let the foot squads fight - each group's existing next waypoint(s) take over.
private _footGroups = [];
{
    if (vehicle _x == _x) then {
        _x enableAI "AUTOCOMBAT";
        private _g = group _x;
        if (!(_g in _footGroups)) then { _footGroups pushBack _g; };
    };
} forEach _riders;
{
    _x setCombatMode "RED";
    _x setBehaviour "AWARE";
} forEach _footGroups;

private _drvId = if (isNull _drv) then { "none" } else { groupId (group _drv) };
diag_log format ["DYNOPS TRANSPORT UNLOAD: %1 dismounted %2 riders via waypoint script (drv %3 stays)", groupId _grp, count _riders, _drvId];
