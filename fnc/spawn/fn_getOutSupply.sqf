// GET-OUT: SUPPLY / AMMO CONVOY TRUCK ------------------------------------------------------
// fn_convoyLoop ships ammunition and utility supply between markers as a physical truck: the
// recipient only receives the supply when the truck actually arrives. There is no garrison, no
// crew order, and nothing to recover here - a convoy truck is cargo on wheels, and the moment its
// crew walks away the shipment it represents is not going to complete.
//
// So this role is the simplest one in the family and deliberately so: the truck is deleted, and
// deleteVehicle FIRES whatever the convoy loop uses to notice the loss, which takes the supply
// out of the world exactly as a shot-up truck would. That is the whole "mirror the Killed handler"
// contract - there is no second copy of the convoy's supply accounting to drift.
//
// This is the ammo half of "if the crew gets out for any reason, that resource is lost". The tanks
// half is fn_getOutArmor, the manpower half is the two unassign/despawn paths in
// fn_getOutTransport, which never delete a passenger.
//
// The crew are deleted with the truck rather than left standing: they exist only to drive the
// shipment (fn_convoyLoop creates a driver group for it), and a group of drivers with no truck
// would sit in the convoy loop's record for ever. Units are removed from the vehicle BEFORE the
// vehicle is deleted, so nothing is left in a crew slot at deletion time.
MISSION_CORE_fnc_getOutSupply = {
    params ["_veh", "_role", "_unit", "_turret", "_isEject"];
    if (isNull _veh || { !alive _veh }) exitWith {};
    diag_log format ["GET-OUT: supply convoy truck %1 abandoned by its crew at %2 - shipment lost", typeOf _veh, mapGridPosition (getPos _veh)];
    // Pull the crew out of their seats first so the delete never hits a crewed unit.
    private _crew = crew _veh;
    { if (!isNull _x) then { unassignVehicle _x; _x leaveVehicle _veh; }; } forEach _crew;
    // deleteVehicle fires the convoy loop's loss detection, which is where the supply accounting
    // for this shipment actually happens.
    deleteVehicle _veh;
    // The driver group existed only to drive this truck.
    { if (!isNull _x) then { deleteVehicle _x; }; } forEach (_crew select { !isPlayer _x });
    private _grp = grpNull;
    if (count _crew > 0) then { _grp = group (_crew select 0); };
    if (!isNull _grp && { count units _grp == 0 }) then { deleteGroup _grp; };
};
