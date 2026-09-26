// ONE-STOP SAFE VEHICLE SPAWN -------------------------------------------------------------
// EVERY vehicle-creating path funnels its createVehicle through this single helper so that,
// RIGHT BEFORE the spawn, all of the following happen in one call:
//   1. wrecked vehicles inside the immediate landing footprint are DELETED - a fresh vehicle
//      must never materialize on / beside a burned-out hull from an earlier fight,
//   2. the spot is verified clear of ANY living land vehicle - CREWED OR EMPTY (alive covers
//      parked unoccupied hulls and crewed armor alike) - plus dry-ground, no-flagged-spawn-kill
//      and no-hard-geometry checks; when blocked and re-roll is allowed, a clean spot is
//      re-rolled nearby via safeVehicleSpawnPos / findVehiclePos,
//   3. the world's accumulated dead bodies/wrecks are purged (permanent vehicle-spawn rule -
//      liftSpawn, which every createVehicle here routes through, runs the global sweep).
// then the vehicle is created at a lifted ground position and aligned along the road.
//   [_class, _pos, _reRoll, _heading] call MISSION_CORE_fnc_safeVehicleSpawn;
//   _reRoll  (default true)  = re-roll a clean spot nearby when _pos fails the safe check;
//                              pass false to pin the exact spot (player-requested spawns).
//   _heading (default 0)     = 0 faces the vehicle along the road under it; any other compass
//                              bearing applies that exact heading.
// Returns the created vehicle (objNull when arguments are invalid).
MISSION_CORE_fnc_safeVehicleSpawn = {
    params ["_cls", "_pos", ["_reRoll", true], ["_heading", 0]];
    if (isNil "_cls" || { typeName _cls != "STRING" } || { _cls == "" }) exitWith { objNull };
    if (isNil "_pos" || { !(_pos isEqualType []) } || { count _pos < 2 }) exitWith { objNull };
    // (1) Right-before-spawn wreck sweep inside the landing footprint.
    [_pos, 45] call MISSION_CORE_fnc_clearNearbyWrecks;
    // (2) Living-vehicle (crewed OR empty) + dry + geometry + spawn-kill verification.
    private _vehPos = _pos;
    if (count _vehPos == 2) then {
        _vehPos = [_vehPos] call MISSION_CORE_fnc_ensureLandPos;
        if (count _vehPos == 2) then { _vehPos pushBack 0; };
    };
    if (!([_vehPos] call MISSION_CORE_fnc_isSafeVehicleSpawnPos)) then {
        if (_reRoll) then {
            // Escalating re-roll: try a 200m box around the spot first, then a wider 400m box, so
            // repeated spawns to the same marker never settle back onto the last parked vehicle.
            private _sizes = [[200, 200], [400, 400]];
            {
                private _retry = [_pos, _pos, _x] call MISSION_CORE_fnc_safeVehicleSpawnPos;
                if (count _retry >= 2 && { [_retry] call MISSION_CORE_fnc_isSafeVehicleSpawnPos }) exitWith { _vehPos = _retry; };
            } forEach _sizes;
        };
    };
    // (3) Global dead-body purge runs inside liftSpawn on the way to createVehicle.
    private _veh = createVehicle [_cls, [_vehPos] call MISSION_CORE_fnc_liftSpawn, [], 5, "CAN_COLLIDE"];
    if (isNull _veh) exitWith { objNull };
    if (_heading == 0) then { [_veh] call MISSION_CORE_fnc_alignVehicleToRoad; } else { _veh setDir _heading; };
    // CREW GET-OUT watcher. Attached here because this is the single funnel every ground vehicle
    // is created through (depot stock, materialized convoys, garrison rebuilds, HQ deploys, foot
    // transports, supply convoys, defense vehicles). It REPLACES the previous Dammaged-based
    // abandoned-wreck reaper: GetOut fires on the actual trigger - the crew leaving the vehicle -
    // rather than on damage plus a ten-minute wait, and it can tell a genuinely shot-up hull from
    // one that is merely stuck or flipped and worth recovering.
    if (!isNil "MISSION_CORE_fnc_attachGetOut") then { [_veh] call MISSION_CORE_fnc_attachGetOut; };
    _veh
};
