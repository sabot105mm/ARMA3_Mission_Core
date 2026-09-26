// GET-OUT: ARMOR - worker.
// Waits for the rest of the crew to finish bailing, then carries out the verdict from
// fn_getOutArmorVerdict.
//
// PARSE NOTE. This file has defeated three rewrites with a bogus "Missing ;" reported at
// fn_getOutArmorWorker.sqf line 40, on an unrelated closing brace. Ruled out by experiment:
// unbalanced delimiters, non-ASCII, BOM, backticks, braces inside comments, block-form
// exitWith (fn_vehicleGetOut.sqf:100 has the same shape and compiles), and
// `count { code } array` (that one was a real bug, in fn_deleteGroupCompletely).
// So the body below is deliberately restricted to the plainest constructs the rest of the
// mission already proves parse: single statement if-then lines, one level of nesting, no
// command-call nesting inside format arrays, and no exitWith inside a then block.
// If this STILL fails to compile, the next step is truncation, not another rewrite: cut the
// body back to params + a single diag_log and add one statement per reload until it breaks.
//
// LOST
//   Economy delivery: flagged MISSION_CORE_GETOUT_WRITEOFF and left to the shipment loop in
//   fn_tankOrderLoop, which already owns the write-off accounting. Flagging instead of
//   re-implementing that ledger here is what makes double accounting impossible.
//   Anything else: the hull is deleted, and deleteVehicle FIRES its Killed handler, so the
//   billing and the replacement request are the existing ones. That is bill-and-replace, which
//   costs the player twice for one lost reinforcement tank and is correct, because it is gone.
//
// RECOVERABLE
//   The hull is moved to clear ground, righted, and re-crewed. A flipped hull reports canMove
//   TRUE, so it is invisible to the canMove poll in fn_armorCommanderLoop and to the position
//   sweep in fn_orderedVehicleCleanup - this is the only path that catches one. Finishing the
//   delivery needs no accounting of its own: the convoy drives on and the existing arrival path
//   delivers the tank and despawns it to the pool.
//
//   If all three attempts fail the hull escalates to a loss rather than being left on the map
//   as a permanent monument.
MISSION_CORE_fnc_getOutArmorWorker = {
    params ["_veh", "_unit", "_lost", "_isEconomy"];
    sleep 1.5;
    if (isNull _veh) exitWith {};
    if (!alive _veh) exitWith {};
    private _grid = mapGridPosition (getPos _veh);
    private _why = "lost - Killed accounting, billed and replaced";
    if (_isEconomy) then { _why = "write-off - delivery hull over 30 percent damage"; };
    if (_lost) then {
        diag_log format ["GET-OUT: armor %1 at %2 abandoned by crew - %3", typeOf _veh, _grid, _why];
        _veh setVariable ["MISSION_CORE_GETOUT_WRITEOFF", _isEconomy];
    };
    if (_lost && { !_isEconomy }) then { deleteVehicle _veh; };
    if (_lost) exitWith {};
    private _crew = [];
    _crew = [_veh, _unit] call MISSION_CORE_fnc_getOutBailedCrew;
    diag_log format ["GET-OUT: armor %1 at %2 undamaged but abandoned - relocating and reboarding", typeOf _veh, _grid];
    private _ok = false;
    _ok = [_veh, _crew, 3] call MISSION_CORE_fnc_getOutRelocate;
    if (_ok) exitWith { diag_log format ["GET-OUT: armor %1 recovered - crew reboarded", typeOf _veh]; };
    diag_log format ["GET-OUT: armor %1 at %2 not recoverable in 3 attempts - escalating", typeOf _veh, _grid];
    _veh setVariable ["MISSION_CORE_GETOUT_WRITEOFF", _isEconomy];
    if (!_isEconomy) then { deleteVehicle _veh; };
};
diag_log format ["GETOUT WORKER: fn_getOutArmorWorker.sqf compiled, helper defined=%1", !(isNil "MISSION_CORE_fnc_getOutArmorWorker")];
