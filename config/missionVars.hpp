// ============================================================================
//  MISSION EDITABLE VARIABLES  -  THIS IS THE ONLY FILE YOU EDIT FOR TUNING
// ============================================================================
//  Included by description.ext via:  #include "config\missionVars.hpp"
//  Read at runtime by missionConfigFile (e.g. fnc\fn_tune.sqf line 14).
//
//  Contains: BLUFOR_FACTION / REDFOR_FACTION, tank caps, defense points,
//  BLACKLIST, LOCATION_TYPES, LOCATION_PRESETS, DETECTION, and MISSION_CORE_TUNE.
//  Everything else in description.ext is UI/notification plumbing - do not tune it.
//
//  Changes require a mission restart.
// ============================================================================

BLUFOR_FACTION = "BLU_F";
REDFOR_FACTION = "OPF_F";
//BLUFOR_FACTION = "CUP_B_USMC";
//REDFOR_FACTION = "CUP_O_RU";
B_MAX_TANKS = 4;
O_MAX_TANKS = 4;
DEFENSE_BUILD_POINTS_DEFAULT = 10000;
DEFENSE_BUILD_POINTS_CAPTURE_REWARD = 50;

class BLACKLIST {
    class Units {
        patterns[] = {"unarmed","Unarmed","Civilian","Citizen","Worker","Survivor","Hook"};
    };
    class Vehicles {
        patterns[] = {"unarmed","Civilian","Quadbike","Van_02","Van_01"};
    };
    class Weapons {
        patterns[] = {};
    };
};

class LOCATION_TYPES {
    class HQ        { prefix = "hq_";        type = "HQ";        priority = 1; };
    class Airfield  { prefix = "airfield_";  type = "Airfield";  priority = 2; };
    class Factory   { prefix = "factory_";   type = "Factory";   priority = 3; };
    class Compound  { prefix = "compound_";  type = "Compound";  priority = 3; };
    class Base      { prefix = "base_";      type = "Base";      priority = 2; };
    class Town      { prefix = "town_";      type = "Town";      priority = 3; };
    class Outpost   { prefix = "outpost_";   type = "Outpost";   priority = 4; };
    class Depot     { prefix = "depot_";     type = "Depot";     priority = 4; };
    class Port      { prefix = "port_";      type = "Port";      priority = 3; };
    class Powerplant { prefix = "power_";    type = "Powerplant"; priority = 3; };
    class Solar     { prefix = "solar_";     type = "Solar";     priority = 4; };
};

// Composition presets per location type, read by fnc\fn_compositions.sqf line 47
// (missionConfigFile >> "LOCATION_PRESETS"). Each name must match a .sqf basename in comps\.
// These only fire at locations that actually have defender positions assigned (the
// forEach guard in placeCompositions), so a type listed here with no defenders places nothing.
// "groups[]" is the defender group pool; the defense builder matches these names.
class LOCATION_PRESETS {
    class HQ {
        groups[] = {"HQ_Defense","Squad_Standard","Squad_Heavy","Team_Patrol","Team_AT","Team_AA","Crew_Stationary","Vehicle_Transport","Vehicle_APC","Vehicle_MBT","Vehicle_AA","Air_Heli_Attack","Air_Heli_Transport"};
        compositions[] = {"hq_main","defense_perimeter","mortar_pit","watchtower"}; };
    class Airfield {
        groups[] = {"Squad_Standard","Team_Patrol","Team_AT","Crew_Stationary","Vehicle_Transport","Vehicle_APC","Air_Heli_Transport","Air_Plane_CAS"};
        compositions[] = {"airfield_defense","watchtower"}; };
    class Factory {
        groups[] = {"Squad_Standard","Team_Patrol","Team_AT","Crew_Stationary","Vehicle_Transport"};
        compositions[] = {"camp_light","camp_medium","watchtower"}; };
    class Compound {
        groups[] = {"Team_Patrol","Team_AT","Crew_Stationary"};
        compositions[] = {"camp_light","camp_medium","ambush_road","watchtower"}; };
    class Base {
        groups[] = {"Squad_Standard","Squad_Heavy","Team_Patrol","Team_AT","Team_AA","Crew_Stationary","Vehicle_Transport","Vehicle_APC","Vehicle_MBT"}; 
        compositions[] = {"defense_perimeter","mortar_pit","watchtower","hq_main"}; };
    class Town {
        groups[] = {"Team_Patrol","Squad_Standard","Crew_Stationary"};
        compositions[] = {"urban_checkpoint","ambush_urban"}; };
    class Outpost {
        groups[] = {"Team_Patrol","Crew_Stationary"};
        compositions[] = {"outpost_light","watchtower"}; };
    class Depot {
        groups[] = {"Team_Patrol","Team_AT","Crew_Stationary","Vehicle_Transport"};
        compositions[] = {"depot_defense"}; };
    class Port {
        groups[] = {"Squad_Standard","Team_Patrol","Team_AT","Crew_Stationary","Vehicle_Transport"};
        compositions[] = {"camp_medium","watchtower"}; };
    class Watchtower {
        groups[] = {"Team_Patrol"};
        compositions[] = {"watchtower"}; };
};

