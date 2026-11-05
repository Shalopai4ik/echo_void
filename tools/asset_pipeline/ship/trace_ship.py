#!/usr/bin/env python3
"""Trace the whole fighter off the reference render, at the game's pixel scale.

The earlier trace stopped at the wings' trailing edge and left the aft third of
the ship outside the canvas: the painted engine that stood in for it was a barrel
the reference does not have, and the ship read as a stubbier, different design.
This rebuilds the source sprite from the reference itself, so the silhouette,
the markings and the blue-grey paint are the reference's rather than an
invention. Everything downstream (smooth_ship, sculpt_ship, assemble_ship) then
operates on the real shape.

The reference is a 228x348 render with soft alpha and 29k colours; the game draws
one texture pixel per screen pixel, so it is resampled to the width the old trace
used and re-quantised onto a small palette. Alpha is premultiplied before the
resize: resampling straight alpha pulls the transparent black into the edges and
leaves a dark fringe around the hull.

Run: python tools/trace_ship.py
Reads tools/_ship/reference.png, writes tools/_ship/ship_raw.png
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

import cv2
import numpy as np
from PIL import Image

HERE = _Path(__file__).resolve().parent
REF = os.path.join(HERE, "_ship", "reference.png")
DST = os.path.join(HERE, "_ship", "ship_raw.png")

WIDTH = 91          # wingspan the old trace used, and the width the game draws at
ALPHA_CUT = 128     # the render's soft edge becomes one hard pixel boundary
PALETTE = 18        # colours the reference is flattened onto


def resample(rgba, width):
    h, w = rgba.shape[:2]
    height = int(round(h * width / float(w)))
    pre = rgba.astype(np.float32)
    pre[..., :3] *= pre[..., 3:] / 255.0
    pre = cv2.resize(pre, (width, height), interpolation=cv2.INTER_AREA)
    pre[..., :3] /= np.maximum(pre[..., 3:] / 255.0, 1e-3)
    return np.clip(pre, 0, 255).astype(np.uint8)


def quantise(rgb, mask, k):
    """Flatten the render onto k colours; the palette is the reference's own."""
    px = rgb[mask].astype(np.float32)
    crit = (cv2.TERM_CRITERIA_EPS + cv2.TERM_CRITERIA_MAX_ITER, 30, 0.5)
    _, _, centres = cv2.kmeans(px, k, None, crit, 4, cv2.KMEANS_PP_CENTERS)
    centres = np.clip(centres, 0, 255).astype(np.uint8)
    d = ((px[:, None, :] - centres[None, :, :].astype(np.float32)) ** 2).sum(-1)
    out = rgb.copy()
    out[mask] = centres[d.argmin(1)]
    return out


def main():
    rgba = np.asarray(Image.open(REF).convert("RGBA"))
    bbox = Image.fromarray(rgba).getchannel("A").getbbox()
    rgba = rgba[bbox[1]:bbox[3], bbox[0]:bbox[2]]
    small = resample(rgba, WIDTH)

    mask = small[..., 3] > ALPHA_CUT
    n, lab, stats, _ = cv2.connectedComponentsWithStats(mask.astype(np.uint8), 8)
    if n > 1:
        mask = lab == (1 + np.argmax(stats[1:, cv2.CC_STAT_AREA]))
    mask = cv2.morphologyEx(mask.astype(np.uint8), cv2.MORPH_CLOSE, np.ones((3, 3), np.uint8)) > 0

    rgb = quantise(small[..., :3], mask, PALETTE)
    out = np.zeros(small.shape, np.uint8)
    out[mask, :3] = rgb[mask]
    out[mask, 3] = 255
    Image.fromarray(out, "RGBA").save(DST)

    print("%s %dx%d  mask %d px  colours %d"
          % (os.path.relpath(DST, os.path.dirname(HERE)), out.shape[1], out.shape[0],
             int(mask.sum()), len(set(map(tuple, out[mask][:, :3].tolist())))))


if __name__ == "__main__":
    main()