// Loader: compiles every function from the split fnc\commander\ folder in source order.
call compile preprocessFileLineNumbers "fnc\commander\fn_stopForDismount.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_aggression.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_getMarkerValue.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_getTargetPriority.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_getAIZoneFocus.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_disengageToNextMarker.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_getCachedImportance.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_getLocationLabel.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_getMarkerDetermination.sqf";
// Strategic worth (own tier value x neighbour proximity), shared by the counter-attack budget
// (fn_reinforceBudget.sqf) and both supply-request channels (fn_convoyLoop.sqf / fn_ammo.sqf).
// Compiled IMMEDIATELY after getMarkerDetermination and not in fn_init.sqf, which is deliberate:
// that adjacency is what guarantees a non-nil MISSION_CORE_fnc_markerWorth implies a non-nil
// MISSION_CORE_fnc_getMarkerDetermination, so the isNil guard at those two request call sites is
// provably sufficient. The ammo loop is spawned at fn_init.sqf:235 and first ticks at t+10s, while
// this file is not compiled until fn_init.sqf:335, so that window is real and the guard is load
// bearing - without it the first ticks would call an undefined function every 10 seconds.
call compile preprocessFileLineNumbers "fnc\commander\fn_markerWorth.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_getDefendersAt.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_getBluDefendersAt.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_defendGate.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_snatch.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_sendReinforce.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_sendCounterAttack.sqf";
// Waypoint builders used by sendCounterAttack (driver staging) and playerHunt (approach staging).
// Compiled here so both definitions exist before either caller can run. They resolve
// fnc_clearGroupWaypoints / fnc_transportStagePos / fnc_tune at CALL time, not at compile time,
// so the later fn_spawn.sqf registrations for those are not an ordering problem.
call compile preprocessFileLineNumbers "fnc\commander\fn_buildTruckDriverWps.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_buildHuntApproachWps.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_commitToBattle.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_splitAfterDismount.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_footSquadPostAssault.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_despawnOverwatchTanks.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_despawnAATanks.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_spawnAssaultGroup.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_assembleAssault.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_restartPatrol.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_requestReinforcement.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_markerCapacity.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_countMarkerGarrison.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_countInitialGarrison.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_retreatGarrison.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_overwatchArtillery.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_countReplenishGroups.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_countFootSquads.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_isMarkerContested.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_isOverwatchMarker.sqf";
// Contested-state authority: fn_isMarkerContested.sqf above is the ONLY writer of
//    MISSION_CORE_CONTESTED. Geometry projection: fn_getContestedMarkers.sqf below, which reads
//    that map's keys and joins MISSION_CORE_CACHED_POSITIONS for pos/size/owner. It has no verdict
//    logic, so it cannot disagree with the authority.
call compile preprocessFileLineNumbers "fnc\commander\fn_getContestedMarkers.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_findCoveredSpawns.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_hasCoveredSpawns.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_replenishMarker.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_spawnerSlotFree.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_releaseSpawnerSlot.sqf";
// Prunes spawn slots held by markers that can no longer field men. Compiled before
// fn_reinforceActions, which calls it when a provider gives up, and before
// fn_neighborCounterAttack, which calls it when a zone hits its ceiling. Depends only on
// fnc_tune (loaded earlier in fn_init) - not on the slot claim/release pair.
call compile preprocessFileLineNumbers "fnc\commander\fn_reevalSpawnerSlots.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_markerCombatAssessment.sqf";
// Reinforcement splits into pure logic (fn_reinforceBudget) and every side effect
// (fn_reinforceActions). Both compile before the orchestrator that calls them, and before
// fn_deactivateNeighborMarkers which calls the reset.
// The single affordability test, shared by fn_neighborCounterAttack's dispatch walk and all three
// queued release handlers. Compiled before all four so there is one definition, not four.
call compile preprocessFileLineNumbers "fnc\commander\fn_providerCanAfford.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_reinforceBudget.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_reinforceActions.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_neighborCounterAttack.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_enqueueSpawn.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_spawnQueueLoop.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_queuedCounterAttackInf.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_queuedCounterAttackTank.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_queuedReplenish.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_queuedReinforce.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_queuedArmorReinf.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_occupationMonitor.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_captureMarkerForPlayers.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_replenishLoop.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_deactivateNeighborMarkers.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_renewDefenses.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_assaultStaging.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_aiAssaultLoop.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_aiCommanderLoop.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_armorCommanderLoop.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_strayRecovery.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_attackStuckWatchdog.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_suppressedReaction.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_statusLogger.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_convoyLoop.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_tankOrderLoop.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_patrolWatchdog.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_debugVisuals.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_despawnUncontestedNeighbors.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_deleteGroupCompletely.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_getRetreatDest.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_retreatPayout.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_transportStuckRecovery.sqf";
// Before fn_playerHunt: the hunt draws already-fielded squads through this, and it is a COMMANDER
// task (one shared definition of "available garrison") rather than an action script's private rule.
call compile preprocessFileLineNumbers "fnc\commander\fn_claimIdleGarrison.sqf";
// The shared "re-task an idle garrison squad before conjuring one" decision, used by BOTH
// reinforcement spawn sites (fn_neighborCounterAttack's dispatch walk and
// fn_queuedCounterAttackInf's release). It calls MISSION_CORE_fnc_claimIdleGarrison (above) and
// MISSION_CORE_fnc_sendCounterAttack (line 16).
//
// SQF resolves `call MISSION_CORE_fnc_x` at RUNTIME, not at compile time, so this position is for
// readability rather than correctness - the two reinforcement callers at lines 50 and 53 already
// reference a function compiled further down this file, exactly as fn_playerHunt already did.
call compile preprocessFileLineNumbers "fnc\commander\fn_claimReinforcementSquad.sqf";
// Before fn_playerHunt, and AFTER fn_reinforceBudget (line 48): this is the reinforcement-priority
// gate that stops a hunt while its source marker still owes a contested marker men. It calls
// MISSION_CORE_fnc_providerBudget directly, so it must be compiled after that.
call compile preprocessFileLineNumbers "fnc\commander\fn_markerHasReinforceNeed.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_playerHunt.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_objectiveDirector.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_playNoteSound.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_longRangeReaction.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_groupMaintenance.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_defenseSpotLoop.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_truckCleanupLoop.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_orderedVehicleCleanup.sqf";
call compile preprocessFileLineNumbers "fnc\commander\fn_quadrantEngage.sqf";
