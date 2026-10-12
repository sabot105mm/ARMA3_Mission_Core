// BOAT TRANSIT MODULE. The abstract-leg system can materialise a foot squad onto the WATER: a
// road route crossing a strait, estuary or causeway (or a leg's straight-line fallback sitting
// off the coast of an island marker) puts the interpolated point over open sea. A foot squad
// dropped there swims, cannot fight, and drowns on a long crossing. This module owns the whole
// water-borne leg of a reinforcement:
//
//   - MISSION_CORE_fnc_mountFootInBoats   raise the squad into boats sized to fit it (called by
//                                         every materialise callback at the materialise point)
//   - MISSION_CORE_fnc_waterCrossingPoint  draw the straight line from the boat spawn to the
//                                         destination marker and return the first point where it
//                                         turns from WATER to LAND - the shore crossing
//   - MISSION_CORE_fnc_boatApproach        ride the boats to that crossing waypoint, then hand
//                                         the rest to the normal foot advance
//   - MISSION_CORE_fnc_boatDismount        the eject fnc: everyone out, boats deleted, transit
//                                         flag cleared
//
// Everything the DIFFERENT squad paths have in common lives here, not in fn_abstractLeg.sqf or
// fn_sendCounterAttack.sqf - this is deliberately one module, compiled once in fn_aiCommander.

// MOUNT. Given the squad and the position it was raised at, embark the WHOLE group when that
// point is over water - one boat, opened only when actually boarding a man, carries up to
// `reinfBoatSeats`; a further boat opens automatically whenever the current one is full (seat
// counter OR moveInCargo refusal), so a boat is never spawned empty and the group is always
// fully aboard. No-op on dry land. Returns TRUE when the squad is now riding, FALSE otherwise.
MISSION_CORE_fnc_mountFootInBoats = {
    params ["_group", "_at"];
    if (isNull _group || { count units _group == 0 }) exitWith { false };
    private _p = if (count _at >= 2) then { _at } else { getPosATL (leader _group) };
    if !(surfaceIsWater [_p select 0, _p select 1]) exitWith { false };
    private _boatClass = ["reinfBoatClass", "O_T_Boat_Armed_01_hmg_F"] call MISSION_CORE_fnc_tune;
    if !(_boatClass isEqualType "") then { _boatClass = "O_T_Boat_Armed_01_hmg_F"; };
    private _seats = ["reinfBoatSeats", 6] call MISSION_CORE_fnc_tune;
    if !(_seats isEqualType 1) then { _seats = 6; };
    if (_seats < 3) then { _seats = 6; };
    private _men = units _group;
    if (_group getVariable ["MISSION_CORE_BOAT_TRANSIT", false]) exitWith { true };
    // Count real seats on the boat class: driver + cargo (transportSoldier) + turret seats.
    private _cargoSeatsReal = [_boatClass] call MISSION_CORE_fnc_vehicleCargo;
    if !(_cargoSeatsReal isEqualType 1) then { _cargoSeatsReal = 0; };
    private _countTurretSeatsFn = {
        params ["_cfg"];
        private _n = 0;
        {
            _n = _n + 1 + ([_x] call _countTurretSeatsFn);
        } forEach ("true" configClasses _cfg);
        _n
    };
    private _turretSeatsReal = 0;
    private _boatCfg = configFile >> "CfgVehicles" >> _boatClass;
    if (isClass _boatCfg) then {
        _turretSeatsReal = [_boatCfg >> "turrets"] call _countTurretSeatsFn;
    };
    private _cap = 1 + _cargoSeatsReal + _turretSeatsReal;
    if (_cap < 1) then { _cap = _seats max 1; };
    private _boats = [];
    private _nMen = count _men;
    private _nBoats = if (_nMen <= 0) then { 1 } else { ceil (_nMen / _cap) };
    if (_nBoats < 1) then { _nBoats = 1 };
    for "_b" from 0 to (_nBoats - 1) do {
        private _ang = 360 * (_b + 1) / 5;
        private _bpos = [(_p select 0) + (sin _ang) * (15 + _b * 8), (_p select 1) + (cos _ang) * (15 + _b * 8), 0];
        private _bt = createVehicle [_boatClass, _bpos, [], 0, "CAN_COLLIDE"];
        _bt setDir (_ang + 90);
        _boats pushBack _bt;
    };
    private _boatHasDriver = _boats apply { false };
    private _boatCargoIn = _boats apply { 0 };
    {
        private _man = _x;
        private _placed = false;
        // Try to find a boat with no driver first.
        for "_b" from 0 to ((count _boats) - 1) do {
            if (!_placed && { !_boatHasDriver select _b }) then {
                private _bt = _boats select _b;
                if (_man moveInDriver _bt) then {
                    _boatHasDriver set [_b, true];
                    _placed = true;
                };
            };
        };
        if (!_placed) then {
            // Find a boat with space in cargo (<= cargoSeatsReal).
            for "_b" from 0 to ((count _boats) - 1) do {
                if (!_placed) then {
                    private _cin = _boatCargoIn select _b;
                    if (_cin < _cargoSeatsReal) then {
                        private _bt = _boats select _b;
                        if (_man moveInCargo _bt) then {
                            _boatCargoIn set [_b, _cin + 1];
                            _placed = true;
                        };
                    };
                };
            };
        };
        // If not placed, do not spawn an extra boat - leave the man where he is (rare, cap misread)
    } forEach _men;
    _group setVariable ["MISSION_CORE_BOAT_TRANSIT", true];
    diag_log format ["BOAT TRANSIT: %1 (%2 men, %3 boats) mounted over water", groupId _group, count _men, count _boats];
    true
};

