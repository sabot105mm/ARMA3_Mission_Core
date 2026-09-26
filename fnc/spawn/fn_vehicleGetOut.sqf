// CREW GET-OUT LIFECYCLE - shared classifier, exclusion gate, relocator, and attach point -----
// One GetOut event handler is attached to every vehicle this mission creates. It decides what an
// abandoned crew means for that vehicle's ROLE, and hands off to that role's own script:
//
//   armor      fn_getOutArmor.sqf      tanks + APCs (MBT, mech)
//   transport  fn_getOutTransport.sqf  foot-transport trucks (counter-attack / hunt carriers)
//   supply     fn_getOutSupply.sqf     ammo / utility convoy trucks
//   static     fn_getOutStatic.sqf     emplacements, tower guns
//
// WHAT THIS DOES NOT COVER, ON PURPOSE. GetOut fires when a unit LEAVES a seat - by choice, by
// eject, or because the crew was killed or deleted. It never fires for a hull that merely stops
// moving with its crew still aboard. That is the job of the systems that already exist:
//
//   fn_orderedVehicleCleanup  position-only sweep, 90s - catches "crew aboard, vehicle parked"
//   fn_armorCommanderLoop     canMove poll          - catches "crew aboard, hull immobile"
//
// Both stay. GetOut covers the case they explicitly cannot see: fn_truckCleanupLoop even bails
// out at line 26 when the driver seat is empty (`isNull _drv` -> continue), so an abandoned
// foot transport is currently an orphan that nothing reaps.
//
// ONE-SHOT RESOLUTION. The FIRST GetOut on a vehicle marks it MISSION_CORE_GETOUT_RESOLVED, so a
// three-man crew stepping down one after another resolves the vehicle exactly once, and the 90s
// ordered-vehicle sweeper skips it. That tag also settles an accounting conflict: the sweeper
// REFUNDS a stuck ordered vehicle, while a GetOut loss is a real casualty that BILLS and replaces
// (the reinforcement handler in fn_requestArmorReinforcement spawns a replacement and may charge
// the provider again). GetOut is the crew-exit-driven authority and the sweeper is the
// position-driven safety net; whichever resolves first owns the event, and neither can double it
// because both check for dead objects and the ARRIVED / GETOUT_RESOLVED guards.
//
// "MIRROR THE KILLED HANDLER" IS LITERAL. Nothing here re-implements an economy ledger. The loss
// paths delete the vehicle, and deleteVehicle FIRES the Killed event handler, so the exact same
// accounting that runs on a shot-up tank runs on an abandoned one. There is no second copy of any
// economy math to drift out of sync.

// ------------------------------------------------------------------------------------------
// ROLE CLASSIFIER. Order matters: the specific tags win over the broad isKindOf tests, because a
// supply truck and a foot transport are both `Truck_F`.
// ------------------------------------------------------------------------------------------
MISSION_CORE_fnc_getOutClassify = {
    params ["_veh"];
    if (isNull _veh) exitWith { "other" };
    // Emplacements and tower guns are StaticWeapon, not LandVehicle - checked first.
    if (_veh isKindOf "StaticWeapon") exitWith { "static" };
    // Ammo / utility convoy truck: tagged by fn_convoyLoop at creation.
    if (_veh getVariable ["MISSION_CORE_CONVOY_TRUCK", false]) exitWith { "supply" };
    // Foot transport: fn_mountInfantry stamps its mount point on every truck it builds, both the
    // dedicated-driver kind and the self-drive kind, so this tag identifies the role regardless of
    // who is driving.
    private _origin = _veh getVariable ["MISSION_CORE_TRUCK_ORIGIN", []];
    if (_origin isEqualType [] && { count _origin > 2 }) exitWith { "transport" };
    // Armor. APC is the common superclass of Wheeled_APC and Tracked_APC; the explicit tests are
    // kept anyway so a hull that only answers to its own class still classifies.
    if (_veh isKindOf "Tank") exitWith { "armor" };
    if (_veh isKindOf "APC") exitWith { "armor" };
    if (_veh isKindOf "Wheeled_APC" || { _veh isKindOf "Tracked_APC" }) exitWith { "armor" };
    // Any other crewed ground vehicle is treated as a transport.
    if (_veh isKindOf "Car" || { _veh isKindOf "Truck_F" }) exitWith { "transport" };
    "other"
};

