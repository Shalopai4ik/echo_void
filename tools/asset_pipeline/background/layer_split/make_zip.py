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
import zipfile, os

root = 'EchoOfVoid_Background_Layers'
zp = r'D:\programming\ideas\EchoOfVoid_Background_Layers.zip'
n = 0
with zipfile.ZipFile(zp, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    for dp, _, fns in os.walk(root):
        for fn in sorted(fns):
            full = os.path.join(dp, fn)
            rel = os.path.relpath(full, '.').replace(os.sep, '/')
            z.write(full, rel)
            n += 1
print('files', n, 'size', round(os.path.getsize(zp) / 1048576, 2), 'MB')
zz = zipfile.ZipFile(zp)
print('integrity:', 'OK' if zz.testzip() is None else 'BROKEN')
for i in zz.infolist():
    if not i.filename.startswith(root + '/sprites/asteroid'):
        print(f'  {i.filename:52s} {i.file_size/1024:8.1f} KB')
print('entries', len(zz.infolist()))
