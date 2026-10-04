# SQF Lessons Learned - Parse Errors I Caused

Authored by Claude (AI assistant) during the reinforcement redesign of
`ARMA3_Mission_Core.altis`. Every entry below is a mistake **I** introduced, the RPT symptom it
produced, and the verified fix. Read this before writing any SQF in this mission.

**The core lesson: in SQF a single parse error fails the ENTIRE file. Every callable defined in
that file then becomes undefined downstream, which produces a cascade of "Undefined variable"
errors that point at innocent-looking call sites hundreds of lines away. Always fix the
HIGHEST line number in the log first, then re-read the RPT.**

---

## 1. `max` / `min` called with two arguments

**Mistake.** Treated `max` as a function:
```sqf
_taper = 1 - ((_dist - _nearBand) / max 0.001 (_range - _nearBand));
```

**RPT.**
```
Error in expression <ge * _taperFrac;   private _span = max 0.001 (_range - _nearBand); >
  Error position: <[_range - _nearBand, 0.001]; >
Error Missing )
File ...fn_reinforceBudget.sqf..., line 102
```

**Cause.** `max`/`min` are **binary operators**, not callables. `max a b` is valid; `max (a, b)`,
`max a (b)`, and `max [a, b]` are all parse errors. Mixing a literal with a parenthesised operand
(`max 0.001 (x)`) is neither infix nor prefix form.

**Fix.** Use infix with an explicit operand on both sides:
```sqf
private _span = (_range - _nearBand) max 0.001;
```

**Evidence used.** `(max|min)\s*\[` matched **exactly one line across 201 files** - the line I had
just written. Infix `a max b` appears 136 times and is known-good. When a construct appears
exactly once in a codebase and is the line that is failing, the construct is the bug.

---

## 2. My "fix" for #1 was also wrong

**Mistake.** "Corrected" it to an array call, which is equally invalid:
```sqf
private _span = max [_range - _nearBand, 0.001];
```

**RPT.** Unchanged: still `Error Missing ;` at line 102, just shifted 99 -> 102.

**Cause.** There is no array form of `max` at all. I had guessed at SQF semantics instead of
checking what the mission actually does.

**Fix.** See #1 - infix only.

**Process lesson.** I also misread the evidence here: both RPT snippets the user pasted were
timestamped `15:49:39` and both already showed the array form, so it was **the same log re-sent**,
not a fresh run proving my fix failed. Check timestamps and content before concluding a fix did or
did not work.

---

## 3. `exitWith` nested inside a `then { }` block

**Mistake.** Rewrote a HOLD gate as a block with the bail-out inside it:
```sqf
if (_verdict == "HOLD") then {
    MISSION_CORE_REINF_COOLDOWN set [_locName, time + _reEvalHold];
    diag_log format [...];
    exitWith {};              // <-- parse error
};
```

**RPT.**
```
Error in expression < round (_assessOut select 0)]; exitWith {}; ... >
  Error position: <{}; >
Error Missing ;
File ...fn_neighborCounterAttack.sqf..., line 110
```

**Cause.** `exitWith` is **not legal inside a `then {}` / `else {}` block**. Arma reports it as a
bogus `Error Missing ;` pointing at the `exitWith` line - the `;` is visibly present, which makes
this especially confusing to debug.

**This was already documented in this mission.** `fn_isMarkerContested.sqf:208-209`:
> `exitWith inside a then/else block is what caused the "Missing ;" parse error, so the early
> return must sit at function scope.`

**Fix.** Side effects stay in the `then` block; the bail-out goes at function scope:
```sqf
if (_verdict == "HOLD") then {
    MISSION_CORE_REINF_COOLDOWN set [_locName, time + _reEvalHold];
    diag_log format [...];
};
// PERMANENT RULE: exitWith is NOT legal inside a then { } block (SQF "Missing ;" parse
// quirk - see fn_isMarkerContested.sqf:208). The HOLD bail-out must sit at function scope.
if (_verdict == "HOLD") exitWith {};
```

