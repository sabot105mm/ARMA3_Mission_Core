// ============================================================
// DEFENSE BUILDER (client) - Zeus-style overhead camera builder
// Hotkey (B) opens a free overhead camera with a panel on the
// left. Pick an item from a category. WASD moves the camera,
// mouse drag pans, wheel zooms, left-click places (must be inside
// an owned BLUFOR marker), right-click rotates the ghost, ESC
// exits. Each placement costs defense points and is validated +
// spawned on the server.
// ============================================================

// Build the item catalog from fixed classes + auto-detected faction
// tanks/statics. Each entry:
//   [category, displayName, classOrComposition, spawnType, cost, ghostClass]
MISSION_CORE_fnc_builderItems = {
    private _tanks = if (!isNil "MISSION_CORE_BUILDER_TANKS") then { MISSION_CORE_BUILDER_TANKS } else { [] };
    private _statics = if (!isNil "MISSION_CORE_BUILDER_STATICS") then { MISSION_CORE_BUILDER_STATICS } else { [] };
    private _items = [];
    // Bunkers (compositions placed + crewed)
    _items pushBack ["bunker", "Big Bunker (4x HMG)", "BigBunkerMG", "bunker", 120, "Land_BagBunker_Large_F"];
    _items pushBack ["bunker", "Tall Bunker (HMG)", "TallBunkerMG", "bunker", 100, "Land_BagBunker_Large_F"];
    _items pushBack ["bunker", "Bunker GMG", "BunkerGM", "bunker", 80, "Land_BagBunker_Small_F"];
    _items pushBack ["bunker", "Bunker MG", "BunkerMG_1", "bunker", 60, "Land_BagBunker_Small_F"];
    // Display-name helper (falls back to the class name)
    private _dn = {
        private _n = getText (configFile >> "CfgVehicles" >> _this >> "displayName");
        if (_n == "") then { _n = _this; };
        _n
    };
    // AI tanks: every MBT / APC / AA class the scan found
    { _items pushBack ["tank", format ["Tank: %1", ((_x select 0) call _dn)], _x select 0, "tank", _x select 1, _x select 0]; } forEach _tanks;
    // Emplacements: every static weapon class the scan found
    { _items pushBack ["emplace", format ["Gun: %1", ((_x select 0) call _dn)], _x select 0, "emplace", _x select 1, _x select 0]; } forEach _statics;
    // Barriers
    _items pushBack ["barrier", "Concrete Barrier", "Land_CncBarrier_F", "barrier", 15, "Land_CncBarrier_F"];
    _items pushBack ["barrier", "Concrete Wall", "Land_CncWall1_F", "barrier", 20, "Land_CncWall1_F"];
    _items pushBack ["barrier", "Hesco Wall (5m)", "Land_HBarrier_5_F", "barrier", 25, "Land_HBarrier_5_F"];
    _items pushBack ["barrier", "Hesco Tower", "Land_HBarrierTower_F", "barrier", 40, "Land_HBarrierTower_F"];
    // Sandbags
    _items pushBack ["sandbag", "Sandbag Fence (long)", "Land_BagFence_Long_F", "sandbag", 8, "Land_BagFence_Long_F"];
    _items pushBack ["sandbag", "Sandbag Fence (short)", "Land_BagFence_Short_F", "sandbag", 5, "Land_BagFence_Short_F"];
    _items pushBack ["sandbag", "Sandbag Fence (round)", "Land_BagFence_Round_F", "sandbag", 8, "Land_BagFence_Round_F"];
    _items pushBack ["sandbag", "Sandbag Fence (corner)", "Land_BagFence_Corner_F", "sandbag", 6, "Land_BagFence_Corner_F"];
    _items pushBack ["sandbag", "Sandbag Bunker", "Land_BagBunker_Small_F", "sandbag", 30, "Land_BagBunker_Small_F"];
    _items pushBack ["sandbag", "Sandbag Bunker (large)", "Land_BagBunker_Large_F", "sandbag", 45, "Land_BagBunker_Large_F"];
    _items pushBack ["sandbag", "Sandbag Tower", "Land_BagBunker_Tower_F", "sandbag", 60, "Land_BagBunker_Tower_F"];
    _items
};

