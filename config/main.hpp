MISSION_CORE_ERA = "MODERN";
MISSION_CORE_BLUFOR_SIDE = WEST;
MISSION_CORE_REDFOR_SIDE = EAST;

class BLUFOR_FACTIONS {
    class MODERN  { faction = "NATO";     display = "NATO"; };
    class COLDWAR { faction = "USA";      display = "US Army"; };
    class WW2     { faction = "US_ARMY";  display = "US Army"; };
    class WW3     { faction = "NATO";     display = "NATO"; };
};
class REDFOR_FACTIONS {
    class MODERN  { faction = "CSAT";     display = "CSAT"; };
    class COLDWAR { faction = "RU";      display = "Soviet Army"; };
    class WW2     { faction = "GER";      display = "Wehrmacht"; };
    class WW3     { faction = "CSAT";     display = "CSAT"; };
};

// === BLACKLIST ===
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

// === LOCATION TYPES ===
class LOCATION_TYPES {
    class HQ        { prefix = "hq_";        type = "HQ";        radius[] = {100,250}; priority = 1; };
    class Airfield  { prefix = "airfield_";  type = "Airfield";  radius[] = {200,500}; priority = 2; };
    class Factory   { prefix = "factory_";   type = "Factory";   radius[] = {75,300};  priority = 3; };
    class Compound  { prefix = "compound_";  type = "Compound";  radius[] = {50,200};  priority = 3; };
    class Base      { prefix = "base_";      type = "Base";      radius[] = {100,400}; priority = 2; };
    class Town      { prefix = "town_";      type = "Town";      radius[] = {75,300};  priority = 3; };
    class Outpost   { prefix = "outpost_";   type = "Outpost";   radius[] = {50,150};  priority = 4; };
    class Depot     { prefix = "depot_";     type = "Depot";     radius[] = {50,200};  priority = 4; };
    class Port      { prefix = "port_";      type = "Port";      radius[] = {75,300};  priority = 3; };
    class Powerplant { prefix = "power_";    type = "Powerplant"; radius[] = {75,300}; priority = 3; };
    class Solar     { prefix = "solar_";     type = "Solar";     radius[] = {50,200};  priority = 4; };
};

// === DETECTION SETTINGS ===
class DETECTION {
    knowsAboutTrigger = 1.5;
    detectionRadius = 500;
    reinforceRadius = 800;
};

// === BALANCE TUNING (numbers only - tweak here, restart)
// Mirrored verbatim into description.ext -> missionConfigFile so the engine reads it. Every value
// below is consumed via MISSION_CORE_fnc_tune (see fnc\fn_tune.sqf). Keep current defaults.
class MISSION_CORE_TUNE {
    // ----- Foot / manpower budget -----
    footSquadRefMen = 6;            // 1 squad-equivalent = this many men (10 squads = 60)
    footSquadCapSquads = 10;        // weighted foot cap per side (in squad-equivalents)

    // ----- Marker size-weight (garrison scaling by footprint x importance) -----
    sizeWeightMinArea = 20000;      // marker footprint (a*b) at/below this = weight 0 (smallest garrison)
    sizeWeightMaxArea = 250000;     // marker footprint (a*b) at/above this = weight 1 (full garrison)
    sizeWeightImpFloor = 0.2;       // importance-1 markers ramp size bonus at this floor rate
    sizeWeightImpCeil = 1.0;        // importance-5 markers ramp at this ceiling rate
    sizeWeightMinMen = 6;           // smallest squad size for tiny/unimportant markers
    sizeWeightMaxMen = 12;          // largest squad size for big/important markers
    vehicleMinImportance = 2;       // markers BELOW this importance spawn foot-only (no vehicles)

    // ----- Proximity spawner -----
    proxSpawnRadius = 700;          // markers within X m of a player spawn a garrison
    proxDespawnDist = 2500;         // markers despawn when nearest player beyond this
    proxDespawnExhausted = 1500;    // ... sooner if the marker's reinforcement pool is spent
    proxMaxActive = 6;              // active marker budget per enemy side
    closeMarkerHysteresis = 50;     // contested handoff band: arm at half-gap-50, drop at half-gap+50

    // ----- Defense coordinator (static ring arms) -----
    defenseRadius = 1800;           // arm a defense ring when a player approaches within this
    defenseRingsPerSide = 2;        // max concurrent defense assignments per side
    defenseMinSpacing = 25;         // min spacing between placed defense comps

