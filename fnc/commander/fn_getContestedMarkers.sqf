
// There is exactly ONE contested marker PER PLAYER (not per side): each alive player's own
// nearest enemy-engaged marker is their zone. Two players attacking two different markers create
// two independent zones (full replenish / reinforce / support for each); two players on the same
// marker share one zone. Returns [_markerName, _pos, _size, _owner] for each zone.
MISSION_CORE_fnc_getContestedMarkers = {
    params ["_side"];
    private _playersA = allPlayers select { alive _x };
    private _now = time;
    // PERMANENT RULE: markers captured from this side within the last 20 minutes are retake
    // targets. Ownership already flipped to the player side so the plain owner filter below
    // would never include them; the retake set keeps them contested so garrison groups will
    // counter-attack to win the base back. Expired entries are ignored (and cleaned up lazily).
    private _retake = [];
    if (!isNil "MISSION_CORE_CAPTURED_RETAKE") then {
        _retake = keys MISSION_CORE_CAPTURED_RETAKE select {
            private _v = MISSION_CORE_CAPTURED_RETAKE get _x;
            (_v select 0) == _side && { _now - (_v select 1) < 1200 }
        };
    };
    // All markers that are contested by at least one player (engaged garrison or retake target).
    private _candidates = MISSION_CORE_CACHED_POSITIONS select {
        private _locPos = _x select 1;
        if ((_x select 0) in _retake) then {
            // Recently-lost marker: contested for this side while a player is nearby, even though
            // it is no longer owned by us - that is exactly why it must be retaken.
            _playersA findIf { _x distance _locPos < 3000 } != -1
        } else {
            (_x select 4) == _side &&
            { [_locPos, _side, _x select 0] call MISSION_CORE_fnc_isMarkerContested }
        }
    };
    if (count _candidates == 0) exitWith { [] };
    // No players alive: keep the nearest candidate contested so garrison groups keep fighting /
    // the capture path still works. (Previous behavior kept a single zone.)
    if (count _playersA == 0) exitWith {
        private _sz = if (count (_candidates select 0) > 8) then { (_candidates select 0) select 8 } else { [50, 50] };
        [[(_candidates select 0) select 0, (_candidates select 0) select 1, _sz, (_candidates select 0) select 4]]
    };
    // ONE zone per alive player: the candidate CLOSEST to each player. Dedupe by marker name so
    // two players on the same marker share a single zone.
    private _zones = [];
    {
        private _p = _x;
        private _best = [];
        private _bestD = 1e10;
        {
            private _d = _p distance (_x select 1);
            if (_d < _bestD) then { _bestD = _d; _best = _x; };
        } forEach _candidates;
        if ((_best select 0) in (_zones apply { _x select 0 })) then { continue; };
        private _sz = if (count _best > 8) then { _best select 8 } else { [50, 50] };
        _zones pushBack [_best select 0, _best select 1, _sz, _best select 4];
    } forEach _playersA;

    // Broadcast the names of currently contested markers so clients (recruit menu) can know which
    // friendly markers are under attack / need defending. Throttled: this function is called from
    // many independent server loops every tick, so only push a broadcast when the contested set
    // actually CHANGED (and at most once per 5s) - otherwise we serialize the same list over the
    // network dozens of times a second. MISSION_CORE_CONTESTED_MARKERS always holds the last
    // value sent, so a change that arrives mid-throttle is still detected and broadcast next pass.
    private _zonedNames = _zones apply { _x select 0 };
    if (isNil "MISSION_CORE_CONTESTED_LAST_BROADCAST") then { MISSION_CORE_CONTESTED_LAST_BROADCAST = -1e10; };
    if (isNil "MISSION_CORE_CONTESTED_MARKERS") then { MISSION_CORE_CONTESTED_MARKERS = []; };
    private _against = +MISSION_CORE_CONTESTED_MARKERS;
    private _changed = { _x in _zonedNames } count _against != count _against
        || { (_x in _against) } count _zonedNames != count _zonedNames;
    if (_changed && { time - MISSION_CORE_CONTESTED_LAST_BROADCAST > 5 }) then {
        MISSION_CORE_CONTESTED_LAST_BROADCAST = time;
        MISSION_CORE_CONTESTED_MARKERS = _zonedNames;
        publicVariable "MISSION_CORE_CONTESTED_MARKERS";
    };

    _zones
};
