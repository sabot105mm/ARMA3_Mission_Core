# Arma 3 SQF Code Optimisation Guide

Source: Bohemia Interactive Community Wiki, "Code Optimisation" (Category: Arma Scripting Tutorials).
Related pages: Code Best Practices, Mission Optimisation (conception optimisation), Scheduler, Multiplayer Scripting.

## Document Notes
- Language: SQF (Arma 3 scripting).
- Benchmarks were run on Arma 3 v1.82 with Tank DLC. Engine performance may have changed since.
- All times are in milliseconds (ms), averaged over 10000 iterations unless stated.
- In code blocks, `// X ms` after a line is the measured time for that line/snippet. Lower is faster.
- The original page used icons to rate importance of each tip (must-change / worth considering for pure performance / negligible gain). The icons were lost in this text; importance is noted in prose where the original text made it clear.

## Contents
1. Quick Reference (summary)
2. Rules (readability and maintainability)
3. Code Optimisation
4. Equivalent Commands Performance
5. Equivalent Data Structures Performance
6. Conversion From Earlier Versions

---

## 1. Quick Reference (summary of key takeaways)

This section is a condensed summary derived from the article below.

- Make it work, make it readable, then optimise.
- Prefer local (`_underscore`) variables over global ones; cache globals in locals inside loops.
- Use `private _var = value` (direct declaration), except for variables reused in a loop (declare once outside the loop).
- Use `pushBack` / `append` to add array elements; `deleteAt` / `deleteRange` to remove.
- Use `for "_i" from .. to .. do` when `_x` is not needed; otherwise `forEach` / `apply`.
- Use `findIf` to stop at the first match.
- Use `call` with a compiled function instead of repeated `execVM` (execVM re-reads and recompiles every call).
- Use `createSimpleObject` instead of `createVehicle` when a simple object is enough (much faster).
- Use `nearEntities` over `nearestObjects` (but it only finds alive on-foot units and vehicles with crew; see caveats).
- Use `isEqualType` instead of `typeName`; `isEqualTo` / `count` comparisons are similar.
- Use `getPosWorld`/`getPosASL`/`getPosATL` rather than `getPos`.
- Use `toLowerANSI`/`toUpperANSI` instead of `toLower`/`toUpper` when ANSI is sufficient.
- Use hashmaps (`createHashMapFromArray`, `get`) for key-value data (Arma 3 v2.02+).
- Build long strings with an array + `joinString`, not repeated `+`.
- Replace old `BIS_fnc_*` helpers with engine commands (`selectRandom`, `vectorMultiply`, `linearConversion`, `selectRandomWeighted`, `param`/`params`, `remoteExec`/`remoteExecCall`, `isEqualTo`, `arrayIntersect`).
- Multiplayer: do not spam `publicVariable` / public `setVariable`; keep variable names short; use `remoteExec`/`remoteExecCall`, never `BIS_fnc_MP`.
- Lazy evaluation (`a && { b }`) can speed up OR slow down code depending on conditions.
- Use `-showScriptErrors` and read the RPT log; script errors slow code and may break it.

---

## 2. Rules

The article has three parts that matter for style:
1. Rules: clean, readable, maintainable code.
2. Code optimisation: performance, sometimes traded against readability.
3. Equivalent commands performance: commands with apparently identical effects but different performance.
4. Conversion from earlier versions: newer commands/syntax to replace old ways.

Any rule is a rule of thumb. Example: a rule saying lines should not exceed 80 characters does not mean no line may exceed 80 characters; sometimes the situation needs it. If the structure is good, do not change code to enforce a single arbitrary rule. If many rules are broken, something may need to change. Use judgement.

Three basic rules:
1. Make it work
2. Make it readable
3. Optimise then

### 2.1 Make It Work

> "Premature optimization is the root of all evil." (Donald Knuth)

The first goal is for code to do what you want.
- Read and take inspiration from other people's code. If you understand it after reading once, it is probably a good source of inspiration.
- When starting from scratch and you know what you want but not the steps, write down in your native language what you want to do. Example: "Get all the units near the city, and for each west soldier in them, add 30% damage."
- Use the `-showScriptErrors` startup parameter and make sure your code does not throw errors. Erroring code runs slower and may not work at all. Read the error, isolate the issue, and look it up on the wiki.
- Read the Arma RPT (report) log for more details about errors.

