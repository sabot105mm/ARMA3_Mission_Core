
MISSION_CORE_fnc_monitorCrew = {
    params ["_grp"];
    if (isNull _grp) exitWith {};
    private _center = _grp getVariable ["MISSION_CORE_MARKER_CENTER", getPos leader _grp];
    private _side = side leader _grp;
    private _factionData = if (_side == WEST) then { MISSION_CORE_BLUFOR_DATA } else { MISSION_CORE_REDFOR_DATA };
    private _crewClass = [_factionData, _side] call MISSION_CORE_fnc_factionRiflemen;
    private _tracked = [];
    {
        private _veh = vehicle _x;
        if (_veh isKindOf "StaticWeapon" && { _tracked findIf { (_x select 0) == _veh } == -1 }) then {
            // Record the ASL spot the gun was seated at (tower deck / bunker embrasure). Respawns
            // reuse it directly; the tower is static so the world position stays valid.
            _tracked pushBack [_veh, typeOf _veh, getPosASL _veh, getDir _veh];
        };
    } forEach units _grp;
    private _respawnQueue = [];
    while { !isNull _grp } do {
        sleep 6 + random 4;
        {
            _x params ["_wep", "_class", "_rpos", "_rdir"];
            if (isNull _wep || { !alive _wep }) then {
                if !(str _rpos in (_respawnQueue apply { str (_x select 2) })) then {
                    diag_log format ["DYNAMIC DEFENSE: scheduling %1 respawn in 5 min", _class];
                    _respawnQueue pushBack [_wep, _class, _rpos, _rdir, time + 300];
                };
            };
        } forEach _tracked;
        private _due = _respawnQueue select { (_x select 4) <= time };
        private _players = allPlayers select { alive _x };
        {
            private _entry = _x;
            _entry params ["_oldWreck", "_class", "_rpos", "_rdir", "_dueAt"];
            _respawnQueue deleteAt (_respawnQueue find _entry);
            // Never respawn a destroyed defense while a player is still in the area - wait for
            // the player to leave, then retry in 60s
            if (count _players > 0 && { (_players findIf { _x distance _rpos < 1500 }) != -1 }) then {
                _entry set [4, time + 60];
                _respawnQueue pushBack _entry;
                diag_log format ["DYNAMIC DEFENSE: %1 respawn held - player in area", _class];
                continue;
            };
            if (!isNull _oldWreck) then { deleteVehicle _oldWreck; };
            private _wep = _class createVehicle _rpos;
            _wep setPosASL _rpos;
            _grp addVehicle _wep;
            private _u = _grp createUnit [selectRandom _crewClass, _rpos, [], 0, "NONE"];
            _u moveInGunner _wep;
            [_wep, _rdir] call MISSION_CORE_fnc_faceWeapon;
            private _idx = _tracked findIf { (_x select 0) == _oldWreck };
            if (_idx >= 0) then { _tracked set [_idx, [_wep, _class, _rpos, _rdir]]; };
            diag_log format ["DYNAMIC DEFENSE: respawned %1 at %2", _class, _rpos];
        } forEach _due;
        // PERMANENT RULE: a surviving static weapon whose gunner is killed stays EMPTY - no
        // replacement soldier is spawned to run and re-man it. It only gets a new gunner when the
        // weapon itself is destroyed and goes through the 5-minute respawn path above.
    };
};