// ------------------------------------------------------------------------------------------
// EXCLUSION GATE.
//
// The player test is `isPlayer`, NOT `side _veh == side player`. The wreck reaper used the side
// test because "never delete the player's wrecks" is the right rule for litter; here it would be
// actively wrong, because on a mission where the players are BLUFOR every BLUFOR AI tank and truck
// would be excluded and the whole system would silently do nothing on the friendly side.
//
// The player test is `isPlayer`, and ONLY `isPlayer`. There is deliberately no
// `side _veh == side player` fallback anywhere in this file: on a mission where the players are
// BLUFOR that test would exclude every BLUFOR AI tank, APC and truck, and the whole system would
// silently do nothing on the friendly side. It is worse than useless here, because the trigger for
// this whole system is a crew that has JUST left - so `crew _veh` is empty by the time the handler
// runs, and any "no AI aboard and on the player's side" test would match every single event the
// system exists to catch.
//
// A player-owned vehicle is identified by an actual player: either the unit stepping out, or
// anyone still crewed in it. A player-claimed hull whose AI crew is gone is already covered by the
// MISSION_CORE_GARRISON / MISSION_CORE_RECRUIT_VEH group checks above, which is where the
// mission's own "this asset belongs to a marker" flags actually live.
// ------------------------------------------------------------------------------------------
MISSION_CORE_fnc_getOutExcluded = {
    params ["_veh", "_unit"];
    if (isNull _veh) exitWith { true };
    // A player climbing out of their own vehicle is not an abandonment.
    if (!isNull _unit && { isPlayer _unit }) exitWith { true };
    if ((crew _veh) findIf { isPlayer _x } != -1) exitWith { true };
    // Already resolved by an earlier crew member stepping out.
    if (_veh getVariable ["MISSION_CORE_GETOUT_RESOLVED", false]) exitWith { true };
    // A deliberate eject is in progress (splitAfterDismount stand-off unload, the shipment
    // write-off crew bail, the APC rider eject). Those are ORDERED, not abandonments, and each of
    // them already does its own unassign / write-off accounting.
    if (_veh getVariable ["MISSION_CORE_GETOUT_SUPPRESS", false]) exitWith { true };
    // Depot stock is inventory, not a casualty - it is never lost to a crew exit.
    if (_veh getVariable ["MISSION_CORE_TANK_STOCKED", false]) exitWith { true };
    // Garrison and recruited-purchase vehicles are marker assets. Their replacement is owned by
    // the refill / recruit system, and the group flags are the only place those live, because the
    // group object outlives the crew leaving the hull.
    private _grp = group _veh;
    private _recruitVeh = [];
    if (!isNull _grp) then {
        if (_grp getVariable ["MISSION_CORE_GARRISON", false]) exitWith { true };
        // MISSION_CORE_RECRUIT_VEH is NOT a bool - fn_tankOrderLoop stores [_vehClass, "tank"].
        // Testing it with `if (...)` is a RUNTIME "Type Array, expected Bool" error, and it threw
        // once per exiting crew member, so the whole exclusion gate (and with it the dispatch) was
        // aborting mid-unload. Test by count instead: unset gives [], set gives a 2 element array.
        _recruitVeh = _grp getVariable ["MISSION_CORE_RECRUIT_VEH", []];
        if (count _recruitVeh > 0) exitWith { true };
    };
    false
};

