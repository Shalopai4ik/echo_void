# Ship systems (stages 4.1 – 4.5)

The hull's internals: power, reserve, condition, damage and equipment. Stage 4.1 built
the architecture and the seams; stage 4.2 filled the energy seam with a reserve,
regeneration, switch-on costs and charge alarms; stage 4.3 filled the damage seam with a
pool with a maximum, per-source costs, critical and destroyed alarms, and collisions that
actually cost the hull something; stage 4.4 completed the equipment seam with availability
checks, a reason for every refusal, and a structured status for every device. Stage 4.5
wired the seams to each other: a wreck stops the ship, a damaged generator browns out its
neighbours, and no hostile number can poison the reserve. The rest of the mechanics still
land in the sub-stages after this one. A follow-up pass added per-device hit location
inside the damage seam.

The rule the whole layer is built around is the same one the flight model has followed
since 1.1: **exactly one place owns each number.** One place integrates the hull
(`ShipController`), one place turns a request into engine power (`EngineController`),
one place shares the power budget, one place writes integrity, one place classifies an
impact. Nothing in this layer moves the ship.

## The object graph

```
Ship (ShipController, RigidBody2D)          # untouched, does not import this layer
├── Engines (EngineController)              # untouched
├── Audio, Visuals, EngineFx, Camera …      # untouched
└── Systems (ShipSystems)                   # the one node this stage adds
    ├── energy : ShipEnergySystem           # RefCounted — the power budget and its reserve
    ├── health : ShipHealthSystem           # RefCounted — the integrity ledger
    ├── damage : ShipDamageRouter           # RefCounted — world impact -> ship event
    ├── EnergyClock : ShipEnergyClock        # Node — the one per-frame tick (stage 4.2)
    └── <devices>                           # ShipComponent children, mounted by the
                                            #   scene author; none ship yet
```

`ShipSystems` is a node because the project injects dependencies through the tree —
`project.godot` has no `[autoload]` section and every suite runs headless because of it
(see `architecture.md`). The three systems are `RefCounted`: they have no `_process`,
no `_physics_process`, and nothing to leak. A component finds its hub by walking up the
tree in `_ready()`, so **mounting a device is installation**.

## The four responsibilities

| System | Owns | Does not |
| --- | --- | --- |
| `ShipEnergySystem` | the output (reactor + named auxiliary sources), the reserve (capacity, charge, regeneration), the appetites, the priority order, the grant written into each device, the brownout flag, the low/empty/restart lines | burn fuel, model heat, decide what a device's appetite means |
| `ShipHealthSystem` | the hull's pool and maximum, the clamping of damage and repair, the mean ratio of the mounted devices, the refusal of NaN/negative amounts | hold a second copy of a device's integrity, decide what damage costs |
| `ShipDamageRouter` | reading one contact report, the severity band, a normalized impact event, the per-band cost lookup | own the health ledger, apply the wound, decide the balance |
| `ShipSystems` | the registry, the bus, the equipment control API (switch, toggle, availability, status), the damage API, the hull's aggregate state, the bridge to the flight model's own signals | any per-frame work, any physics |
| `ShipComponent` | identity, appetite, the crew switch, integrity, the derived state, its four signals, `status()`, `publish()` | decide its own state, reference another device |

## The three states

`NOMINAL`, `DAMAGED`, `OFFLINE` — one enum, one rule, in `ShipSystemState.evaluate()`.
The state is **derived**, never assigned, from three numbers a device carries plus one
fact about the ship it is mounted on:

1. the crew switch (`enabled`),
2. the integrity the health system wrote,
3. the share of its appetite the energy system actually granted,
4. whether the hull is still a ship (`hull_alive`, optional and true outside one).

```
hull is a wreck                    -> OFFLINE    (no ship - 4.5)
switch off                         -> OFFLINE
integrity <= offline_integrity     -> OFFLINE    (wrecked)
grant <= offline_power_ratio       -> OFFLINE    (starved)
integrity < damaged_integrity
  or grant < damaged_power_ratio   -> DAMAGED    (works, badly)
otherwise                          -> NOMINAL
```

