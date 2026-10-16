// ABSTRACT OVERWATCHER
//
// Watches every MATERIALISED abstract leg ("rolling" rows) and answers one question about
// each of them: what actually brought the squad into the world - a nearby PLAYER, or the
// leg simply reaching its destination (routeLegFinalRadius / pending deadline)?
//
// A squad conjured because a player crossed within abstractLegPlayerRadius exists for that
// player's benefit. Once that player (and everyone else) moves away, keeping the squad
// visible just has it marching unobserved across the open map, so the watcher parks it
// (hidden, de-simulated - exactly the fn_abstractClaimedSquad claim phase) and flips the
// row back to "abstract".
//
// THE SAVED ROUTE IS PRESERVED ON PURPOSE: path/cum/travel/time are untouched, so when the
// leg is next materialised it resumes from where the squad was parked instead of re-planning
// from scratch. And because the row's materialise slot is swapped for a claimed-style
// callback, the SAME men - not a fresh conjure - are re-dropped, so nothing is charged
// twice. Route-reached and deadline materialisations NEVER revert: a squad already closing
// on the contested marker stays visible and the tick hands it off normally.
//
// This lives in its own module rather than fn_abstractLeg.sqf to keep the leg layer small.
// It reads the store it is given and needs no changes inside the leg tick: the cause is
// derived here from player proximity at first sighting of each rolling row, and the flip
// is a row edit made from outside.

// Claimed-style materialise for a re-abstracted leg: raise the SAME parked squad at the
// route position, not a fresh conjure. Registered onto the row by reabstract below.
MISSION_CORE_fnc_abstractWatcher_reDrop = {
    params ["_row", "_frac"];
    private _id = _row select 15;
    private _g = MISSION_CORE_ABSTRACT_REPARK getOrDefault [_id, grpNull];
    if (isNull _g || { count units _g == 0 }) exitWith { grpNull };
    private _atp = [_row select 6, _row select 7, _frac] call MISSION_CORE_fnc_convoyPosAt;
    {
        _x hideObjectGlobal false;
        _x enableSimulationGlobal true;
        _x setPos [_atp select 0, _atp select 1, 0];
    } forEach units _g;
    _g setVariable ["MISSION_CORE_ABSTRACT_CLAIMED", nil];
    MISSION_CORE_ABSTRACT_REPARK deleteAt _id;
    // Parked at a spot the river/strait route crossed? Embark the same way a fresh leg would
    // (fn_mountFootInBoats is a no-op on dry land).
    [_g, _atp] call MISSION_CORE_fnc_mountFootInBoats;
    diag_log format ["ABSTRACT WATCH: id %1 (%2) re-materialised SAME squad %3 at %4% of route", _id, _row select 0, groupId _g, round (_frac * 100)];
    _g
};

// Park a materialised squad back onto its abstract leg. The deciding tick handed over a
// live row, but the row is re-read here so a handoff that ran in the same instant cannot
// be raced - parking a squad the arrival script has already taken ownership of would hide
// a squad mid-assault.
MISSION_CORE_fnc_abstractWatcherReabstract = {
    params ["_row", "_id"];
    private _idx = MISSION_CORE_ABSTRACT_LEGS findIf { (_x select 15) == _id };
    if (_idx < 0) exitWith { false };
    private _row2 = MISSION_CORE_ABSTRACT_LEGS select _idx;
    if ((_row2 select 11) != "rolling") exitWith { false };
    private _grp = _row2 select 12;
    if (isNull _grp || { count units _grp == 0 }) exitWith { false };
    // A boat ride is a materialised approach already in full swing (fn_boatApproach.sqf);
    // there is no sane way to park a squad that is embarked - let it finish.
    if (_grp getVariable ["MISSION_CORE_BOAT_TRANSIT", false]) exitWith { false };
    { _x hideObjectGlobal true; _x enableSimulationGlobal false; } forEach units _grp;
    _grp setVariable ["MISSION_CORE_ABSTRACT_CLAIMED", true];
    _grp setVariable ["MISSION_CORE_IDLE", false];
    _grp setVariable ["MISSION_CORE_PATROLLING", false];
    [_grp] call MISSION_CORE_fnc_clearGroupWaypoints;
    // Flip the row back - path/cum/travel/time stay put, so the leg keeps advancing the
    // SAME saved route from this point; only the state, the group handle and the materialise
    // slot change. The re-drop callback hands the same men back when it next raises them.
    _row2 set [11, "abstract"];
    _row2 set [12, grpNull];
    _row2 set [14, MISSION_CORE_fnc_abstractWatcher_reDrop];
    MISSION_CORE_ABSTRACT_LEGS set [_idx, _row2];
    MISSION_CORE_ABSTRACT_REPARK set [_id, _grp];
    MISSION_CORE_ABSTRACT_WATCH deleteAt _id;
    diag_log format ["ABSTRACT WATCH: id %1 (%2) player deserted - squad %3 re-abstracted from %4, saved route resumed (path/cum/time untouched)", _id, _row2 select 0, groupId _grp, getPosATL (leader _grp)];
    true
};

