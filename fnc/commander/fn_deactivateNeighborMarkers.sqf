// When a contested marker stops being contested, its supporting neighborhood goes dormant. Every
// spawned same-side marker within the neighbor reinforcement radius is fully despawned via
// MISSION_CORE_fnc_despawnLocation (garrison, defenses, and any counter-attack / reinforce groups
// still assembling there), so a dead zone's support never keeps feeding forever.
// Reversible: a player marching back in re-spawns a marker on demand.
//
// PERMANENT RULE: this is a NEIGHBORHOOD teardown only - the marker ITSELF never gives up
// (contested only clears via capture / all-threats-gone). It keeps self-replenishing with its own
// garrison; only its support pool stops answering.
//
// A neighbor that is its own active battle is left alone - never touch a marker currently
// contested by a player, or the side's locked zone focus (the fight lives there, and
// reinforcements may still need to flow to it).
//
// There is deliberately NO zone handoff here. Each contested marker is evaluated on its own, and
// a neighbor may support several of them at once - so tearing down marker A's neighborhood must
// never take out a neighbor that marker B still wants. That single rule is what _keep below
// protects, and it is why a provider's commitment to one marker is unaffected by another.
MISSION_CORE_fnc_deactivateNeighborMarkers = {
    params ["_locName", "_locPos", "_side"];
    if (isNil "MISSION_CORE_SPAWNED_LOCATIONS") then { MISSION_CORE_SPAWNED_LOCATIONS = createHashMap; };
    if (isNil "MISSION_CORE_CACHED_POSITIONS") exitWith {};
    private _zoneFocus = if (_side == EAST) then { [EAST] call MISSION_CORE_fnc_getAIZoneFocus } else { "" };

    // SHARED-NEIGHBOR SAFETY: any marker chosen by ANY live contested zone stays up. This is not
    // a handoff - it is what lets one neighbor answer two fights at once. Dropping it would mean
    // marker A's give-up tears down the support marker B is actively using.
    private _keep = [];
    if (!isNil "MISSION_CORE_fnc_getMarkerNeighbors") then {
        // Which markers are contested comes ONLY from MISSION_CORE_CONTESTED (written solely by
        // fn_isMarkerContested). Their POSITIONS come from MISSION_CORE_CACHED_POSITIONS - a
        // separate var answering a separate question. Joining names to cached rows here forms no
        // opinion about contested state, so it cannot disagree with the authority.
        private _zoneNames = if (isNil "MISSION_CORE_CONTESTED") then { [] } else { keys MISSION_CORE_CONTESTED };
        if (!isNil "MISSION_CORE_CACHED_POSITIONS") then {
            {
                private _zName = _x;
                private _zRow = MISSION_CORE_CACHED_POSITIONS findIf { (_x select 0) == _zName };
                if (_zRow >= 0) then {
                    private _zPos = (MISSION_CORE_CACHED_POSITIONS select _zRow) select 1;
                    {
                        if !((_x select 0) in _keep) then { _keep pushBack (_x select 0); };
                    } forEach ([_zName, _zPos, _side, _zoneNames] call MISSION_CORE_fnc_getMarkerNeighbors);
                };
            } forEach _zoneNames;
        };
    };

    // The marker's own reinforcement state returns to full for its next contest. Its manpower is
    // deliberately untouched - a marker on 20 men keeps 20 until resupply tops it back up.
    [_locName] call MISSION_CORE_fnc_reinforceResetZone;

    {
        private _n = _x;
        private _nName = _n select 0;
        if (_nName == _locName) then { continue; };
        // Only markers that are actually up and running need to go dormant.
        if (!(MISSION_CORE_SPAWNED_LOCATIONS getOrDefault [_nName, false])) then { continue; };
        // Never touch a neighbor that is itself an active battle right now.
        if ([(_n select 1), _side, _nName, "deactivateNeighborMarkers"] call MISSION_CORE_fnc_isMarkerContested) then { continue; };
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