All four thresholds live in `ShipSystemsParameters`. `efficiency()` turns the state into
the number a device's own code multiplies by: `1.0`, `damaged_efficiency` (0.5) or `0.0`.
The hull is judged by the same rule with the switch fixed at on, so a hull at 40% reads
`DAMAGED` for exactly the same reason a sensor does.

Inheritance is deliberately avoided: a device does not decide it is damaged, it *is*
damaged because a number crossed a line. That is what makes the state testable from
outside and impossible to fake from inside.

## Power

```
available = reactor_output + Σ auxiliary sources        (ShipEnergySystem.output())
```

`allocate()` sorts the consumers by `power_priority` (highest first, registration order
breaks ties — a manual stable insertion, because `sort_custom()` is not guaranteed
stable), then walks them granting `min(appetite, what is left)`. Each grant is written
back as a 0..1 ratio through `ShipComponent.set_power_ratio()`. Devices that are off,
wrecked, or passive are granted 1.0 so that "unfed" and "did not ask" never look alike.

Allocation runs **only when something moves** — a mount, an unmount, a switch, an
auxiliary source, a threshold crossing — never per frame. The loop is re-entrancy
guarded: writing a grant can change a state, the hub answers a state change by asking
for another allocation, and the guard replays that request once after the current pass
instead of restarting it in the middle.

`demand()` is what the devices *want*; `granted()` is what the bus *gave*; a starved
device keeps asking and reads `OFFLINE` or `DAMAGED` according to its grant. That
distinction is why switching one device off visibly powers another.

## Reserve (stage 4.2)

`output()` is the peak the bus may deliver in an instant. The reserve is what pays for
that delivery over time:

```
capacity   energy_capacity         units the tank holds (0 disables the reserve)
charge     charge()                  live level, clamped to 0..capacity
refill     energy_recharge_rate    units gained per second, before load
drain      granted()               units per second actually handed out
```

`ShipEnergySystem.advance(delta)` is called once per physics frame by `ShipEnergyClock` —
a child node, so the hub itself still has no `_process`/`_physics_process`. Regeneration
lands first, the granted load is subtracted second, and the result is clamped. A device
the bus could not feed was granted 0 and therefore costs 0: the ship pays for what it
used, not for what it wanted.

One-off costs are a separate path. `ShipComponent.activation_energy_cost` is a surge,
not a rate; `set_enabled(true)` asks the hub before the switch moves, and
`ShipSystems.request_activation()` checks and spends **atomically** through
`ShipEnergySystem.try_spend()`. A refused activation costs nothing, an already-lit device
cannot pay twice, and `can_activate()` is the free check a later UI can poll.
`spend_energy(id, amount)` applies the same rule to an arbitrary device action.

`ShipSystemsParameters` carries the two alarm lines as well:

* `energy_low_ratio` — charge at or below this raises `energy_low` once per crossing;
* `energy_restart_ratio` — after a blackout the bus stays dark until the tank is back
  above this fraction, so it cannot flap on every regenerated unit.

Depletion itself is the ordinary rule doing its job: `output()` becomes 0, every device
is granted 0 and derives `OFFLINE`, `is_brownout()` is true, and `ENERGY_DEPLETED` goes
out once. Recovery raises `ENERGY_RESTORED` in the same step the bus comes back.

## Hull pool and damage (stage 4.3)

The hull is the one ledger with a real pool:

```
current   hull_integrity()       points left, clamped 0..maximum
maximum   hull_max_integrity()   hull_max_integrity, default 1.0
ratio     hull_ratio()           current / maximum, the state rules' and a HUD's unit
```

The default maximum of 1.0 keeps the numbers the layer started with (0.15 is 15% of the
hull). Raise it to 100 for visible hit points and scale the three impact numbers with it;
a retune preserves the fraction, not the old points.

`ShipSystems.apply_hull_damage(amount, source)` is the only door:

* negative, zero, NaN and infinite amounts are refused;
* `source` is free text; `damage_source_scale` may discount or amplify it
  (`{"arc": 0.5, "fire": 2.0}`), and a source that is not in the table costs exactly what
  the caller asked — a new hazard needs no edit to the damage system;
