
MISSION_CORE_fnc_getBluDefendersAt = {
    params ["_pos", "_radius"];
    // Optional 3rd arg: a per-tick snapshot of allGroups (see fn_getDefendersAt). Scanning the
    // snapshot avoids an allGroups refetch + full-list allocation for every marker in the loop.
    private _pool = if (count _this > 2) then { _this select 2 } else { allGroups };
    _pool select {
        _x getVariable ["MISSION_CORE_BLUFOR", false] &&
        { (_x getVariable ["MISSION_CORE_ARMOR_SLOT", ""]) == "" } &&
        { !(_x getVariable ["MISSION_CORE_AA_DEFENSE", false]) } &&
        { !(_x getVariable ["MISSION_CORE_STATIC_DEFENSE", false]) } &&
        { (leader _x) distance _pos < _radius }
    }
};
