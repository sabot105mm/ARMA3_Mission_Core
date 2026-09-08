//
// REDFOR PLAYER-HUNT DIRECTOR (one thread)
//
// Watches BLUFOR players near REDFOR markers. A hunt only starts when REDFOR has ACTUALLY seen the
// player - a faint sighting (any garrison unit knowsAbout > 0.1 near a spawned marker) or a real
// LOS sighting still fresh (<60s). Proximity alone never triggers one. The closest REDFOR markers
// then dispatch a HUNT contingent to the player's last known position:
//
//   - Player in a tank       -> an MBT contingent (tank vs tank); if no armor capacity, a bigger
//                               infantry + AT contingent instead.
//   - Player in a vehicle    -> a gun-capable vehicle contingent (APC or gun truck / MBT fallback);
//                               if none can be fielded, a bigger foot contingent.
//   - Player on foot / none  -> a foot squad (bigger = 2 squads when the nearest marker is far).
//
// The contingent rides to the last known position, unloads, then SWEEPS along the heading the
// player was last moving - from the time it ARRIVES at the LKP - for 10 minutes.
//
// INFORMATION MODEL (no god-view):
//   - Contact requires REAL line of sight (terrain/building LOS check) AND knowsAbout > 0.7.
//   - Shared garrison intel: any spawned REDFOR unit with an actual sighting reports
//     [pos, heading, time] into MISSION_CORE_HUNT_INTEL; it decays after ~60s.
//   - While sweeping, groups steer ONLY toward a <60s-old shared sighting; otherwise they walk
//     the original extrapolated line blind. They NEVER steer toward the player's live position.
//   - On re-spot the group engages the position where it can actually see the player; when he
//     escapes again it resumes sweeping from where it saw him last + that recorded heading.
//   - No raw-distance wallhack triggers (only a 30m "stepped on him" bump).
//
// With no re-contact it retreats to the closest same-side marker and despawns on arrival (driver
// + truck cleaned up too). REDFOR side only - BLUFOR AI keeps its assault-based behavior.

// True when unit _from has a clear line of sight to unit _to (no building or terrain in between).
// Needed so hunt AI can never "see" a player through a wall or hill - raw distance is not sight.
MISSION_CORE_fnc_hasLOS = {
    params ["_from", "_to"];
    if (isNull _from || { isNull _to }) exitWith { false };
    private _a = eyePos _from;
    private _b = eyePos _to;
    // lineIntersects already tests terrain AND objects (with _from/_to ignored), returning
    // true when the LOS is blocked. No separate terrainIntersectASL call is needed.
    !(lineIntersects [_a, _b, _from, _to])
};

// True when a REDFOR unit currently SEES the player (knowsAbout above the tune contact threshold
// AND a real terrain/building LOS check). This is the only "contact" that generates shared intel.
MISSION_CORE_fnc_huntSeesPlayer = {
    params ["_u", "_p"];
    if (isNull _u || { isNull _p }) exitWith { false };
    (alive _u && { alive _p } && { _u knowsAbout _p > (["huntContactKnows", 0.7] call MISSION_CORE_fnc_tune) } && { [_u, _p] call MISSION_CORE_fnc_hasLOS })
};

