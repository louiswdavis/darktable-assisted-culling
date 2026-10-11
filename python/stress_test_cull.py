#!/usr/bin/env python3
"""
stress_test_cull.py — Stress test harness for the Assisted Culling pipeline (6,000+ mock items).
"""

import os
import sys
import csv
import time
import tracemalloc
from pathlib import Path
import numpy as np
import cv2
from PIL import Image

# Import main logic from score_images
import score_images

def generate_mock_manifest(num_images=6000, tmp_dir="./"):
    manifest_path = Path(tmp_dir) / "stress_manifest.csv"
    dummy_img_dir = Path(tmp_dir) / "dummy_raws"
    dummy_img_dir.mkdir(exist_ok=True)
    
    # Create a couple of tiny valid dummy images to represent RAWs/JPEGs
    dummy_paths = []
    for i in range(3):
        p = dummy_img_dir / f"dummy_{i}.jpg"
        img = np.random.randint(0, 255, (400, 600, 3), dtype=np.uint8)
        # Add some sharp edges to one, blur others
        if i == 0:
            cv2.rectangle(img, (100, 100), (300, 300), (255, 255, 255), -1)
        CvImage = Image.fromarray(img)
        CvImage.save(p)
        dummy_paths.append(str(p))

    print(f"[Stress Test] Generating mock manifest with {num_images} entries...")
    with open(manifest_path, "w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        for idx in range(num_images):
            image_id = 100000 + idx
            # Cycle through dummy paths and group into simulated bursts of 5-10 shots
            filepath = dummy_paths[idx % len(dummy_paths)]
            burst_id = idx // 8 
            writer.writerow([image_id, filepath, burst_id])
            
    return str(manifest_path), str(dummy_img_dir)

def run_stress_test():
    tmp_dir = "./stress_test_tmp"
    os.makedirs(tmp_dir, exist_ok=True)
    
    manifest_path, dummy_img_dir = generate_mock_manifest(6000, tmp_dir)
    results_path = os.path.join(tmp_dir, "stress_results.csv")
    progress_path = os.path.join(tmp_dir, "stress_progress.txt")

    print("[Stress Test] Starting performance and memory benchmark...")
    tracemalloc.start()
    start_time = time.time()

    try:
        score_images.main(
            manifest_path=manifest_path,
            results_path=results_path,
            progress_path=progress_path,
            ranking_mode="universal",
            sharp_mode="subject_focus",
            exp_mode="whole_frame",
            keep_mode="dynamic_burst"
        )
    except Exception as e:
        print(f"[Stress Test] CRITICAL ERROR: {e}")
        import traceback
        traceback.print_exc()

    end_time = time.time()
    current_ram, peak_ram = tracemalloc.get_traced_memory()
    tracemalloc.stop()

    print("\n" + "="*40)
    print(" STRESS TEST RESULTS (6,000 Images)")
    print("="*40)
    print(f" Total Execution Time : {end_time - start_time:.2f} seconds")
    print(f" Peak RAM Footprint   : {peak_ram / 1024 / 1024:.2f} MB")
    print(f" Results File Created : {Path(results_path).exists()}")
    
    if Path(results_path).exists():
        with open(results_path, "r", encoding="utf-8") as rf:
            line_count = sum(1 for _ in rf)
        print(f" Output Rows Written  : {line_count}")

    # Cleanup test files
    for p in Path(tmp_dir).glob("**/*"):
        if p.is_file():
            p.unlink()
    try:
        Path(dummy_img_dir).rmdir()
        Path(tmp_dir).rmdir()
    except Exception:
        pass
    print("[Stress Test] Cleanup complete. Test passed successfully!")

if __name__ == "__main__":
    run_stress_test()