// CROSSING. Walk the straight line from the boat spawn toward the destination marker and return
// the first point where the line TURNS FROM WATER TO LAND - that shore point is where the boats
// stop and the men take over on foot. Resolution is `_step` metres; if no dry sample exists by
// the far end the line's END is returned so the caller still has a sensible target. Returns
// [] only when the inputs are unusable (caller then falls back to the destination marker).
MISSION_CORE_fnc_waterCrossingPoint = {
    params ["_fromPos", "_toPos", ["_step", 30], ["_maxSteps", 600]];
    if !(_fromPos isEqualType []) exitWith { [] };
    if !(_toPos isEqualType []) exitWith { [] };
    if (count _fromPos < 2 || { count _toPos < 2 }) exitWith { [] };
    private _fx = _fromPos select 0;
    private _fy = _fromPos select 1;
    private _tx = _toPos select 0;
    private _ty = _toPos select 1;
    private _dx = _tx - _fx;
    private _dy = _ty - _fy;
    private _dist = (sqrt ((_dx * _dx) + (_dy * _dy))) max 1;
    private _steps = (ceil (_dist / _step)) min _maxSteps;
    private _sx = _dx / _steps;
    private _sy = _dy / _steps;
    private _hit = [];
    for "_i" from 1 to _steps do {
        private _px = _fx + (_sx * _i);
        private _py = _fy + (_sy * _i);
        // First dry sample along the line, or the line's end if the whole run stays wet.
        if ((!(surfaceIsWater [_px, _py])) || { _i >= _steps }) exitWith { _hit = [_px, _py, 0]; };
    };
    _hit
};

// EJECT FNC. Everyone out of every boat, the boats ridden in deleted, the transit flag cleared.
// Hours the eject details in ONE place so the approach and any future caller share it; returns
// how many men were disembarked (0 = none, e.g. already on foot or squad wiped).
MISSION_CORE_fnc_boatDismount = {
    params ["_group", ["_at", []], ["_side", EAST]];
    if (isNull _group || { count units _group == 0 }) exitWith { 0 };
    if (count _at < 2) then { _at = getPosATL (leader _group); };
    // Collect the boats first (a boat whose all occupants were already thrown may still hold
    // the flag on the NEXT unit - read the vehicle, never the marker flag alone).
    private _boats = [];
    {
        private _v = vehicle _x;
        if ((_v != _x) && { (_v isKindOf "Boat_F") && { !(_v in _boats) } }) then { _boats pushBack _v; };
    } forEach units _group;
    private _nOut = 0;
    {
        private _v = vehicle _x;
        if (_v != _x) then {
            _x action ["Eject", _v];
            moveOut _x;
            _nOut = _nOut + 1;
        };
    } forEach units _group;
    { deleteVehicle _x; } forEach _boats;
    _group setVariable ["MISSION_CORE_BOAT_TRANSIT", nil];
    diag_log format ["BOAT TRANSIT: %1 disembarked %2 men at %3", groupId _group, _nOut, _at];
    _nOut
};

// APPROACH. Spawned (never called) by fn_sendCounterAttack's boat branch and by a leg whose
// squad materialised over water. The boats ride the straight line that spawned them; the
// waypoint is the shore crossing computed by MISSION_CORE_fnc_waterCrossingPoint - the exact
// point where that line turns from water to land. On arrival (or once beached) the eject fnc
// dismounts everyone and the squad finishes exactly like a "within 700m" foot squad.
MISSION_CORE_fnc_boatApproach = {
    params ["_group", "_targetPos", ["_targetSize", [50, 50]], ["_side", EAST]];
    if (isNull _group || { count units _group == 0 }) exitWith {};
    // Draw the line from the boat spawn to the destination marker and stop the ride where it
    // first crosses from water to land.
    private _cross = [getPosATL (leader _group), _targetPos] call MISSION_CORE_fnc_waterCrossingPoint;
    if (count _cross < 2) then { _cross = _targetPos; };
    private _ldr = leader _group;
    private _lp = getPosATL _ldr;
    // Already ashore at or past the crossing? Then there is no ride left - skip straight to
    // the eject (which is still correct: it also handles a partially-empty boat group).
    if (surfaceIsWater [_lp select 0, _lp select 1] && { ((_lp distance2D _cross) > 40) }) then {
        private _wp = _group addWaypoint [_cross, 20];
        _wp setWaypointType "MOVE";
        _wp setWaypointSpeed "FULL";
        _wp setWaypointBehaviour "AWARE";
        _group setCurrentWaypoint _wp;
        private _deadline = time + 600;
        waitUntil {
            sleep 2;
            (time > _deadline) ||
            { count units _group == 0 } ||
            {
                private _l2 = leader _group;
                private _p2 = getPosATL _l2;
                (((_p2 distance2D _cross) < 40) || { !(surfaceIsWater [_p2 select 0, _p2 select 1]) })
            }
        };
    };
    [_group, _cross, _side] call MISSION_CORE_fnc_boatDismount;
    if (count units _group == 0) exitWith {};
    // From the shore crossing the squad is a normal foot squad: approach, then quadrant
    // engagement - identical to the "within 700m" branch even though it just crossed a strait.
    [_group, _targetPos, _side] call MISSION_CORE_fnc_footArrival;
    [_group, _targetPos, _side] spawn MISSION_CORE_fnc_footSquadPostAssault;
};