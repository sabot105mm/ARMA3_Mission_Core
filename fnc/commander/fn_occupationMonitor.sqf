
// =====================================================================
// MARKER OCCUPATION
// When a marker's initial garrison is wiped, the attacker SWITCHES the
// marker to their side but is NOT the rightful owner yet. The marker is
// OCCUPIED: for 10 minutes the attacker gets NO defender spawns, the
// previous owner counter-attacks to win it back, and the marker only
// reverts to the previous owner once the occupier's players / active
// assault squads are gone AND an enemy counter-attack squad physically
// moves into the marker. Only after holding for 10 minutes does the
// attacker become the rightful owner (and defender spawns resume).
// =====================================================================

// True when a marker is currently in the occupation (hold) phase
MISSION_CORE_fnc_isOccupied = {
    params ["_locName"];
    !(isNil "MISSION_CORE_OCCUPATION") && { _locName in MISSION_CORE_OCCUPATION }
};

// Flip a marker's owner in both stores + marker color
MISSION_CORE_fnc_setMarkerOwner = {
    params ["_locName", "_side"];
    private _cIdx = MISSION_CORE_CACHED_POSITIONS findIf { (_x select 0) == _locName };
    if (_cIdx >= 0) then {
        private _centry = MISSION_CORE_CACHED_POSITIONS select _cIdx;
        _centry set [4, _side];
        MISSION_CORE_CACHED_POSITIONS set [_cIdx, _centry];
    };
    private _lIdx = MISSION_CORE_LOCATIONS findIf { (_x select 0) == _locName };
    if (_lIdx >= 0) then {
        private _entry = MISSION_CORE_LOCATIONS select _lIdx;
        _entry set [5, _side];
        MISSION_CORE_LOCATIONS set [_lIdx, _entry];
        private _mkr = _entry select 0;
        _mkr setMarkerColor (if (_side == WEST) then { "ColorBLUFOR" } else { "ColorOPFOR" });
    };
};

