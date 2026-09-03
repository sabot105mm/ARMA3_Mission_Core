if (!isServer) exitWith {};

// Start mission initialization
call compile preprocessFileLineNumbers "fnc\fn_init.sqf";

diag_log "DYNAMIC OPS: Server initialization started";
