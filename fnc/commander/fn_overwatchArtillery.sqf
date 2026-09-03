
// Firing controller for overwatch garrison artillery: the SPG/MLRS pieces the initial spawn places
// on overwatch markers. Unlike the dedicated artilleryMonitor piece, these stay on their marker and
// shell spotted enemy armor on a cooldown. They do not reposition or respawn on their own.
MISSION_CORE_fnc_overwatchArtillery = {
    params ["_grp", "_veh", "_side"];
    private _enemy = if (_side == WEST) then { EAST } else { WEST };
    private _sideKey = if (_side == WEST) then { "BLUFOR" } else { "REDFOR" };
    private _lastFire = time;
    while { !isNull _veh && { alive _veh } && { { alive _x } count units _grp > 0 } } do {
        sleep 15 + random 15;
        if (time - _lastFire < 120) then { continue; };
        private _shells = (magazinesAmmo _veh) select { (_x select 1) > 0 && { (_x select 0) find "Smoke" == -1 } };
        if (count _shells == 0) then { continue; };
        private _target = [_veh, _enemy] call MISSION_CORE_fnc_artilleryTarget;
        if (count _target == 0) then { continue; };
        private _cmdr = leader _grp;
        if (!isNull _cmdr && { alive _cmdr }) then {
            private _mag = _shells select 0;
            private _tp = [_veh, _target] call MISSION_CORE_fnc_scatterArtilleryPoint;
            _cmdr doArtilleryFire [_tp, _mag select 0, 3];
            _lastFire = time;
            diag_log format ["AI ARTY OVERWATCH: %1 fired 3x %2 at %3 (%4m)", _sideKey, _mag select 0, _target, round (_veh distance2D _target)];
        };
    };
};
