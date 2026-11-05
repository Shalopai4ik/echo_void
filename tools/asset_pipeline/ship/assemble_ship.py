#!/usr/bin/env python3
"""Assemble the pixelart canvases into echo_void's ship assets.

The drawing is done in the pixelart MCP (see ship_c.png / flame_c.png there);
this only rotates them into the game's frame, pads them, derives the halo, and
measures what comes out - because the scene's collision polygons, hull_reach and
nozzle offset all have to agree with the art pixel for pixel.

Art is authored nose-up. The game needs nose on +X, so everything is rotated
clockwise: up -> right, and the flame's nozzle (authored on its top edge) lands
on its right edge, which is what the scene's centered=false + offset=(-w,-h/2)
pivot trick expects.

Run: python tools/assemble_ship.py
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
    fail, load_rgba, make_argparser, prepare_dir, require_dir, require_file,
    resolve_output, run, save_rgba)
import os
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter

HERE = _Path(__file__).resolve().parent
# The hand-drawn canvases, the game's asset directory, and where the assembled
# preview and the measured collision rings are written. All three are arguments:
# a rebuild goes into a scratch tree first and is diffed against res:// before
# anything is committed.
_p = make_argparser("assemble the ship canvases into echo_void's ship assets")
add_common(_p, want_input=False, want_output=False)
_p.add_argument("--canvas-dir", type=Path,
                default=TOOLS_ROOT / "asset_pipeline" / "ship" / "canvases",
                help="directory holding ship_c.png, flame_c.png and reference.png")
_p.add_argument("--shot", type=Path,
                default=TOOLS_ROOT / "asset_pipeline" / "ship" / "canvases",
                help="directory for the assembled preview and collision report")
_p.add_argument("-o", "--output", type=Path, default=ASSETS_DIR,
                help="directory to write the ship assets into")
_A = _p.parse_args()
LOG.verbose = _A.verbose
CANVAS_DIR = Path(_A.canvas_dir)
SHOT = Path(_A.shot)
OUT = Path(_A.output)
for _need in ("ship_c.png", "flame_c.png"):
    require_file(CANVAS_DIR / _need, "ship canvas")
if _A.dry_run:
    print("dry run: would assemble %s into %s" % (CANVAS_DIR, OUT))
    raise SystemExit(0)
prepare_dir(OUT, "asset directory", force=_A.force)

SPRITE_SCALE = 2.0     # the scale scenes/main.tscn draws Player/Sprite2D at
PAD = 6                # transparent margin so outline_sprite never gets clipped


def load(name):
    return np.asarray(Image.open(os.path.join(CANVAS_DIR, name)).convert("RGBA"))


def crisp(rgba):
    """Contour hygiene for the hand-drawn art: alpha {0,255} and a mirror-exact mask.

    Only the mask is touched, never a colour - the pixelart canvas is the art.
    """
    a = rgba[..., 3] >= 128
    w = a.shape[1]
    half = w // 2
    # the union is indexed from the axis outward on the left; the right half has
    # to be written back reversed or the two halves meet head-on and the sprite
    # folds onto itself
    union = a[:, :half] | a[:, w - half:][:, ::-1]
    a[:, :half] = union
    a[:, w - half:] = union[:, ::-1]
    out = rgba.copy()
    out[..., 3] = np.where(a, 255, 0).astype(np.uint8)
    return out


def face_right(rgba):
    return np.rot90(rgba, k=-1)


def pad_to(rgba, w, h):
    out = np.zeros((h, w, 4), np.uint8)
    y0 = (h - rgba.shape[0]) // 2
    x0 = (w - rgba.shape[1]) // 2
    out[y0:y0 + rgba.shape[0], x0:x0 + rgba.shape[1]] = rgba
    return out


def opaque_bbox(rgba):
    a = rgba[..., 3] > 8
    ys, xs = np.where(a)
    return int(xs.min()), int(ys.min()), int(xs.max()), int(ys.max())


def convex_hull(p):
    """Andrew's monotone chain: CollisionPolygon2D only takes convex rings."""
    pts = sorted(set((float(x), float(y)) for x, y in p))
    if len(pts) < 3:
        return [[round(x), round(y)] for x, y in pts]

    def half(seq):
        out = []
        for q in seq:
            while len(out) > 1 and (out[-1][0] - out[-2][0]) * (q[1] - out[-2][1]) \
                    - (out[-1][1] - out[-2][1]) * (q[0] - out[-2][0]) <= 0:
                out.pop()
            out.append(q)
        return out

    return [[round(x), round(y)] for x, y in half(pts)[:-1] + half(pts[::-1])[:-1]]


