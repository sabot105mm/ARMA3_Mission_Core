// BLUFOR STAGED-SQUAD LOAD-OUT. When a recruited BLUFOR squad is STAGED at its source edge
// (fn_assaultServer serverStageGroup) get it onto wheels. Two mutually exclusive cases, in order:
//   1. The group ALREADY owns a vehicle (mech/APC/motor/tank template brought one): the crew that
//      came with the template stays put and every DISMOUNTED member is loaded into a free CARGO
//      seat of those vehicles - free seats only, a driver/gunner is never displaced.
//   2. A pure foot group: when it is staged more than "bluforStageTransportDist" (700m) from its
//      target marker, mount it into a fitting transport via fn_mountInfantry in SELF-DRIVE mode.
//      Self-drive is required: the release path only waypoints the squad group (applyAssaultWaypoints),
//      so a dedicated-driver truck would sit parked - the squad drives its own vehicle instead.
// Called from serverStageGroup ONLY (BLUFOR player-staged squads). REDFOR staging and every other
// flow are left alone. A group that brought its own vehicle never spawns a second one.
// [_grp, _tgtPos] call MISSION_CORE_fnc_bluforStageTransport; -> the transport, or objNull
MISSION_CORE_fnc_bluforStageTransport = {
    params ["_grp", "_tgtPos"];
    if (isNull _grp || { count units _grp == 0 }) exitWith { objNull };
    // Case 1 - the group's own vehicles (deduped, alive, ground only).
    private _own = [];
    {
        private _v = vehicle _x;
        if (_v != _x && { _v isKindOf "LandVehicle" } && { alive _v } && { _own findIf { _x == _v } < 0 }) then {
            _own pushBack _v;
        };
    } forEach units _grp;
    private _out = objNull;
    if (count _own > 0) then {
        {
            if (vehicle _x == _x) then {
                private _seat = objNull;
                {
                    if (_x emptyPositions "cargo" > 0) exitWith { _seat = _x; };
                } forEach _own;
                if (!isNull _seat) then { _x moveInCargo _seat; };
            };
        } forEach units _grp;
    } else {
        // Case 2 - foot group: only mount when the staging line sits far from the objective.
        private _ldr = leader _grp;
        private _minD = ["bluforStageTransportDist", 700] call MISSION_CORE_fnc_tune;
        if (!isNull _ldr && { alive _ldr } && { (_ldr distance2D _tgtPos) > _minD }) then {
            _out = [_grp, side _ldr, getPosATL _ldr, true] call MISSION_CORE_fnc_mountInfantry;
        };
    };
    _out
};
