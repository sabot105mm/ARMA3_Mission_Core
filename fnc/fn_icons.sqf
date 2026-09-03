// Map icon for a group based on its role, so spawned units can be identified on the map
MISSION_CORE_fnc_iconType = {
    params ["_grp", "_side"];
    private _slot = _grp getVariable ["MISSION_CORE_ARMOR_SLOT", ""];
    private _isAATank = _grp getVariable ["MISSION_CORE_AA_TANK", false];
    private _subCat = _grp getVariable ["MISSION_CORE_SUBCAT", ""];
    private _prefix = if (_side == WEST) then { "b_" } else { if (_side == EAST) then { "o_" } else { "n_" } };
    private _t = "unknown";
    if (_isAATank || _slot == "mbt") then { _t = "armor"; }
    else {
        if (_slot == "mech") then { _t = "mech_inf"; }
        else {
            if (_subCat == "recon") then { _t = "recon"; }
            else {
                if (_subCat find "_aa" > -1) then { _t = "antiair"; }
                else {
                    if (_subCat find "_at" > -1) then { _t = "antiarmor"; }
                    else {
                        if (_subCat find "inf" == 0) then { _t = "inf"; } else { _t = "unknown"; };
                    };
                };
            };
        };
    };
    _prefix + _t
};

// Keep a live map marker on every spawned group so all units are identifiable
MISSION_CORE_fnc_iconMarkers = {
    if (isNil "MISSION_CORE_UNIT_MARKERS") then { MISSION_CORE_UNIT_MARKERS = createHashMap; };
    while { true } do {
        sleep 5;
        if (!(isNil "MISSION_CORE_SPAWNED_GROUPS")) then {
            // Clean up markers whose group is gone (map is keyed by group object)
            private _deadMarkers = [];
            {
                private _grp = _x;
                if (isNull _grp || { count units _grp == 0 }) then {
                    deleteMarker (MISSION_CORE_UNIT_MARKERS get _grp);
                    _deadMarkers pushBack _grp;
                };
            } forEach (keys MISSION_CORE_UNIT_MARKERS);
            { MISSION_CORE_UNIT_MARKERS deleteAt _x; } forEach _deadMarkers;

            // Update/create a marker for every live spawned group
            {
                private _grp = _x;
                if (!isNull _grp && { count units _grp > 0 }) then {
                    private _mk = MISSION_CORE_UNIT_MARKERS get _grp;
                    if (isNil "_mk") then { _mk = ""; };
                    if (_mk == "") then {
                        _mk = format ["MISSION_CORE_ICON_%1", floor (random 999999)];
                        createMarker [_mk, getPos leader _grp];
                        MISSION_CORE_UNIT_MARKERS set [_grp, _mk];
                    };
                    private _leader = leader _grp;
                    private _s = side _leader;
                    _mk setMarkerType ([_grp, _s] call MISSION_CORE_fnc_iconType);
                    _mk setMarkerPos (getPos _leader);
                    _mk setMarkerDir (getDir _leader);
                    _mk setMarkerColor (if (_s == WEST) then { "ColorBLUFOR" } else { if (_s == EAST) then { "ColorOPFOR" } else { "ColorIndependent" } });
                    _mk setMarkerText (format ["%1 | %2 | %3", _grp getVariable ["MISSION_CORE_ORIGIN_MARKER", "?"], _grp getVariable ["MISSION_CORE_GROUP_TYPE", groupId _grp], _grp getVariable ["MISSION_CORE_ORDER", "patrol"]]);
                    _mk setMarkerSize [0.9, 0.9];
                    _mk setMarkerAlpha 0.85;
                };
            } forEach MISSION_CORE_SPAWNED_GROUPS;
        };
    };
};
