// GET-OUT: ARMOR - damage verdict.
// Decides whether an abandoned tank or APC is a loss or is worth recovering, and nothing else.
// Kept in its own file and kept free of async work so the damage test can never be entangled with
// the wait for the rest of the crew to finish bailing.
//
//   ECONOMY DELIVERY (MISSION_CORE_ECONOMY_ARMOR): lost at over 0.30 damage.
//   Anything else: lost at over 0.35 damage, or when the hull cannot move.
//
// The delivery gate is deliberately the lower of the two. A delivery is not a casualty, it is
// armour the player already paid for that is waiting on a truck to arrive, so it is written off
// as soon as it is clearly not going to finish the run. The 0.30 and 0.35 split is intentional.
//
// canMove is tested as well as damage because not every MBT variant exposes named track hitpoints,
// and a hull that physically cannot move is a casualty whatever its damage number says.
MISSION_CORE_fnc_getOutArmorVerdict = {
    params ["_veh"];
    private _isEconomy = false;
    if (_veh getVariable ["MISSION_CORE_ECONOMY_ARMOR", false]) then {
        _isEconomy = true;
    };
    private _dmg = getDammage _veh;
    private _lost = false;
    if (_isEconomy) then {
        if (_dmg > 0.30) then {
            _lost = true;
        };
    };
    if (!_isEconomy) then {
        if (_dmg > 0.35) then {
            _lost = true;
        };
        if (!canMove _veh) then {
            _lost = true;
        };
    };
    [_lost, _isEconomy]
};
diag_log format ["GETOUT VERDICT: fn_getOutArmorVerdict.sqf compiled, helper defined=%1", !(isNil "MISSION_CORE_fnc_getOutArmorVerdict")];
