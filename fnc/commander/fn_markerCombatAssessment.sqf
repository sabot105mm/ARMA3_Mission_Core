// THREAT WEIGHT ASSESSMENT (the "scare meter"): weighs the BLUFOR force threatening a marker
// against the marker's own surviving garrison and returns a numeric scare score plus the
// HOLD / REINFORCE / CRITICAL verdict that decides how hard the marker begs for help.
//
// Weights (per unit): infantry = 1, APC = 8, tank = 20 (Tank > APC > Inf per unit; a full
// foot-battalion scares by NUMBERS while one mech column scares by mass).
//   - Group-coordination multiplier: the more SEPARATE groups press the marker, the scarier
//     the threat is - 8 foot squads (8 x 8 men) out-scares 1 mech group (8 APCs) because it
//     surrounds and fixes you. The multiplier applies over INSIDE + APPROACHING groups combined.
//   - Inside groups count fully; approaching groups count at a fraction.
//   - Defender power is the same 1/8/20 on the marker's own alive garrison, eroded as it
//     takes casualties toward its retreat threshold - a half-wiped garrison is less scary to
//     face, so the marker gets MORE desperate (scare rises) as the fight grinds on.
//   - Marker size dampens scare (square-root falloff): a big marker with a big garrison is
//     less afraid of the same threat than a one-hut outpost.
//   - DETERMINATION / TIER OVER-REACTION: high-tier markers (factories, powerplants, ports,
//     bases, HQ - anything tier 0/1) are terrified of being lost. They hit REINFORCE with far
//     less threat and hit CRITICAL almost immediately, so they over-react and throw help at
//     themselves harder than a tier-3 outpost would.
//
// Returns [scare, verdict, useFrac]:
//   scare            - the numeric post-dampen net (attacker - defender) threat score.
//   verdict          - "HOLD" (not scared enough to ask for help), "REINFORCE" (asks a FEW
//                      neighbors), or "CRITICAL" (asks ALL of its neighbors, keeps asking).
//   useFrac          - fraction of the neighbor pool to involve: 0 on HOLD, the tier-scaled
//                      askSome fraction on REINFORCE, 1.0 on CRITICAL (ask everyone).
MISSION_CORE_fnc_markerCombatAssessment = {
    params ["_loc", "_owner"];
    if (count _loc < 3) exitWith { [0, "HOLD", 0] };
    private _locName = _loc select 0;
    private _locPos = _loc select 1;
    private _importance = _loc select 7;
    private _mSize = if (count _loc > 8) then { _loc select 8 } else { [200, 200, 0] };
    private _ma = (_mSize select 0) max 1;
    private _mb = (if (count _mSize > 1) then { _mSize select 1 } else { _ma }) max 1;
    private _mRad = (_ma + _mb) / 2;

    // Classify every alive unit into its weight bucket. Vehicles count ONCE per vehicle (a tank
    // crew of 3 is 20, not 60); men on foot count 1 each; soft vehicles (trucks/transports) are
    // counted as their men (foot). Returns [infWeight, apcWeight, tankWeight, men, groups].
    private _bucketGroup = {
        params ["_grp", "_minDist", "_maxDist", "_center"];
        private _alive = units _grp select { !isNull _x && { alive _x } };
        if (count _alive == 0) exitWith { [] };
        private _near = { (_x distance2D _center) <= _maxDist } count _alive;
        if (_near == 0) exitWith { [] };
        private _insideCount = { (_x distance2D _center) <= _minDist } count _alive;
        private _vList = [];
        private _inf = 0;
        private _apc = 0;
        private _tank = 0;
        {
            private _v = vehicle _x;
            if (_v == _x) then { _inf = _inf + 1; }
            else {
                if !(_v in _vList) then {
                    _vList pushBack _v;
                    private _cls = typeOf _v;
                    if ([_cls] call MISSION_CORE_fnc_isTank) then { _tank = _tank + 1; }
                    else {
                        if ([_cls] call MISSION_CORE_fnc_isAPC) then { _apc = _apc + 1; }
                        else { _inf = _inf + 1; };
                    };
                };
            };
        } forEach _alive;
        private _weight = _inf + (_apc * 8) + (_tank * 20);
        private _isInside = _insideCount > 0;
        [_weight, _inf, _apc, _tank, _isInside]
    };

    private _insideR = _mRad + (["assaultStandoffRing", 250] call MISSION_CORE_fnc_tune);
    private _approachR = ["scareApproachRadius", 2500] call MISSION_CORE_fnc_tune;
    private _approachFrac = ["scareApproachFrac", 0.5] call MISSION_CORE_fnc_tune;

    private _atkW = 0;
    private _atkGroups = 0;
    // PLAYER THREAT: every hostile BLUFOR player near the marker counts as its own group
    // (vehicle type decides its weight). Any player, garrison-independent.
    {
        if (!alive _x) then { continue; };
        if (side _x getFriend _owner >= 0.6) then { continue; };
        if ((_x distance2D _locPos) > _approachR) then { continue; };
        private _v = vehicle _x;
        private _w = 1;
        if (_v != _x) then {
            private _cls = typeOf _v;
            if ([_cls] call MISSION_CORE_fnc_isTank) then { _w = 20; }
            else { if ([_cls] call MISSION_CORE_fnc_isAPC) then { _w = 8; }; };
        };
        _atkW = _atkW + _w;
        _atkGroups = _atkGroups + 1;
    } forEach (allPlayers select { alive _x });

    // ASSAULT-GROUP THREAT (target gate): only released BLUFOR assault groups whose ASSIGNED
    // TARGET is THIS marker scare it - a squad marching past somewhere else never does.
    private _collectAssault = {
        params ["_map", "_idx"];
        if (isNil "_map") exitWith {};
        if (count _map == 0) exitWith {};
        {
            private _adata = _y;
            if (count _adata < 7) then { continue; };
            if ((_adata select 5) != "active") then { continue; };
            if ((_adata select 1) != _locName) then { continue; };
            private _ag = _adata select 0;
            if (isNull _ag) then { continue; };
            private _b = [_ag, _insideR, _approachR, _locPos] call _bucketGroup;
            if (count _b == 0) then { continue; };
            private _wg = _b select 0;
            _atkW = _atkW + (_wg * (if (_b select 4) then { 1 } else { _approachFrac }));
            _atkGroups = _atkGroups + 1;
        } forEach _map;
    };
    [MISSION_CORE_ATTACK_GROUPS] call _collectAssault;
    [MISSION_CORE_ATTACK_GROUPS_RELAY] call _collectAssault;

    // Group-coordination multiplier over INSIDE + APPROACHING groups combined.
    private _coordination = if (_atkGroups > 1) then { 1 + (["scareGroupMult", 0.15] call MISSION_CORE_fnc_tune) * (_atkGroups - 1) } else { 1 };
    private _attacker = _atkW * _coordination;

    // DEFENDER POWER: the marker's own alive garrison at the same 1/8/20 weights, eroded by
    // the casualties it has taken toward its retreat threshold - a beaten-down garrison makes
    // the marker MORE scared, so help-asking ramps up before it is overrun.
    private _defW = 0;
    if (isNil "MISSION_CORE_SPAWNED_GROUPS") then { MISSION_CORE_SPAWNED_GROUPS = []; };
    private _sideVar = if (_owner == WEST) then { "MISSION_CORE_BLUFOR" } else { "MISSION_CORE_REDFOR" };
    {
        if (!isNull _x && { _x getVariable [_sideVar, false] } && { (_x getVariable ["MISSION_CORE_ORIGIN_MARKER", ""]) == _locName }) then {
            private _b = [_x, _insideR, 1e10, _locPos] call _bucketGroup;
            if (count _b == 0) then { continue; };
            _defW = _defW + (_b select 0);
        };
    } forEach MISSION_CORE_SPAWNED_GROUPS;
    private _cap = [_importance] call MISSION_CORE_fnc_markerCapacity;
    private _casualties = if (isNil "MISSION_CORE_MARKER_CASUALTIES") then { 0 } else { MISSION_CORE_MARKER_CASUALTIES getOrDefault [_locName, 0] };
    private _retreatAt = round (_cap * (1 - (([_loc] call MISSION_CORE_fnc_getMarkerDetermination) select 1)));
    private _erosion = 1 - ((_casualties / ((_retreatAt max 1))) * (["scareCasualtyErode", 0.75] call MISSION_CORE_fnc_tune));
    _erosion = (_erosion max 0.15) min 1;
    private _defender = _defW * _erosion;

    // NET = attacker - defender, dampened by marker SIZE (square-root falloff: a bigger marker
    // with a bigger garrison shrugs off the same threat).
    private _sizeDampen = 1 / (1 + sqrt (_mRad / (["scareSizeRef", 400] call MISSION_CORE_fnc_tune)));
    private _net = (_attacker - _defender) * _sizeDampen;

    // VERDICT from determination tier (T0/T1 = factories/power/ports/bases/HQ over-react). The
    // tier multipliers scale the ASK THRESHOLDS only - high-tier markers demand help with far
    // less threat. The neighbor COUNT once REINFORCE is reached is a flat "a few" fraction:
    // over-reacting markers reach CRITICAL (ask everyone) sooner; they never ask fewer.
    private _tier = ([_loc] call MISSION_CORE_fnc_getMarkerDetermination) select 0;
    private _tierK = [ [0.35, 0.5], [0.5, 0.65], [0.75, 0.85], [1.0, 1.0] ] select ((_tier max 0) min 3);
    private _askSomeFrac = (["scareAskSomeFrac", 0.4] call MISSION_CORE_fnc_tune) * (_tierK select 0);
    private _askAllFrac  = (["scareAskAllFrac", 1.0] call MISSION_CORE_fnc_tune)  * (_tierK select 1);
    private _askSome = _defender * _askSomeFrac;
    private _askAll = _defender * _askAllFrac;
    private _useSomeFrac = ["scareAskSomeFrac", 0.4] call MISSION_CORE_fnc_tune;
    private _verdict = "HOLD";
    private _useFrac = 0;
    if (_net >= _askAll) then { _verdict = "CRITICAL"; _useFrac = 1; }
    else {
        if (_net >= _askSome) then { _verdict = "REINFORCE"; _useFrac = _useSomeFrac; };
    };

    diag_log format ["DYNAMIC SCARE: %1 tier=%2 atkw=%3 grp=%4 coord=%5 def=%6 cas=%7 net=%8 verdict=%9 useFrac=%10", _locName, _tier, round _atkW, _atkGroups, round _coordination, round _defender, round _casualties, round _net, _verdict, _useFrac];
    [_net, _verdict, _useFrac]
};