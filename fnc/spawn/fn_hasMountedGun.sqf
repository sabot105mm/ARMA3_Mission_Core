
// True when the vehicle carries a mounted gun (HMG/GMG/cannon) - e.g. an armed Ifrit. Crews of
// these fight from the vehicle and must never dismount.
MISSION_CORE_fnc_hasMountedGun = {
    params ["_v"];
    if (isNull _v) exitWith { false };
    private _weapons = weapons _v apply { toLower _x };
    private _hasGun = false;
    {
        if ((_x find "hmg" > -1) || { (_x find "gmg" > -1) } || { (_x find "autocannon" > -1) } || { (_x find "cannon" > -1) }) exitWith { _hasGun = true; };
    } forEach _weapons;
    _hasGun
};