class DETECTION {
    knowsAboutTrigger = 1.5;
    detectionRadius = 500;
    reinforceRadius = 800;
};

// === BALANCE TUNING (numbers only - tweak here, restart)
class MISSION_CORE_TUNE {
    footSquadRefMen = 6;
    footSquadCapSquads = 10;

    // ----- Marker size-weight (garrison scaling by footprint x importance) -----
    sizeWeightMinArea = 20000;
    sizeWeightMaxArea = 250000;
    sizeWeightImpFloor = 0.2;
    sizeWeightImpCeil = 1.0;
    sizeWeightMinMen = 6;
    sizeWeightMaxMen = 12;
    vehicleMinImportance = 2;

    proxSpawnRadius = 700;
    proxDespawnDist = 2500;
    proxDespawnExhausted = 1500;
    proxMaxActive = 6;
    closeMarkerHysteresis = 50;

    defenseRadius = 1800;
    defenseRingsPerSide = 2;

    houseSpawnRadius = 80;
    houseDespawnRadius = 100;
    houseMaxActive = 6;
    houseMaxPerHouse = 2;
    houseOverrideRadius = 20;
    housePriorityRadiusMult = 2;
    cargoTowerSpawnRadius = 600;
    cargoTowerDespawnRadius = 800;
    cargoTowerMaxCount = 8;
    cargoTowerCount1 = 4;
    cargoTowerCount2 = 6;
    cargoTowerCount3 = 8;

    // ----- Quadrant engagement -----
    quadrantPerTargetMax = 99;
    quadrantReleasePerTick = 3;
    quadrantBatchInterval = 90;
    quadrantReEvalInterval = 300;
    quadrantGraceTime = 600;

    huntDetectRange = 1200;
    huntFaintKnows = 0.1;
    huntContactKnows = 0.7;
    huntIntelDecay = 60;
    huntSweepSeconds = 600;
    huntReSpotRadius = 30;
    huntRetargetEvery = 45;
    huntClearEvery = 120;
    huntMountDist = 700;
    huntSpawnMinPlayerDist = 500;
    huntMaxContingents = 3;   // source markers that may answer ONE dispatch event (nearest-first)
    huntMaxPerMarker = 3;       // live hunt contingents ONE marker may have running at once.
    // huntMaxContingents bounds a single director tick; this bounds a garrison over time. Without
    // it a marker near the player answered every tick with another contingent and its hunts stacked
    // indefinitely. Counted on live hunts only - a dead group or one whose sweep ended frees its slot.
    huntSourceMaxRange = 2500;
    huntCurvePace = 4;

    // ----- Assault artillery -----
    artyBracketSteps = 4;

    armorLocalMbtImp3 = 2;
    armorLocalMbtLo = 1;
    armorOutpostMbtMax = 2;
    armorReserveHold = 20;
    armorGlobalFallback = 4;

    tankBuildInterval = 600;
    tankDepotCapSmall = 10;
    tankDepotCapLarge = 20;
    tankShipColumnMax = 3;
    tankTravelSpeed = 18;
    powerplantGlobalBonus = 0.2;
    powerplantNeighborBonus = 0.5;
    powerplantNeighborRange = 1500;
    solarContribution = 0.25;

    // ----- Manpower economy (ports -> bases -> requesting markers) -----
    manpowerPerTickBase = 1;         // base manpower a port generates per 10s tick (6 men/min)
    manpowerPortAccumTicks = 12;     // ticks a port accumulates before shipping to a requesting base
    manpowerConvoySpeed = 14;        // abstract manpower convoy road speed m/s
    manpowerPortSmall = 100;         // port full footprint (m) for the 0.3x size multiplier
    manpowerPortLarge = 300;         // port full footprint (m) for the 0.9x size multiplier
    manpowerPerUnit = 1;             // 1 manpower per soldier recruited
    manpowerCaptureMult = 5;         // importance * this = manpower bonus on capture
    manpowerPortPlayerIncome = 2;    // player pool: manpower per port per tick

