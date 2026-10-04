//
// REDFOR PLAYER-HUNT DIRECTOR (one thread)
//
// Watches BLUFOR players near REDFOR markers. A hunt only starts when REDFOR has ACTUALLY seen the
// player - a real LOS sighting (knowsAbout >= 0.7) that is still fresh (<60s), or a faint 0.1
// awareness that is only usable while that real contact is still recent. Proximity alone never
// triggers one. The closest REDFOR markers then dispatch a HUNT contingent to the player's last
// known position:
//
//   - Player in a tank       -> an MBT contingent (tank vs tank); if no armor capacity, a bigger
//                               infantry + AT contingent instead.
//   - Player in a vehicle    -> a gun-capable vehicle contingent (APC or gun truck / MBT fallback);
//                               if none can be fielded, a bigger foot contingent.
//   - Player on foot / none  -> a foot squad (bigger = 2 squads when the nearest marker is far).
//
// The contingent rides to the last known position, unloads, then SWEEPS along the heading the
// player was last moving - from the time it ARRIVES at the LKP - for 10 minutes.
//
// INFORMATION MODEL (no god-view):
//   - Knowledge is sampled from each REDFOR group's ALIVE LEADER ONLY - never from every unit.
//   - Contact requires REAL line of sight (terrain/building LOS check) AND knowsAbout > 0.7.
//   - Shared garrison intel: any REDFOR group LEADER with an actual sighting reports
//     [pos, heading, time] into MISSION_CORE_HUNT_INTEL; it decays after ~60s.
//   - While sweeping, groups steer ONLY toward a <60s-old shared sighting; otherwise they walk
//     the original extrapolated line blind. They NEVER steer toward the player's live position.
//   - On re-spot the group engages the position where it can actually see the player; when he
//     escapes again it resumes sweeping from where it saw him last + that recorded heading.
//   - No raw-distance wallhack triggers (only a 30m "stepped on him" bump).
//
// With no re-contact it retreats to the closest same-side marker and despawns on arrival (driver
// + truck cleaned up too). REDFOR side only - BLUFOR AI keeps its assault-based behavior.

// True when unit _from has a clear line of sight to unit _to (no building or terrain in between).
// Needed so hunt AI can never "see" a player through a wall or hill - raw distance is not sight.
MISSION_CORE_fnc_hasLOS = {
    params ["_from", "_to"];
    if (isNull _from || { isNull _to }) exitWith { false };
    private _a = eyePos _from;
    private _b = eyePos _to;
    // lineIntersects already tests terrain AND objects (with _from/_to ignored), returning
    // true when the LOS is blocked. No separate terrainIntersectASL call is needed.
    !(lineIntersects [_a, _b, _from, _to])
};

// True when a REDFOR unit currently SEES the player (knowsAbout above the tune contact threshold
// AND a real terrain/building LOS check). This is the only "contact" that generates shared intel.
MISSION_CORE_fnc_huntSeesPlayer = {
    params ["_u", "_p"];
    if (isNull _u || { isNull _p }) exitWith { false };
    (alive _u && { alive _p } && { _u knowsAbout _p > (["huntContactKnows", 0.7] call MISSION_CORE_fnc_tune) } && { [_u, _p] call MISSION_CORE_fnc_hasLOS })
};

