
// When a marker's garrison has ABANDONED the fight (crossed its determination casualty threshold
// and run away) and a player walks into the empty marker, the marker is OCCUPIED, not instantly
// captured. Ownership flips to the player side immediately, but the marker enters a 10-minute
// hold phase (see fn_occupationMonitor): the new owner gets NO defender spawns, the previous
// owner counter-attacks to win it back, and if the new owner leaves/dies inside the marker
// reverts to the previous owner. Only after holding for 10 minutes is the capture final.
// PERMANENT RULE: the garrison is NEVER wiped-captured - it self-replenishes to full strength
// while contested and only retreats at its retreat threshold, so this function is only ever
// reached via the retreat gate.
MISSION_CORE_fnc_captureMarkerForPlayers = {
    params ["_locName", "_locPos", "_owner", "_importance"];
    private _playerSide = if (_owner == WEST) then { EAST } else { WEST };
    if (isNil "MISSION_CORE_OCCUPATION") then { MISSION_CORE_OCCUPATION = createHashMap; };
    if (isNil "MISSION_CORE_MANPOWER") then { MISSION_CORE_MANPOWER = createHashMap; };
    if (isNil "MISSION_CORE_COMMIT") then { MISSION_CORE_COMMIT = createHashMap; };
    if (isNil "MISSION_CORE_MANPOWER_CUTOFF") then { MISSION_CORE_MANPOWER_CUTOFF = createHashMap; };

    // Ownership flips to the attacker immediately (cached positions + locations + marker color).
    [_locName, _playerSide] call MISSION_CORE_fnc_setMarkerOwner;

    // PERMANENT RULE: a freshly captured marker stays EMPTY of the capturer's own garrison until
    // the capturing player moves OUT of it and back IN. The proximity spawner honors this flag so
    // "my team" never materializes around the player the moment they take the marker.
    if (isNil "MISSION_CORE_CAPTURE_SUPPRESSED") then { MISSION_CORE_CAPTURE_SUPPRESSED = createHashMap; };
    MISSION_CORE_CAPTURE_SUPPRESSED set [_locName, true];

    // NO MISSION_CORE_CAPTURED_RETAKE ENTRY (removed). It used to record [_locName, [_owner, time]]
    // here purely so fn_getContestedMarkers could run its OWN "player within 3000m = contested"
    // check against a marker whose ownership had already flipped - a second, independent verdict on
    // contested state. With that removed, a capture no longer creates contested state by itself.
    //
    // WHAT STILL HAPPENS (deliberate): counter-attack and reinforce jobs already queued AT this
    // marker are kept and keep releasing until their zone pool is exhausted or maxed - the capture
    // does not cancel them. Only player hunts are dropped. So a base that just fell is still fought
    // over by the strength already in motion; it simply stops attracting new retake spawns, and the
    // occupation hold/revert below decides whether the capture sticks.
    //
    // Enter the occupation (hold) phase: occupier, previous owner, occupied-at timestamp. This is the
    // authoritative record of the capture and the clock the winding-down scale reads (see
    // fn_neighborCounterAttack / fn_requestReinforcement).
    MISSION_CORE_OCCUPATION set [_locName, [_playerSide, _owner, time]];
    // Wake the occupation monitor (no-op if it is already running).
    [] spawn MISSION_CORE_fnc_occupationMonitor;

    // The occupied marker stops resupplying/spawning from its own supply while it is held.
    MISSION_CORE_MANPOWER set [_locName, []];
    MISSION_CORE_COMMIT set [_locName, 0];
    MISSION_CORE_MANPOWER_CUTOFF deleteAt _locName;

    // The marker keeps its spawn slot even after capture (its reinforcement effort "gave up") -
    // only despawn (player moves away) frees it, so no fresh marker takes its place before then.

    // A capture is the ONE event that legitimately starts a new contest at this marker: ownership
    // changed hands, so the previous owner's retake (armed just above) gets a fresh budget. This is
    // deliberate and is not the old bug. Everywhere else the per-contest budget is only ever bled
    // back gradually by fn_reinforceDecayBudget - it is never hard-reset, which is what let a zone
    // re-latch with a full 200 the moment it went dormant.
    if (isNil "MISSION_CORE_REINF_SENT") then { MISSION_CORE_REINF_SENT = createHashMap; };
    if (isNil "MISSION_CORE_REINF_EXHAUSTED") then { MISSION_CORE_REINF_EXHAUSTED = createHashMap; };
    private _spentBudget = MISSION_CORE_REINF_SENT getOrDefault [_locName, 0];
    MISSION_CORE_REINF_SENT deleteAt _locName;
    MISSION_CORE_REINF_EXHAUSTED deleteAt _locName;
    if (_spentBudget > 0) then {
        diag_log format ["DYNAMIC CAPTURE: %1 reinforcement budget cleared (%2 men spent) - new owner, new contest", _locName, _spentBudget];
    };

// Queue surgery on capture.
    //
    // Counter-attack / reinforce jobs AIMED AT the captured marker are KEPT. This capture just armed
    // MISSION_CORE_CAPTURED_RETAKE precisely so the previous owner fights to win the base back, so
    // cancelling every inbound squad here would veto the retake the capture itself requested. They
    // are gated instead at RELEASE on the provider still being able to pay (provider ownership +
    // manpower reserve, in fn_queuedReinforce / fn_queuedCounterAttackInf / fn_queuedCounterAttackTank),
    // which is where a queue's real viability is decided - by the time a job releases, the provider
    // may have been drained or lost, and that check must not be frozen at enqueue.
    //
    // PLAYER HUNTS are the exception and ARE dropped. A hunt fields its contingent FROM a source
    // marker, so a hunt whose source is the marker the players just took would conjure enemy armor
    // and infantry out of ground the players now hold. Matched on the source marker name, not a
    // radius: a hunt's target is a player, so a distance test would be measuring the wrong thing.
    if (isNil "MISSION_CORE_SPAWN_QUEUE") then { MISSION_CORE_SPAWN_QUEUE = []; };
    private _kept = [];
    {
        private _drop = (_x select 0) isEqualTo "MISSION_CORE_fnc_queuedHuntContingent" && { ((_x select 2) param [6, ""]) == _locName };
        if (_drop) then {
            diag_log format ["DYNAMIC CAPTURE: dropped queued %1 - source marker %2 was just captured", _x select 0, _locName];
        } else {
            _kept pushBack _x;
        };
    } forEach MISSION_CORE_SPAWN_QUEUE;
    MISSION_CORE_SPAWN_QUEUE = _kept;

    diag_log format ["DYNAMIC CAPTURE: %1 occupied by %2 (garrison retreated) - hold 10min to secure", _locName, _playerSide];
    ["DynOps_MarkerOccupied",
        ["MARKER OCCUPIED", format ["%1 occupied - hold it for 10 minutes to secure it!", _locName]]
    ] remoteExec ["BIS_fnc_showNotification", 0];
};
