// When a marker's supporting neighborhood finally gives up - its neighbor reinforcement budget
// is spent, or its retake window has fully decayed - the whole supporting neighborhood goes
// dormant. Every spawned same-side marker within the 4000m reinforcement radius is fully
// despawned via MISSION_CORE_fnc_despawnLocation (garrison, defenses, and any counter-attack /
// reinforce groups still assembling there), so a dead zone's support never keeps feeding forever.
// Reversible: a player marching back in re-spawns a marker on demand.
// PERMANENT RULE: this is a NEIGHBORHOOD teardown only - the contested marker ITSELF never gives
// up (contested only clears via capture / all-threats-gone). It keeps self-replenishing with its
// own garrison; only its support pool stops answering.
//
// A neighbor that is its own active battle is left alone - never touch a marker currently
// contested by a player, or the side's locked zone focus (the fight lives there, and
// reinforcements may still need to flow to it).
MISSION_CORE_fnc_deactivateNeighborMarkers = {
    params ["_locName", "_locPos", "_side"];
    if (isNil "MISSION_CORE_SPAWNED_LOCATIONS") then { MISSION_CORE_SPAWNED_LOCATIONS = createHashMap; };
    if (isNil "MISSION_CORE_CACHED_POSITIONS") exitWith {};
    private _zoneFocus = if (_side == EAST) then { [EAST] call MISSION_CORE_fnc_getAIZoneFocus } else { "" };
    // ZONE HANDOFF SAFETY: when a neighborhood goes dormant, markers that are STILL chosen
    // neighbors of a live contested zone stay up - the fight moved there, and its supporting
    // markers must follow, not be torn down with the old zone.
    private _keep = [];
    if (!isNil "MISSION_CORE_fnc_getMarkerNeighbors") then {
        private _zones = [_side] call MISSION_CORE_fnc_getContestedMarkers;
        private _zoneNames = _zones apply { _x select 0 };
        {
            private _zPos = _x select 1;
            {
                if !((_x select 0) in _keep) then { _keep pushBack (_x select 0); };
            } forEach ([_x select 0, _zPos, _side, _zoneNames] call MISSION_CORE_fnc_getMarkerNeighbors);
        } forEach _zones;
    };
    {
        private _n = _x;
        private _nName = _n select 0;
        if (_nName == _locName) then { continue; };
        // Only markers that are actually up and running need to go dormant.
        if (!(MISSION_CORE_SPAWNED_LOCATIONS getOrDefault [_nName, false])) then { continue; };
        // Never touch a neighbor that is itself an active battle right now.
        if ([(_n select 1), _side, _nName] call MISSION_CORE_fnc_isMarkerContested) then { continue; };
        if (_nName == _zoneFocus) then { continue; };
        if (_nName in _keep) then { continue; };
        diag_log format ["DYNAMIC REINF: %1 gave up - deactivating neighbor %2", _locName, _nName];
        [_nName, _n select 1] call MISSION_CORE_fnc_despawnLocation;
    } forEach (MISSION_CORE_CACHED_POSITIONS select {
        (_x select 4) == _side &&
        { (_x select 0) != _locName } &&
        { ((_x select 1) distance _locPos) < (["neighborRange", 4000] call MISSION_CORE_fnc_tune) }
    });
};

