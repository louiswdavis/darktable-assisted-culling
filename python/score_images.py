#!/usr/bin/env python3
"""
score_images.py — burst-by-burst sharpness/exposure scorer for the darktable Assisted Culling plugin.

With --emit-saliency-points the second positional argument is the output path
for id,x0,y0,x1,y1,cached SAM prompts (the SAM pre-pass), not results.
"""

import argparse
import csv
import gc
import json
import os
import re
import shutil
import sqlite3
import sys
import time
import concurrent.futures
from pathlib import Path

try:
    import numpy as np
    import cv2
except ImportError as _e:
    print(
        f"Missing Python package '{_e.name or _e}' in {sys.executable}. "
        f"Install with: \"{sys.executable}\" -m pip install opencv-python-headless numpy Pillow rawpy",
        file=sys.stderr,
    )
    sys.exit(3)

from common import RAW_EXTENSIONS, atomic_write  # noqa: E402  (stdlib-only module beside this file)
# Decoding and vehicle detection are shared byte for byte with the tagging plugin.
import vehicle_detect  # noqa: E402
from vehicle_detect import (  # noqa: E402
    DetectionCache, boxes_in, decode_rgb, detect, detection_key, file_key, load_detector,
)
# Star tables, keeper rules and the per-burst rating live in rating.py (stdlib only), so
# eval_culling.py can replay them on a finished run without cv2.
from rating import (  # noqa: E402,F401
    STAR_THRESHOLDS, RELATIVE_REFERENCE_PERCENTILE, RELATIVE_MIN_FRAMES, GRADED_STEPS, TIER_THRESHOLDS,
    PEAK_TIER_THRESHOLDS, UNIFORMITY_TIER_THRESHOLDS, MOTION_TIER_THRESHOLDS, TIER_THRESHOLDS_BY_MODE,
    FLAG_PENALTIES, tier_table, keepers_allowed, penalised_flags, blank_frames, relative_references, rate_burst,
)

MAX_DIM = 800
SHADOW_CLIP = 5 / 255
HIGHLIGHT_CLIP = 250 / 255
CLIP_PCT_FLAG = 0.02
# a frame with at least this share of its pixels within BLANK_TOLERANCE of its median
# colour, on every channel, is blank: lens cap, a black barrier, blown sky, fog. Any
# colour counts. rating.rate_burst rejects it. --blank-share overrides it; 0 = off.
BLANK_SHARE = 0.95
BLANK_TOLERANCE = 0.06 * 255


def frame_flags(exposure: str, eyes_closed: bool = False, blank: bool = False) -> tuple:
    flags = () if exposure == "ok" else (exposure,)
    flags += ("eyes_closed",) if eyes_closed else ()
    return flags + ("blank",) if blank else flags


def is_blank(rgb: np.ndarray, share: float = BLANK_SHARE) -> bool:
    """True when at least `share` of the (downscaled) frame's pixels sit within
    BLANK_TOLERANCE of its median colour on every channel. share 0 is never blank."""
    if share <= 0:
        return False
    pixels = rgb.reshape(-1, rgb.shape[-1]).astype(np.float32)
    distance = np.abs(pixels - np.median(pixels, axis=0)).max(axis=1)
    return float(np.mean(distance <= BLANK_TOLERANCE)) >= share


SALIENCY_GRID = 5


def downscale(rgb: np.ndarray) -> np.ndarray:
    """The frame at most MAX_DIM on its long edge."""
    h, w = rgb.shape[:2]
    scale = MAX_DIM / max(h, w)
    if scale < 1:
        rgb = cv2.resize(rgb, (int(w * scale), int(h * scale)), interpolation=cv2.INTER_AREA)
    return rgb


def load_image(filepath: str, fast_jpeg: bool = False) -> np.ndarray:
    """Decoded image, downscaled and upright, so it matches the orientation
    darktable's own pipeline (and therefore the SAM masks) uses."""
    return downscale(decode_rgb(filepath, fast_jpeg))


def saliency_point(rgb: np.ndarray, grid: int = SALIENCY_GRID) -> tuple:
    """(x_frac, y_frac) centre of the tile that stands out most, by edge energy
    plus colour distance from the frame's mean colour. Returns (0.5, 0.5) for a
    featureless frame."""
    gray = cv2.cvtColor(rgb, cv2.COLOR_RGB2GRAY)
    lab = cv2.cvtColor(rgb, cv2.COLOR_RGB2LAB).astype(np.float32)
    frame_mean = lab.reshape(-1, 3).mean(axis=0)
    h, w = gray.shape
    th, tw = h // grid, w // grid

    edge = np.zeros((grid, grid))
    colour = np.zeros((grid, grid))
    for r in range(grid):
        for c in range(grid):
            ys, xs = slice(r * th, (r + 1) * th), slice(c * tw, (c + 1) * tw)
            edge[r, c] = cv2.Laplacian(gray[ys, xs], cv2.CV_64F).var()
            colour[r, c] = np.linalg.norm(lab[ys, xs].reshape(-1, 3).mean(axis=0) - frame_mean)

    score = np.zeros((grid, grid))
    for part in (edge, colour):
        peak = part.max()
        if peak > 0:
            score += 0.5 * part / peak
    if score.max() <= 0:
        return (0.5, 0.5)

    r, c = np.unravel_index(int(np.argmax(score)), score.shape)
    return ((c + 0.5) / grid, (r + 0.5) / grid)


# Vehicle boxes come from a vehicle_detect entry (one per frame, shared with the tagging
# plugin through --detections): every vehicle candidate from CANDIDATE_MIN_SCORE up, in the
# pixels of the frame the detector saw. Culling's own threshold applies on read.
DETECTOR_MIN_SCORE = 0.35

_DETECTORS: dict = {}


def detector_for(model_path: str):
    """The loaded Detector for a model path, read once per process. vehicle_detect.InputError
    when the file is missing or of no known family."""
    if model_path not in _DETECTORS:
        _DETECTORS[model_path] = load_detector(model_path)
    return _DETECTORS[model_path]


def pick_vehicle(boxes: list, w: int, h: int):
    """(the most prominent box (score × area) as (x0, y0, x1, y1) frame fractions
    clipped to the frame, its COCO class), or None when there is no vehicle."""
    if not boxes:
        return None
    x0, y0, x1, y1, _, coco = max(boxes, key=lambda b: b[4] * (b[2] - b[0]) * (b[3] - b[1]))
    return ((min(max(x0 / w, 0.0), 1.0), min(max(y0 / h, 0.0), 1.0),
             min(max(x1 / w, 0.0), 1.0), min(max(y1 / h, 0.0), 1.0)), coco)


def strongest_detections(boxes: list, w: int, h: int) -> str:
    """For the log when no vehicle passes: the strongest vehicle the entry holds (only vehicle
    classes are stored, from CANDIDATE_MIN_SCORE up), with its size in the frame. The detector's
    class is left out: it names side-on cars "motorcycle", and nothing else reads it."""
    if not boxes:
        return f"nothing at {vehicle_detect.CANDIDATE_MIN_SCORE}"
    x0, y0, x1, y1, score, _ = max(boxes, key=lambda b: b[4])
    return f"strongest vehicle {score:.2f} ({(x1 - x0) / w:.2f}x{(y1 - y0) / h:.2f} of frame)"


def subject_tag(coco) -> str:
    """The diagnostic tag (under "Assisted Culling|") for a detector result:
    Detected when the detector found a vehicle, Guessed when it found none.
    The class is left out: the small detector often calls a side-on car a motorcycle."""
    return "Subject|Vehicle|" + ("Detected" if coco is not None else "Guessed")


def vehicle_box(rgb: np.ndarray, entry: dict) -> tuple:
    """(box as frame fractions or None, COCO class or None, log note: "" when a
    vehicle was found). `entry` is the frame's stored detection; its boxes are
    rescaled to `rgb` and those at DETECTOR_MIN_SCORE or more compete."""
    h, w = rgb.shape[:2]
    boxes = boxes_in(entry, w, h)
    found = pick_vehicle([b for b in boxes if b[4] >= DETECTOR_MIN_SCORE], w, h)
    if found:
        return found[0], found[1], ""
    dropped = f"; tagging's car check dropped {entry['dropped']}" if entry.get("dropped") else ""
    return None, None, f"no vehicle at {DETECTOR_MIN_SCORE}: {strongest_detections(boxes, w, h)}{dropped}"


# --car-boxes: tagging's last boxes.json, whose boxes are the ones tagging's SigLIP 2 box check
# kept as cars. A frame in the file keeps only the detector boxes overlapping one of them at
# CAR_BOX_MIN_IOU or more; a frame not in it (or changed since) keeps its raw boxes.
CAR_BOX_MIN_IOU = 0.5


def path_key(filepath: str) -> str:
    return os.path.normcase(os.path.abspath(filepath))


def read_car_boxes(path: str) -> tuple:
    """({path_key: [(x0, y0, x1, y1) frame fractions]} per frame of tagging's boxes.json, log line).
    Frames whose file changed after boxes.json was written, and frames tagging failed on, are left
    out. {} with no path, a missing or unreadable file, or a people run."""
    if not path:
        return {}, "car boxes: off, raw detector boxes"
    try:
        written = os.path.getmtime(path)
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError) as e:
        return {}, f"car boxes: none from tagging ({e.__class__.__name__} on {path}), raw detector boxes"
    if data.get("kind") == "people":
        return {}, f"car boxes: {path} is from a people run, raw detector boxes"
    cars, stale = {}, 0
    for img in data.get("images", {}).values():
        if img.get("status") == "error" or len(img.get("frame") or []) != 2:
            continue
        try:
            unchanged = os.path.getmtime(img["file"]) <= written
        except OSError:
            unchanged = False
        if not unchanged:
            stale += 1
            continue
        fw, fh = img["frame"]
        cars[path_key(img["file"])] = [(b["bbox"][0] / fw, b["bbox"][1] / fh, b["bbox"][2] / fw, b["bbox"][3] / fh)
                                       for b in img["boxes"]]
    return cars, (f"car boxes: {len(cars)} frames from {path}"
                  + (f", {stale} left out (file changed since tagging ran, or gone)" if stale else ""))


def box_iou(a, b) -> float:
    inter = box_area((max(a[0], b[0]), max(a[1], b[1]), min(a[2], b[2]), min(a[3], b[3])))
    union = box_area(a) + box_area(b) - inter
    return inter / union if union > 0 else 0.0


