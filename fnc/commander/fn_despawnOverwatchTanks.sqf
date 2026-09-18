
// Free armor slots when a marker attacks: despawn idle armor unless a player is close to the
// tank or the attack target; any group that stays joins the attack move
MISSION_CORE_fnc_despawnOverwatchTanks = {
    params ["_side", "_targetPos", ["_holdDist", 800]];
    if (isNil "MISSION_CORE_SPAWNED_GROUPS") exitWith {};
    private _sideVar = if (_side == WEST) then { "MISSION_CORE_BLUFOR" } else { "MISSION_CORE_REDFOR" };
    private _players = allPlayers select { alive _x };
    // PERMANENT RULE (BLUFOR GARRISONS): player-recruited garrison tanks are never despawned or
    // re-tasked to attack to free an armor cap - the player owns them and expects them to hold
    // their marker. Config "garrisonStaysHome" (default 1): set 0 to let AI pull them again.
    private _staysHome = ["garrisonStaysHome", 1] call MISSION_CORE_fnc_tune;
    {
        if (_x getVariable [_sideVar, false] && { !(_x getVariable ["MISSION_CORE_DEFENSE_GROUP", false]) } && { count units _x > 0 } &&
            { !(_staysHome > 0 && { _x getVariable ["MISSION_CORE_GARRISON", false] }) }) then {
            private _isArmor = _x getVariable ["MISSION_CORE_AA_TANK", false] || { (_x getVariable ["MISSION_CORE_ARMOR_SLOT", ""]) in ["mbt", "mech"] };
            if (_isArmor) then {
                private _order = _x getVariable ["MISSION_CORE_ORDER", ""];
                if (_order == "" || _order == "defend") then {
                    private _gPos = getPos leader _x;
                    private _holdTank = _players findIf { _x distance _gPos < _holdDist } > -1;
                    private _holdTarget = _players findIf { _x distance _targetPos < _holdDist } > -1;
                    if (!_holdTank && !_holdTarget) then {
                        diag_log format ["AI COMMANDER: despawning idle armor %1 at %2 to free cap", groupId _x, _gPos];
                        // Deletion delegated to deleteGroupCompletely - it also deletes the dedicated
                        // foot-transport DRIVER groups (MISSION_CORE_DRIVER_GROUP) for this tank's
                        // truck, which are NOT in SPAWNED_GROUPS. A manual units+vehs loop here
                        // would leave that driver standing next to the deleted truck.
                        [_x] call MISSION_CORE_fnc_deleteGroupCompletely;
                    } else {
                        // slipped through the check: join the attack move as well
                        if (_order != "attack") then {
                            _x setVariable ["MISSION_CORE_ORDER", "attack"];
                            _x setVariable ["MISSION_CORE_IDLE", false];
                            leader _x setVariable ["MISSION_CORE_PATROLLING", false];
                            [_x] call MISSION_CORE_fnc_clearGroupWaypoints;
                            private _wp = _x addWaypoint [_targetPos, 100];
                            _wp setWaypointType "SAD";
                            _wp setWaypointSpeed "FULL";
                            _wp setWaypointBehaviour "COMBAT";
                            _x setCurrentWaypoint _wp;
                            _x setCombatMode "RED";
                        };
                    };
                };
            };
        };
    } forEach +MISSION_CORE_SPAWNED_GROUPS;
};
