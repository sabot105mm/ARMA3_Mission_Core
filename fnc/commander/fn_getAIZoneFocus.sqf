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

    // Candidates: markers owned by this side, plus un-expired retake targets (captured markers
    // this side is still trying to win back).
    private _retake = [];
    if (!isNil "MISSION_CORE_CAPTURED_RETAKE") then {
        _retake = keys MISSION_CORE_CAPTURED_RETAKE select {
            private _v = MISSION_CORE_CAPTURED_RETAKE get _x;
            (count _v > 1) && { (_v select 0) == _side } && { time - (_v select 1) < 1200 }
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
        private _isRetake = (_x select 0) in _retake;
        if (_owned || _isRetake) then {
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
        private _isRetake = (_x select 0) in _retake;
        if ((_owned || _isRetake) && { (_x select 0) != _closest }) then {
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
        if (_prev != "" && { !isNil "MISSION_CORE_CAPTURED_RETAKE" }) then { MISSION_CORE_CAPTURED_RETAKE deleteAt _prev; };
        diag_log format ["AI ZONE FOCUS: %1 -> %2 (closest marker to player)", _prev, _focus];
    };
    MISSION_CORE_ZONE_FOCUS
};
