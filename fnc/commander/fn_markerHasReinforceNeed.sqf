// DOES THIS MARKER STILL OWE A FIGHT?
//
// The gate that keeps player hunts out of reinforcement waves and counter-attacks. A hunt is the
// LOWEST-priority use of a marker's men: it is discretionary pressure against one player, while a
// contested marker is the mission's actual fight. So while a marker has any live reinforcement
// demand, it dispatches NO hunt contingent at all - not a re-tasked garrison squad, not a conjured
// foot squad, not an MBT, not an APC.
//
// WHY THIS IS ASKED AS A QUESTION ABOUT THE MARKER, NOT ABOUT THE SQUAD
//
// The obvious cheaper gate is "has this provider already committed squads?" - scan the spawn queue
// for a cainf_/reinf_ key naming it, or check MISSION_CORE_REINF_INFLIGHT for a dispatch in flight.
// That is REACTIVE: it only reports a fight once squads are already queued or marching, so a hunt
// can spend a garrison squad in the window between a zone turning critical and the first dispatch
// reaching this provider.
//
// Asking the BUDGET instead is predictive - it closes that window - and it is strictly cheaper,
// because MISSION_CORE_fnc_providerBudget already answers the dispatcher's own question. Reusing it
// means this gate inherits all six of its sub-gates for free (reserve floor, ammo, the
// [provider, contested] pair latch, contested value, asset proximity, distance taper) and cannot
// drift from what fn_neighborCounterAttack will actually decide. A hand-rolled approximation of
// "is it busy" would be a second opinion that eventually disagreed.
//
// NOTE ON MISSION_CORE_COMMIT: deliberately NOT used here. It is cumulative and never refunded (that
// is what makes a flickering zone re-evaluate its neighbours honestly), so it is a permanent-spend
// record, not a liveness one. Gating on it would permanently disable hunts at any marker that had
// ever reinforced once. Liveness is exactly what providerBudget's arithmetic already encodes.
//
// TIMING: this is called from fn_huntSpawnContingent, which runs inside the queue loop when the job
// is RELEASED - not at enqueue. The queue outlives the tick that created the job, and reinforcement
// state is precisely what moves during that wait, so a budget read at enqueue would be stale by the
// time the men were actually spent.
//
// usage - MISSION_CORE_fnc_markerHasReinforceNeed:
//   _srcRow  the SOURCE marker's CACHED_POSITIONS entry (not just its name)
//   _side    the hunting side
// returns: true when the marker still owes a contested marker at least one squad
MISSION_CORE_fnc_markerHasReinforceNeed = {
    params ["_srcRow", "_side"];
    if (count _srcRow == 0) exitWith { false };

    if (isNil "MISSION_CORE_REINF_EXHAUSTED") then { MISSION_CORE_REINF_EXHAUSTED = createHashMap; };
    // A zone that has hit its ceiling is done asking for help; a marker that only supports exhausted
    // zones owes nothing and is free to hunt. Same liveness filter fn_playerHunt uses for its own
    // pacing curve, so the two cannot disagree about which zones are still live.
    // Which zones are contested comes ONLY from MISSION_CORE_CONTESTED (written solely by
    // fn_isMarkerContested); each zone's CACHED POSITIONS ROW is the geometry, resolved by name just
    // below. Joining the two here forms no opinion about contested state.
    if (isNil "MISSION_CORE_CONTESTED") exitWith { false };
    if (count MISSION_CORE_CONTESTED == 0) exitWith { false };
    private _liveZoneNames = (keys MISSION_CORE_CONTESTED) select {
        !(MISSION_CORE_REINF_EXHAUSTED getOrDefault [_x, false])
    };
    if (count _liveZoneNames == 0) exitWith { false };

    // Deliberately loops EVERY live zone rather than only the nearest one. Nearest-only is cheaper
    // but wrong in a specific case: a marker pair-blocked from the closest fight may still be solvent
    // for a further one, and gating on the near zone alone would open the gate while it genuinely owes
    // men. Erring closed is the correct direction when reinforcement is meant to win.
    private _needs = false;
    {
        private _zName = _x;
        // A ZONE row is [_name, _pos, _size, _side] - 4 elements whose index 2 is the marker SIZE
        // array, NOT a CACHED_POSITIONS row. providerBudget wants a cached row (it reads _cLoc
        // select 7 for importance), so hand it the zone NAME and let it resolve the real row the way
        // fn_neighborCounterAttack does. Passing the zone row straight through reached
        // fn_getMarkerDetermination, whose `count _loc < 3` guard passed on the 4-element zone, then
        // did `toLower (_loc select 2)` on that size ARRAY -> "Type Array, expected String".
        private _zIdx = MISSION_CORE_CACHED_POSITIONS findIf { (_x select 0) == (_zName) };
        if (_zIdx < 0) then { continue; };
        private _zRow = MISSION_CORE_CACHED_POSITIONS select _zIdx;
        private _b = [_srcRow, _zRow, _side] call MISSION_CORE_fnc_providerBudget;
        if ((_b select 0) > 0) then {
            _needs = true;
        };
    } forEach _liveZoneNames;

    _needs
};