* a wreck (`hull_ratio() == 0`) accepts nothing more, so a rock grinding on a dead hull
  cannot keep producing wounds;
* the ledger clamps, and only then `hull_damaged`, `hull_integrity_changed`,
  `DAMAGE_TAKEN` and the two alarms follow.

`hull_critical` fires once when the ratio crosses `critical_hull_ratio` (0.25). It is an
alarm, not a fourth state: the words remain NOMINAL / DAMAGED / OFFLINE. `hull_destroyed`
fires once at zero and is a **signal and a latch, not a scene change** — the ship is not
deleted, the flight model is not switched off, and what a wreck does to the camera, HUD
and run is a later decision.

### Which device was hit

`ShipSystems.hit_component(info)` picks the mounted device nearest the impact's estimated
contact point, within `component_hit_radius` (90 px). A device's place is the nearest
`Node2D` at or above it, so a component under a `Marker2D` is locatable and a bare `Node`
device is not. The impact event carries `hit_component`, `hit_distance` and
`hit_is_estimate: true`; the struck device then takes `impact_device_damage_scale` (0.5)
of the hull's *fractional* loss through the ordinary `apply_damage()`. A scale of 0 keeps
the location and spares the device; a radius of 0 disables location entirely.

This is the same estimate the flight model already flags: a point on the centre-to-centre
line, not a manifold query. It answers "which compartment", not "which plate".

### Where collision damage stops

`ShipController` already guarantees one classified contact per object per
`collision_event_cooldown` (0.3 s), built from the shape signal so one rock meeting three
hull slabs is one event. `ShipSystems` turns that event into one wound. Nothing in the
damage path writes velocity, applies force or bounces the body: the physics material and
the flight model own that, and this stage only reads the result.

`impact_damage_enabled` ships **on** as of 4.3; turn it off in the resource to keep a
scene's collisions cosmetic while the events keep flowing.

## Equipment control (stage 4.4)

Mounting is still installation: a `ShipComponent` under `Ship/Systems` registers itself,
gets an id, lands on the power bus and derives a state. What stage 4.4 adds is the control
surface a bridge or a future UI needs, and none of it is a second manager:

```
switch        set_enabled(id, value) / toggle_enabled(id) / set_all_enabled(value)
availability  can_activate(target) / activation_block_reason(target)
status        equipment_status(id) / equipment_statuses()
```

`set_enabled()` returns whether the switch actually moved. A start is refused for one of
three reasons, in this order:

```
destroyed   the hull is at zero integrity
wrecked     the device is at or below offline_integrity
(power)     the reserve cannot pay activation_energy_cost
```

The first two raise `activation_denied(id, reason)`; the third raises the existing
`activation_refused(id, cost, available)`. Both also go on the bus as CUSTOM events. A
refusal never moves the switch and never spends energy.

### What a device draws and when

`nominal_power_draw` is paid only while `draws_power()` is true: the crew switch is on and
the device is above its offline line. A *brownout* is not a reason to throw the switch: a
starved device reads OFFLINE, draws nothing, keeps `enabled == true`, and comes back by
itself when the bus recovers. Physical damage above the offline line is different:
`DAMAGED` still draws the full appetite and works at `damaged_efficiency`; at or below
the line the device is a wreck, draws nothing, cannot be switched on, and needs a repair
before it can be lit again.

### Status without a UI

`equipment_status(id)` returns a dictionary with `id`, `title`, `enabled`, `state`,
`state_name`, `integrity`, `efficiency`, `power_ratio`, `demand`, `available`,
`can_start`, `block_reason`. `equipment_statuses()` is the same for every mounted device,
in registration order. A panel, a save file or a research system reads this instead of
touching fields, and a new device gets the shape for free.

### Reacting to damage

The control system does not own a second damage model: it reads the one `ShipHealthSystem`
writes. `ShipSystems.apply_damage()` already moved the number, `ShipSystemState` already
derives the word, and `draws_power()` already stops the appetite. The only control rule
added here is that a wreck cannot be *started* - the switch refuses before the energy
system is asked.

The crew switch is **intent, not health**: a wreck keeps the switch where the crew left
it, while the derived state and the appetite change. That is why a repair brings a wreck
back without a second switch throw, and why a brownout never moves the switch either.

