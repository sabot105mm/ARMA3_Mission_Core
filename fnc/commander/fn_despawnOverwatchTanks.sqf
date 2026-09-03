
// Free armor slots when a marker attacks: despawn idle armor unless a player is close to the
// tank or the attack target; any group that stays joins the attack move
MISSION_CORE_fnc_despawnOverwatchTanks = {
    params ["_side", "_targetPos", ["_holdDist", 800]];
    if (isNil "MISSION_CORE_SPAWNED_GROUPS") exitWith {};
    private _sideVar = if (_side == WEST) then { "MISSION_CORE_BLUFOR" } else { "MISSION_CORE_REDFOR" };
    private _players = allPlayers select { alive _x };
    private _removed = [];
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
                        _removed pushBack _x;
                        private _vehs = [];
                        { private _v = vehicle _x; if (_v != _x && { alive _v } && { !(_v in _vehs) }) then { _vehs pushBack _v; }; } forEach units _x;
                        { deleteVehicle _x; } forEach units _x;
                        { deleteVehicle _x; } forEach _vehs;
                        deleteGroup _x;
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
    if (count _removed > 0) then {
        MISSION_CORE_SPAWNED_GROUPS = MISSION_CORE_SPAWNED_GROUPS - _removed;
    };
};