// ------------------------------------------------------------------------------------------
// RELOCATE + REBOARD. Reuses the proven unstuck pattern from fn_attackStuckWatchdog (move to a
// safe spot, then setVectorUp surfaceNormal to right a flipped hull). A flipped tank reports
// canMove true, so it is invisible to both the canMove poll and the position sweeper's intent -
// this is the only path that catches it.
//
// Returns true when the hull ended up mobile with its crew back aboard, false when every attempt
// failed and the caller should escalate to a loss.
// ------------------------------------------------------------------------------------------
MISSION_CORE_fnc_getOutRelocate = {
    params ["_veh", "_crew", ["_tries", 3]];
    if (isNull _veh || { !alive _veh }) exitWith { false };
    private _crew = _crew select { !isNull _x && { alive _x } };
    private _here = getPosATL _veh;
    private _heading = getDir _veh;
    for "_i" from 1 to _tries do {
        // Widen the search box each try: a hull wedged in one ditch may have clear ground 400m out.
        private _size = [120 * _i, 120 * _i];
        private _spot = [_here, _size, 12, _heading] call MISSION_CORE_fnc_findVehiclePos;
        if (count _spot < 2) then { _spot = _here; };
        if (count _spot == 2) then { _spot pushBack 0; };
        // Lift clear of whatever it was sitting in, then drop it back onto the ground.
        _veh setPosATL [_spot select 0, _spot select 1, (_spot select 2) + 1.5];
        _veh setPosATL _spot;
        // Right the hull. A flipped or up-on-its-side vehicle is set upright and aligned to the
        // local ground normal before the crew is put back in.
        _veh setVectorUp (surfaceNormal _spot);
        _veh setDir _heading;
        sleep 0.5;
        // Put the crew back in, driver first. Each seat is checked with fullCrew first, so a hull
        // with no such seat (a bare APC, a variant with no commander position) skips it instead of
        // erroring on moveInGunner / moveInCommander.
        //
        // Each seat is filled straight from (_crew deleteAt 0) with no intermediate variable. An
        // earlier version staged the unit in a private and then tested it, and that reported
        // "Undefined variable in expression: _d/_g/_c" at runtime, once per seat per attempt. The
        // intermediate buys nothing here: _crew is filtered at the top of this function to live,
        // non-null men, so deleteAt 0 on a non-empty array always hands back a usable object and
        // needs no null check. Writing the whole seat as one statement also means the unit is
        // consumed and seated in the same step.
        //
        // deleteAt rather than select is deliberate, and the count _crew > 0 test is load-bearing:
        // the re-collect at the bottom of the loop folds _crew into the next attempt, so a man who
        // was seated here must be gone from the list or the next moveInDriver would be handed a
        // unit already in the seat and throw.
        if (isNull (driver _veh) && { count (fullCrew [_veh, "Driver", true]) > 0 } && { count _crew > 0 }) then {
            (_crew deleteAt 0) moveInDriver _veh;
        };
        if (isNull (gunner _veh) && { count (fullCrew [_veh, "Gunner", true]) > 0 } && { count _crew > 0 }) then {
            (_crew deleteAt 0) moveInGunner _veh;
        };
        if (isNull (commander _veh) && { count (fullCrew [_veh, "Commander", true]) > 0 } && { count _crew > 0 }) then {
            (_crew deleteAt 0) moveInCommander _veh;
        };
        // Success = crew is aboard again AND the hull can actually move. A hull that is still
        // immobile after being dropped on clear ground and righted is beyond help.
        if (count crew _veh > 0 && { canMove _veh }) exitWith { true };
        // Re-collect the crew for the next attempt. Units that were still stranded on the ground
        // after the failed reboard are folded back in, and anyone else from this hull's group who
        // is on foot nearby is picked up, so a three-man crew is restored as three, not one.
        private _next = _crew select { !isNull _x && { alive _x } };
        {
            private _u = _x;
            if (!isNull _u && { alive _u } && { !(_u in _next) }) then { _next pushBack _u; };
        } forEach (units (group _veh) select {
            !isNull _x && { alive _x } && { !isPlayer _x } && { vehicle _x == _x } && { _x distance _veh < 60 }
        });
        _crew = _next;
    };
    false
};

// ------------------------------------------------------------------------------------------
// COLLECT THE BAILED CREW. The exiting unit is the one the handler was called for, but a crew
// bails as a group and the other two may already be on the ground. Take everyone from the hull's
// own group who is on foot within 60m of it, plus the exiting unit, so the reboard restores the
// full crew rather than one orphan.
// ------------------------------------------------------------------------------------------
MISSION_CORE_fnc_getOutBailedCrew = {
    params ["_veh", "_unit"];
    private _out = [];
    if (!isNull _unit && { alive _unit } && { !isPlayer _unit }) then { _out pushBack _unit; };
    private _grp = group _veh;
    if (!isNull _grp) then {
        { if (!isNull _x && { alive _x } && { !isPlayer _x } && { vehicle _x == _x } && { _x distance _veh < 60 } && { !(_x in _out) }) then { _out pushBack _x; }; } forEach units _grp;
    };
    _out
};

