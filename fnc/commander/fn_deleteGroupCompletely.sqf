// Delete a group AND every vehicle it owns along with the dedicated driver group of each
// foot-transport truck (fn_mountInfantry spawns drivers in their own group via
// MISSION_CORE_DRIVER_GROUP, so those drivers+trucks are NOT in MISSION_CORE_SPAWNED_GROUPS and
// leak unless cleaned up here). Removes the group from the spawned registry too.
MISSION_CORE_fnc_deleteGroupCompletely = {
    params ["_grp"];
    if (isNull _grp) exitWith {};
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