def collision(rgba):
    """Overlapping forward slabs of the silhouette, one convex ring each.

    A hull of "the wing region" is useless: the ship has forward canards as well
    as swept wings, so the hull bridges them and swallows a triangle of empty
    sky. Slabs follow the outline instead.
    """
    a = rgba[..., 3] > 8
    ys, xs = np.where(a)
    c = (rgba.shape[1] - 1) / 2.0
    r = (rgba.shape[0] - 1) / 2.0
    fwd = (xs - c) * SPRITE_SCALE
    lat = (ys - r) * SPRITE_SCALE
    slab, overlap = 26.0, 6.0
    lo, hi = np.floor(fwd.min()), np.ceil(fwd.max())
    pieces, n, x = {}, 0, lo
    while x < hi:
        x1 = min(x + slab, hi)
        keep = (fwd >= x - (overlap if x > lo else 0)) & (fwd <= x1 + (overlap if x1 < hi else 0))
        if keep.sum() >= 3:
            n += 1
            pieces["Hull%02d" % n] = convex_hull(list(zip(fwd[keep], lat[keep])))
        x = x1
    return pieces


def main():
    os.makedirs(SHOT, exist_ok=True)
    hull_up = crisp(load("ship_c.png"))
    flame_up = load("flame_c.png")

    x0, y0, x1, y1 = opaque_bbox(hull_up)
    # crop tight, not tight-plus-a-row: a lopsided crop moves the ship's own
    # axis away from the texture's centre line, and every probe, the plume
    # offset and the collision slabs are measured from that line
    hull = face_right(hull_up[y0:y1 + 1, x0:x1 + 1])
    hull = pad_to(hull, hull.shape[1] + PAD, hull.shape[0] + PAD)

    fx0, fy0, fx1, fy1 = opaque_bbox(flame_up)
    flame = face_right(flame_up[fy0:fy1 + 1, fx0:fx1 + 1])
    # the nozzle must sit on the texture's right edge and its axis on the vertical
    # centre, or the scene's pivot trick and scale.y both come apart
    fh, fw = flame.shape[:2]
    flame = pad_to(flame, fw + 4, max(fh, 1) + (1 if fh % 2 else 0))

    glow = np.asarray(Image.fromarray(flame).filter(ImageFilter.GaussianBlur(4))).astype(float)
    glow[..., :3] = np.clip(glow[..., :3] * 0.9 + np.array([8, 40, 96]), 0, 255)
    glow[..., 3] = np.clip(glow[..., 3] * 1.7, 0, 255)
    glow = glow.astype(np.uint8)

    core_mask = (flame[..., :3].mean(2) > 175) & (flame[..., 3] > 8)
    core = np.zeros_like(flame)
    core[core_mask] = flame[core_mask]

    for arr, name in ((hull, "fighter.png"), (flame, "engine_plume.png"),
                      (core, "engine_core.png"), (glow, "engine_glow.png")):
        Image.fromarray(arr, "RGBA").save(os.path.join(OUT, name))
        print(f"{name}: {arr.shape[1]}x{arr.shape[0]}")

    rows, cols = np.where(hull[..., 3] > 8)
    tail, nose = int(cols.min()), int(cols.max())
    # the axis is where the ship actually is, not where the texture's middle
    # happens to fall: it is the widest row of the middle third
    band = [(int((hull[r, :, 3] > 8).sum()), r) for r in range(int(rows.min()), int(rows.max()) + 1)
            if abs(r - hull.shape[0] / 2.0) < hull.shape[0] / 6.0]
    mid = max(band)[1]
    nozzle_x = round((tail - (hull.shape[1] - 1) / 2.0) * SPRITE_SCALE)
    pieces = collision(hull)
    allpts = [v for p in pieces.values() for v in p]

    off = 80                                    # room for the flame aft of the hull
    prev = Image.new("RGBA", (hull.shape[1] + off, hull.shape[0]), (14, 17, 24, 255))
    tl = tail + off
    prev.alpha_composite(Image.fromarray(glow), (tl - glow.shape[1] + 6, mid - glow.shape[0] // 2))
    prev.alpha_composite(Image.fromarray(flame), (tl - flame.shape[1] + 6, mid - flame.shape[0] // 2))
    prev.alpha_composite(Image.fromarray(core), (tl - core.shape[1] + 6, mid - core.shape[0] // 2))
    prev.alpha_composite(Image.fromarray(hull), (off, 0))
    prev.resize((prev.width * 4, prev.height * 4), Image.NEAREST).save(os.path.join(SHOT, "assembled.png"))

    with open(os.path.join(SHOT, "collision.txt"), "w", encoding="utf-8") as f:
        for name, p in pieces.items():
            f.write('[node name="%s" type="CollisionPolygon2D" parent="Player/Hull"]\n' % name)
            f.write("polygon = PackedVector2Array(" +
                    ", ".join("%d, %d" % (x, y) for x, y in p) + ")\n\n")

    print("NOZZLE = Vector2(%d, 0)" % nozzle_x)
    print("hull_reach = Vector2(%d, %d)" % (round(max(a[0] for a in allpts)),
                                            round(max(abs(a[1]) for a in allpts))))
    print("layer offset = Vector2(-%d, -%.1f)" % (flame.shape[1], flame.shape[0] / 2.0))
    print("hull content: cols %d..%d rows %d..%d centre row %d" % (tail, nose, rows.min(), rows.max(), mid))
    print("pieces:", len(pieces))

    # smoke_test.gd pokes individual pixels to prove the art is oriented, cut at
    # the nozzle and still carrying its engine; those coordinates belong to the
    # art, so emit them here instead of letting the test guess
    solid = hull[..., 3] > 200
    lum = hull[..., :3].mean(2)
    aft = max(tail, 0) + int((nose - tail) * 0.22)
    band = np.zeros_like(solid)
    band[max(mid - 22, 0):mid + 23, tail:aft] = True   # the engine band, not the wingtips
    cone_row = solid[mid, tail:aft]
    cone_x = tail + int(np.argmax(lum[mid, tail:aft])) if cone_row.any() else -1
    # the mouth is the darkest thing on the centre line at the very back and the
    # rim the brightest thing just in front of it: together they are the proof
    # that there is a nozzle to light, not just a flat tail painted black
    throat = lum[mid, tail:tail + 6]
    mouth_x = tail + int(np.argmin(throat)) if cone_row.any() else -1
    # the rim is the brightest metal between the throat and the wing root: the
    # search window has to clear the whole throat or it just finds more of it
    rim_band = lum[mid, tail + 6:tail + 48]
    rim_x = tail + 6 + int(np.argmax(rim_band)) if len(rim_band) else -1

    print("probes:")
    print("  nose      = Vector2(%d, %d)  alpha=%.2f" % (nose, mid, hull[mid, nose, 3] / 255))
    print("  off_axis  = Vector2(%d, %d)  alpha=%.2f" % (mid, hull.shape[0] - 2, hull[hull.shape[0] - 2, mid, 3] / 255))
    print("  behind    = Vector2(%d, %d) / Vector2(%d, %d)  alpha=%.2f/%.2f"
          % (max(tail - 3, 0), mid, max(tail - 1, 0), mid,
             hull[mid, max(tail - 3, 0), 3] / 255, hull[mid, max(tail - 1, 0), 3] / 255))
    print("  mouth     = Vector2(%d, %d)  v=%.2f" % (mouth_x, mid, lum[mid, mouth_x] / 255))
    print("  rim       = Vector2(%d, %d)  v=%.2f" % (rim_x, mid, lum[mid, rim_x] / 255))


if __name__ == "__main__":
    main()
