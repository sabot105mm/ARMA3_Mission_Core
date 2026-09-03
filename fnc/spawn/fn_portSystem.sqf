// =====================================================================
// PORT TYPE + MANPOWER ECONOMY
//
// Ports are the manpower well. Each port generates manpower every tank
// tick (10s), scaled by its physical footprint (0.3x at 100m -> 0.9x at
// 300m, linear). Manpower accumulates at the port for manpowerPortAccumTicks
// (12 ticks) and is then SHIPPED IN A BATCH to a same-side BASE that needs it
// (a base whose served markers are requesting men). Bases hold the stock and
// distribute it 1-FOR-1 to markers that request men (garrison below baseline
// while contested) - every man delivered becomes exactly one man spawned.
//
// Ports come in two shapes:
//   - NESTED: the port's center sits inside another marker (a town/base/etc).
//     The port marker itself is HIDDEN (alpha 0) and LOCKED (never spawns its
//     own garrison, never captured) - the HOST spawns its garrison instead and
//     inherits factory-tier importance. The port still generates manpower and
//     gets a pier ICON on the map (icon + intel only, not an objective).
//   - ISOLATED: the port has no host. It spawns and acts like a factory
//     (importance 3, factory-style garrison).
// =====================================================================

// True when a loc entry is a Port marker (type "port" or name prefix "port_").
MISSION_CORE_fnc_isPort = {
    params ["_loc"];
    if (isNil "_loc" || { count _loc == 0 }) exitWith { false };
    (toLower (_loc select 2)) == "port" || { (_loc select 0) find "port_" == 0 }
};

// Port tank delivery budget. Ports build up tank points over time (see manpowerTick) that the
// recruit tank system draws on to fill a player's tank request from BLUFOR HQ. Each point is
// one tank delivered to a marker; it is consumed permanently.
MISSION_CORE_fnc_portTankBudget = {
    params ["_portName"];
    if (isNil "MISSION_CORE_PORT_TANK_POOL") then { MISSION_CORE_PORT_TANK_POOL = createHashMap; };
    MISSION_CORE_PORT_TANK_POOL getOrDefault [_portName, 0]
};

// Fill a recruit tank request for _markerName from BLUFOR port tank budget, if any BLUFOR port
// has a tank point available. Consumes one point from the nearest port with stock, then deploys
// a tank to the marker via the standard abstract-convoy path (a tank drives in and defends it).
MISSION_CORE_fnc_portFillTankRequest = {
    params ["_markerName", "_markerPos", ["_vehClass", ""], ["_cost", 0]];
    private _ports = [];
    if (!isNil "MISSION_CORE_PORTS") then {
        _ports = (keys MISSION_CORE_PORTS) select {
            private _info = MISSION_CORE_PORTS get _x;
            (count _info > 0) && { (_info select 2) == WEST } && { ([_x] call MISSION_CORE_fnc_portTankBudget) > 0 }
        };
    };
    if (count _ports == 0) exitWith { false };
    private _nearest = _ports select 0;
    private _nearestD = 1e10;
    {
        if (!isNil "MISSION_CORE_PORTS") then {
            private _pInfo = MISSION_CORE_PORTS get _x;
            if (count _pInfo > 0) then {
                private _d = (_pInfo select 0) distance2D _markerPos;
                if (_d < _nearestD) then { _nearestD = _d; _nearest = _x; };
            };
        };
    } forEach _ports;
    MISSION_CORE_PORT_TANK_POOL set [_nearest, ([_nearest] call MISSION_CORE_fnc_portTankBudget) - 1];
    // Deliver a tank to the marker (abstract column that drives in and defends). This is the
    // same deployment the depot system uses for tank orders.
    private _players = allPlayers select { alive _x };
    private _farDir = random 360;
    if (count _players > 0) then {
        private _np = _players select 0;
        private _bestD = 1e10;
        { private _d = _x distance _markerPos; if (_d < _bestD) then { _bestD = _d; _np = _x; }; } forEach _players;
        _farDir = (_np getDir _markerPos) + 180;
    };
    private _arrived = [WEST, _markerPos, _markerName, 1, (_markerPos getPos [300, _farDir]), _vehClass, _cost] call MISSION_CORE_fnc_tankDeployAbstract;
    diag_log format ["RECRUIT TANK: port %1 delivered a tank to %2", _nearest, _markerName];
    !isNull _arrived
};

