
// When a marker drops to 50% of its garrison, surrounding friendly markers reinforce it.
// PERMANENT RULE: the CLOSEST neighbors dispatch real troops - up to 3 markers may send.
// The neighbor markers never need their own defenses spawned to act as reinforcement sources;
// they only send reinforcements. Farther neighbors do not march units across the map - they
// grant manpower credit to the contested marker that matures based on average travel time.
// This behavior must never be reduced below 3 senders. Do not change.

// PERMANENT RULE: at most 5 markers may spawn troops at once. A claimed slot is PERMANENT - once
// a marker gives up (its reinforcement pool is exhausted) it KEEPS its slot, so no fresh marker
// takes its place. The ONLY way a slot frees is the player moving away and the marker despawning
// (fn_despawnLocation releases it). Returns true if the marker can claim (or already holds) a slot.
MISSION_CORE_fnc_spawnerSlotFree = {
    params ["_markerName"];
    if (isNil "MISSION_CORE_ACTIVE_SPAWNERS") then { MISSION_CORE_ACTIVE_SPAWNERS = createHashMap; };
    if (MISSION_CORE_ACTIVE_SPAWNERS getOrDefault [_markerName, false]) exitWith { true };
    if (count MISSION_CORE_ACTIVE_SPAWNERS >= 5) exitWith { false };
    MISSION_CORE_ACTIVE_SPAWNERS set [_markerName, true];
    diag_log format ["DYNAMIC SPAWNER TRACK: %1 claimed a spawn slot (%2/5 active)", _markerName, count MISSION_CORE_ACTIVE_SPAWNERS];
    true
};
