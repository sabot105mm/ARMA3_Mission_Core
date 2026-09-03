// Client-side FIELD MANUAL help menu. Opened via the H key (registered in initPlayerLocal.sqf).
// The topic list (idc 1572) is populated on load; selecting a topic fills the structured-text body
// (idc 1573) with a full explanation of that mechanic. Content is a [title, body] pair per topic.

MISSION_CORE_fnc_helpMenuTopics = {
    [
        ["Welcome",
            "<t size='1.2' color='#ffd24a'>Dynamic Operations</t><br/>You are BLUFOR fighting to capture REDFOR-held territory on the island. The map is divided into <t color='#7ee07e'>markers</t> - each is a location with a defending garrison.<br/><br/>Your goal: <t color='#ff9a9a'>capture enemy markers</t> and <t color='#ff9a9a'>defend your own</t> against counter-attacks and AI assaults. There is no single win condition - push the front, starve their industry, and survive."],
        ["Markers & Territory",
            "Every named location on the map is a <t color='#7ee07e'>marker</t> with an owner.<br/><br/><t color='#ff9a9a'>RED markers = enemy (REDFOR)</t> - capture these.<br/><t color='#7ee07e'>BLUE markers = yours (BLUFOR)</t> - defend these.<br/><t color='#ffd24a'>Grey loc_ markers</t> are auto-generated towns/villages - they spawn garrisons and can be captured too.<br/><br/>Marker types matter: an <t color='#ff9a9a'>HQ</t> is their command center, a <t color='#ff9a9a'>Factory</t> builds tanks, a <t color='#ff9a9a'>Depot</t> stores a tank reserve, a <t color='#ff9a9a'>Base</t> holds armor, <t color='#ff9a9a'>Town/Compound/Outpost</t> are garrisoned strongpoints."],
        ["Garrisons & Spawning",
            "Markers only field a garrison when a player is <t color='#7ee07e'>nearby</t> (approx 700m of a normal marker, measured from its center). Far-away markers are dormant.<br/><br/>When you approach, the garrison spawns (infantry, armor, static weapons). Move far enough away and it despawns again - this keeps the map alive without swamping the server.<br/><br/>Big markers (>700m wide) spawn their garrison as soon as you are 100m outside their edge, so you never walk into an empty base."],
        ["Capturing a Marker",
            "To capture an enemy marker:<br/>1. <t color='#ffd24a'>Approach</t> it and eliminate its garrison (the AI counter-attacks while you fight).<br/>2. <t color='#ffd24a'>Walk into</t> the marker once its garrison is wiped or has retreated.<br/>3. The marker becomes <t color='#ffd24a'>OCCUPIED</t> - you must <t color='#ff9a9a'>hold it for 10 minutes</t> while the previous owner counter-attacks to take it back.<br/>4. After 10 minutes it flips permanently to you.<br/><br/>If you leave or die during the hold, it reverts to the enemy. An empty marker you never actually fought cannot be captured - its garrison must have spawned first."],
        ["Enemy AI & Counter-Attacks",
            "The enemy commander reacts to you:<br/>- <t color='#ffd24a'>Contested marker</t>: once you engage a garrison, its neighbors dispatch counter-attack squads and tanks toward it.<br/>- <t color='#ffd24a'>Assaults</t>: enemy markers launch full scripted assaults on your BLUFOR positions (with factory-built tanks).<br/>- <t color='#ffd24a'>Hunting</t>: if the enemy <t color='#ff9a9a'>sees you</t> (line-of-sight + awareness), nearby squads sweep toward your last known position.<br/>- <t color='#ffd24a'>Retreat</t>: a garrison that loses too many men retreats to the nearest friendly marker and despawns."],
        ["House Occupation (Red Squares)",
            "In built-up markers, small <t color='#ff9a9a'>red squares</t> mark houses that may hide enemy ambushers.<br/><br/>As you get close to a house, 1-2 enemy soldiers spawn inside at random positions and wait silently. Clear them out to be safe.<br/><br/>Once a house's occupants are dead, its square turns <t color='#7ee07e'>green</t> - that house is cleared and will never spawn ambushers again."],
        ["Tank Industry & Power",
            "Tanks are produced by a real economy:<br/>- <t color='#ffd24a'>Factories</t> build tanks into their own storage (1 per 10 minutes).<br/>- <t color='#ffd24a'>Power Plants</t> speed up ALL your factories (+0.2x each); a power plant next to a factory adds +0.5x to that factory.<br/>- <t color='#ffd24a'>Solar Plants</t> count as a quarter of a power plant.<br/>- <t color='#ffd24a'>Bases & Depots</t> store tank reserves and fill tank requests.<br/>- Capturing enemy factories/power cuts their tank supply; holding your own keeps yours flowing."],
        ["Power Plants",
            "<t color='#ffd24a'>Power Plants</t> are industrial sites that generate electricity for tank production.<br/><br/><t color='#7ee07e'>Global bonus:</t> each power plant your side holds gives <t color='#7ee07e'>+0.2x</t> tank production to EVERY factory on your side. Hold 3 power plants and all your factories build 60% faster.<br/><br/><t color='#7ee07e'>Neighbor bonus:</t> a power plant within 1500m of a factory adds a further <t color='#7ee07e'>+0.5x</t> to that specific factory.<br/><br/>Example: a factory next to one power plant (and 2 more elsewhere on your side) builds at 1 + 0.2*3 + 0.5 = <t color='#ff9a9a'>2.1x</t> speed.<br/><br/><t color='#ff9a9a'>Why take them:</t> capturing enemy power plants starves their tank production and accelerates yours - they are high-value strategic targets even without a big garrison."],
        ["Solar Plants",
            "<t color='#ffd24a'>Solar Plants</t> are smaller power generators - solar farms or arrays that produce less than a full power plant.<br/><br/>Each solar plant counts as <t color='#7ee07e'>a quarter (0.25x) of a power plant</t> for tank production bonuses. Four solar plants equal one full power plant.<br/><br/>They are typically lighter-defended than power plants, making them a cheaper way to boost your factory output while denying the enemy some of their power.<br/><br/><t color='#ff9a9a'>Why take them:</t> a low-risk source of extra tank production - grab them when they are near your front line."],
        ["Defenses (Static Emplacements)",
            "Markers arm a defense ring when you approach: bunkers with machine guns, sandbag positions, and static weapons on cargo towers/posts.<br/><br/><t color='#ffd24a'>Cargo towers</t> get HMGs on the roof; <t color='#ffd24a'>cargo patrol posts</t> get a lookout on top. These gunners are the faction's proper riflemen and will respawn if killed (unless a player is standing right there)."],
        ["Objectives",
            "You are given objectives as you play:<br/>- <t color='#ffd24a'>ATTACK</t>: the nearest enemy marker - capture it.<br/>- <t color='#ffd24a'>DEFEND</t>: a friendly marker under attack - hold it.<br/><br/>Objectives are shown as a colored marker on the map and as notification boxes. Approaching an enemy marker shows a box explaining what it does and why to take it."],
        ["Notifications & Notes",
            "Important events slide in as <t color='#ffd24a'>notification boxes</t> on the right of the screen - the same style the game itself uses.<br/><br/><t color='#ff9a9a'>Assault</t> - an enemy marker is launching an attack on one of your bases (shows source, target, ETA).<br/><t color='#ff9a9a'>Assault Underway / Repelled</t> - an enemy assault has arrived, or you wiped it out.<br/><t color='#ffd24a'>Marker Occupied / Captured / Lost</t> - you entered a wiped marker, secured it after the 10-min hold, or the enemy took one back.<br/><t color='#7ee07e'>Intel note</t> - when you approach an enemy marker, a box explains its function and why to capture it (e.g. a power plant's tank bonus).<br/><t color='#ffd24a'>Attack note</t> - 'Hostile position ahead' as you close on an enemy marker.<br/><br/>These also appear in <t color='#7ee07e'>system chat</t> as text, so you never miss a change in the battle."],
        ["Building & Recruiting",
            "<t color='#ffd24a'>B key - Defense Builder</t>: spend build points to place bunkers, tanks, static guns, walls and sandbags at your owned markers. Points are earned from captures.<br/><br/><t color='#ffd24a'>X key - Recruitment</t>: recruit soldiers at BLUFOR bases to join your squad.<br/><br/><t color='#ffd24a'>M key</t>: open/close the map.<br/><t color='#ffd24a'>H key</t>: open this field manual."],
        ["Controls",
            "<t color='#ffd24a'>M</t> - Map<br/><t color='#ffd24a'>B</t> - Defense Builder (build emplacements)<br/><t color='#ffd24a'>X</t> - Recruitment menu<br/><t color='#ffd24a'>H</t> - Field Manual (this screen)<br/><t color='#ffd24a'>ESC</t> - close menus<br/><br/>In the Defense Builder: <t color='#7ee07e'>WASD</t> move, <t color='#7ee07e'>drag</t> look, <t color='#7ee07e'>wheel</t> zoom, <t color='#7ee07e'>LMB</t> place, <t color='#7ee07e'>RMB</t> rotate."]
    ]
};

MISSION_CORE_fnc_helpMenuLoad = {
    private _d = findDisplay 1570;
    if (isNull _d) exitWith {};
    private _list = _d displayCtrl 1572;
    lbClear _list;
    {
        private _i = _list lbAdd (_x select 0);
        _list lbSetData [_i, str _forEachIndex];
    } forEach ([] call MISSION_CORE_fnc_helpMenuTopics);
    _list lbSetCurSel 0;
    [0] call MISSION_CORE_fnc_helpMenuSelect;
};

MISSION_CORE_fnc_helpMenuSelect = {
    params ["_ctrl", ["_sel", -1]];
    if (_sel < 0) then { _sel = lbCurSel _ctrl; };
    private _d = findDisplay 1570;
    if (isNull _d) exitWith {};
    private _topics = [] call MISSION_CORE_fnc_helpMenuTopics;
    if (_sel < 0 || { _sel >= count _topics }) exitWith {};
    private _body = (_topics select _sel) select 1;
    (_d displayCtrl 1573) ctrlSetStructuredText parseText _body;
};

MISSION_CORE_fnc_openHelpMenu = {
    if (isNull (findDisplay 1570)) then { createDialog "DYNOPS_HelpMenu"; };
};