// Monitor occupied markers: revert to the previous owner if the attacker is wiped, or finalize
// ownership after 10 minutes of holding.
MISSION_CORE_fnc_occupationMonitor = {
    // On-demand loop: only one instance runs at a time, and it lives only while there is at
    // least one occupied marker to watch. It is started by fn_captureMarkerForPlayers and exits
    // on its own the moment the last occupied marker is resolved.
    if (!isNil "MISSION_CORE_OCCUPATION_MONITOR_RUNNING" && { MISSION_CORE_OCCUPATION_MONITOR_RUNNING }) exitWith {};
    MISSION_CORE_OCCUPATION_MONITOR_RUNNING = true;
    if (isNil "MISSION_CORE_OCCUPATION") then { MISSION_CORE_OCCUPATION = createHashMap; };
    diag_log "AI COMMANDER: occupation monitor started";
    while { count MISSION_CORE_OCCUPATION > 0 } do {
        sleep 8 + random 4;
        if (isNil "MISSION_CORE_OCCUPATION") then { MISSION_CORE_OCCUPATION = createHashMap; };
        {
            private _locName = _x;
            private _entry = MISSION_CORE_OCCUPATION get _locName;
            _entry params ["_occupier", "_prevOwner", "_occupiedAt"];
            private _lIdx = MISSION_CORE_CACHED_POSITIONS findIf { (_x select 0) == _locName };
            if (_lIdx < 0) then { MISSION_CORE_OCCUPATION deleteAt _locName; continue; };
            private _locEntry = MISSION_CORE_CACHED_POSITIONS select _lIdx;
            private _locPos = _locEntry select 1;
            private _mSize = if (count _locEntry > 8) then { _locEntry select 8 } else { [200, 200, 0] };
            private _ma = _mSize select 0;
            private _mb = _mSize select 1;
            private _md = if (count _mSize > 2) then { _mSize select 2 } else { 0 };
            // Attacker (occupier) presence inside the marker ellipse that BLOCKS a revert. Narrow
            // definition: only the capturing players themselves and ACTIVE released assault-squad
            // leaders hold the marker. Ordinary occupier-side AI (patrols, garrison) does NOT -
            // walking away with just AI behind flips it back the moment an enemy counter-attacker
            // steps in, without any player requirement.
            private _inside = {
                params ["_p"];
                private _dx = (_p select 0) - (_locPos select 0);
                private _dy = (_p select 1) - (_locPos select 1);
                private _rx = _dx * cos _md - _dy * sin _md;
                private _ry = _dx * sin _md + _dy * cos _md;
                (_rx*_rx)/(_ma*_ma) + (_ry*_ry)/(_mb*_mb) <= 1
            };
            private _occupierPresent = false;
            {
                if (alive _x && { isPlayer _x } && { side _x == _occupier } && { [getPos _x] call _inside }) exitWith { _occupierPresent = true; };
            } forEach allPlayers;
            // ACTIVE released assault-squad leaders also block a revert (their squad is actively
            // pressing/holding the marker even when the player physically walks away).
            if (!_occupierPresent && { !isNil "MISSION_CORE_ATTACK_GROUPS" }) then {
                {
                    private _adata = _y;
                    if ((_adata select 5) != "active") then { continue; };
                    private _ag = _adata select 0;
                    if (isNull _ag) then { continue; };
                    if (side (leader _ag) != _occupier) then { continue; };
                    private _aldr = leader _ag;
                    if (alive _aldr && { [getPos _aldr] call _inside }) exitWith { _occupierPresent = true; };
                } forEach MISSION_CORE_ATTACK_GROUPS;
            };
            // Flip-back trigger: an ENEMY counter-attack squad targeting THIS marker must be
            // physically inside the ellipse. Ordinary enemy patrols/garrison do NOT trigger - only
            // a group dispatched specifically to retake this marker (order counterattack/attack
            // aimed at the marker center within the neighbor range) counts.
            private _enemyRetook = false;
            if (!_occupierPresent) then {
                {
                    if (side _x != _prevOwner) then { continue; };
                    if !((_x getVariable ["MISSION_CORE_ORDER", ""]) in ["counterattack", "attack"]) then { continue; };
                    private _at = _x getVariable ["MISSION_CORE_ATTACK_TARGET", [0, 0, 0]];
                    if (_at distance2D _locPos > (["neighborRange", 4000] call MISSION_CORE_fnc_tune)) then { continue; };
                    if ({ alive _x && { [getPos _x] call _inside } } count units _x > 0) exitWith { _enemyRetook = true; };
                } forEach allGroups;
            };
            if (!_occupierPresent && { _enemyRetook }) then {
                // Occupier gone + an enemy counter-attacker physically retook the marker - revert
                // to the previous owner. The marker flips back with ZERO manpower: it fields no
                // garrisons until its supply network delivers manpower again.
                [_locName, _prevOwner] call MISSION_CORE_fnc_setMarkerOwner;
                MISSION_CORE_OCCUPATION deleteAt _locName;
                if (!isNil "MISSION_CORE_CAPTURED_RETAKE") then { MISSION_CORE_CAPTURED_RETAKE deleteAt _locName; };
                MISSION_CORE_SPAWNED_LOCATIONS set [_locName, false];
                if (isNil "MISSION_CORE_MANPOWER") then { MISSION_CORE_MANPOWER = createHashMap; };
                if (isNil "MISSION_CORE_COMMIT") then { MISSION_CORE_COMMIT = createHashMap; };
                MISSION_CORE_MANPOWER set [_locName, []];
                MISSION_CORE_COMMIT set [_locName, 0];
                diag_log format ["DYNAMIC CAPTURE: %1 reverted to %2 (occupier left + retake squad entered, 0 manpower)", _locName, _prevOwner];
                ["DynOps_MarkerLost",
                    ["MARKER LOST", format ["%1 reverted to the enemy.", _locName]]
                ] remoteExec ["BIS_fnc_showNotification", 0];
            } else {
                if (time - _occupiedAt >= (["captureHoldSeconds", 600] call MISSION_CORE_fnc_tune)) then {
                    // Held for 10 minutes - occupier becomes the rightful owner
                    MISSION_CORE_OCCUPATION deleteAt _locName;
                    if (!isNil "MISSION_CORE_CAPTURED_RETAKE") then { MISSION_CORE_CAPTURED_RETAKE deleteAt _locName; };
                    MISSION_CORE_SPAWNED_LOCATIONS set [_locName, false];
                    diag_log format ["DYNAMIC CAPTURE: %1 secured by %2 (10min hold complete)", _locName, _occupier];
                    private _renownGain = 0;
                    // Marker importance - computed once at loop scope so the manpower/renown reward
                    // AND the aggression gain below both read the same (non-NaN) value.
                    private _locImp = 3;
                    private _impIdx = MISSION_CORE_CACHED_POSITIONS findIf { (_x select 0) == _locName };
                    if (_impIdx >= 0) then { _locImp = (MISSION_CORE_CACHED_POSITIONS select _impIdx) select 7; };
                    if (_occupier == WEST) then {
                        if (isNil "MISSION_CORE_DEFENSE_POINTS") then { MISSION_CORE_DEFENSE_POINTS = createHashMap; };
                        private _reward = getNumber (missionConfigFile >> "DEFENSE_BUILD_POINTS_CAPTURE_REWARD");
                        {
                            if (side _x == WEST) then {
                                private _uid = getPlayerUID _x;
                                if (_uid != "") then {
                                    MISSION_CORE_DEFENSE_POINTS set [_uid, (MISSION_CORE_DEFENSE_POINTS getOrDefault [_uid, MISSION_CORE_DEFENSE_POINTS_DEFAULT]) + _reward];
                                };
                            };
                        } forEach allPlayers;
                        publicVariable "MISSION_CORE_DEFENSE_POINTS";
                        // Manpower bonus: importance * captureMult
                        [_locImp] call MISSION_CORE_fnc_awardCaptureManpower;
                        // Renown bonus: importance * captureMult (scales with marker size/type)
                        _renownGain = _locImp * (["renownCaptureMult", 3] call MISSION_CORE_fnc_tune);
                        [_renownGain] call MISSION_CORE_fnc_awardRenown;
                    };
                    // A player-secured marker infuriates the enemy: aggression rises with the
                    // marker's importance AND its footprint (bigger bases hurt more).
                    if (_occupier == WEST) then {
                        private _sizeWeight = 0;
                        if (!isNil "MISSION_CORE_fnc_markerSizeWeight") then { _sizeWeight = [_locEntry] call MISSION_CORE_fnc_markerSizeWeight; };
                        private _aggGain = (_locImp * (["aggressionCaptureImp", 6] call MISSION_CORE_fnc_tune))
                                        + (_sizeWeight * (["aggressionCaptureSize", 8] call MISSION_CORE_fnc_tune));
                        [_aggGain] call MISSION_CORE_fnc_aggressionAdd;
                        diag_log format ["AGGRESSION: marker %1 secured by players +%2 (imp=%3 sizeW=%4)", _locName, round _aggGain, _locImp, _sizeWeight];
                    };
                    ["DynOps_MarkerCaptured",
                        ["MARKER CAPTURED", format ["%1 has been secured!%2", _locName, if (_renownGain > 0) then { format [" (+%1 renown)", _renownGain] } else { "" }]]
                    ] remoteExec ["BIS_fnc_showNotification", 0];
                };
            };
        } forEach (keys MISSION_CORE_OCCUPATION);
    };
    MISSION_CORE_OCCUPATION_MONITOR_RUNNING = false;
    diag_log "AI COMMANDER: occupation monitor stopped (no occupied markers)";
    // A capture may have landed while this instance was exiting - restart to keep watching it.
    if (count MISSION_CORE_OCCUPATION > 0) then { [] spawn MISSION_CORE_fnc_occupationMonitor; };
};