// True when a loc entry is a Base marker (the manpower distribution hub).
MISSION_CORE_fnc_isBaseMarker = {
    params ["_loc"];
    if (isNil "_loc" || { count _loc == 0 }) exitWith { false };
    (toLower (_loc select 2)) == "base"
};

// Manpower size multiplier: 0.3 at manpowerPortSmall (100m) full footprint,
// 0.9 at manpowerPortLarge (300m), linear, clamped. getMarkerSize is a HALF-extent,
// so full footprint = 2 * largest half-axis.
MISSION_CORE_fnc_portSizeMult = {
    params ["_loc"];
    private _size = if (count _loc > 8 && { (_loc select 8) isEqualType [] }) then { _loc select 8 } else { [50, 50, 0] };
    private _half = (_size select 0) max (_size select 1);
    private _full = _half * 2;
    private _small = ["manpowerPortSmall", 100] call MISSION_CORE_fnc_tune;
    private _large = ["manpowerPortLarge", 300] call MISSION_CORE_fnc_tune;
    private _m = 0.3 + ((_full - _small) / (_large - _small)) * 0.6;
    (_m min 0.9) max 0.3
};

// Point-in-loc test against a cached-position entry (index 0 = name, index 1 = center,
// index 8 = [a, b, dir] half-extents). Shape-aware: RECTANGLE markers use a box test,
// ELLIPSE (and everything else) use the ellipse equation - an ellipse test against a
// rectangle marker wrongly rejects its corners.
MISSION_CORE_fnc_portPosInLoc = {
    params ["_pos", "_loc"];
    private _c = _loc select 1;
    private _sz = if (count _loc > 8) then { _loc select 8 } else { [200, 200, 0] };
    private _a = (_sz select 0) max 1;
    private _b = if (count _sz > 1) then { (_sz select 1) max 1 } else { _a };
    private _d = if (count _sz > 2) then { _sz select 2 } else { 0 };
    private _dx = (_pos select 0) - (_c select 0);
    private _dy = (_pos select 1) - (_c select 1);
    private _rx = _dx * cos _d - _dy * sin _d;
    private _ry = _dx * sin _d + _dy * cos _d;
    private _name = _loc select 0;
    private _shape = if (_name in allMapMarkers) then { markerShape _name } else { "ELLIPSE" };
    if (_shape == "RECTANGLE") exitWith { (abs _rx) <= _a && { abs _ry <= _b } };
    (_rx * _rx) / (_a * _a) + (_ry * _ry) / (_b * _b) <= 1
};

