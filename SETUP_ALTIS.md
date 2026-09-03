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

## 4. Configure Era (optional)
Edit config/main.hpp:
  MISSION_CORE_ERA = "MODERN";  // MODERN, COLDWAR, WW2, WW3

## 5. Adjust Blacklist (optional)
Edit config/main.hpp -> BLACKLIST section to exclude unwanted mod classes.

## 6. Add Custom Compositions (optional)
Export from Eden Editor (right-click composition -> Export Composition) 
Save as .sqf files in comps/ folder:
  comps\my_custom_base.sqf
Then add to config/locations.hpp under the appropriate location type.

## 7. Preview / Play
- SP: Preview in Eden
- MP: Host server with the mission

## Key Markers to Place Minimum:
  hq_1 (BLUE)      -> Your main base / spawn
  factory_1 (RED)  -> Enemy factory
  compound_1 (RED) -> Enemy compound
  base_1 (RED)     -> Enemy base

The system auto-detects everything else from mods.