// ------------------------------------------------------------------------------------------
// ATTACH. Called from MISSION_CORE_fnc_safeVehicleSpawn (the single funnel every tracked hull and
// ground vehicle is created through) and from the static-emplacement builders.
// ------------------------------------------------------------------------------------------
MISSION_CORE_fnc_attachGetOut = {
    params ["_veh"];
    if (isNull _veh) exitWith {};
    if (_veh getVariable ["MISSION_CORE_GETOUT_WATCH", false]) exitWith {};
    _veh setVariable ["MISSION_CORE_GETOUT_WATCH", true];
    _veh addEventHandler ["GetOut", {
        params ["_vehicle", "_role", "_unit", "_turret", "_isEject"];
        [_vehicle, _role, _unit, _turret, _isEject] call MISSION_CORE_fnc_getOutDispatch;
    }];
};

// ------------------------------------------------------------------------------------------
// DISPATCH. One latch, one handoff.
// ------------------------------------------------------------------------------------------
MISSION_CORE_fnc_getOutDispatch = {
    params ["_veh", "_role", "_unit", "_turret", "_isEject"];
    if (isNull _veh || { !alive _veh }) exitWith {};
    if ([_veh, _unit] call MISSION_CORE_fnc_getOutExcluded) exitWith {};
    // OWNERSHIP HANDOFF - a hull sitting in water belongs to the Drowned system, not to this one.
    //
    // These two watchers used to fight over every sinking tank, and GetOut always won. Its loss test
    // is "!canMove" (fn_getOutArmorVerdict.sqf:32), and a hull in water can never move, so ANY
    // submerged tracked hull was judged a casualty, billed and replaced by deleteVehicle 1.5s
    // later (fn_getOutArmorWorker.sqf:45). The Drowned event then either never fired - the crew
    // bailed out, so nobody actually drowned - or fired against an object that no longer existed.
    // The drowning recovery could not run for any hull whose crew got out, which is most of them.
    //
    // Gated on BOTH being in the Drowned watch AND actually being in water, so the domains stay
    // disjoint and the dry-land case is untouched: a tracked hull that is shot up, stuck or
    // flipped on shore with its crew bailed is still GetOut's to relocate and reboard. Only a
    // hull that is in the water is handed over. The registry test is deliberate - it is the same
    // "the Drowned system owns this" flag that fn_vehicleDrowned stamps, so an untracked hull
    // that somehow ends up in water still falls through to GetOut rather than being stranded with
    // nobody handling it.
    private _drownedOwned = false;
    if (!isNil "MISSION_CORE_DROWNED_WATCH") then {
        if (_veh in MISSION_CORE_DROWNED_WATCH) then {
            if (surfaceIsWater (getPosATL _veh)) then { _drownedOwned = true; };
        };
    };
    if (_drownedOwned) exitWith {
        diag_log format ["GET-OUT: %1 is in water and Drowned-owned - leaving it to the drowning handler", typeOf _veh];
    };
    // Latch before the handoff: the role script deletes or relocates the vehicle, and a delete
    // during the handler would otherwise let the next crew member's GetOut through.
    _veh setVariable ["MISSION_CORE_GETOUT_RESOLVED", true];
    private _roleClass = [_veh] call MISSION_CORE_fnc_getOutClassify;
    private _args = [_veh, _role, _unit, _turret, _isEject];
    switch (_roleClass) do {
        case "armor": { _args call MISSION_CORE_fnc_getOutArmor; };
        case "transport": { _args call MISSION_CORE_fnc_getOutTransport; };
        case "supply": { _args call MISSION_CORE_fnc_getOutSupply; };
        case "static": { _args call MISSION_CORE_fnc_getOutStatic; };
        default { };
    };
};