### 2.2 Make It Readable

Whether cleaning your code or someone else's, you must understand the code without twisting your brain:
- SQF is only non-noticeably affected by variable name length, so this should not take precedence over human readability. Names like `_u` instead of `_uniform` should not be present.
- One-lining (everything in one statement) saves little memory and is usually not worth the headache. Do not overuse it.
- Indentation and whitespace matter for the human mind. Space is free.
- Line returns help to see code blocks wrapping multiple related instructions.
- If you see the same code multiple times with only different parameters, write a function.
- If you have many `if..else`, consider `switch`, or break the code into smaller functions.
- If a function is too long, break it into understandable-sized pieces.
- Use camelCase (`namingLikeThis`) for variables; it improves readability, especially for long names.

See also: Code Best Practices.

Unreadable example:

```sqf
_w=[]; {_w pushbackunique primaryweapon _x} foreach((allunits+alldeadmen) select{_x call BIS_fnc_objectside==east});
```

Same logic, readable (proper spacing, good names, intermediate results):

```sqf
_weaponNames = [];
_allUnitsAliveAndDead = allUnits + allDeadMen;
_allEastAliveAndDead = _allUnitsAliveAndDead select { _x call BIS_fnc_objectSide == east };
{ _weaponNames pushBackUnique primaryWeapon _x } forEach _allEastAliveAndDead;
```

### 2.3 Constants

If a hard-coded constant is used more than once, use preprocessor directives instead of storing it in memory or cluttering code with numbers.

Before:

```sqf
a = _x + 1.053;
b = _y + 1.053;
```

Intermediate (variable):

```sqf
_buffer = 1.053;
a = _x + _buffer;
b = _y + _buffer;
```

Better (macro; note: no semicolon after the define):

```sqf
#define BUFFER 1.053
_a = _x + BUFFER;
_b = _y + BUFFER;
```

Note: `#define` only works within the current SQF file. The definition does not propagate elsewhere.

Global "constants" can be defined in `Description.ext` and read with `getMissionConfigValue`.

`Description.ext`:

```cpp
var1 = 123;
var2 = "123";
var3[] = { 1, 2, 3 };
rand = __EVAL(random 999);
```

Usage:

```sqf
hint str getMissionConfigValue "var1"; // 123                                  // 0.0007 ms
hint str getMissionConfigValue "var2"; // "123"                                // 0.0008 ms
hint str getMissionConfigValue "var3"; // [1,2,3]                              // 0.0017 ms
hint str getMissionConfigValue "rand"; // constant random, e.g. 935.038        // 0.0007 ms
```

`getMissionConfigValue` searches `Description.ext` from top to bottom, so for performance put all definitions at the top of the file.

### 2.4 Optimise Then

Once you know what is what, you understand your code better.
- Use private (underscore-prefixed) local variables instead of global variables as much as possible.
- Iterating multiple times over the same array? You should be able to spot the issue now.
- Using `execVM` on the same file many times? Store the function in memory to avoid reading the file on every call, e.g. `_myFunction = compile preprocessFileLineNumbers "myFile.sqf";`
- Variable name too long? Find a shorter one appropriate to the variable's scope. Example:

```sqf
{ _opforUnitUniform = uniform _x; systemChat _opforUnitUniform; } forEach _allOpforUnits;
```

becomes

```sqf
{ _uniform = uniform _x; systemChat _uniform; } forEach _allOpforUnits;
```

---

## 3. Code Optimisation

Benchmark conditions: Arma 3 v1.82 with Tank DLC; averages over 10000 iterations.

### 3.1 Scheduled and Unscheduled Environment

Two code environment types (see Scheduler page):
- **Scheduled**: execution time limit of 3 ms before the script is suspended in favour of another until its turn returns. Slightly slower than unscheduled, but suspending (`sleep`, `waitUntil`) is allowed.
- **Unscheduled**: not watched; runs without limits. Recommended for time-critical scripts, but suspending (`sleep`, `waitUntil`) is NOT allowed.

### 3.2 Variable Assignment

```sqf
private _myVar = [33, 66] select false;                                         // 0.0013 ms  (fastest)
private _myVar = if (false) then { 33; } else { 66; };                          // 0.0020 ms
private "_myVar"; if (false) then { _myVar = 33; } else { _myVar = 66; };       // 0.0025 ms
```