MISSION_CORE_fnc_openDefenseBuilder = {
    diag_log "DEFENSE BUILDER: open requested";
    if (dialog) exitWith { diag_log "DEFENSE BUILDER: blocked (a dialog is already open)"; };
    if (isNil "MISSION_CORE_BUILD_ACTIVE") then { MISSION_CORE_BUILD_ACTIVE = false; };
    if (MISSION_CORE_BUILD_ACTIVE) exitWith { diag_log "DEFENSE BUILDER: already active"; };
    if !(alive player) exitWith { hint "You must be alive to build"; diag_log "DEFENSE BUILDER: blocked (player dead)"; };
    if (side player != WEST) exitWith { hint "Only BLUFOR can build defenses"; };
    player allowDamage false;

    MISSION_CORE_BUILD_ACTIVE = true;
    MISSION_CORE_BUILD_TARGET = getPosATL player;
    MISSION_CORE_BUILD_ALT = 100;
    MISSION_CORE_BUILD_CAMAZ = 0;
    MISSION_CORE_BUILD_CAMPITCH = 55;
    MISSION_CORE_BUILD_TARAZ = 0;
    MISSION_CORE_BUILD_TARPITCH = 55;
    MISSION_CORE_BUILD_DIR = 0;
    MISSION_CORE_BUILD_CURSOR = [0, 0, 0];
    MISSION_CORE_BUILD_SEL = nil;
    MISSION_CORE_BUILD_GHOST = objNull;
    MISSION_CORE_BUILD_GHOST_HIDDEN = false;
    MISSION_CORE_BUILD_GHOST_HIDE_POS = [0, 0];
    MISSION_CORE_BUILD_ITEMS = [];
    MISSION_CORE_BUILD_KEY_W = false;
    MISSION_CORE_BUILD_KEY_A = false;
    MISSION_CORE_BUILD_KEY_S = false;
    MISSION_CORE_BUILD_KEY_D = false;
    MISSION_CORE_BUILD_LMB = false;
    MISSION_CORE_BUILD_PRESS_POS = [0, 0];

    // Ask the server to make sure our points are initialized + synced
    [player] remoteExecCall ["MISSION_CORE_fnc_builderSyncPoints", 2];

    disableSerialization;
    createDialog "DYNOPS_DefenseBuilder";
    private _display = findDisplay 1520;
    if (isNull _display) exitWith {
        MISSION_CORE_BUILD_ACTIVE = false;
        player allowDamage true;
    };

    // Free overhead camera
    private _cam = "camera" camCreate [0, 0, 100];
    _cam cameraEffect ["INTERNAL", "BACK"];
    _cam camSetFov 0.4;
    _cam camCommit 0;
    MISSION_CORE_BUILD_CAM = _cam;

    _display displayAddEventHandler ["MouseZChanged", {
        private _z = _this select 1;
        private _alt = MISSION_CORE_BUILD_ALT;
        _alt = (_alt * (1 - _z * 0.1)) max 15 min 2500;
        MISSION_CORE_BUILD_ALT = _alt;
    }];
    // WASD moves the camera target (keyboard pan); holding LMB and dragging also pans. A quick
    // LMB click (no drag) places. Track WASD + LMB state here; movement is applied in the loop.
    _display displayAddEventHandler ["KeyDown", {
        params ["_display", "_dik"];
        switch (_dik) do {
            case 0x11: { MISSION_CORE_BUILD_KEY_W = true; };
            case 0x1E: { MISSION_CORE_BUILD_KEY_A = true; };
            case 0x1F: { MISSION_CORE_BUILD_KEY_S = true; };
            case 0x20: { MISSION_CORE_BUILD_KEY_D = true; };
        };
        false
    }];
    _display displayAddEventHandler ["KeyUp", {
        params ["_display", "_dik"];
        switch (_dik) do {
            case 0x11: { MISSION_CORE_BUILD_KEY_W = false; };
            case 0x1E: { MISSION_CORE_BUILD_KEY_A = false; };
            case 0x1F: { MISSION_CORE_BUILD_KEY_S = false; };
            case 0x20: { MISSION_CORE_BUILD_KEY_D = false; };
        };
        false
    }];
    _display displayAddEventHandler ["MouseButtonDown", {
        params ["_display", "_button"];
        if (_button == 0) then {
            MISSION_CORE_BUILD_LMB = true;
            MISSION_CORE_BUILD_PRESS_POS = getMousePosition;
        };
        if (_button == 1) then {
            MISSION_CORE_BUILD_DIR = (MISSION_CORE_BUILD_DIR + 45) mod 360;
        };
    }];
    // Place on left-click RELEASE when it was a click (cursor barely moved), never a drag. Skip
    // when the cursor is over the left panel (category buttons / item list).
    _display displayAddEventHandler ["MouseButtonUp", {
        params ["_display", "_button"];
        if (_button != 0) exitWith {};
        MISSION_CORE_BUILD_LMB = false;
        private _m = getMousePosition;
        private _p = if (isNil "MISSION_CORE_BUILD_PRESS_POS") then { _m } else { MISSION_CORE_BUILD_PRESS_POS };
        if ((_m distance _p) >= 0.02) exitWith {};
        if ((_m select 0) < 0.25 && { (_m select 1) > 0.1 } && { (_m select 1) < 0.9 }) exitWith {};
        [] call MISSION_CORE_fnc_builderPlace;
    }];

    [] spawn MISSION_CORE_fnc_builderCameraLoop;
    hint "Defense builder open - WASD to move, drag mouse to look around, wheel to zoom, LMB click to place, RMB to rotate, ESC to exit";
};

