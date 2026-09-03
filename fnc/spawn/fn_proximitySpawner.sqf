
// True when two rotated ellipses (center, half-axis A, half-axis B, dir) actually overlap.
// Not bounding circles: rim-samples the candidate against the other's real rotated ellipse, plus
// a center-inside fast path. Used so long-thin markers whose centers are merely within each
// other's long axes NEVER suppress each other unless their actual areas intersect.
MISSION_CORE_fnc_ellipsesOverlap = {
    params ["_cPos", "_cA", "_cB", "_cD", "_oPos", "_oA", "_oB", "_oD"];
    private _inEllipse = {
        params ["_p", "_ePos", "_eA", "_eB", "_eDir"];
        private _dx = (_p select 0) - (_ePos select 0);
        private _dy = (_p select 1) - (_ePos select 1);
        private _rx = _dx * cos _eDir - _dy * sin _eDir;
        private _ry = _dx * sin _eDir + _dy * cos _eDir;
        ((_rx * _rx) / (_eA * _eA) + (_ry * _ry) / (_eB * _eB)) <= 1
    };
    if ([_cPos, _oPos, _oA, _oB, _oD] call _inEllipse) exitWith { true };
    if ([_oPos, _cPos, _cA, _cB, _cD] call _inEllipse) exitWith { true };
    private _rimPoint = {
        params ["_pos", "_a", "_b", "_dir", "_t"];
        private _rad = (_a max _b) * (_a min _b) /
            sqrt (((_b * cos _t) ^ 2) + ((_a * sin _t) ^ 2));
        _pos getPos [_rad, _t + _dir]
    };
    for "_i" from 0 to 23 do {
        private _t = (_i / 24) * 360;
        private _p = [_cPos, _cA, _cB, _cD, _t] call _rimPoint;
        if ([_p, _oPos, _oA, _oB, _oD] call _inEllipse) exitWith { true };
    };
    false
};

// Radius of a marker along a world bearing (from its center to its outer edge on that bearing).
// Shape-aware: ellipse uses the exact rotated-ellipse radius; rectangle uses a ray-vs-rotated-box
// intersection so a square marker's corners are respected. Cache size comes from the loc entry
// (index 8 = [a, b, dir]).
MISSION_CORE_fnc_markerRadiusAt = {
    params ["_loc", "_bearing"];
    private _size = if (count _loc > 8) then { _loc select 8 } else { [200, 200, 0] };
    private _a = (_size select 0) max 0.01;
    private _b = if (count _size > 1) then { (_size select 1) max 0.01 } else { _a };
    private _dir = if (count _size > 2) then { _size select 2 } else { 0 };
    private _shape = if ((_loc select 0) in allMapMarkers) then { markerShape (_loc select 0) } else { "ELLIPSE" };
    if (_shape == "RECTANGLE") exitWith {
        // Ray from center at local angle t against a [-a,a] x [-b,b] box, then rotated by _dir.
        private _t = _bearing - _dir;
        private _c = abs (cos _t);
        private _s = abs (sin _t);
        private _tx = if (_c < 0.001) then { 1e10 } else { _a / _c };
        private _ty = if (_s < 0.001) then { 1e10 } else { _b / _s };
        _tx min _ty
    };
    // Ellipse (default)
    [_a, _b, _bearing, _dir] call MISSION_CORE_fnc_ellipseRadius
};

// Edge-to-edge gap between two markers along their center line (center distance minus both
// radii measured toward each other). Clamped at 0 for overlapping markers.
MISSION_CORE_fnc_markerEdgeGap = {
    params ["_locA", "_locB"];
    private _pA = _locA select 1;
    private _pB = _locB select 1;
    private _d = _pA distance2D _pB;
    private _bAB = _pA getDir _pB;
    private _bBA = _pB getDir _pA;
    private _rA = [_locA, _bAB] call MISSION_CORE_fnc_markerRadiusAt;
    private _rB = [_locB, _bBA] call MISSION_CORE_fnc_markerRadiusAt;
    (_d - _rA - _rB) max 0
};

