"""Shared by the culling and tagging helpers; each repo holds the same file byte for byte.

The Python tests hash it (COMMON_SHA256 in test_score_images.py and test_common.py), so a
change made in one repo fails the other until it is copied over. Stdlib only: this is
imported before the heavy dependencies are checked.
"""

import os
import tempfile
from contextlib import contextmanager

# Same list as RAW_EXT in plugin_common.lua: LibRaw's camera formats.
RAW_EXTENSIONS = {"." + e for e in (
    "3fr ari arw bay cr2 cr3 crw dcr dcs dng erf fff iiq k25 kdc mdc mef mos mrw nef nrw "
    "orf ori pef raf raw rw2 rwl sr2 srf srw x3f").split()}


@contextmanager
def atomic_write(path, mode="w", **open_kwargs):
    """Yields a file open on a temp name beside `path`; on a clean exit it is moved onto
    `path` with os.replace, so a crash or a full disk leaves the old file whole. Text mode
    defaults to UTF-8 with \\n newlines."""
    path = os.fspath(path)
    if "b" not in mode:
        open_kwargs.setdefault("encoding", "utf-8")
        open_kwargs.setdefault("newline", "\n")
    fd, tmp = tempfile.mkstemp(prefix=os.path.basename(path) + ".", suffix=".tmp", dir=os.path.dirname(path) or ".")
    try:
        with os.fdopen(fd, mode, **open_kwargs) as f:
            yield f
        os.replace(tmp, path)
    except BaseException:
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise
