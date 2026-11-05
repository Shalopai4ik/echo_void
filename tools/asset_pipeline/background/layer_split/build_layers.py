"""Stage 2 - build the RGBA layers from masks.npz.

Decomposition (exact by construction):
  im = star_light + base            (star_light = additive, base = min(im, blur(im)))
  base = clean (holes diffused) with objects occluding
  clean = background + nebula       (background = min(clean, blur(clean, 90)))
Layers composite as: background -> nebula(ADD) -> stars_far(ADD) -> stars_near(ADD)
                     -> planet(NORMAL) -> asteroids_far(NORMAL) -> asteroids_near(NORMAL)
"""
# --- pipeline layout: every path below derives from this file, not the machine ---
# The art tools used to hard-code C:\Users\<someone>\... They now locate the
# repository root by walking up from __file__ to the directory named "tools", so
# one checkout works for any user, drive and clone depth.
import sys as _sys
from pathlib import Path as _Path

_UP = _Path(__file__).resolve()
while _UP.name != "tools":
    _UP = _UP.parent
if str(_UP) not in _sys.path:
    _sys.path.insert(0, str(_UP))

from asset_pipeline.shared.pipeline_common import (  # noqa: E402
    ASSETS_DIR, PLATE_DIR, PROJECT_ROOT, TOOLS_ROOT, LOG, PipelineError, add_common,
    fail, load_rgba, make_argparser, require_dir, require_file, resolve_output,
    run, save_rgba)
from pathlib import Path
import numpy as np, cv2, os, json
from PIL import Image
from scipy.sparse import coo_matrix, diags
from scipy.sparse.linalg import cg

HERE = _Path(__file__).resolve().parent
# --- paths and flags -------------------------------------------------------
# Every input and output below is an argument so the ladder can be re-run from a
# scratch tree. The 1672x941 plate these scripts were cut from lived only on the
# machine that wrote them (C:\Users\HP-1282\Downloads\fa75602c-....png); it is
# not in the repository, so --source has to be supplied by the caller. Everything
# else defaults next to this file.
_p = make_argparser("build the RGBA layers from masks.npz")
add_common(_p, want_input=False, want_output=False, want_config=False,
           want_manifest=False)
_p.add_argument("-i", "--source", type=Path, default=TOOLS_ROOT / 'asset_pipeline' / 'background' / 'layers-source',
                help="the 1672x941 plate the layers were cut from")
_p.add_argument("-o", "--output", type=Path,
                default=HERE / "EchoOfVoid_Background_Layers",
                help="directory the layers are written into")
_p.add_argument("--debug", type=Path, default=HERE / "_debug",
                help="directory for the diagnostic images (not game assets)")
_A = _p.parse_args()
LOG.verbose = _A.verbose
SRC = Path(_A.source)
OUT = Path(_A.output)
DBG = Path(_A.debug)
if _A.dry_run:
    print("dry run: would cut %s into %s" % (SRC, OUT))
    raise SystemExit(0)
prepare_dir(DBG, "debug directory", force=_A.force)

