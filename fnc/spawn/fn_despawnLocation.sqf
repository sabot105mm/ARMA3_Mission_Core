
// Despawn a spawned location: serialize its non-defense groups to cache, delete all groups and
// defense groups near it, release its defense assignment, and recover partial supply.
MISSION_CORE_fnc_despawnLocation = {
    params ["_locName", "_locPos"];
    MISSION_CORE_SPAWNED_LOCATIONS set [_locName, false];
    // A deactivated depot hides its parked reserve battery (stock persists; tankParkReconcile
    // re-parks the warehouse on the next activation).
    if (!isNil "MISSION_CORE_TANK_PARK") then {
        private _park = MISSION_CORE_TANK_PARK getOrDefault [_locName, []];
        { if (!isNull _x) then { deleteVehicle _x; }; } forEach _park;
        MISSION_CORE_TANK_PARK set [_locName, []];
    };
    // The marker left the battle - free its reinforcement spawn slot so a fresh marker can claim it.
    // Spawn slots are keyed [_side, markerName], and despawnLocation is called with only a name and
    // position, so the side is recovered from the cached position row (index 4) - the same lookup
    // fn_reinforceActions uses. Without it the release would miss and the slot would leak.
    private _slotSide = sideUnknown;
    if (!isNil "MISSION_CORE_CACHED_POSITIONS") then {
        // Prefix `isEqualType [...]` before && is a precedence trap (unary binds tighter than && and the
        // expression fails to parse). The infix `(_x isEqualType [])` form is the safe one.
        private _slotRow = MISSION_CORE_CACHED_POSITIONS select {
            (_x isEqualType []) && { count _x > 4 } && { (_x select 0) == _locName }
        };
        if (count _slotRow > 0) then { _slotSide = (_slotRow select 0) select 4; };
    };
    if (_slotSide != sideUnknown) then {
        [_locName, _slotSide] call MISSION_CORE_fnc_releaseSpawnerSlot;
    } else {
        diag_log format ["DYNAMIC SPAWNER TRACK: %1 despawn could not resolve side - slot not released", _locName];
    };
    diag_log format ["DYNAMIC SPAWN: despawning %1", _locName];
    if (_locName in allMapMarkers) then {
        _locName setMarkerAlpha 0;
        _locName setMarkerText "";
    };
    // A deactivated marker that was cut off after a neighbor's capture may receive manpower
    // from neighbors again once it is deactivated
    if (isNil "MISSION_CORE_MANPOWER_CUTOFF") then { MISSION_CORE_MANPOWER_CUTOFF = createHashMap; };
    MISSION_CORE_MANPOWER_CUTOFF deleteAt _locName;

    // Serialize all groups at this location to cache
    private _cacheData = [];
    {
        if (!isNull _x) then {
            // PERMANENT RULE: player-recruited BLUFOR assets (assault squads, garrison squads,
            // delivered vehicles) are never deleted by marker cleanup. Markers sit close together
            // (adjacent outposts/hqs are often <100m apart), so a winning assault squad standing on
            // the captured edge can easily fall inside a despawned NEIGHBOR's 500m radius and be
            // wiped out the moment the battle around it goes dormant.
            if (_x getVariable ["MISSION_CORE_BLUFOR", false]) then { continue; };
            // PERMANENT RULE: an ACTIVE hunt contingent is never deleted by marker cleanup - the
            // hunt controller owns its life (sweep -> retreat -> despawn on arrival). A hunt just
            // dispatched at its source marker is within 500m of it, so a neighbor going dormant the
            // instant the hunt looses would otherwise wipe the whole contingent in place.
            if ((_x getVariable ["MISSION_CORE_HUNT_KEY", ""]) != "") then { continue; };
            private _leaderPos = if (!isNull (leader _x)) then { getPos (leader _x) } else { [0, 0, 0] };
            // "Near" is judged by the group's LIVE position, not its frozen MARKER_CENTER - a group
            // that already marched away must not be deleted with its origin location.
            private _near = count _leaderPos > 0 && { _leaderPos distance _locPos < 500 };
            // Groups marching to this marker (counter-attack / reinforce in flight) die with it
            private _attackTarget = _x getVariable ["MISSION_CORE_ATTACK_TARGET", []];
            private _marchingHere = count _attackTarget > 0 && { _attackTarget distance _locPos < 500 };
            // Groups still ASSEMBLING at this marker (origin == here AND not yet departed) die with it
            private _fromHere = (_x getVariable ["MISSION_CORE_ORIGIN_MARKER", ""]) == _locName && { _leaderPos distance _locPos < 500 };
            if ((_near || _marchingHere || _fromHere)) then {
                if (_near && { _x getVariable ["MISSION_CORE_REDFOR", false] } && { !(_x getVariable ["MISSION_CORE_DEFENSE_GROUP", false]) }) then {
                    _cacheData pushBack ([_x, _locPos] call MISSION_CORE_fnc_serializeGroup);
                };
                // Deletion is owned by MISSION_CORE_fnc_deleteGroupCompletely - it also removes the
                // dedicated foot-transport driver groups (MISSION_CORE_DRIVER_GROUP), which are NOT
                // in SPAWNED_GROUPS; a manual delete here would leave the driver stranded when the
                // truck he drives is deleted for the squad riding it.
                [_x] call MISSION_CORE_fnc_deleteGroupCompletely;
            };
        };
    } forEach MISSION_CORE_SPAWNED_GROUPS;
    MISSION_CORE_SPAWNED_CACHE set [_locName, _cacheData];
    if (!isNil "MISSION_CORE_DEFENSE_ASSIGN") then { MISSION_CORE_DEFENSE_ASSIGN deleteAt _locName; };
    if (!isNil "MISSION_CORE_DEFENSE_LOCKED") then { MISSION_CORE_DEFENSE_LOCKED deleteAt _locName; };

    // Recover partial supply on despawn (serialized groups return to pool)
    private _supplyRecover = count _cacheData * 2;
    private _curSupply = MISSION_CORE_LOCATION_SUPPLY getOrDefault [_locName, 0];
    MISSION_CORE_LOCATION_SUPPLY set [_locName, _curSupply + _supplyRecover];
    diag_log format ["DYNAMIC SUPPLY: %1 despawn recovered %2 (total=%3)", _locName, _supplyRecover, _curSupply + _supplyRecover];
};
