# Technical cleanup log

Project: `echo_void` (Echo of Void). Branch: `tech-health`.
This file records what each stage found, changed, tested and what is still open.
It is the running audit trail of the health work, not a design document.

---

## Stage 0 - preliminary verification and project protection

### Environment found

| Item | Actual value |
| --- | --- |
| Repository root | `D:\programming\ideas\echo_void` (`echo_void/.git`) |
| Working tree at start | branch `master`, commit `7812174` |
| Godot | `C:\Program Files\Progs\Godot_v4.7.2-stable_win64_console.exe` (also `Godot_v4.7.2-stable_win64.exe`), engine reports `v4.7.2.stable.official.ed1daf0bf` |
| Python | `Python 3.11.2` |
| Git | `git version 2.46.1.windows.1` |
| Godot on PATH | **no** - the engine is not reachable through `PATH` |
| Tracked files | 749 (assets 388, screenshots 233, scripts 74, tests 34, scenes 12, tools 2, plus root files and `docs/`) |
| Modified tracked files | 40 |
| Untracked files/dirs | 42 |

### Actions taken

* Created branch `tech-health` off `master`. No `git reset --hard`,
  no `git clean -fd`, no forced checkout, no mass delete. Nothing was
  committed: the user's uncommitted edits stay uncommitted and untouched in
  the working tree.

### Baseline test run (before any change)

Runner used: the repo's own `tools/_run_suites.ps1` equivalent, over the 11
suites that script names.

```
cruiser_test             exit 0
stage1_control_test      exit 0
stage1_2_engines_test    exit 1   <-- ONE FAILURE
stage1_3_assists_test    exit 0
stage1_4_states_test     exit 0
stage1_5_audio_test      exit 0
stage2_world_test        exit 0
smoke_test               exit 0
hud_test                 exit 0
combat_test              exit 0
asteroid_test            exit 0
```

Totals over those 11 suites: **900 PASS / 1 FAIL**.

The two suites the runner never calls were run by hand:

* `bg_system_test` - `RESULT: ALL PASS` (27 asserts).
* `stage3_3_world_chunks_test` - `RESULT: ALL PASS` (72 asserts).

So the honest baseline across all 13 suites present is **999 PASS / 1 FAIL**.
The audited figure of 917 PASS / 0 FAIL is not the current state.

### The failure, and why it is not a test fault

```
FAIL  the main nozzle is lit and stretched to the power
      shown=1.00 plume scale=(1.0, 2.0)
```

`tests/stage1_2_engines_test.gd` still asserts the old engine picture:
`jet.plume.scale.x > 1.5`. The **uncommitted, user-authored** change to
`scripts/ship/engine_jet.gd` deliberately replaced the old `2.0 * length`
stretch with `LENGTH_SCALE := 1.0`, with a comment stating the trail texture is
already authored at its full world length and that the old 2x dragged the nozzle
pivot 468 px down a 234 px taper.

The prose of the assertion ("lit and stretched to the power") is still the
contract; only the magic number `1.5` (a proxy for the removed 2x) is not. The
assert was rewritten to compare the full-power plume against a **half-authority**
plume captured in the same test, and to cap it at the authored length
(`EngineJet.LENGTH_SCALE * 1.35`), which is the real invariant: the flame's
length tracks the power and never runs past the art it was drawn from.

Result after the change: `RESULT: ALL PASS` for `stage1_2_engines_test`,
with no `FAIL` line, confirmed by a full run of the suite.

### Other findings that later stages must answer

* No root `.gitignore` in the project is detailed enough (see Stage 3). The
  one present covers `.godot/`, `/android/`, `/build/`, `export_presets.cfg`,
  `*.translation`, `.DS_Store`, `Thumbs.db`, `*.tmp` only.
* 233 tracked PNG screenshots, ~14 MB, are tracked in Git. `screenshots/`
  holds 248 files and ~16.6 MB on disk.