// Resolve every port: nest it into a host marker (hide + lock + host inherits
// factory importance) or keep it isolated (factory tier). Runs once at init,
// AFTER MISSION_CORE_CACHED_POSITIONS is built. Stores ports in
// MISSION_CORE_PORTS (name -> [pos, hostName, side, sizeMult]) and removes
// nested ports from the spawn/objective lists (they never field their own
// garrison; the host does).
MISSION_CORE_fnc_resolvePorts = {
    if (isNil "MISSION_CORE_PORTS") then { MISSION_CORE_PORTS = createHashMap; };
    if (isNil "MISSION_CORE_BASE_MANPOWER") then { MISSION_CORE_BASE_MANPOWER = createHashMap; };
    if (isNil "MISSION_CORE_PORT_ACCUM") then { MISSION_CORE_PORT_ACCUM = createHashMap; };

    private _ports = MISSION_CORE_CACHED_POSITIONS select { [_x] call MISSION_CORE_fnc_isPort };
    private _nestedNames = [];

    {
        private _port = _x;
        private _pName = _port select 0;
        private _pPos = _port select 1;
        private _side = _port select 4;

        // Find a host: any OTHER marker whose ellipse contains the port center.
        // Skip other ports (a port inside a port is still "isolated" relative to a host).
        private _host = [];
        {
            if ((_x select 0) != _pName && { !([_x] call MISSION_CORE_fnc_isPort) } && { [_pPos, _x] call MISSION_CORE_fnc_portPosInLoc }) exitWith { _host = _x; };
        } forEach MISSION_CORE_CACHED_POSITIONS;

        if (count _host > 0) then {
            // NESTED: hide + lock the port. The host spawns its own garrison; the port never
            // activates/captures on its own. Host inherits factory-tier importance (max(current,3)).
            private _hostName = _host select 0;
            _nestedNames pushBack _pName;
            if (_pName in allMapMarkers) then { _pName setMarkerAlpha 0; };
            // The port inherits its HOST's side - a port inside a BLUFOR HQ is BLUFOR, not the
            // scan default (EAST). Its manpower flows for the host's side, icon takes the host color.
            _side = _host select 4;
            // Pier icon: an ICON marker (not a capturable objective) so the port is visible on map.
            private _icon = createMarker [format ["DynOps_Port_%1", _pName], _pPos];
            _icon setMarkerShape "ICON";
            _icon setMarkerType (if (_side == WEST) then { "b_naval" } else { "o_naval" });
            _icon setMarkerColor (if (_side == WEST) then { "ColorBLUFOR" } else { "ColorOPFOR" });
            _icon setMarkerSize [1, 1];
            _icon setMarkerText (format ["PORT - %1", _hostName]);

            // Bump host importance to factory tier in both cached + location stores.
            private _hi = MISSION_CORE_CACHED_POSITIONS findIf { (_x select 0) == _hostName };
            if (_hi >= 0) then {
                private _he = MISSION_CORE_CACHED_POSITIONS select _hi;
                _he set [7, ((_he select 7) max 3)];
                MISSION_CORE_CACHED_POSITIONS set [_hi, _he];
            };
            if (!isNil "MISSION_CORE_LOCATIONS") then {
                private _li = MISSION_CORE_LOCATIONS findIf { (_x select 0) == _hostName };
                if (_li >= 0) then {
                    private _le = MISSION_CORE_LOCATIONS select _li;
                    _le set [7, ((_le select 7) max 3)];
                    MISSION_CORE_LOCATIONS set [_li, _le];
                };
            };

            MISSION_CORE_PORTS set [_pName, [_pPos, _hostName, _side, [_port] call MISSION_CORE_fnc_portSizeMult]];
            diag_log format ["DYNAMIC PORT: %1 nested inside %2 (hidden+locked, host->factory tier)", _pName, _hostName];
        } else {
            // ISOLATED: it spawns/acts like a factory (importance 3).
            private _pi = MISSION_CORE_CACHED_POSITIONS findIf { (_x select 0) == _pName };
            if (_pi >= 0) then {
                private _pe = MISSION_CORE_CACHED_POSITIONS select _pi;
                _pe set [7, 3];
                MISSION_CORE_CACHED_POSITIONS set [_pi, _pe];
            };
            MISSION_CORE_PORTS set [_pName, [_pPos, "", _side, [_port] call MISSION_CORE_fnc_portSizeMult]];
            diag_log format ["DYNAMIC PORT: %1 isolated - spawning as factory tier", _pName];
        };
    } forEach _ports;

    // Remove nested ports from the spawn/objective lists so nothing ever spawns,
    // contests, or captures them (the host is the real objective).
    if (count _nestedNames > 0) then {
        MISSION_CORE_CACHED_POSITIONS = MISSION_CORE_CACHED_POSITIONS select { !((_x select 0) in _nestedNames) };
        if (!isNil "MISSION_CORE_LOCATIONS") then {
            MISSION_CORE_LOCATIONS = MISSION_CORE_LOCATIONS select { !((_x select 0) in _nestedNames) };
        };
    };
    diag_log format ["DYNAMIC PORT: resolved %1 ports (%2 nested, %3 isolated)", count _ports, count _nestedNames, (count _ports) - (count _nestedNames)];
};

