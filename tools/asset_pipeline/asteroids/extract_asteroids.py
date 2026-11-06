#!/usr/bin/env python3
"""Cut the asteroid block out of an asset sheet and emit sprites + collision shapes.

The sheet is RGBA, and its alpha channel is the thing that actually separates a
stone from the nebula wash: the wash and the soft drop shadow under each rock are
both semi-transparent black (alpha ~150-200) while the rock body is near opaque
(~250). Thresholding luminance instead gets it wrong twice over - the shadow is
darker than the lit side of the stone, so a brightness cut either swallows the
shadow or bites the highlight off the rock. So: threshold the sheet's own alpha,
close over the bright rim speckles, fill each outer contour so the interior is
solid, and keep the colour exactly as the sheet stored it, gamma lifted because
the art is lit for a pale wash and has to read against a black sky.

Collision comes from that same filled silhouette: simplify -> ear-clip triangulate
-> greedily merge triangles while the result stays convex. Godot only accepts
convex polygons on a RigidBody2D, so the decomposition is the point of the
exercise; every piece is rasterised back over the silhouette and the IoU is
reported.

    python tools/extract_asteroids.py <sheet.png> <out_dir> [shapes.gd] [report.json]
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
import json
import os
import sys

import cv2
import numpy as np

# x0, y0, x1, y1 of the "Астероиды" block in the 1536x1024 sheet
CROP = (585, 296, 990, 528)
ROCK_ALPHA = 235       # stone is near opaque, wash and shadow are not
MIN_AREA = 120         # specks below this are noise, not rocks
BRIDGE = 7             # closing that hops the bright rim speckles
MIN_LOBE = 0.10        # a piece smaller than this share of the rock is noise
GAMMA = 0.62           # lift: pale-wash art onto a black sky
SIMPLIFY = 0.018       # approxPolyDP epsilon as a fraction of perimeter
MAX_PIECES = 8         # most pieces a rock silhouette may break into
PAD = 2                # transparent border kept around every sprite


def silhouette(alpha):
    m = (alpha >= ROCK_ALPHA).astype(np.uint8) * 255
    m = cv2.morphologyEx(m, cv2.MORPH_OPEN, np.ones((3, 3), np.uint8))
    return cv2.morphologyEx(m, cv2.MORPH_CLOSE, np.ones((BRIDGE, BRIDGE), np.uint8))


def solid_of(mask):
    """The mask with its holes filled, plus the contours worth keeping."""
    cnts, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    if not cnts:
        return mask, []
    biggest = max(cv2.contourArea(c) for c in cnts)
    keep = [c for c in cnts if cv2.contourArea(c) >= max(biggest * MIN_LOBE, 8.0)]
    out = np.zeros_like(mask)
    cv2.drawContours(out, keep, -1, 255, cv2.FILLED)
    return out, keep


def tile_rgba(src, solid):
    """Opaque interior; the outermost ring keeps the sheet's own anti-aliasing."""
    inner = cv2.erode(solid, np.ones((3, 3), np.uint8)) > 0
    on = solid > 0
    a = np.where(inner, 1.0, np.where(on, src[:, :, 3].astype(np.float32) / 255.0, 0.0))
    rgb = 255.0 * np.power(np.clip(src[:, :, 0:3], 0, 255) / 255.0, GAMMA)
    out = np.dstack([rgb, a * 255.0]).astype(np.uint8)
    out[~on] = 0
    return out


def signed_area(poly):
    p = np.asarray(poly, np.float64)
    x, y = p[:, 0], p[:, 1]
    return float(0.5 * np.sum(x * np.roll(y, -1) - np.roll(x, -1) * y))


# --------------------------------------------------------------- decomposition

def pieces(poly):
    """Greedy convex decomposition of a simple polygon."""
    tris = ear_clip(poly)
    if tris is None:
        return None
    parts = [list(t) for t in tris]
    while 1 < len(parts) <= MAX_PIECES:
        merged = False
        for i in range(len(parts)):
            for j in range(i + 1, len(parts)):
                u = join(parts[i], parts[j])
                if u is not None and is_convex(u):
                    parts[i] = u
                    parts.pop(j)
                    merged = True
                    break
            if merged:
                break
        if not merged:
            break
    for p in parts:
        drop_collinear(p)
    parts = [p for p in parts if len(p) >= 3]
    if not 0 < len(parts) <= MAX_PIECES:
        return None
    # nothing above is allowed to fail silently: a concave piece on a
    # RigidBody2D is a physics bug, not a visual one
    return parts if all(is_convex(p) for p in parts) else None