### 3.3 Lazy Evaluation

In SQF this code evaluates every condition, even if one fails:

```sqf
if (a && b && c) then {};
```

Even if `a` is false (so the whole expression can no longer be true), `b` and `c` are still evaluated.

To avoid this, nest `if` statements or use lazy evaluation:

```sqf
if (a && { b && { c } }) then {};
```

Here evaluation stops once any condition evaluates to false.

#### Influence on Semantics

Depending on where the curly brackets are placed, lazy evaluation can change precedence (and therefore the semantics) of a condition.

Case: `a = false`, `b` = any Boolean, `c = true`.

| Expression | Evaluated conditions | Result |
|---|---|---|
| `a && b \|\| c` | a, b, c | true |
| `a && {b} \|\| {c}` | a, c | true |
| `a && {b \|\| {c}}` | a | false |

(Note: the third form groups `b || c` inside the lazy block, so `c` never saves the result; the result is false.)

#### Performance

Lazy evaluation is not always best; it can speed up or slow down code depending on the condition being evaluated:

```sqf
["true  || { false  || {false}}", nil, 100000] call BIS_fnc_codePerformance;   // 0.00080 ms
["true  ||  {false} || {false} ", nil, 100000] call BIS_fnc_codePerformance;   // 0.00105 ms
["false ||   false  ||  false  ", nil, 100000] call BIS_fnc_codePerformance;   // 0.00123 ms
["true  ||   false  ||  false  ", nil, 100000] call BIS_fnc_codePerformance;   // 0.00128 ms
["false ||  {false} || {false} ", nil, 100000] call BIS_fnc_codePerformance;   // 0.00200 ms
```

### 3.4 Concatenating Strings

`myString = myString + otherString` works for small strings, but becomes slower as the string grows:

```sqf
myString = ""; for "_i" from 1 to 10000 do { myString = myString + "123" };    // 290 ms
```

Solution: collect pieces in an array and join later:

```sqf
strings = [];
for "_i" from 1 to 10000 do { strings pushBack "123" };
strings = strings joinString "";                                               // 30 ms
```

### 3.5 Array Manipulation

#### Add Elements

`append` and `pushBack` hold the best scores.

```sqf
_array = [0,1,2,3]; _array append [4,5,6];                                      // 0.0020 ms
_array = [0,1,2,3]; _array = _array + [4,5,6];                                  // 0.0023 ms
_array = [0,1,2,3]; { _array set [count _array, _x]; } forEach [4,5,6];         // 0.0080 ms

_array = [0,1,2,3]; _array pushBack 4;                                          // 0.0016 ms
_array = [0,1,2,3]; _array = _array + [4];                                      // 0.0021 ms
_array = [0,1,2,3]; _array set [count _array, _x];                              // 0.0022 ms
```

#### Iterate Elements

If `_x` is not required, `for` is about twice as fast as `forEach`; otherwise use `forEach` (see results).

Columns: 64 units / 256 units.

```sqf
private _list = allUnits;                                                               // 64 units     256 units

// if the amount of loops is known
for "_i" from 0 to 63 do {};                                                            // 0.0120 ms    0.0460 ms
for "_i" from 0 to count _list -1 do {};                                                // 0.0170 ms    0.0480 ms
for "_i" from 0 to count _list -1 do { private _x = _list select _i };                  // 0.0500 ms    0.1896 ms
for "_i" from 0 to count _list -1 do { private _x = _list select _i; _x setDamage 0 };  // 0.107 ms     0.39 ms

{} forEach _list;                                                                       // 0.0250 ms    0.098 ms
{ _x setDamage 0 } forEach _list;                                                       // 0.0770 ms    0.312 ms

_list apply {};                                                                         // 0.0250 ms    0.098 ms
_list apply { _x setDamage 0 };                                                         // 0.0770 ms    0.312 ms

private _i = 0;
while { _i < 64 } do { _i = _i + 1; };                                                  // 0.048 ms     0.200 ms

// counts array every loop
private _i = 0;
while { _i < count _list } do { _i = _i + 1; };                                         // 0.062 ms     0.247 ms

private _i = 0;
while { _i < 64 } do { private _x = _list select _i; _i = _i + 1; };                    // 0.086 ms     0.42 ms
```

#### Remove Elements

