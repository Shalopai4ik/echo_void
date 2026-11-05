#!/usr/bin/env python3
"""Locate straight, sign-consistent brightness steps (tiling seams) in an image.

A seam is not merely a column where pixels change: it is a column where the
change keeps the *same sign* for hundreds of rows. Natural nebula edges wander,
so they cancel; a wrap join does not. Measuring the mean signed step instead of
the mean absolute step is what separates the two - and masking out anything
brighter than the haze matters just as much, because one asteroid sitting on one
side of the line produces a bigger absolute step than the seam itself.

    python tools/find_seam.py <image.png> [...] [--amp N] [--bright 18] [--crop x,y,w,h]
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
import os
import sys

import cv2
import numpy as np


def grey(path):
    im = cv2.imread(path, cv2.IMREAD_UNCHANGED)
    if im is None:
        raise SystemExit("cannot read " + path)
    if im.ndim == 3:
        im = cv2.cvtColor(im[..., :3], cv2.COLOR_BGR2GRAY)
    return im.astype(np.float32)


def sky_mask(g, bright):
    return cv2.dilate(g, np.ones((15, 15), np.uint8)) < bright


def line_steps(g, axis, bright):
    """(|score|, line index, signed step, mean |step|, consistency, sharpness, rows)
    for every line, sorted worst first.

    `sharpness` is what tells a seam from a cloud edge: a wrap join spends all of
    its step on one line, so its neighbours step almost nothing, while a soft
    gradient spreads the same total change over tens of lines and every single
    one of them looks like a step on its own."""
    a = g if axis == 1 else g.T
    m = sky_mask(g, bright) if axis == 1 else sky_mask(g.T, bright)
    signed = {}
    for i in range(1, a.shape[1]):
        keep = m[:, i] & m[:, i - 1]
        if keep.sum() < 150:
            continue
        d = a[keep, i] - a[keep, i - 1]
        signed[i] = (float(d.mean()), float(np.abs(d).mean()),
                     abs(float(d.sum())) / max(float(np.abs(d).sum()), 1e-6),
                     int(keep.sum()))
    out = []
    for i, (mean, mag, cons, cnt) in signed.items():
        side = max(abs(signed.get(i - 1, (0.0,))[0]), abs(signed.get(i + 1, (0.0,))[0]))
        sharp = abs(mean) / max(side, 0.02)
        out.append((abs(mean) * min(sharp, 3.0) / 3.0, i, mean, mag, cons, sharp, cnt))
    out.sort(reverse=True)
    return out


def report(path, amp, crop, bright):
    g = grey(path)
    if crop:
        x, y, w, h = crop
        g = g[y:y + h, x:x + w]
    print("%s  %dx%d  sky mean %.2f std %.2f"
          % (path, g.shape[1], g.shape[0], g.mean(), g.std()))
    for axis, name in ((1, "vertical"), (0, "horizontal")):
        res = line_steps(g, axis, bright)
        print("   %s joins, ranked by step x sharpness (8-bit levels):" % name)
        for _, i, signed, mag, cons, sharp, cnt in res[:5]:
            print("      %4d  signed=%+.3f  |d|=%.3f  consistent=%.0f%%  "
                  "sharp=%.1fx  rows=%d" % (i, signed, mag, cons * 100, sharp, cnt))
        if amp and res:
            out = np.clip(g * amp, 0, 255).astype(np.uint8)
            out = cv2.cvtColor(out, cv2.COLOR_GRAY2BGR)
            for _, i, *_ in res[:3]:
                if axis == 1:
                    cv2.line(out, (i, 0), (i, out.shape[0] - 1), (0, 0, 255), 1)
                else:
                    cv2.line(out, (0, i), (out.shape[1] - 1, i), (0, 0, 255), 1)
            fname = "_seammark_%s_%s.png" % (os.path.basename(path).rsplit(".", 1)[0],
                                             "v" if axis == 1 else "h")
            cv2.imwrite(fname, out)
            print("      %dx amplified, worst lines marked -> %s" % (amp, amp, fname))


def main():
    argv = sys.argv[1:]
    amp, crop, files, bright = 0, None, [], 18.0
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--amp":
            amp = int(argv[i + 1]); i += 2
        elif a == "--bright":
            bright = float(argv[i + 1]); i += 2
        elif a == "--crop":
            crop = tuple(int(v) for v in argv[i + 1].split(",")); i += 2
        else:
            files.append(a); i += 1
    if not files:
        print(__doc__)
        return 1
    for f in files:
        report(f, amp, crop, bright)
    return 0


if __name__ == "__main__":
    sys.exit(main())
