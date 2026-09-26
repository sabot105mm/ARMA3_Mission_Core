// Loader: compiles every function from the split fnc\spawn\ folder in source order.
call compile preprocessFileLineNumbers "fnc\spawn\fn_isClearOfTerrain.sqf";
call compile preprocessFileLineNumbers "fnc\spawn\fn_findDefenseAxis.sqf";
call compile preprocessFileLineNumbers "fnc\spawn\fn_clearNearbyWrecks.sqf";
diag_log format ["WRECK SWEEP LOAD: fn_clearNearbyWrecks.sqf compiled, helper defined=%1", !(isNil "MISSION_CORE_fnc_clearNearbyWrecks")];
call compile preprocessFileLineNumbers "fnc\spawn\fn_ellipseRadius.sqf";
call compile preprocessFileLineNumbers "fnc\spawn\fn_markUnsafeVehicleSpawn.sqf";
call compile preprocessFileLineNumbers "fnc\spawn\fn_isUnsafeVehicleSpawn.sqf";
call compile preprocessFileLineNumbers "fnc\spawn\fn_findVehiclePos.sqf";
  call compile preprocessFileLineNumbers "fnc\spawn\fn_findVehicleColumnPos.sqf";
call compile preprocessFileLineNumbers "fnc\spawn\fn_findFlatSpawns.sqf";
call compile preprocessFileLineNumbers "fnc\spawn\fn_buildSafeVehicleSpawns.sqf";
call compile preprocessFileLineNumbers "fnc\spawn\fn_getSafeVehicleSpawns.sqf";
call compile preprocessFileLineNumbers "fnc\spawn\fn_isSafeVehicleSpawnPos.sqf";
call compile preprocessFileLineNumbers "fnc\spawn\fn_isDryPos.sqf";
call compile preprocessFileLineNumbers "fnc\spawn\fn_ensureLandPos.sqf";
call compile preprocessFileLineNumbers "fnc\spawn\fn_safeWaypointPos.sqf";
call compile preprocessFileLineNumbers "fnc\spawn\fn_liftSpawn.sqf";
call compile preprocessFileLineNumbers "fnc\spawn\fn_safeVehicleSpawn.sqf";
diag_log format ["SAFEVEHICLE LOAD: fn_safeVehicleSpawn.sqf compiled, helper defined=%1", !(isNil "MISSION_CORE_fnc_safeVehicleSpawn")];
// CREW GET-OUT LIFECYCLE. One role script per vehicle kind, plus the shared classifier /
// exclusion gate / relocator / attach point. Registered here because fn_safeVehicleSpawn is the
// single funnel that attaches the handler to every hull it creates.
call compile preprocessFileLineNumbers "fnc\spawn\fn_getOutArmorVerdict.sqf";
call compile preprocessFileLineNumbers "fnc\spawn\fn_getOutArmorWorker.sqf";
call compile preprocessFileLineNumbers "fnc\spawn\fn_getOutArmor.sqf";
call compile preprocessFileLineNumbers "fnc\spawn\fn_getOutTransport.sqf";
call compile preprocessFileLineNumbers "fnc\spawn\fn_getOutSupply.sqf";
call compile preprocessFileLineNumbers "fnc\spawn\fn_getOutStatic.sqf";
call compile preprocessFileLineNumbers "fnc\spawn\fn_vehicleGetOut.sqf";
diag_log format ["GETOUT LOAD: armorVerdict=%1 armorWorker=%2 armor=%3 transport=%4 supply=%5 static=%6 dispatch=%7 attach=%8",
    !(isNil "MISSION_CORE_fnc_getOutArmorVerdict"), !(isNil "MISSION_CORE_fnc_getOutArmorWorker"),
    !(isNil "MISSION_CORE_fnc_getOutArmor"), !(isNil "MISSION_CORE_fnc_getOutTransport"),
    !(isNil "MISSION_CORE_fnc_getOutSupply"), !(isNil "MISSION_CORE_fnc_getOutStatic"),
    !(isNil "MISSION_CORE_fnc_getOutDispatch"), !(isNil "MISSION_CORE_fnc_attachGetOut")];
