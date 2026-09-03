MISSION_CORE_fnc_detectFactions = {
    private _bluFaction = getText (missionConfigFile >> "BLUFOR_FACTION");
    private _redFaction = getText (missionConfigFile >> "REDFOR_FACTION");
    if (isNil "MISSION_CORE_VEHICLE_INFO") then { MISSION_CORE_VEHICLE_INFO = createHashMap; };

    // ============================================================
    // DYNAMIC FACTION BUILDER - categorizes everything by role
    // ============================================================
    private _buildFaction = {
        private _side = _this select 0;
        private _faction = _this select 1;

        // --- 1. Get all faction classes from CfgVehicles ---
        private _allEntries = "true" configClasses (configFile >> "CfgVehicles");
        private _factionClasses = _allEntries select { getText (_x >> "faction") == _faction && {getNumber (_x >> "scope") == 2} };

        // --- 2. Categorize UNITS (Man) by role ---
        private _men = _factionClasses select { configName _x isKindOf "Man" && !(configName _x isKindOf "Civilian") };

        // Role detection based on weapons/items/config
        private _categorizeMan = {
            private _cls = _x;
            private _name = configName _cls;
            private _weapons = getArray (_cls >> "weapons");
            private _items = getArray (_cls >> "items");
            private _linkedItems = getArray (_cls >> "linkedItems");
            private _backpack = getText (_cls >> "backpack");
            private _uniform = getText (_cls >> "uniformClass");
            private _role = "rifleman";

            if (_name find "SL" > -1 || _name find "Officer" > -1 || _name find "Leader" > -1) then { _role = "officer"; } else {
                if (_name find "TL" > -1 || _name find "Team" > -1) then { _role = "teamleader"; };
            };

            {
                private _w = _x;
                if (_w find "MG" > -1 || _w find "LMG" > -1 || _w find "Minimi" > -1 || _w find "MK200" > -1 || _w find "SPMG" > -1 || _w find "Zafir" > -1 || _w find "M249" > -1 || _w find "PK" > -1) then { _role = "autorifleman"; } else {
                    if (_w find "AT" > -1 || _w find "Titan" > -1 || _w find "Javelin" > -1 || _w find "RPG" > -1 || _w find "MAAWS" > -1 || _w find "PCML" > -1 || _w find "NLAW" > -1 || _w find "SMAW" > -1) then { _role = "at"; } else {
                        if (_w find "AA" > -1 || _w find "Stinger" > -1 || _w find "Igla" > -1 || _w find "Titan_AA" > -1 || _w find "MANPADS" > -1) then { _role = "aa"; } else {
                            if (_w find "Sniper" > -1 || _w find "DMR" > -1 || _w find "Mk14" > -1 || _w find "Mk18" > -1 || _w find "Rahim" > -1 || _w find "M320" > -1 || _w find "EBR" > -1 || _w find "SVD" > -1) then { _role = "marksman"; } else {
                                if (_w find "Medic" > -1 || _name find "Medic" > -1 || _linkedItems findIf { _x find "Medikit" > -1 } > -1) then { _role = "medic"; } else {
                                    if (_w find "Grenade" > -1 || _w find "UGL" > -1 || _w find "M320" > -1 || _w find "GP25" > -1) then { _role = "grenadier"; } else { _role = "rifleman"; }
                                }
                            }
                        }
                    }
                }
            } forEach _weapons;

            [_name, _role, _cls]
        };

        private _menData = _men apply _categorizeMan;

        // Group by role
        private _byRole = createHashMap;
        {
            private _r = _x select 1;
            private _lst = _byRole getOrDefault [_r, []];
            _lst pushBack (_x select 0);
            _byRole set [_r, _lst];
        } forEach _menData;

        // --- 3. Categorize VEHICLES by type ---
        private _vehicles = _factionClasses select { (configName _x isKindOf "LandVehicle" || configName _x isKindOf "Air" || configName _x isKindOf "Ship") && { !(configName _x isKindOf "StaticWeapon") } };

        // Recursive helpers for turret weapon and seat counts from CfgVehicles
        private _countTurretWeapons = {
            params ["_cfg"];
            private _n = 0;
            // PERMANENT RULE (ammo gate): only a weapon that actually CARRIES ROUNDS counts as a
            // mounted weapon - empty/aux/sensor mount configs (which name a weapon but load no
            // ammo) must never inflate the weapon count or flip a vehicle to "armed"/"attack".
            {
                private _w = _x;
                private _hasRounds = (getArray (configFile >> "CfgWeapons" >> _w >> "magazines")) findIf {
                    (getText (configFile >> "CfgMagazines" >> _x >> "ammo")) != ""
                } != -1;
                if (_hasRounds) then { _n = _n + 1; };
            } forEach (getArray (_cfg >> "weapons"));
            {
                _n = _n + ([_x] call _countTurretWeapons);
            } forEach ("true" configClasses (_cfg >> "turrets"));
            _n
        };
        private _countTurretSeats = {
            params ["_cfg"];
            private _n = 0;
            {
                _n = _n + 1 + ([_x] call _countTurretSeats);
            } forEach ("true" configClasses (_cfg >> "turrets"));
            _n
        };

        // Recursive scan of every hull/turret weapon config: returns [maxMagMm, hasAAWeapon,
        // hasMissile]. "mm" is read from the magazine class name (120mm, 762x51 = 7.62, 127x99 =
        // 12.7), not CfgAmmo "caliber" - a gameplay tuning constant with no physical meaning.
        private _aaWords = ["aa", "tunguska", "pantsir", "strela", "cheetah", "tigris", "zsu", "shilka", "gepard", "stinger", "igla", "adats", "starstreak", "flakpanzer"];
        // Ammo/weapon class hints for small-arms (7.62..12.7mm machine guns) vs vehicle cannon /
        // autocannon / grenade launcher. CfgAmmo "caliber" is a gameplay tuning constant, NOT a
        // physical mm value (a .50cal reads ~2.6, a 40mm GMG ~3.0, a 105mm tank ~35), so the
        // machine-gun-vs-cannon split is judged by class name rather than a numeric threshold.
        private _mgHints = ["127x99", "762x51", "_mg_", "_mg_", "_mg", "lmg", "m134", "minigun", "machinegun", "200rnd", "150rnd"];
        private _cannonHints = ["40mm", "_gmg", "gmg_", "30mm", "25mm", "20mm", "cannon", "mlrs", "_g_40", "_he", "_rocket", "autocannon", "scorch", "2a42", "autocannon_"];
        private _weaponScan = {
            params ["_turret"];
            private _maxC = 0;
            private _aaW = false;
            private _aaMissile = false;
            private _hasMG = false;
            private _hasCannon = false;
            {
                private _w = _x;
                private _wl = toLower _w;
                private _isCannon = (_cannonHints findIf { _wl find _x > -1 } > -1);
                private _isMG = (_mgHints findIf { _wl find _x > -1 } > -1);
                private _wHasRounds = false;
                {
                    private _mag = _x;
                    private _ammo = getText (configFile >> "CfgMagazines" >> _mag >> "ammo");
                    if (_ammo != "") then {
                        _wHasRounds = true;
                        private _al = toLower _ammo;
                        private _c = [_ammo, _mag] call MISSION_CORE_fnc_magToMm;
                        if (_c > _maxC) then { _maxC = _c; };
                        // machine-gun class by ammo name (only if the weapon carries rounds)
                        if (_isMG || { _mgHints findIf { _al find _x > -1 } > -1 }) then { _hasMG = true; };
                        // any cannon/autocannon/GMG-class ammo disqualifies a gun truck
                        if (_isCannon || { _cannonHints findIf { _al find _x > -1 } > -1 }) then { _hasCannon = true; };
                        if (_ammo isKindOf "MissileBase") then {
                            // Use CfgAmmo aiAmmoUsageFlags (a bitmask) to identify what a missile is
                            // for. 256 = OffensiveAir, 128 = OffensiveVeh, 512 = OffensiveArmour,
                            // 64 = OffensiveInf. An ANTI-AIR missile has the 256 bit; an anti-TANK /
                            // anti-vehicle missile (128/512/64) must NEVER score the vehicle as AA.
                            private _flags = getNumber (configFile >> "CfgAmmo" >> _ammo >> "aiAmmoUsageFlags");
                            if (_flags > 0) then {
                                if (_flags mod 512 >= 256) then { _aaMissile = true; };
                            } else {
                                // No flags defined: fall back to the class-name heuristic.
                                private _la = toLower _ammo;
                                if (_la find "_aa" > -1 || { _la find "stinger" > -1 } || { _la find "igla" > -1 } || { _la find "adats" > -1 } || { _la find "starstreak" > -1 }) then { _aaMissile = true; };
                            };
                        };
                        // An AA GUN is an AA/flak-named weapon firing 50cal (12.7mm)+ rounds.
                        // "_aa"/"aa_" avoids matching "maaws"/"laa" by accident.
                        if ((_wl find "_aa" > -1 || { _wl find "aa_" > -1 } || { _wl find "flak" > -1 }) && { _c >= 12.7 }) then { _aaW = true; };
                    };
                } forEach (getArray (configFile >> "CfgWeapons" >> _w >> "magazines"));
            } forEach (getArray (_turret >> "weapons"));
            {
                private _r = [_x] call _weaponScan;
                _maxC = _maxC max (_r select 0);
                if (_r select 1) then { _aaW = true; };
                if (_r select 2) then { _aaMissile = true; };
                if (_r select 3) then { _hasMG = true; };
                if (_r select 4) then { _hasCannon = true; };
            } forEach ("true" configClasses (_turret >> "turrets"));
            [_maxC, _aaW, _aaMissile, _hasMG, _hasCannon]
        };
        private _vehScan = {
            params ["_cls"];
            private _r = [0, false, false, false, false];
            {
                private _s = [_x] call _weaponScan;
                _r = [(_r select 0) max (_s select 0), (_r select 1) || (_s select 1), (_r select 2) || (_s select 2), (_r select 3) || (_s select 3), (_r select 4) || (_s select 4)];
            } forEach ("true" configClasses ((configFile >> "CfgVehicles" >> _cls) >> "turrets"));
            _r
        };

        // Classify by CONFIG - inheritance, weapon magazine-mm, artillery flag, and cargo capacity -
        // so addon vehicles are judged by what they actually are, not by their class names.
        private _categorizeVehicle = {
            private _cls = _x;
            private _name = configName _cls;
            private _turretWeapons = [_cls] call _countTurretWeapons;
            // Hull weapons count only if they carry rounds (same ammo gate as the turret counter).
            private _hullWeapons = 0;
            {
                private _w = _x;
                if ((getArray (configFile >> "CfgWeapons" >> _w >> "magazines") findIf { (getText (configFile >> "CfgMagazines" >> _x >> "ammo")) != "" }) != -1) then { _hullWeapons = _hullWeapons + 1; };
            } forEach (getArray (_cls >> "weapons"));
            private _mountedWeapons = _turretWeapons + _hullWeapons;
            private _fight = [_name] call _vehScan;
            private _caliber = _fight select 0;
            private _isMGClass = _fight select 3;
            private _hasCannonWep = _fight select 4;
            private _hasAAWep = _fight select 1;
            private _hasAAMissile = _fight select 2;
            private _crewSeats = (getNumber (_cls >> "hasDriver")) + ([_cls] call _countTurretSeats);
            private _cargoSeats = getNumber (_cls >> "transportSoldier");
            // CfgVehicles "side" is a NUMBER (0=WEST..3=CIV), not text, so getText on it returns
            // "". We already know the owning side from the faction being built, so derive it from
            // that enum instead - every vehicle under this faction belongs to it.
            private _sideStr = switch (_side) do {
                case WEST: { "WEST" };
                case EAST: { "EAST" };
                case INDEPENDENT: { "INDEP" };
                default { "CIV" };
            };
            private _type = "vehicle_other";

            // PERMANENT RULE (autonomous check): a remote-controlled UGV/UAV/drone is never a
            // crewed combat vehicle. UGVs inherit Tank/APC base classes and would otherwise be
            // miscounted as MBT/armor/transport in the faction's vehicle pools, so an autonomous
            // vehicle is always type "vehicle_other" no matter what it inherits or carries.
            private _autonomous = getNumber (_cls >> "autonomous") == 1;
            if (_autonomous) then { _type = "vehicle_other"; }
            else {
            if (_name isKindOf "Air") then {
                if (_name isKindOf "Helicopter") then {
                    if (_mountedWeapons > 0 && { _name find "Transport" == -1 }) then { _type = "heli_attack"; }
                    else {
                        // A helicopter is a TROOP transport only if it can actually carry people.
                        // Recon/utility drones (cargo 0, unarmed) are not transports - they would
                        // otherwise claim heli transport slots carrying nobody.
                        if (_cargoSeats > 0) then { _type = "heli_transport"; }
                        else { _type = "vehicle_other"; };
                    };
                } else { _type = "plane_cas"; };
            } else {
                if (_name isKindOf "Ship") then { _type = "boat"; }
                else {
                    private _lname = toLower _name;
                    // First gate: WHEELS vs TRACKS. Read the vehicle's own config flags, falling
                    // back to inheritance so vanilla AND mods are handled.
                    private _hasWheels = getNumber (_cls >> "hasWheels") == 1;
                    private _hasTracks = getNumber (_cls >> "hasTracks") == 1;
                    private _wheeled = _hasWheels || (_name isKindOf "Car") || (_name isKindOf "Wheeled_APC");
                    private _tracked = _hasTracks || (_name isKindOf "Tank") || (_name isKindOf "Tracked_APC");
                    // A "real turret" is a turret config that actually mounts an armed gun (cannon,
                    // machine gun, autocannon or AA) - NOT a bare sensor/RCWS turret with no weapon.
                    // Deliberately NOT gated on _caliber: a caliber parse failure (0) must never
                    // sink a tank/APC into the "no turret -> transport" path.
                    private _hasRealTurretWeapon = _hasCannonWep || { _isMGClass } || { _hasAAWep };
                    private _hasTurret = (count ("true" configClasses (_cls >> "turrets"))) > 0 && { _hasRealTurretWeapon };
                    private _armor = getNumber (_cls >> "armor");
                    private _isSPG = getNumber (_cls >> "artilleryScanner") == 1;

                    // Real SPGs/MLRS/mortars by name/flag first, no matter how they inherit.
                    if (_lname find "artillery" > -1 || { _lname find "arty" > -1 } || { _lname find "mlrs" > -1 } || { _lname find "scorcher" > -1 } || { _lname find "m270" > -1 } || { _lname find "grad" > -1 } || { _lname find "dana" > -1 } || { _isSPG }) then { _type = "artillery"; }
                    else {
                        // AA: an AA-named hull, or it carries a genuine anti-air gun / anti-air
                        // missile. An anti-TANK missile (Titan_AT, MAAWS, PCML, RPG) or a plain
                        // autocannon is NOT anti-air.
                        if (_name find "AA" > -1 || { _aaWords findIf { _lname find _x > -1 } > -1 } || { _hasAAWep } || { _hasAAMissile }) then { _type = "aa"; }
                        else {
                            if (_wheeled && { !_tracked }) then {
                                // ================= WHEELED =================
                                if (_hasTurret) then {
                                    // RULE (APC): a turreted wheeled vehicle carrying a squad (cargo >= 6)
                                    // or heavily armored (armor >= 200) -> APC.
                                    if (_cargoSeats >= 6 || { _armor >= 200 }) then { _type = "apc"; }
                                    else {
                                        // wheels + turret + MG-class armament (7.62..12.7mm machine gun) + barely
                                        // any cargo -> gun truck. Judged by weapon/ammo CLASS, not a numeric
                                        // threshold. A cannon/autocannon/GMG disqualifies it.
                                        if (_isMGClass && { !_hasCannonWep } && { _cargoSeats < 4 }) then { _type = "gunTruck"; }
                                        else {
                                            // artillery computer -> self-propelled gun
                                            if (_isSPG) then { _type = "artillery"; }
                                            else {
                                                // otherwise an armored fighting vehicle / fire support
                                                if (_caliber >= 7) then { _type = "afv"; }
                                                else { _type = "vehicle_other"; };
                                            };
                                        };
                                    };
                                } else {
                                    // wheeled, no turret
                                    if (_cargoSeats >= 3) then { _type = "transport"; }
                                    else { _type = "vehicle_other"; };
                                };
                            } else {
                                    // ================= TRACKED / OTHER =================
                                    if (_hasTurret) then {
                                        // RULE (MBT): tracks + a real turret + a real tank cannon
                                        // (cannon weapon, Tank base class, or >=100mm gun) -> MBT even if
                                        // it also carries cargo. A tracked hull with a big gun must never
                                        // be typed as an APC regardless of cargo.
                                        if (_hasCannonWep || { _name isKindOf "Tank" } || { _caliber >= 100 }) then { _type = "mbt"; }
                                        else {
                                            // RULE (APC): a turreted vehicle that carries a squad (cargo >= 6)
                                            // OR is heavily armored (armor >= 200) -> APC.
                                            if (_cargoSeats >= 6 || { _armor >= 200 }) then { _type = "apc"; }
                                            else {
                                                // tracked turret gun carrier without a squad or a real cannon
                                                if (_isMGClass) then { _type = "afv"; }
                                                else { _type = "vehicle_other"; };
                                            };
                                        };
                                    } else {
                                    // tracked, no turret
                                    if (_cargoSeats >= 3) then { _type = "transport"; }
                                    else { _type = "vehicle_other"; };
                                };
                            };
                    };
                };
            };
            };
            };
            [_name, _type, _cls, _mountedWeapons, _crewSeats, _cargoSeats, _sideStr, _caliber]
        };

        private _vehData = _vehicles apply _categorizeVehicle;

        private _byVehType = createHashMap;
        {
            private _t = _x select 1;
            private _lst = _byVehType getOrDefault [_t, []];
            _lst pushBack (_x select 0);
            _byVehType set [_t, _lst];
            // Expose full per-vehicle metadata for transport/cap decisions elsewhere
            MISSION_CORE_VEHICLE_INFO set [(_x select 0), [(_x select 1), (_x select 3), (_x select 4), (_x select 5), (_x select 6)]];
        } forEach _vehData;

        diag_log format ["DYNAMIC DETECT: %1 vehicles for %2 [v10]", count _vehData, _faction];
        { diag_log format ["DYNAMIC DETECT:   veh %1 type=%2 wep=%3 crew=%4 cargo=%5 side=%6 cal=%7", _x select 0, _x select 1, _x select 3, _x select 4, _x select 5, _x select 6, _x select 7]; } forEach _vehData;

        // --- 4. Categorize STATIONARY WEAPONS ---
        private _stationary = _factionClasses select { configName _x isKindOf "StaticWeapon" };
        private _categorizeStatic = {
            private _cls = _x;
            private _name = configName _cls;
            private _type = "static_other";
            if (_name find "MG" > -1 || _name find "HMG" > -1 || _name find "Minimi" > -1 || _name find "M2_" > -1 || _name find "Kord" > -1 || _name find "NSV" > -1 || _name find "DShK" > -1) then { _type = "hmg"; } else {
                if (_name find "AT" > -1 || _name find "TOW" > -1 || _name find "Kornet" > -1 || _name find "Metis" > -1 || _name find "Javelin" > -1 || _name find "Spike" > -1) then { _type = "at"; } else {
                    if (_name find "AA" > -1 || _name find "MANPADS" > -1 || _name find "Stinger" > -1 || _name find "Igla" > -1 || _name find "Tunguska" > -1 || _name find "Pantsir" > -1 || _name find "ZSU" > -1) then { _type = "aa"; } else {
                        if (_name find "Mortar" > -1 || _name find "Mk6" > -1 || _name find "2B14" > -1 || _name find "M252" > -1) then { _type = "mortar"; } else { _type = "static_other"; }
                    }
                }
            };
            [_name, _type]
        };
        private _staticData = _stationary apply _categorizeStatic;
        private _byStaticType = createHashMap;
        {
            private _t = _x select 1;
            private _lst = _byStaticType getOrDefault [_t, []];
            _lst pushBack (_x select 0);
            _byStaticType set [_t, _lst];
        } forEach _staticData;

        // --- 5. AMMO BOXES ---
        private _ammoBoxes = _factionClasses select { configName _x isKindOf "ReammoBox_F" } apply { configName _x };

        // --- 6. WEAPONS & MAGAZINES (from CfgWeapons/CfgMagazines) ---
        private _allWeps = "true" configClasses (configFile >> "CfgWeapons");
        private _weapons = _allWeps select { getNumber (_x >> "scope") == 2 && {getText (_x >> "faction") == _faction} } apply { configName _x };
        private _allMags = "true" configClasses (configFile >> "CfgMagazines");
        private _magazines = _allMags select { getNumber (_x >> "scope") == 2 && {getText (_x >> "faction") == _faction} } apply { configName _x };

        // --- 7. APPLY BLACKLIST ---
        private _cfgBLU = missionConfigFile >> "BLACKLIST" >> "Units" >> "patterns";
        private _blUnits = if (isClass _cfgBLU) then { getArray _cfgBLU } else { [] };
        private _cfgBLV = missionConfigFile >> "BLACKLIST" >> "Vehicles" >> "patterns";
        private _blVeh = if (isClass _cfgBLV) then { getArray _cfgBLV } else { [] };
        private _cfgBLW = missionConfigFile >> "BLACKLIST" >> "Weapons" >> "patterns";
        private _blWep = if (isClass _cfgBLW) then { getArray _cfgBLW } else { [] };
        private _filter = {
            private _list = _this;
            private _patterns = _this select 1;
            _list select { private _c = _x; !(_patterns findIf { _c find _x > -1 } > -1) };
        };
        _ammoBoxes = [_ammoBoxes, _blUnits] call _filter;
        _weapons = [_weapons, _blWep] call _filter;

        // --- 8. READ GROUPS FROM CfgGroups ---
        private _cfgSide = switch (_side) do {
            case WEST: { "West" };
            case EAST: { "East" };
            case INDEPENDENT: { "Indep" };
            case CIVILIAN: { "Civilian" };
            default { "" };
        };

        // Categorize a group: first by its parent CfgGroups category, then refine by name/units
        private _categorizeGroup = {
            params ["_grpConfig", "_grpUnits", "_catName"];
            private _grpName = configName _grpConfig;
            private _dispName = toLower (getText (_grpConfig >> "name"));
            private _hay = toLower (_grpName + " " + _dispName);

            // Step 0: base type comes from the parent CfgGroups category - matched by word, not an
            // exact name, so addon categories that are not literally "Infantry"/"Armored"/etc still
            // classify correctly (e.g. "Motorized_Infantry", "Panzergrenadier", "Recon_Infantry").
            private _base = "squad";
            private _lcCat = toLower _catName;
            if (_lcCat find "mechan" > -1 || _lcCat find "motor" > -1 || _lcCat find "panzergren" > -1 || _lcCat find "grenadier" > -1) then { _base = "mech"; }
            else {
                if (_lcCat find "armor" > -1 || _lcCat find "panzer" > -1 || _lcCat find "tank" > -1) then { _base = "tank"; }
                else {
                    if (_lcCat find "infantry" > -1 || _lcCat find "infanterie" > -1 || _lcCat find "schuetzen" > -1 || _lcCat find "rifle" > -1) then { _base = "inf"; }
                    else {
                        if (_lcCat find "air" > -1 || _lcCat find "helicopter" > -1 || _lcCat find "helikopter" > -1 || _lcCat find "luft" > -1) then { _base = "air"; }
                        else {
                            if (_lcCat find "naval" > -1 || _lcCat find "marine" > -1 || _lcCat find "seestreit" > -1) then { _base = "naval"; }
                            else {
                                if (_lcCat find "special" > -1 || _lcCat find "sonder" > -1 || _lcCat find "recon" > -1 || _lcCat find "aufklaerung" > -1) then { _base = "special"; };
                            };
                        };
                    };
                };
            };

            // Step 1: name signals (refine the base, never override it)
            private _hasAAName = _hay find "aa" > -1 || _hay find "air defense" > -1 || _hay find "anti-air" > -1 || _hay find "airdef" > -1;
            private _hasATName = _hay find "_at" > -1 || _hay find "anti-tank" > -1 || _hay find "antitank" > -1 || _hay find "tankhunter" > -1 || _hay find "at team" > -1 || _hay find "at squad" > -1;
            private _isRecon = _hay find "recon" > -1 || _hay find "sentry" > -1 || _hay find "patrol" > -1;
            // Anything in CfgGroups whose name says "spg" is self-propelled artillery, NOT armour -
            // even though the vehicle is still isKindOf "Tank".
            private _hasArtillery = _hay find "spg" > -1;

            // Step 2: drill into the units for AT/AA/vehicle signals
            private _hasMBT = false;
            private _hasAPC = false;
            private _hasAA = false;
            private _hasAAVehicle = false;
            private _hasAT = false;
            {
                private _uClass = _x;
                if (_uClass isKindOf "Tank") then {
                    if (_uClass find "AA" > -1 || _uClass find "Tunguska" > -1 || _uClass find "Pantsir" > -1 || _uClass find "ZSU" > -1 || _uClass find "Strela" > -1 || _uClass find "Tigris" > -1) then { _hasAA = true; _hasAAVehicle = true; } else { _hasMBT = true; };
                } else {
                    if (_uClass isKindOf "Wheeled_APC" || _uClass isKindOf "Tracked_APC") then {
                        if (_uClass find "AA" > -1 || _uClass find "Tunguska" > -1 || _uClass find "Pantsir" > -1 || _uClass find "ZSU" > -1) then { _hasAA = true; _hasAAVehicle = true; } else { _hasAPC = true; };
                    } else {
                        if (_uClass isKindOf "Man") then {
                            private _weps = getArray (configFile >> "CfgVehicles" >> _uClass >> "weapons");
                            {
                                private _w = _x;
                                if (_w find "AT" > -1 || _w find "Titan" > -1 || _w find "Javelin" > -1 || _w find "RPG" > -1 || _w find "MAAWS" > -1 || _w find "PCML" > -1 || _w find "NLAW" > -1 || _w find "SMAW" > -1) exitWith { _hasAT = true; };
                                if (_w find "AA" > -1 || _w find "Stinger" > -1 || _w find "Igla" > -1 || _w find "MANPADS" > -1) exitWith { _hasAA = true; };
                            } forEach _weps;
                        };
                    };
                };
            } forEach _grpUnits;

            // Step 3: resolve - base stays, role refined by AA/AT/arty
            if (_hasArtillery) exitWith { "artillery" };
            if (_hasAAVehicle) exitWith { "tank_aa" };
            if (_hasAA || _hasAAName) exitWith { format ["%1_aa", _base]; };
            if (_hasAT || _hasATName) exitWith { format ["%1_at", _base]; };
            if (_base == "inf" && _isRecon) exitWith { "recon"; };
            if (_base == "squad") then {
                if (_hasMBT) exitWith { "tank"; };
                if (_hasAPC) exitWith { "mech"; };
            };
            if (_base == "inf" && _hay find "weapon" > -1) exitWith { "inf_weapons"; };
            _base
        };

        private _groups = [];
        if (_cfgSide != "") then {
            private _cfgFaction = configFile >> "CfgGroups" >> _cfgSide >> _faction;
            if (!isClass _cfgFaction) exitWith {};
            // Scan EVERY category under the faction - the hardcoded 7-name list missed addon
            // categories that are not exactly "Infantry"/"Motorized"/etc. The word-based matcher
            // in _categorizeGroup classifies whatever category name is actually present.
            private _categories = "true" configClasses _cfgFaction;
            {
                private _catName = configName _x;
                private _cat = _cfgFaction >> _catName;
                if (isClass _cat) then {
                    private _catGroups = "true" configClasses _cat;
                    {
                        private _grpConfig = _x;
                        private _grpName = configName _grpConfig;
                        private _grpUnits = [];
                        for [{ _i = 0 }, { _i < 100 }, { _i = _i + 1 }] do {
                            private _u = _grpConfig >> format ["Unit%1", _i];
                            if (!isClass _u) then { _i = 100; };
                            if (_i < 100) then {
                                private _veh = getText (_u >> "vehicle");
                                if (_veh != "") then { _grpUnits pushBack _veh; };
                            };
                        };
                        if (count _grpUnits > 0) then {
                            private _subCat = [_grpConfig, _grpUnits, _catName] call _categorizeGroup;
                            _groups pushBack [_grpName, _grpUnits, count _grpUnits, _subCat, _catName];
                        };
                    } forEach _catGroups;
                };
            } forEach _categories;
        };

        diag_log format ["DYNAMIC DETECT: %1 groups from CfgGroups for %2", count _groups, _faction];
        { diag_log format ["DYNAMIC DETECT:   group %1 (%2 units, %3, cat=%4)", _x select 0, _x select 2, _x select 3, _x select 4]; } forEach _groups;

        // Recruitment pool: all available men
        private _recruitment = _menData apply { _x select 0 };

        // Return complete faction data structure
        [
            "side", _side,
            "faction", _faction,
            "roles", _byRole,
            "vehicles", _byVehType,
            "static", _byStaticType,
            "ammoBoxes", _ammoBoxes,
            "weapons", _weapons,
            "magazines", _magazines,
            "groups", _groups,
            "recruitment", _recruitment
        ]
    };

    private _bluData = [WEST, _bluFaction] call _buildFaction;
    private _redData = [EAST, _redFaction] call _buildFaction;

    diag_log format ["DYNAMIC DETECT: BLUFOR groups=%1, REDFOR groups=%2", count (_bluData select 17), count (_redData select 17)];

    [_bluData, _redData]
};