```sqf
_array = [0,1,2,3]; _array deleteAt 0;                                                              // 0.0015 ms
_array = [0,1,2,3]; _array set [0, objNull]; _array = _array - [objNull];                          // 0.0038 ms
_array = [0,1,2,3]; _array deleteRange [1, 2];                                                      // 0.0018 ms
_array = [0,1,2,3]; { _array set [_x, objNull] } forEach [1,2]; _array = _array - [objNull];       // 0.0078 ms
```

### 3.6 Multiplayer Recommendations

See Multiplayer Scripting for more.
- Do not saturate the network: `publicVariable` or public `setVariable` should not be used at high frequency, or everyone's performance suffers.
- The server is expected to have a good CPU and lots of memory: store functions on it, run them there, send only results to clients.
- Variable name length in `publicVariable` and `setVariable` impacts network traffic. Send well-named but short, understandable variables (avoid absurdly long names like `playerNameBecauseThePlayerIsImportantAndWeNeedToKnowWhoTheyAreAllTheTimeEspeciallyInsideThisImpressiveFunction`).
- Use `remoteExec` and `remoteExecCall`. Ditch `BIS_fnc_MP` for good.

---

## 4. Equivalent Commands Performance

### 4.1 call

`call` without arguments is faster than `call` with arguments:

```sqf
call {};                                // 0.0007 ms
123 call {};                            // 0.0013 ms
```

Variables from the parent scope are visible in the called child scope, so you can sometimes avoid passing arguments:

```sqf
player addEventHandler ["HandleDamage", { call my_fnc_damage }];
```

instead of:

```sqf
player addEventHandler ["HandleDamage", { _this call my_fnc_damage }];
```

### 4.2 execVM and call

WARNING: Using `execVM` repeatedly makes the game read the file and recompile it every time. If you use the script more than once, store its code in a variable, or better, make it a Function.

```sqf
// myFile.sqf is an EMPTY file
private _myFunction = compile preprocessFileLineNumbers "myFile.sqf"; // compile is done only once
call _myFunction;               // 0.0009 ms
execVM "myFile.sqf";            // 0.275 ms

// myFile.sqf is BIS_fnc_showRespawnMenu
private _myFunction = compile preprocessFileLineNumbers "myFile.sqf"; // compile is done only once
["close"] call _myFunction;     // 0.0056 ms
["close"] execVM "myFile.sqf";  // 0.506 ms
```

### 4.3 loadFile, preprocessFile and preprocessFileLineNumbers

```sqf
// myFile.sqf is an empty file
loadFile "myFile.sqf";                      // 0.219 ms
preprocessFile "myFile.sqf";                // 0.353 ms
preprocessFileLineNumbers "myFile.sqf";     // 0.355 ms

// myFile.sqf is BIS_fnc_showRespawnMenu
loadFile "myFile.sqf";                      // 0.3516 ms
preprocessFile "myFile.sqf";                // 2.75 ms
preprocessFileLineNumbers "myFile.sqf";     // 2.73 ms

// myFile.sqf is a missing file
loadFile "myFile.sqf";                      // 0.692 ms
preprocessFile "myFile.sqf";                // 0.6225 ms
preprocessFileLineNumbers "myFile.sqf";     // 0.6225 ms
```

WARNING: The comparison of `loadFile` with `preprocessFile*` is not fair, because `loadFile` does not preprocess the content. The loaded file also cannot contain `//` or `/* */` comments or any preprocessor instructions (including debug information like line numbers or file info).

### 4.4 if

```sqf
if (condition) then { /* thenCode */ };                         // 0.0011 ms
if (condition) exitWith { /* exitCode */ };                     // 0.0014 ms
if (condition) then { /* thenCode */ } else { /* elseCode */ }; // 0.0015 ms
if (condition) then [{ /* thenCode */ }, { /* elseCode */ }];   // 0.0016 ms
```

### 4.5 if and select

Use `[array] select boolean` instead of the lazy-evaluated `if`:

```sqf
_result = ["false result", "true result"] select true;                  // 0.0011 ms
_result = if (true) then { "true result"; } else { "false result"; };   // 0.0017 ms
```

### 4.6 if and switch

```sqf
_result = call {
    if (false) exitWith {};
    if (false) exitWith {};
    if (true)  exitWith {};
    if (false) exitWith {};
    if (false) exitWith {};
};                                                                      // 0.0032 ms

_result = switch (true) do {
    case (false): {};
    case (false): {};
    case (true) : {};
    case (false): {};
    case (false): {};
};                                                                      // 0.0047 ms
```

