// -------------------------------------------------------------------
// SNATCH FILTER - which existing groups the AI commander may pull into a battle
//
// The commander used to yank ANY eligible group to a contested marker regardless of where it was
// fighting. That pulled whole platoons off their own assault, dragged squads from far side of the
// map, and tore groups out of the marker they were ALREADY defending. This filter applies to every
// existing-group pickup (commitToBattle + the aiCommanderLoop counter-attack / vehicle / far pickers):
//
//   1. NEVER pull a group whose leader sits more than 1000m from the defend marker.
//   2. Within range, still skip a group that is mid-assault on its OWN target (leader within a
//      small buffer of that target) - it is already executing a counter-attack, not available.
//   3. Within range, still skip a group whose leader is already inside (or hugging the edge of)
//      the very marker the commander would send it to - it is effectively already there; yanking
//      it is a no-op that shuffles its ORDER for nothing.
//   4. A player-side assault squad (BLUFOR & tracked in MISSION_CORE_ATTACK_GROUPS) caught by
//      rules 1-3 needs the COMMANDER's say-so before being rerouted - the player-commander is
//      asked first, and if they never answer the reroute defaults to GO (see fn_askRerouteApproval).
// -------------------------------------------------------------------

if (isNil "MISSION_CORE_REROUTE_ASKS") then { MISSION_CORE_REROUTE_ASKS = createHashMap; };

// The commander slot = a WEST player in a LIEUTENANT+ (CO) unit. First alive one found wins; there is
// normally only one playable CO in the mission. No commander found -> decisions default to GO.
MISSION_CORE_fnc_getCommanderPlayer = {
    private _cmdr = objNull;
    {
        if (alive _x && { side _x == WEST } && { rank _x in ["COLONEL", "GENERAL", "LIEUTENANT"] }) exitWith { _cmdr = _x; };
    } forEach (allPlayers select { alive _x });
    _cmdr
};

// Server-side answer recorder (called by remoteExecCall from the commander's YES/NO dialog).
MISSION_CORE_fnc_commanderRerouteAnswer = {
    params ["_key", "_answer"];
    if (isNil "MISSION_CORE_REROUTE_ASKS") then { MISSION_CORE_REROUTE_ASKS = createHashMap; };
    MISSION_CORE_REROUTE_ASKS set [_key, [time, _answer]];
};

// ASYNC commander approval for rerouting a specific player assault squad to a defend marker.
// Returns true when the group may be pulled now, false when it must wait (pending) or was refused.
//   - First time a squad+marker is asked: fire the dialog to the commander client and wait.
//   - No commander slot exists -> approve immediately (default reroute anyway).
//   - Dialog unanswered within commanderRerouteTimeout (default 30s) -> approve (default GO).
//   - Commander answers NO -> the squad is never pulled for THAT marker again this session.
MISSION_CORE_fnc_askRerouteApproval = {
    params ["_grp", "_markerName"];
    private _key = format ["%1|%2", groupId _grp, _markerName];
    private _entry = MISSION_CORE_REROUTE_ASKS getOrDefault [_key, []];
    if (count _entry > 0) then {
        private _askedAt = _entry select 0;
        private _answer = _entry select 1;
        if !(isNil "_answer") exitWith { _answer };
        // Still pending - default GO only after the timeout so a commander unsure gets a moment.
        if (time - _askedAt >= (["commanderRerouteTimeout", 30] call MISSION_CORE_fnc_tune)) exitWith {
            MISSION_CORE_REROUTE_ASKS set [_key, [_askedAt, true]];
            true
        };
        false
    } else {
        // First ask: record pending, then find the commander.
        MISSION_CORE_REROUTE_ASKS set [_key, [time, nil]];
        private _cmdr = [] call MISSION_CORE_fnc_getCommanderPlayer;
        if (isNull _cmdr) exitWith { MISSION_CORE_REROUTE_ASKS set [_key, [time, true]]; true };
        [_key, groupId _grp, _markerName] remoteExecCall ["MISSION_CORE_fnc_showCommanderReroutePrompt", _cmdr, false];
        false
    };
};

