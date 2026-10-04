// Draw an ALREADY-FIELDED squad off a marker's garrison for a one-off task.
//
// This belongs to the AI COMMANDER, not to an action callable script. It used to be written inline
// inside fn_playerHunt's contingent builder, which meant the eligibility rules were private to the
// player-hunt feature: reinforcement could not ask the same question, and any second caller would
// have had to copy the filter and drift out of sync. Owning it here means every commander subsystem
// pulls from ONE pool of squads by ONE definition of "available".
//
// It RE-TASKS, it never spawns. Nothing is created and no manpower is drawn - the squad is already
// inside the fielded army's budget, which is exactly why a hunt prefers this over conjuring a new
// one. Returning grpNull means "this marker fields nothing you may have", which is a normal answer,
// not an error.
//
// usage - MISSION_CORE_fnc_claimIdleGarrison:
//   _sideVar     the side flag name to test on each group, e.g. "MISSION_CORE_IS_REDFOR"
//   _markerName  only squads rooted at this marker are eligible
// returns: the group, or grpNull
MISSION_CORE_fnc_claimIdleGarrison = {
    params ["_sideVar", "_markerName"];
    if (isNil "MISSION_CORE_SPAWNED_GROUPS") exitWith { grpNull };
    private _cands = MISSION_CORE_SPAWNED_GROUPS select {
        !isNull _x &&
        { count units _x > 0 } &&
        { _x getVariable [_sideVar, false] } &&
        { (_x getVariable ["MISSION_CORE_ORIGIN_MARKER", ""]) == _markerName } &&
        { (_x getVariable ["MISSION_CORE_ORDER", ""]) in ["", "patrol", "defend", "engage"] } &&
        { !(_x getVariable ["MISSION_CORE_AA_DEFENSE", false]) } &&
        { !(_x getVariable ["MISSION_CORE_AA_TANK", false]) } &&
        { !(_x getVariable ["MISSION_CORE_STATIC_GUARD", false]) } &&
        { ({ vehicle _x == _x } count units _x) == count units _x }
    };
    if (count _cands == 0) exitWith { grpNull };
    selectRandom _cands
};