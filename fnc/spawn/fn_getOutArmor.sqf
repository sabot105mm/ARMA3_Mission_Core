// GET-OUT: ARMOR - entry point.
// Thin synchronous shim. Reads the verdict, then hands the work to the worker on its own thread so
// the GetOut event handler returns immediately and never blocks the engine on a sleep.
//
// The crew bails as a group, so by the time the worker runs the other two may already be on the
// ground. It re-collects the whole crew from the hull's own group rather than trusting the single
// unit this handler was called for, which is what restores a three-man crew as three.
//
// Split across three files (verdict, worker, entry) purely so a compile failure in any one of them
// is attributable from the startup log instead of showing up as one anonymous broken file.
MISSION_CORE_fnc_getOutArmor = {
    params ["_veh", "_role", "_unit", "_turret", "_isEject"];
    if (isNull _veh) exitWith {};
    if (!alive _veh) exitWith {};
    private _verdict = [];
    _verdict = [_veh] call MISSION_CORE_fnc_getOutArmorVerdict;
    private _lost = false;
    private _isEconomy = false;
    _lost = _verdict select 0;
    _isEconomy = _verdict select 1;
    [_veh, _unit, _lost, _isEconomy] spawn MISSION_CORE_fnc_getOutArmorWorker;
};
diag_log format ["GETOUT ARMOR: fn_getOutArmor.sqf compiled, helper defined=%1", !(isNil "MISSION_CORE_fnc_getOutArmor")];
