
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
if (isNil "MISSION_CORE_ASSAULT_CONTEST_GROUPS") then { MISSION_CORE_ASSAULT_CONTEST_GROUPS = createHashMap; };

// ---- DIAGNOSTIC (writes a bookkeeping map + diag_log lines; never reads or writes contest state) ----
// MISSION_CORE_DEBUG_CONTEST is the master switch - set it false to silence all of this with no edit.
// MISSION_CORE_DEBUG_CONTEST_WHY is the evidence trail: marker -> [entry, ...] where each entry is
// [time, holder, path, aliveCount]. Written ONLY while a hold is still live, because the registries
// prune a dead group within a second - by the time the single clear at the bottom of this file fires,
// the squad that was fighting there is already gone from MISSION_CORE_ASSAULT_CONTEST_GROUPS and an
// empty registry cannot say whether it died, despawned, walked off, or was never there. This map is
// the only place that fact survives long enough to be reported.
// One entry per distinct (holder, path) pair, overwritten in place, so the 1Hz re-proof of a live
// squad refreshes its own row instead of growing the list. Capped at 8 rows per marker.
if (isNil "MISSION_CORE_DEBUG_CONTEST") then { MISSION_CORE_DEBUG_CONTEST = true; };
if (isNil "MISSION_CORE_DEBUG_CONTEST_WHY") then { MISSION_CORE_DEBUG_CONTEST_WHY = createHashMap; };
MISSION_CORE_fnc_debugContestHold = {
    params ["_name", "_holder", "_path", "_alive"];
    if (isNil "MISSION_CORE_DEBUG_CONTEST") then { MISSION_CORE_DEBUG_CONTEST = true; };
    if !MISSION_CORE_DEBUG_CONTEST exitWith {};
    if (_name == "") exitWith {};
    private _rec = MISSION_CORE_DEBUG_CONTEST_WHY getOrDefault [_name, []];
    // An entry is [time, _holder, _path, _aliveCount] - so the (holder, path) key lives at indexes
    // 1 and 2, NOT 0 and 1. Comparing element 0 (a Number, the timestamp) against _holder (a
    // String) is a Number == String comparison, which SQF rejects outright, so the whole evidence
    // map silently stopped being written.
    private _idx = _rec findIf { ((_x select 1) == _holder) && { (_x select 2) == _path } };
    if (_idx >= 0) then { _rec set [_idx, [time, _holder, _path, _alive]]; } else { _rec pushBack [time, _holder, _path, _alive]; };
    if (count _rec > 8) then { _rec deleteAt 0; };
    MISSION_CORE_DEBUG_CONTEST_WHY set [_name, _rec];
};

