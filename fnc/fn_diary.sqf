// Client-side MAP DIARY ("Dynamic Operations" tab). Opened inside the map (M). Registered in initPlayerLocal.sqf.
// Reuses the exact [title, body] topic list from fn_helpMenu.sqf so the H-key field manual and the
// diary tab can never drift apart. Each record is styled as a mini dossier page:
//   - centered topical marker icon (base-game ui_f PBO, all paths verified present in vanilla A3)
//   - category kicker + gold title + accent-color divider
//   - body (with SQF format % escaped) and a right-aligned footer rule.
// The list also gets a per-record icon via the [title, text, icon] form of createDiaryRecord.

// Per-topic style: returns [iconPath, accentColor, categoryLabel]. Falls back to a default.
MISSION_CORE_fnc_diaryStyleFor = {
    params ["_title"];
    private _styles = [
        ["Welcome", "\A3\ui_f\data\map\markers\military\flag_CA.paa", "#ffd24a", "OVERVIEW"],
        ["Markers & Territory", "\A3\ui_f\data\map\markers\military\mission_CA.paa", "#7ee07e", "TERRITORY"],
        ["Garrisons & Spawning", "\A3\ui_f\data\map\markers\nato\b_inf.paa", "#7ee07e", "TERRITORY"],
        ["Capturing a Marker", "\A3\ui_f\data\map\markers\military\objective_CA.paa", "#ff9a9a", "TERRITORY"],
        ["Light Infrastructure (Power / Solar)", "\A3\ui_f\data\map\markers\nato\b_installation.paa", "#7dd8ff", "ECONOMY"],
        ["Enemy AI & Counter-Attacks", "\A3\ui_f\data\map\markers\nato\o_inf.paa", "#ff9a9a", "ENEMY"],
        ["Player Hunts", "\A3\ui_f\data\map\markers\nato\o_recon.paa", "#ff9a9a", "ENEMY"],
        ["Quadrant Defense", "\A3\ui_f\data\map\markers\military\triangle_CA.paa", "#7dd8ff", "DEFENSE"],
        ["House Occupation (Red Squares)", "\A3\ui_f\data\map\markers\military\marker_CA.paa", "#c9a0ff", "TERRITORY"],
        ["Tank Industry & Power", "\A3\ui_f\data\map\markers\nato\b_armor.paa", "#ffd24a", "ECONOMY"],
        ["Power Plants", "\A3\ui_f\data\map\markers\nato\b_art.paa", "#ffd24a", "ECONOMY"],
        ["Solar Plants", "\A3\ui_f\data\map\markers\nato\b_art.paa", "#ffd24a", "ECONOMY"],
        ["Manpower Economy", "\A3\ui_f\data\map\markers\nato\b_med.paa", "#ffd24a", "ECONOMY"],
        ["Aggression", "\A3\ui_f\data\map\markers\military\warning_CA.paa", "#ff9a9a", "ENEMY"],
        ["Defenses (Static Emplacements)", "\A3\ui_f\data\map\markers\nato\b_antiair.paa", "#7dd8ff", "DEFENSE"],
        ["Objectives", "\A3\ui_f\data\map\markers\military\objective_CA.paa", "#7ee07e", "TERRITORY"],
        ["Notifications & Notes", "\A3\ui_f\data\map\markers\handdrawn\warning_CA.paa", "#c9a0ff", "MISC"],
        ["Building & Recruiting", "\A3\ui_f\data\map\markers\nato\b_hq.paa", "#7dd8ff", "MISC"],
        ["Controls", "\A3\ui_f\data\map\markers\military\dot_CA.paa", "#b8b8b8", "MISC"]
    ];
    private _hit = _styles select { (_x select 0) == _title };
    if (count _hit > 0) exitWith {
        _hit select 0 params ["_t", "_icon", "_color", "_cat"];
        [_icon, _color, _cat]
    };
    ["\A3\ui_f\data\map\markers\military\mission_CA.paa", "#b8b8b8", "MISC"]
};

// Escape ampersands for the diary's strict HTML parser ("&" opens an entity reference and an
// incomplete one blanks the whole record). splitString/joinString is used because Arma's SQF
// parser in this build rejects the replace command (Missing ; at parse time).
MISSION_CORE_fnc_diaryEscape = {
    params ["_s"];
    (_s splitString "&") joinString "&amp;"
};

// Populate the map's diary with one styled record per help topic. No-op for non-clients and when the
// subject already exists (JIP / re-init).
MISSION_CORE_fnc_setupDiary = {
    if (!hasInterface || { isNull player }) exitWith {};
    if (player diarySubjectExists "DynOpsFieldManual") exitWith {};
    player createDiarySubject ["DynOpsFieldManual", "Dynamic Operations"];
    private _topics = call MISSION_CORE_fnc_helpMenuTopics;
    for "_j" from (count _topics) - 1 to 0 step -1 do {
        private _topic = _topics select _j;
        _topic params ["_title", "_body"];
        private _style = [_title] call MISSION_CORE_fnc_diaryStyleFor;
        _style params ["_icon", "_accent", "_category"];
        // Diary record title (plain, shown in the list) keeps the raw "&"; the HTML body must use
        // &amp; or the strict diary parser blanks the record.
        private _tHtml = [_title] call MISSION_CORE_fnc_diaryEscape;
        private _bHtml = [_body] call MISSION_CORE_fnc_diaryEscape;
        private _recordText = format [
            "<t align='center'><img image='%3' width='80' height='80' title='%1'/></t><br/>" +
            "<t align='center' size='1.1' color='%4' font='EtelkaMonospacePro'>%5</t><br/>" +
            "<t align='center' size='1.8' color='#ffd24a' font='PuristaBold' shadow='2'>%1</t><br/><br/>" +
            "<hr size='2' color='%4'/><br/>" +
            "%2<br/><br/>" +
            "<hr size='1' color='#555555'/><br/>" +
            "<t align='right' size='0.9' color='#999999' font='PuristaLight'>Dynamic Operations - Field Manual</t>",
            _tHtml, _bHtml, _icon, _accent, _category
        ];
        player createDiaryRecord ["DynOpsFieldManual", [_title, _recordText, _icon]];
    };
    diag_log format ["DYNAMIC OPS: map diary populated (%1 entries)", count _topics];
};