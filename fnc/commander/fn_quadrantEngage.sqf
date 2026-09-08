//
// QUADRANT ENGAGEMENT - REDFOR footprint responds to players by quadrant of the contested marker.
//
// For each EAST marker under real player contact (knowsAbout > 1.2), the spawned REDFOR foot
// garrison no longer simply SADs the nearest player's exact coordinate. Instead:
//
//   - Each engaged player is mapped to one of 4 marker quadrants (NE/SE/SW/NW: the quarter of the
//     marker rect in marker-local space) and flagged inside/outside the marker footprint.
//   - A quadrant's patrol depth comes from the PLAYER's DEPTH FRACTION (distance from center over
//     the ellipse radius on his bearing): a player 75% inside the marker on the NE side means the
//     released squads PATROL that NE square sector at ~75% of the way out - not his exact feet, not
//     a single point on the edge. OUTSIDE players push the patrol to 85-95% of the edge (perimeter).
//   - The foot groups are apportioned across the DISTINCT engaged quadrants (so multiple players
//     spread around the marker split the defenders). A quadrant holding several players is one
//     "bigger" target - the whole quadrant gets that force, not the separate player spots.
//   - Each released squad gets a zig-zag sweep of MOVE waypoints across a SQUARE sector of the
//     marker (the player's quadrant quarter, kept on their depth ring 45-95%), then an engage-at-will
//     SAD anchor, then a CYCLE so the sector stays held while it intercepts whoever crosses it.
//   - Release is STAGED "one by one": only quadrantReleasePerTick group per target is dispatched
//     per commander tick, the rest wait in the backlog, so a squad streams in rather than the whole
//     force teleporting onto one point.
//
// State:
//   MISSION_CORE_QUAD_BACKLOG = array of [_markerName, _group, _targetPos] staged, not yet sent.

// Returns true while a group sits in the quadrant staging backlog (claimed but not yet released).
// Every other re-tasker (commitToBattle, sendCounterAttack, defenseSpotLoop, suppressedReaction,
// restartPatrol, longRangeReaction) must skip staged squads or they get stolen between staging and
// release. The backlog itself is authoritative - the flag dies automatically on purge/release.
MISSION_CORE_fnc_isQuadrantStaged = {
    params ["_grp"];
    if (isNil "MISSION_CORE_QUAD_BACKLOG") exitWith { false };
    (MISSION_CORE_QUAD_BACKLOG findIf { (_x select 1) == _grp }) != -1
};

// Returns [quadrantIdx, insideTheMarker] for a world pos relative to an elliptical marker.
// quadrantIdx: 0=NE, 1=SE, 2=SW, 3=NW, in marker-local rotated space (+x east, +y north).
MISSION_CORE_fnc_quadrantOf = {
    params ["_center", "_size", "_dir", "_pos", ["_shape", "ELLIPSE"]];
    private _a = _size select 0; if (_a <= 0) then { _a = 1; };
    private _b = _size select 1; if (_b <= 0) then { _b = 1; };
    private _dx = (_pos select 0) - (_center select 0);
    private _dy = (_pos select 1) - (_center select 1);
    // Rotate into marker-local space (inverse of marker rotation).
    private _rad = -_dir;
    private _cS = cos _rad; private _sS = sin _rad;
    private _lx = _dx * _cS - _dy * _sS;
    private _ly = _dx * _sS + _dy * _cS;
    // Shape-aware membership (mirrors fn_portSystem): a box test for RECTANGLE markers, the ellipse
    // equation for ELLIPSE. An ellipse test against a rectangle marker wrongly rejects its corners;
    // a box test against an ellipse lets the far corner escape the footprint.
    private _inside = if (_shape == "RECTANGLE") then { (abs _lx <= _a) && { abs _ly <= _b } } else { ((_lx * _lx) / (_a * _a) + (_ly * _ly) / (_b * _b)) <= 1 };
    private _q = if (_lx >= 0) then { if (_ly >= 0) then { 0 } else { 1 } } else { if (_ly >= 0) then { 3 } else { 2 } };
    [_q, _inside]
};

// Compute the quadrant patrol anchor for a player at _pos relative to the marker: the point at the
// player's DEPTH FRACTION along the center->player bearing (a player 75% inside the marker gets the
// sweep centered on ~75% of the radius). Depth is clamped 0.45..0.95 so the wedge patrol never
// collapses onto the center or runs past the edge; outside players are pushed to 85-95% (perimeter).
// Returns [_anchorPos, _depthFrac].
MISSION_CORE_fnc_quadrantTarget = {
    params ["_center", "_size", "_dir", "_pos", "_inside", ["_shape", "ELLIPSE"]];
    private _a = _size select 0; if (_a <= 0) then { _a = 1; };
    private _b = _size select 1; if (_b <= 0) then { _b = 1; };
    private _ang = _center getDir _pos;
    // Shape-aware boundary radius on the player's bearing: ELLIPSE uses the ellipse radius
    // (fn_ellipseRadius); RECTANGLE uses the ray-to-edge distance of the box - the distance from
    // the center to the rect border along the bearing (in marker-local space).
    private _eR = 1;
    if (_shape == "RECTANGLE") then {
        private _la = _ang - _dir;
        private _cxL = cos _la; private _cyL = sin _la;
        private _tX = if (abs _cxL > 0.0001) then { _a / (abs _cxL) } else { 1e9 };
        private _tY = if (abs _cyL > 0.0001) then { _b / (abs _cyL) } else { 1e9 };
        _eR = (_tX min _tY) max 1;
    } else {
        _eR = (([_a, _b, _ang, _dir] call MISSION_CORE_fnc_ellipseRadius) max 1);
    };
    private _depth0 = if (_inside) then { (_center distance2D _pos) / _eR } else { 1.0 };
    private _depth = (0.45 max _depth0) min 0.95;
    [_center getPos [_eR * _depth, _ang], _depth]
};