def car_filtered(entry, cars):
    """`entry` with only the boxes overlapping one of `cars` (frame fractions) at CAR_BOX_MIN_IOU or
    more, and `dropped` = how many went. `entry` itself when cars is None (frame not in tagging's
    file) or there is no entry."""
    if cars is None or not entry:
        return entry
    fw, fh = entry["frame"]
    keep = [b for b in entry["boxes"]
            if any(box_iou((b[0] / fw, b[1] / fh, b[2] / fw, b[3] / fh), c) >= CAR_BOX_MIN_IOU for c in cars)]
    return dict(entry, boxes=keep, dropped=len(entry["boxes"]) - len(keep))


def car_key(cars) -> tuple:
    """The cache-key part for a frame's car boxes: () when the frame isn't in tagging's file, so
    keys are unchanged with the check off."""
    return () if cars is None else (["cars", CAR_BOX_MIN_IOU, [[round(v, 4) for v in c] for c in cars]],)


def log_car_check(rows, detections, detector: str, cars_of: dict, note: str):
    """Logs where the boxes came from and, over the frames in tagging's file, how many boxes at
    DETECTOR_MIN_SCORE or more the car check removed and how many frames it left with none."""
    frames = removed = emptied = 0
    for row in rows:
        cars = cars_of.get(path_key(row[1]))
        entry = detections.get(detection_key(row[1], detector_for(detector))) if cars is not None else None
        if not entry:
            continue
        before = sum(b[4] >= DETECTOR_MIN_SCORE for b in entry["boxes"])
        after = sum(b[4] >= DETECTOR_MIN_SCORE for b in car_filtered(entry, cars)["boxes"])
        frames += 1
        removed += before - after
        emptied += bool(before) and not after
    log(note + (f"; checked {frames} frames: {removed} boxes removed, {emptied} frames left with no vehicle"
                if cars_of else ""))


# Framing defects (motion_aware with a detector), judged per burst from the stored
# detections. Boxes are frame fractions, not clipped, so a box past an edge shows how far.
DIRECTION_MIN_SHIFT = 0.05  # the target's centre must move this share of the frame width across the burst
EDGE_TOUCH = 0.005  # a box ending this close to a frame edge touches it
CUT_TRAILING_SHARE = 0.10  # trailing, top and bottom edges: share of the box past the edge that counts
TIGHT_CROP_SHARE = 0.6  # a target covering this share of the frame is framed tight on purpose: never cut_off
BLOCKED_SHARE = 0.25  # share of the target a larger (nearer) vehicle box must cover


def frame_boxes(entry) -> list:
    """The entry's vehicle boxes at DETECTOR_MIN_SCORE or more as (x0, y0, x1, y1, score),
    fractions of the frame the detector saw; [] for no entry."""
    if not entry:
        return []
    fw, fh = entry["frame"]
    return [(b[0] / fw, b[1] / fh, b[2] / fw, b[3] / fh, float(b[4]))
            for b in entry["boxes"] if b[4] >= DETECTOR_MIN_SCORE]


def box_area(b) -> float:
    return max(0.0, b[2] - b[0]) * max(0.0, b[3] - b[1])


def burst_targets(boxes_of: list) -> list:
    """Per frame the target box, or None. The target is the box nearest in size to the burst's
    typical car (median area of each frame's most prominent box), so a car passing close in
    front for a frame or two is not taken for the target."""
    prominent = [box_area(max(bs, key=lambda b: b[4] * box_area(b))) for bs in boxes_of if bs]
    if not prominent:
        return [None] * len(boxes_of)
    typical = float(np.median(prominent))
    if typical <= 0:
        return [None] * len(boxes_of)
    return [min(bs, key=lambda b: abs(np.log(max(box_area(b), 1e-9) / typical))) if bs else None
            for bs in boxes_of]


def travel_direction(targets: list) -> str:
    """"left", "right" or "unknown" (fewer than 3 targets, or a shift under DIRECTION_MIN_SHIFT):
    the sign of the target centre's shift from the burst's first half to its second, in time
    order. Rally cars slide, so this follows the box, not the way the nose points."""
    xs = [(t[0] + t[2]) / 2 for t in targets if t]
    if len(xs) < 3:
        return "unknown"
    half = len(xs) // 2
    shift = sum(xs[-half:]) / half - sum(xs[:half]) / half
    if abs(shift) < DIRECTION_MIN_SHIFT:
        return "unknown"
    return "right" if shift > 0 else "left"


def is_cut_off(target, direction: str) -> bool:
    """The target touches the leading edge (both side edges when the direction is unknown),
    or reaches more than CUT_TRAILING_SHARE of its size past any other edge."""
    if box_area(target) >= TIGHT_CROP_SHARE:
        return False
    w, h = target[2] - target[0], target[3] - target[1]
    past = {"left": (-target[0], w), "right": (target[2] - 1, w),
            "top": (-target[1], h), "bottom": (target[3] - 1, h)}
    leading = {direction} if direction in ("left", "right") else {"left", "right"}
    for edge, (beyond, size) in past.items():
        if edge in leading:
            if beyond >= -EDGE_TOUCH:
                return True
        elif size > 0 and beyond / size > CUT_TRAILING_SHARE:
            return True
    return False


def is_blocked(target, boxes: list) -> bool:
    """A larger vehicle box (nearer the camera) covers more than BLOCKED_SHARE of the target."""
    area = box_area(target)
    for b in boxes:
        if b is target or area <= 0 or box_area(b) <= area:
            continue
        overlap = box_area((max(target[0], b[0]), max(target[1], b[1]), min(target[2], b[2]), min(target[3], b[3])))
        if overlap / area > BLOCKED_SHARE:
            return True
    return False


def framing_flags(boxes_of: list) -> tuple:
    """(travel direction, per frame the framing flags it earns) for one burst's frames in time
    order; boxes_of holds each frame's frame_boxes. A flag every frame shares costs nothing
    (rating.penalised_flags), so a burst framed tight or shot through traffic is unaffected."""
    targets = burst_targets(boxes_of)
    direction = travel_direction(targets)
    flags = []
    for target, boxes in zip(targets, boxes_of):
        own = ()
        if target is not None:
            own = (("cut_off",) if is_cut_off(target, direction) else ()) + \
                  (("blocked",) if is_blocked(target, boxes) else ())
        flags.append(own)
    return direction, flags


_CASCADES: dict = {}


def _cascade(filename: str):
    if filename not in _CASCADES:
        _CASCADES[filename] = cv2.CascadeClassifier(cv2.data.haarcascades + filename)
    return _CASCADES[filename]


BLINK_MIN_FACE_PX = 120  # below this the eye detector misses open eyes too often to call a blink
EYE_SEARCH_TOP = 0.6     # eyes sit in the upper face; lower down, nostrils and mouth corners fool the detector


def _detect_eyes(face_gray: np.ndarray):
    """Open eyes in a face crop. Haar eye detectors are trained on open eyes,
    so closed ones are mostly missed; the glasses-aware detector is tried
    second so spectacles aren't mistaken for a blink."""
    for name in ("haarcascade_eye.xml", "haarcascade_eye_tree_eyeglasses.xml"):
        eyes = _cascade(name).detectMultiScale(face_gray, scaleFactor=1.1, minNeighbors=5)
        if len(eyes) > 0:
            return eyes
    return ()