    // ----- House occupation -----
    houseSpawnRadius = 80;          // base spawn radius (priority 4/5 houses)
    houseDespawnRadius = 100;       // occupant despawns when player beyond this (uniform)
    houseMaxActive = 6;             // hard active-house cap (exempt from foot budget)
    houseMaxPerHouse = 2;           // max occupants per house (1-2)
    houseOverrideRadius = 20;       // player this close -> spawn house regardless of cap
    housePriorityRadiusMult = 2;    // bunker/military/guard-post houses spawn at spawnRadius x this
    cargoTowerSpawnRadius = 600;    // cargo towers: first defenders (top deck) spawn when player is within this
    cargoTowerDespawnRadius = 800;  // cargo towers: garrison despawns when the player withdraws beyond this
    cargoTowerMaxCount = 8;         // hard cap on defenders per cargo tower
    cargoTowerCount1 = 4;           // defenders once inside cargoTowerSpawnRadius (deck)
    cargoTowerCount2 = 6;           // +2 at 0.7x radius (floor below the deck)
    cargoTowerCount3 = 8;           // +2 at 0.5x radius (floor below that / ground)

    // ----- Quadrant engagement -----
    quadrantPerTargetMax = 99;      // max REDFOR foot groups staged per engaged player-quadrant per wave (99 = every eligible foot group; waves paced by quadrantBatchInterval)
    quadrantReleasePerTick = 3;     // groups dispatched per quadrant per commander tick (3 = three at a time)
    quadrantBatchInterval = 90;     // seconds to WAIT between per-target batches (send a wave, pause, see if more players spotted, send the next wave)
    quadrantMinSpanDeg = 20;        // minimum patrol sector wedge angle (large markers never go below this)
    quadrantSpanFalloffSize = 500;  // marker avg half-axis where the sector span halves (90 -> 45 deg); smaller markers stay wider
    quadrantReEvalInterval = 300;   // seconds between quadrant re-evals (repoint squads whose player moved to another sector)
    quadrantGraceTime = 600;        // keep streaming the quadrant response this long after the last live contact (sight lost)
    quadrantEngageKnows = 1.2;      // knowsAbout threshold for a player to count as engaging a marker (quadrant response)

    // ----- Hunt director -----
    huntDetectRange = 1200;         // player "near a marker" proximity for hunt tracking
    huntFaintKnows = 0.1;           // knowsAbout threshold for a *faint* sighting (usable only after a recent 0.7 contact)
    huntContactKnows = 0.7;         // knowsAbout threshold for a real contact (LOS required)
    huntFaintPosError = 250;        // max random LKP offset for a faint/stale sighting (weakest knowledge = most imprecise)
    huntIntelDecay = 60;            // seconds a shared sighting stays steerable
    huntSweepSeconds = 600;         // 10 min sweep clock from arrival at the LKP
    huntReSpotRadius = 30;          // non-LOS "stepped on him" bump radius
    huntRetargetEvery = 45;         // seconds between blind-sweep retargets
    huntClearEvery = 120;           // seconds between house-clears while sweeping
    huntMountDist = 700;            // far target -> squad mounts a transport
    huntSpawnMinPlayerDist = 500;   // fresh hunt contingents NEVER conjure within this of any alive player
    huntMaxContingents = 3;         // how many nearby markers each dispatch a hunting squad
    huntSourceMaxRange = 2500;      // a marker must be within this of the LKP to join the hunt

    // ----- Armor caps -----
    armorLocalMbtImp3 = 2;          // max local MBTs for importance >= 3
    armorLocalMbtLo = 1;            // max local MBTs otherwise
    armorOutpostMbtMax = 2;         // max outposts per side fielding MBTs
    armorReserveHold = 20;          // seconds an armor reservation is held
    armorGlobalFallback = 4;        // default global MBT cap if mission config unset

    // ----- Tank depot / production -----
    tankBuildInterval = 600;        // seconds between factory builds (1 per 10 min)
    tankDepotCapSmall = 10;         // storage cap for markers under 700m
    tankDepotCapLarge = 20;         // storage cap for markers at/over 700m
    tankShipColumnMax = 3;          // max tanks in a convoy column
    tankTravelSpeed = 18;           // abstract road travel speed m/s
    powerplantGlobalBonus = 0.2;    // +0.2x per same-side powerplant (all factories)
    powerplantNeighborBonus = 0.5;  // +0.5x per powerplant within neighbor range of a factory
    powerplantNeighborRange = 1500; // powerplant this close to a factory counts as its neighbor
    solarContribution = 0.25;       // a solar plant counts as this fraction of a powerplant

