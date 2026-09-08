// transport_tankArrival.sqf
// Fired by setWaypointScript when a PLAYER-PROXIMITY materialized tank shipment reaches the
// end of its road path (completion radius = half the target marker's size), so the convoy was
// physically driven in and seen arrive. It never stays as standing defenders - it despawns back
// into the target marker's tank pool, exactly like the abstract arrival path.
// _this = [groupLeader, waypointPos, targetObject]
// The shipment data (side/depot/target/count/vehicles) was stamped onto the group when it
// materialized (MISSION_CORE_TANK_SHIP_*), so no arguments need to ride the waypointScript
// string. Runs on the machine that owns the group (the server that runs fn_tankOrderLoop),
// where the tank delivery globals are live.
params ["_leader", "_wpPos", "_target"];

// Element 0 is the group leader unit per this script's contract, but tolerate an engine binding
// that passes the GROUP itself as the first element - either way the convoy must be cleaned up.
private _sGrp = if (typeName _leader == "GROUP") then { _leader } else { group _leader };
if (isNull _sGrp || { count units _sGrp == 0 }) exitWith {};

private _sSide = _sGrp getVariable ["MISSION_CORE_TANK_SHIP_SIDE", WEST];
private _sDepot = _sGrp getVariable ["MISSION_CORE_TANK_SHIP_DEPOT", ""];
private _sTarget = _sGrp getVariable ["MISSION_CORE_TANK_SHIP_TARGET", ""];
private _sCount = _sGrp getVariable ["MISSION_CORE_TANK_SHIP_COUNT", 0];
private _sVehs = _sGrp getVariable ["MISSION_CORE_TANK_SHIP_VEHS", []];
if (count _sVehs == 0) exitWith {};

// Idempotency guard: the pool must only ever be credited once per shipment (the destroyed-en-route
// Killed handler in fn_tankOrderLoop flicks the same flag, so the two paths never double-account).
if (_sGrp getVariable ["MISSION_CORE_TANK_ARRIVED", false]) exitWith {};
_sGrp setVariable ["MISSION_CORE_TANK_ARRIVED", true];

// Shared accounting: credits inflight/DELIVERED exactly once. If the target marker is awaiting an
// assault, the live convoy is kept and registered for the assault commit; otherwise it despawns to
// the pool inside the helper (standing tanks were getting re-tasked to defend a neighbor).
[_sSide, _sTarget, _sCount, _sGrp, _sVehs] call MISSION_CORE_fnc_tankDeliverAccount;