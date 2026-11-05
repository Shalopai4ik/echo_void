#!/usr/bin/env python3
"""Print a canvas as an ASCII map so a non-visual agent can read the art."""
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
import sys

import numpy as np
from PIL import Image

POOL = ("Xx+1Oo*oy&s%8#:=fFhH"
        "23456789abcdefghjkmnpqrstuvwxyzABCDEFGHIJKLMNPQRSTUVWXYZ")


def legend_for(a):
    cols = {}
    for px in a.reshape(-1, 4):
        if px[3] < 128:
            continue
        key = tuple(int(v) for v in px[:3])
        cols[key] = cols.get(key, 0) + 1
    order = sorted(cols, key=lambda c: (0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2]))
    chars, out = {}, {}
    for i, c in enumerate(order):
        ch = POOL[i] if i < len(POOL) else "?"
        chars[c] = ch
        out[ch] = c
    return chars, out


def main(path, x0=None, x1=None, y0=None, y1=None):
    a = np.asarray(Image.open(path).convert("RGBA"))
    h, w = a.shape[:2]
    x0 = 0 if x0 is None else x0
    y0 = 0 if y0 is None else y0
    x1 = w if x1 is None else x1
    y1 = h if y1 is None else y1
    chars, back = legend_for(a)
    print("   " + "".join(str((x0 + i) // 100 % 10) for i in range(x1 - x0)))
    print("   " + "".join(str((x0 + i) // 10 % 10) for i in range(x1 - x0)))
    print("   " + "".join(str((x0 + i) % 10) for i in range(x1 - x0)))
    for r in range(y0, y1):
        row = ""
        for c in range(x0, x1):
            if a[r, c, 3] < 128:
                row += "."
            else:
                row += chars.get(tuple(int(v) for v in a[r, c, :3]), "?")
        print("%3d %s" % (r, row))
    print()
    print("legend: " + "  ".join("%s=#%02x%02x%02x" % (ch, *rgb) for ch, rgb in back.items()))


if __name__ == "__main__":
    args = [int(v) for v in sys.argv[2:6]] if len(sys.argv) > 2 else []
    main(sys.argv[1], *args)