**Lesson.** Before restructuring a function, read the `PERMANENT RULE` comments in it and in
sibling files. The previous author had already documented this exact trap and I reintroduced it
anyway.

---

## 4. Unary operator written in infix position

**Mistake.** Wrote `ceil` after its operand:
```sqf
private _groups = ((_provBudget / 8) ceil) min 5;
```

**RPT.**
```
Error in expression <}; private _groups = ((_provBudget / 8) ceil) min 5; for "_i" from 1 to _groups >
  Error position: <ceil) min 5; >
Error Missing )
File ...fn_neighborCounterAttack.sqf..., line 245
```

**Cause.** `ceil`/`floor`/`round`/`sqrt`/`deg`/`rad` are **unary prefix** operators: `ceil x`.
Writing `x ceil` is a parse error. Note this produced `Missing )` here, not `Missing ;` - the
message varies with where the parser gave up, so do not over-index on the exact wording.

**Fix.**
```sqf
// ceil/floor/round/sqrt are UNARY prefix operators: `ceil x`, never `x ceil`.
private _groups = (ceil (_provBudget / 8)) min 5;
```

---

## 5. `call FNAME [args]` - arguments on the wrong side

**Mistake.** Put the args array *after* the callable:
```sqf
call MISSION_CORE_fnc_reinforcePaceWait [_f];
```

**RPT.**
```
Error in expression <call MISSION_CORE_fnc_reinforcePaceWait [_f]}; if (_sentMen > 0) then { ... _to >
  Error position: <[_f]; }; if (_sentMen > 0) then { ... >
Error Missing ;
File ...fn_neighborCounterAttack.sqf..., line 278
```

**Cause.** `call` / `spawn` are **unary prefix operators** that bind to the code that immediately
follows them. `call FNAME [_f]` parses as `(call FNAME) [_f]`, leaving `[_f]` dangling as a
stray array literal -> `Missing ;`. The args array must be the *left* operand.

**Fix.** Arguments first:
```sqf
[_f] call MISSION_CORE_fnc_reinforcePaceWait;
```

**Valid and NOT flagged:**
```sqf
[args] call MISSION_CORE_fnc_sendCounterAttack;     // correct - args on the left
[args] spawn MISSION_CORE_fnc_reinforceDispatch;    // correct
_args remoteExecCall ["FNAME", 2];                  // correct - remoteExecCall differs
```

**Cascade.** This parse error made the whole file fail, so line 268 of `fn_aiCommanderLoop.sqf`
then reported `Undefined variable ... mission_core_fnc_neighborcounterattack`. Fixing 278 cleared
both.

---

## 6. Release gate dropped valid counter-attack orders (not a parse error)

**Symptom.** Orders logged successfully, nothing ever spawned:
```
"DYNAMIC TANK: order placed EAST -> outpost_16 (n=1, assault=true)"
"DYNAMIC REINF: counter-attack tank order placed for outpost_16 (n=1, budget 1/3)"
```

**Cause.** The *queued* spawn handlers - not the order placement - required a living player within
2000m of the target:
- `fn_queuedCounterAttackInf.sqf:14`
- `fn_queuedCounterAttackTank.sqf:5`

```sqf
if (allPlayers findIf { alive _x && { _x distance _targetPos < 2000 } } == -1) exitWith { ... };
```

So during a player-less AI-vs-AI fight the order was placed, queued, then silently discarded. The
fight was real (the marker was in `MISSION_CORE_CONTESTED`) but nobody was watching, so nothing
spawned.

**Fix.** A contested marker is proof there is a live battle at that position; player presence is
not required for the fight to matter. Extracted one shared helper so both paths cannot drift:

`fn_reinforceActions.sqf`:
```sqf
MISSION_CORE_fnc_counterAttackWorthReleasing = {
    params ["_targetPos"];
    ...
    // Any living player near the target.
    if (allPlayers findIf { alive _x && { _x distance _targetPos < _r } } != -1) exitWith { true };
    // Otherwise: any currently contested marker near the target.
    if (isNil "MISSION_CORE_CONTESTED" || { count MISSION_CORE_CONTESTED == 0 }) exitWith { false };
    if (isNil "MISSION_CORE_CACHED_POSITIONS") exitWith { false };
    private _hit = MISSION_CORE_CACHED_POSITIONS findIf {
        (_x select 0) in MISSION_CORE_CONTESTED && { (_x select 1) distance _targetPos < _r }
    };
    _hit != -1
};
```