    // ----- Ammunition (MISSION_CORE_LOCATION_AMMO) -----
    // Ammo is a pure number, but it MOVES on the abstract road conveyor like manpower: a port
    // ships a batch to the nearest depot and a low marker orders from the nearest depot, both as
    // ETA convoys credited on arrival. Requires depot_ markers - there is no second donor type.
    ammoBasePerImp = 20;            // max ammo = importance * this * size factor
    // DEPOT ROWS ONLY: storage is multiplied by this, and they start at a random fraction between
    // the two start values rather than a flat 50%. A depot is a warehouse, not a garrison, so its
    // capacity should not scale with its combat importance - depots are importance 1, which put
    // them at roughly 9-13 while an absolute donor floor of 10 made every depot of 13 or less
    // permanently ineligible, even sitting full. Measured on a live RPT: depot caps vary
    // by marker (roughly 9-13 before this multiplier), ports were filling only 2 of the 12, and the
    // best-stocked depot on the whole side still read 6/13 - under a floor of 10. Doubling capacity
    // plus the proportional donor floor below fixes both halves of that. Both multipliers are
    // tunable so they can be walked back without a code edit.
    ammoDepotCapacityMult = 2;      // depot max ammo = normal max * this
    ammoDepotStartFracMin = 0.4;    // depot starting supply, randomised in [min, max)
    ammoDepotStartFracMax = 0.7;
    ammoPortRatePerImp = 0.5;       // ammo a port accumulates per tick (10s)
    ammoPortShipThreshold = 20;     // accumulated ammo a port puts on the road in one batch
    // Depot candidates a port or a marker tries on ONE dispatch before giving up. The candidates
    // are ranked (port: emptiest first; marker: nearest first), and a rank that cannot route is
    // skipped in favour of the next - so one dead station never holds a batch hostage. routePlan
    // already straight-falls on its own (supplyRouteStraightFallback) for the "last resort" leg.
    ammoRetryDepots = 3;
    ammoRequestThreshold = 0.3;     // order from a depot below this fraction of max
    ammoMaxPerRequest = 20;         // cap on one depot -> marker shipment
    ammoRequestCooldown = 120;      // per-marker seconds between orders
    // A depot donates only while it is above this fraction of its OWN cap, so a small depot is
    // never excluded by an absolute constant. This is the load-bearing pair with
    // ammoDepotCapacityMult: an absolute floor scales wrong, because on this map it excluded every
    // depot whose cap was at or below the floor even when completely full.
    ammoDonorStockFrac = 0.3;       // depot must retain this fraction of its cap to donate
    ammoDonorStockMin = 3;          // absolute floor for very small depots
    // Request propensity, shared with the resupply channel.
    //   chance = worth * urgency * (per-worth factor), capped at requestChanceMax
    //   worth   = MISSION_CORE_fnc_markerWorth - own tier value x proximity to the nearest tier
    //              0/1 marker, spanning 1.0 (nobody special, nobody valuable nearby) to 4.0
    //   urgency = 0.1 when sitting exactly on the trigger, 1.0 when completely empty
    // The 0.1 floor is load bearing: the stock tests only skip when the fraction is strictly WORSE
    // than the trigger, so a marker resting exactly on it does get evaluated and would otherwise
    // compute a chance of 0 and never order. Setting a per-worth factor to 0 does NOT disable the
    // channel - it forces chance to 0 everywhere, so that channel silently stops ordering
    // altogether. To make ordering unconditional instead, raise requestChanceMax well above 1.0
    // (the cap clamps at that value), which makes every evaluated marker pass the roll.
    // RAISED 0.25 -> 0.5. This is the global VOLUME dial: it scales every marker equally, so it
    // changes how often orders happen without changing their RANKING (an empty factory still
    // outranks an empty minor outpost). It multiplies worth x urgency, both of which are derived
    // from game state, so the low value was the only fixed term.
    //
    // Measured on a live RPT at 0.25: the roll produced chance 0.08 for a marker at worth 2.0 and
    // urgency 0.15 (just under the 0.3 trigger), i.e. ~1 order per 13 ten-second sweeps. Across 13
    // real opportunities that session every one was lost to this roll (chanceMiss=13, shipped=0)
    // while every other gate reported clean. At 0.5 the same marker sits near 0.15, ~1 in 7.
    // Set to 1.0 for ~0.30 (1 in 3); 1.5 gives ~0.45. requestChanceMax still clamps at 0.95 and
    // is not reached at these values.
    ammoRequestChancePerWorth = 0.5;
    requestChanceMax = 0.95;            // shared cap for both request channels
    // (requestSkipActiveProviders was retired: its only reader was the ammo channel's "a busy
    // donor also asks" gate, but the permanent depot rule makes that gate structurally redundant -
    // a depot is the only donor, and a depot never requests. Requests now queue without limit.)
    ammoConvoySpeed = 14;           // abstract ammo convoy road speed m/s
    ammoTruckLoad = 20;             // cargo one ammo truck carries (lost per recon truck kill)
    ammoCostAssaultWave = 3;        // spent fielding an assault wave
    ammoCostCounterAttack = 2;      // spent launching a counter-attack
    ammoCostHunt = 2;               // spent running a hunt for the players
    ammoCostArmorReinf = 3;         // spent ordering an armor replacement