## Events

One value object, `ShipSystemEvent`, with a kind, a component id, a magnitude, a
timestamp and a free-form `data` dictionary.

| Kind | Raised by | Meaning |
| --- | --- | --- |
| `STATE_CHANGED` | hub | a device or the hull crossed a threshold |
| `POWER_CHANGED` | hub | a grant was written |
| `DAMAGE_TAKEN` / `REPAIRED` | hub | `apply_damage()`, `apply_hull_damage()`, `repair*()` |
| `ENABLED` / `DISABLED` | hub | the crew switch moved |
| `IMPACT` | hub | the flight model reported a classified contact |
| `EQUIPMENT` | device | `publish(topic, data)` — a device's own vocabulary |
| `ENERGY_LOW` | hub | the reserve crossed `energy_low_ratio` |
| `ENERGY_DEPLETED` | hub | the reserve hit zero; the bus is dark |
| `ENERGY_RESTORED` | hub | the reserve cleared `energy_restart_ratio` after a blackout |
| `CUSTOM` | anyone | `dispatch(ShipSystemEvent.custom(...))` — also carries `activation_refused`, `activation_denied`, `hull_critical` and `hull_destroyed` |

The hull's own signals fire in this order on one hit:
`hull_damaged(amount, integrity, maximum, source)` → `hull_integrity_changed(ratio)` →
`DAMAGE_TAKEN` on `system_event` → `hull_critical(ratio)` once when the line is crossed,
or `hull_destroyed` once at zero. A listener that only needs a bar reads the ratio signal;
a listener that needs the cause reads the damage signal or the event.

Two doors only: `ShipSystems.system_event` for signals, and
`ShipComponent.receive_event(event)` for devices. Delivery goes to **every** mounted
device, including the publisher (check `event.component_id` if you do not want your own
echo). A depth guard drops a chain past eight hops with a warning — a device that
publishes from `receive_event()` is a loop, and a loop with no stop condition takes the
game down on the first frame it happens.

## Cross-system rules (stage 4.5)

The seams above already pass numbers between the four systems. What 4.5 adds is the
wiring where one system's condition has to change another's *behaviour*, and the guards
that keep a hostile caller from changing a number twice.

**A wreck is a stopped ship.** `hull_destroyed` is still a signal and a latch — the hull
is not deleted and `ShipController` is not cut — but the latch now does two things before
it is announced: `ShipEnergySystem.set_bus_online(false)` and a re-derivation of every
device's condition.

* `output()` is zero while the bus is offline, so the ordinary allocation grants zero to
  everything and each device derives `OFFLINE` through the same three-word rule. Nothing
  is switched off behind the crew's back: the switches keep their positions.
* `ShipSystemState.evaluate()` takes a fifth, optional `hull_alive` argument, and
  `ShipComponent._refresh_state()` fills it from `ShipSystems.is_hull_destroyed()`. A
  passive device with no appetite is therefore `OFFLINE` too — there is nothing to do on
  a wreck — and it is still `enabled`, so a repair brings it back without a second button.
* `advance()` freezes the tank while the bus is offline: a wreck neither draws nor
  regenerates, and the reserve a wreck went down with is the reserve a repair finds.
  `try_spend()` refuses for the same reason, so nothing can fund an action around the
  hub's back.
* `repair_hull()` above zero restores the bus and re-derives every device in the same
  call, before `hull_integrity_changed` is emitted. `set_parameters()` does the same, so a
  retune cannot leave a live hull with a dark plant.
* `activation_block_reason()` already answered `destroyed`; `spend_energy()` now refuses
  for the same two reasons the switch does (`destroyed`, `wrecked`) and says so in the
  `energy_refused` event, so an action cannot be paid for by hardware that is gone.

**A device can feed the bus as well as draw from it.** `ShipComponent.power_supply` is
the number of units a generator, auxiliary reactor or charged battery adds while it is
working; the default of 0 is a consumer, which is every device that existed before 4.5.
`supplied_power()` is the nameplate scaled by what is left of the device (`integrity`),
zero when it is off, wrecked, or on a wreck. `ShipEnergySystem.device_supply()` sums it
into `output()` and the panel prints it as `supply`. That makes damage to a power source a
real brownout: hurt it and the lowest-priority devices lose their grant first; wreck it
and the hull runs on the reactor alone. The supply deliberately reads integrity and never
the device's own grant — the grant depends on the output, and the output would then depend
on the grant, a loop with no fixed point.

