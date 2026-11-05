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
import numpy as np, os, math
from PIL import Image

SP = 'EchoOfVoid_Background_Layers/sprites'
files = [f for f in sorted(os.listdir(SP)) if f.endswith('.png')]
picks = ([f'asteroid_{i:03d}.png' for i in (1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 20, 40, 70, 100, 126)]
         + ['planet.png', 'planet_atmosphere.png', 'star_01.png', 'star_05.png', 'star_14.png', 'flare_streak.png'])
picks = [p for p in picks if p in files]
cell, cols = 210, 7
rows = math.ceil(len(picks) / cols)
sheet = np.full((rows * cell, cols * cell, 3), 70, np.uint8)
for i, f in enumerate(picks):
    im = Image.open(os.path.join(SP, f)).convert('RGBA')
    a = np.array(im).astype(np.float32)
    s = min(1.0, (cell - 16) / max(a.shape[0], a.shape[1]))
    if s < 1:
        a = np.array(im.resize((max(1, int(a.shape[1] * s)), max(1, int(a.shape[0] * s))),
                               Image.BILINEAR)).astype(np.float32)
    r, c = divmod(i, cols)
    y, x = r * cell + 8, c * cell + 8
    h, w = a.shape[:2]
    al = a[..., 3:4] / 255.0
    sub = sheet[y:y + h, x:x + w]
    sheet[y:y + h, x:x + w] = (a[..., :3] * al + sub * (1 - al)).astype(np.uint8)
Image.fromarray(sheet).save('_debug/95_sprites_sheet.png')
print(len(picks), 'tiles', sheet.shape)
