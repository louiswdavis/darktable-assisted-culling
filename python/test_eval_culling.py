# Run with: python python/test_eval_culling.py
# Exercises eval_culling.py on a synthetic shoot in a temp folder; stdlib only, no darktable.

import os
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import eval_culling as E

failures = 0


def check(name, got, want):
    global failures
    if got != want:
        failures += 1
        print(f"FAIL {name}: got {got!r}, want {want!r}")
    else:
        print(f"ok   {name}")


def touch(path, text=""):
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def xmp(rating):
    return f'<x:xmpmeta><rdf:Description xmp:Rating="{rating}" darktable:xmp_version="5"/></x:xmpmeta>'


# ranks / spearman -----------------------------------------------------------
check("ranks: ties share their mean rank", E.ranks([10, 20, 20, 30]), [1.0, 2.5, 2.5, 4.0])
check("spearman: identical order is +1", round(E.spearman([1, 2, 3, 4], [10, 20, 30, 40]), 6), 1.0)
check("spearman: reversed order is -1", round(E.spearman([1, 2, 3, 4], [40, 30, 20, 10]), 6), -1.0)
check("spearman: under 3 pairs is n/a", E.spearman([1, 2], [2, 1]), None)
check("spearman: a constant side is n/a", E.spearman([3, 3, 3], [1, 2, 3]), None)

# parse_rating ---------------------------------------------------------------
check("parse_rating: attribute form", E.parse_rating(xmp(3)), (3, False))
check("parse_rating: element form", E.parse_rating("<xmp:Rating>4</xmp:Rating>"), (4, False))
check("parse_rating: -1 is a reject", E.parse_rating(xmp(-1)), (0, True))
check("parse_rating: no rating", E.parse_rating("<x:xmpmeta/>"), None)

