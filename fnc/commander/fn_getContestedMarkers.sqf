
// There is NO artificial zone cap: EVERY marker with any BLUFOR threat present (any player
// approaching/inside, or any assault squad whose assigned target it is) is a contested zone.
// Fight count is bounded only by the max-spawned-troops caps, so reinforcements/replenish
// scale with how much the players actually threaten at once. Returns
// [_markerName, _pos, _size, _owner] for each zone.

// Broadcast the contested marker names for ONE side, then broadcast the UNION across sides so the
// client recruit menu (friendly markers under attack) and the server assault deploy / staged-squad
// auto-release (enemy target markers) both see the truth no matter which side's getContestedMarkers
// call happened to run most recently. Previously a single list was overwritten by whichever side
// queried last, so an EAST-targeted assault could vanish from the list whenever a WEST call landed
// in between, which stalled staged-squad auto-release and mis-staged fresh deploys. Throttled: this
// is called from many server loops every tick, so only push a broadcast when the union actually
// CHANGED (and at most once per 5s) - otherwise the same list would be serialized dozens of times
// a second. MISSION_CORE_CONTESTED_MARKERS always holds the last value sent, so a change that
// arrives mid-throttle is still detected and broadcast on the next pass.
if (isNil "MISSION_CORE_CONTESTED_BY_SIDE") then { MISSION_CORE_CONTESTED_BY_SIDE = createHashMap; };
MISSION_CORE_fnc_publishContestedMarkers = {
    params ["_side", "_names"];
    // Key by side name so the map never depends on Side objects being valid HashMap keys.
    MISSION_CORE_CONTESTED_BY_SIDE set [str _side, _names];
    private _union = [];
    {
        {
            if !(_x in _union) then { _union pushBack _x; };
        } forEach _y;
    } forEach MISSION_CORE_CONTESTED_BY_SIDE;
    if (isNil "MISSION_CORE_CONTESTED_LAST_BROADCAST") then { MISSION_CORE_CONTESTED_LAST_BROADCAST = -1e10; };
    if (isNil "MISSION_CORE_CONTESTED_MARKERS") then { MISSION_CORE_CONTESTED_MARKERS = []; };
    private _against = +MISSION_CORE_CONTESTED_MARKERS;
    private _changed = { _x in _union } count _against != count _against
        || { (_x in _against) } count _union != count _union;
    if (_changed && { time - MISSION_CORE_CONTESTED_LAST_BROADCAST > 5 }) then {
        MISSION_CORE_CONTESTED_LAST_BROADCAST = time;
        MISSION_CORE_CONTESTED_MARKERS = _union;
        publicVariable "MISSION_CORE_CONTESTED_MARKERS";
    };
};

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
    // ASSAULT-TARGET ZONES: a released assault squad pushing its assigned target marker makes that
    // marker a contested zone in its own right, the same way player presence does. Without this a
    // player-less squad battle (or one where the player happens to be nearer a different contested
    // marker) is dropped from the zone list, so the replenish gate, the fresh-garrison commit and
    // the AI counter-attack support all treat the target as quiet while it is actually under attack.
    //
    // Read the SERVER-SPAWNED tracked assault groups DIRECTLY (the authoritative server map plus
    // the relay map) instead of the derived MISSION_CORE_ASSAULT_CONTEST snapshot: that snapshot
    // only lists a group while presence is re-proven each second against the marker geometry, so
    // it flickers - a squad that has arrived and is fighting (its men physically inside, see the
    // replenish capture scan) could be missing from the snapshot on the tick this runs, dropping
    // its target from the zone list. Assignment to an ACTIVE group with at least one living member
    // actually at/near the objective is the reliable signal. Only markers OWNED by the queried
    // side are zones for it. Built up-front so the early-exit paths below cannot discard it.
    private _assaultZones = [];
    private _assaultNames = [];
    {
        private _grpVar = _x;
        if (isNil _grpVar) then { continue; };
        private _tracked = missionNamespace getVariable [_grpVar, objNull];
        if !(_tracked isEqualType createHashMap) then { continue; };
        {
            private _adata = _y;
            if (count _adata < 7) then { continue; };
            // Only a RELEASED (advancing) group contests - staging / hold / wiped groups do not.
            if ((_adata select 5) != "active") then { continue; };
            private _ag = _adata select 0;
            if (isNull _ag) then { continue; };
            private _mName = _adata select 1;
            if (_mName == "") then { continue; };
            if (_mName in _assaultNames) then { continue; };
            private _attackerSide = _adata select 4;
            if ((_side getFriend _attackerSide) >= 0.6) then { continue; };
            private _aliveMen = units _ag select { !isNull _x && { alive _x } };
            if (count _aliveMen == 0) then { continue; };
            private _locIdx = MISSION_CORE_CACHED_POSITIONS findIf { (_x select 0) == _mName };
            if (_locIdx < 0) then { continue; };
            private _loc = MISSION_CORE_CACHED_POSITIONS select _locIdx;
            if ((_loc select 4) != _side) then { continue; };
            private _sz = if (count _loc > 8) then { _loc select 8 } else { [50, 50] };
            private _sa = if (count _sz > 0) then { _sz select 0 } else { 50 };
            private _sb = if (count _sz > 1) then { _sz select 1 } else { _sa };
            private _sd = if (count _sz > 2) then { _sz select 2 } else { 0 };
            private _locPos = _loc select 1;
            // Must actually be at/near the objective - an active group still back at its staging
            // marker must not freeze the target from across the map. Presence is measured against
            // the marker's REAL SHAPE: any living member inside its rotated ellipse inflated to
            // 1.2x the edge (1.2*a, 1.2*b). This is exact for square markers (a == b -> a circle of
            // radius 1.2*a) and for elliptical ones (rotated by the marker's own direction), instead
            // of the old max-size+1000m circle that distorted long thin markers - a 600x100 strip
            // used to count a man 1600m out along its narrow axis. Distance is per living member,
            // not just the leader, so it does not share the leader-only blind spot.
            private _infl = 1.2;
            private _inside = {
                params ["_p"];
                private _dx = (_p select 0) - (_locPos select 0);
                private _dy = (_p select 1) - (_locPos select 1);
                private _rx = _dx * cos _sd - _dy * sin _sd;
                private _ry = _dx * sin _sd + _dy * cos _sd;
                (_rx*_rx)/((_sa*_infl)*(_sa*_infl)) + (_ry*_ry)/((_sb*_infl)*(_sb*_infl)) <= 1
            };
            if (_aliveMen findIf { [getPos _x] call _inside } == -1) then { continue; };
            _assaultZones pushBack [_mName, _locPos, _sz, _side];
            _assaultNames pushBack _mName;
        } forEach _tracked;
    } forEach ["MISSION_CORE_ATTACK_GROUPS", "MISSION_CORE_ATTACK_GROUPS_RELAY"];

    if (count _candidates == 0) exitWith {
        [_side, _assaultNames] call MISSION_CORE_fnc_publishContestedMarkers;
        _assaultZones
    };
    // No players alive: keep the nearest candidate contested so garrison groups keep fighting /
    // the capture path still works. (Previous behavior kept a single zone.)
    if (count _playersA == 0) exitWith {
        private _sz = if (count (_candidates select 0) > 8) then { (_candidates select 0) select 8 } else { [50, 50] };
        private _z = [[(_candidates select 0) select 0, (_candidates select 0) select 1, _sz, (_candidates select 0) select 4]];
        private _all = _z + _assaultZones;
        [_side, _all apply { _x select 0 }] call MISSION_CORE_fnc_publishContestedMarkers;
        _all
    };
    // ALL contested markers are zones (PERMANENT RULE). A marker is contested the moment ANY
    // BLUFOR threat is present (players + assault squads, garrison-independent - see
    // fn_isMarkerContested), and the fight count is bounded only by the max-spawned-troops
    // caps, never by a per-player zone limit. Every candidate from the contested filter above
    // becomes its own zone with its own neighbor pool / replenish cycle.
    private _zones = [];
    {
        private _sz = if (count _x > 8) then { _x select 8 } else { [50, 50] };
        _zones pushBack [_x select 0, _x select 1, _sz, _x select 4];
    } forEach _candidates;
    // Merge in the assault-target zones (dedupe against the contested candidates).
    {
        if !((_x select 0) in (_zones apply { _x select 0 })) then { _zones pushBack _x; };
    } forEach _assaultZones;

    // Publish this side's zones; the helper broadcasts the cross-side union (friendly + enemy
    // contested markers) so both consumer groups see the truth regardless of call order.
    [_side, _zones apply { _x select 0 }] call MISSION_CORE_fnc_publishContestedMarkers;

    _zones
};
