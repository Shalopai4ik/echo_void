# Tools

Every tool that generates, validates or tests an Echo of Void asset lives in
here, under version control. Before this cleanup they lived outside the
repository in `D:\programming\ideas\tools`, which meant no shipped texture had a
generator the project could run again.

```
tools/
  requirements.txt          python dependencies of the pipeline
  asset_pipeline/
    shared/pipeline_common.py   the one place paths, logging and CLI live
    ship/                     the fighter's canvases and the assembler
      canvases/               the hand-drawn art the ship textures are cut from
    asteroids/                the belt sprite cutter
    background/
      layers/                 the cut plates: ships as the game's space_bg input
      layer_split/            the ladder that cut them (needs the source plate)
    world/                    the decor painter (wrecks, structures, beacons)
    manifests/                JSON side-cars the generators read and write
  validation/
    asset_check.py            asset categories the game needs are present
    dump_map.py               print a canvas as text so it can be read in CI
  testing/
    run_tests.ps1             one runner for every test suite
  scratch/                    NOT IN GIT: one-off scripts, renders and logs
```

## Install

```powershell
python -m pip install -r tools/requirements.txt
```

Pinned versions are the ones this pipeline was verified with on Python 3.11.

## Regenerate the shipped assets

Every command takes `--output`. Point it at a scratch directory, run it, diff
it against `assets/`, and only then copy over `res://` - nothing overwrites the
shipped art on its own.

```powershell
# world decor: byte-identical, 9 of 9 files
python tools/asset_pipeline/world/make_stage2_decor.py --output <scratch>/world

# the ship: byte-identical, 4 of 4 files
python tools/asset_pipeline/ship/assemble_ship.py --output <scratch>

# the space background: 153 of 153 PNG byte-identical, 4 tiles differ - see the
# note below before replacing anything
python tools/asset_pipeline/background/prep_assets.py --output <scratch>/space_bg
```

All of them accept `-n/--dry-run` (validate and report, write nothing) and
`-f/--force` (overwrite). They exit 2 with a sentence on a bad input.

## What does not regenerate byte-for-byte

The layer-split ladder in `background/layer_split/` was cut from a 1672x941
plate that lived on one machine
(`C:\Users\HP-1282\Downloads\fa75602c-....png`) and is **not in the
repository**. Re-running it needs `--source <that plate>`. The extracted plates
it produced are in `background/layers/`, so `prep_assets.py` still works without
the original.

Running `prep_assets.py` today reproduces 153 of 157 shipped `space_bg` PNGs
byte for byte. Four do not match, and the difference is an **improvement in the
tool, not a regression in the art**:

| file | shipped wrap step | regenerated wrap step |
| --- | --- | --- |
| `nebula_tile.png` | 0.068 levels | 0.035 |
| `stars_far_tile.png` | 0.059 | 0.000 |

(the two `*_chunk` tiles match exactly). The shipped ones were cut by an earlier
`seamless_tile.py`; the current one closes the wrap better. So regeneration
**would** change how the game looks - for the better, but that is an art
decision, not a cleanup. The shipped assets were deliberately left untouched.

`masks.npz` is the one binary intermediate kept in Git: the plate it was derived
from is gone, so it is now the only record of the split.

## Validate

```powershell
python tools/validation/asset_check.py          # exit 1 if a category is broken
python tools/validation/asset_check.py --json   # same, machine readable
```

## Test

```powershell
tools\testing\run_tests.ps1                 # all logic suites (headless)
tools\testing\run_tests.ps1 -List           # what exists, and what kind
tools\testing\run_tests.ps1 -Suite hud_test # one suite
tools\testing\run_tests.ps1 -Visual         # suites that draw (need a GPU)
tools\testing\run_tests.ps1 -Full           # both
```

No Godot path is hard-coded. `-GodotPath` overrides; otherwise the engine is
looked up on PATH and its version is checked to be the 4.7 line this project
targets - a different version is never used.

Read `../docs/testing.md` for what the runner considers a failure and why the
exit code alone is not enough.
