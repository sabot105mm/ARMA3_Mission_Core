# SETUP ON ALTIS (or any map)

## 1. Copy Mission Folder
Copy the entire ARMA3_Mission_Core folder to your Arma 3 missions folder:
  %LOCALAPPDATA%\Arma 3\missions\ARMA3_Mission_Core.Altis
  (or Documents\Arma 3\missions\ARMA3_Mission_Core.Altis)

The .Altis suffix tells Arma 3 this is an Altis mission.

## 2. Open in Eden Editor
1. Launch Arma 3
2. Open Eden Editor
3. Open mission: ARMA3_Mission_Core.Altis

## 3. Place Markers (REQUIRED - this drives the whole system)
Place markers with these EXACT prefixes (case-insensitive):

BLUFOR markers (blue color) = player spawn points:
  hq_1, hq_2              -> HQ (priority 1, large base)
  base_1, base_2          -> Base (priority 2)
  airfield_1              -> Airfield (priority 2)
  factory_1, factory_2    -> Factory (priority 3)
  compound_1, compound_2  -> Compound (priority 3)
  town_1, town_2          -> Town (priority 3)
  depot_1                 -> Depot (priority 4)
  outpost_1               -> Outpost (priority 4)
  watch_1                 -> Watchtower (priority 5)

REDFOR markers (red/opfor color) = enemy locations:
  Same prefixes: factory_1, base_1, compound_1, hq_1, etc.

## 4. Choose Factions (optional)
Edit config/missionVars.hpp:
  BLUFOR_FACTION = "CUP_B_USMC";   // any configFile faction class
  REDFOR_FACTION = "CUP_O_RU";

The era is implied by the faction you pick (CUP_B_USMC/CUP_O_RU = modern).
There is no MISSION_CORE_ERA setting - the old one lived in config\main.hpp,
which nothing ever loaded; it had no effect and has been removed.

## 5. Adjust Blacklist (optional)
Edit config\missionVars.hpp -> BLACKLIST section to exclude unwanted mod classes.

## 6. Add Custom Compositions (optional)
Export from Eden Editor (right-click composition -> Export Composition) 
Save as .sqf files in comps/ folder:
  comps\my_custom_base.sqf
Then add to config\missionVars.hpp under `class LOCATION_PRESETS`, in the
compositions[] list of the appropriate location type.

Compositions only appear at locations that have defender positions assigned, so
adding a type here does not by itself put objects on the map.

## 7. Preview / Play
- SP: Preview in Eden
- MP: Host server with the mission

## Key Markers to Place Minimum:
  hq_1 (BLUE)      -> Your main base / spawn
  factory_1 (RED)  -> Enemy factory
  compound_1 (RED) -> Enemy compound
  base_1 (RED)     -> Enemy base

The system auto-detects everything else from mods.
