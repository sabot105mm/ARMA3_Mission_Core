
MISSION_CORE_fnc_renewDefenses = {
    params ["_targetPos"];
    if (isNil "MISSION_CORE_SPAWNED_GROUPS") exitWith {};
    private _renewGroups = MISSION_CORE_SPAWNED_GROUPS select {
        !isNull _x &&
        _x getVariable ["MISSION_CORE_BLUFOR", false] &&
        { (_x getVariable ["MISSION_CORE_MARKER_CENTER", [0,0,0]]) distance _targetPos < 200 }
    };
    private _crewClass = "B_crew_F";
    {
        private _group = _x;
        private _vehList = [];
        { private _v = vehicle _x; if (_v != _x && !(_v in _vehList)) then { _vehList pushBack _v; }; } forEach units _group;
        {
            private _veh = _x;
            if (!alive _veh || damage _veh > 0.8) then {
                { deleteVehicle _x; } forEach crew _veh;
                deleteVehicle _veh;
            } else {
                private _oldCrew = crew _veh;
                { if (!alive _x) then { deleteVehicle _x; }; } forEach _oldCrew;
                private _emptyPositions = (_veh emptyPositions "gunner") + (_veh emptyPositions "driver") + (_veh emptyPositions "commander");
                for "_c" from 1 to _emptyPositions do {
                    private _newUnit = _group createUnit [_crewClass, getPos _veh, [], 0, "NONE"];
                    _newUnit moveInAny _veh;
                };
            };
        } forEach _vehList;
        private _unitCount = { alive _x } count units _group;
        if (_unitCount == 0) then { deleteGroup _group; };
    } forEach _renewGroups;
    diag_log format ["DYNAMIC DEFENSE: renewed %1 BLUFOR groups at %2", count _renewGroups, _targetPos];
};
