// =====================================================================
// ARTY CONTROLLER (PER SIDE)
//
// ONE fire loop per side gathers every artillery piece of that side
// registered here - garrison pieces (initial overwatch spawns, recruited
// MLRS/SPG/mortar) and assault pieces (attached to a target marker).
// The fire mechanics are shared (rearm triggers, laser round tiering,
// bracket rake, range pull-back, standby cooldown); only the TARGET
// SOURCE differs by role:
//
//   garrison:  defenders' eyes - the marker's own garrison groups plus
//              the piece's crew must KNOW an enemy (knowsAbout > 0.7)
//              inside the marker's footprint (largest half-axis + 150,
//              clamped 300..2000 - the same rule the assault spot
//              search uses). No such contact -> no fire, no marker
//              fallback. REDFOR pieces keep the old generic nearest-
//              spotted-armor scan anywhere in weapon range.
//   assault:   contacts spotted by the assault squads marching on the
//              same target marker (assaultArtySpotTarget), else the
//              still-active marker itself (bracket rake), else nothing.
//   laser:     shared by every role - an exact painted dot always wins.
//
// Replaces the old per-group fn_overwatchArtillery loop and the single
// shared MISSION_CORE_fnc_playerArtyLoop (both folded in here). The
// bracket/spot/marker helpers stay in fn_recruitServer.sqf and are
// resolved at call time, so compile order is not load-bearing.
// Compiled on the server in fn_init.sqf.
// =====================================================================

if (isNil "MISSION_CORE_ARTY_CTRL") then { MISSION_CORE_ARTY_CTRL = createHashMap; };
// Per-side loop heartbeat: keys "_RUN_West"/"_TICK_West" (+ "_..._East").
if (isNil "MISSION_CORE_ARTY_CTRL_STATE") then { MISSION_CORE_ARTY_CTRL_STATE = createHashMap; };

// ---- registration ------------------------------------------------------

// [_veh, _grp, _side, _role ("garrison"|"assault"), _markerName, _aimPos]
// Keyed by netId, so a re-registration (e.g. an assault piece assigned a
// fresh target) overwrites in place. Then (re)starts the side's loop
// unless its heartbeat proves it already alive - a crashed loop (no tick
// in >90s) must not blacklist the side for the rest of the mission.
MISSION_CORE_fnc_artyRegister = {
    params ["_veh", "_grp", "_side", "_role", ["_markerName", ""], ["_aimPos", []]];
    if (isNull _veh || { isNull _grp }) exitWith {};
    if (_side != WEST && { _side != EAST }) exitWith {};
    if (isNil "MISSION_CORE_ARTY_CTRL") then { MISSION_CORE_ARTY_CTRL = createHashMap; };
    if (isNil "MISSION_CORE_ARTY_CTRL_STATE") then { MISSION_CORE_ARTY_CTRL_STATE = createHashMap; };
    MISSION_CORE_ARTY_CTRL set ["ARTY_" + str (netId _veh), [_veh, _grp, _role, _side, _markerName, _aimPos]];
    diag_log format ["ARTY CTRL: registered %1 (%2) role=%3 side=%4 marker=%5 aim=%6", _veh, typeOf _veh, _role, _side, _markerName, _aimPos];
    private _sk = str _side;
    if (!(MISSION_CORE_ARTY_CTRL_STATE getOrDefault ["_RUN_" + _sk, false]) || { time - (MISSION_CORE_ARTY_CTRL_STATE getOrDefault ["_TICK_" + _sk, -1e10]) > 90 }) then {
        MISSION_CORE_ARTY_CTRL_STATE set ["_RUN_" + _sk, true];
        MISSION_CORE_ARTY_CTRL_STATE set ["_TICK_" + _sk, time];
        [_side] spawn MISSION_CORE_fnc_artyLoop;
        diag_log format ["ARTY CTRL: %1 loop (re)started", _sk];
    };
};

// ---- garrison target source -------------------------------------------

