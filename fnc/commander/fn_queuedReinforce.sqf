
MISSION_CORE_fnc_queuedReinforce = {
    params ["_side", "_template", "_spawnPos", "_faction", "_importance", "_locPos", "_mSize", "_providerName"];
    if !([_side, "inf", _locPos] call MISSION_CORE_fnc_townCategoryCanUse) exitWith { false };
    if (([_side] call MISSION_CORE_fnc_countFootSquads) >= (["footSquadCapSquads", 10] call MISSION_CORE_fnc_tune)) exitWith { false };
    // PROVIDER NOT EXHAUSTED (PERMANENT RULE). This job is allowed to reach a marker the players
    // just captured - it is part of the retake - but only while the PROVIDER can still pay for it.
    // Re-checked here rather than at enqueue, because a queue outlives the provider's manpower: a
    // marker can be drained, or lost to the players, while this job waits its turn. Both conditions
    // are terminal - a provider that is gone or spent will not recover inside this queue pass, and
    // leaving the job queued would just spin it until the 60-attempt limit for nothing.
    private _provNow = (MISSION_CORE_CACHED_POSITIONS select { (_x select 0) == _providerName });
    if (count _provNow > 0 && { (_provNow select 0) select 4 != _side }) exitWith {
        diag_log format ["DYNAMIC QUEUE: dropped queued reinforce %1 - provider %2 is now player-held", _template select 0, _providerName];
        true
    };
    // MANPOWER RESERVE: never ship men that would leave the provider's home below its own retreat
    // threshold. Uses the shared helper, which reads the PROVIDER's own cached row for capacity and
    // hold fraction - _importance here is the TARGET marker's (fn_requestReinforcement passes the
    // requesting marker's value), so using it would have costed the provider off the wrong marker.
    private _afford = [_providerName, (_template select 2)] call MISSION_CORE_fnc_providerCanAfford;
    if !(_afford select 0) exitWith {
        diag_log format ["DYNAMIC QUEUE: dropped queued reinforce %1 from %2 - provider exhausted (stock=%3 committed=%4 squad=%5 retreatAt=%6)", _template select 0, _providerName, _afford select 1, _afford select 2, _template select 2, _afford select 3];
        true
    };
    // LONG HAUL? Check BEFORE spawning. The immediate-dispatch path in fn_requestReinforcement
    // gates on reinforceAbstractMinDist (2000m) and sends an abstract leg instead of a marching
    // squad; the QUEUE path originally skipped that check, so a far pair, once a foot slot freed,
    // released a real squad for a multi-km foot slog. Mirror the direct path so both routes to a
    // reinforcement agree. Returns true here (job done) when a leg takes the squad, or when the
    // haul is >= the gate but cannot be abstracted - a far unabstractable pair is never spent on
    // a doomed conjure. The destination NAME (arg 8) is passed by fn_requestReinforcement's
    // enqueue; routePlan is keyed on names, so without it no leg and no skip-conjure, and the
    // short/direct behaviour below runs exactly as before.
    private _toName = _this param [8, ""];
    private _providerPos = _locPos;
    if (_providerName != "") then {
        private _pIdx = MISSION_CORE_CACHED_POSITIONS findIf { (_x select 0) == _providerName };
        if (_pIdx >= 0 && { count ((MISSION_CORE_CACHED_POSITIONS select _pIdx) select 1) >= 2 }) then {
            _providerPos = (MISSION_CORE_CACHED_POSITIONS select _pIdx) select 1;
        };
    };
    // Same payload layout as fn_requestReinforcement's leg: 0 template, 1 recipient importance,
    // 2 side, 3 faction templates, 4 provider name (convoy payer), 5 recipient name (payee).
    private _legTaken = false;
    if (_toName != "") then {
        _legTaken = [
            "reinf", _providerName, _toName,
            _providerPos, _locPos, _mSize,
            [_template select 0, _importance, _side, _faction, _providerName, _toName],
            {
                params ["_row", "_frac"];
                private _pl = _row select 5;
                private _at = [_row select 6, _row select 7, _frac] call MISSION_CORE_fnc_convoyPosAt;
                private _g = [_pl select 0, [_at select 0, _at select 1, 0], _pl select 2, _pl select 3, "AWARE", "LIMITED", _pl select 1, _row select 3, _row select 4] call MISSION_CORE_fnc_spawnGroup;
                if (!isNull _g) then {
                    _g setVariable ["MISSION_CORE_MARKER_CENTER", _row select 3];
                    if (isNil "MISSION_CORE_SPAWNED_GROUPS") then { MISSION_CORE_SPAWNED_GROUPS = []; };
                    MISSION_CORE_SPAWNED_GROUPS pushBack _g;
                    // Raised over open water (a strait / island hop)? Embark the squad into
                    // boats sized to fit it before anyone swims. No-op on dry land.
                    [_g, _at] call MISSION_CORE_fnc_mountFootInBoats;
                    // The supply follows the men: nothing is debited until the squad exists.
                    // startConvoy returns false and debits nothing if it cannot create a record.
                    if (!isNil "MISSION_CORE_CONTESTED" && { !((_pl select 5) in MISSION_CORE_CONTESTED) }) then {
                        private _sentConv = [_pl select 4, _pl select 5, 1] call MISSION_CORE_fnc_startConvoy;
                        if (_sentConv) then {
                            diag_log format ["ABSTRACT LEG: reinf %1 -> %2 convoy dispatched (1 supply) - squad spawned", _pl select 4, _pl select 5];
                        } else {
                            diag_log format ["ABSTRACT LEG: reinf %1 -> %2 supply convoy refused - recipient contested or BLUFOR-held", _pl select 4, _pl select 5];
                        };
                    } else {
                        diag_log format ["ABSTRACT LEG: reinf %1 -> %2 supply convoy skipped - recipient contested", _pl select 4, _pl select 5];
                    };
                };
                _g
            },
            {
                params ["_g", "_row"];
                if (isNull _g) exitWith {};
                [_g, _row select 3, _row select 4] call MISSION_CORE_fnc_sendCounterAttack;
            }
        ] call MISSION_CORE_fnc_abstractLegDispatch;
    };
    if (_legTaken) exitWith { true };
    // LONG-HAUL GATE (same guard as the direct path): at/over the abstraction threshold a foot
    // haul belongs to the leg system. If the abstract dispatch itself declined - no route, missing
    // endpoints - skip the conjure rather than release a squad doomed to a long slog.
    private _skipConjure = false;
    if (_toName != "" && { count _providerPos >= 2 }) then {
        private _minG = ["reinforceAbstractMinDist", 2000] call MISSION_CORE_fnc_tune;
        if !(_minG isEqualType 1) then { _minG = 2000; };
        private _dist = _providerPos distance2D _locPos;
        if (_dist >= _minG) then {
            _skipConjure = true;
            diag_log format ["LONG HAUL REINF: %1 -> %2 is %3m (>= %4m); abstract declined - skipping conjure", _providerName, _toName, round _dist, _minG];
        };
    };
    if (_skipConjure) exitWith { true };

    private _grp = [_template select 0, _spawnPos, _side, _faction, "AWARE", "LIMITED", _importance, _locPos, _mSize] call MISSION_CORE_fnc_spawnGroup;
    if (isNull _grp) exitWith { false };
    _grp setVariable ["MISSION_CORE_ORIGIN_MARKER", _providerName];
    _grp setVariable ["MISSION_CORE_MARKER_CENTER", _locPos];
    [_grp] call MISSION_CORE_fnc_clearGroupWaypoints;
    private _wp = _grp addWaypoint [_locPos, 100];
    _wp setWaypointType "SAD";
    _wp setWaypointSpeed "NORMAL";
    _wp setWaypointBehaviour "COMBAT";
    _grp setCurrentWaypoint _wp;
    _grp setCombatMode "RED";
    if (isNil "MISSION_CORE_SPAWNED_GROUPS") then { MISSION_CORE_SPAWNED_GROUPS = []; };
    MISSION_CORE_SPAWNED_GROUPS pushBack _grp;
    // The squad exists now, so it is paid for now - the reserve gate above tested against this.
    MISSION_CORE_COMMIT set [_providerName, (MISSION_CORE_COMMIT getOrDefault [_providerName, 0]) + (_template select 2)];
    diag_log format ["DYNAMIC QUEUE: released queued reinforce %1 from %2", _template select 0, _providerName];
    true
};