// Shared presence evaluation for ONE assault group pressing ITS assigned target marker (BLUFOR
// recruited groups AND REDFOR committed assault force share this same logic). Writes the group's
// side into _map when it is present (or when the marker is already sticky-contested and the group
// is still on it). Used by refreshAssaultContest once per second via both registration paths.
MISSION_CORE_fnc_assaultGroupEval = {
    params ["_ag", "_mName", "_side", "_map", ["_isMechMotor", false], ["_tag", "?"]];
    if (isNull _ag) exitWith {};
    private _present = false;
    // _path names WHICH sub-test below proved presence, for the diagnostic record only. "ring" = a
    // living man (or his vehicle) is inside the inflated ellipse; "knowsAbout" = no one is inside but
    // the garrison has eyes on one of them; "sticky" = neither was true and the marker was only held
    // because it was ALREADY contested and this group is still on it. The last one is the important
    // distinction: sticky means presence genuinely lapsed rather than never being proven again.
    private _path = "none";
    // Presence is evaluated over the group's LIVING members, never just its leader. Using the
    // leader alone meant an assault squad whose leader had been killed - but whose men were still
    // fighting inside the marker - never registered as contesting it, so the target marker went
    // quiet while the fight continued. This is the common case during a real engagement.
    private _aliveUnits = units _ag select { !isNull _x && { alive _x } };
    if (count _aliveUnits > 0) then {
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
        // dismounted men (vehicle _x == _x) are counted by the same expression. The flag is
        // precomputed by the caller (BLUFOR from the template, REDFOR from simply being a mounted
        // column) and cached.
        if (_isMechMotor) then {
            if (_aliveUnits findIf { private _v = vehicle _x; alive _v && { [getPos _v] call _inMarker } } != -1) then { _present = true; _path = "ring"; };
        } else {
            if (_aliveUnits findIf { [getPos _x] call _inMarker } != -1) then { _present = true; _path = "ring"; };
        };
        // PERMANENT RULE: a squad pressing the marker from just OUTSIDE its edge still counts
        // as present when the garrison has detected ANY of its men (knowsAbout). Foot squads
        // legitimately open fire from the standoff line / edge ring instead of walking into the
        // ellipse, so the old strict "inside" test starved assault-targets of their contested
        // state (and with it the counter-attack/defense flow) for whole engagements. The garrison's
        // knowledge is sampled from each enemy group's ALIVE LEADER ONLY - never from every unit.
        if (!_present) then {
            private _enemies = _pos nearEntities ["Man", 1500] select { alive _x && { side _x getFriend _side < 0.6 } };
            private _enemyLeaders = [];
            {
                private _g = group _x;
                if (isNull _g) then { continue; };
                private _ldr = leader _g;
                if (isNull _ldr) then { continue; };
                if !(alive _ldr) then { continue; };
                if (_enemyLeaders findIf { _x == _ldr } == -1) then { _enemyLeaders pushBack _ldr; };
            } forEach _enemies;
            private _knows = ["assaultContestKnows", 0.7] call MISSION_CORE_fnc_tune;
            if (_enemyLeaders findIf { private _e = _x; _aliveUnits findIf { _e knowsAbout _x > _knows } != -1 } != -1) then { _present = true; _path = "knowsAbout"; };
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
        //
        // GUARDED READ. MISSION_CORE_CONTESTED is created lazily inside fnc_isMarkerContested, but
        // fn_aiCommanderLoop calls fnc_refreshAssaultContest unconditionally from startup - so this
        // eval can run BEFORE any call to isMarkerContested has created the map, and a direct
        // reference throws "Undefined variable". `in` accepts an Array as well as a HashMap, so an
        // empty array is a safe stand-in that simply fails every membership test.
        private _contestedNow = if (isNil "MISSION_CORE_CONTESTED") then { [] } else { MISSION_CORE_CONTESTED };
        if (_mName in _contestedNow) then {
            _path = "sticky";
            private _existing = _map getOrDefault [_mName, []];
            if (!(_side in _existing)) then { _map set [_mName, _existing + [_side]]; };
        };
    };
    // Evidence trail. Written ONLY while this group is genuinely holding the marker, because the
    // registries prune a dead group within a second: by the time the single clear at the bottom of
    // this file fires, the squad that was fighting here is already out of MISSION_CORE_ASSAULT_CONTEST_GROUPS
    // and an empty registry cannot say whether it died, despawned, walked off, or was never there.
    // Note _present is NOT set by the sticky branch - it only re-asserts the marker in _map - so the
    // two conditions are checked separately. This is the only write this block makes.
    if (_present || { _path == "sticky" }) then {
        [_mName, _tag, _path, count _aliveUnits] call MISSION_CORE_fnc_debugContestHold;
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
            // TYPE GUARD BEFORE count. MISSION_CORE_ATTACK_GROUPS has been observed holding SCALAR
            // values (not just arrays), and `count` on a scalar throws "Type Number, expected
            // Array". Inside this loop that throw aborts the WHOLE 1Hz presence rebuild partway
            // through, so every group ordered after the bad entry is silently never evaluated and
            // its marker never becomes contested. The isEqualType test lets the loop skip the entry and
            // carry on - same guard the AI registry below already has.
            if (!(_adata isEqualType [])) then { continue; };
            if (count _adata < 7) then { continue; };
            // No status gate: "active" means en route near the zone, not "contesting". Presence is
            // the only question here; group status belongs to the staging flow.
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
            [_ag, _mName, _side, _map, _isMechMotor, format ["recruit-%1", _x]] call MISSION_CORE_fnc_assaultGroupEval;
        } forEach MISSION_CORE_ATTACK_GROUPS;
    };
    // MULTIPLAYER RELAY: client-spawned assault groups reported to the server (fn_assaultRelay.sqf)
    // are evaluated for contest exactly like the local ones above. Entries share the same shape.
    if (!isNil "MISSION_CORE_ATTACK_GROUPS_RELAY") then {
        {
            private _adata = _y;
            if (!(_adata isEqualType [])) then { continue; };  // same scalar guard as the local path above
            if (count _adata < 7) then { continue; };
            // Same on the relay path: presence only, no status gate.
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
                        || { (_catName find "Mechanized" > -1 || _subCat find "mech" > -1) };
                };
            };
            [_ag, _mName, _side, _map, _isMechMotor, format ["relay-%1", _x]] call MISSION_CORE_fnc_assaultGroupEval;
        } forEach MISSION_CORE_ATTACK_GROUPS_RELAY;
    };
    // AI ASSAULT FORCE. fn_assaultStaging / fn_assembleAssault -> fn_spawnAssaultGroup register their
    // groups in MISSION_CORE_ASSAULT_CONTEST_GROUPS. These were excluded here entirely, which meant an
    // AI squad could stand inside a target marker trading fire with its garrison while the marker
    // reported itself uncontested and aged out through the grace window - the reinforcement flow for
    // that fight then read "no longer contested" and stopped sending. They are evaluated with the
    // IDENTICAL presence logic as the recruited paths above: same standoff ring, same knowsAbout
    // fallback, same sticky branch. Both kinds of attacker now trip contest the same way.
    if (!isNil "MISSION_CORE_ASSAULT_CONTEST_GROUPS") then {
        private _drop = [];
        {
            private _gid = _x;
            private _gd = _y;
            private _tn = "";
            private _gs = WEST;
            private _ok = _gd isEqualType [] && { count _gd >= 3 };
            if (_ok) then {
                _tn = _gd select 1;
                _gs = _gd select 2;
                private _g = _gd select 0;
                _ok = _tn != "" && { !isNull _g } && { count (units _g select { !isNull _x && { alive _x } }) > 0 };
            };
            // PRUNE: a null handle, a dead group, or a nameless target cannot contest anything.
            // Collected and deleted AFTER the iteration so nothing mutates the map mid-forEach.
            if (!_ok) then { _drop pushBack _gid; } else {
                [_gd select 0, _tn, _gs, _map, (_gd select 0) getVariable ["MISSION_CORE_MECH_MOTOR", false], format ["ai-%1", _gid]] call MISSION_CORE_fnc_assaultGroupEval;
            };
        } forEach MISSION_CORE_ASSAULT_CONTEST_GROUPS;
        { MISSION_CORE_ASSAULT_CONTEST_GROUPS deleteAt _x; } forEach _drop;
    };
    MISSION_CORE_ASSAULT_CONTEST = _map;
};

