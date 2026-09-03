
// A marker is CONTESTED once a hostile player engages its garrison (knowsAbout), and STAYS
// contested without any further knowsAbout requirement until the player moves 1200m+ away OR
// steps inside a different marker (their fight moved elsewhere), or the marker gives up
// (retreats - cleared by the replenish loop). It is a sticky flag, not a per-tick live-enemy
// check, so reinforcements keep flowing even while the garrison is momentarily wiped.
MISSION_CORE_fnc_isMarkerContested = {
    params [["_locPos", [0, 0, 0]], ["_owner", WEST], ["_markerName", ""]];
    if (isNil "MISSION_CORE_CONTESTED") then { MISSION_CORE_CONTESTED = createHashMap; };
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
                private _sz = (MISSION_CORE_CACHED_POSITIONS select _mIdx) select 8;
                private _sa = if (count _sz > 0) then { (_sz select 0) max 1 } else { 200 };
                private _sb = if (count _sz > 1) then { (_sz select 1) max 1 } else { _sa };
                private _sd = if (count _sz > 2) then { _sz select 2 } else { 0 };
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
                    if (!(_markerName in MISSION_CORE_CONTESTED)) then {
                        // Just became contested - redirect any retreating same-side squads to it.
                        [_markerName, _locPos, _owner] call MISSION_CORE_fnc_rerouteRetreating;
                    };
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
    private _a = 200;
    private _b = 200;
    private _md = 0;
    if (_markerName != "" && { !isNil "MISSION_CORE_CACHED_POSITIONS" }) then {
        private _idx = MISSION_CORE_CACHED_POSITIONS findIf { (_x select 0) == _markerName };
        if (_idx >= 0) then {
            private _sz = (MISSION_CORE_CACHED_POSITIONS select _idx) select 8;
            if (count _sz > 0) then { _a = _sz select 0; };
            if (count _sz > 1) then { _b = _sz select 1; };
            if (count _sz > 2) then { _md = _sz select 2; };
        };
    };
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
        // Event-driven re-route: a marker just became contested - immediately redirect any
        // retreating same-side squads to counter-attack it (no polling loop needed).
        if (_markerName != "") then { [_markerName, _locPos, _owner] call MISSION_CORE_fnc_rerouteRetreating; };
        true
    } else {
        false
    };
};
