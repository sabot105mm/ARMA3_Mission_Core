//
// TANK DEPOTS - production & warehousing for armor refills.
//
// Factories BUILD tanks (1 per 10 min) into their own storage; bases act as WAREHOUSES
// (filled by factory overflow). Storage cap is 10 tanks on a marker whose largest axis is
// under 700m, 20 tanks at/over 700m - the SAME rule for factories and bases. Surplus beyond
// a factory's cap convoys to the nearest same-side base instead of idling.
//
// Parked tanks are EMPTY, uncrewed, stealable vehicles. They are excluded from the
// armorCapOpen fielded count (only real deployed armor consumes the global MBT budget).
// The moment a player boards a driver seat the tank leaves the side's stock.
//
// Orders (pool refills / counter-attack tanks) route to the nearest same-side base that
// has stock; if no base has stock the order forwards to the nearest factory. Shipments move
// as convoy columns of 2-3 tanks and are gated at dispatch by the side-wide MBT cap.
// =====================================================================

MISSION_CORE_fnc_tankDepotIsDepot = {
    params ["_loc"];
    if (isNil "_loc" || count _loc == 0) exitWith { false };
    private _t = toLower (_loc select 2);
    // Tank warehouses: factories build + store, bases store (overflow target), and dedicated
    // depots hold a reserve battery too - all can fill tank orders for markers that request them.
    (_t find "factory" > -1 || _t find "base" > -1 || _t find "depot" > -1)
};

MISSION_CORE_fnc_tankDepotIsProducer = {
    params ["_loc"];
    if (isNil "_loc" || count _loc == 0) exitWith { false };
    (toLower (_loc select 2)) find "factory" > -1
};

// A POWERPLANT: an editor marker named power_* OR any auto-generated loc_* whose real map label
// (index 10) contains "power" (e.g. "Power Plant", "Kavala Power Plant").
MISSION_CORE_fnc_isPowerplant = {
    params ["_loc"];
    if (isNil "_loc" || count _loc == 0) exitWith { false };
    private _name = toLower (_loc select 0);
    if (_name find "power_" == 0) exitWith { true };
    if (count _loc > 10) then {
        private _lbl = toLower (_loc select 10);
        if (_lbl find "power" > -1) exitWith { true };
    };
    false
};

// A SOLAR PLANT: an editor marker named solar_* OR an auto loc_* whose label contains "solar".
// Counts as solarContribution of a full powerplant.
MISSION_CORE_fnc_isSolarPlant = {
    params ["_loc"];
    if (isNil "_loc" || count _loc == 0) exitWith { false };
    private _name = toLower (_loc select 0);
    if (_name find "solar_" == 0) exitWith { true };
    if (count _loc > 10) then {
        private _lbl = toLower (_loc select 10);
        if (_lbl find "solar" > -1) exitWith { true };
    };
    false
};

// Tank production multiplier for a factory:
//   multiplier = 1 + powerplantGlobalBonus * (same-side powerplant UNITS)
//                + powerplantNeighborBonus * (powerplant UNITS within neighbor range)
// A full powerplant = 1.0 unit; a solar plant = solarContribution units (default 0.25).
// Faster production = the build interval is divided by this (so 2x -> builds every interval/2).
MISSION_CORE_fnc_tankFactoryMultiplier = {
    params ["_loc"];
    private _side = _loc select 4;
    private _fPos = _loc select 1;
    private _solarFrac = ["solarContribution", 0.25] call MISSION_CORE_fnc_tune;
    // All same-side power sources with their unit weights.
    private _sources = MISSION_CORE_CACHED_POSITIONS select {
        (_x select 4) == _side && {
            if ([_x] call MISSION_CORE_fnc_isPowerplant) then { true }
            else { [_x] call MISSION_CORE_fnc_isSolarPlant }
        }
    };
    private _global = 0;
    {
        private _w = if ([_x] call MISSION_CORE_fnc_isPowerplant) then { 1 } else { _solarFrac };
        _global = _global + _w;
    } forEach _sources;
    private _nRange = ["powerplantNeighborRange", 1500] call MISSION_CORE_fnc_tune;
    private _neighbors = 0;
    {
        if ((_x select 1) distance2D _fPos < _nRange) then {
            private _w = if ([_x] call MISSION_CORE_fnc_isPowerplant) then { 1 } else { _solarFrac };
            _neighbors = _neighbors + _w;
        };
    } forEach _sources;
    private _gBonus = ["powerplantGlobalBonus", 0.2] call MISSION_CORE_fnc_tune;
    private _nBonus = ["powerplantNeighborBonus", 0.5] call MISSION_CORE_fnc_tune;
    1 + (_gBonus * _global) + (_nBonus * _neighbors)
};

