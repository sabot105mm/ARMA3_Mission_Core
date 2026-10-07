// -------------------------------------------------------------------
// STAGED ASSAULT SYSTEM
// -------------------------------------------------------------------
// PERMANENT RULE (REDFOR STAGING): committed REDFOR assault groups never drive
// straight at their target the moment the assault is announced. They first move to
// the EDGE of their own (source) marker area, on the compass bearing from the source
// center toward the target marker, and HOLD there (the same edge-hold pattern the
// recruit attack groups use when their captured marker flips). The assault force
// only advances once the requested factory tanks are built and delivered to the
// source marker (or the build deadline passes and the waves roll in regardless).
// There is NO contested/manual/auto release path for REDFOR: the AI commander
// presses the attack itself the moment its armor is on the ground.
// BLUFOR staging (player-purchased squads staged at their source edge until the
// target is engaged or the player releases them) lives in fn_recruit.sqf /
// fn_assaultServer.sqf (serverStageGroup).
//
// SHARED STAGING CORE: MISSION_CORE_fnc_stageGroupAtEdge is the ONE implementation
// of "move to the marker edge on the target bearing and hold" - the waypoint/order/
// state setup. REDFOR stageAssaultGroup, BLUFOR serverStageGroup and the assembled
// full-counter-attack staging all call it. Nothing else re-implements edge staging.

// Reset all REDFOR staging state between assaults.
MISSION_CORE_fnc_resetStagedAssault = {
    MISSION_CORE_ASSAULT_STAGED = createHashMap;
};

// Shared edge-staging core: point a group at the edge of its source marker on the compass
// bearing toward its target and HOLD there. Sets ORDER "staging", ATTACK_TARGET and
// STAGE_POS. Returns the computed stage position (callers log/register with it).
// [_grp, _srcPos, _srcSize, _tgtPos] call MISSION_CORE_fnc_stageGroupAtEdge;
MISSION_CORE_fnc_stageGroupAtEdge = {
    params ["_grp", "_srcPos", "_srcSize", "_tgtPos"];
    private _rad = if (count _srcSize > 0) then { (_srcSize select 0) max 1 } else { 200 };
    private _dir = _srcPos getDir _tgtPos;
    private _stagePos = _srcPos getPos [_rad, _dir];
    if (_stagePos isEqualTo _srcPos) then { _stagePos = _srcPos getPos [250, _dir]; };
    _stagePos = [_stagePos, _srcPos] call MISSION_CORE_fnc_safeWaypointPos;
    [_grp] call MISSION_CORE_fnc_clearGroupWaypoints;
    _grp setBehaviour "SAFE";
    _grp setCombatMode "YELLOW";
    _grp setSpeedMode "LIMITED";
    private _wp = _grp addWaypoint [_stagePos, 30];
    _wp setWaypointType "MOVE";
    _wp setWaypointBehaviour "SAFE";
    _wp setWaypointCombatMode "YELLOW";
    _wp setWaypointSpeed "LIMITED";
    private _hwp = _grp addWaypoint [_stagePos, 0];
    _hwp setWaypointType "HOLD";
    _hwp setWaypointBehaviour "SAFE";
    _hwp setWaypointCombatMode "YELLOW";
    _hwp setWaypointSpeed "LIMITED";
    _grp setCurrentWaypoint _wp;
    _grp setVariable ["MISSION_CORE_ORDER", "staging"];
    _grp setVariable ["MISSION_CORE_ATTACK_TARGET", _tgtPos];
    _grp setVariable ["MISSION_CORE_STAGE_POS", _stagePos];
    _stagePos
};

