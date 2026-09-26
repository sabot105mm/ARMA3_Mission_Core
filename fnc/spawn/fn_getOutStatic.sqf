// GET-OUT: STATIC WEAPONS -------------------------------------------------------------------
// Emplacements and tower guns are crewed, so their gunner has a GetOut event like any driver - but
// a static weapon is the ONE vehicle role in this family where an empty crew is the correct,
// intended outcome, and the mission already has a permanent rule saying so.
//
// PERMANENT RULE (fn_monitorCrew): a surviving static weapon whose gunner is killed stays EMPTY.
// No replacement soldier is ever spawned into it. The emplacement is a fixed position on the map
// and its crew is drawn from the marker's existing garrison - the gunner is not a purchased
// transport, a tank delivery, or a shipment, so there is no resource to lose, refund, or replace.
//
// So this script does nothing on purpose. It is not a stub and it is not an oversight: adding a
// replacement here would silently break a rule the player can see (a cleared tower stays cleared
// and is never re-garrisoned). All it does is record the event so the log shows a gunner stepping
// off a position, which is the only way to tell an intentional stand-off from a crew that lost its
// nerve.
//
// Note the shared dispatcher already latched MISSION_CORE_GETOUT_RESOLVED before calling this, so
// the remaining gunner and commander of the same emplacement do not each log separately.
MISSION_CORE_fnc_getOutStatic = {
    params ["_veh", "_role", "_unit", "_turret", "_isEject"];
    if (isNull _veh) exitWith {};
    diag_log format ["GET-OUT: static weapon %1 at %2 - crew stepped off, left EMPTY by permanent rule (no replacement)", typeOf _veh, mapGridPosition (getPos _veh)];
};
