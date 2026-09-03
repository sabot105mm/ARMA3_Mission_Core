// =====================================================================
// AI ARTILLERY
// One piece per side (self-propelled gun preferred, static mortar fallback).
// It parks 1000m+ away from the nearest contested marker / player and holds
// position; when friendly AI spot an enemy tank it shell-bombs it with
// doArtilleryFire. Order/armor-slot variables keep every other AI system
// (commits, armor commander, overwatch despawn, stray recovery) from moving
// or despawning the piece.
// =====================================================================

MISSION_CORE_fnc_artilleryHomePos = {
    params ["_side", ["_isStatic", false]];
    private _contested = [_side] call MISSION_CORE_fnc_getContestedMarkers;
    private _anchor = [0, 0, 0];
    private _cName = "";
    if (count _contested > 0) then {
        _anchor = (_contested select 0) select 1;
        _cName = (_contested select 0) select 0;
    } else {
        private _players = allPlayers select { alive _x };
        if (count _players > 0) then {
            _anchor = getPos (_players select 0);
        } else {
            if (count MISSION_CORE_CACHED_POSITIONS > 0) then { _anchor = (MISSION_CORE_CACHED_POSITIONS select 0) select 1; };
        };
    };
    if (_anchor distance [0, 0, 0] < 1) exitWith { [0, 0, 0] };
    if (_isStatic) exitWith {
        // Mortars spawn INSIDE the contested marker when the battle starts
        _anchor
    };
    // Self-propelled guns spawn at a NEIGHBORING friendly marker (the closest friendly marker to
    // the contested one, excluding the contested marker itself).
    private _friendly = MISSION_CORE_CACHED_POSITIONS select {
        (_x select 4) == _side && { (_x select 0) != _cName }
    };
    if (count _friendly == 0) exitWith { _anchor };
    private _best = _friendly select 0;
    private _bestD = (_best select 1) distance2D _anchor;
    {
        private _d = (_x select 1) distance2D _anchor;
        if (_d < _bestD) then { _bestD = _d; _best = _x; };
    } forEach _friendly;
    (_best select 1)
};

// Nearest danger anchor for a side's artillery: the closest contested marker of that side, or the
// closest player - whichever is nearer to the given position
MISSION_CORE_fnc_artilleryDanger = {
    params ["_side", "_refPos"];
    private _best = [0, 0, 0];
    private _bestD = 1e10;
    {
        private _d = (_x select 1) distance2D _refPos;
        if (_d < _bestD) then { _bestD = _d; _best = _x select 1; };
    } forEach ([_side] call MISSION_CORE_fnc_getContestedMarkers);
    {
        private _d = _x distance2D _refPos;
        if (_d < _bestD) then { _bestD = _d; _best = getPos _x; };
    } forEach (allPlayers select { alive _x });
    _best
};

// Target selection: the nearest enemy armored vehicle (tank/APC) within range that at least one
// friendly AI unit within 1200m of it knows about (knowsAbout > 0.4). Returns a position.
MISSION_CORE_fnc_artilleryTarget = {
    params ["_veh", "_enemy"];
    private _rangeCap = if (_veh isKindOf "StaticMortar") then { 1700 } else { 10000 };
    private _candidates = vehicles select {
        alive _x &&
        { side _x == _enemy } &&
        { _x isKindOf "Tank_F" || { _x isKindOf "Tank" } || { _x isKindOf "Wheeled_APC" } || { _x isKindOf "Tracked_APC" } } &&
        { _x distance2D _veh < _rangeCap }
    };
    private _best = [];
    private _bestD = 1e10;
    {
        private _tank = _x;
        private _spotted = false;
        {
            if (side _x == side _veh && { alive _x } && { _x knowsAbout _tank > 0.7 }) exitWith { _spotted = true; };
        } forEach (_tank nearEntities [["Man", "LandVehicle"], 1200]);
        if (_spotted) then {
            private _d = _tank distance2D _veh;
            if (_d < _bestD) then { _bestD = _d; _best = getPos _tank; };
        };
    } forEach _candidates;
    _best
};

