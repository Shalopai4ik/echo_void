#!/usr/bin/env python3
"""Cut a whole-rock sprite sheet into the belt's asteroid sprites + collision shapes.

`extract_asteroids.py` crops one hard-coded block out of one hard-coded plate.
This tool is the other half of the same job: it takes a sheet that holds a whole
catalogue of separate rocks on transparency - the sort of sheet an art pass
hands over - finds every rock on it, and cuts the N largest into the shipped
`asteroid_NN.png` family.

Two decisions are worth knowing about:

**Scale.** The belt multiplies a texture by `px_scale` and derives mass from the
collision area (`scripts/obstacles/rock.gd`), so a sprite's
pixel size *is* a gameplay number, not a display choice. The sheet's rocks are
100-370 px across; shipping them as they are would put boulders the size of the
screen in the belt. So the rocks are ranked by area and dropped onto a geometric
size ladder between `--long-max` and `--long-min` (76 to 20 px by default, the
range the belt was tuned against): the biggest rock on the sheet becomes the
biggest sprite, the twentieth becomes the twentieth, and the aspect ratio of each
rock is kept.

**Cut quality.** The sheet is RGBA and its alpha is the silhouette, so that is
what gets threshed. The downscale is done premultiplied and with a Lanczos
filter, then divided back out - resampling straight RGBA averages the colour of
fully transparent pixels into the rim and leaves a dark fringe around every
rock. The colour is gamma-lifted (0.8) because the sheet is lit for a neutral
backdrop and has to read as a lit stone against a near-black sky, and the lift is
calibrated to the brightness the existing sprites already have.

Collision comes from the finished sprite's own silhouette, through the same
ear-clip / greedy-merge decomposition `extract_asteroids.py` uses, capped at the
six pieces the belt's collision table carries. Nothing is written until
every rock has been cut, and `--dry-run` writes nothing at all.

    python tools/asset_pipeline/asteroids/cut_asteroid_sheet.py \\
        -i <sheet.png> -o assets/asteroids --force

`--force` is required to replace existing files. The sheet itself is not in the
repository - it is art input that lives wherever the artist put it - so it is
always a command-line argument.
"""

# --- pipeline layout: every path below derives from this file, not the machine ---
# The art tools used to hard-code C:\\Users\\<someone>\\... They now locate the
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
    LOG, SCRIPTS_DIR, add_common, fail, load_rgba, make_argparser, run,
    save_rgba)
from asset_pipeline.asteroids.extract_asteroids import (  # noqa: E402
    decompose, emit_gd, iou_of, solid_of)
from pathlib import Path  # noqa: E402
import json  # noqa: E402

import cv2  # noqa: E402
import numpy as np  # noqa: E402
from PIL import Image  # noqa: E402

HERE = _Path(__file__).resolve().parent
MANIFEST = HERE.parent / "manifests" / "asteroids_report.json"
SHAPES = SCRIPTS_DIR / "asteroid_shapes.gd"

ROCK_ALPHA = 200    # the sheet's rock body; its soft rim and any wash are lower
MIN_AREA = 2000     # a 20 px sprite carries ~250 px of stone: below this it is debris
EDGE_OPEN = 3       # drops single-pixel sparks off the silhouette
EDGE_CLOSE = 3      # hops the speckles inside a lit crater rim
KEEP_RIM = 7        # dilation that keeps each rock's own anti-aliased edge
PAD = 2             # transparent border kept around every sprite, as shipped
GAMMA = 0.8         # lift: sheet lit for a backdrop, sprite drawn against a void
SHAPE_NODES = 6     # pieces per rock in scripts/asteroid_shapes.gd
# Simplification scales to try, in order, before a rock is judged too ragged.
EPS_STEPS = (1.0, 0.7, 1.4, 0.5, 2.0)
COUNT = 20          # sprites in assets/asteroids/
LONG_MAX = 76       # px, the biggest sprite the belt was balanced with
LONG_MIN = 20       # px, the smallest


def silhouette(alpha):
    """The stone's outline, without the sparks the renderer left around it."""
    m = (alpha >= ROCK_ALPHA).astype(np.uint8) * 255
    m = cv2.morphologyEx(m, cv2.MORPH_OPEN, np.ones((EDGE_OPEN, EDGE_OPEN), np.uint8))
    return cv2.morphologyEx(m, cv2.MORPH_CLOSE, np.ones((EDGE_CLOSE, EDGE_CLOSE), np.uint8))


