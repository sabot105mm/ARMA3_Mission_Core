//
// NOTE SOUNDS - plays a sound file from the mission "sounds" folder when a
// note is announced to the players. One file per note kind:
//   - "ATTACK":  sounds\attack.ogg
//   - "DEFEND":  sounds\defend.ogg
// The sound is played at the player's own position so it is clearly audible.
//
MISSION_CORE_fnc_playNoteSound = {
    params ["_kind"];
    if (!hasInterface) exitWith {};
    private _file = if (_kind == "DEFEND") then { "defend.ogg" } else { "attack.ogg" };
    private _path = getMissionPath ("sounds\" + _file);
    if (fileExists _path) then {
        playSound3D [_path, player, false, getPosASL player, 3, 1, 500];
    };
};