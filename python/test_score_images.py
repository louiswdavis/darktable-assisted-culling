# Run with: python python/test_score_images.py
# Exercises score_images.py's pure functions on synthetic images; no darktable needed.

import os
import sys
import tempfile

import cv2
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import score_images as S

failures = 0


def check(name, got, want):
    global failures
    if got != want:
        failures += 1
        print(f"FAIL {name}: got {got!r}, want {want!r}")
    else:
        print(f"ok   {name}")


# saliency_point -----------------------------------------------------------
img = np.full((90, 90, 3), 128, dtype=np.uint8)
img[4:14, 4:14] = (255, 0, 0)
img[4:14:2, 4:14] = (0, 0, 255)
x, y = S.saliency_point(img)
check("saliency: off-centre patch wins (x)", x < 0.3, True)
check("saliency: off-centre patch wins (y)", y < 0.3, True)

flat = np.full((90, 90, 3), 128, dtype=np.uint8)
check("saliency: flat frame falls back to frame centre", S.saliency_point(flat), (0.5, 0.5))

# parse_manifest_row -----------------------------------------------------
check("manifest: 4-column row keeps mask path",
      S.parse_manifest_row(["1", "/a.jpg", "3", "/m.png"]), ("1", "/a.jpg", "3", "/m.png"))
check("manifest: 3-column row gets empty mask path",
      S.parse_manifest_row(["1", "/a.jpg", "3"]), ("1", "/a.jpg", "3", ""))

# mask-aware sharpness ---------------------------------------------------
tmp = tempfile.mkdtemp()
rng = np.random.default_rng(0)
noise = rng.integers(0, 255, (120, 120, 3), dtype=np.uint8)
scene = cv2.GaussianBlur(noise, (15, 15), 0)
scene[10:50, 10:50] = noise[10:50, 10:50]  # sharp subject in a soft frame, off-centre
mask = np.zeros((120, 120), np.uint8)
mask[10:50, 10:50] = 255
mask_path = os.path.join(tmp, "mask.png")
cv2.imwrite(mask_path, mask)
empty_path = os.path.join(tmp, "empty.png")
cv2.imwrite(empty_path, np.zeros((120, 120), np.uint8))

fallback = S.sharpness_score(scene, "sam_subject", mask_path="")
check("sam: masked subject scores above the unmasked fallback",
      S.sharpness_score(scene, "sam_subject", mask_path=mask_path) > fallback, True)
check("sam: missing mask file falls back",
      S.sharpness_score(scene, "sam_subject", mask_path=os.path.join(tmp, "nope.png")), fallback)
check("sam: all-zero mask falls back",
      S.sharpness_score(scene, "sam_subject", mask_path=empty_path), fallback)
check("sam: unmasked fallback matches subject_focus",
      fallback, S.sharpness_score(scene, "subject_focus"))


print("")
if failures == 0:
    print("all tests passed")
    sys.exit(0)
print(f"{failures} test(s) failed")
sys.exit(1)
