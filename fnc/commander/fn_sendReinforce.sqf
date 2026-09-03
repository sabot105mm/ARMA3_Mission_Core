
// Reinforcements ride trucks exactly like counter-attacks: a reinforcing foot squad far from the
// target mounts a truck and rides to the friendly marker instead of marching across the map on
// foot. This delegates to sendCounterAttack (which mounts when >=700m away and a player is near)
// so reinforce and counter-attack share one truck/disembark/assault pipeline.
MISSION_CORE_fnc_sendReinforce = {
    params ["_group", "_targetPos", "_speed"];
    [_group, _targetPos, [50, 50], "RED", "reinforce"] call MISSION_CORE_fnc_sendCounterAttack;
};
