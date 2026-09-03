
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
    [_locName] call MISSION_CORE_fnc_releaseSpawnerSlot;
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
    private _toDelete = [];
    {
        if (!isNull _x) then {
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
                private _vehs = [];
                { private _v = vehicle _x; if (_v != _x && { alive _v } && { !(_v in _vehs) }) then { _vehs pushBack _v; }; } forEach units _x;
                { deleteVehicle _x; } forEach units _x;
                { deleteVehicle _x; } forEach _vehs;
                deleteGroup _x;
                _toDelete pushBack _forEachIndex;
            };
        };
    } forEach MISSION_CORE_SPAWNED_GROUPS;
    MISSION_CORE_SPAWNED_CACHE set [_locName, _cacheData];
    _toDelete sort false;
    { MISSION_CORE_SPAWNED_GROUPS deleteAt _x; } forEach _toDelete;
    if (!isNil "MISSION_CORE_DEFENSE_ASSIGN") then { MISSION_CORE_DEFENSE_ASSIGN deleteAt _locName; };
    if (!isNil "MISSION_CORE_DEFENSE_LOCKED") then { MISSION_CORE_DEFENSE_LOCKED deleteAt _locName; };

    // Recover partial supply on despawn (serialized groups return to pool)
    private _supplyRecover = count _cacheData * 2;
    private _curSupply = MISSION_CORE_LOCATION_SUPPLY getOrDefault [_locName, 0];
    MISSION_CORE_LOCATION_SUPPLY set [_locName, _curSupply + _supplyRecover];
    diag_log format ["DYNAMIC SUPPLY: %1 despawn recovered %2 (total=%3)", _locName, _supplyRecover, _curSupply + _supplyRecover];
};