// ZONE HANDOFF RE-EVALUATION: when the player's fight moves from an old contested marker to a
// new one, the supporting neighborhood follows the fight.
//   - DROP: every chosen neighbor of a replaced (gone) zone that no live zone chooses is
//     deactivated (its garrison / in-flight counter-attack groups go dormant).
//   - ADD: the new zone's closest chosen neighbors that are not already active are brought up
//     in their place, so the same number of markers support the fight. On a TRUE handoff those
//     new neighbors first get a one-time top-up back to full strength (capped at their own
//     capacity) before they are manpower-blocked for the continuing fight.
//   - BUDGET: a TRUE handoff (the new marker SHARES a chosen neighbor with the old one) INHERITS
//     the old marker's reinforcement ledgers - the neighbors were already investing in that
//     fight. A replaced marker with NO shared neighbor is reset to zero - a fresh fight draws a
//     fresh budget, not one carried over from an unrelated battle.
MISSION_CORE_fnc_reevalZoneNeighbors = {
    params ["_side", "_newZones", "_goneZones"];
    if (isNil "MISSION_CORE_CACHED_POSITIONS") exitWith {};
    if (isNil "MISSION_CORE_SPAWNED_LOCATIONS") then { MISSION_CORE_SPAWNED_LOCATIONS = createHashMap; };
    private _zoneList = [_side] call MISSION_CORE_fnc_getContestedMarkers;
    private _zoneNames = _zoneList apply { _x select 0 };
    // Every marker chosen by ANY live zone is kept (and brought up); shared neighbors survive.
    private _keep = [];
    {
        private _zPos = _x select 1;
        {
            if !((_x select 0) in _keep) then { _keep pushBack (_x select 0); };
        } forEach ([_x select 0, _zPos, _side, _zoneNames] call MISSION_CORE_fnc_getMarkerNeighbors);
    } forEach _zoneList;

    // ZONE HANDOFF: decide which replaced zones are a TRUE handoff into a new zone. A handoff
    // only exists when the new contested marker SHARES at least one chosen neighbor with the
    // old one - the fight moved within the same supporting neighborhood. A true handoff INHERITS
    // the old marker's reinforcement budget (the neighbors were already investing in that fight).
    // A marker with NO shared neighbor is a fresh fight: it evaluates neighbors normally with a
    // completely fresh budget.
    private _goneNeighb = createHashMap;
    {
        private _gName = _x;
        private _gIdx = MISSION_CORE_CACHED_POSITIONS findIf { (_x select 0) == _gName };
        if (_gIdx >= 0) then {
            private _gPos = (MISSION_CORE_CACHED_POSITIONS select _gIdx) select 1;
            _goneNeighb set [_gName, ([_gName, _gPos, _side, _zoneNames] call MISSION_CORE_fnc_getMarkerNeighbors) apply { _x select 0 }];
        };
    } forEach _goneZones;
    private _newNeighb = createHashMap;
    {
        private _zName = _x;
        private _zIdx = MISSION_CORE_CACHED_POSITIONS findIf { (_x select 0) == _zName };
        if (_zIdx >= 0) then {
            private _zPos = (MISSION_CORE_CACHED_POSITIONS select _zIdx) select 1;
            _newNeighb set [_zName, ([_zName, _zPos, _side, _zoneNames] call MISSION_CORE_fnc_getMarkerNeighbors) apply { _x select 0 }];
        };
    } forEach _newZones;
    // handoffTo[newName] = oldName that it inherited from. Only the first matching old zone per
    // new zone transfers (a new zone can only inherit one budget).
    private _handoffTo = createHashMap;
    private _handoffFrom = createHashMap;
    {
        private _nName = _x;
        private _nSet = _newNeighb getOrDefault [_nName, []];
        if (count _nSet == 0) then { continue; };
        {
            private _gName = _x;
            private _gSet = _goneNeighb getOrDefault [_gName, []];
            if (count _gSet == 0) then { continue; };
            private _shared = false;
            { if (_x in _gSet) exitWith { _shared = true; }; } forEach _nSet;
            if (_shared) then {
                _handoffTo set [_nName, _gName];
                _handoffFrom set [_gName, _nName];
            };
        } forEach _goneZones;
    } forEach _newZones;

    // 1) DROP old-zone neighbors that no live zone chooses anymore.
    {
        private _goneName = _x;
        private _gIdx = MISSION_CORE_CACHED_POSITIONS findIf { (_x select 0) == _goneName };
        if (_gIdx >= 0) then {
            private _gPos = (MISSION_CORE_CACHED_POSITIONS select _gIdx) select 1;
            {
                private _nName = _x select 0;
                private _nPos = _x select 1;
                if (_nName in _keep) then { continue; };
                if (!(MISSION_CORE_SPAWNED_LOCATIONS getOrDefault [_nName, false])) then { continue; };
                if ([_nPos, _side, _nName] call MISSION_CORE_fnc_isMarkerContested) then { continue; };
                diag_log format ["DYNAMIC REINF: zone handoff - dropping old neighbor %1 (was supporting %2)", _nName, _goneName];
                [_nName, _nPos] call MISSION_CORE_fnc_despawnLocation;
            } forEach ([_goneName, _gPos, _side, _zoneNames] call MISSION_CORE_fnc_getMarkerNeighbors);
        };
        // BUDGET: a TRUE handoff transfers the old marker's ledger to the new contested marker
        // (the neighbors' pending investment carries into the continued fight). A non-handoff
        // replaced marker is RESET to zero - a re-contested marker draws a fresh budget instead
        // of inheriting one from a fight that never shared a neighborhood.
        if (isNil "MISSION_CORE_REINF_SENT") then { MISSION_CORE_REINF_SENT = createHashMap; };
        if (isNil "MISSION_CORE_REINF_TANK_BUDGET") then { MISSION_CORE_REINF_TANK_BUDGET = createHashMap; };
        if (isNil "MISSION_CORE_REINF_COOLDOWN") then { MISSION_CORE_REINF_COOLDOWN = createHashMap; };
        if (isNil "MISSION_CORE_REINF_EXHAUSTED") then { MISSION_CORE_REINF_EXHAUSTED = createHashMap; };
        if (isNil "MISSION_CORE_MANPOWER") then { MISSION_CORE_MANPOWER = createHashMap; };
        if (isNil "MISSION_CORE_TANK_DELIVERED") then { MISSION_CORE_TANK_DELIVERED = createHashMap; };
        if (isNil "MISSION_CORE_TANK_DELIVERED_GROUPS") then { MISSION_CORE_TANK_DELIVERED_GROUPS = createHashMap; };
        if (isNil "MISSION_CORE_TANK_REQUESTED") then { MISSION_CORE_TANK_REQUESTED = createHashMap; };
        private _newOwner = _handoffFrom getOrDefault [_goneName, ""];
        if (_newOwner != "") then {
            private _gSent = MISSION_CORE_REINF_SENT getOrDefault [_goneName, 0];
            private _gTank = MISSION_CORE_REINF_TANK_BUDGET getOrDefault [_goneName, 0];
            private _gManpower = + (MISSION_CORE_MANPOWER getOrDefault [_goneName, []]);
            private _gTankDel = MISSION_CORE_TANK_DELIVERED getOrDefault [_goneName, 0];
            private _gTankDelGrp = + (MISSION_CORE_TANK_DELIVERED_GROUPS getOrDefault [_goneName, []]);
            private _gTankReq = MISSION_CORE_TANK_REQUESTED getOrDefault [_goneName, 0];
            private _gExhausted = MISSION_CORE_REINF_EXHAUSTED getOrDefault [_goneName, false];
            MISSION_CORE_REINF_SENT set [_newOwner, _gSent];
            MISSION_CORE_REINF_TANK_BUDGET set [_newOwner, _gTank];
            MISSION_CORE_MANPOWER set [_newOwner, _gManpower];
            MISSION_CORE_TANK_DELIVERED set [_newOwner, _gTankDel];
            MISSION_CORE_TANK_DELIVERED_GROUPS set [_newOwner, _gTankDelGrp];
            MISSION_CORE_TANK_REQUESTED set [_newOwner, _gTankReq];
            MISSION_CORE_REINF_EXHAUSTED set [_newOwner, _gExhausted];
            // No cooldown stamp: the handoff marker is freshly contested and must be able to ask
            // its neighbors IMMEDIATELY (the inherited budget already caps the spend).
            diag_log format ["DYNAMIC REINF: zone HANDOFF - inherited budget of %1 into %2 (sent=%3 tank=%4)", _goneName, _newOwner, _gSent, _gTank];
        } else {
            MISSION_CORE_REINF_SENT set [_goneName, 0];
            MISSION_CORE_REINF_TANK_BUDGET set [_goneName, 0];
            MISSION_CORE_REINF_COOLDOWN deleteAt _goneName;
            MISSION_CORE_REINF_EXHAUSTED deleteAt _goneName;
            MISSION_CORE_MANPOWER set [_goneName, []];
            MISSION_CORE_TANK_DELIVERED set [_goneName, 0];
            MISSION_CORE_TANK_DELIVERED_GROUPS set [_goneName, []];
            MISSION_CORE_TANK_REQUESTED deleteAt _goneName;
        };
        // Clear the give-up latch either way, so this marker can still raise its own teardown later.
        if (!isNil "MISSION_CORE_NEIGHBOR_GIVEUP") then { MISSION_CORE_NEIGHBOR_GIVEUP deleteAt _goneName; };
        if (_newOwner == "") then {
            diag_log format ["DYNAMIC REINF: zone handoff - reset reinforcement budget for old marker %1", _goneName];
        };
    } forEach _goneZones;

    // 2) ADD the new zone's closest chosen neighbors that are not already active. Matches the
    // counter-attack dispatcher's "up to 3 closest neighbors send real troops" rule, so the
    // active supporting field keeps the same size across the handoff. On a TRUE handoff the new
    // zone's neighbors first TOP UP back to full strength (one-time, capped at their capacity)
    // before they are manpower-blocked for the continuing fight.
    {
        private _zName = _x;
        private _zIdx = MISSION_CORE_CACHED_POSITIONS findIf { (_x select 0) == _zName };
        if (_zIdx < 0) then { continue; };
        private _zPos = (MISSION_CORE_CACHED_POSITIONS select _zIdx) select 1;
        private _isHandoff = _zName in _handoffTo;
        private _added = 0;
        {
            if (_added >= 3) exitWith {};
            private _nLoc = _x;
            private _nName = _nLoc select 0;
            if (MISSION_CORE_SPAWNED_LOCATIONS getOrDefault [_nName, false]) then { continue; };
            if ([_nName] call MISSION_CORE_fnc_isOccupied) then { continue; };
            diag_log format ["DYNAMIC REINF: zone handoff - activating new neighbor %1 (supporting %2)", _nName, _zName];
            MISSION_CORE_SPAWNED_LOCATIONS set [_nName, true];
            [_nLoc] call MISSION_CORE_fnc_spawnLocation;
            _added = _added + 1;
            // One-time handoff top-up: let this neighbor refill to its own capacity before it gets
            // manpower-blocked (capped by the amount needed to reach full - replenishLoop caps the
            // request at the marker's max manpower limit).
            if (_isHandoff) then {
                if (isNil "MISSION_CORE_HANDOFF_TOPUP") then { MISSION_CORE_HANDOFF_TOPUP = []; };
                if !(_nName in MISSION_CORE_HANDOFF_TOPUP) then { MISSION_CORE_HANDOFF_TOPUP pushBack _nName; };
            };
        } forEach ([_zName, _zPos, _side, _zoneNames] call MISSION_CORE_fnc_getMarkerNeighbors);
    } forEach _newZones;
};