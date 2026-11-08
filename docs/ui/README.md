# Echo of Void — UI architecture

## Scope

This directory contains the UI foundation only. It does not read ship, scanner,
research, equipment or upgrade state, and it does not change the gameplay scene.

## Structure

- `scenes/ui/core/InterfaceShell.tscn` — shared composition root. `HUDLayer`,
  `ScreenLayer`, `ModalLayer` and `DebugLayer` are independent full-rect layers.
- `scenes/ui/components/` — small reusable scenes: technical panel, row,
  module slot, telemetry bar, resource gauge, ship status panel and notification feed.
- `scenes/ui/screens/` — independent screens: HUD, scanner, research, equipment,
  upgrades, main menu and pause menu.
- `scenes/ui/screens/ScannerScreen.tscn` — presentation-only scanner interface.
  `ScannerPreview.tscn` is its isolated review scene; neither is connected to
  gameplay.
- `scenes/ui/components/ScannerMarker.tscn` and `ScannerContactCard.tscn` —
  reusable radar marker and contact row components.
- `scenes/ui/components/UpgradeDeviceCard.tscn`, `UpgradePathRow.tscn` and
  `ResearchXpBadge.tscn` — the device row, the upgrade path row and the compact
  research XP readout used by the upgrades panel and the HUD.
- `ui/upgrades/` — upgrade snapshots (`UpgradeVisual`, `UpgradeDevice`), the
  shared display table (`upgrades_presentation.gd`), the demonstration catalogue,
  the card/row/badge presenters and the panel presenter. The presenter scripts
  query no device, research desk or manager. `upgrades_snapshot.gd` and
  `upgrades_console.gd` are the only two files here that read gameplay state; the
  console is the single place that calls `ResearchUpgradeManager.purchase()`.
- `ui/scanner/` — scanner snapshots, radial visualization and screen presenter.
  No scanner, ship or research system is queried by these scripts.
- `ui/hud/hud_visual_data.gd` and `hud_demo_data.tres` — isolated visual-only
  demonstration snapshot for the ship HUD.
- `scenes/hud/HUD.tscn` + `scripts/hud.gd` — the flight HUD that ships. It draws
  its own telemetry, mission rows, ability slots and radar, and carries the flight
  `ResearchXpBadge` in the top-right corner. Any open modal panel joins the
  `ui_modal` group; the HUD asks that group before it answers a control key.
- `ui/theme/echo_theme.tres` — single visual source of truth.
- `ui/theme/fonts/technical.tres` — shared technical typography.
- `ui/core/viewport_policy.gd` — minimum window size and safe-area policy.
- `ui/core/interface_screen.gd` — the modal base of every in-flight panel: it
  joins the `ui_modal` group, holds the world (the physics server off, the hull
  and the field stopped), closes the other panels and closes itself on `Esc`.
- `ui/core/interface_console.gd` — the base of every console: it owns the key
  that opens the panel, joins the `interface_panel` group and carries a
  `panel_id`, so one panel can hand the pilot to another without knowing its
  class.
- `ui/equipment/`, `ui/scanner/`, `ui/research/`, `ui/menu/` — the stage 7
  layer: a card or a screen per panel, a snapshot builder that reads gameplay
  state, and a console that turns a button into a call on the real system.
  `scripts/ship/systems/equipment_slots.gd` is the one registry of the four
  slots: number, device, key.

## Visual rules

- Background: near-black blue (`#020810` family).
- Surfaces: translucent navy with one-pixel blue borders.
- Primary accent: muted cyan; bright cyan is reserved for active/focus state.
- Text: light cyan-white for values, desaturated cyan for secondary data.
- Corners are almost square (2 px). Panels are flat and minimal.
- Do not add decorative ornament that competes with the world or telemetry.

## Responsive rules

The project uses `canvas_items` stretch with `expand`. The logical canvas grows
on the longer axis, so no black bars are introduced. UI screens use anchored
full-rect roots and containers; long lists use `ScrollContainer`. Fixed minimum
sizes are reserved for controls and never for a whole screen. The real window
minimum is 640x360. The compact safe inset is 8 px below 720 logical pixels;
otherwise it is 16 px.

## Extension contract

Add data-driven content to the appropriate screen scene. Do not put game-state
reads in theme, components or layout scripts. A future controller may instance
screens into the matching shell layer and provide a model later; controllers
must not be coupled to the internal node structure of reusable components.

