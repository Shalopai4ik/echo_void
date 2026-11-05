"""Prepare the echo_void background assets.

The plates are authored 1672x941 frames, not tiles, so they are never repeated
edge to edge. Instead:
  * base_tile.png      - genuinely seamless low-frequency haze, palette sampled
                         from background.png, used for the infinite base layer
  * *_chunk.png        - the authored plates with feathered alpha so they can be
                         scattered as large decor without any visible border
  * nebula_puff_NN.png - crops of the nebula plate, again feathered, for variety
  * sprites/           - the cut-out objects, copied as-is
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
import numpy as np, cv2, os, sys, json, shutil
from pathlib import Path
from scipy.ndimage import gaussian_filter
from PIL import Image

from asset_pipeline.background.seamless_tile import periodic, seam
# The plates the background ladder was cut from and the destination the game
# imports. Both are arguments, so a caller can rebuild into a scratch tree first
# and diff it against the shipped assets before touching res://.
_p = make_argparser(
    "prepare assets/space_bg from the cut background plates")
add_common(_p, want_input=False, want_output=False, want_config=False,
           want_manifest=False)
_p.add_argument("-i", "--input", type=Path, default=PLATE_DIR,
                help="directory holding background.png, nebula.png, stars_*")
_p.add_argument("-o", "--output", type=Path, default=ASSETS_DIR / "space_bg",
                help="directory to write the prepared assets into")
_A = _p.parse_args()
LOG.verbose = _A.verbose
SRC = Path(_A.input)
DST = Path(_A.output)
require_dir(SRC, "plate directory")
if _A.dry_run:
    print("dry run: would prepare %s into %s" % (SRC, DST))
    raise SystemExit(0)
prepare_dir(DST, "space_bg directory", force=_A.force)
os.makedirs(DST, exist_ok=True)
os.makedirs(os.path.join(DST, 'sprites'), exist_ok=True)


def load(p):
    return np.array(Image.open(p).convert('RGBA')).astype(np.float32) / 255.0


def save(p, rgba):
    Image.fromarray((np.clip(rgba, 0, 1) * 255).astype(np.uint8)).save(p, optimize=True)


def feather(h, w, border, power=1.0):
    """alpha ramp that is 1 in the middle and 0 at the very edge"""
    x = np.linspace(0, 1, w, dtype=np.float32)[None, :]
    y = np.linspace(0, 1, h, dtype=np.float32)[:, None]
    ex = np.minimum(x, 1 - x) * (w / border)
    ey = np.minimum(y, 1 - y) * (h / border)
    a = np.clip(np.minimum(ex, ey), 0, 1) ** power
    return a * a * (3 - 2 * a)


# ---------------------------------------------------------------- 1. base tile
bg = load(os.path.join(SRC, 'background.png'))
lum = (bg[..., :3] * np.array([0.2126, 0.7152, 0.0722], np.float32)).sum(-1)
N = 512
rng = np.random.default_rng(11)
field = np.zeros((N, N), np.float32)
for sigma, amp in ((40, 1.0), (18, 0.55), (7, 0.30), (3, 0.16)):
    w = rng.standard_normal((N, N)).astype(np.float32)
    field += gaussian_filter(w, sigma, mode='wrap') * amp
field /= np.abs(field).max()
field = 0.5 + 0.5 * field
lo, hi = np.percentile(lum, [3, 97])
val = lo + (hi - lo) * field ** 1.35
tint = bg[..., :3].mean((0, 1))
tint = tint / max(tint.max(), 1e-6)
tile_rgb = (val[..., None] * tint[None, None, :]) * 1.05
tile_rgb += gaussian_filter(rng.standard_normal((N, N)).astype(np.float32), 0.6,
                            mode='wrap')[..., None] * 0.004
noise = np.concatenate([np.clip(tile_rgb, 0, 1), np.ones((N, N, 1), np.float32)], -1)
save(os.path.join(DST, 'base_noise.png'), noise)
# ---------------------------------------------------------------- 1b. real base
# Wrapping the blur does NOT make the plate tileable. A circular filter leaves the
# plate's own left/right and top/bottom mismatch exactly where it is and only
# smears it over a few pixels, and that smeared step is the rectangular seam you
# see once the band is tiled. Band-limiting in the Fourier domain would make it
# periodic, but the haze keeps 99.5% of its energy in the flattest two percent of
# the spectrum, so a cutoff that kills the step also eats half the contrast.
# What works is repairing only the edges: pull a band next to each wrap towards
# the average of the pair and the step becomes exactly zero, with everything
# outside the bands untouched. See tools/seamless_tile.py.
for band in (48, 96, 160):
    levels, grad = seam((periodic(bg[..., :3], band) * 255).astype(np.uint8))
    print(f'  band={band}: seam {levels:.3f} levels, x{grad:.2f} of gradient')
tile_rgb = np.clip(periodic(bg[..., :3], 96), 0, 1)
save(os.path.join(DST, 'base_tile.png'), np.concatenate([tile_rgb, np.ones((*tile_rgb.shape[:2], 1), np.float32)], -1))
print(f'base_tile {tile_rgb.shape[1]}x{tile_rgb.shape[0]} mean={tile_rgb.mean():.4f}')

# ------------------------------------------- 1c. seamless versions to tile
# A circular (wrap) blur does not make a plate tileable either: it smears the
# mismatch over a few pixels and leaves it exactly on the border. Every channel
# has to be pulled into agreement with its opposite edge, alpha included, since
# these plates composite as RGB * A. See tools/seamless_tile.py.
for src, dst, sig in (('nebula', 'nebula_tile', 3.0), ('stars_far', 'stars_far_tile', 1.0),
                      ('stars_near', 'stars_near_tile', 1.0)):
    a = load(os.path.join(SRC, src + '.png'))
    if sig > 0:
        a = np.stack([gaussian_filter(a[..., c], sig, mode='nearest')
                      for c in range(a.shape[2])], -1)
    a = np.clip(periodic(a, 96), 0, 1)
    jump, grad = seam((a * 255.0).astype(np.uint8))
    save(os.path.join(DST, dst + '.png'), a)
    print(f'{dst}: {a.shape[1]}x{a.shape[0]} mean_alpha={a[..., 3].mean():.5f} '
          f'wrap_step={jump:.3f} levels (interior gradient {grad:.3f})')

# ------------------------------------------------------- 2. feathered chunks
F = feather
for name, border in (('background', 200), ('nebula', 200), ('stars_far', 150), ('stars_near', 150)):
    a = load(os.path.join(SRC, name + '.png'))
    h, w = a.shape[:2]
    if name == 'background':
        rgb, al = a[..., :3], np.ones((h, w), np.float32)
    else:
        rgb, al = a[..., :3], a[..., 3]
    m = F(h, w, border)
    out = np.concatenate([rgb, (al * m)[..., None]], -1)
    out[out[..., 3] < 1 / 255.0, :3] = 0
    save(os.path.join(DST, name + '_chunk.png'), out)
    print(f'{name}_chunk {w}x{h} mean_alpha={out[...,3].mean():.3f}')

# --------------------------------------------------------- 3. nebula puffs
neb = load(os.path.join(SRC, 'nebula.png'))
H, W = neb.shape[:2]
crops = [(60, 90, 760, 560), (700, 120, 1400, 640), (180, 480, 900, 941), (900, 420, 1600, 900)]
for i, (x0, y0, x1, y1) in enumerate(crops, 1):
    c = neb[y0:y1, x0:x1]
    h, w = c.shape[:2]
    m = F(h, w, min(h, w) // 3)
    out = np.concatenate([c[..., :3], (c[..., 3] * m)[..., None]], -1)
    out[out[..., 3] < 1 / 255.0, :3] = 0
    save(os.path.join(DST, f'nebula_puff_{i:02d}.png'), out)
    print(f'nebula_puff_{i:02d} {w}x{h} mean_alpha={out[...,3].mean():.3f}')

# ------------------------------------------------------------ 4. sprites
src_sp = os.path.join(SRC, 'sprites')
copied = 0
for fn in sorted(os.listdir(src_sp)):
    shutil.copy2(os.path.join(src_sp, fn), os.path.join(DST, 'sprites', fn))
    copied += 1
print('sprites copied', copied)

# ----------------------------------------------------------- 5. palette info
pal = {
    'clear_color': [round(float(v), 4) for v in np.percentile(lum, 2) * tint],
    'background_mean_rgb': [round(float(v), 4) for v in bg[..., :3].mean((0, 1))],
    'nebula_mean_rgb': [round(float(v), 4) for v in neb[neb[..., 3] > 0.5, :3].mean(0)],
    'base_tile_size': N,
    'plate_size': [W, H],
}
json.dump(pal, open(os.path.join(DST, 'palette.json'), 'w'), indent=1)
print(json.dumps(pal, indent=1))
