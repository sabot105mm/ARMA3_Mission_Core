
// =====================================================================
// DEBUG MAP OVERLAY - gated by MISSION_CORE_DEBUG_VISUALS (set in fn_init.sqf).
// Draws on the map:
//   - a dedicated ICON label with the marker NAME for every active (spawned) location,
//     colored by owner (BLUFOR blue / OPFOR red)
//   - a GREEN ellipse ring = the capture "inside" boundary for active markers
//   - a YELLOW name + RED ellipse ring = the marker a player is currently CONTESTING
//     (same isMarkerContested check the capture logic uses)
//   - an ORANGE circle ring = the foot-transport unload stand-off distance around each
//     AI-contested marker (where trucks drop their foot squads)
// Flip MISSION_CORE_DEBUG_VISUALS to false to stop it. All markers are local and vanish
// on mission restart.
// =====================================================================
MISSION_CORE_fnc_debugVisuals = {
    diag_log "DEBUG VISUALS: started";
    private _capRings = createHashMap;
    private _unloadRings = createHashMap;
    private _nameLabels = createHashMap;
    while { MISSION_CORE_DEBUG_VISUALS } do {
        sleep 2;
        if (isNil "MISSION_CORE_CACHED_POSITIONS") then { continue; };
        private _players = allPlayers select { alive _x };

        // Marker names + capture boundary ellipse
        {
            _x params ["_name", "_pos", "_typeName", "_prio", "_owner", "_def", "_amb", "_imp", "_size"];
            private _ma = _size select 0;
            private _mb = _size select 1;
            private _md = if (count _size > 2) then { _size select 2 } else { 0 };
            private _active = MISSION_CORE_SPAWNED_LOCATIONS getOrDefault [_name, false];
            private _contested = _active && { [_pos, _owner, _name] call MISSION_CORE_fnc_isMarkerContested };

            // Name label - dedicated ICON marker so the text is always readable on the map
            private _lblName = format ["%1_dbg_name", _name];
            private _lbl = _nameLabels getOrDefault [_lblName, ""];
            if (_lbl == "" || { !(_lbl in allMapMarkers) }) then {
                _lbl = createMarkerLocal [_lblName, _pos];
                _lbl setMarkerType "mil_dot";
                _lbl setMarkerSize [0.3, 0.3];
                _nameLabels set [_lblName, _lbl];
            };
            _lbl setMarkerPos _pos;
            if (_contested) then {
                _lbl setMarkerText _name;
                _lbl setMarkerColor "ColorYellow";
                _lbl setMarkerAlpha 1;
            } else {
                _lbl setMarkerText (if (_active) then { _name } else { "" });
                _lbl setMarkerColor (if (_owner == WEST) then { "ColorBLUFOR" } else { "ColorOPFOR" });
                _lbl setMarkerAlpha (if (_active) then { 1 } else { 0 });
            };

            // Capture boundary ellipse (the "inside" area for capture)
            private _capName = format ["%1_dbg_cap", _name];
            private _cap = _capRings getOrDefault [_capName, ""];
            if (_cap == "" || { !(_cap in allMapMarkers) }) then {
                _cap = createMarkerLocal [_capName, _pos];
                _capRings set [_capName, _cap];
            };
            _cap setMarkerPos _pos;
            _cap setMarkerShape "ELLIPSE";
            _cap setMarkerBrush "Border";
            _cap setMarkerSize [_ma, _mb];
            _cap setMarkerDir _md;
            if (_contested) then {
                _cap setMarkerColor "ColorRed";
                _cap setMarkerAlpha 0.9;
            } else {
                _cap setMarkerColor "ColorGreen";
                _cap setMarkerAlpha (if (_active) then { 0.45 } else { 0 });
            };
        } forEach MISSION_CORE_CACHED_POSITIONS;

        // Transport unload stand-off ring for each marker a hostile player is INSIDE of - matches
        // sendCounterAttack's _unloadDist = ellipse-radial-along-approach + 100, using the closest
        // active same-side neighbor as the approach origin.
        {
            _x params ["_name", "_pos", "_typeName", "_prio", "_owner", "_def", "_amb", "_imp", "_size"];
            private _a = _size select 0;
            private _b = if (count _size > 1) then { _size select 1 } else { _a };
            private _md = if (count _size > 2) then { _size select 2 } else { 0 };
            private _playerInside = _players findIf {
                side _x getFriend _owner < 0.6 && {
                    private _p = getPos _x;
                    private _dx = (_p select 0) - (_pos select 0);
                    private _dy = (_p select 1) - (_pos select 1);
                    private _rx = _dx * cos _md - _dy * sin _md;
                    private _ry = _dx * sin _md + _dy * cos _md;
                    (_rx*_rx)/(_a*_a) + (_ry*_ry)/(_b*_b) <= 1
                }
            } != -1;
            if (!_playerInside) then { continue; };
            private _origin = [0, 0, 0];
            private _originD = 1e10;
            {
                if ((_x select 4) == _owner && { (_x select 0) != _name } && { MISSION_CORE_SPAWNED_LOCATIONS getOrDefault [_x select 0, false] }) then {
                    private _d = (_x select 1) distance _pos;
                    if (_d < _originD) then { _originD = _d; _origin = _x select 1; };
                };
            } forEach MISSION_CORE_CACHED_POSITIONS;
            private _dirIn = if (_originD < 1e10) then { ((_pos select 0) - (_origin select 0)) atan2 ((_pos select 1) - (_origin select 1)) } else { 0 };
            private _den = sqrt (((_b * cos _dirIn) ^ 2) + ((_a * sin _dirIn) ^ 2));
            private _rad = if (_den > 0) then { (_a * _b) / _den } else { _a };
            private _unloadDist = _rad + 100;
            private _uName = format ["%1_dbg_unload", _name];
            private _u = _unloadRings getOrDefault [_uName, ""];
            if (_u == "" || { !(_u in allMapMarkers) }) then {
                _u = createMarkerLocal [_uName, _pos];
                _unloadRings set [_uName, _u];
            };
            _u setMarkerPos _pos;
            _u setMarkerShape "ELLIPSE";
            _u setMarkerBrush "SolidBorder";
            _u setMarkerSize [_unloadDist, _unloadDist];
            _u setMarkerColor "ColorOrange";
            _u setMarkerAlpha 1;
        } forEach MISSION_CORE_CACHED_POSITIONS;
    };
};