MISSION_CORE_fnc_playerHunt = {
    diag_log "PLAYER HUNT: director started";
    MISSION_CORE_HUNT_ACTIVE = createHashMap;     // player -> hunt group
    MISSION_CORE_PLAYER_LKP = createHashMap;      // player -> [pos, heading, lastSeen]

    private _side = EAST;                          // REDFOR hunts the BLUFOR player
    private _enemySide = WEST;
    private _sideVar = "MISSION_CORE_REDFOR";
    private _factionData = MISSION_CORE_REDFOR_DATA;
    private _detectRange = ["huntDetectRange", 1200] call MISSION_CORE_fnc_tune;

    while { true } do {
        sleep (20 + random 10);
        if (isNil "MISSION_CORE_SPAWNED_LOCATIONS") then { continue; };
        if (isNil "MISSION_CORE_CACHED_POSITIONS") then { continue; };
        private _players = allPlayers select { alive _x && { side _x == _enemySide } };
        // ASSAULT LEADER HUNTS: released/active BLUFOR attack-group leaders are also hunted
        // alongside the player when the toggle is enabled.
        if ((["assaultLeaderHunts", 1] call MISSION_CORE_fnc_tune) > 0 && { !isNil "MISSION_CORE_ATTACK_GROUPS" }) then {
            {
                private _data = _y;
                if ((_data select 5) != "active") then { continue; };
                private _ag = _data select 0;
                if (isNull _ag) then { continue; };
                private _rep = (units _ag select { alive _x }) param [0, objNull];
                if (!isNull _rep && { side _rep == _enemySide }) then { _players pushBack _rep; };
            } forEach MISSION_CORE_ATTACK_GROUPS;
        };
        // MULTIPLAYER RELAY: client-spawned assault leaders are hunted too (fn_assaultRelay.sqf).
        if ((["assaultLeaderHunts", 1] call MISSION_CORE_fnc_tune) > 0 && { !isNil "MISSION_CORE_ATTACK_GROUPS_RELAY" }) then {
            {
                private _data = _y;
                if ((_data select 5) != "active") then { continue; };
                private _ag = _data select 0;
                if (isNull _ag) then { continue; };
                private _rep = (units _ag select { alive _x }) param [0, objNull];
                if (!isNull _rep && { side _rep == _enemySide }) then { _players pushBack _rep; };
            } forEach MISSION_CORE_ATTACK_GROUPS_RELAY;
        };
        if (count _players == 0) then { continue; };
        // Snapshot this side's units once per tick and reuse for all players. Avoids an allUnits
        // refetch per player (the list only changes between frames, not mid-loop-body).
        private _snapUnits = allUnits select { side _x == _side };
        // Knowledge of the player is sampled from each REDFOR group's ALIVE LEADER ONLY - never from
        // every unit. The group commander's own sighting is what counts as command-level contact, so
        // a grunt's faint curiosity can no longer drag a whole contingent across the map.
        private _snapLeaders = [];
        {
            private _g = group _x;
            if (isNull _g) then { continue; };
            private _ldr = leader _g;
            if (isNull _ldr) then { continue; };
            if !(alive _ldr) then { continue; };
            if (_snapLeaders findIf { _x == _ldr } == -1) then { _snapLeaders pushBack _ldr; };
        } forEach _snapUnits;

        // Spawned REDFOR markers = the "eyes" that eventually spot a player loitering nearby.
        private _redSpawned = MISSION_CORE_CACHED_POSITIONS select {
            (_x select 4) == _side && { MISSION_CORE_SPAWNED_LOCATIONS getOrDefault [(_x select 0), false] }
        };
        if (count _redSpawned == 0) then { continue; };

        {
                    private _p = _x;
            private _pKey = str _p;   // hashmap keys: strings only (objects are not valid keys)
            private _pPos = getPos _p;
            private _entry = MISSION_CORE_PLAYER_LKP getOrDefault [_pKey, [_pPos, 0, 0]];
            _entry params ["_lpos", "_lhead", "_lseen"];

            // A player counts as "seen" when inside _detectRange of any spawned REDFOR marker.
            private _near = (_redSpawned findIf { (_x select 1) distance2D _pPos < _detectRange }) != -1;

            // A CURRENT live sighting: a REDFOR group LEADER with a real LOS + knowsAbout saw the
            // player this tick. This is a genuine "we know where he is right now" - enough to hunt
            // even when the player is not near a spawned marker (e.g. a patrol or convoy leader
            // spotted him).
            private _liveSight = (_snapLeaders findIf {
                [_x, _p] call MISSION_CORE_fnc_huntSeesPlayer
            }) != -1;

            // Always track position + heading for everyone (so a fresh sweep still knows which
            // way the player was heading) - the dwell only decides whether a hunt dispatches.
            // Heading = compass direction the player moved from _lpos to _pPos.
            private _heading = 0;
            if (_lpos distance2D _pPos > 10) then { _heading = _lpos getDir _pPos; };
            MISSION_CORE_PLAYER_LKP set [_pKey, [_pPos, _heading, time]];

            // ---- Shared garrison intel ----
            // Any REDFOR unit with a REAL line of sight and knowsAbout > 0.7 reports a
            // contact. The intel is a time-stamped position of a legitimately-sighted spot.
            if (isNil "MISSION_CORE_HUNT_INTEL") then { MISSION_CORE_HUNT_INTEL = createHashMap; };
            if (_liveSight) then {
                MISSION_CORE_HUNT_INTEL set [_pKey, [_pPos, _heading, time]];
            };

            // Hunts only dispatch toward a player the REDFOR genuinely knows of. Proximity to a
            // spawned marker is the norm, but a current live LOS sighting is always sufficient on
            // its own - the enemy KNOWS where the player is right now and will hunt him anywhere.
            if (!_near && { !_liveSight }) then { continue; };

            // ---- HUNT REQUIRES AN ACTUAL SIGHTING ----
            // Proximity alone never starts a hunt, and a FAINT awareness is never enough on its
            // own: a 0.1 knowsAbout only counts while a real LOS contact (knowsAbout >= 0.7) is
            // still fresh (<60s). No real contact = no hunt.
            private _intel = MISSION_CORE_HUNT_INTEL getOrDefault [_pKey, []];
            private _intelFresh = count _intel >= 3 && { (time - (_intel select 2)) <= (["huntIntelDecay", 60] call MISSION_CORE_fnc_tune) };
            // Strongest current awareness of the player - sampled from group leaders only. Drives how
            // precise the reported position is. Full contact = exact spot, faint 0.1 = a wide drift,
            // never a god-view pin.
            private _maxKnows = 0;
            {
                if (alive _x && { _x distance2D _pPos < (_detectRange + 300) }) then {
                    _maxKnows = _maxKnows max (_x knowsAbout _p);
                };
            } forEach _snapLeaders;
            if (!_intelFresh && { !_liveSight }) then { continue; };

            // Already hunting this player - living contingents are on the way / sweeping.
            private _active = MISSION_CORE_HUNT_ACTIVE getOrDefault [_pKey, []];
            private _living = _active select { !isNull _x && { { alive _x } count units _x > 0 } };
            if (count _living > 0) then { MISSION_CORE_HUNT_ACTIVE set [_pKey, _living]; continue; };

            // Aim the hunt at a position the REDFOR genuinely knows. When a unit has a CURRENT live
            // LOS sighting this tick, that legitimately-sighted spot is the player's own position
            // (no god-view - a real enemy just laid eyes on him). Otherwise fall back to the last
            // real sighting (_intel) or the previously-recorded LKP. The lower the current
            // awareness the more imprecise that reported spot is - a 0.1 faint never gives an
            // exact player position, only a wide drift around the last known area.
            private _aimPos = _lpos;
            private _aimHead = _heading;
            if (_liveSight || _intelFresh) then { _aimPos = _intel select 0; _aimHead = _intel select 1; };
            private _contactKnows = ["huntContactKnows", 0.7] call MISSION_CORE_fnc_tune;
            private _faintKnows = ["huntFaintKnows", 0.1] call MISSION_CORE_fnc_tune;
            private _weakFrac = 1 - ((_maxKnows - _faintKnows) / (_contactKnows - _faintKnows));
            _weakFrac = (_weakFrac max 0) min 1;
            private _errR = _weakFrac * (["huntFaintPosError", 250] call MISSION_CORE_fnc_tune);
            _aimPos = [(_aimPos select 0) + (_errR * (random 2 - 1)), (_aimPos select 1) + (_errR * (random 2 - 1)), 0];
            [_p, _pKey, _aimPos, _aimHead, _side, _sideVar, _factionData] call MISSION_CORE_fnc_huntDispatch;
        } forEach _players;
    };
};

