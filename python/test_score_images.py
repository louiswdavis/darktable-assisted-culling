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

    # decode_vehicles / pick_vehicle -------------------------------------------
    raw = np.zeros((8400, 85), np.float32)
    raw[410, :4] = (0.5, 0.5, np.log(5), np.log(5))   # stride-8 cell (10, 5): 40 px box centred (84, 44)
    raw[410, 4], raw[410, 5 + 2] = 0.9, 1.0          # a car
    raw[411, :4] = (-0.5, 0.5, np.log(5), np.log(5))  # the same box, weaker: NMS drops it
    raw[411, 4], raw[411, 5 + 2] = 0.6, 1.0
    raw[500, :4] = (0.5, 0.5, np.log(5), np.log(5))
    raw[500, 4], raw[500, 5 + 0] = 0.9, 1.0          # a person: not a vehicle
    boxes = S.decode_vehicles(raw, 0.5)
    check("detector: one vehicle survives class filter and NMS", len(boxes), 1)
    check("detector: box mapped back to source pixels",
          [round(float(v), 1) for v in boxes[0][:5]], [128.0, 48.0, 208.0, 128.0, 0.9])
    check("detector: box keeps its COCO class", boxes[0][5], 2)
    check("detector: nothing above threshold → no boxes", S.decode_vehicles(np.zeros((8400, 85), np.float32), 1.0), [])

    weak = np.zeros((8400, 85), np.float32)
    weak[410, :4] = (0.5, 0.5, np.log(5), np.log(5))  # 40 px box at scale 0.5 → 80 px of a 400 px frame
    weak[410, 4], weak[410, 5 + 2] = 0.5, 0.4         # a car at 0.20, under the threshold
    weak[500, 4], weak[500, 5 + 0] = 0.9, 0.5         # a person at 0.45
    check("detector log: names the strongest detection and the strongest vehicle",
          S.strongest_detections(weak, 0.5, 400, 400),
          "strongest person 0.45 (0.04x0.04 of frame), strongest vehicle car 0.20 (0.20x0.20 of frame)")

    small_sure = (10, 10, 30, 30, 0.95, 2)
    big_unsure = (100, 50, 300, 250, 0.5, 7)
    check("pick vehicle: prominence beats raw confidence",
          S.pick_vehicle([small_sure, big_unsure], 400, 300), ((0.25, 50 / 300, 0.75, 250 / 300), 7))
    check("pick vehicle: box clipped to the frame",
          S.pick_vehicle([(-20, 0, 420, 150, 0.8, 3)], 400, 300), ((0.0, 0.0, 1.0, 0.5), 3))
    check("pick vehicle: none found", S.pick_vehicle([], 400, 300), None)

    # diagnostic tags ------------------------------------------------------------
    check("subject tag: vehicle class", S.subject_tag(7), "Subject|Vehicle|Truck")
    check("subject tag: no vehicle found", S.subject_tag(None), "Subject|Vehicle|Guessed")
    check("technique tag: pan", S.technique_tag("subject_peak"), "Technique|Panning")
    check("technique tag: wide aperture", S.technique_tag("subject_focus"), "Technique|Shallow DoF")

    # parse_manifest_row -----------------------------------------------------
    check("manifest: 4-column row keeps mask path",
          S.parse_manifest_row(["1", "/a.jpg", "3", "/m.png"]), ("1", "/a.jpg", "3", "/m.png", "", "", 0.0, 0.0))
    check("manifest: 5-column row keeps shortlist flag",
          S.parse_manifest_row(["1", "/a.jpg", "3", "", "0"]), ("1", "/a.jpg", "3", "", "0", "", 0.0, 0.0))
    check("manifest: 6-column row keeps edit time",
          S.parse_manifest_row(["1", "/a.jpg", "3", "", "", "t"]), ("1", "/a.jpg", "3", "", "", "t", 0.0, 0.0))
    check("manifest: 3-column row gets empty mask path",
          S.parse_manifest_row(["1", "/a.jpg", "3"]), ("1", "/a.jpg", "3", "", "", "", 0.0, 0.0))
    check("manifest: 8-column row keeps shutter and aperture",
          S.parse_manifest_row(["1", "/a.jpg", "3", "", "", "", "0.0080000004", "2.8"]),
          ("1", "/a.jpg", "3", "", "", "", 0.0080000004, 2.8))

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

    # flags: listed in column 3, each costs its stars, and they stack -------------
    check("frame_flags: exposure ok and eyes open is no flags", S.frame_flags("ok"), ())
    check("frame_flags: both problems", S.frame_flags("overexposed", True), ("overexposed", "eyes_closed"))

    def keeper_row(flags, rank_mode):
        open(res_path, "w").close()
        S.process_burst_logic("1", {"a": 5000.0}, {"a": flags}, 1,
                              Namespace(keep_mode="single_best", rank_mode=rank_mode, nk_mode="leave"),
                              res_path)
        row = open(res_path).read().strip().split(",")
        return row[2], int(row[5])

    for mode in ("universal", "relative"):
        check(f"flags ({mode}): clean keeper gets 5 stars", keeper_row((), mode), ("", 5))
        check(f"flags ({mode}): eyes closed is one star lower", keeper_row(("eyes_closed",), mode),
              ("eyes_closed", 4))
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
    try:
        S.main(Namespace(manifest=man_a, results=points_p, progress="", emit_saliency_points=True,
                         keep_mode="single_best", exp_mode="whole_frame", fast_jpeg=False, prescores="",
                         detector=os.path.join(tmp, "missing.onnx")))
        check("stage A: missing detector model fails the run", "no error", "FileNotFoundError")
    except FileNotFoundError:
        check("stage A: missing detector model fails the run", "FileNotFoundError", "FileNotFoundError")

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
    check("stage C: no masks and no detector tags only the fallback",
          {r[6] for r in res_rows}, {"Scored|Subject bias"})

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
          {r[6] for r in _csv.reader(open(os.path.join(tmp, "plain_res.csv")))}, {"Technique|Panning"})

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


    print("")
    if failures == 0:
        print("all tests passed")
        sys.exit(0)
    print(f"{failures} test(s) failed")
    sys.exit(1)


if __name__ == "__main__":
    run_tests()
