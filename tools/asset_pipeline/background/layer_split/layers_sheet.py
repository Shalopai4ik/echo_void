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

OUT = 'EchoOfVoid_Background_Layers'
names = ['background', 'nebula', 'stars_far', 'stars_near', 'planet_glow', 'planet',
         'asteroids_far', 'asteroids_near']
W, H = 1672, 941
cols, cw, ch = 2, 836, 470
sheet = np.zeros((ch * len(names) // cols + ch, cw * cols, 3), np.uint8)
sheet[:] = 24
for i, n in enumerate(names):
    L = np.array(Image.open(os.path.join(OUT, n + '.png')).convert('RGBA')).astype(np.float32) / 255.0
    rgb = L[..., :3] if n in ('background',) else L[..., :3] * L[..., 3:4]
    img = np.clip(rgb, 0, 1)
    img = np.array(Image.fromarray((img * 255).astype(np.uint8)).resize((cw, ch), Image.BILINEAR)).astype(np.float32) / 255.
    boost = (np.clip(img / 0.18, 0, 1) ** 0.65)
    r, c = divmod(i, cols)
    tile = (boost * 255).astype(np.uint8)
    sheet[r * ch:(r + 1) * ch, c * cw:(c + 1) * cw] = tile
    print(n, 'max', float(L.max()), 'a>0', int((L[..., 3] > 0).sum()))
Image.fromarray(sheet).save('_debug/97_layers_sheet.png')
print('saved', sheet.shape)