// Pick the CLOSEST REDFOR markers as hunt sources and dispatch up to huntMaxContingents squads
// at the player's last known position - so several nearby towns converge instead of just one.
// No source may be the marker the player is standing inside (a squad that spawns 0m away is absurd),
// and only markers within huntSourceMaxRange of the LKP join the hunt.
MISSION_CORE_fnc_huntDispatch = {
    params ["_player", "_playerKey", "_lkp", "_heading", "_side", "_sideVar", "_factionData"];
    if (isNil "MISSION_CORE_HUNT_ACTIVE") then { MISSION_CORE_HUNT_ACTIVE = createHashMap; };

    private _cands = MISSION_CORE_CACHED_POSITIONS select { (_x select 4) == _side };
    if (count _cands == 0) exitWith {};
    // PERMANENT RULE: Powerplant / Solar are static tiny garrisons - they never dispatch hunt contingents.
    _cands = _cands select { !([_x] call MISSION_CORE_fnc_isLightInfrastructure) };
    // AMMO: a source marker with <30% ammo is defensive and never spares men to hunt. At 0 ammo
    // it is fully passive. Only markers with enough ammo may field a hunt contingent.
    _cands = _cands select { ([(_x select 0)] call MISSION_CORE_fnc_getAmmoFraction) >= 0.3 };
    // RETREAT GATE (PERMANENT RULE): once a source marker's garrison has retreated (crossed its
    // determination casualty threshold) it stops fielding hunt contingents - the hunt gate keeps
    // spawning from a marker only until that marker retreats, never after it has given up.
    _cands = _cands select { isNil "MISSION_CORE_RETREATED" || { !((MISSION_CORE_RETREATED getOrDefault [(_x select 0), false])) } };
    private _maxN = ["huntMaxContingents", 3] call MISSION_CORE_fnc_tune;
    private _srcRange = ["huntSourceMaxRange", 2500] call MISSION_CORE_fnc_tune;
    // Exclude markers that CONTAIN the aim point (you can't attack your own yard with 0m run).
    private _srcCands = _cands select {
        private _p = _x select 1;
        private _s = if (count _x > 8) then { _x select 8 } else { [200, 200] };
        private _sa = ((_s select 0) max 1);
        private _sb = if (count _s > 1) then { ((_s select 1) max 1) } else { _sa };
        private _sd = if (count _s > 2) then { _s select 2 } else { 0 };
        private _dx = (_lkp select 0) - (_p select 0);
        private _dy = (_lkp select 1) - (_p select 1);
        private _rx = _dx * cos _sd - _dy * sin _sd;
        private _ry = _dx * sin _sd + _dy * cos _sd;
        ((_rx * _rx) / (_sa * _sa) + (_ry * _ry) / (_sb * _sb)) > 1
    };
    if (count _srcCands == 0) then { _srcCands = _cands; };  // all else fails: any marker
    // Sort nearest-first, keep only markers within the source range, cap to max contingents.
    _srcCands = [_srcCands, [], { (_x select 1) distance2D _lkp }, "ASCEND"] call BIS_fnc_sortBy;
    _srcCands = _srcCands select { (_x select 1) distance2D _lkp <= _srcRange };
    _srcCands resize (_maxN min (count _srcCands));

    // COUNTER-ATTACK CURVE PACING (HUNT GATE, PERMANENT RULE): a source marker ACTIVELY
    // supporting a live counter-attack (a contested zone within neighbor range whose
    // reinforcement pool is NOT exhausted) paces its hunt dispatches on the same cubic intensity
    // curve as its reinforcement spawns - fast while the zone's pool is fresh, losing steam as
    // it drains. A marker with no counter-attack to support keeps its hunt gate open at the
    // director's normal cadence until it retreats (retreat gate above).
    if (isNil "MISSION_CORE_REINF_EXHAUSTED") then { MISSION_CORE_REINF_EXHAUSTED = createHashMap; };
    if (isNil "MISSION_CORE_REINF_SENT") then { MISSION_CORE_REINF_SENT = createHashMap; };
    // TWO SEPARATE QUESTIONS, TWO SEPARATE VARS.
    // (1) contested NAMES - MISSION_CORE_CONTESTED only, written solely by fn_isMarkerContested.
    private _zoneList = if (isNil "MISSION_CORE_CONTESTED") then { [] } else { keys MISSION_CORE_CONTESTED };
    // (2) POSITIONS - MISSION_CORE_CACHED_POSITIONS, joined by name. The nearest-zone math below
    // needs each contested marker's position; that is geometry, not contested state, so it is read
    // from the cache rather than from a contested helper. The join forms no opinion about contested.
    private _liveZones = [];
    if (!isNil "MISSION_CORE_CACHED_POSITIONS") then {
        {
            private _zName = _x;
            if (MISSION_CORE_REINF_EXHAUSTED getOrDefault [_zName, false]) then { continue; };
            private _zIdx = MISSION_CORE_CACHED_POSITIONS findIf { (_x select 0) == _zName };
            if (_zIdx >= 0) then { _liveZones pushBack (MISSION_CORE_CACHED_POSITIONS select _zIdx); };
        } forEach _zoneList;
    };
    if (isNil "MISSION_CORE_HUNT_COOLDOWN") then { MISSION_CORE_HUNT_COOLDOWN = createHashMap; };

    private _dispatched = 0;
    {
        private _src = _x;
        private _srcName = _src select 0;
        private _srcPos = _src select 1;
        private _srcImp = _src select 7;
        private _srcSize = if (count _src > 8) then { _src select 8 } else { [200, 200] };
        private _srcD = _srcPos distance2D _lkp;

        // Nearest live counter-attack zone near this source (within neighbor reinforce range).
        private _nearZn = "";
        private _nearD = 1e10;
        { private _d = (_x select 1) distance2D _srcPos; if (_d < _nearD) then { _nearD = _d; _nearZn = _x select 0; }; } forEach _liveZones;
        private _supporting = (_nearZn != "");
        private _pace = 0;
        if (_supporting) then {
            // Intense-zone progress (men sent / budget) drives the cubic curve gap, mirroring
            // fn_neighborCounterAttack's own curve (0.2s fresh -> ~5s near exhausted). Hunt pacing
            // scales the gap up to the director's cadence via huntCurvePace.
            private _sentTotal = MISSION_CORE_REINF_SENT getOrDefault [_nearZn, 0];
            private _pool = 1;
            private _idx = MISSION_CORE_CACHED_POSITIONS findIf { (_x select 0) == _nearZn };
            if (_idx >= 0) then {
                private _zp = MISSION_CORE_CACHED_POSITIONS select _idx;
                private _budgetFrac = ([_zp] call MISSION_CORE_fnc_getMarkerDetermination) select 2;
                private _nb = [_nearZn, (_zp select 1), _side, _zoneList] call MISSION_CORE_fnc_getMarkerNeighbors;
                private _sum = 0;
                { _sum = _sum + ([(_x select 7)] call MISSION_CORE_fnc_markerCapacity); } forEach _nb;
                _pool = round (_sum * _budgetFrac);
            };
            private _frac = (((_sentTotal / (_pool max 1)) min 1) max 0);
            private _gap = 0.2 + ((_frac * _frac * _frac) * 4.8);
            _pace = _gap * (["huntCurvePace", 4] call MISSION_CORE_fnc_tune);
            diag_log format ["PLAYER HUNT: %1 source %2 follows counter-attack curve for %3 (frac=%4 gap=%5s cd=%6s)", _side, _srcName, _nearZn, _frac, _gap, round _pace];
        };

        // PER-MARKER HUNT CAP, checked before anything is queued. huntSpawnContingent re-checks this
        // (it is the authority - the queue can outlive this tick), but skipping the enqueue here
        // keeps a saturated marker from filling the queue with jobs that are guaranteed to no-op.
        private _maxPerMarker = ["huntMaxPerMarker", 3] call MISSION_CORE_fnc_tune;
        private _liveHunts = [_srcName] call MISSION_CORE_fnc_huntMarkerLive;
        if (count _liveHunts >= _maxPerMarker) then {
            diag_log format ["PLAYER HUNT: %1 source %2 skipped - already running %3 live hunt(s), per-marker cap %4", _side, _srcName, count _liveHunts, _maxPerMarker];
            continue;
        };

        // Curve cooldown gate: while the marker's next allowed hunt time has not arrived it
        // dispatches nothing toward ANY player (the marker is mid-reinforcement-tempo).
        private _cd = MISSION_CORE_HUNT_COOLDOWN getOrDefault [_srcName, -1e10];
        if (time < _cd) then {
            diag_log format ["PLAYER HUNT: %1 source %2 paused - counter-attack curve cooldown (%.1fs left)", _side, _srcName, _cd - time];
            continue;
        };

        // A player hunt is the LOWEST-priority spawn on the map. It used to be spawned inline here,
        // which meant it bypassed MISSION_CORE_SPAWN_QUEUE completely and could put a fresh MBT or a
        // conjured squad on the field while a marker reinforcement was already queued and waiting
        // for those same foot/armor slots. It is now QUEUED at priority -2 (fn_spawnQueueLoop),
        // below the armor-critical -1 jump, so every other queue spawn trumps it and it only goes
        // first when the queue is otherwise empty.
        //
        // All the bookkeeping that used to follow this call - hunt cooldown, ammo cost, HUNT_ACTIVE
        // registration, the HUNT_TARGET/HUNT_KEY vars, huntSweep and the dispatch log - has MOVED
        // into MISSION_CORE_fnc_queuedHuntContingent. It cannot stay here: the group does not exist
        // at this point any more, so there is nothing to tag or sweep.
        ["MISSION_CORE_fnc_queuedHuntContingent", format ["hunt_%1_%2", _srcName, _playerKey], [_player, _lkp, _heading, _side, _sideVar, _factionData, _srcName, _srcPos, _srcSize, _srcImp, _srcD, _playerKey, _pace]] call MISSION_CORE_fnc_enqueueSpawn;
        _dispatched = _dispatched + 1;
    } forEach _srcCands;
    diag_log format ["PLAYER HUNT: %1 queued %2 contingent(s) toward %3 (lowest priority - trumped by every other queue spawn)", _side, _dispatched, _lkp];
};