// Query cached CfgVehicles metadata: [type, mountedWeapons, crewSeats, cargoSeats, sideStr]
MISSION_CORE_fnc_vehInfo = {
    params ["_cls"];
    if (isNil "MISSION_CORE_VEHICLE_INFO") then { MISSION_CORE_VEHICLE_INFO = createHashMap; };
    private _info = MISSION_CORE_VEHICLE_INFO get _cls;
    if (isNil "_info") then {
        private _cfg = configFile >> "CfgVehicles" >> _cls;
        _info = ["", 0, 0, getNumber (_cfg >> "transportSoldier"), getText (_cfg >> "side")];
    };
    _info
};

// Foot-infantry template pool with priority: prefer PROPER CfgGroups infantry squads (Infantry
// category, or subcat starting "inf"), 4-9 men, all real combat riflemen. Only if none exist does
// it fall back to "all-men" - any template whose units are all combat riflemen regardless of how
// the addon categorised the group (Support/SpecOps/etc).
MISSION_CORE_fnc_getInfTemplates = {
    params ["_allGroups"];
    private _pref = _allGroups select {
        ((_x select 4) == "Infantry" || (_x select 3) find "inf" == 0) &&
        { (_x select 2) >= 4 && (_x select 2) <= 9 } &&
        { ({ !([_x] call MISSION_CORE_fnc_isCombatMan) } count (_x select 1)) == 0 }
    };
    if (count _pref == 0) then {
        _pref = _allGroups select {
            ({ !([_x] call MISSION_CORE_fnc_isCombatMan) } count (_x select 1)) == 0 &&
            { (_x select 2) >= 4 && (_x select 2) <= 9 }
        };
    };
    _pref
};

