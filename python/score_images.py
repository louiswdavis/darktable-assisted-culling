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
    from PIL import Image
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
EXPOSURE_PENALTY_RELATIVE = 30

TIER_THRESHOLDS = [
    (1800, 5),
    (1000, 4),
    (550, 3),
    (200, 2),
    (70, 1),
    (0, 0),
]
EXPOSURE_PENALTY_STARS = 1

SALIENCY_GRID = 5


def _open_rgb(source, fast_jpeg: bool) -> np.ndarray:
    img = Image.open(source)
    if fast_jpeg:
        try:
            img.draft("RGB", (MAX_DIM, MAX_DIM))
        except Exception:
            pass
    return np.array(img.convert("RGB"))


def load_image(filepath: str, fast_jpeg: bool = False) -> np.ndarray:
    ext = Path(filepath).suffix.lower()
    if ext in RAW_EXTENSIONS:
        import rawpy
        with rawpy.imread(filepath) as raw:
            try:
                thumb = raw.extract_thumb()
                if thumb.format == rawpy.ThumbFormat.JPEG:
                    rgb = _open_rgb(io.BytesIO(thumb.data), fast_jpeg)
                elif thumb.format == rawpy.ThumbFormat.BITMAP:
                    rgb = thumb.data
                else:
                    raise ValueError("Unsupported thumbnail")
            except Exception:
                rgb = raw.postprocess(half_size=True, use_camera_wb=True, no_auto_bright=True)
    else:
        rgb = _open_rgb(filepath, fast_jpeg)

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


def _face_eye_sharpness(gray: np.ndarray, denoised: np.ndarray):
    """Laplacian variance over the largest detected face's eye region, falling
    back to the whole face box if no eyes are found. Returns None if no face
    is detected, so the caller can fall back to the frame-wide heuristic."""
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

    eyes = _cascade("haarcascade_eye.xml").detectMultiScale(
        gray[y:y + fh, x:x + fw], scaleFactor=1.1, minNeighbors=5,
    )
    if len(eyes) > 0:
        ex0 = min(e[0] for e in eyes)
        ey0 = min(e[1] for e in eyes)
        ex1 = max(e[0] + e[2] for e in eyes)
        ey1 = max(e[1] + e[3] for e in eyes)
        eye_crop = face_crop[ey0:ey1, ex0:ex1]
        if eye_crop.size > 0:
            return float(cv2.Laplacian(eye_crop, cv2.CV_64F).var())

    return float(cv2.Laplacian(face_crop, cv2.CV_64F).var())


def _masked_sharpness(denoised: np.ndarray, mask_path: str):
    """Laplacian variance inside a SAM mask PNG, or None if the mask is missing,
    unreadable or empty, so the caller can fall back to the heuristic."""
    mask = cv2.imread(mask_path, cv2.IMREAD_GRAYSCALE) if os.path.exists(mask_path) else None
    if mask is None:
        return None
    h, w = denoised.shape
    inside = cv2.resize(mask, (w, h), interpolation=cv2.INTER_NEAREST) > 127
    if not inside.any():
        return None
    return float(cv2.Laplacian(denoised, cv2.CV_64F)[inside].var())


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
        face_score = _face_eye_sharpness(gray, denoised)
        if face_score is not None:
            return face_score
        # no face in frame: fall through to the frame-wide heuristic below

    # 3x3 patch grid. subject_focus (and sam_subject without a usable mask)
    # weights the center patches higher, assuming the subject sits mid-frame;
    # tiles_uniformity, and face_detect when no face was found, weight every
    # patch equally.
    h_step, w_step = h // 3, w // 3
    if mode in ("subject_focus", "sam_subject"):
        patch_weights = [[0.8, 1.0, 0.8], [1.0, 1.2, 1.0], [0.8, 1.0, 0.8]]
    else:
        patch_weights = [[1.0, 1.0, 1.0] for _ in range(3)]

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


def parse_manifest_row(row) -> tuple:
    """(id, filepath, burst_id, mask_path); mask_path is "" for 3-column rows."""
    return (row[0], row[1], row[2], row[3] if len(row) > 3 else "")


def process_single_image(filepath: str, sharp_mode: str, exp_mode: str, cancel_path: str = "",
                         fast_jpeg: bool = False, mask_path: str = ""):
    if cancel_path and os.path.exists(cancel_path):
        return filepath, None, None, "cancelled"
    try:
        rgb = load_image(filepath, fast_jpeg)
        sharp = sharpness_score(rgb, sharp_mode, mask_path)
        exp = exposure_status(rgb, exp_mode)
        return filepath, sharp, exp, None
    except Exception as e:
        return filepath, None, None, str(e)


def process_single_saliency(filepath: str, fast_jpeg: bool = False):
    try:
        return filepath, saliency_point(load_image(filepath, fast_jpeg)), None
    except Exception as e:
        return filepath, None, str(e)


