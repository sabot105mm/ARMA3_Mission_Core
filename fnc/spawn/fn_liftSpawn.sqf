
// Lift a spawn position a few meters above the terrain so a freshly created vehicle drops and
// settles onto the ground instead of clipping into terrain/bushes or wedging into a shallow dip
// at the exact spawn point. The drop also nudges the vehicle into the engine's resting pose.
MISSION_CORE_fnc_liftSpawn = {
    params ["_pos", ["_lift", 3]];
    if !(_pos isEqualType []) exitWith { _pos };
    [_pos param [0, 0, [0]], _pos param [1, 0, [0]], (_pos param [2, 0, [0]]) + _lift]
};