// Storage cap: 10 unless the marker spans >= 700m on its largest axis -> 20.
MISSION_CORE_fnc_tankDepotCap = {
    params ["_loc"];
    private _size = if (count _loc > 8 && { (_loc select 8) isEqualType [] }) then { _loc select 8 } else { [200, 200] };
    if (((_size select 0) max (_size select 1)) >= 700) exitWith { ["tankDepotCapLarge", 20] call MISSION_CORE_fnc_tune };
    ["tankDepotCapSmall", 10] call MISSION_CORE_fnc_tune
};

MISSION_CORE_fnc_tankDepotStock = {
    params ["_name"];
    if (isNil "MISSION_CORE_TANK_STOCK") then { MISSION_CORE_TANK_STOCK = createHashMap; };
    MISSION_CORE_TANK_STOCK getOrDefault [_name, 0]
};

// Parked position for the _parkCount-th tank: a PERFECT LINE along the marker's row axis.
// Rows: once the row is full (or a spot fails the safety check) a NEW ROW starts further
// back - the "safe spot finder can't find another spot -> new row" rule.
MISSION_CORE_fnc_tankParkPos = {
    params ["_loc", "_parkCount"];
    private _center = _loc select 1;
    private _size = if (count _loc > 8 && { (_loc select 8) isEqualType [] }) then { _loc select 8 } else { [200, 200] };
    private _dir = if (count _size > 2) then { _size select 2 } else { 0 };
    private _maxAxis = (_size select 0) max (_size select 1);
    private _spacing = 16;
    private _rowMax = (floor ((_maxAxis * 0.8) / _spacing)) max 1;
    private _row = floor (_parkCount / _rowMax);
    private _col = _parkCount mod _rowMax;
    private _dx = (_col - (_rowMax - 1) * 0.5) * _spacing;
    private _dy = _row * 20;
    private _rad = _dir;
    private _ox = _dx * cos _rad - _dy * sin _rad;
    private _oy = _dx * sin _rad + _dy * cos _rad;
    ([(_center select 0) + _ox, (_center select 1) + _oy, 0])
};