### 4.7 if else and switch

Equal performance:

```sqf
_mode = "killed";

switch _mode do {
    case "init": {};
    case "killed": {};
    case "respawned": {};
};                                                                      // 0.0019 ms
```

```sqf
_mode = "killed";

if (_mode == "init") then {} else {
    if (_mode == "killed") then {} else {
        if (_mode == "respawned") then {};
    };
};                                                                      // 0.0019 ms
```

### 4.8 in vs find

```sqf
// String search
"bar" in "foobar"                                   // 0.0008 ms
"foobar" find "bar" > -1                            // 0.0012 ms

// Array search - case-sensitive
"bar" in ["foo", "Bar", "bar", "BAR"];              // 0.0012 ms
["foo", "Bar", "bar", "BAR"] find "bar" > -1;       // 0.0016 ms
```

### 4.9 for

`for..from..to..do` is about twice as fast as the alternative `for..do` syntax:

```sqf
for "_i" from 0 to 10 do { /* forCode */ };                                     // 0.015 ms
for [{ _i = 0 }, { _i < 100 }, { _i = _i + 1 }] do { /* forCode */ };           // 0.030 ms
```

### 4.10 forEach vs count vs findIf

`forEach` and `count` both step through all elements and expose the current element as `_x`. `count` is a little faster, but has no `_forEachIndex`. The code inside `count` must return Boolean or Nothing, while `count` itself returns a Number. If you must add an extra `true`/`false`/`nil` at the end to make `count` work, it will be slower than `forEach`.

```sqf
{ diag_log _x } count   [1,2,3,4,5];                                            // 0.082 ms
{ diag_log _x } forEach [1,2,3,4,5];                                            // 0.083 ms
```

With an empty array:

```sqf
_someoneIsNear = (allUnits findIf { _x distance [0,0,0] < 1000 }) != -1;        // 0.0046 ms
_someoneIsNear = { _x distance [0,0,0] < 1000 } count allUnits > 0;             // 0.0047 ms
_someoneIsNear = {
    if (_x distance [0,0,0] < 1000) exitWith { true };
    false
} forEach allUnits;                                                             // 0.0060 ms
```

With a 30-item array:

```sqf
_someoneIsNear = (allUnits findIf { _x distance [0,0,0] < 1000 }) != -1;        // 0.0275 ms
_someoneIsNear = { _x distance [0,0,0] < 1000 } count allUnits > 0;             // 0.0645 ms
_someoneIsNear = {
    if (_x distance [0,0,0] < 1000) exitWith { true };
    false
} forEach allUnits;                                                             // 0.0390 ms
```

### 4.11 findIf

`findIf` stops iterating as soon as the condition is met.

```sqf
[0,1,2,3,4,5,6,7,8,9] findIf { _x == 2 };                                       // 0.0050 ms
{ if (_x == 2) exitWith { _forEachIndex; }; } forEach [0,1,2,3,4,5,6,7,8,9];    // 0.0078 ms
_quantity = { _x == 2 } count [0,1,2,3,4,5,6,7,8,9];                            // 0.0114 ms
```

### 4.12 format vs str

```sqf
str 33;                 // 0.0016 ms
format ["%1", 33];      // 0.0022 ms
```

### 4.13 + vs format vs joinString

Non-String data:

```sqf
[33, 45, 78] joinString "";             // 0.0052 ms - no length limit
format ["%1%2%3", 33, 45, 78];          // 0.0054 ms - limited to ~8Kb
str 33 + str 45 + str 78;               // 0.0059 ms - no length limit
```

String data:

```sqf
["str1", "str2", "str3"] joinString "";         // 0.0015 ms - no length limit
format ["%1%2%3", "str1", "str2", "str3"];      // 0.0015 ms - limited to ~8Kb
"str1" + "str2" + "str3";                       // 0.0012 ms - no length limit
```

### 4.14 private

Direct declaration (`private _var = value`) is faster than declaring then assigning:

```sqf
private _a = 1;
private _b = 2;
private _c = 3;
private _d = 4;
// 0.0023 ms
```

```sqf
private ["_a", "_b", "_c", "_d"];
_a = 1;
_b = 2;
_c = 3;
_d = 4;
// 0.0040 ms
```

