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

`depot_` markers are **required** for the ammo rule to function. On the live Altis map
`mission.sqm` resolves **13 usable EAST depots** (`depot_1`..`depot_13`); only the bare
`depot` marker is not registered, because `fn_markers.sqf` special-cases bare names only
for Outpost/Powerplant/Solar. The sweep counts this live, so adding a depot in the editor
shows up on the next restart as a higher `depots=` figure - not as a stale constant. **WEST has no depots by design** - if WEST resupply is ever
wanted, place `depot_` markers for it, because the request channel filters donors by owner
and a side with no depot can never be resupplied. The ammo rules below are strict, not
fallback-guarded, by owner decision.

Depot capacity and donation are tuned in `config/missionVars.hpp`: depot rows only get
`ammoDepotCapacityMult` (2x) storage and a randomised 40-70% opening stock, because a
depot is a warehouse rather than a garrison and importance-scaled storage left the caps so
small that the donor floor excluded depots even when full. A depot donates only while above
`ammoDonorStockFrac` of its own cap, never below the absolute `ammoDonorStockMin`.

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
- **Reinforcement logic (`fnc/commander/fn_requestReinforcement.sqf`) is off-limits to SUPPLY
  work.** Reinforcement gets its manpower from the sender's marker. It is not supply's business.
  It is NOT off-limits in general - see the standing mandates in section 3a, which do edit it.
- Do not edit `fnc/commander/fn_playerHunt.sqf` for supply reasons.
- Do not edit `fnc/spawn/fn_requestArmorReinforcement.sqf` for supply reasons.
- Do not rename `MISSION_CORE_LOCATION_SUPPLY` or its keys.
- The road-node pathfinder (`MISSION_CORE_fnc_roadRoute`) lives in `fn_convoyLoop.sqf` for now.
  Other systems keep their own routing; do not refactor them onto it uninvited.

### 3a. Standing mandates that DO cross those boundaries

These are deliberate, owner-approved exceptions to section 3. They are not supply work and they
were not invited in by a supply task - each was requested explicitly. Reverting them "because
section 3 says so" is a regression, not compliance.

- **Non-combat-effective markers mount no offensive action.** A Factory, Powerplant, Solar or Depot
  is a production/logistics site: its garrison defends in place and never launches a reinforcement,
  counter-attack or assault. It still captures, still fields its garrison and static defenses, still
  receives support, and its own self-defense is untouched - only the offensive half is removed.
  Enforced in two layers, and **both are required**:
  - *Layer 1 - selection.* These markers are filtered out before they are chosen as a source, so no
    manpower is spent and no log claims a march that will not happen.
  - *Layer 2 - dispatch.* `fn_sendCounterAttack` refuses the order. This layer exists because
    `fn_aiAssaultLoop` wave groups and `fn_armorCommanderLoop` build their own waypoints and never
    call `sendCounterAttack` at all - deleting that guard would have silently reopened the hole.

  Single source of truth: `MISSION_CORE_fnc_isNonCombatEffective` / `..._groupIsNonCombatEffective`
  in `fnc/fn_markers.sqf`, driven by the `nonCombatEffectiveMarkers` / `nonCombatEffectiveGate`
  tunes. Do NOT re-implement this check inline at a call site, and do NOT delete the `sendCounterAttack`
  guard - `fn_aiCommanderLoop` commits every group of the side with radius `1e10`, so that guard is
  also what keeps power/solar garrisons home.

  Deliberately NOT gated, because they are not offensive dispatches: hunts
  (`fn_playerHunt`), port/ammo resupply routing (`fn_portSystem` via `getMarkerNeighbors`),
  quadrant engagement, long-range reaction, static defenses, house occupation, and target-side
  filters. `getMarkerNeighbors` takes an opt-in `_excludeNonCombat` flag for exactly this reason -
  three of its four callers must keep seeing depots and factories.

### Hard-won lesson

An earlier change was reverted wholesale (`git checkout` back to `06b061c`) because a
supply-routing task was allowed to spread into reinforcement, counter-attack, ammo and
the manpower economy. Keep supply changes inside supply. Note the boundary is about *who
initiated the change*, not about whether reinforcement code may ever change - section 3a is the
record of the times it legitimately did.

## 3b. Abstract travel for long-range troop legs

A foot squad dispatched `reinforceAbstractMinDist` (2000m) or further does not spawn
immediately. It becomes an **abstract leg**: a record with no units in the world
(`fnc/commander/fn_abstractLeg.sqf`), carrying the men as a promise. It raises a real
squad only when a player comes within `abstractLegPlayerRadius` (1200m) of the leg's
position along its route, and hands the last stretch to the normal arrival script once
the squad is inside `routeLegFinalRadius` (1000m) of the destination.

- **Exactly three dispatch paths are eligible.** All three spawn a squad and immediately
  send it somewhere, with nothing waiting on it: `fn_requestReinforcement`,
  `fn_neighborCounterAttack` (the *conjured* branch only), `fn_queuedCounterAttackInf`.
