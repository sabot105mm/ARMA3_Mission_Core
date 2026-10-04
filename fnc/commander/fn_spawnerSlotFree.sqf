// When a marker drops to 50% of its garrison, surrounding friendly markers reinforce it.
// PERMANENT RULE: the CLOSEST neighbors dispatch real troops - up to 3 markers may send.
// The neighbor markers never need their own defenses spawned to act as reinforcement sources;
// they only send reinforcements. Farther neighbors do not march units across the map - they
// grant manpower credit to the contested marker that matures based on average travel time.
// This behavior must never be reduced below 3 senders. Do not change.

// PERMANENT RULE: at most spawnerSlotCap markers PER SIDE may spawn troops at once. Slots are keyed
// [_side, markerName] so the two sides have independent pools - a marker-dense enemy neighborhood
// can no longer starve our own providers out of the shared pool.
//
// A marker that gives up (its reinforcement pool is exhausted) does NOT hold its slot forever.
// MISSION_CORE_fnc_reevalSpawnerSlots prunes holders that can no longer field men; the freed
// capacity is then claimed on demand by whichever marker asks next. Despawning a marker also
// releases its slot (fn_despawnLocation). Returns true if the marker can claim - or already holds -
// a slot.
MISSION_CORE_fnc_spawnerSlotFree = {
    params ["_markerName", "_side"];
    if (isNil "MISSION_CORE_ACTIVE_SPAWNERS") then { MISSION_CORE_ACTIVE_SPAWNERS = createHashMap; };
    private _key = [_side, _markerName];
    if (MISSION_CORE_ACTIVE_SPAWNERS getOrDefault [_key, false]) exitWith { true };
    private _cap = (["spawnerSlotCap", 5] call MISSION_CORE_fnc_tune);
    // Count only this side's slots. A flat `count MISSION_CORE_ACTIVE_SPAWNERS` would double the
    // effective cap now that both sides live in the same map.
    //
    // `select` does NOT work on a HashMap in this engine - it throws "select: Type HashMap, expected
    // Array,String,Config entry". The only supported readers are count / keys / getOrDefault / forEach,
    // so iterate the KEYS with postfix forEach and count the matches.
    private _held = 0;
    private _heldKeys = keys MISSION_CORE_ACTIVE_SPAWNERS;
    {
        private _k = _x;
        if (_k isEqualType []) then {
            if ((_k select 0) == _side) then { _held = _held + 1; };
        };
    } forEach _heldKeys;
    if (_held >= _cap) exitWith { false };
    MISSION_CORE_ACTIVE_SPAWNERS set [_key, true];
    diag_log format ["DYNAMIC SPAWNER TRACK: %1 %2 claimed a spawn slot (%3/%4 active on side)",
        _markerName, _side, _held + 1, _cap];
    true
};