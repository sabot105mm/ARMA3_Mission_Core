// ============================================================================
// DROWNED ARMOUR RECOVERY
// ----------------------------------------------------------------------------
// AI armour has no water awareness: a tank that spots an enemy on a hill will
// reverse at FULL speed straight into a lake and drown its engine. That is an
// unfair loss caused by our own pathing, not by the player, so this file turns
// a drowned hull into either a rescued tank or a clean write-off:
//
//   1st drowning  -> RESCUE: lifted onto the nearest dry land, engine repaired,
//                    crew re-seated, AI resumes its waypoints.
//   2nd+ drowning -> WRITEOFF: hull + crew deleted, the freed armour cap slot is
//                    left to the normal spawn queue so the enemy gets the tank
//                    back. No effect on the player's armour economy.
//
// Covers every tracked hull - MBT, AA, SPG, MLRS, tracked APC/IFV - but ONLY on
// columns that were ordered to attack a contested marker. The handler is attached
// per tank by fn_tankOrderLoop at the moment an ASSAULT column is materialized, so
// factory/depot stock and passive delivery convoys have no handler at all and are
// never touched, even if one is parked half in a lake. The rescue helpers use only
// native commands (surfaceIsWater) so the identical code runs on either the server
// or an owning client without pulling in the server-only spawn helpers.
// ============================================================================

// Nearest dry bank to a point. Self-contained so the same rescue runs on the
// server and a client. Checks the point plus four cardinal probes so the hull
// does not get parked right at the waterline and immediately re-drowns.
MISSION_CORE_fnc_nearestDryLand = {
    params ["_pos", ["_maxR", 300]];
    private _p = [_pos select 0, _pos select 1, 0];
    private _isClear = {
        params ["_c"];
        if (surfaceIsWater _c) exitWith { false };
        private _ok = true;
        for "_k" from 0 to 3 do {
            if (surfaceIsWater (_c getPos [18, _k * 90])) exitWith { _ok = false; };
        };
        _ok
    };
    if ([_p] call _isClear) exitWith { _p };
    // break (not exitWith) inside the loops: an exitWith in a for-body only leaves the then-block,
    // which would silently fall through to the fallback and return the original water point.
    private _found = [];
    for "_r" from 25 to _maxR step 25 do {
        if (count _found > 0) then { break; };
        for "_i" from 0 to 11 do {
            if (count _found > 0) then { break; };
            private _c = _p getPos [_r, _i * 30];
            if ([_c] call _isClear) then { _found = [_c select 0, _c select 1, 0]; };
        };
    };
    if (count _found == 3) then { _found } else {
        // Nothing dry within range - fall back to the original point.
        _p
    };
};

// Lift a drowned hull onto the bank, repair the engine, and put the crew back in.
MISSION_CORE_fnc_vehicleDrownRescue = {
    params ["_veh"];
    if (isNull _veh) exitWith {};

    // 1) Clear of the water, keeping its heading, AND on ground the hull can actually drive off.
    private _land = [getPos _veh, 300] call MISSION_CORE_fnc_nearestDryLand;
    private _dir = getDir _veh;
    // nearestDryLand only answers one question - is it water - and will happily return a boulder
    // field, a cliff face or a treeline. That is how a rescued hull ended up stranded on rocks:
    // the tank was out of the water and completely undriveable, which is no rescue at all. So push
    // the candidate through the same shared check every other armour spawn path already uses
    // (fn_isSafeVehicleSpawnPos: dry ground, no flagged-unsafe spawn, no hard geometry, nothing
    // rocky/woody/wrecked/ruined within 8m, no parked land vehicle within 40m), widening the search
    // box until one passes. Mirrors the escalating re-roll in fn_safeVehicleSpawn.sqf:36-40, and
    // falls back to the dry-land spot when nothing passes, which still beats leaving it sunk.
    if (!([_land] call MISSION_CORE_fnc_isSafeVehicleSpawnPos)) then {
        private _sizes = [[200, 200], [400, 400], [700, 700]];
        {
            private _retry = [_land, _land, _x] call MISSION_CORE_fnc_safeVehicleSpawnPos;
            if ([_retry] call MISSION_CORE_fnc_isSafeVehicleSpawnPos) exitWith { _land = _retry; };
        } forEach _sizes;
    };
    // Says whether the final spot passed the full check or fell back to bare dry land, so a
    // rescue that still lands badly is diagnosable from the log instead of guessed at.
    diag_log format ["DROWN: rescue %1 -> %2 safeSpot=%3", typeOf _veh, mapGridPosition _land, [_land] call MISSION_CORE_fnc_isSafeVehicleSpawnPos];
    _veh setPos _land;
    _veh setDir _dir;

    // 2) Repair the drowned engine. Submersion wrecks it (waterDamaged); clear the
    //    engine, and only fall back to a full damage reset if the hull is still
    //    immobile (submersion can also hurt the hull/track hitpoints).
    _veh setHitPointDamage ["HitEngine", 0];
    if (!canMove _veh) then { _veh setDamage 0; };
    _veh setFuel 1;

    // 3) Re-seat. allowCrewInImmobile keeps the crew aboard while the hull is
    //    stuck, so the three crew seats are normally already filled; this fills
    //    any empty seat from the owning group and is a safety net for a crew that
    //    was thrown out. An empty-seat fill can never double-assign because the
    //    pool excludes anyone already in the vehicle.
    private _crew = crew _veh;
    private _grp = grpNull;
    if (count _crew > 0) then { _grp = group (_crew select 0); };
    if (!isNull _grp) then {
        private _pool = [];
        {
            private _u = _x;
            if (alive _u && { !(_u in _crew) } && { vehicle _u != _veh }) then { _pool pushBack _u; };
        } forEach units _grp;
        private _i = 0;
        if (isNull (driver _veh)     && { count _pool > _i }) then { (_pool select _i) moveInDriver _veh;     _i = _i + 1; };
        if (isNull (gunner _veh)     && { count _pool > _i }) then { (_pool select _i) moveInGunner _veh;     _i = _i + 1; };
        if (isNull (commander _veh)  && { count _pool > _i }) then { (_pool select _i) moveInCommander _veh;  _i = _i + 1; };
    };

    // 4) Resume driving. The AI never lost its waypoint list - it just could not
    //    move - so a mobile hull simply continues. This only resets the stuck /
    //    panicked state back to something that will drive again.
    _veh setBehaviour "AWARE";
    _veh setSpeedMode "FULL";
};

