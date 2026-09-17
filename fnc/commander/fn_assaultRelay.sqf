// =====================================================================
// BLUFOR ASSAULT GROUP RELAY (multiplayer visibility)
//
// BLUFOR recruit assault groups are spawned CLIENT-side (fn_recruit.sqf,
// BIS_fnc_spawnGroup) and tracked only in the spawning client's
// MISSION_CORE_ATTACK_GROUPS. On a dedicated / hosted server that map does
// not exist (or only holds the host's own locally-spawned groups), so the
// server-side systems that must react to an assault - marker contest
// (fn_isMarkerContested / fn_refreshAssaultContest), the AI commander's
// assault-leader detection (fn_aiCommanderLoop) and assault artillery
// spotting (fn_assaultArtySpotTarget) - could never see a remote player's
// squads. The squads marched, their target markers never became contested,
// and the garrison never counter-attacked.
//
// Each client periodically reports its assault groups here (see
// MISSION_CORE_fnc_reportAssaultGroups in fn_recruit.sqf). The server
// resolves each group (groupFromNetId) into MISSION_CORE_ATTACK_GROUPS_RELAY,
// shaped exactly like a normal attack-group entry:
//   [_grp, _targetName, [], ["", "", 0, _subCat, _catName], WEST, _status, _targetPos]
// so every existing server consumer can treat it as one more attack group.
// The client's own MISSION_CORE_ATTACK_GROUPS is left untouched - its UI
// still reads exactly what it wrote.
//
// Report entry (client -> server, via remoteExec to target 2):
//   [grpNetId, leaderNetId, targetName, status, targetPos, isMechMotor, subCat, catName]
// =====================================================================

if (isNil "MISSION_CORE_ASSAULT_REPORTS") then { MISSION_CORE_ASSAULT_REPORTS = createHashMap; };
if (isNil "MISSION_CORE_ATTACK_GROUPS_RELAY") then { MISSION_CORE_ATTACK_GROUPS_RELAY = createHashMap; };

// Rebuild the relay map from every reporter's latest snapshot. Reporters are pruned on a slow
// cadence by MISSION_CORE_fnc_assaultRelayLoop; here we just re-resolve groups and reproduce the
// relay entries (a report that stops arriving naturally disappears once its reporter is pruned).
MISSION_CORE_fnc_assaultRelayRebuild = {
    if (!isServer) exitWith {};
    private _map = createHashMap;
    private _reports = MISSION_CORE_ASSAULT_REPORTS;
    {
        private _uid = _x;
        private _rep = _y;
        private _caller = _rep select 0;
        private _entries = _rep select 1;
        private _stamp = _rep select 2;
        if ((time - _stamp) > 90) then { continue; };
        if (isNull _caller || { !(isPlayer _caller) }) then { continue; };
        {
            private _e = _x;
            if ((count _e) < 8) then { continue; };
            // Resolve the group. groupFromNetId is the group-aware lookup; fall back to the
            // leader's group via objectFromNetId (units are objects, so that call is valid).
            private _grp = groupFromNetId (_e select 0);
            if (isNull _grp) then {
                private _u = objectFromNetId (_e select 1);
                if (!isNull _u) then { _grp = group _u; };
            };
            if (isNull _grp) then { continue; };
            private _data = [_grp, _e select 2, [], ["", "", 0, _e select 6, _e select 7], WEST, _e select 3, _e select 4];
            _map set [format ["%1_%2", _uid, _forEachIndex], _data];
        } forEach _entries;
    } forEach _reports;
    MISSION_CORE_ATTACK_GROUPS_RELAY = _map;
};

// Server handler for client assault-group snapshots. Runs via remoteExec on the server only.
MISSION_CORE_fnc_assaultRelayReceive = {
    params ["_caller", "_entries"];
    if (!isServer) exitWith {};
    if (!(isPlayer _caller)) exitWith {};
    if ((typeName _entries) != "ARRAY") exitWith {};
    if ((count _entries) > 40) then { _entries = _entries select [0, 40]; };
    private _uid = getPlayerUID _caller;
    if (_uid == "") exitWith {};
    MISSION_CORE_ASSAULT_REPORTS set [_uid, [_caller, _entries, time]];
    call MISSION_CORE_fnc_assaultRelayRebuild;
};

// Slow prune loop: drop reporters that have disconnected or stopped reporting (90s no-report
// timeout - the client monitor re-reports every ~5s), then rebuild the relay map.
MISSION_CORE_fnc_assaultRelayLoop = {
    if (!isServer) exitWith {};
    while { true } do {
        sleep 15;
        private _reports = MISSION_CORE_ASSAULT_REPORTS;
        {
            private _rep = _y;
            if ((time - (_rep select 2)) > 90 || { isNull (_rep select 0) } || { !(isPlayer (_rep select 0)) }) then {
                _reports deleteAt _x;
            };
        } forEach _reports;
        call MISSION_CORE_fnc_assaultRelayRebuild;
    };
};