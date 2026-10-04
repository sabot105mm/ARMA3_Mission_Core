# MISSION CORE - DESIGN RULES (authoritative)

Owner-stated rules. These are not suggestions. Read this before editing `fnc/`.

## 1. Resource storage roles

| Resource | Who CREATES it | Who STORES it for requestors | Who only REQUESTS |
|---|---|---|---|
| Manpower | `port` | **`base`** | everything else |
| Ammo | `port` (the creator) | **`depot`** | everything else |
| Tanks | `factory` (builds 1 / 10 min) | **`depot`** (also `factory`, `base`) | everything else |

- Every marker keeps its own LOCAL pool. A marker spends its own pool to re-field its
  own garrison, spawn/despawn groups, and absorb attrition.
- "Stores for requestors" means only that marker type can be DRAINED to supply another
  marker. It does not mean other markers have no local pool of their own.

### Known map dependency

`depot_` markers are **required** for the ammo rule to function. As of the last check
`mission.sqm` contained **0** `depot_` markers, so ammo does not flow until they are
placed. The ammo rules below are strict, not fallback-guarded, by owner decision.

## 2. The two manpower channels - do not conflate them

Manpower moves two completely different ways. They share one primitive and nothing else.

### A. Reinforcement - `fnc/commander/fn_requestReinforcement.sqf`

- Reinforcement squads spawn at the **sender's** marker and **walk** to the target.
- The cost is taken from the **sender's own** `MISSION_CORE_LOCATION_SUPPLY` pool.
- **ANY marker may be a sender** (except powerplants / solar, which never give).
- These men are not shipped, so they are never a resupply order.
- **This file is off limits to supply work.**

### B. Resupply order - `MISSION_CORE_fnc_resupplyDispatch` in `fn_convoyLoop.sqf`

- A **storer** ships a physical convoy of supply to a marker that is running low.
- **Only a `base` may be a storer.** This is the ONLY place the storer rule is enforced.
- A marker that has acted as a reinforcement sender, or has simply been ground down, becomes
  *eligible* for a resupply order once its own pool drops below its floor.
- Stock moves as trucks. It can be intercepted, and it is lost if the trucks die.

### Why the rule lives where it does

`MISSION_CORE_fnc_startConvoy` is a **neutral primitive** - "ship N from A to B" - because both
channels call it. It deliberately applies NO rule about what may be a sender.

An earlier version put the base-only check inside `startConvoy`. That was wrong: reinforcement
pays the sender through `startConvoy` (it is the only place the sender's pool is debited), so the
check silently made **reinforcement free for every non-base sender** - towns, outposts, factories
and HQ all fielded squads at zero cost. Never gate `startConvoy` on a type rule.

## 3. Scope boundaries - DO NOT CROSS

- **Supply work means SUPPLY ONLY**: shipment, movement, routing, storage rules, and the
  `MISSION_CORE_LOCATION_SUPPLY` pool, all in `fnc/commander/fn_convoyLoop.sqf` and `fnc/fn_ammo.sqf`.
- **NEVER edit reinforcement logic** (`fnc/commander/fn_requestReinforcement.sqf`).
  Reinforcement gets its manpower from the sender's marker. It is not supply's business.
- Do not edit `fnc/commander/fn_playerHunt.sqf` for supply reasons.
- Do not edit `fnc/spawn/fn_requestArmorReinforcement.sqf` for supply reasons.
- Do not rename `MISSION_CORE_LOCATION_SUPPLY` or its keys.
- The road-node pathfinder (`MISSION_CORE_fnc_roadRoute`) lives in `fn_convoyLoop.sqf` for now.
  Other systems keep their own routing; do not refactor them onto it uninvited.

### Hard-won lesson

An earlier change was reverted wholesale (`git checkout` back to `06b061c`) because a
supply-routing task was allowed to spread into reinforcement, counter-attack, ammo and
the manpower economy. Keep supply changes inside supply.

## 4. Convoy rules that are deliberate

- A convoy is an abstract cargo record. It **carries no combat units**.
- Provider is debited at dispatch; recipient is credited only on arrival.
- `MISSION_CORE_fnc_startConvoy` returns `true` only if a convoy record was actually created.
  Callers use this to avoid cooling down a requester that received nothing.
- A shipment is one cargo record: if ANY truck in a column is destroyed, the whole
  shipment is lost. Per-truck loss accounting would mean changing what the recipient is
  owed mid-route.
- Supply convoys into a marker keyed in `MISSION_CORE_CONTESTED` are refused (PERMANENT
  RULE). This is intentional even though it means busy markers go unsupplied.
- Destroyed trucks are fully deleted, crew included. Wrecks must not persist.
- If materialisation fails (no truck spawns), the exact debited `_cost` is refunded onto
  the CURRENT pool value, never onto a stale snapshot.

## 5. Tune keys added for supply convoys

All tunable mission variables live in `config/missionVars.hpp` under
`class MISSION_CORE_TUNE` (description.ext only `#include`s that file):

- `supplyRouteNodeBudget = 1200` - BFS node expansion cap
- `convoySupplyPerTruck = 100` - cargo per truck
- `convoyColumnMax = 6` - trucks per convoy
- `convoyColumnSpacing = 14` - echelon spacing (m)
- `convoyArriveRadius = 150` - delivery radius
- `convoyStragglerGrace = 90` - grace after leader arrives
- `convoyLootBoxMax = 3` - ammo boxes on a loss
- `resupplyDispatchEveryTicks = 12` - convoy ticks between resupply sweeps
- `resupplyTriggerFrac = 0.35` - order below `importance * this * 100`
- `resupplyTopUpAmount = 60` - max per order
- `resupplyStorerReserve = 40` - a base keeps this much for itself
- `resupplyStorerFloor = 30` - below this a base stops shipping
- `resupplyCooldown = 300` - per-requester cooldown (s)
