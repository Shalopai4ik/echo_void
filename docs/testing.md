# Testing

Every suite is a GDScript file that extends `SceneTree` and is run headless:

```powershell
godot --headless --path . --script tests/<suite>.gd
```

There are 27 suites under `tests\`: 21 logic suites (headless, safe anywhere) and 6
visual suites (they take screenshots, so they need a real GPU). The `_exp_*`
scratch scripts live under `tests/experiments/`; they are not suites and are not
part of a verdict. `ship_systems_test.gd` is the stage
4.1 architecture suite, `ship_energy_test.gd` the stage 4.2 reserve suite,
`ship_damage_test.gd` the stage 4.3 hull pool suite and `ship_equipment_test.gd` the
stage 4.4 equipment control suite; `docs/ship_systems.md` says what their phases hold.

## One runner

```powershell
tools\testing\run_tests.ps1                 # all logic suites
tools\testing\run_tests.ps1 -List           # what exists, and what kind
tools\testing\run_tests.ps1 -Suite hud_test # one suite
tools\testing\run_tests.ps1 -Visual         # the 6 visual suites
tools\testing\run_tests.ps1 -Full           # both
tools\testing\run_tests.ps1 -Filter '*world*'
tools\testing\run_tests.ps1 -GodotPath <path> -Timeout 900
```

Suites are discovered by reading `tests\`. A new suite needs no edit to the
runner. Screenshots a visual suite writes go to `test-output\`, which is
git-ignored; the per-suite logs go to `test-output\logs\` and a `summary.csv`
lands there too.

### What counts as a failure

The runner never trusts one signal, because each one lies for a different
reason:

* **stdout's `PASS`/`FAIL` lines** are what the suite asserts. This is the
  primary verdict.
* **the `RESULT: ALL PASS` line** catches a suite that printed asserts and then
  died before its summary.
* **a parse error** is read from *stderr*, because a GDScript parse error under
  `--script` makes Godot print
  `ERROR: Failed to load script ... Parse error` and then **hang forever**.
  A runner that watched only stdout would wait 10 minutes and then report a
  green suite. The watchdog turns that into `PARSE ERROR`.
* **the exit code is deliberately not the verdict.** Godot 4.7 returns 1
  whenever it prints "N resources still in use at exit", which every suite in
  this project does - so a runner that trusted the exit code would call an
  entirely green run red. The exit code is only consulted when the suite printed
  no result line at all, which is what a crash looks like.

Exit code of the runner: 0 only when every requested suite passed.

## Known timing sensitivity

One assertion was measuring a value that is painted in `_process` after
waiting on the *physics* tick. On a loaded machine the process tick falls behind
the physics tick, so the value can legitimately not have been drawn yet, and the
assert fails for a ship behaving correctly. It was fixed:

* `stage1_5_audio_test.gd`'s "letting go does not cut the spin" now measures the
  spin loss against the flight model's own `angular_deceleration` over the
  wall-clock time that really elapsed, instead of demanding "75% of the release
  value still turning four frames later" - a 60 Hz assumption.

The assert was not weakened: an instant cut still fails it.

### Still open on a fast headless machine

That fix measures the spin loss against `angular_deceleration * elapsed`, but
`elapsed` is **wall-clock** time while the physics ticks are what took the spin away.
On this workstation the headless tree delivers four `physics_frame` signals in ~0.03 s,
so four fixed 1/60 s steps of simulation are compared against 0.03 s of deceleration
budget, and the assert fails (`1.25 of 1.70 rad/s, lost 0.45 over 0.035 s ... allows
0.16`) while the ship is behaving exactly as designed.

It is **not** caused by the stage 4.1 systems layer: the same suite fails the same
assertion with the `Ship/Systems` node removed from `Ship.tscn` (measured). The honest
fix is to count the simulated time the steps represent - physics frames times
`1.0 / Engine.physics_ticks_per_second` - instead of `Time.get_ticks_usec()`, which
would also make the assertion machine-independent. Left for the test-harness task
rather than changed in an architecture sub-stage.

## Leaks at exit

Some suites still end with messages like

```
WARNING: 109 RIDs of type "CanvasItem" were leaked.
WARNING: 151 ObjectDB instances were leaked at exit
ERROR: 20 resources still in use at exit
```

Most of those are **engine teardown artefacts**: an empty `SceneTree` reports nothing, a
loaded-and-freed scene reports nothing, and with `--verbose` the survivors name themselves
as `CompressedTexture2D` with reference counts 1-10, an `Image` beside each one, and
`CanvasItemMaterial` from the dummy renderer. They are `ResourceCache` entries and
`Texture2D.get_image()` images the engine holds until the process ends; `quit()` skips the
cache flush.

**One class was a real leak.** `space_layer.gd` keeps its chunks and sprites in pools that
are detached with `remove_child()` and recycled. Detached from the tree, they could not be
freed by it, so `stage1_2_engines_test` and `stage3_6_space_balance_test` reported
`Node2D` / `Sprite2D` leaks (and the textures they held). `SpaceLayer._exit_tree()` now
empties both pools; both suites report `leaks: clean`.

The runner still prints leak counters rather than asserting on them, and no suite frees
its scene before quitting. A shared harness that tears the tree down before `quit()` and
asserts a zero project-node count remains the honest fix (see `architecture.md`).
