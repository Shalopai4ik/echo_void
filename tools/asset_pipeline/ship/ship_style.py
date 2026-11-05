#!/usr/bin/env python3
"""The fighter's look, kept in one place so both paint passes agree.

Two decisions matter more than the paint itself:

* the outline is a ring of a *binary* mask, one pixel thin, every pixel of it
  the same colour - no half-transparent fringe. The sprite is drawn at 1:1 on
  screen (scale 2 under a 0.5 camera), so an antialiased edge does not smooth
  anything, it just makes the contour look chewed;
* shading is quantised onto one short metal ramp, so every surface in the ship
  is made of the same material whatever pass painted it.
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
import cv2
import numpy as np

OUTLINE = (11, 18, 25)

RAMP = [(22, 31, 42), (43, 53, 66), (61, 74, 90), (82, 92, 107),
        (105, 115, 127), (126, 136, 150), (150, 159, 170), (174, 182, 191),
        (193, 200, 206), (212, 217, 222), (233, 237, 240), (244, 246, 248)]

GLASS = [(15, 40, 57), (18, 56, 79), (30, 74, 101), (47, 109, 143),
         (77, 127, 161), (120, 168, 196)]


def ramp(v):
    """Map 0..1 onto the metal ramp; 0 is outline-dark, 1 is the brightest."""
    i = int(round(np.clip(v, 0.0, 1.0) * (len(RAMP) - 1)))
    return RAMP[i]


def glass(v):
    i = int(round(np.clip(v, 0.0, 1.0) * (len(GLASS) - 1)))
    return GLASS[i]


def largest_blob(mask):
    n, labels, stats, _ = cv2.connectedComponentsWithStats(mask.astype(np.uint8), 8)
    if n <= 1:
        return mask
    keep = 1 + int(np.argmax(stats[1:, cv2.CC_STAT_AREA]))
    return labels == keep


def fill_holes(mask):
    """Any transparent pocket inside the silhouette is paint, not sky."""
    m = mask.astype(np.uint8)
    pad = np.zeros((m.shape[0] + 2, m.shape[1] + 2), np.uint8)
    pad[1:-1, 1:-1] = m
    flood = pad.copy()
    cv2.floodFill(flood, np.zeros((pad.shape[0] + 2, pad.shape[1] + 2), np.uint8), (0, 0), 1)
    return (pad | (1 - flood))[1:-1, 1:-1].astype(bool)


def symmetrize(mask, cx):
    """Mirror the silhouette onto itself.

    The shape was traced off a photograph, so its left and right sides differ by
    a pixel here and there. On a 90 pixel wingspan that reads as a wobbly
    contour rather than as character, so the hull is made exactly symmetric.
    """
    h, w = mask.shape
    src = np.rint(cx - (np.arange(w) - cx)).astype(int)
    ok = (src >= 0) & (src < w)
    mir = np.zeros_like(mask)
    mir[:, ok] = mask[:, src[ok]]
    return mask | mir


def boundary(mask):
    """The 1 px ring of mask pixels that touch the outside (4-neighbour)."""
    er = cv2.erode(mask.astype(np.uint8), np.ones((3, 3), np.uint8), borderValue=0)
    return (mask.astype(np.uint8) - er).astype(bool)


def outline(img):
    """Binary alpha plus a single uniform ring. Idempotent while the mask holds."""
    mask = img[..., 3] > 8
    out = np.zeros_like(img)
    out[mask] = img[mask]
    out[mask, 3] = 255
    ring = boundary(mask)
    out[ring, :3] = OUTLINE
    out[ring, 3] = 255
    return out


def outline_stats(img):
    """Proof that the contour is even: every boundary pixel, one colour, no fringe."""
    a = img[..., 3]
    mask = a > 8
    ring = boundary(mask)
    partial = int(((a > 0) & (a < 255)).sum())
    ring_cols = {tuple(c) for c in img[ring][:, :3].tolist()}
    # a contour pixel is only allowed to be the contour: if the dark colour shows
    # up just inside the ring, the outline is thicker than one pixel there. The
    # nozzle throat is deliberately the same black, so only look near the edge.
    interior = mask & ~ring & (cv2.distanceTransform(mask.astype(np.uint8), cv2.DIST_L2, 5) <= 2.0)
    painted = np.array([tuple(c) == OUTLINE for c in img[interior][:, :3].tolist()],
                       dtype=bool) if interior.any() else np.zeros(0, bool)
    return {"ring_px": int(ring.sum()), "ring_colours": ring_cols,
            "partial_alpha": partial, "interior_outline_px": int(painted.sum())}