// Write a hull off: delete it and its crew. Frees the armour cap slot, which the
// regular spawn queue uses to top the enemy back up over time - that is the
// refund. Depot stock is deliberately NOT touched (that is the player's armour
// economy; a lost AI tank must not mint one for them).
MISSION_CORE_fnc_vehicleDrownWriteoff = {
    params ["_veh", "_reason"];
    if (isNull _veh) exitWith {};
    private _crew = crew _veh;
    private _grp = grpNull;
    if (count _crew > 0) then { _grp = group (_crew select 0); };
    // Strip the Killed handler before deleting, like fn_despawnOrderedVehicle: every
    // armour spawn path hangs one off the hull to request a replacement on death.
    _veh removeAllEventHandlers "Killed";
    diag_log format ["DROWN: %1 written off at %2 (%3)", typeOf _veh, mapGridPosition (getPos _veh), _reason];
    // Single-hull group (the normal MBT/APC/garrison case): delete the group, hull
    // and crew as one set, reusing the shared cleanup. A multi-hull group keeps its
    // siblings - remove just this hull and its crew.
    // NOTE: the group's vehicles must come from units + vehicle, NOT "vehicles _grp".
    // The vehicles command takes no argument (it returns every vehicle on the map), so
    // handing it a group leaves a dangling operand -> "Missing ;". This mirrors
    // fn_deleteGroupCompletely. Deduped: a 3-man crew would push the same hull 3x and
    // make the single-hull test below fail for an ordinary MBT.
    private _grpVehs = [];
    if (!isNull _grp) then {
        {
            private _v = vehicle _x;
            if (_v != _x && { !(_v in _grpVehs) }) then { _grpVehs pushBack _v; };
        } forEach units _grp;
    };
    if (count _grpVehs == 1) then {
        [_grp] call MISSION_CORE_fnc_deleteGroupCompletely;
    } else {
        { if (!isNull _x) then { deleteVehicle _x; }; } forEach _crew;
        deleteVehicle _veh;
        if (!isNull _grp && { count units _grp == 0 }) then {
            if (!isNil "MISSION_CORE_SPAWNED_GROUPS") then { MISSION_CORE_SPAWNED_GROUPS = MISSION_CORE_SPAWNED_GROUPS - [_grp]; };
            deleteGroup _grp;
        };
    };
};

// "Drowned" handler. CALLED BY A MISSION EVENT HANDLER, not attached per vehicle: "Drowned" was
// removed in 2.02 and brought back in 2.14 as a MISSION level event, so _veh addEventHandler
// ["Drowned", ...] is not in the per-object EH enum and throws "Unknown enum value". A single
// addMissionEventHandler is registered, and selectivity is preserved by a registry
// (MISSION_CORE_DROWNED_WATCH) whose only writer is MISSION_CORE_fnc_drownedWatch below - so a bare
// global handler still cannot touch factory/depot stock or a passive delivery convoy, which is what
// the old per-vehicle attachment was there to achieve.
// Each hull fires on the rising edge only (see the latch below).