    // ----- Armor reinforcement orders (abstract, materialize near players) -----
    // APC/mech replacements and the no-provider fallback ride the abstract conveyor too. The
    // order shows an icon along the road route; the vehicle is only created once the order has
    // arrived AND a player is inside the radius, so nothing pops in on an empty map. MBTs are
    // not here - they are built at a depot and travel as a TANK_SHIPMENT instead.
    armorOrderSpeed = 14;           // abstract armor order road speed m/s
    armorOrderCost = 8;             // supply the provider pays when the order is placed
    armorOrderMaterializeRadius = 1200;  // a player this close to the target sees it appear
    armorOrderTickInterval = 3;     // seconds between order checks while orders are in flight
    replenishMinEdgeRadius = 350;   // foot squads stand at least this far off the marker edge

    // ----- Supply convoys (MISSION_CORE_LOCATION_SUPPLY) -----
    // Only a BASE may be drained to supply another marker. Every marker keeps its own local
    // pool for its own garrison. See MISSION_RULES.md.
    supplyRouteSnapBase = 800;         // endpoint search radius = this + marker footprint radius
    supplyRouteNodeBudget = 25000;    // BFS node expansion cap on the road network
    supplyRouteRetryGrow = 2.5;       // how far a failing pair widens snap/budget on each retry
    supplyRouteRetryGrowSteps = 3;    // retries that actually widen; after this a pair retries at max width
    supplyRouteRetryGrowMax = 4;      // hard ceiling on that widening - unsquared, this bounds the deepest pass at 100k nodes
    supplyRouteFailBackoff = 30;      // base seconds before an unreachable pair is searched again
    supplyRouteFailBackoffMax = 600;  // ceiling on that backoff, so it never stops retrying forever
    supplyRouteTimeBudget = 5;        // max seconds a single BFS may burn (diag_tickTime wall clock) -
                                      // bounds the 100k-node worst pass so one unreachable pair can
                                      // never stall a calling loop past its 90s heartbeat
    supplyRouteStraightFallback = 1;  // 1 = unroutable pairs ship on a straight-line path instead of
                                      // being refused/held; the road search keeps retrying behind it,
                                      // so a later order upgrades the pair to a real route
    routeWarmEnabled = true;          // pre-resolve marker pairs at init so the first order is a cache hit
    routeWarmPairsPerWake = 2;        // pairs resolved per batch before yielding - higher batches cause a visible stutter
    routeWarmSleep = 0.5;             // seconds between batches, keeping the pre-warm off the mission's critical path
    routeDetourMaxHops = 12;          // transfer markers tried when two ends share no road
    routeDetourSearchRadius = 20000;  // how far from the origin a transfer marker may sit (m)
    supplyRouteRelayEnabled = 1;      // 1 = when a pair still fails after the retry ladder + detour,
                                      // thread it through road-adjacent markers near the straight
                                      // start->end line instead of leaving it to the straight fallback
    supplyRouteRelayLateral = 1500;   // corridor half-width: markers within this many metres of the
                                      // straight line are relay candidates
    supplyRouteRelayCandidates = 8;   // max corridor markers ranked per refusal; when none sit in the
                                      // band (an ocean crossing) the closest few overall still qualify
    supplyRouteRelayMaxHops = 3;      // max intermediate markers in a relay chain
    convoySupplyPerTruck = 100;      // supply cargo carried by one truck
    convoyColumnMax = 6;             // trucks in one convoy
    convoyColumnSpacing = 14;        // echelon spacing between trucks (m)
    // Vehicle per cargo class, so supply / ammo / manpower read differently on the map.
    // Each is config-checked at spawn; a missing class falls back to the supply truck.
    convoyTruckSupply = "O_Truck_02_covered_F";     // supply cargo
    convoyTruckAmmo = "O_Truck_02_reammo_F";        // ammunition
    convoyTruckManpower = "O_Truck_01_transport_F"; // manpower
    convoyArriveRadius = 150;        // delivery radius around the destination
    convoyStragglerGrace = 90;       // grace (s) after the leader arrives before force-delivery
    convoyLootBoxMax = 3;            // ammo boxes dropped when a shipment is lost