MISSION_CORE_fnc_playerHunt = {
    diag_log "PLAYER HUNT: director started";
    MISSION_CORE_HUNT_ACTIVE = createHashMap;     // player -> hunt group
    MISSION_CORE_PLAYER_LKP = createHashMap;      // player -> [pos, heading, lastSeen]

    private _side = EAST;                          // REDFOR hunts the BLUFOR player
    private _enemySide = WEST;
    private _sideVar = "MISSION_CORE_REDFOR";
    private _factionData = MISSION_CORE_REDFOR_DATA;
    private _detectRange = ["huntDetectRange", 1200] call MISSION_CORE_fnc_tune;

    while { true } do {
        sleep 20 + random 10;
        if (isNil "MISSION_CORE_SPAWNED_LOCATIONS") then { continue; };
        if (isNil "MISSION_CORE_CACHED_POSITIONS") then { continue; };
        private _players = allPlayers select { alive _x && { side _x == _enemySide } };
        if (count _players == 0) then { continue; };
        // Snapshot this side's units once per tick and reuse for all players. Avoids an allUnits
        // refetch per player (the list only changes between frames, not mid-loop-body).
        private _snapUnits = allUnits select { side _x == _side };

        // Spawned REDFOR markers = the "eyes" that eventually spot a player loitering nearby.
        private _redSpawned = MISSION_CORE_CACHED_POSITIONS select {
            (_x select 4) == _side && { MISSION_CORE_SPAWNED_LOCATIONS getOrDefault [(_x select 0), false] }
        };
        if (count _redSpawned == 0) then { continue; };

        {
                    private _p = _x;
            private _pKey = str _p;   // hashmap keys: strings only (objects are not valid keys)
            private _pPos = getPos _p;
            private _entry = MISSION_CORE_PLAYER_LKP getOrDefault [_pKey, [_pPos, 0, 0]];
            _entry params ["_lpos", "_lhead", "_lseen"];

            // A player counts as "seen" when inside _detectRange of any spawned REDFOR marker.
            private _near = (_redSpawned findIf { (_x select 1) distance2D _pPos < _detectRange }) != -1;

            // A CURRENT live sighting: any REDFOR unit with a real LOS + knowsAbout saw the player
            // this tick. This is a genuine "we know where he is right now" - enough to hunt even when
            // the player is not near a spawned marker (e.g. a field patrol or convoy spotted him).
            private _liveSight = (_snapUnits findIf {
                [_x, _p] call MISSION_CORE_fnc_huntSeesPlayer
            }) != -1;

            // Always track position + heading for everyone (so a fresh sweep still knows which
            // way the player was heading) - the dwell only decides whether a hunt dispatches.
            // Heading = compass direction the player moved from _lpos to _pPos.
            private _heading = 0;
            if (_lpos distance2D _pPos > 10) then { _heading = _lpos getDir _pPos; };
            MISSION_CORE_PLAYER_LKP set [_pKey, [_pPos, _heading, time]];

            // ---- Shared garrison intel ----
            // Any REDFOR unit with a REAL line of sight and knowsAbout > 0.7 reports a
            // contact. The intel is a time-stamped position of a legitimately-sighted spot.
            if (isNil "MISSION_CORE_HUNT_INTEL") then { MISSION_CORE_HUNT_INTEL = createHashMap; };
            if (_liveSight) then {
                MISSION_CORE_HUNT_INTEL set [_pKey, [_pPos, _heading, time]];
            };

            // Hunts only dispatch toward a player the REDFOR genuinely knows of. Proximity to a
            // spawned marker is the norm, but a current live LOS sighting is always sufficient on
            // its own - the enemy KNOWS where the player is right now and will hunt him anywhere.
            if (!_near && { !_liveSight }) then { continue; };

            // ---- HUNT REQUIRES AN ACTUAL SIGHTING ----
            // Proximity alone never starts a hunt. The REDFOR must have at least a FAINT awareness
            // of the player (any garrison unit knowsAbout > 0.1) or a real LOS sighting that is
            // still fresh (<60s). No observation = no hunt.
            private _intel = MISSION_CORE_HUNT_INTEL getOrDefault [_pKey, []];
            private _intelFresh = count _intel >= 3 && { (time - (_intel select 2)) <= (["huntIntelDecay", 60] call MISSION_CORE_fnc_tune) };
            private _faintContact = _snapUnits findIf {
                alive _x && { _x distance2D _pPos < (_detectRange + 300) && { _x knowsAbout _p > (["huntFaintKnows", 0.1] call MISSION_CORE_fnc_tune) } }
            } != -1;
            if (!_faintContact && { !_intelFresh }) then { continue; };

            // Already hunting this player - living contingents are on the way / sweeping.
            private _active = MISSION_CORE_HUNT_ACTIVE getOrDefault [_pKey, []];
            private _living = _active select { !isNull _x && { { alive _x } count units _x > 0 } };
            if (count _living > 0) then { MISSION_CORE_HUNT_ACTIVE set [_pKey, _living]; continue; };

            // Aim the hunt at a position the REDFOR genuinely knows. When a unit has a CURRENT live
            // LOS sighting this tick, that legitimately-sighted spot is the player's own position
            // (no god-view - a real enemy just laid eyes on him). Otherwise fall back to the last
            // real sighting (_intel) or the previously-recorded LKP so a faint-only contact still
            // hunts where they WERE, not where they are right now.
            private _aimPos = _lpos;
            private _aimHead = _heading;
            if (_liveSight || _intelFresh) then { _aimPos = _intel select 0; _aimHead = _intel select 1; };
            [_p, _pKey, _aimPos, _aimHead, _side, _sideVar, _factionData] call MISSION_CORE_fnc_huntDispatch;
        } forEach _players;
    };
};