def ear_clip(poly):
    if len(poly) < 3:
        return None
    idx = list(range(len(poly)))
    tris = []
    while len(idx) > 3:
        m = len(idx)
        for i in range(m):
            a, b, c = idx[(i - 1) % m], idx[i], idx[(i + 1) % m]
            if cross(poly[a], poly[b], poly[c]) <= 1e-9:
                continue
            if any(point_in(poly[k], poly[a], poly[b], poly[c])
                   for k in idx if k not in (a, b, c)):
                continue
            tris.append((poly[a], poly[b], poly[c]))
            idx.pop(i)
            break
        else:
            return None
    if len(idx) == 3:
        tris.append((poly[idx[0]], poly[idx[1]], poly[idx[2]]))
        return tris
    return None


def join(p, q):
    """Union of two polygons sharing exactly one oppositely-traversed edge."""
    for i in range(len(p)):
        a, b = p[i], p[(i + 1) % len(p)]
        for j in range(len(q)):
            if q[j] == a and q[(j + 1) % len(q)] == b:
                return None                      # same direction: not a boundary pair
            if q[j] == b and q[(j + 1) % len(q)] == a:
                # rotate each ring to start on the shared edge, then splice
                p2 = p[i + 1:] + p[:i + 1]       # b ... a
                q2 = q[j + 1:] + q[:j + 1]       # a ... b
                return p2[:-1] + q2[:-1]
    return None


def cross(o, a, b):
    return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])


def is_convex(poly, tol=1e-6):
    sign = 0
    n = len(poly)
    for i in range(n):
        c = cross(poly[i], poly[(i + 1) % n], poly[(i + 2) % n])
        if abs(c) <= tol:
            continue
        if sign == 0:
            sign = 1 if c > 0 else -1
        elif (c > 0) != (sign > 0):
            return False
    return sign != 0


def point_in(pt, a, b, c):
    d = [cross(a, b, pt), cross(b, c, pt), cross(c, a, pt)]
    return not (min(d) < -1e-9 and max(d) > 1e-9)


def drop_collinear(poly):
    i = 0
    while i < len(poly) - 2:
        n = len(poly)
        if abs(cross(poly[(i - 1) % n], poly[i], poly[(i + 1) % n])) < 1e-6:
            poly.pop(i)
            i = max(i - 1, 0)
        else:
            i += 1


def simplify(c, eps_scale=1.0):
    approx = cv2.approxPolyDP(c, cv2.arcLength(c, True) * SIMPLIFY * eps_scale, True)
    poly = [(float(px), float(py)) for px, py in approx.reshape(-1, 2)]
    if signed_area(poly) < 0:
        poly.reverse()
    return poly


def decompose(lobes, eps_scale=1.0):
    """Convex pieces for every kept outline, or the hull of all of them.

    `eps_scale` loosens or tightens the outline simplification: a silhouette
    that needs more pieces than a body can carry is worth retrying at a coarser
    epsilon, which drops the vertices that were splitting it.
    """
    out, note = [], ""
    for c in lobes:
        p = pieces(simplify(c, eps_scale))
        if p is None:
            note = "convex-hull"
            break
        out += p
    if note or not 0 < len(out) <= MAX_PIECES:
        all_pts = np.vstack([c.reshape(-1, 2) for c in lobes]).astype(np.int32)
        hull = cv2.convexHull(all_pts).reshape(-1, 2)
        out, note = [[(float(px), float(py)) for px, py in hull]], "convex-hull"
    return out, note


def iou_of(polys, mask):
    cover = np.zeros(mask.shape, np.uint8)
    pts = [np.asarray(p, np.int32).reshape(-1, 1, 2) for p in polys if len(p) >= 3]
    if pts:
        cv2.fillPoly(cover, pts, 1)
    union = np.logical_or(cover > 0, mask > 0).sum()
    inter = np.logical_and(cover > 0, mask > 0).sum()
    return float(inter) / float(max(union, 1))