**One impact, one wound.** `report_impact()` refuses to nest: a device that calls it from
`receive_event()` gets `null` and a log line instead of a second event, a second hull
wound and a second device wound. The dispatch depth guard alone would only bound the
storm at eight hops, and every hop would already have paid. Sequential impacts — two rocks
in two frames — are untouched.

**Hostile numbers stop at the door.** Every amount that reaches the reserve is checked
for `is_finite`: `set_charge()`, `add_charge()`, `try_spend()`, `can_afford()`,
`advance()` and `add_source()` ignore NaN and infinity, and `ShipComponent.set_integrity()`
/ `set_power_ratio()` refuse them rather than clamping them, because `clampf()` keeps a
NaN. `_commit()` falls back to the previous level if the number it is handed still slips
through, so `0 <= charge <= capacity` is true after every path. A device whose
`nominal_power_draw` or `power_supply` is not a finite positive number is treated as
passive instead of being given a NaN grant.

## Bridging the flight model

`ShipSystems._bind_ship()` connects to the parent's existing `ship_collision_detected`
signal — by name, through `has_signal()`, with no import of `ShipController`. The
controller does not know the layer exists, was not edited for it, and a hull built in
code without a `Systems` node flies exactly as before.

`report_impact(info)` is public: a scripted hazard, a replay or a test can hand the ship
an impact without pretending to be a body. It classifies (reusing the ship's own
`ShipWorldParameters` bands), fills the event, dispatches it, **then** spends integrity
if `impact_damage_enabled` is on — so a listener hears the cause before the effect and
reads a hull ratio that already includes it.

## Adding a device

```gdscript
extends ShipComponent
class_name LongRangeSensor

@export var sweep_seconds := 6.0

func receive_event(event: ShipSystemEvent) -> void:
	if event.kind == ShipSystemEvent.Kind.IMPACT:
		publish("contact", {"closing": event.amount})
```

1. Drop a node with that script under `Ship/Systems`.
2. Set `component_id`, `nominal_power_draw`, `power_priority` and (if the device needs a
   surge to light) `activation_energy_cost` in the inspector. A device that *supplies*
   the bus instead of consuming it sets `power_supply` and leaves `nominal_power_draw` at
   0: a generator, an auxiliary reactor, a charged battery.
3. Nothing else. It registers itself, lands on the bus, gets a derived state, and its
   grant arrives through `set_power_ratio()` → `efficiency()`. Its runtime appetite is
   paid from the reserve, its switch-on surge is checked by the hub, its availability is
   answered by the same rule as every other device, and `equipment_status()` describes it
   with no change to `ShipEnergySystem`, `ShipHealthSystem` or `ShipSystems`.

Ids are stable strings; an empty id becomes the node name in snake_case. A second node
claiming a taken id is refused with a warning rather than silently overwriting a
neighbour's power draw.

## Seams left for the next sub-stages

| Next stage | Where it plugs in | Already there |
| --- | --- | --- |
| Fuel, heat, reactor wear | `ShipEnergySystem.advance()` / `energy_recharge_rate` | a reserve with capacity, charge, regeneration, low/empty/restart lines and events |
| Damaged power plants | `ShipComponent.power_supply` / `ShipEnergySystem.device_supply()` | a supply that scales with the device's integrity and disappears when it is wrecked |
| Death sequence | the `hull_destroyed` signal and `ShipSystems.state()` | a clamped pool, per-source costs, critical/destroyed latches, device hit location, and a plant that is cut with the hull |
| HUD bars | `ShipSystems.energy_ratio()` / `energy_changed`, `hull_integrity()` / `hull_max_integrity()` / `hull_damaged`, `state()`, `system_event` | one writer per number, alarms as signals, no polling needed |
| Research devices (scanner, decoy launcher, signal flares) | `ShipComponent` subclasses; `equipment_status()` / `activation_denied` | mount/switch/availability/power/damage/status, no hub edit |
| Boost's tank | `BoostSystem.set_charge()` / `take_charge()` (documented seam since 1.3) | a `ShipComponent` with `nominal_power_draw` draws from the same reserve |