- **The threshold is measured on the ROUTE'S OWN ENDPOINTS.** Both marker positions are
  resolved from `MISSION_CORE_CACHED_POSITIONS` by name - the same pair `routePlan` routes
  between - and the caller's positions are not used for the test. They cannot be: the
  commander loop reads `_locPos` out of `MISSION_CORE_LOCATIONS` while the provider side
  comes from the cache, and the two disagree. That disagreement is what once let a 639m hop
  clear a 1500m gate, materialise at the provider and hand off one second later, 639m from
  where it was supposed to be going. A road arc is always `>=` the straight line between
  its endpoints, so **a logged route shorter than the gate distance means the endpoint
  lookup has regressed** - both numbers are printed on every dispatch line to make that
  visible immediately.
- **Replenishment is NOT eligible.** `fn_replenishMarker` and `fn_queuedReplenish` are a
  garrison re-fielding its OWN men: the squad spawns on that marker's edge and either
  walks tens of metres to its own centre or marches to a contested neighbour. That is not
  a neighbouring force making a long haul to someone else's fight, so every journey out
  of those two files is concrete. Do not add a dispatch call to them.
- **Assault staging is NOT eligible, by design.** `fn_assaultStaging` and the staged mode
  of `fn_spawnAssaultGroup` hold groups at the source edge and *wait* for the whole force
  to assemble before releasing it. Abstracting one of those groups would leave the release
  monitor waiting on men that do not exist, so the assault would never launch. Eligibility
  follows whatever actually STARTS the attack, and staging does not start anything - it
  only assembles.
- **KNOWN GAP: the assault WAVE is not abstracted either** (`fn_aiAssaultLoop.sqf`, the
  `for "_w"` wave loop). This one is deliberate for now, not an oversight. The wave is a
  real long haul - it spawns 300-500m from the source and trucks to the target - but its
  lifecycle is synchronous: 300s after the wave spawns, that loop kills 80% of every unit
  in `_assaultWaves`, deletes the trucks and driver groups, drops the waves from
  `MISSION_CORE_SPAWNED_GROUPS`, and clears `MISSION_CORE_ASSAULT_ACTIVE`. `_assaultWaves`
  is a FUNCTION-LOCAL array, and an SQF code block does not close over the enclosing scope,
  so a leg that materialises late cannot be added to it. Such a wave would escape the 80%
  resolution entirely and sit in `MISSION_CORE_SPAWNED_GROUPS` as a permanent foot-cap
  consumer. Abstracting it requires moving the wave/truck/driver bookkeeping into
  mission-namespace state keyed by assault id, so the resolution can still find a late
  arrival. Do NOT add a dispatch call to that loop without doing that move first.
- **A re-tasked squad is never abstracted.** `fn_neighborCounterAttack` prefers an idle
  garrison squad over conjuring a new one; that squad already stands in the world.
- **A self-replenish squad is never abstracted.** Neither kind is: see the replenishment
  rule above.
- **A pending leg cannot hold a cap slot forever.** Pending legs reserve a `footSquadCapSquads`
  slot and only the leg tick ever releases it, so a leg the tick loses track of would pin
  that slot for the rest of the mission - and because the neighbouring dispatch gates test
  the same cap, stranded legs make the AI stop reinforcing while still visibly queueing.
  `abstractLegPendingSlack` (180s, a safety valve rather than a knob) forces any leg still
  abstract that long past its own travel time into the world at its destination.
- **The 2000m gate is sticky per provider/target pair.** The test is the 2D straight line
  between the two markers, never the solved arc, and `MISSION_CORE_ABSTRACT_GATE` memoises that
  distance under the key `"from>to"`. Without it, every dispatch attempt for the same pair
  re-walked both endpoints out of the live cache, so a row rewritten in place between two asks
  (tier refresh, a capture flipping its owner) could re-decide an unchanged pair and one sweep
  would abstract a haul the next sweep refused. The memo stores the DISTANCE only, never the
  verdict, so `reinforceAbstractMinDist` still moves the threshold for every pair - it is not a
  cached allow/deny list. It deliberately does not survive a deleted endpoint: the name lookup
  runs first and declines with "endpoint missing", since a memoised distance would route a leg to
  a marker that no longer exists. It is dropped (`= nil`) wherever the marker set is rebuilt or
  pruned: `fnc_cacheTerrain` (fn_cache.sqf), fn_init.sqf, and nested-port removal in
  `fn_portSystem`.
- **Staging absorption wins over abstraction.** `fn_tryAbsorbSupply` needs a live group
  and takes priority over marching, so while an assembly is filling at a marker its supply
  squads go to the staging roster no matter how far the contested marker is.
  `fnc_hasActiveStaging` mirrors `tryAbsorbSupply`'s four guards so callers can ask this
  before spawning; keep the two in step.
