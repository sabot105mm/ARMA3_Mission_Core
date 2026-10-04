// CLAIM AN ALREADY-FIELDED SQUAD TO MARCH ON A CONTESTED MARKER - idle squads only.
//
// Reinforcement used to have exactly one way to field men: conjure a new squad from a template and
// pay for it out of the provider's MISSION_CORE_LOCATION_SUPPLY pool. A marker sitting on idle troops
// would spend fresh manpower marching reinforcements while its own soldiers stood idle at home. The
// hunt feature already had the better answer - draw an already-fielded squad off the garrison, which
// costs no manpower - but it lived inside fn_playerHunt's contingent builder where reinforcement
// could not reach it.
//
// -----------------------------------------------------------------------------
// WHY THIS HAS ITS OWN FILTER INSTEAD OF CALLING MISSION_CORE_fnc_claimIdleGarrison
// -----------------------------------------------------------------------------
// It looks like duplication and it is, deliberately. That helper is shared with the player hunt, and
// hunt behaviour must not change as a side effect of reinforcement work. Editing it - even adding a
// default-false parameter - puts hunt behaviour one edit away from silently changing, which is
// exactly the drift this mission keeps paying for. So the duplication is the trade, and it is bounded
// to this one file. If the eligibility rules ever genuinely need to move together, that is a
// deliberate change with hunt's behaviour deliberately changed too, not a side effect.
//
// TWO RULES, AND THEY ARE NOT THE SAME RULE:
//
//   1. NEVER EMPTY A DEFENDED MARKER. A squad whose MISSION_CORE_ORDER is "defend" is holding a
//      marker. This function will not take one, ever, regardless of how convenient it would be. Note
//      the filter accepts ORDER == "" ONLY - "defend" is not merely deprioritised, it is not a
//      candidate. Idle squads trump defend squads; defend squads are not the fallback.
//
//   2. ONLY GENUINELY IDLE SQUADS. ORDER == "" means "no task", but MISSION_CORE_IDLE is the flag the
//      commander itself uses to decide who is free (fn_aiCommanderLoop.sqf:334 and :352). Both are
//      required. Reading ORDER alone is the bug this avoids: every writer of "defend" also sets IDLE
//      false (fn_spawnLocation.sqf:327-328, fn_tankOrderLoop.sqf:78-79, fn_compositions.sqf:147-148,
//      fn_recruitServer.sqf x4, fn_defenseBuilderServer.sqf:78-79), so the two agree on defenders -
//      but IDLE is also set false by subsystems that never write an ORDER at all
//      (fn_sendCounterAttack.sqf:59), and those are equally committed and equally untouchable.
//
// WHY THE STATIC FLAGS ARE CORRECTED HERE RATHER THAN SHARED
//
// fn_claimIdleGarrison tests MISSION_CORE_STATIC_GUARD, but the flag that actually marks a never-moving
// emplacement is MISSION_CORE_STATIC_DEFENSE - set at fn_defenseBuilderServer.sqf:76, two lines before
// `disableAI "MOVE"` at :79. STATIC_GUARD is a DIFFERENT flag (fn_spawnDefenses.sqf:119, a turret
// object). So a group that physically cannot walk is a candidate, MISSION_CORE_fnc_sendCounterAttack
// hands it waypoints it cannot execute, returns true, and this file would log a march that never
// happens. Checked by MISSION_CORE_STATIC_DEFENSE plus the umbrella MISSION_CORE_DEFENSE_GROUP, which
// is what fn_aiAssaultLoop.sqf:259 and fn_commitToBattle.sqf:35 already treat as untouchable.
//
// usage - MISSION_CORE_fnc_claimReinforcementSquad:
//   _sideVar     the side's group flag, e.g. "MISSION_CORE_REDFOR"
//   _provName    the PROVIDER marker's name - only squads rooted here are eligible
//   _targetPos   the contested marker being marched on
//   _targetSize  its half-axes
// returns: the group that actually accepted the march, or grpNull (conjure instead)
MISSION_CORE_fnc_claimReinforcementSquad = {
    params ["_sideVar", "_provName", "_targetPos", ["_targetSize", [200, 200]]];

    if (isNil "MISSION_CORE_SPAWNED_GROUPS") exitWith { grpNull };

    private _cands = MISSION_CORE_SPAWNED_GROUPS select {
        !isNull _x &&
        { count units _x > 0 } &&
        { _x getVariable [_sideVar, false] } &&
        { (_x getVariable ["MISSION_CORE_ORIGIN_MARKER", ""]) == _provName } &&
        // RULE 1 + 2, both required. See the header.
        { (_x getVariable ["MISSION_CORE_ORDER", ""]) == "" } &&
        { (_x getVariable ["MISSION_CORE_IDLE", true]) } &&
        { !(_x getVariable ["MISSION_CORE_STATIC_DEFENSE", false]) } &&
        { !(_x getVariable ["MISSION_CORE_DEFENSE_GROUP", false]) } &&
        { !(_x getVariable ["MISSION_CORE_AA_DEFENSE", false]) } &&
        { !(_x getVariable ["MISSION_CORE_AA_TANK", false]) } &&
        // Dismounted only - a squad riding a truck cannot march off it on its own.
        { ({ vehicle _x == _x } count units _x) == count units _x }
    };
    if (count _cands == 0) exitWith { grpNull };

    private _grp = selectRandom _cands;

    // MISSION_CORE_fnc_sendCounterAttack REFUSES some groups by design - a BLUFOR garrison that must
    // hold its marker, a light-infrastructure origin that never leaves its outpost. A refusal is NOT
    // a re-task and must return grpNull: returning the group anyway would report a squad that marched
    // when none did, and would skip the conjure that should have happened instead.
    if !([_grp, _targetPos, _targetSize] call MISSION_CORE_fnc_sendCounterAttack) exitWith {
        diag_log format ["DYNAMIC REINF: %1 idle squad %2 refused the march (garrison / light-infra rule) - conjuring instead", _provName, groupId _grp];
        grpNull
    };

    diag_log format ["DYNAMIC REINF: %1 re-tasked idle squad %2 to contested %3 (re-tasked, not spawned - no manpower cost)", _provName, groupId _grp, _targetPos];
    _grp
};