// Issue a quadrant PATROL order to one group: sweep the quadrant wedge (the area between the two
// bearing lines bounding quadrant _q) on a ring around the player's depth fraction, holding the
// sector engage-at-will. Mirrors the old engage command but replaces the single marker-edge SAD
// with a zig-zag sweep through the quadrant area the player is in.
MISSION_CORE_fnc_issueQuadrantSAD = {
    params ["_g", "_target", ["_marker", ""], ["_q", 0], ["_depth", 0.75], ["_force", false], ["_center", []], ["_size", []], ["_dir", 0], ["_shrink", 1.0], ["_shape", "ELLIPSE"]];
    if (!_force && { _g getVariable ["MISSION_CORE_ORDER", ""] != "" }) exitWith {};
    _g setVariable ["MISSION_CORE_ORDER", "engage"];
    _g setVariable ["MISSION_CORE_QUAD_MARKER", _marker];
    _g setVariable ["MISSION_CORE_DISPATCH_MARKER", _marker];
    _g setVariable ["MISSION_CORE_ATTACK_TARGET", _target];
    _g setVariable ["MISSION_CORE_QUAD_Q", _q];
    _g setVariable ["MISSION_CORE_QUAD_TIME", time];
    _g setVariable ["MISSION_CORE_IDLE", false];
    _g setVariable ["MISSION_CORE_PATROLLING", false];
    leader _g setVariable ["MISSION_CORE_PATROLLING", false];
    _g setFormation "WEDGE";
    _g setSpeedMode "NORMAL";
    _g setBehaviour "AWARE";
    // Approach the quadrant at NORMAL speed and YELLOW combat mode; the monitor flips the group
    // RED the moment it reaches the waypoint right before the SAD (see below).
    _g setCombatMode "YELLOW";
    // Sweep geometry is taken from the SAME [_center, _size, _dir] that computed this group's
    // quadrant + depth (the caller's marker entry), so the sweep can NEVER disagree with the
    // quadrant the player was mapped into - no second data source to drift apart. The LOCATIONS
    // re-lookup below is only a backup for callers that did not pass geometry (none currently).
    private _c = _target;
    private _sz = [250, 250];
    private _mDir = 0;
    if (count _size > 1) then {
        _c = [_center select 0, _center select 1, 0];
        private _sa = _size select 0; if (_sa > 0) then { _sz set [0, _sa]; };
        private _sb = _size select 1; if (_sb > 0) then { _sz set [1, _sb]; };
        _mDir = _dir;
    } else {
        if !(isNil "MISSION_CORE_LOCATIONS") then {
            private _li = MISSION_CORE_LOCATIONS findIf { (_x select 0) == _marker };
            if (_li >= 0) then {
                private _area = (MISSION_CORE_LOCATIONS select _li) select 1;
                if (count _area > 1) then {
                    _c = _area select 0;
                    if (count (_area select 1) > 1) then { _sz = _area select 1; };
                    if (count _area > 2) then { _mDir = _area select 2; };
                    if (count _area > 3) then { _shape = _area select 3; };
                };
            };
        };
    };
    private _a = _sz select 0; if (_a <= 0) then { _a = 1; };
    private _bM = if (count _sz > 1) then { _sz select 1 } else { _a }; if (_bM <= 0) then { _bM = 1; };
    // Tighten the quad itself for BIGGER markers: a size-scaled multiplier pulls the sweep box in
    // toward the quadrant core - 0.85 ^ (mean half-axis / 500) - so a marker twice the 500m
    // reference tightens another ~15%, and every doubling beyond that tightens further. Uniform
    // on both axes.
    private _sizeShrink = 0.85 ^ ((_a + _bM) * 0.5 / 500);
    // Stacked groups: each ADDITIONAL squad assigned to the same quadrant shrinks its patrol box by
    // 10% (via _shrink = 0.9 ^ (squads already patrolling this quadrant)). All squads share the same
    // bearing center (the quadrant is one target); every extra squad nests 10% closer to it.
    private _aT = _a * _shrink * _sizeShrink; if (_aT <= 0) then { _aT = 1; };
    private _bT = _bM * _shrink * _sizeShrink; if (_bT <= 0) then { _bT = 1; };
    // Bearing-centered quadrant sweep: the patrol box is centered on the ENGAGING PLAYER'S exact
    // bearing anchor (the quadrantTarget depth point, passed in as _target) instead of a static
    // quadrant-quarter corner - so the center is really the center of his sector. NE/SE/SW/NW stays
    // as the grouping label only. The box spans +/- 0.25 of the tightened half-axes around that
    // center and is clamped so it can never cross into an adjacent quadrant; _sx/_sy carry the
    // quadrant side signs (signed local axes, X running along the marker's heading).
    private _radA = _mDir;
    private _cRb = cos _radA; private _sRb = sin _radA;
    private _sx = if (_q == 0 || _q == 1) then { 1 } else { -1 };
    private _sy = if (_q == 0 || _q == 3) then { 1 } else { -1 };
    private _locToWorld = {
        params ["_lx", "_ly"];
        [(_c select 0) + _lx * _cRb - _ly * _sRb, (_c select 1) + _lx * _sRb + _ly * _cRb, 0]
    };
    private _worldToLoc = {
        params ["_wx", "_wy"];
        private _dx = _wx - (_c select 0);
        private _dy = _wy - (_c select 1);
        private _iw = -_mDir;
        [(_dx * cos _iw - _dy * sin _iw), (_dx * sin _iw + _dy * cos _iw)]
    };
    private _hx = _aT * 0.25;
    private _hy = _bT * 0.25;
    private _tL = [_target select 0, _target select 1] call _worldToLoc;
    // The box center is ALWAYS the engaging player's exact position (the passed-in target), no
    // exception - outside/perimeter players included. A depth-clamped proxy parks the ring hundreds
    // of metres short of an outside player (95% of the marker edge vs a player 2x outside), so the
    // recentre law is absolute. The half-extents are only capped to keep the box inside the quadrant
    // half: for centers INSIDE the marker both axis edges limit the box; for centers OUTSIDE the
    // marker only the quadrant axis line matters (the far side can't cross any other quadrant line).
    private _inQ = (abs (_tL select 0) <= _a) && { abs (_tL select 1) <= _bM };
    private _hxE = _hx min (if (_sx > 0) then { _tL select 0 } else { -(_tL select 0) });
    private _hyE = _hy min (if (_sy > 0) then { _tL select 1 } else { -(_tL select 1) });
    if (_inQ) then {
        _hxE = _hxE min (if (_sx > 0) then { _a - (_tL select 0) } else { (_tL select 0) + _a });
        _hyE = _hyE min (if (_sy > 0) then { _bM - (_tL select 1) } else { (_tL select 1) + _bM });
    };
    _hxE = _hxE max 1; _hyE = _hyE max 1;
    private _qCL = _tL;
    [_g] call MISSION_CORE_fnc_clearGroupWaypoints;
    // Zig-zag sweep corners of the capped box around the exact bearing center.
    private _sweep = [
        [(_qCL select 0) - _sx * _hxE, (_qCL select 1) + _sy * _hyE],
        [(_qCL select 0) + _sx * _hxE, (_qCL select 1) + _sy * _hyE],
        [(_qCL select 0) + _sx * _hxE, (_qCL select 1) - _sy * _hyE],
        [(_qCL select 0) - _sx * _hxE, (_qCL select 1) - _sy * _hyE]
    ];
    // APPROACH waypoint: the box center (the player's exact position). Completion radius hugs the
    // ACTUAL sweep box - its half-diagonal + 25%, never the whole quadrant - so the drawn circle sits
    // tight around the ring instead of looped 700m out, and the group flips RED when it reaches the
    // patrol area, not a kilometre early. transport_quadrantCommitRed.sqf flips RED on completion;
    // the patrol below already runs fire-at-will.
    private _qCtr = [_qCL select 0, _qCL select 1] call _locToWorld;
    private _qr = (sqrt ((_hxE * _hxE) + (_hyE * _hyE))) * 1.25;
    private _wpA = _g addWaypoint [_qCtr, _qr];
    _wpA setWaypointType "MOVE";
    _wpA setWaypointSpeed "NORMAL";
    _wpA setWaypointBehaviour "AWARE";
    _wpA setWaypointCombatMode "YELLOW";
    _wpA setWaypointFormation "WEDGE";
    _wpA setWaypointScript "fnc\commander\transport_quadrantCommitRed.sqf";
    private _sweepPts = [];
    private _dropped = 0;
    {
        // Pure marker math around the marker center - keep the points exactly where generated.
        // A sweep point that lands over water is DROPPED, not re-snapped: the old safeWaypointPos
        // coastal pull dragged whole blocks onto a nearby dry patch, out of the player's quadrant.
        // ELLIPSE markers clamp a sweep corner onto the ellipse quarter so no waypoint pokes past
        // the footprint (box markers keep their full box).
        private _lx0 = _x select 0;
        private _ly0 = _x select 1;
        // Only pull corners onto the footprint when the box CENTER is inside the marker: an
        // outside-player ring must stay around the player, not snap back onto the ellipse edge.
        if (_shape != "RECTANGLE" && { _inQ }) then {
            private _ee = ((_lx0 * _lx0) / (_aT * _aT) + (_ly0 * _ly0) / (_bT * _bT));
            if (_ee > 1) then { private _es = 1 / sqrt _ee; _lx0 = _lx0 * _es; _ly0 = _ly0 * _es; };
        };
        private _p = ([_lx0, _ly0] call _locToWorld);
        if (surfaceIsWater _p) then { _dropped = _dropped + 1; continue; };
        _sweepPts pushBack _p;
        private _wp = _g addWaypoint [_p, 30];
        _wp setWaypointType "MOVE";
        _wp setWaypointSpeed "NORMAL";
        // Sweep waypoints keep AWARE behaviour (squad keeps moving through the sector) but carry
        // RED combat mode, so the moment the approach completes they patrol fire-at-will.
        _wp setWaypointBehaviour "AWARE";
        _wp setWaypointCombatMode "RED";
        _wp setWaypointFormation "WEDGE";
    } forEach _sweep;
    // Engage-at-will SAD anchor at the SAME clamped bearing center as the approach/sweep box, so no
    // waypoint strays from the patrol (an un-clamped bearing anchor sits visibly outside tightly
    // nested tier boxes when the player is near a quadrant edge). Whoever crosses into the quadrant
    // gets intercepted instead of the squad idling on the sweep. If the center is over water the
    // SAD is dropped (the sweep patrol still covers the quadrant).
    if !(surfaceIsWater _qCtr) then {
        private _wpSad = _g addWaypoint [_qCtr, 15];
        _wpSad setWaypointType "SAD";
        _wpSad setWaypointSpeed "NORMAL";
        _wpSad setWaypointBehaviour "AWARE";
        _wpSad setWaypointCombatMode "RED";
        _wpSad setWaypointFormation "WEDGE";
    };
    // (Red/combat flip now happens on the APPROACH waypoint above, so the SAD needs no script.)
    // CYCLE back to the start of the sweep so the sector stays patrolled between contacts.
    private _wps = waypoints _g;
    private _loopPos = if (count _wps > 0) then { waypointPosition (_wps select 0) } else { _c };
    private _wpC = _g addWaypoint [_loopPos, 0];
    _wpC setWaypointType "CYCLE";
    _wpC setWaypointSpeed "NORMAL";
    _wpC setWaypointBehaviour "AWARE";
    // The RED/COMBAT flip fires on the APPROACH waypoint (transport_quadrantCommitRed.sqf), so the
    // sweep + SAD below already run hot. No polling loop: the waypoint script fires once on arrival,
    // and re-issuing a quadrant order clears the old sweep + SAD (and its attached script) auto.
    private _wps = waypoints _g;
    if (count _wps > 0) then {
        private _start = _wps select 0;
        { if (waypointType _x != "CYCLE") exitWith { _start = _x; }; } forEach _wps;
        _g setCurrentWaypoint _start;
    };
    diag_log format ["AI COMMANDER: %1 patrols QUAD %2 (q=%3 center=%4 a=%5 b=%6 dir=%7) depth=%8 approach=%9 r=%10 SAD=%11 sweep=%12 shrink=%13 dropped=%14 sizeShrink=%15 bearing=%16", groupId _g, (["NE", "SE", "SW", "NW"] select _q), _q, _c, _a, _bM, _mDir, _depth, _qCtr, _qr, _qCtr, _sweepPts, _shrink, _dropped, _sizeShrink, _target];
};

