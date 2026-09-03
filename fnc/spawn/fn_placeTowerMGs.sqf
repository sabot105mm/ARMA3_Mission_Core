// Place static defenders on military cargo structures inside a marker:
//   - CARGO TOWERS (Land_Cargo_Tower_*): an HMG + gunner on the top roof deck (cross-fire pair).
//   - CARGO PATROL POSTS (Land_Cargo_Patrol_V1/V2_F, Land_Cargo_Post_*): a pinned lookout soldier
//     on the top platform (no weapon mount, but he engages/spotlights from the high ground). Uses
//     the defense spawn group + faction unit pool.
// Called from spawnDefenses when a marker arms its defenses. Structures already armed (marked via
// MISSION_CORE_TOWER_ARMED) are skipped so re-spawning defenses never stacks defenders.
MISSION_CORE_fnc_placeTowerMGs = {
    params ["_targetPos", "_targetSize", "_side", "_factionData"];
    private _hmgPool = (_factionData select 9) getOrDefault ["hmg", []];
    // Tower guns use the HIGH tripod mount (HMG_01_high_F) so they cover over the parapet. Falls
    // back to the full pool if a faction defines no high variant.
    private _highHmg = _hmgPool select {
        (toLower _x) find "hmg" > -1 &&
        { (toLower _x) find "high" > -1 }
    };
    if (count _highHmg > 0) then { _hmgPool = _highHmg; };
    if (count _hmgPool == 0) exitWith { 0 };
    private _r = ((_targetSize select 0) max (_targetSize select 1)) * 1.2;
    private _towers = nearestObjects [_targetPos, ["House", "Building"], _r] select {
        _x isKindOf "Land_Cargo_Tower_base_F" || { (toLower (typeOf _x)) find "cargo_tower" > -1 }
    };
    // Cargo patrol mounts (Land_Cargo_Patrol_V1/V2_F) and cargo post towers (Land_Cargo_Post_*)
    // - the small raised guard towers. The class string is "cargo_patrol", not "cargo_post".
    private _posts = nearestObjects [_targetPos, ["House", "Building"], _r] select {
        private _t = toLower (typeOf _x);
        _t find "cargo_patrol" > -1 || { _t find "cargo_post" > -1 }
    };
    if (count _towers == 0 && { count _posts == 0 }) exitWith { 0 };
    private _defGroup = createGroup _side;
    // Tower MG gunners AND cargo-post lookouts are all the faction's proper riflemen, not crew.
    private _unitPool = [_factionData, _side] call MISSION_CORE_fnc_factionRiflemen;
    private _placed = 0;
    {
        private _b = _x;
        if (_b getVariable ["MISSION_CORE_TOWER_ARMED", false]) then { continue; };
        // Collect building positions until the first empty one (buildingPos _i -> [0,0,0] when the
        // index is past the last position). A cargo tower has a bounded set, so a hard cap is safe.
        private _posList = [];
        for "_i" from 0 to 39 do {
            private _p = _b buildingPos _i;
            if (isNil "_p" || { _p isEqualTo [0, 0, 0] }) exitWith {};
            _posList pushBack _p;
        };
        if (count _posList == 0) then { continue; };
        // Highest building positions = the roof. The top floor has several positions at the same
        // (max) height; pick up to two of them for a cross-fire pair.
        private _top = [];
        private _maxZ = -1e10;
        {
            private _z = _x select 2;
            if (_z > _maxZ) then { _maxZ = _z; _top = [_x]; }
            else { if (abs (_z - _maxZ) < 0.5) then { _top pushBack _x; }; };
        } forEach _posList;
        if (count _top == 0) then { continue; };
        private _count = 2 min (count _top);
        for "_i" from 0 to (_count - 1) do {
            // buildingPos is the deck's feet-level ATL point; parking the pivot there seats the
            // tripod on the slab. A 6-inch (0.15m) lift keeps the model out of the surface without
            // floating it - no physics drop, no bbox offsets, no attachTo (its offset is the object
            // CENTER in the parent's model space).
            private _deckPos = _top select _i;
            private _wep = createVehicle [selectRandom _hmgPool, _deckPos, [], 0, "CAN_COLLIDE"];
            _wep setPosATL [_deckPos select 0, _deckPos select 1, (_deckPos select 2) + 0.15];
            _wep setDir (random 360);
            _wep setVectorUp [0, 0, 1];
            _defGroup addVehicle _wep;
            private _gunner = _defGroup createUnit [selectRandom _unitPool, _deckPos, [], 0, "NONE"];
            _gunner moveInGunner _wep;
            _placed = _placed + 1;
        };
        _b setVariable ["MISSION_CORE_TOWER_ARMED", true];
    } forEach _towers;
    // Cargo posts: one pinned lookout on the top platform.
    {
        private _b = _x;
        if (_b getVariable ["MISSION_CORE_TOWER_ARMED", false]) then { continue; };
        private _posList = [];
        for "_i" from 0 to 39 do {
            private _p = _b buildingPos _i;
            if (isNil "_p" || { _p isEqualTo [0, 0, 0] }) exitWith {};
            _posList pushBack _p;
        };
        if (count _posList == 0) then { continue; };
        private _top = +(_posList select 0);
        private _maxZ = -1e10;
        {
            if ((_x select 2) > _maxZ) then { _maxZ = _x select 2; _top = +_x; };
        } forEach _posList;
        // Slight lift so the soldier stands ON the platform deck, not sunk into it.
        _top set [2, (_top select 2) + 0.1];
        // Face the direction the cargo patrol post itself is facing, standing ~1m forward and a
        // foot (~0.3m) to the left of the top deck position (getPos preserves the lifted altitude).
        private _bDir = getDir _b;
        private _spot = (_top getPos [1, _bDir]) getPos [0.3, _bDir - 90];
        private _soldier = _defGroup createUnit [selectRandom _unitPool, _spot, [], 0, "NONE"];
        _soldier setPosATL _spot;
        _soldier setDir _bDir;
        _soldier setUnitPos "UP";
        // SAFE + RED: the lookouts are POSTED, not careless - they hold their post, watch the
        // approach, and only engage/return fire. disableAI "PATH" pins them in place so they stay
        // on the platform instead of strolling down the ladder during gaps in the alert cycle.
        _soldier setBehaviour "SAFE";
        _soldier setCombatMode "RED";
        _soldier disableAI "PATH";
        _soldier disableAI "AUTOCOMBAT";
        [_soldier, _spot] spawn {
            params ["_s", "_pos"];
            if (isNull _s) exitWith {};
            while { alive _s } do {
                sleep 4;
                if (_s distance2D _pos > 2.5) then { _s setPosATL _pos; };
            };
        };
        _placed = _placed + 1;
        _b setVariable ["MISSION_CORE_TOWER_ARMED", true];
    } forEach _posts;
    if (_placed > 0) then {
        _defGroup setBehaviour "SAFE";
        _defGroup setCombatMode "RED";
        private _isBLU = if (_side == WEST) then { "BLUFOR" } else { "REDFOR" };
        _defGroup setVariable [format ["MISSION_CORE_%1", _isBLU], true];
        _defGroup setVariable ["MISSION_CORE_DEFENSE_GROUP", true];
        _defGroup setVariable ["MISSION_CORE_MARKER_CENTER", _targetPos];
        if (isNil "MISSION_CORE_SPAWNED_GROUPS") then { MISSION_CORE_SPAWNED_GROUPS = []; };
        MISSION_CORE_SPAWNED_GROUPS pushBack _defGroup;
        [_defGroup] spawn MISSION_CORE_fnc_monitorCrew;
        diag_log format ["DYNAMIC DEFENSE: %1 armed %2 tower/post defender(s) at %3", _isBLU, _placed, _targetPos];
    } else {
        deleteGroup _defGroup;
    };
    _placed
};