However, if you reuse the same variable in a loop, external declaration is faster. A declaration inside the loop creates, assigns and deletes the variable on each iteration; an external declaration creates it once and the loop only assigns.

```sqf
private ["_a", "_b", "_c", "_d"];
for "_i" from 1 to 10 do
{
    _a = 1; _b = 2; _c = 3; _d = 4;
};
// 0.0195 ms
```

```sqf
for "_i" from 1 to 10 do
{
    private _a = 1; private _b = 2; private _c = 3; private _d = 4;
};
// 0.0235 ms
```

### 4.15 isNil

```sqf
isNil "varName";                    // 0.0007 ms
isNil { varName };                  // 0.0012 ms
```

### 4.16 isEqualType and typeName

`isEqualType` is much faster than `typeName`:

```sqf
"string" isEqualType 33;                // 0.0006 ms
typeName "string" == typeName 33;       // 0.0018 ms
```

### 4.17 isEqualTo and count

With an items array:

```sqf
allUnits isEqualTo [];              // 0.0040 ms
count allUnits == 0;                // 0.0043 ms
```

### 4.18 select and param

```sqf
[1,2,3] select 0;                   // 0.0008 ms
[1,2,3] param [0];                  // 0.0011 ms
```

### 4.19 createSimpleObject vs createVehicle

`createSimpleObject` is over 43x faster than `createVehicle`:

```sqf
deleteVehicle createSimpleObject ["a3\structures_f_mark\vr\shapes\vr_shape_01_cube_1m_f.p3d", [0,0,0]];  // ~0.08 ms
deleteVehicle createSimpleObject ["Land_VR_Shape_01_cube_1m_F", [0,0,0]];                                // ~3.2 ms
deleteVehicle createVehicle ["Land_VR_Shape_01_cube_1m_F", [0,0,0], [], 0, "CAN_COLLIDE"];               // ~2.7 ms
deleteVehicle createVehicle ["Land_VR_Shape_01_cube_1m_F", [0,0,0], [], 0, "NONE"];                      // ~78 ms
```

(The ~0.08 ms case uses the model path (.p3d) directly; the class-name form is much slower.)

### 4.20 objectParent and vehicle

```sqf
isNull objectParent player;         // 0.0013 ms
vehicle player == player;           // 0.0022 ms
```

### 4.21 nearEntities and nearestObjects

`nearEntities` is much faster than `nearestObjects`, depending on range and number of objects in range. If the range is over 100 meters, using `nearEntities` is highly recommended.

```sqf
// tested with a NATO rifle squad amongst solar power plant panels on Altis at [20762,15837]
getPosATL player nearEntities [["CAManBase"], 50];          // 0.0075 ms
nearestObjects [getPosATL player, ["CAManBase"], 50];       // 0.0145 ms
```

WARNING: `nearEntities` only finds alive objects and on-foot soldiers. In-vehicle units, killed units, destroyed vehicles, static objects and buildings are ignored.

### 4.22 Global Variables vs Local Variables

If a global variable is used repeatedly in a loop, copy it to a local variable first.

Slower:

```sqf
SomeGlobalVariable = [123];
for "_i" from 1 to 100 do
{
    SomeGlobalVariable select 0;
};
// 0.13 ms
```

Faster:

```sqf
SomeGlobalVariable = [123];
private _var = SomeGlobalVariable;
for "_i" from 1 to 100 do
{
    _var select 0;
};
// 0.08 ms
```

### 4.23 Config path delimiter

`>>` is slightly faster than `/` in config paths with `configFile` or `missionConfigFile`:

```sqf
configFile >> "CfgVehicles";        // 0.0019 ms
configFile  / "CfgVehicles";        // 0.0023 ms
```

Tip: store a config path in a variable to save CPU time: `_cfgVehicles = configFile >> "CfgVehicles"`.

### 4.24 getPos* and setPos*

```sqf
getPosWorld                         // 0.0015 ms
getPosASL                           // 0.0016 ms
getPosATL                           // 0.0016 ms
getPosASLW                          // 0.0023 ms
getPos                              // 0.0030-0.0300 ms; depends on where the command is used - see its documentation
position                            // same as getPos
getPosVisual                        // same as getPos
visiblePosition                     // same as getPos
setPosWorld                         // 0.0060 ms
setPosASL                           // 0.0060 ms
setPosATL                           // 0.0060 ms
setPos                              // 0.0063 ms
setPosASLW                          // 0.0068 ms
setVehiclePosition                  // 0.0077 ms with "CAN_COLLIDE"
                                    // 0.0390 ms with "NONE"
```