// Mortar target selection: the nearest enemy INFANTRY (not armor) that a friendly AI unit nearby
// knows about (knowsAbout > 0.4). Returns a position. SPGs use fn_artilleryTarget (tanks/APCs).
MISSION_CORE_fnc_artilleryInfantryTarget = {
    params ["_veh", "_enemy"];
    private _rangeCap = if (_veh isKindOf "StaticMortar") then { 1700 } else { 10000 };
    private _friendly = side _veh;
    private _candidates = allUnits select {
        alive _x &&
        { side _x == _enemy } &&
        { _x isKindOf "Man" } &&
        { _x distance2D _veh < _rangeCap }
    };
    private _best = [];
    private _bestD = 1e10;
    {
        private _tgt = _x;
        private _spotted = false;
        {
            if (side _x == _friendly && { alive _x } && { _x knowsAbout _tgt > 0.7 }) exitWith { _spotted = true; };
        } forEach (_tgt nearEntities [["Man", "LandVehicle"], 1200]);
        if (_spotted) then {
            private _d = _tgt distance2D _veh;
            if (_d < _bestD) then { _bestD = _d; _best = getPos _tgt; };
        };
    } forEach _candidates;
    _best
};

// Fallback target when no tanks are spotted: the center of the nearest marker owned by the
// player's side (never our own territory) that has an alive player within 600m of it and is in
// range. Firing at these betrays the piece's position, so the driver repositions afterwards.
MISSION_CORE_fnc_artilleryMarkerTarget = {
    params ["_side", "_refPos", "_rangeCap"];
    private _players = allPlayers select { alive _x };
    if (count _players == 0) exitWith { [] };
    private _best = [];
    private _bestD = 1e10;
    {
        if ((_x select 4) == _side) then { continue; };
        private _mPos = _x select 1;
        private _playerNear = _players findIf { _x distance2D _mPos < 600 } > -1;
        if (!_playerNear) then { continue; };
        private _d = _mPos distance2D _refPos;
        if (_d < _rangeCap && { _d < _bestD }) then { _bestD = _d; _best = _mPos; };
    } forEach MISSION_CORE_CACHED_POSITIONS;
    _best
};

// Scatter an artillery aim point by a radius that GROWS with range: mortar fire wanders widely at
// long range (high, slow ballistic arc + imprecise sighting), while SPG/MLRS stay comparatively
// tight. Uniform disc so shots land anywhere in the circle, not just a ring or a cross.
MISSION_CORE_fnc_scatterArtilleryPoint = {
    params ["_veh", "_target", ["_isInfantry", false]];
    private _range = _veh distance2D _target;
    private _isMortar = _veh isKindOf "StaticMortar";
    // Mortar: linear with range, 100m at 1000m. SPG: tight spread (fine for vehicles), but when a
    // self-propelled gun spends its area fire on infantry the pattern widens 4x - gunfire on
    // foot-mobile targets should wander rather than hammer a single point.
    private _spread = if (_isMortar) then { _range * 0.1 } else { 4 + _range * 0.008 };
    if (!_isMortar && { _isInfantry }) then { _spread = _spread * 4; };
    _spread = _spread min 300;
    private _dir = random 360;
    private _r = sqrt (random 1) * _spread;
    [(_target select 0) + (sin _dir) * _r, (_target select 1) + (cos _dir) * _r, 0]
};

// Walk a vehicle's turret weapons and return every magazine class belonging to a weapon whose
// CfgWeapons "weaponLockSystem" (an integer, or a "a + b" expression of flags) includes the
// LASER-GUIDED flag (4). Used to tell a self-propelled gun it carries a laser-guided round.
MISSION_CORE_fnc_artilleryLaserMags = {
    params ["_veh"];
    private _cls = typeOf _veh;
    private _laserMags = [];
    private _scanTurret = {
        params ["_turretCfg"];
        {
            private _w = _x;
            private _weap = configFile >> "CfgWeapons" >> _w;
            private _wls = getText (_weap >> "weaponLockSystem");
            if (_wls == "") then { _wls = str (getNumber (_weap >> "weaponLockSystem")); };
            private _flags = 0;
            { _flags = _flags + (parseNumber _x); } forEach (_wls splitString " +");
            if (_flags mod 8 >= 4) then {
                { _laserMags pushBack _x; } forEach (getArray (_weap >> "magazines"));
            };
        } forEach (getArray (_turretCfg >> "weapons"));
        {
            [_x] call _scanTurret;
        } forEach ("true" configClasses (_turretCfg >> "turrets"));
    };
    {
        [_x] call _scanTurret;
    } forEach ("true" configClasses (configFile >> "CfgVehicles" >> _cls >> "turrets"));
    _laserMags
};

