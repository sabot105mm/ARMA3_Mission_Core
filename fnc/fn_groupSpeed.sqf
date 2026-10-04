//
// GROUP SPEED MODE NORMALISER
//
// setSpeedMode (a group command) accepts only UNCHANGED / LIMITED / NORMAL / FULL and
// throws "Unknown enum value" for anything else, which aborts the rest of the calling
// block. The waypoint enum is a different, larger set (UNCHANGED / LOW / NORMAL / HIGH /
// LIMITED / FULL), so a speed read back off a waypoint is NOT automatically valid for the
// group.
//
// That mismatch is exactly how "Unknown enum value: FAST" reached setSpeedMode: the editor
// cycle, and therefore the stored default, contained a value that belongs to neither enum.
// This helper exists so any speed arriving from stored data, a serialised group, a waypoint
// or a player edit degrades to a legal value instead of throwing mid-mission.
//
// Compiled on BOTH client and server (initServer.sqf and initPlayerLocal.sqf) because the
// consumers are split across machines: fn_recruit.sqf runs client-side, while fn_snatch.sqf,
// fn_spawnGroup.sqf and fn_deserializeGroup.sqf run server-side.
//

// Returns a value that is always legal for setSpeedMode.
MISSION_CORE_fnc_normaliseGroupSpeed = {
    params [["_speed", ""]];

    switch (_speed) do {
        case "UNCHANGED": { "UNCHANGED" };
        case "LIMITED":   { "LIMITED" };
        case "NORMAL":    { "NORMAL" };
        case "FULL":      { "FULL" };
        // Waypoint-only tiers with no group equivalent.
        // HIGH -> FULL so the group doesn't hold back for stragglers; LOW -> NORMAL so it
        // still keeps formation, just without the crawl.
        case "HIGH":      { "FULL" };
        case "LOW":       { "NORMAL" };
        // The old editor cycle value. Never legal for the group; mapped rather than
        // dropped so an already-placed waypoint keeps a sane pace.
        case "FAST":      { "FULL" };
        default           { "FULL" };
    };
};

// Returns true when _speed can be handed to setSpeedMode unaltered. Use this to assert
// rather than silently repair, at boundaries where a bad value means the caller's own
// default is wrong (e.g. a shipped cycle list).
MISSION_CORE_fnc_isValidGroupSpeed = {
    params [["_speed", ""]];
    _speed in ["UNCHANGED","LIMITED","NORMAL","FULL"];
};

// The speed tiers that are legal for BOTH setWaypointSpeed and setSpeedMode, i.e. the only
// values safe to put in a shared editor cycle. Anything outside this set is a waypoint-only
// tier and must be normalised before it reaches setSpeedMode.
MISSION_CORE_GROUP_SPEEDS_SHARED = ["LIMITED","NORMAL","FULL"];