// Per-marker engagement tick. Returns true if foot defenders were (scheduled to be) engaged.
MISSION_CORE_fnc_quadrantEngage = {
    params ["_loc", "_engagedPlayers", "_defenders", "_markerName", "_locPos", "_engageRadius"];
    if (count _engagedPlayers == 0) exitWith { false };
    // PERMANENT RULE: Outposts are static tiny garrisons - they never get the quadrant sweep/SAD
    // order. The garrison simply holds its own marker.
    if ([_loc] call MISSION_CORE_fnc_isLightInfrastructure) exitWith { false };
    private _mkrArea = _loc select 1;
    private _size = if (count _mkrArea > 1) then { _mkrArea select 1 } else { [200, 200] };
    private _dir = if (count _mkrArea > 2) then { _mkrArea select 2 } else { 0 };
    private _shape = if (count _mkrArea > 3) then { _mkrArea select 3 } else { "ELLIPSE" };
    private _perTargetMax = ["quadrantPerTargetMax", 99] call MISSION_CORE_fnc_tune;
    private _releasePerTick = ["quadrantReleasePerTick", 3] call MISSION_CORE_fnc_tune;
    private _batchInterval = ["quadrantBatchInterval", 90] call MISSION_CORE_fnc_tune;
    if (isNil "MISSION_CORE_QUAD_BACKLOG") then { MISSION_CORE_QUAD_BACKLOG = []; };
    if (isNil "MISSION_CORE_QUAD_BATCH_TIMER") then { MISSION_CORE_QUAD_BATCH_TIMER = createHashMap; };
    if (isNil "MISSION_CORE_QUAD_SENT") then { MISSION_CORE_QUAD_SENT = createHashMap; };

    // 1) Distinct quadrant targets from engaged players (dedupe by quadrant -> bigger per-quadrant
    //    force when several players share it).
    private _targets = [];   // [_targetPos, quadrantIdx, depthFrac]
    {
        private _p = _x;
        private _qi = [_locPos, _size, _dir, getPos _p, _shape] call MISSION_CORE_fnc_quadrantOf;
        private _q = _qi select 0;
        if (_targets findIf { (_x select 1) == _q } == -1) then {
            private _qt = [_locPos, _size, _dir, getPos _p, (_qi select 1), _shape] call MISSION_CORE_fnc_quadrantTarget;
            _targets pushBack [getPosATL _p, _q, _qt select 1, _qt select 0];
        };
    } forEach _engagedPlayers;

    // Log each distinct quadrant target: the driving player's position IS the sweep box center (approach/
    // SAD/ring center all pivot on it, no exception); the anchor is the old depth-fraction proxy, kept
    // for comparison only.
    {
        _x params ["_pPos", "_tQ", "_tDepth", "_anchor"];
        diag_log format ["AI COMMANDER: QUAD TARGET %1 (q=%2) player=%3 center=%4 anchor=%5 depth=%6", _markerName, (["NE", "SE", "SW", "NW"] select _tQ), _pPos, _pPos, _anchor, _tDepth];
    } forEach _targets;

    // 2) Purge stale staged tasks for this marker (dead / already ordered / out of range).
    //    Dismounted counter-attack squads (MISSION_CORE_QUAD_ARRIVED) are exempt from the staging
    //    radius while they march in - they were already heading to this marker on foot, so an
    //    ARRIVED squad outside the 300m ring must not be purged before its release turn.
    MISSION_CORE_QUAD_BACKLOG = MISSION_CORE_QUAD_BACKLOG select {
        (_x select 0) != _markerName ||
        { !isNull (_x select 1) &&
          { { alive _x } count units (_x select 1) > 0 } &&
          { (_x select 1) getVariable ["MISSION_CORE_ORDER", ""] == "" } &&
          { ((leader (_x select 1)) distance _locPos <= _engageRadius) || { (_x select 1) getVariable ["MISSION_CORE_QUAD_ARRIVED", false] } } }
    };

    // 3) Stage up to _perTargetMax NEW groups per target per tick, nearest-first, from eligible
    //    defenders. This is a per-tick staging BATCH gated by a per-target throttle: we send a batch
    //    of up to _perTargetMax, then WAIT _batchInterval seconds (a few minutes) in case MORE
    //    players become spotted before committing the next batch - so a lone player gets one wave,
    //    a pause, then the next wave, instead of the whole garrison dumping in at once. Step 4 still
    //    releases one group per tick within a batch. "Always keep sending all the foot groups, one
    //    batch of them at a time."
    {
        _x params ["_target", "_q", "_depth"];
        // Per-target batch throttle: no new staging for this target until the interval has elapsed.
        private _tkey = _markerName + "_" + str _target;
        if (time < (MISSION_CORE_QUAD_BATCH_TIMER getOrDefault [_tkey, -1e10])) then { continue; };
        private _stagedThisTick = 0;
        for "_s" from 0 to (_perTargetMax - 1) do {
            private _stagedGroups = MISSION_CORE_QUAD_BACKLOG select { (_x select 0) == _markerName && { (_x select 2) distance2D _target < 1 } } apply { _x select 1 };
            private _pick = _defenders select {
                ((_x getVariable ["MISSION_CORE_ORDER", ""] == "") ||
                // Counter-attack squads join the quadrant response the moment they are on foot
                // (truck unloaded / sweeping). Only MOUNTED counter-attackers stay out - the
                // all-on-foot filter below already excludes those, so a rider's transport is never
                // stolen from under it.
                { (_x getVariable ["MISSION_CORE_ORDER", ""]) == "counterattack" }) &&
                // Never SAD a group still mounted in its transport truck for a quadrant - that has
                // the truck roll straight at the player. Only on-foot groups participate: the truck
                // keeps driving in, splitAfterDismount breaks the foot off, and footArrival makes
                // those foot groups eligible once they're dismounted and sweeping the marker.
                { { vehicle _x == _x } count units _x == count units _x } &&
                { (leader _x) distance _locPos <= _engageRadius } &&
                { !(_x in _stagedGroups) } &&
                // Dismounted counter-attack squads queued by splitAfterDismount are already in the
                // backlog - never re-stage them, even if the driving player shifted a few meters and
                // the target-position match above missed them.
                { !(_x getVariable ["MISSION_CORE_QUAD_ARRIVED", false]) }
            };
            if (count _pick == 0) exitWith {};
            _pick = [_pick, [], { (leader _x) distance2D _target }, "ASCEND"] call BIS_fnc_sortBy;
            private _stagedGrp = _pick select 0;
            // An on-foot counter-attack squad is now owned by the quadrant response: drop the old
            // counter-attack order so the release step can hand it the quadrant sweep instead of a
            // stale counter-attack that would otherwise sit in the backlog forever.
            if ((_stagedGrp getVariable ["MISSION_CORE_ORDER", ""]) == "counterattack") then {
                _stagedGrp setVariable ["MISSION_CORE_ORDER", ""];
            };
            MISSION_CORE_QUAD_BACKLOG pushBack [_markerName, _stagedGrp, _target, _q, _depth];
            _stagedThisTick = _stagedThisTick + 1;
        };
        // This batch of defenders is committed - hold the next batch until the interval elapses (a
        // paused wave), so a lone player isn't swamped by every group at once.
        if (_stagedThisTick > 0) then { MISSION_CORE_QUAD_BATCH_TIMER set [_tkey, time + _batchInterval]; };
    } forEach _targets;

    // 4) Release "one by one": up to _releasePerTick group per target this tick, rest stay staged.
    private _counts = createHashMap;
    private _remaining = [];
    {
        _x params ["_m", "_g", "_target", "_q", "_depth"];
        if (_m != _markerName) then { _remaining pushBack _x; continue; };
        private _key = str _target;
        if ((_counts getOrDefault [_key, 0]) >= _releasePerTick) then { _remaining pushBack _x; continue; };
        if (isNull _g) then { continue; };
        if ({ alive _x } count units _g == 0) then { continue; };
        // A staged squad whose ORDER became non-empty was hijacked after staging (some re-tasker
        // missed the isQuadrantStaged guard). Log it so the culprit surfaces instead of silently
        // dropping the squad from the backlog.
        private _gOrder = _g getVariable ["MISSION_CORE_ORDER", ""];
        if (_gOrder != "") then {
            diag_log format ["AI COMMANDER: QUAD %1 staged %2 hijacked while staged (order=%3) - dropped from backlog", _markerName, groupId _g, _gOrder];
            continue;
        };
        // Tier the patrol box: squads ALREADY on this quadrant define the shrink for the newcomer.
        // At release time this squad's order is still "" (set inside issueQuadrantSAD), so _pat counts
        // only the squads already patrolling the same marker+quadrant - the newcomer is one more.
        private _pat = { (_x getVariable ["MISSION_CORE_ORDER", ""]) == "engage" && { (_x getVariable ["MISSION_CORE_QUAD_MARKER", ""]) == _m } && { (_x getVariable ["MISSION_CORE_QUAD_Q", -1]) == _q } } count _defenders;
        [_g, _target, _m, _q, _depth, false, _locPos, _size, _dir, (0.9 ^ _pat), _shape] call MISSION_CORE_fnc_issueQuadrantSAD;
        _counts set [_key, (_counts getOrDefault [_key, 0]) + 1];
        MISSION_CORE_QUAD_SENT set [_markerName, (MISSION_CORE_QUAD_SENT getOrDefault [_markerName, 0]) + 1];
        diag_log format ["AI COMMANDER: QUAD released %1 for %2 (targets=%3, releasePerTick=%4, backlog=%5, dispatched=%6)", groupId _g, _markerName, count _targets, _releasePerTick, count MISSION_CORE_QUAD_BACKLOG, MISSION_CORE_QUAD_SENT getOrDefault [_markerName, 0]];
    } forEach MISSION_CORE_QUAD_BACKLOG;
    MISSION_CORE_QUAD_BACKLOG = _remaining;

    // 5) Every few minutes, re-evaluate groups HOLDING AN OLD quadrant order: if the player(s)
    //    driving that quadrant have since moved into a different quadrant, force-repoint the squad
    //    to the new quadrant (a fresh sweep + SAD) instead of leaving it patrolling where the
    //    player used to be. Fresh (< re-eval interval) quadrant orders are left alone.
    private _reEvalInterval = ["quadrantReEvalInterval", 300] call MISSION_CORE_fnc_tune;
    if (isNil "MISSION_CORE_QUAD_REEVAL") then { MISSION_CORE_QUAD_REEVAL = createHashMap; };
    private _rkey = "reeval_" + _markerName;
    if (time >= (MISSION_CORE_QUAD_REEVAL getOrDefault [_rkey, 0])) then {
        MISSION_CORE_QUAD_REEVAL set [_rkey, time + _reEvalInterval];
        {
            private _grp = _x;
            if ((_grp getVariable ["MISSION_CORE_ORDER", ""]) == "engage" &&
                { (_grp getVariable ["MISSION_CORE_QUAD_MARKER", ""]) == _markerName } &&
                { (_grp getVariable ["MISSION_CORE_QUAD_TIME", 0]) < (time - _reEvalInterval) } &&
                { count _engagedPlayers > 0 }) then {
                private _p0 = _engagedPlayers select 0;
                private _qi = [_locPos, _size, _dir, getPos _p0, _shape] call MISSION_CORE_fnc_quadrantOf;
                private _nq = _qi select 0;
                private _oldQ = _grp getVariable ["MISSION_CORE_QUAD_Q", -1];
                if (_nq != _oldQ) then {
                    private _qt = [_locPos, _size, _dir, getPos _p0, (_qi select 1), _shape] call MISSION_CORE_fnc_quadrantTarget;
                    // The group already holds "engage" on _markerName, so _pat counts it too - the
                    // repointed squad keeps its own patrol tier (no re-tiering from the move).
                    private _pat = { (_x getVariable ["MISSION_CORE_ORDER", ""]) == "engage" && { (_x getVariable ["MISSION_CORE_QUAD_MARKER", ""]) == _markerName } && { (_x getVariable ["MISSION_CORE_QUAD_Q", -1]) == _nq } } count _defenders;
                    [_grp, getPosATL _p0, _markerName, _nq, _qt select 1, true, _locPos, _size, _dir, (0.9 ^ (_pat - 1)), _shape] call MISSION_CORE_fnc_issueQuadrantSAD;
                    diag_log format ["AI COMMANDER: QUAD re-eval %1 repointed %2 -> %3 (player moved quadrants)", groupId _grp, (["NE", "SE", "SW", "NW"] select _oldQ), (["NE", "SE", "SW", "NW"] select _nq)];
                };
            };
        } forEach _defenders;
    };

    private _ongoingQ = { (_x getVariable ["MISSION_CORE_ORDER", ""]) == "engage" && { (_x getVariable ["MISSION_CORE_QUAD_MARKER", ""]) == _markerName } } count _defenders;
    diag_log format ["AI COMMANDER: QUAD %1 targets=%2 defenders=%3 staged/backlog=%4 releasePerTick=%5 onQuadrant=%6 dispatched=%7", _markerName, count _targets, count _defenders, count MISSION_CORE_QUAD_BACKLOG, _releasePerTick, _ongoingQ, MISSION_CORE_QUAD_SENT getOrDefault [_markerName, 0]];

    true
};

