
// PERF: marker ellipse shape (center, a, b, dir) resolved ONCE per marker name and cached, so the
// per-tick contest scans never re-derive geometry via findIf over CACHED_POSITIONS on every call.
if (isNil "MISSION_CORE_MARKER_SHAPE_CACHE") then { MISSION_CORE_MARKER_SHAPE_CACHE = createHashMap; };
MISSION_CORE_fnc_getMarkerShape = {
    params ["_markerName"];
    private _s = MISSION_CORE_MARKER_SHAPE_CACHE getOrDefault [_markerName, []];
    if (count _s == 4) exitWith { _s };
    private _r = [[0, 0, 0], 200, 200, 0];
    if (!isNil "MISSION_CORE_CACHED_POSITIONS") then {
        private _idx = MISSION_CORE_CACHED_POSITIONS findIf { (_x select 0) == _markerName };
        if (_idx >= 0) then {
            private _loc = MISSION_CORE_CACHED_POSITIONS select _idx;
            private _sz = _loc select 8;
            private _sa = if (count _sz > 0) then { _sz select 0 } else { 200 };
            private _sb = if (count _sz > 1) then { _sz select 1 } else { _sa };
            private _sd = if (count _sz > 2) then { _sz select 2 } else { 0 };
            _r = [_loc select 1, _sa max 1, _sb max 1, _sd];
        };
    };
    MISSION_CORE_MARKER_SHAPE_CACHE set [_markerName, _r];
    _r
};

// PERF: loop-order flip. Instead of scanning every ATTACK_GROUPS entry for EACH candidate marker
// (N*M string scans + ellipse math per contested call across all loops), this precomputes once per
// ~1s a map of marker -> [attacking sides with presence in it], iterating attack groups ONCE (M).
// isMarkerContested then does a single hashmap lookup + tiny friend check per marker (N).
if (isNil "MISSION_CORE_ASSAULT_CONTEST") then { MISSION_CORE_ASSAULT_CONTEST = createHashMap; };
if (isNil "MISSION_CORE_ASSAULT_CONTEST_AT") then { MISSION_CORE_ASSAULT_CONTEST_AT = -1e10; };

// Shared presence evaluation for ONE assault group pressing ITS assigned target marker (BLUFOR
// recruited groups AND REDFOR committed assault force share this same logic). Writes the group's
// side into _map when it is present (or when the marker is already sticky-contested and the group
// is still on it). Used by refreshAssaultContest once per second via both registration paths.
MISSION_CORE_fnc_assaultGroupEval = {
    params ["_ag", "_mName", "_side", "_map", ["_isMechMotor", false]];
    if (isNull _ag) exitWith {};
    private _present = false;
    if (!isNull (leader _ag) && { alive (leader _ag) }) then {
        private _shape = [_mName] call MISSION_CORE_fnc_getMarkerShape;
        private _pos = _shape select 0;
        private _sa = _shape select 1;
        private _sb = _shape select 2;
        private _sd = _shape select 3;
        // Standoff ring: an assault squad pressing its assigned target fights from JUST outside
        // the marker edge (foot squads halt at the outer ring to open fire, mech/motor column
        // hulls stop short of the ellipse too). The strict inside-ellipse test alone starves the
        // contest - the leader stands 50-200m off the edge for whole engagements and never
        // crosses in. So presence uses the ellipse inflated by the standoff ring (default 250m):
        // committed + arrived at the edge == contested. Once the marker is contested it STAYS
        // contested (sticky branch below) while the squad remains "active".
        private _ring = ["assaultStandoffRing", 250] call MISSION_CORE_fnc_tune;
        private _inMarker = {
            params ["_p"];
            private _dx = (_p select 0) - (_pos select 0);
            private _dy = (_p select 1) - (_pos select 1);
            private _rx = _dx * cos _sd - _dy * sin _sd;
            private _ry = _dx * sin _sd + _dy * cos _sd;
            (_rx*_rx)/((_sa+_ring)*(_sa+_ring)) + (_ry*_ry)/((_sb+_ring)*(_sb+_ring)) <= 1
        };
        // Mech/motorized: mounted men ARE the vehicle, so the transport itself counts as presence;
        // the real leader never drives the call by himself. The flag is precomputed by the caller
        // (BLUFOR from the template, REDFOR from simply being a mounted column) and cached.
        if (_isMechMotor) then {
            if (units _ag findIf { private _v = vehicle _x; alive _v && { [getPos _v] call _inMarker } } != -1) then { _present = true; };
        } else {
            if ([getPos (leader _ag)] call _inMarker) then { _present = true; };
        };
        // PERMANENT RULE: a leader pressing the marker from just OUTSIDE its edge still counts
        // as present when the garrison has detected him (knowsAbout). Foot squads legitimately
        // open fire from the standoff line / edge ring instead of walking into the ellipse, so
        // the old strict "leader inside" test starved assault-targets of their contested state
        // (and with it the counter-attack/defense flow) for whole engagements.
        if (!_present) then {
            private _enemies = _pos nearEntities ["Man", 1500] select { alive _x && { side _x getFriend _side < 0.6 } };
            if (_enemies findIf { _x knowsAbout (leader _ag) > (["assaultContestKnows", 0.7] call MISSION_CORE_fnc_tune) } != -1) then { _present = true; };
        };
    };
    if (_present) then {
        private _existing = _map getOrDefault [_mName, []];
        if (!(_side in _existing)) then { _map set [_mName, _existing + [_side]]; };
    } else {
        // STICKY ASSAULT-TARGET: once an assault squad has made this marker contested (hit it as
        // its assigned target), it STAYS contested while that squad is still on it - no need to
        // re-prove presence/knowsAbout every second. The squad committed, the garrison responded;
        // the fight must not flicker out mid-engagement just because the leader is momentarily out
        // of LOS or just outside the ellipse. The group leaving the assault drops it.
        if (_mName in MISSION_CORE_CONTESTED) then {
            private _existing = _map getOrDefault [_mName, []];
            if (!(_side in _existing)) then { _map set [_mName, _existing + [_side]]; };
        };
    };
};

