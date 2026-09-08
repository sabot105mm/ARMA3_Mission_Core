// =====================================================================
// AMMUNITION SYSTEM
// Per-marker ammo resource that drives AI aggression.  Ports produce
// ammo, ship it abstractly to depots (base/hq/factory), and markers
// request from depots when low.  Offensive actions (attack, counter-
// attack, hunt, armor reinforcement) consume ammo.  Low ammo forces
// defensive behavior; empty ammo forces passivity.
// =====================================================================

MISSION_CORE_fnc_initAmmo = {
    if (isNil "MISSION_CORE_LOCATION_AMMO") then { MISSION_CORE_LOCATION_AMMO = createHashMap; };
    if (isNil "MISSION_CORE_LOCATION_AMMO_MAX") then { MISSION_CORE_LOCATION_AMMO_MAX = createHashMap; };
    if (isNil "MISSION_CORE_PORT_AMMO_ACCUM") then { MISSION_CORE_PORT_AMMO_ACCUM = createHashMap; };
    if (isNil "MISSION_CORE_AMMO_REQUEST_CD") then { MISSION_CORE_AMMO_REQUEST_CD = createHashMap; };
    private _base = ["ammoBasePerImp", 20] call MISSION_CORE_fnc_tune;
    {
        private _name = _x select 0;
        private _imp = _x select 7;
        private _area = _x select 8;
        private _sizeA = _area select 0;
        private _sizeB = _area select 1;
        private _sizeFactor = (sqrt (_sizeA * _sizeB) / 150) min 2;
        private _maxAmmo = floor (_imp * _base * _sizeFactor);
        MISSION_CORE_LOCATION_AMMO_MAX set [_name, _maxAmmo];
        MISSION_CORE_LOCATION_AMMO set [_name, floor (_maxAmmo * 0.5)];
    } forEach MISSION_CORE_CACHED_POSITIONS;
    publicVariable "MISSION_CORE_LOCATION_AMMO_MAX";
    publicVariable "MISSION_CORE_LOCATION_AMMO";
    diag_log format ["AMMO: initialized %1 markers (base=%2)", count MISSION_CORE_LOCATION_AMMO, _base];
};

// Charge ammo from a marker. Returns true if the marker had enough.
MISSION_CORE_fnc_consumeAmmo = {
    params ["_markerName", "_amount"];
    if (isNil "MISSION_CORE_LOCATION_AMMO") exitWith { false };
    private _cur = MISSION_CORE_LOCATION_AMMO getOrDefault [_markerName, 0];
    if (_cur < _amount) exitWith { false };
    MISSION_CORE_LOCATION_AMMO set [_markerName, _cur - _amount];
    publicVariable "MISSION_CORE_LOCATION_AMMO";
    true
};

// Ammo fraction (0..1) for a marker.
MISSION_CORE_fnc_getAmmoFraction = {
    params ["_markerName"];
    if (isNil "MISSION_CORE_LOCATION_AMMO" || isNil "MISSION_CORE_LOCATION_AMMO_MAX") exitWith { 1 };
    private _ammo = MISSION_CORE_LOCATION_AMMO getOrDefault [_markerName, 0];
    private _max = MISSION_CORE_LOCATION_AMMO_MAX getOrDefault [_markerName, 1];
    if (_max <= 0) exitWith { 0 };
    _ammo / _max
};

// Aggression multiplier from ammo level.  0 = passive, 0.3 = defensive, 0.5 = cautious, 1 = aggressive.
MISSION_CORE_fnc_ammoAggressionMult = {
    params ["_markerName"];
    private _frac = [_markerName] call MISSION_CORE_fnc_getAmmoFraction;
    if (_frac <= 0) exitWith { 0 };
    if (_frac < 0.3) exitWith { 0 };
    if (_frac < 0.7) exitWith { 0.5 };
    1.0
};

MISSION_CORE_fnc_ammoCanAttack = {
    params ["_markerName"];
    ([_markerName] call MISSION_CORE_fnc_getAmmoFraction) >= 0.3
};

MISSION_CORE_fnc_ammoCanHunt = {
    params ["_markerName"];
    ([_markerName] call MISSION_CORE_fnc_getAmmoFraction) >= 0.3
};