// Hunt-sighting quadrant update: when a hunt contingent ACTUALLY re-sights a player (real LOS
// contact - not the stale LKP), that is fresh shared intel. Repoint every quadrant order currently
// held ("marked") for that player's contested marker onto his fresh position, even if he only crept
// WITHIN the same quadrant - the re-eval step above only repoints when he crosses into a DIFFERENT
// quadrant, so without this a player who hides in one sector would keep every sweep box locked onto
// where he used to stand. Fires only on a real hunt sighting (rare), so the geometry cost is fine.
MISSION_CORE_fnc_updateQuadrantsForPlayer = {
    params ["_player", "_pos"];
    if (isNull _player) exitWith {};
    if (isNil "MISSION_CORE_SPAWNED_GROUPS") exitWith {};
    if (isNil "MISSION_CORE_CACHED_POSITIONS") exitWith {};
    private _zones = [EAST] call MISSION_CORE_fnc_getContestedMarkers;
    if (count _zones == 0) exitWith {};
    // The single contested zone this player drives (closest of the side's zones to the sight).
    private _zone = _zones select 0;
    private _zd = _zone select 1 distance2D _pos;
    { private _d = _x select 1 distance2D _pos; if (_d < _zd) then { _zd = _d; _zone = _x; }; } forEach _zones;
    private _markerName = _zone select 0;
    private _idx = MISSION_CORE_CACHED_POSITIONS findIf { (_x select 0) == _markerName };
    if (_idx < 0) exitWith {};
    private _loc = MISSION_CORE_CACHED_POSITIONS select _idx;
    private _locPos = _loc select 1;
    private _size = [200, 200];
    if (count _loc > 8) then { private _sz = _loc select 8; if (count _sz > 0) then { _size = _sz; }; };
    private _dir = if (count _size > 2) then { _size select 2 } else { 0 };
    private _shape = markerShape _markerName;
    if (_shape == "ICON") then { _shape = "ELLIPSE"; };
    private _qi = [_locPos, _size, _dir, _pos, _shape] call MISSION_CORE_fnc_quadrantOf;
    private _nq = _qi select 0;
    private _qt = [_locPos, _size, _dir, _pos, (_qi select 1), _shape] call MISSION_CORE_fnc_quadrantTarget;
    // Mirror the re-eval tiering: the repointed squad already holds "engage" on this marker, so it
    // counts itself in _pat and keeps its own patrol tier (no re-tiering from the move).
    private _pat = { (_x getVariable ["MISSION_CORE_ORDER", ""]) == "engage" && { (_x getVariable ["MISSION_CORE_QUAD_MARKER", ""]) == _markerName } && { (_x getVariable ["MISSION_CORE_QUAD_Q", -1]) == _nq } } count MISSION_CORE_SPAWNED_GROUPS;
    private _upd = 0;
    {
        private _grp = _x;
        if (isNull _grp || { { alive _x } count units _grp == 0 }) then { continue; };
        if ((_grp getVariable ["MISSION_CORE_ORDER", ""]) != "engage") then { continue; };
        if ((_grp getVariable ["MISSION_CORE_QUAD_MARKER", ""]) != _markerName) then { continue; };
        [_grp, getPosATL _player, _markerName, _nq, _qt select 1, true, _locPos, _size, _dir, (0.9 ^ (_pat - 1)), _shape] call MISSION_CORE_fnc_issueQuadrantSAD;
        _upd = _upd + 1;
    } forEach MISSION_CORE_SPAWNED_GROUPS;
    if (_upd > 0) then {
        diag_log format ["AI COMMANDER: QUAD hunt-sight repointed %1 group(s) for %2 at %3 onto %4", _upd, (name _player), _markerName, (["NE", "SE", "SW", "NW"] select _nq)];
    };
};