def find_rocks(sheet, count):
    """Every separate stone worth cutting, largest first, as (area, bbox, label).

    A component that touches the sheet border is dropped rather than trimmed: a
    rock the artist let run off the edge has no outline to cut.
    """
    mask = silhouette(sheet[:, :, 3])
    n, lab, stats, _cent = cv2.connectedComponentsWithStats(mask, 8)
    h, w = mask.shape
    kept, dropped = [], []
    for i in range(1, n):
        x, y, cw, ch, area = stats[i]
        if area < MIN_AREA:
            continue
        if x <= 1 or y <= 1 or x + cw >= w - 1 or y + ch >= h - 1:
            dropped.append(("touches the sheet border", int(area), (int(x), int(y))))
            continue
        kept.append((int(area), (int(x), int(y), int(cw), int(ch)), i))
    kept.sort(key=lambda r: r[0], reverse=True)
    if len(kept) < count:
        fail("only %d rocks of %d px or more on the sheet, %d needed"
             % (len(kept), MIN_AREA, count))
    for why, area, at in dropped:
        LOG.step("dropped %s: area %d at %s" % (why, area, at))
    return kept, lab


def cut(sheet, box, label, labels):
    """One rock, trimmed to its own ink (the soft rim included).

    Pixels of anything else inside the rock's bounding box - a neighbour's
    corner, a loose speck of debris - are dropped, so a sprite never carries a
    fragment that the collision shape does not cover.
    """
    x, y, w, h = box
    tile = sheet[y:y + h, x:x + w].copy()
    own = cv2.dilate((labels[y:y + h, x:x + w] == label).astype(np.uint8),
                     np.ones((KEEP_RIM, KEEP_RIM), np.uint8)) > 0
    tile[~own] = 0
    ys, xs = np.nonzero(tile[:, :, 3])
    if xs.size == 0:
        fail("empty rock at %s" % (box,))
    return tile[ys.min():ys.max() + 1, xs.min():xs.max() + 1]


def resize_rgba(src, width, height):
    """Lanczos downscale that does not darken the rim.

    Resampling straight RGBA averages the colour of transparent pixels (black)
    into every edge, which draws a dark fringe around the rock. Premultiplying
    first removes that term, and dividing the result back out restores the colour.
    """
    alpha = src[:, :, 3].astype(np.float32) / 255.0
    planes = [Image.fromarray(src[:, :, i].astype(np.float32) * alpha, mode="F")
              .resize((width, height), Image.LANCZOS) for i in range(3)]
    av = np.asarray(Image.fromarray(alpha, mode="F").resize((width, height), Image.LANCZOS),
                    np.float32)
    av = np.clip(av, 0.0, 1.0)
    out = np.empty((height, width, 4), np.float32)
    for i in range(3):
        out[:, :, i] = np.asarray(planes[i], np.float32) / np.maximum(av, 1e-4)
    out[:, :, 3] = av * 255.0
    return np.clip(np.round(out), 0.0, 255.0).astype(np.uint8)


def lift(sprite):
    """Gamma-lift the colour, leave the alpha alone."""
    sprite = sprite.copy()
    rgb = np.clip(sprite[:, :, :3] / 255.0, 0.0, 1.0)
    sprite[:, :, :3] = np.clip(np.round(255.0 * np.power(rgb, GAMMA)), 0, 255)
    return sprite


def pad(sprite):
    """Centre the rock in its own transparent border, as the shipped sprites are."""
    return cv2.copyMakeBorder(sprite, PAD, PAD, PAD, PAD,
                              cv2.BORDER_CONSTANT, value=(0, 0, 0, 0))


def collision(sprite):
    """Convex pieces + IoU for a finished sprite, measured from its own centre.

    None when the silhouette cannot be covered by `SHAPE_NODES` convex pieces.
    Such a rock is skipped rather than given a hull: a hull over a deep concave
    bite is a stone the ship stops against in open space.
    """
    mask = silhouette(sprite[:, :, 3])
    solid, lobes = solid_of(mask)
    if not lobes:
        fail("a rock cut to %dx%d lost its outline" % (sprite.shape[1], sprite.shape[0]))
    for eps in EPS_STEPS:
        dec, note = decompose(lobes, eps)
        if note or len(dec) > SHAPE_NODES:
            continue
        cx, cy = sprite.shape[1] / 2.0, sprite.shape[0] / 2.0
        local = [[(round(px - cx, 2), round(py - cy, 2)) for px, py in p] for p in dec]
        return local, iou_of(dec, solid)
    return None


def ladder(count, long_max, long_min):
    """Long side per rank: the biggest rock gets `long_max`, the last `long_min`.

    Geometric, not linear: stone size reads as a ratio, and the shipped set
    climbs 76 -> 20 the same way.
    """
    if count == 1:
        return [long_max]
    step = (long_min / long_max) ** (1.0 / (count - 1))
    return [long_max * step ** i for i in range(count)]


