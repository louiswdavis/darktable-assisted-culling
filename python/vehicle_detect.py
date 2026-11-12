"""Vehicle detection shared by the culling and tagging plugins: decode a frame, load a
detector, run it, and cache every candidate box per frame in one SQLite file.

Byte-identical copies live in darktable-assisted-culling/python/ and
darktable-assisted-tagging/python/; VEHICLE_DETECT_SHA256 in each suite pins them.
Each plugin applies its own score threshold and box selection to the stored entry."""

import hashlib
import io
import json
import os
import sqlite3
import sys
import time
from dataclasses import dataclass
from pathlib import Path

try:
    import numpy as np
    import cv2
    from PIL import Image, ImageOps
except ImportError as _e:
    print(
        f"Missing Python package '{_e.name or _e}' in {sys.executable}. "
        f"Install with: \"{sys.executable}\" -m pip install -r requirements.txt (from the repo's python folder)",
        file=sys.stderr,
    )
    sys.exit(3)

from common import RAW_EXTENSIONS  # noqa: E402  (stdlib-only module beside this file)

DETECTOR_INPUT = 640
DETECTOR_STRIDES = (8, 16, 32)
DETECTOR_NMS = 0.5
CANDIDATE_MIN_SCORE = 0.03  # every NMS survivor this strong is stored; plugins filter higher
DETECT_VERSION = 1  # bump when decode or inference behaviour changes, so cached boxes are redone
CACHE_MAX_AGE_DAYS = 90
CACHE_COMMIT_EVERY = 50
FAST_JPEG_DIM = 800  # Pillow draft target when fast_jpeg is on (culling's MAX_DIM)

COCO_NAMES = {0: "person", 1: "bicycle", 2: "car", 3: "motorcycle", 4: "airplane", 5: "bus",
              6: "train", 7: "truck", 8: "boat"}


class InputError(Exception):
    """Bad input the user fixes (a model path, the cache file): exit 2, message on stderr."""


def file_key(filepath: str):
    """[path, mtime_ns, size], or None if the file can't be stat'ed (it then
    isn't cached, and the decode reports the real error)."""
    try:
        st = os.stat(filepath)
    except OSError:
        return None
    return [os.path.abspath(filepath), st.st_mtime_ns, st.st_size]


# ---------------------------------------------------------------- decode

def _open_rgb(source, fast_jpeg: bool) -> tuple:
    """(rgb array upright per EXIF orientation, whether the file carried a rotation)."""
    img = Image.open(source)
    if fast_jpeg:
        try:
            img.draft("RGB", (FAST_JPEG_DIM, FAST_JPEG_DIM))
        except Exception:
            pass
    rotated = img.getexif().get(0x0112, 1) not in (0, 1)
    return np.array(ImageOps.exif_transpose(img).convert("RGB")), rotated


# LibRaw's sizes.flip codes → the np.rot90 turns (counter-clockwise) that make the image upright
_RAW_FLIP_TURNS = {3: 2, 5: 1, 6: 3}


def decode_rgb(filepath: str, fast_jpeg: bool = False) -> np.ndarray:
    """Decoded image, upright, at the size the file holds it: a JPEG at full size
    (fast_jpeg lets Pillow decode near FAST_JPEG_DIM), a RAW's embedded preview at its
    own size, or a half-size RAW render when there is no usable preview."""
    ext = Path(filepath).suffix.lower()
    if ext in RAW_EXTENSIONS:
        import rawpy
        with rawpy.imread(filepath) as raw:
            try:
                thumb = raw.extract_thumb()
                if thumb.format == rawpy.ThumbFormat.JPEG:
                    rgb, rotated = _open_rgb(io.BytesIO(thumb.data), fast_jpeg)
                elif thumb.format == rawpy.ThumbFormat.BITMAP:
                    rgb, rotated = thumb.data, False
                else:
                    raise ValueError("Unsupported thumbnail")
                # embedded previews are usually stored unrotated; the raw header says how to turn them
                if not rotated:
                    rgb = np.ascontiguousarray(np.rot90(rgb, _RAW_FLIP_TURNS.get(raw.sizes.flip, 0)))
            except Exception:
                rgb = raw.postprocess(half_size=True, use_camera_wb=True, no_auto_bright=True)
        return rgb
    rgb, _ = _open_rgb(filepath, fast_jpeg)
    return rgb


