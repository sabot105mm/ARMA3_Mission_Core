
// Attack-stuck relocation (one tick of the group maintenance loop). Relocate attacking AI that
// have stalled at or near their own spawn point. A group committed to attack/counterattack/
// reinforce whose leader has barely moved from where it spawned (stuck in geometry, blocked by a
// building, or frozen) gets a fresh, safe spawn near its contested target and is re-committed
// there - instead of sitting uselessly forever. Handles every contested zone (one per player).
MISSION_CORE_fnc_attackStuckWatchdogTick = {
    if (isNil "MISSION_CORE_SPAWNED_GROUPS") exitWith {};
    {
        private _side = _x;
        private _sideVar = if (_side == WEST) then { "MISSION_CORE_BLUFOR" } else { "MISSION_CORE_REDFOR" };
        private _contested = [_side] call MISSION_CORE_fnc_getContestedMarkers;
        if (count _contested == 0) then { continue; };
        private _groups = MISSION_CORE_SPAWNED_GROUPS select {
            !isNull _x && { count units _x > 0 } && { _x getVariable [_sideVar, false] } &&
            { (_x getVariable ["MISSION_CORE_ORDER", ""]) in ["attack", "counterattack", "reinforce"] }
        };
        {
            private _grp = _x;
            private _ldr = leader _grp;
            if (isNull _ldr || { !(alive _ldr) }) then { continue; };
            private _at = _grp getVariable ["MISSION_CORE_ATTACK_TARGET", []];
            if (count _at == 0) then { continue; };
            // Match the group to the contested zone it is marching toward; skip if none matches.
            private _cEntry = _contested select { (_x select 1) distance2D _at <= 100 } param [0, []];
            if (count _cEntry == 0) then { continue; };
            private _cPos = _cEntry select 1;
            private _cSize = _cEntry select 2;
            // The group must have had time to move before we call it stuck
            private _born = _grp getVariable ["MISSION_CORE_SPAWN_TIME", -1];
            if (_born < 0 || { time - _born < 90 }) then { continue; };
            private _spawnPos = _grp getVariable ["MISSION_CORE_SPAWN_POS", getPos _ldr];
            // Stuck = leader still within 25m of its spawn point after the grace period. A
            // group that is driving (moving) is never touched even if far from spawn.
            if ((_ldr distance2D _spawnPos) > 25) then { continue; };
            // Don't yank a group that is legitimately fighting in place at the spawn
            if (_grp getVariable ["MISSION_CORE_IDLE", false]) then { continue; };
            private _last = _grp getVariable ["MISSION_CORE_STUCK_LAST", 0];
            if (time - _last < 120) then { continue; };
            _grp setVariable ["MISSION_CORE_STUCK_LAST", time];
            // Find a safe, flat spot near the contested marker for the relocation
            private _relocPos = [_cPos, _cSize, 30, random 360] call MISSION_CORE_fnc_findVehiclePos;
            if (_relocPos distance2D _spawnPos < 50) then { _relocPos = _cPos getPos [200 + random 200, random 360]; };
            _relocPos = [_relocPos] call MISSION_CORE_fnc_ensureLandPos;
            private _vehs = [];
            {
                private _v = vehicle _x;
                if (_v != _x && { !(_v in _vehs) }) then { _vehs pushBack _v; };
            } forEach units _grp;
            if (count _vehs > 0) then {
                // Vehicle group stuck: move each vehicle to the safe spot
                {
                    _x setPos _relocPos;
                    _x setDir (random 360);
                    _x setVectorUp surfaceNormal _relocPos;
                } forEach _vehs;
            } else {
                // Foot squad stuck: relocate the leader and teleport the squad to follow
                _ldr setPos _relocPos;
                {
                    if (_x != _ldr && { vehicle _x == _x }) then {
                        _x setPos (_relocPos getPos [2 + random 4, random 360]);
                    };
                } forEach units _grp;
            };
            // Re-commit so it presses the attack from the fresh spot
            diag_log format ["AI COMMANDER: %1 %2 stuck at spawn - relocated %.0fm to %3", _side, groupId _grp, round (_relocPos distance2D _cPos), _cEntry select 0];
            [_grp, _cPos, _cSize] call MISSION_CORE_fnc_sendCounterAttack;
        } forEach _groups;
    } forEach [WEST, EAST];
};
