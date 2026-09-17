// fn_stopForDismount.sqf
// Bring a troop transport to a FULL STOP before any rider is forced out. The UNLOAD/GETOUT
// waypoints and arrival fallbacks can fire while the truck is still rolling, and ejecting men
// from a moving vehicle throws them out at speed and kills them on landing. This is the ONE
// canonical stop routine shared by every dismount path - transport_unload.sqf,
// transport_assaultUnload.sqf, the fn_recruit.sqf drop fallback and the fn_playerHunt.sqf
// disembark all call this instead of duplicating the stop-and-wait loop. New waypoints assigned
// after the drop cancel the doStop so the transport can drive on.
// _this = [_veh]
MISSION_CORE_fnc_stopForDismount = {
    params ["_veh"];
    if (isNull _veh) exitWith {};
    if (alive _veh) then {
        _veh setSpeedMode "LIMITED";
        private _drvStop = driver _veh;
        if (!isNull _drvStop) then { doStop _drvStop; };
        private _stopBy = time + 6;
        waitUntil { sleep 0.2; isNull _veh || { !(alive _veh) } || { speed _veh < 2 } || { time > _stopBy } };
    };
};