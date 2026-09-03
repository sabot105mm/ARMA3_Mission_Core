
// Despawn all AA overwatch tanks of a side whenever that side is attacking,
// unless a player is within 800m of the tank
MISSION_CORE_fnc_despawnAATanks = {
    params ["_side"];
    if (isNil "MISSION_CORE_SPAWNED_GROUPS") exitWith {};
    private _sideVar = if (_side == WEST) then { "MISSION_CORE_BLUFOR" } else { "MISSION_CORE_REDFOR" };
    private _players = allPlayers select { alive _x };
    private _removed = [];
    {
        if (_x getVariable [_sideVar, false] && { _x getVariable ["MISSION_CORE_AA_TANK", false] } && { count units _x > 0 }) then {
            private _gPos = getPos leader _x;
            private _hold = _players findIf { _x distance _gPos < 800 } > -1;
            if (!_hold) then {
                diag_log format ["AI COMMANDER: despawning AA tank %1 at %2 during attack", groupId _x, _gPos];
                _removed pushBack _x;
                private _vehs = [];
                { private _v = vehicle _x; if (_v != _x && { alive _v } && { !(_v in _vehs) }) then { _vehs pushBack _v; }; } forEach units _x;
                { deleteVehicle _x; } forEach units _x;
                { deleteVehicle _x; } forEach _vehs;
                deleteGroup _x;
            };
        };
    } forEach +MISSION_CORE_SPAWNED_GROUPS;
    if (count _removed > 0) then {
        MISSION_CORE_SPAWNED_GROUPS = MISSION_CORE_SPAWNED_GROUPS - _removed;
    };
};
