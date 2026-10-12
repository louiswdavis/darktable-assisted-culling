#!/usr/bin/env python3
"""
score_images.py — burst-by-burst sharpness/exposure scorer for the darktable Assisted Culling plugin.

With --emit-saliency-points the second positional argument is the output path
for id,x_frac,y_frac subject points (the SAM prompt pre-pass), not results.
"""

import argparse
import csv
import gc
import io
import os
import sys
import time
import concurrent.futures
from pathlib import Path

try:
    import numpy as np
    import cv2
    from PIL import Image, ImageOps
except ImportError as _e:
    print(
        f"Missing Python package '{_e.name or _e}' in {sys.executable}. "
        f"Install with: \"{sys.executable}\" -m pip install opencv-python-headless numpy Pillow rawpy",
        file=sys.stderr,
    )
    sys.exit(3)

RAW_EXTENSIONS = {".cr2", ".cr3", ".nef", ".arw", ".rw2", ".dng", ".raf", ".orf"}
MAX_DIM = 800
SHADOW_CLIP = 5 / 255
HIGHLIGHT_CLIP = 250 / 255
CLIP_PCT_FLAG = 0.02

STAR_THRESHOLDS = [(95, 5), (85, 4), (75, 3), (60, 2), (45, 1), (0, 0)]

TIER_THRESHOLDS = [
    (1800, 5),
    (1000, 4),
    (550, 3),
    (200, 2),
    (70, 1),
    (0, 0),
]

# Per-frame problem flags → (points off the relative-mode score, stars off in
# tier mode). A frame pays for every flag it carries. Relative-mode keepers
# start at 100, so 15 points is one star (STAR_THRESHOLDS) and 30 is three.
# The results CSV lists a frame's flags in column 3; culling.lua maps each to a tag.
FLAG_PENALTIES = {
    "overexposed": (30, 1),
    "underexposed": (30, 1),
    "eyes_closed": (15, 1),
}


def frame_flags(exposure: str, eyes_closed: bool = False) -> tuple:
    flags = () if exposure == "ok" else (exposure,)
    return flags + ("eyes_closed",) if eyes_closed else flags


def penalised_flags(burst_flags: dict, tag_only=frozenset()) -> dict:
    """id → the flags that cost that frame stars. Tag-only flags never do, nor
    does a flag every frame of a multi-frame burst shares: a burst that's all
    dark or all eyes-closed was most likely shot that way on purpose."""
    shared = set.intersection(*map(set, burst_flags.values())) if len(burst_flags) > 1 else set()
    exempt = shared | set(tag_only)
    return {i: tuple(f for f in flags if f not in exempt) for i, flags in burst_flags.items()}

SALIENCY_GRID = 5


def _open_rgb(source, fast_jpeg: bool) -> tuple:
    """(rgb array upright per EXIF orientation, whether the file carried a rotation)."""
    img = Image.open(source)
    if fast_jpeg:
        try:
            img.draft("RGB", (MAX_DIM, MAX_DIM))
        except Exception:
            pass
    rotated = img.getexif().get(0x0112, 1) not in (0, 1)
    return np.array(ImageOps.exif_transpose(img).convert("RGB")), rotated


# LibRaw's sizes.flip codes → the np.rot90 turns (counter-clockwise) that make the image upright
_RAW_FLIP_TURNS = {3: 2, 5: 1, 6: 3}


def load_image(filepath: str, fast_jpeg: bool = False) -> np.ndarray:
    """Decoded image, downscaled and upright, so it matches the orientation
    darktable's own pipeline (and therefore the SAM masks) uses."""
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
    else:
        rgb, _ = _open_rgb(filepath, fast_jpeg)

    h, w = rgb.shape[:2]
    scale = MAX_DIM / max(h, w)
    if scale < 1:
        rgb = cv2.resize(rgb, (int(w * scale), int(h * scale)), interpolation=cv2.INTER_AREA)
    return rgb


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
    # mid-frame (subject_focus, and the fallback for face_detect / sam_subject).
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


def _init_worker():
    try:
        cv2.setNumThreads(1)
    except Exception:
        pass


SHORTLIST_MIN = 3


def keepers_allowed(keep_mode: str, burst_size: int) -> int:
    if keep_mode == "dynamic_burst":
        return 1 if burst_size <= 4 else (2 if burst_size <= 8 else (3 if burst_size <= 12 else (4 if burst_size <= 18 else 5)))
    if keep_mode == "portrait_mode":
        return 1 if burst_size <= 3 else 2
    if keep_mode == "single_best":
        return 1
    return burst_size


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
    """(id, filepath, burst_id, mask_path, shortlisted). The last two are ""
    when absent; shortlisted is "1"/"0" only in sam_subject runs."""
    return (row[0], row[1], row[2],
            row[3] if len(row) > 3 else "",
            row[4] if len(row) > 4 else "")