* The 36 Python art tools live **outside** the repository in
  `D:\programming\ideas\tools` (275 files, ~78 MB). They are not versioned, so
  none of the 205 game textures has a reproducible generator under Git.
* 15 Python files carry hard-coded absolute paths:
  `C:\Users\HP-1282\Downloads\...` (14 files) and
  `D:\programming\ideas\...` (2 files).
* `D:\programming\ideas\EchoOfVoid_Background_Layers.zip` (4.6 MB) sits in the
  parent directory and duplicates the extracted
  `tools/layer_split/EchoOfVoid_Background_Layers/` tree that `make_zip.py`
  itself produces. It is a generated artefact, not a source.
* `project.godot` has no `[autoload]` section.
* No `export_presets.cfg` exists, and no CI exists.
* `docs/` contains a single stale file, `stage3_readiness.md`.

### Known limitation found while testing

A GDScript **parse error** under `--script` does not make Godot exit: the engine
prints `ERROR: Failed to load script ... Parse error` and then hangs until the
process is killed. Any test runner must therefore (a) treat a hang as a
timeout failure and (b) capture stderr, not just stdout, so a broken script is
never reported as a pass. Stage 6's runner does both.

---

## Stage 1-2 - Python asset pipeline under version control, and portable

### Was the audit right?

Partly. The 36 Python scripts really did live outside the repository
(275 files, ~78 MB) and were not versioned. `layer_split` held 15 of them, the
parent folder 21, and 14 of the 15 carried
`C:\Users\HP-1282\Downloads\fa75602c-c11e-43ed-bb58-2342f75b8264.png` verbatim.

What the audit did not say: that plate **is no longer on this machine** - the
Downloads folder now holds only a Godot zip. So the ladder cannot be re-run end
to end, and `masks.npz` (22.7 MB) is now the only surviving record of the split.
That changed the priority: `masks.npz` had to be kept, and the ladder needed a
`--source` flag with a clear error when the plate is absent.

### What was built

```
tools/
  requirements.txt            numpy 1.26.4, Pillow 10.2.0,
                              opencv-python 4.9.0, scipy 1.13.0
  asset_pipeline/
    shared/pipeline_common.py paths, logging, argparse, error handling
    ship/smooth_ship.py sculpt_ship.py assemble_ship.py trace_ship.py ship_style.py
    ship/canvases/             the hand-drawn art, moved into Git
    asteroids/extract_asteroids.py
    background/seamless_tile.py prep_assets.py find_seam.py
    background/layers/         the extracted plates, moved into Git
    background/layer_split/    the 11-file ladder + masks.npz
    world/make_stage2_decor.py
    manifests/                 layers, seg, asteroids_report, world_art_report
  validation/asset_check.py dump_map.py
  testing/run_tests.ps1
  scratch/                    NOT IN GIT: 74 one-off scripts, renders, logs
```

`shared/pipeline_common.py` is the single home of the infrastructure instead of a
copy in each of 25 scripts: `PROJECT_ROOT` found by walking up from `__file__`
to the directory named `tools`, `require_file` / `require_dir` /
`resolve_output` / `prepare_dir`, a `Log` class, `add_common` for argparse flags,
`load_rgba` / `save_rgba` that fail loudly on a bad file, and `run()` which turns
a `PipelineError` into exit code 2.

Every generation tool now has argparse with `--input`, `--output`, `--config`,
`--verbose`, `--dry-run`, `--force`; checks its inputs before writing anything;
refuses to clobber a non-empty destination without `--force`; writes nothing
under `--dry-run`.

### Reproducibility, measured

| Generator | Result |
| --- | --- |
| `make_stage2_decor.py` | **9 of 9 byte-identical** to `assets/world/` |
| `assemble_ship.py` | **4 of 4 byte-identical** (`fighter`, `engine_plume`, `engine_core`, `engine_glow`) |
| `prep_assets.py` | **153 of 157 byte-identical** to `assets/space_bg/` |
| `layer_split/*.py` | dry-run clean on all 11; cannot regenerate (plate absent) |

