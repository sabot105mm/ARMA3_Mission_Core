// =====================================================================
// RECRUIT VEHICLE SPAWN QUEUE (per-marker waiting list)
//
// Safety net for BLUFOR recruit vehicle spawns. When more vehicles are
// bought than the marker's spawn box can physically hold, a naive spawn
// reuses a spot that already has armor on or around it, so the vehicles
// materialise on top of each other.
//
// This queue defers the ACTUAL spawn: the gate simply asks the ONE-STOP
// vehicle safe spawn engine (fn_findVehiclePos.sqf) whether the spawn box
// has room RIGHT NOW - same finders, same 40m vehicle / 8m geometry
// object-detection distances the spawn itself will run, same box size.
// No scanning lives in this file. While the area is full, the request sits
// on that marker's FIFO waiting list; a maintenance tick drains ONE
// request per marker each pass once the engine reports room, so the
// backlog deploys one group at a time as spots free up, never stacked.
// Runs server-side only (compiled in fn_init.sqf).
// =====================================================================

// Gate: does the recruit-tab spawn box around this marker have room for ONE more vehicle? The
// box ([120,120], matching the findVehiclePos call in serverAddVehicleSpawnNow) is resolved here
// from the marker's LOCATIONS row; the actual safety decision is delegated entirely to the
// vehicle safe spawn engine. Markers without a LOCATIONS row are never gated.
MISSION_CORE_fnc_recruitMarkerSpotClear = {
    params ["_markerName"];
    if (isNil "MISSION_CORE_LOCATIONS") exitWith { true };
    private _idx = MISSION_CORE_LOCATIONS findIf { (_x select 0) == _markerName };
    if (_idx < 0) exitWith { true };
    private _center = ((MISSION_CORE_LOCATIONS select _idx) select 1) select 0;
    [_center, [120, 120], 1] call MISSION_CORE_fnc_vehicleSpawnRoom
};

// Gate: does the assault spawn box around this marker have room for ALL LandVehicles in the
// group RIGHT NOW? The box ([200,200], matching both alignGroupVehiclesToRoad calls in the
// assault spawn paths) is resolved here from the marker's LOCATIONS row; the whole-group safety
// decision is delegated entirely to the vehicle safe spawn engine (findVehicleColumnPos must
// produce one dry, geometry-light, unoccupied road spot per vehicle). Infantry groups (0
// vehicles) and markers without a LOCATIONS row are never gated.
MISSION_CORE_fnc_assaultMarkerColumnClear = {
    params ["_markerName", ["_vehCount", 0]];
    if (_vehCount <= 0) exitWith { true };
    if (isNil "MISSION_CORE_LOCATIONS") exitWith { true };
    private _idx = MISSION_CORE_LOCATIONS findIf { (_x select 0) == _markerName };
    if (_idx < 0) exitWith { true };
    private _center = ((MISSION_CORE_LOCATIONS select _idx) select 1) select 0;
    [_center, [200, 200], _vehCount] call MISSION_CORE_fnc_vehicleSpawnRoom
};

// Spawn now if a safe spot is clear, else park the request on the marker's FIFO waiting list.
// Returns true if the spawn ran immediately, false if it was queued. The caller has ALREADY
// charged manpower by this point (charge-now policy), so a queued request never double-charges.
// _fncName names a mission function that takes exactly _args and performs the spawn + registration.
// _clearTest/_clearArgs name the gate that decides whether the marker is clear to spawn - default
// recruitMarkerSpotClear([marker]) asks the vehicle safe spawn engine for room in the [120,120]
// recruit-tab spawn box, while the assault paths pass assaultMarkerColumnClear([marker, vehCount])
// so the engine must find a clean road-column spot per LandVehicle - the WHOLE group fits or it
// waits.
MISSION_CORE_fnc_queueRecruitVehicleSpawn = {
    params ["_markerName", "_fncName", "_args", "_caller", ["_clearTest", "MISSION_CORE_fnc_recruitMarkerSpotClear"], ["_clearArgs", []]];
    if (count _clearArgs == 0) then { _clearArgs = [_markerName]; };
    if (_clearArgs call (missionNamespace getVariable [_clearTest, {}])) then {
        _args call (missionNamespace getVariable [_fncName, {}]);
        true
    } else {
        if (isNil "MISSION_CORE_RECRUIT_VEH_QUEUE") then { MISSION_CORE_RECRUIT_VEH_QUEUE = createHashMap; };
        private _q = MISSION_CORE_RECRUIT_VEH_QUEUE getOrDefault [_markerName, []];
        _q pushBack [_fncName, _args, _caller, time, _clearTest, _clearArgs];
        MISSION_CORE_RECRUIT_VEH_QUEUE set [_markerName, _q];
        false
    }
};

// Drain ONE queued request per marker as soon as the marker passes ITS OWN clear gate (recruit-tab
// items wait for room in the [120,120] spawn box, assault items for a clean road-column spot per
// LandVehicle in the group - both answered by the same vehicleSpawnRoom engine). Called from the consolidated group-maintenance loop. FIFO; a marker's backlog therefore
// deploys the group only when ALL its spots are free, one group per open slot, never stacked.
// Iterates a keys() snapshot so deleting an emptied marker's row mid-pass is safe.
MISSION_CORE_fnc_recruitVehicleQueueTick = {
    if (isNil "MISSION_CORE_RECRUIT_VEH_QUEUE") exitWith {};
    {
        private _markerName = _x;
        private _q = MISSION_CORE_RECRUIT_VEH_QUEUE getOrDefault [_markerName, []];
        if (count _q > 0) then {
            private _head = _q select 0;
            private _clearTest = _head param [4, "MISSION_CORE_fnc_recruitMarkerSpotClear"];
            private _clearArgs = _head param [5, [_markerName]];
            if (count _clearArgs == 0) then { _clearArgs = [_markerName]; };
            if (_clearArgs call (missionNamespace getVariable [_clearTest, {}])) then {
                private _item = _q deleteAt 0;
                _item params ["_fncName", "_args", "_caller"];
                diag_log format ["RECRUIT QUEUE: deploying %1 at %2 (%3 still waiting)", _fncName, _markerName, count _q];
                try {
                    _args call (missionNamespace getVariable [_fncName, {}]);
                } catch {
                    diag_log format ["RECRUIT QUEUE: %1 at %2 errored - dropped: %3", _fncName, _markerName, _exception];
                };
            };
        };
        if (count _q == 0) then { MISSION_CORE_RECRUIT_VEH_QUEUE deleteAt _markerName; };
    } forEach (keys MISSION_CORE_RECRUIT_VEH_QUEUE);
};
