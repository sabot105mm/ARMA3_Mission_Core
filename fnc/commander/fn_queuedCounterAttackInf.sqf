
// Queued spawn jobs (called by the queue loop, return true when the spawn actually happened)

MISSION_CORE_fnc_queuedCounterAttackInf = {
    params ["_side", "_template", "_spawnPos", "_faction", "_importance", "_provPos", "_provSize", "_provName", "_targetPos", "_targetSize", ["_targetName", ""], ["_remaining", 0], ["_squadIndex", 0], ["_infPool", []], ["_interest", 1]];
    // HARD CAP: the zone's pool may have been spent while this sat in the queue - never release
    // a squad from an exhausted zone (the budget exit stamped MISSION_CORE_REINF_EXHAUSTED for it).
    // A zone that has hit its 200 ceiling is DONE - it will not come back under this dispatch, so the
    // job is terminal. This used to return false (retry), which made a permanently exhausted zone
    // spin the job every reinfQueueRetryDelay until the 60-attempt limit, ~20 minutes of futile
    // retries and log spam per queued squad.
    if (_targetName != "" && { isNil "MISSION_CORE_REINF_EXHAUSTED" || { MISSION_CORE_REINF_EXHAUSTED getOrDefault [_targetName, false] } }) exitWith {
        diag_log format ["DYNAMIC QUEUE: dropped queued counter-attack inf %1 from %2 - zone %3 pool exhausted", _template select 0, _provName, _targetName];
        true
    };
    // The target may have gone quiet while this sat in the queue. It still counts as worth
    // reinforcing if a live player OR any contested marker is near it - requiring a player alone
    // dropped valid orders in player-less squad battles.
    if !([_targetPos] call MISSION_CORE_fnc_counterAttackWorthReleasing) exitWith {
        diag_log format ["DYNAMIC QUEUE: dropped queued counter-attack inf %1 - target %2 has no player and no contested marker nearby", _template select 0, _targetName];
        true
    };
    if !([_side, "inf", _provPos] call MISSION_CORE_fnc_townCategoryCanUse) exitWith { false };
    // ---- RE-TASK FIRST: draw an idle garrison squad off this provider before conjuring one ----
    // Deliberately placed ABOVE the three gates below. A re-tasked squad needs none of them: it
    // creates nothing (no spawner slot), is already counted in the global foot cap (it is not a new
    // squad), and spends no manpower (so providerCanAfford is irrelevant). Putting this after any of
    // them would mean a provider that has idle men but no supply left could never use them - exactly
    // backwards, and the whole point of preferring a re-task.
    private _sideVar = if (_side == WEST) then { "MISSION_CORE_BLUFOR" } else { "MISSION_CORE_REDFOR" };
    private _grp = [_sideVar, _provName, _targetPos, _targetSize] call MISSION_CORE_fnc_claimReinforcementSquad;
    if (!isNull _grp) exitWith {
        // Men really do arrive at the zone, so the zone's 200 cap is charged on the squad's ACTUAL
        // strength, not the template's assumed size. A real garrison squad is often smaller than the
        // template it would have replaced.
        private _rtMen = count units _grp;
        if (_targetName != "") then {
            private _rtSent = MISSION_CORE_REINF_SENT getOrDefault [_targetName, 0];
            if ((_rtSent + _rtMen) > (["reinfMenCapPerMarker", 200] call MISSION_CORE_fnc_tune)) exitWith {
                diag_log format ["DYNAMIC QUEUE: dropped re-tasked reinforcement from %1 - zone %2 already at %3 men", _provName, _targetName, _rtSent];
                true
            };
            MISSION_CORE_REINF_SENT set [_targetName, _rtSent + _rtMen];
        };
        // NO MISSION_CORE_COMMIT charge: no manpower was spent. These men were already charged when
        // this garrison spawned them.
        diag_log format ["DYNAMIC QUEUE: released RE-TASKED reinforcement %1 from %2 -> %3 (%4 men, no manpower charged)", groupId _grp, _provName, _targetName, _rtMen];
        // The job is consumed. The chain does NOT continue: a re-tasked squad cost no supply, so
        // letting it immediately claim another garrison squad would drain the provider's whole
        // garrison into one zone at supply-infinite speed.
        true
    };
    // Global foot-squad cap is hard at 10 enemy groups (PERMANENT RULE) - never bypass it,
    // even for an active battle. A queued squad waits for a slot to free up.
    // PENDING ABSTRACT LEGS COUNT IN THE CAP - this queue is a long-haul pipeline, so most of
    // its squads are legs, and a cap that cannot see them is no cap at all.
    if ((([_side] call MISSION_CORE_fnc_countFootSquads) + ([] call MISSION_CORE_fnc_countPendingAbstractLegs)) >= (["footSquadCapSquads", 10] call MISSION_CORE_fnc_tune)) exitWith { false };
    // The provider marker may have been captured while this spawn sat in the queue - never
    // spawn a counter-attack out of a marker the players now own.
    private _provNow = (MISSION_CORE_CACHED_POSITIONS select { (_x select 0) == _provName });
    if (count _provNow > 0 && { (_provNow select 0) select 4 != _side }) exitWith { false };
    // MANPOWER RESERVE (PERMANENT RULE): re-check at release time - the provider never ships so many
    // men that the men left at home drop below its own retreat threshold. MISSION_CORE_fnc_providerCanAfford
    // is the same test fn_neighborCounterAttack's dispatch walk runs, so the budget that promised
    // these men and the gate that releases them cannot disagree. Terminal: a drained provider will
    // not refill inside this queue pass.
    private _afford = [_provName, (_template select 2)] call MISSION_CORE_fnc_providerCanAfford;
    if !(_afford select 0) exitWith {
        diag_log format ["DYNAMIC QUEUE: dropped queued counter-attack inf %1 from %2 - home men above retreat threshold (stock=%3 committed=%4 squad=%5 retreatAt=%6)", _template select 0, _provName, _afford select 1, _afford select 2, _template select 2, _afford select 3];
        true
    };
    // THE QUEUE IS THE SEQUENCE. This is the only place a queued counter-attack actually
    // materialises, so the zone's 200 cap is charged HERE, on the squad that really spawns -
    // the dispatch no longer charges queued squads, which had spent the cap on men that did not
    // exist yet. Re-check the cap too: it may have been reached by direct spawns in the meantime.
    if (_targetName != "") then {
        private _qSent = MISSION_CORE_REINF_SENT getOrDefault [_targetName, 0];
        if ((_qSent + (_template select 2)) > (["reinfMenCapPerMarker", 200] call MISSION_CORE_fnc_tune)) exitWith {
            diag_log format ["DYNAMIC QUEUE: dropped queued counter-attack inf %1 - zone %2 already at %3/%4 men", _template select 0, _targetName, _qSent, ["reinfMenCapPerMarker", 200] call MISSION_CORE_fnc_tune];
            true
        };
    };
    // Claim the provider's spawner slot HERE, at release. The dispatch only TRIED to claim it; when
    // all 5 were busy it queued this provider instead of skipping it, so this is where the slot is
    // actually taken. A denial returns false so the job stays queued and retries on a later pass -
    // that is the whole point of the queue, and it is never a reason to drop the squad.
    if !([_provName, _side] call MISSION_CORE_fnc_spawnerSlotFree) exitWith {
        diag_log format ["DYNAMIC QUEUE: queued counter-attack inf %1 from %2 still waiting - all 5 spawner slots busy", _template select 0, _provName];
        false
    };
    // LONG HAUL? This queue exists precisely for long-range counter-attacks, so it is the
    // single biggest producer of legs. Nothing waits on the squad: it is released and sent,
    // and the self-feed successor is enqueued below on the same basis. Safe to abstract.
    private _legTaken = [
        "qcainf", _provName, _targetName,
        _provPos, _targetPos, _targetSize,
        [_template select 0, _side, _faction, _importance, _provPos, _provSize, _provName, _template select 2],
        {
            params ["_row", "_frac"];
            private _pl = _row select 5;
            private _at = [_row select 6, _row select 7, _frac] call MISSION_CORE_fnc_convoyPosAt;
            private _g = [_pl select 0, [_at select 0, _at select 1, 0], _pl select 1, _pl select 2, "AWARE", "NORMAL", _pl select 3, _pl select 4, _pl select 5] call MISSION_CORE_fnc_spawnGroup;
            if (!isNull _g) then {
                _g setVariable ["MISSION_CORE_ORIGIN_MARKER", _pl select 6];
                _g setVariable ["MISSION_CORE_IMPORTANCE", _pl select 3];
                if (isNil "MISSION_CORE_SPAWNED_GROUPS") then { MISSION_CORE_SPAWNED_GROUPS = []; };
                MISSION_CORE_SPAWNED_GROUPS pushBack _g;
                // MANPOWER IS COMMITTED HERE, ON SPAWN - the same write as line 102 below, moved.
                // A leg has spent nothing, so the provider is still whole while it travels.
                MISSION_CORE_COMMIT set [_pl select 6, (MISSION_CORE_COMMIT getOrDefault [_pl select 6, 0]) + _pl select 7];
            };
            _g
        },
        {
            params ["_g", "_row"];
            if (isNull _g) exitWith {};
            [_g, _row select 3, _row select 4] call MISSION_CORE_fnc_sendCounterAttack;
        }
    ] call MISSION_CORE_fnc_abstractLegDispatch;
    // LONG-HAUL GATE: a queued C/A foot squad at/over the abstraction threshold belongs to the
    // leg system (this queue is the biggest leg producer), not to a truck-ride or foot slog. The
    // dispatch above already tried to leg it, straight-line fallback included; only conjure a
    // squad when the haul is under the threshold, so a far unabstractable pair is never spent on
    // a doomed conjure.
    private _skipConjure = false;
    private _minG = ["reinforceAbstractMinDist", 2000] call MISSION_CORE_fnc_tune;
    if !(_minG isEqualType 1) then { _minG = 2000; };
    if (_legTaken) then {
        // Published against the zone's 200 cap even though nothing spawned - these men are
        // committed and the cap is a MEN budget. But the provider is NOT charged: that waits
        // for the spawn above.
        if (_targetName != "") then {
            MISSION_CORE_REINF_SENT set [_targetName, (MISSION_CORE_REINF_SENT getOrDefault [_targetName, 0]) + (_template select 2)];
        };
        diag_log format ["ABSTRACT LEG: queued counter-attack inf %1 from %2 promised -> %3", _template select 0, _provName, _targetName];
    } else {
        if ((_provPos distance2D _targetPos) >= _minG) then {
            _skipConjure = true;
            diag_log format ["LONG HAUL REINF: queued C/A inf %1 -> %2 is %3m (>= %4m); abstract declined - skipping conjure", _provName, _targetName, round (_provPos distance2D _targetPos), _minG];
        };
        if (!_skipConjure) then {
        private _conjured = [_template select 0, _spawnPos, _side, _faction, "AWARE", "NORMAL", _importance, _provPos, _provSize] call MISSION_CORE_fnc_spawnGroup;
    if (isNull _conjured) exitWith { false };
    // _conjured, never _grp. On this path the re-task lookup above already failed, so _grp is NULL
    // here; tagging it threw a runtime error that aborted the rest of this function - the squad was
    // never pushed to MISSION_CORE_SPAWNED_GROUPS, never ordered, never charged, and the zone's cap
    // was never spent. Approved provider budgets silently vanished into spawned-but-inert groups.
    _conjured setVariable ["MISSION_CORE_ORIGIN_MARKER", _provName];
    _conjured setVariable ["MISSION_CORE_IMPORTANCE", _importance];
    if (isNil "MISSION_CORE_SPAWNED_GROUPS") then { MISSION_CORE_SPAWNED_GROUPS = []; };
    MISSION_CORE_SPAWNED_GROUPS pushBack _conjured;
    [_conjured, _targetPos, _targetSize] call MISSION_CORE_fnc_sendCounterAttack;
    MISSION_CORE_COMMIT set [_provName, (MISSION_CORE_COMMIT getOrDefault [_provName, 0]) + (_template select 2)];
        };
    };
    // The squad exists now, so it counts against the zone's cap now. Done inside the queue loop's
    // single thread, where this charge cannot race a dispatch worker's own publish. An abstract leg
    // published this above instead - either way the cap is charged exactly once per promised squad.
    if (!_legTaken && { !_skipConjure } && { _targetName != "" }) then {
        MISSION_CORE_REINF_SENT set [_targetName, (MISSION_CORE_REINF_SENT getOrDefault [_targetName, 0]) + (_template select 2)];
    };
    diag_log format ["DYNAMIC QUEUE: released queued counter-attack inf %1 from %2 -> %3", _template select 0, _provName, _targetName];
    // SELF-FEED THE SEQUENCE. Exactly one job per provider sits in the queue at a time, and it
    // enqueues its successor only now, after this squad has actually spawned. The dispatch used to
    // push every one of a provider's squads into the queue in one burst, which pre-committed men
    // for squads that had not spawned and buried the queue behind work that could be stale.
    if (_remaining > 0 && { count _infPool > 0 }) then {
        private _nextIdx = _squadIndex + 1;
        private _nextTpl = selectRandom _infPool;
        // Recompute the rally point: a squad that waited minutes should march from where the
        // provider is now, not from a stale pre-queued position.
        private _nextPos = [_provPos, _provSize, 30, (_provPos getDir _targetPos), true] call MISSION_CORE_fnc_findVehiclePos;
        // INTEREST CADENCE. The successor inherits this provider's own interest, so the gap
        // between ITS squads is that provider's pace, not one global number. This is the only
        // place the cadence is applied, and it is a release-to-release delay: the squad that was
        // just released is what the wait is measured from.
        private _gap = [_interest] call MISSION_CORE_fnc_reinfInterestInterval;
        ["MISSION_CORE_fnc_queuedCounterAttackInf", format ["cainf_%1_%2_%3", _provName, _targetName, _nextIdx], [_side, _nextTpl, _nextPos, _faction, _importance, _provPos, _provSize, _provName, _targetPos, _targetSize, _targetName, _remaining - 1, _nextIdx, _infPool, _interest], time + _gap] call MISSION_CORE_fnc_enqueueSpawn;
        // Same trap as fn_neighborCounterAttack: `round` is unary, so the rounding is
        // hoisted OUT of the format array. A bare `_interest round 100` inside `[...]` reads as one
        // element and runs on past the comma -> "Error Missing ]".
        private _iRpt = (round (_interest * 100)) / 100;
        private _gRpt = (round _gap * 10) / 10;
        diag_log format ["DYNAMIC QUEUE: %1 -> %2 queued next squad %3 of %4 (interest %5 -> due in %6s)", _provName, _targetName, _nextIdx, _squadIndex + _remaining, _iRpt, _gRpt];
    };
    true
};
