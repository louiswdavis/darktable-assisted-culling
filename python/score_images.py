#!/usr/bin/env python3
"""
score_images.py — burst-by-burst sharpness/exposure scorer for the darktable Assisted Culling plugin.
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


def _open_rgb(source, fast_jpeg: bool) -> np.ndarray:
    img = Image.open(source)
    if fast_jpeg:
        try:
            # JPEG only: decode at 1/2, 1/4 or 1/8 scale (never below MAX_DIM); no-op for other formats
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


def sharpness_score(rgb: np.ndarray, mode: str) -> float:
    gray = cv2.cvtColor(rgb, cv2.COLOR_RGB2GRAY)
    denoised = cv2.bilateralFilter(gray, 5, 50, 50)

    if mode == "center":
        h, w = gray.shape
        crop = denoised[int(h * 0.25):int(h * 0.75), int(w * 0.25):int(w * 0.75)]
        lap = cv2.Laplacian(crop, cv2.CV_64F)
        return float(lap.var())
    if mode == "peak":
        lap = cv2.Laplacian(denoised, cv2.CV_64F)
        return float(np.percentile(np.abs(lap), 99))

    h, w = denoised.shape
    h_step, w_step = h // 3, w // 3
    patch_vars = []
    for r in range(3):
        for c in range(3):
            patch = denoised[r * h_step:(r + 1) * h_step, c * w_step:(c + 1) * w_step]
            if patch.size > 0:
                patch_vars.append(float(cv2.Laplacian(patch, cv2.CV_64F).var()))
    if patch_vars:
        return float(np.max(patch_vars) * 0.85 + np.median(patch_vars) * 0.15)
    return float(cv2.Laplacian(denoised, cv2.CV_64F).var())


def exposure_status(rgb: np.ndarray, mode: str) -> str:
    if mode == "none":
        return "ok"
    gray = cv2.cvtColor(rgb, cv2.COLOR_RGB2GRAY).astype(np.float32) / 255.0
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
    """Each worker is already a separate process; stop OpenCV oversubscribing cores."""
    try:
        cv2.setNumThreads(1)
    except Exception:
        pass


def process_single_image(filepath: str, sharp_mode: str, exp_mode: str, cancel_path: str = "", fast_jpeg: bool = False):
    """Worker function for concurrent processing."""
    if cancel_path and os.path.exists(cancel_path):
        return filepath, None, None, "cancelled"
    try:
        rgb = load_image(filepath, fast_jpeg)
        sharp = sharpness_score(rgb, sharp_mode)
        exp = exposure_status(rgb, exp_mode)
        return filepath, sharp, exp, None
    except Exception as e:
        return filepath, None, None, str(e)


def process_burst_logic(burst_id, burst_sharpness, burst_exposure, burst_size, args, results_path):
    """Handles the keeper selection and CSV appending once a burst is fully scored."""
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

    # Identify all keepers in order of sharpness
    burst_keepers = [i for i in sorted_members if i in keepers]
    num_keepers = len(burst_keepers)
    top_40_count = max(1, int(round(num_keepers * 0.4)))

    computed_stars = {}
    for img_id in burst_sharpness:
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

        computed_stars[img_id] = stars

    # Get the star rating of the absolute best keeper
    best_keeper_star = computed_stars[burst_keepers[0]] if burst_keepers else 0

    burst_rows = []
    for img_id in sorted_members:
        is_keeper = img_id in keepers
        raw_score = burst_sharpness[img_id]
        stars = computed_stars[img_id]

        if is_keeper:
            # If this keeper is past the top 40% and shares the best keeper's star rating, demote by 1 star
            if num_keepers > 1 and img_id in burst_keepers[top_40_count:]:
                if stars == best_keeper_star:
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
        manifest = [(row[0], row[1], row[2]) for row in csv.reader(f) if row]

    total_images = len(manifest)
    if total_images == 0:
        write_progress(args.progress, 0, 0, 0, 0)
        return

    burst_groups = {}
    for image_id, filepath, burst_id in manifest:
        burst_groups.setdefault(burst_id, []).append((image_id, filepath))

    total_bursts = len(burst_groups)

    # Pre-flight: fail fast with a clear message if RAW support is missing.
    if any(Path(fp).suffix.lower() in RAW_EXTENSIONS for _, fp, _ in manifest):
        try:
            import rawpy  # noqa: F401
        except ImportError:
            print(
                f"Missing Python package 'rawpy' in {sys.executable} (needed for RAW files). "
                f"Install with: \"{sys.executable}\" -m pip install rawpy",
                file=sys.stderr,
            )
            sys.exit(3)
    
    # Track completion state for cross-burst concurrency
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
    workers = max(1, (os.cpu_count() or 2) - 1)  # leave a core for darktable's UI

    with concurrent.futures.ProcessPoolExecutor(max_workers=workers, initializer=_init_worker) as executor:
        # Submit ALL images to the executor instantly to fully saturate all CPU cores
        future_to_item = {}
        for burst_id, items in burst_groups.items():
            for image_id, filepath in items:
                fut = executor.submit(process_single_image, filepath, args.sharp_mode, args.exp_mode, cancel_path, args.fast_jpeg)
                future_to_item[fut] = (burst_id, image_id, filepath)

        for future in concurrent.futures.as_completed(future_to_item):
            if cancel_requested(args.progress):
                print("cancelled", file=sys.stderr)
                # drop everything still queued; only in-flight images finish
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

            # When a burst reaches its total count, trigger its logic and write to CSV
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
                
                # Free memory immediately for completed bursts
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

    args = parser.parse_args()

    try:
        main(args)
    except Exception:
        import traceback
        traceback.print_exc()
        sys.exit(1)