## Scanner presentation

The scanner screen supports six local demonstration presentations: ready,
scanning, contacts found, no contacts, insufficient energy and malfunction.
The contact registry uses a scroll container, and the radial scope distinguishes
asteroids, debris, beacons, unknown signals and anomalies by marker shape and
accent color. Since stage 7 the screen also has a live mode: `ScannerConsole`
builds a `ScannerSnapshot` out of the mounted `ShipScanner`, the research desk's
own progress and the hull's own reserve, and the screen shows that picture
instead of the demonstration table. The screen's `scan_requested` signal is
answered by the console with the scanner's own `start_scan()`, and the refusal
comes back in the pilot's own words. The demonstration table is still used by
the isolated `ScannerPreview.tscn`, where there is no ship to read.

## Upgrades panel

`scenes/ui/screens/UpgradesScreen.tscn` is the equipment upgrade panel;
`UpgradesPreview.tscn` is its isolated review scene. It lists one card per
mounted device (`UpgradesConsole` skips a device the hull does not carry), and
the detail panel shows the selected device's current characteristics and one row
per upgrade path: level, current value, value after the next level, XP price and
an availability word (`ДОСТУПНО` / `НЕДОСТАТОЧНО XP` / `МАКСИМУМ`).

- `U` toggles the panel, `Escape` closes it. Both keys belong to the panel, not
  to the flight model.
- While it is open the panel owns the input: it joins the `ui_modal` group (the
  flight HUD asks that group before answering `R`) and `UpgradesConsole` calls
  `ShipController.set_interface_input_locked(true)`, so a held throttle cannot
  burn behind the screen. The lock is separate from `movement_enabled`: the hull
  is not switched off, it simply has no hands on the levers.
- `РЕЖИМ: ОКНО / РЕЖИМ: ПОЛНЫЙ ЭКРАН` in the header is the shared
  `UiWindowModeButton`, the only way to reach fullscreen in flight.
- The Research XP badge shows the running total, pulses with `+delta` on a gain
  and flashes `−delta` on a purchase. The same component sits top-right on
  `HUD.tscn`, fed by the research desk through `scripts/hud.gd`.
- In flight, `UpgradesConsole` builds the snapshot from `ResearchUpgradeManager`
  and the devices' live values, and turns `upgrade_requested` into a single
  `purchase()`. The manager's own signals drive every refresh, so XP, levels,
  values, prices and the button state cannot disagree with the ship.
- The Research XP badge shows the running total, pulses with `+delta` on a gain
  and flashes `−delta` on a purchase. The same component sits top-right on
  `HUD.tscn`.
- `ДЕМО: +150 XP` exists only in the isolated preview: it awards demonstration
  XP and buys nothing. The flight console hides it (`load_demo_data = false`).
- Refusals (`insufficient_xp`, `max_level`, `device_not_found`,
  `wrong_device_type`, `no_research_system`) appear in the footer for 1.6 s;
  the row and the action button pulse after a successful level.

## Current limitation

`scenes/hud/HUD.tscn` is the HUD that ships: it draws the telemetry, the mission
rows, the ability slots and the radar itself, and carries the flight Research XP
badge. `scenes/ui/screens/HUD.tscn` is the unconnected foundation for the later
migration.

Since stage 7 every screen of the flight scene is connected to the ship:
`EquipmentConsole`, `ScannerConsole`, `ResearchConsole`, `UpgradesConsole`,
`PauseMenuConsole` and `MainMenuConsole` are instanced in `SpaceMap.tscn`, each
one finds its system through the tree and feeds its screen a live snapshot.

Two limits remain, and both are deliberate:

* **A panel holds the world.** While a panel is open the physics server is off
  and the hull and the field of stones stop processing, so nothing moves,
  nothing burns energy and no XP appears. A sweep or an analysis therefore
  only advances after the panel is closed. The reason and the measurements are
  in `docs/stage7_report.md` (the naive `SceneTree.paused` route breaks Godot
  4.7's 2D physics server on this scene).
* **The main menu does not open by itself.** It opens from the pause menu
  ("ЗАВЕРШИТЬ ИССЛЕДОВАНИЯ"), because opening it at start-up would change the
  order in which the flight begins.

The signal light's upgrade paths are live in the catalogue but the device is not
mounted in `SpaceMap.tscn` yet, so the flight panel lists the scanner, the
research desk and the decoy launcher; the fourth slot is empty and says so.