MISSION_CORE_fnc_builderSelectCategory = {
    params ["_cat"];
    private _all = call MISSION_CORE_fnc_builderItems;
    private _items = _all select { (_x select 0) == _cat };
    MISSION_CORE_BUILD_ITEMS = _items;
    diag_log format ["DEFENSE BUILDER: category '%1' -> %2 items (tanks=%3 statics=%4)", _cat, count _items, count (if (!isNil "MISSION_CORE_BUILDER_TANKS") then { MISSION_CORE_BUILDER_TANKS } else { [] }), count (if (!isNil "MISSION_CORE_BUILDER_STATICS") then { MISSION_CORE_BUILDER_STATICS } else { [] })];
    private _display = findDisplay 1520;
    if (isNull _display) exitWith {};
    private _ctrl = _display displayCtrl 1535;
    lbClear _ctrl;
    { _ctrl lbAdd format ["%1  ($%2)", _x select 1, _x select 4]; } forEach _items;
    _ctrl lbSetCurSel 0;
    // lbSetCurSel does NOT fire onLBSelChanged, so select the first entry explicitly - otherwise
    // clicking the already-highlighted item never sets the selection and placement reports
    // "Select an item first".
    if (count _items > 0) then { [_ctrl, 0] call MISSION_CORE_fnc_builderSelectItem; };
};

MISSION_CORE_fnc_builderMakeGhost = {
    private _item = MISSION_CORE_BUILD_SEL;
    if (isNil "_item") exitWith {};
    if (!isNull MISSION_CORE_BUILD_GHOST) then { deleteVehicle MISSION_CORE_BUILD_GHOST; };
    private _ghost = createSimpleObject [(_item select 5), [0, 0, 0]];
    if (isNull _ghost) then {
        _ghost = (_item select 5) createVehicleLocal [0, 0, 0];
        _ghost allowDamage false;
        _ghost enableSimulation true;
    } else {
        _ghost allowDamage false;
        _ghost enableSimulation true;
    };
    MISSION_CORE_BUILD_GHOST = _ghost;
};

MISSION_CORE_fnc_builderSelectItem = {
    params ["_ctrl", "_index"];
    if (_index < 0 || { _index >= count MISSION_CORE_BUILD_ITEMS }) exitWith {};
    private _item = MISSION_CORE_BUILD_ITEMS select _index;
    MISSION_CORE_BUILD_SEL = _item;
    MISSION_CORE_BUILD_DIR = 0;
    private _disp = findDisplay 1520;
    private _costCtrl = _disp displayCtrl 1536;
    _costCtrl ctrlSetText format ["COST: %1 pts", _item select 4];
    MISSION_CORE_BUILD_GHOST_HIDDEN = false;
    [] call MISSION_CORE_fnc_builderMakeGhost;
};

MISSION_CORE_fnc_builderPlace = {
    private _item = MISSION_CORE_BUILD_SEL;
    if (isNil "_item") exitWith { hint "Select an item first"; };
    private _pos = MISSION_CORE_BUILD_CURSOR;
    private _dir = MISSION_CORE_BUILD_DIR;
    [player, _item select 3, _item select 2, _pos, _dir, _item select 4] remoteExec ["MISSION_CORE_fnc_builderServerPlace", 2];
    // Remove the ghost at once so it never overlaps (and collides with) the just-placed object.
    // It comes back once the mouse moves away from the placement point (see the camera loop).
    if (!isNull MISSION_CORE_BUILD_GHOST) then { deleteVehicle MISSION_CORE_BUILD_GHOST; };
    MISSION_CORE_BUILD_GHOST = objNull;
    MISSION_CORE_BUILD_GHOST_HIDDEN = true;
    MISSION_CORE_BUILD_GHOST_HIDE_POS = getMousePosition;
};