// Pick the CLOSEST REDFOR markers as hunt sources and dispatch up to huntMaxContingents squads
// at the player's last known position - so several nearby towns converge instead of just one.
// No source may be the marker the player is standing inside (a squad that spawns 0m away is absurd),
// and only markers within huntSourceMaxRange of the LKP join the hunt.
MISSION_CORE_fnc_huntDispatch = {
    params ["_player", "_playerKey", "_lkp", "_heading", "_side", "_sideVar", "_factionData"];
    if (isNil "MISSION_CORE_HUNT_ACTIVE") then { MISSION_CORE_HUNT_ACTIVE = createHashMap; };

    private _cands = MISSION_CORE_CACHED_POSITIONS select { (_x select 4) == _side };
    if (count _cands == 0) exitWith {};
    // PERMANENT RULE: Outposts are static tiny garrisons - they never dispatch hunt contingents.
    _cands = _cands select { !([_x] call MISSION_CORE_fnc_isLightInfrastructure) };
    // AMMO: a source marker with <30% ammo is defensive and never spares men to hunt. At 0 ammo
    // it is fully passive. Only markers with enough ammo may field a hunt contingent.
    _cands = _cands select { ([(_x select 0)] call MISSION_CORE_fnc_getAmmoFraction) >= 0.3 };
    private _maxN = ["huntMaxContingents", 3] call MISSION_CORE_fnc_tune;
    private _srcRange = ["huntSourceMaxRange", 2500] call MISSION_CORE_fnc_tune;
    // Exclude markers that CONTAIN the aim point (you can't attack your own yard with 0m run).
    private _srcCands = _cands select {
        private _p = _x select 1;
        private _s = if (count _x > 8) then { _x select 8 } else { [200, 200] };
        private _sa = ((_s select 0) max 1);
        private _sb = if (count _s > 1) then { ((_s select 1) max 1) } else { _sa };
        private _sd = if (count _s > 2) then { _s select 2 } else { 0 };
        private _dx = (_lkp select 0) - (_p select 0);
        private _dy = (_lkp select 1) - (_p select 1);
        private _rx = _dx * cos _sd - _dy * sin _sd;
        private _ry = _dx * sin _sd + _dy * cos _sd;
        ((_rx * _rx) / (_sa * _sa) + (_ry * _ry) / (_sb * _sb)) > 1
    };
    if (count _srcCands == 0) then { _srcCands = _cands; };  // all else fails: any marker
    // Sort nearest-first, keep only markers within the source range, cap to max contingents.
    _srcCands = [_srcCands, [], { (_x select 1) distance2D _lkp }, "ASCEND"] call BIS_fnc_sortBy;
    _srcCands = _srcCands select { (_x select 1) distance2D _lkp <= _srcRange };
    _srcCands resize (_maxN min (count _srcCands));

    private _dispatched = 0;
    {
        private _src = _x;
        private _srcName = _src select 0;
        private _srcPos = _src select 1;
        private _srcImp = _src select 7;
        private _srcSize = if (count _src > 8) then { _src select 8 } else { [200, 200] };
        private _srcD = _srcPos distance2D _lkp;

        private _grp = [_player, _lkp, _heading, _side, _sideVar, _factionData, _srcName, _srcPos, _srcSize, _srcImp, _srcD] call MISSION_CORE_fnc_huntSpawnContingent;
        if (isNull _grp) then { continue; };
        // AMMO: dispatching a hunt contingent costs the source marker ammo.
        [_srcName, ["ammoCostHunt", 2] call MISSION_CORE_fnc_tune] call MISSION_CORE_fnc_consumeAmmo;

        private _list = MISSION_CORE_HUNT_ACTIVE getOrDefault [_playerKey, []];
        _list pushBack _grp;
        MISSION_CORE_HUNT_ACTIVE set [_playerKey, _list];
        _grp setVariable ["MISSION_CORE_HUNT_TARGET", _player];
        _grp setVariable ["MISSION_CORE_HUNT_KEY", _playerKey];
        [_grp, _lkp, _heading, _side, _player, _playerKey, _srcName, _srcPos, _srcD] spawn MISSION_CORE_fnc_huntSweep;
        _dispatched = _dispatched + 1;
        diag_log format ["PLAYER HUNT: %1 dispatching %2 from %3 toward %4 (%.0fm)", _side, groupId _grp, _srcName, _lkp, _srcD];
    } forEach _srcCands;
    diag_log format ["PLAYER HUNT: %1 dispatched %2 contingent(s) toward %3", _side, _dispatched, _lkp];
};