def emit_gd(report, path, by="tools/extract_asteroids.py"):
    """The shapes as a GDScript constant, so no JSON has to survive the export."""
    lines = [
        "extends RefCounted",
        "## Generated by %s - do not edit by hand." % by,
        "## Convex collision pieces per rock, in texture pixels measured from the",
        "## centre the Sprite2D draws at. Scale them by the sprite scale to match.",
        "",
        "const SHAPES := {",
    ]
    for r in report:
        lines.append('\t"%s": [' % r["file"].rsplit(".", 1)[0])
        for p in r["shapes"]:
            # a plain Array of Vector2: PackedVector2Array is not a constant
            # expression in GDScript, so the body packs it at runtime instead
            pts = ", ".join("Vector2(%g, %g)" % xy for xy in p)
            lines.append("\t\t[%s]," % pts)
        lines.append("\t],")
    lines += ["}", ""]
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines))


# ------------------------------------------------------------------------ main

def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 1
    sheet, out_dir = sys.argv[1], sys.argv[2]
    shapes = sys.argv[3] if len(sys.argv) > 3 else os.path.join(
        os.path.dirname(out_dir.rstrip("\\/")), "asteroid_shapes.gd")
    report_path = sys.argv[4] if len(sys.argv) > 4 else os.path.join(out_dir, "asteroids.json")
    os.makedirs(out_dir, exist_ok=True)
    raw = cv2.imread(sheet, cv2.IMREAD_UNCHANGED)
    if raw is None:
        print("cannot read", sheet)
        return 1
    if raw.ndim != 3 or raw.shape[2] != 4:
        print("expected an RGBA sheet, got", raw.shape)
        return 1

    x0, y0, x1, y1 = CROP
    block = raw[y0:y1, x0:x1]
    mask = silhouette(block[:, :, 3])
    padded = cv2.copyMakeBorder(block, PAD, PAD, PAD, PAD,
                                cv2.BORDER_CONSTANT, value=(0, 0, 0, 0))
    n, lab, stats, _ = cv2.connectedComponentsWithStats(mask, 8)

    report = []
    dropped = []
    for i in range(1, n):
        x, y, w, h, area = stats[i]
        if area < MIN_AREA:
            continue
        if x <= 1 or y <= 1 or x + w >= mask.shape[1] - 1 or y + h >= mask.shape[0] - 1:
            dropped.append(("touches crop border", int(area)))
            continue

        comp = (lab[y:y + h, x:x + w] == i).astype(np.uint8) * 255
        solid, lobes = solid_of(comp)
        box = np.zeros((h + 2 * PAD, w + 2 * PAD), np.uint8)
        box[PAD:PAD + h, PAD:PAD + w] = solid          # same offset as the tile
        tile = tile_rgba(padded[y:y + h + 2 * PAD, x:x + w + 2 * PAD], box)
        dec, note = decompose(lobes)
        outline = sum(len(simplify(c)) for c in lobes)

        name = "asteroid_%02d" % (len([r for r in report]) + 1)
        cv2.imwrite(os.path.join(out_dir, name + ".png"), tile)

        # contour points are relative to the component bbox, the tile adds PAD
        cx, cy = (w + 2 * PAD) / 2.0, (h + 2 * PAD) / 2.0
        local = [[(round(px + PAD - cx, 2), round(py + PAD - cy, 2)) for px, py in p]
                 for p in dec]
        report.append({
            "file": name + ".png", "size": [int(w + 2 * PAD), int(h + 2 * PAD)],
            "outline": outline, "pieces": len(local),
            "iou": round(iou_of(dec, solid), 3), "note": note, "shapes": local,
        })

    with open(report_path, "w", encoding="utf-8") as f:
        json.dump(report, f, ensure_ascii=False, indent=1)
    emit_gd(report, shapes)

    for r in report:
        print("%s size=%-9s outline=%-3d pieces=%-2d iou=%.3f %s"
              % (r["file"], "x".join(map(str, r["size"])), r["outline"],
                 r["pieces"], r["iou"], r["note"]))
    for why, area in dropped:
        print("-  dropped (%s) area %d" % (why, area))
    print("extracted", len(report), "rocks ->", out_dir)
    return 0


if __name__ == "__main__":
    sys.exit(main())
