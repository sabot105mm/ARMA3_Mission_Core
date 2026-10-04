// SPAWNER SLOT RE-EVALUATION
//
// Spawn slots used to be PERMANENT: a marker that gave up (its reinforcement pool was exhausted)
// kept its slot until the player moved away and the marker despawned. With every side's markers
// holding slots in one pool, an exhausted neighborhood could sit on every slot while providers with
// men to spare were turned away - the zone froze mid-contest (27/200 men committed, 5 slots busy,
// 8 men queued) even though both sides' garrisons had already stopped producing.
//
// This pass PRUNES the holders that can no longer field men and lets the freed capacity be claimed
// on demand. It deliberately does NOT hand slots out to specific markers: pre-granting recreates the
// same disease, since a marker holding a slot it never asked for holds it until despawn. Instead the
// freed capacity returns to the pool and the ordinary claim path
// (fn_neighborCounterAttack / fn_queuedCounterAttackInf / fn_replenishLoop / fn_longRangeReaction)
// hands it to whichever marker asks next, within one sweep.
//
// PERSISTENT SIGNALS ONLY. The prune tests states that cannot flip back on their own. Pruning on a
// transient reading (providerBudget, MISSION_CORE_COMMIT, a current squad count) would release a
// slot and then let the same marker immediately re-claim it, ping-ponging against whoever claimed
// it in between.
MISSION_CORE_fnc_reevalSpawnerSlots = {
    params [["_why", "?"]];
    if (isNil "MISSION_CORE_ACTIVE_SPAWNERS") then { MISSION_CORE_ACTIVE_SPAWNERS = createHashMap; };
    if (isNil "MISSION_CORE_SPAWNED_LOCATIONS") then { MISSION_CORE_SPAWNED_LOCATIONS = createHashMap; };
    if (isNil "MISSION_CORE_RETREATED") then { MISSION_CORE_RETREATED = createHashMap; };

    private _freed = [];
    // keys returns [_x, _y] pairs: _x is the key, _y the value.
    //
    // forEach is a UNARY operator and only has the postfix form `{code} forEach array`. There is no
    // prefix form and no `do` - both `forEach (keys X) do {}` and `forEach (keys X) {}` fail to parse
    // with "Missing ;". Assign the keys to a local first, then iterate postfix.
    private _keys = keys MISSION_CORE_ACTIVE_SPAWNERS;
    {
        private _k = _x;
        // Legacy migration: slots claimed before side-keying are bare name strings. They would
        // never be found by a [_side, name] lookup, so they'd occupy a phantom slot forever.
        // The type test is an if/else, never `isEqualType [...] && {...}` - isEqualType is unary
        // and binds tighter than &&, which fails to parse.
        if (!(_k isEqualType [])) then {
            MISSION_CORE_ACTIVE_SPAWNERS deleteAt _k;
            _freed pushBack format ["legacy:%1", _k];
        } else {
            // key shape is [_side, markerName]
            private _name = _k select 1;
            private _dead = false;
            private _whyDead = "";
            // The garrison is not on the map, so it can never field from this slot.
            if (!(MISSION_CORE_SPAWNED_LOCATIONS getOrDefault [_name, false])) then {
                _dead = true;
                _whyDead = "notSpawned";
            };
            // Crossed its determination casualty threshold; MISSION_CORE_RETREATED is latched by
            // fn_replenishLoop and never cleared while the marker stays up.
            if (!_dead) then {
                if (MISSION_CORE_RETREATED getOrDefault [_name, false]) then {
                    _dead = true;
                    _whyDead = "retreated";
                };
            };
            // Hit its ceiling for this contest and its support is done.
            if (!_dead) then {
                if (!isNil "MISSION_CORE_REINF_EXHAUSTED") then {
                    if (MISSION_CORE_REINF_EXHAUSTED getOrDefault [_name, false]) then {
                        _dead = true;
                        _whyDead = "exhausted";
                    };
                };
            };
            if (_dead) then {
                MISSION_CORE_ACTIVE_SPAWNERS deleteAt _k;
                _freed pushBack format ["%1:%2", _name, _whyDead];
            };
        };
    } forEach _keys;

    private _west = 0;
    private _east = 0;
    // Postfix again - see the note on the first loop.
    private _keys2 = keys MISSION_CORE_ACTIVE_SPAWNERS;
    {
        private _k2 = _x;
        if (_k2 isEqualType []) then {
            if ((_k2 select 0) == WEST) then {
                _west = _west + 1;
            } else {
                _east = _east + 1;
            };
        };
    } forEach _keys2;

    private _freedTxt = if (count _freed == 0) then { "none" } else { _freed joinString ", " };
    diag_log format ["DYNAMIC SPAWNER TRACK: slot re-eval (%1) freed %2 -> west %3, east %4",
        _why, _freedTxt, _west, _east];
};