- **A leg takes no manpower and no ammo until it spawns.** `commitProviderMen`,
  `MISSION_CORE_COMMIT` and `consumeAmmo` all run inside the leg's materialize block, not
  at dispatch. An abstract-only provider also skips the post-walk ammo charge in
  `fn_neighborCounterAttack`, or it would be billed twice.
- **A leg IS accounted for at dispatch.** Pending legs count toward `footSquadCapSquads`
  and toward the zone's 200-man cap, so a provider cannot mint free squads - nothing is
  debited, but the budget slot is reserved. This is why `fnc_countPendingAbstractLegs`
  exists: `fnc_countFootSquads` cannot see a squad that has no group yet.
- **A leg is irreversible.** It is never cancelled or refunded - not when the destination
  changes owner, stops being contested, the zone budget drains, or the provider is
  captured. The destination position is frozen into the record at dispatch for the same
  reason. The only exit is handoff, and a leg that runs out of route is force-handed-off
  rather than left to sit at 100% forever.
- **Route legs are shared with convoys.** `fnc/commander/fn_routeLegWps.sqf` emits
  waypoints in a fixed `routeLegSpacing` (700m) stride plus one trailing waypoint to the
  target. Convoys and tank columns use it too - that is waypoint DENSITY only and changes
  no economics. `routeLegFinalRadius` is deliberately a single tune shared by the stride
  cutoff and the troop handoff ring: two values could drift and leave a squad idling past
  the ring, or hand it off before it reaches its leg.
- Abstract legs are deliberately **absent from `fn_recon.sqf`**. Once materialised a squad
  is an ordinary group and is killable as normal; only the abstract phase is untouchable.

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
- The same ban applies to AMMO, not only manpower. A contested marker receives neither. It is
  enforced in two places per channel, so a direct call cannot route around it:
  `fnc_startConvoy` (recipient guard) and the request loop's own skip, in `fn_convoyLoop.sqf`;
  `fnc_dispatchAmmoConvoy` (recipient guard) and the request loop's skip, in `fn_ammo.sqf`.
  A contested DONOR is still a valid source - only receiving is banned.
- A marker that is ACTIVELY HELPING a contested zone gets a slight priority when asking for
  supplies of its own (`ammoContestedAssistEdge` / `resupplyContestedAssistEdge`, 1.25).
  "Helping" is the existing `MISSION_CORE_fnc_getMarkerNeighbors` set - same side, not the zone,
  not another contested zone, not light infrastructure, within `neighborRange`, overwatch-aware -
  so the supply channels and the troop channels cannot disagree about who counts as a helper.
  A marker merely standing near a contested zone, doing nothing, gets nothing.
  It is a MULTIPLIER applied before `requestChanceMax`, so it shifts order volume and never rank:
  a starving unimportant marker can never outrank an empty important one. It never applies to a
  contested marker, since the helper returns 1 for those and they are refused supply anyway.
- Destroyed trucks are fully deleted, crew included. Wrecks must not persist.
- If materialisation fails (no truck spawns), the exact debited `_cost` is refunded onto
  the CURRENT pool value, never onto a stale snapshot.
- **An unroutable pair ships on a straight line, it does not fail forever.**
  `MISSION_CORE_fnc_supplyRoute` itself NEVER returns a straight line - it returns an empty
  path and records a backoff so the next attempt re-searches. The fallback lives one layer
  up, in the three consumers: `MISSION_CORE_fnc_routePlan` (abstract ammo, troop legs,
  armor orders), `MISSION_CORE_fnc_startConvoy` (physical supply trucks) and the manpower
  port tick. Each builds the same 3-point plan via `MISSION_CORE_fnc_straightPlan` (3
  points, not 2, so `count _cum >= 2` still holds for `routeLegWps` and the abstract-leg
  guard), nothing about it is cached, and the road search keeps retrying underneath - so a
  later order for the same pair silently upgrades to a real route. Gated by
  `supplyRouteStraightFallback` (1 = on): set it to 0 to restore refuse-and-refund / hold
  the batch. ETA on a fallback leg is the 2D distance, so it is optimistic next to a road
  arc. The route warm pass measures ROAD connectivity only and never falls back - its
  `routed/unroutable` counts are meant to stay honest.

## 5. Tune keys added for supply convoys

All tunable mission variables live in `config/missionVars.hpp` under
`class MISSION_CORE_TUNE` (description.ext only `#include`s that file):

- `supplyRouteNodeBudget = 25000` - BFS node expansion cap (was 1200 here; the code moved first)
- `supplyRouteSnapBase = 800` - endpoint road-snap radius (NOT a minimum shipping distance)
- `supplyRouteFailBackoff = 30` / `supplyRouteFailBackoffMax = 600` - retry schedule for an
  unreachable pair
- `supplyRouteStraightFallback = 1` - unroutable pairs ship on a straight line instead of
  being refused (see the convoy rules in section 4)
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
