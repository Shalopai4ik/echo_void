# Architecture

## The ship slice

There is one ship: `scenes/world/SpaceMap.tscn` (the project's `run/main_scene`),
`scripts/ship/ship_controller.gd` (a RigidBody2D whose flight model, camera,
assists, audio and systems all hang off it as children) and
`scripts/world/world_field.gd` (the chunked endless field). `scripts/hud.gd` is
the glass of that hull only: telemetry off the controller, radar contacts off the
field, and objective rows from a node in the `mission` group when one exists.

The old Node2D fighter slice was removed: `scenes/main.tscn`, `scripts/ship.gd`,
`scripts/asteroid_field.gd`, `scripts/asteroid.gd`, `scripts/hull_bank.gdshader`,
`scenes/Asteroid.tscn`, `assets/fighter.png` and its exhaust textures, and the
`tools/asset_pipeline/ship/` generator. The HUD's armour bars went with it - the
current hull has no shield to report, so the bottom-left block is telemetry. The
suites that loaded `main.tscn` (smoke, asteroid, combat and the legacy visual
checks) were removed too; the current hull is covered by `stage1_*`, `ship_*`,
`cruiser_test`, `collision_response_test` and the visual scenes that mount
`TestControlMap.tscn`.

`move_left/right/up/down` stay in `project.godot` because the background review
scene's `scripts/space_background/test_ship.gd` reads them. The game itself does
not bind them.

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

The first device built this way is the survey scanner (stage 5.1, `scanner.md`).
`ShipScanner` is a `ShipComponent`, so it draws from the same reserve, shows the same
condition and answers the same `equipment_status()`; what it added was a device that
*does* something. The one new question it asks is of the world -
`EchoWorldField.objects_near()` - and it asks it by group and by method name rather
than by import, so every ship-only suite still mounts it in a scene with no world.
Nothing in the flight model, the hub, the energy system or the HUD was edited to add
it, which is the claim the extension point was built to support.

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

## Display

The game is authored for a 960x540 canvas and runs with stretch mode
`canvas_items` and aspect `expand`. The scale therefore stays uniform - a ship
is never wider than it is tall - and a window that is not 16:9 gains visible
world on one axis instead of black bars: extra width at 21:9, extra height at
5:4. The HUD follows the same rule: anything that hugs a corner is offset from
`DESIGN_SIZE` in `scripts/hud.gd` rather than pinned to a pixel, so the radar
rides the right edge and the telemetry hangs off the bottom one.

One caveat for tests: the headless display server hands out a 64x64 window,
which `expand` turns into a 960x960 canvas. Suites that measure the authored
frame pin `root.size` to 960x540 themselves.

## Testing

See `testing.md` and `tools/README.md`.