// Pick the faction's RIFLEMAN class(es) - the default infantryman, not a crewman/officer/AT/AA
// specialist. Emplacement MG gunners, manned-house occupants, and guard-post lookouts all use
// this so they are proper soldiers of the faction, not "B_crew_F" seat-warmers.
// _factionData = BLUFOR/REDFOR data block (index 5 = roles map, 19 = recruitment pool).
// Returns the rifleman pool (array), falling back to the recruitment pool, then a vanilla default.
MISSION_CORE_fnc_factionRiflemen = {
    params ["_factionData", ["_side", sideUnknown]];
    private _pool = [];
    // Roles map: "rifleman" key was built by fn_detect's _categorizeMan.
    if (count _factionData > 5 && { (_factionData select 5) isEqualType createHashMap }) then {
        _pool = (_factionData select 5) getOrDefault ["rifleman", []];
    };
    // Combat-man filter: drop any placeholder/crew/pilot that leaked into the role.
    _pool = _pool select { [_x] call MISSION_CORE_fnc_isCombatMan };
    if (count _pool == 0) then {
        if (count _factionData > 19) then { _pool = (_factionData select 19) select { [_x] call MISSION_CORE_fnc_isCombatMan }; };
    };
    if (count _pool == 0) then {
        _pool = if (_side == WEST) then { ["B_Soldier_F"] } else { ["O_Soldier_F"] };
    };
    _pool
};