// Issue AWARE patrol waypoints over a marker (center + size), NORMAL speed, YELLOW combat mode.
// Used by footArrival instead of SAD-ing the marker center: a re-tasked squad that reaches a marker
// with no active quadrant battle patrols the whole area alert rather than clumping on the center.
MISSION_CORE_fnc_issuePatrolAware = {
    params ["_grp", "_center", ["_size", [250, 250]]];
    // Never overwrite a squad already committed to a quadrant patrol/engagement - that group stays
    // on its sector sweep. Only free/patrolling squads get the full-marker aware patrol. Same for
    // a group the player-hunt director committed.
    if ((_grp getVariable ["MISSION_CORE_ORDER", ""]) == "engage" && { (_grp getVariable ["MISSION_CORE_QUAD_MARKER", ""]) != "" }) exitWith {};
    if ((_grp getVariable ["MISSION_CORE_HUNT_KEY", ""]) != "") exitWith {};
    private _ma = _size select 0; if (_ma <= 0) then { _ma = 250; };
    private _mb = if (count _size > 1) then { _size select 1 } else { _ma }; if (_mb <= 0) then { _mb = _ma; };
    private _mDir = if (count _size > 2) then { _size select 2 } else { 0 };
    // SMALL MARKER SPREAD: light-infra markers (outpost/powerplant/solar) are tiny - an alert
    // patrol must spread out over the terrain around the marker, not clump in the small box.
    if !(isNil "MISSION_CORE_CACHED_POSITIONS") then {
        private _locAt = [_center] call MISSION_CORE_fnc_getLocByPos;
        if (count _locAt > 2 && { [_locAt] call MISSION_CORE_fnc_isLightInfrastructure }) then {
            private _spreadR = ["lightInfraPatrolRadius", 300] call MISSION_CORE_fnc_tune;
            if (_ma < _spreadR) then { _ma = _spreadR; };
            if (_mb < _spreadR) then { _mb = _spreadR; };
        };
    };
    _grp setVariable ["MISSION_CORE_ORDER", ""];
    _grp setVariable ["MISSION_CORE_IDLE", false];
    _grp setVariable ["MISSION_CORE_PATROLLING", false];
    leader _grp setVariable ["MISSION_CORE_PATROLLING", false];
    _grp setFormation "WEDGE";
    _grp setCombatMode "YELLOW";
    _grp setBehaviour "AWARE";
    _grp setSpeedMode "NORMAL";
    [_grp] call MISSION_CORE_fnc_clearGroupWaypoints;
    private _count = 4 + floor (random 2);
    for "_i" from 1 to _count do {
        private _ang = random 360;
        // Patrol inside the marker: 40-90% of the half-axes so they stay within the area.
        private _ratio = 0.4 + random 0.5;
        private _ox = _ratio * _ma * cos _ang;
        private _oy = _ratio * _mb * sin _ang;
        private _rx = _ox * cos _mDir - _oy * sin _mDir;
        private _ry = _ox * sin _mDir + _oy * cos _mDir;
        private _wpPos = [(_center select 0) + _rx, (_center select 1) + _ry, 0];
        _wpPos = [_wpPos, _center] call MISSION_CORE_fnc_safeWaypointPos;
        private _wp = _grp addWaypoint [_wpPos, 30];
        _wp setWaypointType "MOVE";
        _wp setWaypointSpeed "NORMAL";
        _wp setWaypointBehaviour "AWARE";
    };
    private _wpC = _grp addWaypoint [_center, 0];
    _wpC setWaypointType "CYCLE";
    _wpC setWaypointSpeed "NORMAL";
    _wpC setWaypointBehaviour "AWARE";
    private _wps = waypoints _grp;
    if (count _wps > 0) then {
        private _start = _wps select 0;
        { if (waypointType _x != "CYCLE") exitWith { _start = _x; }; } forEach _wps;
        _grp setCurrentWaypoint _start;
    };
};

