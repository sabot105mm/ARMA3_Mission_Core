// -------------------------------------------------------------------
// DEFEND GATE - the single source of truth for "is this friendly marker under attack?"
//
// The old rules fired DEFEND on (a) any faction that OCCUPIED a hostile marker (its garrison
// dropped everything to "hold" the zone) or (b) any ENEMY UNIT - attacker or idle patrol - passing
// within objHouseThreatRadius of the marker. Both misfired: a captured zone sat permanently in
// DEFEND, and a stray patrol walking past a friendly marker flipped its owner's whole objective
// onto the defensive.
//
// A marker is defended ONLY when a hostile ASSAULT-CLASSIFIED group leader is inside a 2x-scaled
// copy of the marker's real shape (ELLIPSE or RECTANGLE, same center + rotation). "Assault-
// classified" = the group carries an attack/counterattack order, is flagged as an assault group,
// or is tracked as an active released assault squad in MISSION_CORE_ATTACK_GROUPS. Patrols,
// holds and idle squads NEVER trigger the gate - no leader, no order, no friends - the gate fires
// on a real, directed attack on the marker only.
//
// The same gate drives the AI commander's BLUFOR defender reaction (fn_aiCommanderLoop BLU
// DEFEND block) and the player-facing objective director, so a note can never fire for one but
// not the other.
// -------------------------------------------------------------------

if (isNil "MISSION_CORE_MARKER_GEOMETRY_CACHE") then { MISSION_CORE_MARKER_GEOMETRY_CACHE = createHashMap; };

// Resolve a marker's REAL geometry [pos, sizeA, sizeB, dir, shape] from MISSION_CORE_LOCATIONS
// (the authoritative map of every location; area is [pos, [a,b], dir, "ELLIPSE"/"RECTANGLE"]).
// CACHED_POSITIONS has no size, so the legacy getMarkerShape falls back to a fixed 200m ellipse.
// Cached once per marker name - these entries never change mid-session.
MISSION_CORE_fnc_getMarkerGeometry = {
    params ["_markerName"];
    private _g = MISSION_CORE_MARKER_GEOMETRY_CACHE getOrDefault [_markerName, []];
    if (count _g == 5) exitWith { _g };
    private _r = [[0, 0, 0], 200, 200, 0, "ELLIPSE"];
    if (!isNil "MISSION_CORE_LOCATIONS" && { count MISSION_CORE_LOCATIONS > 0 }) then {
        private _idx = MISSION_CORE_LOCATIONS findIf { (_x select 0) == _markerName };
        if (_idx >= 0) then {
            private _area = (MISSION_CORE_LOCATIONS select _idx) select 1;
            if (count _area >= 3) then {
                private _sz = _area select 1;
                private _a = if (count _sz > 0) then { (_sz select 0) max 1 } else { 200 };
                private _b = if (count _sz > 1) then { (_sz select 1) max 1 } else { _a };
                private _dir = _area select 2;
                private _shape = if (count _area > 3) then { toUpper (_area select 3) } else { "ELLIPSE" };
                if (_shape != "RECTANGLE") then { _shape = "ELLIPSE"; };
                _r = [_area select 0, _a, _b, _dir, _shape];
            };
        };
    };
    MISSION_CORE_MARKER_GEOMETRY_CACHE set [_markerName, _r];
    _r
};

// Shape-aware point-in-marker test honoring the marker's real shape and rotation, with an optional
// scale multiplier on both half-extents. RECTANGLE uses a rotated box test; ELLIPSE (and any unknown
// shape) uses the rotated ellipse equation - mirrors fn_portSystem / fn_quadrantEngage.
MISSION_CORE_fnc_pointInGeometry = {
    params ["_point", "_geom", ["_scale", 1]];
    private _pos = _geom select 0;
    private _a = (_geom select 1) * _scale;
    private _b = (_geom select 2) * _scale;
    private _dir = _geom select 3;
    private _shape = _geom select 4;
    private _dx = (_point select 0) - (_pos select 0);
    private _dy = (_point select 1) - (_pos select 1);
    private _rx = _dx * cos _dir - _dy * sin _dir;
    private _ry = _dx * sin _dir + _dy * cos _dir;
    if (_shape == "RECTANGLE") exitWith { abs _rx <= _a && { abs _ry <= _b } };
    ((_rx * _rx) / (_a * _a) + (_ry * _ry) / (_b * _b)) <= 1
};

// Is this group an ASSAULT-CLASSIFIED group? A group counts once it carries an attack / counter-
// attack order, is flagged as an assault group, or is an active released assault squad in
// MISSION_CORE_ATTACK_GROUPS. Used by the defend gate so only real directed attacks trip DEFEND.
MISSION_CORE_fnc_isAssaultClassified = {
    params ["_grp"];
    if (isNull _grp) exitWith { false };
    private _o = _grp getVariable ["MISSION_CORE_ORDER", ""];
    if (_o == "attack" || { _o == "counterattack" }) exitWith { true };
    if (_grp getVariable ["MISSION_CORE_ASSAULT_GROUP", false]) exitWith { true };
    if (!isNil "MISSION_CORE_ATTACK_GROUPS" && { count MISSION_CORE_ATTACK_GROUPS > 0 }) then {
        private _matched = false;
        {
            private _entry = _y;
            if ((_entry select 0) == _grp) exitWith { _matched = true; };
        } forEach MISSION_CORE_ATTACK_GROUPS;
        if (_matched) exitWith { true };
    };
    false
};

// THE GATE. True when any hostile (owner-side enemy) assault-classified group leader is inside a
// 2x-scaled copy of the marker's real shape. _groupsPool is an optional pre-snapshot of allGroups
// for callers that already own one (the AI loop snapshots once per tick); when empty, allGroups is
// fetched here. The gate is deliberately side-aware and group-type-aware: friends never trip it,
// and a patrol / garrison / hold never trips it - only a directed assault does.
MISSION_CORE_fnc_defendGate = {
    params ["_markerName", "_ownerSide", ["_groupsPool", []]];
    private _geom = [_markerName] call MISSION_CORE_fnc_getMarkerGeometry;
    private _pool = if (count _groupsPool == 0) then { allGroups } else { _groupsPool };
    private _hit = false;
    {
        private _grp = _x;
        if (isNull _grp) then { continue; };
        if (count units _grp == 0) then { continue; };
        if (side _grp getFriend _ownerSide >= 0.6) then { continue; };
        if !([_grp] call MISSION_CORE_fnc_isAssaultClassified) then { continue; };
        private _ldr = leader _grp;
        if (isNull _ldr) then { continue; };
        if !(alive _ldr) then { continue; };
        if ([getPos _ldr, _geom, 2] call MISSION_CORE_fnc_pointInGeometry) exitWith { _hit = true; };
    } forEach _pool;
    _hit
};