// True when a Man class is a real combat rifleman: carries a primary weapon (rifle/carbine) and a
// medical kit, and is not a placeholder / specialist class (VR avatar, diver, general, civilian,
// unarmed, pilot, crew). Used to keep foot-infantry pools free of non-combat men.
MISSION_CORE_fnc_isCombatMan = {
    params ["_cls"];
    if (isNil "_cls" || { _cls == "" } || { !(_cls isKindOf "Man") }) exitWith { false };
    private _lc = toLower _cls;
    if (_lc find "virtual" > -1 || _lc find "vrguy" > -1 || _lc find "diver" > -1 || _lc find "general" > -1 || _lc find "civilian" > -1 || _lc find "unarmed" > -1 || _lc find "pilot" > -1 || _lc find "crew" > -1) exitWith { false };
    private _cfg = configFile >> "CfgVehicles" >> _cls;
    private _hasRifle = false;
    {
        private _type = getNumber (configFile >> "CfgWeapons" >> _x >> "type");
        if (_type == 1) exitWith { _hasRifle = true; };
    } forEach (getArray (_cfg >> "weapons"));
    if (!_hasRifle) exitWith { false };
    private _hasMed = false;
    {
        private _il = toLower _x;
        if (_il find "firstaid" > -1 || _il find "medikit" > -1 || _il find "medbag" > -1) exitWith { _hasMed = true; };
    } forEach (getArray (_cfg >> "items"));
    _hasMed
};