// Spawn the contingent for one hunt. Returns the group (grpNull if nothing could be fielded).
MISSION_CORE_fnc_huntSpawnContingent = {
    params ["_player", "_lkp", "_heading", "_side", "_sideVar", "_factionData", "_srcName", "_srcPos", "_srcSize", "_srcImp", "_srcD"];
    private _vehMap = _factionData select 7;
    private _mbtClasses = _vehMap getOrDefault ["mbt", []];
    private _apcClasses = _vehMap getOrDefault ["apc", []];

    private _playerVeh = vehicle _player;
    private _inTank = _playerVeh != _player && { _playerVeh isKindOf "Tank" };
    private _inVeh = _playerVeh != _player && { !_inTank };
    private _spawnPos = [_srcPos, _srcSize, 30, random 360] call MISSION_CORE_fnc_findVehiclePos;
    _spawnPos = [_spawnPos] call MISSION_CORE_fnc_ensureLandPos;

    private _grp = grpNull;

    // 1) Tank threat - field an MBT (respects the armor cap), else a bigger AT-capable squad.
    if (_inTank && { count _mbtClasses > 0 && { [_side, "mbt", _lkp, _srcImp] call MISSION_CORE_fnc_armorCapOpen } }) then {
        _grp = [_side, selectRandom _mbtClasses, "mbt", _spawnPos, 0, _srcImp, _lkp] call MISSION_CORE_fnc_spawnDefenseVehicle;
    };

    // 2) Vehicle threat - gun-capable vehicle (APC, else MBT).
    if (isNull _grp && { _inVeh }) then {
        private _vehClass = "";
        if (count _apcClasses > 0 && { [_side, "mech", _lkp, _srcImp] call MISSION_CORE_fnc_armorCapOpen }) then { _vehClass = selectRandom _apcClasses; };
        if (_vehClass == "" && { count _mbtClasses > 0 && { [_side, "mbt", _lkp, _srcImp] call MISSION_CORE_fnc_armorCapOpen } }) then { _vehClass = selectRandom _mbtClasses; };
        if (_vehClass != "") then {
            _grp = [_side, _vehClass, if (_vehClass isKindOf "Tank") then { "mbt" } else { "mech" }, _spawnPos, 0, _srcImp, _lkp] call MISSION_CORE_fnc_spawnDefenseVehicle;
        };
    };

    // 3) Foot threat / fallbacks - an infantry squad.
    //    PERMANENT RULE (hunt sourcing): hunt forces are drawn from units ALREADY SPAWNED in the
    //    source marker's garrison - never fresh-created on top of the fielded army. This keeps hunt
    //    contingents inside the same budget as every other spawn (no unlimited bandit squads when
    //    the player keeps stepping in and out of sight). We pick an idle/patrolling foot REDFOR
    //    group rooted at this marker and re-task it to hunt; only if the marker fields no eligible
    //    group do we spawn one as a last resort.
    if (isNull _grp) then {
        private _idleAtSrc = [];
        if (!isNil "MISSION_CORE_SPAWNED_GROUPS") then {
            _idleAtSrc = MISSION_CORE_SPAWNED_GROUPS select {
                !isNull _x &&
                { count units _x > 0 } &&
                { _x getVariable [_sideVar, false] } &&
                { (_x getVariable ["MISSION_CORE_ORIGIN_MARKER", ""]) == _srcName } &&
                { (_x getVariable ["MISSION_CORE_ORDER", ""]) in ["", "patrol", "defend", "engage"] } &&
                { !(_x getVariable ["MISSION_CORE_AA_DEFENSE", false]) } &&
                { !(_x getVariable ["MISSION_CORE_AA_TANK", false]) } &&
                { !(_x getVariable ["MISSION_CORE_STATIC_GUARD", false]) } &&
                { ({ vehicle _x == _x } count units _x) == count units _x }
            };
        };
        if (count _idleAtSrc > 0) then {
            _grp = selectRandom _idleAtSrc;
        } else {
            // Fallback: no eligible spawned garrison at this source - spawn one.
            private _infPool = [(_factionData select 17)] call MISSION_CORE_fnc_getInfTemplates;
            if (count _infPool > 0) then {
                private _template = selectRandom _infPool;
                _grp = [_template select 0, _spawnPos, _side, _factionData select 3, "AWARE", "NORMAL", _srcImp, _srcPos, _srcSize] call MISSION_CORE_fnc_spawnGroup;
                if (!isNull _grp) then {
                    _grp setVariable ["MISSION_CORE_ORIGIN_MARKER", _srcName];
                    if (isNil "MISSION_CORE_SPAWNED_GROUPS") then { MISSION_CORE_SPAWNED_GROUPS = []; };
                    MISSION_CORE_SPAWNED_GROUPS pushBack _grp;
                };
            };
        };
    };

    if (isNull _grp) exitWith { grpNull };
    _grp setVariable ["MISSION_CORE_ORDER", "hunt"];
    _grp setVariable ["MISSION_CORE_IDLE", false];
    _grp
};