// Park ONE reserve tank at a depot. Empty, uncrewed, stealable, flagged MISSION_CORE_TANK_RESERVE
// so armorCapOpen never counts it as a fielded MBT.
MISSION_CORE_fnc_tankReserveSpawn = {
    params ["_loc", "_parkCount", "_side", "_name"];
    private _factionData = if (_side == WEST) then { MISSION_CORE_BLUFOR_DATA } else { MISSION_CORE_REDFOR_DATA };
    private _mbtClasses = (_factionData select 7) getOrDefault ["mbt", []];
    if (count _mbtClasses == 0) exitWith { objNull };
    private _parkPos = [_loc, _parkCount] call MISSION_CORE_fnc_tankParkPos;
    private _center = [_parkPos select 0, _parkPos select 1, 0];
    private _size = if (count _loc > 8 && { (_loc select 8) isEqualType [] }) then { _loc select 8 } else { [200, 200] };
    private _maxR = ((_size select 0) max (_size select 1)) min 300;
    // BIS_fnc_findSafePos: [center, minDist, maxDist, objDist, waterMode, maxGrad, shoreMode]
    private _pos = [_center, 0, _maxR, 15, 0, 0.5, 0] call BIS_fnc_findSafePos;
    if (count _pos < 2) then { _pos = [_center, 0, _maxR, 15, 0, 1, 0] call BIS_fnc_findSafePos; };
    if (count _pos < 2) then { _pos = +_parkPos; };
    // Ensure 3-element position array
    if (count _pos == 2) then { _pos pushBack 0; };
    if ([_pos] call MISSION_CORE_fnc_isUnsafeVehicleSpawn) then {
        _pos = [_center, 0, _maxR, 15, 0, 0.5, 0] call BIS_fnc_findSafePos;
        if (count _pos < 2) then { _pos = +_parkPos; };
        if (count _pos == 2) then { _pos pushBack 0; };
    };
    // PERMANENT RULE: parked rows sit 50m+ from any house/building - armor never parks against a
    // house. Verify the resolved spot before spawning; if a house is within 50m, step the parked
    // position outward AWAY from the nearest house (bounded to 500m) until a house-free spot is
    // found. If no clear spot exists, park at the candidate that ended up farthest from houses.
    private _houseTypesNear = ["Building", "House", "Strategic", "Fortress", "Wall", "Fence"];
    if ((count (nearestObjects [_pos, _houseTypesNear, 50])) > 0) then {
        private _bestSpot = _pos;
        private _bestHouseDist = 1e10;
        private _foundClear = false;
        private _nearH0 = nearestObjects [_pos, _houseTypesNear, 50] select 0;
        private _awayV = _pos vectorDiff (getPos _nearH0);
        private _awayLen = vectorMagnitude _awayV;
        if (_awayLen > 0) then { _awayV = _awayV vectorMultiply (1 / _awayLen); };
        for "_s" from 1 to 25 do {
            private _cand = (_pos vectorAdd (_awayV vectorMultiply (_s * 20))) call MISSION_CORE_fnc_ensureLandPos;
            private _near = nearestObjects [_cand, _houseTypesNear, 100];
            private _dHouse = if (count _near > 0) then { _cand distance2D (_near select 0) } else { 1e10 };
            if (_dHouse < _bestHouseDist) then { _bestHouseDist = _dHouse; _bestSpot = _cand; };
            if (_dHouse >= 50) exitWith { _pos = _cand; _foundClear = true; };
        };
        if (!_foundClear) then { _pos = _bestSpot; };
    };
    _pos = [_pos] call MISSION_CORE_fnc_ensureLandPos;
    private _veh = createVehicle [selectRandom _mbtClasses, [_pos] call MISSION_CORE_fnc_liftSpawn, [], 0, "CAN_COLLIDE"];
    _veh setDir random 360;
    _veh lock 0;
    _veh setVariable ["MISSION_CORE_TANK_RESERVE", true];
    _veh setVariable ["MISSION_CORE_TANK_HOME", _name];
    _veh setVariable ["MISSION_CORE_TANK_SIDE", _side];
    _veh setVariable ["MISSION_CORE_TANK_STOCKED", true];
    // Stolen (driver boarded by any unit) or destroyed -> leave the side's stock.
    _veh addEventHandler ["GetIn", {
        params ["_v", "_role"];
        if (_role == "driver" && { _v getVariable ["MISSION_CORE_TANK_STOCKED", false] }) then {
            _v setVariable ["MISSION_CORE_TANK_STOCKED", false];
            [_v] call MISSION_CORE_fnc_tankUnpark;
        };
    }];
    _veh addEventHandler ["Killed", {
        params ["_v"];
        if (_v getVariable ["MISSION_CORE_TANK_STOCKED", false]) then {
            _v setVariable ["MISSION_CORE_TANK_STOCKED", false];
            [_v] call MISSION_CORE_fnc_tankUnpark;
        };
    }];
    diag_log format ["DYNAMIC TANK: parked %1 at %2 (stock %3)", typeOf _veh, _name, [_name] call MISSION_CORE_fnc_tankDepotStock];
    _veh
};