// Returns the nominal caliber (mm) of a round. The physical caliber lives in the AMMO class
// name (the actual round) - e.g. 120mm shells, 762x51, 76mm, 50BMG - which is the first arg.
// Some packs keep the caliber in the MAGAZINE class name instead (120mm, 762x51), so the
// magazine name is the fallback (second arg). Each name is parsed for a "<N>mm" pattern
// (120mm, 105mm, 40mm, 12.7mm) or the European "<N>x<M>" pattern, where the first number is
// the bore in hundredths of a mm (762x51 = 7.62mm, 127x99 = 12.7mm, 556x45 = 5.56mm). Returns
// 0 when nothing usable is found. This reads the physical caliber straight out of the class
// names, which is far more reliable than CfgAmmo "caliber" - a gameplay tuning constant with
// no physical meaning (.50cal ~2.6, 40mm GMG ~3.0, 105mm ~35).
MISSION_CORE_fnc_magToMm = {
    params [["_ammo", ""], ["_mag", ""]];
    private _mmOf = {
        private _n = toLower _this;
        private _digits = [48,49,50,51,52,53,54,55,56,57,46];
        private _i = _n find "mm";
        if (_i > 0) then {
            private _j = _i - 1;
            while { _j >= 0 && { (toArray _n select _j) in _digits } } do { _j = _j - 1; };
            private _tok = _n select [_j + 1, (_i - 1) - _j];
            private _val = parseNumber _tok;
            if (_val > 0) exitWith { _val };
        };
        private _x = _n find "x";
        if (_x > 0) then {
            private _j = _x - 1;
            while { _j >= 0 && { (toArray _n select _j) in _digits } } do { _j = _j - 1; };
            private _tok = _n select [_j + 1, (_x - 1) - _j];
            private _val = parseNumber _tok;
            if (_val >= 100) then { _val = _val / 100; };
            if (_val > 0) exitWith { _val };
        };
        0
    };
    private _v = _ammo call _mmOf;
    if (_v > 0) exitWith { _v };
    private _v2 = _mag call _mmOf;
    if (_v2 > 0) exitWith { _v2 };
    0
};

