
MISSION_CORE_fnc_faceWeapon = {
    params ["_wep", "_dir"];
    if (isNull _wep) exitWith {};
    _wep setVectorUp [0, 0, 1];
    _wep setDir _dir;
    [_wep, _dir] spawn {
        params ["_wep", "_dir"];
        sleep 0.5;
        if (isNull _wep) exitWith {};
        _wep setVectorUp [0, 0, 1];
        _wep setDir _dir;
        private _p = getPosATL _wep;
        _wep setPosATL [_p select 0, _p select 1, (_p select 2) max 0.05];
    };
};
