
// Assemble an attack force when a marker decides to attack: free the cap, then ensure
// up to 2 tank markers (MBT + mech + 2 foot inf squads) and 1 infantry marker (3 squads)
// In STAGED mode (REDFOR maximal counter-attack) the assembled force is held together at the
// source edge until every requested group has physically arrived. Foot manpower is supplied by the
// marker's OWN supply pipeline (replenish/budget squads are absorbed into the staged roster) with
// the pooled supplier budget as a TTL fallback, armor stages directly, and the whole force is
// released in one push by a spawned monitor (releaseCounterStaged). BLUFOR support keeps the
// instant-march behavior (_staged = false default).
MISSION_CORE_fnc_assembleAssault = {
    params ["_side", "_originPos", "_targetPos", "_importance", ["_originName", ""], ["_staged", false], ["_tgtName", ""]];
    private _sideVar = if (_side == WEST) then { "MISSION_CORE_BLUFOR" } else { "MISSION_CORE_REDFOR" };
    private _factionData = if (_side == WEST) then { MISSION_CORE_BLUFOR_DATA } else { MISSION_CORE_REDFOR_DATA };
    private _allGroups = _factionData select 17;
    private _faction = _factionData select 3;
    if (isNil "MISSION_CORE_SPAWNED_GROUPS") then { MISSION_CORE_SPAWNED_GROUPS = []; };

    // Free the cap and pull kept armor into the attack
    [_side, _targetPos, 800] call MISSION_CORE_fnc_despawnOverwatchTanks;

    // Stage EDGE radius = the ORIGIN marker's own size (half-extent of its area): the staged
    // force parks on the rim of the marker it belongs to, mirroring recruit-edge staging.
    private _originSize = [200, 200];
    if (_originName != "" && { !isNil "MISSION_CORE_CACHED_POSITIONS" }) then {
        private _oEnt = (MISSION_CORE_CACHED_POSITIONS select { (_x select 0) == _originName }) param [0, []];
        if (count _oEnt > 8) then { _originSize = _oEnt select 8; };
    };

    // Count existing usable forces near the origin (kept armor + standing infantry)
    private _existingMBT = 0;
    private _existingMech = 0;
    private _existingInf = 0;
    {
        if (_x getVariable [_sideVar, false] && { count units _x > 0 } && { !(_x getVariable ["MISSION_CORE_DEFENSE_GROUP", false]) }) then {
            if ((leader _x) distance _originPos < 1500) then {
                if (_x getVariable ["MISSION_CORE_AA_TANK", false] || { (_x getVariable ["MISSION_CORE_ARMOR_SLOT", ""]) == "mbt" }) then {
                    _existingMBT = _existingMBT + 1;
                } else {
                    if (_x getVariable ["MISSION_CORE_ARMOR_SLOT", ""] == "mech") then {
                        _existingMech = _existingMech + 1;
                    } else {
                        if (_x getVariable ["MISSION_CORE_ORDER", ""] == "attack" || { (_x getVariable ["MISSION_CORE_SUBCAT", ""]) find "inf" == 0 }) then { _existingInf = _existingInf + 1; };
                    };
                };
            };
        };
    } forEach MISSION_CORE_SPAWNED_GROUPS;

    private _mbtTemplates = _allGroups select { (_x select 3) find "tank" > -1 && { (_x select 3) find "_aa" == -1 } && { ({ !(_x isKindOf "Man") } count (_x select 1)) <= 2 } };
    private _mechTemplates = _allGroups select { (_x select 3) == "mech" && { ({ !(_x isKindOf "Man") } count (_x select 1)) <= 2 } };
    // Foot infantry: proper CfgGroups infantry squads first, all-men combat groups as last resort
    private _infTemplates = [_allGroups] call MISSION_CORE_fnc_getInfTemplates;

    // STAGED FOOT MANPOWER POOLING (SUPPLY-REUSE HYBRID): request the infantry budget BEFORE the
    // supply window opens, from the side's suppliers (bases/HQ 1:1, then neighbor pools, each
    // keeping its retreat reserve). The SUPPLY PIPELINE is the primary infantry source for a staged
    // counter-attack - replenish/budget squads streaming into the contested marker are absorbed into
    // the staged roster (tryAbsorbSupply) while the assembly is filling. The pooled budget is only
    // the FALLBACK: releaseCounterStaged tops up what the supply window failed to deliver, so even a
    // full-strength marker (which contributes zero supply squads) still forms its counter-attack.
    // Tanks are not manpower - only the foot squads consume this budget.
    private _infAllowed = 0;
    private _infDonors = [];
    private _avgInfMen = 0;
    private _minInfMen = 8;
    private _targetSquads = 0;
    private _need = 0;
    if (_staged && { _existingInf < 3 } && { count _infTemplates > 0 }) then {
        private _avgSum = 0;
        { _avgSum = _avgSum + ((_x select 2) max 0); } forEach _infTemplates;
        _avgInfMen = round (_avgSum / ((count _infTemplates) max 1));
        _minInfMen = 999999;
        { if (((_x select 2) max 0) < _minInfMen) then { _minInfMen = _x select 2; }; } forEach _infTemplates;
        _minInfMen = _minInfMen max 1;
        _targetSquads = (3 - _existingInf) max 0;
        _need = (_targetSquads * _avgInfMen) max _minInfMen;
        private _rq = [_side, _originPos, _need, _originName] call MISSION_CORE_fnc_requestManpower;
        _infAllowed = _rq select 0;
        _infDonors = _rq select 1;
        diag_log format ["STAGED COUNTER-ATTACK: %1 pooled %2 men for %3 foot squads (donors=%4)", _originName, _infAllowed, _targetSquads, _infDonors];
    };

    private _spawned = 0;
    // STAGED MODE (SUPPLY-REUSE HYBRID): the assembled counter-attack does NOT spawn its own foot
    // squads here. The marker's OWN supply pipeline (fn_replenishMarker / fn_queuedReplenish)
    // supplies the men - while the assembly entry is open, arriving supply squads destined for this
    // marker are absorbed into the staged roster by MISSION_CORE_fnc_tryAbsorbSupply. The pooled
    // manpower budget is held in the entry as the FALLBACK: releaseCounterStaged spends it on the
    // squads the supply window failed to deliver, so even a full-strength marker (which contributes
    // zero supply squads) still forms its counter-attack. Armor stages directly as usual below.
    private _stagedGroups = [];
    // Up to 2 tank markers: MBT each
    private _targetMBT = 2;
    while { _existingMBT < _targetMBT && count _mbtTemplates > 0 } do {
        if ([_side, "mbt", _originPos, _importance] call MISSION_CORE_fnc_armorCapOpen) then {
            private _grp = [_mbtTemplates, _side, _faction, _importance, _originPos, _targetPos, _originName, _staged, _tgtName, _originSize] call MISSION_CORE_fnc_spawnAssaultGroup;
            if (isNull _grp) then { break; };
            if (_staged) then { _stagedGroups pushBack _grp; };
            _existingMBT = _existingMBT + 1;
            _spawned = _spawned + 1;
            sleep 0.4;
        } else { break; };
    };
    // Each tank marker carries 1 mech; +1 so combined-arms (mech+inf) outweighs MBT armor ~3:1
    private _targetMech = _targetMBT + 1;
    while { _existingMech < _targetMech && count _mechTemplates > 0 } do {
        if ([_side, "mech", _originPos, _importance] call MISSION_CORE_fnc_armorCapOpen) then {
            private _grp = [_mechTemplates, _side, _faction, _importance, _originPos, _targetPos, _originName, _staged, _tgtName, _originSize] call MISSION_CORE_fnc_spawnAssaultGroup;
            if (isNull _grp) then { break; };
            if (_staged) then { _stagedGroups pushBack _grp; };
            _existingMech = _existingMech + 1;
            _spawned = _spawned + 1;
            sleep 0.4;
        } else { break; };
    };
    // Foot infantry: BLUFOR support (_staged=false) keeps the instant-march spawn. The staged
    // counter-attack relies on the supply pipeline + the assembly monitor's budgeted fallback.
    if (!_staged) then {
        private _targetInf = 3;
        while { _existingInf < _targetInf && count _infTemplates > 0 } do {
            private _grp = [_infTemplates, _side, _faction, _importance, _originPos, _targetPos, _originName, _staged, _tgtName, _originSize] call MISSION_CORE_fnc_spawnAssaultGroup;
            if (isNull _grp) then { break; };
            _existingInf = _existingInf + 1;
            _spawned = _spawned + 1;
            sleep 0.4;
        };
    };
    diag_log format ["AI COMMANDER: %1 assault from %2 vs %3 -> mbt=%4 mech=%5 inf=%6 spawned=%7", _side, _originPos, _targetPos, _existingMBT, _existingMech, _existingInf, _spawned];
    // 5s gap after the assault force finishes assembling before the next spawn burst
    if (_spawned > 0) then { sleep 5; };
    // STAGED: publish the supply-reuse assembly (keyed by the origin marker) and spawn the release
    // monitor. The monitor waits out the supply window (arriving replenish squads are absorbed), tops
    // up the shortfall from the pooled budget, holds until EVERY group reaches the staging edge, then
    // releases the whole force TOGETHER (no timeout - it pushes when the last group arrives).
    if (_staged) then {
        if (isNil "MISSION_CORE_STAGING_BUDGET") then { MISSION_CORE_STAGING_BUDGET = createHashMap; };
        private _entry = createHashMapFromArray [
            ["roster", _stagedGroups],
            ["menNeeded", _need],
            ["targetPos", _targetPos],
            ["tgtSize", [50, 50]],
            ["tgtName", _tgtName],
            ["side", _side],
            ["funded", _infAllowed],
            ["donors", _infDonors],
            ["minInfMen", _minInfMen],
            ["infTemplates", _infTemplates],
            ["faction", _faction],
            ["importance", _importance],
            ["originPos", _originPos],
            ["originSize", _originSize],
            ["created", time]
        ];
        MISSION_CORE_STAGING_BUDGET set [_originName, _entry];
        diag_log format ["STAGED COUNTER-ATTACK: %1 assembly published - %2 men needed, %3 pooled, %4 armor staged", _originName, _need, _infAllowed, count _stagedGroups];
        [_originName] spawn MISSION_CORE_fnc_releaseCounterStaged;
    };
};
