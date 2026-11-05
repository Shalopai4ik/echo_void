#!/usr/bin/env python3
"""Smooth the fighter's silhouette and flatten its paint noise.

The sprite in tools/_ship/ship_c.png was lifted pixel by pixel off a photo, which
leaves two things a redrawn ship should not have: a boundary that jags by single
pixels, and paint that speckles because the photograph had grain. Both are fixed
here geometrically rather than by blurring, because the nose is two pixels wide
and any blur that softens a staircase also eats the spike.

The outline is resampled to equal arc length and smoothed along that arc, so a
point only ever moves toward its neighbours *on the contour* - the nose stays
pointed, the wing leading edges become one clean ramp instead of a saw.

Run: python tools/smooth_ship.py
Reads the photo-derived ship_raw.png, writes the working ship_c.png that
the pixelart canvases are then drawn on top of.
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
SRC = os.path.join(HERE, "_ship", "ship_raw.png")
DST = os.path.join(HERE, "_ship", "ship_c.png")

SS = 8                    # supersample used to rasterise the smooth outline
SMOOTH_PX = 2.2           # arc length, in sprite pixels, of the boundary blur
BILATERAL = (5, 22, 2.0)  # d, sigmaColor, sigmaSpace - flattens grain, keeps seams
PALETTE_KEEP = 18         # colours left standing after the paint is flattened
MARGIN = 4                # transparent border kept clear around the silhouette


def boundary(src):
    """The outline as one ordered curve, smoothed along its own arc length."""
    cnts, _ = cv2.findContours(src, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE)
    pts = cnts[0].reshape(-1, 2).astype(float)          # (x, y)
    step = np.linalg.norm(np.diff(np.vstack([pts, pts[:1]]), axis=0), axis=1)
    total = float(step.sum())
    s = np.concatenate([[0.0], np.cumsum(step)[:-1], [total]])    # closed, n+1 long
    xs = np.concatenate([pts[:, 0], pts[:1, 0]])
    ys = np.concatenate([pts[:, 1], pts[:1, 1]])
    n = max(int(total * 2), 64)                          # ~half-pixel resolution
    t = np.linspace(0, total, n, endpoint=False)
    xy = np.stack([np.interp(t, s, xs), np.interp(t, s, ys)], axis=1)

    # circular kernel: the curve closes on itself, so the ends must wrap
    radius = max(1, int(round(SMOOTH_PX * n / total)))
    k = np.exp(-0.5 * (np.arange(-radius, radius + 1) / (radius / 2.2)) ** 2)
    k /= k.sum()
    pad = np.concatenate([xy[-radius:], xy, xy[:radius]])
    return np.stack([np.convolve(pad[:, i], k, mode="valid") for i in (0, 1)], axis=1)


def rasterise(curve, h, w):
    big = np.zeros((h * SS, w * SS), np.uint8)
    cv2.fillPoly(big, [np.round(curve * SS).astype(np.int32)], 255, cv2.LINE_AA)
    return (cv2.resize(big, (w, h), interpolation=cv2.INTER_AREA) > 127).astype(np.uint8) * 255


def offset_outward(curve, want_area, h, w):
    """Push the outline half a pixel off the pixel centres it was traced through.

    cv2.findContours walks pixel centres, so a polygon through them encloses about
    half the boundary's worth of area less than the pixels themselves. Without
    this the smoothing quietly shrinks the airframe and the nose loses its tip.
    """
    tan = np.roll(curve, -1, axis=0) - np.roll(curve, 1, axis=0)
    nrm = np.stack([-tan[:, 1], tan[:, 0]], axis=1)
    nrm /= np.maximum(np.linalg.norm(nrm, axis=1, keepdims=True), 1e-6)
    for sign in (0.5, -0.5):
        got = rasterise(curve + nrm * sign, h, w)
        if abs(got.sum() / 255 - want_area) < 24:
            return got
    return rasterise(curve + nrm * 0.5, h, w)


def snap_palette(rgb, mask, src_rgb, src_mask):
    """Re-quantise onto the colours the sprite was actually built from.

    The bilateral pass does its job too well: it invents intermediate shades and
    a 4600 pixel sprite ends up with 194 of them, which reads as dirt rather than
    as metal. Snapping back to the dominant source colours keeps the flattening
    and puts the ramp under control again.
    """
    cols = src_rgb[src_mask > 0].astype(float)
    counts = {}
    for c in cols.astype(int).tolist():
        counts[tuple(c)] = counts.get(tuple(c), 0) + 1
    keep = np.array([c for c, _ in sorted(counts.items(), key=lambda kv: -kv[1])
                     [:PALETTE_KEEP]], float)
    ys, xs = np.where(mask > 0)
    px = rgb[ys, xs].astype(float)
    idx = ((px[:, None, :] - keep[None, :, :]) ** 2).sum(-1).argmin(1)
    out = rgb.copy()
    out[ys, xs] = keep[idx].astype(np.uint8)
    return out


def main():
    rgba = np.asarray(Image.open(SRC).convert("RGBA")).copy()
    h, w = rgba.shape[:2]
    old = np.where(rgba[..., 3] > 8, 255, 0).astype(np.uint8)
    curve = boundary(old)
    new = offset_outward(curve, float((old > 0).sum()), h, w)

    # Paint that fell inside the new outline but outside the old one has to be
    # filled from the nearest drawn pixel, or the smoothing leaves pale gaps.
    outside = (new > 0) & (old == 0)
    if outside.any():
        _, labels = cv2.distanceTransformWithLabels(1 - (old > 0).astype(np.uint8),
                                                    cv2.DIST_L2, 3,
                                                    labelType=cv2.DIST_LABEL_PIXEL)
        idx = labels[outside] - 1
        src_yx = np.argwhere(old > 0)
        rgba[outside, :3] = rgba[src_yx[idx, 0], src_yx[idx, 1], :3]

    rgb = cv2.bilateralFilter(rgba[..., :3].astype(np.uint8), *BILATERAL)
    rgb = snap_palette(rgb, new, rgba[..., :3], old)
    art = np.dstack([rgb, np.where(new > 0, 255, 0).astype(np.uint8)])
    # a margin on every side: the wings reach the edge of the traced sprite, and
    # a uniform outline has nowhere to go without room to be drawn in
    out = np.zeros((art.shape[0] + MARGIN * 2, art.shape[1] + MARGIN * 2, 4), np.uint8)
    out[MARGIN:MARGIN + art.shape[0], MARGIN:MARGIN + art.shape[1]] = art
    Image.fromarray(out, "RGBA").save(DST)

    face = out[..., 3] > 8
    print("%s: %dx%d (content %d px, %d colours)"
          % (os.path.relpath(DST, os.path.dirname(HERE)), out.shape[1], out.shape[0],
             int(face.sum()), len(set(map(tuple, out[face][:, :3].reshape(-1, 3).tolist())))))
    print("boundary pixels moved: %d, of which %d newly painted, %d removed"
          % (int(np.abs((new > 0).astype(int) - (old > 0).astype(int)).sum()),
             int(((new > 0) & (old == 0)).sum()),
             int(((new == 0) & (old > 0)).sum())))


if __name__ == "__main__":
    main()
