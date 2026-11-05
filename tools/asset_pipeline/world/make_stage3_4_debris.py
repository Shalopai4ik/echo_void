#!/usr/bin/env python3
"""Paint the metallic debris family for Echo of Void sub-stage 3.4.

The pieces are dark, cold, damaged manufactured fragments: torn panels, a bent
strut, a broken housing and a scorched hull shard.  They use the same top-left
star and restrained rim light as the existing world decor, so they sit naturally
in the void without becoming interactive-looking loot.

Run:
    python tools/asset_pipeline/world/make_stage3_4_debris.py \
        --output assets/world/debris --force
"""
from __future__ import annotations

import argparse
from pathlib import Path

import cv2
import numpy as np
from PIL import Image

SEED = 3404
LIGHT = np.array([-0.58, -0.81], dtype=np.float64)
LIGHT /= np.linalg.norm(LIGHT)
DARK = np.array([9, 13, 19], dtype=np.float64)
BODY = np.array([28, 36, 47], dtype=np.float64)
LIT = np.array([62, 78, 96], dtype=np.float64)
RIM = np.array([132, 158, 184], dtype=np.float64)
SPEC = np.array([190, 210, 226], dtype=np.float64)


def _mask(size, polygons):
    mask = np.zeros((size[1], size[0]), dtype=np.uint8)
    for polygon in polygons:
        cv2.fillPoly(mask, [np.array(polygon, dtype=np.int32)], 255)
    return mask


def _shade(size, mask, rng):
    h, w = size[1], size[0]
    dist = cv2.distanceTransform(mask, cv2.DIST_L2, 3)
    gy, gx = np.gradient(dist.astype(np.float32))
    normal = np.stack((gx, gy), axis=-1)
    normal /= np.maximum(np.linalg.norm(normal, axis=2, keepdims=True), 1e-4)
    ys, xs = np.mgrid[0:h, 0:w].astype(np.float64)
    axis = xs * LIGHT[0] + ys * LIGHT[1]
    turned = np.clip((axis - axis.min()) / max(axis.max() - axis.min(), 1.0), 0.0, 1.0) ** 1.3
    low = rng.normal(0.0, 1.0, (max(2, h // 8), max(2, w // 8)))
    grain = cv2.resize(low.astype(np.float32), (w, h), interpolation=cv2.INTER_CUBIC)
    grain = cv2.GaussianBlur(grain, (0, 0), 2.2) * 4.0
    rgb = DARK * (1.0 - turned[..., None]) + BODY * turned[..., None]
    rgb += (LIT - BODY) * np.clip(turned - 0.68, 0.0, 1.0)[..., None] * 2.2
    rgb += grain[..., None]
    facing = np.clip(-(normal[..., 0] * LIGHT[0] + normal[..., 1] * LIGHT[1]), 0.0, 1.0)
    edge = np.clip(1.0 - dist / 1.7, 0.0, 1.0)
    rgb += RIM * ((facing ** 2.2) * edge * (0.25 + turned * 0.65))[..., None]
    return np.clip(rgb, 0.0, 255.0)


def _save(path, rgb, mask):
    alpha = cv2.GaussianBlur(mask.astype(np.float64), (0, 0), 0.38)
    rgba = np.zeros((*mask.shape, 4), dtype=np.uint8)
    rgba[..., :3] = np.clip(rgb, 0, 255).astype(np.uint8)
    rgba[..., 3] = np.clip(alpha, 0, 255).astype(np.uint8)
    rgba[0, :, 3] = 0
    rgba[-1, :, 3] = 0
    rgba[:, 0, 3] = 0
    rgba[:, -1, 3] = 0
    Image.fromarray(rgba, "RGBA").save(path)


def _damage(rgb, mask, rng):
    """Add panel seams and tiny gouges without turning the fragment into UI."""
    ys, xs = np.nonzero(mask > 0)
    if not len(xs):
        return
    x0, x1 = int(xs.min()), int(xs.max())
    y0, y1 = int(ys.min()), int(ys.max())
    seam_x = rng.integers(x0 + 8, max(x0 + 9, x1 - 7))
    cv2.line(rgb, (int(seam_x), y0), (int(seam_x), y1), DARK * 0.72, 1)
    cv2.line(rgb, (int(seam_x) + 1, y0), (int(seam_x) + 1, y1), LIT * 0.58, 1)
    for _ in range(3):
        px = int(rng.integers(x0 + 3, max(x0 + 4, x1 - 2)))
        py = int(rng.integers(y0 + 3, max(y0 + 4, y1 - 2)))
        if mask[py, px] > 0:
            cv2.circle(rgb, (px, py), 1, DARK * 0.65, -1)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path("assets/world/debris"))
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    rng = np.random.default_rng(SEED)
    size = (96, 96)
    shapes = [
        [[(18, 26), (57, 18), (78, 31), (68, 58), (33, 70), (16, 48)]],
        [[(16, 68), (71, 22), (78, 29), (25, 77)], [(61, 28), (74, 40), (67, 47), (55, 35)]],
        [[(23, 19), (76, 27), (66, 72), (44, 61), (35, 39), (16, 31)]],
        [[(27, 30), (63, 17), (79, 40), (61, 78), (21, 68)]],
        [[(20, 51), (43, 19), (68, 28), (76, 65), (45, 78), (26, 68)]],
        [[(16, 30), (45, 22), (78, 40), (62, 75), (29, 68), (12, 48)]],
    ]
    for index, polygons in enumerate(shapes, start=1):
        mask = _mask(size, polygons)
        rgb = _shade(size, mask, rng)
        _damage(rgb, mask, rng)
        path = args.output / ("debris_%02d.png" % index)
        if path.exists() and not args.force:
            raise SystemExit("refusing to overwrite %s (use --force)" % path)
        _save(path, rgb, mask)
        print("wrote", path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
