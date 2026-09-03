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
    houseSpawnRadius = 80;          // occupant spawns when player within this
    houseDespawnRadius = 140;       // occupant despawns when player beyond this
    houseMaxActive = 6;             // hard active-house cap (exempt from foot budget)
    houseMaxPerHouse = 2;           // max occupants per house (1-2)

    // ----- Hunt director -----
    huntDetectRange = 1200;         // player "near a marker" proximity for hunt tracking
    huntFaintKnows = 0.1;           // knowsAbout threshold for a *faint* sighting (dispatch)
    huntContactKnows = 0.7;         // knowsAbout threshold for a real contact (LOS required)
    huntIntelDecay = 60;            // seconds a shared sighting stays steerable
    huntSweepSeconds = 600;         // 10 min sweep clock from arrival at the LKP
    huntReSpotRadius = 30;          // non-LOS "stepped on him" bump radius
    huntRetargetEvery = 45;         // seconds between blind-sweep retargets
    huntClearEvery = 120;           // seconds between house-clears while sweeping
    huntMountDist = 700;            // far target -> squad mounts a transport
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

    // ----- Capture / retake / retreat -----
    captureHoldSeconds = 600;        // 10 min hold to secure a captured marker
    retakeWindowSeconds = 1200;      // neighbor retake intensity decay window
    contestedGraceSeconds = 45;      // grace before neighbor squads retreat after contest ends
    neighborRange = 4000;            // neighbor reinforcement / deactivation radius
    retreatDespawnFallback = 300;    // seconds before a retreating squad despawns on its own

    // ----- Assault -----
    assaultCooldown = 2400;          // 40 min global assault cooldown
    assaultSupportRange = 1500;      // base friendly-support scan radius
    assaultTankBase = 2;             // tanks = base + floor(importance * tankPerImp), capped
    assaultTankPerImp = 0.5;
    assaultTankMax = 4;

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
};

