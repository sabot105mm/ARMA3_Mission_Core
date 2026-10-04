// PERMANENT RULE: exactly ONE AI contested zone per side. The AI concentrates all its
// reinforcement / counter-attack effort on a single marker - the zone. The zone is simply the
// enemy marker the nearest player is CLOSEST to (not "some other" marker). When markers overlap
// (their center points within 700m), the HIGHEST importance (then largest radius) marker wins,
// so a small nearby location never steals focus from a bigger objective.
// Returns the focus marker name or "" (no zone locked).
MISSION_CORE_fnc_getAIZoneFocus = {
    params ["_side"];
    if (isNil "MISSION_CORE_ZONE_FOCUS") then { MISSION_CORE_ZONE_FOCUS = ""; };
    if (isNil "MISSION_CORE_ZONE_FOCUS_TIME") then { MISSION_CORE_ZONE_FOCUS_TIME = 0; };
    private _playersA = allPlayers select { alive _x };
    if (count _playersA == 0) exitWith { MISSION_CORE_ZONE_FOCUS };

    // Candidates: markers owned by this side, plus markers CURRENTLY under occupation against it.
    //
    // This used to add un-expired MISSION_CORE_CAPTURED_RETAKE entries as candidates. The retake
    // table is gone (see fn_captureMarkerForPlayers), but it was only ever needed here because a
    // captured marker's ownership had already flipped to the player side - so "owned by this side"
    // could never match it. MISSION_CORE_OCCUPATION answers the same question and is still written
    // on capture: [_markerName, [occupierSide, previousOwner, occupiedAtTime]]. A marker being
    // occupied AGAINST _side is the live version of "lost but being fought over", and it expires on
    // its own when fn_occupationMonitor finalizes or reverts the hold, so there is no window to
    // invent here.
    private _heldAgainst = [];
    if (!isNil "MISSION_CORE_OCCUPATION") then {
        _heldAgainst = keys MISSION_CORE_OCCUPATION select {
            private _occ = MISSION_CORE_OCCUPATION get _x;
            (count _occ > 2) && { (_occ select 1) == _side }
        };
    };

    // Pass 1: the candidate marker whose center is closest to the nearest player.
    private _closest = "";
    private _closestD = 1e10;
    private _closestPos = [0, 0, 0];
    private _closestRad = 0;
    private _closestImp = 0;
    {
        private _owned = (_x select 4) == _side;
        private _isHeldAgainstUs = (_x select 0) in _heldAgainst;
        if (_owned || _isHeldAgainstUs) then {
            private _mPos = _x select 1;
            private _pd = 1e10;
            { private _d = _x distance _mPos; if (_d < _pd) then { _pd = _d; }; } forEach _playersA;
            if (_pd < _closestD) then {
                _closestD = _pd;
                _closest = _x select 0;
                _closestPos = _mPos;
                private _size = if (count _x > 8) then { _x select 8 } else { [200, 200, 0] };
                _closestRad = (_size select 0) max (_size select 1);
                _closestImp = _x select 7;
            };
        };
    } forEach MISSION_CORE_CACHED_POSITIONS;

    // Pass 2: if another candidate's center point is within 700m of the closest marker's center,
    // the highest importance (then largest radius) marker wins.
    private _focus = _closest;
    private _focusImp = _closestImp;
    private _focusRad = _closestRad;
    {
        private _owned = (_x select 4) == _side;
        private _isHeldAgainstUs = (_x select 0) in _heldAgainst;
        if ((_owned || _isHeldAgainstUs) && { (_x select 0) != _closest }) then {
            private _mPos = _x select 1;
            private _size = if (count _x > 8) then { _x select 8 } else { [200, 200, 0] };
            private _rad = (_size select 0) max (_size select 1);
            private _imp = _x select 7;
            if (_closestPos distance _mPos < 700) then {
                if (_imp > _focusImp || { _imp == _focusImp && { _rad > _focusRad } }) then {
                    _focus = _x select 0;
                    _focusImp = _imp;
                    _focusRad = _rad;
                };
            };
        };
    } forEach MISSION_CORE_CACHED_POSITIONS;

    if (_focus != "" && { _focus != MISSION_CORE_ZONE_FOCUS }) then {
        private _prev = MISSION_CORE_ZONE_FOCUS;
        MISSION_CORE_ZONE_FOCUS = _focus;
        MISSION_CORE_ZONE_FOCUS_TIME = time;
        // No retake cleanup needed here any more - the old line deleted the previous focus's
        // MISSION_CORE_CAPTURED_RETAKE entry, which only existed to stop that marker counting as a
        // candidate. Candidates are now derived from MISSION_CORE_OCCUPATION, and fn_occupationMonitor
        // clears that entry itself when the hold finalizes or reverts, so a stale focus could never
        // keep a marker in the running.
        diag_log format ["AI ZONE FOCUS: %1 -> %2 (closest marker to player)", _prev, _focus];
    };
    MISSION_CORE_ZONE_FOCUS
};
