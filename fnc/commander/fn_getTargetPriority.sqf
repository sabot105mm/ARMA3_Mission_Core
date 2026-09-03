MISSION_CORE_fnc_getTargetPriority = {
    params ["_locName"];
    private _value = [_locName] call MISSION_CORE_fnc_getMarkerValue;
    // A target that keeps surviving (higher defense score) keeps losing its appeal: each
    // successful defense subtracts a heavy penalty. Value trumps raw capture chance - a
    // Factory is always more attractive than an Outpost until it has been defended a lot.
    private _defense = MISSION_CORE_DEFENSE_SCORE getOrDefault [_locName, 0];
    (_value - (_defense * 50)) max 0
};