### The four that do not match - and why they were left alone

`nebula_tile.png`, `stars_far_tile.png` (and, at pixel level only, the two other
tiles, which differ by one 8-bit level from Pillow's `optimize`) differ because
the shipped ones were cut by an **earlier** `seamless_tile.py`. The current tool
closes the wrap better:

| file | shipped wrap step | regenerated |
| --- | --- | --- |
| `nebula_tile.png` | 0.068 levels | 0.035 |
| `stars_far_tile.png` | 0.059 | 0.000 |

Regenerating would therefore change how the game looks - for the better, but that
is an art decision and not a cleanup. **The shipped assets were deliberately left
untouched** and the divergence is documented in `tools/README.md`.

### No absolute paths remain

A scan over every `.py` under `tools/` for `C:\Users\`, `D:\programming` and
`HP-1282` returns nothing. CI enforces the same scan.

---

## Stage 3 - Git and repository hygiene

* `git rm -r --cached screenshots/` removed **233 tracked PNG screenshots
  (~14 MB)** from the index. The files are still on disk; nothing was deleted.
* That was safe because they are **test output, not baselines**: no test loads
  one, every visual suite only ever writes to `const OUT := "res://screenshots/..."`
  and there is no comparison step anywhere in `tests/`.
* All 8 visual suites were retargeted to `res://test-output/`, which
  `.gitignore` now covers.
* `.gitignore` rewritten to cover Python caches and virtualenvs, `.npy`/`.npz`
  (with one documented negation for `masks.npz`), the ladder's `_debug/`,
  `layers-source/`, the ship tools' diagnostics, `test-output/`,
  `tools/scratch/`, and logs. It does **not** blanket-ignore `*.png` or `*.zip`.
* `.gitattributes` now also marks `*.uid`, `*.npz`, `*.wav`, `*.ogg` binary.
* `EchoOfVoid_Background_Layers.zip` in the parent directory is an artefact
  `make_zip.py` produces from the extracted tree that now lives in
  `tools/asset_pipeline/background/layers/`. The extracted copy is the tracked
  one; the archive is not needed and was left where the user put it.

---

## Stage 4 - the two ship slices

Analysed, not deleted. The full record is in `docs/architecture.md`.

* Both slices are in production. `run/main_scene` points at
  `scenes/world/SpaceMap.tscn`; `scenes/main.tscn` is not the main scene but is
  still loaded by 7 suites (`smoke_test`, `asteroid_test`, `combat_test`,
  `main_flight_screens`, `screenshot`, `ship_anim_screens`,
  `stage1_flight_screens`) and carries 19 legacy HUD assertions.
* Decision: **the current slice grows, the legacy stays as the regression
  fixture**, and the HUD gets a small two-method protocol both hulls answer
  instead of poking at each other's internals. That protocol is the follow-up
  task; it was not implemented here because it changes a scene seven passing
  suites depend on.

---

## Stage 5-6 - one test runner

`tests/framework/` was **not** built. 21 suites each implement their own harness,
which is duplication, but every one of those harnesses is exercised by ~49
asserts on average and all 21 pass. Replacing 21 working harnesses in one pass,
with no way to bisect a regression to a suite, is the mass rewrite the brief
forbids. The runner makes the shared parts real and useful instead.

`tools/testing/run_tests.ps1`:

* discovers suites by reading `tests/` - a new suite needs no edit here;
* splits them into logic (13) and visual (8), and can run either, both, one, or a
  filtered set;
* has no absolute Godot path. `-GodotPath` overrides; otherwise it looks for the
  engine on `PATH` and the two known install paths, reads `--version`, and
  **refuses a different major.minor** than the 4.7 line this project targets;
* a per-suite watchdog (`-Timeout`, default 600 s: `stage2_world_test` and
  `stage1_control_test` genuinely take three and a half minutes each, which is
  slow, not hung);
* captures **stderr** as well as stdout, because a GDScript parse error prints to
  stderr and then hangs;
* a log per suite plus a `summary.csv`;
* exits non-zero if any suite failed, timed out, or failed to parse.

### Two runner bugs found and fixed while building it

1. `@('--script', 'tests/') + $name + '.gd'` - PowerShell's `+` on an array is
   *array concatenation*, so Godot got `--script tests/` and failed with
   `ERROR: Resource file not found: res://tests`. The path is built into a scalar
   first.
2. `[switch]$Visual` collided with `$visual = @(...)`: PowerShell variables are
   case-insensitive, so the array overwrote the parameter and every invocation
   died with "Cannot convert value System.Object[] to type SwitchParameter".

### The exit code is not the verdict

Godot 4.7 returns **1** whenever it prints "N resources still in use at exit",
which every suite in this project does. A runner that trusted the exit code
would call an entirely green run red. The verdict is the suite's own `PASS` /
`FAIL` lines plus its `RESULT` line; the exit code is only consulted when the
suite printed no result at all, which is what a crash looks like.

---

## Stage 7 - the leak messages

Every suite ends with e.g. `WARNING: 109 RIDs of type "CanvasItem" were leaked`
and `WARNING: 151 ObjectDB instances were leaked at exit`.

Three controlled experiments classify them:

1. An empty `SceneTree` script that loads nothing reports **nothing**.
2. A script that loads `res://scenes/main.tscn`, runs one frame, frees it and
   exits reports **nothing**.
3. A script that runs the whole `smoke_test`, then frees the scene from
   **outside its coroutine** (314 nodes freed, `root.get_child_count()` back to
   0) **still reports ~144 ObjectDB instances**.

With `--verbose` the survivors name themselves: `CompressedTexture2D` with
reference counts 1-10, an `Image` beside each one, and `CanvasItemMaterial` from
the dummy renderer. So they are ResourceCache entries and `Texture2D.get_image()`
images the engine holds until the process ends - `quit()` skips the cache flush.

**They are not project node or RID leaks**, and the pools are provably not
leaking: when the owning node is freed the node count returns to zero, and
`bg_system_test` / `stage3_3_world_chunks_test` assert "nodes are recycled, not
leaked" and "chunk nodes and the chunk count agree" directly.

Freeing from *inside* the coroutine does not help either - a coroutine keeps its
locals alive, so the scene stays referenced by the test's own frame. Evidence and
the remaining work are in `docs/testing.md`.

**Correction (stage 4.3 follow-up).** "The pools are provably not leaking" held for
`world_field.gd` but not for `space_layer.gd`: its chunks and sprites are detached from
the tree on purpose, so the tree could not free them and `stage1_2_engines_test` /
`stage3_6_space_balance_test` reported real `Node2D`/`Sprite2D` leaks. `SpaceLayer`
now frees both pools in `_exit_tree()`; both suites report `leaks: clean`.

---

## Stage 8 - asset validation

`tools/validation/asset_check.py` checks the fixed named references (both scenes,
the bus layout, the four `.tres` parameter resources, `project.godot`), the
directories the game enumerates at run time (`space_bg/sprites`, `space_bg`,
`asteroids`, `world`, `ship`) for existence and non-emptiness, that the sprites
the icon and the ship scene point at decode, that `sprites/manifest.json` parses
and every file it lists is present (all 143 are), and the audio gap. Exit 1 on
any failure.

It deliberately does **not** turn the 205 assets into 205 hand-written strings: a
directory meant to hold "whatever PNGs are here" is checked as a directory.

Current result: **17 ok, 0 failed, 1 warning** - the warning is
`audio ship events: no sound files`.

---

## Stage 9 - audio

No files were invented. The subsystem was read and documented against the code,
not against the audit's summary: `ship_audio.gd` defines **18 named streams** (5
continuous layers + 13 one-shots over a fixed pool of 8 voices), not the 19 the
audit claimed. Every constant name is now in `docs/audio_requirements.md` with
the exact lookup rule (`res://assets/audio/ship/<key>.{ogg,wav,mp3}`), the
intended bus routing, and what to verify when the files land.

