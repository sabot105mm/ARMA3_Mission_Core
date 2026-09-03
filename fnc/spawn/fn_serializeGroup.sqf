
MISSION_CORE_fnc_serializeGroup = {
    params ["_grp", "_center"];
    private _units = [];
    {
        _units pushBack [
            typeOf _x,
            [(_x distance2D _center), (_x getDir _center)],
            damage _x
        ];
    } forEach units _grp;
    private _waypoints = [];
    private _currentWpIdx = currentWaypoint _grp;
    private _wps = waypoints _grp;
    {
        _waypoints pushBack [waypointPosition _x, waypointType _x, waypointSpeed _x, waypointBehaviour _x];
    } forEach _wps;
    [
        _units,
        _waypoints,
        _currentWpIdx,
        behaviour (leader _grp),
        combatMode (leader _grp),
        speedMode (leader _grp),
        leader _grp getVariable ["MISSION_CORE_PATROLLING", false],
        _grp getVariable ["MISSION_CORE_IDLE", true],
        _grp getVariable ["MISSION_CORE_GROUP_TYPE", ""],
        _grp getVariable ["MISSION_CORE_ARMOR_SLOT", ""],
        _grp getVariable ["MISSION_CORE_AA_DEFENSE", false],
        _grp getVariable ["MISSION_CORE_SUBCAT", ""]
    ]
};
