// When a marker finally gives up - its neighbor reinforcement budget is spent, or its retake
// window has fully decayed - the whole supporting neighborhood goes dormant with it. Every
// spawned same-side marker within the 4000m reinforcement radius is fully despawned via
// MISSION_CORE_fnc_despawnLocation (garrison, defenses, and any counter-attack / reinforce
// groups still assembling there), so a dead zone never keeps feeding or being fed forever.
// Reversible: a player walking back in re-spawns a marker on demand.
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
//     in their place, so the same number of markers support the fight.
//   - RESET: the replaced marker's reinforcement ledgers go back to 0 - the manpower and tanks
//     its neighbors were willing to send must NOT carry over from the last contested marker.
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
        // RESET the replaced marker's willingness ledger. REINF_SENT is the manpower pool the
        // neighbors had spent on this marker; REINF_TANK_BUDGET is the tanks committed to it.
        // Clearing both (plus the exhausted/cooldown flags and in-flight manpower credits) means
        // a re-contested marker draws a completely fresh budget instead of inheriting the old one.
        if (isNil "MISSION_CORE_REINF_SENT") then { MISSION_CORE_REINF_SENT = createHashMap; };
        if (isNil "MISSION_CORE_REINF_TANK_BUDGET") then { MISSION_CORE_REINF_TANK_BUDGET = createHashMap; };
        if (isNil "MISSION_CORE_REINF_COOLDOWN") then { MISSION_CORE_REINF_COOLDOWN = createHashMap; };
        if (isNil "MISSION_CORE_REINF_EXHAUSTED") then { MISSION_CORE_REINF_EXHAUSTED = createHashMap; };
        if (isNil "MISSION_CORE_MANPOWER") then { MISSION_CORE_MANPOWER = createHashMap; };
        if (isNil "MISSION_CORE_TANK_DELIVERED") then { MISSION_CORE_TANK_DELIVERED = createHashMap; };
        if (isNil "MISSION_CORE_TANK_DELIVERED_GROUPS") then { MISSION_CORE_TANK_DELIVERED_GROUPS = createHashMap; };
        if (isNil "MISSION_CORE_TANK_REQUESTED") then { MISSION_CORE_TANK_REQUESTED = createHashMap; };
        MISSION_CORE_REINF_SENT set [_goneName, 0];
        MISSION_CORE_REINF_TANK_BUDGET set [_goneName, 0];
        MISSION_CORE_REINF_COOLDOWN deleteAt _goneName;
        MISSION_CORE_REINF_EXHAUSTED deleteAt _goneName;
        MISSION_CORE_MANPOWER set [_goneName, []];
        MISSION_CORE_TANK_DELIVERED set [_goneName, 0];
        MISSION_CORE_TANK_DELIVERED_GROUPS set [_goneName, []];
        MISSION_CORE_TANK_REQUESTED deleteAt _goneName;
        // Clear the give-up latch too, so this marker can still raise its own teardown later.
        if (!isNil "MISSION_CORE_NEIGHBOR_GIVEUP") then { MISSION_CORE_NEIGHBOR_GIVEUP deleteAt _goneName; };
        diag_log format ["DYNAMIC REINF: zone handoff - reset reinforcement budget for old marker %1", _goneName];
    } forEach _goneZones;

    // 2) ADD the new zone's closest chosen neighbors that are not already active. Matches the
    // counter-attack dispatcher's "up to 3 closest neighbors send real troops" rule, so the
    // active supporting field keeps the same size across the handoff.
    {
        private _zName = _x;
        private _zIdx = MISSION_CORE_CACHED_POSITIONS findIf { (_x select 0) == _zName };
        if (_zIdx < 0) then { continue; };
        private _zPos = (MISSION_CORE_CACHED_POSITIONS select _zIdx) select 1;
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
        } forEach ([_zName, _zPos, _side, _zoneNames] call MISSION_CORE_fnc_getMarkerNeighbors);
    } forEach _newZones;
};