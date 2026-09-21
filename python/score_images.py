#!/usr/bin/env python3
"""
score_images.py — sharpness / exposure scoring for a batch of photos.

Reads a CSV manifest of (image_id, filepath, burst_id) — burst_id groups
images the Lua plugin already clustered by capture time — and scores each
image for sharpness and exposure. Within each burst, the sharpest image
is marked the keeper; the rest are treated as rejects. Writes a results
CSV that the darktable Lua plugin reads back and applies as ratings,
color labels, and image groups.

Usage:
    python score_images.py manifest.csv results.csv

Manifest CSV columns (no header): id,filepath,burst_id
Results  CSV columns (no header): id,sharpness,exposure,burst_id,is_keeper,stars
"""

import sys
import csv
from pathlib import Path

import numpy as np
import cv2
from PIL import Image

# ---- tunable constants -------------------------------------------------
# Everything that shapes the scoring lives here. Adjust these instead of
# touching the logic below.

RAW_EXTENSIONS = {".cr2", ".cr3", ".nef", ".arw", ".rw2", ".dng", ".raf", ".orf"}
MAX_DIM = 800                  # downscale the long edge to this before scoring
SHADOW_CLIP = 5 / 255          # luma below this = crushed shadow
HIGHLIGHT_CLIP = 250 / 255     # luma above this = blown highlight
CLIP_PCT_FLAG = 0.02           # flag exposure if more than this fraction of pixels clip

# composite score (0-100) -> star rating. Checked top-down, first match wins.
STAR_THRESHOLDS = [(85, 5), (70, 4), (50, 3), (30, 2), (10, 1)]
EXPOSURE_PENALTY = 30          # subtracted from the composite score if exposure is flagged


def load_image(filepath: str) -> np.ndarray:
    """Return an RGB uint8 array, downscaled so its long edge is MAX_DIM."""
    ext = Path(filepath).suffix.lower()
    if ext in RAW_EXTENSIONS:
        import rawpy  # imported lazily: only needed if a raw file shows up
        with rawpy.imread(filepath) as raw:
            rgb = raw.postprocess(half_size=True, use_camera_wb=True, no_auto_bright=True)
    else:
        rgb = np.array(Image.open(filepath).convert("RGB"))

    h, w = rgb.shape[:2]
    scale = MAX_DIM / max(h, w)
    if scale < 1:
        rgb = cv2.resize(rgb, (int(w * scale), int(h * scale)), interpolation=cv2.INTER_AREA)
    return rgb


def sharpness_score(rgb: np.ndarray) -> float:
    """Variance of the Laplacian — a standard, cheap focus-blur proxy."""
    gray = cv2.cvtColor(rgb, cv2.COLOR_RGB2GRAY)
    return float(cv2.Laplacian(gray, cv2.CV_64F).var())


def exposure_status(rgb: np.ndarray) -> str:
    gray = cv2.cvtColor(rgb, cv2.COLOR_RGB2GRAY).astype(np.float32) / 255.0
    if np.mean(gray > HIGHLIGHT_CLIP) > CLIP_PCT_FLAG:
        return "overexposed"
    if np.mean(gray < SHADOW_CLIP) > CLIP_PCT_FLAG:
        return "underexposed"
    return "ok"


def stars_from_score(score: float) -> int:
    for threshold, stars in STAR_THRESHOLDS:
        if score >= threshold:
            return stars
    return 0


def main(manifest_path: str, results_path: str):
    with open(manifest_path, newline="") as f:
        manifest = [(row[0], row[1], row[2]) for row in csv.reader(f) if row]

    sharpness, exposure, burst_of = {}, {}, {}
    for image_id, filepath, burst_id in manifest:
        try:
            rgb = load_image(filepath)
        except Exception as exc:
            print(f"skip {image_id} ({filepath}): {exc}", file=sys.stderr)
            continue
        sharpness[image_id] = sharpness_score(rgb)
        exposure[image_id] = exposure_status(rgb)
        burst_of[image_id] = burst_id

    # Rank sharpness across the whole batch -> a 0-100 percentile. This
    # matters because raw Laplacian variance isn't comparable across
    # cameras/lenses/ISOs; relative rank within *this* batch is.
    ranked = sorted(sharpness, key=lambda i: sharpness[i])
    denom = max(1, len(ranked) - 1)
    percentile = {img_id: 100 * rank / denom for rank, img_id in enumerate(ranked)}

    # One keeper per burst: highest sharpness wins.
    burst_members = {}
    for img_id, burst_id in burst_of.items():
        burst_members.setdefault(burst_id, []).append(img_id)
    keepers = {max(members, key=lambda i: sharpness[i]) for members in burst_members.values()}

    with open(results_path, "w", newline="") as f:
        writer = csv.writer(f)
        for img_id in sharpness:
            is_keeper = img_id in keepers
            score = percentile[img_id]
            if exposure[img_id] != "ok":
                score -= EXPOSURE_PENALTY
            if not is_keeper:
                score = 0
            stars = stars_from_score(max(0, score))
            writer.writerow([
                img_id,
                round(sharpness[img_id], 1),
                exposure[img_id],
                burst_of[img_id],
                int(is_keeper),
                stars,
            ])


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("usage: python score_images.py manifest.csv results.csv", file=sys.stderr)
        sys.exit(1)
    main(sys.argv[1], sys.argv[2])
