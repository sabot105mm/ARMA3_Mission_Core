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

// Paint the unlock screen locally if the broadcast state has not arrived yet. The client should
// NEVER show a blank list - defaults mirror the server's init (reconMaxUnits=4, same costs/gear),
// and the authoritative server state overwrites them the moment the pull broadcast lands.
MISSION_CORE_fnc_ensureLocalReconDefaults = {
    if (isNil "MISSION_CORE_RECON_GEAR" || { count MISSION_CORE_RECON_GEAR < 5 }) then {
        MISSION_CORE_RECON_GEAR = [
            ["optics", "Long-Range Optics", 25, [8, 0, 0]],
            ["designator", "Target Designator", 30, [6, 10, 0]],
            ["spg", "SPG Fire Support", 40, [0, 20, 12]],
            ["mlrs", "MLRS Fire Support", 55, [0, 25, 22]],
            ["paveway", "Paveway LGB", 60, [0, 20, 30]]
        ];
    };
    if (isNil "MISSION_CORE_RECON_UNITS" || { count MISSION_CORE_RECON_UNITS == 0 }) then {
        MISSION_CORE_RECON_UNITS = [];
        private _maxR = ["reconMaxUnits", 4] call MISSION_CORE_fnc_tuneIfAvailable;
        for "_i" from 0 to (_maxR - 1) do { MISSION_CORE_RECON_UNITS pushBack false; };
    };
    if (isNil "MISSION_CORE_RECON_UNIT_COSTS" || { count MISSION_CORE_RECON_UNIT_COSTS == 0 }) then {
        MISSION_CORE_RECON_UNIT_COSTS = [];
        private _base = ["reconUnitCostBase", 100] call MISSION_CORE_fnc_tuneIfAvailable;
        private _step = ["reconUnitCostStep", 75] call MISSION_CORE_fnc_tuneIfAvailable;
        for "_i" from 0 to (count MISSION_CORE_RECON_UNITS - 1) do { MISSION_CORE_RECON_UNIT_COSTS pushBack (_base + _i * _step); };
    };
    if (isNil "MISSION_CORE_RENOWN") then { MISSION_CORE_RENOWN = 0; };
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

// Pull the authoritative recon state from the server (idempotent re-broadcast). Covers clients
// that joined mid-mission and missed the init publicVariable, and any state-loss hitches.
MISSION_CORE_fnc_reconPullState = {
    if (isServer) then {
        if (!(isNil "MISSION_CORE_fnc_reconPushState")) then { call MISSION_CORE_fnc_reconPushState; };
    } else {
        [] remoteExec ["MISSION_CORE_fnc_reconPushState", 2];
    };
};

MISSION_CORE_fnc_openUnlockMenu = {
    call MISSION_CORE_fnc_ensureLocalReconDefaults;
    if !([] call MISSION_CORE_fnc_nearHQ) exitWith { hint "Move to your HQ flag to access Force Recon command."; };
    // Require real content - an empty/missing list is never a valid unlock screen. Pull again
    // and retry once after the broadcast lands instead of opening an empty menu.
    if (isNil "MISSION_CORE_RECON_UNITS" || { count MISSION_CORE_RECON_UNITS == 0 } || { isNil "MISSION_CORE_RECON_GEAR" }) exitWith {
        [] call MISSION_CORE_fnc_reconPullState;
        hint "Requesting Force Recon state... open again in a second.";
        [] spawn MISSION_CORE_fnc_reconWaitAndOpen;
    };
    closeDialog 2;
    createDialog "DYNOPS_UnlockMenu";
    [] spawn MISSION_CORE_fnc_unlockMenuRefresh;
};

// Retry-open once the pulled state lands (spawned only when the open was deferred above).
MISSION_CORE_fnc_reconWaitAndOpen = {
    private _t = time + 10;
    waitUntil { sleep 0.5; _t < time || { !(isNil "MISSION_CORE_RECON_UNITS") && { count MISSION_CORE_RECON_UNITS > 0 } && { !(isNil "MISSION_CORE_RECON_GEAR") } } };
    private _ok = !(isNil "MISSION_CORE_RECON_UNITS") && { count MISSION_CORE_RECON_UNITS > 0 } && { !(isNil "MISSION_CORE_RECON_GEAR") } && { [] call MISSION_CORE_fnc_nearHQ };
    if (_ok) then {
        closeDialog 2;
        createDialog "DYNOPS_UnlockMenu";
        [] spawn MISSION_CORE_fnc_unlockMenuRefresh;
    };
    if (!(_ok) && { _t < time }) then {
        hint "Force Recon data still unavailable.";
    };
};

// One-shot refresh right after the menu opens: pull the authoritative server state and repopulate
// both lists once the broadcast lands, so the screen always shows current renown/ownership.
MISSION_CORE_fnc_unlockMenuRefresh = {
    sleep 1.0;
    if (isNull (findDisplay 1580)) exitWith {};
    [] call MISSION_CORE_fnc_reconPullState;
    sleep 1.0;
    if (isNull (findDisplay 1580)) exitWith {};
    [] call MISSION_CORE_fnc_unlockMenuLoad;
};

// Populate both lists + the info panel from the broadcast state.
MISSION_CORE_fnc_unlockMenuLoad = {
    private _d = findDisplay 1580;
    if (isNull _d) exitWith {};
    call MISSION_CORE_fnc_ensureLocalReconDefaults;
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
                private _gid = _x;
                private _gi = MISSION_CORE_RECON_GEAR findIf { (_x select 0) == _gid };
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

    // Empty-list guard: if the unit list is still blank, the broadcast may not have landed yet.
    // Pull the server state and repopulate once - never twice, so a valid selection never churns.
    if (lbSize _ul == 0) then {
        diag_log "RENOWN/RECON: unit list empty at load - pulling state";
        [] call MISSION_CORE_fnc_reconPullState;
        [] spawn MISSION_CORE_fnc_unlockMenuLoadRetry;
    };
    diag_log format ["RENOWN/RECON: unlock menu loaded - units=%1 gear=%2", count MISSION_CORE_RECON_UNITS, count MISSION_CORE_RECON_GEAR];

    [] call MISSION_CORE_fnc_unlockMenuSelect;
};

// One-shot repopulate after the pulled state lands (spawned only when the load saw an empty list).
MISSION_CORE_fnc_unlockMenuLoadRetry = {
    sleep 1.5;
    private _d2 = findDisplay 1580;
    if (isNull _d2) exitWith {};
    private _ul2 = _d2 displayCtrl 1583;
    if (lbSize _ul2 == 0 && { !(isNil "MISSION_CORE_RECON_UNITS") } && { count MISSION_CORE_RECON_UNITS > 0 }) then {
        diag_log "RENOWN/RECON: repopulating unit list after pull";
        [] call MISSION_CORE_fnc_unlockMenuLoad;
    };
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
            { private _gid = _x; private _gi = MISSION_CORE_RECON_GEAR findIf { (_x select 0) == _gid }; if (_gi >= 0) then { private _e = (MISSION_CORE_RECON_GEAR select _gi) select 3; _det = _det + (_e select 0); _hit = _hit + (_e select 1); _dest = _dest + (_e select 2); }; } forEach _x;
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

// Server-triggered: repaint the shared interdiction log diary entry from the broadcast
// MISSION_CORE_RECON_KILLS ledger [ammoConvoys, men, tanks]. Rebuild the whole subject so a
// player never accumulates duplicate log pages regardless of event ordering quirks.
MISSION_CORE_fnc_reconLogDiary = {
    if (!hasInterface || { isNull player }) exitWith {};
    try {
        private _kills = missionNamespace getVariable ["MISSION_CORE_RECON_KILLS", [0, 0, 0]];
        if (!(_kills isEqualType []) || { count _kills < 3 }) then {
            diag_log format ["RENOWN/RECON: CLIENT RECON_KILLS was %1 (%2) - resetting", _kills, typeName _kills];
            _kills = [0, 0, 0];
        };
        _kills = [(_kills select 0), (_kills select 1), (_kills select 2)];
        if (!((_kills select 0) isEqualType 0) || { !((_kills select 0) >= 0) } || { (_kills select 0) >= 1e9 }) then { _kills set [0, 0] };
        if (!((_kills select 1) isEqualType 0) || { !((_kills select 1) >= 0) } || { (_kills select 1) >= 1e9 }) then { _kills set [1, 0] };
        if (!((_kills select 2) isEqualType 0) || { !((_kills select 2) >= 0) } || { (_kills select 2) >= 1e9 }) then { _kills set [2, 0] };
        if (!(isNil "MISSION_CORE_RECON_DIARY_LAST") && { _kills isEqualTo MISSION_CORE_RECON_DIARY_LAST }) exitWith {}; // already painted
        MISSION_CORE_RECON_DIARY_LAST = _kills;
        private _ammo = _kills select 0;
        private _men = _kills select 1;
        private _tanks = _kills select 2;
    if (player diarySubjectExists "DynOpsReconLog") then {
        player removeDiarySubject "DynOpsReconLog";
    };
    player createDiarySubject ["DynOpsReconLog", "Force Recon Interdiction"];
    private _ammoIcon = "a3\ui_f\data\map\vehicleicons\iconTruck_ca.paa";
    private _menIcon = "a3\ui_f\data\map\markers\nato\o_inf.paa";
    private _tankIcon = "a3\ui_f\data\map\markers\nato\o_armor.paa";
    private _body = format [
        "<t align='center' size='1.1' color='#ffd24a' font='PuristaBold' shadow='2'>FORCE RECON INTERDICTION</t><br/>" +
        "<t align='center' size='0.9' color='#999999' font='PuristaLight'>Combat interdiction tally - supply convoys struck, hostile manpower lost, armor columns destroyed.</t><br/><br/>" +
        "<t align='center' size='0.9' color='#7ee07e' font='EtelkaMonospacePro'>Accumulated strikes executed by Marine Force Recon fire support.</t><br/><br/>" +
        "<img image='%3' width='32' height='32'/> <t size='1.05' color='#ffd24a' font='OrbitronLight'>ENEMY SUPPLY CUT</t><br/><t align='center' size='1.6' color='#ffffff' font='PuristaBold'>%1</t><br/><br/>" +
        "<img image='%4' width='32' height='32'/> <t size='1.05' color='#ff9a9a' font='OrbitronLight'>ENEMY MANPOWER KILLED</t><br/><t align='center' size='1.6' color='#ffffff' font='PuristaBold'>%2 men</t><br/><br/>" +
        "<img image='%5' width='32' height='32'/> <t size='1.05' color='#ff9a9a' font='OrbitronLight'>ARMOR COLUMNS DESTROYED</t><br/><t align='center' size='1.6' color='#ffffff' font='PuristaBold'>%6</t><br/><br/>" +
        "<hr size='1' color='#555555'/><br/>" +
        "<t align='right' size='0.8' color='#707070' font='PuristaLight'>figures are a trend, not a live combat report</t>",
        _ammo, _men, _ammoIcon, _menIcon, _tankIcon, _tanks
    ];
    player createDiaryRecord ["DynOpsReconLog", ["Interdiction Log", _body]];
    } catch {
        diag_log format ["RENOWN/RECON: reconLogDiary exception: %1", _exception];
    };
};

// Clients repaint the Interdiction Log diary whenever the server broadcasts a strikes-ledger
// update (a kill) or re-broadcasts on pull. The initial render below guarantees the diary page
// exists even before the first kill; the poll keeps a locally-hosted game's own process in sync
// because addPublicVariableEventHandler does not fire for the machine that set the variable.
if (hasInterface) then {
    "MISSION_CORE_RECON_KILLS" addPublicVariableEventHandler {
        call MISSION_CORE_fnc_reconLogDiary;
    };
    [] spawn {
        waitUntil { !isNull player };
        sleep 3;
        call MISSION_CORE_fnc_reconLogDiary;
        while { true } do {
            sleep 10;
            call MISSION_CORE_fnc_reconLogDiary;
        };
    };
};