Both spawn handlers now call `[_targetPos] call MISSION_CORE_fnc_counterAttackWorthReleasing`.
Radius is tunable via `counterAttackSpawnGateRadius` (default 2000).

**Notes.** Reads `MISSION_CORE_CONTESTED` directly. That is the single canonical answer to "is
this marker contested?" - written only by `fn_isMarkerContested.sqf`, and the former
`fn_getContestedMarkers` helper (a second, side-filtered verdict with its own geometry and its own
client broadcast) has been retired. Never derive contested state from a distance test, a waypoint,
a group status, or an ownership filter; join names to `MISSION_CORE_CACHED_POSITIONS` when you
also need geometry.
Data layout verified against the code: `MISSION_CORE_CACHED_POSITIONS` row = `[name, pos, ...]`
(`fn_neighborCounterAttack.sqf:216-218`), and `MISSION_CORE_CONTESTED` is name-keyed
(`fn_isMarkerContested.sqf:106`).

`fn_sendCounterAttack.sqf:230` keeps its own 2000m player check, but it only picks approach
behaviour when a player is watching - it never drops the order, so it is not part of this bug.

---

## 7. My validators passed every broken file

**Mistake.** The four existing checks all reported the files above as CLEAN:
`check-balance`, `check-isequaltype`, `check-chained-commands`, `check-escape-position`, and
`check-sqf-syntax` (which flagged only 6 pre-existing `deleteAt` groups).

**Cause.** Brace counting and line-pattern matching cannot see SQF semantics. All four bugs above
have perfectly balanced braces and no unusual characters.

**Fix.** Added three targeted checkers, each self-tested against known-bad and known-good input
before being trusted:

| Checker | Catches |
|---|---|
| `check-sqf-operators.ps1` | `max`/`min` array + mixed forms, unary arity errors |
| `check-exitwith-block.ps1` | `exitWith` nested inside `then {}` / `else {}` |
| `check-infix-unary.ps1` | `ceil`/`floor`/`round`/`sqrt` in infix position |
| `check-call-args.ps1` | `call`/`spawn` with args on the wrong side |
| `check-bracket-depth.ps1` | per-line `()[]{}` depth, string-aware |
| `check-string-state.ps1` | unterminated string literals |

All live in `C:\Users\Gary\AppData\Local\Temp\opencode`.

**Process lesson.** Each of those checkers threw **false positives on first run** (160, then 5, then
2) because I again guessed at what valid SQF looks like. Every one needed a self-test probe
containing both a real violation and the valid near-miss spellings before I could trust a PASS. A
validator that has never been shown a true negative is not a validator.

---

## 8. I deleted the queue's own work (not a parse error)

`outpost_16` showed 9 solvent providers, a 168-man pool, and 14 men delivered in 14 minutes.

**Root cause 1 - a denied cap dropped the provider.** `fn_neighborCounterAttack.sqf` checked
`fn_spawnerSlotFree`, and on denial logged `skipped - all 4 spawner slots busy` and moved to the
next provider. Nothing was queued. Five permanent slots were held, so every provider past the
fifth contributed nothing. The fix is not to raise the cap: **a denied slot is "not yet", never
"never"** - queue the provider and re-claim the slot at release.

**Root cause 2 - the queue was used as a bulk drop, not a sequence.** The dispatch pushed *all* of
a provider's `_groups` squads in one burst. That is not what a queue is for.

**Root cause 3 - the queue loop deleted jobs added mid-pass.** `fn_spawnQueueLoop.sqf` iterated
`MISSION_CORE_SPAWN_QUEUE` directly and then assigned `MISSION_CORE_SPAWN_QUEUE = _remaining`.
Any job enqueued *during* that pass was overwritten away. Even a correct self-feeding chain was
silently truncated to a single squad per provider. The loop now iterates a `+MISSION_CORE_SPAWN_QUEUE`
snapshot and merges mid-pass additions back in by key.