// ---- PORT PRODUCTION ----
// Every tick each port accumulates importance * rate * sizeMult ammo.  When the batch reaches
// the threshold it is shipped abstractly to the nearest same-side depot (base/hq/factory) that
// has room.
MISSION_CORE_fnc_ammoPortProduction = {
    if (isNil "MISSION_CORE_LOCATION_AMMO") exitWith {};
    private _rate = ["ammoPortRatePerImp", 0.5] call MISSION_CORE_fnc_tune;
    private _threshold = ["ammoPortShipThreshold", 20] call MISSION_CORE_fnc_tune;
    {
        private _name = _x select 0;
        private _type = _x select 2;
        private _imp = _x select 7;
        private _owner = _x select 4;
        if (toLower _type != "port") then { continue; };
        private _sizeMult = if (!isNil "MISSION_CORE_PORTS" && { _name in MISSION_CORE_PORTS }) then {
            (MISSION_CORE_PORTS get _name) select 3
        } else { 1.0 };
        private _accum = MISSION_CORE_PORT_AMMO_ACCUM getOrDefault [_name, 0];
        MISSION_CORE_PORT_AMMO_ACCUM set [_name, _accum + (_imp * _rate * _sizeMult)];
        private _newAccum = MISSION_CORE_PORT_AMMO_ACCUM getOrDefault [_name, 0];
        if (_newAccum >= _threshold) then {
            private _depots = MISSION_CORE_CACHED_POSITIONS select {
                (_x select 4) == _owner &&
                { (_x select 0) != _name } &&
                { toLower (_x select 2) in ["base", "hq", "factory"] } &&
                { (MISSION_CORE_LOCATION_AMMO getOrDefault [_x select 0, 0]) < (MISSION_CORE_LOCATION_AMMO_MAX getOrDefault [_x select 0, 1]) }
            };
            if (count _depots > 0) then {
                private _portPos = _x select 1;
                _depots = [_depots, [], { (_x select 1) distance _portPos }, "ASCEND"] call BIS_fnc_sortBy;
                private _depot = _depots select 0;
                private _depotName = _depot select 0;
                private _depotMax = MISSION_CORE_LOCATION_AMMO_MAX getOrDefault [_depotName, 1];
                private _depotCur = MISSION_CORE_LOCATION_AMMO getOrDefault [_depotName, 0];
                private _room = _depotMax - _depotCur;
                private _toShip = (_threshold min _room) max 0;
                if (_toShip > 0) then {
                    MISSION_CORE_PORT_AMMO_ACCUM set [_name, _newAccum - _toShip];
                    MISSION_CORE_LOCATION_AMMO set [_depotName, _depotCur + _toShip];
                    diag_log format ["AMMO: port %1 shipped %2 to depot %3", _name, _toShip, _depotName];
                };
            };
        };
    } forEach MISSION_CORE_CACHED_POSITIONS;
};

// ---- MARKER AMMO REQUEST ----
// When a marker's ammo drops below 30% of its max it requests from the nearest same-side depot.
MISSION_CORE_fnc_ammoRequestTick = {
    if (isNil "MISSION_CORE_LOCATION_AMMO") exitWith {};
    private _requestFrac = ["ammoRequestThreshold", 0.3] call MISSION_CORE_fnc_tune;
    private _maxPerReq = ["ammoMaxPerRequest", 20] call MISSION_CORE_fnc_tune;
    private _cooldown = ["ammoRequestCooldown", 120] call MISSION_CORE_fnc_tune;
    {
        private _name = _x select 0;
        private _owner = _x select 4;
        private _pos = _x select 1;
        private _maxAmmo = MISSION_CORE_LOCATION_AMMO_MAX getOrDefault [_name, 1];
        private _current = MISSION_CORE_LOCATION_AMMO getOrDefault [_name, 0];
        private _fraction = if (_maxAmmo > 0) then { _current / _maxAmmo } else { 1 };
        if (_fraction >= _requestFrac) then { continue; };
        private _lastReq = MISSION_CORE_AMMO_REQUEST_CD getOrDefault [_name, -9999];
        if (time - _lastReq < _cooldown) then { continue; };
        private _depots = MISSION_CORE_CACHED_POSITIONS select {
            (_x select 4) == _owner &&
            { (_x select 0) != _name } &&
            { toLower (_x select 2) in ["base", "hq", "factory", "port"] } &&
            { (MISSION_CORE_LOCATION_AMMO getOrDefault [_x select 0, 0]) > 10 }
        };
        if (count _depots == 0) then { continue; };
        _depots = [_depots, [], { (_x select 1) distance _pos }, "ASCEND"] call BIS_fnc_sortBy;
        private _depot = _depots select 0;
        private _depotName = _depot select 0;
        private _depotAmmo = MISSION_CORE_LOCATION_AMMO getOrDefault [_depotName, 0];
        private _deficit = _maxAmmo - _current;
        private _toGive = (_deficit min _maxPerReq min _depotAmmo) max 0;
        if (_toGive > 0) then {
            MISSION_CORE_LOCATION_AMMO set [_depotName, _depotAmmo - _toGive];
            MISSION_CORE_LOCATION_AMMO set [_name, _current + _toGive];
            MISSION_CORE_AMMO_REQUEST_CD set [_name, time];
            diag_log format ["AMMO: %1 received %2 from %3", _name, _toGive, _depotName];
        };
    } forEach MISSION_CORE_CACHED_POSITIONS;
};

// ---- MAIN LOOP ----
MISSION_CORE_fnc_ammoLoop = {
    diag_log "AMMO: loop started";
    while { true } do {
        sleep 10;
        [] call MISSION_CORE_fnc_ammoPortProduction;
        [] call MISSION_CORE_fnc_ammoRequestTick;
    };
};