The code already handles absence: `missing_streams()`, `report()` and
`total_streams()` exist for it, and a missing file resolves to null without an
error. `asset_check.py` reports the gap as a warning pointing at that document.

---

## Stage 10 - autoloads

No `[autoload]` was added, deliberately; the reasoning is in
`docs/architecture.md`. `project.godot` has none today and nothing in the running
tree looks for a singleton by name: `ShipController` owns its subsystems as
children and `world_field.gd` preloads `CHUNK`, `SHAPES` and `HASH` directly.
That is dependency injection through the tree, it is why the headless suites need
no bootstrapping, and an autoload for `AudioMixer` or a config manager would make
every suite depend on a global existing first while buying nothing a child node
does not already give.

---

## Stage 11-12 - magic numbers and dead code

**Not done, and reported rather than faked.** The audit counted ~440 raw
literals; they were not re-counted here. Extracting them is the change most
likely to move the ship's balance by accident, and the brief's first rule is that
the game must not change - so it needs its own pass with the flight model's tests
as the gate, not a cleanup stage.

Dead code was investigated and mostly **kept, with reasons recorded**:

* `move_left/right/up/down` - bound only by the legacy hull and asserted by
  `smoke_test.gd` (`action bound: move_left`, 2 events each). Removing them
  breaks a passing suite for no gain.