with tempfile.TemporaryDirectory() as tmp:
    shoot = os.path.join(tmp, "shoot")
    os.mkdir(shoot)
    # burst A: two JPEG+ARW pairs and a lone ARW; burst B: three JPEGs
    for name in ("a1.JPG", "a1.ARW", "a2.jpg", "a2.ARW", "a3.ARW", "b1.jpg", "b2.jpg", "b3.jpg", "notes.txt"):
        touch(os.path.join(shoot, name))
    touch(os.path.join(shoot, "a1.ARW.xmp"), xmp(5))     # paired RAW's sidecar rates the shot
    touch(os.path.join(shoot, "a2.jpg.xmp"), xmp(-1))
    touch(os.path.join(shoot, "a3.ARW.xmp"), xmp(2))
    touch(os.path.join(shoot, "b1.jpg.xmp"), xmp(4))
    touch(os.path.join(shoot, "b2.jpg.xmp"), xmp(3))
    # b3 is unrated by hand

    files = E.photos([shoot])
    check("photos: RAW with a JPEG beside it is skipped, sorted",
          [os.path.basename(f) for f in files], ["a1.JPG", "a2.jpg", "a3.ARW", "b1.jpg", "b2.jpg", "b3.jpg"])
    check("photos: a file is taken as given", E.photos([os.path.join(shoot, "b3.jpg")]), [os.path.join(shoot, "b3.jpg")])

    check("sidecar_rating: paired RAW's sidecar found from the JPEG", E.sidecar_rating(os.path.join(shoot, "a1.JPG")), (5, False))
    check("sidecar_rating: own sidecar", E.sidecar_rating(os.path.join(shoot, "a2.jpg")), (0, True))
    check("sidecar_rating: none", E.sidecar_rating(os.path.join(shoot, "b3.jpg")), None)

    truth = E.sidecar_truth(files)
    check("sidecar_truth: five rated shots", len(truth), 5)

    report = os.path.join(tmp, "last-run.csv")
    touch(report, "\n".join([
        "burst,file,rank,of,score,stars,keeper,flags,tags,why,folder,reason",
        f"A,a1.JPG,1,3,900,5,yes,,Technique|Panning;Why|Keeper,kept,{shoot},Keeper",
        f"A,a2.jpg,2,3,700,3,yes,,Why|Keeper by margin,kept,{shoot},Keeper by margin",
        f"A,a3.ARW,3,3,200,leave,no,,Technique|Motion Blur;Why|Outranked,not kept,{shoot},Outranked",
        f"B,b1.jpg,1,3,800,4,yes,,Why|Keeper,kept,{shoot},Keeper",
        f"B,b2.jpg,2,3,600,2,no,,Why|Graded,not kept,{shoot},Graded",
        f"B,b3.jpg,3,3,500,1,no,,Why|Graded,not kept,{shoot},Graded",
        f"C,c1.jpg,1,1,500,3,yes,,Why|Keeper,kept,{os.path.join(tmp, 'elsewhere')},Keeper",
    ]) + "\n")

    frames = E.read_report(report, "subject_focus")
    check("read_report: rows", len(frames), 7)
    check("frame_of: leave is unrated", frames[2]["stars"], None)
    check("frame_of: motion class from the Technique tag", [f["motion"] for f in frames[:3]], ["pan", "ordinary", "motion_blur"])
    check("frame_of: Panning in subject_focus means the burst switched to subject_peak",
          [f["mode"] for f in frames[:2]], ["subject_peak", "subject_focus"])
    check("frame_of: no switch outside subject_focus", E.frame_of({"burst": "A", "file": "x", "tags": "Technique|Panning"}, "motion_aware")["mode"], "motion_aware")

    wanted = {E.shot_key(p) for p in files}
    mine = [f for f in frames if E.shot_key(f["path"]) in wanted]
    check("shot_key: rows outside the given photos drop", len(mine), 6)

    result = E.evaluate(mine, truth, 1)
    o = result["overall"]
    check("evaluate: b3 has no hand rating", result["no_truth"], 1)
    check("evaluate: picks are rated 1+ and not rejected", o["picks"], 4)         # a1, a3, b1, b2
    check("evaluate: hits", o["hits"], 2)                                          # a1, b1 kept
    check("evaluate: false keepers", (o["false"], o["kept"]), (1, 3))               # a2 kept but rejected by hand
    check("evaluate: unrated frames leave the correlation", (o["rated"], o["unrated"]), (4, 1))
    check("evaluate: rejected counts", result["truth_rejected"], 1)
    check("evaluate: per burst keys", list(result["by_burst"]), ["A", "B"])
    check("evaluate: burst B spearman is n/a with 2 rated frames", result["by_burst"]["B"]["spearman"], None)
    check("evaluate: motion classes", list(result["by_motion"]), ["motion_blur", "ordinary", "pan"])
    check("evaluate: modes", list(result["by_mode"]), ["subject_focus", "subject_peak"])
    check("evaluate: pick threshold 4 narrows the picks", E.evaluate(mine, truth, 4)["overall"]["picks"], 2)

    text = E.render(result, 1)
    check("render: same input, same text", E.render(E.evaluate(mine, truth, 1), 1), text)
    check("render: overall line", "overall: 5 frames, picks 4, kept 3, hit rate 50.0%, false keepers 1 of 3 (33.3%), Spearman +0.80 (n=4, 1 left unrated)" in text, True)

    # per burst ranking: A has 3 hand-rated frames, B only 2 (b3 is unrated by hand)
    ranking = result["ranking"]
    check("burst_ranking: A judged, B skipped", (list(ranking["bursts"]), ranking["skipped"]), (["A"], 1))
    a = ranking["bursts"]["A"]
    check("burst_ranking: top-1 is a pick, first frame by file when ids are missing", (a["top1"], a["frames"], a["first"]), (True, 3, "a1.JPG"))
    check("burst_ranking: Spearman of score vs stars", round(a["spearman"], 6), 0.5)   # scores 900/700/200 vs stars 5/-1/2
    check("render: ranking summary", "mean top-1 agreement 100.0%, median Spearman +0.50 (n=1)" in text, True)
    check("render: worst bursts name their first frame", "a1.JPG" in text.split("worst 5 by Spearman")[1], True)
    check("evaluate: no ranking without scores", E.evaluate([{k: v for k, v in f.items() if k != "score"} for f in mine], truth, 1)["ranking"], None)

    # truth CSV: bare names match any folder, full paths match their folder
    truth_csv = os.path.join(tmp, "truth.csv")
    touch(truth_csv, "file,rating,reject\na1.JPG,5,no\na2.jpg,0,yes\n" + os.path.join(shoot, "a3.ARW") + ",2,\nb1.jpg,-1,\n")
    t = E.read_truth_csv(truth_csv)
    check("read_truth_csv: bare name keys on the stem", t[("", "a1")], (5, False))
    check("read_truth_csv: reject column", t[("", "a2")], (0, True))
    check("read_truth_csv: -1 rating is a reject", t[("", "b1")], (0, True))
    check("read_truth_csv: full path keys on its folder", E.lookup_truth(t, os.path.join(shoot, "a3.ARW")), (2, False))
    check("lookup_truth: bare name matches a path", E.lookup_truth(t, os.path.join(shoot, "a1.JPG")), (5, False))

    snap = os.path.join(tmp, "snap.csv")
    check("write_snapshot: rated photos only", E.write_snapshot(files, snap), 5)
    check("write_snapshot: reads back the same truth", E.read_truth_csv(snap), {E.shot_key(k[0] + os.sep + k[1]): v for k, v in truth.items()})

    # end to end through the CLI, with @list.txt
    listing = os.path.join(tmp, "list.txt")
    touch(listing, shoot + "\n")
    out = os.path.join(tmp, "eval.txt")
    run = subprocess.run([sys.executable, E.__file__, "@" + listing, "--report", report, "--sharp-mode", "subject_focus", "--out", out],
                         capture_output=True, text=True)
    check("cli: exit 0", run.returncode, 0)
    check("cli: prints the summary", run.stdout.strip(), text)
    with open(out, encoding="utf-8") as f:
        check("cli: --out holds the same text", f.read(), text + "\n")
    run = subprocess.run([sys.executable, E.__file__, shoot, "--report", os.path.join(tmp, "missing.csv")], capture_output=True, text=True)
    check("cli: missing report exits 1 with a hint", (run.returncode, "--report" in run.stderr), (1, True))

    # --suggest: replay the report through rating.rate_burst under other settings ----------
    import json
    from rating import TIER_THRESHOLDS, rate_burst, star_tier

    s = E.settings_of({"rank_mode": "universal", "keep_mode": "single_best", "keep_margin": "off", "spread_keepers": "off", "non_keeper": "leave", "star_scale": "1"})
    check("settings_of: margin off is 0, scale is a float", (s.keep_margin, s.star_scale, s.nk_mode), (0.0, 1.0, "leave"))
    check("settings_of: margin 90 is 0.9", E.settings_of({**vars(s), "non_keeper": "graded", "keep_margin": "90", "star_scale": "1.25"}).keep_margin, 0.9)

    whole = E.read_report(report, "subject_focus", suggest=True)
    check("read_report --suggest: score, flags, of, eligible", (whole[0]["score"], whole[0]["flags"], whole[0]["of"], whole[0]["eligible"]), (900.0, (), 3, True))
    rated = {f["path"]: f for f in E.replay(whole, s, "subject_focus")}
    a1, a2, a3, b1 = (os.path.join(shoot, n) for n in ("a1.JPG", "a2.jpg", "a3.ARW", "b1.jpg"))
    check("replay: single_best keeps one per burst", [rated[p]["keeper"] for p in (a1, a2, a3, b1)], [True, False, False, True])
    check("replay: leave non-keepers", (rated[a2]["stars"], rated[a3]["stars"]), (None, None))
    check("replay: keeper stars from the universal tiers", rated[a1]["stars"], star_tier(900, TIER_THRESHOLDS))
    direct = rate_burst({a1: 900.0, a2: 700.0, a3: 200.0}, {a1: (), a2: (), a3: ()}, 3, s, {a1, a2, a3}, None, "subject_peak")[2]
    check("replay: same stars as rate_burst on the burst", {p: rated[p]["stars"] for p in (a1,)}, {a1: direct[a1]})
    margin = E.settings_of({**vars(s), "non_keeper": "graded", "keep_margin": "75", "star_scale": "1"})
    rated = {f["path"]: f for f in E.replay(whole, margin, "subject_focus")}
    check("replay: a margin keeps a2 as well and grades a3", (rated[a2]["keeper"], rated[a3]["keeper"], rated[a3]["stars"] is not None), (True, False, True))

    ranked = E.suggest([(whole, truth)], "subject_focus", 1, 3)
    check("suggest: top 3", len(ranked), 3)
    check("suggest: every choice names every panel setting", [sorted(c) for c, _ in ranked], [sorted(E.SUGGEST_GRID)] * 3)
    check("suggest: best first", [(c["hits"] / c["picks"] - c["false"] / c["kept"]) if c["kept"] else 0 for _, c in ranked] ==
          sorted([(c["hits"] / c["picks"] - c["false"] / c["kept"]) if c["kept"] else 0 for _, c in ranked], reverse=True), True)
    check("suggest: scores the hand-rated frames only", ranked[0][1]["frames"], 5)
    preset = json.loads(E.preset_json(ranked[0][0], "subject_focus"))
    check("preset_json: a custom preset with the run's sharpness mode", (preset["genre"], preset["sharp_mode"], sorted(preset)),
          ("custom", "subject_focus", ["genre", "keep_margin", "keep_mode", "non_keeper", "rank_mode", "sharp_mode", "star_scale"]))
    text = E.render_suggestions(ranked, 1, 5, "subject_focus", 1)
    check("render_suggestions: one shoot warns", "one shoot only" in text, True)
    check("render_suggestions: two shoots do not", "one shoot only" in E.render_suggestions(ranked, 2, 10, "subject_focus", 1), False)
    check("render_suggestions: numbered with the preset", ("\n1. rank_mode" in text, '"genre": "custom"' in text), (True, True))

    run = subprocess.run([sys.executable, E.__file__, shoot, "--report", report, "--suggest"], capture_output=True, text=True)
    check("cli: --suggest needs --sharp-mode", (run.returncode, "--sharp-mode" in run.stderr), (1, True))
    preset_file = os.path.join(tmp, "mine.json")
    run = subprocess.run([sys.executable, E.__file__, shoot, "--report", report, "--sharp-mode", "subject_focus", "--suggest", "--top", "2",
                          "--shoot", report, snap, "--write-preset", preset_file], capture_output=True, text=True)
    check("cli: --suggest with a second --shoot", (run.returncode, run.stdout.startswith("suggest: 2 shoots, 10 frames")), (0, True))
    with open(preset_file, encoding="utf-8") as f:
        check("cli: --write-preset writes the first suggestion", json.load(f)["genre"], "custom")
    run = subprocess.run([sys.executable, E.__file__, "--suggest", "--sharp-mode", "subject_focus", "--shoot", report, snap, "--write-preset", preset_file],
                         capture_output=True, text=True)
    check("cli: --shoot alone works and an existing preset file is refused", (run.returncode, "exists" in run.stderr), (1, True))

    # score parts and --set ------------------------------------------------------
    parted = E.frame_of({"burst": "P", "file": "x.jpg", "id": "7", "subject": "80.5", "motion": "pan", "straightness": "0.25"}, "motion_aware")
    check("frame_of: score parts", (parted["id"], parted["subject"], parted["cls"], parted["straight"]), (7, 80.5, "pan", 0.25))
    bare = E.frame_of({"burst": "P", "file": "x.jpg"}, "motion_aware")
    check("frame_of: no parts in an older report", (bare["id"], bare["subject"], bare["cls"], bare["straight"]), (None, None, "", 0.0))

    check("lift_blur: a motion-blur frame rises to the burst's median", E.lift_blur({"a": 10.0, "b": 30.0, "c": 5.0},
          {"a": ("ordinary", 0.0), "b": ("pan", 0.0), "c": ("motion_blur", 0.0)}, 500.0), {"a": 10.0, "b": 30.0, "c": 20.0})
    check("lift_blur: an all-blur burst scores by straightness", E.lift_blur({"a": 1.0}, {"a": ("motion_blur", 0.1)}, 500.0), {"a": 50.0})

    def part(name, rank, subject, cls, score, burst="P"):
        return {"path": name, "burst": burst, "rank": rank, "subject": subject, "cls": cls, "straight": 0.0, "score": score}

    live = [part("p1", 1, 80.0, "pan", 92.0), part("p2", 2, 90.0, "ordinary", 90.0), part("p3", 3, 100.0, "missed_pan", 70.0),
            {**part("q1", 1, None, "", 500.0, "Q")}]
    check("rescore: today's constants rebuild the live scores", [f["score"] for f in E.rescore(live, E.PART_DEFAULTS)], [92.0, 90.0, 70.0, 500.0])
    flat = E.rescore(live, {**E.PART_DEFAULTS, "PAN_BONUS": 1.0})
    check("rescore: PAN_BONUS 1.0 drops the pan below p2; no parts keeps its score", [f["score"] for f in flat], [80.0, 90.0, 70.0, 500.0])
    own = [{**live[0], "subject_own": 60.0}] + live[1:]
    check("rescore: SAME_SCALE 0 uses the own-size subject where there is one",
          [f["score"] for f in E.rescore(own, {**E.PART_DEFAULTS, "SAME_SCALE": 0.0})], [69.0, 90.0, 70.0, 500.0])
    check("rescore: SAME_SCALE 1 keeps the shared-size subject", E.rescore(own, E.PART_DEFAULTS)[0]["score"], 92.0)
    check("frame_of: own-size subject", E.frame_of({"burst": "P", "file": "x.jpg", "subject_own": "60.25"}, "motion_aware")["subject_own"], 60.25)
    check("parts_agreement: bursts with parts only", E.parts_agreement(live), (1, 1))
    check("parts_agreement: a score out of step disagrees", E.parts_agreement([{**live[0], "subject": 70.0}] + live[1:]), (0, 1))

    kept = [{**f, "keeper": f["path"] in ("p1", "q1")} for f in live]
    check("keeper_agreement: same keepers", E.keeper_agreement(kept, kept), (2, 2))
    check("keeper_agreement: one burst differs", E.keeper_agreement(kept, [{**f, "keeper": f["path"] in ("p2", "q1")} for f in live]), (1, 2))

    check("parse_sets: numbers by name", E.parse_sets(["PAN_BONUS=1.1", "CLOSE_CALL_SHARE=0.5"]), {"PAN_BONUS": 1.1, "CLOSE_CALL_SHARE": 0.5})
    for bad in ("BLUR_STRAIGHT_SCALE=400", "PAN_BONUS=high", "PAN_BONUS"):
        try:
            E.parse_sets([bad])
            check(f"parse_sets: {bad} exits", "no exit", "exit")
        except SystemExit:
            check(f"parse_sets: {bad} exits", "exit", "exit")

    parts_dir = os.path.join(tmp, "parts")
    os.mkdir(parts_dir)
    for name, stars in (("p1.jpg", 3), ("p2.jpg", 5), ("p3.jpg", 1)):
        touch(os.path.join(parts_dir, name))
        touch(os.path.join(parts_dir, name + ".xmp"), xmp(stars))
    parts_report = os.path.join(tmp, "parts.csv")
    touch(parts_report, "\n".join([
        "burst,file,rank,of,score,stars,keeper,flags,tags,why,folder,reason,direction,id,subject,motion,straightness,crop",
        f"P,p1.jpg,1,3,92.0,4,yes,,Technique|Panning,kept,{parts_dir},Keeper,,11,80.0,pan,0.0,640x400",
        f"P,p2.jpg,2,3,90.0,leave,no,,Why|Outranked,not kept,{parts_dir},Outranked,,12,90.0,ordinary,0.0,640x400",
        f"P,p3.jpg,3,3,70.0,leave,no,,Technique|Missed Pan,not kept,{parts_dir},Outranked,,13,100.0,missed_pan,0.0,640x400",
    ]) + "\n")
    run = subprocess.run([sys.executable, E.__file__, parts_dir, "--report", parts_report, "--sharp-mode", "motion_aware",
                          "--non-keeper", "leave", "--pick-stars", "4"], capture_output=True, text=True)
    check("cli: parts note without --set", (run.returncode, run.stdout.startswith("score parts rebuild the live ranking in 1/1 bursts\n")), (0, True))
    check("cli: per burst ranking printed", "mean top-1 agreement 0.0%" in run.stdout, True)   # p1 ranks first, p2 is the 5-star
    run = subprocess.run([sys.executable, E.__file__, parts_dir, "--report", parts_report, "--sharp-mode", "motion_aware",
                          "--non-keeper", "leave", "--pick-stars", "4", "--set", "PAN_BONUS=1.0"], capture_output=True, text=True)
    check("cli: --set replays with the live keepers first", (run.returncode, "keeps the live run's frames in 1/1 bursts" in run.stdout), (0, True))
    check("cli: --set PAN_BONUS lifts p2 to top-1", ("set: PAN_BONUS=1.0" in run.stdout, "mean top-1 agreement 100.0%" in run.stdout), (True, True))
    run = subprocess.run([sys.executable, E.__file__, shoot, "--report", report, "--sharp-mode", "subject_focus", "--set", "PAN_BONUS=1.1"],
                         capture_output=True, text=True)
    check("cli: --set of a part needs a report with parts", (run.returncode, "no score parts" in run.stderr), (1, True))
    run = subprocess.run([sys.executable, E.__file__, shoot, "--report", report, "--set", "CLOSE_CALL_SHARE=0.5"], capture_output=True, text=True)
    check("cli: --set needs --sharp-mode", (run.returncode, "--sharp-mode" in run.stderr), (1, True))

print(f"\n{'all ok' if failures == 0 else f'{failures} failed'}")
sys.exit(1 if failures else 0)
