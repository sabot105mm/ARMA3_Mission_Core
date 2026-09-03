
// True when a vehicle is a wheeled soft transport (trucks, jeeps) - never helicopters or APCs
MISSION_CORE_fnc_isSoftTransport = {
    params ["_v"];
    if (isNull _v) exitWith { false };
    (_v isKindOf "Truck_F") || { (_v isKindOf "Car") && { !(_v isKindOf "Wheeled_APC") } }
};