// Proximity radii for a marker with close same-side neighbors. Returns
// [activationRadius, deactivationRadius] measured FROM THE CENTER, or [] if the marker has no
// close neighbor (caller keeps the default 700/2500).
//   - activation = own radius toward the CLOSEST neighbor + half that edge-gap
//   - deactivation = own radius toward the NEXT-closest neighbor + full that edge-gap
// (a marker with one neighbor uses the same gap for both; deactivation uses the full gap).
// REDFOR (EAST) markers only.
MISSION_CORE_fnc_markerCloseRadii = {
    params ["_loc"];
    private _side = _loc select 4;
    if (_side != EAST) exitWith { [] };
    private _mName = _loc select 0;
    private _mPos = _loc select 1;
    private _maxR = ["proxDespawnDist", 2500] call MISSION_CORE_fnc_tune;
    private _nbrs = MISSION_CORE_CACHED_POSITIONS select {
        (_x select 4) == _side &&
        { (_x select 0) != _mName } &&
        { ((_x select 1) distance2D _mPos) < _maxR }
    };
    if (count _nbrs == 0) exitWith { [] };
    // Rank neighbors by edge gap, ascending.
    private _gaps = _nbrs apply { [_loc, _x] call MISSION_CORE_fnc_markerEdgeGap };
    private _sorted = _nbrs;
    _sorted = [_sorted, [], { [_loc, _x] call MISSION_CORE_fnc_markerEdgeGap }, "ASCEND"] call BIS_fnc_sortBy;
    private _closest = _sorted select 0;
    private _gapC = [_loc, _closest] call MISSION_CORE_fnc_markerEdgeGap;
    private _bearC = _mPos getDir (_closest select 1);
    private _act = ([_loc, _bearC] call MISSION_CORE_fnc_markerRadiusAt) + (_gapC / 2);
    // Deactivation uses the next-closest neighbor (fall back to closest when only one).
    private _next = if (count _sorted > 1) then { _sorted select 1 } else { _closest };
    private _gapN = [_loc, _next] call MISSION_CORE_fnc_markerEdgeGap;
    private _bearN = _mPos getDir (_next select 1);
    private _des = ([_loc, _bearN] call MISSION_CORE_fnc_markerRadiusAt) + _gapN;
    [_act, _des]
};