# ---------------------------------------------------------------- detector families

@dataclass
class Detector:
    id: str  # "<family>:<basename>:<size>:<sha1 of the bytes>", the same for the same file at any path
    family: str
    net: object
    classes: frozenset


# YOLOX as exported by opencv_zoo (object_detection_yolox_2022nov.onnx): RGB 0–255
# letterboxed top-left onto a 114-grey 640² canvas; raw per-anchor grid outputs.
def _yolox_load(data: bytes):
    """cv2.dnn net from the file bytes: cv2's own path argument is narrow on
    Windows, so a non-ASCII path (a username) fails."""
    return cv2.dnn.readNetFromONNX(np.frombuffer(data, np.uint8))


def _yolox_anchors(size: int = DETECTOR_INPUT) -> tuple:
    grids, strides = [], []
    for s in DETECTOR_STRIDES:
        n = size // s
        xv, yv = np.meshgrid(np.arange(n), np.arange(n))
        grids.append(np.stack((xv, yv), 2).reshape(-1, 2))
        strides.append(np.full((n * n, 1), s))
    return np.concatenate(grids), np.concatenate(strides)


def _yolox_run(detector: Detector, canvas: np.ndarray, scale: float, w: int, h: int) -> np.ndarray:
    """Raw YOLOX output (anchors × 85) → rows [x0, y0, x1, y1, score, coco] in source
    pixels for the family's classes at CANDIDATE_MIN_SCORE or above, before NMS."""
    net = detector.net
    net.setInput(np.transpose(canvas, (2, 0, 1))[np.newaxis])
    raw = net.forward(net.getUnconnectedOutLayersNames())[0][0]
    classes = sorted(detector.classes)
    grid, stride = _yolox_anchors()
    xy = (raw[:, :2] + grid) * stride
    wh = np.exp(raw[:, 2:4]) * stride
    cls = raw[:, 4:5] * raw[:, 5:][:, classes]
    score, best = cls.max(axis=1), cls.argmax(axis=1)
    keep = score >= CANDIDATE_MIN_SCORE
    if not keep.any():
        return np.zeros((0, 6))
    xy, wh, score, best = xy[keep] / scale, wh[keep] / scale, score[keep], best[keep]
    tl = xy - wh / 2
    coco = np.array(classes)[best]
    return np.column_stack([tl, tl + wh, score, coco])


# D-FINE / RT-DETR exported with the post-processor: inputs `images` (1×3×640×640, RGB 0–1)
# and `orig_target_sizes` (1×2), outputs `labels`, `boxes` (xyxy in input pixels), `scores`.
# Deformable attention is not in cv2.dnn, so this family runs through onnxruntime.
def _detr_load(data: bytes):
    import onnxruntime  # lazy: culling installs it only once the DETR family is the default
    return onnxruntime.InferenceSession(data, providers=["CPUExecutionProvider"])


def _detr_run(detector: Detector, canvas: np.ndarray, scale: float, w: int, h: int) -> np.ndarray:
    """Rows [x0, y0, x1, y1, score, coco] in source pixels for the family's classes at
    CANDIDATE_MIN_SCORE or above; the export's own post-processing has already done NMS."""
    session = detector.net
    names = {i.name for i in session.get_inputs()}
    size_name = next((n for n in names if "size" in n), "orig_target_sizes")
    image_name = next((n for n in names if n != size_name), "images")
    feeds = {image_name: (np.transpose(canvas, (2, 0, 1))[np.newaxis] / 255.0).astype(np.float32),
             size_name: np.array([[canvas.shape[1], canvas.shape[0]]], np.int64)}
    out = dict(zip([o.name for o in session.get_outputs()], session.run(None, feeds)))
    labels, boxes, scores = np.asarray(out["labels"])[0], np.asarray(out["boxes"])[0], np.asarray(out["scores"])[0]
    keep = (scores >= CANDIDATE_MIN_SCORE) & np.isin(labels, list(detector.classes))
    if not keep.any():
        return np.zeros((0, 6))
    return np.column_stack([boxes[keep] / scale, scores[keep], labels[keep]])