// CLEAR HOUSES - when a hunt squad is searching near built-up areas (a player's last-known spot
// in a town, or after losing contact), fan the unitS out into DIFFERENT buildings to clear them:
// each living footman is doMove'd to a random distinct buildingPos, so the squad splits up and
// sweeps multiple houses instead of all stacking at one. Foot units cover the entries, then the
// whole group re-converges on the search center for the ongoing sweep.
MISSION_CORE_fnc_huntClearBuildings = {
    params ["_grp", "_center", ["_radius", 400]];
    if (isNull _grp || { count units _grp == 0 }) exitWith {};
    private _men = units _grp select { alive _x && { vehicle _x == _x && { !(isNull _x) } } };
    if (count _men == 0) exitWith {};

    private _houses = nearestObjects [_center, ["House", "Building", "Strategic", "Fortress"], _radius];
    private _spots = [];
    {
        for "_i" from 0 to 39 do {
            private _p = _x buildingPos _i;
            if (_p isEqualTo [0, 0, 0]) exitWith {};
            _spots pushBack _p;
        };
    } forEach _houses;
    // No buildings here - nothing to clear (caller keeps sweeping blind).
    if (count _spots == 0) exitWith {};

    // Give each man a random, distinct entry/building point. They split up and move in.
    private _cleared = 0;
    {
        if (count _spots == 0) exitWith {};
        private _p = _spots deleteAt (floor (random (count _spots)));
        _x doMove _p;
        _cleared = _cleared + 1;
    } forEach _men;
    _grp setBehaviour "AWARE";
    _grp setCombatMode "RED";
    diag_log format ["PLAYER HUNT: %1 clearing %2 houses (%3 spots) at %4", groupId _grp, count _houses, _cleared, _center];
};