// BLUFOR garrison target: the nearest KNOWN enemy inside this marker's
// footprint. Spotters are the marker's own garrison groups
// (MISSION_CORE_ORIGIN_MARKER == _markerName, alive only) plus the
// piece's own crew - a target must be known to them (knowsAbout > 0.7),
// not merely inside the ring. Footprint radius = largest half-axis + 150,
// clamped 300..2000. Infantry bucket first (matches the AI garrison-
// defense doctrine), armor fallback; MOVING vehicles are never engaged
// by area fire. Optional _mag prefilters candidates the ballistics cannot
// REACH (inRangeOfArtillery covers min AND max range). Returns a
// position, or [] when nothing is known in reach.
MISSION_CORE_fnc_artyGarrisonTarget = {
    params ["_veh", "_markerName", ["_mag", ""]];
    if (_markerName == "") exitWith { [] };
    private _enemy = if (side _veh == WEST) then { EAST } else { WEST };
    // Marker center + footprint radius (cached row first, locations row as fallback).
    private _mPos = [];
    private _mSearch = 450;
    if (!(isNil "MISSION_CORE_CACHED_POSITIONS")) then {
        private _mi = MISSION_CORE_CACHED_POSITIONS findIf { (_x select 0) == _markerName };
        if (_mi >= 0) then {
            private _row = MISSION_CORE_CACHED_POSITIONS select _mi;
            _mPos = _row select 1;
            private _sz = _row select 8;
            private _ma = if (count _sz > 0) then { _sz select 0 } else { 200 };
            private _mb = if (count _sz > 1) then { _sz select 1 } else { _ma };
            _mSearch = (((_ma max _mb) max 300) + 150) min 2000;
        };
    };
    if (count _mPos == 0 && { !(isNil "MISSION_CORE_LOCATIONS") }) then {
        private _li = MISSION_CORE_LOCATIONS findIf { (_x select 0) == _markerName };
        if (_li >= 0) then {
            private _row = MISSION_CORE_LOCATIONS select _li;
            _mPos = (_row select 1) select 0;
            private _sz = if (count _row > 8) then { _row select 8 } else { [200, 200] };
            private _ma = if (count _sz > 0) then { _sz select 0 } else { 200 };
            private _mb = if (count _sz > 1) then { _sz select 1 } else { _ma };
            _mSearch = (((_ma max _mb) max 300) + 150) min 2000;
        };
    };
    if (count _mPos == 0) exitWith { [] };
    // Defender spotters: the marker's garrison groups (alive only) + the crew.
    private _spotters = [];
    if (!(isNil "MISSION_CORE_SPAWNED_GROUPS")) then {
        {
            private _sg = _x;
            if (isNull _sg) then { continue; };
            if ((_sg getVariable ["MISSION_CORE_ORIGIN_MARKER", ""]) != _markerName) then { continue; };
            if ({ alive _x } count units _sg > 0) then { _spotters pushBack _sg; };
        } forEach MISSION_CORE_SPAWNED_GROUPS;
    };
    {
        if (alive _x) then { _spotters pushBack _x; };
    } forEach (crew _veh);
    if (count _spotters == 0) exitWith { [] };
    private _infantry = [];
    private _armor = [];
    {
        private _u = _x;
        if (!(alive _u) || { side _u != _enemy }) then { continue; };
        if (_u distance2D _mPos > _mSearch) then { continue; };
        if (_spotters findIf { _x knowsAbout _u > 0.7 } == -1) then { continue; };
        if (_mag != "" && { !((getPos _u) inRangeOfArtillery [[_veh], _mag]) }) then { continue; };
        if (_u isKindOf "Man") then { _infantry pushBack _u; continue; };
        if (_u isKindOf "LandVehicle") then {
            if (speed _u > 2) then { continue; };
            if (_u isKindOf "Wheeled_APC" || { _u isKindOf "Tracked_APC" } || { _u isKindOf "Tank" } || { _u isKindOf "Tank_F" }) then {
                _armor pushBack _u;
            };
        };
    } forEach (allUnits + vehicles);
    private _pickNearest = {
        params ["_list"];
        if (count _list == 0) exitWith { [] };
        private _best = _list select 0;
        private _bestD = _best distance2D _veh;
        {
            private _d = _x distance2D _veh;
            if (_d < _bestD) then { _bestD = _d; _best = _x; };
        } forEach _list;
        getPos _best
    };
    private _best = [_infantry] call _pickNearest;
    if (count _best == 0) then { _best = [_armor] call _pickNearest; };
    _best
};

// ---- per-side loop -----------------------------------------------------

