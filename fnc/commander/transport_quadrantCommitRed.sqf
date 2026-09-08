// transport_quadrantCommitRed.sqf
// Fired by setWaypointScript when a quadrant-ordered squad COMPLETES the APPROACH waypoint (the
// center of the player's quadrant quarter, reached once within its big completion radius). Commits
// the group to RED (fire at will) so it pushes hard into the player's quadrant instead of hovering
// at YELLOW. Behaviour stays AWARE - the squad keeps moving through its sweep, but engages freely.
params ["_leader", "_wpPos", "_target"];
private _g = group _leader;
if (!isNull _g) then {
    _g setCombatMode "RED";
};