// Live hunt contingents fielded by ONE source marker.
//
// huntMaxContingents (above) caps how many SOURCE MARKERS may answer a single dispatch event - it
// bounds one sweep of the director, not how many hunts one garrison can have running. Without a
// separate per-marker ceiling the same marker answered every director tick with another contingent
// and hunts stacked on it indefinitely.
//
// The registry is pruned on every READ rather than by an explicit unregister: a contingent that
// died, or whose sweep finished (fn_huntSweep clears MISSION_CORE_HUNT_KEY when it disbands), frees
// its slot the next time anyone asks. So there is no path where a finished hunt keeps a slot busy.
if (isNil "MISSION_CORE_MARKER_HUNTS") then { MISSION_CORE_MARKER_HUNTS = createHashMap; };
MISSION_CORE_fnc_huntMarkerLive = {
    params ["_srcName"];
    if (isNil "MISSION_CORE_MARKER_HUNTS") then { MISSION_CORE_MARKER_HUNTS = createHashMap; };
    private _list = MISSION_CORE_MARKER_HUNTS getOrDefault [_srcName, []];
    private _live = [];
    {
        private _g = _x;
        // Alive AND still a hunt. A null handle, a wiped group, or one whose sweep has ended (its
        // HUNT_KEY was cleared, or it was re-tasked back to garrison duty) is no longer a hunt.
        private _isHunt = (_g getVariable ["MISSION_CORE_HUNT_KEY", ""]) != "";
        if (!isNull _g && { count (units _g select { !isNull _x && { alive _x } }) > 0 } && { _isHunt }) then {
            _live pushBack _g;
        };
    } forEach _list;
    if (count _live > 0) then { MISSION_CORE_MARKER_HUNTS set [_srcName, _live]; } else { MISSION_CORE_MARKER_HUNTS deleteAt _srcName; };
    _live
};

MISSION_CORE_fnc_huntMarkerRegister = {
    params ["_srcName", "_grp"];
    if (isNil "MISSION_CORE_MARKER_HUNTS") then { MISSION_CORE_MARKER_HUNTS = createHashMap; };
    private _list = [_srcName] call MISSION_CORE_fnc_huntMarkerLive;
    _list pushBack _grp;
    MISSION_CORE_MARKER_HUNTS set [_srcName, _list];
    count _list
};

