
// When a marker's garrison is wiped while a player is inside it, the marker is OCCUPIED, not
// instantly captured. Ownership flips to the player side immediately, but the marker enters a
// 10-minute hold phase (see fn_occupationMonitor): the new owner gets NO defender spawns, the
// previous owner counter-attacks to win it back, and if the new owner leaves/dies inside the
// marker reverts to the previous owner. Only after holding for 10 minutes is the capture final.
MISSION_CORE_fnc_captureMarkerForPlayers = {
    params ["_locName", "_locPos", "_owner", "_importance"];
    private _playerSide = if (_owner == WEST) then { EAST } else { WEST };
    if (isNil "MISSION_CORE_OCCUPATION") then { MISSION_CORE_OCCUPATION = createHashMap; };
    if (isNil "MISSION_CORE_MANPOWER") then { MISSION_CORE_MANPOWER = createHashMap; };
    if (isNil "MISSION_CORE_COMMIT") then { MISSION_CORE_COMMIT = createHashMap; };
    if (isNil "MISSION_CORE_MANPOWER_CUTOFF") then { MISSION_CORE_MANPOWER_CUTOFF = createHashMap; };

    // Ownership flips to the attacker immediately (cached positions + locations + marker color).
    [_locName, _playerSide] call MISSION_CORE_fnc_setMarkerOwner;

    // PERMANENT RULE: a freshly captured marker stays EMPTY of the capturer's own garrison until
    // the capturing player moves OUT of it and back IN. The proximity spawner honors this flag so
    // "my team" never materializes around the player the moment they take the marker.
    if (isNil "MISSION_CORE_CAPTURE_SUPPRESSED") then { MISSION_CORE_CAPTURE_SUPPRESSED = createHashMap; };
    MISSION_CORE_CAPTURE_SUPPRESSED set [_locName, true];

    // The side that lost this marker treats it as a RETARGET, so its garrison counter-attacks to
    // win the base back (it no longer matches getContestedMarkers' "owned by us" filter).
    if (isNil "MISSION_CORE_CAPTURED_RETAKE") then { MISSION_CORE_CAPTURED_RETAKE = createHashMap; };
    MISSION_CORE_CAPTURED_RETAKE set [_locName, [_owner, time]];

    // Enter the occupation (hold) phase: occupier, previous owner, occupied-at timestamp.
    MISSION_CORE_OCCUPATION set [_locName, [_playerSide, _owner, time]];
    // Wake the occupation monitor (no-op if it is already running).
    [] spawn MISSION_CORE_fnc_occupationMonitor;

    // The occupied marker stops resupplying/spawning from its own supply while it is held.
    MISSION_CORE_MANPOWER set [_locName, []];
    MISSION_CORE_COMMIT set [_locName, 0];
    MISSION_CORE_MANPOWER_CUTOFF deleteAt _locName;

    // The marker keeps its spawn slot even after capture (its reinforcement effort "gave up") -
    // only despawn (player moves away) frees it, so no fresh marker takes its place before then.

    // Drop queued counter-attack / reinforce spawns still targeting the occupied marker.
    if (isNil "MISSION_CORE_SPAWN_QUEUE") then { MISSION_CORE_SPAWN_QUEUE = []; };
    private _kept = [];
    {
        private _tpos = [0, 0, 0];
        switch (_x select 0) do {
            case "MISSION_CORE_fnc_queuedCounterAttackInf": { _tpos = (_x select 2) param [8, [0,0,0]]; };
            case "MISSION_CORE_fnc_queuedCounterAttackTank": { _tpos = (_x select 2) param [8, [0,0,0]]; };
            case "MISSION_CORE_fnc_queuedReinforce": { _tpos = (_x select 2) param [5, [0,0,0]]; };
        };
        if (count _tpos > 0 && { _tpos distance _locPos < 500 }) then {
            diag_log format ["DYNAMIC CAPTURE: dropped queued %1 (target %2 occupied)", _x select 0, _locName];
        } else {
            _kept pushBack _x;
        };
    } forEach MISSION_CORE_SPAWN_QUEUE;
    MISSION_CORE_SPAWN_QUEUE = _kept;

    diag_log format ["DYNAMIC CAPTURE: %1 occupied by %2 (garrison wiped) - hold 10min to secure", _locName, _playerSide];
    ["DynOps_MarkerOccupied",
        ["MARKER OCCUPIED", format ["%1 occupied - hold it for 10 minutes to secure it!", _locName]]
    ] remoteExec ["BIS_fnc_showNotification", 0];
};
