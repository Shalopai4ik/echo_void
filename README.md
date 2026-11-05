# Echo of Void

A 2D top-down space horror survey. You fly one hull through endless generated
space: asteroid belts, wrecks, ancient structures, a gas giant, and nothing that
tells you what happened here.

* **Engine:** Godot 4.7.2 (`v4.7.2.stable.official.ed1daf0bf`), GDScript,
  GL Compatibility renderer, 960x540 viewport.
* **Status:** in development. The ship flight model, world generation and HUD are
  complete and tested; the internal systems architecture (power, condition, damage,
  equipment) landed in stage 4.1 with its mechanics still to come. Combat, the upgrade
  system and audio content are not.

## Requirements

| | |
| --- | --- |
| Godot | 4.7.2 - the Windows build lives at `C:\Program Files\Progs\Godot_v4.7.2-stable_win64_console.exe`; put it on `PATH` and the tooling finds it |
| Python | 3.11 (verified on 3.11.2), only for the art pipeline |
| Python packages | `pip install -r tools/requirements.txt` |
| Export templates | only if you want to build a standalone copy; the project runs from the editor otherwise |

## Layout

```
echo_void/
  project.godot              engine config, input map, buses
  default_bus_layout.tres    7 audio buses
  export_presets.cfg         Windows Desktop preset
  assets/
    *.png                    ship and effect textures
    ship/                    ShipAssist / Engine / Audio / World parameters (.tres)
    asteroids/               belt sprites
    space_bg/                infinite background: tiles, chunks, sprites/, manifest.json
    world/                   decor + space_generation.tres
    audio/ship/              EMPTY - see docs/audio_requirements.md
  scenes/
    world/SpaceMap.tscn      the current main scene (run/main_scene)
    main.tscn                the legacy slice, still used by tests
    ship/, hud/, obstacles/, world/, test/
  scripts/
    ship/                    ship_controller + engine, camera, assist, boost, brake, audio
    ship/systems/            power, condition, damage and equipment hub (stage 4.1)
    world/                   world_field (chunked endless space), gas giant, generation settings
    space_background/        infinite parallax background
    audio/audio_mixer.gd
    ship.gd, asteroid_field.gd, asteroid*.gd, hud.gd   the legacy slice
  tests/                     21 suites, all runnable headless
  tools/                     the art pipeline, the validator and the test runner
  docs/                      architecture, testing, audio, the cleanup log
  screenshots/               NOT IN GIT - visual suite output from past runs
  test-output/               NOT IN GIT - what a run writes now
```

## Open the project

```powershell
godot --path .            # or open the folder in the editor
```

`run/main_scene` is `res://scenes/world/SpaceMap.tscn`, so that is the scene to
keep open while working on the game. The editor restores whatever scene was open
last, and `scenes/main.tscn` is the legacy slice - if the 2D view does not match
what F5 runs, check the scene tab first.

## Play

`W` / `S` thrust and brake, `A` / `D` yaw, `Q` / `E` strafe, `Shift` boost,
`Space` emergency brake, `R` scan, `F1` debug overlay.

## Run the tests

```powershell
tools\testing\run_tests.ps1                 # the 13 headless suites
tools\testing\run_tests.ps1 -List           # every suite and its kind
tools\testing\run_tests.ps1 -Suite hud_test # one
tools\testing\run_tests.ps1 -Visual         # the 8 that screenshot (needs a GPU)
tools\testing\run_tests.ps1 -Full
```

Logs land in `test-output\logs\`. See `docs/testing.md` for what counts as a
failure and why the exit code alone is not trusted.

One suite directly:

```powershell
godot --headless --path . --script tests/smoke_test.gd
```

## Regenerate art

```powershell
python -m pip install -r tools/requirements.txt

python tools/asset_pipeline/world/make_stage2_decor.py --output <scratch>\world
python tools/asset_pipeline/ship/assemble_ship.py --output <scratch>
python tools/asset_pipeline/background/prep_assets.py --output <scratch>\space_bg
```

Every generator takes `--output`, `--dry-run` and `--force`. Two of the three
reproduce the shipped assets byte for byte - see `tools/README.md` for the exact
numbers and for the four background tiles that deliberately were **not**
regenerated.

## Validate assets

```powershell
python tools/validation/asset_check.py          # exit 1 on a broken category
python tools/validation/asset_check.py --json
```

## Add an asset

1. Drop the file in the right folder under `assets/`.
2. If it belongs to a directory the game enumerates at run time
   (`assets/space_bg/sprites/`, `assets/asteroids/`, `assets/world/`), it is
   picked up automatically - no code change.
3. If it is named by a scene or a script, add the reference and run
   `asset_check.py`.
4. If a generator produced it, the generator must produce it again: run the
   relevant command into a scratch directory and confirm the bytes match.

## Export

```powershell
godot --path . --headless --export-debug "Windows Desktop"
```

Writes `build/echo_of_void.exe`. Nothing under `tools/`, `tests/`, `docs/` or
`test-output/` is exported. You need the Windows export template for 4.7.2
installed; without it Godot reports `export_presets.cfg` has no usable template
and nothing is written.

## CI

`.github/workflows/ci.yml` runs on push and PR: Python syntax, a scan for
machine-bound absolute paths, the asset check, dry-run generators, then the
Godot logic suites. The engine step installs Godot if the runner image has it
and **reports a notice rather than guessing at a version** if it does not.

## Known limitations

* `assets/audio/ship/` is empty: the audio subsystem is complete and silent.
  `docs/audio_requirements.md` lists all 18 streams by name.
* The layer-split ladder cannot be re-run end to end: its 1672x941 source plate
  is not in the repository. The extracted plates are, so `prep_assets.py` still
  works.
* Two implementations of the ship coexist. `docs/architecture.md` explains what
  depends on which and the agreed direction.
* No suite frees its scene before quitting, so the "leaked at exit" reports are
  measured and classified (engine artefacts, not project leaks) but not asserted
  away. `docs/testing.md` has the evidence.
* `move_left/right/up/down` are kept because `smoke_test.gd` asserts them.
