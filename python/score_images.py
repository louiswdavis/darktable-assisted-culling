#!/usr/bin/env python3
"""
score_images.py — burst-by-burst sharpness/exposure scorer for the darktable AI Cull plugin.
"""

import csv
import gc
import io
import os
import sys
import time
from pathlib import Path

import numpy as np
import cv2
from PIL import Image

RAW_EXTENSIONS = {".cr2", ".cr3", ".nef", ".arw", ".rw2", ".dng", ".raf", ".orf"}
MAX_DIM = 800
SHADOW_CLIP = 5 / 255
HIGHLIGHT_CLIP = 250 / 255
CLIP_PCT_FLAG = 0.02

STAR_THRESHOLDS = [(95, 5), (87, 4), (75, 3), (62, 2), (45, 1), (0, 0)]
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


def load_image(filepath: str) -> np.ndarray:
    ext = Path(filepath).suffix.lower()
    if ext in RAW_EXTENSIONS:
        import rawpy
        with rawpy.imread(filepath) as raw:
            try:
                thumb = raw.extract_thumb()
                if thumb.format == rawpy.ThumbFormat.JPEG:
                    rgb = np.array(Image.open(io.BytesIO(thumb.data)).convert("RGB"))
                elif thumb.format == rawpy.ThumbFormat.BITMAP:
                    rgb = thumb.data
                else:
                    raise ValueError("Unsupported thumbnail")
            except Exception:
                rgb = raw.postprocess(half_size=True, use_camera_wb=True, no_auto_bright=True)
    else:
        rgb = np.array(Image.open(filepath).convert("RGB"))

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
                pf.flush()
                os.fsync(pf.fileno())
            return
        except OSError:
            time.sleep(0.02)


def cancel_requested(progress_path: str) -> bool:
    if not progress_path:
        return False
    return Path(progress_path + ".cancel").exists()


def main(
    manifest_path: str,
    results_path: str,
    progress_path: str = "",
    ranking_mode: str = "universal",
    sharp_mode: str = "subject_focus",
    exp_mode: str = "whole_frame",
    keep_mode: str = "dynamic_burst",
    nk_mode: str = "leave",
):
    with open(manifest_path, newline="", encoding="utf-8") as f:
        manifest = [(row[0], row[1], row[2]) for row in csv.reader(f) if row]

    total_images = len(manifest)
    if total_images == 0:
        write_progress(progress_path, 0, 0, 0, 0)
        return

    burst_groups = {}
    for image_id, filepath, burst_id in manifest:
        burst_groups.setdefault(burst_id, []).append((image_id, filepath))

    total_bursts = len(burst_groups)

    with open(results_path, "w", newline="", encoding="utf-8") as f:
        pass

    processed_count = 0
    write_progress(progress_path, 0, total_images, 0, total_bursts)

    for burst_idx, (burst_id, items) in enumerate(burst_groups.items()):
        if cancel_requested(progress_path):
            print("cancelled", file=sys.stderr)
            sys.exit(130)

        burst_sharpness = {}
        burst_exposure = {}

        for image_id, filepath in items:
            if cancel_requested(progress_path):
                print("cancelled", file=sys.stderr)
                sys.exit(130)
            try:
                rgb = load_image(filepath)
                burst_sharpness[image_id] = sharpness_score(rgb, sharp_mode)
                burst_exposure[image_id] = exposure_status(rgb, exp_mode)
                del rgb
            except Exception as exc:
                print(f"skip {image_id} ({filepath}): {exc}", file=sys.stderr)

            processed_count += 1
            write_progress(progress_path, processed_count, total_images, burst_idx + 1, total_bursts)

        if not burst_sharpness:
            continue

        burst_size = len(items)
        if keep_mode == "dynamic_burst":
            allowed = 1 if burst_size <= 4 else (2 if burst_size <= 8 else (3 if burst_size <= 12 else (4 if burst_size <= 18 else 5)))
        elif keep_mode == "portrait_mode":
            allowed = 1 if burst_size <= 3 else 2
        elif keep_mode == "single_best":
            allowed = 1
        else:
            allowed = burst_size

        sorted_members = sorted(burst_sharpness.keys(), key=lambda i: burst_sharpness[i], reverse=True)
        keepers = set(sorted_members[:allowed])

        burst_rows = []
        for img_id in burst_sharpness:
            is_keeper = img_id in keepers
            raw_score = burst_sharpness[img_id]

            if ranking_mode == "relative":
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

            # Route the non-keeper rating appropriately
            if not is_keeper:
                if nk_mode == "leave":
                    stars = "leave"
                elif nk_mode == "reject":
                    stars = -1
                else:
                    try:
                        stars = int(nk_mode)
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

        if burst_idx % 25 == 0:
            gc.collect()

        with open(results_path, "a", newline="", encoding="utf-8") as f:
            csv.writer(f).writerows(burst_rows)
            f.flush()
            os.fsync(f.fileno())

    write_progress(progress_path, total_images, total_images, total_bursts, total_bursts)


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(
            "usage: python score_images.py manifest.csv results.csv [progress_path] [ranking_mode] [sharp_mode] [exp_mode] [keep_mode] [nk_mode]",
            file=sys.stderr,
        )
        sys.exit(1)

    # Simplified argument unpacking now that Lua strictly passes all 8 variables
    prog_arg = sys.argv[3] if len(sys.argv) >= 4 else ""
    mode_arg = sys.argv[4] if len(sys.argv) >= 5 else "universal"
    s_mode = sys.argv[5] if len(sys.argv) >= 6 else "subject_focus"
    e_mode = sys.argv[6] if len(sys.argv) >= 7 else "whole_frame"
    k_mode = sys.argv[7] if len(sys.argv) >= 8 else "dynamic_burst"
    nk_mode = sys.argv[8] if len(sys.argv) >= 9 else "leave"

    try:
        main(sys.argv[1], sys.argv[2], prog_arg, mode_arg, s_mode, e_mode, k_mode, nk_mode)
    except Exception:
        import traceback
        traceback.print_exc()
        sys.exit(1)