MISSION_CORE_fnc_refreshAssaultContest = {
    if (time - MISSION_CORE_ASSAULT_CONTEST_AT < 1) exitWith {};
    MISSION_CORE_ASSAULT_CONTEST_AT = time;
    private _map = createHashMap;
    // BLUFOR recruited attack groups (player-deployed, status "active" = released and moving on
    // their assigned target marker). Each entry: [_grp, _targetName, _wps, _template, WEST, status, _targetPos].
    if (!isNil "MISSION_CORE_ATTACK_GROUPS" && { count MISSION_CORE_ATTACK_GROUPS > 0 }) then {
        {
            private _adata = _y;
            if (count _adata < 7) then { continue; };
            if ((_adata select 5) != "active") then { continue; };
            private _ag = _adata select 0;
            if (isNull _ag) then { continue; };
            private _mName = _adata select 1;
            if (_mName == "") then { continue; };
            private _side = _adata select 4;
            // Mech/motorized flag stamped once per group - never re-string-scan the template on
            // every contest pass.
            private _isMechMotor = _ag getVariable ["MISSION_CORE_MECH_MOTOR", nil];
            if (isNil "_isMechMotor") then {
                private _tmpl = _adata select 3;
                _isMechMotor = false;
                if (count _tmpl > 4) then {
                    private _subCat = _tmpl select 3;
                    private _catName = _tmpl select 4;
                    _isMechMotor = (_catName find "Motorized" > -1 || _subCat find "motor" > -1)
                        || (_catName find "Mechanized" > -1 || _subCat find "mech" > -1);
                };
                _ag setVariable ["MISSION_CORE_MECH_MOTOR", _isMechMotor];
            };
            [_ag, _mName, _side, _map, _isMechMotor] call MISSION_CORE_fnc_assaultGroupEval;
        } forEach MISSION_CORE_ATTACK_GROUPS;
    };
    // MULTIPLAYER RELAY: client-spawned assault groups reported to the server (fn_assaultRelay.sqf)
    // are evaluated for contest exactly like the local ones above. Entries share the same shape.
    if (!isNil "MISSION_CORE_ATTACK_GROUPS_RELAY") then {
        {
            private _adata = _y;
            if (count _adata < 7) then { continue; };
            if ((_adata select 5) != "active") then { continue; };
            private _ag = _adata select 0;
            if (isNull _ag) then { continue; };
            private _mName = _adata select 1;
            if (_mName == "") then { continue; };
            private _side = _adata select 4;
            private _isMechMotor = _ag getVariable ["MISSION_CORE_MECH_MOTOR", nil];
            if (isNil "_isMechMotor") then {
                private _tmpl = _adata select 3;
                _isMechMotor = false;
                if (count _tmpl > 4) then {
                    private _subCat = _tmpl select 3;
                    private _catName = _tmpl select 4;
                    _isMechMotor = (_catName find "Motorized" > -1 || _subCat find "motor" > -1)
                        || (_catName find "Mechanized" > -1 || _subCat find "mech" > -1);
                };
            };
            [_ag, _mName, _side, _map, _isMechMotor] call MISSION_CORE_fnc_assaultGroupEval;
        } forEach MISSION_CORE_ATTACK_GROUPS_RELAY;
    };
    // REDFOR committed assault force has NO contest registration - the operator's request is only
    // that BLUFOR recruited attack groups contest their assigned REDFOR target marker, and they
    // are handled above via MISSION_CORE_ATTACK_GROUPS. The REDFOR AI assault system is a separate
    // flow (fn_assaultStaging/fn_aiAssaultLoop) and intentionally does not participate here.
    MISSION_CORE_ASSAULT_CONTEST = _map;
};