def emit_saliency_points(manifest, args):
    """Writes id,x_frac,y_frac per image to args.results. Images that fail to
    decode are left out; the Lua side then scores them without a mask."""
    total = len(manifest)
    with open(args.results, "w", newline="", encoding="utf-8"):
        pass
    write_progress(args.progress, 0, total, 0, 0)
    workers = max(1, (os.cpu_count() or 2) - 1)
    done = 0
    with concurrent.futures.ProcessPoolExecutor(max_workers=workers, initializer=_init_worker) as executor:
        future_to_id = {
            executor.submit(process_single_saliency, row[1], args.fast_jpeg): row[0]
            for row in manifest
        }
        for future in concurrent.futures.as_completed(future_to_id):
            if cancel_requested(args.progress):
                print("cancelled", file=sys.stderr)
                executor.shutdown(wait=False, cancel_futures=True)
                sys.exit(130)
            image_id = future_to_id[future]
            filepath, point, err = future.result()
            if err:
                print(f"skip saliency {image_id} ({filepath}): {err}", file=sys.stderr)
            else:
                with open(args.results, "a", newline="", encoding="utf-8") as f:
                    csv.writer(f).writerow([image_id, round(point[0], 4), round(point[1], 4)])
            done += 1
            write_progress(args.progress, done, total, 0, 0)


def process_burst_logic(burst_id, burst_sharpness, burst_exposure, burst_size, args, results_path):
    if not burst_sharpness:
        return

    if args.keep_mode == "dynamic_burst":
        allowed = 1 if burst_size <= 4 else (2 if burst_size <= 8 else (3 if burst_size <= 12 else (4 if burst_size <= 18 else 5)))
    elif args.keep_mode == "portrait_mode":
        allowed = 1 if burst_size <= 3 else 2
    elif args.keep_mode == "single_best":
        allowed = 1
    else:
        allowed = burst_size

    sorted_members = sorted(burst_sharpness.keys(), key=lambda i: burst_sharpness[i], reverse=True)
    keepers = set(sorted_members[:allowed])

    burst_keepers = [i for i in sorted_members if i in keepers]
    num_keepers = len(burst_keepers)
    top_40_count = max(1, int(round(num_keepers * 0.4)))
    top_40_keepers = set(burst_keepers[:top_40_count])

    burst_rows = []
    for img_id in sorted_members:
        is_keeper = img_id in keepers
        raw_score = burst_sharpness[img_id]

        if args.rank_mode == "relative":
            score = 100.0 if is_keeper else 0.0
            if burst_exposure[img_id] != "ok":
                score -= EXPOSURE_PENALTY_RELATIVE
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
            if burst_exposure[img_id] != "ok":
                stars = max(0, stars - EXPOSURE_PENALTY_STARS)

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
            burst_exposure[img_id],
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
    for image_id, filepath, burst_id, mask_path in manifest:
        burst_groups.setdefault(burst_id, []).append((image_id, filepath, mask_path))

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
    
    burst_completion = {b_id: 0 for b_id in burst_groups}
    burst_sharpness = {b_id: {} for b_id in burst_groups}
    burst_exposure = {b_id: {} for b_id in burst_groups}

    with open(args.results, "w", newline="", encoding="utf-8") as f:
        pass

    processed_count = 0
    completed_bursts = 0
    last_progress = 0.0
    write_progress(args.progress, 0, total_images, 0, total_bursts)

    cancel_path = (args.progress + ".cancel") if args.progress else ""
    workers = max(1, (os.cpu_count() or 2) - 1)

    with concurrent.futures.ProcessPoolExecutor(max_workers=workers, initializer=_init_worker) as executor:
        future_to_item = {}
        for burst_id, items in burst_groups.items():
            for image_id, filepath, mask_path in items:
                fut = executor.submit(process_single_image, filepath, args.sharp_mode, args.exp_mode,
                                      cancel_path, args.fast_jpeg, mask_path)
                future_to_item[fut] = (burst_id, image_id, filepath)

        for future in concurrent.futures.as_completed(future_to_item):
            if cancel_requested(args.progress):
                print("cancelled", file=sys.stderr)
                executor.shutdown(wait=False, cancel_futures=True)
                sys.exit(130)

            burst_id, image_id, filepath = future_to_item[future]
            try:
                _, sharp, exp, err = future.result()
            except concurrent.futures.CancelledError:
                continue
            if err == "cancelled":
                executor.shutdown(wait=False, cancel_futures=True)
                sys.exit(130)

            if err:
                print(f"skip {image_id} ({filepath}): {err}", file=sys.stderr)
            else:
                burst_sharpness[burst_id][image_id] = sharp
                burst_exposure[burst_id][image_id] = exp

            processed_count += 1
            burst_completion[burst_id] += 1

            if burst_completion[burst_id] == len(burst_groups[burst_id]):
                completed_bursts += 1
                process_burst_logic(
                    burst_id, 
                    burst_sharpness[burst_id], 
                    burst_exposure[burst_id], 
                    len(burst_groups[burst_id]), 
                    args, 
                    args.results
                )
                
                del burst_sharpness[burst_id]
                del burst_exposure[burst_id]

                if completed_bursts % 25 == 0:
                    gc.collect()

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

    args = parser.parse_args()

    try:
        main(args)
    except Exception:
        import traceback
        traceback.print_exc()
        sys.exit(1)