* `scripts/space_background/test_ship.gd`, `scenes/space_bg_test.tscn` - the
  legacy debug scene, used by `bg_screens.gd` and `bg_debug.gd`.
* `scripts/world/world_chunk.gd`, `chunk_state_store.gd` - untracked, new, and
  already used: `world_field.gd` preloads both and
  `stage3_3_world_chunks_test.gd` (106 asserts) exercises them.
* `scripts/world/world_objects.gd`, `scripts/ship/flight_order.gd` - left in
  place. Neither is referenced by a scene, a test or a `class_name` consumer
  found in this pass, but deleting an unused file is easy to do wrong.

---

## Stage 13-15 - export, CI, docs

* `export_presets.cfg` for Windows Desktop, hand-written so it holds no local
  paths; excludes `test-output/`, `tools/`, `docs/` as a safety net. **The build
  itself was not produced**: this machine has no 4.7.2 export template, so
  `--export-debug` cannot run. That is a documented limitation, not a claim.
* `.github/workflows/ci.yml`: Python syntax, an absolute-path scan, the asset
  check, dry-run generators, then the Godot logic suites with logs uploaded. The
  engine step looks for a usable Godot and, if the runner image has none, prints
  a notice and exits 0 - it never fakes green on the checks that did run.
* `.editorconfig`: LF everywhere, tabs for GDScript, 4 spaces for Python.
* `README.md`, `docs/architecture.md`, `docs/testing.md`,
  `docs/audio_requirements.md`.

---

## Stage 16 - final verification

| Check | Result |
| --- | --- |
| Baseline, 11 suites, old runner | 900 PASS / 1 FAIL |
| Baseline, all 13 suites by hand | 999 PASS / 1 FAIL |
| Final, 13 logic suites, new runner | **1030 PASS / 1 FAIL** |
| `tools/validation/asset_check.py` | 17 ok, 0 failed, 1 warning |
| `assemble_ship.py` | 4 of 4 byte-identical |
| `make_stage2_decor.py` | 9 of 9 byte-identical |
| `prep_assets.py` | 153 of 157 byte-identical |
| Absolute paths in `tools/**/*.py` | none |
| Every `tools/**.py` compiles | yes |
| `SpaceMap.tscn` headless, 200 frames | no error on stdout or stderr |
| `main.tscn` headless, 200 frames | no error on stdout or stderr |
| Standalone export build | not produced - no export template locally |

