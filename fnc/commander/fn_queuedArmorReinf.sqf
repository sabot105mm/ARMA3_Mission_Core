
MISSION_CORE_fnc_queuedArmorReinf = {
    params ["_side", ["_targetPos", [0, 0, 0]], ["_targetName", ""]];
    if (isNil "_side") exitWith { false };
    if (isNil "_targetPos" || { !(_targetPos isEqualType []) }) then { _targetPos = [0, 0, 0]; };
    if (isNil "_targetName") then { _targetName = ""; };
    if (_targetPos isEqualTo [0, 0, 0] && _targetName == "") exitWith { false };
    private _targetImportance = 1;
    private _tl = MISSION_CORE_CACHED_POSITIONS select { (_x select 0) == _targetName };
    if (count _tl > 0) then {
        _targetImportance = (_tl select 0) select 7;
        if (_targetPos isEqualTo [0, 0, 0]) then { _targetPos = (_tl select 0) select 1; };
    };
    if (_targetPos isEqualTo [0, 0, 0]) exitWith { false };
    if !(([_side, "mbt", _targetPos, _targetImportance] call MISSION_CORE_fnc_armorCapOpen) || { ([_side, "mech", _targetPos, _targetImportance] call MISSION_CORE_fnc_armorCapOpen) }) exitWith { false };
    [_side, _targetPos, _targetName, true] call MISSION_CORE_fnc_requestArmorReinforcement;
    true
};
