
MISSION_CORE_fnc_getDefendersAt = {
    params ["_pos", "_radius"];
    allGroups select {
        _x getVariable ["MISSION_CORE_REDFOR", false] &&
        { (_x getVariable ["MISSION_CORE_ARMOR_SLOT", ""]) == "" } &&
        { !(_x getVariable ["MISSION_CORE_AA_DEFENSE", false]) } &&
        { !(_x getVariable ["MISSION_CORE_STATIC_DEFENSE", false]) } &&
        { (leader _x) distance _pos < _radius }
    }
};