// Max TURRET-mounted weapon caliber (mm) of a vehicle (recursive scan).
MISSION_CORE_fnc_vehicleMaxCaliber = {
    params ["_cls"];
    private _scan = {
        params ["_turret"];
        private _m = 0;
        {
            private _weapon = _x;
            {
                private _ammo = getText (configFile >> "CfgMagazines" >> _x >> "ammo");
                if (_ammo != "") then {
                    private _c = [_ammo, _x] call MISSION_CORE_fnc_magToMm;
                    if (_c > _m) then { _m = _c; };
                };
            } forEach (getArray (configFile >> "CfgWeapons" >> _weapon >> "magazines"));
        } forEach (getArray (_turret >> "weapons"));
        {
            private _sub = [_x] call _scan;
            if (_sub > _m) then { _m = _sub; };
        } forEach ("true" configClasses (_turret >> "turrets"));
        _m
    };
    private _max = 0;
    {
        private _sub = [_x] call _scan;
        if (_sub > _max) then { _max = _sub; };
    } forEach ("true" configClasses ((configFile >> "CfgVehicles" >> _cls) >> "turrets"));
    _max
};

// True when any turret weapon (or one of its ammo classes) matches a cannon/autocannon/GMG class
// name hint. Same hint list and scanning the vehicle categorizer uses to type MBTs - numeric
// caliber is not used here because magazine class names no longer parse to a reliable mm value
// for the big-gun rounds (120mm/etc read as 0).
MISSION_CORE_fnc_hasCannonWeapon = {
    params ["_cls"];
    private _cannonHints = ["40mm", "_gmg", "gmg_", "30mm", "25mm", "20mm", "cannon", "mlrs", "_g_40", "_he", "_rocket", "autocannon", "scorch", "2a42", "autocannon_"];
    private _scan = {
        params ["_turret"];
        private _found = false;
        {
            private _wl = toLower _x;
            {
                private _mag = _x;
                private _al = toLower _mag;
                private _ammo = toLower (getText (configFile >> "CfgMagazines" >> _mag >> "ammo"));
                if (_ammo != "" && {
                    (_cannonHints findIf { _wl find _x > -1 } > -1) ||
                    { (_cannonHints findIf { _al find _x > -1 } > -1) } ||
                    { (_cannonHints findIf { _ammo find _x > -1 } > -1) }
                }) exitWith { _found = true; };
            } forEach (getArray (configFile >> "CfgWeapons" >> _x >> "magazines"));
        } forEach (getArray (_turret >> "weapons"));
        if (!_found) then {
            {
                if ([_x] call _scan) exitWith { _found = true; };
            } forEach ("true" configClasses (_turret >> "turrets"));
        };
        _found
    };
    private _found = false;
    {
        if ([_x] call _scan) exitWith { _found = true; };
    } forEach ("true" configClasses ((configFile >> "CfgVehicles" >> _cls) >> "turrets"));
    _found
};