// A marker is CONTESTED once a hostile player engages its garrison (knowsAbout), and STAYS
// contested without any further knowsAbout requirement until the player moves 1200m+ away OR
// steps inside a different marker (their fight moved elsewhere), or the marker gives up
// (retreats - cleared by the replenish loop). It is a sticky flag, not a per-tick live-enemy
// check, so reinforcements keep flowing even while the garrison is momentarily wiped.
MISSION_CORE_fnc_isMarkerContested = {
    // _src is a DIAGNOSTIC tag identifying the call site ("replenishLoop", "tankOrderLoop", ...).
    // It is optional and never affects the verdict; it exists only so the clear log can name the
    // caller, since the stored state alone cannot tell a wrong-_owner call from a correct one.
    params [["_locPos", [0, 0, 0]], ["_owner", WEST], ["_markerName", ""], ["_src", "?"]];
    if (isNil "MISSION_CORE_CONTESTED") then {
        MISSION_CORE_CONTESTED = createHashMap;
        // PUBLIC SO THAT CLIENTS CANNOT HOLD A DIFFERENT ANSWER. Clients used to read a separately
        // broadcast union array (MISSION_CORE_CONTESTED_MARKERS, published by
        // fn_publishContestedMarkers on a 5s throttle from a side-filtered derived list). That
        // array was a SECOND copy of this verdict: it lagged the latch by up to 5s and was computed
        // from fn_getContestedMarkers' own owner filter, so the client recruit menu could flag a
        // marker [UNDER ATTACK] that this map had already cleared - or miss one still contested.
        //
        // There is now exactly one value. Key present = contested, for every consumer on every
        // machine, server and client alike. Clients read `keys MISSION_CORE_CONTESTED`.
        publicVariable "MISSION_CORE_CONTESTED";
    };

    // SINGLE WRITER. This function is the ONLY thing that sets or clears MISSION_CORE_CONTESTED.
    // It used to not be: three separate set sites plus two delete sites lived in this file, and a
    // sixth delete lived in fn_despawnUncontestedNeighbors, so "is this marker contested" had five
    // independent answers that could disagree with each other and with the consumers that read the
    // raw map. Every condition below now REFRESHES the latch and returns true; clearing happens once,
    // at the very end, and only after the grace window. Adding a new reason to be contested must add
    // a refresh here - never a new exit.
    // Assault presence is evaluated for every registered group targeting this marker, whatever its
    // status: "active" means en route near the zone, not "contesting", so it must not gate contest.
    private _CONTESTED = MISSION_CORE_CONTESTED;
    // The stored value is [lastSeen, sources] - kept as an ARRAY rather than the old bare `true` so
    // the grace check has a timestamp to work from. Consumers are unaffected: every reader in the
    // mission does `_name in MISSION_CORE_CONTESTED` (key membership) and never reads the value.
    private _lastSeen = (_CONTESTED getOrDefault [_markerName, [-1e10, []]]) select 0;
    private _grace = ["contestedClearGrace", 10] call MISSION_CORE_fnc_tune;
    private _hold = {
        // PERMANENT RULE: `call FNAME [args]` is INVALID. `call` binds to the code first, leaving
        // [args] dangling -> "Error Missing ;". The args array must come FIRST: `[args] call FNAME`.
        // (Same rule as fn_neighborCounterAttack.) `_hold` is a code block, so it has no named
        // parameters - it takes its reason as _this and is invoked as `["why"] call _hold`.
        params [["_why", "unknown"]];
        // Evidence trail for the player-driven holds. The assault-target hold is deliberately NOT
        // recorded here - MISSION_CORE_fnc_assaultGroupEval already writes a far richer row (which
        // squad, which sub-test proved presence) from inside the 1Hz presence pass, and tagging it
        // again would overwrite that detail with a contentless "assaultTarget" row.
        if (_why != "assaultTarget") then { [_markerName, _why, "latch", 1] call MISSION_CORE_fnc_debugContestHold; };
        private _prev = _CONTESTED getOrDefault [_markerName, [-1e10, []]];
        // Publishing on EVERY hold would serialize this HashMap to every client dozens of times a
        // second: this function is called per marker per tick from many loops, and the stored
        // timestamp changes every call. But no consumer ever reads the value - they only test key
        // membership (`_name in MISSION_CORE_CONTESTED`). So the only events a client can act on are
        // a marker ENTERING the map and a marker LEAVING it. Those are rare; the per-call refresh
        // in between is server-local bookkeeping and must stay off the wire.
        private _wasNew = !(_markerName in _CONTESTED);
        _CONTESTED set [_markerName, [time, _prev select 1]];
        if (_wasNew) then { publicVariable "MISSION_CORE_CONTESTED"; };
        true
    };
    // DIAGNOSTIC: _sides/_asTarget are hoisted to function scope (they used to be private to the
    // assault block below) so the clear block at the bottom can still report WHY the assault hold did
    // or did not fire. Without them the log can only show that no hold ran, not whether the presence
    // map was empty or whether it had the squad and the owner comparison still said "friendly".
    private _sides = [];
    private _asTarget = false;
    private _assaultHold = false;
    // ASSAULT-TARGET CONTEST: a marker that is the ASSIGNED TARGET of an active released assault
    // squad is contested by that squad's presence alone - the squad pressing/engaging it. This
    // gives a player-less squad battle the full contested response (replenish priority,
    // reinforcement flow, defense). Pass-through markers a squad merely marches across are NOT
    // contested here - they only get spawned (see proximitySpawner) so there is something to fight
    // on the way. The per-group presence (and mech/motor riding-vehicle logic) is computed once per
    // second in MISSION_CORE_fnc_refreshAssaultContest - see the helper at the top of this file.
    if (_markerName != "" && { ((!isNil "MISSION_CORE_ATTACK_GROUPS") && { count MISSION_CORE_ATTACK_GROUPS > 0 }) || { (!isNil "MISSION_CORE_ATTACK_GROUPS_RELAY") && { count MISSION_CORE_ATTACK_GROUPS_RELAY > 0 } } }) then {
        call MISSION_CORE_fnc_refreshAssaultContest;
        _sides = MISSION_CORE_ASSAULT_CONTEST getOrDefault [_markerName, []];
        _asTarget = _sides findIf { _owner getFriend _x < 0.6 } != -1;
        // A squad pressing its assigned target keeps the marker contested through the grace window.
        // refreshAssaultContest rebuilds its map from scratch once a second, so any tick where the
        // squad is mid-move, outside the standoff ring, or briefly short a living man used to drop
        // the marker out of contested for that second and un-contest a live fight. The player path
        // below has a sticky latch for exactly this reason; this is the assault path's equivalent.
        // The only status gate is "the group still exists and has a living member" - group status
        // ("active"/"hold") says whether the group is en route near the zone, which is NOT the same
        // question as whether it is contesting the marker, so it does not gate this.
        if (_asTarget) then { ["assaultTarget"] call _hold; _assaultHold = true; };
    };
    // THIS RETURN MUST SIT AT FUNCTION SCOPE. `exitWith` inside the then-block above does NOT leave
    // this function - it leaves that code block and execution carried on into the player / close-band
    // / sticky / apron checks and then into the single clear at the bottom. Because _lastSeen is read
    // once at function entry, the clear then evaluated `time - <timestamp from before _hold ran>`
    // against a key _hold had ALREADY refreshed in this very call, judged it stale, and deleted it.
    // Result: a squad holding its target marker contested it and cleared it in the same invocation,
    // forever. Observed on outpost_16 as age=1e+10 with raw stored value [289.026,[]] - the value was
    // fresh; only the age was measured against the pre-hold sentinel.
    if (_assaultHold) exitWith { true };
    private _players = allPlayers select { alive _x };

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
                    ["closeBand"] call _hold;
                    _closeResult = [true];
                };
            };
        };
    };
    // This early return can only ever say YES. It used to also say no: `!_armed` set
    // _closeResult to [false], which returned false straight past the assault-group hold above AND
    // past the grace-gated clear at the end of this function. Any marker with a close same-side
    // neighbour took that path, and HQ markers essentially always do - hq_4 sat next to other
    // high-value markers inside proxDespawnDist, so it reported "no longer contested" the instant a
    // player stepped outside halfGap-50m, even with an assault group registered against it.
    //
    // Leaving the activation band is ONE reason to be contested stopping, not proof the fight
    // ended. So this block now contributes evidence and nothing else: when armed it refreshes the
    // latch and returns true; when not armed it simply falls through to the assault test, the sticky
    // block and generic presence, and the single grace-gated clear decides.
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
        if (_stillHere) exitWith { ["stickyPlayer"] call _hold };
        // Not clearing here either - same reason as the close-band exit above. Falling out of the
        // 1200m player radius is one reason stopping, not proof the marker is quiet.
    };
    // OTHERWISE GARRISON-INDEPENDENT CONTEST: set contested the moment ANY BLUFOR threat is
    // present - a hostile player physically inside the marker ellipse, OR approaching it
    // (within the standard approach radius). No knowsAbout / garrison engagement required:
    // the instant BLUFOR threatens the marker it is contested, whether or not the garrison is
    // spawned, wiped, or has spotted anyone. This replaces the old "inside + enemy spotted the
    // player" gate that left markers quietly uncontested (and untereplenished) until a garrison
    // was already being ground down. Clear is handled by the caller paths (full capture, all
    // enemies died/walked away).
    private _shape = if (_markerName != "") then { [_markerName] call MISSION_CORE_fnc_getMarkerShape } else { [[0, 0, 0], 200, 200, 0] };
    private _a = _shape select 1;
    private _b = _shape select 2;
    private _md = _shape select 3;
    // THE 250m APRON: one shape-aware band around the marker's edge, gating BOTH ways in. The
    // assault-group gate above already used it - fn_assaultGroupEval inflates the ellipse by
    // assaultStandoffRing - so this is the identical construction and a player and an assault squad
    // trip contest at the same distance from the boundary. Semiaxes a/b and the rotation are all
    // honoured, so a long thin marker bands off its long axis, not off a circle.
    // Replaces the old `(distance from centre) <= scareApproachRadius` (2500m) player test, which
    // gave every marker the same reach from its centre: it swallowed the map around a small outpost
    // and still stopped short of a big HQ's edge.
    private _edge = ["assaultStandoffRing", 250] call MISSION_CORE_fnc_tune;
    private _inEdgeBand = {
        params ["_p"];
        private _dx = (_p select 0) - (_locPos select 0);
        private _dy = (_p select 1) - (_locPos select 1);
        private _rx = _dx * cos _md - _dy * sin _md;
        private _ry = _dx * sin _md + _dy * cos _md;
        ((_rx*_rx)/((_a+_edge)*(_a+_edge))) + ((_ry*_ry)/((_b+_edge)*(_b+_edge))) <= 1
    };
    private _threatPresent = _markerName != "" && { _players findIf {
        side _x getFriend _owner < 0.6 && { [getPos _x] call _inEdgeBand }
    } != -1 };
    if (_threatPresent) exitWith { ["playerApron"] call _hold };

    // ---- THE ONE CLEAR ---- every other exit above returned true by refreshing the latch, so
    // reaching this point means NO reason currently holds the marker contested. It stays contested
    // until lastSeen is older than the grace window, then it clears - once, here, in one place.
    // Previously each reason had its own deleteAt, so a marker could be un-contested by whichever
    // unrelated condition happened to be evaluated, which is what produced the flicker that capped
    // the zone's reinforcement at 29 men and reset its pool on every bad tick.
    // RE-READ THE TIMESTAMP IMMEDIATELY BEFORE DECIDING. _lastSeen was captured once at function
    // entry, but every hold above writes `time` into that same entry as it runs. If the key was
    // absent at entry the sentinel -1e10 is used, so a hold earlier in THIS invocation would be
    // judged "older than the grace window" and the clear would delete the key that hold had just
    // written. Re-reading here makes the grace test immune to ordering for every hold above, not
    // just the assault one.
    private _freshLastSeen = (_CONTESTED getOrDefault [_markerName, [-1e10, []]]) select 0;
    if (_markerName != "" && { (_markerName in _CONTESTED) && { (time - _freshLastSeen) <= _grace } }) exitWith { true };
    if (_markerName != "" && { _markerName in _CONTESTED }) then {
        // DIAGNOSTIC: captured BEFORE deleteAt below erases it. The distinction this preserves is
        // the whole point of the block: a stored timestamp of -1e10 means no hold EVER fired for
        // this marker, while a real-but-old timestamp means holds did fire and then lapsed. Those
        // are different bugs and the -1e10 alone (which round() prints as age=1e10) cannot tell them
        // apart from _lastSeen, because _lastSeen is only element 0 of the value.
        private _rawVal = _CONTESTED getOrDefault [_markerName, ["<absent>"]];
        _CONTESTED deleteAt _markerName;
        // A key left the map, so publish it. Clients read key membership, so this is what clears the
        // [UNDER ATTACK] flag in the recruit menu and what the staged-squad auto-release loop watches
        // - without this the client would keep showing a contested marker the server already cleared.
        publicVariable "MISSION_CORE_CONTESTED";
        diag_log format ["CONTEST: %1 cleared - no threat within %2s grace", _markerName, round _grace];
        // ---- DIAGNOSTIC: why did it clear? ----
        // The question this block exists to answer is "was it an AI group that died, or something
        // else", and the registries CANNOT answer it at this point: a group with no living member is
        // pruned from MISSION_CORE_ASSAULT_CONTEST_GROUPS within a second, so a squad that died just
        // before this line looks identical to a squad that was never registered. The evidence map
        // holds the last proven-holding state per holder; the census below holds the current state.
        // Read the two together: holder "ai-N" in the evidence list with a registry census of none is
        // a squad that died (or despawned); a census entry with alive=0 that is still listed is a
        // pruning lag; and a path of "sticky" means presence was never re-proven and genuinely lapsed.
        // isServer is the other half of the answer: this line is reachable on a client too.
        if (isNil "MISSION_CORE_DEBUG_CONTEST") then { MISSION_CORE_DEBUG_CONTEST = true; };
        if (MISSION_CORE_DEBUG_CONTEST) then {
            // WHO CALLED THIS. The clear is reachable from ~10 loops and each passes its own _owner
            // argument; two of them pass a side that is not the marker's owner at all
            // (fn_tankOrderLoop passes _orderSide, fn_defenseSpotLoop passes side _ldr). A
            // wrong-owner call and a correct call that found no threat produce identical stored
            // state, so the call sites tag themselves via the optional 4th argument. A call stack
            // dump would answer the same question, but this is cheaper and unambiguous.
            diag_log format ["CONTEST: %1 UNC0NTESTED  isServer=%2  age=%3s  grace=%4s", _markerName, isServer, round (time - _lastSeen), round _grace];
            diag_log format ["CONTEST:   called from %1", _src];
            diag_log format ["CONTEST:   raw stored value = %1", _rawVal];
            diag_log format ["CONTEST:   call args:  locPos=%1  owner=%2  markerName=%3", _locPos, _owner, _markerName];
            diag_log format ["CONTEST:   assault eval:  sides=%1  asTarget=%2  keyInContestMap=%3", _sides, _asTarget, (_markerName in MISSION_CORE_ASSAULT_CONTEST)];
            private _why = MISSION_CORE_DEBUG_CONTEST_WHY getOrDefault [_markerName, []];
            if (count _why == 0) then {
                diag_log format ["CONTEST:   no holder was ever recorded for this marker - it was never held by anything this function can see"];
            } else {
                {
                    private _e = _x;
                    // Entry shape is [time, holder, path, aliveCount] - printed in THAT order.
                    // These labels were previously shifted by one, which made a live squad read as
                    // "path=recruit-0 alive=ring".
                    diag_log format ["CONTEST:   last holder %1  path=%2  alive=%3  at t=%4  isServer=%5", _e select 1, _e select 2, _e select 3, round (_e select 0), isServer];
                } forEach _why;
            };
            // Current census: which groups are registered against THIS marker right now, and how many
            // of them are still standing. All three registries share the shape [_grp, _targetName, ...]
            // so one loop serves them. Referenced directly rather than through missionNamespace
            // getVariable: the array form of getVariable demands [name, default] (2 elements, not 1),
            // and plain direct reference matches the guards used elsewhere in this file.
            private _maps = [];
            if (!isNil "MISSION_CORE_ATTACK_GROUPS" && { count MISSION_CORE_ATTACK_GROUPS > 0 }) then { _maps pushBack ["recruit", MISSION_CORE_ATTACK_GROUPS]; };
            if (!isNil "MISSION_CORE_ATTACK_GROUPS_RELAY" && { count MISSION_CORE_ATTACK_GROUPS_RELAY > 0 }) then { _maps pushBack ["relay", MISSION_CORE_ATTACK_GROUPS_RELAY]; };
            if (!isNil "MISSION_CORE_ASSAULT_CONTEST_GROUPS" && { count MISSION_CORE_ASSAULT_CONTEST_GROUPS > 0 }) then { _maps pushBack ["ai", MISSION_CORE_ASSAULT_CONTEST_GROUPS]; };
            diag_log format ["CONTEST:   sizes: ATTACK_GROUPS=%1  RELAY=%2  AI=%3  ASSAULT_CONTEST_KEYS=%4", count (missionNamespace getVariable ["MISSION_CORE_ATTACK_GROUPS", []]), count (missionNamespace getVariable ["MISSION_CORE_ATTACK_GROUPS_RELAY", []]), count (missionNamespace getVariable ["MISSION_CORE_ASSAULT_CONTEST_GROUPS", []]), count (missionNamespace getVariable ["MISSION_CORE_ASSAULT_CONTEST", []])];
            private _live = [];
            private _skipped = [];
            {
                private _reg = _x;
                private _regName = _reg select 0;
                {
                    private _d = _x;
                    // TYPE GUARD BEFORE count. `(count _d) >= 3` cannot protect itself: if an entry
                    // is not an array, `count` throws "Type Number, expected Array" (booleans and
                    // numbers are numbers in SQF) and the whole clear log dies mid-print. The length
                    // check is meant to skip malformed entries, so it has to test the TYPE first.
                    if (!(_d isEqualType [])) then {
                        if ((count _skipped) < 3) then { _skipped pushBack format ["%1 key %2 holds %3", _regName, _x, typeName _d]; };
                    } else {
                        if ((count _d) >= 3 && { (_d select 1) == _markerName } && { !isNull (_d select 0) }) then {
                            private _g = _d select 0;
                            _live pushBack [format ["%1:%2 (side%3)", _regName, _x, side (leader _g)], count (units _g select { !isNull _x && { alive _x } })];
                        };
                    };
                } forEach (_reg select 1);
            } forEach _maps;
            if ((count _skipped) > 0) then {
                diag_log format ["CONTEST:   WARNING: %1 registry entries are not arrays and were skipped -", (count _skipped)];
                { diag_log format ["CONTEST:     bad entry: %1", _x]; } forEach _skipped;
            };
            if (count _live == 0) then {
                diag_log format ["CONTEST:   no group is registered against %1 any more - died, despawned, walked off, or was never in the registry", _markerName];
            } else {
                { diag_log format ["CONTEST:   still registered %1  alive=%2", _x select 0, _x select 1]; } forEach _live;
            };
            // The evidence has served its purpose - drop it so the next clear reports only the holds
            // that happened after this one, not a mixture of two separate fights.
            MISSION_CORE_DEBUG_CONTEST_WHY deleteAt _markerName;
        };
    };
    false
};
