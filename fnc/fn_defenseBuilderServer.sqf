
// ============================================================
// DEFENSE BUILDER (server) - validates placements, spends defense
// points, and spawns the placed item. Only runs on the server.
// ============================================================

// Ensure a player has a points entry and broadcast the table.
MISSION_CORE_fnc_builderSyncPoints = {
    params ["_p"];
    if (!isServer) exitWith {};
    if (isNil "MISSION_CORE_DEFENSE_POINTS") then { MISSION_CORE_DEFENSE_POINTS = createHashMap; };
    private _uid = getPlayerUID _p;
    MISSION_CORE_DEFENSE_POINTS set [_uid, MISSION_CORE_DEFENSE_POINTS_DEFAULT];
    publicVariable "MISSION_CORE_DEFENSE_POINTS";
};

// Spawn a single placed defense and return [_grp, _objs]. Everything placed is a STATIC defense:
// it never moves - the AI loops ignore it (MISSION_CORE_STATIC_DEFENSE) and its crew has move AI
// disabled.
MISSION_CORE_fnc_builderSpawnDefense = {
    params ["_type", "_class", "_pos", "_dir"];
    private _grp = grpNull;
    private _objs = [];
    switch (_type) do {
        case "bunker": {
            _objs = [_class, _pos, _dir, WEST] call MISSION_CORE_fnc_placeComposition;
            _grp = createGroup WEST;
            {
                if (_x isKindOf "StaticWeapon") then {
                    _grp addVehicle _x;
                    private _gunner = _grp createUnit [selectRandom (MISSION_CORE_BLUFOR_DATA select 19), getPos _x, [], 0, "NONE"];
                    _gunner moveInGunner _x;
                    [_x, _dir] call MISSION_CORE_fnc_faceWeapon;
                };
            } forEach _objs;
        };
        case "tank": {
            _grp = createGroup WEST;
            private _veh = createVehicle [_class, [_pos] call MISSION_CORE_fnc_liftSpawn, [], 0, "CAN_COLLIDE"];
            _veh setDir _dir;
            _grp addVehicle _veh;
            private _crew = [];
            for "_c" from 1 to 3 do { _crew pushBack (_grp createUnit ["B_crew_F", _pos, [], 0, "NONE"]); };
            _crew params [["_d", objNull], ["_g", objNull], ["_c2", objNull]];
            if (!isNull _d && { isNull (driver _veh) }) then { _d moveInDriver _veh; };
            if (!isNull _g && { isNull (gunner _veh) }) then { _g moveInGunner _veh; };
            if (!isNull _c2 && { isNull (commander _veh) }) then { _c2 moveInCommander _veh; };
        };
        case "emplace": {
            _grp = createGroup WEST;
            private _wep = createVehicle [_class, [_pos] call MISSION_CORE_fnc_liftSpawn, [], 0, "CAN_COLLIDE"];
            _wep setDir _dir;
            _grp addVehicle _wep;
            private _gunner = _grp createUnit [selectRandom (MISSION_CORE_BLUFOR_DATA select 19), getPos _wep, [], 0, "NONE"];
            _gunner moveInGunner _wep;
            [_wep, _dir] call MISSION_CORE_fnc_faceWeapon;
        };
        case "barrier";
        case "sandbag": {
            private _obj = createVehicle [_class, [_pos] call MISSION_CORE_fnc_liftSpawn, [], 0, "CAN_COLLIDE"];
            _obj setDir _dir;
            _obj setPos _pos;
            _objs = [_obj];
        };
    };
    if (!isNull _grp) then {
        _grp setBehaviour "SAFE";
        _grp setCombatMode "RED";
        _grp setVariable ["MISSION_CORE_BLUFOR", true];
        _grp setVariable ["MISSION_CORE_DEFENSE_GROUP", true];
        _grp setVariable ["MISSION_CORE_STATIC_DEFENSE", true];
        _grp setVariable ["MISSION_CORE_MARKER_CENTER", _pos];
        _grp setVariable ["MISSION_CORE_ORDER", "defend"];
        { _x disableAI "MOVE"; } forEach units _grp;
    };
    [_grp, _objs]
};