// One manpower tick (shared with the tank loop's 10s cadence):
//   1. every port accumulates manpower (perTickBase * sizeMult);
//   2. a port that has accumulated for manpowerPortAccumTicks ships its whole
//      batch to a same-side BASE that needs it (a base whose served markers are
//      requesting men); travel is abstract along the road network (convoy, not
//      piecemeal) and credits the base on arrival;
//   3. bases distribute 1-for-1 to requesting markers (contested, below baseline).
MISSION_CORE_fnc_manpowerTick = {
    if (isNil "MISSION_CORE_PORTS") exitWith {};
    if (isNil "MISSION_CORE_BASE_MANPOWER") then { MISSION_CORE_BASE_MANPOWER = createHashMap; };
    if (isNil "MISSION_CORE_PORT_ACCUM") then { MISSION_CORE_PORT_ACCUM = createHashMap; };
    if (isNil "MISSION_CORE_MANPOWER_CONVOYS") then { MISSION_CORE_MANPOWER_CONVOYS = []; };

    private _perTick = ["manpowerPerTickBase", 1] call MISSION_CORE_fnc_tune;
    private _accumTicks = ["manpowerPortAccumTicks", 12] call MISSION_CORE_fnc_tune;
    private _speed = ["manpowerConvoySpeed", 14] call MISSION_CORE_fnc_tune;

    // ---- 1. Ports accumulate ----
    {
        private _portName = _x;
        private _acc = MISSION_CORE_PORT_ACCUM getOrDefault [_portName, [0, 0]];
        private _mult = (MISSION_CORE_PORTS get _portName) select 3;
        _acc set [0, (_acc select 0) + (_perTick * _mult)];
        _acc set [1, (_acc select 1) + 1];
        MISSION_CORE_PORT_ACCUM set [_portName, _acc];
    } forEach (keys MISSION_CORE_PORTS);

    // ---- 1b. Ports build up tank-delivery budget ----
    // Every manpowerPortAccumTicks ticks a port gains one tank point (BLUFOR recruit tanks draw
    // on this via portFillTankRequest). Larger ports build slightly faster. Consumed permanently.
    if (isNil "MISSION_CORE_PORT_TANK_POOL") then { MISSION_CORE_PORT_TANK_POOL = createHashMap; };
    if (isNil "MISSION_CORE_PORT_TANK_ACCUM") then { MISSION_CORE_PORT_TANK_ACCUM = createHashMap; };
    {
        private _portName = _x;
        private _tacc = MISSION_CORE_PORT_TANK_ACCUM getOrDefault [_portName, 0];
        _tacc = _tacc + 1;
        MISSION_CORE_PORT_TANK_ACCUM set [_portName, _tacc];
        if (_tacc >= _accumTicks) then {
            MISSION_CORE_PORT_TANK_ACCUM set [_portName, 0];
            MISSION_CORE_PORT_TANK_POOL set [_portName, ([_portName] call MISSION_CORE_fnc_portTankBudget) + 1];
            diag_log format ["DYNAMIC PORT: %1 gained a tank-delivery point (pool %2)", _portName, ([_portName] call MISSION_CORE_fnc_portTankBudget)];
        };
    } forEach (keys MISSION_CORE_PORTS);

    // ---- 2. Port -> base shipping (batched convoy, not piecemeal) ----
    // A base "needs" manpower when its stock is empty. Ship the whole accumulated
    // batch to the nearest same-side base that needs it; travel is abstract (ETA by
    // distance / speed), crediting the base on arrival. Ports with no empty base hold
    // their batch (never piecemeal).
    {
        private _portName = _x;
        private _pInfo = MISSION_CORE_PORTS get _portName;
        private _pPos = _pInfo select 0;
        private _pSide = _pInfo select 2;
        private _acc = MISSION_CORE_PORT_ACCUM getOrDefault [_portName, [0, 0]];
        if ((_acc select 1) < _accumTicks) then { continue; };
        private _ship = _acc select 0;
        if (_ship <= 0) then { continue; };
        MISSION_CORE_PORT_ACCUM set [_portName, [0, 0]];

        private _bases = MISSION_CORE_CACHED_POSITIONS select {
            (_x select 4) == _pSide && { [_x] call MISSION_CORE_fnc_isBaseMarker }
        };
        if (count _bases == 0) then { continue; };
        // Prefer the nearest base that NEEDS manpower (empty stock); fall back to nearest base.
        private _needBase = [];
        private _needD = 1e10;
        {
            if ((MISSION_CORE_BASE_MANPOWER getOrDefault [_x select 0, 0]) <= 0) then {
                private _d = _pPos distance2D (_x select 1);
                if (_d < _needD) then { _needD = _d; _needBase = _x; };
            };
        } forEach _bases;
        if (count _needBase == 0) then {
            // No base is empty - hold the batch at the port (no piecemeal shipping).
            MISSION_CORE_PORT_ACCUM set [_portName, [_ship, _accumTicks]];
            continue;
        };
private _bName = _needBase select 0;
    private _bPos = _needBase select 1;
    private _dist = _pPos distance2D _bPos;
    private _eta = _dist / _speed;
    MISSION_CORE_MANPOWER_CONVOYS pushBack [_portName, _bName, _ship, time + _eta];
    diag_log format ["DYNAMIC MANPOWER: %1 shipping %2 manpower to base %3 (ETA %4s)", _portName, round (_ship * 10) / 10, _bName, round _eta];
    } forEach (keys MISSION_CORE_PORTS);

    // ---- Arrive manpower convoys ----
    {
        private _c = _x;
        if (time >= (_c select 3)) then {
            private _bName = _c select 1;
            private _stock = MISSION_CORE_BASE_MANPOWER getOrDefault [_bName, 0];
            MISSION_CORE_BASE_MANPOWER set [_bName, _stock + (_c select 2)];
            diag_log format ["DYNAMIC MANPOWER: %1 -> base %2 delivered %3 manpower", _c select 0, _bName, round ((_c select 2) * 10) / 10];
            MISSION_CORE_MANPOWER_CONVOYS set [_forEachIndex, []];
        };
    } forEach MISSION_CORE_MANPOWER_CONVOYS;
    MISSION_CORE_MANPOWER_CONVOYS = MISSION_CORE_MANPOWER_CONVOYS select { count _x > 0 };
};