def process_single_image(filepath: str, sharp_mode: str, exp_mode: str, cancel_path: str = "",
                         fast_jpeg: bool = False, mask_path: str = ""):
    if cancel_path and os.path.exists(cancel_path):
        return filepath, None, None, "cancelled"
    try:
        rgb = load_image(filepath, fast_jpeg)
        eyes_closed = False
        if sharp_mode == "face_detect":
            sharp, eyes_closed = face_detect_score(rgb)
        elif sharp_mode == "sam_subject":
            # both scores, so the burst can settle on one scale once every frame is in
            gray = cv2.bilateralFilter(cv2.cvtColor(rgb, cv2.COLOR_RGB2GRAY), 5, 50, 50)
            masked = _masked_sharpness(gray, mask_path) if mask_path else None
            sharp = (masked, sharpness_score(rgb, "subject_focus"))
        else:
            sharp = sharpness_score(rgb, sharp_mode, mask_path)
        return filepath, sharp, frame_flags(exposure_status(rgb, exp_mode), eyes_closed), None
    except Exception as e:
        return filepath, None, None, str(e)


def process_single_saliency(filepath: str, fast_jpeg: bool = False, exp_mode: str = "whole_frame"):
    try:
        rgb = load_image(filepath, fast_jpeg)
        return (filepath, saliency_point(rgb), sharpness_score(rgb, "subject_focus"),
                exposure_status(rgb, exp_mode), None)
    except Exception as e:
        return filepath, None, None, None, str(e)


def read_prescores(path: str) -> dict:
    """id → (fallback sharpness, exposure status) from a stage-A prescore file."""
    if not path or not os.path.exists(path):
        return {}
    with open(path, newline="", encoding="utf-8") as f:
        return {row[0]: (float(row[1]), row[2]) for row in csv.reader(f) if len(row) == 3}


def emit_saliency_points(manifest, args):
    """Writes id,x_frac,y_frac to args.results for each burst's shortlist: the
    frames worth running SAM on, picked by the center-weighted heuristic.
    With args.prescores, also writes id,fallback_score,exposure for every frame
    so the scoring pass needn't decode frames outside the shortlist again.
    Images that fail to decode are left out and so can't be keepers."""
    total = len(manifest)
    prescores = getattr(args, "prescores", "")
    exp_mode = getattr(args, "exp_mode", "whole_frame")
    for path in (args.results, prescores):
        if path:
            with open(path, "w", newline="", encoding="utf-8"):
                pass
    write_progress(args.progress, 0, total, 0, 0)

    burst_of = {row[0]: row[2] for row in manifest}
    remaining = {}
    for row in manifest:
        remaining[row[2]] = remaining.get(row[2], 0) + 1
    found = {b: {} for b in remaining}  # burst → id → (point, heuristic score)

    workers = max(1, (os.cpu_count() or 2) - 1)
    done = 0
    with concurrent.futures.ProcessPoolExecutor(max_workers=workers, initializer=_init_worker) as executor:
        future_to_id = {
            executor.submit(process_single_saliency, row[1], args.fast_jpeg, exp_mode): row[0]
            for row in manifest
        }
        for future in concurrent.futures.as_completed(future_to_id):
            if cancel_requested(args.progress):
                print("cancelled", file=sys.stderr)
                executor.shutdown(wait=False, cancel_futures=True)
                sys.exit(130)
            image_id = future_to_id[future]
            burst = burst_of[image_id]
            filepath, point, heuristic, exposure, err = future.result()
            if err:
                print(f"skip saliency {image_id} ({filepath}): {err}", file=sys.stderr)
            else:
                found[burst][image_id] = (point, heuristic)
                if prescores:
                    with open(prescores, "a", newline="", encoding="utf-8") as f:
                        csv.writer(f).writerow([image_id, heuristic, exposure])
            remaining[burst] -= 1
            if remaining[burst] == 0 and found[burst]:
                picks = shortlist({i: v[1] for i, v in found[burst].items()}, args.keep_mode)
                with open(args.results, "a", newline="", encoding="utf-8") as f:
                    w = csv.writer(f)
                    for i in sorted(picks):
                        x, y = found[burst][i][0]
                        w.writerow([i, round(x, 4), round(y, 4)])
                del found[burst]
            done += 1
            write_progress(args.progress, done, total, 0, 0)


