
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
        // "Is ANY marker contested?" - answered ONLY by MISSION_CORE_CONTESTED (written solely by
        // fn_isMarkerContested). This gate needs no geometry at all, just whether the map is empty.
        private _contested = if (isNil "MISSION_CORE_CONTESTED") then { [] } else { keys MISSION_CORE_CONTESTED };
        if (count _contested == 0) then { continue; };
        private _groups = MISSION_CORE_SPAWNED_GROUPS select {
            !isNull _x && { count units _x > 0 } && { _x getVariable [_sideVar, false] } &&
            { (_x getVariable ["MISSION_CORE_ORDER", ""]) in ["attack", "counterattack", "reinforce", "staging"] }
        };
        {
            private _grp = _x;
            private _ldr = leader _grp;
            if (isNull _ldr || { !(alive _ldr) }) then { continue; };
            private _at = _grp getVariable ["MISSION_CORE_ATTACK_TARGET", []];
            if (count _at == 0) then { continue; };
            // Match the group to the contested zone it is marching toward. We need a NAME (a string) out
            // of this, because _cName is matched against cached rows by name further down. Going
            // through fn_getContestedMarkers gives [_name,_pos,_size,_owner] rows, so the position
            // is index 1 and the name is index 0. Contested NAMES still come solely from
            // MISSION_CORE_CONTESTED (the helper filters that map and joins geometry from
            // MISSION_CORE_CACHED_POSITIONS) - this forms no opinion about contested state.
            // NOTE: findIf returns an INDEX, not the element, so the name has to be pulled back out
            // of the row by that index. Assigning the raw findIf result to _cName made it a number,
            // and the `_cName == ""` test below then raised a type error that killed the file.
            private _cName = "";
            private _cRows = [sideUnknown] call MISSION_CORE_fnc_getContestedMarkers;
            private _cHit = _cRows findIf { ((_x select 1) distance2D _at) <= 100 };
            if (_cHit >= 0) then { _cName = (_cRows select _cHit) select 0; };
            if (_cName == "") then {
                // PERMANENT RULE (STALE-ORDER RELEASE): the group's one-way task has no live
                // contested target anymore (the marker it was marching on flipped / the fight it
                // was committed to ended). Such an order would otherwise block the group from ever
                // rejoining a new assault (the "assault groups refuse to assault a new marker"
                // bug) and from ever reverting to patrol (restartPatrol refuses attack/counterattack/
                // reinforce orders). One exception: a group still committed to the ACTIVE assault
                // target is on a live task - its target is a BLUFOR marker, not an EAST contested
                // zone, so it must be spared.
                private _release = true;
                if (!(isNil "MISSION_CORE_ASSAULT_ACTIVE") && { MISSION_CORE_ASSAULT_ACTIVE } &&
                    { !(isNil "MISSION_CORE_ASSAULT_TARGET") } && { MISSION_CORE_ASSAULT_TARGET != "" }) then {
                    private _aPos = _grp getVariable ["MISSION_CORE_ATTACK_TARGET", []];
                    if (count _aPos == 0) then { _aPos = _at; };
                    private _curAssaultPos = [];
                    if (!(isNil "MISSION_CORE_CACHED_POSITIONS")) then {
                        private _aIx = MISSION_CORE_CACHED_POSITIONS findIf { (_x select 0) == MISSION_CORE_ASSAULT_TARGET };
                        if (_aIx >= 0) then { _curAssaultPos = (MISSION_CORE_CACHED_POSITIONS select _aIx) select 1; };
                    };
                    if (count _curAssaultPos > 0 && { _aPos distance2D _curAssaultPos <= 300 }) then { _release = false; };
                };
                if (_release) then {
                    diag_log format ["AI COMMANDER: %1 stale %2 order released (no live contested/assault target) - back to patrol", groupId _grp, _grp getVariable ["MISSION_CORE_ORDER", ""]];
                    _grp setVariable ["MISSION_CORE_ORDER", ""];
                    _grp setVariable ["MISSION_CORE_ASSAULT_GROUP", false];
                    [_grp] call MISSION_CORE_fnc_restartPatrol;
                };
                continue;
            };
            private _cRow = MISSION_CORE_CACHED_POSITIONS select (MISSION_CORE_CACHED_POSITIONS findIf { (_x select 0) == _cName });
            private _cPos = _cRow select 1;
            // Size is index 8 of a cached row (index 2 is typeName).
            private _cSize = if (count _cRow > 8 && { ((_cRow select 8) isEqualType []) }) then { _cRow select 8 } else { [200, 200, 0] };
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
            diag_log format ["AI COMMANDER: %1 %2 stuck at spawn - relocated %.0fm to %3", _side, groupId _grp, round (_relocPos distance2D _cPos), _cName];
            [_grp, _cPos, _cSize] call MISSION_CORE_fnc_sendCounterAttack;
        } forEach _groups;
    } forEach [WEST, EAST];
};
