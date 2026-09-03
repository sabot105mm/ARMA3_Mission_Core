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