    // ----- Manpower economy (ports -> bases -> requesting markers) -----
    manpowerPerTickBase = 1;         // base manpower a port generates per 10s tick (6 men/min)
    manpowerPortAccumTicks = 12;     // ticks a port accumulates before shipping to a requesting base
    manpowerConvoySpeed = 14;        // abstract manpower convoy road speed m/s
    manpowerPortSmall = 100;         // port full footprint (m) for the 0.3x size multiplier
    manpowerPortLarge = 300;         // port full footprint (m) for the 0.9x size multiplier

    // ----- Start state (recruit testing) -----
    startManpower = 500;             // initial BLUFOR player-manpower pool on mission start (testing: lots)
    startTanks = 20;                 // initial BLUFOR armor-pool tank points on mission start (testing: lots)

    // ----- Capture / retake / retreat -----
    captureHoldSeconds = 600;        // 10 min hold to secure a captured marker
    retakeWindowSeconds = 1200;      // neighbor retake intensity decay window
    contestedGraceSeconds = 45;      // grace before neighbor squads retreat after contest ends
    neighborRange = 4000;            // neighbor reinforcement / deactivation radius
    retreatDespawnFallback = 300;    // seconds before a retreating squad despawns on its own

    // ----- Scare (threat-weight assessment) -----
    scareApproachRadius = 2500;      // meters a BLUFOR player/assault group must be within to scare a marker
    scareApproachFrac = 0.5;         // approaching (not inside) groups' weight counts at this fraction
    scareGroupMult = 0.15;           // +15% attacker weight per additional attacking group (coordination)
    scareCasualtyErode = 0.75;       // defender power erodes up to 75% as casualties approach retreatAt
    scareSizeRef = 400;              // marker radius that halves the scare via square-root size dampen
    scareAskSomeFrac = 0.4;          // REINFORCE: ask this fraction of the neighbor pool (few, closest)
    scareAskAllFrac = 1.0;           // CRITICAL: ask this fraction (all) of the neighbor pool

    // ----- Assault -----
    assaultCooldown = 2400;          // 40 min global assault cooldown
    assaultSupportRange = 1500;      // base friendly-support scan radius
    assaultTankBase = 2;             // tanks = base + floor(importance * tankPerImp), capped
    assaultTankPerImp = 0.5;
    assaultTankMax = 4;
    assaultSquadCapture = 1;        // 1 = released/active assault squads can capture a wiped marker without a player inside
    assaultLeaderQuads = 1;         // 1 = quads + counter-attacks target released/active assault leaders near the marker
    assaultLeaderHunts = 1;         // 1 = hunt director also tracks released/active assault leaders

    // ----- Aggression -----
    aggressionStart = 5;            // enemy aggression when the mission starts (low = holds off)
    aggressionMax = 100;            // cap
    aggressionThreshold = 40;       // below this NO assault launches (enemy holds off)
    aggressionDriftEvery = 600;     // seconds between passive drift ticks
    aggressionDriftAmt = 2;         // passive aggression gained per drift tick
    aggressionCaptureImp = 6;       // aggression per importance level of a player-secured marker
    aggressionCaptureSize = 8;      // aggression from a fully-sized marker footprint (0..1 weight)
    aggressionConvoyPerSupply = 0.25; // aggression per supply unit a destroyed convoy was carrying
    aggressionDrainBase = 4;        // aggression spent by committing ANY assault
    aggressionDrainPerImp = 2;      // extra spent per importance level of the assault source
    aggressionDrainPerTank = 3;     // extra spent per tank requested for the assault

    // ----- Replenish -----
    replenishCapPerMarker = 5;       // max alive replenish squads assigned per marker
    replenishRange = 2500;           // markers within this of a player are replenish candidates

    // ----- Objectives -----
    objDefendRange = 2500;           // defend objective wins when the threatened friendly is this close
    objAttackNoteRange = 1500;       // "attack" note triggers when within this of an enemy marker
    objNoteCooldown = 300;           // seconds between attack notes per player
    objHouseThreatRadius = 600;      // REDFOR within this of a friendly marker marks it "under attack"
    intelApproachRange = 400;        // player within this of an enemy marker -> show the intel panel

    // ----- Truck unload stand-off -----
    truckUnloadBuffer = 100;         // trucks stop this far outside the contested ellipse
    truckUnloadPush = 50;            // each truck-kill streak pushes the ring 50m further
    truckUnloadMaxPushes = 5;

    // ----- Ordered-vehicle cleanup -----
    stuckVehicleTime = 240;          // seconds an ordered vehicle may sit at spawn before it is considered stuck
    stuckVehicleRadius = 150;        // vehicle must have left this far from spawn to prove it is moving
    stuckVehicleTick = 30;           // sweep interval of the ordered-vehicle cleanup loop
};