// Register hulls for selective drowning recovery. THIS IS THE ONLY WRITER of
// MISSION_CORE_DROWNED_WATCH, and the only place the mission-level Drowned handler is installed.
//
// This used to be a block of inline code inside fn_tankOrderLoop, which made the registry a
// convoy-only thing by accident rather than by decision - the tank order loop was simply the first
// caller. That left three MBT spawn paths with no recovery at all: the recruit Attack tab
// (fn_assaultServerRequestNew resolves its template straight out of CfgGroups, so picking an
// Armored template spawns real crewed tanks), fn_spawnAssaultGroup for the AI commander, and the
// staged release. Recruit armor is paid for out of player manpower and refunded only if the spawn
// itself fails, so a hull that sank was a permanent, unrefunded loss.
//
// Installing the handler HERE rather than at a call site is the other half of the fix: previously
// it only came into existence if a tank-order assault column happened to dispatch, so a session
// that only ever used the recruit menu had a registry with nothing behind it.
//
// Accepts a hull, an array of hulls, or a group (expanded to the vehicles its units occupy), so
// callers need not each know how to enumerate a group's hulls. Returns how many were newly added.
MISSION_CORE_fnc_drownedWatch = {
    params [["_what", []], ["_tag", "hull"]];
    if (isNil "MISSION_CORE_DROWNED_WATCH") then { MISSION_CORE_DROWNED_WATCH = []; };
    // Prune dead/removed hulls on every registration, so the registry cannot grow without bound
    // across a long session. typename rather than isNull: this array is mission-global, and isNull
    // throws a hard type error on any element that is not an Object, which fails the caller's whole
    // statement. typename accepts anything, so a polluted row can never break a registration.
    MISSION_CORE_DROWNED_WATCH = MISSION_CORE_DROWNED_WATCH select { (typename _x) == "OBJECT" && { alive _x } };
    // Type dispatch via typename, NOT isEqualType. This mission's proven isEqualType idiom passes
    // a VALUE of the wanted type - isEqualType [], isEqualType "", isEqualType 0, isEqualType
    // createHashMap - and a bare type keyword such as `isEqualType Group` is a parse error here:
    // it took this file out at line 179 with "unexpected )" and failed the whole compile.
    // Unary + on line below copies the array; proven in fn_assaultServer.sqf:391 and :575.
    private _list = [];
    private _tn = typename _what;
    if (_tn == "ARRAY") then {
        _list = +_what;
    } else {
        if (_tn == "GROUP") then {
            {
                private _v = vehicle _x;
                if (_v != _x) then { _list pushBack _v; };
            } forEach (units _what);
        } else {
            // Only objects may enter the list. Anything else reaching isNull/isKindOf below is a
            // hard runtime type error - "isnull: Type String, expected Object" - which is what
            // killed the first version of this helper. Guarding on typename makes that impossible
            // whatever a caller passes, and the log names the culprit if a caller ever does.
            if ((typename _what) == "OBJECT") then {
                _list pushBack _what;
            } else {
                diag_log format ["DROWN-EH: watch ignored non-object arg, typename=%1", typename _what];
            };
        };
    };
    private _added = 0;
    {
        // Flat single-statement if-then lines, no && chain. To be clear about WHY, because the
        // obvious guess is wrong: the compound form (!isNull _x && { alive _x } && { ... }) is
        // NOT the problem - it is proven in this mission, e.g. fn_advHints.sqf:47 chains four
        // terms exactly that way and fn_artillery.sqf:70 uses `alive _x &&`. The original crash
        // was a RUNTIME "isnull: Type String", i.e. a non-Object had got into _list, and that is
        // prevented by the typename guards above and below rather than by flattening this loop.
        // typename is the mission's proven discriminator (63 uses; fn_recon.sqf, fn_recruitServer.sqf,
        // and every transport_*.sqf compares it against "GROUP").
        //
        // Only tracked armour, and only what fn_vehicleDrowned actually acts on - it drops
        // anything that is not a Tank or Tracked_APC, so registering a wheel would just add a row
        // that could never be rescued. The registry test also collapses the duplicate rows a
        // crewed group produces (one per crew member, all the same hull).
        private _add = false;
        if ((typename _x) == "OBJECT") then { _add = true; };
        if (_add) then { if (!(alive _x)) then { _add = false; }; };
        if (_add) then { if (_x in MISSION_CORE_DROWNED_WATCH) then { _add = false; }; };
        if (_add) then {
            if (_x isKindOf "Tank" || { _x isKindOf "Tracked_APC" }) then {
                MISSION_CORE_DROWNED_WATCH pushBack _x;
                _added = _added + 1;
            };
        };
    } forEach _list;
    if (isNil "MISSION_CORE_DROWNED_MISSION_EH") then {
        MISSION_CORE_DROWNED_MISSION_EH = addMissionEventHandler ["Drowned", {
            params ["_veh", "_drowned"];
            if (isNil "MISSION_CORE_DROWNED_WATCH") exitWith {};
            if (!(_veh in MISSION_CORE_DROWNED_WATCH)) exitWith {};
            [_veh, _drowned] call MISSION_CORE_fnc_vehicleDrowned;
        }];
        // Logged HERE, at the one place it is actually true. The old line sat outside the install
        // guard and so claimed "mission handler registered" on every later convoy dispatch too.
        diag_log format ["DROWN-EH: mission handler registered, watching %1 hulls (%2)", count MISSION_CORE_DROWNED_WATCH, _tag];
    };
    // One line per event that actually registered something, so a spawn path that silently fails to
    // register is visible in the log. Bounded by the number of new hulls, not by dispatch count.
    if (_added > 0) then {
        diag_log format ["DROWN-EH: +%1 tracked hulls (%2), watching %3 total", _added, _tag, count MISSION_CORE_DROWNED_WATCH];
    };
    _added
};