### The remaining failure, and the two flakes it exposed

`combat_test`'s "it drains instead of snapping" measured the HUD's shield bar
two **physics** frames after a hit. The bar is painted in `_process`, and on a
loaded machine the process tick falls behind the physics tick, so the bar can
legitimately not have been drawn yet - the suite failed for a ship behaving
correctly. Fixed by adding `_frames(n)` (process frames) alongside `_steps(n)`
(physics frames) and using `_frames` for every HUD reading, with a note on
`_steps` explaining why.

The same class of flake existed in `stage1_5_audio_test`'s "letting go does not
cut the spin", which demanded "75% of the release value still turning four frames
later" - a 60 Hz assumption; it now measures the loss against the flight model's
own `angular_deceleration` over the wall-clock time that really elapsed.

Both asserts still catch what they were written for: a bar that snaps, and a spin
that is cut. `stage1_5_audio_test` passes 105/105 after the fix.

### Git

* Branch `tech-health` created off `master`.
* Nothing committed. The user's 40 modified files and 42 untracked paths are
  untouched in the working tree; the cleanup's work sits beside them uncommitted
  so it can be reviewed separately.

---

## Stage 17 - repository organisation pass

Second audit pass, run on branch `tech-health` at `d5eba6d` with a clean working
tree (984 tracked files). Goal: the tree should hold only what runs, tests,
regenerates and documents the game; nothing was renamed inside the game itself.

### Outside the repository