FAMILIES = {
    "yolox": {"match": lambda name: name.startswith("object_detection_yolox_"), "load": _yolox_load,
              "run": _yolox_run, "classes": frozenset({2, 3, 7}), "nms": True},  # COCO car, motorcycle, truck
    "detr": {"match": lambda name: name.startswith("dfine_") or name.startswith("rtdetr"), "load": _detr_load,
             "run": _detr_run, "classes": frozenset({2, 3, 7}), "nms": False},
}


def load_detector(model_path: str) -> Detector:
    """A Detector for the model file, its family chosen from the filename; InputError when
    the file is missing, unreadable or of no known family. Read once per process."""
    name = os.path.basename(model_path)
    family = next((f for f, row in FAMILIES.items() if row["match"](name)), None)
    if family is None:
        raise InputError(f"object detector {model_path}: unknown model family (expected "
                         f"object_detection_yolox_*.onnx, dfine_*.onnx or rtdetr*.onnx)")
    try:
        with open(model_path, "rb") as f:
            data = f.read()
    except OSError as e:
        raise InputError(f"object detector model not found or unreadable: {model_path} ({e})") from e
    did = f"{family}:{name}:{len(data)}:{hashlib.sha1(data).hexdigest()}"
    return Detector(id=did, family=family, net=FAMILIES[family]["load"](data), classes=FAMILIES[family]["classes"])


# ---------------------------------------------------------------- inference

def nms(boxes, thresh: float = DETECTOR_NMS) -> list:
    """Greedy NMS over rows [x0, y0, x1, y1, score, cls], highest score first; a box is
    dropped when a kept box overlaps it above `thresh` IoU. Returns the kept rows, score descending."""
    rows = sorted((list(map(float, b[:5])) + [int(b[5])] for b in boxes), key=lambda b: b[4], reverse=True)
    kept = []
    for b in rows:
        area_b = max(b[2] - b[0], 0) * max(b[3] - b[1], 0)
        ok = True
        for k in kept:
            iw = max(0.0, min(b[2], k[2]) - max(b[0], k[0]))
            ih = max(0.0, min(b[3], k[3]) - max(b[1], k[1]))
            inter = iw * ih
            union = area_b + max(k[2] - k[0], 0) * max(k[3] - k[1], 0) - inter
            if union > 0 and inter / union > thresh:
                ok = False
                break
        if ok:
            kept.append(b)
    return kept


def detect(rgb: np.ndarray, detector: Detector) -> dict:
    """The stored entry for one decoded frame: {"frame": [w, h], "detector": id, "boxes": [...]}
    with every box of the family's classes that scored CANDIDATE_MIN_SCORE or more and survived
    NMS, [x0, y0, x1, y1, score, coco] in the frame's own pixels, score descending."""
    h, w = rgb.shape[:2]
    scale = min(DETECTOR_INPUT / h, DETECTOR_INPUT / w)
    canvas = np.full((DETECTOR_INPUT, DETECTOR_INPUT, 3), 114.0, np.float32)
    canvas[:int(h * scale), :int(w * scale)] = cv2.resize(rgb, (int(w * scale), int(h * scale)),
                                                          interpolation=cv2.INTER_AREA)
    family = FAMILIES[detector.family]
    rows = [b for b in np.asarray(family["run"](detector, canvas, scale, w, h)).reshape(-1, 6).tolist()
            if b[4] >= CANDIDATE_MIN_SCORE]
    if family["nms"]:
        rows = nms(rows, DETECTOR_NMS)
    rows = sorted(([float(v) for v in b[:5]] + [int(b[5])] for b in rows), key=lambda b: b[4], reverse=True)
    return {"frame": [w, h], "detector": detector.id, "boxes": rows}