// Spawn the contingent for one hunt. Returns the group (grpNull if nothing could be fielded).
MISSION_CORE_fnc_huntSpawnContingent = {
    params ["_player", "_lkp", "_heading", "_side", "_sideVar", "_factionData", "_srcName", "_srcPos", "_srcSize", "_srcImp", "_srcD"];

    // ---- REINFORCEMENT TRUMPS THE HUNT: no contingent of any kind while this marker owes a fight ----
    // This gate sits ABOVE the threat ladder on purpose. A hunt is the lowest-priority use of a
    // marker's men - discretionary pressure against one player, while a contested marker is the
    // mission's actual fight - so while the source still owes reinforcement it fields NOTHING toward
    // a player: no re-tasked garrison squad, no conjured foot squad, no MBT, no APC. Putting the gate
    // here rather than inside the re-task branch below is what makes the armor answers trump too; a
    // gate placed at the re-task call would leave MBT/APC ungated, and one placed inside
    // MISSION_CORE_fnc_claimIdleGarrison would silently become part of the shared garrison rules for
    // every future commander subsystem that draws squads from that pool.
    //
    // fn_markerHasReinforceNeed asks MISSION_CORE_fnc_providerBudget - the dispatcher's own
    // arithmetic - so this cannot drift from what fn_neighborCounterAttack will decide.
    //
    // The source row is re-read from the cache here rather than passed in: the queue outlives the
    // director tick that queued this job, so any budget read at enqueue time would be stale by the
    // moment these men were actually spent.
    private _srcRow = [];
    if (!isNil "MISSION_CORE_CACHED_POSITIONS") then {
        _srcRow = MISSION_CORE_CACHED_POSITIONS select { (_x select 0) == _srcName };
    };
    if (([_srcRow param [0, []], _side] call MISSION_CORE_fnc_markerHasReinforceNeed)) exitWith {
        diag_log format ["PLAYER HUNT: %1 source %2 held - it still owes reinforcement to a contested marker, so it fields no hunt contingent (no re-task, no foot, no armor)", _side, _srcName];
        grpNull
    };

    private _vehMap = _factionData select 7;
    private _mbtClasses = _vehMap getOrDefault ["mbt", []];
    private _apcClasses = _vehMap getOrDefault ["apc", []];

    // PER-MARKER HUNT CAP. Sits below the reinforcement gate (a marker owing a fight is still held
    // for that, which is the stronger rule) and above the threat ladder, so a marker already running
    // its full allowance spends nothing on armour templates, vehicle-column lookups or a doomed
    // spawnGroup call. SQF has no `return`, so the exitWith is written out - grpNull is this
    // function's normal "nothing fielded" value, which the single caller already handles.
    private _maxPerMarker = ["huntMaxPerMarker", 3] call MISSION_CORE_fnc_tune;
    private _liveHunts = [_srcName] call MISSION_CORE_fnc_huntMarkerLive;
    if (count _liveHunts >= _maxPerMarker) exitWith {
        diag_log format ["PLAYER HUNT: %1 source %2 held - already running %3 live hunt(s), per-marker cap %4", _side, _srcName, count _liveHunts, _maxPerMarker];
        grpNull
    };

    private _playerVeh = vehicle _player;
    private _inTank = _playerVeh != _player && { _playerVeh isKindOf "Tank" };
    private _inVeh = _playerVeh != _player && { !_inTank };
    private _spawnPos = [_srcPos, _srcSize, 30, random 360] call MISSION_CORE_fnc_findVehiclePos;
    _spawnPos = [_spawnPos] call MISSION_CORE_fnc_ensureLandPos;

    // SPAWN SAFETY: a hunt contingent is never CONJURED inside a player's sight bubble. Re-used
    // garrison groups already exist on the field (nothing new pops in), but every FRESH spawn
    // below - fallback foot squad, MBT, APC - must materialize at least huntSpawnMinPlayerDist
    // from any alive player. If this source sits too close to a player, the contingent is simply
    // not fielded here rather than popping into view at their feet.
    private _pNear = 1e10;
    { _pNear = _pNear min (_spawnPos distance2D _x); } forEach (allPlayers select { alive _x });
    private _spawnSafe = _pNear >= (["huntSpawnMinPlayerDist", 500] call MISSION_CORE_fnc_tune);

    private _grp = grpNull;

    // 1) Tank threat - field an MBT (respects the armor cap), else a bigger AT-capable squad.
    if (_inTank && { _spawnSafe } && { count _mbtClasses > 0 && { [_side, "mbt", _lkp, _srcImp] call MISSION_CORE_fnc_armorCapOpen } }) then {
        _grp = [_side, selectRandom _mbtClasses, "mbt", _spawnPos, 0, _srcImp, _lkp] call MISSION_CORE_fnc_spawnDefenseVehicle;
    };

    // 2) Vehicle threat - gun-capable vehicle (APC, else MBT).
    if (isNull _grp && { _spawnSafe && { _inVeh } }) then {
        private _vehClass = "";
        if (count _apcClasses > 0 && { [_side, "mech", _lkp, _srcImp] call MISSION_CORE_fnc_armorCapOpen }) then { _vehClass = selectRandom _apcClasses; };
        if (_vehClass == "" && { count _mbtClasses > 0 && { [_side, "mbt", _lkp, _srcImp] call MISSION_CORE_fnc_armorCapOpen } }) then { _vehClass = selectRandom _mbtClasses; };
        if (_vehClass != "") then {
            _grp = [_side, _vehClass, if (_vehClass isKindOf "Tank") then { "mbt" } else { "mech" }, _spawnPos, 0, _srcImp, _lkp] call MISSION_CORE_fnc_spawnDefenseVehicle;
        };
    };

    // 3) Foot threat / fallbacks - an infantry squad.
    //    PERMANENT RULE (hunt sourcing): hunt forces are drawn from units ALREADY SPAWNED in the
    //    source marker's garrison - never fresh-created on top of the fielded army. This keeps hunt
    //    contingents inside the same budget as every other spawn (no unlimited bandit squads when
    //    the player keeps stepping in and out of sight). We pick an idle/patrolling foot REDFOR
    //    group rooted at this marker and re-task it to hunt; only if the marker fields no eligible
    //    group do we spawn one as a last resort.
    if (isNull _grp) then {
        // Drawing an already-fielded squad off a garrison is the AI COMMANDER's task, not an action
        // callable script's. MISSION_CORE_fnc_claimIdleGarrison owns the eligibility rules so any
        // commander subsystem can ask the same question of the same pool. It RE-TASKS and never
        // spawns: nothing is conjured and no manpower is drawn, which is why a hunt prefers it.
        _grp = [_sideVar, _srcName] call MISSION_CORE_fnc_claimIdleGarrison;
        if (!isNull _grp) then {
            diag_log format ["PLAYER HUNT: %1 re-tasked idle garrison %2 from %3 (re-tasked, not spawned - no manpower cost)", _side, groupId _grp, _srcName];
        } else {
            // Fallback: no eligible spawned garrison at this source - spawn one (respecting the
            // spawn-safety distance already checked above; a source hugging the player fields no
            // CONJURED contingent - the squad would materialize in his face).
            // PERMANENT RULE (global foot budget): the hunt fallback NEVER bypasses the per-side
            // foot-squad cap - it cannot float the map over budget.
            if (!_spawnSafe) then {
                diag_log format ["PLAYER HUNT: %1 source %2 skipped - spawn safety (%3m < %4m)", _side, _srcName, round _pNear, round (["huntSpawnMinPlayerDist", 500] call MISSION_CORE_fnc_tune)];
            } else {
                if (([_side] call MISSION_CORE_fnc_countFootSquads) < (["footSquadCapSquads", 10] call MISSION_CORE_fnc_tune)) then {
                    private _infPool = [(_factionData select 17)] call MISSION_CORE_fnc_getInfTemplates;
                    if (count _infPool > 0) then {
                        private _template = selectRandom _infPool;
                        // MANPOWER (marker pool, PERMANENT RULE): a CONJURED hunt squad is paid for
                        // out of the source marker's OWN MISSION_CORE_LOCATION_SUPPLY pool - 1 man =
                        // 1 supply, the same 1-for-1 rule that funds garrison replenishment. It is
                        // never free on top of the fielded army. An empty pool fields no conjured
                        // contingent (spare garrison squads can still be re-tasked - they already
                        // exist inside the budget). This makes repeated hunts draw down the same
                        // pool that funds the marker's garrison, so back-to-back sightings can never
                        // bankroll unlimited bandit squads.
                        private _manDraw = _template select 2;
                        if (isNil "MISSION_CORE_LOCATION_SUPPLY") then { MISSION_CORE_LOCATION_SUPPLY = createHashMap; };
                        private _supply = MISSION_CORE_LOCATION_SUPPLY getOrDefault [_srcName, 0];
                        if (_supply < _manDraw) then {
                            diag_log format ["PLAYER HUNT: %1 source %2 manpower pool %3 < %4 men - no conjured hunt squad", _side, _srcName, _supply, _manDraw];
                        } else {
                            _grp = [_template select 0, _spawnPos, _side, _factionData select 3, "AWARE", "NORMAL", _srcImp, _srcPos, _srcSize] call MISSION_CORE_fnc_spawnGroup;
                            if (!isNull _grp) then {
                                MISSION_CORE_LOCATION_SUPPLY set [_srcName, _supply - _manDraw];
                                diag_log format ["PLAYER HUNT: %1 conjured hunt squad %2 from %3 - manpower pool -%4 (remain=%5)", _side, groupId _grp, _srcName, _manDraw, _supply - _manDraw];
                                _grp setVariable ["MISSION_CORE_ORIGIN_MARKER", _srcName];
                                if (isNil "MISSION_CORE_SPAWNED_GROUPS") then { MISSION_CORE_SPAWNED_GROUPS = []; };
                                MISSION_CORE_SPAWNED_GROUPS pushBack _grp;
                            };
                        };
                    };
                } else {
                    diag_log format ["PLAYER HUNT: %1 source %2 skipped - global foot squad cap full (%3/%4)", _side, _srcName, round ([_side] call MISSION_CORE_fnc_countFootSquads), ["footSquadCapSquads", 10] call MISSION_CORE_fnc_tune];
                };
            };
        };
    };

    if (isNull _grp) exitWith { grpNull };
    _grp setVariable ["MISSION_CORE_ORDER", "hunt"];
    _grp setVariable ["MISSION_CORE_IDLE", false];
    _grp setVariable ["MISSION_CORE_HUNT_SOURCE", _srcName];
    _grp
};

// CLEAR HOUSES - when a hunt squad is searching near built-up areas (a player's last-known spot
// in a town, or after losing contact), fan the unitS out into DIFFERENT buildings to clear them:
// each living footman is doMove'd to a random distinct buildingPos, so the squad splits up and
// sweeps multiple houses instead of all stacking at one. Foot units cover the entries, then the
// whole group re-converges on the search center for the ongoing sweep.
MISSION_CORE_fnc_huntClearBuildings = {
    params ["_grp", "_center", ["_radius", 400]];
    if (isNull _grp || { count units _grp == 0 }) exitWith {};
    private _men = units _grp select { alive _x && { vehicle _x == _x && { !(isNull _x) } } };
    if (count _men == 0) exitWith {};

    private _houses = nearestObjects [_center, ["House", "Building", "Strategic", "Fortress"], _radius];
    private _spots = [];
    {
        for "_i" from 0 to 39 do {
            private _p = _x buildingPos _i;
            if (_p isEqualTo [0, 0, 0]) exitWith {};
            _spots pushBack _p;
        };
    } forEach _houses;
    // No buildings here - nothing to clear (caller keeps sweeping blind).
    if (count _spots == 0) exitWith {};

    // Give each man a random, distinct entry/building point. They split up and move in.
    private _cleared = 0;
    {
        if (count _spots == 0) exitWith {};
        private _p = _spots deleteAt (floor (random (count _spots)));
        _x doMove _p;
        _cleared = _cleared + 1;
    } forEach _men;
    _grp setBehaviour "AWARE";
    _grp setCombatMode "RED";
    diag_log format ["PLAYER HUNT: %1 clearing %2 houses (%3 spots) at %4", groupId _grp, count _houses, _cleared, _center];
};