// A marker is CONTESTED once a hostile player engages its garrison (knowsAbout), and STAYS
// contested without any further knowsAbout requirement until the player moves 1200m+ away OR
// steps inside a different marker (their fight moved elsewhere), or the marker gives up
// (retreats - cleared by the replenish loop). It is a sticky flag, not a per-tick live-enemy
// check, so reinforcements keep flowing even while the garrison is momentarily wiped.
MISSION_CORE_fnc_isMarkerContested = {
    params [["_locPos", [0, 0, 0]], ["_owner", WEST], ["_markerName", ""]];
    if (isNil "MISSION_CORE_CONTESTED") then { MISSION_CORE_CONTESTED = createHashMap; };
    // ASSAULT-TARGET CONTEST: a marker that is the ASSIGNED TARGET of an active released assault
    // squad is contested by that squad's presence alone - the squad pressing/engaging it. This
    // gives a player-less squad battle the full contested response (replenish priority,
    // reinforcement flow, defense). Pass-through markers a squad merely marches across are NOT
    // contested here - they only get spawned (see proximitySpawner) so there is something to fight
    // on the way. The per-group presence (and mech/motor riding-vehicle logic) is computed once per
    // second in MISSION_CORE_fnc_refreshAssaultContest - see the helper at the top of this file.
    if (_markerName != "" && { ((!isNil "MISSION_CORE_ATTACK_GROUPS") && { count MISSION_CORE_ATTACK_GROUPS > 0 }) || { (!isNil "MISSION_CORE_ATTACK_GROUPS_RELAY") && { count MISSION_CORE_ATTACK_GROUPS_RELAY > 0 } } }) then {
        call MISSION_CORE_fnc_refreshAssaultContest;
        private _sides = MISSION_CORE_ASSAULT_CONTEST getOrDefault [_markerName, []];
        private _asTarget = _sides findIf { _owner getFriend _x < 0.6 } != -1;
        if (_asTarget) exitWith { MISSION_CORE_CONTESTED set [_markerName, true]; true };
    };
    private _players = allPlayers select { alive _x };
    if (count _players == 0) exitWith { false };

    // Close-marker proximity split: a REDFOR marker with a close same-side neighbor is contested
    // PURELY by player proximity - within its activation radius (half the gap to the closest
    // neighbor). No engagement/knowsAbout required. The garrison stays spawned either way; this
    // only toggles the "contested" state so the fight hands off to the marker the player is near.
    // The verdict is stored in _closeResult ([] = "not a close marker, fall through to the sticky/
    // engaging logic below") and returned at top level - exitWith inside a then/else block is what
    // caused the "Missing ;" parse error, so the early return must sit at function scope.
    private _closeResult = [];
    if (_markerName != "" && { !isNil "MISSION_CORE_CACHED_POSITIONS" }) then {
        private _mIdx = MISSION_CORE_CACHED_POSITIONS findIf { (_x select 0) == _markerName };
        if (_mIdx >= 0) then {
            private _closeR = [(MISSION_CORE_CACHED_POSITIONS select _mIdx)] call MISSION_CORE_fnc_markerCloseRadii;
            if (count _closeR == 2) then {
                // Hysteresis band: become contested within half-gap - 50m; once contested, stay
                // contested until the player is beyond half-gap + 50m, then drop (and it can flip
                // back again when they re-enter). Prevents fluttering at the boundary.
                // A player physically INSIDE the marker ellipse always counts as armed too, even if
                // the gap to the neighbor is tiny (in which case half-gap - 50m could sit INSIDE the
                // marker and a man standing in it would otherwise never trigger contested).
                private _halfGap = _closeR select 0;
                private _hyst = ["closeMarkerHysteresis", 50] call MISSION_CORE_fnc_tune;
                private _shape = [_markerName] call MISSION_CORE_fnc_getMarkerShape;
                private _sa = _shape select 1;
                private _sb = _shape select 2;
                private _sd = _shape select 3;
                private _armed = _players findIf {
                    private _pp = getPos _x;
                    private _dx = (_pp select 0) - (_locPos select 0);
                    private _dy = (_pp select 1) - (_locPos select 1);
                    private _rx = _dx * cos _sd - _dy * sin _sd;
                    private _ry = _dx * sin _sd + _dy * cos _sd;
                    (_x distance _locPos <= (_halfGap - _hyst)) || ((_rx*_rx)/(_sa*_sa) + (_ry*_ry)/(_sb*_sb) <= 1)
                } != -1;
                private _inBand = _players findIf { _x distance _locPos <= (_halfGap + _hyst) } != -1;
                if (_armed) then {
                    MISSION_CORE_CONTESTED set [_markerName, true];
                    _closeResult = [true];
                } else {
                    if (_markerName in MISSION_CORE_CONTESTED) then {
                        if (!_inBand) then { MISSION_CORE_CONTESTED deleteAt _markerName; };
                    };
                    _closeResult = [false];
                };
            };
        };
    };
    if (count _closeResult == 1) exitWith { _closeResult select 0 };

    // Sticky: once the marker has detected an enemy it stays contested WHILE a player is still
    // fighting it - within 1200m of the marker AND not inside some other marker. No ongoing
    // knowsAbout check needed. Moving 1200m+ away, or entering a different marker, clears it.
    if (_markerName != "" && { _markerName in MISSION_CORE_CONTESTED }) then {
        if (isNil "MISSION_CORE_CACHED_POSITIONS") then { MISSION_CORE_CACHED_POSITIONS = []; };
        private _stillHere = _players findIf {
            private _p = _x;
            private _pos = getPos _p;
            private _near = (_p distance _locPos) <= 1200;
            _near && {
                private _inOther = false;
                {
                    if ((_x select 0) == _markerName) then { continue; };
                    private _oPos = _x select 1;
                    private _oSz = if (count _x > 8) then { _x select 8 } else { [200, 200, 0] };
                    private _oa = ((_oSz select 0) max 1);
                    private _ob = ((_oSz select 1) max 1);
                    private _od = if (count _oSz > 2) then { _oSz select 2 } else { 0 };
                    private _dx = (_pos select 0) - (_oPos select 0);
                    private _dy = (_pos select 1) - (_oPos select 1);
                    private _rx = _dx * cos _od - _dy * sin _od;
                    private _ry = _dx * sin _od + _dy * cos _od;
                    if ((_rx*_rx)/(_oa*_oa) + (_ry*_ry)/(_ob*_ob) <= 1) exitWith { _inOther = true; };
                } forEach MISSION_CORE_CACHED_POSITIONS;
                !_inOther
            }
        } != -1;
        if (_stillHere) exitWith { true };
        MISSION_CORE_CONTESTED deleteAt _markerName;
    };
    // Otherwise set it when a hostile player is inside + engaging the garrison.
    private _shape = if (_markerName != "") then { [_markerName] call MISSION_CORE_fnc_getMarkerShape } else { [[0, 0, 0], 200, 200, 0] };
    private _a = _shape select 1;
    private _b = _shape select 2;
    private _md = _shape select 3;
    private _inside = {
        params ["_p"];
        private _dx = (_p select 0) - (_locPos select 0);
        private _dy = (_p select 1) - (_locPos select 1);
        private _rx = _dx * cos _md - _dy * sin _md;
        private _ry = _dx * sin _md + _dy * cos _md;
        (_rx*_rx)/(_a*_a) + (_ry*_ry)/(_b*_b) <= 1
    };
    private _enemiesNear = _locPos nearEntities ["Man", 1500] select { side _x == _owner && { alive _x } };
    private _engaging = _players findIf {
        private _p = _x;
        side _p getFriend _owner < 0.6 &&
        { [getPos _p] call _inside } &&
        { _enemiesNear findIf { _p knowsAbout _x > 1.2 } != -1 }
    } != -1;
    if (_engaging) then {
        MISSION_CORE_CONTESTED set [_markerName, true];
        true
    } else {
        false
    };
};
