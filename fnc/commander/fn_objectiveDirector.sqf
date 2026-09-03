//
// OBJECTIVE DIRECTOR - gives BLUFOR players attack / defend objectives.
//
// For every alive player it maintains ONE objective (the closest enemy marker to attack, or the
// closest BLUFOR marker that is under attack to defend - defend wins over attack when the player's
// own side is threatened). The objective is shown as:
//   - a map marker (DynOpsObj_<uid>) on the target
//   - an official notification box when it changes
//   - a systemChat line when the player draws near an enemy marker ("attack note")
//
// REDFOR never gets objectives here (it has its own commander behaviors).

// Build [title, typeBadge, accentRGB, structuredText] for the intel panel describing a marker's
// function + why to take it. accentRGB tints the panel's title bar / edge by marker type.
MISSION_CORE_fnc_intelBlurb = {
    params ["_loc"];
    private _mName = _loc select 0;
    private _type = toLower (_loc select 2);
    private _label = [_mName] call MISSION_CORE_fnc_getLocationLabel;
    private _imp = _loc select 7;

    // Special power-source detection so factories/power infrastructure explain the tank economy.
    private _isPower = [_loc] call MISSION_CORE_fnc_isPowerplant;
    private _isSolar = [_loc] call MISSION_CORE_fnc_isSolarPlant;
    private _isFactory = _type find "factory" > -1;

    private _title = _label;
    private _badge = "ENEMY POSITION";
    private _accent = [0.9,0.55,0.2,1];   // default orange
    private _body = "";
    private _gBonus = ["powerplantGlobalBonus", 0.2] call MISSION_CORE_fnc_tune;
    private _nBonus = ["powerplantNeighborBonus", 0.5] call MISSION_CORE_fnc_tune;

    if (_isPower) then {
        _title = format ["POWER PLANT - %1", _label];
        _badge = "POWER INFRASTRUCTURE";
        _accent = [0.95,0.82,0.20,1];
        _body = format ["<t color='#ffd24a'>Function:</t> generates power that speeds up tank factories.<br/>Each power plant you hold adds <t color='#7ee07e'>+%1x</t> tank production to EVERY factory on your side, and +%2x to a factory within %3m.<br/><br/><t color='#ff9a9a'>Why take it:</t> starves the enemy of armor; feeds your own.", _gBonus, _nBonus, (["powerplantNeighborRange", 1500] call MISSION_CORE_fnc_tune)];
    } else {
        if (_isSolar) then {
            _title = format ["SOLAR PLANT - %1", _label];
            _badge = "POWER INFRASTRUCTURE";
            _accent = [0.95,0.82,0.20,1];
            _body = format ["<t color='#ffd24a'>Function:</t> a smaller power source - worth <t color='#7ee07e'>%1x</t> of a full power plant toward tank production.<br/><br/><t color='#ff9a9a'>Why take it:</t> a cheaper way to boost your factory output.", (["solarContribution", 0.25] call MISSION_CORE_fnc_tune)];
        } else {
            switch (true) do {
                case (_type == "hq"): {
                    _badge = "COMMAND & LOGISTICS";
                    _accent = [0.85,0.2,0.2,1];
                    _body = "<t color='#ffd24a'>Function:</t> command & logistics center - the enemy's heaviest garrison and armor park.<br/><br/><t color='#ff9a9a'>Why take it:</t> cripples enemy command; captures their strongest base.";
                };
                case (_isFactory): {
                    _badge = "WAR PRODUCTION";
                    _accent = [0.85,0.5,0.15,1];
                    _body = "<t color='#ffd24a'>Function:</t> builds tanks into local storage, convoys them to bases and to markers that request armor.<br/><br/><t color='#ff9a9a'>Why take it:</t> stops enemy tank production entirely at this source.";
                };
                case (_type == "port"): {
                    _badge = "NAVAL PORT";
                    _accent = [0.2,0.55,0.75,1];
                    _body = "<t color='#ffd24a'>Function:</t> naval port - generates manpower and ships it to bases, which distribute it to markers that request men.<br/><br/><t color='#ff9a9a'>Why take it:</t> cuts the enemy's manpower supply chain at its source.";
                };
                case (_type == "depot"): {
                    _badge = "SUPPLY DEPOT";
                    _accent = [0.4,0.6,0.85,1];
                    _body = "<t color='#ffd24a'>Function:</t> warehouse holding a reserve tank battery; feeds convoy/order routing.<br/><br/><t color='#ff9a9a'>Why take it:</t> steals their stockpile and their resupply hub.";
                };
                case (_type == "base"): {
                    _badge = "MILITARY BASE";
                    _accent = [0.8,0.35,0.2,1];
                    _body = "<t color='#ffd24a'>Function:</t> military base - garrisoned armor/infantry and a tank warehouse.<br/><br/><t color='#ff9a9a'>Why take it:</t> denies a fortified spawn point and tank reserve.";
                };
                case (_type == "airfield"): {
                    _badge = "AIRFIELD";
                    _accent = [0.5,0.75,0.9,1];
                    _body = "<t color='#ffd24a'>Function:</t> airfield - air assets and heavy defensive overwatch.<br/><br/><t color='#ff9a9a'>Why take it:</t> removes enemy air support and a high-value position.";
                };
                case (_type == "town"): {
                    _badge = "POPULATION CENTER";
                    _accent = [0.6,0.7,0.4,1];
                    _body = "<t color='#ffd24a'>Function:</t> population center - garrison patrols and manpower.<br/><br/><t color='#ff9a9a'>Why take it:</t> expands your control and cuts enemy manpower.";
                };
                case (_type == "compound"): {
                    _badge = "FORTIFIED COMPOUND";
                    _accent = [0.7,0.55,0.3,1];
                    _body = "<t color='#ffd24a'>Function:</t> fortified compound - patrols and anti-tank teams.<br/><br/><t color='#ff9a9a'>Why take it:</t> a defensible foothold in enemy territory.";
                };
                case (_type == "outpost"): {
                    _badge = "FORWARD OUTPOST";
                    _accent = [0.55,0.7,0.5,1];
                    _body = "<t color='#ffd24a'>Function:</t> small forward outpost - light garrison.<br/><br/><t color='#ff9a9a'>Why take it:</t> cheap early objective and staging point.";
                };
                default {
                    _badge = "ENEMY POSITION";
                    _accent = [0.9,0.55,0.2,1];
                    _body = "<t color='#ffd24a'>Function:</t> enemy-held position with a defending garrison.<br/><br/><t color='#ff9a9a'>Why take it:</t> pushes the front forward and denies the enemy this ground.";
                };
            };
        };
    };
    [_title, _badge, _accent, _body]
};