// Hunt leader Killed EH (the "torch"): the sweep samples contact from the group's LIVING LEADER
// ONLY (see huntSeesPlayer), so when the leader goes down the torch must pass to the next alive
// member. The engine auto-promotes a leader on death, but we still switch explicitly (selectLeader
// when the leader slot is dead) and re-arm the EH on the new leader so a chain of leader deaths
// never leaves the sweep reading a dead unit / without the hunt leader state.
MISSION_CORE_fnc_huntLeaderTorch = {
    params ["_dead", "_killer"];
    private _g = group _dead;
    if (isNull _g) exitWith {};
    if ((_g getVariable ["MISSION_CORE_HUNT_KEY", ""]) == "") exitWith {};
    private _alive = units _g select { alive _x };
    if (count _alive == 0) exitWith {};
    if (isNull (leader _g) || { !(alive (leader _g)) }) then { _g selectLeader (_alive select 0); };
    private _new = leader _g;
    if (isNull _new) exitWith {};
    _new setVariable ["MISSION_CORE_PATROLLING", false];
    _new addEventHandler ["Killed", { _this call MISSION_CORE_fnc_huntLeaderTorch; }];
    diag_log format ["PLAYER HUNT: %1 leader down - %2 takes over", groupId _g, name _new];
};

// Sweep controller for one hunt contingent.
MISSION_CORE_fnc_huntSweep = {
    params ["_grp", "_lkp", "_heading", "_side", "_player", "_playerKey", "_srcName", "_srcPos", "_srcD"];
    if (isNull _grp) exitWith {};
    _grp setVariable ["MISSION_CORE_PATROLLING", false];
    leader _grp setVariable ["MISSION_CORE_PATROLLING", false];
    // Arm the leader torch (passes to the next alive member on leader death).
    (leader _grp) addEventHandler ["Killed", { _this call MISSION_CORE_fnc_huntLeaderTorch; }];

    // Transport rule for the hunt:
    //   - Player FAR away     -> mount a transport to close the distance (even a footman far out
    //                            is worth riding toward; the truck unloads well short of contact).
    //   - Player NEAR on foot -> advance barefoot, no trucks - a troop truck rolling up next to a
    //                            nearby footman is cheesy and easy to spot.
    //   - Player in a VEHICLE -> transport allowed (needed to keep pace), no range restriction.
    private _ldr = leader _grp;
    private _playerDist = if (isNull _player) then { _ldr distance2D _lkp } else { _ldr distance2D _player };
    private _targetInVeh = !isNull _player && { vehicle _player != _player };
    private _mounted = vehicle _ldr != _ldr;
    if (!_mounted && { _targetInVeh || { _playerDist >= (["huntMountDist", 700] call MISSION_CORE_fnc_tune) } }) then {
        // Self-drive: the contingent crews its own truck (no spawned driver / dedicated driver group).
        [_grp, _side, getPos _ldr, true] call MISSION_CORE_fnc_mountInfantry;
    };
    _mounted = vehicle _ldr != _ldr;

    // HUNT CONTACT RULE: fight on foot, never from the truck.
    //   - Plain cargo truck (self-driven) -> EVERYONE out, the driver included. The empty truck is
    //                                       left parked + cargo-locked where it stopped.
    //   - Gun truck (gun MRAP)            -> the DRIVER and GUNNER stay mounted as mobile fire
    //                                       support, the CARGO dismounts. Re-embarking is locked out.
    // After the unload the step behaves COMBAT + combat mode RED.
    private _disembark = {
        params ["_g"];
        private _gLdr = leader _g;
        private _v = vehicle _gLdr;
        if (isNull _v || { _v == _gLdr }) exitWith {};
        // Bring the truck to a FULL STOP before ejecting anyone. The arrival/re-spot code can fire
        // while the truck is still rolling toward the contact, and ejecting at speed kills the men.
        // New waypoints assigned right after the drop cancel the doStop so the truck can drive on.
        // Shared stop routine (see fn_stopForDismount.sqf).
        [_v] call MISSION_CORE_fnc_stopForDismount;
        private _keepCrew = [_v] call MISSION_CORE_fnc_hasMountedGun;
        private _gDrv = driver _v;
        _v lock false;
        // Per-unit leaveVehicle is what actually stops the AI re-boarding loop - orderGetIn false
        // and lockCargo alone just make the men yell "get back in" while being refused. It is
        // applied per rider (not _g leaveVehicle) so a kept driver/gunner is never told to leave.
        // A plain truck keeps NO crew - only a gun truck retains its driver+gunner.
        {
            if (_keepCrew && { _x isEqualTo _gDrv }) then { continue; };
            if (_keepCrew && { _x isEqualTo (gunner _v) }) then { continue; };
            if (_keepCrew && { _x isEqualTo (commander _v) }) then { continue; };
            if (vehicle _x != _v) then { continue; };
            unassignVehicle _x;
            _x leaveVehicle _v;
            [_x] orderGetIn false;
            _x action ["getOut", _v];
        } forEach (crew _v);
        sleep 0.6;
        _v lockCargo true;
        _g setCombatMode "RED";
        _g setBehaviour "COMBAT";
        diag_log format ["PLAYER HUNT: %1 dismounted (%2 stayed mounted)", groupId _g, if (_keepCrew) then { "driver+gunner" } else { "nobody" }];
    };

    // Advance to the LKP. The contingent drives its OWN truck now (no dedicated driver group), so
    // this is a plain MOVE for both mounted and on-foot - at arrival _disembark does the unload: a
    // plain truck empties completely (driver included), a gun truck keeps its driver+gunner. No
    // waypoint script is needed and no separate driver group exists to receive a TR UNLOAD.
    // A MOUNTED contingent now stages on a road near _srcPos first, so it clears the source marker
    // before committing to the drive instead of driving straight through it. On-foot contingents
    // have no road to clear and go straight to the LKP.
    private _fromPos = if (!isNil "_srcPos" && { count _srcPos >= 2 }) then { _srcPos } else { getPosATL _grp };
    [_grp, _fromPos, _lkp] call MISSION_CORE_fnc_buildHuntApproachWps;

    // Arrive: wait until the leader reaches the LKP (or timeout).
    private _arrival = time + (["huntSweepSeconds", 600] call MISSION_CORE_fnc_tune);
    waitUntil { sleep 2;
        isNull _grp || { count units _grp == 0 } ||
        { (leader _grp) distance2D _lkp < 150 } ||
        { time > _arrival }
    };

    // Arrival done - get the squad on the ground (gun trucks only now eject their cargo; the
    // driver+gunner stay). No-op when already on foot.
    [_grp] call _disembark;

    // The self-driven truck is left parked + cargo-locked where it stopped - no driver group to
    // send it home (a gun truck keeps its own driver+gunner aboard as fire support).

    // The 10-minute sweep clock starts when the contingent REACHES the player's last known pos.
    private _sweepEnd = time + (["huntSweepSeconds", 600] call MISSION_CORE_fnc_tune);
    private _curLkp = _lkp;
    private _curHead = _heading;

    private _step = 300;
    private _chainWp = {
        params ["_g", "_base", "_head", "_count"];
        [_g] call MISSION_CORE_fnc_clearGroupWaypoints;
        private _wps = [];
        for "_i" from 1 to _count do {
            private _pos = _base getPos [_i * _step, _head];
            private _wp = _g addWaypoint [_pos, 60];
            _wp setWaypointType "MOVE";
            _wp setWaypointSpeed "NORMAL";
            _wp setWaypointBehaviour "COMBAT";
            _wps pushBack _wp;
        };
        _g setCurrentWaypoint (_wps select 0);
        _g setBehaviour "COMBAT";
        _g setCombatMode "RED";
    };

    // Initial sweep chain along the extrapolated heading.
    [_grp, _curLkp, _curHead, 10] call _chainWp;

    if (isNil "MISSION_CORE_HUNT_INTEL") then { MISSION_CORE_HUNT_INTEL = createHashMap; };
    private _lastRetarget = 0;
    private _lastClear = 0;
    while { time < _sweepEnd && { !isNull _grp } && { count units _grp > 0 } && { { alive _x } count units _grp > 0 } } do {
        sleep 8;
        if (isNull _player) then { continue; };

        // ---- Re-spot (REAL contact only) ----
        // The group's ALIVE LEADER is considered to have "seen" the player when it has actual line
        // of sight AND knowsAbout > 0.7. Raw distance is NEVER sight (no wallhacking through a house
        // or a hill). A tiny 30m bump-in radius is the only non-LOS trigger (they practically
        // stepped on him).
        private _ldrS = leader _grp;
        private _sight = !isNull _ldrS && { [_ldrS, _player] call MISSION_CORE_fnc_huntSeesPlayer };
        private _close = (leader _grp) distance2D _player < (["huntReSpotRadius", 30] call MISSION_CORE_fnc_tune);
        if (_sight || _close) then {
            // PUBLISH the real sighting as shared intel immediately. Until this moment no group
            // knew the player's EXACT position (the sweep ran on stale intel/LKP); this hunt squad
            // just ACTUALLY laid eyes on him. Every marked quadrant for his contested marker repoints
            // onto this fresh position right now - no waiting for the next director tick.
            if (isNil "MISSION_CORE_HUNT_INTEL") then { MISSION_CORE_HUNT_INTEL = createHashMap; };
            MISSION_CORE_HUNT_INTEL set [_playerKey, [getPos _player, _curHead, time]];
            if (isNil "MISSION_CORE_PLAYER_LKP") then { MISSION_CORE_PLAYER_LKP = createHashMap; };
            MISSION_CORE_PLAYER_LKP set [_playerKey, [getPos _player, _curHead, time]];
            diag_log format ["PLAYER HUNT: %1 re-sighted player - publishing fresh intel", groupId _grp];
            [_player, getPos _player] call MISSION_CORE_fnc_updateQuadrantsForPlayer;
            // ABORT sweep - engage on foot: never fight from the truck. Gun trucks keep their
            // driver+gunner mounted as fire support and dump the cargo; cargo trucks dump everyone.
            [_grp] call _disembark;
            // The waypoint aims at the last position where a unit could actually see the player
            // (his current pos IS a legit sighted position right now).
            [_grp] call MISSION_CORE_fnc_clearGroupWaypoints;
            private _wp = _grp addWaypoint [getPos _player, 40];
            _wp setWaypointType "SAD";
            _wp setWaypointSpeed "FULL";
            _wp setWaypointBehaviour "COMBAT";
            _grp setCurrentWaypoint _wp;
            _grp setBehaviour "COMBAT";
            _grp setCombatMode "RED";

            // Wait for them to shake him again (or kill him): the chase continues ONLY while a
            // member still has LOS+knows, or he is within 30m bump range. No 1500m distance glue.
            private _lastSeen = getPos _player;
            private _escAt = time + 30;
            while { time < _escAt && { !isNull _grp } && { alive _player } && { !isNull _player } } do {
                sleep 5;
                if (isNull _grp) exitWith {};
                private _ldrS2 = leader _grp;
                private _still = !isNull _ldrS2 && { [_ldrS2, _player] call MISSION_CORE_fnc_huntSeesPlayer };
                if (_still || { (leader _grp) distance2D _player < (["huntReSpotRadius", 30] call MISSION_CORE_fnc_tune) }) then {
                    _lastSeen = getPos _player;
                    _escAt = time + 30;
                    [_grp] call MISSION_CORE_fnc_clearGroupWaypoints;
                    if (alive _player) then {
                        private _wpE = _grp addWaypoint [getPos _player, 60];
                        _wpE setWaypointType "SAD";
                        _wpE setWaypointSpeed "FULL";
                        _grp setCurrentWaypoint _wpE;
                    };
                };
            };
            if (isNull _grp || { isNull _player } || { !(alive _player) }) then { break; };
            // Contact lost: resume sweeping from WHERE HE WAS LAST SEEN (not his live pos) + the
            // recorded heading. Fresh 10-min clock.
            _curLkp = _lastSeen;
            if (isNil "MISSION_CORE_PLAYER_LKP") then { MISSION_CORE_PLAYER_LKP = createHashMap; };
            _curHead = (MISSION_CORE_PLAYER_LKP getOrDefault [_playerKey, [_curLkp, _heading, 0]]) select 1;
            if (count (MISSION_CORE_HUNT_INTEL getOrDefault [_playerKey, []]) > 0) then {
                private _i = MISSION_CORE_HUNT_INTEL get _playerKey;
                if (time - (_i select 2) <= (["huntIntelDecay", 60] call MISSION_CORE_fnc_tune)) then { _curLkp = _i select 0; _curHead = _i select 1; };
            };
            _sweepEnd = time + (["huntSweepSeconds", 600] call MISSION_CORE_fnc_tune);
            // He was last seen at _curLkp - if a town/compound is here, clear its houses so he
            // can't be hiding inside one while they sweep past outside.
            [_grp, _curLkp] call MISSION_CORE_fnc_huntClearBuildings;
            [_grp, _curLkp, _curHead, 10] call _chainWp;
        } else {
            // ---- Sweeping blind, steered ONLY by stale shared intel ----
            // Every ~45s, if a garrison unit has ACTUALLY sighted the player within the last ~60s
            // (shared intel), nudge the sweep anchor/heading toward that known point. No contact =
            // keep walking the original extrapolated line. NEVER steered from a live player pos.
            if (time > _lastRetarget + (["huntRetargetEvery", 45] call MISSION_CORE_fnc_tune)) then {
                _lastRetarget = time;
                private _intel = MISSION_CORE_HUNT_INTEL getOrDefault [_playerKey, []];
                if (count _intel >= 3 && { (time - (_intel select 2)) <= 60 }) then {
                    private _nb = _curLkp getDir (_intel select 0);
                    [_grp, _curLkp, _nb, 10] call _chainWp;
                };
            };
            // When the squad is walking THROUGH houses on the sweep line, fan out and clear the
            // buildings along the way - keeps them from ignoring whole streets of cover. Throttled
            // to once per ~2min so doMove doesn't re-yank the squad every 8s tick.
            if (time > _lastClear + (["huntClearEvery", 120] call MISSION_CORE_fnc_tune) && { (leader _grp) distance2D _curLkp < 800 }) then {
                _lastClear = time;
                [_grp, getPos (leader _grp)] call MISSION_CORE_fnc_huntClearBuildings;
            };
        };
    };

    // Release THIS squad's hunt slot so a future loiter can dispatch a fresh contingent (other
    // squads hunting the same player stay registered).
    if (isNil "MISSION_CORE_HUNT_ACTIVE") then { MISSION_CORE_HUNT_ACTIVE = createHashMap; };
    private _list = MISSION_CORE_HUNT_ACTIVE getOrDefault [_playerKey, []];
    _list = _list - [_grp];
    MISSION_CORE_HUNT_ACTIVE set [_playerKey, _list];

    // Declared out here, beside the branch that reads them, rather than inside it. The retreat
    // destination is consumed two blocks deeper (in the else), and a private declared inside a then
    // block is not reliably in scope at that depth.
    private _dest = [];
    private _hasDest = false;

    // No re-contact within the window -> retreat to the closest same-side marker, despawn on arrival.
    if (!isNull _grp && { count units _grp > 0 }) then {
        diag_log format ["PLAYER HUNT: contingent %1 sweep over - retreating", groupId _grp];
        // The hunt is over - release ownership so the commander can recommit this squad later.
        _grp setVariable ["MISSION_CORE_HUNT_KEY", ""];
        _grp setVariable ["MISSION_CORE_ORDER", ""];
        _dest = [getPos (leader _grp), _side, [_srcName]] call MISSION_CORE_fnc_getRetreatDest;
        // fn_getRetreatDest answers [0,0,0] for "nowhere to go", but a call that fails partway can
        // leave _dest as something that is not a position at all. Measure nothing until the shape is
        // known: both distance and addWaypoint need three numbers, and handing either a non-position
        // is what produced "0 elements provided, 3 expected" at the distance test and again at the
        // waypoint, with the error reported against addWaypoint and _grp rather than the real cause.
        if (count _dest == 3 && { _dest isEqualType [] }) then {
            _hasDest = count (_dest select { _x isEqualType 0 }) == 3;
        };
        if (!_hasDest || { _dest distance2D [0, 0, 0] < 1 }) then {
            // Nowhere to walk to - the men still go back to the marker the hunt drew them from.
            [_grp, getPos (leader _grp), _srcName] call MISSION_CORE_fnc_retreatPayout;
            [_grp] call MISSION_CORE_fnc_deleteGroupCompletely;
        } else {
            // Record the destination so fn_retreatPayout can resolve which marker these survivors
            // are being credited to on arrival. MISSION_CORE_ORDER is deliberately left "" - the
            // hunt releases ownership so the commander can recommit this squad later, and the
            // despawn sweeper only ever touches groups tagged "retreat".
            _grp setVariable ["MISSION_CORE_RETREAT_DEST", _dest];
            _grp setCombatMode "GREEN";
            _grp setBehaviour "AWARE";
            _grp setSpeedMode "FULL";
            [_grp] call MISSION_CORE_fnc_clearGroupWaypoints;
            private _wp = _grp addWaypoint [_dest, 100];
            _wp setWaypointType "MOVE";
            _wp setWaypointSpeed "FULL";
            // Despawn on arrival - transport_retreatArrive.sqf fires on the MOVE completion.
            _wp setWaypointScript "fnc\commander\transport_retreatArrive.sqf";
            _grp setCurrentWaypoint _wp;
        };
    } else {
        if (!isNull _grp) then { [_grp] call MISSION_CORE_fnc_deleteGroupCompletely; };
    };
};

