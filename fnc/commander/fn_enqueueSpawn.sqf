
// Queue of deferred counter-attack / reinforcement spawns that were blocked by a cap. Each entry
// is [_fncName, _key, _args, _attempts, _notBefore]. The queue loop retries them as each job comes
// due; caps only count alive units, so a KIA frees a slot and the queued spawn fires automatically.
//
// _notBefore is an ABSOLUTE mission time, not a delay. It is the interest cadence: a job whose time
// has not arrived is left alone and is NOT counted as a denied attempt, so a slow provider waits its
// turn without slowly burning down its own retry budget. Default 0 = due immediately, which is what
// every existing caller gets.
MISSION_CORE_fnc_enqueueSpawn = {
    params ["_fncName", "_key", "_args", ["_notBefore", 0]];
    if (isNil "MISSION_CORE_SPAWN_QUEUE") then { MISSION_CORE_SPAWN_QUEUE = []; };
    if ({ (_x select 1) == _key } count MISSION_CORE_SPAWN_QUEUE > 0) exitWith {
        // already queued - silent (replenish/reinforce checks re-enqueue every cycle)
    };
    MISSION_CORE_SPAWN_QUEUE pushBack [_fncName, _key, _args, 0, _notBefore];
    // Rounding hoisted out of the format array: `round` is unary, and a bare `round x` inside a
    // `[...]` literal is read as one array element that runs on past the next comma -> "Missing ]".
    private _dueIn = round ((_notBefore - time) max 0);
    diag_log format ["DYNAMIC QUEUE: +%1 (key %2, due in %3s, queue=%4)", _fncName, _key, _dueIn, count MISSION_CORE_SPAWN_QUEUE];
};