call compile preprocessFileLineNumbers "fnc\spawn\fn_guardSpawnKill.sqf";
call compile preprocessFileLineNumbers "fnc\spawn\fn_countSideArmor.sqf";
call compile preprocessFileLineNumbers "fnc\spawn\fn_countArmorAt.sqf";
call compile preprocessFileLineNumbers "fnc\spawn\fn_countArmorByHome.sqf";
call compile preprocessFileLineNumbers "fnc\spawn\fn_countArmorOutposts.sqf";
call compile preprocessFileLineNumbers "fnc\spawn\fn_countTownCategory.sqf";
call compile preprocessFileLineNumbers "fnc\spawn\fn_townCategoryCanUse.sqf";
call compile preprocessFileLineNumbers "fnc\spawn\fn_armorCapOpen.sqf";
call compile preprocessFileLineNumbers "fnc\spawn\fn_getLocByPos.sqf";
call compile preprocessFileLineNumbers "fnc\spawn\fn_countSideComposition.sqf";
call compile preprocessFileLineNumbers "fnc\spawn\fn_requestArmorReinforcement.sqf";
call compile preprocessFileLineNumbers "fnc\spawn\fn_spawnHQForce.sqf";
  call compile preprocessFileLineNumbers "fnc\spawn\fn_markerTankPool.sqf";
call compile preprocessFileLineNumbers "fnc\spawn\fn_markerSizeWeight.sqf";
call compile preprocessFileLineNumbers "fnc\spawn\fn_tankDepot.sqf";
diag_log format ["TANKDEPOT LOAD: fn_tankDepot.sqf compiled, tankDepotIsDepot defined=%1 producer=%2 stock=%3 cap=%4", !(isNil "MISSION_CORE_fnc_tankDepotIsDepot"), !(isNil "MISSION_CORE_fnc_tankDepotIsProducer"), !(isNil "MISSION_CORE_fnc_tankDepotStock"), !(isNil "MISSION_CORE_fnc_tankDepotCap")];
call compile preprocessFileLineNumbers "fnc\spawn\fn_portSystem.sqf";
call compile preprocessFileLineNumbers "fnc\spawn\fn_hasClearLOS.sqf";
call compile preprocessFileLineNumbers "fnc\spawn\fn_faceWeapon.sqf";
call compile preprocessFileLineNumbers "fnc\spawn\fn_monitorCrew.sqf";
call compile preprocessFileLineNumbers "fnc\spawn\fn_spawnDefenseVehicle.sqf";
call compile preprocessFileLineNumbers "fnc\spawn\fn_spawnDefenses.sqf";
call compile preprocessFileLineNumbers "fnc\spawn\fn_placeTowerMGs.sqf";
call compile preprocessFileLineNumbers "fnc\spawn\fn_spawnGroup.sqf";
call compile preprocessFileLineNumbers "fnc\spawn\fn_isSoftTransport.sqf";
call compile preprocessFileLineNumbers "fnc\spawn\fn_hasMountedGun.sqf";
call compile preprocessFileLineNumbers "fnc\spawn\fn_mountInfantry.sqf";
call compile preprocessFileLineNumbers "fnc\spawn\fn_clearGroupWaypoints.sqf";
call compile preprocessFileLineNumbers "fnc\spawn\fn_serializeGroup.sqf";
call compile preprocessFileLineNumbers "fnc\spawn\fn_deserializeGroup.sqf";
call compile preprocessFileLineNumbers "fnc\spawn\fn_spawnLocation.sqf";
call compile preprocessFileLineNumbers "fnc\spawn\fn_proximitySpawner.sqf";
call compile preprocessFileLineNumbers "fnc\spawn\fn_despawnLocation.sqf";
call compile preprocessFileLineNumbers "fnc\spawn\fn_deactivateFarMarkers.sqf";
call compile preprocessFileLineNumbers "fnc\spawn\fn_defenseCoordinator.sqf";
call compile preprocessFileLineNumbers "fnc\spawn\fn_houseOccupation.sqf";
