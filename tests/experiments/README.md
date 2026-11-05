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