// Sweep controller for one hunt contingent.
MISSION_CORE_fnc_huntSweep = {
    params ["_grp", "_lkp", "_heading", "_side", "_player", "_playerKey", "_srcName", "_srcPos", "_srcD"];
    if (isNull _grp) exitWith {};
    _grp setVariable ["MISSION_CORE_PATROLLING", false];
    leader _grp setVariable ["MISSION_CORE_PATROLLING", false];

    // Transport rule for the hunt:
    //   - Player FAR away     -> mount a transport to close the distance (even a footman far out
    //                            is worth riding toward; the truck unloads well short of contact).
    //   - Player NEAR on foot -> advance barefoot, no trucks - a troop truck rolling up next to a
    //                            nearby footman is cheesy and easy to spot.
    //   - Player in a VEHICLE -> transport allowed (needed to keep pace), no range restriction.
    private _ldr = leader _grp;
    private _playerDist = if (isNull _player) then { _ldr distance2D _lkp } else { _ldr distance2D _player };
    private _targetInVeh = !isNull _player && { vehicle _player != _player };
    private _mounted = vehicle _ldr != _ldr;
    private _truck = objNull;
    if (!_mounted && { _targetInVeh || { _playerDist >= (["huntMountDist", 700] call MISSION_CORE_fnc_tune) } }) then {
        _truck = [_grp, _side, getPos _ldr] call MISSION_CORE_fnc_mountInfantry;
    };
    _mounted = vehicle _ldr != _ldr;
    private _isGun = _mounted && { [vehicle _ldr] call MISSION_CORE_fnc_hasMountedGun };
    if (_isGun) then { _truck = objNull; };

    // HUNT CONTACT RULE: fight on foot, never from the truck.
    //   - Plain cargo truck           -> everyone out (the dedicated driver group keeps the truck).
    //   - Gun truck (gun MRAP)        -> the DRIVER and GUNNER stay mounted as mobile fire support,
    //                                   the CARGO dismounts. Re-embarking is locked out.
    // After the unload the step behaves COMBAT + combat mode RED.
    private _disembark = {
        params ["_g"];
        private _gLdr = leader _g;
        private _v = vehicle _gLdr;
        if (isNull _v || { _v == _gLdr }) exitWith {};
        // Bring the truck to a FULL STOP before ejecting anyone. The arrival/re-spot code can fire
        // while the truck is still rolling toward the contact, and ejecting at speed kills the men.
        // New waypoints assigned right after the drop cancel the doStop so the truck can drive on.
        if (alive _v) then {
            _v setSpeedMode "LIMITED";
            private _drvStop = driver _v;
            if (!isNull _drvStop) then { doStop _drvStop; };
            private _stopBy = time + 6;
            waitUntil { sleep 0.2; isNull _v || { !(alive _v) } || { speed _v < 2 } || { time > _stopBy } };
        };
        private _keepCrew = [_v] call MISSION_CORE_fnc_hasMountedGun;
        private _gDrv = driver _v;
        _v lock false;
        {
            if (_x isEqualTo _gDrv) then { continue; };
            if (_keepCrew && { _x isEqualTo (gunner _v) }) then { continue; };
            if (_keepCrew && { _x isEqualTo (commander _v) }) then { continue; };
            if (vehicle _x != _v) then { continue; };
            unassignVehicle _x;
            [_x] orderGetIn false;
            _x action ["getOut", _v];
        } forEach (crew _v);
        sleep 0.6;
        _v lockCargo true;
        _g setCombatMode "RED";
        _g setBehaviour "COMBAT";
        diag_log format ["PLAYER HUNT: %1 dismounted (%2 stayed mounted, cargo unloaded)", groupId _g, if (_keepCrew) then { "driver+gunner" } else { "driver only" }];
    };

    if (_mounted && { !_isGun }) then {
        // Cargo truck - add GETOUT at the LKP (driven by a waypoint script so the dismount is
        // precision-timed to arrival); the driver group gets a TR UNLOAD ring at the LKP.
        [_grp] call MISSION_CORE_fnc_clearGroupWaypoints;
        private _wpG = _grp addWaypoint [_lkp, 60];
        _wpG setWaypointType "GETOUT";
        _wpG setWaypointSpeed "FULL";
        _wpG setWaypointScript "fnc\commander\transport_assaultUnload.sqf";
        private _drvGrp = _truck getVariable ["MISSION_CORE_DRIVER_GROUP", grpNull];
        if (!isNull _drvGrp) then {
            [_drvGrp] call MISSION_CORE_fnc_clearGroupWaypoints;
            _drvGrp setBehaviour "CARELESS";
            private _wpU = _drvGrp addWaypoint [_lkp, 60];
            _wpU setWaypointType "TR UNLOAD";
            _wpU setWaypointSpeed "FULL";
            _drvGrp setCurrentWaypoint _wpU;
        };
        _grp setCurrentWaypoint _wpG;
    } else {
        [_grp] call MISSION_CORE_fnc_clearGroupWaypoints;
        private _wp = _grp addWaypoint [_lkp, 50];
        _wp setWaypointType "MOVE";
        _wp setWaypointSpeed "FULL";
        _grp setCurrentWaypoint _wp;
        _grp setBehaviour "AWARE";
        _grp setCombatMode "RED";
    };

    // Arrive: wait until the leader reaches the LKP (or everyone unloaded there / timeout).
    private _arrival = time + (["huntSweepSeconds", 600] call MISSION_CORE_fnc_tune);
    waitUntil { sleep 2;
        isNull _grp || { count units _grp == 0 } ||
        { (leader _grp) distance2D _lkp < 150 } ||
        { !(_mounted && { !_isGun }) && { (leader _grp) distance2D _lkp < 300 } } ||
        { time > _arrival }
    };

    // Arrival done - get the squad on the ground. Cargo trucks already unloaded via the GETOUT
    // waypoint script; a gun truck only now gets its cargo out (driver+gunner stay). No-op when
    // already on foot.
    [_grp] call _disembark;

    // The hunt squad is on the ground now - the support truck's job is done. Turn the driver
    // group loose to drive it back toward the source marker and despawn there, so an empty truck
    // never idles at the LKP for the whole sweep.
    if (!isNull _truck && { alive _truck }) then {
        private _drvGrp = _truck getVariable ["MISSION_CORE_DRIVER_GROUP", grpNull];
        if (!isNull _drvGrp) then {
            private _tHome = if (_srcPos distance [0, 0, 0] > 1) then { _srcPos } else { getPos _truck };
            // Turn the driver group loose on a MOVE waypoint home; transport_truckArrive.sqf
            // despawns crew + truck + group on arrival - no 5s polling loop.
            _drvGrp setBehaviour "CARELESS";
            _drvGrp setSpeedMode "FULL";
            [_drvGrp] call MISSION_CORE_fnc_clearGroupWaypoints;
            private _wpHome = _drvGrp addWaypoint [_tHome, 30];
            _wpHome setWaypointType "MOVE";
            _wpHome setWaypointSpeed "FULL";
            _wpHome setWaypointBehaviour "CARELESS";
            _wpHome setWaypointScript "fnc\commander\transport_truckArrive.sqf";
            _drvGrp setCurrentWaypoint _wpHome;
        };
    };

    // The 10-minute sweep clock starts when the contingent REACHES the player's last known pos.
    private _sweepEnd = time + (["huntSweepSeconds", 600] call MISSION_CORE_fnc_tune);
    private _curLkp = _lkp;
    private _curHead = _heading;

    private _step = 300;
    private _chainWp = {
        params ["_g", "_base", "_head", "_count"];
        [_g] call MISSION_CORE_fnc_clearGroupWaypoints;
        private _wps = [];
        for "_i" from 1 to _count do {
            private _pos = _base getPos [_i * _step, _head];
            private _wp = _g addWaypoint [_pos, 60];
            _wp setWaypointType "MOVE";
            _wp setWaypointSpeed "NORMAL";
            _wp setWaypointBehaviour "COMBAT";
            _wps pushBack _wp;
        };
        _g setCurrentWaypoint (_wps select 0);
        _g setBehaviour "COMBAT";
        _g setCombatMode "RED";
    };

    // Initial sweep chain along the extrapolated heading.
    [_grp, _curLkp, _curHead, 10] call _chainWp;

    if (isNil "MISSION_CORE_HUNT_INTEL") then { MISSION_CORE_HUNT_INTEL = createHashMap; };
    private _lastRetarget = 0;
    private _lastClear = 0;
    while { time < _sweepEnd && { !isNull _grp } && { count units _grp > 0 } && { { alive _x } count units _grp > 0 } } do {
        sleep 8;
        if (isNull _player) then { continue; };

        // ---- Re-spot (REAL contact only) ----
        // A group member is considered to have "seen" the player when they have actual line of
        // sight AND knowsAbout > 0.7. Raw distance is NEVER sight (no wallhacking through a house
        // or a hill). A tiny 30m bump-in radius is the only non-LOS trigger (they practically
        // stepped on him).
        private _sight = (units _grp findIf { [_x, _player] call MISSION_CORE_fnc_huntSeesPlayer }) != -1;
        private _close = (leader _grp) distance2D _player < (["huntReSpotRadius", 30] call MISSION_CORE_fnc_tune);
        if (_sight || _close) then {
            // PUBLISH the real sighting as shared intel immediately. Until this moment no group
            // knew the player's EXACT position (the sweep ran on stale intel/LKP); this hunt squad
            // just ACTUALLY laid eyes on him. Every marked quadrant for his contested marker repoints
            // onto this fresh position right now - no waiting for the next director tick.
            if (isNil "MISSION_CORE_HUNT_INTEL") then { MISSION_CORE_HUNT_INTEL = createHashMap; };
            MISSION_CORE_HUNT_INTEL set [_playerKey, [getPos _player, _curHead, time]];
            if (isNil "MISSION_CORE_PLAYER_LKP") then { MISSION_CORE_PLAYER_LKP = createHashMap; };
            MISSION_CORE_PLAYER_LKP set [_playerKey, [getPos _player, _curHead, time]];
            diag_log format ["PLAYER HUNT: %1 re-sighted player - publishing fresh intel", groupId _grp];
            [_player, getPos _player] call MISSION_CORE_fnc_updateQuadrantsForPlayer;
            // ABORT sweep - engage on foot: never fight from the truck. Gun trucks keep their
            // driver+gunner mounted as fire support and dump the cargo; cargo trucks dump everyone.
            [_grp] call _disembark;
            // The waypoint aims at the last position where a unit could actually see the player
            // (his current pos IS a legit sighted position right now).
            [_grp] call MISSION_CORE_fnc_clearGroupWaypoints;
            private _wp = _grp addWaypoint [getPos _player, 40];
            _wp setWaypointType "SAD";
            _wp setWaypointSpeed "FULL";
            _wp setWaypointBehaviour "COMBAT";
            _grp setCurrentWaypoint _wp;
            _grp setBehaviour "COMBAT";
            _grp setCombatMode "RED";

            // Wait for them to shake him again (or kill him): the chase continues ONLY while a
            // member still has LOS+knows, or he is within 30m bump range. No 1500m distance glue.
            private _lastSeen = getPos _player;
            private _escAt = time + 30;
            while { time < _escAt && { !isNull _grp } && { alive _player } && { !isNull _player } } do {
                sleep 5;
                if (isNull _grp) exitWith {};
                private _still = (units _grp findIf { [_x, _player] call MISSION_CORE_fnc_huntSeesPlayer }) != -1;
                if (_still || { (leader _grp) distance2D _player < (["huntReSpotRadius", 30] call MISSION_CORE_fnc_tune) }) then {
                    _lastSeen = getPos _player;
                    _escAt = time + 30;
                    [_grp] call MISSION_CORE_fnc_clearGroupWaypoints;
                    if (alive _player) then {
                        private _wpE = _grp addWaypoint [getPos _player, 60];
                        _wpE setWaypointType "SAD";
                        _wpE setWaypointSpeed "FULL";
                        _grp setCurrentWaypoint _wpE;
                    };
                };
            };
            if (isNull _grp || { isNull _player } || { !(alive _player) }) then { break; };
            // Contact lost: resume sweeping from WHERE HE WAS LAST SEEN (not his live pos) + the
            // recorded heading. Fresh 10-min clock.
            _curLkp = _lastSeen;
            if (isNil "MISSION_CORE_PLAYER_LKP") then { MISSION_CORE_PLAYER_LKP = createHashMap; };
            _curHead = (MISSION_CORE_PLAYER_LKP getOrDefault [_playerKey, [_curLkp, _heading, 0]]) select 1;
            if (count (MISSION_CORE_HUNT_INTEL getOrDefault [_playerKey, []]) > 0) then {
                private _i = MISSION_CORE_HUNT_INTEL get _playerKey;
                if (time - (_i select 2) <= (["huntIntelDecay", 60] call MISSION_CORE_fnc_tune)) then { _curLkp = _i select 0; _curHead = _i select 1; };
            };
            _sweepEnd = time + (["huntSweepSeconds", 600] call MISSION_CORE_fnc_tune);
            // He was last seen at _curLkp - if a town/compound is here, clear its houses so he
            // can't be hiding inside one while they sweep past outside.
            [_grp, _curLkp] call MISSION_CORE_fnc_huntClearBuildings;
            [_grp, _curLkp, _curHead, 10] call _chainWp;
        } else {
            // ---- Sweeping blind, steered ONLY by stale shared intel ----
            // Every ~45s, if a garrison unit has ACTUALLY sighted the player within the last ~60s
            // (shared intel), nudge the sweep anchor/heading toward that known point. No contact =
            // keep walking the original extrapolated line. NEVER steered from a live player pos.
            if (time > _lastRetarget + (["huntRetargetEvery", 45] call MISSION_CORE_fnc_tune)) then {
                _lastRetarget = time;
                private _intel = MISSION_CORE_HUNT_INTEL getOrDefault [_playerKey, []];
                if (count _intel >= 3 && { (time - (_intel select 2)) <= 60 }) then {
                    private _nb = _curLkp getDir (_intel select 0);
                    [_grp, _curLkp, _nb, 10] call _chainWp;
                };
            };
            // When the squad is walking THROUGH houses on the sweep line, fan out and clear the
            // buildings along the way - keeps them from ignoring whole streets of cover. Throttled
            // to once per ~2min so doMove doesn't re-yank the squad every 8s tick.
            if (time > _lastClear + (["huntClearEvery", 120] call MISSION_CORE_fnc_tune) && { (leader _grp) distance2D _curLkp < 800 }) then {
                _lastClear = time;
                [_grp, getPos (leader _grp)] call MISSION_CORE_fnc_huntClearBuildings;
            };
        };
    };

    // Release THIS squad's hunt slot so a future loiter can dispatch a fresh contingent (other
    // squads hunting the same player stay registered).
    if (isNil "MISSION_CORE_HUNT_ACTIVE") then { MISSION_CORE_HUNT_ACTIVE = createHashMap; };
    private _list = MISSION_CORE_HUNT_ACTIVE getOrDefault [_playerKey, []];
    _list = _list - [_grp];
    MISSION_CORE_HUNT_ACTIVE set [_playerKey, _list];

    // No re-contact within the window -> retreat to the closest same-side marker, despawn on arrival.
    if (!isNull _grp && { count units _grp > 0 }) then {
        diag_log format ["PLAYER HUNT: contingent %1 sweep over - retreating", groupId _grp];
        // The hunt is over - release ownership so the commander can recommit this squad later.
        _grp setVariable ["MISSION_CORE_HUNT_KEY", ""];
        _grp setVariable ["MISSION_CORE_ORDER", ""];
        private _dest = [getPos (leader _grp), _side, [_srcName]] call MISSION_CORE_fnc_getRetreatDest;
        if (_dest distance [0, 0, 0] < 1) then {
            [_grp] call MISSION_CORE_fnc_deleteGroupCompletely;
        } else {
            _grp setCombatMode "GREEN";
            _grp setBehaviour "AWARE";
            _grp setSpeedMode "FULL";
            [_grp] call MISSION_CORE_fnc_clearGroupWaypoints;
            private _wp = _grp addWaypoint [_dest, 100];
            _wp setWaypointType "MOVE";
            _wp setWaypointSpeed "FULL";
            // Despawn on arrival - transport_retreatArrive.sqf fires on the MOVE completion.
            _wp setWaypointScript "fnc\commander\transport_retreatArrive.sqf";
            _grp setCurrentWaypoint _wp;
        };
    } else {
        if (!isNull _grp) then { [_grp] call MISSION_CORE_fnc_deleteGroupCompletely; };
    };
};