`D:\programming\ideas` held the first generation of the art pipeline beside the
project. All of it moved to `D:\programming\ideas\_archive\` unchanged - nothing
deleted, nothing read by the game:

| moved | size | why it is only an archive |
| --- | --- | --- |
| `tools/` (411 files) | 78.1 MB | superseded by `echo_void/tools/`; its `layer_split/masks.npz` is MD5-identical to the copy kept in the repository (`B88567DB…`) |
| `files/aee34b98-…png` | 1.1 MB | the ship reference sheet; the same sheet is `tools/scratch/_ship_sheet_source.png` |
| `_seammark_ref_h.png`, `_seammark_ref_v.png` | 0.04 MB | seam references for `find_seam.py`, which now lives in the repository |
| `EchoOfVoid_Background_Layers.zip` | 4.4 MB | intermediate output of the layer-split ladder, not project input |

`ideas/README.md` lists what the archive contains and states it can be deleted.

### Inside the repository

| change | detail |
| --- | --- |
| `tests/_exp_*.gd` (4 benches + `.uid`) → `tests/experiments/` | `git mv`. They print measurements and never assert, so the runner called them suites and counted them as CRASH/PASS on silence. The runner enumerates `tests/*.gd` without recursing, so suites found drops from 35 to 31 (22 logic, 9 visual) with no test lost. `tests/experiments/README.md` documents them and how to run each by hand |
| `README-space-background.md` → `docs/space_background.md` | 31 KB system doc that had no reference from anywhere; its three `screenshots/…` paths now say `test-output/…` |
| `screenshots/` → archive | 248 PNG, 15.9 MB, output of runs from before the visual suites were retargeted. No suite reads it |
| `test-output/` → archive | 203 files, 11.9 MB of old logs, plus the `summary.csv.import` and `*.translation` files Godot had generated beside them |
| `test-output/.gdignore` (force-added) | the folder is inside `res://`, so Godot imported every screenshot a run wrote. After the flag: 60 files written by `bg_screens`, 0 `.import` side-cars. A fresh clone has the flag because it is force-added past the ignore rule |
| `tools/asset_pipeline/.gdignore` | same reason: 162 pipeline PNGs are Python input, never game resources |
| 163 tracked `*.png.import` under `tools/` removed | editor metadata for those pipeline PNGs. `--import` after the change regenerated none of them, which is the check that `.gdignore` is in force. `tools/author_world_settings.gd` is outside the ignored folder and still runs |
| `tools/scratch/*.import` removed, `__pycache__/` removed | generated, gitignored |
| `docs/README.md` | index of the eleven docs |
| `README.md` | layout and counts corrected (they said 21/13/8 suites; the tree had 35/26/9) |
| `tools/README.md`, `.gitignore` | record the two `.gdignore` flags and why the side-cars are gone |

### Verification

| check | result |
| --- | --- |
| `project.godot` | unchanged (`git status` reports no edit); `run/main_scene` still `res://scenes/world/SpaceMap.tscn` |
| `godot --headless --path . --import` | exit 0, no error on stdout or stderr |
| `SpaceMap.tscn`, 300 frames headless | exit 0, no output |
| `main.tscn` (legacy slice), 200 frames headless | exit 0, no output |
| `res://` references in scenes, scripts, tools, tests | 82 distinct, 7 unresolved - all 7 are `test-output/…` output folders the visual suites create themselves |
| `tools/validation/asset_check.py` | 17 ok, 0 failed, 1 warning (audio still empty) |
| `assemble_ship.py --dry-run`, `make_stage2_decor.py --dry-run`, `prep_assets.py --dry-run` | all three plan their output, write nothing |
| logic suites (`run_tests.ps1`) | 22 suites, 21 PASS, 0 TIMEOUT, 0 PARSE ERROR, 1512 asserts |
| `stage2_world_test` re-run alone | `RESULT: ALL PASS`, worst generating frame 2130 µs of a 6000 µs budget |
| visual suites (`run_tests.ps1 -Visual`) | 9 suites, 3 PASS, 133 asserts |

### What the two runs exposed (none of it caused by this pass)

* `stage2_world_test` failed its frame-budget assert once, at 7257 µs against a
  6000 µs budget, while the whole suite set ran. Alone, on an idle machine, the
  same assert measures 2130 µs. The budget is measured, not mocked, so the suite
  is load-sensitive; it is not a regression and the assert was not touched.
* `stage1_flight_screens` fails 12-13 asserts about hull readability and brake
  station lighting. A pristine `git worktree` at `d5eba6d`, with none of this
  pass applied, fails the same assertions, so the suite was already red.
* The runner calls the five image-only visual suites (`bg_debug`, `bg_screens`,
  `screenshot`, `stage3_3_chunk_screens`, `stage3_4_space_screens`) CRASH: they
  print `saved …` and no `RESULT:` line, and "no result line and no asserts" is
  a crash by the runner's own rule. `bg_screens` writes the same seven frames
  with the same means as the archived pre-pass run.
* `collision_response_test` asserts nothing and ends with a literal
  `RESULT: ALL PASS`, so the runner reports 0 asserts / PASS. It is a bench that
  was named as a test - worth either turning into one or moving next to
  `tests/experiments/`, which is the owner's call.

### Git

Nothing committed. The pass is staged so `git diff --cached` shows it whole: 9
renames, 4 additions, 3 modified files, 163 deletions (all `.import`).

---

## Unresolved

1. No standalone export build - no 4.7.2 export template installed locally.
2. `tests/framework/` still does not exist; 21 harnesses still duplicate their
   plumbing. The runner removed the operational cost, not the code cost.
3. The HUD still distinguishes the two hulls by poking at implementation
   internals; the agreed protocol is documented but not implemented.
4. Magic numbers are not extracted.
5. Visual suites are not in CI and were not run here: they need a real GPU, and
   `--headless` uses a dummy renderer with nothing to screenshot.
6. The 4 divergent `space_bg` tiles are intentionally not regenerated.
7. No suite frees its scene before quitting, so the at-exit leak reports are
   classified (engine artefacts) but not asserted away.

