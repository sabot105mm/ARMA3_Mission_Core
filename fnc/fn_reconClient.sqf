// =====================================================================
// RENOWN + FORCE RECON (CLIENT)
// Unlock menu usable at the BLUFOR HQ flag. All purchases are validated
// server-side via MISSION_CORE_fnc_reconServerAction - the menu only
// paints from the broadcast MISSION_CORE_RENOWN / MISSION_CORE_RECON_UNITS
// state.
// =====================================================================

// Client-safe tune read: MISSION_CORE_SETTINGS only exists on the server, so fall back to the
// SQF default when it is missing (the default matches the server's fallback value).
MISSION_CORE_fnc_tuneIfAvailable = {
    params ["_key", ["_default", 0]];
    if (isNil "MISSION_CORE_SETTINGS") exitWith { _default };
    (MISSION_CORE_SETTINGS getOrDefault [_key, _default])
};

// True when the player stands at the HQ flag area.
MISSION_CORE_fnc_nearHQ = {
    if (isNil "MISSION_CORE_LOCATIONS") exitWith { false };
    private _range = ["reconMenuRange", 200] call MISSION_CORE_fnc_tuneIfAvailable;
    private _hq = MISSION_CORE_LOCATIONS findIf { (_x select 5) == WEST && { toLower (_x select 2) == "hq" } };
    if (_hq < 0) exitWith { false };
    private _pos = ((MISSION_CORE_LOCATIONS select _hq) select 1) select 0;
    (player distance _pos) <= _range
};

MISSION_CORE_fnc_openUnlockMenu = {
    if !([] call MISSION_CORE_fnc_nearHQ) exitWith { hint "Move to your HQ flag to access Force Recon command."; };
    if (isNil "MISSION_CORE_RECON_UNITS") exitWith { hint "Force Recon system not ready yet."; };
    if (isNil "MISSION_CORE_RECON_GEAR") exitWith { hint "Force Recon gear list not ready."; };
    closeDialog 2;
    createDialog "DYNOPS_UnlockMenu";
};

// Populate both lists + the info panel from the broadcast state.
MISSION_CORE_fnc_unlockMenuLoad = {
    private _d = findDisplay 1580;
    if (isNull _d) exitWith {};
    if (isNil "MISSION_CORE_RECON_UNITS" || isNil "MISSION_CORE_RECON_GEAR") exitWith {};
    private _renown = if (isNil "MISSION_CORE_RENOWN") then { 0 } else { MISSION_CORE_RENOWN };
    (_d displayCtrl 1582) ctrlSetText format ["RENOWN: %1", _renown];

    // Units list (lbData = slot number, lbValue = 1 if unlocked)
    private _ul = _d displayCtrl 1583;
    lbClear _ul;
    {
        private _slot = _forEachIndex;
        private _st = _x;
        private _idx = _ul lbAdd (if (typeName _st == "ARRAY") then {
            private _gearNames = [];
            {
                private _gi = MISSION_CORE_RECON_GEAR findIf { (_x select 0) == _forEachValue };
                if (_gi >= 0) then { _gearNames pushBack ((MISSION_CORE_RECON_GEAR select _gi) select 1); };
            } forEach _st;
            private _gearStr = "";
            {
                _gearStr = _gearStr + (if (_forEachIndex > 0) then { ", " } else { "" }) + _x;
            } forEach _gearNames;
            format ["Recon Unit %1  (%2)", _slot + 1, if (_gearStr == "") then { "no gear" } else { _gearStr }]
        } else {
            private _cost = if (!isNil "MISSION_CORE_RECON_UNIT_COSTS") then {
                MISSION_CORE_RECON_UNIT_COSTS param [_slot, 100 + _slot * 75]
            } else { 100 + _slot * 75 };
            format ["Recon Unit %1  [LOCKED - %2 renown]", _slot + 1, _cost]
        });
        _ul lbSetData [_idx, str _slot];
        _ul lbSetValue [_idx, if (typeName _st == "ARRAY") then { 1 } else { 0 }];
        _ul lbSetColor [_idx, if (typeName _st == "ARRAY") then { [1, 0.75, 0.3, 1] } else { [0.8, 0.8, 0.8, 0.6] }];
    } forEach MISSION_CORE_RECON_UNITS;

    if (isNil "MISSION_CORE_RECON_SEL") then { MISSION_CORE_RECON_SEL = 0; };
    MISSION_CORE_RECON_SEL = ((MISSION_CORE_RECON_SEL) max 0) min (count MISSION_CORE_RECON_UNITS - 1);
    _ul lbSetCurSel MISSION_CORE_RECON_SEL;

    [] call MISSION_CORE_fnc_unlockMenuSelect;
};

