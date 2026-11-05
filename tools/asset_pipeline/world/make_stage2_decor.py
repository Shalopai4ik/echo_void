#!/usr/bin/env python3
"""Paint the decorative space content for echo_void stage 2.

Three families, all cut for a bare black sky and one light direction:

  wreck_0N.png       fragments of something manufactured: plate, strut, shard
  structure_0N.png   distant silhouettes - a broken ring arc, a hulk, a truss
  beacon_0N.png      rare glowing objects, add-blended, mostly light

The look is a rim-lit silhouette rather than a texture study: at the size these
are read - a few percent of the screen, against deep space - the only thing that
registers is where the light catches an edge. So the body of every object is a
smooth ramp from the dark side to the lit side, the surface variation is
low-frequency (a rock is not television static), and the rim is the brightest
thing on it.

Beacons are deliberately kept dim. A rare light in an empty void is the point;
a lens flare competing with the ship is not.

Everything is deterministic from one seed, padded so no sprite touches the border
of its crop, and verified by reading the finished files back off disk.

Run:  python tools/make_stage2_decor.py
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
import json
import os
from pathlib import Path

import cv2
import numpy as np
from PIL import Image

HERE = _Path(__file__).resolve().parent
OUT_DIR = ASSETS_DIR / "world"
REPORT = os.path.join(HERE, "world_art_report.json")
SEED = 20261102

# one star lights this system, and it sits behind and above the ship
LIGHT = np.array([-0.58, -0.81], dtype=np.float64)
LIGHT /= np.linalg.norm(LIGHT)

DARK = np.array([10, 14, 20], dtype=np.float64)      # the side that faces nothing
BODY = np.array([26, 36, 48], dtype=np.float64)      # what the void still bounces back
LIT = np.array([58, 76, 96], dtype=np.float64)       # the face the star reaches
RIM = np.array([150, 178, 204], dtype=np.float64)    # the edge that turns to the light
SPEC = np.array([214, 232, 246], dtype=np.float64)   # a glint off a hard corner
WARM = np.array([226, 168, 96], dtype=np.float64)    # somebody's window
CYAN = np.array([104, 196, 246], dtype=np.float64)
AMBER = np.array([246, 168, 96], dtype=np.float64)

_rng = np.random.default_rng(SEED)


def normals(mask, dist):
    """Outward normal per pixel: the gradient of 'how far am I from the edge'."""
    gy, gx = np.gradient(dist.astype(np.float32))
    n = np.stack([gx, gy], axis=-1)
    length = np.linalg.norm(n, axis=-1, keepdims=True)
    return np.divide(n, length, out=np.zeros_like(n), where=length > 1e-4)


def surface_field(size, gain):
    """Low-frequency variation, so a silhouette reads as a rock with sides rather
    than as a swatch of noise."""
    h, w = size[1], size[0]
    small = _rng.normal(0.0, 1.0, (max(2, h // 9), max(2, w // 9)))
    field = cv2.resize(small.astype(np.float32), (w, h), interpolation=cv2.INTER_CUBIC)
    field = cv2.GaussianBlur(field, (0, 0), max(1.0, min(w, h) / 26.0))
    return (field - field.mean()) * gain


def shade(size, mask, rim_gain=1.0, grain=7.0, dark=DARK, body=BODY, lit=LIT,
          rim=RIM):
    """Directional shading of a silhouette: a ramp across the light axis, a little
    surface, and a rim only where the edge genuinely turns toward the star."""
    h, w = size[1], size[0]
    dist = cv2.distanceTransform(mask, cv2.DIST_L2, 3)
    n = normals(mask, dist)
    ys, xs = np.mgrid[0:h, 0:w].astype(np.float64)
    axis = xs * LIGHT[0] + ys * LIGHT[1]
    turned = np.clip((axis - axis.min()) / max(axis.max() - axis.min(), 1.0), 0.0, 1.0)
    turned = turned ** 1.25

    base = dark[None, None, :] * (1.0 - turned[..., None]) \
        + body[None, None, :] * turned[..., None]
    base = base + (lit - body)[None, None, :] * np.clip(turned - 0.62, 0.0, 1.0)[..., None] * 2.6
    base = base + surface_field(size, grain)[..., None]

    facing = np.clip(-(n[..., 0] * LIGHT[0] + n[..., 1] * LIGHT[1]), 0.0, 1.0)
    edge = np.clip(1.0 - dist / 1.6, 0.0, 1.0)          # the outermost pixel and a half
    band = (facing ** 2.0) * edge * (0.35 + 0.65 * turned)
    img = base + rim[None, None, :] * (band * rim_gain)[..., None]

    # hard corners and spar tips catch more than a flat face
    tight = (edge > 0.55) & (facing > 0.72) & (turned > 0.5)
    img = img + SPEC[None, None, :] * (tight.astype(np.float64) * 0.5 * rim_gain)[..., None]
    return np.clip(img, 0.0, 255.0), dist


def soft_alpha(mask, blur=0.45):
    a = mask.astype(np.float64)
    if blur > 0:
        a = cv2.GaussianBlur(a, (0, 0), blur)
    return np.clip(a, 0.0, 255.0).astype(np.uint8)


def save(name, rgb, alpha, size):
    """Compose RGBA, keep the border clean, write the PNG."""
    w, h = size
    arr = np.zeros((h, w, 4), dtype=np.uint8)
    arr[..., :3] = np.clip(rgb, 0, 255).astype(np.uint8)
    arr[..., 3] = alpha
    arr[0, :, 3] = 0
    arr[-1, :, 3] = 0
    arr[:, 0, 3] = 0
    arr[:, -1, 3] = 0
    path = os.path.join(OUT_DIR, name)
    Image.fromarray(arr, "RGBA").save(path)
    return {"file": name, "size": [w, h], "path": path}


def rand_poly(cx, cy, r, points, squash=1.0, wobble=0.42):
    """An irregular closed outline: a circle with each vertex pushed around."""
    pts = []
    step = 2 * np.pi / points
    spin = _rng.uniform(0.0, 2 * np.pi)
    for i in range(points):
        a = spin + step * i + _rng.normal(0.0, step * wobble * 0.5)
        rad = r * _rng.uniform(1.0 - wobble, 1.0 + wobble * 0.7)
        pts.append((cx + np.cos(a) * rad, cy + np.sin(a) * rad * squash))
    return pts


def mask_of(size, polys):
    h, w = size[1], size[0]
    mask = np.zeros((h, w), dtype=np.uint8)
    for pts in polys:
        cv2.fillPoly(mask, [np.array(pts, dtype=np.int32)], 255)
    return mask


# --------------------------------------------------------------------- wrecks

def make_wrecks():
    """Small manufactured debris: a torn plate, two plates still sharing a seam,
    a bent strut, a shard."""
    size = (76, 76)
    shapes = [
        [[(14, 30), (40, 22), (58, 28), (54, 40), (60, 50), (34, 54), (16, 46)]],
        [[(12, 20), (44, 14), (50, 26), (20, 34)],
         [(26, 42), (58, 36), (64, 52), (34, 58)]],
        [[(16, 52), (58, 18), (62, 24), (22, 58)],
         [(30, 22), (44, 40), (38, 46), (24, 30)]],
        [rand_poly(38, 38, 21, 7, 1.0, 0.5)],
    ]
    out = []
    for i, polys in enumerate(shapes, start=1):
        mask = mask_of(size, polys)
        rgb, _ = shade(size, mask, rim_gain=1.15, grain=6.0)
        out.append(save("wreck_%02d.png" % i, rgb, soft_alpha(mask), size)
                   | {"kind": "wreck"})
    return out


# ----------------------------------------------------------------- structures

def make_structures():
    """Big, far, and only half readable: the shapes that give the void its scale."""
    out = []

    # 1 - a ring arc: a section of something built around a planet, with two
    # breaks in it so it is wreckage rather than machinery
    size = (256, 256)
    h, w = size
    ys, xs = np.mgrid[0:h, 0:w].astype(np.float64)
    c = np.array([w, h]) * 0.5
    rad = np.sqrt((xs - c[0]) ** 2 + (ys - c[1]) ** 2)
    ang = (np.arctan2(ys - c[1], xs - c[0]) + np.pi) % (2 * np.pi)
    r_in, r_out = 96.0, 120.0
    frac = (rad - r_in) / (r_out - r_in)
    shell = (frac > 0.0) & (frac < 1.0)
    arc = (ang > 0.45) & (ang < 3.6)
    gap = ((ang > 2.35) & (ang < 2.62)) | ((ang > 5.5) & (ang < 5.86))
    ribs = np.sin(ang * 11.0) > 0.90
    skin = (frac < 0.10) | (frac > 0.90)
    mask = np.zeros((h, w), dtype=np.uint8)
    mask[shell & arc & ~gap & (skin | ribs)] = 255
    # stubs where the ring broke off, so the ends are torn and not cut
    for a in (0.45, 2.35, 2.62, 3.6, 5.5, 5.86):
        x = int(c[0] + np.cos(a) * (r_in + 12))
        y = int(c[1] + np.sin(a) * (r_in + 12))
        cv2.line(mask, (x, y), (x + 7, y - 5), 255, 2)
    out.append(_structure("structure_01.png", size, mask, 256, windows=5))

    # 2 - a hulk: a long hull with a piece missing amidships, its windows still lit
    size = (320, 128)
    hull = [(14, 62), (34, 44), (150, 34), (166, 46), (166, 74), (150, 88), (34, 84), (14, 74)]
    aft = [(196, 44), (286, 50), (304, 62), (286, 82), (196, 84), (190, 64)]
    mask = mask_of(size, [hull, aft])
    cv2.rectangle(mask, (166, 56), (196, 70), 255, -1)          # the spine across the gap
    cv2.rectangle(mask, (296, 56), (312, 74), 255, -1)          # a pod on the tail
    out.append(_structure("structure_02.png", size, mask, 320, windows=9, row=64))

    # 3 - a truss, most of it gone
    size = (200, 200)
    mask = np.zeros((size[1], size[0]), dtype=np.uint8)
    cv2.rectangle(mask, (20, 86), (150, 95), 255, -1)
    cv2.rectangle(mask, (20, 111), (138, 120), 255, -1)
    for i in range(7):
        x = 26 + i * 17
        if i == 4:
            continue                                            # the missing bay
        cv2.line(mask, (x, 95), (x + 15, 111), 255, 2)
        cv2.line(mask, (x, 111), (x + 15, 95), 255, 2)
    cv2.rectangle(mask, (150, 74), (176, 132), 255, -1)         # what is left of the rig
    cv2.line(mask, (150, 100), (188, 92), 255, 2)
    out.append(_structure("structure_03.png", size, mask, 200, windows=2, row=103))
    return out


def _structure(name, size, mask, span, windows, row=None):
    rgb, dist = shade(size, mask, rim_gain=1.3, grain=5.0)
    # windows are the only proof that anybody was inside, so they go in a line
    # along the spine of the thing rather than anywhere the mask allows
    h, w = size[1], size[0]
    if windows:
        if row is not None:
            xs = np.arange(0, w)
            band = mask[row - 3:row + 2, :] > 0
            solid = xs[band.any(axis=0)]
            picks = _rng.choice(solid, size=min(windows, len(solid)), replace=False) \
                if len(solid) else []
            for x in picks:
                yy = row + int(_rng.integers(-1, 2))
                if mask[yy, x] == 0:
                    continue
                rgb[yy, x] = WARM
                rgb[max(0, yy - 1):yy + 2, max(0, x - 1):x + 2] += WARM * 0.16
        else:
            ys_, xs_ = np.nonzero((mask > 0) & (dist > 2.0))
            picks = _rng.choice(len(xs_), size=min(windows, len(xs_)), replace=False)
            for p in picks:
                x, y = int(xs_[p]), int(ys_[p])
                rgb[y, x] = WARM
                rgb[max(0, y - 1):y + 2, max(0, x - 1):x + 2] += WARM * 0.16
    return save(name, rgb, soft_alpha(mask, 0.5), size) | {"kind": "structure"}


# --------------------------------------------------------------------- beacons

def make_beacons():
    """Rare points of light. Alpha carries the intensity, so the add blend does
    the rest. Kept small and dim on purpose: these are the only thing out there
    that is looking back, and they must not compete with the ship for the frame."""
    out = []
    for name, tint, spikes, gain in [("beacon_01.png", CYAN, 4, 0.55),
                                     ("beacon_02.png", AMBER, 2, 0.42)]:
        size = (128, 128)
        h, w = size
        ys, xs = np.mgrid[0:h, 0:w].astype(np.float64)
        cx, cy = w * 0.5, h * 0.5
        dx, dy = xs - cx, ys - cy
        r = np.sqrt(dx * dx + dy * dy)
        core = np.exp(-(r / 2.4) ** 2)
        halo = np.exp(-(r / 11.0) ** 2) * 0.5
        wide = np.exp(-(r / 34.0) ** 2) * 0.12
        spike = np.zeros((h, w), dtype=np.float64)
        for k in range(spikes):
            a = np.pi * k / spikes + 0.2
            ux, uy = np.cos(a), np.sin(a)
            along = np.clip(dx * ux + dy * uy, 0, 26)
            across = np.abs(-dx * uy + dy * ux)
            spike += np.exp(-(across / 0.9) ** 2) * np.exp(-(along / 9.0))
        spike = np.clip(spike + spike[::-1, ::-1] * 0.6, 0.0, 1.0)
        lum = np.clip((core + halo + wide + spike * 0.55) * gain, 0.0, 1.0)
        # the centre keeps a little of its colour instead of blowing out to white
        hot = np.clip(core * 0.55, 0, 1)
        rgb = (tint[None, None, :] * (1 - hot[..., None])
               + np.array([236.0, 242.0, 250.0]) * hot[..., None]) * (lum * 255.0)[..., None]
        alpha = (lum * 255.0).astype(np.uint8)
        out.append(save(name, rgb, alpha, size) | {"kind": "beacon"})
    return out


# ---------------------------------------------------------------------- report

def verify(entries):
    """Read the files back off disk: nothing may touch the crop edge, and nothing
    may be bright enough to compete with the ship."""
    report = []
    for e in entries:
        im = np.array(Image.open(os.path.join(OUT_DIR, e["file"])))
        a = im[..., 3] / 255.0
        rgb = im[..., :3]
        border = max(a[0].max(), a[-1].max(), a[:, 0].max(), a[:, -1].max())
        lit = rgb[a > 0.55]
        mean = lit.mean(axis=0) if len(lit) else np.zeros(3)
        solid = rgb[a > 0.9]
        body = solid.mean(axis=0) if len(solid) else np.zeros(3)
        report.append({**e,
                       "border_alpha": round(float(border), 4),
                       "lit_mean_rgb": [round(float(v), 1) for v in mean],
                       "body_mean_rgb": [round(float(v), 1) for v in body],
                       "lit_peak": round(float(lit.max()) if len(lit) else 0.0, 1),
                       "coverage": round(float((a > 0.5).mean()), 4)})
    return report


def main(argv=None) -> int:
    global SEED, OUT_DIR, REPORT, _rng
    parser = make_argparser("paint echo_void's decorative space content")
    add_common(parser, want_input=False, want_output=False)
    parser.add_argument("-o", "--output", type=Path, default=ASSETS_DIR / "world",
                        help="directory to write the decor into")
    parser.add_argument("-c", "--config", type=Path, default=None,
                        help="JSON manifest to write (defaults next to the output)")
    parser.add_argument("--seed", type=int, default=SEED,
                        help="the one number the whole set is derived from")
    args = parser.parse_args(argv)
    LOG.verbose = args.verbose
    SEED = args.seed
    _rng = np.random.default_rng(SEED)
    OUT_DIR = Path(args.output)
    REPORT = Path(args.config) if args.config else OUT_DIR.parent / "world_art_report.json"
    LOG.step("seed %d" % SEED)
    LOG.step("writing to %s" % OUT_DIR)
    if args.dry_run:
        print("dry run: would write the decor set to %s with seed %d"
              % (OUT_DIR, SEED))
        return 0
    resolve_output(OUT_DIR, "decor directory", force=args.force, dry_run=False)
    if OUT_DIR.exists() and not args.force:
        fail("decor directory already exists: %s (pass --force to overwrite)" % OUT_DIR)
    os.makedirs(OUT_DIR, exist_ok=True)
    entries = make_wrecks() + make_structures() + make_beacons()
    report = verify(entries)
    REPORT.parent.mkdir(parents=True, exist_ok=True)
    with open(REPORT, "w", encoding="utf-8") as fh:
        json.dump({"seed": SEED, "light": [round(float(v), 3) for v in LIGHT],
                   "files": report}, fh, indent=1)
    for r in report:
        print("%-18s %-10s %-10s border=%.3f body=%s lit=%s peak=%.0f cover=%.3f" % (
            r["file"], r["kind"], str(r["size"]), r["border_alpha"],
            r["body_mean_rgb"], r["lit_mean_rgb"], r["lit_peak"], r["coverage"]))
    bad = [r["file"] for r in report if r["border_alpha"] > 0.001]
    print("wrote %d files to %s" % (len(report), OUT_DIR))
    print("edge-clean: %s" % ("yes" if not bad else "NO -> " + ", ".join(bad)))
    if bad:
        LOG.error("sprites touch their own crop edge: %s" % ", ".join(bad))
        return 3
    return 0


if __name__ == "__main__":
    run(main)