// One 8s tick per side walks that side's registered pieces. Reuses the
// fn_recruitServer helpers (isValidArtyAim, assaultArtySpotTarget,
// assaultArtyMarkerFireable, assaultArtyBracketStep) and the fn_artillery
// round helpers at call time.
MISSION_CORE_fnc_artyLoop = {
    params ["_side"];
    if (isNil "MISSION_CORE_ARTY_CTRL") then { MISSION_CORE_ARTY_CTRL = createHashMap; };
    if (isNil "MISSION_CORE_ARTY_CTRL_STATE") then { MISSION_CORE_ARTY_CTRL_STATE = createHashMap; };
    private _sk = str _side;
    private _running = true;
    while { _running } do {
        sleep 8;
        // Heartbeat BEFORE the work so a failed tick still proves the loop
        // was alive (registration sites use it to respawn a crashed loop).
        MISSION_CORE_ARTY_CTRL_STATE set ["_TICK_" + _sk, time];
        private _anyLive = false;
        private _deadKeys = [];
        // A platoon's vehicles share one group; relocate the group once per tick, not once per piece.
        private _relocatedGroups = [];
        {
            private _key = _x;
            private _data = MISSION_CORE_ARTY_CTRL get _key;
            if (isNil "_data") then { continue; };
            if ((_data select 3) != _side) then { continue; };
            _data params ["_veh", "_grp", "_role", "", "_markerName", "_aimAt"];
            // A piece stays registered (keeps firing) as long as the vehicle is alive
            // and usable. Only a fully disabled or dead tank stops the entry - ammo-down
            // or immobilized vehicles keep the fire loop running for when the gun comes
            // back / gets repaired. Deletion happens after the walk (dead-key list), so
            // the registry is never mutated mid-iteration.
            if (isNull _veh || { !(alive _veh) } || { getDammage _veh >= 1 } || { isNull _grp } || { { alive _x } count units _grp == 0 }) then {
                _deadKeys pushBack _key;
                continue;
            };
            _anyLive = true;
            private _lastFire = _veh getVariable ["MISSION_CORE_ARTY_LAST_FIRE", 0];
            // REARM, three independent triggers (no spawned thread - this 8s tick owns
            // the deadline via vehicle variable MISSION_CORE_ARTY_REARM_UNTIL):
            //   1. Any combat (HE) ammo TYPE has run out (0 rounds) -> reload now, regardless of idle.
            //   2. The piece has done NOTHING for 5 full minutes AND total combat ammo is below max
            //      -> reload (a shot moving _lastFire forward resets the idle clock for free).
            //   3. Fewer than HALF the magazines the piece spawned with are left -> reload (the
            //      50% rule; baseline captured lazily on the first tick while mags are full).
            // On trigger: "rearming" parked for ~20s (no fire, no relocate), then setVehicleAmmo to
            // max and "rearmed". An empty LG mag alone doesn't force it - tiering downgrades to
            // GPS/other and it keeps fighting; the HE-empty rule catches a truly dry piece.
            private _rearmUntil = _veh getVariable ["MISSION_CORE_ARTY_REARM_UNTIL", 0];
            if (_rearmUntil > 0) then {
                if (time >= _rearmUntil) then {
                    _veh setVariable ["MISSION_CORE_ARTY_REARM_UNTIL", nil];
                    _veh setVehicleAmmo 1;
                    _veh setVehicleAmmoDef 1;
                    _veh setFuel 1;
                    [_grp, "Rearmed. All ammunition restored. Resuming fire support."] call MISSION_CORE_fnc_artillerySideChat;
                    diag_log format ["ARTY CTRL: %1 (%2) rearm complete - ammo refilled, refueled", _veh, typeOf _veh];
                } else {
                    continue;
                };
            } else {
                // Aggregate rounds PER combat ammo type (non-smoke): current vs the type's max.
                // Accumulate into per-type hashmaps, then iterate keys (a plain array) - never
                // forEach over a HashMap directly (iterator reliability quirk). includeEmpty=true
                // is essential: a SPENT magazine then still appears with 0 rounds, so trigger 1
                // (_cur == 0) can actually see it - with mags vanishing it never fired.
                private _typeCur = createHashMap;
                private _typeMax = createHashMap;
                {
                    private _m = _x select 0;
                    if (_m find "Smoke" == -1) then {
                        _typeCur set [_m, (_typeCur getOrDefault [_m, 0]) + (_x select 1)];
                        _typeMax set [_m, (_typeMax getOrDefault [_m, 0]) + (getNumber (configFile >> "CfgMagazines" >> _m >> "count"))];
                    };
                } forEach (magazinesAmmo [_veh, true]);
                private _heOut = false;
                private _totalCur = 0;
                private _totalMax = 0;
                {
                    private _m = _x;
                    private _cur = _typeCur getOrDefault [_m, 0];
                    private _max = _typeMax getOrDefault [_m, 0];
                    if (_max > 0) then {
                        if (_cur == 0) then { _heOut = true; };
                    };
                    _totalCur = _totalCur + _cur;
                    _totalMax = _totalMax + _max;
                } forEach (keys _typeCur);
                private _needRearm = _heOut;
                if (!_needRearm) then {
                    if (time - _lastFire > 300) then {
                        if (_totalCur < _totalMax) then { _needRearm = true; };
                    };
                };
                // Trigger 3: below half the spawn magazine count. Non-empty mag count shrinks as
                // whole magazines empty (includeEmpty=false), the baseline stays at spawn level.
                private _lowSpawn = false;
                if (!_needRearm) then {
                    if (isNil { _veh getVariable "MISSION_CORE_ARTY_MAGS_SPAWN" }) then {
                        _veh setVariable ["MISSION_CORE_ARTY_MAGS_SPAWN", count magazinesAmmo [_veh, true]];
                    };
                    private _spawnMags = _veh getVariable ["MISSION_CORE_ARTY_MAGS_SPAWN", 0];
                    if (_spawnMags > 0 && { (count magazinesAmmo [_veh, false]) * 2 < _spawnMags }) then {
                        _lowSpawn = true;
                        _needRearm = true;
                    };
                };
                if (_needRearm) then {
                    _veh setVariable ["MISSION_CORE_ARTY_REARM_UNTIL", time + 20];
                    [_grp, "Rearming. Ordnance depleted or resupply due - weapons offline."] call MISSION_CORE_fnc_artillerySideChat;
                    diag_log format ["ARTY CTRL: %1 (%2) rearming - trigger HEempty=%3 idle5mBelowMax=%4 lowSpawnMags=%5", _veh, typeOf _veh, _heOut, (time - _lastFire > 300), _lowSpawn];
                    continue;
                };
            };
            // Assessed at tick scope: the relocation block below (which sits AFTER the fire block)
            // gates on _standoffGun, and a block-private declaration would be out of scope there.
            private _standoffGun = if (_role == "assault") then { [_aimAt] call MISSION_CORE_fnc_isValidArtyAim } else { false };
            if (time - _lastFire > 120) then {
                private _enemy = if (side _veh == WEST) then { EAST } else { WEST };
                private _laserTarget = if (!(_veh isKindOf "StaticMortar")) then {
                    [side _veh, _veh, 10000] call MISSION_CORE_fnc_artilleryLaserTarget;
                } else { [] };
                private _preferLaser = count _laserTarget > 0;
                // Assault pieces fire at REAL enemy targets on their assigned marker. LASER still
                // wins - an exact dot lands where aimed (the only case a MOVING target may be
                // engaged). Standoffs become last-resort fire only when the objective is still
                // ACTIVE (an alive assault squad still presses it) AND enemy-held - a captured or
                // abandoned marker never draws fire.
                private _markerFireable = if (_standoffGun) then {
                    [_veh, _aimAt] call MISSION_CORE_fnc_assaultArtyMarkerFireable
                } else { false };
                // TARGET SOURCE by role (the only difference between garrison and assault):
                // laser -> assault contact/bracket/marker -> garrison known-in-footprint scan.
                private _target = [];
                private _targetFromContact = false;
                private _bracketPos = [];   // shared group bracket-rake step when marker-barraging
                private _targetSource = "none";
                if (_preferLaser) then {
                    _target = _laserTarget;
                    _targetSource = "laser";
                } else {
                    if (_standoffGun) then {
                        // Real contacts win: eligible enemies the assault squads on the same marker
                        // have spotted (see fn_assaultArtySpotTarget - stationary tanks > APCs, no
                        // moving vehicles). Only when no such contact exists does the piece fall back
                        // to the assigned marker, and then ONLY if it is still active + enemy.
                        _target = [_veh, _aimAt] call MISSION_CORE_fnc_assaultArtySpotTarget;
                        if (count _target > 0) then {
                            _targetFromContact = true;
                            _targetSource = "assault-contact";
                        } else {
                            if (_markerFireable) then {
                                // BRACKET BARRAGE (active target marker): rake the marker's footprint
                                // from its NEAR side to its FAR side - all pieces fire at the SAME
                                // bracket location each volley, stepping across until the LAST bracket,
                                // then cease firing on the marker location. Afterwards the bare marker
                                // never draws indirect fire again - further fire missions come only from
                                // spotted contacts (assaultArtySpotTarget) or laser dots.
                                _bracketPos = [_veh, _grp, _aimAt] call MISSION_CORE_fnc_assaultArtyBracketStep;
                                if (count _bracketPos > 0) then {
                                    _target = _aimAt;
                                    _targetSource = "assault-bracket";
                                };
                            };
                        };
                    } else {
                        // GARRISON: round first so the scan keeps only candidates the ballistics can
                        // REACH (inRangeOfArtillery covers min AND max range).
                        private _preMag = [_veh, false] call MISSION_CORE_fnc_pickArtilleryMag;
                        private _preMagName = if (count _preMag > 0) then { _preMag select 0 } else { "" };
                        if (side _veh == WEST) then {
                            // BLUFOR: defenders' eyes - known enemy inside the marker footprint,
                            // given by this piece's marker association (no marker -> no fire).
                            _target = [_veh, _markerName, _preMagName] call MISSION_CORE_fnc_artyGarrisonTarget;
                            if (count _target > 0) then { _targetSource = "garrison-spot"; };
                        } else {
                            // REDFOR: the old generic way - nearest spotted armor anywhere in range.
                            _target = [_veh, _enemy, _preMagName] call MISSION_CORE_fnc_artilleryTarget;
                            if (count _target > 0) then { _targetSource = "redfor-spot"; };
                        };
                    };
                };
                if (count _target > 0) then {
                    // Round tiering for a laser-designated coord: 1) laser-guided round (LGB,
                    // weaponLockSystem flag 4) hits the exact dot; 2) a GPS/precision self-homing
                    // round ("guided" magazine) also hits the exact coord; 3) any other live shell
                    // drops a bracketed barrage onto the coord instead of a single precise hit.
                    private _roundTier = "other";
                    private _mag = [];
                    if (_preferLaser) then {
                        private _shells = (magazinesAmmo _veh) select { (_x select 1) > 0 && { (_x select 0) find "Smoke" == -1 } };
                        if (count _shells > 0) then {
                            private _laserSet = [_veh] call MISSION_CORE_fnc_artilleryLaserMags;
                            private _gpsSet = [_veh] call MISSION_CORE_fnc_artilleryGpsMags;
                            diag_log format ["ARTY CTRL DIAG: %1 loaded=%2 laserSet=%3 gpsSet=%4", typeOf _veh, ((magazinesAmmo _veh) apply { _x select 0 }), _laserSet, _gpsSet];
                            private _liveLaser = _shells select { (_x select 0) in _laserSet };
                            if (count _liveLaser > 0) then {
                                _roundTier = "laser";
                                _mag = _liveLaser select 0;
                            } else {
                                private _liveGps = _shells select { (_x select 0) in _gpsSet && { !((_x select 0) in _laserSet) } };
                                if (count _liveGps > 0) then {
                                    _roundTier = "gps";
                                    _mag = _liveGps select 0;
                                } else {
                                    _roundTier = "other";
                                    _mag = _shells select 0;
                                };
                            };
                        };
                    } else {
                        _mag = [_veh, false] call MISSION_CORE_fnc_pickArtilleryMag;
                    };
                    if (count _mag > 0) then {
                        // Command the shot from a crewmember actually IN the piece. doArtilleryFire
                        // silently does nothing when the caller is a foot soldier (e.g. a CfgGroups
                        // recruit template whose group leader walks outside the tank), so prefer the
                        // vehicle's commander, then the gunner - never blindly the group leader.
                        private _cmdr = commander _veh;
                        if (isNull _cmdr || { !(alive _cmdr) }) then { _cmdr = gunner _veh; };
                        if (isNull _cmdr || { !(alive _cmdr) }) then { _cmdr = leader _grp; };
                        if (!(isNull _cmdr) && { alive _cmdr }) then {
                            // LGB and GPS rounds land on the painted coord (single precision shot);
                            // a plain shell scatters a 3-round bracket over the coord.
                            private _exact = _roundTier != "other";
                            private _salvo = if (_exact) then { 1 } else { 3 };
                            private _magClass = _mag select 0;
                            // Standoff barrage is delivered to a scattered point so each volley lands
                            // near the marker rather than on the head of a single soldier/vehicle.
                            // A bracket-rake volley aims ALL pieces of the group at the same shared step position; any
                            // other area shot keeps the scattered-point behavior.
                            private _firePos = if (_exact) then { _target } else { if (count _bracketPos > 0) then { _bracketPos } else { [_veh, _target, false] call MISSION_CORE_fnc_scatterArtilleryPoint; }; };
                            // A fire mission outside the round's reach makes the crew radio "Invalid
                            // coordinates. Cease fire." and nothing flies. Pull the aim back along the
                            // bearing to the target (90%..30% of distance) until the point is verifiably
                            // in range, so the piece still delivers a reachable suppression near the
                            // intended marker instead of a dead radio line.
                            private _tp = _firePos;
                            if (_exact) then {
                                private _dotRange = _tp inRangeOfArtillery [[_veh], _magClass];
                                if (!_dotRange) then {
                                    diag_log format ["ARTY CTRL: %1 (%2) laser coord %3 out of range for %4", _veh, typeOf _veh, _tp, _magClass];
                                };
                            } else {
                                // _firePos is the intended impact dot (a random scatter disc around the
                                // target, or the group's shared bracket step). When that dot is out of
                                // reach, the correction depends on WHICH limit was hit: a target beyond
                                // the piece's reach is dragged back IN along the bearing; a target inside
                                // the piece's minimum ballistic arc can never be engaged from here, so
                                // pulling closer only digs in - the aim instead extends OUTWARD past the
                                // marker. Either way the fallback re-scatters RANDOMLY around the first
                                // reachable point - a true pattern, never a deterministic snap to a single
                                // bearing coordinate.
                                if (!(_tp inRangeOfArtillery [[_veh], _magClass])) then {
                                    private _bearing = _veh getDir _firePos;
                                    private _dist = _veh distance2D _firePos;
                                    private _minR = _veh call MISSION_CORE_fnc_serverArtyMinRange;
                                    private _close = _veh distance2D _target < _minR;
                                    private _shifts = if (_close) then { [1.2, 1.35, 1.5, 1.65, 1.8, 2.0] } else { [0.9, 0.8, 0.7, 0.6, 0.5, 0.4, 0.3] };
                                    private _anchor = [];
                                    {
                                        private _cand = _veh getPos [_dist * _x, _bearing];
                                        if (_cand inRangeOfArtillery [[_veh], _magClass]) exitWith { _anchor = _cand; };
                                    } forEach _shifts;
                                    if (count _anchor > 0) then {
                                        private _spread = (_minR * 0.35) min 80;
                                        private _rdir = random 360;
                                        private _rr = sqrt (random 1) * _spread;
                                        _tp = [_anchor select 0, _anchor select 1, 0] vectorAdd [(sin _rdir) * _rr, (cos _rdir) * _rr, 0];
                                        if (!(_tp inRangeOfArtillery [[_veh], _magClass])) then { _tp = _anchor; };
                                    } else {
                                        if (_close) then { _veh setVariable ["MISSION_CORE_ARTY_WANT_MOVE", true]; };
                                        diag_log format ["ARTY CTRL: %1 (%2) mission %3 invalid - no in-range aim point for %4", _veh, typeOf _veh, _target, _magClass];
                                    };
                                };
                            };
                            if ((_tp inRangeOfArtillery [[_veh], _magClass])) then {
                                _cmdr doArtilleryFire [_tp, _magClass, _salvo];
                                _veh setVariable ["MISSION_CORE_ARTY_LAST_FIRE", time];
                                private _srcLabel = if (_roundTier == "laser") then { "laser-LGB" } else { if (_roundTier == "gps") then { "laser-GPS" } else { _targetSource } };
                                diag_log format ["ARTY CTRL: %1 (%2) fired %3x %4 at %5 -> %6m via %7 (%8)", _veh, typeOf _veh, _salvo, _magClass, _tp, round (_veh distance2D _tp), _cmdr, _srcLabel];
                            } else {
                                diag_log format ["ARTY CTRL: %1 (%2) skipped fire mission %3 - out of range / invalid coords", _veh, typeOf _veh, _target];
                            };
                        };
                    };
                };
            };
            // Assault-piece relocation: after each barrage the piece moves to a BLUFOR marker to
            // keep it safe (run-away behavior), exactly like the REDFOR artillery driver. Only
            // relocates once it has actually fired at least once - a fresh piece never rushes away
            // unseen - OR when the current target sits inside the minimum ballistic range
            // (MISSION_CORE_ARTY_WANT_MOVE), because no in-range aim point exists from here at
            // all; a new firing marker is the fix. Garrison pieces NEVER relocate (they hold
            // their own marker).
            if (_standoffGun && { _lastFire > 0 || { _veh getVariable ["MISSION_CORE_ARTY_WANT_MOVE", false] } }) then {
                // A group of SPGs shares waypoints - relocate the whole platoon once per tick so the
                // commander's standoff move applies to every vehicle together.
                if (_relocatedGroups findIf { _x == _grp } != -1) then { continue; };
                private _lastMove = _veh getVariable ["MISSION_CORE_ARTY_LAST_MOVE", 0];
                if (time - _lastMove > 45 && { (_lastFire + 30 < time) || { _veh getVariable ["MISSION_CORE_ARTY_WANT_MOVE", false] } }) then {
                    // Run to a DIFFERENT BLUFOR marker (>= 800m away) so the shot-down position is
                    // abandoned, mirroring the REDFOR artillery driver's retreat. The new standoff
                    // must also keep this piece's minimum ballistic range from its aim target, or
                    // the next salvo would be "Invalid coordinates / cease fire" again. When every
                    // friendly marker is too close to the target, stay where it is.
                    private _minR = _veh call MISSION_CORE_fnc_serverArtyMinRange;
                    private _standoff = [getPosATL _veh, 800, _aimAt, _minR] call MISSION_CORE_fnc_serverArtyStandoff;
                    if (_standoff distance [0, 0, 0] > 1) then {
                        _relocatedGroups pushBack _grp;
                        _veh setVariable ["MISSION_CORE_ARTY_LAST_MOVE", time];
                        _veh setVariable ["MISSION_CORE_ARTY_WANT_MOVE", false];
                        _grp setBehaviour "SAFE";
                        _grp setSpeedMode "LIMITED";
                        [_grp] call MISSION_CORE_fnc_clearGroupWaypoints;
                        private _wp = _grp addWaypoint [_standoff, 50];
                        _wp setWaypointType "MOVE";
                        _wp setWaypointBehaviour "SAFE";
                        _wp setWaypointCombatMode "YELLOW";
                        _wp setWaypointSpeed "LIMITED";
                        private _hwp = _grp addWaypoint [_standoff, 0];
                        _hwp setWaypointType "HOLD";
                        _hwp setWaypointBehaviour "SAFE";
                        _hwp setWaypointCombatMode "YELLOW";
                        _hwp setWaypointSpeed "LIMITED";
                        _grp setCurrentWaypoint _wp;
                        diag_log format ["ARTY CTRL: assault piece %1 relocated to BLUFOR marker %2", _veh, _standoff];
                    };
                };
            };
        } forEach (keys MISSION_CORE_ARTY_CTRL);
        // Prune dead entries only after the walk (a HashMap is never mutated while iterating
        // its keys - and never forEach'd directly, see the mission's SQF rules).
        { MISSION_CORE_ARTY_CTRL deleteAt _x; } forEach _deadKeys;
        if (!_anyLive) then {
            MISSION_CORE_ARTY_CTRL_STATE set ["_RUN_" + _sk, false];
            _running = false;
        };
    };
    diag_log format ["ARTY CTRL: %1 loop exiting - no live entries", _sk];
};