MISSION_CORE_fnc_objectiveDirector = {
    diag_log "OBJECTIVES: director started";
    if (isNil "MISSION_CORE_PLAYER_OBJECTIVES") then { MISSION_CORE_PLAYER_OBJECTIVES = createHashMap; };
    private _lastNoteAt = createHashMap;   // uid -> time of last "near marker" attack note
    private _intelShownAt = createHashMap; // uid -> marker name currently shown in the intel panel

    while { true } do {
        sleep 10;
        if (isNil "MISSION_CORE_CACHED_POSITIONS") then { continue; };
        // Follow whichever side the player is on (BLUFOR normally, but CIV/Indep in a test must
        // not break the whole objective/intel system).
        private _players = allPlayers select { alive _x };
        if (count _players == 0) then { continue; };

        {
            private _p = _x;
            private _uid = getPlayerUID _p;
            private _pos = getPos _p;
            private _pName = name _p;
            private _pSide = side _p;

            // The closest ENEMY marker: owned by a side hostile to this player, and not occupied.
            private _attackTarget = [];
            private _attackD = 1e10;
            {
                private _mSide = _x select 4;
                if (_pSide getFriend _mSide < 0.6 && { [(_x select 0)] call MISSION_CORE_fnc_isOccupied == false }) then {
                    private _d = (_x select 1) distance2D _pos;
                    if (_d < _attackD) then { _attackD = _d; _attackTarget = _x; };
                };
            } forEach MISSION_CORE_CACHED_POSITIONS;

            // Light nudge: the player's attack objective spawns its garrison the moment they close
            // to 700m, so an objective is always garrisoned on approach (the proximity spawner
            // normally handles this, but a budget-full marker can sit deferred; this guarantees it).
            // Despawn stays on the default proximity-spawner cycle - nothing is overridden there.
            if (count _attackTarget > 0 && { _attackD <= (["proxSpawnRadius", 700] call MISSION_CORE_fnc_tune) }) then {
                private _aName = _attackTarget select 0;
                if (!(MISSION_CORE_SPAWNED_LOCATIONS getOrDefault [_aName, false])) then {
                    private _aIdx = MISSION_CORE_CACHED_POSITIONS findIf { (_x select 0) == _aName };
                    if (_aIdx >= 0) then {
                        MISSION_CORE_SPAWNED_LOCATIONS set [_aName, true];
                        [MISSION_CORE_CACHED_POSITIONS select _aIdx] call MISSION_CORE_fnc_spawnLocation;
                        diag_log format ["OBJECTIVES: nudge-spawned garrison at %1 (player within 700m)", _aName];
                    };
                };
            };

            // The closest FRIENDLY marker that needs DEFENDING: its garrison is under attack by
            // enemy units OR it is an occupied zone being held by this player's side.
            private _defendTarget = [];
            private _defendD = 1e10;
            {
                if ((_x select 4) == _pSide) then {
                    private _mName = _x select 0;
                    private _mPos = _x select 1;
                    private _underAttack = false;
                    // Occupied = a hostile marker captured by this side, still in the hold phase.
                    private _occ = if (isNil "MISSION_CORE_OCCUPATION") then { [] } else { MISSION_CORE_OCCUPATION getOrDefault [_mName, []] };
                    if (count _occ >= 3 && { (_occ select 0) == _pSide }) then { _underAttack = true; };
                    // A friendly marker with a live ENEMY inside/near is under attack.
                    if (!_underAttack) then {
                    private _enemyProbe = allUnits findIf {
                        side _x getFriend _pSide < 0.6 && { alive _x } && { _x distance2D _mPos < (["objHouseThreatRadius", 600] call MISSION_CORE_fnc_tune) }
                    };
                        if (_enemyProbe != -1) then { _underAttack = true; };
                    };
                    if (_underAttack) then {
                        private _d = _mPos distance2D _pos;
                        if (_d < _defendD) then { _defendD = _d; _defendTarget = _x; };
                    };
                };
            } forEach MISSION_CORE_CACHED_POSITIONS;

            // Decide: defend wins when the player's side is directly threatened and close enough
            // to matter (within objDefendRange). Otherwise attack the closest enemy marker.
            private _objective = [];
            if (count _defendTarget > 0 && { _defendD <= (["objDefendRange", 2500] call MISSION_CORE_fnc_tune) }) then {
                _objective = ["DEFEND", _defendTarget];
            } else {
                if (count _attackTarget > 0) then { _objective = ["ATTACK", _attackTarget]; };
            };

            // Build state for this player.
            private _state = if (count _objective == 0) then { ["NONE", "", "", []] } else {
                private _kind = _objective select 0;
                private _tgt = _objective select 1;
                private _mName = _tgt select 0;
                private _label = [_mName] call MISSION_CORE_fnc_getLocationLabel;
                [_kind, _mName, _label, _tgt select 1]
            };

            // Compare against what the player already has.
            private _prev = MISSION_CORE_PLAYER_OBJECTIVES getOrDefault [_uid, ["NONE", "", "", []]];
            private _changed = (_prev select 0) != (_state select 0) || { (_prev select 1) != (_state select 1) };

            if (_changed) then {
                MISSION_CORE_PLAYER_OBJECTIVES set [_uid, _state];
                // Clear any previous objective marker for this player.
                private _oldMk = format ["DynOpsObj_%1", _uid];
                if (_oldMk in allMapMarkers) then { deleteMarker _oldMk; };
                if ((_state select 0) != "NONE" && { (_state select 0) != "CLEAR" }) then {
                    private _mk = createMarker [_oldMk, _state select 3];
                    _mk setMarkerShape "ICON";
                    _mk setMarkerType "mil_objective";
                    _mk setMarkerColor (if ((_state select 0) == "DEFEND") then { "ColorRed" } else { "ColorOrange" });
                    _mk setMarkerSize [1, 1];
                    _mk setMarkerAlpha 0.9;
                    _mk setMarkerText (format ["%1 %2", _state select 0, _state select 2]);
                    // Objective notification - official box.
                    private _tmpl = if ((_state select 0) == "DEFEND") then { "DynOps_ObjectiveDefend" } else { "DynOps_ObjectiveAttack" };
                    [_tmpl, [_state select 0, format ["%1 %2", _state select 0, _state select 2]]] remoteExec ["BIS_fnc_showNotification", 0];
                };
            };

            // Attack note: when a player draws near an enemy marker, give an "attack" note
            // (throttled to once per objNoteCooldown per player so it doesn't spam).
            if (count _attackTarget > 0 && { _attackD < (["objAttackNoteRange", 1500] call MISSION_CORE_fnc_tune) }) then {
                private _lastNote = _lastNoteAt getOrDefault [_uid, -99999];
                if (time - _lastNote > (["objNoteCooldown", 300] call MISSION_CORE_fnc_tune)) then {
                    _lastNoteAt set [_uid, time];
                    private _label = [_attackTarget select 0] call MISSION_CORE_fnc_getLocationLabel;
                    ["DynOps_ObjectiveAttack", ["ATTACK!", format ["Hostile position at %1 is ahead.", _label]]] remoteExec ["BIS_fnc_showNotification", 0];
                    [format ["ATTACK: %1 is %2m ahead - move in!", _label, round _attackD]] remoteExec ["systemChat", 0];
                };
            };

            // Intel: when a player approaches an enemy marker they have not taken, show the
            // built-in notification box (Antistasi-style, slides in on the right) explaining the
            // marker's function + why to capture it. Re-shown every approach (throttled by the
            // _intelShownAt marker-change guard, so a NEW marker pops immediately).
            private _intelRange = ["intelApproachRange", 400] call MISSION_CORE_fnc_tune;
            private _intelTarget = if (count _attackTarget > 0 && { _attackD <= _intelRange }) then { _attackTarget } else { [] };
            if (count _intelTarget > 0) then {
                private _mName = _intelTarget select 0;
                private _shownNow = _intelShownAt getOrDefault [_uid, ""];
                if (_shownNow != _mName) then {
                    _intelShownAt set [_uid, _mName];
                    private _blurb = [_intelTarget] call MISSION_CORE_fnc_intelBlurb;
                    ["DynOps_Intel", [_blurb select 0, _blurb select 3]] remoteExec ["BIS_fnc_showNotification", 0];
                };
            } else {
                if (_intelShownAt getOrDefault [_uid, ""] != "") then {
                    _intelShownAt set [_uid, ""];
                };
            };
        } forEach _players;
    };
};
