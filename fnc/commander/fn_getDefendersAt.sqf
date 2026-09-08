
MISSION_CORE_fnc_getDefendersAt = {
    params ["_pos", "_radius"];
    // Optional 3rd arg: a per-tick snapshot of allGroups. When supplied, scan that instead of
    // calling allGroups (which refetches + allocates a full list each time). Callers in the hot
    // commander loop pass the tick snapshot to avoid O(markers) full-list refetches.
    private _pool = if (count _this > 2) then { _this select 2 } else { allGroups };
    _pool select {
        _x getVariable ["MISSION_CORE_REDFOR", false] &&
        { (_x getVariable ["MISSION_CORE_ARMOR_SLOT", ""]) == "" } &&
        { !(_x getVariable ["MISSION_CORE_AA_DEFENSE", false]) } &&
        { !(_x getVariable ["MISSION_CORE_STATIC_DEFENSE", false]) } &&
        { (leader _x) distance _pos < _radius }
    }
};