## Deliberately not implemented

* no fuel, heat or reactor wear — the reserve is a plain tank and regeneration is
  `energy_recharge_rate`, not a modelled reactor;
* hit location is a radius around an estimated point, not a true contact manifold: no
  per-shape damage, and a device with no `Node2D` ancestor cannot be located;
* no death sequence: `hull_destroyed` is a signal and a latch. The ship is not deleted,
  its control is not cut, and no explosion, camera move or game-over is attached. The
  latch *does* stop the ship's own plant and put every device `OFFLINE` (stage 4.5), but
  the wreck is still flyable and still takes input;
* no device mechanics: no scanner sweep, no decoy launch, no signal flare. The control
  system they will use is here; their own behaviour is their own sub-stage;
* no equipment UI: no panel, no buttons, no hotkeys. `equipment_status()` is the read
  side a UI will use later;
* no repair mechanic: `repair_hull()` exists as a seam from 4.1 and is used by tests, but
  nothing in the game calls it;
* no HUD, no visuals, no crew;
* no per-frame update in the hub: `ShipEnergyClock` is its own node, the hub has neither
  `_process` nor `_physics_process`, and the suites assert that.

## Verifying

```powershell
godot --headless --path . --script tests/ship_systems_test.gd
godot --headless --path . --script tests/ship_energy_test.gd
godot --headless --path . --script tests/ship_damage_test.gd
godot --headless --path . --script tests/ship_equipment_test.gd
godot --headless --path . --script tests/ship_integration_test.gd
tools\testing\run_tests.ps1 -Suite ship_systems_test
tools\testing\run_tests.ps1 -Suite ship_energy_test
tools\testing\run_tests.ps1 -Suite ship_damage_test
tools\testing\run_tests.ps1 -Suite ship_equipment_test
tools\testing\run_tests.ps1 -Suite ship_integration_test
```

`ship_systems_test` holds 99 assertions across nine phases: boot and wiring, **flight
unchanged**, equipment mounting and independent switches, budget and priorities, derived
states and integrity, the bus, a real collision against a rock, the panel, and the
teardown (the tree must be the size it was).

`ship_energy_test` holds 61 assertions across nine phases: boot and the clock,
consumption, regeneration, bounds, switch-on cost (including the no-double-charge rule),
low charge and blackout with the restart line, a device mounted after the fact, the live
clock over real physics frames, and teardown.

`ship_damage_test` holds 72 assertions across ten phases: a full hull with a current and
a maximum, a retune to a 100-point pool, direct damage with the physics untouched,
per-source multipliers, refused invalid damage, the critical alarm, destruction and its
latch, per-device hit location with its share and its off-switches, a real rock flown into
(one contact, one wound, no speed amplification), and teardown.

`ship_equipment_test` holds 53 assertions across nine phases: the registry and the status
shape, on/off/toggle/all switches, the switch-on price paid once with a short reserve
refused, a wrecked device denied with its reason and made startable by repair, a brownout
that goes OFFLINE without throwing the crew switch, damage from DAMAGED to wreck and back,
a destroyed hull that refuses every start, a new device class that needs no hub change,
and teardown.

`ship_integration_test` holds 116 assertions across twelve phases and is the one that
tests the wires rather than the seams: normal operation, several devices at once with the
priority order and a grant that adds up to the budget, switches that free and restore
power without touching a neighbour, the activation surge paid once and refused without a
spend, full depletion with the restart line and recovery, hull damage during work (DAMAGED,
wrecked, repaired) with the neighbours untouched, a wrecked device that can neither start
nor spend, destruction that cuts the plant, puts every device — including a passive one —
`OFFLINE`, freezes the tank and blocks every start, a repair that brings the ship back
under the same switches, a damaged generator whose supply browns out the hull and a
repaired one that restores it, a re-entrant impact that lands exactly one wound, NaN and
infinity refused at every door into the reserve, the panel, and teardown.