// True when the class is a real main battle tank: a "Tank" base, not self-propelled artillery,
// carrying a turret cannon. Matches the categorizer's MBT rule so the recruit tank pool never
// disagrees with detection - a Tank-base hull or a cannon-class turret counts, no numeric caliber.
MISSION_CORE_fnc_isTank = {
    params ["_cls"];
    if (isNil "_cls" || { _cls == "" } || { !(_cls isKindOf "Tank") }) exitWith { false };
    if (getNumber (configFile >> "CfgVehicles" >> _cls >> "artilleryScanner") == 1) exitWith { false };
    ([_cls] call MISSION_CORE_fnc_hasCannonWeapon) || { ([_cls] call MISSION_CORE_fnc_vehicleMaxCaliber) >= 100 }
};

// True when the class is an armored personnel carrier / IFV (tracked or wheeled) with a weapon of
// 7.62mm or bigger. "Armored" is judged by the vehicle's own config armor value (armor >= 100),
// because vanilla APCs/AFVs don't inherit the Wheeled_APC/Tracked_APC base classes. An MBT/100mm+
// gun hull is NOT an APC.
MISSION_CORE_fnc_isAPC = {
    params ["_cls"];
    if (isNil "_cls" || { _cls == "" }) exitWith { false };
    if (getNumber (configFile >> "CfgVehicles" >> _cls >> "armor") < 100 &&
        { !(_cls isKindOf "Wheeled_APC") } && { !(_cls isKindOf "Tracked_APC") } && { !(_cls isKindOf "Tank") }) exitWith { false };
    if ([_cls] call MISSION_CORE_fnc_isTank) exitWith { false };
    ([_cls] call MISSION_CORE_fnc_vehicleMaxCaliber) >= 7
};

// True when the vehicle is armored (a real fighting vehicle with config armor >= 100, or one of
// the Tank/Wheeled_APC/Tracked_APC base classes).
MISSION_CORE_fnc_isArmoredVehicle = {
    params ["_cls"];
    if (isNil "_cls" || { _cls == "" }) exitWith { false };
    (getNumber (configFile >> "CfgVehicles" >> _cls >> "armor") >= 100) ||
    { (_cls isKindOf "Tank") } || { (_cls isKindOf "Wheeled_APC") } || { (_cls isKindOf "Tracked_APC") }
};

// Cargo (transportSoldier) capacity of a vehicle.
MISSION_CORE_fnc_vehicleCargo = {
    params ["_cls"];
    getNumber (configFile >> "CfgVehicles" >> _cls >> "transportSoldier")
};