**Root cause 4 - queued men were charged twice.** The dispatch called `fn_commitProviderMen` at
enqueue *and* `fn_queuedCounterAttackInf` charged again at release, draining providers early. The
dispatch no longer charges queued squads at all; the queue loop's single thread owns that charge,
which also makes its reserve re-check and the charge atomic.

The contract, now enforced in code:

- One job per provider sits in `MISSION_CORE_SPAWN_QUEUE` at a time.
- A job enqueues its own successor **only after it has actually spawned** (`_remaining`).
- `MISSION_CORE_REINF_SENT` is charged **on release**, so men that are still waiting do not spend
  the 200-man cap early.
- Every cap denial returns `false` (stay queued, retry), never `true` (consume and drop).
  `true` is only for terminal outcomes: exhausted zone, target gone quiet, provider captured,
  reserve blown, or the cap finally reached.

---

## 9. A bare unary operator inside a `[...]` literal kills the whole file

Added after a live crash. Both of these broke the mission:

```sqf
diag_log format ["... interest %1 ...", _interest round 100 / 100, _cap];
diag_log format ["... due in %1s", _gap round 10 / 10];
```

`round` is a **unary prefix** operator, so `x round y` is infix and invalid — the same class as
section 4. What made it worse is *where* it sat: inside the `[...]` argument list of `format`, the
preprocessor reads `round 100 / 100, _cap` as a single array element, runs past the comma looking
for its one operand, and reports `Error Missing ]`. The position in the message points at a
semicolon or bracket that looks perfectly fine, because the real offender is 40 characters earlier.

The failure is **file-wide, not line-wide.** One bad argument makes the whole file fail to compile,
so every `MISSION_CORE_fnc_*` it defines goes undefined downstream:

```
Error Missing ]  ... fn_neighborCounterAttack.sqf line 343
Undefined variable: mission_core_fnc_neighborcounterattack  ... fn_aiCommanderLoop.sqf line 268
```

That second line is cascade. Always fix the **highest RPT line number first**.

**Rule: hoist every unary operator out of a literal array.**

```sqf
// WRONG - parse error, whole file dies
diag_log format ["i=%1", _interest round 100 / 100];

// RIGHT - compute first, then format
private _iRpt = (round (_interest * 100)) / 100;
diag_log format ["i=%1", _iRpt];
```

Note `(round _x)` is safe *inside* a literal because the parentheses make it a complete expression.
The danger is the bare, unparenthesized keyword.

**And my validator missed it.** `check-infix-unary.ps1` only matched `)`, `]`, or a digit before the
keyword, on the theory that a bare letter before an operator is always a command name — that keeps
`select floor (x)` out of the results. But `select` and `_interest` both end in `t`, so the rule
could not tell a valid prefix from an infix one. It now also matches an `_`-prefixed identifier
immediately before the keyword (SQF variables are `_`-prefixed, commands are bare words), which
separates the two. Re-tested against the real violation *and* the valid near-miss
`select floor (configFile >> "CfgWeapons")`.

---

## 10. `getMarkerDetermination` returns 3 elements - and I read the wrong one

`fn_getMarkerDetermination.sqf` returns `[tier, garrisonHoldFrac, neighborBudgetFrac]`, so
`select 1` is the fraction of its OWN manpower a marker **keeps** fighting with before it retreats.
Not the fraction it gives up. `select 0` is the tier; `select 2` is `neighborBudgetFrac`, which is
unused by the budget path.

`fn_reinforceBudget.sqf` had it right (`_retreatAt = round (_cap * (_det select 1))`). All three
queued release handlers had it **inverted**:

```sqf
// WRONG - reads the complement, so the floor is cap*0.15 where dispatch uses cap*0.85
_qRetreatAt = round (_qCap * (1 - (_qDet select 1)));
```