    // ----- Resupply orders (storer -> needy marker) -----
    // Independent of reinforcement. Reinforcement pays the SENDER's own pool and may use any
    // marker; this path is the only one where only a BASE may supply another marker.
    resupplyDispatchEveryTicks = 12; // convoy ticks between resupply sweeps (5s each = 60s)
    resupplyTriggerFrac = 0.35;      // order when stock falls under importance * this * 100
    resupplyTopUpAmount = 60;        // max supply ordered in one shipment
    resupplyStorerReserve = 40;      // a base keeps this much for itself before shipping
    resupplyStorerFloor = 30;        // below this a base stops shipping entirely
    resupplyRetryStorers = 3;        // bases one resupply order tries before giving up, nearest first
    resupplyCooldown = 300;          // per-requester cooldown between orders (s)
    // Same curve as the ammo channel, own pool instead. RAISED 0.25 -> 0.5 for the same reason and with
    // the same scaling: this is the volume dial, and the two channels are meant to answer "how
    // important is this marker" with identical arithmetic, so leaving this at 0.25 while the ammo
    // key went to 0.5 would have made the channels disagree about volume.
    resupplyChancePerWorth = 0.5;
    // CONTESTED-ASSIST EDGE - a slight priority for a marker ACTIVELY HELPING a contested zone when
    // it asks for supplies of its own. Resolved by MISSION_CORE_fnc_contestedAssistEdge (fn_ammo.sqf),
    // which reuses MISSION_CORE_fnc_getMarkerNeighbors as the definition of "helping", so this cannot
    // drift from who the troop channels consider a helper. A marker merely standing near a contested
    // zone, doing nothing, gets nothing.
    //
    // Applied as a MULTIPLIER on the roll before requestChanceMax, never as an addend: it shifts the
    // volume of orders without changing their rank, so a starving unimportant marker can never be
    // lifted above an empty important one.
    //
    // NEVER applies to a contested marker. Those are refused supply outright by a permanent rule in
    // both channels (fn_convoyLoop.sqf startConvoy, fn_ammo.sqf dispatchAmmoConvoy) and the helper
    // returns 1 for them, so this cannot become a back door around the ban.
    //
    // Set either to 1 to disable that channel's edge without touching the other.
    ammoContestedAssistEdge = 1.25;
    resupplyContestedAssistEdge = 1.25;

    // ----- Start state (recruit testing) -----
    startManpower = 500;             // initial BLUFOR player-manpower pool on mission start (testing: lots)
    startTanks = 20;                 // initial BLUFOR armor-pool tank points on mission start (testing: lots)

    captureHoldSeconds = 600;
    contestedGraceSeconds = 45;
    // How long a marker stays contested after its last reason to be contested stopped applying.
    // Distinct from contestedGraceSeconds above, which gates NEIGHBORHOOD DEACTIVATION. This one
    // gates the MISSION_CORE_CONTESTED latch in fn_isMarkerContested, so it must be long enough to
    // ride out a squad mid-move or one bad second, and short enough that an abandoned marker stops
    // drawing reinforcement.
    contestedClearGrace = 10;
    // How long a just-captured marker keeps WINDING DOWN the previous owner's response. Scales the
    // requested squad count toward zero across the window (1.0 -> 0.0) so a base that just fell is
    // still fought over by strength already in motion, but stops attracting fresh retake spawns and
    // gets released as a dead zone. Reads the MISSION_CORE_OCCUPATION occupied-at timestamp, so it
    // is the same clock as captureHoldSeconds - not a separate 20-minute retake window.
    captureWindDownWindow = 1200;
    neighborRange = 4000;

    scareApproachRadius = 2500;
    scareApproachFrac = 0.5;
    scareGroupMult = 0.15;
    scareCasualtyErode = 0.75;
    scareSizeRef = 400;
    scareAskSomeFrac = 0.4;
    scareAskAllFrac = 1.0;
    scareHoldReevalSeconds = 30;     // a HOLD marker is re-read this often (it dispatched nothing)
    scareReinfReevalSeconds = 300;   // a marker that dispatched REINFORCE re-asks this often
    scareCritReevalSeconds = 300;    // CRITICAL keeps asking every neighbor on the same cadence

