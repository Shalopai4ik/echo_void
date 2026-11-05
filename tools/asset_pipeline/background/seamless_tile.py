#!/usr/bin/env python3
"""Make a background tile genuinely seamless, in place.

A wrap-blurred plate is NOT seamless, however the generator describes it: circular
filtering leaves the plate's own left/right and top/bottom mismatch exactly where
it is and only smears it over a few pixels, and that smeared step is the
rectangular seam you see once the band is tiled.

Band-limiting in the Fourier domain does make a picture periodic, but it is the
wrong trade here. The haze keeps 99.5% of its *energy* below a radius of 0.02,
and that energy is the flat background: the texture you actually see lives in the
fraction of a percent a cutoff throws away, so the tile came back with half its
contrast gone.

So fix only what is broken. Force the two wrap edges to agree by pulling a band
next to each one towards the average of the pair, easing back to the untouched
image over `band` pixels. The step across the border becomes exactly zero, and
everything outside the two bands is bit for bit what it was.

Two rules this tool exists because of:

* Every channel gets the same treatment. A tiled RGBA layer composites as
  RGB * A, so a step hiding in the alpha or in the near-transparent haze is as
  visible as one in the base colour; suturing only the RGB of `nebula_tile.png`
  left a 3-level line on screen.
* The interior gradient does not license a step. Comparing a wrap break to the
  tile's own per-pixel gradient says "only 1.4x, nothing special" - but the
  gradient wanders while the break is dead straight and runs the full height of
  the screen, and the eye integrates along a line. So any step above a tenth of
  a level gets closed, whatever the ratio.

    python tools/seamless_tile.py <file_or_dir> [...more] [--band 96] [--check]

--check writes nothing and exits non-zero if any tile still has a step, so it
works as a gate before a build.
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
import glob
import os
import sys

import cv2
import numpy as np

DEFAULT_BAND = 96        # pixels at each edge pulled towards the wrap average
SEAM_LEVELS = 0.1        # a straight line is visible well below one 8-bit level


def _smooth(t):
    return t * t * (3.0 - 2.0 * t)


JITTER = 3.0             # px of per-pixel scatter on the blend distance


def periodic(img, band=DEFAULT_BAND, seed=11):
    """Pull every channel's wrap edges into agreement. Works on any shape.

    The blend distance is scattered per pixel. Without that scatter the
    correction moves a whole column by the same fraction, so the 8-bit rounding
    boundary is crossed at the same x for hundreds of rows at once and the
    repaired band comes back as a set of dead-straight one-level lines - worse
    than the seam it replaced, because a straight line is what the eye integrates
    (x=65 of the base haze went from -0.06 levels at 25% sign agreement to
    +0.22 at 96%). Scattering the distance by a few pixels wiggles those
    boundaries back into the noise of the image, and leaves the edges untouched:
    the weight is still exactly 0 at both wrap borders, so they still match.
    """
    rng = np.random.default_rng(seed)
    out = img.astype(np.float32)
    for axis in (1, 0):
        a = np.moveaxis(out, axis, 0)          # a[0] and a[-1] are the wrap edges
        n = a.shape[0]
        b = min(band, n // 2 - 1)
        if b < 1:
            continue
        avg = 0.5 * (a[0] + a[-1])             # the value both edges must agree on
        lead = (n,) + (1,) * (a.ndim - 1)
        d = np.minimum(np.arange(n), n - 1 - np.arange(n)).astype(np.float32)
        d = d.reshape(lead)
        # one-sided: the transition may only be pushed later, never earlier, so
        # the distance stays exactly 0 on both wrap borders and they still agree
        d = np.maximum(d - rng.random((n,) + a.shape[1:-1] + (1,)).astype(np.float32)
                       * JITTER, 0.0)
        w = _smooth(np.clip(d / b, 0.0, 1.0))
        a[:] = a * w + avg[None] * (1.0 - w)   # moveaxis hands back a view
    return out


def seam(img):
    """Worst mean step across either wrap edge, in 8-bit levels, over every
    channel plus the premultiplied colour that is what actually reaches the
    screen. Also returns the tile's own interior gradient for context."""
    f = img.astype(np.float32)
    chans = [f[..., ch] for ch in range(f.shape[2])]
    if f.shape[2] == 4:
        a = f[..., 3:4] / 255.0
        chans += [f[..., :3] * a]              # premultiplied: what the blend sees
    jump = max(float(max(np.abs(c[:, 0] - c[:, -1]).mean(),
                         np.abs(c[0] - c[-1]).mean())) for c in chans)
    inner = max(float(max(np.abs(np.diff(c, axis=1)).mean(),
                          np.abs(np.diff(c, axis=0)).mean())) for c in chans)
    return jump, inner


def fix(path, band, check_only):
    raw = cv2.imread(path, cv2.IMREAD_UNCHANGED)
    if raw is None:
        print("cannot read", path)
        return 0
    was, inner = seam(raw)
    if check_only:
        ok = was <= SEAM_LEVELS
        print("%-32s %5dx%-5d seam %6.3f levels (interior gradient %.3f)  %s"
              % (os.path.basename(path), raw.shape[1], raw.shape[0], was, inner,
                 "OK" if ok else "NEEDS FIX"))
        return 0 if ok else 1
    if was <= SEAM_LEVELS:
        print("%-32s %5dx%-5d seam %6.3f levels, already seamless"
              % (os.path.basename(path), raw.shape[1], raw.shape[0], was))
        return 0
    # rint, not astype: truncating turns 6.999 into 6 and paints a one
    # level line wherever the correction lands just under an integer
    out = np.rint(np.clip(periodic(raw, band), 0, 255)).astype(raw.dtype)
    touched = float(np.abs(out.astype(np.float32) - raw.astype(np.float32)).mean())
    g = [float(cv2.cvtColor(a[..., :3], cv2.COLOR_BGR2GRAY).std()) for a in (raw, out)]
    now, inner_now = seam(out)
    if not check_only:
        cv2.imwrite(path, out)
    print("%-32s %5dx%-5d seam %6.3f -> %6.3f levels   "
          "changed %.3f/255, contrast %.2f -> %.2f"
          % (os.path.basename(path), raw.shape[1], raw.shape[0], was, now,
             touched, g[0], g[1]))
    return 1


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    band = DEFAULT_BAND
    if "--band" in sys.argv:
        band = int(sys.argv[sys.argv.index("--band") + 1])
        args = [a for a in args if a != "--band" and a != str(band)]
    if not args:
        print(__doc__)
        return 1
    check = "--check" in sys.argv
    files = []
    for a in args:
        files += sorted(glob.glob(os.path.join(a, "**", "*tile*.png"), recursive=True)) \
            if os.path.isdir(a) else [a]
    tally = sum(fix(f, band, check) for f in files)
    if check:
        print("%d tile(s) reported, %d need fixing" % (len(files), tally))
        return 1 if tally else 0
    print("%d file(s) rewritten" % tally)
    return 0


if __name__ == "__main__":
    sys.exit(main())
