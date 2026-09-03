
// Level-based garrison capacity per friendly marker: lvl 1-5 -> 50, 60, 70, 80, 100 men
MISSION_CORE_fnc_markerCapacity = {
    params ["_importance"];
    ([50, 60, 70, 80, 100] select ((_importance - 1) max 0 min 4))
};
