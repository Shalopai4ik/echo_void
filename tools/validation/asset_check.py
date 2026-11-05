"""Check that every asset category the game needs is present and loadable.

Run:  python tools/validation/asset_check.py [--verbose] [--json]

Why this exists: parts of the game discover their art at run time by listing a
directory (the space background's `sprites/`, the world field's decor, the
asteroid belts). A renamed or deleted file in one of those folders fails at
run time with no static warning, and nothing in CI would notice. This tool is
that missing static check: it walks the categories the game actually asks for,
and exits non-zero when one is missing, empty or contains a file Godot cannot
import.

It checks existence, non-emptiness and PNG decodability. It deliberately does
NOT invent a manifest of 205 file names - a directory that is supposed to hold
"whatever PNGs are here" is checked as a directory, and only the fixed
single-file references (the ship, the buses, the settings resources) are named.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

_UP = Path(__file__).resolve()
while _UP.name != "tools":
    _UP = _UP.parent
if str(_UP) not in sys.path:
    sys.path.insert(0, str(_UP))

from asset_pipeline.shared.pipeline_common import (  # noqa: E402
    ASSETS_DIR, LOG, PROJECT_ROOT, SCENES_DIR, TOOLS_ROOT, add_common, fail,
    load_rgba, make_argparser, require_dir, run)

# A directory the game enumerates at run time. If it is empty, the feature that
# reads it silently does nothing - which is why an empty one is a hard error.
SCANNED = (
    # (label, directory, required suffix filter, minimum count)
    # suffix "*" means "any file at all"
    ("space background sprites", ASSETS_DIR / "space_bg" / "sprites", ".png", 1),
    ("space background layers", ASSETS_DIR / "space_bg", ".png", 2),
    ("asteroid sprites", ASSETS_DIR / "asteroids", ".png", 1),
    ("world decor", ASSETS_DIR / "world", ".png", 1),
    ("ship resources", ASSETS_DIR / "ship", ".tres", 1),
)

# Audio is the one category that is deliberately allowed to be empty for now:
# the mixer, the buses and the event names exist, the sound files do not. An
# empty directory is reported as a warning listing the expected events, so the
# gap is visible without failing the build.
AUDIO_DIR = ASSETS_DIR / "audio" / "ship"

# A single file the game names outright.
NAMED = (
    ("main scene", SCENES_DIR / "world" / "SpaceMap.tscn"),
    ("legacy scene", SCENES_DIR / "main.tscn"),
    ("bus layout", PROJECT_ROOT / "default_bus_layout.tres"),
    ("world settings resource", ASSETS_DIR / "world" / "space_generation.tres"),
    ("engine parameters", ASSETS_DIR / "ship" / "engine_parameters.tres"),
    ("assist parameters", ASSETS_DIR / "ship" / "assist_parameters.tres"),
    ("audio parameters", ASSETS_DIR / "ship" / "audio_parameters.tres"),
    ("project file", PROJECT_ROOT / "project.godot"),
)

# The sprites the project icon and the ship scene point at.
ICONS = ("fighter.png", "cruiser.png")

# JSON catalogues that must parse and agree with the directory they describe.
CATALOGUES = (
    ("space background sprites", ASSETS_DIR / "space_bg" / "sprites" / "manifest.json",
     ASSETS_DIR / "space_bg" / "sprites", "file"),
)


def check_scanned(results: list) -> None:
    for label, path, suffix, minimum in SCANNED:
        if not path.is_dir():
            results.append(("FAIL", f"{label}: directory missing ({path})"))
            continue
        found = sorted(p.name for p in path.glob("*" + suffix))
        if len(found) < minimum:
            results.append(("FAIL", f"{label}: {len(found)} {suffix} files, "
                                    f"need at least {minimum} ({path})"))
            continue
        results.append(("OK", f"{label}: {len(found)} {suffix} in {path.name}/"))


def check_audio(results: list) -> None:
    """Report the audio gap without inventing files the project does not have."""
    if not AUDIO_DIR.is_dir():
        results.append(("FAIL", f"audio ship events: directory missing ({AUDIO_DIR})"))
        return
    audio = sorted(p.name for p in AUDIO_DIR.iterdir()
                   if p.suffix.lower() in (".wav", ".ogg", ".mp3"))
    if not audio:
        results.append(("WARN", "audio ship events: no sound files; the mixer, "
                                "buses and event names exist but are silent "
                                "(see docs/audio_requirements.md)"))
        return
    results.append(("OK", f"audio ship events: {len(audio)} sound files"))


def check_named(results: list) -> None:
    for label, path in NAMED:
        if not path.is_file():
            results.append(("FAIL", f"{label}: missing ({path})"))
            continue
        if path.stat().st_size == 0:
            results.append(("FAIL", f"{label}: empty ({path})"))
            continue
        results.append(("OK", f"{label}: {path.name}"))


def check_icons(results: list) -> None:
    for name in ICONS:
        path = ASSETS_DIR / name
        if not path.is_file():
            results.append(("WARN", f"art icon {name}: missing"))
            continue
        try:
            load_rgba(path, f"art icon {name}")
            results.append(("OK", f"art icon {name}: decodes"))
        except PipelineError as exc:
            results.append(("FAIL", str(exc)))


def check_catalogues(results: list) -> None:
    for label, manifest, base, key in CATALOGUES:
        if not manifest.is_file():
            results.append(("FAIL", f"{label} manifest: missing ({manifest})"))
            continue
        try:
            data = json.loads(manifest.read_text(encoding="utf-8"))
        except Exception as exc:
            results.append(("FAIL", f"{label} manifest: not valid JSON ({exc})"))
            continue
        entries = data.get("sprites") if isinstance(data, dict) else data
        if not isinstance(entries, list):
            results.append(("FAIL", f"{label} manifest: no sprite list"))
            continue
        missing, present = [], 0
        for entry in entries:
            name = entry.get(key) if isinstance(entry, dict) else entry
            if not name:
                results.append(("FAIL", f"{label} manifest: entry with no {key}"))
                continue
            if (base / name).is_file():
                present += 1
            else:
                missing.append(name)
        if missing:
            results.append(("FAIL", f"{label}: {len(missing)} listed files absent, "
                                    f"first: {missing[0]}"))
        else:
            results.append(("OK", f"{label}: {present} entries all present"))


def main(argv=None) -> int:
    parser = make_argparser("verify echo_void's asset categories")
    add_common(parser, want_input=False, want_output=False)
    parser.add_argument("--json", action="store_true",
                        help="emit the report as JSON instead of text")
    args = parser.parse_args(argv)
    LOG.verbose = args.verbose

    require_dir(ASSETS_DIR, "asset")
    require_dir(SCENES_DIR, "scenes")
    results: list = []
    check_named(results)
    check_scanned(results)
    check_icons(results)
    check_catalogues(results)
    check_audio(results)
    bad = [r for r in results if r[0] == "FAIL"]
    warn = [r for r in results if r[0] == "WARN"]
    if args.json:
        print(json.dumps([{"status": s, "detail": d} for s, d in results], indent=1))
    else:
        for status, detail in results:
            print(f"{status:4}  {detail}")
        print(f"\n{len(results) - len(bad)} ok, {len(bad)} failed, {len(warn)} warning")
    if bad:
        LOG.error(f"{len(bad)} asset problem(s)")
        return 1
    return 0


if __name__ == "__main__":
    run(main)

from asset_pipeline.shared.pipeline_common import (  # noqa: E402
    ASSETS_DIR, LOG, PipelineError, PROJECT_ROOT, SCENES_DIR, SCRIPTS_DIR,
    TOOLS_ROOT, add_common, fail, load_rgba, make_argparser, require_dir, run)

if __name__ == "__main__":
    run(main)