// Draw up to _men manpower from the nearest same-side base with stock, 1-for-1.
// Returns [_funded, _baseName] (baseName "" when nothing was available). The caller
// may refund unused men via MISSION_CORE_fnc_refundBaseManpower.
MISSION_CORE_fnc_drawBaseManpower = {
    params ["_side", "_locPos", "_men"];
    if (_men <= 0) exitWith { [0, ""] };
    if (isNil "MISSION_CORE_BASE_MANPOWER") then { MISSION_CORE_BASE_MANPOWER = createHashMap; };
    private _bases = MISSION_CORE_CACHED_POSITIONS select {
        (_x select 4) == _side && { [_x] call MISSION_CORE_fnc_isBaseMarker }
    };
    private _best = [];
    private _bestD = 1e10;
    {
        if ((MISSION_CORE_BASE_MANPOWER getOrDefault [_x select 0, 0]) > 0) then {
            private _d = _locPos distance2D (_x select 1);
            if (_d < _bestD) then { _bestD = _d; _best = _x; };
        };
    } forEach _bases;
    if (count _best == 0) exitWith { [0, ""] };
    private _bName = _best select 0;
    private _stock = MISSION_CORE_BASE_MANPOWER getOrDefault [_bName, 0];
    private _give = _stock min _men;
    if (_give <= 0) exitWith { [0, ""] };
    MISSION_CORE_BASE_MANPOWER set [_bName, _stock - _give];
    [_give, _bName]
};

// Return unused manpower to a base's stock (a replenish spawned fewer men than budgeted).
MISSION_CORE_fnc_refundBaseManpower = {
    params ["_baseName", "_amount"];
    if (_baseName == "" || { _amount <= 0 }) exitWith {};
    if (isNil "MISSION_CORE_BASE_MANPOWER") then { MISSION_CORE_BASE_MANPOWER = createHashMap; };
    private _stock = MISSION_CORE_BASE_MANPOWER getOrDefault [_baseName, 0];
    MISSION_CORE_BASE_MANPOWER set [_baseName, _stock + _amount];
};
