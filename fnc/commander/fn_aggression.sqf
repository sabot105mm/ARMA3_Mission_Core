// =====================================================================
// AGGRESSION SYSTEM
// The enemy side holds ONE global aggression value (0..aggressionMax) that
// replaces the old assault trigger. Low aggression = the enemy holds off;
// the player's actions (capturing markers, destroying convoys) push it up;
// each assault the enemy commits BURNS aggression proportional to its size,
// so after one or two big pushes the enemy calms below the assault
// threshold again and holds off until the player provokes it once more.
// A slow drift keeps a passive campaign slowly escalating.
// =====================================================================

// Current aggression (create on first use so every hook is safe).
MISSION_CORE_fnc_aggressionGet = {
    if (isNil "MISSION_CORE_AGGRESSION") then {
        MISSION_CORE_AGGRESSION = ["aggressionStart", 5] call MISSION_CORE_fnc_tune;
    };
    MISSION_CORE_AGGRESSION
};

// Add _amount (may be negative) to global aggression, clamped to 0..aggressionMax.
MISSION_CORE_fnc_aggressionAdd = {
    params ["_amount"];
    private _cur = call MISSION_CORE_fnc_aggressionGet;
    private _max = ["aggressionMax", 100] call MISSION_CORE_fnc_tune;
    MISSION_CORE_AGGRESSION = (_cur + _amount) min _max max 0;
    publicVariable "MISSION_CORE_AGGRESSION";
    if (_amount != 0) then {
        diag_log format ["AGGRESSION: %1 -> %2 (%3%4)", _cur, MISSION_CORE_AGGRESSION, _amount, if (_amount > 0) then { " gained" } else { " spent" }];
    };
    MISSION_CORE_AGGRESSION
};

// 0..1 scale of how "wound up" the enemy is above the assault threshold.
// Below the threshold it is 0 -> every assault chance is zeroed -> the enemy
// holds off. At aggressionMax it is 1 -> the full (confidence-gated) chance.
MISSION_CORE_fnc_aggressionFactor = {
    private _agg = call MISSION_CORE_fnc_aggressionGet;
    private _thr = ["aggressionThreshold", 40] call MISSION_CORE_fnc_tune;
    private _max = ["aggressionMax", 100] call MISSION_CORE_fnc_tune;
    ((_agg - _thr) / ((_max - _thr) max 1)) min 1 max 0
};