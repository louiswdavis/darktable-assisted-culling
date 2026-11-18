# Run with: python python/test_score_images.py
# Exercises score_images.py's pure functions on synthetic images; no darktable needed.

import os
import sys
import tempfile

import cv2
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import score_images as S
import vehicle_detect as VD

sys.stdout.reconfigure(encoding="utf-8", errors="replace")  # check names hold arrows; a cp1252 console would crash on them
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

    # vehicle_box / strongest_detections (shared detection entries) --------------
    # the detector saw the full 3200x1600 frame; the worker scores a 1600x800 downscale
    entry = {"frame": [3200, 1600], "detector": "fake", "boxes": [[800, 400, 1600, 800, 0.9, 2]]}
    check("vehicle_box: the stored box is rescaled to the frame scored, as fractions",
          S.vehicle_box(np.zeros((800, 1600, 3), np.uint8), entry), ((0.25, 0.25, 0.5, 0.5), 2, ""))
    weak = {"frame": [400, 400], "detector": "fake", "boxes": [[160, 160, 240, 240, 0.2, 2]]}
    check("vehicle_box: under DETECTOR_MIN_SCORE → none, the log names the strongest vehicle",
          S.vehicle_box(np.zeros((400, 400, 3), np.uint8), weak),
          (None, None, f"no vehicle at {S.DETECTOR_MIN_SCORE}: strongest vehicle 0.20 (0.20x0.20 of frame)"))
    check("vehicle_box: an entry with no boxes → none",
          S.vehicle_box(np.zeros((400, 400, 3), np.uint8), {"frame": [400, 400], "detector": "fake", "boxes": []})[2],
          f"no vehicle at {S.DETECTOR_MIN_SCORE}: nothing at {VD.CANDIDATE_MIN_SCORE}")
    check("MAX_DIM is the shared module's fast-JPEG draft size", S.MAX_DIM, VD.FAST_JPEG_DIM)

    # car boxes from tagging's boxes.json (--car-boxes) ---------------------------
    # culling's detector saw 4000x2000; tagging decoded the same frame at 2000x1000
    two = {"frame": [4000, 2000], "detector": "fake",
           "boxes": [[400, 400, 1200, 1200, 0.9, 2], [2400, 200, 3800, 1800, 0.8, 7]]}  # car, shed
    car = [(200 / 2000, 200 / 1000, 600 / 2000, 600 / 1000)]
    check("car boxes: the shed box tagging dropped goes, the car stays",
          S.car_filtered(two, car), dict(two, boxes=[two["boxes"][0]], dropped=1))
    check("car boxes: not in tagging's file → the entry as it was", S.car_filtered(two, None) is two, True)
    check("car boxes: in the file with no kept box → no vehicle, the log says what went",
          S.vehicle_box(np.zeros((500, 1000, 3), np.uint8), S.car_filtered(two, []))[::2],
          (None, f"no vehicle at {S.DETECTOR_MIN_SCORE}: nothing at {VD.CANDIDATE_MIN_SCORE}; tagging's car check dropped 2"))
    check("car boxes: the shed is no longer the prominent box",
          S.vehicle_box(np.zeros((500, 1000, 3), np.uint8), S.car_filtered(two, car))[0], (0.1, 0.2, 0.3, 0.6))
    check("car boxes: IoU under CAR_BOX_MIN_IOU doesn't match",
          S.car_filtered(two, [(0.1, 0.2, 0.2, 0.4)])["boxes"], [])
    check("car boxes: cache key unchanged off the file", S.car_key(None), ())
    with tempfile.TemporaryDirectory() as cb_tmp:
        shot, gone = os.path.join(cb_tmp, "a.jpg"), os.path.join(cb_tmp, "b.jpg")
        open(shot, "wb").close()
        boxes_json = os.path.join(cb_tmp, "c.boxes.json")
        import json as _json
        with open(boxes_json, "w", encoding="utf-8") as f:
            _json.dump({"images": {
                "1": {"file": shot, "frame": [2000, 1000], "status": "ok", "boxes": [{"bbox": [200, 200, 600, 600]}]},
                "2": {"file": gone, "frame": [2000, 1000], "status": "ok", "boxes": []},
                "3": {"file": shot, "frame": [], "status": "error", "boxes": []}}}, f)
        os.utime(shot, (1, 1))
        cars_of, note = S.read_car_boxes(boxes_json)
        check("car boxes: read as frame fractions, keyed by path", cars_of, {S.path_key(shot): car})
        check("car boxes: the log counts frames left out", note.endswith("1 left out (file changed since tagging ran, or gone)"), True)
        os.utime(shot, None)
        os.utime(boxes_json, (1, 1))
        check("car boxes: a frame changed after tagging ran is left out", S.read_car_boxes(boxes_json)[0], {})
        with open(boxes_json, "w", encoding="utf-8") as f:
            _json.dump({"kind": "people", "images": {}}, f)
        check("car boxes: a people run gives none", S.read_car_boxes(boxes_json)[0], {})
    check("car boxes: a missing file gives none", S.read_car_boxes(os.path.join(tempfile.gettempdir(), "no.boxes.json"))[0], {})
    check("car boxes: no path gives none", S.read_car_boxes(""), ({}, "car boxes: off, raw detector boxes"))
    # ticket 38: number reads from the same file, per manifest id, best confidence over all boxes
    with tempfile.TemporaryDirectory() as nr_tmp:
        shot, plain_shot = os.path.join(nr_tmp, "a.jpg"), os.path.join(nr_tmp, "b.jpg")
        open(shot, "wb").close()
        open(plain_shot, "wb").close()
        boxes_json = os.path.join(nr_tmp, "c.boxes.json")
        with open(boxes_json, "w", encoding="utf-8") as f:
            _json.dump({"images": {
                "1": {"file": shot, "frame": [2000, 1000], "status": "ok", "boxes": [
                    {"bbox": [0, 0, 9, 9], "ocr": [["12", 0.6], ["7", 0.3]]},
                    {"bbox": [0, 0, 9, 9], "ocr": [["12", 0.8], [" ", 0.9]]}]},
                "2": {"file": plain_shot, "frame": [2000, 1000], "status": "ok", "boxes": [{"bbox": [0, 0, 9, 9]}]}}}, f)
        os.utime(shot, (1, 1))
        os.utime(plain_shot, (1, 1))
        reads, note = S.read_number_reads(boxes_json, [["5", shot], ["6", plain_shot], ["7", "elsewhere.jpg"]])
        check("number reads: best confidence per number, blanks dropped, frames with none left out",
              reads, {"5": {"12": 0.8, "7": 0.3}})
        check("number reads: the log counts frames", note, f"number reads: 1 frames from {boxes_json}")
    check("number reads: no path is off", S.read_number_reads("", [["5", "a.jpg"]]), ({}, ""))

    small_sure = (10, 10, 30, 30, 0.95, 2)
    big_unsure = (100, 50, 300, 250, 0.5, 7)
    check("pick vehicle: prominence beats raw confidence",
          S.pick_vehicle([small_sure, big_unsure], 400, 300), ((0.25, 50 / 300, 0.75, 250 / 300), 7))
    check("pick vehicle: box clipped to the frame",
          S.pick_vehicle([(-20, 0, 420, 150, 0.8, 3)], 400, 300), ((0.0, 0.0, 1.0, 0.5), 3))
    check("pick vehicle: none found", S.pick_vehicle([], 400, 300), None)

    # diagnostic tags ------------------------------------------------------------
    check("subject tag: vehicle found, class left out", S.subject_tag(3), "Subject|Vehicle|Detected")
    check("subject tag: no vehicle found", S.subject_tag(None), "Subject|Vehicle|Guessed")
    check("technique tag: pan", S.technique_tag("subject_peak"), "Technique|Panning")
    check("technique tag: wide aperture", S.technique_tag("subject_focus"), "Technique|Shallow DoF")

    # parse_manifest_row -----------------------------------------------------
    check("manifest: 4-column row keeps mask path",
          S.parse_manifest_row(["1", "/a.jpg", "3", "/m.png"]), ("1", "/a.jpg", "3", "/m.png", "", "", 0.0, 0.0, 0.0, ""))
    check("manifest: 5-column row keeps shortlist flag",
          S.parse_manifest_row(["1", "/a.jpg", "3", "", "0"]), ("1", "/a.jpg", "3", "", "0", "", 0.0, 0.0, 0.0, ""))
    check("manifest: 6-column row keeps edit time",
          S.parse_manifest_row(["1", "/a.jpg", "3", "", "", "t"]), ("1", "/a.jpg", "3", "", "", "t", 0.0, 0.0, 0.0, ""))
    check("manifest: 3-column row gets empty mask path",
          S.parse_manifest_row(["1", "/a.jpg", "3"]), ("1", "/a.jpg", "3", "", "", "", 0.0, 0.0, 0.0, ""))
    check("manifest: 8-column row keeps shutter and aperture",
          S.parse_manifest_row(["1", "/a.jpg", "3", "", "", "", "0.0080000004", "2.8"]),
          ("1", "/a.jpg", "3", "", "", "", 0.0080000004, 2.8, 0.0, ""))
    check("manifest: 9-column row keeps focal length",
          S.parse_manifest_row(["1", "/a.jpg", "3", "", "", "", "0.004", "5.6", "400"]),
          ("1", "/a.jpg", "3", "", "", "", 0.004, 5.6, 400.0, ""))
    check("manifest: 9-column row has no car",
          S.parse_manifest_row(["1", "/a.jpg", "3", "", "", "", "0.004", "5.6", "400"])[-1], "")
    check("manifest: 10-column row carries the car",
          S.parse_manifest_row(["1", "/a.jpg", "3", "", "", "", "0.004", "5.6", "400", "37"])[-1], "37")

    # EXIF intent rules --------------------------------------------------------
    check("intent: 1/125 in subject bias is a pan",
          S.burst_sharp_mode("subject_focus", [0.0079999998] * 3, [8.0] * 3), "subject_peak")
    check("intent: 1/160 in subject bias isn't a pan",
          S.burst_sharp_mode("subject_focus", [1 / 160] * 3, [8.0] * 3), "subject_focus")
    check("intent: the burst's median shutter decides, not one stray frame",
          S.burst_sharp_mode("subject_focus", [1 / 500, 1 / 500, 1 / 30], [8.0] * 3), "subject_focus")
    check("intent: a slow shutter in uniformity mode is a tripod, not a pan",
          S.burst_sharp_mode("tiles_uniformity", [2.0], [11.0]), "tiles_uniformity")
    check("intent: f/4 in uniformity mode skips the edge-to-edge check",
          S.burst_sharp_mode("tiles_uniformity", [1 / 250], [4.0000001]), "subject_focus")
    check("intent: f/5.6 in uniformity mode keeps it",
          S.burst_sharp_mode("tiles_uniformity", [1 / 250], [5.6]), "tiles_uniformity")
    check("intent: unknown EXIF changes nothing",
          S.burst_sharp_mode("subject_focus", [0.0, 0.0], [0.0, 0.0]), "subject_focus")
    check("intent: other modes ignore EXIF",
          S.burst_sharp_mode("face_detect", [1 / 30], [1.8]), "face_detect")

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
    S.process_burst_logic("1", {"a": 9.0, "b": 1.0}, {"a": (), "b": ()}, 2,
                          Namespace(keep_mode="single_best", rank_mode="universal", nk_mode="leave"),
                          res_path, eligible={"b"})
    keeper_rows = [line.split(",")[0] for line in open(res_path) if line.split(",")[4] == "1"]
    check("burst logic: ineligible frame can't keep even when it scores higher", keeper_rows, ["b"])

    def why_of(**kw):
        """id -> Why reason for a 3-frame burst scored 9/6/1."""
        open(res_path, "w").close()
        ns = dict(keep_mode="single_best", rank_mode="universal", nk_mode="leave", keep_margin=0.0)
        ns.update(kw.pop("ns", {}))
        S.process_burst_logic("1", {"a": 9.0, "b": 6.0, "c": 1.0}, {k: () for k in "abc"}, 3, Namespace(**ns),
                              res_path, diag_tags={"a": ["Scored|Masked"]}, **kw)
        rows = [line.strip().split(",") for line in open(res_path)]
        return {r[0]: [t for t in r[6].split(";") if t.startswith("Why|")][0][4:] for r in rows}

    check("why: keeper by rank, the rest outranked", why_of(), {"a": "Keeper", "b": "Outranked", "c": "Outranked"})
    check("why: the margin keeper says so", why_of(ns={"keep_margin": 0.6}),
          {"a": "Keeper", "b": "Keeper by margin", "c": "Outranked"})
    check("why: graded non-keepers", why_of(ns={"nk_mode": "graded"}), {"a": "Keeper", "b": "Graded", "c": "Graded"})
    check("why: a frame outside the shortlist", why_of(eligible={"a", "b"}),
          {"a": "Keeper", "b": "Outranked", "c": "Not shortlisted"})
    check("why: a no-vehicle frame is left alone, the next frame keeps", why_of(no_vehicle={"a"}),
          {"a": "No vehicle", "b": "Keeper", "c": "Outranked"})
    check("why: an all-no-vehicle burst is left alone", set(why_of(no_vehicle={"a", "b", "c"}).values()), {"No vehicle"})
    open(res_path, "w").close()
    S.process_burst_logic("1", {"a": 9.0, "b": 8.8}, {"a": (), "b": ()}, 2, Namespace(
        keep_mode="single_best", rank_mode="universal", nk_mode="leave"), res_path)
    close_rows = {r[0]: r for r in (line.strip().split(",") for line in open(res_path))}
    check("why: two near-identical frames are a close call, one still keeps",
          ({k: r[6] for k, r in close_rows.items()}, close_rows["a"][4], close_rows["b"][4]),
          ({"a": "Why|Close call", "b": "Why|Close call"}, "1", "0"))
    open(res_path, "w").close()
    S.process_burst_logic("1", {"a": 9.0}, {"a": ()}, 1, Namespace(keep_mode="single_best", rank_mode="universal",
                          nk_mode="leave"), res_path, diag_tags={"a": ["Scored|Masked"]})
    check("why: the Why tag follows the other diagnostic tags", open(res_path).read().strip().split(",")[6],
          "Scored|Masked;Why|Keeper")
    check("why: every reason the scorer writes is listed",
          set(why_of(ns={"keep_margin": 0.6}).values()) | set(why_of(ns={"nk_mode": "graded"}).values())
          | set(why_of(eligible={"a"}).values()) <= set(S.WHY_REASONS), True)

    # ticket 52: keeper count from eligible frames, close-call keepers keep their stars
    import rating as R
    seven = {k: 90.0 - 10 * n for n, k in enumerate("abcdefg")}
    dynamic = Namespace(keep_mode="dynamic_burst", rank_mode="relative", nk_mode="leave")
    check("keepers: 7 frames, 3 eligible, dynamic_burst keeps 1",
          R.rate_burst(seven, {k: () for k in seven}, 7, dynamic, eligible={"a", "b", "c"}, reference=100.0)[1], ["a"])
    def stars_for(third):
        """id -> stars for 5 eligible frames (2 keepers), the best loser scoring third."""
        burst = {"a": 99.0, "b": 90.0, "c": third, "d": 45.0, "e": 40.0}
        return R.rate_burst(burst, {k: () for k in burst}, 5, dynamic, reference=100.0)[2]
    check("star drop: a clear runner-up keeper loses the top-40% star", (stars_for(50.0)["a"], stars_for(50.0)["b"]), (5, 3))
    check("star drop: a keeper in a close call keeps its own stars", (stars_for(88.0)["a"], stars_for(88.0)["b"]), (5, 4))

    # ticket 54: spread keepers over the burst; ids are capture order
    spread_on = Namespace(keep_mode="dynamic_burst", rank_mode="universal", nk_mode="leave", spread_keepers=True)
    def twelve(**sharp):
        """12 frames in capture order, 40 unless given; dynamic_burst allows 3 keepers."""
        return {i: sharp.get(f"f{i}", 40.0) for i in range(1, 13)}
    best_three = twelve(f2=96.0, f5=100.0, f6=99.0, f7=98.0, f10=97.0)
    _m, kept, _s, why = R.rate_burst(best_three, {k: () for k in best_three}, 12, spread_on)
    check("spread: 12 frames, 3 keepers, the best three adjacent keep one per third", sorted(kept), [2, 5, 10])
    check("spread: a slice's pick over a sharper frame says Spread, the frame it beat is a close call",
          (why[2], why[10], why[5], why[6]), ("Spread", "Spread", "Keeper", "Close call"))
    one_moment = twelve(f5=100.0, f6=99.0, f7=98.0)
    _m, kept, _s, why = R.rate_burst(one_moment, {k: () for k in one_moment}, 12, spread_on)
    check("spread: mostly blur with one sharp moment keeps the sharp frames", (sorted(kept), why[6]), ([5, 6, 7], "Keeper"))
    check("spread: frames are sliced in the order given, not by id",
          sorted(R.rate_burst(best_three, {k: () for k in best_three}, 12, spread_on,
                              order=[5, 6, 1, 2, 7, 3, 4, 8, 9, 10, 11, 12])[1]), [5, 7, 10])
    plain = Namespace(keep_mode="dynamic_burst", rank_mode="universal", nk_mode="leave")
    check("spread: off rates exactly as before",
          R.rate_burst(best_three, {k: () for k in best_three}, 12, Namespace(**{**vars(plain), "spread_keepers": False})),
          R.rate_burst(best_three, {k: () for k in best_three}, 12, plain))
    check("spread: one keeper allowed keeps the best frame",
          R.rate_burst(best_three, {k: () for k in best_three}, 12,
                       Namespace(**{**vars(spread_on), "keep_mode": "single_best"}))[1], [5])

    # ticket 84: a car cut by the frame edge keeps nothing while a whole car exists
    single = Namespace(keep_mode="single_best", rank_mode="universal", nk_mode="leave")
    trio = {"a": 300.0, "b": 200.0, "c": 100.0}
    _m, kept, _s, why = R.rate_burst(trio, {"a": ("cut_off",), "b": (), "c": ()}, 3, single)
    check("cut off: loses to a whole car", (kept, why["a"]), (["b"], "Outranked"))
    check("cut off: kept when every frame is cut off",
          R.rate_burst(trio, {k: ("cut_off",) for k in trio}, 3, single)[1], ["a"])
    check("cut off: tag-only setting does not change eligibility",
          R.rate_burst(trio, {"a": ("cut_off",), "b": (), "c": ()}, 3,
                       Namespace(**{**vars(single), "tag_only_flags": frozenset({"cut_off"})}))[1], ["b"])

    # ticket 84: the best frame of another view of the car keeps one star lower
    angled = Namespace(**{**vars(single), "keep_angles": True, "sharp_mode": "motion_aware"})
    turn = {"a": 450.0, "b": 440.0, "c": 330.0, "d": 320.0}
    no_flags = {k: () for k in turn}
    two_views = {"a": 0, "b": 0, "c": 1, "d": 1}
    _m, kept, stars, why = R.rate_burst(turn, no_flags, 4, angled, views=two_views)
    check("other angle: kept one star lower",
          (kept, stars["a"], stars["c"], why["c"], stars["d"]), (["a", "c"], 4, 3, "Other angle", "leave"))
    check("other angle: under the share is not kept",
          R.rate_burst({**turn, "c": 300.0, "d": 290.0}, no_flags, 4, angled, views=two_views)[1], ["a"])
    check("other angle: off without the flag", R.rate_burst(turn, no_flags, 4, single, views=two_views)[1], ["a"])
    check("other angle: no views, result equals today's",
          R.rate_burst(turn, no_flags, 4, angled),
          R.rate_burst(turn, no_flags, 4, Namespace(**{**vars(angled), "keep_angles": False})))
    check("other angle: a frame without a box makes no view",
          R.rate_burst(turn, no_flags, 4, angled, views={"a": 0, "b": 0, "c": None, "d": None})[1], ["a"])
    check("other angle: a cut-off frame is not the view's pick",
          R.rate_burst(turn, {**no_flags, "c": ("cut_off",)}, 4, angled, views=two_views)[1], ["a", "d"])
    pair = Namespace(**{**vars(angled), "keep_mode": "keep_all"})
    _m, kept, stars, why = R.rate_burst(turn, no_flags, 4, pair, views=two_views)
    check("other angle: a ranked keeper that leads another view is relabelled, one star lower",
          (why["a"], why["c"], stars["c"], why["d"]), ("Keeper", "Other angle", 3, "Keeper"))
    nine = {"a": 450.0, "b": 445.0, "c": 440.0, "d": 435.0, **{k: 100.0 for k in "efghi"}}
    _m, kept, stars, why = R.rate_burst(nine, {k: () for k in nine}, 9,
                                        Namespace(**{**vars(angled), "keep_mode": "dynamic_burst"}),
                                        views={k: int(k != "a") for k in nine})
    check("other angle: no keeper of that view outrates its Other angle frame",
          (kept, stars["a"], why["b"], stars["b"], why["c"], stars["c"]), (["a", "b", "c"], 4, "Other angle", 3, "Close call", 3))

    # ticket 84: a straight, consistent blur with the car showing keeps for its look
    looked = Namespace(**{**vars(single), "motion_look": True, "sharp_mode": "motion_aware"})
    _m, kept, stars, why = R.rate_burst(trio, {k: () for k in trio}, 3, looked, motion_look={"b": 0.5, "c": 0.86})
    check("motion look: straight blur kept and rated by straightness",
          (kept, stars["c"], why["c"], why["a"]), (["a", "c"], 5, "Motion look", "Keeper"))
    check("motion look: never replaces a sharp keeper",
          len(kept) - len(R.rate_burst(trio, {k: () for k in trio}, 3, looked)[1]), 1)
    check("motion look: below the threshold adds nothing",
          R.rate_burst(trio, {k: () for k in trio}, 3, looked, motion_look={"b": 0.5, "c": 0.74})[1], ["a"])
    _m, kept, stars, why = R.rate_burst(trio, {k: () for k in trio}, 3, looked, motion_look={"a": 0.9, "c": 0.86})
    check("motion look: best frame already a keeper adds nothing", (kept, why["a"], stars["a"]), (["a"], "Keeper", 3))
    check("motion look: off without the flag",
          R.rate_burst(trio, {k: () for k in trio}, 3, single, motion_look={"c": 0.86})[1], ["a"])
    check("motion look: a flag still costs its stars",
          R.rate_burst(trio, {"a": (), "b": (), "c": ("blocked",)}, 3, looked, motion_look={"c": 0.86})[2]["c"],
          5 - R.FLAG_PENALTIES["blocked"][1])

    # ticket 84: keeper stars on an even slope across the shoot
    ten = {str(i): float(i) for i in range(1, 11)}
    check("slope: ten keepers fill five even bands",
          [R.slope_stars(ten)[str(i)] for i in range(1, 11)], [1, 1, 2, 2, 3, 3, 4, 4, 5, 5])
    check("slope: under the minimum returns nothing", R.slope_stars({str(i): float(i) for i in range(1, 10)}), {})
    tied = R.slope_stars({**ten, "9": 10.0, "7": 8.0})
    check("slope: ties share a band", (tied["9"], tied["10"], tied["7"], tied["8"]), (5, 5, 4, 4))
    _m, kept, stars, why = R.rate_burst(turn, no_flags, 4, angled, views=two_views, slope={"a": 5, "c": 5})
    check("slope: other angle stays one below its burst's best", (stars["a"], stars["c"], why["c"]), (5, 4, "Other angle"))
    check("slope: a flag still costs its stars",
          R.rate_burst(trio, {"a": ("overexposed",), "b": (), "c": ()}, 3, looked, slope={"a": 4})[2]["a"], 3)
    check("slope: relative stars are untouched",
          R.rate_burst(trio, {k: () for k in trio}, 3, Namespace(**{**vars(looked), "rank_mode": "relative"}),
                       reference=max(trio.values()), slope={"a": 1})[2]["a"],
          R.rate_burst(trio, {k: () for k in trio}, 3, Namespace(**{**vars(looked), "rank_mode": "relative"}),
                       reference=max(trio.values()))[2]["a"])

    # ticket 38: a clearer number read settles a close call
    close_pair = {"a": 100.0, "b": 97.0}
    def settle(reads, burst=close_pair, settings=single):
        _m, kept, _s, why = R.rate_burst(burst, {k: () for k in burst}, len(burst), settings, reads=reads)
        return kept, why
    check("number: the dropped frame of a close call reads clearer, so it keeps",
          settle({"a": {"12": 0.6}, "b": {"12": 0.9}}), (["b"], {"a": "Close call", "b": "Number clearer"}))
    check("number: a gap under NUMBER_READ_MIN_GAP keeps the sharper frame",
          settle({"a": {"12": 0.6}, "b": {"12": 0.65}})[0], ["a"])
    check("number: only one frame reading keeps today's ranking", settle({"b": {"12": 0.9}})[0], ["a"])
    check("number: different numbers keep today's ranking", settle({"a": {"12": 0.3}, "b": {"21": 0.9}})[0], ["a"])
    check("number: the number both read best decides",
          settle({"a": {"12": 0.9, "7": 0.1}, "b": {"12": 0.8, "7": 0.5}})[0], ["a"])
    check("number: no reads rate exactly as before", (settle(None), settle({})),
          ((["a"], {"a": "Close call", "b": "Close call"}),) * 2)
    check("number: not a close call keeps the sharper frame",
          settle({"a": {"12": 0.1}, "b": {"12": 0.9}}, {"a": 100.0, "b": 90.0})[0], ["a"])
    check("number: the keeper margin still holds the sharper frame",
          settle({"a": {"12": 0.6}, "b": {"12": 0.9}}, settings=Namespace(**{**vars(single), "keep_margin": 0.98})),
          (["a", "b"], {"a": "Close call", "b": "Number clearer"}))
    check("number: number_clearer needs a shared number", R.number_clearer({"1": 0.1}, {"2": 0.9}), False)

    # ticket 14: the sharpness judge settles a close call the reads left
    def judge(judged, burst=close_pair, settings=single, reads=None):
        _m, kept, _s, why = R.rate_burst(burst, {k: () for k in burst}, len(burst), settings, reads=reads, judged=judged)
        return kept, why
    check("judge: the dropped frame scored clearer keeps",
          judge({"a": 0.50, "b": 0.60}), (["b"], {"a": "Close call", "b": "Subject clearer"}))
    check("judge: a gap under JUDGE_MIN_GAP keeps the sharper frame", judge({"a": 0.50, "b": 0.52})[0], ["a"])
    check("judge: one frame unjudged keeps today's ranking", judge({"b": 0.9})[0], ["a"])
    check("judge: no scores rate exactly as before", (judge(None), judge({})),
          ((["a"], {"a": "Close call", "b": "Close call"}),) * 2)
    check("judge: not a close call keeps the sharper frame", judge({"a": 0.1, "b": 0.9}, {"a": 100.0, "b": 90.0})[0], ["a"])
    check("judge: a number read settles it first",
          judge({"a": 0.50, "b": 0.60}, reads={"a": {"12": 0.6}, "b": {"12": 0.9}}),
          (["b"], {"a": "Close call", "b": "Number clearer"}))
    check("judge: reads that settle nothing leave it to the judge",
          judge({"a": 0.50, "b": 0.60}, reads={"a": {"12": 0.6}, "b": {"12": 0.62}})[1]["b"], "Subject clearer")
    check("judge_shortlist: frames within the close-call share, best first, capped",
          R.judge_shortlist({"a": 100.0, "b": 99.0, "c": 98.0, "d": 97.0, "e": 50.0}, {"a", "b", "c", "d", "e"}),
          ["a", "b", "c"])
    check("judge_shortlist: ineligible frames stay out",
          R.judge_shortlist({"a": 100.0, "b": 99.0}, {"b"}), ["b"])
    check("judge_shortlist: nothing to judge", (R.judge_shortlist({}, set()), R.judge_shortlist({"a": 0.0}, {"a"})), ([], []))
    check("judge_clearer: an unscored or zero keeper never swaps",
          (R.judge_clearer(None, 0.9), R.judge_clearer(0.5, None), R.judge_clearer(0.0, 0.9)), (False, False, False))
    tile_rng = np.random.default_rng(14)
    tiles = S.judge_tiles(tile_rng.integers(0, 255, (300, 500, 3), dtype=np.uint8))
    check("judge_tiles: a 3x3 grid of JUDGE_SIZE squares",
          (len(tiles), {t.shape for t in tiles}), (S.JUDGE_GRID ** 2, {(S.JUDGE_SIZE, S.JUDGE_SIZE, 3)}))
    small = S.judge_tiles(tile_rng.integers(0, 255, (100, 150, 3), dtype=np.uint8))
    check("judge_tiles: a small crop grows to JUDGE_SIZE first", {t.shape for t in small}, {(S.JUDGE_SIZE, S.JUDGE_SIZE, 3)})
    check("judge_tiles: an exact-size crop is one tile", len(S.judge_tiles(np.zeros((224, 224, 3), np.uint8))), 1)

    # flags: listed in column 3, each costs its stars, and they stack -------------
    check("frame_flags: exposure ok and eyes open is no flags", S.frame_flags("ok"), ())
    check("frame_flags: both problems", S.frame_flags("overexposed", True), ("overexposed", "eyes_closed"))
    check("frame_flags: blank comes last", S.frame_flags("underexposed", blank=True), ("underexposed", "blank"))

    # blank frames: one flat colour, always rejected -------------------------------
    blank_rng = np.random.default_rng(36)

    def flat(colour):
        """A 120 × 160 frame of one colour with ±4 of sensor noise."""
        noise = blank_rng.integers(-4, 5, (120, 160, 3))
        return np.clip(np.array(colour) + noise, 0, 255).astype(np.uint8)

    check("is_blank: black, white and flat red are blank",
          [S.is_blank(flat(c)) for c in ((0, 0, 0), (255, 255, 255), (200, 20, 20))], [True, True, True])
    headlights = flat((8, 8, 8))
    headlights[50:75, 20:50] = 250
    headlights[50:75, 110:140] = 250
    check("is_blank: a dark frame with lit headlights is not blank", S.is_blank(headlights), False)
    check("is_blank: share 0 turns it off", S.is_blank(flat((0, 0, 0)), 0.0), False)
    check("penalised_flags: blank costs stars even when the whole burst shares it",
          S.penalised_flags({"a": ("blank",), "b": ("blank",)}), {"a": ("blank",), "b": ("blank",)})

    def blank_rows(flags_of):
        """id -> (keeper, stars, Why tag) for a 3-frame burst scored 9/6/1."""
        open(res_path, "w").close()
        S.process_burst_logic("1", {"a": 9.0, "b": 6.0, "c": 1.0}, flags_of, 3,
                              Namespace(keep_mode="single_best", rank_mode="universal", nk_mode="leave"), res_path)
        rows = [line.strip().split(",") for line in open(res_path)]
        return {r[0]: (r[4], r[5], [t for t in r[6].split(";") if t.startswith("Why|")][0]) for r in rows}

    check("blank: an all-blank burst is rejected in full",
          blank_rows({k: ("blank",) for k in "abc"}),
          {k: ("0", "-1", "Why|Blank") for k in "abc"})
    check("blank: the sharpest frame is blank, a good frame keeps",
          blank_rows({"a": ("blank",), "b": (), "c": ()}),
          {"a": ("0", "-1", "Why|Blank"), "b": ("1", "0", "Why|Keeper"), "c": ("0", "leave", "Why|Outranked")})
    check("blank: Blank is a listed Why reason", "Blank" in S.WHY_REASONS, True)

    def keeper_row(flags, rank_mode, sharp=5000.0, reference=None):
        open(res_path, "w").close()
        S.process_burst_logic("1", {"a": sharp}, {"a": flags}, 1,
                              Namespace(keep_mode="single_best", rank_mode=rank_mode, nk_mode="leave"),
                              res_path, reference=reference)
        row = open(res_path).read().strip().split(",")
        return row[2], int(row[5])

    for mode in ("universal", "binary"):
        check(f"flags ({mode}): clean keeper gets 5 stars", keeper_row((), mode), ("", 5))
        check(f"flags ({mode}): eyes closed is one star lower", keeper_row(("eyes_closed",), mode),
              ("eyes_closed", 4))
    check("relative: a keeper at the reference gets 5 stars", keeper_row((), "relative", 400.0, 400.0), ("", 5))
    check("relative: 80% of the reference is 3 stars", keeper_row((), "relative", 320.0, 400.0), ("", 3))
    check("relative: eyes closed is one star lower", keeper_row(("eyes_closed",), "relative", 400.0, 400.0),
          ("eyes_closed", 4))
    check("relative: a reference of 0 is 0 stars", keeper_row((), "relative", 400.0, 0.0), ("", 0))
    check("relative: no reference (group too small) takes the universal tiers",
          keeper_row((), "relative", 5000.0), ("", 5))
    check("relative reference: one freak frame doesn't set the scale",
          S.relative_references({"g": [100.0] * 19 + [10000.0]})["g"] < 1000, True)
    check("relative reference: a group under RELATIVE_MIN_FRAMES gets none",
          S.relative_references({"g": [100.0] * (S.RELATIVE_MIN_FRAMES - 1), "h": [100.0] * S.RELATIVE_MIN_FRAMES}),
          {"h": 100.0})

    # universal tiers per sharpness mode -----------------------------------------
    check("tier_table: variance modes share TIER_THRESHOLDS",
          [S.tier_table(m) is S.TIER_THRESHOLDS for m in ("subject_focus", "subject_peak", "center", "face_detect", "sam_subject")],
          [True] * 5)
    check("tier_table: own tables", (S.tier_table("peak"), S.tier_table("tiles_uniformity"), S.tier_table("motion_aware")),
          (S.PEAK_TIER_THRESHOLDS, S.UNIFORMITY_TIER_THRESHOLDS, S.MOTION_TIER_THRESHOLDS))
    check("tier_table: every table ends at 0 stars", [t[-1] == (0, 0) or t[-1][1] == 1 for t in S.TIER_THRESHOLDS_BY_MODE.values()],
          [True] * len(S.TIER_THRESHOLDS_BY_MODE))

    def stars_in(sharp_mode, sharp, **kw):
        open(res_path, "w").close()
        S.process_burst_logic("1", {"a": sharp}, {"a": ()}, 1,
                              Namespace(keep_mode="single_best", rank_mode="universal", nk_mode="leave", sharp_mode=sharp_mode),
                              res_path, **kw)
        return int(open(res_path).read().strip().split(",")[5])

    check("universal: a peak score of 150 is 5 stars in peak mode, 0 on the variance scale",
          (stars_in("peak", 150.0), stars_in("subject_focus", 150.0)), (5, 0))
    check("universal: tiles_uniformity has its own table", stars_in("tiles_uniformity", 700.0), 3)
    check("universal: the burst's own mode wins over the run's",
          stars_in("subject_focus", 150.0, mode="peak"), 5)
    check("flags (universal): exposure and eyes closed stack",
          keeper_row(("underexposed", "eyes_closed"), "universal"), ("underexposed;eyes_closed", 3))

    check("penalised_flags: a flag the whole burst shares costs nothing",
          S.penalised_flags({"a": ("underexposed", "eyes_closed"), "b": ("underexposed",)}),
          {"a": ("eyes_closed",), "b": ()})
    check("penalised_flags: a lone frame still pays for its flags",
          S.penalised_flags({"a": ("underexposed",)}), {"a": ("underexposed",)})
    check("penalised_flags: tag-only flags cost nothing",
          S.penalised_flags({"a": ("eyes_closed",), "b": ()}, {"eyes_closed"}), {"a": (), "b": ()})

    open(res_path, "w").close()
    S.process_burst_logic("1", {"a": 5000.0, "b": 4000.0}, {"a": ("underexposed",), "b": ("underexposed",)}, 2,
                          Namespace(keep_mode="keep_all", rank_mode="universal", nk_mode="leave"), res_path)
    rows = [line.strip().split(",") for line in open(res_path)]
    check("burst logic: shared flag keeps its tag but not its penalty",
          [(r[2], int(r[5])) for r in rows], [("underexposed", 5), ("underexposed", 5)])

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
    point_rows = list(_csv.reader(open(points_p)))
    shortlisted_ids = {r[0] for r in point_rows}
    check("stage A: points only for the shortlist", len(shortlisted_ids), 3)
    check("stage A: point prompts leave the box corner empty", {(len(r), r[3], r[4]) for r in point_rows},
          {(6, "", "")})
    check("stage A: no cache means nothing is marked cached", {r[5] for r in point_rows}, {"0"})
    man_bad = os.path.join(tmp, "a_bad.csv")
    with open(man_bad, "w", newline="") as f:
        _csv.writer(f).writerows([["0", frames[0], "9"], ["7", os.path.join(tmp, "gone.jpg"), "9"]])
    pre_bad = os.path.join(tmp, "pre_bad.csv")
    S.main(Namespace(manifest=man_bad, results=os.path.join(tmp, "pts_bad.csv"), progress="",
                     emit_saliency_points=True, keep_mode="single_best", exp_mode="whole_frame",
                     fast_jpeg=False, prescores=pre_bad))
    bad_scored, bad_failed = S.read_prescores(pre_bad)
    check("stage A: an undecodable frame is recorded as failed", (sorted(bad_scored), bad_failed), (["0"], {"7"}))
    try:
        S.main(Namespace(manifest=man_a, results=points_p, progress="", emit_saliency_points=True,
                         keep_mode="single_best", exp_mode="whole_frame", fast_jpeg=False, prescores="",
                         detector=os.path.join(tmp, "missing.onnx")))
        check("stage A: missing detector model fails the run", "no error", "InputError")
    except VD.InputError:
        check("stage A: missing detector model fails the run", "InputError", "InputError")

    # shared detections: a worker handed a stored entry never runs the detector (AC1)
    def detector_ran(rgb, detector):
        raise AssertionError("detector ran")
    saved_detect, S.detect = S.detect, detector_ran
    try:
        stored = {"frame": [400, 400], "detector": "fake", "boxes": [[100, 100, 300, 300, 0.9, 2]]}
        out = S.process_single_saliency(frames[0], False, "whole_frame", "fake.onnx", stored)
    finally:
        S.detect = saved_detect
    check("shared detections: a stored entry skips the detector and is not handed back",
          (out[4], out[1], out[5], out[7]), (None, (0.25, 0.25, 0.75, 0.75), "Subject|Vehicle|Detected", None))

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
    check("stage C: no masks and no detector tags only the fallback (plus the Why reason)",
          {t for r in res_rows for t in r[6].split(";") if not t.startswith("Why|")}, {"Scored|Subject bias"})

    # score cache: plain modes ------------------------------------------------
    import sqlite3 as _sq

    cache_p = os.path.join(tmp, "cache", "scores.sqlite")
    man_p = os.path.join(tmp, "plain.csv")
    with open(man_p, "w", newline="") as f:
        _csv.writer(f).writerows([[str(i), p, str(i)] for i, p in enumerate(frames[:2])])

    def plain_run(**kw):
        opts = dict(manifest=man_p, results=os.path.join(tmp, "plain_res.csv"), progress="",
                    emit_saliency_points=False, rank_mode="universal", sharp_mode="subject_focus",
                    exp_mode="whole_frame", keep_mode="single_best", nk_mode="leave", fast_jpeg=False,
                    prescores="", cache=cache_p)
        opts.update(kw)
        S.main(Namespace(**opts))
        return {r[0]: r[1] for r in _csv.reader(open(opts["results"]))}

    fresh = plain_run()
    db = _sq.connect(cache_p)
    check("cache: one entry per frame", db.execute("SELECT COUNT(*) FROM scores").fetchone()[0], 2)
    db.execute("UPDATE scores SET value = '{\"sharp\": 12345.0, \"flags\": []}'")
    db.commit()
    db.close()
    check("cache: a rerun with other ranking reads the cache instead of decoding",
          plain_run(rank_mode="relative"), {"0": "12345.0", "1": "12345.0"})
    check("cache: another sharpness mode misses", plain_run(sharp_mode="tiles_uniformity")["0"] != "12345.0", True)
    st = os.stat(frames[0])
    os.utime(frames[0], ns=(st.st_atime_ns, st.st_mtime_ns + 10**9))
    check("cache: a modified file is re-scored", plain_run(), {"0": fresh["0"], "1": "12345.0"})
    motion_fresh = plain_run(sharp_mode="motion_aware")
    check("motion_aware: every frame scored without a detector", sorted(motion_fresh), ["0", "1"])
    check("motion_aware: a rerun reads its cache entries", plain_run(sharp_mode="motion_aware"), motion_fresh)

    # ticket 84: the star slope through the real scorer
    def plain_rows(**kw):
        plain_run(**kw)
        return sorted(_csv.reader(open(os.path.join(tmp, "plain_res.csv"))))

    check("slope: under the minimum the run equals one without the flag",
          plain_rows(star_slope=True), plain_rows())
    man_s = os.path.join(tmp, "slope.csv")
    with open(man_s, "w", newline="") as f:
        _csv.writer(f).writerows([[str(i), frames[i % len(frames)], str(i)] for i in range(10)])
    sloped = sorted(((float(r[1]), r[5]) for r in plain_rows(manifest=man_s, star_slope=True)))
    check("slope: ten single-frame bursts rate 1 to 5 in score order",
          ([st for _s, st in sloped] == sorted(st for _s, st in sloped), sloped[0][1], sloped[-1][1]),
          (True, "1", "5"))
    check("slope: off, the same run takes the tier table",
          {r[5] for r in plain_rows(manifest=man_s)} != {st for _s, st in sloped}, True)

    def exif_manifest(name, exposure):
        path = os.path.join(tmp, name)
        with open(path, "w", newline="") as f:
            _csv.writer(f).writerows([[str(i), p, str(i), "", "", "", exposure, "8"]
                                      for i, p in enumerate(frames[:2])])
        return path

    check("cache: a fast shutter keeps the subject bias entry",
          plain_run(manifest=exif_manifest("fast.csv", "0.002"))["1"], "12345.0")
    check("cache: a pan is scored as subject_peak, not read from the subject bias entry",
          plain_run(manifest=exif_manifest("pan.csv", "0.008"))["1"] != "12345.0", True)
    check("diagnostic tags: a pan is tagged Technique|Panning",
          {t for r in _csv.reader(open(os.path.join(tmp, "plain_res.csv"))) for t in r[6].split(";") if not t.startswith("Why|")},
          {"Technique|Panning"})

    db = _sq.connect(cache_p)
    db.execute("UPDATE scores SET used = 0")
    db.commit()
    db.close()
    S.ScoreCache(cache_p).close()
    db = _sq.connect(cache_p)
    check("cache: entries unused for 90 days are dropped", db.execute("SELECT COUNT(*) FROM scores").fetchone()[0], 0)
    db.close()

    # score cache: sam_subject masked scores ------------------------------------
    sam_cache = os.path.join(tmp, "sam.sqlite")
    mask_p = os.path.join(tmp, "mask.png")
    cv2.imwrite(mask_p, np.full((120, 120), 255, dtype=np.uint8))

    def sam_stage_a(edited):
        with open(man_a, "w", newline="") as f:
            _csv.writer(f).writerows([[str(i), p, "9", "", "", edited] for i, p in enumerate(frames)])
        S.main(Namespace(manifest=man_a, results=points_p, progress="", emit_saliency_points=True,
                         keep_mode="single_best", exp_mode="whole_frame", fast_jpeg=False, prescores=pre_p,
                         cache=sam_cache, sam_model="sam-test"))
        return {r[0]: r[5] for r in _csv.reader(open(points_p))}

    def sam_stage_b(edited, masked_ids):
        man_b = os.path.join(tmp, "b.csv")
        with open(man_b, "w", newline="") as f:
            _csv.writer(f).writerows([[str(i), p, "9", mask_p if str(i) in masked_ids else "",
                                       "1" if str(i) in short else "0", edited] for i, p in enumerate(frames)])
        res_b = os.path.join(tmp, "resb.csv")
        S.main(Namespace(manifest=man_b, results=res_b, progress="", emit_saliency_points=False,
                         rank_mode="universal", sharp_mode="sam_subject", exp_mode="whole_frame",
                         keep_mode="single_best", nk_mode="leave", fast_jpeg=False, prescores=pre_p,
                         cache=sam_cache, sam_model="sam-test"))
        return sorted((r[0], r[1], r[4]) for r in _csv.reader(open(res_b)))

    marks = sam_stage_a("t1")
    short = set(marks)
    check("sam cache: a first run has no masked scores cached", set(marks.values()), {"0"})
    first = sam_stage_b("t1", short)
    check("sam cache: masked scores are cached for the next run", set(sam_stage_a("t1").values()), {"1"})
    check("sam cache: cached masked scores match the masked run", sam_stage_b("t1", set()), first)
    check("sam cache: a darktable edit invalidates the masked score", set(sam_stage_a("t2").values()), {"0"})

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

    # pans with the same crisp subject: one failed to blur the background, one didn't
    pan_missed = detail
    pan_blurred = cv2.GaussianBlur(detail, (31, 31), 0)
    pan_blurred[100:200, 100:200] = detail[100:200, 100:200]

    def blur_shift(mode):
        a, b = S.sharpness_score(pan_missed, mode), S.sharpness_score(pan_blurred, mode)
        return abs(a - b) / a

    # not exactly 0: with a crisp background, a crisp non-centre patch can win the max
    check("subject_peak: background blur barely moves the score", blur_shift("subject_peak") < 0.05, True)
    check("subject_peak: moves less than subject bias does",
          blur_shift("subject_peak") * 5 < blur_shift("subject_focus"), True)

    check("face mode without a face falls back to subject bias",
          S.sharpness_score(one_spot, "face_detect"), S.sharpness_score(one_spot, "subject_focus"))
    check("face mode without a face never flags closed eyes",
          S.face_detect_score(one_spot), (S.sharpness_score(one_spot, "subject_focus"), False))

    # motion_aware -------------------------------------------------------------
    texture = rng.integers(0, 256, (240, 240), dtype=np.uint8)
    streak_h = cv2.blur(texture, (31, 1))
    streak_v = cv2.blur(texture, (1, 31))

    def framed(background, centre):
        out = background.copy()
        out[80:160, 80:160] = centre[80:160, 80:160]  # the centre third: a 2x2 block of motion tiles
        return out

    def motion_class(gray, share=S.STREAK_SHARE):
        return S.classify_motion(S.motion_tiles(gray), S.CENTRE_BOX, share)[0]

    check("motion: sharp car on a streaked background is a pan", motion_class(framed(streak_h, texture)), "pan")
    check("motion: whole frame streaked one way is motion blur", motion_class(streak_h), "motion_blur")
    check("motion: car streaked across the pan is a missed pan",
          motion_class(framed(streak_h, streak_v)), "missed_pan")
    check("motion: sharp everywhere is ordinary", motion_class(texture), "ordinary")
    check("motion: straightness of a clean streak is high",
          S.classify_motion(S.motion_tiles(streak_h), S.CENTRE_BOX, S.STREAK_SHARE)[1] > 0.6, True)

    rgb_of = lambda g: np.dstack([g, g, g])
    full_contrast = S.normalised_sharpness(rgb_of(texture))
    half_contrast = S.normalised_sharpness(rgb_of((texture.astype(np.float64) * 0.5 + 64).astype(np.uint8)))
    check("normalised sharpness: half the contrast scores within 10%",
          abs(full_contrast - half_contrast) / full_contrast < 0.10, True)
    check("normalised sharpness: a streaked frame scores lower",
          S.normalised_sharpness(rgb_of(streak_h)) < full_contrast * 0.7, True)
    check("subject crop: padded box cut from the full frame",
          S.subject_crop(np.zeros((1000, 2000, 3), np.uint8), (0.25, 0.25, 0.75, 0.75)).shape, (600, 1200, 3))
    check("subject crop: shrunk to SUBJECT_CROP_MAX",
          max(S.subject_crop(np.zeros((4000, 6000, 3), np.uint8), (0.0, 0.0, 1.0, 1.0)).shape[:2])
          == S.SUBJECT_CROP_MAX, True)

    # same_scale: one burst's cars compared at one size
    big = rgb_of(cv2.resize(texture, (1800, 1200), interpolation=cv2.INTER_CUBIC))
    small = S.shrunk_to(big, 600)
    check("shrunk_to: long side exact, aspect kept", small.shape[:2], (400, 600))
    check("shrunk_to: never grows", S.shrunk_to(small, 900).shape, small.shape)
    check("scale ladder: steps under the long side, then its own size",
          [s for s, _ in S.scale_ladder(small)], [400, 600])
    size, subject_of = S.same_scale({"near": S.scale_ladder(big), "far": S.scale_ladder(small)})
    check("same_scale: the largest size both crops have", size, 600)
    check("same_scale: the same scene at 600 and 1800 px scores within 5%",
          abs(subject_of["near"] - subject_of["far"]) / subject_of["far"] < 0.05, True)
    check("same_scale: a crop under the smallest step leaves each frame at its smallest size",
          S.same_scale({"a": [[300, 5.0]], "b": [[400, 7.0], [900, 9.0]]}), (None, {"a": 5.0, "b": 7.0}))
    check("same_scale: a lone frame keeps its own size", S.same_scale({"a": [[400, 7.0], [900, 9.0]]}), (900, {"a": 9.0}))
    check("same_scale: no frames", S.same_scale({}), (None, {}))
    check("class factor: pan, missed pan, ordinary",
          (S.class_factor("pan"), S.class_factor("missed_pan"), S.class_factor("ordinary")),
          (S.PAN_BONUS, S.MISSED_PAN_FACTOR, 1.0))

    check("EXIF prior: unknown shutter uses the default", S.streak_share_needed(0.0, 0.0), S.STREAK_SHARE)
    check("EXIF prior: 1/2000 needs more streak", S.streak_share_needed(1 / 2000, 400), S.STREAK_SHARE_FAST)
    check("EXIF prior: 1/60 at 100 mm needs less", S.streak_share_needed(1 / 60, 100), S.STREAK_SHARE_SLOW)
    check("EXIF prior: 1/250 at 50 mm keeps the default", S.streak_share_needed(1 / 250, 50), S.STREAK_SHARE)

    check("motion blur: lifted to the burst's median",
          S.lift_motion_blur({"a": 100.0, "b": 300.0, "c": 50.0}, {"c": ("motion_blur", 0.8)}),
          {"a": 100.0, "b": 300.0, "c": 200.0})
    blur3 = {2: ("motion_blur", 0.8), 3: ("motion_blur", 0.6), 4: ("motion_blur", 0.7)}
    check("lift: raised frames keep their order",
          S.lift_motion_blur({1: 300.0, 2: 200.0, 3: 220.0, 4: 260.0}, blur3), {1: 300.0, 2: 280.0, 3: 300.0, 4: 340.0})
    check("lift: all-blur burst keeps car sharpness",
          S.lift_motion_blur({"a": 10.0, "b": 20.0}, {"a": ("motion_blur", 0.8), "b": ("motion_blur", 0.6)}),
          {"a": 10.0, "b": 20.0})
    check("lift: blur already above the rest is not lowered",
          S.lift_motion_blur({"a": 100.0, "b": 900.0}, {"b": ("motion_blur", 0.5)}), {"a": 100.0, "b": 900.0})

    def motion_stars(score, star_scale):
        open(res_path, "w").close()
        S.process_burst_logic("1", {"a": score}, {"a": ()}, 1,
                              Namespace(keep_mode="single_best", rank_mode="universal", nk_mode="leave",
                                        sharp_mode="motion_aware", star_scale=star_scale), res_path)
        return int(open(res_path).read().strip().split(",")[5])

    check("stars: motion_aware uses its own tiers", motion_stars(450.0, 1.0), 4)
    check("stars: a star scale under 1 is more generous", motion_stars(450.0, 0.5), 5)
    check("stars: a star scale over 1 is stricter", motion_stars(450.0, 2.0), 2)

    # keeper margin and graded non-keepers ---------------------------------------
    burst = {"a": 3000.0, "b": 2900.0, "c": 2400.0, "d": 1900.0, "e": 500.0}

    def graded(margin, star_scale=1.0):
        open(res_path, "w").close()
        S.process_burst_logic("1", burst, {k: () for k in burst}, len(burst),
                              Namespace(keep_mode="single_best", rank_mode="universal", nk_mode="graded",
                                        keep_margin=margin, star_scale=star_scale), res_path)
        rows = [line.split(",") for line in open(res_path).read().strip().splitlines()]
        return {r[0]: (int(r[4]), int(r[5])) for r in rows}

    check("keeper margin: frames within 95% of the best are kept too", graded(0.95),
          {"a": (1, 5), "b": (1, 4), "c": (0, 2), "d": (0, 1), "e": (0, 0)})
    check("keeper margin off: graded non-keepers step down from the keeper", graded(0.0),
          {"a": (1, 5), "b": (0, 4), "c": (0, 3), "d": (0, 2), "e": (0, 0)})
    check("graded: a stricter star scale drops non-keepers faster", graded(0.0, 2.0)["c"], (0, 0))

    # report_rows --------------------------------------------------------------
    rep_manifest = [("1", "/p/a.jpg", "0", "", "", "", 0.0, 0.0, 0.0, "37"), ("2", "/p/b.jpg", "0", "", "", "", 0.0, 0.0, 0.0, ""),
                    ("3", "/p/c.jpg", "1", "", "", "", 0.0, 0.0, 0.0, "")]
    rep_results = [["2", "40.0", "blur", "0", "0", "leave", ""], ["1", "80.0", "", "0", "1", "4", "Subject|Car;Why|Keeper"],
                   ["3", "55.0", "", "1", "1", "3", ""]]
    rep = S.report_rows(rep_manifest, rep_results, lambda n: 1)
    check("report: bursts in manifest order, best frame first", [r[1] for r in rep], ["a.jpg", "b.jpg", "c.jpg"])
    check("report: a keeper says its rank and the allowance", rep[0][9], "kept: rank 1 of 2, 1 allowed")
    check("report: a non-keeper lists its flags", rep[1][9],
          "not kept: rank 2 of 2, only 1 allowed or not eligible; flagged blur")
    check("report: diagnostic tags carry through", rep[0][8], "Subject|Car;Why|Keeper")
    check("report: the folder is the eleventh column", rep[0][10], os.path.dirname("/p/a.jpg"))
    check("report: the reason column is the Why tag", (rep[0][11], rep[1][11]), ("Keeper", ""))
    check("report: the car column is twelfth", (rep[0][12], rep[1][12]), ("37", ""))
    check("report: one column per header", len(rep[0]), len(S.REPORT_HEADER))
    check("report: direction is fourteenth, blank without a detector", rep[0][13], "")
    check("report: direction per burst", S.report_rows(rep_manifest, rep_results, lambda n: 1, {"0": "left"})[0][13],
          "left")
    check("report: the id column is darktable's id", [r[14] for r in rep], ["1", "2", "3"])
    check("report: score parts blank outside motion_aware", rep[0][15:20], ["", "", "", "", ""])
    parts = S.report_rows(rep_manifest, rep_results, lambda n: 1, None,
                          {"1": (69.565217, "pan", 0.812345, "640x400 → 600", 55.123456)})
    check("report: score parts per frame, rounded", (parts[0][15:20], parts[1][15:20]),
          ([69.5652, "pan", 0.8123, "640x400 → 600", 55.1235], ["", "", "", "", ""]))
    check("report: parts without an own-size subject leave it blank",
          S.report_rows(rep_manifest, rep_results, lambda n: 1, None, {"1": (1.0, "pan", 0.5, "9x9")})[0][19], "")
    check("report: parts columns, then reads, then judge, are last", S.REPORT_HEADER[-8:],
          ["id", "subject", "motion", "straightness", "crop", "subject_own", "reads", "judge"])
    judged_rep = S.report_rows(rep_manifest, rep_results, lambda n: 1, judged_of={"1": 0.612345})
    check("report: the judge score per judged frame, blank for the rest", [r[-1] for r in judged_rep], [0.6123, "", ""])
    judged_results = [["2", "40.0", "", "0", "0", "leave", "Why|Close call"],
                      ["1", "80.0", "", "0", "1", "4", "Why|Subject clearer"], ["3", "55.0", "", "1", "1", "3", ""]]
    check("report: a judge keeper says why", S.report_rows(rep_manifest, judged_results, lambda n: 1)[0][9],
          "kept: rank 1 of 2, a close call the sharpness judge scores clearer")

    # framing_flags --------------------------------------------------------------
    def det(*boxes):
        return {"frame": [1000, 500], "detector": "t", "boxes": [list(b) + [0.9, 3] for b in boxes]}

    # a car crossing left to right, a 200x100 box; the last frame reaches the right (leading) edge
    crossing = [S.frame_boxes(det((x, 200, x + 200, 300))) for x in (100, 300, 500, 800)]
    direction, flags = S.framing_flags(crossing)
    check("framing: direction follows the box", direction, "right")
    check("framing: touching the leading edge is cut off", flags, [(), (), (), ("cut_off",)])
    # going left, the same last frame touches the trailing edge by 0: not cut off
    direction, flags = S.framing_flags(list(reversed(crossing)))
    check("framing: touching the trailing edge is fine", (direction, flags[0]), ("left", ()))
    # going left, 30 of 200 px past the trailing (right) edge is over CUT_TRAILING_SHARE
    past_trailing = [S.frame_boxes(det((830, 200, 1030, 300)))] + list(reversed(crossing))[1:]
    check("framing: well past the trailing edge is cut off", S.framing_flags(past_trailing),
          ("left", [("cut_off",), (), (), ()]))
    check("framing: under 3 boxes is unknown", S.travel_direction(S.burst_targets(crossing[:2])), "unknown")
    check("framing: a frame-filling car is never cut off",
          S.is_cut_off((0.0, 0.0, 1.0, 0.9, 0.9), "right"), False)
    # a nearer car covering half of the target in frame 2
    blocked = crossing[:1] + [S.frame_boxes(det((300, 200, 500, 300), (380, 150, 700, 400)))] + crossing[2:3]
    check("framing: a larger box over the target is blocked", S.framing_flags(blocked)[1], [(), ("blocked",), ()])
    check("framing: no detections, no flags", S.framing_flags([[], []]), ("unknown", [(), ()]))

    def shaped(aspects):
        return [None if a is None else (0.1, 0.1, 0.1 + 0.1 * a, 0.2, 0.9) for a in aspects]
    check("views: head-on then side-on is two views", S.burst_views(shaped([1.2, 1.3, 1.25, 2.2, 2.3])), [0, 0, 0, 1, 1])
    check("views: one odd box joins its neighbours", S.burst_views(shaped([1.2, 4.5, 1.3])), [0, 0, 0])
    check("views: no target is None", S.burst_views(shaped([1.2, None, 1.3, None])), [0, None, 0, None])
    check("views: no targets at all", S.burst_views([None, None]), [None, None])
    check("framing: a shared cut_off costs nothing",
          S.penalised_flags({"a": ("cut_off",), "b": ("cut_off",)}), {"a": (), "b": ()})
    # frame 5 couldn't be read, so it has no result row; the allowance still counts it
    unread_manifest = rep_manifest + [("5", "/p/e.jpg", "1", "", "", "", 0.0, 0.0, 0.0, "")]
    unread = S.report_rows(unread_manifest, rep_results, lambda n: n)
    check("report: the allowance counts unreadable frames", unread[2][9], "kept: rank 1 of 1, 2 allowed")

    with tempfile.TemporaryDirectory() as arch_tmp:
        arch_src = os.path.join(arch_tmp, "last-run.csv")
        with open(arch_src, "w") as f:
            f.write("x\n")
        arch_dir = os.path.join(arch_tmp, "reports")
        os.makedirs(arch_dir)
        for stamp in ("20200101-000001", "20200101-000002", "20200101-000003"):
            open(os.path.join(arch_dir, stamp + ".csv"), "w").close()
        open(os.path.join(arch_dir, "notes.txt"), "w").close()
        S.archive_report(arch_src, arch_dir, 3)
        left = sorted(os.listdir(arch_dir))
        check("report archive: keeps the newest 3 and leaves other files alone", len(left), 4)
        check("report archive: the oldest is deleted", "20200101-000001.csv" in left, False)
        check("report archive: the new copy is added", any(n > "2021" for n in left), True)

    # cache fingerprint ---------------------------------------------------------
    # every public constant is filed as a cache input or as neutral, so a new one
    # can't silently leave stale scores in the cache
    constants = {n for n, v in vars(S).items() if n.isupper() and not n.startswith("_")
                 and not callable(v) and not hasattr(v, "__file__")}
    filed = set(S.CACHE_INPUTS) | set(S.CACHE_NEUTRAL)
    check("fingerprint: every constant is filed as input or neutral", sorted(constants - filed), [])
    check("fingerprint: nothing filed twice", sorted(set(S.CACHE_INPUTS) & set(S.CACHE_NEUTRAL)), [])
    check("fingerprint: nothing filed that doesn't exist", sorted(filed - constants), [])
    fp = S.cache_fingerprint()
    check("fingerprint: 12 hex chars", (len(fp), all(c in "0123456789abcdef" for c in fp)), (12, True))
    S._FINGERPRINT, saved = "", S.MAX_DIM
    S.MAX_DIM = saved + 1
    changed = S.cache_fingerprint()
    S.MAX_DIM, S._FINGERPRINT = saved, ""
    check("fingerprint: a changed input changes it", changed != fp, True)
    check("fingerprint: restored inputs give the old value back", S.cache_fingerprint(), fp)
    check("fingerprint: it is part of every cache key", fp in S.ScoreCache._key(("score", "x")), True)

    # common.py ----------------------------------------------------------------
    # Shared byte for byte with the tagging repo: bump COMMON_SHA256 there too.
    COMMON_SHA256 = "e18eed8d2048bb379ed2bdbb9d5292803bc589858750f00e529115bde0ae4480"
    import hashlib
    import common
    with open(common.__file__, "rb") as f:
        digest = hashlib.sha256(f.read().replace(b"\r\n", b"\n")).hexdigest()
    check("common.py matches the shared copy", digest, COMMON_SHA256)
    # Shared byte for byte with the tagging repo: bump VEHICLE_DETECT_SHA256 there too.
    VEHICLE_DETECT_SHA256 = "fc181a26478de85d3d7a6a23c42a61c980e6b390532464faaef2de7ef260c29e"
    with open(os.path.join(os.path.dirname(common.__file__), "vehicle_detect.py"), "rb") as f:
        digest = hashlib.sha256(f.read().replace(b"\r\n", b"\n")).hexdigest()
    check("vehicle_detect.py matches the shared copy", digest, VEHICLE_DETECT_SHA256)
    check("common: RAW_EXTENSIONS is the one score_images uses", S.RAW_EXTENSIONS is common.RAW_EXTENSIONS, True)

    # eval_culling.py keeps its own copy of the motion tags (it imports no cv2/numpy) -----
    import eval_culling
    check("eval_culling: MOTION_CLASS mirrors MOTION_TAGS", eval_culling.MOTION_CLASS, {v: k for k, v in S.MOTION_TAGS.items()})
    check("eval_culling: score-part constants mirror score_images",
          {n: eval_culling.PART_DEFAULTS[n] for n in ("PAN_BONUS", "MISSED_PAN_FACTOR")},
          {"PAN_BONUS": S.PAN_BONUS, "MISSED_PAN_FACTOR": S.MISSED_PAN_FACTOR})
    check("eval_culling: lift mirrors lift_motion_blur",
          eval_culling.lift_blur({1: 300.0, 2: 200.0, 3: 220.0, 4: 260.0}, blur3),
          S.lift_motion_blur({1: 300.0, 2: 200.0, 3: 220.0, 4: 260.0}, blur3))
    check("eval_culling: an all-blur burst keeps car sharpness like lift_motion_blur",
          eval_culling.lift_blur({"a": 10.0, "b": 20.0}, {"a": ("motion_blur", 0.8), "b": ("motion_blur", 0.6)}),
          S.lift_motion_blur({"a": 10.0, "b": 20.0}, {"a": ("motion_blur", 0.8), "b": ("motion_blur", 0.6)}))
    check("eval_culling: mode switches name technique_tag's tags",
          sorted(t for _m, t in eval_culling.MODE_SWITCH), sorted({S.technique_tag("subject_peak"), S.technique_tag("subject_focus")}))
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, "x.txt")
        with open(p, "w") as f:
            f.write("old")
        try:
            with common.atomic_write(p) as f:
                f.write("new")
                raise RuntimeError("abort")
        except RuntimeError:
            pass
        with open(p) as f:
            check("common: atomic_write keeps the old file on failure", f.read(), "old")
        with common.atomic_write(p) as f:
            f.write("new")
        with open(p) as f:
            check("common: atomic_write replaces on success", f.read(), "new")
        check("common: atomic_write leaves no temp file", sorted(os.listdir(d)), ["x.txt"])

    # the real script, launched as darktable does: argparse checks every help string at startup (3.14+)
    import subprocess
    launched = subprocess.run([sys.executable, S.__file__, "--help"], capture_output=True, text=True)
    check("scorer: starts and builds its arguments", (launched.returncode, launched.stderr[-200:]), (0, ""))

    print("")
    if failures == 0:
        print("all tests passed")
        sys.exit(0)
    print(f"{failures} test(s) failed")
    sys.exit(1)


if __name__ == "__main__":
    run_tests()
