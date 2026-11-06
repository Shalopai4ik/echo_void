"""Shared plumbing for the Echo of Void asset pipeline.

Everything the generation scripts used to hard-code lives here instead: where the
project root is, where the canvases and the shipped assets are, how a script
reports progress, how a script fails, and how a script is driven from the command
line.

The rules this module enforces, and the reason it exists:

* **No absolute paths.** `PROJECT_ROOT` is derived from this file's own location,
  so the same checkout works under any user name, any drive and any depth. A
  script that needs a path the repo does not own takes it as a CLI argument.
* **Inputs are checked before anything is written.** `require_file` and
  `require_dir` fail with a one-line message and a non-zero exit code, so a broken
  invocation is never mistaken for a successful regeneration.
* **Nothing is overwritten silently.** `resolve_output` refuses to clobber an
  existing file unless `--force` was passed.
* **`--dry-run` means it.** Scripts must not touch the disk when it is set.
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

# --------------------------------------------------------------------------- #
# Repo layout
# --------------------------------------------------------------------------- #

# tools/asset_pipeline/shared/pipeline_common.py -> tools/asset_pipeline/shared
# -> tools/asset_pipeline -> tools -> <project root>
TOOLS_ROOT: Path = Path(__file__).resolve().parents[2]
PROJECT_ROOT: Path = TOOLS_ROOT.parent

ASSETS_DIR: Path = PROJECT_ROOT / "assets"
SCENES_DIR: Path = PROJECT_ROOT / "scenes"
SCRIPTS_DIR: Path = PROJECT_ROOT / "scripts"
TESTS_DIR: Path = PROJECT_ROOT / "tests"

SCRATCH_DIR: Path = TOOLS_ROOT / "scratch"

# The plates the background ladder was cut from. Kept in Git: regenerating
# `assets/space_bg/*` is impossible without them.
PLATE_DIR: Path = TOOLS_ROOT / "asset_pipeline" / "background" / "layers"

LAYER_SPLIT_DIR: Path = TOOLS_ROOT / "asset_pipeline" / "background" / "layer_split"

# Image loading that fails loudly instead of writing a blank sprite.

SUPPORTED_IN = {".png"}


def load_rgba(path: Path, what: str = "image"):
    """Read an image as an RGBA numpy array, or fail with a readable message."""
    import numpy as np
    from PIL import Image

    path = require_file(path, what)
    if path.suffix.lower() not in SUPPORTED_IN:
        fail(f"{what} is not a PNG: {path}")
    try:
        with Image.open(path) as im:
            return np.asarray(im.convert("RGBA"))
    except Exception as exc:  # a truncated or non-image file must not pass silently
        fail(f"{what} could not be decoded: {path} ({exc})")


def save_rgba(path: Path, array, *, force: bool = False, dry_run: bool = False,
              what: str = "output") -> Path:
    """Write an RGBA numpy array, honouring --force and --dry-run."""
    from PIL import Image

    path = resolve_output(path, what, force=force, dry_run=dry_run)
    if dry_run:
        return path
    Image.fromarray(array).save(path)
    return path



# --------------------------------------------------------------------------- #
# Logging
# --------------------------------------------------------------------------- #


class Log:
    """One logging voice for the whole pipeline.

    `-v/--verbose` turns on per-step chatter; without it a script prints only
    what a reader needs to know it did the right thing. Errors go to stderr
    always, because a caller watching stdout must never miss one.
    """

    def __init__(self, verbose: bool = False) -> None:
        self.verbose = verbose

    def step(self, message: str) -> None:
        if self.verbose:
            print(f"  {message}")

    def info(self, message: str) -> None:
        print(message)

    def warn(self, message: str) -> None:
        print(f"WARNING: {message}", file=sys.stderr)

    def error(self, message: str) -> None:
        print(f"ERROR: {message}", file=sys.stderr)


LOG = Log()


# --------------------------------------------------------------------------- #
# Failures
# --------------------------------------------------------------------------- #


class PipelineError(Exception):
    """A problem worth a non-zero exit code and a sentence a human can act on."""


def fail(message: str) -> PipelineError:
    raise PipelineError(message)


def require_file(path: Path, what: str) -> Path:
    """Fail unless `path` is an existing readable file."""
    path = Path(path)
    if not path.exists():
        fail(f"{what} not found: {path}")
    if not path.is_file():
        fail(f"{what} is not a file: {path}")
    if not os.access(path, os.R_OK):
        fail(f"{what} is not readable: {path}")
    return path


def require_dir(path: Path, what: str) -> Path:
    """Fail unless `path` is an existing directory."""
    path = Path(path)
    if not path.exists():
        fail(f"{what} directory not found: {path}")
    if not path.is_dir():
        fail(f"{what} is not a directory: {path}")
    return path


def resolve_output(path: Path, what: str, force: bool = False,
                   dry_run: bool = False) -> Path:
    """Refuse to clobber an existing FILE unless `force` was asked for.

    Directories are created as needed: a generator's job is to fill a directory,
    and refusing to write into one that already exists would make the common
    case (rebuild into a scratch tree that already holds a previous attempt)
    unusable. Gate individual files with this call, not whole trees.
    """
    path = Path(path)
    if path.exists() and path.is_file() and not force:
        fail(f"{what} already exists: {path} (pass --force to overwrite)")
    if not dry_run:
        path.parent.mkdir(parents=True, exist_ok=True)
    return path


def prepare_dir(path: Path, what: str, *, force: bool = False,
                dry_run: bool = False) -> Path:
    """Make sure a destination directory is usable, honouring --dry-run."""
    path = Path(path)
    if dry_run:
        return path
    if path.exists() and not path.is_dir():
        fail(f"{what} exists and is not a directory: {path}")
    if path.is_dir() and any(path.iterdir()) and not force:
        fail(f"{what} is not empty: {path} (pass --force to overwrite)")
    path.mkdir(parents=True, exist_ok=True)
    return path


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #


def add_common(parser: argparse.ArgumentParser, *,
               want_input: bool = True, want_output: bool = True,
               want_config: bool = False, want_manifest: bool = False) -> None:
    """Add only the flags a tool actually uses, so `--help` stays honest."""
    if want_input:
        parser.add_argument("-i", "--input", type=Path, default=None,
                            metavar="PATH", help="source image or directory")
    if want_output:
        parser.add_argument("-o", "--output", type=Path, default=None,
                            metavar="PATH", help="destination file or directory")
    if want_config:
        parser.add_argument("-c", "--config", type=Path, default=None,
                            metavar="JSON", help="side-car settings (seed, palette)")
    if want_manifest:
        parser.add_argument("-m", "--manifest", type=Path, default=None,
                            metavar="JSON", help="manifest to read or write")


def make_argparser(description: str) -> argparse.ArgumentParser:
    """A parser that already carries the flags every tool honours.

    `-v/--verbose`, `-n/--dry-run` and `-f/--force` are always present; the
    path flags come from `add_common`.
    """
    parser = argparse.ArgumentParser(
        prog=Path(sys.argv[0]).name,
        description=description,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("-v", "--verbose", action="store_true",
                        help="explain each step as it happens")
    parser.add_argument("-n", "--dry-run", action="store_true",
                        help="validate and report, write nothing")
    parser.add_argument("-f", "--force", action="store_true",
                        help="overwrite existing outputs")
    return parser


def run(main) -> None:
    """Execute `main`, turn a `PipelineError` into exit code 2.

    Exit codes: 0 ok, 2 bad input or unwritable output, 130 interrupted. Every
    other failure is a bug and gets a traceback.
    """
    try:
        code = main(sys.argv[1:])
    except PipelineError as exc:
        LOG.error(str(exc))
        raise SystemExit(2)
    except KeyboardInterrupt:
        raise SystemExit(130)
    raise SystemExit(0 if code is None else int(code))