// True when the class carries a mounted weapon (hull or any turret) of 7.62mm or bigger. An
// "unarmed" transport is one where this returns false.
MISSION_CORE_fnc_vehicleArmed = {
    params ["_cls"];
    if (isNil "_cls" || { _cls == "" }) exitWith { false };
    ([_cls] call MISSION_CORE_fnc_vehicleMaxCaliber) >= 7
};

// True when the class is a ground troop transport: can carry a squad (transportSoldier >= 3 -
// support trucks with 1-2 seats like ammo/fuel/repair are NOT troop transports) and is not an APC,
// MBT, or self-propelled artillery. Armed/unarmed via MISSION_CORE_fnc_vehicleArmed, size via
// MISSION_CORE_fnc_transportTier.
MISSION_CORE_fnc_isTransport = {
    params ["_cls"];
    if (isNil "_cls" || { _cls == "" }) exitWith { false };
    if (!(_cls isKindOf "LandVehicle")) exitWith { false };
    if ((getNumber (configFile >> "CfgVehicles" >> _cls >> "transportSoldier")) < 3) exitWith { false };
    if ([_cls] call MISSION_CORE_fnc_isAPC) exitWith { false };
    if ([_cls] call MISSION_CORE_fnc_isTank) exitWith { false };
    if ([_cls] call MISSION_CORE_fnc_isArtilleryVehicle) exitWith { false };
    true
};

// Cargo-capacity tier of a transport: "light" (<=6 seats), "medium" (7-12), "heavy" (>12).
MISSION_CORE_fnc_transportTier = {
    params ["_cls"];
    private _c = [_cls] call MISSION_CORE_fnc_vehicleCargo;
    if (_c <= 6) exitWith { "light" };
    if (_c <= 12) exitWith { "medium" };
    "heavy"
};

// True when the class is a self-propelled artillery / MLRS / line-mortar vehicle (armored or
// soft-skin). Split armored vs not with MISSION_CORE_fnc_isArmoredVehicle.
MISSION_CORE_fnc_isArtilleryVehicle = {
    params ["_cls"];
    if (isNil "_cls" || { _cls == "" }) exitWith { false };
    private _lname = toLower _cls;
    if (_lname find "artillery" > -1 || { _lname find "arty" > -1 } || { _lname find "mlrs" > -1 } || { _lname find "scorcher" > -1 } || { _lname find "m270" > -1 } || { _lname find "grad" > -1 } || { _lname find "dana" > -1 }) exitWith { true };
    if (getNumber (configFile >> "CfgVehicles" >> _cls >> "artilleryScanner") == 1) exitWith { true };
    // Addon fallback: a big (60mm+) non-cannon weapon on a soft-skin (unarmored) chassis is field
    // artillery. Armored AFVs/IFVs carrying a heavy autocannon are combat vehicles, NOT artillery -
    // judged by the vehicle's own config armor value (vanilla AFVs/APCs don't inherit the
    // *_APC/Tank base classes), so the soft-skin check also excludes any high-armor hull.
    if (getNumber (configFile >> "CfgVehicles" >> _cls >> "armor") >= 100) exitWith { false };
    if (_cls isKindOf "Tank" || _cls isKindOf "Wheeled_APC" || _cls isKindOf "Tracked_APC") exitWith { false };
    ([_cls] call MISSION_CORE_fnc_vehicleMaxCaliber) >= 60
};

// True when the class is an anti-air vehicle: carries an AA-named gun (50 cal+ round) or an
// anti-AIR missile. Anti-tank missiles / plain autocannons are NOT anti-air. Split armored vs not
// with MISSION_CORE_fnc_isArmoredVehicle.
MISSION_CORE_fnc_isAAVehicle = {
    params ["_cls"];
    if (isNil "_cls" || { _cls == "" }) exitWith { false };
    private _aaWords = ["aa", "tunguska", "pantsir", "strela", "cheetah", "tigris", "zsu", "shilka", "gepard", "stinger", "igla", "adats", "starstreak", "flakpanzer"];
    private _lname = toLower _cls;
    private _hasAAClass = (_cls find "AA") > -1 || { _aaWords findIf { _lname find _x > -1 } > -1 };
    private _scan = {
        params ["_turret"];
        private _maxC = 0;
        private _aaW = false;
        private _aaMissile = false;
        {
            private _wl = toLower _x;
            {
                private _ammo = getText (configFile >> "CfgMagazines" >> _x >> "ammo");
                if (_ammo != "") then {
                    private _c = [_ammo, _x] call MISSION_CORE_fnc_magToMm;
                    if (_c > _maxC) then { _maxC = _c; };
                    if (_ammo isKindOf "MissileBase") then {
                        private _la = toLower _ammo;
                        if (_la find "_aa" > -1 || { _la find "stinger" > -1 } || { _la find "igla" > -1 } || { _la find "adats" > -1 } || { _la find "starstreak" > -1 }) then { _aaMissile = true; };
                    };
                    if ((_wl find "_aa" > -1 || { _wl find "aa_" > -1 } || { _wl find "flak" > -1 }) && { _c >= 12.7 }) then { _aaW = true; };
                };
            } forEach (getArray (configFile >> "CfgWeapons" >> _x >> "magazines"));
        } forEach (getArray (_turret >> "weapons"));
        {
            private _r = [_x] call _scan;
            _maxC = _maxC max (_r select 0);
            if (_r select 1) then { _aaW = true; };
            if (_r select 2) then { _aaMissile = true; };
        } forEach ("true" configClasses (_turret >> "turrets"));
        [_maxC, _aaW, _aaMissile]
    };
    private _r = [0, false, false];
    {
        private _s = [_x] call _scan;
        _r = [(_r select 0) max (_s select 0), (_r select 1) || (_s select 1), (_r select 2) || (_s select 2)];
    } forEach ("true" configClasses ((configFile >> "CfgVehicles" >> _cls) >> "turrets"));
    _hasAAClass || { (_r select 1) } || { (_r select 2) }
};