    // NEIGHBOR REINFORCEMENT (per contested marker; the pool is the SUM of each provider's own
    // independent decision, so these scale one provider's commitment, not a shared pool).
    reinfMenCapPerMarker = 200;      // hard ceiling on men reinforcing one marker per contest
    // Dormant-zone budget bleed-back (men per commander tick; the commander sleeps 8-13s). The
    // spent budget above is never hard-reset - fn_reinforceDecayBudget gives it back gradually
    // while the zone is not contested, so a marker cannot be recharged to a full 200 by simply
    // going quiet. Importance is STATIC (the marker's own tier), not the live fight verdict.
    reinfDecayOrdinary = 1;      // importance 1 - ~30min to fully refund, effectively stays spent
    reinfDecayImportant = 2;     // importance 2 - about twice as fast
    reinfDecayCritical = 6;      // importance 3+ - fastest, so a high-value marker can be re-fought
    spawnerSlotCap = 5;             // markers per side allowed to spawn troops at once (10 total). An
    // exhausted provider gives its slot back (fn_reevalSpawnerSlots) and the next marker that needs
    // one claims it on demand - a marker that gave up no longer holds its slot forever.
    reinfForceSpawnMaxDist = 1000;  // fn_ensureMarkerActive only force-builds a garrison when a living
    // player is within this many metres of the marker CENTER. The AI contests and dispatches
    // map-wide, so without this a distant fight built whole neighborhoods the player never saw;
    // the proximity spawner still builds them on arrival.
    neighborAssetRange = 800;        // range over which a nearby tier 0/1 marker influences a provider
    neighborAssetTier0Influence = 2.0;  // provider right beside a critical (tier 0) marker
    neighborAssetTier1Influence = 1.35; // provider beside a tier 1 marker - a little more
    neighborTaperFrac = 0.5;         // full weight inside this fraction of neighborRange, then linear to 0
    counterAttackSpawnGateRadius = 2000;  // a queued counter-attack releases if a live player OR a
    // currently contested marker is within this radius of the target. The old rule required a
    // player, which silently dropped valid orders during player-less squad battles.
    assaultHoldContestedRadius = 800;     // a released assault group engaging within this range of a
    // marker keeps it contested (and its reinforcement pool open) even after the defending player
    // dies. Without it the marker gives up the moment the player is gone, stranding the assault.

    // ---- INTEREST CADENCE (how FAST a provider's own squads walk out) ----
    // The budget curve (_cVal * _asset * _taper, max 4.0) already measures how much a provider
    // cares about a contested zone. It decided HOW MANY men; these decide HOW OFTEN the queue
    // releases the next squad from that provider. Replaces the flat 30s tick for everyone.
    // A freed cap slot does NOT bypass the interval - the cadence is the pacing, so a casual
    // provider can leave a slot briefly idle rather than dumping a burst.
    reinfQueueTickUrgent = 4;        // seconds between squads at maximum interest (2.0 * 2.0 * 1.0)
    reinfQueueTickCasual = 45;       // seconds between squads at zero interest - slower than the old
                                     // flat 30s, so urgent and casual fights are actually distinct
    reinfQueueInterestMax = 4.0;     // interest that maps to reinfQueueTickUrgent; clamps above it
    reinfQueueRetryDelay = 20;       // seconds to wait after a real cap denial before retrying. NOT
                                     // the cadence - cadence paces a willing provider's squads, this
                                     // paces a job that is merely blocked. 60 retries x 20s ~ 20min

    assaultCooldown = 2400;
    assaultSupportRange = 1500;
    assaultTankBase = 2;
    assaultTankPerImp = 0.5;
    assaultTankMax = 4;
    assaultSquadCapture = 1;
    assaultLeaderQuads = 1;
    assaultLeaderHunts = 1;

    aggressionStart = 5;
    aggressionMax = 100;
    aggressionThreshold = 40;
    aggressionDriftEvery = 600;
    aggressionDriftAmt = 2;
    aggressionCaptureImp = 6;
    aggressionCaptureSize = 8;
    aggressionConvoyPerSupply = 0.25;
    aggressionDrainBase = 4;
    aggressionDrainPerImp = 2;
    aggressionDrainPerTank = 3;

    replenishCapPerMarker = 5;
    replenishRange = 2500;

