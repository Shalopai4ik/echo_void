#!/usr/bin/env python3
"""Give the fighter volume without repainting it into a different ship.

The reference render already carries its own shading, panels and blue-grey paint;
the previous version of this pass threw all of that away and rebuilt the hull from
a fixed metal ramp, which is why the ship stopped looking like the reference. What
this pass does now is keep the traced colour underneath and add only the form the
silhouette implies:

* a dome from the distance transform, so the light falls across the body and the
  crest runs where the surface is deepest;
* a wing camber along the chord, so a swept panel brightens toward its leading
  edge instead of turning into a vertical plank;
* a bounce on the far rim, so the shadow side does not collapse to a hole.

The factor is normalised to its own mean and then softened, so it decides where
the light falls and never how bright the ship is. Hue is preserved by multiplying
RGB rather than replacing it, and the result is re-quantised onto a small palette
so the reference's blue stays blue instead of becoming grey.

The silhouette is rebuilt, not painted over: it is smoothed, symmetrised about its
own axis, and given one 1 px ring of a single colour drawn from the mask itself.
`outline_sprite` + `apply_spaa` left a 1.5 px semi-transparent ring, which at 1:1
on screen is exactly what "uneven outline" looks like.

Run: python tools/sculpt_ship.py   (rewrites tools/_ship/ship_c.png in place)
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
from PIL import Image

HERE = _Path(__file__).resolve().parent
sys.path.insert(0, HERE)

import ship_style as st
import smooth_ship

CANVAS = os.path.join(HERE, "_ship", "ship_c.png")

SHOULDER = 9.0        # px from the edge over which the hull still falls away
KEY = np.array([-0.26, -0.30, 0.92])     # top left, in front of the ship
RIM = np.array([0.55, 0.62, 0.55])       # bounce off the lower right
STRENGTH = 0.30       # how much of the analytic light is folded in
CAMBER = 0.55         # wing chord tilt, in normal units
QUANT = 20            # colours the lit hull is flattened onto


def rebuild_mask(img):
    """Smooth, then mirror: one clean outline to draw everything else inside."""
    mask = (img[..., 3] > 8).astype(np.uint8) * 255
    curve = smooth_ship.boundary(mask)
    mask = smooth_ship.offset_outward(curve, float((mask > 0).sum()),
                                      mask.shape[0], mask.shape[1]) > 127
    xs = np.where(mask.any(0))[0]
    cx = (xs.min() + xs.max()) / 2.0
    mask = st.symmetrize(mask, cx)
    return st.fill_holes(st.largest_blob(mask)), cx


def chord_map(mask):
    """How far aft a pixel sits between the leading and trailing edge of its column."""
    h, w = mask.shape
    lead = np.zeros(w)
    trail = np.zeros(w)
    for x in range(w):
        col = np.where(mask[:, x])[0]
        lead[x] = col.min() if len(col) else 0
        trail[x] = col.max() if len(col) else 0
    chord = (np.arange(h)[:, None] - lead[None, :]) / np.maximum(trail - lead, 1.0)[None, :]
    return np.clip(chord, 0.0, 1.0)


def form_normals(mask, cx):
    """Surface normals: a dome over the body, cambered panels out on the wings."""
    h, w = mask.shape
    rows, cols = np.mgrid[0:h, 0:w]
    u = cols - cx
    au = np.abs(u)
    hw = np.zeros(h)
    for y in range(h):
        c = np.where(mask[y])[0]
        if len(c):
            hw[y] = max(c.max() - cx, cx - c.min())
    wing = np.clip((au - 0.45 * hw[:, None]) / np.maximum(0.55 * hw[:, None], 1.0), 0.0, 1.0)

    dist = cv2.distanceTransform(mask.astype(np.uint8), cv2.DIST_L2, 5)
    dome = cv2.GaussianBlur(np.minimum(dist, SHOULDER) / SHOULDER, (0, 0), 1.4)
    gy, gx = np.gradient(dome)
    body = np.stack([-gx, -gy, 0.45 * np.ones_like(gx)], axis=-1)

    chord = chord_map(mask)
    panels = np.stack([0.55 * np.sign(u) * wing,
                       (chord - 0.30) * 2.0 * CAMBER, np.ones_like(u)], axis=-1)

    n = body * (1.0 - wing[..., None]) + panels * wing[..., None]
    n /= np.maximum(np.linalg.norm(n, axis=-1, keepdims=True), 1e-6)
    return n, dist


def quantise(rgb, mask, k):
    px = rgb[mask].astype(np.float32)
    crit = (cv2.TERM_CRITERIA_EPS + cv2.TERM_CRITERIA_MAX_ITER, 30, 0.5)
    _, _, centres = cv2.kmeans(px, k, None, crit, 4, cv2.KMEANS_PP_CENTERS)
    centres = np.clip(centres, 0, 255).astype(np.uint8)
    d = ((px[:, None, :] - centres[None, :, :].astype(np.float32)) ** 2).sum(-1)
    out = rgb.copy()
    out[mask] = centres[d.argmin(1)]
    return out


def main():
    img = np.asarray(Image.open(CANVAS).convert("RGBA")).copy()
    mask, cx = rebuild_mask(img)
    n, dist = form_normals(mask, cx)

    key = KEY / np.linalg.norm(KEY)
    rim = RIM / np.linalg.norm(RIM)
    diff = np.clip((n * key).sum(-1), 0.0, 1.0)
    bounce = np.clip((n * rim).sum(-1), 0.0, 1.0) ** 3

    factor = 0.42 + 0.90 * diff + 0.14 * bounce * np.clip((3.0 - dist) / 3.0, 0, 1)
    factor *= float(mask.sum()) / float(factor[mask].sum())
    factor = 1.0 + STRENGTH * (factor - 1.0)      # keep the reference's own lighting
    factor = np.clip(factor, 0.62, 1.45)

    out = img.copy()
    out[..., 3] = np.where(mask, 255, 0)
    out[~mask, :3] = 0
    out[mask, :3] = np.clip(np.round(img[mask, :3].astype(float) * factor[mask][:, None]),
                            0, 255).astype(np.uint8)
    out[..., :3] = quantise(out[..., :3], mask, QUANT)
    out = st.outline(out)
    Image.fromarray(out, "RGBA").save(CANVAS)

    stats = st.outline_stats(out)
    print("canvas %dx%d  mask %d px  axis %.1f  colours %d"
          % (out.shape[1], out.shape[0], int(mask.sum()), cx,
             len(set(map(tuple, out[mask][:, :3].tolist())))))
    print("outline: %d px, %d partial-alpha, %d interiors, colours %s"
          % (stats["ring_px"], stats["partial_alpha"], stats["interior_outline_px"],
             sorted(stats["ring_colours"])))
    lum = out[..., :3].astype(float).mean(2)
    for name, y0, y1, x0, x1 in (("nose", 4, 24, 0, out.shape[1]),
                                 ("body", 34, 54, 36, 62),
                                 ("wing L", 56, 78, 4, 30),
                                 ("wing R", 56, 78, 68, 94),
                                 ("tail", 100, 130, 30, 70)):
        sel = mask[y0:y1, x0:x1]
        got = lum[y0:y1, x0:x1][sel]
        if got.size:
            print("  %-7s mean %5.1f  min %5.1f  max %5.1f" % (name, got.mean(), got.min(), got.max()))
    print("mask px changed vs traced: %d" % int((mask != (img[..., 3] > 8)).sum()))


if __name__ == "__main__":
    main()