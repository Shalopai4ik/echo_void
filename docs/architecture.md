# Architecture

## The two ship slices

The project carries two complete implementations of "a ship in space", and the
HUD is the only place they meet.

| | Legacy | Current |
| --- | --- | --- |
| Scene | `scenes/main.tscn` | `scenes/world/SpaceMap.tscn` |
| Controller | `scripts/ship.gd` | `scripts/ship/ship_controller.gd` |
| Field | `scripts/asteroid_field.gd` | `scripts/world/world_field.gd` |
| Status | production | production |

Both are in production. `scenes/main.tscn` is the project's legacy main scene
but **not** `run/main_scene` - that points at `SpaceMap.tscn`. `scripts/hud.gd`
holds both together: `scripts/hud.gd` was written to talk to either hull.

### What depends on the legacy slice

* `scenes/main.tscn`, `scripts/ship.gd`, `scripts/asteroid_field.gd`,
  `scripts/asteroid.gd`, `scripts/asteroid_shapes.gd`,
  `scripts/hull_bank.gdshader`, `scenes/obstacles/Rock.tscn`.
* Tests that load it by path: `smoke_test.gd`, `asteroid_test.gd`,
  `combat_test.gd`, `main_flight_screens.gd`, `screenshot.gd`,
  `ship_anim_screens.gd`, `stage1_flight_screens.gd`.
* `tests/hud_test.gd` asserts 19 legacy behaviours against `main.tscn`.

### Why it was not removed

1. Deleting it would delete seven suites, including the combat and asteroid
   coverage, which is the opposite of the brief.
2. The migration has an accepted interface problem to solve first: the HUD
   reads `shield_ratio()` off the legacy hull and asks the current world field
   for its bodies a different way. That interface is the whole cost.
3. The `hull_bank.gdshader` bank/roll effect is only exercised by the legacy
   sprite.

### The agreed direction

* The current slice is the one that grows. New features land on
  `ship_controller.gd` and `world_field.gd`.
* The legacy slice is isolated but not deleted: it stays as the regression
  fixture for the flight model and for the HUD's legacy contract.
* The HUD must stop distinguishing the hulls by poking at implementation
  internals. The right shape is one small protocol both answer - something like
  `hull_ratio() -> float` and `radar_bodies() -> Array` - declared once in
  `scripts/` and implemented by both. That is a follow-up task, listed in
  `technical_cleanup_log.md`; it was not done here because it changes a scene
  that seven passing suites depend on.
* `move_left/right/up/down` in `project.godot` are bound only by the legacy
  hull and are asserted by `smoke_test.gd` (`action bound: move_left` and
  friends). They are kept for that reason and documented here rather than
  deleted on suspicion.

## Global services

`project.godot` has **no `[autoload]` section**, and nothing in the running tree
looks for a singleton by name. Systems that need each other get each other
through the scene: `ShipController` owns `EngineController`, `EngineVisuals`,
`ShipAudio`, `ShipCamera`, `StabilizationSystem`, `BoostSystem` and
`EmergencyBrakeSystem` as children, and `world_field.gd` preloads its own
dependencies (`CHUNK`, `SHAPES`, `HASH`) rather than reaching for a global.

That is dependency injection through the tree, and it is why the suites work
headless with no bootstrapping. The recommendation is to **keep it that way**:
adding `[autoload]` for `AudioMixer` or a config manager would make every
headless suite depend on a global existing first, and would buy nothing that a
child node does not already give. If a genuinely cross-scene service appears
(a save file, a run-level seed), add exactly one autoload for it then.

## Ship systems

`scripts/ship/systems/` is the hull's internals — power, condition, damage, equipment —
and it is the newest layer on the current slice. It is one child node, `Ship/Systems`,
plus eight scripts; `docs/ship_systems.md` has the full picture.

The energy reserve added in stage 4.2 is the one number in the layer that moves on its
own, so it gets the one per-frame node: `ShipEnergyClock`, a child of the hub with a
single `_physics_process` that calls `ShipEnergySystem.advance(delta)`. The hub itself
still has no `_process`/`_physics_process` and stage 4.1's suite still asserts that.

