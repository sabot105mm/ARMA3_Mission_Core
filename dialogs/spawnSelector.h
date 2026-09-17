class DYNOPS_SpawnSelector
{
    idd = 1500;
    movingEnable = 1;
    onLoad = "uiNamespace setVariable ['DYNOPS_SpawnSelector', _this select 0]";
    class Controls
    {
        class Title: RscText
        {
            idc = 1501;
            x = 0.3; y = 0.2; w = 0.4; h = 0.04;
            text = "SELECT SPAWN LOCATION";
            colorBackground[] = {0,0,0,0.8};
        };
        class List: RscListBox
        {
            idc = 1502;
            x = 0.3; y = 0.25; w = 0.4; h = 0.4;
        };
        class SpawnBtn: RscButton
        {
            idc = 1503;
            x = 0.4; y = 0.67; w = 0.2; h = 0.04;
            text = "SPAWN";
            action = "[] call MISSION_CORE_fnc_onSpawnSelect;";
        };
        class CancelBtn: RscButton
        {
            idc = 1504;
            x = 0.3; y = 0.72; w = 0.4; h = 0.04;
            text = "CANCEL";
            action = "closeDialog 0;";
        };
    };
};

class DYNOPS_Recruitment
{
    idd = 1510;
    movingEnable = 1;
    onLoad = "uiNamespace setVariable ['DYNOPS_Recruitment', _this select 0]";
    class Controls
    {
        class Title: RscText
        {
            idc = 1511;
            x = 0.3; y = 0.2; w = 0.4; h = 0.04;
            text = "RECRUIT UNITS";
            colorBackground[] = {0,0,0,0.8};
        };
        class List: RscListBox
        {
            idc = 1512;
            x = 0.3; y = 0.25; w = 0.4; h = 0.35;
            onLBDblClick = "[_this select 0, _this select 1] call MISSION_CORE_fnc_onRecruit;";
        };
        class CloseBtn: RscButton
        {
            idc = 1513;
            x = 0.3; y = 0.62; w = 0.4; h = 0.04;
            text = "CLOSE";
            action = "closeDialog 0;";
        };
    };
};
