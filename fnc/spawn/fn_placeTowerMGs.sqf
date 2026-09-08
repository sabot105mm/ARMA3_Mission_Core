// Place static defenders on military cargo structures inside a marker:
//   - RAISED BUNKER / BARRIER TOWERS (Land_BagBunker_Tower_F, Land_HBarrierTower_F, etc): an HMG +
//     gunner on the top roof deck. Cargo towers are NOT handled here - the house-occupation system
//     mans those with up to 8 top-deck guards facing the player.
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
    private _r = ((_targetSize select 0) max (_targetSize select 1)) * 1.2;
    // Match structures by BOTH their display name and their model (class) name, so editor-placed
    // watchtowers/bunkers (H-barrier tower, bag-bunker tower, sandbag towers, bag bunkers) are found
    // and manned even when the class string differs from the on-map label. Raised towers get the
    // rooftop HMG pair; bunkers / cargo patrol mounts / guard posts get a pinned lookout-gunner.
    private _towerPats = ["cargo_tower", "cargo tower", "watchtower", "watch_tower", "watch tower", "guardtower", "guard_tower", "guard tower", "patroltower", "patrol_tower", "patrol tower", "hbarriertower", "h_barrier_tower", "hbarrier tower", "h-barrier tower", "hesco tower", "hesco_tower", "bagbunker_tower", "bag_bunker_tower", "bag-bunker tower", "sandbag tower", "sandbag_tower", "bunkertower", "bunker_tower", "bunker tower", "fort_watchtower", "fortress_watchtower", "fortress watchtower"];
    private _postPats = ["cargo_patrol", "cargo patrol", "cargo_post", "cargo post", "guardpost", "guard_post", "guard post", "bagbunker", "bag_bunker", "bag-bunker", "bag bunker", "sandbag bunker", "bunker"];
    // Bag-bunker / sandbag-bunker models face 180deg AWAY from the way a man stands in them: when the
    // editor rotates one "to face the attacker", the embrasure actually points back. Guards posted on
    // such structures must therefore be turned 180deg against the structure's own direction.
    private _bunkerPats = ["bagbunker", "bag_bunker", "bag-bunker", "bag bunker", "sandbag bunker", "bunker"];
    private _matches = {
        params ["_b", "_pats"];
        private _t = toLower (typeOf _b);
        private _dn = toLower (getText (configFile >> "CfgVehicles" >> typeOf _b >> "displayName"));
        _pats findIf { (_t find _x) > -1 || { (_dn find _x) > -1 } } != -1
    };
    private _towers = nearestObjects [_targetPos, ["House", "Building", "Strategic", "Fortress"], _r] select {
        private _b = _x;
        // Cargo towers are manned by the house-occupation system (up to 8 top-deck guards facing
        // the player) - they get NO rooftop HMGs here. This pass owns raised bunker/barrier towers
        // (Land_BagBunker_Tower_F, Land_HBarrierTower_F) and big cargo HMG decks on other structures.
        if (_b isKindOf "Land_Cargo_Tower_base_F") then { false } else {
            // Cargo patrol posts (Land_Cargo_Patrol_V1/V2_F) are the small raised guard towers - their
            // display name reads "Cargo Tower", so keep them OUT of the HMG-tower pass by class. The
            // tower pass owns raised bunker/barrier towers too (Land_BagBunker_Tower_F, Land_HBarrierTower_F).
            private _t = toLower (typeOf _b);
            if (_t find "cargo_patrol" > -1 || { _t find "cargo_post" > -1 }) then { false } else { [_b, _towerPats] call _matches }
        }
    };
    // Bunkers / cargo patrol mounts / guard posts: a pinned lookout or gunner, never also a tower.
    private _posts = nearestObjects [_targetPos, ["House", "Building", "Strategic", "Fortress"], _r] select {
        private _b = _x;
        if (_b in _towers) then { false } else { [_b, _postPats] call _matches }
    };
    if (count _towers == 0 && { count _posts == 0 }) exitWith { 0 };
    private _defGroup = createGroup _side;
    // Tower MG gunners AND cargo-post lookouts are all the faction's proper riflemen, not crew.
    private _unitPool = [_factionData, _side] call MISSION_CORE_fnc_factionRiflemen;
    private _placed = 0;
    // Top deck of a structure: prefer buildingPos (highest positions), fall back to the bounding-box
    // top center for editor towers with no buildingPos slots (Land_HBarrierTower_F has none).
    private _getTop = {
        params ["_b"];
        private _posList = [];
        for "_i" from 0 to 39 do {
            private _p = _b buildingPos _i;
            if (isNil "_p" || { _p isEqualTo [0, 0, 0] }) exitWith {};
            _posList pushBack _p;
        };
        if (count _posList == 0) then {
            private _bb = boundingBoxReal _b;
            private _topZ = (_bb select 1) select 2;
            private _c = getPosATL _b;
            _posList pushBack [_c select 0, _c select 1, (_c select 2) + _topZ];
        };
        private _top = [];
        private _maxZ = -1e10;
        {
            private _z = _x select 2;
            if (_z > _maxZ) then { _maxZ = _z; _top = [_x]; }
            else { if (abs (_z - _maxZ) < 0.5) then { _top pushBack _x; }; };
        } forEach _posList;
        if (count _top == 0) then { _top = [+(_posList select 0)]; };
        _top
    };
    {
        private _b = _x;
        if (_b getVariable ["MISSION_CORE_TOWER_ARMED", false]) then { continue; };
        private _top = [_b] call _getTop;
        if (count _top == 0) then { continue; };
        private _count = 2 min (count _top);
        if (count _hmgPool == 0) then { _count = 1; };
        for "_i" from 0 to (_count - 1) do {
            private _deckPos = _top select _i;
            if (count _hmgPool > 0) then {
                private _wep = createVehicle [selectRandom _hmgPool, _deckPos, [], 0, "CAN_COLLIDE"];
                _wep setPosATL [_deckPos select 0, _deckPos select 1, (_deckPos select 2) + 0.15];
                _wep setDir ((getDir _b + 180) mod 360);
                //_wep setVectorUp [0, 0, 1];
                // visual=false attaches in SIMULATION scope (not the default render scope), so the AI gunner
                // sees the weapon as a real vehicle it can aim/operate - render-scope attachment makes
                // gunners twitch and refuse to target while players can still mount it.
                //[_wep, _b, false] call BIS_fnc_attachToRelative;
                _defGroup addVehicle _wep;
                private _gunner = _defGroup createUnit [selectRandom _unitPool, _deckPos, [], 0, "NONE"];
                _gunner moveInGunner _wep;
            } else {
                // No HMG in the faction pool - post a pinned lookout on the deck instead.
                private _tDir = getDir _b;
                if ([_b, _bunkerPats] call _matches) then { _tDir = (_tDir + 180) mod 360; };
                private _lookout = _defGroup createUnit [selectRandom _unitPool, _deckPos, [], 0, "NONE"];
                _lookout setPosATL _deckPos;
                _lookout setDir _tDir;
                _lookout setUnitPos "UP";
                _lookout setBehaviour "SAFE";
                _lookout setCombatMode "RED";
                _lookout disableAI "PATH";
            };
            _placed = _placed + 1;
        };
        _b setVariable ["MISSION_CORE_TOWER_ARMED", true];
    } forEach _towers;
    // Cargo posts: one pinned lookout on the top platform.
    {
        private _b = _x;
        if (_b getVariable ["MISSION_CORE_TOWER_ARMED", false]) then { continue; };
        if (_b isKindOf "Land_Cargo_Patrol_base_F") then {
            // Cargo patrol tower: stand a foot OFF the platform center, facing away from the
            // structure's own door facing (bunkers/towers point INTO the field, the man stands
            // looking out over the parapet). Offset replaces a buildingPos exactly on the ladder.
            private _cargoDir = (getDir _b) - 180;
            private _soldier = _defGroup createUnit [selectRandom _unitPool, getPosATL _b, [], 0, "NONE"];
            _soldier setPosATL (_b buildingPos 1);
            _soldier setDir _cargoDir;
            private _basePos = getPosATL _soldier;
            private _pos = _basePos getPos [2.5, _cargoDir] getPos [-1, _cargoDir + 90];
            _pos set [2, _basePos select 2];
            _soldier setPosATL _pos;
            _soldier disableAI "PATH";
            // SAFE + RED: the lookouts are POSTED, not careless - they hold their post, watch the
            // approach, and only engage/return fire. disableAI "PATH" pins them in place so they stay
            // on the platform instead of strolling down the ladder during gaps in the alert cycle.
            _soldier setBehaviour "SAFE";
            _soldier setCombatMode "RED";
        } else {
            private _top = [_b] call _getTop;
            if (count _top == 0) then { continue; };
            private _topPos = +(_top select 0);
            _topPos set [2, (_topPos select 2) + 0.1];
            private _bDir = getDir _b;
            if ([_b, _bunkerPats] call _matches) then { _bDir = (_bDir + 180) mod 360; };
            private _spot = (_topPos getPos [1, _bDir]) getPos [0.3, _bDir - 90];
            private _soldier = _defGroup createUnit [selectRandom _unitPool, _spot, [], 0, "NONE"];
            _soldier setPosATL _spot;
            _soldier setDir _bDir;
            _soldier setUnitPos "UP";
            _soldier setBehaviour "SAFE";
            _soldier setCombatMode "RED";
            _soldier disableAI "PATH";
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