    objDefendRange = 2500;
    objAttackNoteRange = 1500;
    objNoteCooldown = 300;
    intelApproachRange = 400;

    truckUnloadBuffer = 100;
    truckUnloadPush = 50;
    truckUnloadMaxPushes = 5;

    // ----- Transport staging waypoint (fn_transportStagePos) -----
    // A transport driver first drives to a staging point near its origin before setting off for the
    // target, so it does not cut through the fight while unloading. Deterministic, never random.
    transportStageRoadMin = 10;          // reject road candidates closer than this to the origin
    transportStageRoadMax = 300;         // search radius for a staging road
    transportStageFallbackDist = 50;     // no usable road -> stage exactly this far ahead
    transportStageCandidateCap = 24;     // nearRoads entries examined (matches fn_mountInfantry)

    // ----- Ordered-vehicle cleanup -----
    stuckVehicleTime = 240;
    stuckVehicleTick = 30;

    // ----- Drowned armour recovery (fn_vehicleDrowned.sqf) -----
    // How many times a group may drown before the hull is written off. 1 = rescue
    // never, write off on the first drowning. 2 = rescue once, then write off if it
    // drowns again. Player-owned hulls are always rescued and ignore this entirely.
    drownRescueLimit = 2;

    // BLUFOR AI behavior (0 = disabled, 1 = enabled)
    bluforAutoAttack = 0;
    bluforPatrolMarkers = 0;

    // Garrison tanks (player-recruited defenders) stay at their own marker: never pulled to
    // ally-defend / counter-attack / assault. 1 = stay home (default), 0 = AI can re-task them.
    garrisonStaysHome = 1;

    // PERMANENT RULE (NON-COMBAT-EFFECTIVE MARKERS): a Factory / Powerplant / Solar / Depot is a
    // production and logistics site. Its garrison defends in place and NEVER launches a
    // reinforcement, a counter-attack or an assault. It still captures, still fields its garrison
    // and static defenses, and still RECEIVES support from other markers - only the offensive half
    // is removed. Kept separate from the light-infrastructure rule, which also withholds static
    // defenses and must NOT be extended to factories or depots.
    // 1 = enforce (default). 0 = disable for debugging only - the rule is intended to be permanent.
    nonCombatEffectiveGate = 1;
    // Marker TYPES treated as non-combat-effective, lowercase. Compared against the cached marker
    // TYPE (position-cache row index 2), NOT the marker name.
    nonCombatEffectiveMarkers[] = {"factory", "powerplant", "solar", "depot"};

    // ----- ABSTRACT TRAVEL (long-range reinforcements / counter-attacks / assaults) -----
    // Applies to the 5 TROOP dispatch paths ONLY - requestReinforcement, replenishMarker,
    // neighborCounterAttack, assaultStaging, sendCounterAttack. No supply convoy, tank column,
    // ammo shipment or manpower shipment is abstracted, and their economics are untouched.
    //
    // A foot squad whose journey is this far or longer travels as an ABSTRACT LEG: a
    // cargo-like record with no units in the world, which only raises a real squad once a
    // player is near enough to see it or it reaches the final approach. Under this distance
    // nothing changes - dispatch is exactly as before.
    //
    // Measured as the straight line between the two markers' positions in
    // MISSION_CORE_CACHED_POSITIONS, i.e. the same endpoints fn_supplyRoutes routePlan
    // routes between. 2000m is deliberately well above routeLegFinalRadius (1000m): a leg
    // shorter than the handoff ring is born already inside it and would materialise and
    // hand off in the same second, which is a no-op with the dispatch's side effects.
    reinforceAbstractMinDist = 2000;
    // Ground speed (m/s) used to turn the routed distance into the leg's ETA. Matches the
    // default fn_supplyRoutes routePlan is called with, so legs and convoys agree.
    reinforceAbstractSpeed = 14;
    // How close a PLAYER must be to an abstract leg's position along the route before the
    // squad materialises. There is deliberately no destination-proximity trigger for troops:
    // an army marching into a fight the player is watching from 3km away should not pop into
    // existence. (Supply cargo DOES materialise on destination proximity - see below.)
    abstractLegPlayerRadius = 1200;
    // Safety valve, not a tuning knob. A pending leg reserves a foot-squad slot and only the
    // leg tick ever releases it, so a leg the tick loses track of holds that slot for the rest
    // of the mission - and since the neighbouring dispatch gates test the same cap, stranded
    // legs make the AI stop reinforcing while still queueing. This many seconds past a leg's
    // own travel time forces it into the world at its destination. Generous on purpose: it
    // should only ever fire for a leg the normal logic has lost, never during normal play.
    abstractLegPendingSlack = 180;

