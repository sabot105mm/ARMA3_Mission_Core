
// Despawn all AA overwatch tanks of a side whenever that side is attacking,
// unless a player is within 800m of the tank
MISSION_CORE_fnc_despawnAATanks = {
    params ["_side"];
    if (isNil "MISSION_CORE_SPAWNED_GROUPS") exitWith {};
    private _sideVar = if (_side == WEST) then { "MISSION_CORE_BLUFOR" } else { "MISSION_CORE_REDFOR" };
    private _players = allPlayers select { alive _x };
    {
        if (_x getVariable [_sideVar, false] && { _x getVariable ["MISSION_CORE_AA_TANK", false] } && { count units _x > 0 }) then {
            private _gPos = getPos leader _x;
            private _hold = _players findIf { _x distance _gPos < 800 } > -1;
                    if (!_hold) then {
                        diag_log format ["AI COMMANDER: despawning AA tank %1 at %2 during attack", groupId _x, _gPos];
                        // Deletion is delegated to deleteGroupCompletely - it also deletes the
                        // dedicated foot-transport DRIVER groups (MISSION_CORE_DRIVER_GROUP) assigned
                        // to this tank's truck, which are NOT in SPAWNED_GROUPS. A manual units+vehs
                        // loop here would leave that driver standing next to the deleted truck.
                        [_x] call MISSION_CORE_fnc_deleteGroupCompletely;
                    };
        };
    } forEach +MISSION_CORE_SPAWNED_GROUPS;
};
