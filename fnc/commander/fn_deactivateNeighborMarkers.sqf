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
    {
        private _n = _x;
        private _nName = _n select 0;
        if (_nName == _locName) then { continue; };
        // Only markers that are actually up and running need to go dormant.
        if (!(MISSION_CORE_SPAWNED_LOCATIONS getOrDefault [_nName, false])) then { continue; };
        // Never touch a neighbor that is itself an active battle right now.
        if ([(_n select 1), _side, _nName] call MISSION_CORE_fnc_isMarkerContested) then { continue; };
        if (_nName == _zoneFocus) then { continue; };
        diag_log format ["DYNAMIC REINF: %1 gave up - deactivating neighbor %2", _locName, _nName];
        [_nName, _n select 1] call MISSION_CORE_fnc_despawnLocation;
    } forEach (MISSION_CORE_CACHED_POSITIONS select {
        (_x select 4) == _side &&
        { (_x select 0) != _locName } &&
        { ((_x select 1) distance _locPos) < (["neighborRange", 4000] call MISSION_CORE_fnc_tune) }
    });
};