// THE FILTER. true = the commander may pull this group to defend _defendMarker at _defendPos.
MISSION_CORE_fnc_canSnatchGroup = {
    params ["_grp", "_defendMarker", "_defendPos"];
    private _ldr = leader _grp;
    if (isNull _ldr || { !alive _ldr }) exitWith { false };
    // Rule 1: beyond 1000m of the defend marker - never pulled.
    if (_ldr distance2D _defendPos > (["commanderSnatchRange", 1000] call MISSION_CORE_fnc_tune)) exitWith { false };
    // Rule 2: mid-assault on its OWN target - the leader is within a small buffer of its own
    // attack/counterattack target, i.e. actively pressing that fight. Don't steal it.
    private _cur = _grp getVariable ["MISSION_CORE_ORDER", ""];
    private _ownTarget = _grp getVariable ["MISSION_CORE_ATTACK_TARGET", [0, 0, 0]];
    if ((_cur == "attack" || { _cur == "counterattack" }) && { count _ownTarget > 0 }) then {
        if (_ldr distance2D _ownTarget < (["commanderSnatchOwnTargetRange", 300] call MISSION_CORE_fnc_tune)) exitWith { false };
    };
    // Rule 3: already inside / hugging the edge of the defend marker - it is effective there;
    // snatching it back and forth would flip ORDER for nothing.
    private _geom = [_defendMarker] call MISSION_CORE_fnc_getMarkerGeometry;
    if ([getPos _ldr, _geom, (["commanderSnatchEdgeScale", 1.2] call MISSION_CORE_fnc_tune)] call MISSION_CORE_fnc_pointInGeometry) exitWith { false };
    // Rule 4: player-side assault squad (BLUFOR + tracked in ATTACK_GROUPS) - ask the commander.
    if (side _grp == WEST && { !isNil "MISSION_CORE_ATTACK_GROUPS" } && { count MISSION_CORE_ATTACK_GROUPS > 0 }) then {
        private _tracked = false;
        {
            private _entry = _y;
            if ((_entry select 0) == _grp) exitWith { _tracked = true; };
        } forEach MISSION_CORE_ATTACK_GROUPS;
        if (_tracked) exitWith { [_grp, _defendMarker] call MISSION_CORE_fnc_askRerouteApproval };
    };
    true
};

// NetId variant of applyAssaultWaypoints for SERVER-owned groups (the commander client forwards
// owner=server groups here). fn_recruit.sqf's client-side copy has the same name - that file is
// only compiled on players and this file only on the server, so no machine ever defines it twice.
MISSION_CORE_fnc_applyAssaultWaypointsNet = {
    params ["_netId", "_wps", "_targetPos"];
    private _grp = objectFromNetId _netId;
    if (isNull _grp) exitWith {};
    if !(local _grp) exitWith {};
    [_grp] call MISSION_CORE_fnc_clearGroupWaypoints;
    private _firstWp = [];
    private _firstSpeed = "FULL";
    private _firstBeh = "AWARE";
    private _firstRoe = "YELLOW";
    {
        _x params ["_wpPos", "_wpType", "_wpRoe", ["_wpSpeed", "FULL"], ["_wpBeh", "AWARE"]];
        if (_wpType == "CYCLE") then { _wpType = "MOVE"; };
        private _wp = _grp addWaypoint [_wpPos, 10];
        _wp setWaypointType _wpType;
        _wp setWaypointCombatMode _wpRoe;
        _wp setWaypointSpeed _wpSpeed;
        _wp setWaypointBehaviour _wpBeh;
        if (count _firstWp == 0) then {
            _firstWp = _wp;
            _firstSpeed = _wpSpeed;
            _firstBeh = _wpBeh;
            _firstRoe = _wpRoe;
        };
    } forEach _wps;
    if (count _wps == 0) then {
        _firstWp = _grp addWaypoint [_targetPos, 50];
        _firstWp setWaypointType "SAD";
        _firstWp setWaypointCombatMode "YELLOW";
        _firstWp setWaypointSpeed "FULL";
        _firstWp setWaypointBehaviour "AWARE";
    };
    if (count _firstWp > 0) then { _grp setCurrentWaypoint _firstWp; };
    _grp setBehaviour _firstBeh;
    _grp setCombatMode _firstRoe;
    _grp setSpeedMode _firstSpeed;
    _grp setVariable ["MISSION_CORE_ORDER", "attack"];
    _grp setVariable ["MISSION_CORE_ATTACK_TARGET", _targetPos];
};