A tier-3 provider (hold 85%) therefore had a dispatch floor of `cap*0.85` and a release floor of
`cap*0.15`. The budget could promise men the gate refused, and men dispatch refused were releasable
after the fact. Worse, the release gates also used `fn_markerCapacity` as the base while dispatch
used `MISSION_CORE_LOCATION_SUPPLY` — two different answers to one question, in four places.

All four now call `MISSION_CORE_fnc_providerCanAfford`, which is the only place the floor is
computed. **Never hand-roll a reserve check; call the helper.**

## 11. A flickering contested zone re-advertised identical budgets

`fn_reinforceResetZone` clears `REINF_SENT`, `REINF_EXHAUSTED`, the pair latches and the cooldown
when a zone stops being contested. It deliberately does **not** clear `MISSION_CORE_COMMIT` — that
ledger is the provider's lifetime "men already marching", and zeroing it would hand out free
soldiers.

But `providerBudget` computed `_usable = _stock - _retreatAt` and never read `COMMIT`. Since
counter-attack squads charge `COMMIT` and never debit `LOCATION_SUPPLY`, every input to the budget
was unchanged by marching. Combined with the pair latch being cleared on reset, a zone that
flickered out of contention and came back had each neighbour advertise **byte-identical** numbers
to the wave it had already paid for. `_groups` was recomputed the same, and the trim happened only
later at the release gate — so the log and the plan both lied.

`providerBudget` now subtracts `COMMIT` too:

```sqf
private _usable = (_stock - _committed) - _retreatAt;
```

`_stock` and `_committed` are disjoint sets of men (un-fielded vs. already marching), so this is
not double-counting. `COMMIT` surviving the reset is what makes the second wave genuinely smaller.

**When passing in-walk accruals, know what is already charged.** `fn_neighborCounterAttack` charges
`COMMIT` per directly-spawned squad via `fn_commitProviderMen`, but queued squads are charged only
at release. So the walk's reserve check adds `_queuedMen` and must **not** add `_sentMen` — that
would double-charge the provider, the exact bug section 8 root cause 4 was about.

---

## 12. A `{ }` block with no executor is a silent no-op

**Mistake.** A provider-walk inside a `forEach` body was written as a bare block:
```sqf
{
    private _provIdx = ...;
    private _sentMen  = 0;
    ...
};                            // <-- never invoked, and SQF says nothing
```
**RPT.** No error at all. The surrounding log looked healthy because the lines just above the block
still ran:
```
DYNAMIC QUEUE: +MISSION_CORE_fnc_queuedCounterAttackInf ...
DYNAMIC REINF: outpost_16 dispatch complete - 0 providers, men this dispatch=0, zone sent=0/200
```
Five of those. Every provider's budget was positive (`budget=20 usable=20 ...`) and nothing spawned.

**Cause.** A bare code block is a *literal*. Evaluated as a statement it just yields itself; nothing
runs the body. The `private` declarations inside therefore never executed, so every later read of
`_sentMen` / `_queuedMen` was `nil`. In SQF `nil + 0 == 0`, so `(_sentMen + _queuedMen) > 0` was
`false` and `_spawnedProviders` stayed `0` — with no fault raised anywhere.

The trap is that it looks correct. The braces balance, the statements are reachable-looking, and the
only proof it was dead is that a variable declared inside it reads back `nil` from outside.

**Fix.** `call { ... };` — the walk then runs per provider, and its `private` scope is what keeps
each provider's counters from leaking into the next iteration.

**Lesson.** Any `{ }` in this mission must have an executor on one side (`call`, `spawn`, `then`,
`forEach`, `do`, `count`...). `check-bare-block.ps1` now scans for the executor-less case, which is why
this class gets caught statically instead of by a 40-minute RPT hunt. A variable that is declared,
assigned inside a block, and read outside it is the tell.

---

## 13. A cooldown that logged its cadence and never applied it