// Player spawns a defense. Validates: alive BLUFOR, enough points, inside an owned BLUFOR marker.
MISSION_CORE_fnc_builderServerPlace = {
    params ["_p", "_type", "_class", "_pos", "_dir", "_cost"];
    if (!isServer) exitWith {};
    if (isNull _p || { !alive _p } || { side _p != WEST }) exitWith {};
    if (isNil "MISSION_CORE_DEFENSE_POINTS") then { MISSION_CORE_DEFENSE_POINTS = createHashMap; };
    private _uid = getPlayerUID _p;
    private _pts = MISSION_CORE_DEFENSE_POINTS getOrDefault [_uid, MISSION_CORE_DEFENSE_POINTS_DEFAULT];
    if (_pts < _cost) exitWith {
        [format ["Not enough points (need %1, have %2)", _cost, _pts]] remoteExec ["hint", _p];
    };

    // Must be inside a marker currently owned by BLUFOR
    private _inside = false;
    {
        if ((_x select 4) == WEST) then {
            private _mPos = _x select 1;
            private _sz = _x select 8;
            private _a = _sz select 0;
            private _b = if (count _sz > 1) then { _sz select 1 } else { _a };
            private _md = if (count _sz > 2) then { _sz select 2 } else { 0 };
            private _dx = (_pos select 0) - (_mPos select 0);
            private _dy = (_pos select 1) - (_mPos select 1);
            private _rx = _dx * cos _md - _dy * sin _md;
            private _ry = _dx * sin _md + _dy * cos _md;
            if ((_rx*_rx)/(_a*_a) + (_ry*_ry)/(_b*_b) <= 1) exitWith { _inside = true; };
        };
    } forEach MISSION_CORE_CACHED_POSITIONS;
    if (!_inside) exitWith {
        ["You can only build inside a marker owned by BLUFOR!"] remoteExec ["hint", _p];
    };

    _pos set [2, 0];
    private _res = [_type, _class, _pos, _dir] call MISSION_CORE_fnc_builderSpawnDefense;
    _res params ["_grp", "_objs"];
    if (isNil "MISSION_CORE_PLAYER_DEFENSES") then { MISSION_CORE_PLAYER_DEFENSES = []; };
    MISSION_CORE_PLAYER_DEFENSES pushBack [_type, _class, _pos, _dir, _grp, _objs, "active"];

    MISSION_CORE_DEFENSE_POINTS set [_uid, _pts - _cost];
    publicVariable "MISSION_CORE_DEFENSE_POINTS";
    [format ["Placed %1 (-%2 pts)", _class, _cost]] remoteExec ["hint", _p];
};

