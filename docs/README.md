# Docs

| file | what it is |
| --- | --- |
| `architecture.md` | the two ship implementations, what depends on which, agreed direction |
| `ship_systems.md` | power / condition / damage / equipment hub (stage 4.1) |
| `space_background.md` | the infinite parallax background: how it works, how to move it, how to test it |
| `audio_requirements.md` | all 18 streams the mixer expects, by event name |
| `testing.md` | what the runner counts as a failure, and why the exit code is not trusted |
| `performance_baseline.md` | measured frame budgets |
| `performance_optimization_log.md` | what was optimised, with numbers |
| `technical_cleanup_log.md` | the running audit trail of the health work |
| `stage3_readiness.md` | stage 3 entry checklist |
| `stage3_4_report.md` | stage 3.4 report (space objects) |
| `stage3_6_report.md` | stage 3.6 report (space balance) |

Design documents are tracked; anything a suite writes goes to `test-output/`,
which is not.

The reports quote log paths such as `test-output/logs/a36/`. Those runs predate
the current tree; their logs were archived outside the repository
(`../_archive/echo_void-artifacts/`), and the runner writes the same layout
under `test-output/logs/` on every run.