def _face_eye_sharpness(gray: np.ndarray, denoised: np.ndarray):
    """(score, eyes closed) for the largest detected face: Laplacian variance
    over its eye region, or the whole face box if no eyes are found. Eyes
    count as closed only when none are found in a face big enough to judge.
    Returns None if no face is detected, so the caller can fall back to the
    frame-wide heuristic."""
    faces = _cascade("haarcascade_frontalface_default.xml").detectMultiScale(
        gray, scaleFactor=1.1, minNeighbors=5,
        minSize=(gray.shape[1] // 10, gray.shape[0] // 10),
    )
    if len(faces) == 0:
        return None
    x, y, fw, fh = max(faces, key=lambda f: f[2] * f[3])  # largest face = main subject
    face_crop = denoised[y:y + fh, x:x + fw]
    if face_crop.size == 0:
        return None

    eyes = _detect_eyes(gray[y:y + int(fh * EYE_SEARCH_TOP), x:x + fw])
    if len(eyes) > 0:
        ex0 = min(e[0] for e in eyes)
        ey0 = min(e[1] for e in eyes)
        ex1 = max(e[0] + e[2] for e in eyes)
        ey1 = max(e[1] + e[3] for e in eyes)
        eye_crop = face_crop[ey0:ey1, ex0:ex1]
        if eye_crop.size > 0:
            return float(cv2.Laplacian(eye_crop, cv2.CV_64F).var()), False

    return float(cv2.Laplacian(face_crop, cv2.CV_64F).var()), len(eyes) == 0 and fw >= BLINK_MIN_FACE_PX


def face_detect_score(rgb: np.ndarray) -> tuple:
    """(sharpness, eyes closed) for face_detect mode. A frame with no face
    scores as subject_focus and is never flagged."""
    gray = cv2.cvtColor(rgb, cv2.COLOR_RGB2GRAY)
    face = _face_eye_sharpness(gray, cv2.bilateralFilter(gray, 5, 50, 50))
    return face if face is not None else (sharpness_score(rgb, "subject_focus"), False)


MASK_ASPECT_TOLERANCE = 0.03


def _masked_sharpness(denoised: np.ndarray, mask_path: str):
    """Laplacian variance inside a SAM mask PNG, or None if the mask is missing,
    unreadable, empty, or framed differently from the image (e.g. a darkroom
    crop changed the aspect ratio), so the caller can fall back."""
    mask = cv2.imread(mask_path, cv2.IMREAD_GRAYSCALE) if os.path.exists(mask_path) else None
    if mask is None:
        return None
    h, w = denoised.shape
    mh, mw = mask.shape
    if not (h and w and mh and mw):
        return None
    if abs((mw / mh) / (w / h) - 1) > MASK_ASPECT_TOLERANCE:
        return None
    inside = cv2.resize(mask, (w, h), interpolation=cv2.INTER_NEAREST) > 127
    if not inside.any():
        return None
    return float(cv2.Laplacian(denoised, cv2.CV_64F)[inside].var())


UNIFORMITY_MIN_CONTRAST = 6.0  # large-scale patch std (0–255) below which it's featureless, e.g. clear sky


def _uniformity_score(denoised: np.ndarray) -> float:
    """Mean Laplacian variance of the weakest third of a 3x3 grid, so a soft
    corner pulls the score down. Featureless patches are skipped: clear sky
    looks equally flat sharp or blurred and would otherwise decide every frame.
    "Featureless" is judged on the patch shrunk to 8x8, i.e. its large-scale
    tones, which blur leaves intact, so a soft corner is never mistaken for sky."""
    h, w = denoised.shape
    h_step, w_step = h // 3, w // 3
    textured, every = [], []
    for r in range(3):
        for c in range(3):
            patch = denoised[r * h_step:(r + 1) * h_step, c * w_step:(c + 1) * w_step]
            if patch.size == 0:
                continue
            var = float(cv2.Laplacian(patch, cv2.CV_64F).var())
            every.append(var)
            coarse = cv2.resize(patch, (8, 8), interpolation=cv2.INTER_AREA)
            if float(coarse.std()) >= UNIFORMITY_MIN_CONTRAST:
                textured.append(var)
    if not textured:
        return float(np.median(every)) if every else float(cv2.Laplacian(denoised, cv2.CV_64F).var())
    textured.sort()
    weakest = textured[:max(1, len(textured) // 3)]
    return float(np.mean(weakest))


def sharpness_score(rgb: np.ndarray, mode: str, mask_path: str = "") -> float:
    gray = cv2.cvtColor(rgb, cv2.COLOR_RGB2GRAY)
    denoised = cv2.bilateralFilter(gray, 5, 50, 50)
    h, w = denoised.shape

    if mode == "sam_subject" and mask_path:
        masked = _masked_sharpness(denoised, mask_path)
        if masked is not None:
            return masked
        # no usable mask for this image: fall through to the center-weighted heuristic

    if mode == "center":
        crop = denoised[int(h * 0.25):int(h * 0.75), int(w * 0.25):int(w * 0.75)]
        return float(cv2.Laplacian(crop, cv2.CV_64F).var())
    if mode == "peak":
        lap = cv2.Laplacian(denoised, cv2.CV_64F)
        return float(np.percentile(np.abs(lap), 99))
    if mode == "face_detect":
        face = _face_eye_sharpness(gray, denoised)
        if face is not None:
            return face[0]
        # no face in frame: fall through to the center-weighted heuristic below
    if mode == "tiles_uniformity":
        return _uniformity_score(denoised)

    # 3x3 patch grid weighted toward the center, assuming the subject sits
    # mid-frame (subject_focus and subject_peak, and the fallback for
    # face_detect / sam_subject). subject_peak drops the median term, which is
    # mostly background.
    h_step, w_step = h // 3, w // 3
    patch_weights = [[0.8, 1.0, 0.8], [1.0, 1.2, 1.0], [0.8, 1.0, 0.8]]

    weighted_vars = []
    patch_vars = []
    for r in range(3):
        for c in range(3):
            patch = denoised[r * h_step:(r + 1) * h_step, c * w_step:(c + 1) * w_step]
            if patch.size > 0:
                var = float(cv2.Laplacian(patch, cv2.CV_64F).var())
                patch_vars.append(var)
                weighted_vars.append(var * patch_weights[r][c])

    if weighted_vars:
        if mode == "subject_peak":
            return float(np.max(weighted_vars))
        return float(np.max(weighted_vars) * 0.80 + np.median(patch_vars) * 0.20)
    return float(cv2.Laplacian(denoised, cv2.CV_64F).var())


def exposure_status(rgb: np.ndarray, mode: str) -> str:
    if mode == "none":
        return "ok"
    gray = cv2.cvtColor(rgb, cv2.COLOR_RGB2GRAY).astype(np.float32) / 255.0
    if mode == "subject_only":
        # Drop the top fifth of the frame: skies/backgrounds blow out often
        # and shouldn't flag a frame whose subject is correctly exposed.
        gray = gray[int(gray.shape[0] * 0.2):, :]
    if mode == "strict":
        if np.mean(gray > (HIGHLIGHT_CLIP - 0.05)) > (CLIP_PCT_FLAG / 2):
            return "overexposed"
        if np.mean(gray < (SHADOW_CLIP + 0.05)) > (CLIP_PCT_FLAG / 2):
            return "underexposed"
    else:
        if np.mean(gray > HIGHLIGHT_CLIP) > CLIP_PCT_FLAG:
            return "overexposed"
        if np.mean(gray < SHADOW_CLIP) > CLIP_PCT_FLAG:
            return "underexposed"
    return "ok"


def log(msg: str):
    """One timestamped line on stderr, which the plugin appends to its run log."""
    print(time.strftime("%H:%M:%S ") + "py: " + msg, file=sys.stderr, flush=True)


def write_progress(progress_path: str, cur: int, tot: int, b_cur: int, b_tot: int):
    if not progress_path:
        return
    payload = f"{cur},{tot},{b_cur},{b_tot}"
    for _ in range(8):
        try:
            with open(progress_path, "w", encoding="utf-8") as pf:
                pf.write(payload)
            return
        except OSError:
            time.sleep(0.02)


def cancel_requested(progress_path: str) -> bool:
    if not progress_path:
        return False
    return Path(progress_path + ".cancel").exists()


def _init_worker(detector_path: str = ""):
    try:
        cv2.setNumThreads(1)
    except Exception:
        pass
    if detector_path:
        detector_for(detector_path)  # read once per worker, not once per frame


SHORTLIST_MIN = 3


def shortlist(heuristic: dict, keep_mode: str) -> set:
    """Ids of the frames worth running SAM on: the top heuristic scorers, at
    least SHORTLIST_MIN and never fewer than the burst can keep."""
    k = max(SHORTLIST_MIN, keepers_allowed(keep_mode, len(heuristic)))
    return set(sorted(heuristic, key=heuristic.get, reverse=True)[:k])


def resolve_burst_scores(scores: dict, candidates=None) -> tuple:
    """(one float per image, ids eligible to be keepers).

    sam_subject scores arrive as (masked or None, fallback) pairs, and the two
    aren't on the same scale. If every shortlisted frame (every frame, when
    there's no shortlist) got a mask, shortlisted frames compete on their
    masked score and only they can keep; the rest keep their fallback score
    for star tiers. Otherwise the whole burst uses the fallback and everyone
    is eligible. Plain floats pass through, all eligible."""
    everyone = set(scores)
    pairs = {k: v for k, v in scores.items() if isinstance(v, tuple)}
    if not pairs:
        return dict(scores), everyone
    shortlisted = set(pairs) if candidates is None else set(pairs) & set(candidates)
    if shortlisted and all(pairs[k][0] is not None for k in shortlisted):
        resolved = {k: (v[0] if k in shortlisted else v[1]) if isinstance(v, tuple) else v
                    for k, v in scores.items()}
        return resolved, shortlisted
    return {k: v[1] if isinstance(v, tuple) else v for k, v in scores.items()}, everyone


def parse_manifest_row(row) -> tuple:
    """(id, filepath, burst_id, mask_path, shortlisted, edited, exposure, aperture, focal, car).
    mask_path, shortlisted and edited are "" when absent; shortlisted is "1"/"0"
    and edited is darktable's change_timestamp, both only in sam_subject runs.
    exposure (seconds), aperture (f-number) and focal length (mm) come from
    darktable's EXIF, 0.0 when absent or unknown. car is the car number the frame
    was pooled under, "" when absent."""
    row = list(row) + [""] * (10 - len(row))
    return (row[0], row[1], row[2], row[3], row[4], row[5],
            float(row[6] or 0), float(row[7] or 0), float(row[8] or 0), row[9])


PANNING_SHUTTER = 1 / 125    # this slow or slower (s): a pan, background blur expected
SHALLOW_DOF_APERTURE = 4.0   # this wide or wider (f-number): soft frame edges expected
EXIF_SLACK = 1.01            # EXIF values arrive as float32, so 1/125 can land a hair either side


def burst_sharp_mode(sharp_mode: str, exposures, apertures) -> str:
    """The sharpness mode a burst is scored with once shooting intent is read
    from its median shutter and aperture (0 = unknown, ignored), so every frame
    in the burst shares one scale. A pan in subject_focus scores the subject
    only (subject_peak); a wide aperture in tiles_uniformity skips the
    edge-to-edge check (subject_focus). Panning leaves tiles_uniformity alone:
    a slow shutter there is usually a tripod landscape, not a pan."""
    exposures = [e for e in exposures if e > 0]
    apertures = [a for a in apertures if a > 0]
    if sharp_mode == "subject_focus" and exposures \
            and float(np.median(exposures)) * EXIF_SLACK >= PANNING_SHUTTER:
        return "subject_peak"
    if sharp_mode == "tiles_uniformity" and apertures \
            and float(np.median(apertures)) <= SHALLOW_DOF_APERTURE * EXIF_SLACK:
        return "subject_focus"
    return sharp_mode


def technique_tag(burst_mode: str) -> str:
    """The diagnostic tag (under "Assisted Culling|") for a mode burst_sharp_mode switched to."""
    return "Technique|Panning" if burst_mode == "subject_peak" else "Technique|Shallow DoF"


# Constants whose value changes a number stored in the score cache. cache_fingerprint()
# hashes them with the decoder versions, so editing one re-scores on the next run with
# no version to bump. test_score_images.py fails when a module constant is in neither
# tuple, so a new constant must be filed here.
CACHE_INPUTS = (
    "MAX_DIM", "SHADOW_CLIP", "HIGHLIGHT_CLIP", "CLIP_PCT_FLAG", "BLANK_SHARE", "BLANK_TOLERANCE",
    "SALIENCY_GRID", "DETECTOR_MIN_SCORE",
    # CAR_BOX_MIN_IOU is not here: car_key puts it in the key of each frame it applies to
    "BLINK_MIN_FACE_PX", "EYE_SEARCH_TOP", "MASK_ASPECT_TOLERANCE", "UNIFORMITY_MIN_CONTRAST", "EXIF_SLACK",
    "SUBJECT_PAD", "SUBJECT_CROP_MAX", "SUBJECT_SCALES", "NORM_MIN_CONTRAST", "MOTION_GRID", "STREAK_COHERENCE", "STREAK_ANGLE_TOL",
    "SUBJECT_STREAK_MAX", "STREAK_SHARE", "STREAK_SHARE_SLOW", "STREAK_SHARE_FAST", "PAN_REACH", "FAST_SHUTTER",
    "PAN_BONUS", "MISSED_PAN_FACTOR", "BLUR_STRAIGHT_SCALE", "CENTRE_BOX",
)
# Constants that only use cached numbers (ranking, stars, keepers, shortlist, report) or
# pick a mode that is already in the key. Changing one re-applies without re-scoring.
CACHE_NEUTRAL = (
    "RAW_EXTENSIONS", "STAR_THRESHOLDS", "RELATIVE_REFERENCE_PERCENTILE", "RELATIVE_MIN_FRAMES", "GRADED_STEPS",
    "TIER_THRESHOLDS", "PEAK_TIER_THRESHOLDS", "UNIFORMITY_TIER_THRESHOLDS", "TIER_THRESHOLDS_BY_MODE",
    "FLAG_PENALTIES", "SHORTLIST_MIN", "PANNING_SHUTTER", "SHALLOW_DOF_APERTURE",
    "SCORE_CACHE_MAX_AGE_DAYS", "SCORE_CACHE_COMMIT_EVERY", "CACHE_INPUTS", "CACHE_NEUTRAL",
    "MOTION_TIER_THRESHOLDS", "MOTION_TAGS", "PRESCORE_FAILED", "REPORT_HEADER", "REPORT_ARCHIVE_KEEP", "WHY_REASONS",
    # framing is judged across the burst and never cached; NO_VEHICLE_SUBJECT matches a cached subject
    "DIRECTION_MIN_SHIFT", "EDGE_TOUCH", "CUT_TRAILING_SHARE", "TIGHT_CROP_SHARE", "BLOCKED_SHARE", "NO_VEHICLE_SUBJECT",
    # keyed per frame by car_key, so a change misses only the frames in tagging's file
    "CAR_BOX_MIN_IOU",
)
SCORE_CACHE_MAX_AGE_DAYS = 90
SCORE_CACHE_COMMIT_EVERY = 50
_FINGERPRINT = ""


def _jsonable(v):
    if isinstance(v, (set, frozenset)):
        return sorted(v)
    if isinstance(v, dict):
        return {str(k): _jsonable(x) for k, x in v.items()}
    if isinstance(v, (list, tuple)):
        return [_jsonable(x) for x in v]
    return v


def cache_fingerprint() -> str:
    """12 hex chars over CACHE_INPUTS' values, vehicle_detect's detection fingerprint and the
    decoder versions (OpenCV, Pillow, rawpy, numpy). Part of every cache key, so any of them
    changing misses the cache."""
    global _FINGERPRINT
    if _FINGERPRINT:
        return _FINGERPRINT
    import hashlib
    import PIL
    try:
        import rawpy
        rawpy_version = getattr(rawpy, "__version__", "?")
    except ImportError:
        rawpy_version = "none"
    g = globals()
    bits = {name: _jsonable(g[name]) for name in CACHE_INPUTS}
    bits["detection"] = vehicle_detect.detection_fingerprint()
    bits["versions"] = [cv2.__version__, PIL.__version__, rawpy_version, np.__version__]
    _FINGERPRINT = hashlib.sha1(json.dumps(bits, sort_keys=True, default=str).encode()).hexdigest()[:12]
    return _FINGERPRINT


class ScoreCache:
    """Per-frame scores in SQLite, keyed by everything that changes the number:
    the file's identity, the settings that feed the score, and
    cache_fingerprint(). Settings that only use the scores (ranking, keepers,
    non-keepers, tag-only flags) stay out of the key. An empty path disables
    it: every get misses and put does nothing. Only the main process uses it."""

    def __init__(self, path: str):
        self.db, self.path, self.used, self.pending = None, path, [], 0
        if not path:
            return
        os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
        try:
            self.db = sqlite3.connect(path, timeout=30)
            self.db.execute("CREATE TABLE IF NOT EXISTS scores "
                            "(key TEXT PRIMARY KEY, value TEXT NOT NULL, used REAL NOT NULL)")
            self.db.execute("DELETE FROM scores WHERE used < ?",
                            (time.time() - SCORE_CACHE_MAX_AGE_DAYS * 86400,))
            self.db.commit()
        except sqlite3.DatabaseError as e:
            raise RuntimeError(f"score cache {path} is unreadable ({e}); delete it to start a fresh one") from e

    @staticmethod
    def _key(parts) -> str:
        return json.dumps(list(parts) + [cache_fingerprint()], separators=(",", ":"))

    def get(self, *parts):
        if not self.db or any(p is None for p in parts):
            return None
        k = self._key(parts)
        row = self.db.execute("SELECT value FROM scores WHERE key = ?", (k,)).fetchone()
        if row is None:
            return None
        self.used.append(k)
        return json.loads(row[0])

    def put(self, value, *parts):
        if not self.db or any(p is None for p in parts):
            return
        self.db.execute("INSERT OR REPLACE INTO scores (key, value, used) VALUES (?, ?, ?)",
                        (self._key(parts), json.dumps(value), time.time()))
        self.pending += 1
        if self.pending >= SCORE_CACHE_COMMIT_EVERY:
            self.db.commit()
            self.pending = 0

    def close(self):
        if not self.db:
            return
        now = time.time()
        self.db.executemany("UPDATE scores SET used = ? WHERE key = ?", [(now, k) for k in self.used])
        self.db.commit()
        self.db.close()
        self.db = None


def detector_key(detector: str):
    """The detector model's identity (family, file name, size, sha1) for cache keys;
    "" when there's none."""
    if not detector:
        return ""
    return detector_for(detector).id


def masked_key(filepath: str, args, prompt, edited: str):
    """Key parts for a frame's SAM-masked score. The mask comes from darktable's
    export of the edited image, so the edit time is part of it."""
    return ("masked", file_key(filepath), args.fast_jpeg, getattr(args, "sam_model", ""),
            [round(v, 4) for v in prompt], edited)


# motion_aware (motorsport): the car is scored at full resolution with a
# contrast-free measure, and each frame's motion is read from the streaks in
# its tiles. Design: docs/superpowers/specs/culling/assisted-culling/2026-11-11-rally-sharpness-design.md
SUBJECT_PAD = 0.10          # vehicle box grown by this share of its size on each side
SUBJECT_CROP_MAX = 1600      # long side (px) the subject crop is shrunk to
SUBJECT_SCALES = (400, 600, 800, 1200)  # smaller long sides (px) the car is also scored at (same_scale)
NORM_MIN_CONTRAST = 8.0      # gray std (0–255) floor, so a flat patch can't divide by ~0
MOTION_GRID = 6
STREAK_COHERENCE = 0.45      # structure-tensor coherence from which a tile counts as streaked
STREAK_ANGLE_TOL = 20.0      # degrees a streak may differ from the background's direction
SUBJECT_STREAK_MAX = 0.35    # share of streaked subject tiles above which the car is not frozen
STREAK_SHARE = 0.5           # share of background tiles streaked in one direction for a pan
STREAK_SHARE_SLOW = 0.4      # ... when shutter × focal length says blur is likely
STREAK_SHARE_FAST = 0.7      # ... when the shutter is fast enough to freeze most pans
PAN_REACH = 0.8              # shutter (s) × focal length (mm): 1/125 at 100 mm
FAST_SHUTTER = 1 / 1000
PAN_BONUS = 1.15
MISSED_PAN_FACTOR = 0.7
BLUR_STRAIGHT_SCALE = 500.0  # an all-motion-blur burst scores straightness × this
CENTRE_BOX = (1 / 3, 1 / 3, 2 / 3, 2 / 3)
MOTION_TAGS = {"pan": "Technique|Panning", "motion_blur": "Technique|Motion Blur",
               "missed_pan": "Technique|Missed Pan"}


def subject_crop(full: np.ndarray, box) -> np.ndarray:
    """The box (frame fractions) grown by SUBJECT_PAD, cut from the full-size
    image and shrunk so its long side is at most SUBJECT_CROP_MAX."""
    h, w = full.shape[:2]
    x0, y0, x1, y1 = box
    px, py = (x1 - x0) * SUBJECT_PAD, (y1 - y0) * SUBJECT_PAD
    top, left = int(max(0.0, y0 - py) * h), int(max(0.0, x0 - px) * w)
    bottom, right = max(int(min(1.0, y1 + py) * h), top + 1), max(int(min(1.0, x1 + px) * w), left + 1)
    crop = full[top:bottom, left:right]
    return shrunk_to(crop, SUBJECT_CROP_MAX)


def shrunk_to(crop: np.ndarray, long_side: int) -> np.ndarray:
    """The crop shrunk (INTER_AREA) so its long side is exactly long_side; never grown."""
    ch, cw = crop.shape[:2]
    if max(ch, cw) <= long_side:
        return crop
    scale = long_side / max(ch, cw)
    size = (long_side, max(1, round(ch * scale))) if cw >= ch else (max(1, round(cw * scale)), long_side)
    return cv2.resize(crop, size, interpolation=cv2.INTER_AREA)


def scale_ladder(crop: np.ndarray) -> list:
    """[[long side, normalised_sharpness]] at each SUBJECT_SCALES step under the crop's long
    side, smallest first, then at its own size: the sizes same_scale can pick from."""
    long_side = max(crop.shape[:2])
    return ([[s, normalised_sharpness(shrunk_to(crop, s))] for s in SUBJECT_SCALES if s < long_side]
            + [[long_side, normalised_sharpness(crop)]])


def same_scale(ladders: dict) -> tuple:
    """(long side, {id: subject sharpness}): a burst's cars compared at the largest size every
    frame has in its scale_ladder. Laplacian steps span more of the scene on a smaller crop, so
    an approaching car would otherwise score sharper for filling more pixels. When no size is
    shared (a crop under the smallest step), each frame uses its smallest size and size is None."""
    if not ladders:
        return None, {}
    shared = set.intersection(*({s for s, _ in ladder} for ladder in ladders.values()))
    if not shared:
        return None, {i: ladder[0][1] for i, ladder in ladders.items()}
    size = max(shared)
    return size, {i: next(v for s, v in ladder if s == size) for i, ladder in ladders.items()}


def normalised_sharpness(rgb: np.ndarray) -> float:
    """Laplacian std over gray std per tile of a 3x3 grid, ×1000; 80% best
    tile + 20% median. Both terms scale with contrast, so overcast and sunny
    frames of the same focus score alike. A linear blur (not bilateral)
    denoises first, so the ratio holds exactly."""
    gray = cv2.GaussianBlur(cv2.cvtColor(rgb, cv2.COLOR_RGB2GRAY), (3, 3), 0).astype(np.float64)
    h, w = gray.shape
    hs, ws = max(1, h // 3), max(1, w // 3)
    vals = []
    for r in range(3):
        for c in range(3):
            patch = gray[r * hs:(r + 1) * hs, c * ws:(c + 1) * ws]
            if patch.shape[0] < 4 or patch.shape[1] < 4:
                continue
            lap = float(cv2.Laplacian(patch, cv2.CV_64F).std())
            vals.append(1000.0 * lap / max(float(patch.std()), NORM_MIN_CONTRAST))
    if not vals:
        return 0.0
    return float(max(vals) * 0.8 + np.median(vals) * 0.2)


def motion_tiles(gray: np.ndarray) -> list:
    """[(centre x, centre y as frame fractions, coherence, doubled gradient
    angle in radians)] for each textured tile of a MOTION_GRID grid. Coherence
    is (λ1 − λ2)/(λ1 + λ2) of the tile's structure tensor: near 1 when every
    edge runs one way (a streak), near 0 for texture in all directions."""
    g = gray.astype(np.float32)
    gx = cv2.Sobel(g, cv2.CV_32F, 1, 0, ksize=3)
    gy = cv2.Sobel(g, cv2.CV_32F, 0, 1, ksize=3)
    h, w = g.shape
    hs, ws = h // MOTION_GRID, w // MOTION_GRID
    if hs < 4 or ws < 4:
        return []
    out = []
    for r in range(MOTION_GRID):
        for c in range(MOTION_GRID):
            rows, cols = slice(r * hs, (r + 1) * hs), slice(c * ws, (c + 1) * ws)
            if float(g[rows, cols].std()) < UNIFORMITY_MIN_CONTRAST:
                continue
            tx, ty = gx[rows, cols], gy[rows, cols]
            a, b, d = float((tx * tx).mean()), float((ty * ty).mean()), float((tx * ty).mean())
            if a + b <= 1e-6:
                continue
            coherence = float(np.sqrt((a - b) ** 2 + 4 * d * d) / (a + b))
            out.append(((c + 0.5) / MOTION_GRID, (r + 0.5) / MOTION_GRID, coherence, float(np.arctan2(2 * d, a - b))))
    return out


def _angle_gap(a: float, b: float) -> float:
    """Degrees between two streak directions given as doubled angles."""
    return float(np.degrees(abs((a - b + np.pi) % (2 * np.pi) - np.pi)) / 2)


def streak_share_needed(exposure: float, focal: float) -> float:
    """Share of background tiles that must streak for a pan, from EXIF
    (0 = unknown → the default). A prior, never a rule: a fast shutter can
    still pan, it just needs more evidence."""
    if exposure <= 0:
        return STREAK_SHARE
    if exposure <= FAST_SHUTTER * EXIF_SLACK:
        return STREAK_SHARE_FAST
    if focal > 0 and exposure * focal * EXIF_SLACK >= PAN_REACH:
        return STREAK_SHARE_SLOW
    return STREAK_SHARE


def classify_motion(tiles: list, box, share_needed: float) -> tuple:
    """(class, straightness). Background = tiles centred outside the box.
    pan: background streaked one way, subject tiles mostly not streaked.
    motion_blur: subject streaked the same way as the background (the whole
    frame blurred in a straight line). missed_pan: background streaked,
    subject streaked some other way. ordinary: no dominant background streak.
    Straightness is the mean coherence of the aligned tiles."""
    x0, y0, x1, y1 = box
    inside = [x0 <= t[0] <= x1 and y0 <= t[1] <= y1 for t in tiles]
    bg = [t for t, i in zip(tiles, inside) if not i]
    subj = [t for t, i in zip(tiles, inside) if i]
    streaked_bg = [t for t in bg if t[2] >= STREAK_COHERENCE]
    if not streaked_bg:
        return "ordinary", 0.0
    direction = float(np.arctan2(np.mean([np.sin(t[3]) for t in streaked_bg]),
                                 np.mean([np.cos(t[3]) for t in streaked_bg])))

    def aligned(t):
        return t[2] >= STREAK_COHERENCE and _angle_gap(t[3], direction) <= STREAK_ANGLE_TOL

    if sum(map(aligned, bg)) / len(bg) < share_needed:
        return "ordinary", 0.0
    straight = float(np.mean([t[2] for t in tiles if aligned(t)]))
    if not subj:
        return "pan", straight
    if sum(map(aligned, subj)) / len(subj) >= share_needed:
        return "motion_blur", straight
    if sum(t[2] >= STREAK_COHERENCE for t in subj) / len(subj) < SUBJECT_STREAK_MAX:
        return "pan", straight
    return "missed_pan", straight


def motion_aware_score(filepath: str, rgb: np.ndarray, entry, exposure: float, focal: float,
                       full=None) -> tuple:
    """(score, class, straightness, log detail, no vehicle, subject sharpness, crop "WxH",
    scale_ladder) for one frame; score is subject × class_factor, at the crop's own size until
    score_manifest compares the burst at one size (same_scale). rgb is the
    MAX_DIM frame; the car is cut from a full-size decode (`full` when the
    caller has one). entry is the frame's stored detection, None without a
    detector. No detector or no vehicle → the centre third stands in for the car.
    no vehicle is True only when the detector ran and found no car."""
    box, note = None, "no detector"
    if entry is not None:
        box, _, note = vehicle_box(rgb, entry)
    region = box or CENTRE_BOX
    crop = subject_crop(decode_rgb(filepath) if full is None else full, region)
    ladder = scale_ladder(crop)
    subject = ladder[-1][1]
    cls, straight = classify_motion(motion_tiles(cv2.cvtColor(rgb, cv2.COLOR_RGB2GRAY)), region,
                                    streak_share_needed(exposure, focal))
    score = subject * class_factor(cls)
    detail = (f"{cls}, straightness {straight:.2f}, subject {subject:.0f}, crop {crop.shape[1]}x{crop.shape[0]}"
              + ("" if box else f", centre third ({note})"))
    if box and entry.get("dropped") is not None:
        detail += (f", car box {box[0]:.2f},{box[1]:.2f}-{box[2]:.2f},{box[3]:.2f} from tagging"
                   f" ({entry['dropped']} other boxes dropped)")
    return (score, cls, straight, detail, entry is not None and not box, subject, f"{crop.shape[1]}x{crop.shape[0]}",
            ladder)


def class_factor(cls: str) -> float:
    """What a motion class multiplies the subject sharpness by."""
    return {"pan": PAN_BONUS, "missed_pan": MISSED_PAN_FACTOR}.get(cls, 1.0)


def lift_motion_blur(scores: dict, motion: dict) -> dict:
    """Motion-blur frames scored like their burst: raised to the median of the
    burst's other frames, so a deliberate blur is kept or left with its
    neighbours, never rejected for being soft. An all-blur burst is ranked by
    straightness. motion maps an id to (class, straightness)."""
    blur = [i for i in scores if motion.get(i, ("", 0.0))[0] == "motion_blur"]
    if not blur:
        return scores
    rest = [v for i, v in scores.items() if i not in blur]
    out = dict(scores)
    for i in blur:
        out[i] = max(out[i], float(np.median(rest))) if rest else motion[i][1] * BLUR_STRAIGHT_SCALE
    return out


def frame_entry(rgb: np.ndarray, detector: str, detections):
    """(the frame's detection entry or None without a detector, the entry when it was
    detected here or None when `detections` was the stored one): the parent writes
    only fresh entries to the shared cache."""
    if not detector:
        return None, None
    if detections is not None:
        return detections, None
    fresh = detect(rgb, detector_for(detector))
    return fresh, fresh


def process_single_image(filepath: str, sharp_mode: str, exp_mode: str, cancel_path: str = "",
                         fast_jpeg: bool = False, mask_path: str = "", detector: str = "",
                         exposure: float = 0.0, focal: float = 0.0, detections=None,
                         blank_share: float = BLANK_SHARE, cars=None):
    """(filepath, score, flags, error, fresh detection entry or None). The detector sees
    the frame as decoded; scoring sees it downscaled to MAX_DIM. `cars` are the frame's car
    boxes from tagging (car_filtered), None when it isn't in tagging's file."""
    if cancel_path and os.path.exists(cancel_path):
        return filepath, None, None, "cancelled", None
    try:
        full = decode_rgb(filepath, fast_jpeg)
        entry, fresh = frame_entry(full, detector if sharp_mode == "motion_aware" else "", detections)
        entry = car_filtered(entry, cars)
        rgb = downscale(full)
        eyes_closed = False
        if sharp_mode == "face_detect":
            sharp, eyes_closed = face_detect_score(rgb)
        elif sharp_mode == "sam_subject":
            # both scores, so the burst can settle on one scale once every frame is in
            gray = cv2.bilateralFilter(cv2.cvtColor(rgb, cv2.COLOR_RGB2GRAY), 5, 50, 50)
            masked = _masked_sharpness(gray, mask_path) if mask_path else None
            sharp = (masked, sharpness_score(rgb, "subject_focus"))
        elif sharp_mode == "motion_aware":
            # a fast_jpeg decode is near MAX_DIM, so the car is cut from a second, full decode
            sharp = motion_aware_score(filepath, rgb, entry, exposure, focal, None if fast_jpeg else full)
        else:
            sharp = sharpness_score(rgb, sharp_mode, mask_path)
        flags = frame_flags(exposure_status(rgb, exp_mode), eyes_closed, is_blank(rgb, blank_share))
        return filepath, sharp, flags, None, fresh
    except Exception as e:
        return filepath, None, None, str(e), None


def process_single_saliency(filepath: str, fast_jpeg: bool = False, exp_mode: str = "whole_frame",
                            detector: str = "", detections=None, blank_share: float = BLANK_SHARE, cars=None):
    """The SAM prompt is a vehicle box (x0, y0, x1, y1) when `detector` finds one,
    else the saliency point (x, y). Then the fallback score, the frame's flags
    ";"-joined, the subject tag ("" without a detector), the detector's log note
    and the fresh detection entry (None when `detections` was the stored one or
    there is no detector). `cars` as for process_single_image."""
    try:
        full = decode_rgb(filepath, fast_jpeg)
        entry, fresh = frame_entry(full, detector, detections)
        entry = car_filtered(entry, cars)
        rgb = downscale(full)
        if entry is not None:
            prompt, coco, note = vehicle_box(rgb, entry)
            subject = subject_tag(coco)
        else:
            prompt, subject, note = None, "", ""
        flags = frame_flags(exposure_status(rgb, exp_mode), blank=is_blank(rgb, blank_share))
        return (filepath, prompt or saliency_point(rgb), sharpness_score(rgb, "subject_focus"),
                ";".join(flags), None, subject, note, fresh)
    except Exception as e:
        return filepath, None, None, None, str(e), "", "", None


PRESCORE_FAILED = "failed"


def read_prescores(path: str) -> tuple:
    """(id → (fallback sharpness, flags ";"-joined, prompt, subject tag), ids stage A
    couldn't decode) from a stage-A prescore file."""
    scored, failed = {}, set()
    if not path or not os.path.exists(path):
        return scored, failed
    with open(path, newline="", encoding="utf-8") as f:
        for row in csv.reader(f):
            if len(row) == 8:
                scored[row[0]] = (float(row[1]), row[2], [float(v) for v in row[3:7] if v], row[7])
            elif len(row) == 2 and row[1] == PRESCORE_FAILED:
                failed.add(row[0])
    return scored, failed


def emit_saliency_points(manifest, args, cache, detections):
    """Writes id,x0,y0,x1,y1,cached rows to args.results for each burst's
    shortlist: the frames worth running SAM on, picked by the center-weighted
    heuristic. A box prompt fills all four; a point prompt leaves x1,y1 empty.
    cached is "1" when the frame's masked score is already in the cache, so
    darktable needn't run SAM on it.
    With args.prescores, also writes id,fallback_score,flags,x0,y0,x1,y1,subject
    for every frame so the scoring pass needn't decode frames outside the
    shortlist again. Images that fail to decode get an id,failed row instead, so the
    scoring pass skips them without a second decode; they can't be keepers."""
    total = len(manifest)
    prescores = getattr(args, "prescores", "")
    exp_mode = getattr(args, "exp_mode", "whole_frame")
    blank_share = getattr(args, "blank_share", BLANK_SHARE)
    detector = getattr(args, "detector", "")
    det_key = detector_key(detector)  # loads the model: a missing or unreadable one fails the run, not each frame
    cars_of, cars_note = read_car_boxes(getattr(args, "car_boxes", "")) if detector else ({}, "")
    with open(args.results, "w", newline="", encoding="utf-8"):
        pass
    # opened once for the whole stage; darktable reads it only after the stage's done file
    pre_file = open(prescores, "w", newline="", encoding="utf-8") if prescores else None
    pre_writer = csv.writer(pre_file) if pre_file else None
    write_progress(args.progress, 0, total, 0, 0)

    row_of = {row[0]: row for row in manifest}
    remaining = {}
    for row in manifest:
        remaining[row[2]] = remaining.get(row[2], 0) + 1
    found = {b: {} for b in remaining}  # burst → id → (prompt, heuristic score)
    done = 0

    def stage_a_key(filepath):
        return ("stage_a", file_key(filepath), exp_mode, blank_share, args.fast_jpeg, det_key,
                *car_key(cars_of.get(path_key(filepath))))

    def record(image_id, prompt, heuristic, flags, subject):
        nonlocal done
        image_id, filepath, burst = row_of[image_id][:3]
        if prompt is not None:
            prompt = [round(v, 4) for v in prompt]
            found[burst][image_id] = (prompt, heuristic)
            if pre_writer:
                pre_writer.writerow([image_id, heuristic, flags] + prompt + [""] * (4 - len(prompt)) + [subject])
        elif pre_writer:
            pre_writer.writerow([image_id, PRESCORE_FAILED])
        remaining[burst] -= 1
        if remaining[burst] == 0 and found[burst]:
            picks = shortlist({i: v[1] for i, v in found[burst].items()}, args.keep_mode)
            notes = []
            with open(args.results, "a", newline="", encoding="utf-8") as f:
                w = csv.writer(f)
                for i in sorted(picks):
                    p = found[burst][i][0]
                    hit = cache.get(*masked_key(row_of[i][1], args, p, row_of[i][5])) is not None
                    w.writerow([i] + p + [""] * (4 - len(p)) + ["1" if hit else "0"])
                    notes.append(f"{i} {'box' if len(p) == 4 else 'point'}{' cached' if hit else ''}")
            log(f"burst {burst}: shortlist of {len(found[burst])} frames: {', '.join(notes)}")
            del found[burst]
        done += 1
        write_progress(args.progress, done, total, 0, 0)

    to_decode = []
    for row in manifest:
        hit = cache.get(*stage_a_key(row[1]))
        if hit:
            if hit.get("note"):
                log(f"{row[0]} ({os.path.basename(row[1])}): {hit['note']} (cached)")
            record(row[0], hit["prompt"], hit["heuristic"], hit["flags"], hit["subject"])
        else:
            to_decode.append(row)
    log(f"finding subjects: {total} frames in {len(remaining)} bursts, {total - len(to_decode)} from cache, "
        f"detector {detector or 'off'}")

    workers = max(1, (os.cpu_count() or 2) - 1)
    stored, detected = {}, 0  # filepath → detection entry already in the shared cache; frames detected here
    if detector:
        stored = {row[1]: hit for row in to_decode for hit in [detections.get(detection_key(row[1], detector_for(detector)))]
                  if hit is not None}
    with concurrent.futures.ProcessPoolExecutor(max_workers=workers, initializer=_init_worker,
                                                initargs=(detector,)) as executor:
        future_to_id = {
            executor.submit(process_single_saliency, row[1], args.fast_jpeg, exp_mode, detector,
                            stored.get(row[1]), blank_share, cars_of.get(path_key(row[1]))): row[0]
            for row in to_decode
        }
        for future in concurrent.futures.as_completed(future_to_id):
            if cancel_requested(args.progress):
                log("cancelled")
                if pre_file:
                    pre_file.close()
                executor.shutdown(wait=False, cancel_futures=True)
                sys.exit(130)
            image_id = future_to_id[future]
            filepath, prompt, heuristic, flags, err, subject, note, fresh = future.result()
            if fresh is not None:
                detections.put(fresh, detection_key(filepath, detector_for(detector)))
                detected += 1
            if err:
                log(f"skip saliency {image_id} ({filepath}): {err}")
                prompt = None
            else:
                if note:
                    log(f"{image_id} ({os.path.basename(filepath)}): {note}")
                cache.put({"prompt": [float(v) for v in prompt], "heuristic": float(heuristic), "flags": flags,
                           "subject": subject, "note": note}, *stage_a_key(filepath))
            record(image_id, prompt, heuristic, flags, subject)
    if pre_file:
        pre_file.close()
    if detector:
        log(f"detections: {len(stored)} cached, {detected} detected")
        log_car_check(manifest, detections, detector, cars_of, cars_note)
    log("finding subjects: done")


# The one "Why|<reason>" tag every scored frame gets in results column 7, saying how
# it was decided. Kept to a handful: a tag per score bucket floods darktable's tag list.
WHY_REASONS = ("Keeper", "Keeper by margin", "Outranked", "Graded", "Not shortlisted",
               "No vehicle", "Close call", "Blank", "Spread")
# the subject tag of a sam_subject frame whose detector found no car
NO_VEHICLE_SUBJECT = "Subject|Vehicle|Guessed"


def process_burst_logic(burst_id, burst_sharpness, burst_flags, burst_size, args, results_path,
                        eligible=None, diag_tags=None, reference=None, mode=None,
                        no_vehicle=frozenset()) -> list:
    """Appends the burst's result rows and returns its keepers, best first.
    diag_tags maps an id to its diagnostic tags (under "Assisted Culling|"),
    written ";"-joined in the 7th column after the frame's Why|<reason> tag
    (WHY_REASONS). reference is the relative mode's selection-wide sharpness
    for 100 points (see relative_references); None means the group was too
    small for one and the burst takes universal tiers. mode is the burst's
    sharp mode (args.sharp_mode when not given) and picks its tier table. no_vehicle
    frames are left alone with Why|No vehicle (rate_burst)."""
    sorted_members, burst_keepers, stars_of, reason_of = rate_burst(
        burst_sharpness, burst_flags, burst_size, args, eligible, reference, mode, no_vehicle,
        sorted(burst_sharpness, key=int) if getattr(args, "spread_keepers", False) else None)
    keepers = set(burst_keepers)
    burst_rows = [[
        img_id,
        round(burst_sharpness[img_id], 1),
        ";".join(burst_flags[img_id]),
        burst_id,
        int(img_id in keepers),
        stars_of[img_id],
        ";".join(list((diag_tags or {}).get(img_id, [])) + [f"Why|{reason_of[img_id]}"]),
    ] for img_id in sorted_members]

    with open(results_path, "a", newline="", encoding="utf-8") as f:
        csv.writer(f).writerows(burst_rows)
    return burst_keepers


REPORT_HEADER = ["burst", "file", "rank", "of", "score", "stars", "keeper", "flags", "tags", "why", "folder", "reason", "car",
                 "direction", "id", "subject", "motion", "straightness", "crop", "subject_own"]


def report_rows(manifest, result_rows, keepers_per_burst, direction_of=None, parts_of=None) -> list:
    """One row per scored frame, bursts in manifest order and frames best first, saying why it
    was kept or not. stars is "leave" for a non-keeper the run left alone. reason is the
    frame's Why tag (WHY_REASONS); car is the car number the frame was pooled under, "" if none;
    direction is the burst's travel direction (left, right, unknown), "" without a detector.
    id is darktable's image id (capture order within a film roll). subject, motion,
    straightness and crop are motion_aware's score parts (parts_of), blank in other modes:
    eval_culling.py re-ranks from them. subject is at the burst's shared size (same_scale,
    crop "WxH → size"); subject_own is at the crop's own size. These are last so older readers
    of the columns keep working."""
    file_of = {row[0]: row[1] for row in manifest}
    car_of = {row[0]: row[9] for row in manifest}
    by_burst = {}
    for row in result_rows:
        if len(row) >= 6:
            by_burst.setdefault(row[3], []).append(row)
    # the keeper allowance comes from the whole burst, as in score_manifest, unreadable frames included
    burst_size = {}
    for row in manifest:
        burst_size[row[2]] = burst_size.get(row[2], 0) + 1
    out = []
    for burst_id in burst_size:
        rows = sorted(by_burst.get(burst_id, []), key=lambda r: -float(r[1]))
        allowed = keepers_per_burst(burst_size[burst_id])
        for rank, (img_id, score, flags, _burst, keeper, stars, *rest) in enumerate(rows, 1):
            tags = rest[0] if rest else ""
            reason = next((t[4:] for t in tags.split(";") if t.startswith("Why|")), "")
            why = ("left alone: no vehicle found" if reason == "No vehicle"
                   else f"kept: rank {rank} of {len(rows)}, the best of its stretch of the burst" if reason == "Spread"
                   else f"kept: rank {rank} of {len(rows)}, {allowed} allowed" if keeper == "1" and rank <= allowed
                   else f"kept: rank {rank} of {len(rows)}, within the keeper margin of the best" if keeper == "1"
                   else f"not kept: rank {rank} of {len(rows)}, only {allowed} allowed or not eligible")
            if reason == "Close call":
                why += "; close call with the next frame"
            if flags:
                why += f"; flagged {flags.replace(';', ', ')}"
            path = file_of.get(img_id, img_id)
            subject, cls, straight, crop, own = (*(parts_of or {}).get(img_id, ("", "", "", "")), "")[:5]
            out.append([burst_id, os.path.basename(path), rank, len(rows),
                        score, stars, "yes" if keeper == "1" else "no", flags, tags, why,
                        os.path.dirname(path), reason, car_of.get(img_id, ""),
                        (direction_of or {}).get(burst_id, ""), img_id,
                        "" if subject == "" else round(subject, 4), cls,
                        "" if straight == "" else round(straight, 4), crop, "" if own == "" else round(own, 4)])
    return out


REPORT_ARCHIVE_KEEP = 20  # reports kept under --report-archive-dir; the oldest are deleted


def archive_report(report_path, archive_dir, keep):
    """Copies the report to <archive_dir>/<YYYYMMDD-HHMMSS>.csv and deletes all but the newest
    `keep` archived reports. A failure is logged, never fatal: last-run.csv is already written."""
    try:
        os.makedirs(archive_dir, exist_ok=True)
        dest = os.path.join(archive_dir, time.strftime("%Y%m%d-%H%M%S") + ".csv")
        shutil.copy2(report_path, dest)
        runs = sorted(n for n in os.listdir(archive_dir) if re.fullmatch(r"\d{8}-\d{6}\.csv", n))
        for old in runs[:-keep]:
            os.remove(os.path.join(archive_dir, old))
        log(f"archived report: {dest}")
    except OSError as e:
        log(f"couldn't archive the report: {e}")


def write_report(manifest, args, direction_of=None, parts_of=None):
    """Writes args.report (CSV, REPORT_HEADER) from the finished results file, then archives it
    when args.report_archive_dir is set; a failure is logged, never fatal, since the scores are
    already on their way back to darktable."""
    try:
        with open(args.results, newline="", encoding="utf-8") as f:
            result_rows = [row for row in csv.reader(f) if row]
        with atomic_write(args.report, newline="") as f:  # last-run.csv outlives the run; never half-written
            w = csv.writer(f)
            w.writerow(REPORT_HEADER)
            w.writerows(report_rows(manifest, result_rows, lambda n: keepers_allowed(args.keep_mode, n),
                                    direction_of, parts_of))
    except OSError as e:
        log(f"couldn't write the report {args.report}: {e}")
        return
    if getattr(args, "report_archive_dir", ""):
        archive_report(args.report, args.report_archive_dir, REPORT_ARCHIVE_KEEP)


def main(args):
    with open(args.manifest, newline="", encoding="utf-8") as f:
        manifest = [parse_manifest_row(row) for row in csv.reader(f) if row]

    total_images = len(manifest)
    if total_images == 0:
        write_progress(args.progress, 0, 0, 0, 0)
        return

    cache = ScoreCache(getattr(args, "cache", ""))
    detections = DetectionCache(getattr(args, "detections", ""))  # shared with tagging; "" = detect every run
    try:
        if getattr(args, "emit_saliency_points", False):
            emit_saliency_points(manifest, args, cache, detections)
        else:
            direction_of, parts_of = score_manifest(manifest, args, cache, detections)
            if getattr(args, "report", ""):
                write_report(manifest, args, direction_of, parts_of)
    finally:
        cache.close()
        detections.close()


def score_manifest(manifest, args, cache, detections):
    total_images = len(manifest)
    burst_groups = {}
    candidates_of = {}  # burst → shortlisted ids, only when the manifest carries a shortlist
    exif_of = {}  # burst → ([exposures], [apertures])
    shot_of = {}  # id → (exposure, focal length), for motion_aware's EXIF prior
    for image_id, filepath, burst_id, mask_path, shortlisted, edited, exposure, aperture, focal, car in manifest:
        burst_groups.setdefault(burst_id, []).append((image_id, filepath, mask_path, shortlisted, edited))
        shot_of[image_id] = (exposure, focal)
        exposures, apertures = exif_of.setdefault(burst_id, ([], []))
        exposures.append(exposure)
        apertures.append(aperture)
        if shortlisted:
            picks = candidates_of.setdefault(burst_id, set())
            if shortlisted == "1":
                picks.add(image_id)
    mode_of = {b: burst_sharp_mode(args.sharp_mode, *exif_of[b]) for b in burst_groups}

    total_bursts = len(burst_groups)

    if any(Path(row[1]).suffix.lower() in RAW_EXTENSIONS for row in manifest):
        try:
            import rawpy  # noqa: F401
        except ImportError:
            print(
                f"Missing Python package 'rawpy' in {sys.executable} (needed for RAW files). "
                f"Install with: \"{sys.executable}\" -m pip install rawpy",
                file=sys.stderr,
            )
            sys.exit(3)

    if args.sharp_mode == "face_detect" and not hasattr(cv2, "CascadeClassifier"):
        print(
            f"OpenCV {cv2.__version__} in {sys.executable} has no Haar face detector (removed in OpenCV 5), "
            f"which the face & eyes mode needs. Install with: \"{sys.executable}\" -m pip install \"opencv-python-headless<5\", "
            "or pick another sharpness mode.",
            file=sys.stderr,
        )
        sys.exit(3)

    burst_completion = {b_id: 0 for b_id in burst_groups}
    burst_sharpness = {b_id: {} for b_id in burst_groups}
    burst_flags = {b_id: {} for b_id in burst_groups}

    with open(args.results, "w", newline="", encoding="utf-8") as f:
        pass

    processed_count = 0
    completed_bursts = 0
    last_progress = 0.0
    write_progress(args.progress, 0, total_images, 0, total_bursts)

    cancel_path = (args.progress + ".cancel") if args.progress else ""
    workers = max(1, (os.cpu_count() or 2) - 1)

    def finish_burst(burst_id):
        nonlocal completed_bursts
        completed_bursts += 1
        raw = burst_sharpness[burst_id]
        if motion:
            size, subject_of = same_scale({i: ladder_of.pop(i) for i in list(raw) if i in ladder_of})
            for i, subject in subject_of.items():
                own, cls, straight, crop = parts_of[i]
                raw[i] = subject * class_factor(cls)
                parts_of[i] = (subject, cls, straight, f"{crop} → {size or 'own size'}", own)
            if subject_of and size is None:
                log(f"burst {burst_id}: a car crop is under {SUBJECT_SCALES[0]} px, so its frames are compared "
                    "at their smallest sizes, not one shared size")
        scores, eligible = resolve_burst_scores(raw, candidates_of.get(burst_id))
        burst_motion = motion_of.pop(burst_id, {})
        if burst_motion:
            scores = lift_motion_blur(scores, burst_motion)
        if detector:
            # framing is judged across the burst, so it's added here and never cached per frame
            ids = [item[0] for item in burst_groups[burst_id] if item[0] in raw]
            path_of = {item[0]: item[1] for item in burst_groups[burst_id]}
            direction, framing = framing_flags(
                [frame_boxes(car_filtered(detections.get(detection_key(path_of[i], detector_for(detector))),
                                          cars_of.get(path_key(path_of[i])))) for i in ids])
            direction_of[burst_id] = direction
            for i, extra in zip(ids, framing):
                if extra:
                    burst_flags[burst_id][i] = tuple(burst_flags[burst_id][i]) + extra
        no_vehicle = frozenset()
        if getattr(args, "no_vehicle_leave", False):
            no_vehicle = frozenset(i for i in raw if (sam and i in prescored and prescored[i][3] == NO_VEHICLE_SUBJECT)
                                   or burst_motion.get(i, (None, 0.0, False))[2])
            # an all-no-vehicle burst is left alone too; relative references skip these frames
            eligible = set(eligible) - no_vehicle
        # rejected whatever their score, so they set no relative reference either
        eligible = set(eligible) - blank_frames(burst_flags[burst_id], getattr(args, "tag_only_flags", frozenset()))
        burst_tags = []
        note = f"burst {burst_id}: {len(raw)} of {len(burst_groups[burst_id])} frames scored, mode {mode_of[burst_id]}"
        if mode_of[burst_id] != args.sharp_mode:
            burst_tags.append(technique_tag(mode_of[burst_id]))
            med = [float(np.median(known)) if (known := [v for v in vals if v > 0]) else 0.0
                   for vals in exif_of[burst_id]]
            note += f" from EXIF (median {med[0]:.4g} s, f/{med[1]:.3g}; 0 = unknown)"
        if sam:
            short = [k for k, v in raw.items() if isinstance(v, tuple) and k in candidates_of.get(burst_id, raw)]
            masked = sum(raw[k][0] is not None for k in short)
            used_masks = bool(short) and masked == len(short)
            burst_tags.append("Scored|Masked" if used_masks else "Scored|Subject bias")
            note += f", masked {masked} of {len(short)} shortlisted" + ("" if used_masks else ", so subject bias")
        diag = {i: ([prescored[i][3]] if i in prescored and prescored[i][3] else []) + burst_tags
                + ([MOTION_TAGS[burst_motion[i][0]]] if burst_motion.get(i, ("",))[0] in MOTION_TAGS else [])
                for i in raw}
        if args.rank_mode == "relative":
            # masked and fallback scores, and each sharpness mode, run on their own scales
            group = (mode_of[burst_id], sam and used_masks)
            relative_scores.setdefault(group, []).extend(scores[i] for i in eligible if i in scores)
            deferred.append((burst_id, scores, burst_flags[burst_id], eligible, diag, note, group, no_vehicle))
        else:
            keepers = process_burst_logic(burst_id, scores, burst_flags[burst_id], len(burst_groups[burst_id]),
                                          args, args.results, eligible, diag, mode=mode_of[burst_id],
                                          no_vehicle=no_vehicle)
            log(f"{note}, keepers {', '.join(keepers) or 'none'}"
                + (f", {len(no_vehicle)} left alone (no vehicle)" if no_vehicle else ""))
        del burst_sharpness[burst_id]
        del burst_flags[burst_id]
        if completed_bursts % 25 == 0:
            gc.collect()

    # sam_subject: every frame was already scored in the saliency pass, so only
    # frames with a fresh SAM mask are decoded again. The rest use that
    # fallback score, plus the cached masked score when there is one.
    sam = args.sharp_mode == "sam_subject"
    # relative mode rates against the whole selection, so its bursts wait for the last one
    deferred, relative_scores = [], {}
    prescored, stage_a_failed = read_prescores(getattr(args, "prescores", "")) if sam else ({}, set())

    # keyed on the burst's effective mode, so the EXIF rules and their
    # thresholds are part of the key without storing shutter or aperture
    motion = args.sharp_mode == "motion_aware"
    blank_share = getattr(args, "blank_share", BLANK_SHARE)
    detector = getattr(args, "detector", "") if motion else ""
    det_key = detector_key(detector)  # loads the model: a missing or corrupt one fails the run here, not the centre third on every frame
    cars_of, cars_note = read_car_boxes(getattr(args, "car_boxes", "")) if detector else ({}, "")
    motion_of = {}  # burst → {id: (class, straightness, no vehicle)}, motion_aware only
    direction_of = {}  # burst → travel direction (framing_flags), with a detector only
    parts_of = {}  # id → (subject sharpness, class, straightness, crop[, own-size subject]), motion_aware only, for the report
    ladder_of = {}  # id → scale_ladder until its burst is finished, motion_aware only
    det_hits = det_fresh = 0

    def score_key(filepath, burst_id, image_id):
        key = ("score", file_key(filepath), mode_of[burst_id], args.exp_mode, blank_share, args.fast_jpeg)
        if motion:
            # the EXIF prior and the detector change the class, so they key it
            key += (det_key, [round(v, 6) for v in shot_of[image_id]], *car_key(cars_of.get(path_key(filepath))))
        return key

    def keep_motion(burst_id, image_id, cls, straight, no_vehicle, subject, crop, ladder):
        motion_of.setdefault(burst_id, {})[image_id] = (cls, straight, no_vehicle)
        parts_of[image_id] = (subject, cls, straight, crop)
        ladder_of[image_id] = ladder

    def store(filepath, sharp, flags, image_id, mask_path, edited, burst_id):
        if motion:
            score, cls, straight, _, no_vehicle, subject, crop, ladder = sharp
            cache.put({"sharp": float(score), "flags": list(flags), "class": cls, "straight": straight,
                       "no_vehicle": no_vehicle, "subject": float(subject), "crop": crop,
                       "ladder": [[s, float(v)] for s, v in ladder]},
                      *score_key(filepath, burst_id, image_id))
        elif not sam:
            cache.put({"sharp": float(sharp), "flags": list(flags)}, *score_key(filepath, burst_id, image_id))
        elif mask_path and image_id in prescored:
            # None (mask unusable) is cached too: the same inputs give the same mask
            masked = None if sharp[0] is None else float(sharp[0])
            cache.put({"masked": masked}, *masked_key(filepath, args, prescored[image_id][2], edited))

    with concurrent.futures.ProcessPoolExecutor(max_workers=workers, initializer=_init_worker,
                                                initargs=(detector,)) as executor:
        future_to_item = {}
        for burst_id, items in burst_groups.items():
            for image_id, filepath, mask_path, shortlisted, edited in items:
                known = None
                if sam and not mask_path and image_id in stage_a_failed:
                    # stage A couldn't decode it (logged there); a second decode would fail too
                    processed_count += 1
                    burst_completion[burst_id] += 1
                    continue
                if sam and not mask_path and image_id in prescored:
                    fallback, flags, prompt, _ = prescored[image_id]
                    hit = cache.get(*masked_key(filepath, args, prompt, edited)) if shortlisted == "1" else None
                    known = ((hit["masked"] if hit else None, fallback), tuple(filter(None, flags.split(";"))))
                elif not sam:
                    hit = cache.get(*score_key(filepath, burst_id, image_id))
                    # a motion entry cached before its score parts were stored is scored again
                    if hit and (not motion or "ladder" in hit):
                        known = (hit["sharp"], tuple(hit["flags"]))
                        if motion:
                            keep_motion(burst_id, image_id, hit["class"], hit["straight"], hit["no_vehicle"],
                                        hit["subject"], hit["crop"], hit["ladder"])
                if known:
                    burst_sharpness[burst_id][image_id], burst_flags[burst_id][image_id] = known
                    processed_count += 1
                    burst_completion[burst_id] += 1
                    continue
                stored = detections.get(detection_key(filepath, detector_for(detector))) if detector else None
                det_hits += stored is not None
                fut = executor.submit(process_single_image, filepath, mode_of[burst_id], args.exp_mode,
                                      cancel_path, args.fast_jpeg, mask_path, detector, *shot_of[image_id],
                                      detections=stored, blank_share=blank_share,
                                      cars=cars_of.get(path_key(filepath)))
                future_to_item[fut] = (burst_id, image_id, filepath, mask_path, edited)
        log(f"scoring: {total_images} frames in {total_bursts} bursts, {processed_count} from cache or stage A, "
            f"{len(future_to_item)} to decode, sharpness {args.sharp_mode}")
        for burst_id in list(burst_sharpness):
            if burst_completion[burst_id] == len(burst_groups[burst_id]):
                finish_burst(burst_id)

        for future in concurrent.futures.as_completed(future_to_item):
            if cancel_requested(args.progress):
                log("cancelled")
                executor.shutdown(wait=False, cancel_futures=True)
                sys.exit(130)

            burst_id, image_id, filepath, mask_path, edited = future_to_item[future]
            try:
                _, sharp, flags, err, fresh = future.result()
            except concurrent.futures.CancelledError:
                continue
            if fresh is not None:
                detections.put(fresh, detection_key(filepath, detector_for(detector)))
                det_fresh += 1
            if err == "cancelled":
                executor.shutdown(wait=False, cancel_futures=True)
                sys.exit(130)

            if err:
                log(f"skip {image_id} ({filepath}): {err}")
            else:
                store(filepath, sharp, flags, image_id, mask_path, edited, burst_id)
                if motion:
                    score, cls, straight, detail, no_vehicle, subject, crop, ladder = sharp
                    keep_motion(burst_id, image_id, cls, straight, no_vehicle, subject, crop, ladder)
                    log(f"motion {image_id} ({os.path.basename(filepath)}): {detail}")
                    sharp = score
                burst_sharpness[burst_id][image_id] = sharp
                burst_flags[burst_id][image_id] = flags

            processed_count += 1
            burst_completion[burst_id] += 1

            if burst_completion[burst_id] == len(burst_groups[burst_id]):
                finish_burst(burst_id)

            now = time.monotonic()
            if now - last_progress >= 0.1 or processed_count == total_images:
                last_progress = now
                write_progress(args.progress, processed_count, total_images, completed_bursts, total_bursts)

    if detector:
        log(f"detections: {det_hits} cached, {det_fresh} detected")
        log_car_check(manifest, detections, detector, cars_of, cars_note)
    references = relative_references(relative_scores)
    for (mode, masked), values in relative_scores.items():
        label = f"{mode}{' masked' if masked else ''} ({len(values)} frames)"
        ref = references.get((mode, masked))
        if ref is None:
            log(f"relative: {label} is under {RELATIVE_MIN_FRAMES} frames, so its bursts take the universal "
                f"tiers of {mode}")
        elif ref <= 0:
            log(f"relative: every frame scores 0 for {label}, so 0 stars")
        else:
            log(f"relative: {ref:.1f} sharpness is 100 points for {label}")
    for burst_id, scores, flags, eligible, diag, note, group, no_vehicle in deferred:
        keepers = process_burst_logic(burst_id, scores, flags, len(burst_groups[burst_id]),
                                      args, args.results, eligible, diag, references.get(group), mode=group[0],
                                      no_vehicle=no_vehicle)
        log(f"{note}, keepers {', '.join(keepers) or 'none'}"
            + (f", {len(no_vehicle)} left alone (no vehicle)" if no_vehicle else ""))
    return direction_of, parts_of


if __name__ == "__main__":
    # redirected stderr on Windows is cp1252: a filename outside it must not crash a log line
    sys.stderr.reconfigure(errors="backslashreplace")
    parser = argparse.ArgumentParser(description="Assisted Culling Scorer")
    parser.add_argument("manifest", help="Path to manifest CSV")
    parser.add_argument("results", help="Path to results output CSV")
    parser.add_argument("--progress", default="", help="Path for progress tracking")
    parser.add_argument("--rank-mode", default="universal", help="Ranking logic mode")
    parser.add_argument("--sharp-mode", default="subject_focus", help="Sharpness evaluation mode")
    parser.add_argument("--exp-mode", default="whole_frame", help="Exposure evaluation mode")
    parser.add_argument("--keep-mode", default="dynamic_burst", help="Keeper allowance logic")
    parser.add_argument("--nk-mode", default="leave", help="Handling for non-keepers")
    parser.add_argument("--fast-jpeg", action="store_true",
                        help="Decode JPEGs at reduced scale (faster; scores shift slightly)")
    parser.add_argument("--emit-saliency-points", action="store_true",
                        help="Write id,x0,y0,x1,y1,cached SAM prompts to the results path instead of scoring")
    parser.add_argument("--star-scale", default=1.0, type=float,
                        help="Multiplies every sharpness threshold a star needs (universal and relative "
                             "ranking) and the steps graded non-keepers drop by: above 1 is stricter, below 1 more generous")
    parser.add_argument("--keep-margin", default=0.0, type=float,
                        help="Also keep every eligible frame scoring at least this share of its burst's best (0 = off)")
    parser.add_argument("--spread-keepers", action="store_true",
                        help="Keep one frame per equal time slice of each burst instead of the top frames by "
                             "score, where the slice's best scores at least CLOSE_CALL_SHARE of the burst's best")
    parser.add_argument("--no-vehicle-leave", action="store_true",
                        help="A frame where the detector found no car (motion_aware, or sam_subject with a "
                             "detector) is never a keeper and keeps its rating, tagged Why|No vehicle")
    parser.add_argument("--detector", default="",
                        help="object detector .onnx (YOLOX, D-FINE or RT-DETR) whose most prominent vehicle box "
                             "prompts SAM (--emit-saliency-points) or locates the car (motion_aware); "
                             "frames without one fall back to the saliency point or the centre third")
    parser.add_argument("--detections", default="",
                        help="SQLite cache of per-frame detections shared with the tagging plugin (empty = detect every run)")
    parser.add_argument("--car-boxes", default="",
                        help="tagging's last boxes.json: score only detector boxes its car check kept (empty = raw boxes)")
    parser.add_argument("--prescores", default="",
                        help="sam_subject: per-frame fallback scores written by the saliency pass "
                             "and read by the scoring pass, so frames outside the shortlist decode once")
    parser.add_argument("--cache", default="",
                        help="SQLite file of per-frame scores reused across runs (created if missing)")
    parser.add_argument("--report", default="",
                        help="CSV listing every scored frame with its rank in the burst and why it was kept or not")
    parser.add_argument("--report-archive-dir", default="",
                        help="folder that keeps a timestamped copy of each run's --report (newest 20)")
    parser.add_argument("--sam-model", default="",
                        help="sam_subject: id of darktable's SAM model, part of the masked-score cache key")
    parser.add_argument("--tag-only-flags", default="", type=lambda s: frozenset(filter(None, s.split(","))),
                        help="Comma-separated flags that are still listed but never cost stars")
    parser.add_argument("--blank-share", default=BLANK_SHARE, type=float,
                        help="Flag a frame blank (rejected, Why|Blank) when at least this share of its pixels "
                             "is one flat colour (0 = off)")

    args = parser.parse_args()
    unknown = args.tag_only_flags - set(FLAG_PENALTIES)
    if unknown:
        parser.error(f"unknown --tag-only-flags: {', '.join(sorted(unknown))}")

    try:
        main(args)
    except Exception:
        import traceback
        traceback.print_exc()
        sys.exit(1)