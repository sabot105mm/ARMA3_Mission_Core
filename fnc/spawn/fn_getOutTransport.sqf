// GET-OUT: FOOT TRANSPORT ------------------------------------------------------------------
// fn_mountInfantry builds these: a squad is mounted into a truck so it rides to the battle instead
// of walking. Two very different things can happen on the way, and they are told apart by the SEAT
// the unit was in, not by what the unit was doing.
//
// CREW SEAT (driver / gunner / commander) - the truck is the resource, and a truck with no driver
// is a truck that is never going anywhere again. The whole squad-mobility package is lost: the
// truck is deleted, which FIRES its Killed handler. For a plain non-gun foot transport that
// handler records the kill streak and flags both the mount point and the death spot as an unsafe
// spawn (fn_mountInfantry:159), so the next replacement truck mounts somewhere else instead of
// rolling back into the same kill pocket - the existing anti-camping behaviour, now also covering
// "the crew walked out" and not just "something shot it".
//
// The dedicated driver group goes with it. That group exists only to drive the truck
// (MISSION_CORE_DRIVER_GROUP), so it is deleted whole, exactly as fn_truckCleanupLoop does.
//
// SELF-DRIVE EXCEPTION. On a gun-mounted self-drive truck - the player hunt, where the SQUAD crews
// its own truck so the leader can stay on foot - the driver is a paid combatant the marker still
// counts. Deleting him would delete a soldier and leave his group without a transport. So on
// self-drive the truck is deleted (the mobility resource is still lost) and the driver is only
// unassigned and left standing. He keeps his combat value; the squad continues on foot.
//
// CARGO SEAT - nothing is lost and nothing is deleted. This is the unassign path, and it is the
// same one fn_splitAfterDismount uses: unassign, leave, lock cargo so the AI does not climb
// straight back in, and let the man continue on foot. That is what makes a stand-off unload work
// at all, so it must be identical here or a squad would re-board the truck it just left.
//
// The deliberate eject in fn_splitAfterDismount sets MISSION_CORE_GETOUT_SUPPRESS, which the shared
// exclusion gate treats as an ordered unload rather than an abandonment - otherwise every routine
// stand-off unload would delete the truck carrying the squad.
MISSION_CORE_fnc_getOutTransport = {
    params ["_veh", "_role", "_unit", "_turret", "_isEject"];
    if (isNull _veh || { !alive _veh }) exitWith {};
    private _isCrew = (_role in ["driver", "gunner", "commander", "copilot"]);
    if (!_isCrew) exitWith {
        // CARGO - unassign only. No loss, no delete, the squad walks on.
        if (!isNull _unit && { alive _unit }) then {
            unassignVehicle _unit;
            _unit leaveVehicle _veh;
            [_unit] orderGetIn false;
            _unit action ["getOut", _veh];
            _veh lockCargo true;
        };
        diag_log format ["GET-OUT: foot transport %1 - cargo unassigned, squad continues on foot", mapGridPosition (getPos _veh)];
    };
    // CREW SEAT - the transport resource is lost.
    private _drvGrp = _veh getVariable ["MISSION_CORE_DRIVER_GROUP", grpNull];
    private _selfDrive = true;
    if (!isNull _drvGrp) then { _selfDrive = false; };
    private _who = "crew";
    if (!isNull _unit) then { _who = name _unit };
    private _note = "";
    if (_selfDrive) then { _note = " (self-drive, driver kept)" };
    diag_log format ["GET-OUT: foot transport %1 - %2 left the %3 seat, truck lost%4", mapGridPosition (getPos _veh), _who, _role, _note];
    // Record the spot as an unsafe spawn so the replacement truck does not mount into the same
    // pocket, mirroring the Killed handler's own flagging, then delete the truck. deleteVehicle
    // fires Killed, which does the rest of the accounting.
    // The registry stores a POSITION - fn_isUnsafeVehicleSpawn does `_pos distance _uPos`, and a
    // unit is not a position array, so handing it one would error on every later safe-spawn check.
    // Read it off the vehicle, which is still alive here, and not off _unit: on the dedicated
    // driver path that unit is deleted with its group further down. Unconditional, because the
    // truck is lost at this spot whether or not a unit object was supplied.
    [getPosATL _veh] call MISSION_CORE_fnc_markUnsafeVehicleSpawn;
    // Unassign anyone still in a seat before the delete, so no ghost crew is left behind.
    { if (!isNull _x) then { unassignVehicle _x; _x leaveVehicle _veh; }; } forEach (crew _veh);
    deleteVehicle _veh;
    if (_selfDrive) exitWith {
        // Self-drive: the driver is one of the squad. He is already out of the truck (that is why
        // this handler fired) - just make sure he is not left assigned to a vehicle that no longer
        // exists, and leave him standing.
        if (!isNull _unit) then {
            unassignVehicle _unit;
            [_unit] orderGetIn false;
        };
    };
    // Dedicated driver group - it exists only to drive this truck, so it goes with the truck.
    if (!isNull _drvGrp) then {
        { if (!isNull _x) then { deleteVehicle _x; }; } forEach (units _drvGrp);
        deleteGroup _drvGrp;
    };
};