// Stage a single committed REDFOR group at its source edge, facing the target. Thin REDFOR
// wrapper over the shared core: adds the staging formation (vehicles follow the leader) and
// registers the group in the REDFOR assault registry.
// [_grp, _srcPos, _srcSize, _tgtPos, _tgtSize, _tgtName] call MISSION_CORE_fnc_stageAssaultGroup;
MISSION_CORE_fnc_stageAssaultGroup = {
    params ["_grp", "_srcPos", "_srcSize", "_tgtPos", "_tgtSize", ["_tgtName", ""]];
    if (isNil "MISSION_CORE_ASSAULT_STAGED") then { call MISSION_CORE_fnc_resetStagedAssault; };
    private _stagePos = [_grp, _srcPos, _srcSize, _tgtPos] call MISSION_CORE_fnc_stageGroupAtEdge;
    private _dir = _srcPos getDir _tgtPos;
    _grp setVariable ["MISSION_CORE_ASSAULT_GROUP", true];
    // PERMANENT RULE (STAGED ARMOR FORMATION): vehicle-mounted groups hold their formation on the
    // leader while parked at the staging edge and roll out in column behind him once released. Each
    // driver/gunner follows the leader's slot (doFollow = "follow as my formation leader"), so tanks
    // arrive in a line instead of each free-driving. Skip the leader himself.
    if (({ objectParent _x != _x } count units _grp) > 0) then {
        private _fLdr = leader _grp;
        { if (_x != _fLdr) then { _x doFollow _fLdr; }; } forEach units _grp;
    };
    MISSION_CORE_ASSAULT_STAGED set [groupId _grp, [_grp, _tgtPos, _tgtSize, _tgtName]];
    diag_log format ["STAGED ASSAULT: %1 staging at %2 on bearing %3 toward %4", groupId _grp, _stagePos, round _dir, _tgtName];
    _grp
};

// Release every staged group on the current REDFOR assault toward the target.
// [_tgtPos, _tgtSize, _tgtName] call MISSION_CORE_fnc_releaseStagedAssault;
MISSION_CORE_fnc_releaseStagedAssault = {
    params ["_tgtPos", "_tgtSize", ["_tgtName", ""]];
    if (isNil "MISSION_CORE_ASSAULT_STAGED") exitWith {};
    private _staged = values MISSION_CORE_ASSAULT_STAGED;
    MISSION_CORE_ASSAULT_STAGED = createHashMap;
    {
        private _grp = _x select 0;
        if (isNull _grp || { count units _grp == 0 }) then { continue; };
        _grp setVariable ["MISSION_CORE_ORDER", "counterattack"];
        [_grp, _tgtPos, _tgtSize] call MISSION_CORE_fnc_sendCounterAttack;
        diag_log format ["STAGED ASSAULT: %1 released toward %2", groupId _grp, _tgtName];
    } forEach _staged;
};

// WATCHDOG SAFETY (shared): the attack-stuck watchdog spare-releases any group whose ATTACK_TARGET
// is more than 100m from a live contested-zone center ("stale order" path). A counter-attack aims at
// the nearest player's live position, which on a large marker can easily sit further out than 100m
// from its center - without snapping the target var the watchdog would send a staging force back to
// patrol one group at a time. Snap ATTACK_TARGET to the nearest same-side contested-zone center (the
// waypoint store already faces the real position, and release re-tasks the LIVE push target at release,
// so this var only feeds the watchdog).
MISSION_CORE_fnc_snapAttackTargetToZone = {
    params ["_grp", "_side", "_targetPos"];
    // TWO SEPARATE QUESTIONS, TWO SEPARATE VARS.
    // (1) contested NAMES - MISSION_CORE_CONTESTED only, written solely by fn_isMarkerContested.
    // (2) POSITIONS - MISSION_CORE_CACHED_POSITIONS, for the nearest-contested-marker search.
    private _nearest = [];
    private _bestD = 1e10;
    if (!isNil "MISSION_CORE_CONTESTED" && { !isNil "MISSION_CORE_CACHED_POSITIONS" }) then {
        {
            private _n = _x;
            private _i = MISSION_CORE_CACHED_POSITIONS findIf { (_x select 0) == _n };
            if (_i >= 0) then {
                private _row = MISSION_CORE_CACHED_POSITIONS select _i;
                private _d = (_row select 1) distance2D _targetPos;
                if (_d < _bestD) then { _bestD = _d; _nearest = _row; };
            };
        } forEach (keys MISSION_CORE_CONTESTED);
    };
    if (count _nearest > 0) then { _grp setVariable ["MISSION_CORE_ATTACK_TARGET", _nearest select 1]; };
};