MISSION_CORE_fnc_proximitySpawner = {
    diag_log "DYNAMIC SPAWN: proximity spawner started";
    MISSION_CORE_SPAWNED_LOCATIONS = createHashMap;
    MISSION_CORE_SPAWNED_CACHE = createHashMap;
    MISSION_CORE_SPAWNED_GROUPS = [];
    private _maxActive = ["proxMaxActive", 6] call MISSION_CORE_fnc_tune;
    while { true } do {
        sleep 10 + random 5;
        private _players = allPlayers select { alive _x };
        private _playerSides = _players apply { side _x };
        {
            private _loc = _x;
            private _locPos = _loc select 1;
            private _locName = _loc select 0;
            if (MISSION_CORE_SPAWNED_LOCATIONS getOrDefault [_locName, false]) then {
                private _nearestDist = 99999;
                { private _d = _x distance _locPos; if (_d < _nearestDist) then { _nearestDist = _d; }; } forEach _players;
                // A marker that gave up (its reinforcement pool was exhausted) despawns sooner -
                // 1500m instead of 2500m - so its spawn slot frees as soon as the player backs off.
                if (isNil "MISSION_CORE_REINF_EXHAUSTED") then { MISSION_CORE_REINF_EXHAUSTED = createHashMap; };
                private _despawnDist = if (MISSION_CORE_REINF_EXHAUSTED getOrDefault [_locName, false])
                    then { ["proxDespawnExhausted", 1500] call MISSION_CORE_fnc_tune }
                    else { ["proxDespawnDist", 2500] call MISSION_CORE_fnc_tune };
                if (_nearestDist > _despawnDist) then {
                    // A marker under active attack is never despawned - its defenders keep fighting.
                    // Otherwise (nothing attacking it) even a player-owned marker despawns on
                    // distance and simply re-spawns when the player returns.
                    private _owner = _loc select 4;
                    private _enemySide = if (_owner == WEST) then { EAST } else { WEST };
                    private _underAttack = { alive _x && { side _x == _enemySide } && { _x distance _locPos < 1500 } } count allUnits > 0;
                    if (!_underAttack) then {
                        [_locName, _locPos] call MISSION_CORE_fnc_despawnLocation;
                    };
                };
            };
        } forEach MISSION_CORE_CACHED_POSITIONS;

        // Enforce the active budget BEFORE spawning: only the nearest markers per enemy side may
        // trigger, so a marker is never spawned and then instantly despawned by deactivateFarMarkers
        // (the old code spawned every marker within 1500m, then culled to 4 - a churn that wasted
        // supply and spawned whole batches of units for a second).
        if (count _players > 0) then {
            {
                private _side = _x;
                // The player's own side is never budget-capped (matches deactivateFarMarkers)
                private _budget = if (_side in _playerSides) then { 1e10 } else { _maxActive };
                private _withDist = [];
                {
                    private _loc = _x;
                    if ((_loc select 4) == _side) then {
                        private _locPos = _loc select 1;
                        private _locName = _loc select 0;
                        // PERMANENT RULE (BLUFOR garrison sourcing): a marker the player garrisoned via
                        // the recruit menu (defend tab) NEVER also gets the auto-recruited garrison - the
                        // player's deployed force REPLACES / IS the garrison. Groups/vehicles are tracked
                        // in MISSION_CORE_GARRISON_DB, so a marker becomes "player-garrisoned" as soon as
                        // one squad or vehicle is deployed there.
                        if (_side == WEST) then {
                            private _pg = if (isNil "MISSION_CORE_GARRISON_DB") then { [[], []] } else { MISSION_CORE_GARRISON_DB getOrDefault [_locName, [[], []]] };
                            if ((count (_pg select 0) > 0) || { count (_pg select 1) > 0 }) then { continue; };
                        };
                        // PERMANENT RULE (request 2): an auto-recruited BLUFOR marker's garrison is only
                        // fielded when it is actually needed - an enemy (REDFOR) must be attacking it or
                        // inside it. Just having the marker's own player nearby never spawns the garrison.
                        // An already-spawned marker is left to its normal despawn logic.
                        if (_side == WEST && { !(MISSION_CORE_SPAWNED_LOCATIONS getOrDefault [_locName, false]) }) then {
                            private _gateR = ["proxSpawnRadius", 700] call MISSION_CORE_fnc_tune;
                            private _enemyNear = { alive _x && { side _x == EAST } && { _x distance _locPos < _gateR } } count allUnits > 0;
                            if (!_enemyNear) then { continue; };
                        };
                        // PERMANENT RULE: an occupied marker (in the 10-min hold phase) fields NO
                        // garrison for its new owner - the occupier must hold it with their own
                        // units while the previous owner counter-attacks to win it back.
                        if ([_locName] call MISSION_CORE_fnc_isOccupied) then { continue; };
                        private _nearestDist = 99999;
                        private _nearestPlayer = objNull;
                        { private _d = _x distance _locPos; if (_d < _nearestDist) then { _nearestDist = _d; _nearestPlayer = _x; }; } forEach _players;
                        // A freshly captured marker stays clear of the capturer's own garrison until
                        // the player MOVES OUT of the spawn radius and back IN. While suppressed we
                        // never spawn here; the flag clears once the player has actually left the
                        // marker's spawn footprint, so re-entering later spawns normally.
                        if (_side in _playerSides) then {
                            if (isNil "MISSION_CORE_CAPTURE_SUPPRESSED") then { MISSION_CORE_CAPTURE_SUPPRESSED = createHashMap; };
                            if (MISSION_CORE_CAPTURE_SUPPRESSED getOrDefault [_locName, false]) then {
                                private _clearR = ["proxSpawnRadius", 700] call MISSION_CORE_fnc_tune;
                                if (_nearestDist > _clearR) then { MISSION_CORE_CAPTURE_SUPPRESSED deleteAt _locName; }
                                else { continue; };
                            };
                        };
                        if (MISSION_CORE_SPAWNED_LOCATIONS getOrDefault [_locName, false]) then {
                            _withDist pushBack [_loc, _nearestDist, true];
                        } else {
                            // PERMANENT RULE: only markers within proxSpawnRadius of a player spawn a
                            // garrison. Markers farther out exist purely as reinforcement sources -
                            // they send troops to the contested marker but never field a garrison.
                            // Markers WIDER than 700m (largest half-axis > 700m) measure the spawn
                            // radius from the EDGE and spawn 100m outside it, so a huge marker doesn't
                            // pop its garrison only after you're already inside. Markers 700m or
                            // smaller keep plain center-distance (proxSpawnRadius = 700m).
                            private _spawnR = ["proxSpawnRadius", 700] call MISSION_CORE_fnc_tune;
                            private _edgeDist = _nearestDist;
                            private _size = if (count _loc > 8) then { _loc select 8 } else { [200, 200, 0] };
                            private _a = (_size select 0) max 0.01;
                            private _b = if (count _size > 1) then { (_size select 1) max 0.01 } else { _a };
                            private _mDir = if (count _size > 2) then { _size select 2 } else { 0 };
                            private _shape = if ((_loc select 0) in allMapMarkers) then { markerShape (_loc select 0) } else { "ELLIPSE" };
                            // Close-marker split: a REDFOR marker with a close same-side neighbor
                            // activates at HALF the gap to its closest neighbor (edge-based, center
                            // radius), overriding the 700m / big-marker rules entirely.
                            private _closeR = [_loc] call MISSION_CORE_fnc_markerCloseRadii;
                            if (count _closeR == 2) then {
                                _spawnR = _closeR select 0;
                                _edgeDist = _nearestDist;   // already a center distance
                            } else {
                                if (_shape == "RECTANGLE") then {
                                    // Rectangles spawn from their actual box edge (grew outward by
                                    // proxSpawnRadius), never a circle around the center - so a long
                                    // town rectangle reaches its full footprint, not a round blob.
                                    private _angle = _locPos getDir (getPos _nearestPlayer);
                                    private _edge = [_loc, _angle] call MISSION_CORE_fnc_markerRadiusAt;
                                    _edgeDist = (_nearestDist - _edge) max 0;
                                } else {
                                    // "Big" ellipse = largest half-axis exceeds 700m (not 700 sqm).
                                    if ((_a max _b) > 700) then {
                                        private _angle = _locPos getDir (getPos _nearestPlayer);
                                        private _edge = [_a, _b, _angle, _mDir] call MISSION_CORE_fnc_ellipseRadius;
                                        _edgeDist = (_nearestDist - _edge) max 0;
                                        _spawnR = 100;   // big markers spawn 100m outside their edge
                                    };
                                };
                            };
                            if (_edgeDist < _spawnR) then { _withDist pushBack [_loc, _edgeDist, false]; };
                        };
                    };
                } forEach MISSION_CORE_CACHED_POSITIONS;
                _withDist = [_withDist, [], { _x select 1 }, "ASCEND"] call BIS_fnc_sortBy;
                // Suppress candidates that actually OVERLAP a bigger same-side marker (higher
                // importance, then larger radius) - never spawn two markers inside each other.
                // Uses a real ellipse-vs-ellipse test, not bounding circles: two long-thin ellipses
                // whose centers happen to sit within each other's long axes + long axis are NOT
                // necessarily overlapping, and must not suppress each other.
                private _suppressed = [];
                {
                    private _c = _x;
                    if (_c select 2) then { continue; };
                    private _cLoc = _c select 0;
                    private _cImp = _cLoc select 7;
                    private _cSize = if (count _cLoc > 8) then { _cLoc select 8 } else { [200, 200, 0] };
                    private _cA = (_cSize select 0) max 1;
                    private _cB = if (count _cSize > 1) then { (_cSize select 1) max 1 } else { _cA };
                    private _cD = if (count _cSize > 2) then { _cSize select 2 } else { 0 };
                    private _cPos = _cLoc select 1;
                    {
                        private _o = _x;
                        if ((_o select 0) select 0 == (_cLoc select 0)) then { continue; };
                        private _oLoc = _o select 0;
                        private _oSize = if (count _oLoc > 8) then { _oLoc select 8 } else { [200, 200, 0] };
                        private _oA = (_oSize select 0) max 1;
                        private _oB = if (count _oSize > 1) then { (_oSize select 1) max 1 } else { _oA };
                        private _oD = if (count _oSize > 2) then { _oSize select 2 } else { 0 };
                        private _oPos = _oLoc select 1;
                        if ([_cPos, _cA, _cB, _cD, _oPos, _oA, _oB, _oD] call MISSION_CORE_fnc_ellipsesOverlap) then {
                            private _oImp = _oLoc select 7;
                            private _oArea = _oA * _oB;
                            private _cArea = _cA * _cB;
                            if (_oImp > _cImp || (_oImp == _cImp && { _oArea > _cArea })) then {
                                _suppressed pushBack (_cLoc select 0);
                                diag_log format ["DYNAMIC SPAWN: suppressing %1 (overlaps bigger %2)", _cLoc select 0, _oLoc select 0];
                            };
                        };
                    } forEach _withDist;
                } forEach _withDist;
                private _activeCount = { _x select 2 } count _withDist;
                {
                    private _entry = _x;
                    if (_entry select 2) then { continue; };
                    if (_activeCount >= _budget) then {
                        // Budget full but this candidate is closer than the farthest active marker:
                        // swap them so the nearest markers stay live instead of a stale distant one.
                        private _farIdx = -1;
                        private _farDist = -1;
                        for "_i" from 0 to (count _withDist - 1) do {
                            private _e = _withDist select _i;
                            if (_e select 2 && { _e select 1 > _farDist }) then { _farDist = _e select 1; _farIdx = _i; };
                        };
                        if (_farIdx < 0 || { _farDist <= (_entry select 1) }) then {
                            // Log each deferred marker at most once per 60s - the budget stays full
                            // for many minutes while the player holds position, and re-logging the
                            // same "deferred" line every 10s is just spam.
                            if (isNil "MISSION_CORE_DEFERRED_LOG") then { MISSION_CORE_DEFERRED_LOG = createHashMap; };
                            private _lastLog = MISSION_CORE_DEFERRED_LOG getOrDefault [(_entry select 0) select 0, -99999];
                            if (time - _lastLog > 60) then {
                                MISSION_CORE_DEFERRED_LOG set [(_entry select 0) select 0, time];
                                diag_log format ["DYNAMIC SPAWN: deferred %1 (active budget %2 reached)", (_entry select 0) select 0, _budget];
                            };
                            continue;
                        };
                        private _farLoc = (_withDist select _farIdx) select 0;
                        diag_log format ["DYNAMIC SPAWN: swapping %1 out for %2 (dist %3 vs %4)", _farLoc select 0, (_entry select 0) select 0, _farDist, _entry select 1];
                        [_farLoc select 0, _farLoc select 1] call MISSION_CORE_fnc_despawnLocation;
                        _withDist set [_farIdx, [_farLoc, _farDist, false]];
                        _activeCount = _activeCount - 1;
                    };
                    private _loc = _entry select 0;
                    private _locName = _loc select 0;
                    if (_locName in _suppressed) then { continue; };
                    MISSION_CORE_SPAWNED_LOCATIONS set [_locName, true];
                    _activeCount = _activeCount + 1;
                    diag_log format ["DYNAMIC SPAWN: proximity triggered %1 (dist=%2)", _locName, _entry select 1];
                    [_loc] call MISSION_CORE_fnc_spawnLocation;
                } forEach _withDist;
            } forEach [WEST, EAST];
        };
        // Keep only the nearest N spawned markers active per enemy side; fully despawn the rest
        [] call MISSION_CORE_fnc_deactivateFarMarkers;
    };
};
