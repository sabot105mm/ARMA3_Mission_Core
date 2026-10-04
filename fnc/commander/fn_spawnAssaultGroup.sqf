
// Spawn a single group for the assault force. In staged mode (full counter-attack) the group
// is staged at the SOURCE edge and held until the whole force has assembled - no attack order,
// no ordered-vehicle tag (while it holds deliberately it must not be recycled by the sweeper).
// The caller (fn_assembleAssault) is responsible for the release monitor once all groups are in.
MISSION_CORE_fnc_spawnAssaultGroup = {
    params ["_templates", "_side", "_faction", "_importance", "_originPos", "_targetPos", ["_originName", ""], ["_staged", false], ["_tgtName", ""], ["_srcSize", [200, 200]]];
    if (count _templates == 0) exitWith { grpNull };
    private _tmpl = selectRandom _templates;
    private _spawnPos = [_originPos, [200, 200], 20, random 360] call MISSION_CORE_fnc_findVehiclePos;
    private _grp = [(_tmpl select 0), _spawnPos, _side, _faction, "AWARE", "FULL", _importance, _originPos, [200, 200]] call MISSION_CORE_fnc_spawnGroup;
    if (isNull _grp) exitWith { grpNull };
    _grp setVariable ["MISSION_CORE_ORDER", "attack"];
    _grp setVariable ["MISSION_CORE_IDLE", false];
    _grp setVariable ["MISSION_CORE_ORIGIN_MARKER", _originName];
    leader _grp setVariable ["MISSION_CORE_PATROLLING", false];
    // Tracked armour the template brought is eligible for drowning recovery, whether it is an MBT
    // column or a mech template. Done once for the whole group here rather than inside the
    // _subCat branches below, so a new armour subcategory cannot be added and silently miss it.
    if (!isNil "MISSION_CORE_fnc_drownedWatch") then {
        [_grp, format ["ai assault %1", _tgtName]] call MISSION_CORE_fnc_drownedWatch;
    };
    private _subCat = _tmpl select 3;
    // Presence-for-contest reads this same flag (fn_assaultGroupEval): a mech/motor column is judged
    // by its vehicle position, a foot squad by its men. Stamped once from the template here rather
    // than re-derived on every 1Hz contest pass.
    _grp setVariable ["MISSION_CORE_MECH_MOTOR", ((_subCat == "mech") || { (_subCat find "motor") > -1 })];
    if (_subCat find "tank" > -1 && { _subCat find "_aa" == -1 }) then {
        _grp setVariable ["MISSION_CORE_ARMOR_SLOT", "mbt"];
        {
            private _v = vehicle _x;
            if (_v != _x && { _v isKindOf "Tank" }) then {
                _v setVariable ["MISSION_CORE_REINF_TARGET", _targetPos];
                _v addEventHandler ["Killed", {
                    params ["_kv"];
                    private _s = _side;
                    private _t = _kv getVariable ["MISSION_CORE_REINF_TARGET", [0, 0, 0]];
                    private _l = getPos _kv call MISSION_CORE_fnc_getLocByPos;
                    private _n = if (count _l > 0) then { _l select 0 } else { "" };
                    [_s, _t, _n] call MISSION_CORE_fnc_requestArmorReinforcement;
                }];
                // Ordered away (release below) - track it so a tank that never leaves spawn is
                // recycled instead of parking on a free slot. NOT tagged while staging: a holding
                // tank is deliberately parked and must not be swept.
                if (!_staged) then { [_v, _targetPos] call MISSION_CORE_fnc_tagOrderedVehicle; };
            };
        } forEach units _grp;
    };
    if (_subCat == "mech") then {
        _grp setVariable ["MISSION_CORE_ARMOR_SLOT", "mech"];
        {
            private _v = vehicle _x;
            if (_v != _x && { _v isKindOf "Wheeled_APC" || _v isKindOf "Tracked_APC" }) then {
                _v setVariable ["MISSION_CORE_REINF_TARGET", _targetPos];
                _v addEventHandler ["Killed", {
                    params ["_kv"];
                    private _s = _side;
                    private _t = _kv getVariable ["MISSION_CORE_REINF_TARGET", [0, 0, 0]];
                    private _l = getPos _kv call MISSION_CORE_fnc_getLocByPos;
                    private _n = if (count _l > 0) then { _l select 0 } else { "" };
                    [_s, _t, _n] call MISSION_CORE_fnc_requestArmorReinforcement;
                }];
                if (!_staged) then { [_v, _targetPos] call MISSION_CORE_fnc_tagOrderedVehicle; };
            };
        } forEach units _grp;
    };
    // Motorized infantry: load foot squads into a side cargo truck so they drive to the attack zone
    if (_subCat find "inf" == 0) then {
        [_grp, _side, _spawnPos] call MISSION_CORE_fnc_mountInfantry;
    };
    [_grp] call MISSION_CORE_fnc_clearGroupWaypoints;
    private _assaultCombat = if (_subCat find "tank" > -1 || _subCat == "mech") then { "YELLOW" } else { "RED" };
    if (_staged) then {
        // Stage at the source edge on the bearing to the target; the release monitor in
        // fn_assembleAssault orders the whole force together once every group has arrived.
        _grp setVariable ["MISSION_CORE_ASSAULT_COMBAT", _assaultCombat];
        _grp setVariable ["MISSION_CORE_ASSAULT_GROUP", true];
        [_grp, _originPos, _srcSize, _targetPos] call MISSION_CORE_fnc_stageGroupAtEdge;
        // WATCHDOG SAFETY: the attack-stuck watchdog spare-releases any group whose ATTACK_TARGET
        // is more than 100m from a live contested-zone center ("stale order" path). A counter-attack
        // aims at the nearest player's live position, which on a large marker can easily sit further
        // out than 100m from its center - without snapping the target var the watchdog would send a
        // staging force back to patrol one group at a time. Snap ATTACK_TARGET to the nearest
        // same-side contested-zone center (the waypoint store already faces the real player position,
        // and releaseCounterStaged re-tasks the LIVE push target at release, so this var only feeds
        // the watchdog).
        [_grp, _side, _targetPos] call MISSION_CORE_fnc_snapAttackTargetToZone;
        diag_log format ["STAGED COUNTER-ATTACK: %1 staged %2 at source edge on bearing %3", groupId _grp, _subCat, round (_originPos getDir _targetPos)];
    } else {
        // Unified assault: one MOVE (or GETOUT for truck-mounted foot squads) to the confidence-driven
        // advance point, then one SAD at the target center. Dismounted foot troops split into their own
        // group and lose ownership of the transport. Armor spawns engage (YELLOW) but not engage-at-will.
        [_grp, _targetPos, [50, 50], _assaultCombat] call MISSION_CORE_fnc_sendCounterAttack;
    };
    // PERMANENT RULE (ARMOR FORMATION): tanks/mech follow their group leader (doFollow) so the
    // column advances (or holds at the staging edge) in formation behind the lead tank instead of
    // each crew free-driving to the target. The leader himself is skipped.
    if (_subCat find "tank" > -1 || _subCat == "mech") then {
        {
            if (_x != leader _grp) then { _x doFollow leader _grp; };
        } forEach units _grp;
    };
    MISSION_CORE_SPAWNED_GROUPS pushBack _grp;
    // CONTEST REGISTRATION. This is an AI assault force group (fn_assaultStaging /
    // fn_assembleAssault) and it used to be COMPLETELY invisible to isMarkerContested.
    // MISSION_CORE_ATTACK_GROUPS is only ever written by the recruit and assaultServer flows, so an
    // AI squad could sit inside its target marker, fight the garrison for minutes, and never mark
    // that marker contested - the zone read "no longer contested" and its reinforcement stopped.
    // Registered in its own map deliberately: ATTACK_GROUPS carries _status semantics that the
    // recruit / staging / release / wipe loops depend on, and injecting AI groups there would
    // disturb those flows. refreshAssaultContest prunes entries as groups die.
    if (_tgtName != "") then {
        if (isNil "MISSION_CORE_ASSAULT_CONTEST_SEQ") then { MISSION_CORE_ASSAULT_CONTEST_SEQ = 0 };
        if (isNil "MISSION_CORE_ASSAULT_CONTEST_GROUPS") then { MISSION_CORE_ASSAULT_CONTEST_GROUPS = createHashMap };
        MISSION_CORE_ASSAULT_CONTEST_SEQ = MISSION_CORE_ASSAULT_CONTEST_SEQ + 1;
        MISSION_CORE_ASSAULT_CONTEST_GROUPS set [["aia", MISSION_CORE_ASSAULT_CONTEST_SEQ], [_grp, _tgtName, _side]];
    };
    _grp
};
