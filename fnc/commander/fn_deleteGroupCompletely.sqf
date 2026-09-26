// Delete a group AND every vehicle it owns along with the dedicated driver group of each
// foot-transport truck (fn_mountInfantry spawns drivers in their own group via
// MISSION_CORE_DRIVER_GROUP, so those drivers+trucks are NOT in MISSION_CORE_SPAWNED_GROUPS and
// leak unless cleaned up here). Removes the group from the spawned registry too.
MISSION_CORE_fnc_deleteGroupCompletely = {
    params ["_grp"];
    if (isNull _grp) exitWith {};
    // Never delete a player, and never delete a group that still has one: deleteGroup on a group
    // with a player member would strip the player's squad membership out from under them. Bail on
    // the WHOLE group rather than skipping the human - a despawn pass must never be the thing that
    // deletes a player or silently un-groups them. Every current caller is an AI-only flow, so
    // this only ever fires on a group that has genuinely gone player-run.
    if ({ isPlayer _x } count units _grp > 0) exitWith {
        diag_log format ["DELETE-GROUP: refusing to delete %1 - group contains a player", _grp];
    };
    private _vehs = [];
    { private _v = vehicle _x; if (_v != _x && { alive _v } && { !(_v in _vehs) }) then { _vehs pushBack _v; }; } forEach units _grp;
    // Dedicated foot-transport driver groups own their truck - delete truck + crew + group as a set
    private _drvGrps = [];
    {
        private _dg = _x getVariable ["MISSION_CORE_DRIVER_GROUP", grpNull];
        if (!isNull _dg && { !(_dg in _drvGrps) }) then { _drvGrps pushBack _dg; };
    } forEach _vehs;
    {
        if (!isNull _x) then {
            { if (!isNull _x) then { deleteVehicle _x; }; } forEach units _x;
            deleteGroup _x;
        };
    } forEach _drvGrps;
    { deleteVehicle _x; } forEach units _grp;
    { deleteVehicle _x; } forEach _vehs;
    deleteGroup _grp;
    if (!isNil "MISSION_CORE_SPAWNED_GROUPS") then { MISSION_CORE_SPAWNED_GROUPS = MISSION_CORE_SPAWNED_GROUPS - [_grp]; };
};
