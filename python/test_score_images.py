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


# Worker processes re-import this file on spawn; only the parent runs the tests.
def run_tests():
    global failures
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
          S.parse_manifest_row(["1", "/a.jpg", "3", "/m.png"]), ("1", "/a.jpg", "3", "/m.png", ""))
    check("manifest: 5-column row keeps shortlist flag",
          S.parse_manifest_row(["1", "/a.jpg", "3", "", "0"]), ("1", "/a.jpg", "3", "", "0"))
    check("manifest: 3-column row gets empty mask path",
          S.parse_manifest_row(["1", "/a.jpg", "3"]), ("1", "/a.jpg", "3", "", ""))

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

    # orientation and mask/image agreement ------------------------------------
    from PIL import Image

    tall = np.zeros((60, 120, 3), np.uint8)  # stored landscape
    rot_path = os.path.join(tmp, "rotated.jpg")
    exif = Image.Exif()
    exif[0x0112] = 6  # camera held vertically: display rotated 90° CW
    Image.fromarray(tall).save(rot_path, exif=exif)
    check("load_image honours EXIF orientation", S.load_image(rot_path).shape[:2], (120, 60))

    wide_mask = os.path.join(tmp, "wide.png")
    m = np.zeros((60, 120), np.uint8)
    m[:, :60] = 255
    cv2.imwrite(wide_mask, m)
    check("sam: mask with a different aspect ratio falls back",
          S.sharpness_score(scene, "sam_subject", mask_path=wide_mask), fallback)

    # resolve_burst_scores -----------------------------------------------------
    check("burst: all masked → masked scores, all eligible",
          S.resolve_burst_scores({"a": (5.0, 1.0), "b": (7.0, 2.0)}), ({"a": 5.0, "b": 7.0}, {"a", "b"}))
    check("burst: any unmasked → everyone uses fallback",
          S.resolve_burst_scores({"a": (5.0, 1.0), "b": (None, 2.0)}), ({"a": 1.0, "b": 2.0}, {"a", "b"}))
    check("burst: plain floats pass through",
          S.resolve_burst_scores({"a": 3.0}), ({"a": 3.0}, {"a"}))
    check("burst: masked shortlist → only the shortlist can keep",
          S.resolve_burst_scores({"a": (5.0, 1.0), "b": (None, 2.0)}, candidates={"a"}),
          ({"a": 5.0, "b": 2.0}, {"a"}))
    check("burst: a shortlisted frame without a mask → whole burst falls back",
          S.resolve_burst_scores({"a": (None, 1.0), "b": (None, 2.0), "c": (6.0, 3.0)}, candidates={"a", "c"}),
          ({"a": 1.0, "b": 2.0, "c": 3.0}, {"a", "b", "c"}))

    # keepers_allowed / shortlist ----------------------------------------------
    check("allowed: single best", S.keepers_allowed("single_best", 40), 1)
    check("allowed: dynamic, long burst", S.keepers_allowed("dynamic_burst", 40), 5)
    check("allowed: keep all", S.keepers_allowed("keep_all", 7), 7)
    check("shortlist: top 3 by heuristic score",
          S.shortlist({"a": 1.0, "b": 5.0, "c": 3.0, "d": 4.0, "e": 2.0}, "single_best"), {"b", "d", "c"})
    check("shortlist: grows to the keeper count",
          len(S.shortlist({str(i): float(i) for i in range(30)}, "dynamic_burst")), 5)
    check("shortlist: small burst keeps everyone",
          S.shortlist({"a": 1.0, "b": 2.0}, "single_best"), {"a", "b"})

    # process_burst_logic respects eligibility ----------------------------------
    from argparse import Namespace
    res_path = os.path.join(tmp, "res.csv")
    open(res_path, "w").close()
    S.process_burst_logic("1", {"a": 9.0, "b": 1.0}, {"a": "ok", "b": "ok"}, 2,
                          Namespace(keep_mode="single_best", rank_mode="universal", nk_mode="leave"),
                          res_path, eligible={"b"})
    keeper_rows = [line.split(",")[0] for line in open(res_path) if line.split(",")[4] == "1"]
    check("burst logic: ineligible frame can't keep even when it scores higher", keeper_rows, ["b"])

    # single decode in sam_subject: stage A prescores, stage C skips non-shortlisted --
    import csv as _csv

    frames = []
    for i in range(5):
        p = os.path.join(tmp, f"burst{i}.jpg")
        cv2.imwrite(p, cv2.GaussianBlur(noise, (1 + 4 * i, 1 + 4 * i), 0))
        frames.append(p)
    man_a = os.path.join(tmp, "a.csv")
    with open(man_a, "w", newline="") as f:
        _csv.writer(f).writerows([[str(i), p, "9"] for i, p in enumerate(frames)])
    points_p, pre_p = os.path.join(tmp, "pts.csv"), os.path.join(tmp, "pre.csv")
    S.main(Namespace(manifest=man_a, results=points_p, progress="", emit_saliency_points=True,
                     keep_mode="single_best", exp_mode="whole_frame", fast_jpeg=False, prescores=pre_p))
    pre_rows = list(_csv.reader(open(pre_p)))
    check("stage A: prescores every frame", sorted(r[0] for r in pre_rows), ["0", "1", "2", "3", "4"])
    shortlisted_ids = {r[0] for r in _csv.reader(open(points_p))}
    check("stage A: points only for the shortlist", len(shortlisted_ids), 3)

    # stage C: point non-shortlisted rows at files that don't exist; they must still score
    man_c = os.path.join(tmp, "c.csv")
    with open(man_c, "w", newline="") as f:
        w = _csv.writer(f)
        for i, p in enumerate(frames):
            short = str(i) in shortlisted_ids
            w.writerow([str(i), p if short else os.path.join(tmp, "gone.jpg"), "9", "", "1" if short else "0"])
    res_c = os.path.join(tmp, "resc.csv")
    S.main(Namespace(manifest=man_c, results=res_c, progress="", emit_saliency_points=False,
                     rank_mode="universal", sharp_mode="sam_subject", exp_mode="whole_frame",
                     keep_mode="single_best", nk_mode="leave", fast_jpeg=False, prescores=pre_p))
    res_rows = list(_csv.reader(open(res_c)))
    check("stage C: every frame scored without re-decoding the rest", sorted(r[0] for r in res_rows),
          ["0", "1", "2", "3", "4"])
    check("stage C: keeper comes from the shortlist",
          [r[0] for r in res_rows if r[4] == "1"][0] in shortlisted_ids, True)

    # edge-to-edge uniformity rewards the weakest areas, ignoring featureless sky --
    # a "landscape": large tonal shapes plus fine texture, like rock or foliage
    shapes = cv2.resize(rng.integers(40, 215, (6, 6, 3), dtype=np.uint8), (300, 300),
                        interpolation=cv2.INTER_CUBIC).astype(np.int16)
    grain = rng.integers(-40, 40, (300, 300, 3), dtype=np.int16)
    detail = np.clip(shapes + grain, 0, 255).astype(np.uint8)
    even = cv2.GaussianBlur(detail, (3, 3), 0)          # moderately sharp everywhere
    one_spot = cv2.GaussianBlur(detail, (15, 15), 0)     # soft everywhere...
    one_spot[100:200, 100:200] = detail[100:200, 100:200]  # ...except one crisp patch
    check("uniformity: evenly sharp frame beats one sharp patch",
          S.sharpness_score(even, "tiles_uniformity") > S.sharpness_score(one_spot, "tiles_uniformity"), True)

    sky_sharp = even.copy()
    sky_sharp[:100] = 200                                # flat sky across the top third
    sky_soft = cv2.GaussianBlur(detail, (9, 9), 0)
    sky_soft[:100] = 200
    sharp_score = S.sharpness_score(sky_sharp, "tiles_uniformity")
    # if the flat sky patches counted, both scores would collapse to ~0
    check("uniformity: flat sky doesn't flatten every score",
          sharp_score > 2 * S.sharpness_score(sky_soft, "tiles_uniformity"), True)

    check("face mode without a face falls back to subject bias",
          S.sharpness_score(one_spot, "face_detect"), S.sharpness_score(one_spot, "subject_focus"))


    print("")
    if failures == 0:
        print("all tests passed")
        sys.exit(0)
    print(f"{failures} test(s) failed")
    sys.exit(1)


if __name__ == "__main__":
    run_tests()