MISSION_CORE_fnc_builderCameraLoop = {
    waitUntil { !isNil "MISSION_CORE_BUILD_CAM" && { !isNull MISSION_CORE_BUILD_CAM } };
    private _lastMouse = getMousePosition;
    while { MISSION_CORE_BUILD_ACTIVE } do {
        private _t = MISSION_CORE_BUILD_TARGET;
        if (isNil "_t" || { typeName _t != "ARRAY" } || { count _t < 2 }) then { _t = getPosATL player; };
        private _tx = _t param [0, 0];
        private _ty = _t param [1, 0];
        private _alt = MISSION_CORE_BUILD_ALT;
        if (isNil "_alt" || { typeName _alt != "SCALAR" }) then { _alt = 100; };
        private _az = MISSION_CORE_BUILD_CAMAZ;
        if (isNil "_az" || { typeName _az != "SCALAR" }) then { _az = 0; };
        private _pitch = MISSION_CORE_BUILD_CAMPITCH;
        if (isNil "_pitch" || { typeName _pitch != "SCALAR" }) then { _pitch = 55; };
        // Free camera: the position is fixed (moved by WASD), and the view direction comes from
        // yaw/pitch so dragging rotates the view IN PLACE rather than swinging around a ground
        // point. _pitch is the downward tilt in degrees (0 = horizon, 90 = straight down);
        // sin/cos take degrees in SQF.
        private _dir = [
            (sin _az) * (cos _pitch),
            (cos _az) * (cos _pitch),
            -(sin _pitch)
        ];
        private _cam = MISSION_CORE_BUILD_CAM;
        _cam camSetPos [_tx, _ty, _alt];
        _cam camSetTarget [_tx + (_dir select 0) * 1000, _ty + (_dir select 1) * 1000, _alt + (_dir select 2) * 1000];
        _cam camSetFov 0.4;
        _cam camCommit 0;
        // Ground point under the cursor, computed manually from the camera basis + FOV. This does
        // not rely on screenToWorld/positionCameraToWorld, which lag or misreport for a scripted
        // camera (that made the ghost feel like a slow joystick and placements miss the cursor).
        private _mPos = getMousePosition;
        private _ndcX = ((_mPos select 0) * 2) - 1;
        private _ndcY = 1 - ((_mPos select 1) * 2);
        private _res = getResolution;
        private _aspect = if ((_res select 1) > 0) then { (_res select 0) / (_res select 1) } else { 1.77778 };
        private _tanV = tan (0.2 * 57.2958);   // tan() takes DEGREES; half vFOV = 0.2 rad = 11.46 deg
        private _tanH = _tanV * _aspect;
        private _rfx = (sin _az) * (cos _pitch);
        private _rfy = (cos _az) * (cos _pitch);
        private _rfz = -(sin _pitch);
        private _rrx = cos _az;
        private _rry = -(sin _az);
        private _rux = (sin _az) * (sin _pitch);
        private _ruy = (cos _az) * (sin _pitch);
        private _ruz = cos _pitch;
        private _rdx = _rfx + (_ndcX * _tanH) * _rrx + (_ndcY * _tanV) * _rux;
        private _rdy = _rfy + (_ndcX * _tanH) * _rry + (_ndcY * _tanV) * _ruy;
        private _rdz = _rfz + (_ndcY * _tanV) * _ruz;
        private _ground = [_tx, _ty, 0];
        if (_rdz < 0) then {
            private _t = -(_alt) / _rdz;
            private _gt = [_tx + (_t * _rdx), _ty + (_t * _rdy), 0];
            _ground = _gt;
        } else {
            // Ray pointing up/horizontal - compute ground point at max range
            private _t = 100;
            private _gt = [_tx + (_t * _rdx), _ty + (_t * _rdy), _alt + (_t * _rdz)];
            // If this puts us above ground, force to ground
            if (_gt select 2 > 0) then { _gt set [2, 0]; };
            _ground = _gt;
        };
        MISSION_CORE_BUILD_CURSOR = _ground;
        if (!isNull MISSION_CORE_BUILD_GHOST) then {
            // Force exact cursor tracking - enable simulation and use setPosATL
            MISSION_CORE_BUILD_GHOST enableSimulation true;
            MISSION_CORE_BUILD_GHOST setPosATL _ground;
            MISSION_CORE_BUILD_GHOST setDir MISSION_CORE_BUILD_DIR;
        };
        // After a placement the ghost is hidden; bring it back once the mouse moves away.
        if (!isNil "MISSION_CORE_BUILD_GHOST_HIDDEN" && { MISSION_CORE_BUILD_GHOST_HIDDEN } && { !isNil "MISSION_CORE_BUILD_SEL" }) then {
            private _hp = MISSION_CORE_BUILD_GHOST_HIDE_POS;
            if (!isNil "_hp" && { (_mPos distance _hp) > 0.02 }) then {
                [] call MISSION_CORE_fnc_builderMakeGhost;
                MISSION_CORE_BUILD_GHOST_HIDDEN = false;
            };
        };
        // Live points readout
        private _pts = if (isNil "MISSION_CORE_DEFENSE_POINTS") then { 0 } else { MISSION_CORE_DEFENSE_POINTS getOrDefault [getPlayerUID player, 0] };
        private _display = findDisplay 1520;
        if (!isNull _display) then { (_display displayCtrl 1522) ctrlSetText format ["POINTS: %1", _pts]; };
        // WASD moves the camera horizontally, relative to its facing (W/S forward/back, A/D strafe).
        private _mSpeed = _alt * 0.005;
        private _fx = sin _az;
        private _fy = cos _az;
        private _rx = cos _az;
        private _ry = -(sin _az);
        private _mx = 0;
        private _my = 0;
        if (!isNil "MISSION_CORE_BUILD_KEY_W" && { MISSION_CORE_BUILD_KEY_W }) then { _mx = _mx + _fx * _mSpeed; _my = _my + _fy * _mSpeed; };
        if (!isNil "MISSION_CORE_BUILD_KEY_S" && { MISSION_CORE_BUILD_KEY_S }) then { _mx = _mx - _fx * _mSpeed; _my = _my - _fy * _mSpeed; };
        if (!isNil "MISSION_CORE_BUILD_KEY_A" && { MISSION_CORE_BUILD_KEY_A }) then { _mx = _mx - _rx * _mSpeed; _my = _my - _ry * _mSpeed; };
        if (!isNil "MISSION_CORE_BUILD_KEY_D" && { MISSION_CORE_BUILD_KEY_D }) then { _mx = _mx + _rx * _mSpeed; _my = _my + _ry * _mSpeed; };
        if (_mx != 0 || _my != 0) then {
            MISSION_CORE_BUILD_TARGET = [_tx + _mx, _ty + _my, 0];
        };
        // Mouse drag rotates the view in place: horizontal motion turns yaw, vertical tilts pitch.
        // The rotation is smoothed by easing the live angle toward the mouse-driven target angle.
        private _tarAz = MISSION_CORE_BUILD_TARAZ;
        if (isNil "_tarAz" || { typeName _tarAz != "SCALAR" }) then { _tarAz = _az; MISSION_CORE_BUILD_TARAZ = _az; };
        private _tarPitch = MISSION_CORE_BUILD_TARPITCH;
        if (isNil "_tarPitch" || { typeName _tarPitch != "SCALAR" }) then { _tarPitch = _pitch; MISSION_CORE_BUILD_TARPITCH = _pitch; };
        if (!isNil "MISSION_CORE_BUILD_LMB" && { MISSION_CORE_BUILD_LMB }) then {
            private _dx = (_mPos select 0) - (_lastMouse select 0);
            private _dy = (_mPos select 1) - (_lastMouse select 1);
            _tarAz = _tarAz + (_dx * 180);
            _tarPitch = ((_tarPitch + (_dy * 90)) max 15) min 89;
            MISSION_CORE_BUILD_TARAZ = _tarAz;
            MISSION_CORE_BUILD_TARPITCH = _tarPitch;
        };
        MISSION_CORE_BUILD_CAMAZ = _az + ((_tarAz - _az) * 0.25);
        MISSION_CORE_BUILD_CAMPITCH = _pitch + ((_tarPitch - _pitch) * 0.25);
        _lastMouse = _mPos;
        sleep 0.02;
    };
};

MISSION_CORE_fnc_exitDefenseBuilder = {
    if (isNil "MISSION_CORE_BUILD_ACTIVE" || !MISSION_CORE_BUILD_ACTIVE) exitWith {};
    MISSION_CORE_BUILD_ACTIVE = false;
    if (!isNil "MISSION_CORE_BUILD_CAM" && { !isNull MISSION_CORE_BUILD_CAM }) then {
        MISSION_CORE_BUILD_CAM cameraEffect ["TERMINATE", "BACK"];
        camDestroy MISSION_CORE_BUILD_CAM;
        MISSION_CORE_BUILD_CAM = objNull;
    };
    if (!isNil "MISSION_CORE_BUILD_GHOST" && { !isNull MISSION_CORE_BUILD_GHOST }) then { deleteVehicle MISSION_CORE_BUILD_GHOST; };
    player allowDamage true;
};
