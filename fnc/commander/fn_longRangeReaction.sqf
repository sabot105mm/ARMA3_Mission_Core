
// Long-range reaction (one tick of the group maintenance loop): when a garrison unit at a marker
// actually knows about an enemy player who is firing into the marker from OUTSIDE its ellipse
// (a sniper / long-range attacker), the AI dispatches a mobile counter to the shooter's position:
//   - MAN attacker  -> a garrison foot squad (or a freshly spawned one if a spawn slot is open)
//                      rides a fresh armored gun truck to the shooter and SADs.
//   - TANK attacker -> an existing spawned MBT of the same side is sent to do the same.
// One reaction per marker per cooldown (no repeated dispatching while a marker is being shelled).
MISSION_CORE_fnc_longRangeReactionTick = {
    if (isNil "MISSION_CORE_SPAWNED_GROUPS") exitWith {};
    if (isNil "MISSION_CORE_CACHED_POSITIONS") exitWith {};
    if (isNil "MISSION_CORE_SPAWNED_LOCATIONS") exitWith {};
    private _players = allPlayers select { alive _x };
    if (count _players == 0) exitWith {};
    if (isNil "MISSION_CORE_LONG_RANGE_COOLDOWN") then { MISSION_CORE_LONG_RANGE_COOLDOWN = createHashMap; };
    {
        private _side = _x;
        private _sideVar = if (_side == WEST) then { "MISSION_CORE_BLUFOR" } else { "MISSION_CORE_REDFOR" };
        private _factionData = if (_side == WEST) then { MISSION_CORE_BLUFOR_DATA } else { MISSION_CORE_REDFOR_DATA };
        {
            private _loc = _x;
            if ((_loc select 4) != _side) then { continue; };
            private _locName = _loc select 0;
            private _locPos = _loc select 1;
            // PERMANENT RULE: outposts / powerplants / solar are static tiny garrisons - they
            // never dispatch a long-range counter to a shooter (sniper response, tank strike).
            if ([_loc] call MISSION_CORE_fnc_isLightInfrastructure) then { continue; };
            if (!(MISSION_CORE_SPAWNED_LOCATIONS getOrDefault [_locName, false])) then { continue; };
            private _lastReact = MISSION_CORE_LONG_RANGE_COOLDOWN getOrDefault [_locName, -99999];
            if (time - _lastReact < 120) then { continue; };
            // Marker ellipse for the "shooter is outside" test
            private _mSize = if (count _loc > 8) then { _loc select 8 } else { [200, 200, 0] };
            private _ma = _mSize select 0;
            private _mb = _mSize select 1;
            private _md = if (count _mSize > 2) then { _mSize select 2 } else { 0 };
            private _inside = {
                params ["_p"];
                private _dx = (_p select 0) - (_locPos select 0);
                private _dy = (_p select 1) - (_locPos select 1);
                private _rx = _dx * cos _md - _dy * sin _md;
                private _ry = _dx * sin _md + _dy * cos _md;
                (_rx*_rx)/(_ma*_ma) + (_ry*_ry)/(_mb*_mb) <= 1
            };
            // Garrison units that could see/know about the shooter
            private _garrison = [];
            {
                if (!isNull _x && { _x getVariable [_sideVar, false] } && { (_x getVariable ["MISSION_CORE_ORIGIN_MARKER", ""]) == _locName }) then {
                    { if (alive _x) then { _garrison pushBack _x; }; } forEach units _x;
                };
            } forEach MISSION_CORE_SPAWNED_GROUPS;
            if (count _garrison == 0) then { continue; };
            // First enemy player outside the ellipse that any garrison unit actually knows about
            private _shooter = objNull;
            {
                private _p = _x;
                if (side _p getFriend _side < 0.6 && { !([getPos _p] call _inside) }) then {
                    if (_garrison findIf { _x knowsAbout _p > 1.2 } != -1) exitWith { _shooter = _p; };
                };
            } forEach _players;
            if (isNull _shooter) then { continue; };
            private _shooterPos = getPos _shooter;
            private _shooterVeh = vehicle _shooter;
            private _inTank = _shooterVeh != _shooter && { _shooterVeh isKindOf "Tank" };
            private _reacted = false;
            if (_inTank) then {
                // Tank attacker: dispatch an existing (idle) MBT of this side to the shooter.
                private _tank = MISSION_CORE_SPAWNED_GROUPS select {
                    !isNull _x && { _x getVariable [_sideVar, false] } &&
                    { (_x getVariable ["MISSION_CORE_ARMOR_SLOT", ""]) == "mbt" } &&
                    { { alive _x } count units _x > 0 } &&
                    { (_x getVariable ["MISSION_CORE_ORDER", ""]) in ["", "defend", "engage"] }
                };
                if (count _tank > 0) then {
                    private _grpT = _tank select 0;
                    _grpT setVariable ["MISSION_CORE_LONG_RANGE_STRIKE", true];
                    [_grpT, _shooterPos, [50, 50]] call MISSION_CORE_fnc_sendCounterAttack;
                    _reacted = true;
                    diag_log format ["AI LONG RANGE: %1 dispatching tank %2 to shooter %3m out", _locName, groupId _grpT, round ((leader _grpT) distance2D _shooter)];
                };
            } else {
                // Man attacker: a garrison foot squad rides a fresh gun truck to the shooter and SADs.
                private _foot = MISSION_CORE_SPAWNED_GROUPS select {
                    !isNull _x && { _x getVariable [_sideVar, false] } &&
                    { (_x getVariable ["MISSION_CORE_ORIGIN_MARKER", ""]) == _locName } &&
                    { { alive _x } count units _x > 0 } &&
                    { { !(_x isKindOf "Man") } count units _x == 0 } &&
                    { (_x getVariable ["MISSION_CORE_ORDER", ""]) in ["", "defend", "engage"] } &&
                    // Never yank a squad that is staged for (or already holding) a quadrant order -
                    // the quadrant response owns those foot groups.
                    { !([_x] call MISSION_CORE_fnc_isQuadrantStaged) } &&
                    { !((_x getVariable ["MISSION_CORE_ORDER", ""]) == "engage" && { (_x getVariable ["MISSION_CORE_QUAD_MARKER", ""]) != "" }) }
                };
                private _grp = if (count _foot > 0) then { _foot select 0 } else { grpNull };
                if (isNull _grp) then {
                    // No free garrison squad - spawn one at the marker if a spawn slot is open
                    if ([_locName] call MISSION_CORE_fnc_spawnerSlotFree) then {
                        private _infPool = [(_factionData select 17)] call MISSION_CORE_fnc_getInfTemplates;
                        if (count _infPool > 0) then {
                            private _template = selectRandom _infPool;
                            _grp = [_template select 0, _locPos, _side, _factionData select 3, "AWARE", "NORMAL", _loc select 7, _locPos, _mSize] call MISSION_CORE_fnc_spawnGroup;
                            if (!isNull _grp) then {
                                _grp setVariable ["MISSION_CORE_ORIGIN_MARKER", _locName];
                                MISSION_CORE_SPAWNED_GROUPS pushBack _grp;
                            };
                        };
                    };
                };
                if (!isNull _grp) then {
                    // Marked so the "target no longer contested" cleanup never retreats a long-range
                    // strike: its attack target is the shooter's position, not a contested marker.
                    _grp setVariable ["MISSION_CORE_LONG_RANGE_STRIKE", true];
                    [_grp, _side, getPos leader _grp] call MISSION_CORE_fnc_mountInfantry;
                    [_grp, _shooterPos, [50, 50]] call MISSION_CORE_fnc_sendCounterAttack;
                    _reacted = true;
                    diag_log format ["AI LONG RANGE: %1 dispatching foot squad %2 in a gun truck to shooter %3m out", _locName, groupId _grp, round ((leader _grp) distance2D _shooter)];
                };
            };
            if (_reacted) then {
                MISSION_CORE_LONG_RANGE_COOLDOWN set [_locName, time];
            };
        } forEach MISSION_CORE_CACHED_POSITIONS;
    } forEach [WEST, EAST];
};