// SUPPLY-REUSE ABSORPTION HOOK: the marker's OWN supply pipeline (fn_replenishMarker /
// fn_queuedReplenish) calls this while an assembled counter-attack is still filling at the marker.
// If the marker has an active staged-assembly (MISSION_CORE_STAGING_BUDGET keyed by origin name)
// and men are still owed, the arriving supply squad is ABSORBED into the staging roster instead of
// marching to the contested center - it stages at the source edge on the bearing to the target, is
// tagged as an assault group, and its men are counted against the assembly's manpower need. The
// grouped budget from requestManpower is NOT spent on these men (the supply pipeline already paid
// for them from the marker's local pool); it only tops up the shortfall via the fallback.
// [_grp, _locName, _locPos, _markerSize, _side] call MISSION_CORE_fnc_tryAbsorbSupply; -> bool
// Would tryAbsorbSupply take this squad? EXACTLY its first four guards, with no group.
//
// fn_tryAbsorbSupply needs a LIVE group - it counts units _grp and pushes _grp onto the staging
// roster - so a caller cannot ask "is absorption available?" before it has spawned anything. The
// abstract-leg path must ask exactly that question first, because absorption takes PRIORITY over
// marching a squad to a contested marker: if a staged assembly is filling here, the squad belongs
// to the staging roster and must never be turned into a leg. Mirroring the guards here is what lets
// the caller skip abstraction without changing which branch wins.
//
// Kept adjacent to, and deliberately duplicative of, the guards above: if the two ever drift, a
// squad would silently go to the contested center instead of the staging edge.
// [_locName, _side] call MISSION_CORE_fnc_hasActiveStaging; -> bool
MISSION_CORE_fnc_hasActiveStaging = {
    params ["_locName", "_side"];
    if (isNil "MISSION_CORE_STAGING_BUDGET") exitWith { false };
    private _entry = MISSION_CORE_STAGING_BUDGET getOrDefault [_locName, missionNamespace];
    if (_entry isEqualTo missionNamespace) exitWith { false };
    if ((_entry get "side") != _side) exitWith { false };
    if ((_entry get "menNeeded") <= 0) exitWith { false };
    true
};

MISSION_CORE_fnc_tryAbsorbSupply = {
    params ["_grp", "_locName", "_locPos", "_markerSize", "_side"];
    if (isNil "MISSION_CORE_STAGING_BUDGET") exitWith { false };
    private _entry = MISSION_CORE_STAGING_BUDGET getOrDefault [_locName, missionNamespace];
    if (_entry isEqualTo missionNamespace) exitWith { false };
    if ((_entry get "side") != _side) exitWith { false };
    if ((_entry get "menNeeded") <= 0) exitWith { false };
    private _men = count units _grp;
    _entry set ["menNeeded", ((_entry get "menNeeded") - _men) max 0];
    (_entry get "roster") pushBack _grp;
    _grp setVariable ["MISSION_CORE_ASSAULT_GROUP", true];
    _grp setVariable ["MISSION_CORE_ASSAULT_COMBAT", "RED"];
    // These men are dispatched OUTWARD now - their deaths must not count against the marker's
    // retreat tally (garrison-only tally rule in fn_spawnGroup.sqf). MISSION_CORE_ORIGIN_MARKER is
    // kept so the marker's alive-garrison count stays honest while they hold at the staging edge.
    _grp setVariable ["MISSION_CORE_CASUALTY_MARKER", nil];
    [_grp, _locPos, _markerSize, (_entry get "targetPos")] call MISSION_CORE_fnc_stageGroupAtEdge;
    // Same watchdog snap as spawnAssaultGroup - the staged waypoint faces the live target, but the
    // ATTACK_TARGET var feeds only the stuck-watchdog and must point at a contested-zone center.
    [_grp, _side, (_entry get "targetPos")] call MISSION_CORE_fnc_snapAttackTargetToZone;
    diag_log format ["SUPPLY ABSORB: %1 +%2 men rerouted into staged counter-attack (menNeeded rem %3)", _locName, _men, _entry get "menNeeded"];
    true
};