// Selection changed (either list) - repaint gear ownership for the selected unit + info panel.
MISSION_CORE_fnc_unlockMenuSelect = {
    private _d = findDisplay 1580;
    if (isNull _d) exitWith {};
    private _ul = _d displayCtrl 1583;
    private _sel = lbCurSel _ul;
    if (_sel >= 0) then {
        private _slot = parseNumber (_ul lbData _sel);
        MISSION_CORE_RECON_SEL = _slot;
    };
    private _slot = MISSION_CORE_RECON_SEL;
    private _unlocked = typeName (MISSION_CORE_RECON_UNITS param [_slot, false]) == "ARRAY";
    private _owned = if (_unlocked) then { MISSION_CORE_RECON_UNITS select _slot } else { [] };

    // Equipment list (lbData = gear id, lbValue = 1 if owned by selected unit)
    private _el = _d displayCtrl 1585;
    lbClear _el;
    {
        private _g = _x;
        private _eff = _g select 3;
        private _has = _g select 0 in _owned;
        private _idx = _el lbAdd format ["%1  (-%2 renown)  %3", _g select 1, _g select 2,
            if (_has) then { "[OWNED]" } else { "" }];
        _el lbSetData [_idx, _g select 0];
        _el lbSetValue [_idx, if (_has) then { 1 } else { 0 }];
        _el lbSetColor [_idx, if (_has) then { [0.4, 0.85, 0.4, 1] } else { [0.85, 0.85, 0.85, 1] }];
        _el lbSetTooltip [_idx, format ["Detection +%1 | Strike chance +%2 | Destroy weight +%3 | %4",
            _eff select 0, _eff select 1, _eff select 2, _g select 1]];
    } forEach MISSION_CORE_RECON_GEAR;

    // Info panel: current recon power summary
    private _n = 0;
    private _det = 0;
    private _hit = 0;
    private _dest = 0;
    {
        if (typeName _x == "ARRAY") then {
            _n = _n + 1;
            { private _gi = MISSION_CORE_RECON_GEAR findIf { (_x select 0) == _forEachValue }; if (_gi >= 0) then { private _e = (MISSION_CORE_RECON_GEAR select _gi) select 3; _det = _det + (_e select 0); _hit = _hit + (_e select 1); _dest = _dest + (_e select 2); }; } forEach _x;
        };
    } forEach MISSION_CORE_RECON_UNITS;
    private _dChance = ((20 + _n * 12 + _det) min 85) max 0;
    private _sChance = ((15 + _n * 10 + _hit) min 90) max 0;
    private _dWeight = 15 + _dest;
    private _renown = if (isNil "MISSION_CORE_RENOWN") then { 0 } else { MISSION_CORE_RENOWN };
    private _info = format [
        "<t align='center' color='#CFBF4B'>MARINE FORCE RECON</t><br/><br/>" +
        "Renown: %1<br/>" +
        "Recon units: %2 (detection ~%3%5 per convoy cycle, strike ~%4%5, destroy weight %6)<br/><br/>" +
        "Recon units never spawn or spot - they roll dice. More units and optics reveal supply routes sooner; SPG / MLRS / Paveway exist only as strike dice.<br/>" +
        "Capture markers to earn renown; destroyed convoys also pay renown.<br/><br/>" +
        "<t align='center' color='#808080'>Intel is shared with the whole team.</t>",
        _renown, _n, _dChance, _sChance, "%", _dWeight
    ];
    (_d displayCtrl 1587) ctrlSetStructuredText parseText _info;
};

MISSION_CORE_fnc_unlockUnit = {
    if (isNil "MISSION_CORE_RECON_SEL") exitWith {};
    if !([] call MISSION_CORE_fnc_nearHQ) exitWith { hint "You must be at the HQ flag."; };
    private _slot = MISSION_CORE_RECON_SEL;
    if (typeName (MISSION_CORE_RECON_UNITS param [_slot, false]) == "ARRAY") exitWith { hint "Already unlocked."; };
    [player, "unlock", _slot] remoteExec ["MISSION_CORE_fnc_reconServerAction", 2];
    [] spawn { sleep 0.7; [] call MISSION_CORE_fnc_unlockMenuLoad; };
};

MISSION_CORE_fnc_buyEquip = {
    if (isNil "MISSION_CORE_RECON_SEL") exitWith {};
    if !([] call MISSION_CORE_fnc_nearHQ) exitWith { hint "You must be at the HQ flag."; };
    private _ul = findDisplay 1580;
    if (isNull _ul) exitWith {};
    private _el = _ul displayCtrl 1585;
    private _sel = lbCurSel _el;
    if (_sel < 0) exitWith { hint "Select an equipment item first."; };
    private _item = _el lbData _sel;
    if (_item == "") exitWith { hint "Select an equipment item first."; };
    [player, "equip", MISSION_CORE_RECON_SEL, _item] remoteExec ["MISSION_CORE_fnc_reconServerAction", 2];
    [] spawn { sleep 0.7; [] call MISSION_CORE_fnc_unlockMenuLoad; };
};

// Called via remoteExec from the server with the result of a purchase.
MISSION_CORE_fnc_reconHint = {
    params ["_msg"];
    hint _msg;
};