// Post-arrival decision for a re-tasked foot squad that just reached a contested marker (by truck
// unload or on-foot advance). It never SADs the center:
//   - If the commander's quadrant engagement is ALREADY active for this marker (battle running and
//     which marker it drives the split), leave the squad eligible (empty order) so the commander's
//     quadrant loop assigns a per-quadrant SAD on a later tick.
//   - Otherwise hand it AWARE patrol waypoints (normal speed, yellow) over the marker.
MISSION_CORE_fnc_footArrival = {
    params ["_grp", "_targetPos", "_side", ["_size", [250, 250]]];
    if (isNull _grp || { { alive _x } count units _grp == 0 }) exitWith {};
    // Resolve the target marker name + true size from the location cache.
    private _markerName = "";
    if !(isNil "MISSION_CORE_CACHED_POSITIONS") then {
        private _idx = MISSION_CORE_CACHED_POSITIONS findIf { (_x select 1) distance2D _targetPos < 60 };
        if (_idx >= 0) then {
            _markerName = (MISSION_CORE_CACHED_POSITIONS select _idx) select 0;
            private _sz = (MISSION_CORE_CACHED_POSITIONS select _idx) select 8;
            if (count _sz > 0) then { _size = _sz; };
        };
    };
    // Claim this squad for this marker. The commander's commitToBattle must NOT re-route a group
    // that is already dispatched to this contested marker (no matter what its current ORDER is,
    // since the defense watchdog can flip it to "defend") - otherwise it yanks the squad back to
    // sendCounterAttack every couple of minutes and the fight never settles. Quadrant/patrol own it.
    _grp setVariable ["MISSION_CORE_DISPATCH_MARKER", _markerName];
    // Always keep the squad MOVING on an AWARE patrol while it waits (never idle): whether it is
    // only patrolling (no active battle) or waiting for its quadrant turn, the group sweeps the
    // marker aware at normal speed. If the quadrant loop is active, its issueQuadrantSAD clears
    // these patrol waypoints and hands it a MOVE+SAD to the player's marker-edge target when the
    // squad's release slot comes up.
    [_grp, _targetPos, _size] call MISSION_CORE_fnc_issuePatrolAware;
};