    // ----- ROUTE LEG WAYPOINTS (shared by convoys, tank columns and troop legs) -----
    // Stride between generated waypoints. A materialised convoy used to take the remaining
    // ROAD NODES of its route, so waypoint density depended on whatever the road network
    // happened to produce - long legs crawled, short ones snapped. Fixed stride instead.
    routeLegSpacing = 700;
    // ONE radius, two jobs: stop emitting stride waypoints inside it, AND hand a troop leg
    // off to its arrival script inside it. Sharing the value is what guarantees the two can
    // never drift into a gap - separate values could leave a squad idling past the handoff
    // ring, or hand it off before it reaches its leg. Both tests use distance2D to the
    // destination (never arc-length-remaining) so they always agree.
    routeLegFinalRadius = 1000;

    // ----- SUPPLY CARGO MATERIALISATION -----
    // Unlike troops, supply cargo is NOT distance-triggered: a shipment is a physical thing
    // and must arrive whether or not a player is watching. It stays abstract until a player
    // is within the radius below and only then becomes visible on the map.
    ammoMaterializePlayerRadius = 1200;
    manpowerMaterializePlayerRadius = 1200;

    // ----- Tune defaults promoted from SQF fallbacks -----
    // These keys were already live through the loader's per-call fallback but never
    // declared here, so tuning was impossible without editing code. Values above are
    // exactly what the mission ran with - promoted byte-for-byte, no behavior change.
    // Generated by opencode consolidation pass; edit freely from this point on.

    // from fn_isMarkerContested.sqf
    assaultContestKnows = 0.7;
    assaultStandoffRing = 250;

    // from fn_snatch.sqf
    commanderRerouteTimeout = 30;
    commanderSnatchEdgeScale = 1.2;
    commanderSnatchOwnTargetRange = 300;
    commanderSnatchRange = 1000;

    // from fn_assaultStaging.sqf
    counterAttackFlipWatchTTL = 600;
    counterAttackSupplyTTL = 90;

    // from fn_proximitySpawner.sqf
    despawnEnemyPastEdge = 500;

    // from fn_playerHunt.sqf
    huntFaintPosError = 250;

    // from fn_quadrantEngage.sqf
    lightInfraPatrolRadius = 300;

    // from fn_aiCommanderLoop.sqf
    quadrantEngageKnows = 1.2;

    // from fn_recon.sqf
    reconDestroyCap = 45;
    reconDetectBase = 20;
    reconDetectCap = 70;
    reconDetectEvery = 30;
    reconDetectPerUnit = 12;
    reconManpowerRenownMult = 0.5;
    reconMaxUnits = 4;
    reconSpotAltMax = 300;             // ASL height (m) at which a spotter reaches its band ceiling
    reconMoveSpeed = 13.411;           // recon move order travel speed m/s (30 mph)
    reconRedZoneRadius = 250;          // steer radius kept around each enemy marker

    // from fn_reconClient.sqf
    reconMenuRange = 200;

    reconRouteCap = 8;
    reconRouteKnownReveals = 2;
    reconStrikeBase = 15;
    reconStrikeCap = 65;
    reconStrikeEvery = 60;
    reconStrikePerUnit = 10;
    reconTankRenownMult = 1.2;
    reconTankStrikeMult = 0.6;
    reconUnitCostBase = 100;
    reconUnitCostStep = 75;

    // from fn_occupationMonitor.sqf
    renownCaptureMult = 3;

    // Free renown granted once at recon init, on top of the earned pool.
    // 0 = normal balance. Set high (e.g. 1000) to test recon unlocks/gear.
    renownFreeRecon = 1000;

    renownPerConvoy = 15;

    // from fn_replenishLoop.sqf
    replenishQuietPeriod = 120;

    // from fn_retreatPayout.sqf
    retreatBaseSeconds = 300;

    // from fn_getRetreatDest.sqf
    retreatMinDistance = 1500;

    // from fn_defenseSpotLoop.sqf
    standToProx = 600;

    // from fn_orderedVehicleCleanup.sqf
    stuckVehicleMove = 5;

    // from fn_transportStuckRecovery.sqf
    transportStuckMaxTries = 2;
    transportStuckMove = 3;
    transportStuckRadius = 400;
    transportStuckTick = 10;

    // from fn_truckCleanupLoop.sqf
    truckCleanupIdleWindow = 60;
};