def target_size(rock, long_side):
    """Aspect-preserving fit of `rock` so its long side is `long_side` px."""
    h, w = rock.shape[:2]
    scale = long_side / float(max(w, h))
    return max(6, int(round(w * scale))), max(6, int(round(h * scale)))


def main(argv=None) -> int:
    parser = make_argparser("cut a whole-rock sprite sheet into asteroid sprites")
    add_common(parser)
    parser.add_argument("--shapes", type=Path, default=SHAPES,
                        help="GDScript table of collision pieces to write")
    parser.add_argument("--manifest", type=Path, default=MANIFEST,
                        help="JSON report to write")
    parser.add_argument("--count", type=int, default=COUNT,
                        help="how many sprites to cut, biggest rocks first")
    parser.add_argument("--long-max", type=int, default=LONG_MAX,
                        help="long side of the biggest sprite, in px")
    parser.add_argument("--long-min", type=int, default=LONG_MIN,
                        help="long side of the smallest sprite, in px")
    args = parser.parse_args(argv)
    LOG.verbose = args.verbose

    if args.input is None:
        fail("no sheet given: pass -i/--input <sheet.png>")
    if args.output is None:
        fail("no destination given: pass -o/--output <sprite directory>")
    if args.count < 1:
        fail("--count must be at least 1")
    if not 0 < args.long_min <= args.long_max:
        fail("--long-min must be positive and no larger than --long-max")

    sheet = load_rgba(Path(args.input), "asteroid sheet")
    LOG.step("sheet %s, %dx%d" % (Path(args.input).name, sheet.shape[1], sheet.shape[0]))
    candidates, labels = find_rocks(sheet, args.count)
    sizes = ladder(args.count, args.long_max, args.long_min)

    # every rock is cut and measured before a single file is written: a sheet that
    # runs out of usable stones must not leave half a belt behind
    cut_rocks = []
    for area, box, label in candidates:
        if len(cut_rocks) == args.count:
            break
        rank = len(cut_rocks)
        rock = cut(sheet, box, label, labels)
        # the border is part of the sprite, so the stone itself is that much shorter
        art_long = max(6.0, sizes[rank] - 2.0 * PAD)
        width, height = target_size(rock, art_long)
        sprite = pad(lift(resize_rgba(rock, width, height)))
        shape = collision(sprite)
        if shape is None:
            LOG.step("skipped the %dx%d rock at %s: more than %d collision pieces"
                     % (box[2], box[3], box[:2], SHAPE_NODES))
            continue
        cut_rocks.append(("asteroid_%02d" % (rank + 1), sprite, shape[0], shape[1], box, area))

    if len(cut_rocks) < args.count:
        fail("only %d of the %d rocks on the sheet can be cut into %d convex pieces"
             % (len(cut_rocks), len(candidates), SHAPE_NODES))

    report = []
    for name, sprite, pieces, iou, box, area in cut_rocks:
        report.append({
            "file": name + ".png",
            "size": [int(sprite.shape[1]), int(sprite.shape[0])],
            "outline": sum(len(p) for p in pieces),
            "pieces": len(pieces),
            "iou": round(iou, 3),
            "note": "",
            "shapes": pieces,
        })
        LOG.info("%s %2dx%-2d from %3dx%-3d (area %6d) pieces=%d iou=%.3f"
                 % (name, sprite.shape[1], sprite.shape[0],
                    box[2], box[3], area, len(pieces), iou))

    if args.dry_run:
        LOG.info("dry run: %d rocks cut, nothing written" % len(report))
        return 0

    out_dir = Path(args.output)
    out_dir.mkdir(parents=True, exist_ok=True)
    for name, sprite, _pieces, _iou, _box, _area in cut_rocks:
        save_rgba(out_dir / (name + ".png"), sprite, force=args.force, what=name)

    Path(args.manifest).parent.mkdir(parents=True, exist_ok=True)
    with open(args.manifest, "w", encoding="utf-8", newline="\n") as f:
        json.dump(report, f, ensure_ascii=False, indent=1)
    emit_gd(report, str(args.shapes),
            by="tools/asset_pipeline/asteroids/cut_asteroid_sheet.py")

    names = {r["file"] for r in report}
    extra = [p.name for p in sorted(out_dir.glob("asteroid_*.png")) if p.name not in names]
    if extra:
        LOG.warn("%d sprite(s) in %s are not in the report: %s"
                 % (len(extra), out_dir, ", ".join(extra[:5])))
    LOG.info("cut %d rocks -> %s" % (len(report), out_dir))
    LOG.info("shapes  -> %s" % args.shapes)
    LOG.info("report  -> %s" % args.manifest)
    return 0


if __name__ == "__main__":
    run(main)