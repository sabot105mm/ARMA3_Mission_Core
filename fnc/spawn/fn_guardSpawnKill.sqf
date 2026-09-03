
// Watch a freshly spawned vehicle for a short settle window. If it dies within ~15s with no enemy
// nearby, it was a spawn-kill (spawned clipped into geometry / on a bad spot). Mark that spot
// unsafe so future spawns avoid it, then respawn the vehicle at a safe clearing via findVehiclePos
// and re-crew it so the force keeps its tank/APC. Called right after each armored vehicle spawn.
MISSION_CORE_fnc_guardSpawnKill = {
    params ["_veh", "_grp", "_side"];
    if (isNull _veh) exitWith {};
    [_veh, _grp, _side] spawn {
        params ["_veh", "_grp", "_side"];
        private _spawnPos = getPos _veh;
        private _deadline = time + 15;
        private _done = false;
        while { time < _deadline && !_done } do {
            sleep 3;
            if (isNull _veh) exitWith {};
            if (!alive _veh) then {
                _done = true;
                // Only treat as a spawn-kill if nothing hostile was near enough to shoot it
                private _enemyNear = { side _x != _side && { alive _x } && { _x distance _veh < 300 } } count allUnits;
                if (_enemyNear > 0) exitWith {};
                diag_log format ["MISSION CORE: %1 exploded on spawn at %2 - respawning in a safer clearing", typeOf _veh, _spawnPos];
                [_spawnPos, 60, 900] call MISSION_CORE_fnc_markUnsafeVehicleSpawn;
                // Armor that carries a REINF_TARGET already triggers requestArmorReinforcement on
                // death (a replacement drives in from a provider). Respawn only vehicles that have
                // no self-replacement so we never double the armor stack.
                private _hasReinf = count (_veh getVariable ["MISSION_CORE_REINF_TARGET", [0, 0, 0]]) > 0;
                if (_hasReinf) exitWith {
                    diag_log format ["MISSION CORE: %1 spawn-kill - armor reinforcement will replace it instead", typeOf _veh];
                };
                // Grab any surviving crew before the vehicle is deleted (unit dies with the wreck)
                private _survivors = (crew _veh) select { alive _x && { vehicle _x == _veh } };
                private _vehClass = typeOf _veh;
                deleteVehicle _veh;
                // Find a clear spot and rebuild the vehicle
                private _newPos = [_spawnPos, 0, 100, 10, 0, 0.5, 0] call BIS_fnc_findSafePos;
                if (count _newPos < 2) then { _newPos = [_spawnPos] call MISSION_CORE_fnc_ensureLandPos; };
                if (count _newPos == 2) then { _newPos pushBack 0; };
                private _newVeh = _vehClass createVehicle ([_newPos] call MISSION_CORE_fnc_liftSpawn);
                _grp addVehicle _newVeh;
                // Re-seat surviving crew, then top up with fresh crew
                private _crewClass = if (_side == WEST) then { "B_crew_F" } else { "O_crew_F" };
                private _seated = [];
                {
                    if (isNull (driver _newVeh) && isNull (gunner _newVeh) && isNull (commander _newVeh)) then {
                        _x moveInDriver _newVeh;
                        _seated pushBack _x;
                    } else {
                        if (isNull (gunner _newVeh)) then { _x moveInGunner _newVeh; } else { _x moveInCommander _newVeh; };
                        _seated pushBack _x;
                    };
                } forEach _survivors;
                for "_c" from (count _seated + 1) to 3 do {
                    private _u = _grp createUnit [_crewClass, _newPos, [], 0, "NONE"];
                    _seated pushBack _u;
                };
                _seated params [["_d", objNull], ["_g", objNull], ["_c", objNull]];
                if (!isNull _d && isNull (driver _newVeh)) then { _d moveInDriver _newVeh; };
                if (!isNull _g && isNull (gunner _newVeh)) then { _g moveInGunner _newVeh; };
                if (!isNull _c && isNull (commander _newVeh)) then { _c moveInCommander _newVeh; };
                // Re-apply the standard armor reinforcement Killed handler
                _newVeh setVariable ["MISSION_CORE_REINF_TARGET", _spawnPos];
                _newVeh addEventHandler ["Killed", {
                    params ["_v"];
                    private _s = _side;
                    private _t = _v getVariable ["MISSION_CORE_REINF_TARGET", [0, 0, 0]];
                    private _l = getPos _v call MISSION_CORE_fnc_getLocByPos;
                    private _n = if (count _l > 0) then { _l select 0 } else { "" };
                    [_s, _t, _n] call MISSION_CORE_fnc_requestArmorReinforcement;
                }];
                diag_log format ["MISSION CORE: %1 respawned at %2 after spawn-kill", _vehClass, _newPos];
            };
        };
    };
};