// Remove a tank from a depot's stock + parking list (stolen/destroyed/shipped).
MISSION_CORE_fnc_tankUnpark = {
    params ["_veh"];
    if (isNull _veh) exitWith {};
    private _home = _veh getVariable ["MISSION_CORE_TANK_HOME", ""];
    if (_home == "") exitWith {};
    if (isNil "MISSION_CORE_TANK_PARK") then { MISSION_CORE_TANK_PARK = createHashMap; };
    private _parked = MISSION_CORE_TANK_PARK getOrDefault [_home, []];
    _parked = _parked - [_veh];
    MISSION_CORE_TANK_PARK set [_home, _parked];
    private _stock = MISSION_CORE_TANK_STOCK getOrDefault [_home, 0];
    MISSION_CORE_TANK_STOCK set [_home, (_stock - 1) max 0];
    diag_log format ["DYNAMIC TANK: %1 departed %2 stock -> %3", typeOf _veh, _home, MISSION_CORE_TANK_STOCK getOrDefault [_home, 0]];
};

// Ensure a live depot physically shows the number of tanks in its stock (up to cap).
// Delete surplus physical tanks beyond stock; spawn more up to stock.
MISSION_CORE_fnc_tankParkReconcile = {
    params ["_loc"];
    private _name = _loc select 0;
    private _stock = [_name] call MISSION_CORE_fnc_tankDepotStock;
    if (isNil "MISSION_CORE_TANK_PARK") then { MISSION_CORE_TANK_PARK = createHashMap; };
    private _parked = MISSION_CORE_TANK_PARK getOrDefault [_name, []];
    _parked = _parked select { !isNull _x && { alive _x } };
    while { count _parked > _stock } do {
        private _v = _parked deleteAt (count _parked - 1);
        deleteVehicle _v;
    };
    private _side = _loc select 4;
    if (isNil "MISSION_CORE_TANK_PARK_SIDE") then { MISSION_CORE_TANK_PARK_SIDE = createHashMap; };
    MISSION_CORE_TANK_PARK_SIDE set [_name, _side];
    while { count _parked < _stock } do {
        private _v = [_loc, count _parked, _side, _name] call MISSION_CORE_fnc_tankReserveSpawn;
        if (isNull _v) exitWith {};
        _parked pushBack _v;
        sleep 0.05;
    };
    MISSION_CORE_TANK_PARK set [_name, _parked];
};

// Place a tank refill order. Deduplicated per side+target so lost tanks never stack an
// unlimited order list; the loop keeps it until a depot can satisfy it.
MISSION_CORE_fnc_orderTank = {
    params ["_side", "_targetName", "_targetPos", ["_n", 1], ["_assault", false]];
    if (isNil "_side" || { _side isEqualTo "" }) exitWith { false };
    if (isNil "_targetName" || _targetName == "") exitWith { false };
    if (isNil "MISSION_CORE_TANK_ORDERS") then { MISSION_CORE_TANK_ORDERS = []; };
    // Deduplicated per side+target so lost tanks never stack an unlimited order list; a repeat
    // request only raises the pending count (a two-tank pool that lost both tops up to 2). An
    // ASSAULT order draws extra tanks for a scripted attack (ignores the per-marker local MBT
    // rule at dispatch, but still respects the side-wide cap).
    private _i = MISSION_CORE_TANK_ORDERS findIf { (_x select 0) == _side && { (_x select 1) == _targetName } };
    if (_i != -1) then {
        private _cur = MISSION_CORE_TANK_ORDERS select _i;
        if ((_cur select 4) < _n) then { _cur set [4, _n]; };
        if (_assault) then { _cur set [5, true]; };
        false
    } else {
        MISSION_CORE_TANK_ORDERS pushBack [_side, _targetName, _targetPos, time, _n, _assault];
        diag_log format ["DYNAMIC TANK: order placed %1 -> %2 (n=%3, assault=%4)", _side, _targetName, _n, _assault];
        true
    };
};

// =====================================================================
// ARMOR RECRUIT POOL - the deliverable armor the HQ recruit system draws on.
//
// "Tank pool available to recruit": every same-side depot's parked stock PLUS every
// same-side port's tank-delivery budget. Recruiting armor (tank / APC / SPG / MLRS) is
// NEVER conjured from nothing - it consumes one of these pool points. Queued tank orders
// wait for the pool to fill (factories build, ports accumulate); instant delivery and
// APC/SPG/MLRS recruits consume a pool point immediately or are refused.
// =====================================================================