### 4.25 toLower/toUpper vs toLowerANSI/toUpperANSI

`_myString` is a 100-char string like `"aAaAaA(...)"`.

```sqf
toLowerANSI _myString;              // 0.0006 ms
toLower _myString;                  // 0.0016 ms

toUpperANSI _myString;              // 0.0006 ms
toUpper _myString;                  // 0.0016 ms
```

---

## 5. Equivalent Data Structures Performance

### 5.1 Key-Value Data Structures

Hashmaps (`createHashMapFromArray`) exist since Arma 3 v2.02.

```sqf
private _hashMap    = createHashMapFromArray [["id", 123], ["name", "player name"], ["unit", player]];
private _goodFormat = [["id", "name", "unit"], [123, "player name", player]];
private _slowFormat = [["id", 123], ["name", "player name"], ["unit", player]];

private _name = _hashMap get "name";                                // 0.0018 ms

// this takes 0.0038 ms:
private _index = _goodFormat select 0 find "name";                  // loop in engine
private _name  = _goodFormat select 1 select _index;

// this takes 0.0116 ms:
private _index = _slowFormat findIf { _x select 0 == "name" };      // loop in script
private _name  = _slowFormat select _index select 1;
```

Note: the Database Functions use the slow format.

---

## 6. Conversion From Earlier Versions

Each iteration of Bohemia games (Operation Flashpoint, Armed Assault, Arma 2, Take On Helicopters, Arma 3) added new commands, especially Arma 2 and Arma 3. When converting older scripts, review the following.

### 6.1 Loops
`forEach` loops can, depending on the situation, be replaced by: `apply`, `count`, `findIf`, `select`.

### 6.2 Array Operations

| Task | Old way | New way |
|---|---|---|
| Add an item | `myArray + [element]`, `myArray set [count myArray, element]` | `pushBack` |
| Random item | `BIS_fnc_selectRandom` | `selectRandom` |
| Remove items | `myArray set [1, objNull]; myArray - [objNull]` | `deleteAt`, `deleteRange` |
| Concatenate | `myArray = myArray + [element]` | `append` (if you do not need the original array modified, use `+`) |
| Compare | `BIS_fnc_areEqual` | `isEqualTo` |
| Common items | `in` inside a `forEach` | `arrayIntersect` |
| Condition filtering | `forEach` | `select` (alternative syntax with code) |

Condition filtering example:

```sqf
result = (arrayOfNumbers select { _x % 2 == 0 });   // 1.55 ms

result = [];
{
    if (_x % 2 == 0) then { result pushBack _x; };
} forEach arrayOfNumbers;                           // 2.57 ms
```

### 6.3 Vector Operations
- `BIS_fnc_vectorMultiply` replaced by `vectorMultiply` (at least 6x faster).
- `BIS_fnc_vectorDivide` replaced too, to an extent (see its page).

```sqf
private _vector = [102, 687, 1543];
private _factor = 53;

_vector vectorMultiply _factor;                     // 0.0028 ms
[_vector, _factor] call BIS_fnc_vectorMultiply;     // 0.0145 ms

_vector vectorMultiply (1 / _factor);               // 0.003 ms - but beware of 0 divisor
[_vector, _factor] call BIS_fnc_vectorDivide;       // 0.017 ms
```

### 6.4 String Operations
String manipulation was simplified with:
- Alternative syntax for `select`: `string select index`.
- `toArray` and `toString` reinforced by `splitString` and `joinString`.

### 6.5 Number Operations
- `BIS_fnc_linearConversion` replaced by `linearConversion` (9x faster).
- `BIS_fnc_selectRandomWeighted` replaced by `selectRandomWeighted` (7x faster).

### 6.6 Type Comparison
`typeName` has been more than reinforced by `isEqualType`.

### 6.7 Multiplayer
`BIS_fnc_MP` has been replaced by `remoteExec` and `remoteExecCall` (and it uses them internally). Use the engine commands from now on. See also Multiplayer Scripting.

### 6.8 Parameters
`BIS_fnc_param` has been replaced by `param` and `params` (approximately 14x faster). Use them.