// Does exactly what the name says: cause-track every materialised leg, revert the ones
// whose player is gone. Read-only scan, then apply - rows are never edited while iterating.
MISSION_CORE_fnc_abstractWatcherTick = {
    if (isNil "MISSION_CORE_ABSTRACT_LEGS") exitWith {};
    if (count MISSION_CORE_ABSTRACT_LEGS == 0) exitWith {};
    if (isNil "MISSION_CORE_ABSTRACT_WATCH") then { MISSION_CORE_ABSTRACT_WATCH = createHashMap; };
    if (isNil "MISSION_CORE_ABSTRACT_REPARK") then { MISSION_CORE_ABSTRACT_REPARK = createHashMap; };

    private _playerR = ["abstractLegPlayerRadius", 1200] call MISSION_CORE_fnc_tune;
    if !(_playerR isEqualType 1) then { _playerR = 1200; };
    private _awayR = ["abstractWatchAwayRadius", 1600] call MISSION_CORE_fnc_tune;
    if !(_awayR isEqualType 1) then { _awayR = 1600; };
    if (_awayR < _playerR) then { _awayR = _playerR * 1.5; };
    private _finalR = ["routeLegFinalRadius", 1000] call MISSION_CORE_fnc_tune;
    if !(_finalR isEqualType 1) then { _finalR = 1000; };
    private _minDist = ["abstractWatchMinDist", 1500] call MISSION_CORE_fnc_tune;
    if !(_minDist isEqualType 1) then { _minDist = 1500; };
    private _players = allPlayers select { alive _x };

    private _reabstract = [];
    private _ids = [];
    {
        _ids pushBack (_x select 15);
    } forEach MISSION_CORE_ABSTRACT_LEGS;

    {
        private _row = _x;
        if ((_row select 11) == "rolling") then {
            private _id = _row select 15;
            private _grp = _row select 12;
            if (!isNull _grp && { count units _grp > 0 }) then {
                if !(_grp getVariable ["MISSION_CORE_BOAT_TRANSIT", false]) then {
                    private _pos = getPosATL (leader _grp);
                    private _entry = MISSION_CORE_ABSTRACT_WATCH getOrDefault [_id, []];
                    if (count _entry == 0) then {
                        // First sighting of a materialised leg: record WHAT materialised it.
                        // A player within the materialise radius = the player did; otherwise the
                        // leg reached its destination ring or its deadline, both "route" causes.
                        private _cause = "route";
                        if (({ (_pos distance2D (getPosATL _x)) < _playerR } count _players) > 0) then { _cause = "player"; };
                        MISSION_CORE_ABSTRACT_WATCH set [_id, [_pos, _cause, time]];
                        diag_log format ["ABSTRACT WATCH: id %1 (%2) materialised at %3 - cause %4", _id, _row select 0, _pos, _cause];
                    } else {
                        if ((_entry select 1) == "player") then {
                            // Everyone has moved away from where it materialised (the revert ring
                            // is bigger than the trigger ring, so it does not flap on the boundary)
                            // AND the squad is not closing on the contested marker - back to abstract.
                            private _anyNear = ({ (_x distance2D (_entry select 0)) < _awayR } count _players) > 0;
                            if (!_anyNear && { ((_pos distance2D (_row select 3)) > _finalR) } && { ((_pos distance2D (_row select 3)) > _minDist) }) then {
                                _reabstract pushBack [_row, _id];
                            };
                        };
                    };
                };
            };
        };
    } forEach MISSION_CORE_ABSTRACT_LEGS;

    {
        [_x select 0, _x select 1] call MISSION_CORE_fnc_abstractWatcherReabstract;
    } forEach _reabstract;

    // Prune readers of legs that have left the store (handed off or dropped).
    {
        private _k = _x;
        if !(_k in _ids) then {
            MISSION_CORE_ABSTRACT_WATCH deleteAt _k;
            MISSION_CORE_ABSTRACT_REPARK deleteAt _k;
        };
    } forEach (keys MISSION_CORE_ABSTRACT_WATCH);
};

MISSION_CORE_fnc_abstractWatcherLoop = {
    diag_log "ABSTRACT WATCH: overwatcher started - materialised legs cause-tracked, player-deserted squads re-abstracted";
    waitUntil { !isNil "MISSION_CORE_fnc_abstractLegTick" };
    private _iv = ["abstractWatchInterval", 4] call MISSION_CORE_fnc_tune;
    if !(_iv isEqualType 1) then { _iv = 4; };
    if (_iv < 2) then { _iv = 2; };
    private _nextScan = 0;
    while { true } do {
        sleep 1;
        if (time >= _nextScan) then {
            _nextScan = time + _iv;
            [] call MISSION_CORE_fnc_abstractWatcherTick;
        };
    };
};