MISSION_CORE_fnc_vehicleDrowned = {
    params ["_veh", "_drowned"];
    // Fire counter (diagnostic): incremented on EVERY invocation - true AND false -
    // before any early exit, so the real firing rate is measurable from the console even
    // though the action log below is edge-latched. Machine-local (no sync), so counting
    // costs almost nothing.
    if (!isNull _veh) then {
        _veh setVariable ["MISSION_CORE_DROWN_FIRES", (_veh getVariable ["MISSION_CORE_DROWN_FIRES", 0]) + 1];
    };
    // "Drowned" is a continuous STATE, not a one-shot edge: it re-fires ~20x/sec
    // while a hull is in water, and the flag flickers true/false as the hull bobs
    // at the waterline. Latch on the false->true rising edge so this log and the
    // rescue each run ONCE per drowning; clear the latch when it reports false
    // (hull dry again) so the next dip is handled fresh.
    if (!_drowned) exitWith {
        if (isNull _veh) exitWith {};
        _veh setVariable ["MISSION_CORE_DROWN_HANDLED", false];
    };
    if (isNull _veh) exitWith {};
    if (_veh getVariable ["MISSION_CORE_DROWN_HANDLED", false]) exitWith {};
    _veh setVariable ["MISSION_CORE_DROWN_HANDLED", true];
    // Stamp EVERY drowning. Submersion wrecks the engine, so a sunk hull also trips the
    // AI-wreck reaper in fn_safeVehicleSpawn.sqf - this stamp is how that reaper tells "sank in
    // a lake" from "shot up on dry land" and leaves a drowned hull to this system instead.
    _veh setVariable ["MISSION_CORE_DROWN_STAMP", time];
    // Gates that need no log: they are machine-independent, so they are evaluated
    // before the forward block below without spamming a second machine with a
    // duplicate "skip" line. All logging happens after the forward, so exactly one
    // machine (the one that does the work) reports per drowning.
    if (!(alive _veh)) exitWith {};
    // Tracked armour only - MBT, AA, SPG, MLRS, tracked APC/IFV. Wheels/statics skipped.
    if (!(_veh isKindOf "Tank" || { _veh isKindOf "Tracked_APC" })) exitWith {
        diag_log format ["DROWN-EH: skip (untracked) type=%1", typeOf _veh];
    };

    // ---- OWNER FORWARD (restored) ----
    // The event fires where the hull is simulated. If it is not local here, forward
    // to the owning machine so setPos / repair act on the real object.
    // NOTE: exitWith is only valid as the DIRECT body of an if, never as a standalone
    // statement inside a then { } block. That mistake caused every "Missing ;" in this
    // file, and the compiler always pointed at the enclosing block's closing brace
    // rather than the real line.
    //
    // ORDERING: the latch above is set BEFORE this forward, and it is deliberately
    // MACHINE-LOCAL (no public flag). It dedupes the ~20 events/sec this machine would
    // otherwise re-forward, while leaving the OWNER's own latch untouched - so the
    // remoteExecCall lands on the owner with its latch still clear, does the work once,
    // and latches itself. A public latch here would sync "true" to the owner and make
    // the forwarded call exit as already-handled, so the player-side hull would never
    // be rescued.
    private _isLocal = local _veh;
    if (!_isLocal) exitWith {
        private _owner = owner _veh;
        if (!isNull (driver _veh)) then { _owner = owner (driver _veh); };
        diag_log format ["DROWN-EH: nonlocal type=%1 -> forwarding to owner %2", typeOf _veh, _owner];
        if (_owner != player) then {
            [_veh, true] remoteExecCall ["MISSION_CORE_fnc_vehicleDrowned", _owner, false];
        };
    };

    // Armour-economy hulls are NOT ours: a tank still parked in a factory/depot
    // warehouse belongs to the depot stock system - leave it alone. A dispatch-time
    // handler can only be on an assault column, so this is a belt-and-braces net
    // (e.g. a column that reached its destination and was re-parked). Gated on real
    // park-list membership, NOT the RESERVE flag: tankUnpark never clears
    // MISSION_CORE_TANK_RESERVE, so a stolen/recruited tank still reads RESERVE=true.
    private _home = _veh getVariable ["MISSION_CORE_TANK_HOME", ""];
    private _isParked = false;
    if (_home != "" && { !isNil "MISSION_CORE_TANK_PARK" }) then {
        _isParked = _veh in (MISSION_CORE_TANK_PARK getOrDefault [_home, []]);
    };
    if (_isParked) exitWith {
        diag_log format ["DROWN-EH: skip (depot parked) %1 at %2", typeOf _veh, _home];
    };

    // Acting machine from here on: local hull, work actually happens below. One log
    // line per drowning, never one per machine and never one per event.
    diag_log format ["DROWN-EH: fired  type=%1 local=%2 side=%3 alive=%4", typeOf _veh, local _veh, side _veh, alive _veh];

    // A crewed hull is worth saving. An uncrewed hull cannot be re-crewed, so just
    // get it on the bank and repaired - still better than a dead one in the water.
    // (No "busy" guard: the latch above already guarantees one pass per drowning
    // cycle and everything below is synchronous, so the flag could never be observed
    // as set - and the convoy skip path below never cleared it, so it used to latch
    // a passive shipment's hull "busy" permanently.)
    private _crew = crew _veh;
    if (count _crew == 0) exitWith {
        diag_log format ["DROWN-EH: uncrewed %1 - lifting to dry land only", typeOf _veh];
        [_veh] call MISSION_CORE_fnc_vehicleDrownRescue;
    };

    private _grp = group (_crew select 0);

    // A player-owned hull (human crew, or on the player's side) is NEVER written
    // off - it is always rescued, no matter how many times it drowns.
    private _hasHuman = false;
    { if (isPlayer _x) then { _hasHuman = true; }; } forEach _crew;
    private _playerAsset = _hasHuman || { side _veh == side player };

    // NOTE: no convoy/shipment test here. The handler is only ever attached to a
    // column that was ALREADY TOLD TO ATTACK a contested marker, so "is this an
    // assault run" was decided at dispatch. Re-deriving it here from whether the
    // target marker happens to be contested RIGHT NOW would be wrong: a column can
    // flip back to passive (marker retaken) mid-route and would then be skipped
    // while still driving into the fight it was ordered into.

    // Repeat-offender counter, kept on the group so it survives a re-spawn of the
    // same squad. Only tracked combat groups ever reach the write-off below.
    private _limit = 2;
    if (!isNil "MISSION_CORE_fnc_tune") then { _limit = ["drownRescueLimit", 2] call MISSION_CORE_fnc_tune; };
    private _count = (_grp getVariable ["MISSION_CORE_DROWN_COUNT", 0]) + 1;
    _grp setVariable ["MISSION_CORE_DROWN_COUNT", _count];
    diag_log format ["DROWN-EH: %1  drown#%2/%3  playerAsset=%4 side=%5", typeOf _veh, _count, _limit, _playerAsset, side _veh];

    // Write off only a repeat-offender hull. An assault column is AI armour by
    // definition, but keep the player-asset guard: a hull that changed hands mid-route
    // is always rescued, never deleted.
    if (_count >= _limit && { !_playerAsset }) then {
        [_veh, format ["drowned %1x", _count]] call MISSION_CORE_fnc_vehicleDrownWriteoff;
    } else {
        [_veh] call MISSION_CORE_fnc_vehicleDrownRescue;
        diag_log format ["DROWN: %1 at %2 saved (drown #%3, side %4)", typeOf _veh, mapGridPosition (getPos _veh), _count, side _veh];
    };
};
