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
- `ui/scanner/` — scanner snapshots, radial visualization and screen presenter.
  No scanner, ship or research system is queried by these scripts.
- `ui/hud/hud_visual_data.gd` and `hud_demo_data.tres` — isolated visual-only
  demonstration snapshot for the ship HUD.
- `ui/theme/echo_theme.tres` — single visual source of truth.
- `ui/theme/fonts/technical.tres` — shared technical typography.
- `ui/core/viewport_policy.gd` — minimum window size and safe-area policy.
- `ui/core/window_mode_button.gd` — display-only window/fullscreen toggle.

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
accent color. Stage 7 may provide a controller that maps gameplay snapshots to
this presentation; the screen currently emits only the unconnected
`scan_requested` UI signal.

## Current limitation

The current `scenes/hud/HUD.tscn` is an older, gameplay-connected HUD and is
left untouched. The new `scenes/ui/screens/HUD.tscn` is the unconnected
foundation for the later migration. `ScannerScreen.tscn` is likewise unconnected:
its demo button emits a local request signal but does not call `ShipScanner`.