// Release monitor for the ASSEMBLED full counter-attack (fn_assembleAssault). SUPPLY-REUSE HYBRID:
// the whole staged force holds at the source edge until it is COMPLETE - the requested foot manpower
// is first routed in from the marker's OWN supply pipeline (replenish/budget squads are absorbed via
// tryAbsorbSupply while the SUPPLY WINDOW is open, counterAttackSupplyTTL); when the window closes
// short, the pooled requestManpower budget tops up the difference (fallback spawn), so a marker
// running at full garrison still forms its counter-attack. Only then does the force advance: every
// remaining group must have physically reached its STAGE_POS (the last "arrived" group gates the
// whole push, exactly like the recruit staging wait) before every group is released TOGETHER against
// the target. Groups that died out are dropped; if none survive the wait the assault is aborted and
// the pooled budget refunded. Runs from MISSION_CORE_STAGING_BUDGET keyed by origin marker - its OWN
// registry, never the REDFOR MISSION_CORE_ASSAULT_STAGED registry, so an overlapping aiAssaultLoop
// resetStagedAssault / releaseStagedAssault can never touch this assault's staging.
// FLIP BEHAVIOR (per design): a RELEASED staged force is deliberately reusable as an assault force
// rather than a bespoke script - release always funnels through one shared release block (ORDER +
// sendCounterAttack + ordered-vehicle tag) so any caller can aim an assembled roster at any target.
// If the ORIGIN marker flips to the enemy BEFORE release (during the supply window OR the all-arrived
// hold), the assembly does NOT die: the staged roster holds at the source edge and re-targets to the
// next LIVE objective - the aiAssaultLoop's current assault target first, else the nearest
// player-contested REDFOR zone (getContestedMarkers also lists markers captured from us while a player
// is near, so the flipped origin itself re-enters as a retake target). The moment one is live the
// roster releases immediately in ASSAULT posture (ORDER "attack" - capture-eligible through the
// occupation revert path). If the origin flips EN ROUTE after a normal release, the survivors are
// switched to ORDER "attack" and re-aimed at the next live objective - the shared collection then owns
// them (stale-order release, occupation revert, assault-loop rejoin). Wipe at any point still ends the
// monitor quietly (budget already refunded, window already closed).
// [_originName] spawn MISSION_CORE_fnc_releaseCounterStaged;
MISSION_CORE_fnc_releaseCounterStaged = {
    params ["_originName"];
    if (isNil "MISSION_CORE_STAGING_BUDGET") exitWith {};
    private _entry = MISSION_CORE_STAGING_BUDGET getOrDefault [_originName, missionNamespace];
    if (_entry isEqualTo missionNamespace) exitWith {};
    private _side = _entry get "side";
    private _targetPos = _entry get "targetPos";
    private _tgtSize = _entry get "tgtSize";
    private _tgtName = _entry get "tgtName";
    private _funded = _entry get "funded";
    private _donors = _entry get "donors";
    private _roster = _entry get "roster";
    private _ttl = ["counterAttackSupplyTTL", 90] call MISSION_CORE_fnc_tune;
    private _aborted = false;
    private _retarget = false;
    // PHASE 1 - SUPPLY WINDOW: keep the absorption hook open while men are still owed and the window
    // has not elapsed. Abort if the whole staged roster dies before any manpower is routed in. If the
    // ORIGIN marker flips to the enemy while staging, the assembly does NOT die - it flags RETARGET
    // and re-aims at the next live objective instead (see the retarget block below).
    while { (time - (_entry get "created")) < _ttl && { (_entry get "menNeeded") > 0 } } do {
        sleep 2;
        _roster = _entry get "roster";
        private _aliveList = _roster select { !isNull _x && { count units _x > 0 } };
        if (count _roster > 0 && { count _aliveList == 0 }) exitWith { _aborted = true; };
        if (!(isNil "MISSION_CORE_CACHED_POSITIONS")) then {
            private _oNow = (MISSION_CORE_CACHED_POSITIONS select { (_x select 0) == _originName }) param [0, []];
            if (count _oNow > 0 && { (_oNow select 4) != _side }) exitWith { _retarget = true; };
        };
    };
    // PHASE 2 - MANPOWER TOP-UP: refund the pooled budget, but first spend what remains on the
    // foot squads the supply window failed to deliver (each fallback spawn also decrements men owed).
    // Skipped when re-targeting - the origin is gone, so no more men are spawned on its assembly;
    // the leftovers are refunded and the staged roster is carried as-is into the re-target.
    if (!_aborted && { !_retarget }) then {
        while { (_entry get "menNeeded") > 0 && { _funded >= (_entry get "minInfMen") } && { count (_entry get "infTemplates") > 0 } } do {
            private _grp = [(_entry get "infTemplates"), _side, _entry get "faction", _entry get "importance", _entry get "originPos", _targetPos, _originName, true, _tgtName, _entry get "originSize"] call MISSION_CORE_fnc_spawnAssaultGroup;
            if (isNull _grp) then { break; };
            private _men = count units _grp;
            _funded = _funded - _men;
            _entry set ["menNeeded", ((_entry get "menNeeded") - _men) max 0];
            _roster pushBack _grp;
            sleep 0.4;
        };
    };
    if (_funded > 0) then { [_donors, _funded] call MISSION_CORE_fnc_refundManpower; };
    if (_aborted) exitWith {
        diag_log format ["COUNTER-ATTACK: %1 staging aborted - pooled budget refunded", _originName];
        MISSION_CORE_STAGING_BUDGET deleteAt _originName;
    };
    // Close the supply window so no later supply squad gets absorbed into this finished assembly.
    MISSION_CORE_STAGING_BUDGET deleteAt _originName;

    // SHARED RELEASE (reusable): dispatch the ENTIRE staged roster toward ONE target under ONE
    // order - a single code path for the normal counter-attack release, the origin-flip re-target
    // release and the en-route assault conversion, so a staged force is always aimed through the
    // same assault machinery instead of bespoke per-case behavior.
    private _releaseStaged = {
        params ["_pos", "_size", "_order", "_label"];
        private _rel = 0;
        {
            if (isNull _x || { count units _x == 0 }) then { continue; };
            private _combat = _x getVariable ["MISSION_CORE_ASSAULT_COMBAT", "RED"];
            _x setVariable ["MISSION_CORE_ORDER", _order];
            [_x, _pos, _size, _combat, _order] call MISSION_CORE_fnc_sendCounterAttack;
            // Ordered away now - tag land vehicles at RELEASE only, so while they held at the source
            // edge during staging the ordered-vehicle sweeper never recycled a deliberately-parked tank.
            {
                private _v = vehicle _x;
                if (_v != _x && { _v isKindOf "LandVehicle" }) then {
                    [_v, _pos] call MISSION_CORE_fnc_tagOrderedVehicle;
                };
            } forEach units _x;
            _rel = _rel + 1;
        } forEach _roster;
        diag_log format ["COUNTER-ATTACK: %1 released %2 groups toward %3 (%4)", _originName, _rel, _label, _order];
    };
    // NEXT LIVE OBJECTIVE (reusable): the aiAssaultLoop's CURRENT assault target if one is live,
    // else the nearest player-contested / recent-retake REDFOR zone to _fromPos. Returns [] only
    // when nothing is live at this instant.
    private _nextLiveObjective = {
        params ["_side", "_fromPos"];
        if (!(isNil "MISSION_CORE_ASSAULT_ACTIVE") && { MISSION_CORE_ASSAULT_ACTIVE } && { !(isNil "MISSION_CORE_ASSAULT_TARGET") } && { MISSION_CORE_ASSAULT_TARGET != "" } && { !(isNil "MISSION_CORE_CACHED_POSITIONS") }) then {
            private _tName = MISSION_CORE_ASSAULT_TARGET;
            private _idx = MISSION_CORE_CACHED_POSITIONS findIf { (_x select 0) == _tName };
            if (_idx >= 0) exitWith {
                private _l = MISSION_CORE_CACHED_POSITIONS select _idx;
                private _sz = if (count _l > 8) then { _l select 8 } else { [50, 50] };
                [(_l select 0), (_l select 1), _sz]
            };
        };
        // Contested NAMES from MISSION_CORE_CONTESTED (written solely by fn_isMarkerContested); the
        // POSITIONS used to find the nearest live objective come from MISSION_CORE_CACHED_POSITIONS.
        // Two separate vars answering two separate questions.
        private _best = [];
        private _bd = 1e10;
        if (!isNil "MISSION_CORE_CONTESTED" && { !isNil "MISSION_CORE_CACHED_POSITIONS" }) then {
            {
                private _n = _x;
                private _i = MISSION_CORE_CACHED_POSITIONS findIf { (_x select 0) == _n };
                if (_i >= 0) then {
                    private _row = MISSION_CORE_CACHED_POSITIONS select _i;
                    private _d = (_row select 1) distance2D _fromPos;
                    if (_d < _bd) then { _best = _row; _bd = _d; };
                };
            } forEach (keys MISSION_CORE_CONTESTED);
        };
        if (count _best == 0) exitWith { [] };
        [(_best select 0), (_best select 1), (_best select 2)]
    };
    // RETARGET ACQUISITION (reusable): hold the roster staged and poll for the next live objective,
    // returning [name,pos,size] the MOMENT one is live (immediate release - nothing is held back).
    // [] means the whole staged force was wiped while waiting.
    private _retargetAcquire = {
        params ["_side", "_fromPos"];
        private _out = [];
        while { count _out == 0 } do {
            sleep 2;
            private _alive = _roster select { !isNull _x && { count units _x > 0 } };
            if (count _alive == 0) exitWith { _out = []; };
            _out = [_side, _fromPos] call _nextLiveObjective;
        };
        _out
    };

    if (_retarget) then {
        // ORIGIN FLIPPED BEFORE RELEASE - the staged roster holds at the source edge and waits for
        // the next LIVE objective (ai-assault target, else nearest contested / retake zone - the
        // flipped origin itself re-enters as a retake target while a player is near it). The moment
        // one is live the force releases immediately in ASSAULT posture (ORDER "attack",
        // capture-eligible through the occupation revert path).
        diag_log format ["COUNTER-ATTACK: %1 origin flipped while staging - %2 staged groups held, waiting for next live target", _originName, count (_roster select { !isNull _x && { count units _x > 0 } })];
        private _obj = [_side, (_entry get "originPos")] call _retargetAcquire;
        if (count _obj == 0) exitWith {
            diag_log "COUNTER-ATTACK: staged force wiped during re-target wait - abandoned";
        };
        [(_obj select 1), (_obj select 2), "attack", (_obj select 0)] call _releaseStaged;
    } else {
        // PHASE 3 - ALL-ARRIVED WAIT (no timeout), while the origin still stands. If the origin
        // flips DURING this hold, jump to the retarget block instead of releasing toward a dead source.
        private _arrived = false;
        while { !_arrived && { !_retarget } } do {
            sleep 2;
            private _remaining = _roster select { !isNull _x && { count units _x > 0 } };
            if (count _remaining == 0) exitWith {};  // full wipe - handled after the loop
            if (!(isNil "MISSION_CORE_CACHED_POSITIONS")) then {
                private _oNow = (MISSION_CORE_CACHED_POSITIONS select { (_x select 0) == _originName }) param [0, []];
                if (count _oNow > 0 && { (_oNow select 4) != _side }) then { _retarget = true; };
            };
            if (!_retarget) then {
                _arrived = true;
                {
                    // A group counts as "arrived" when it is physically at the source-edge staging
                    // line OR it has LEFT staging (ORDER != "staging" - the attack-stuck watchdog
                    // relocated a truly stuck group near the contested zone, or another path re-tasked
                    // it). A re-tasked group can never reach STAGE_POS; with a no-timeout joint wait
                    // it would otherwise hang the whole force forever. Every remaining group must
                    // satisfy one of the two to release.
                    private _stl = _x getVariable ["MISSION_CORE_ORDER", ""];
                    if (_stl == "staging") then {
                        private _stagePos = _x getVariable ["MISSION_CORE_STAGE_POS", []];
                        if (count _stagePos > 0 && { (leader _x) distance2D _stagePos > 60 }) then { _arrived = false; };
                    };
                } forEach _remaining;
            };
        };
        if (count (_roster select { !isNull _x && { count units _x > 0 } }) == 0) exitWith {
            diag_log "COUNTER-ATTACK: staged force wiped before release - assault aborted";
        };
        if (_retarget) then {
            // Origin flipped during the all-arrived hold - same retarget as the supply-window flip.
            diag_log format ["COUNTER-ATTACK: %1 origin flipped during all-arrived hold - %2 staged groups re-targeted", _originName, count (_roster select { !isNull _x && { count units _x > 0 } })];
            private _obj = [_side, (_entry get "originPos")] call _retargetAcquire;
            if (count _obj == 0) exitWith {
                diag_log "COUNTER-ATTACK: staged force wiped during re-target wait - abandoned";
            };
            [(_obj select 1), (_obj select 2), "attack", (_obj select 0)] call _releaseStaged;
        } else {
            // PHASE 4 - RELEASE TOGETHER toward the original counter-attack target (counterattack
            // posture). The shared release block keeps this path identical to any other release.
            [_targetPos, _tgtSize, "counterattack", _tgtName] call _releaseStaged;
            // PHASE 5 - EN-ROUTE FLIP WATCH (bounded, counterAttackFlipWatchTTL): should the ORIGIN
            // flip while the released force is still advancing, convert the survivors to ASSAULT
            // posture (ORDER "attack") so the shared collection (occupation revert, capture path,
            // stale-order release, assault-loop rejoin) owns them as a real assault force. The force
            // KEEPS attacking its live target; only if that target cleared does it re-aim at the next
            // live objective. Ends once every group reaches the target / dies, or right after the
            // one-time conversion.
            private _converted = false;
            private _watchUntil = time + (["counterAttackFlipWatchTTL", 600] call MISSION_CORE_fnc_tune);
            while { time < _watchUntil && { !_converted } } do {
                sleep 3;
                private _advancing = _roster select {
                    !isNull _x && { count units _x > 0 } &&
                    { (_x getVariable ["MISSION_CORE_ORDER", ""]) in ["counterattack", "attack"] } &&
                    { (leader _x) distance2D _targetPos > ((_tgtSize select 0) max (_tgtSize select 1)) }
                };
                if (count _advancing == 0) exitWith {};  // all arrived / wiped - watch done
                if (!(isNil "MISSION_CORE_CACHED_POSITIONS")) then {
                    private _oNow = (MISSION_CORE_CACHED_POSITIONS select { (_x select 0) == _originName }) param [0, []];
                    if (count _oNow > 0 && { (_oNow select 4) != _side }) then {
                        _converted = true;
                        // Contested state comes ONLY from MISSION_CORE_CONTESTED (written solely by
                        // fn_isMarkerContested). _tgtName is already a marker name, so this is a
                        // direct membership test - no derived zone list, no independent opinion.
                        private _tgtStillLive = _tgtName != "" && {
                            (!isNil "MISSION_CORE_CONTESTED") && { _tgtName in MISSION_CORE_CONTESTED }
                        };
                        if (_tgtStillLive) then {
                            diag_log format ["COUNTER-ATTACK: %1 origin flipped en route - %2 advancing groups converted to assault posture, keep pressing %3", _originName, count _advancing, _tgtName];
                            [_targetPos, _tgtSize, "attack", _tgtName] call _releaseStaged;
                        } else {
                            private _obj = [_side, _targetPos] call _nextLiveObjective;
                            if (count _obj == 0) then {
                                diag_log format ["COUNTER-ATTACK: %1 origin flipped en route - %2 advancing groups converted to assault posture, no live target yet", _originName, count _advancing];
                                continue;
                            };
                            diag_log format ["COUNTER-ATTACK: %1 origin flipped en route - %2 advancing groups converted to assault posture, re-aimed at %3", _originName, count _advancing, _obj select 0];
                            [(_obj select 1), (_obj select 2), "attack", (_obj select 0)] call _releaseStaged;
                        };
                    };
                };
            };
        };
    };
};