**Mistake.** The dispatch committed a verdict-specific cadence, computed and logged it, then stored
the wrong thing:
```sqf
private _reEval = if (_verdict == "CRITICAL")
    then { ["scareCritReevalSeconds", 300] call MISSION_CORE_fnc_tune }
    else { ["scareReinfReevalSeconds", 300] call MISSION_CORE_fnc_tune };
MISSION_CORE_REINF_COOLDOWN set [_locName, time];          // <-- raw time, discards _reEval
diag_log format ["... committed, re-eval in %3s", _reEval];  // <-- logs 300, applies 30
```
**Cause.** Reader and writer disagreed on what the map held. The reader did
`time - _last < scareHoldReevalSeconds`, so *any* stored value bought exactly the 30s HOLD window.
`_reEval` had no reader at all. A CRITICAL marker that had just dispatched was re-asked every 30s
instead of 300s, walking its neighbours' manpower a second time for squads the per-contest cap had
already accounted for.

**Fix.** One map entry, one meaning — an absolute expiry. HOLD stamps `time + _reEvalHold`, a commit
stamps `time + _reEval`, and the reader asks `time < expiry`. The flicker reset in
`fn_reinforceActions.sqf` still deletes the key outright, so a re-contested marker asks immediately.

**Lesson.** If a value is computed and logged but nothing reads it, grep its name — a logged-only
value is a dead value, and its log line is actively misleading because it reports the intent. Rule 14
extended: a value read by one function and written by two others has to have exactly one documented
meaning, or one of the three is wrong in a way no type system will catch.

---

## Rules to follow when writing SQF in this mission

1. **Fix the highest RPT line number first.** It is the root cause; everything below it is cascade.
2. **`max`/`min` are binary.** `a max b`. Never `max a b`, `max(a,b)`, or `max [a, b]`.
3. **`ceil`/`floor`/`round`/`sqrt` are unary prefix.** `ceil x`. Never `x ceil`.
3a. **Never leave a bare unary keyword inside a `[...]` literal.** Hoist it into a `private` first.
    `(round _x)` is fine; `_x round 100` is not. See section 9.
4. **`call`/`spawn` take the code on the right, args on the left.** `[args] call FNAME`. Never
   `call FNAME [args]`.
5. **`exitWith` must sit at function scope**, never inside `then {}` / `else {}`. Legal one-liners
   `if (c) exitWith {};` and `exitWith { if (a) then { b } else { c } };` are fine.
6. **No `setSpeedMode "FAST"`** - valid values are UNCHANGED / LIMITED / NORMAL / FULL only.
7. **Do not mutate a collection while iterating it.** Collect the affected keys first, then delete.
8. **Check what the codebase already does before inventing syntax.** A construct appearing exactly
   once, on the failing line, is the bug.
9. **Self-test every validator** against both a real violation and the valid near-miss forms.
10. **A denied cap is a delay, not a rejection.** Return `false` and let the job stay queued.
    Returning `true` throws the work away.
11. **Charge men when they spawn, not when they are requested.** Reserve on enqueue and you spend
    the cap on squads that may never exist.
12. **A queue is a sequence.** Enqueue the next item from inside the item that just completed, and
    never rebuild the queue from a variable that omits what was added during the pass.
13. **Check a helper's return arity before indexing it.** `[_a, _b, _c]` with `_d select 1` reads
    a different value than the author intended, and the mistake is silent. See section 10.
14. **One definition of affordability, called everywhere.** Never re-derive a reserve floor inline;
    a hand-rolled copy is how the inverted floor reached three files at once.
15. **A reset that re-opens a zone must still be bounded.** Per-zone counters may reset, but the
    provider's lifetime ledger may not — otherwise the budget repeats itself forever. See section 11.
16. **Every `{ }` needs an executor on one side.** `call`, `spawn`, `then`, `forEach`, `do`. A bare
    block is a literal that silently does nothing. See section 12.
17. **If it is logged, something must read it.** A value computed, logged, and never read is dead —
    and its log line lies about the system's behavior. See section 13.
18. **Never read a validator by its last line.** `| Select-Object -Last 1` shows only the `FINAL:`
    summary, which prints `( = 0 [ = 0 { = 0` for a file with an unbalanced closer, because the
    counter clamps at zero. The actual finding is the per-line `EXTRA )` several lines above it.
    Always surface the per-line diagnostics and assert on them by name.
