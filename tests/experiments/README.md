# Experiments, not suites

Four measuring benches used while tuning the ship's collision answer. They print
measurements and never assert, so they report no `RESULT:` line - they are not
tests and the runner must not treat them as ones.

They live in this subdirectory on purpose: `tools/testing/run_tests.ps1`
enumerates `tests/*.gd` without recursing, so a bench here is version
controlled and readable but is not picked up as a suite.

```powershell
godot --headless --path . --script tests/experiments/_exp_bench.gd
godot --headless --path . --script tests/experiments/_exp_bench2.gd
godot --headless --path . --script tests/experiments/_exp_bounce.gd
godot --headless --path . --script tests/experiments/_exp_trace.gd
```

| file | what it measures |
| --- | --- |
| `_exp_bench.gd` | bounce / friction / mass / spin sweep, one fresh ship and rock per sample |
| `_exp_bench2.gd` | the same sweep with a second parameter set |
| `_exp_bounce.gd` | how the answer to a rock changes with the physics material |
| `_exp_trace.gd` | a per-frame trace of one approach for reading the contact itself |

The behaviour they measured is asserted by `tests/collision_response_test.gd`;
these benches are kept for the next tuning pass, not as a safety net.
## Visual playthrough

`_playthrough_shots.gd` drives the real flight scene through the demo's main
beats - sweep, analysis, a forced hunt with the brood, a decoy and a flare,
the manifestation, the pause menu, the upgrades panel, the end screen and the
main menu - and saves a screenshot of each into `test-output/shots/`. It also
prints the notification history, the comms log and the sounds played. It needs
a GPU (no `--headless`):

```powershell
godot --path . --script tests/experiments/_playthrough_shots.gd
```

## Performance probes

Both need a GPU (no `--headless`) and print numbers, no verdict.

| file | what it measures |
| --- | --- |
| `_frame_profile.gd` | 25 s of real flight under thrust and boost: frame-time percentiles and the worst frames. Wall time - noisy on a loaded machine, compare several runs. Pass `-- off=HUD,Background` to switch nodes off. |
| `_fps_bench.gd` | uncapped frame cost (vsync off, GPU at full clock) with and without the HUD - the stable number to compare between changes. |

```powershell
godot --path . --script tests/experiments/_frame_profile.gd
godot --path . --script tests/experiments/_fps_bench.gd
```