def boxes_in(entry: dict, w: int, h: int) -> list:
    """The entry's boxes rescaled from the frame the detector saw to a (w, h) frame."""
    fw, fh = entry["frame"]
    sx, sy = w / fw, h / fh
    return [[b[0] * sx, b[1] * sy, b[2] * sx, b[3] * sy, float(b[4]), int(b[5])] for b in entry["boxes"]]


def detection_fingerprint() -> str:
    """12-hex sha1 over the constants that change a stored entry; part of every cache key."""
    bits = [DETECTOR_INPUT, list(DETECTOR_STRIDES), DETECTOR_NMS, CANDIDATE_MIN_SCORE, DETECT_VERSION,
            {f: sorted(row["classes"]) for f, row in sorted(FAMILIES.items())}]
    return hashlib.sha1(json.dumps(bits, sort_keys=True).encode()).hexdigest()[:12]


def detection_key(path: str, detector: Detector) -> str:
    return json.dumps([file_key(path), detector.id, detection_fingerprint()], separators=(",", ":"))


# ---------------------------------------------------------------- cache

class DetectionCache:
    """Stored entries in SQLite under the darktable config dir, shared by both plugins and
    keyed by detection_key. Nothing plugin-specific is in the key; thresholds apply on read.
    An empty path disables it. Rows unused for CACHE_MAX_AGE_DAYS are pruned on open."""

    def __init__(self, path: str):
        self.db, self.used, self.pending = None, [], 0
        if not path:
            return
        os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
        try:
            self.db = sqlite3.connect(path, timeout=30)
            self.db.execute("CREATE TABLE IF NOT EXISTS detections "
                            "(key TEXT PRIMARY KEY, value TEXT NOT NULL, used INTEGER NOT NULL)")
            self.prune()
        except sqlite3.DatabaseError as e:
            raise InputError(f"detection cache {path} is unreadable ({e}); delete it to start a fresh one") from e

    def prune(self, days: int = CACHE_MAX_AGE_DAYS):
        if not self.db:
            return
        self.db.execute("DELETE FROM detections WHERE used < ?", (int(time.time()) - days * 86400,))
        self.db.commit()

    def get(self, key: str):
        if not self.db or key is None:
            return None
        row = self.db.execute("SELECT value FROM detections WHERE key = ?", (key,)).fetchone()
        if row is None:
            return None
        self.used.append(key)
        return json.loads(row[0])

    def put(self, entry: dict, key: str):
        if not self.db or key is None:
            return
        self.db.execute("INSERT OR REPLACE INTO detections (key, value, used) VALUES (?, ?, ?)",
                        (key, json.dumps(entry), int(time.time())))
        self.pending += 1
        if self.pending >= CACHE_COMMIT_EVERY:
            self.db.commit()
            self.pending = 0

    def close(self):
        if not self.db:
            return
        now = int(time.time())
        self.db.executemany("UPDATE detections SET used = ? WHERE key = ?", [(now, k) for k in self.used])
        self.db.commit()
        self.db.close()
        self.db = None


def detect_cached(path: str, detector: Detector, cache: DetectionCache, fast_jpeg: bool = False, rgb=None) -> tuple:
    """(entry, hit): the cached entry for the file and detector, or a fresh detection written to
    the cache. `rgb` is the already decoded frame when the caller has one; otherwise decode_rgb
    runs here, and its error propagates with nothing written."""
    key = detection_key(path, detector)
    entry = cache.get(key)
    if entry is not None:
        return entry, True
    if rgb is None:
        rgb = decode_rgb(path, fast_jpeg)
    entry = detect(rgb, detector)
    cache.put(entry, key)
    return entry, False