// Manage placed defenses: despawn when the nearest player moves away, respawn when destroyed
// (after a short delay) while a player is still nearby.
MISSION_CORE_fnc_playerDefenseLoop = {
    diag_log "DEFENSE BUILDER: player defense loop started";
    while { true } do {
        sleep 15;
        if (isNil "MISSION_CORE_PLAYER_DEFENSES") then { MISSION_CORE_PLAYER_DEFENSES = []; };
        if (count MISSION_CORE_PLAYER_DEFENSES == 0) then { continue; };
        private _players = allPlayers select { alive _x && { side _x == WEST } };
        if (count _players == 0) then { continue; };
        // Fully delete a defense group (crew + their vehicles) and any placed objects.
        private _cleanup = {
            params ["_grp", "_objs"];
            if (!isNull _grp) then {
                private _vehs = [];
                { private _v = vehicle _x; if (_v != _x && { !isNull _v } && { !(_v in _vehs) }) then { _vehs pushBack _v; }; } forEach units _grp;
                { deleteVehicle _x; } forEach units _grp;
                { deleteVehicle _x; } forEach _vehs;
                deleteGroup _grp;
            };
            { deleteVehicle _x; } forEach _objs;
        };
        private _keep = [];
        {
            _x params ["_type", "_class", "_pos", "_dir", "_grp", "_objs", ["_state", "active"]];
            private _nearD = 99999;
            { private _d = _x distance _pos; if (_d < _nearD) then { _nearD = _d; }; } forEach _players;
            if (_nearD > 2500) then {
                // Player moved away: despawn whatever is left, but KEEP the record so the defense
                // respawns when the player comes back.
                if (_state != "despawned") then {
                    [_grp, _objs] call _cleanup;
                    _x set [4, grpNull];
                    _x set [5, []];
                    _x set [6, "despawned"];
                    diag_log format ["DEFENSE BUILDER: despawned %1 (player moved away)", _class];
                };
            } else {
                if (_state == "despawned") then {
                    // Player came back: respawn fresh.
                    private _res = [_type, _class, _pos, _dir] call MISSION_CORE_fnc_builderSpawnDefense;
                    _x set [4, _res select 0];
                    _x set [5, _res select 1];
                    _x set [6, "active"];
                    diag_log format ["DEFENSE BUILDER: respawned %1 (player returned)", _class];
                } else {
                    if (_state == "active") then {
                        // Destroyed? Clean up the wreck, but do NOT respawn - it only comes back
                        // once the player leaves and returns.
                        private _destroyed = false;
                        if (!isNull _grp) then {
                            _destroyed = { alive _x } count units _grp == 0;
                        } else {
                            _destroyed = ({ alive _x } count _objs) == 0;
                        };
                        if (_destroyed) then {
                            [_grp, _objs] call _cleanup;
                            _x set [4, grpNull];
                            _x set [5, []];
                            _x set [6, "destroyed"];
                            diag_log format ["DEFENSE BUILDER: %1 destroyed - respawns when player returns", _class];
                        } else {
                            // Mortars are indirect-fire and never auto-engage on their own, so a
                            // player-built mortar is ordered to shell a RANDOM REDFOR unit,
                            // preferring infantry.
                            if (_type == "emplace" && { _class isKindOf "StaticMortar" } && { !isNull _grp }) then {
                                private _mortar = objNull;
                                {
                                    private _v = vehicle _x;
                                    if (_v != _x && { _v isKindOf "StaticMortar" }) exitWith { _mortar = _v; };
                                } forEach units _grp;
                                if (!isNull _mortar && { alive _mortar }) then {
                                    // Unified artillery targeting: mortars shell enemy infantry
                                    // (same fn as the AI mortars), SPGs handle armor separately.
                                    private _target = [_mortar, EAST] call MISSION_CORE_fnc_artilleryInfantryTarget;
                                    if (count _target > 0) then {
                                        private _lastFire = _grp getVariable ["MISSION_CORE_MORTAR_LAST_FIRE", -99999];
                                        if (time - _lastFire > 45) then {
                                            private _shells = (magazinesAmmo _mortar) select { (_x select 1) > 0 && { (_x select 0) find "Smoke" == -1 } };
                                            if (count _shells > 0) then {
                                                private _mag = _shells select 0;
                                                private _cmdr = leader _grp;
                                                if (!isNull _cmdr && { alive _cmdr }) then {
                                                    _grp setVariable ["MISSION_CORE_MORTAR_LAST_FIRE", time];
                                                    _cmdr doArtilleryFire [_target, _mag select 0, 1];
                                                    diag_log format ["DEFENSE BUILDER: mortar %1 firing at infantry %2 (%3m)", _class, _target, round (_pos distance2D _target)];
                                                };
                                            };
                                        };
                                    };
                                };
                            };
                        };
                    };
                };
            };
            _keep pushBack _x;
        } forEach MISSION_CORE_PLAYER_DEFENSES;
        MISSION_CORE_PLAYER_DEFENSES = _keep;
    };
};
