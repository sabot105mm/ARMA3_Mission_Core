// =====================================================================
// PLAYER MANPOWER ECONOMY
//
// Manpower is the currency for recruiting squads. BLUFOR players share
// a single pool that grows from two sources:
//   1. PORTS: each BLUFOR port generates manpower every tick, scaled
//      by its size multiplier (same as the AI garrison system).
//   2. TOWN CAPTURE: securing a marker awards importance * captureMult
//      manpower as a one-time bonus.
//
// Spending: recruit squads (player group, defenders, attackers) costs
// manpowerPerUnit per soldier.
// =====================================================================

MISSION_CORE_MANPOWER_PER_UNIT = ["manpowerPerUnit", 1] call MISSION_CORE_fnc_tune;
MISSION_CORE_MANPOWER_CAPTURE_MULT = ["manpowerCaptureMult", 5] call MISSION_CORE_fnc_tune;
MISSION_CORE_MANPOWER_PORT_PER_TICK = ["manpowerPortPlayerIncome", 2] call MISSION_CORE_fnc_tune;

// Initialize the shared BLUFOR manpower pool and start the port income loop.
// Runs on the server; publishes to clients via publicVariable.
MISSION_CORE_fnc_initManpower = {
    if (isNil "MISSION_CORE_BLUFOR_MANPOWER") then { MISSION_CORE_BLUFOR_MANPOWER = 0; };
    publicVariable "MISSION_CORE_BLUFOR_MANPOWER";

    // Port income: every tick, each BLUFOR port adds manpower to the shared pool.
    [] spawn {
        waitUntil { !isNil "MISSION_CORE_PORTS" };
        while { true } do {
            sleep 10;
            {
                private _pInfo = MISSION_CORE_PORTS getOrDefault [_x, []];
                if (count _pInfo > 0 && { (_pInfo select 2) == WEST }) then {
                    private _mult = _pInfo select 3;
                    private _income = MISSION_CORE_MANPOWER_PORT_PER_TICK * _mult;
                    MISSION_CORE_BLUFOR_MANPOWER = MISSION_CORE_BLUFOR_MANPOWER + _income;
                };
            } forEach (keys MISSION_CORE_PORTS);
            publicVariable "MISSION_CORE_BLUFOR_MANPOWER";
        };
    };
    diag_log "DYNAMIC MANPOWER: player manpower system initialized";
};

// Award manpower when a marker is captured. Called from fn_occupationMonitor.
MISSION_CORE_fnc_awardCaptureManpower = {
    params ["_importance"];
    private _bonus = round (_importance * MISSION_CORE_MANPOWER_CAPTURE_MULT);
    if (_bonus <= 0) exitWith {};
    MISSION_CORE_BLUFOR_MANPOWER = MISSION_CORE_BLUFOR_MANPOWER + _bonus;
    publicVariable "MISSION_CORE_BLUFOR_MANPOWER";
    diag_log format ["DYNAMIC MANPOWER: +%1 from capture (importance %2)", _bonus, _importance];
};

// Draw manpower from the pool. Returns true if sufficient funds existed.
MISSION_CORE_fnc_drawManpower = {
    params ["_amount"];
    if (_amount <= 0) exitWith { true };
    if (MISSION_CORE_BLUFOR_MANPOWER < _amount) exitWith { false };
    MISSION_CORE_BLUFOR_MANPOWER = MISSION_CORE_BLUFOR_MANPOWER - _amount;
    publicVariable "MISSION_CORE_BLUFOR_MANPOWER";
    true
};

// Return unused manpower to the pool.
MISSION_CORE_fnc_refundManpower = {
    params ["_amount"];
    if (_amount <= 0) exitWith {};
    MISSION_CORE_BLUFOR_MANPOWER = MISSION_CORE_BLUFOR_MANPOWER + _amount;
    publicVariable "MISSION_CORE_BLUFOR_MANPOWER";
};

// Calculate the manpower cost for a set of unit classnames.
MISSION_CORE_fnc_calcManpowerCost = {
    params ["_units"];
    count _units * MISSION_CORE_MANPOWER_PER_UNIT
};
