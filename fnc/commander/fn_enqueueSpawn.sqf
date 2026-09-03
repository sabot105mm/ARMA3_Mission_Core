
// Queue of deferred counter-attack / reinforcement spawns that were blocked by a cap. Each entry
// is [_fncName, _key, _args]. The queue loop retries them every 30s; caps only count alive units,
// so a KIA frees a slot and the queued spawn fires automatically.
MISSION_CORE_fnc_enqueueSpawn = {
    params ["_fncName", "_key", "_args"];
    if (isNil "MISSION_CORE_SPAWN_QUEUE") then { MISSION_CORE_SPAWN_QUEUE = []; };
    if ({ (_x select 1) == _key } count MISSION_CORE_SPAWN_QUEUE > 0) exitWith {
        // already queued - silent (replenish/reinforce checks re-enqueue every cycle)
    };
    MISSION_CORE_SPAWN_QUEUE pushBack [_fncName, _key, _args, 0];
    diag_log format ["DYNAMIC QUEUE: +%1 (key %2, queue=%3)", _fncName, _key, count MISSION_CORE_SPAWN_QUEUE];
};
