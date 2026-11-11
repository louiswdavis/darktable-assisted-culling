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

print(f"\n{'all ok' if failures == 0 else f'{failures} failed'}")
sys.exit(1 if failures else 0)
