// Defense reaction - the SINGLE loop that puts my-side garrison groups (foot AI, tanks, APCs, gun
// trucks) onto SAD + fire at will (COMBAT/RED) when a hostile is IN or CLOSE TO their marker area.
//
// It is the consolidated replacement for the older per-path reactions that each covered only part
// of the garrison (armor-commander handled tanls/APCs, ai-commander handled foot when a player had
// spotted the enemy). Here one loop scans every BLUFOR/REDFOR garrison group and reacts purely on
// spatial proximity to the group's own marker, regardless of a player's knowsAbout or the group's
// LOS, so the garrison defends its ground the instant an enemy threatens it.
//
// Only idle/patrol/defend groups react - one-way attackers, AA overwatch and emplacement crews are
// untouched.
MISSION_CORE_fnc_defenseSpotLoop = {
    diag_log "AI COMMANDER: defense spot loop started";
    private _prox = ["standToProx", 600] call MISSION_CORE_fnc_tune;
    if (isNil "MISSION_CORE_SPOT_COOLDOWN") then { MISSION_CORE_SPOT_COOLDOWN = createHashMap; };
    while { true } do {
        sleep 6 + random 4;
        if (isNil "MISSION_CORE_SPAWNED_GROUPS") then { continue; };
        // Nothing spawned at all - nothing to react to. Keep looping (a garrison may spawn later,
        // e.g. a recruit or a marker garrison popping in near a player); just skip the per-group pass.
        if (count MISSION_CORE_SPAWNED_GROUPS == 0) then { continue; };
        {
            private _grp = _x;
            if (isNull _grp || { count units _grp == 0 }) then { continue; };
            if (!(_grp getVariable ["MISSION_CORE_REDFOR", false] || _grp getVariable ["MISSION_CORE_BLUFOR", false])) then { continue; };
            // Only idle/patrol/defend groups - never one-way attackers, AA overwatch, or emplacement crews
            private _order = _grp getVariable ["MISSION_CORE_ORDER", ""];
            if (!(_order in ["", "defend", "engage"])) then { continue; };
            if (_grp getVariable ["MISSION_CORE_AA_DEFENSE", false]) then { continue; };
            if (_grp getVariable ["MISSION_CORE_AA_TANK", false]) then { continue; };
            private _ldr = leader _grp;
            if (isNull _ldr || { !(alive _ldr) }) then { continue; };
            // A leader manning a static weapon / AT guard can't move - leave it
            if (vehicle _ldr isKindOf "StaticWeapon") then { continue; };
            if (_ldr getVariable ["MISSION_CORE_STATIC_GUARD", false]) then { continue; };

            private _home = _grp getVariable ["MISSION_CORE_MARKER_CENTER", getPos _ldr];
            // Resolve the origin marker's area (size/dir/shape) so the threat test is shape-aware:
            // "enemy in the marker OR within standToProx metres of the marker edge".
            private _mag = _grp getVariable ["MISSION_CORE_MARKER_SIZE", [200, 200]];
            if (_mag isEqualType []) then { _mag = [200, 200]; };
            private _ma = if (count _mag > 0) then { _mag select 0 } else { 200 };
            private _mb = if (count _mag > 1) then { _mag select 1 } else { _ma };
            private _mDir = 0;
            private _mShape = "ELLIPSE";
            private _oMkr = _grp getVariable ["MISSION_CORE_ORIGIN_MARKER", ""];
            if (_oMkr != "" && { !(isNil "MISSION_CORE_CACHED_POSITIONS") }) then {
                private _ploc = MISSION_CORE_CACHED_POSITIONS findIf { (_x select 0) == _oMkr };
                if (_ploc >= 0) then {
                    private _area = (MISSION_CORE_CACHED_POSITIONS select _ploc) select 1;
                    if (_area isEqualType [] && { count _area > 1 }) then {
                        private _sz = _area select 1;
                        if (_sz isEqualType []) then {
                            if (count _sz > 0) then { _ma = (_sz select 0) max 50; };
                            if (count _sz > 1) then { _mb = (_sz select 1) max 50; };
                        };
                        if (count _area > 2) then { _mDir = _area select 2; };
                        if (count _area > 3) then { _mShape = toUpper (_area select 3); };
                    };
                };
            };

            // Spatial threat: a hostile is inside the marker area or within _prox of its edge.
            private _ldrSide = side _ldr;
            private _threat = false;
            {
                if (alive _x && { (getPosATL _x) inArea [_home, _ma + _prox, _mb + _prox] } && { side _x getFriend _ldrSide < 0.6 }) exitWith { _threat = true };
            } forEach allUnits;

            // This loop only manages groups it itself put on "defend" (ATTACK_TARGET at home). If the
            // threat has cleared, release them back to patrol instead of leaving them on SAD forever.
            private _att = _grp getVariable ["MISSION_CORE_ATTACK_TARGET", [0, 0, 0]];
            if (_order == "defend" && { (_att distance _home) < 100 }) then {
                if (!_threat) then {
                    _grp setVariable ["MISSION_CORE_ORDER", ""];
                    _grp setVariable ["MISSION_CORE_ATTACK_TARGET", [0, 0, 0]];
                    [_grp] call MISSION_CORE_fnc_restartPatrol;
                    diag_log format ["AI DEFENSE: %1 no longer threatened - back to patrol", groupId _grp];
                };
                continue;
            };

            // Already reacting / in cooldown - don't re-yank every tick.
            if (time < (MISSION_CORE_SPOT_COOLDOWN getOrDefault [(groupId _grp), -99999])) then { continue; };
            if (!_threat) then { continue; };

            // Stop patrol, defend the friendly marker
            _grp setVariable ["MISSION_CORE_ORDER", "defend"];
            _grp setVariable ["MISSION_CORE_IDLE", false];
            _grp setVariable ["MISSION_CORE_PATROLLING", false];
            _grp setVariable ["MISSION_CORE_ATTACK_TARGET", _home];
            _ldr setVariable ["MISSION_CORE_PATROLLING", false];
            _grp setBehaviour "AWARE";
            _grp setCombatMode "RED";
            [_grp] call MISSION_CORE_fnc_clearGroupWaypoints;
            // MOVE first (pre-1.22 rule), then SAD so it seeks and engages enemies around the marker.
            private _wpM = _grp addWaypoint [_home, 80];
            _wpM setWaypointType "MOVE";
            _wpM setWaypointSpeed "FULL";
            _wpM setWaypointBehaviour "COMBAT";
            private _wp = _grp addWaypoint [_home, 80];
            _wp setWaypointType "SAD";
            _wp setWaypointSpeed "FULL";
            _wp setWaypointBehaviour "COMBAT";
            _grp setCurrentWaypoint _wpM;
            MISSION_CORE_SPOT_COOLDOWN set [(groupId _grp), time + 30];
            diag_log format ["AI DEFENSE: %1 spotted enemy - defending friendly marker", groupId _grp];
        } forEach MISSION_CORE_SPAWNED_GROUPS;
    };
};