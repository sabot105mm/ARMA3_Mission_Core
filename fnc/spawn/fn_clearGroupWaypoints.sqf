
// Delete all of a group's waypoints by removing the last one first. Deleting forward (index 0
// repeatedly) while the group's current waypoint is a CYCLE makes the engine log
// "Cycle as first waypoint has no sense" and can leave the group frozen at the CYCLE.
MISSION_CORE_fnc_clearGroupWaypoints = {
    params ["_grp"];
    while { count waypoints _grp > 0 } do {
        deleteWaypoint ((waypoints _grp) select (count waypoints _grp - 1));
    };
};