// The laser dot currently being painted by a friendly unit with a laser designator, if it's a
// ground position within the piece's range. Returns a position (or []).
MISSION_CORE_fnc_artilleryLaserTarget = {
    params ["_side", "_veh", "_rangeCap"];
    private _best = [];
    {
        if (side _x == _side && { alive _x } && { _x hasWeapon "Laserdesignator" }) then {
            private _lt = laserTarget _x;
            if (!isNull _lt) then {
                private _p = getPosATL _lt;
                if (_veh distance2D _p < _rangeCap) then { _best = _p; };
            };
        };
    } forEach allPlayers;
    _best
};

// Select the right round for the piece. weaponLockSystem tells us which magazines are laser-guided:
// when a laser dot is our target we want the laser-guided round, otherwise we prefer a standard
// (unguided) round for area fire. Returns [magazine, count] or [].
MISSION_CORE_fnc_pickArtilleryMag = {
    params ["_veh", "_preferLaser"];
    private _shells = (magazinesAmmo _veh) select { (_x select 1) > 0 && { (_x select 0) find "Smoke" == -1 } };
    if (count _shells == 0) exitWith { [] };
    private _laserSet = [_veh] call MISSION_CORE_fnc_artilleryLaserMags;
    private _laser = _shells select { (_x select 0) in _laserSet };
    private _normal = _shells select { !((_x select 0) in _laserSet) };
    if (_preferLaser) then {
        if (count _laser > 0) then { _laser select 0 } else { _shells select 0 };
    } else {
        if (count _normal > 0) then { _normal select 0 } else { _shells select 0 };
    }
};

// Play an audible built-in Arma 3 explosion/cannon sound at a position so nearby players hear the
// piece fire/reload. Volumes and distance cap keep it perceptible but not overwhelming.
MISSION_CORE_fnc_artilleryPlaySound = {
    params ["_pos", ["_volume", 3], ["_distance", 2500]];
    playSound3D ["\a3\sounds_f\weapons\Explosion\expl_big_1.wss", objNull, false, _pos, _volume, 1, _distance];
};

// Side chat from the piece's commander on the side that owns it, so friendly players get fire /
// reload / range / ETA reports.
MISSION_CORE_fnc_artillerySideChat = {
    params ["_grp", "_msg"];
    private _cmdr = leader _grp;
    if (!isNull _cmdr && { alive _cmdr }) then {
        _cmdr sideChat _msg;
    };
};

MISSION_CORE_fnc_spawnArtillery = {
    params ["_side"];
    if (isNil "MISSION_CORE_ARTY") then { MISSION_CORE_ARTY = createHashMap; };
    private _sideKey = if (_side == WEST) then { "BLUFOR" } else { "REDFOR" };
    private _factionData = if (_side == WEST) then { MISSION_CORE_BLUFOR_DATA } else { MISSION_CORE_REDFOR_DATA };
    if (isNil "_factionData") exitWith {};
    private _vehMap = _factionData select 7;
    private _staticMap = _factionData select 9;
    private _spgClasses = _vehMap getOrDefault ["artillery", []];
    private _mortarClasses = _staticMap getOrDefault ["mortar", []];
    private _vehClass = "";
    private _isStatic = false;
    private _hasSpg = count _spgClasses > 0;
    private _hasMortar = count _mortarClasses > 0;
    // When both an SPG and a mortar are available, roll randomly between them - either side can
    // field a mortar instead of always taking the SPG. Otherwise use whatever single type exists.
    if (_hasSpg && { _hasMortar }) then {
        if (random 1 < 0.5) then {
            _vehClass = selectRandom _spgClasses;
        } else {
            _vehClass = selectRandom _mortarClasses;
            _isStatic = true;
        };
    } else {
        if (_hasSpg) then {
            _vehClass = selectRandom _spgClasses;
        } else {
            if (_hasMortar) then {
                _vehClass = selectRandom _mortarClasses;
                _isStatic = true;
            } else {
                diag_log format ["AI ARTY: no SPG or mortar class for %1, retrying later", _sideKey];
                MISSION_CORE_ARTY set [_sideKey, [grpNull, objNull, time + 900]];
            };
        };
    };
    if (_vehClass == "") exitWith {};
    private _pos = [_side, _isStatic] call MISSION_CORE_fnc_artilleryHomePos;
    if (_pos distance [0, 0, 0] < 1) exitWith {
        MISSION_CORE_ARTY set [_sideKey, [grpNull, objNull, time + 300]];
    };
    private _veh = createVehicle [_vehClass, _pos, [], 5, "CAN_COLLIDE"];
    _veh setPosATL ([_pos] call MISSION_CORE_fnc_liftSpawn);
    _veh setVehicleAmmo 1;
    _veh setVehicleAmmoDef 1;
    private _grp = createVehicleCrew _veh;
    _grp addVehicle _veh;
    _grp setVariable [format ["MISSION_CORE_%1", _sideKey], true];
    _grp setVariable ["MISSION_CORE_ORDER", "artillery"];
    _grp setVariable ["MISSION_CORE_ARMOR_SLOT", "arty"];
    _grp setVariable ["MISSION_CORE_ARTILLERY", true];
    _grp setVariable ["MISSION_CORE_MARKER_CENTER", _pos];
    _grp setBehaviour "SAFE";
    _grp setCombatMode "RED";
    _grp setSpeedMode "LIMITED";
    _grp setFormation "WEDGE";
    MISSION_CORE_ARTY set [_sideKey, [_grp, _veh, 0]];
    diag_log format ["AI ARTY: %1 spawned %2 (%3) at %4, static=%5", _sideKey, typeOf _veh, _vehClass, _pos, _isStatic];
    [_side, _grp, _veh] spawn MISSION_CORE_fnc_artilleryDriver;
};