Stage 4.3 adds no node. The hull's pool lives in `ShipHealthSystem`, the price of a
contact in `ShipDamageRouter`, and the single public door is
`ShipSystems.apply_hull_damage(amount, source)`. Damage never writes velocity: the
contact response and the physics material stay with `ShipController`, which still does
not know the layer exists. A follow-up added `ShipSystems.hit_component(info)`: the
nearest placed device to the estimated contact point is named in the impact event and
takes a configurable share of the hull's loss.

Stage 4.4 also adds no node: the control surface is methods on `ShipSystems`
(`set_enabled`, `toggle_enabled`, `can_activate`, `equipment_status`) and on
`ShipComponent` (`can_start`, `status`). A device refuses to start on a wrecked hull or
when its own integrity is at the offline line; the reason travels as
`activation_denied`, and a brownout still only changes the derived state, never the crew
switch.

Stage 4.5 adds no node either. It is wiring and guards: the destruction latch cuts the
plant through `ShipEnergySystem.set_bus_online(false)` and makes every device re-derive
its condition, `ShipComponent.power_supply` feeds a generator's integrity-scaled units
back into `output()`, `ShipSystems.report_impact()` refuses to nest, and every amount that
reaches the reserve is checked before it is written. One writer per number still holds:
the supply is read from the device's own integrity, never from its grant, so the bus
cannot chase its own tail.

The shape is worth knowing here because it repeats the project's two standing rules:

* **Dependency injection through the tree, no autoload.** The hub is a child of the
  hull, a device finds it by walking up in `_ready()`, and the flight model does not
  import any of it. Removing the node from `Ship.tscn` leaves a ship that flies exactly
  as it did before stage 4.1 — the layer is additive by construction.
* **One writer per number.** `ShipEnergySystem` is the only place a power grant is
  computed, `ShipHealthSystem` the only writer of integrity, `ShipDamageRouter` the only
  reader of a contact report into the ship's own vocabulary. `ShipController` still owns
  every acceleration and is not touched by any of them.

`ShipComponent` is the extension point: a new onboard device is a node with that script
under `Ship/Systems` and nothing else. Its condition (`NOMINAL` / `DAMAGED` / `OFFLINE`)
is derived from its switch, its integrity and its power grant by one function in
`ShipSystemState`, so no device can declare itself healthy.

## World generation

`scripts/world/world_field.gd` is the heart of the current slice:

* There is no map. Chunks are wanted because they overlap the viewport plus a
  runway ahead of the bow and dropped once they fall behind a wider window.
* Every chunk is rebuilt from a hash of its integer cell coordinates and
  `world_seed` - never from a rolling random stream. That buys four things: a
  region flown out of comes back identical, direction of arrival does not
  matter, frame rate does not matter, and nothing has to be remembered.
* One flag on a population decides its kind: `physics` populations become real
  bodies, everything else becomes flat parallax sprites with no simulation cost.
* A decorative population is background, so its depth is carried by RGB, never by
  alpha: the sprite stays opaque, its tint is graded down by its own `parallax`
  (a farther plane is darker), and a pooled sprite has both colour channels
  rewritten when it is handed a new object.
* What the player changed lives in `ChunkStateStore`, keyed by chunk id and the
  object's stable `cell:slot` id; the generated content is never stored.
* The work per frame is budgeted: unload largest-backlog-first, build
  nearest-first, bounded by `max_chunk_unloads_per_frame`,
  `max_chunk_generations_per_frame`, `build_per_frame` and
  `build_microseconds`.

Pools: `pop.pool_chunks` recycles chunk nodes and the object pool recycles the
bodies, so a long flight does not grow the tree. `bg_system_test` and
`stage3_3_world_chunks_test` assert exactly that.

## Audio

See `audio_requirements.md`. The subsystem is complete and silent: 19 named
streams, 7 buses, a mixer, and no sound files yet.

## Testing

See `testing.md` and `tools/README.md`.