// Total armor-pool points a side can recruit from right now.
MISSION_CORE_fnc_poolTanksForSide = {
    params ["_side"];
    private _n = 0;
    if (!isNil "MISSION_CORE_TANK_STOCK" && { !isNil "MISSION_CORE_CACHED_POSITIONS" }) then {
        {
            if ((_x select 4) == _side && { [_x] call MISSION_CORE_fnc_tankDepotIsDepot }) then {
                _n = _n + ([(_x select 0)] call MISSION_CORE_fnc_tankDepotStock);
            };
        } forEach MISSION_CORE_CACHED_POSITIONS;
    };
    if (!isNil "MISSION_CORE_PORTS") then {
        {
            private _info = MISSION_CORE_PORTS get _x;
            if (count _info > 0 && { (_info select 2) == _side }) then {
                _n = _n + ([_x] call MISSION_CORE_fnc_portTankBudget);
            };
        } forEach (keys MISSION_CORE_PORTS);
    };
    _n
};

// Consume ONE pool point for a side's recruit: take from the NEAREST depot that has parked
// stock (bases first, then factories), else from the nearest same-side port with tank budget.
// Returns the source marker name, or "" when the pool has nothing available.
MISSION_CORE_fnc_consumePoolTankForSide = {
    params ["_side", "_nearPos"];
    if (isNil "_nearPos") then { _nearPos = [0, 0, 0]; };
    private _src = "";
    if (!isNil "MISSION_CORE_TANK_STOCK" && { !isNil "MISSION_CORE_CACHED_POSITIONS" }) then {
        private _depots = MISSION_CORE_CACHED_POSITIONS select {
            (_x select 4) == _side && { [_x] call MISSION_CORE_fnc_tankDepotIsDepot } && { ([(_x select 0)] call MISSION_CORE_fnc_tankDepotStock) > 0 }
        };
        if (count _depots > 0) then {
            private _bases = _depots select { !([_x] call MISSION_CORE_fnc_tankDepotIsProducer) };
            private _cands = if (count _bases > 0) then { _bases } else { _depots };
            _cands = [_cands, [], { _nearPos distance (_x select 1) }, "ASCEND"] call BIS_fnc_sortBy;
            private _d = _cands select 0;
            private _name = _d select 0;
            MISSION_CORE_TANK_STOCK set [_name, ([_name] call MISSION_CORE_fnc_tankDepotStock) - 1];
            [_d] call MISSION_CORE_fnc_tankParkReconcile;
            diag_log format ["RECRUIT TANK: consumed 1 armor pool point from depot %1 (stock %2)", _name, ([_name] call MISSION_CORE_fnc_tankDepotStock)];
            _src = _name;
        };
    };
    if (_src == "" && { !isNil "MISSION_CORE_PORTS" }) then {
        private _ports = (keys MISSION_CORE_PORTS) select {
            private _info = MISSION_CORE_PORTS get _x;
            (count _info > 0) && { (_info select 2) == _side } && { ([_x] call MISSION_CORE_fnc_portTankBudget) > 0 }
        };
        if (count _ports > 0) then {
            private _best = _ports select 0;
            private _bestD = 1e10;
            {
                private _pInfo = MISSION_CORE_PORTS get _x;
                if (count _pInfo > 0) then {
                    private _dd = (_pInfo select 0) distance2D _nearPos;
                    if (_dd < _bestD) then { _bestD = _dd; _best = _x; };
                };
            } forEach _ports;
            MISSION_CORE_PORT_TANK_POOL set [_best, ([_best] call MISSION_CORE_fnc_portTankBudget) - 1];
            diag_log format ["RECRUIT TANK: consumed 1 armor pool point from port %1 (budget %2)", _best, ([_best] call MISSION_CORE_fnc_portTankBudget)];
            _src = _best;
        };
    };
    _src
};

// Broadcast the current BLUFOR armor-pool count so every HQ recruit menu can show availability.
MISSION_CORE_fnc_publishArmorPool = {
    missionNamespace setVariable ["MISSION_CORE_ARMOR_POOL", [WEST] call MISSION_CORE_fnc_poolTanksForSide, true];
};