// Per-piece controller: holds position 1000m+ from danger, fires 3-round bursts 1-3 minutes
// apart, and despawns once its shells are gone. When no tanks are spotted it can seldom shell a
// player-held marker center, then repositions because the shot gives its position away.
MISSION_CORE_fnc_artilleryDriver = {
    params ["_side", "_grp", "_veh"];
    private _sideKey = if (_side == WEST) then { "BLUFOR" } else { "REDFOR" };
    private _enemy = if (_side == WEST) then { EAST } else { WEST };
    private _lastMove = time - 10;
    private _lastFire = time;
    private _lastMarkerFire = 0;
    private _reposition = false;
    while { true } do {
        sleep 8;
        if (isNull _veh || { !(alive _veh) } || { { alive _x } count units _grp == 0 }) exitWith {
            if (!isNull _veh) then { deleteVehicle _veh; };
            if (!isNull _grp) then { { deleteVehicle _x; } forEach units _grp; deleteGroup _grp; };
            if (isNil "MISSION_CORE_ARTY") then { MISSION_CORE_ARTY = createHashMap; };
            MISSION_CORE_ARTY set [_sideKey, [grpNull, objNull, time + 600]];
            diag_log format ["AI ARTY: %1 piece destroyed, respawn in 10min", _sideKey];
        };
        private _pos = getPos _veh;

        // 0. Despawn when the shells run out (monitor respawns it after the cooldown)
        private _shellTotal = 0;
        {
            if ((_x select 0) find "Smoke" == -1) then { _shellTotal = _shellTotal + (_x select 1); };
        } forEach (magazinesAmmo _veh);
        if (_shellTotal <= 0) exitWith {
            if (!isNull _veh) then { deleteVehicle _veh; };
            if (!isNull _grp) then { { deleteVehicle _x; } forEach units _grp; deleteGroup _grp; };
            if (isNil "MISSION_CORE_ARTY") then { MISSION_CORE_ARTY = createHashMap; };
            MISSION_CORE_ARTY set [_sideKey, [grpNull, objNull, time + 600]];
            diag_log format ["AI ARTY: %1 out of ammo, despawning (respawn in 10min)", _sideKey];
        };

        // 1. MLRS/SPG keep 1000m+ from the nearest threat and re-locate if pressed. Mortars stay
        //    inside their contested marker - they never relocate away from it. For a BLUFOR SPG
        //    the threat anchor also covers the nearest enemy (assault) marker: during an assault
        //    the piece hangs back at standoff and never advances up to the objective.
        private _isStatic = _veh isKindOf "StaticMortar";
        private _danger = [_side, _pos] call MISSION_CORE_fnc_artilleryDanger;
        private _anchor = _danger;
        if (_side == WEST && { !_isStatic } && { !isNil "MISSION_CORE_CACHED_POSITIONS" }) then {
            private _nearestEnemyMkr = [0, 0, 0];
            private _bestD = 1e10;
            {
                if ((_x select 4) == EAST) then {
                    private _d = (_x select 1) distance2D _pos;
                    if (_d < _bestD) then { _bestD = _d; _nearestEnemyMkr = _x select 1; };
                };
            } forEach MISSION_CORE_CACHED_POSITIONS;
            // Retreat from the nearer threat so we always keep standoff from the assault objective.
            if (_nearestEnemyMkr distance [0, 0, 0] > 1 && { _nearestEnemyMkr distance2D _pos < _danger distance2D _pos }) then {
                _anchor = _nearestEnemyMkr;
            };
        };
        if (!_isStatic && { _anchor distance [0, 0, 0] > 1 } && { _veh distance2D _anchor < 1000 } && { time - _lastMove > 20 }) then {
            _lastMove = time;
            private _awayDir = ((_pos getDir _anchor) + 180) mod 360;
            private _away = [_anchor getPos [1300, _awayDir]] call MISSION_CORE_fnc_ensureLandPos;
            [_grp] call MISSION_CORE_fnc_clearGroupWaypoints;
            private _wp = _grp addWaypoint [_away, 30];
            _wp setWaypointType "MOVE";
            _wp setWaypointSpeed "FULL";
            _wp setWaypointBehaviour "CARELESS";
            _grp setCurrentWaypoint _wp;
            _grp setVariable ["MISSION_CORE_MARKER_CENTER", _away];
            diag_log format ["AI ARTY: %1 relocating to %2 (%3m from threat anchor)", _sideKey, _away, round (_away distance2D _anchor)];
            continue;
        };

        // 2. Fire a 3-round burst, then pause 1-3 minutes before the next. Mortars shell enemy
        //    infantry; a BLUFOR SPG shells enemy infantry (garrison + assault support) with armor
        //    as its fallback, and a REDFOR SPG keeps shelling enemy tanks/APCs.
        if (time - _lastFire > (60 + random 120)) then {
            private _isMortar = _veh isKindOf "StaticMortar";
            private _rangeCap = if (_isMortar) then { 1700 } else { 10000 };

            // SPG-only laser-guided fire: if a friendly unit is painting a laser dot within range
            // AND the piece carries a laser-guided round (weaponLockSystem flag 4), fire that round
            // at the exact dot (no scatter). This takes priority over radar/visual target picking.
            private _laserMags = [];
            if (!_isMortar) then { _laserMags = [_veh] call MISSION_CORE_fnc_artilleryLaserMags; };
            private _laserTarget = if (count _laserMags > 0) then {
                [_side, _veh, _rangeCap] call MISSION_CORE_fnc_artilleryLaserTarget;
            } else { [] };
            private _preferLaser = count _laserTarget > 0;

            private _isInfantryTarget = false;
            private _target = if (_preferLaser) then {
                _laserTarget
            } else {
                if (_isMortar) then {
                    [_veh, _enemy] call MISSION_CORE_fnc_artilleryInfantryTarget;
                } else {
                    // Self-propelled gun target selection. For BLUFOR the SPG must also engage enemy
                    // INFANTRY (it used to shell only armor) - this covers both garrison defense and
                    // assault support. Spotted infantry is preferred, armor is the fallback.
                    if (_side == WEST) then {
                        private _inf = [_veh, _enemy] call MISSION_CORE_fnc_artilleryInfantryTarget;
                        if (count _inf > 0) then {
                            _isInfantryTarget = true;
                            _inf
                        } else {
                            [_veh, _enemy] call MISSION_CORE_fnc_artilleryTarget;
                        };
                    } else {
                        [_veh, _enemy] call MISSION_CORE_fnc_artilleryTarget;
                    };
                };
            };
            private _markerFire = false;
            if (!_preferLaser && { count _target == 0 }) then {
                // No tanks spotted: seldom (25% chance, 5min cooldown) shell a player-held marker
                // center instead - it reveals the piece, so it repositions after firing
                if (time - _lastMarkerFire > 300 && { random 1 < 0.25 }) then {
                    private _m = [_side, _pos, _rangeCap] call MISSION_CORE_fnc_artilleryMarkerTarget;
                    if (count _m > 0) then {
                        _target = _m;
                        _markerFire = true;
                        _lastMarkerFire = time;
                    };
                };
            };
            if (count _target > 0) then {
                // weaponLockSystem round selection: laser round for a laser dot, standard round otherwise
                private _mag = [_veh, _preferLaser] call MISSION_CORE_fnc_pickArtilleryMag;
                if (count _mag > 0) then {
                    private _cmdr = leader _grp;
                    if (!isNull _cmdr && { alive _cmdr }) then {
                        private _tp = if (_preferLaser) then {
                            _target
                        } else {
                            [_veh, _target, _isInfantryTarget] call MISSION_CORE_fnc_scatterArtilleryPoint;
                        };
                        private _rounds = if (_preferLaser) then { 1 } else { 3 };
                        _cmdr doArtilleryFire [_tp, _mag select 0, _rounds];

                        // Audible fire at the barrel + at the target, then let the side know the
                        // battery is up. inRangeOfArtillery flags an out-of-range shot, and
                        // getArtilleryETA reports the impact time on the fire chat.
                        [_tp, 3, _rangeCap] call MISSION_CORE_fnc_artilleryPlaySound;
                        [_pos, 3, 1200] call MISSION_CORE_fnc_artilleryPlaySound;
                        private _inRange = _tp inRangeOfArtillery [[_veh], _mag select 0];
                        private _eta = -1;
                        try {
                            private _e = _cmdr getArtilleryETA [_tp, _mag select 0];
                            if (!isNil "_e") then { _eta = _e; };
                        } catch { };
                        private _etaStr = if (_eta > 0) then { format ["Impact in %1s.", round _eta] } else { "Impact imminent." };
                        if (!_inRange) then {
                            [_grp, format ["Baseplate, TARGET OUT OF RANGE - unable to engage at %1m.", round (_veh distance2D _tp)]] call MISSION_CORE_fnc_artillerySideChat;
                        } else {
                            [_grp, format ["Battery, rounds away - %1x %2. %3", _rounds, _mag select 0, _etaStr]] call MISSION_CORE_fnc_artillerySideChat;
                        };

                        _lastFire = time;
                        if (_markerFire) then { _reposition = true; };
                        diag_log format ["AI ARTY: %1 fired %2x %3 at %4 (%5m), inRange=%6, ETA=%7%8", _sideKey, _rounds, _mag select 0, _target, round (_veh distance2D _target), _inRange, _eta, if (_preferLaser) then { " LASER-GUIDED" } else { if (_markerFire) then { " marker - repositioning" } else { "" } }];

                        // Reload feedback a moment later: clank at the tube + a side chat once the
                        // battery is back up.
                        [_grp, _veh] spawn {
                            params ["_grp", "_veh"];
                            sleep 15;
                            if (!isNull _veh && { alive _veh }) then {
                                [getPos _veh, 2, 800] call MISSION_CORE_fnc_artilleryPlaySound;
                                [_grp, "Baseplate, reloaded and standing by."] call MISSION_CORE_fnc_artillerySideChat;
                            };
                        };
                    };
                };
            };
        };

        // 3. After a marker-center bombardment the position is compromised - shift to a fresh spot
        //    (MLRS/SPG only; mortars hold their position inside the contested marker).
        if (_reposition && { !_isStatic }) then {
            _reposition = false;
            if (time - _lastMove > 30) then {
                _lastMove = time;
                private _away = [_pos getPos [600 + random 300, random 360]] call MISSION_CORE_fnc_ensureLandPos;
                if (_away distance2D _danger > 1100) then {
                    [_grp] call MISSION_CORE_fnc_clearGroupWaypoints;
                    private _wp = _grp addWaypoint [_away, 30];
                    _wp setWaypointType "MOVE";
                    _wp setWaypointSpeed "FULL";
                    _wp setWaypointBehaviour "CARELESS";
                    _grp setCurrentWaypoint _wp;
                    _grp setVariable ["MISSION_CORE_MARKER_CENTER", _away];
                    diag_log format ["AI ARTY: %1 repositioning after marker fire to %2", _sideKey, _away];
                };
            };
        };
    };
};

// Ensure at most one live piece per side, spawning it once that side enters a battle
MISSION_CORE_fnc_artilleryMonitor = {
    diag_log "AI ARTY: artillery monitor started";
    while { true } do {
        sleep 20;
        if (isNil "MISSION_CORE_BLUFOR_DATA" || { isNil "MISSION_CORE_REDFOR_DATA" }) then { continue; };
        if (isNil "MISSION_CORE_ARTY") then { MISSION_CORE_ARTY = createHashMap; };
        {
            _x params ["_side", "_sideKey"];
            private _entry = MISSION_CORE_ARTY getOrDefault [_sideKey, []];
            private _hasLive = count _entry > 1 && { !(isNull (_entry select 1)) } && { alive (_entry select 1) };
            if (_hasLive) then { continue; };
            private _respawnAt = if (count _entry > 2) then { _entry select 2 } else { 0 };
            if (time < _respawnAt) then { continue; };
            if (count ([_side] call MISSION_CORE_fnc_getContestedMarkers) == 0) then { continue; };
            [_side] call MISSION_CORE_fnc_spawnArtillery;
        } forEach [[WEST, "BLUFOR"], [EAST, "REDFOR"]];
    };
};