def process_burst_logic(burst_id, burst_sharpness, burst_flags, burst_size, args, results_path,
                        eligible=None):
    if not burst_sharpness:
        return

    allowed = keepers_allowed(args.keep_mode, burst_size)
    if eligible is None:
        eligible = set(burst_sharpness)

    sorted_members = sorted(burst_sharpness.keys(),
                            key=lambda i: (i in eligible, burst_sharpness[i]), reverse=True)
    keepers = set([i for i in sorted_members if i in eligible][:allowed])

    burst_keepers = [i for i in sorted_members if i in keepers]
    num_keepers = len(burst_keepers)
    top_40_count = max(1, int(round(num_keepers * 0.4)))
    top_40_keepers = set(burst_keepers[:top_40_count])
    penalised = penalised_flags(burst_flags, getattr(args, "tag_only_flags", frozenset()))

    burst_rows = []
    for img_id in sorted_members:
        is_keeper = img_id in keepers
        raw_score = burst_sharpness[img_id]
        flags = burst_flags[img_id]

        if args.rank_mode == "relative":
            score = 100.0 if is_keeper else 0.0
            score -= sum(FLAG_PENALTIES[f][0] for f in penalised[img_id])
            for threshold, stars in STAR_THRESHOLDS:
                if max(0, score) >= threshold:
                    break
            else:
                stars = 0
        else:
            for threshold, stars in TIER_THRESHOLDS:
                if raw_score >= threshold:
                    break
            else:
                stars = 0
            stars = max(0, stars - sum(FLAG_PENALTIES[f][1] for f in penalised[img_id]))

        if is_keeper:
            if args.keep_mode != "keep_all" and num_keepers > 1 and img_id not in top_40_keepers:
                stars = max(0, stars - 1)
        else:
            if args.nk_mode == "leave":
                stars = "leave"
            elif args.nk_mode == "reject":
                stars = -1
            else:
                try:
                    stars = int(args.nk_mode)
                except ValueError:
                    stars = 0

        burst_rows.append([
            img_id,
            round(raw_score, 1),
            ";".join(flags),
            burst_id,
            int(is_keeper),
            stars,
        ])

    with open(results_path, "a", newline="", encoding="utf-8") as f:
        csv.writer(f).writerows(burst_rows)


def main(args):
    with open(args.manifest, newline="", encoding="utf-8") as f:
        manifest = [parse_manifest_row(row) for row in csv.reader(f) if row]

    total_images = len(manifest)
    if total_images == 0:
        write_progress(args.progress, 0, 0, 0, 0)
        return

    if getattr(args, "emit_saliency_points", False):
        emit_saliency_points(manifest, args)
        return

    burst_groups = {}
    candidates_of = {}  # burst → shortlisted ids, only when the manifest carries a shortlist
    for image_id, filepath, burst_id, mask_path, shortlisted in manifest:
        burst_groups.setdefault(burst_id, []).append((image_id, filepath, mask_path, shortlisted))
        if shortlisted:
            picks = candidates_of.setdefault(burst_id, set())
            if shortlisted == "1":
                picks.add(image_id)

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
            f"which the face & eyes mode needs. Install with: \"{sys.executable}\" -m pip install \"opencv-python-headless<5\"",
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
        scores, eligible = resolve_burst_scores(burst_sharpness[burst_id], candidates_of.get(burst_id))
        process_burst_logic(burst_id, scores, burst_flags[burst_id], len(burst_groups[burst_id]),
                            args, args.results, eligible)
        del burst_sharpness[burst_id]
        del burst_flags[burst_id]
        if completed_bursts % 25 == 0:
            gc.collect()

    # sam_subject: frames outside the shortlist were already scored in the
    # saliency pass, so they aren't decoded again.
    prescored = read_prescores(getattr(args, "prescores", "")) if args.sharp_mode == "sam_subject" else {}

    with concurrent.futures.ProcessPoolExecutor(max_workers=workers, initializer=_init_worker) as executor:
        future_to_item = {}
        for burst_id, items in burst_groups.items():
            for image_id, filepath, mask_path, shortlisted in items:
                if shortlisted == "0" and image_id in prescored:
                    fallback, exp = prescored[image_id]
                    burst_sharpness[burst_id][image_id] = (None, fallback)
                    burst_flags[burst_id][image_id] = frame_flags(exp)
                    processed_count += 1
                    burst_completion[burst_id] += 1
                    continue
                fut = executor.submit(process_single_image, filepath, args.sharp_mode, args.exp_mode,
                                      cancel_path, args.fast_jpeg, mask_path)
                future_to_item[fut] = (burst_id, image_id, filepath)
        for burst_id in list(burst_sharpness):
            if burst_completion[burst_id] == len(burst_groups[burst_id]):
                finish_burst(burst_id)

        for future in concurrent.futures.as_completed(future_to_item):
            if cancel_requested(args.progress):
                print("cancelled", file=sys.stderr)
                executor.shutdown(wait=False, cancel_futures=True)
                sys.exit(130)

            burst_id, image_id, filepath = future_to_item[future]
            try:
                _, sharp, flags, err = future.result()
            except concurrent.futures.CancelledError:
                continue
            if err == "cancelled":
                executor.shutdown(wait=False, cancel_futures=True)
                sys.exit(130)

            if err:
                print(f"skip {image_id} ({filepath}): {err}", file=sys.stderr)
            else:
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


if __name__ == "__main__":
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
                        help="Write id,x_frac,y_frac to the results path instead of scoring")
    parser.add_argument("--prescores", default="",
                        help="sam_subject: per-frame fallback scores written by the saliency pass "
                             "and read by the scoring pass, so frames outside the shortlist decode once")
    parser.add_argument("--tag-only-flags", default="", type=lambda s: frozenset(filter(None, s.split(","))),
                        help="Comma-separated flags that are still listed but never cost stars")

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