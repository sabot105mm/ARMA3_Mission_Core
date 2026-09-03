
// Commit every already-spawned group of the defending side that is within reach of a contested
// marker - IMMEDIATELY, the moment the battle starts. Standing patrols are never held back as if
// queued; each one fast-moves to the marker edge and then search-and-destroys the center. This is
// the same behavior as the HQ alert (all groups converge at once), routed through sendCounterAttack
// so foot squads ride trucks and vehicle crews keep fighting from their mounts.
MISSION_CORE_fnc_commitToBattle = {
    params ["_side", "_targetPos", "_targetSize", ["_radius", 4000]];
    private _sideVar = if (_side == WEST) then { "MISSION_CORE_BLUFOR" } else { "MISSION_CORE_REDFOR" };
    private _players = allPlayers select { alive _x };
    if (count _players == 0) exitWith { 0 };
    // Contested markers = the side's markers a player is actively attacking. A player can attack
    // several markers at once. Every eligible group is committed to a contested marker so that
    // far-out foot patrols board trucks and ride to the fight too - not just groups already
    // inside the contested area. Markers within 1500m of the group are preferred, and among the
    // preferred ones the marker closest to a player wins.
    private _contested = [_side] call MISSION_CORE_fnc_getContestedMarkers;
    if (count _contested == 0) exitWith { 0 };
    private _bestGlobal = _contested select 0;
    private _globalPDist = 1e10;
    {
        private _mPos = _x select 1;
        private _pd = 1e10;
        { private _d = _x distance _mPos; if (_d < _pd) then { _pd = _d; }; } forEach _players;
        if (_pd < _globalPDist) then { _globalPDist = _pd; _bestGlobal = _x; };
    } forEach _contested;
    private _count = 0;
    private _footCount = 0;
    {
        private _grp = _x;
        if (!isNull _grp &&
            { count units _grp > 0 } &&
            { _grp getVariable [_sideVar, false] } &&
            { !(_grp getVariable ["MISSION_CORE_AA_DEFENSE", false]) } &&
            { !(_grp getVariable ["MISSION_CORE_DEFENSE_GROUP", false]) } &&
            { (_grp getVariable ["MISSION_CORE_ORDER", ""]) in ["", "defend", "engage", "attack", "counterattack", "reinforce"] }) then {
            private _gPos = getPos leader _grp;
            // PERMANENT RULE: a group that spawned from a contested zone defends ITS OWN fight -
            // never march a zone's garrison to a DIFFERENT contested zone. If this group's origin
            // marker is itself a contested zone, that zone is its target.
            private _ownZone = [];
            private _ownName = _grp getVariable ["MISSION_CORE_ORIGIN_MARKER", ""];
            if (_ownName != "") then {
                _ownZone = _contested select { (_x select 0) == _ownName } param [0, []];
            };
            // Preferred: the contested marker closest to a player among those within 1500m of the
            // group. Fallback: the overall contested marker closest to a player (far patrols).
            private _bestMkr = if (count _ownZone > 0) then { _ownZone } else { _bestGlobal };
            private _bestPDist = if (count _ownZone > 0) then { -1 } else { _globalPDist };
            // Own-zone groups never get re-assigned to a different contested marker - they defend
            // their own fight.
            if (count _ownZone == 0) then {
                {
                    private _mPos = _x select 1;
                    if (_gPos distance _mPos <= 1500) then {
                        private _pDist = 1e10;
                        { private _pd = _x distance _mPos; if (_pd < _pDist) then { _pDist = _pd; }; } forEach _players;
                        if (_pDist < _bestPDist) then { _bestPDist = _pDist; _bestMkr = _x; };
                    };
                } forEach _contested;
            };
            if (count _bestMkr > 0) then {
                // Already counter-attacking this exact marker: leave it alone. Without this guard
                // the battle loop re-issues the assault every tick and yanks the group's waypoints
                // back and forth with the armor loop.
                private _cur = _grp getVariable ["MISSION_CORE_ORDER", ""];
                private _at = _grp getVariable ["MISSION_CORE_ATTACK_TARGET", [0, 0, 0]];
                if (_cur == "counterattack" && { (_bestMkr select 1) distance _at < 200 }) then { continue; };
                if ({ vehicle _x == _x } count units _grp == count units _grp) then { _footCount = _footCount + 1; };
                [_grp, _bestMkr select 1, _bestMkr select 2] call MISSION_CORE_fnc_sendCounterAttack;
                diag_log format ["AI COMMANDER: committed %1 to contested %2", groupId _grp, _bestMkr select 0];
                _count = _count + 1;
            };
        };
    } forEach allGroups;
    if (_count > 0) then {
        diag_log format ["AI COMMANDER: committed %1 existing groups (%2 foot) to battle", _count, _footCount];
    };
    _count
};