// QUEUED HUNT CONTINGENT - the player-hunt spawn, released from MISSION_CORE_SPAWN_QUEUE at
// priority -2, strictly below every other queue spawn including the armor-critical -1 jump.
//
// Why it is queued: a hunt used to spawn inline, bypassing the queue entirely, so it could field a
// fresh MBT or conjured squad while a marker reinforcement sat queued for those same slots. Marker
// and player-hunt work now contend through one queue and one set of caps, and the hunt loses.
//
// Returns TRUE once handled. A hunt is not a cap-gated job that should sit retrying: by the time it
// is reached the queue is already empty, and if the contingent cannot be fielded even then the
// source stays un-latched and simply offers itself again on the next director tick. Nothing is lost
// by consuming the job, and it avoids a dead job occupying the back of the queue forever.
MISSION_CORE_fnc_queuedHuntContingent = {
    params ["_player", "_lkp", "_heading", "_side", "_sideVar", "_factionData", "_srcName", "_srcPos", "_srcSize", "_srcImp", "_srcD", "_playerKey", "_pace"];

    // The player this hunt was queued for may be gone by the time its turn comes. Nothing to hunt.
    if (isNull _player) exitWith {
        diag_log format ["DYNAMIC QUEUE: dropped hunt from %1 - target player no longer exists", _srcName];
        true
    };

    // The spawn itself, with every gate it already had: armor cap, foot cap, spawn safety, and the
    // source marker's own manpower pool. That pool is debited HERE, at the moment the squad actually
    // exists - never back at enqueue - so a hunt that waits behind marker work cannot spend men it
    // never fielded.
    private _grp = [_player, _lkp, _heading, _side, _sideVar, _factionData, _srcName, _srcPos, _srcSize, _srcImp, _srcD] call MISSION_CORE_fnc_huntSpawnContingent;
    if (isNull _grp) exitWith {
        diag_log format ["DYNAMIC QUEUE: hunt from %1 released its turn but fielded nothing (cap/safety/pool) - source stays available", _srcName];
        true
    };

    // Only a SUCCESSFUL dispatch sets the source's next allowed hunt time - a refused or skipped
    // source stays free to retry on the next director tick.
    if (_pace > 0) then { MISSION_CORE_HUNT_COOLDOWN set [_srcName, time + _pace]; };
    // AMMO: dispatching a hunt contingent costs the source marker ammo.
    [_srcName, ["ammoCostHunt", 2] call MISSION_CORE_fnc_tune] call MISSION_CORE_fnc_consumeAmmo;

    private _list = MISSION_CORE_HUNT_ACTIVE getOrDefault [_playerKey, []];
    _list pushBack _grp;
    MISSION_CORE_HUNT_ACTIVE set [_playerKey, _list];
    _grp setVariable ["MISSION_CORE_HUNT_TARGET", _player];
    _grp setVariable ["MISSION_CORE_HUNT_KEY", _playerKey];
    // Register AFTER HUNT_KEY is stamped: that var is how fn_huntMarkerLive tells a live hunt from
    // one whose sweep has ended, so registering first would let the very next read prune this group
    // and the marker would never reach its allowance.
    private _nowLive = [_srcName, _grp] call MISSION_CORE_fnc_huntMarkerRegister;
    [_grp, _lkp, _heading, _side, _player, _playerKey, _srcName, _srcPos, _srcD] spawn MISSION_CORE_fnc_huntSweep;
    diag_log format ["PLAYER HUNT: %1 dispatching %2 from %3 toward %4 (%.0fm, %5 live hunt(s) from this marker)", _side, groupId _grp, _srcName, _lkp, _srcD, _nowLive];
    true
};
