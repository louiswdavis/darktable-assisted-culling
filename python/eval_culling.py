"""Scores a culling run against your own stars and rejects, so tuning uses numbers, not guesses.
Run from the repo root:

  python python/eval_culling.py PHOTOS...                       # truth from the .xmp sidecars beside the photos
  python python/eval_culling.py @rally-photos.txt --report PATH  # one path per line; last-run.csv from PATH
  python python/eval_culling.py PHOTOS... --snapshot truth.csv   # save the hand ratings BEFORE culling writes its own
  python python/eval_culling.py PHOTOS... --truth truth.csv      # score the run against that snapshot
  python python/eval_culling.py PHOTOS... --truth truth.csv --sharp-mode motion_aware --suggest
                                                                 # try other settings on the same scores

PHOTOS are files, folders of photos, or @list.txt. The truth is your stars (0-5) and reject
flag per photo, read from darktable's .xmp sidecars (xmp:Rating, -1 = rejected) or from a
truth CSV (columns file, stars, rejected). Culling writes its own stars into the same sidecars,
so take the snapshot before the run, or the plugin's ratings leak into the truth. The report
is culling's last-run.csv (see README, "What you get"); only its rows for the given photos
count. No darktable, numpy or cv2 needed.

A pick is a photo you rated --pick-stars or more and did not reject. Per group and overall:
hit rate (picks the plugin kept), false keepers (plugin keepers that are not picks) and the
Spearman rank correlation between your stars (rejected = -1) and the plugin's; frames the run
left unrated are excluded from the correlation and counted. The sharpness-mode and
motion-class summaries use the report's Technique tags; --sharp-mode names the run's mode.

--suggest replays the run's scores through every combination of ranking mode, keepers,
keeper margin, star strictness and non-keepers (SUGGEST_GRID, the panel's own choices) with
the same rules the plugin applies (rating.py), and prints the best few against the truth,
each as JSON to paste into a preset file. Nothing is changed. One shoot overfits: add
others with --shoot REPORT TRUTH (a saved last-run.csv and its --snapshot), all run in the
same --sharp-mode, which --suggest needs to know."""

import argparse
import csv
import itertools
import json
import os
import re
import sys
from argparse import Namespace

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import RAW_EXTENSIONS
from rating import rate_burst, relative_references

# --suggest tries every combination; the values are the panel's choices (assisted_culling.lua
# PRESET_SCHEMA), in panel order so the plugin's defaults come first among equals.
SUGGEST_GRID = {
    "rank_mode": ["universal", "binary", "relative"],
    "keep_mode": ["single_best", "portrait_mode", "dynamic_burst", "keep_all"],
    "keep_margin": ["off", "95", "90", "85", "80", "75"],
    "non_keeper": ["leave", "graded"],
    "star_scale": ["1", "0.5", "0.75", "1.25", "1.5", "2"],
}
SUGGEST_COLUMNS = ("score", "flags", "of")  # the report columns a replay needs on top of REPORT_COLUMNS

IMAGE_EXT = RAW_EXTENSIONS | {".jpg", ".jpeg", ".png", ".tif", ".tiff"}
JPEG_EXT = {".jpg", ".jpeg"}
DEFAULT_REPORT = os.path.join(
    os.environ.get("LOCALAPPDATA", os.path.expanduser("~/.config")) if os.name == "nt" else os.path.expanduser("~/.config"),
    "darktable", "assisted_culling", "last-run.csv")
REPORT_COLUMNS = ("burst", "file", "stars", "keeper", "tags", "folder")
# Mirrors MOTION_TAGS in score_images.py (checked by test_score_images.py), tag -> class.
MOTION_CLASS = {"Technique|Panning": "pan", "Technique|Motion Blur": "motion_blur",
                "Technique|Missed Pan": "missed_pan"}
# burst_sharp_mode switches these modes per burst and technique_tag marks the switch.
MODE_SWITCH = {("subject_focus", "Technique|Panning"): "subject_peak",
               ("tiles_uniformity", "Technique|Shallow DoF"): "subject_focus"}
RATING_RE = re.compile(r'xmp:Rating\s*=\s*"(-?\d+)"|<xmp:Rating>\s*(-?\d+)\s*</xmp:Rating>')
TRUE_WORDS = {"1", "yes", "true", "y", "-1"}


def shot_key(path: str) -> tuple:
    """A RAW+JPEG pair and its sidecars share one key: the folder and the lower-cased stem."""
    folder, name = os.path.split(os.path.abspath(path))
    return os.path.normcase(folder), os.path.splitext(name)[0].lower()


def photos(paths: list) -> list:
    """Files as given, plus each folder's images, sorted; a RAW with a same-name JPEG beside it
    is skipped, as the report has one row per pair, under the JPEG."""
    out = []
    for p in paths:
        if not os.path.isdir(p):
            out.append(p)
            continue
        files = [f for f in os.listdir(p) if os.path.splitext(f)[1].lower() in IMAGE_EXT]
        jpeg_stems = {os.path.splitext(f)[0].lower() for f in files if os.path.splitext(f)[1].lower() in JPEG_EXT}
        out += sorted(os.path.join(p, f) for f in files
                      if os.path.splitext(f)[1].lower() in JPEG_EXT or os.path.splitext(f)[0].lower() not in jpeg_stems)
    return out


def parse_rating(text: str):
    """(stars, rejected) from sidecar text, or None when it holds no xmp:Rating."""
    m = RATING_RE.search(text)
    if not m:
        return None
    value = int(m.group(1) or m.group(2))
    return (0, True) if value < 0 else (min(value, 5), False)


def sidecar_rating(path: str):
    """The rating of the photo's darktable sidecar (`photo.ext.xmp`), else of any sidecar with
    the same stem in its folder (the paired RAW's), else None."""
    candidates = [path + ".xmp"]
    folder, stem = os.path.dirname(path) or ".", os.path.splitext(os.path.basename(path))[0].lower()
    if os.path.isdir(folder):
        candidates += sorted(os.path.join(folder, f) for f in os.listdir(folder)
                             if f.lower().endswith(".xmp") and os.path.splitext(os.path.splitext(f)[0])[0].lower() == stem)
    for xmp in candidates:
        if os.path.isfile(xmp):
            with open(xmp, encoding="utf-8", errors="replace") as f:
                rating = parse_rating(f.read())
            if rating is not None:
                return rating
    return None


def sidecar_truth(files: list) -> dict:
    """shot_key -> (stars, rejected) for every photo with a rated sidecar."""
    truth = {}
    for path in files:
        rating = sidecar_rating(path)
        if rating is not None:
            truth[shot_key(path)] = rating
    return truth


def read_truth_csv(path: str) -> dict:
    """shot_key -> (stars, rejected) from a CSV with file (path or name), stars|rating and
    rejected|reject columns. A bare file name keys on ("", stem) and matches any folder."""
    truth = {}
    with open(path, newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        cols = {c.strip().lower(): c for c in reader.fieldnames or []}
        file_col = next((cols[c] for c in ("file", "path", "filename", "filepath") if c in cols), None)
        stars_col = next((cols[c] for c in ("stars", "rating") if c in cols), None)
        reject_col = next((cols[c] for c in ("rejected", "reject") if c in cols), None)
        if not file_col or not stars_col:
            sys.exit(f"{path}: needs a file column and a stars (or rating) column; has {reader.fieldnames}")
        for row in reader:
            name = (row[file_col] or "").strip()
            if not name:
                continue
            stars = int(float(row[stars_col] or 0))
            rejected = stars < 0 or (bool(reject_col) and (row[reject_col] or "").strip().lower() in TRUE_WORDS)
            key = shot_key(name) if os.path.dirname(name) else ("", os.path.splitext(name)[0].lower())
            truth[key] = (0 if rejected else min(stars, 5), rejected)
    return truth


def lookup_truth(truth: dict, path: str):
    key = shot_key(path)
    return truth.get(key, truth.get(("", key[1])))


def write_snapshot(files: list, out: str) -> int:
    """Writes file,stars,rejected for every photo with a rated sidecar; returns the count."""
    rows = [(path, *rating) for path in files for rating in [sidecar_rating(path)] if rating is not None]
    with open(out, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["file", "stars", "rejected"])
        for path, stars, rejected in rows:
            w.writerow([os.path.abspath(path), stars, "yes" if rejected else "no"])
    return len(rows)


def frame_of(row: dict, sharp_mode: str) -> dict:
    """One report row as the eval sees it: plugin stars (None when the run left the frame
    alone), keeper, motion class and the burst's sharpness mode."""
    tags = [t for t in (row.get("tags") or "").split(";") if t]
    stars = (row.get("stars") or "").strip()
    mode = sharp_mode
    for tag in tags:
        mode = MODE_SWITCH.get((sharp_mode, tag), mode)
    reason = (row.get("reason") or "").strip() or next((t[4:] for t in tags if t.startswith("Why|")), "")
    frame = {"path": os.path.join(row.get("folder") or "", row["file"]), "burst": row["burst"],
             "stars": None if stars in ("", "leave") else int(float(stars)),
             "keeper": (row.get("keeper") or "").strip().lower() == "yes",
             "motion": next((MOTION_CLASS[t] for t in tags if t in MOTION_CLASS), "ordinary"), "mode": mode}
    if "score" in row:  # what a --suggest replay needs
        frame.update({"score": float(row["score"] or 0.0),
                      "flags": tuple(f for f in (row.get("flags") or "").split(";") if f),
                      "of": int(row.get("of") or 0), "eligible": reason != "Not shortlisted",
                      "masked": "Scored|Masked" in tags})
    return frame


def read_report(path: str, sharp_mode: str, suggest: bool = False) -> list:
    with open(path, newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        missing = [c for c in REPORT_COLUMNS + (SUGGEST_COLUMNS if suggest else ())
                   if c not in (reader.fieldnames or [])]
        if missing:
            sys.exit(f"{path} lacks the columns {missing}: pass culling's last-run.csv")
        return [frame_of(row, sharp_mode) for row in reader if row.get("file")]


def settings_of(choice: dict) -> Namespace:
    """A grid choice (panel strings) as the scorer's arguments, as assisted_culling.lua passes them."""
    return Namespace(rank_mode=choice["rank_mode"], keep_mode=choice["keep_mode"], nk_mode=choice["non_keeper"],
                     keep_margin=0.0 if choice["keep_margin"] == "off" else int(choice["keep_margin"]) / 100,
                     star_scale=float(choice["star_scale"]))


def replay(frames: list, settings, sharp_mode: str) -> list:
    """The report's frames rated again under settings, by rating.rate_burst: same scores,
    same bursts, same shortlist, other keepers and stars. frames must be a whole run's rows
    (the relative reference spans the run). Tag-only flags are not in the report, so every
    flag counts; a burst's unreadable frames are not either, so `of` is its size. A burst
    is scored in one mode: the one EXIF switched it to when any of its frames says so."""
    bursts = {}
    for f in frames:
        bursts.setdefault(f["burst"], []).append(f)
    mode_of = {b: next((f["mode"] for f in fs if f["mode"] != sharp_mode), sharp_mode) for b, fs in bursts.items()}
    groups = {}
    for burst, burst_frames in bursts.items():
        for f in burst_frames:
            if f["eligible"]:
                groups.setdefault((mode_of[burst], f["masked"]), []).append(f["score"])
    references = relative_references(groups) if settings.rank_mode == "relative" else {}
    out = []
    for burst, burst_frames in bursts.items():
        first = burst_frames[0]
        _members, keepers, stars_of, _reasons = rate_burst(
            {f["path"]: f["score"] for f in burst_frames}, {f["path"]: f["flags"] for f in burst_frames},
            first["of"] or len(burst_frames), settings, {f["path"] for f in burst_frames if f["eligible"]},
            references.get((mode_of[burst], first["masked"])), mode_of[burst])
        kept = set(keepers)
        for f in burst_frames:
            stars = stars_of[f["path"]]
            out.append({**f, "stars": None if stars == "leave" else stars, "keeper": f["path"] in kept})
    return out


def suggest(shoots: list, sharp_mode: str, pick_stars: int, top: int) -> list:
    """shoots are (report frames of a whole run, truth) pairs. Every SUGGEST_GRID choice is
    replayed on each shoot and scored on the frames with a hand rating, pooled; the list is
    best first by hit rate minus false-keeper rate, then Spearman, and two choices with the
    same outcome keep the earlier (the panel's default) one."""
    outcomes = {}
    for values in itertools.product(*SUGGEST_GRID.values()):
        choice = dict(zip(SUGGEST_GRID, values))
        settings = settings_of(choice)
        pooled = []
        for frames, truth in shoots:
            rated = {f["path"]: f for f in replay(frames, settings, sharp_mode)}
            for f in frames:
                rating = lookup_truth(truth, f["path"])
                if rating is not None:
                    stars, rejected = rating
                    pooled.append({**rated[f["path"]], "truth": -1 if rejected else stars,
                                   "pick": not rejected and stars >= pick_stars})
        s = summarise(pooled)
        key = (s["hits"], s["picks"], s["false"], s["kept"], None if s["spearman"] is None else round(s["spearman"], 6))
        if key not in outcomes:
            outcomes[key] = (choice, s)

    def goodness(item):
        s = item[1]
        hit = s["hits"] / s["picks"] if s["picks"] else 0.0
        false = s["false"] / s["kept"] if s["kept"] else 0.0
        return (hit - false, -2.0 if s["spearman"] is None else s["spearman"])

    return sorted(outcomes.values(), key=goodness, reverse=True)[:top]


def preset_json(choice: dict, sharp_mode: str) -> str:
    """The choice as a preset file's keys (assisted_culling/presets/<name>.json); the ones not
    listed take their defaults when the plugin loads it."""
    return json.dumps({"genre": "custom", "rank_mode": choice["rank_mode"], "sharp_mode": sharp_mode,
                       "keep_mode": choice["keep_mode"], "keep_margin": choice["keep_margin"],
                       "non_keeper": choice["non_keeper"], "star_scale": choice["star_scale"]}, indent=2)


def render_suggestions(ranked: list, shoots: int, frames: int, sharp_mode: str, pick_stars: int) -> str:
    lines = [f"suggest: {shoots} shoot{'s' if shoots != 1 else ''}, {frames} frames rated by hand, "
             f"a pick is {pick_stars}+ stars and not rejected, sharpness mode {sharp_mode}"]
    if shoots < 2:
        lines.append("one shoot only: these fit that shoot, not your taste; add another with --shoot REPORT TRUTH")
    for n, (choice, s) in enumerate(ranked, 1):
        lines += ["", f"{n}. " + ", ".join(f"{k} {v}" for k, v in choice.items()), f"   {line_of('   result', s).strip()}",
                  "   " + preset_json(choice, sharp_mode).replace("\n", "\n   ")]
    return "\n".join(lines)


def ranks(values: list) -> list:
    """Average ranks, 1-based, ties sharing their mean rank."""
    order = sorted(range(len(values)), key=lambda i: values[i])
    out = [0.0] * len(values)
    i = 0
    while i < len(order):
        j = i
        while j + 1 < len(order) and values[order[j + 1]] == values[order[i]]:
            j += 1
        for k in range(i, j + 1):
            out[order[k]] = (i + j) / 2 + 1
        i = j + 1
    return out


def spearman(xs: list, ys: list):
    """Spearman's rho via Pearson on average ranks; None under 3 pairs or when either side is constant."""
    if len(xs) < 3 or len(set(xs)) < 2 or len(set(ys)) < 2:
        return None
    rx, ry = ranks(xs), ranks(ys)
    mx, my = sum(rx) / len(rx), sum(ry) / len(ry)
    cov = sum((a - mx) * (b - my) for a, b in zip(rx, ry))
    vx = sum((a - mx) ** 2 for a in rx) ** 0.5
    vy = sum((b - my) ** 2 for b in ry) ** 0.5
    return cov / (vx * vy)


def summarise(frames: list) -> dict:
    """Counts and Spearman over frames that carry both a truth and a plugin rating."""
    picks = [f for f in frames if f["pick"]]
    kept = [f for f in frames if f["keeper"]]
    rated = [f for f in frames if f["stars"] is not None]
    return {"frames": len(frames), "picks": len(picks), "kept": len(kept),
            "hits": sum(1 for f in picks if f["keeper"]), "false": sum(1 for f in kept if not f["pick"]),
            "rated": len(rated), "unrated": len(frames) - len(rated),
            "spearman": spearman([f["truth"] for f in rated], [f["stars"] for f in rated])}


def evaluate(report: list, truth: dict, pick_stars: int) -> dict:
    """Joins the report to the truth; frames with no hand rating are dropped and counted."""
    frames, unrated_by_hand = [], 0
    for f in report:
        rating = lookup_truth(truth, f["path"])
        if rating is None:
            unrated_by_hand += 1
            continue
        stars, rejected = rating
        frames.append({**f, "truth": -1 if rejected else stars, "rejected": rejected,
                       "pick": not rejected and stars >= pick_stars})

    def by(key):
        groups = {}
        for f in frames:
            groups.setdefault(f[key], []).append(f)
        return {k: summarise(v) for k, v in sorted(groups.items())}

    return {"overall": summarise(frames), "no_truth": unrated_by_hand,
            "truth_rejected": sum(1 for f in frames if f["rejected"]),
            "by_burst": by("burst"), "by_mode": by("mode"), "by_motion": by("motion")}


def pct(n: int, d: int) -> str:
    return f"{100 * n / d:.1f}%" if d else "n/a"


def rho(value) -> str:
    return "n/a" if value is None else f"{value:+.2f}"


def line_of(label: str, s: dict) -> str:
    return (f"{label}: {s['frames']} frames, picks {s['picks']}, kept {s['kept']}, hit rate {pct(s['hits'], s['picks'])}, "
            f"false keepers {s['false']} of {s['kept']} ({pct(s['false'], s['kept'])}), "
            f"Spearman {rho(s['spearman'])} (n={s['rated']}" + (f", {s['unrated']} left unrated)" if s["unrated"] else ")"))


def render(result: dict, pick_stars: int) -> str:
    o = result["overall"]
    lines = [f"truth: {o['frames']} frames rated by hand ({result['truth_rejected']} rejected); "
             f"a pick is {pick_stars}+ stars and not rejected: {o['picks']} picks",
             f"report: {o['frames']} rows matched a hand rating, {result['no_truth']} had none",
             line_of("overall", o), "", "per sharpness mode"]
    lines += [f"  {line_of(k, s)}" for k, s in result["by_mode"].items()]
    lines += ["", "per motion class"]
    lines += [f"  {line_of(k, s)}" for k, s in result["by_motion"].items()]
    lines += ["", "per group", f"  {'burst':<14}{'frames':>7}{'picks':>7}{'hits':>6}{'false':>7}{'spearman':>10}"]
    lines += [f"  {k:<14}{s['frames']:>7}{s['picks']:>7}{s['hits']:>6}{s['false']:>7}{rho(s['spearman']):>10}"
              for k, s in result["by_burst"].items()]
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0], fromfile_prefix_chars="@")
    ap.add_argument("paths", nargs="*", help="photos, or folders of photos; @list.txt reads one path per line")
    ap.add_argument("--report", default=DEFAULT_REPORT, help="culling's last-run.csv (default: darktable's config folder)")
    ap.add_argument("--truth", help="a truth CSV (file, stars, rejected) instead of the .xmp sidecars")
    ap.add_argument("--snapshot", help="write the sidecar ratings to this CSV and stop; run it before culling")
    ap.add_argument("--pick-stars", type=int, default=1, help="stars a hand rating needs to count as a pick (default 1)")
    ap.add_argument("--sharp-mode", default="run", help="the run's sharpness mode, to name it in the per-mode summary")
    ap.add_argument("--out", help="also write the summary to this file")
    ap.add_argument("--suggest", action="store_true",
                    help="replay the run under other settings and print the best few (needs --sharp-mode)")
    ap.add_argument("--shoot", nargs=2, action="append", default=[], metavar=("REPORT", "TRUTH"),
                    help="another shoot for --suggest: its saved last-run.csv and --snapshot CSV; repeatable")
    ap.add_argument("--top", type=int, default=5, help="how many suggestions to print (default 5)")
    ap.add_argument("--write-preset", metavar="FILE",
                    help="write the best suggestion as a preset file (a new file; the plugin reads presets on Reload)")
    a = ap.parse_args()
    if a.suggest and a.sharp_mode == "run":
        sys.exit("--suggest needs the run's sharpness mode: pass --sharp-mode (the panel's sharpness choice)")
    if not a.paths and not (a.suggest and a.shoot):
        sys.exit("give photos, folders or @list.txt")
    shoots = []
    files = photos(a.paths) if a.paths else []
    if a.paths:
        if not files:
            sys.exit("no photos under the given paths")
        if a.snapshot:
            n = write_snapshot(files, a.snapshot)
            print(f"{n} of {len(files)} photos had a rated sidecar; written to {a.snapshot}")
            return
        if a.truth:
            truth = read_truth_csv(a.truth)
        else:
            truth = sidecar_truth(files)
            if not truth:
                sys.exit("no rated .xmp sidecar beside any of the photos; pass --truth CSV or rate them in darktable first")
        if not os.path.isfile(a.report):
            sys.exit(f"report not found: {a.report}; pass --report PATH to last-run.csv")
        wanted = {shot_key(p) for p in files}
        whole = read_report(a.report, a.sharp_mode, a.suggest)
        report = [f for f in whole if shot_key(f["path"]) in wanted]
        if not report:
            sys.exit(f"{a.report} has no row for the given photos; was the last run on them?")
        shoots.append((whole, {k: v for k, v in truth.items() if any(lookup_truth({k: v}, f["path"]) for f in report)}))
    for path, truth_path in a.shoot:
        for p in (path, truth_path):
            if not os.path.isfile(p):
                sys.exit(f"--shoot file not found: {p}")
        shoots.append((read_report(path, a.sharp_mode, True), read_truth_csv(truth_path)))
    if a.suggest:
        rated = sum(1 for frames, truth in shoots for f in frames if lookup_truth(truth, f["path"]) is not None)
        if not rated:
            sys.exit("no report row has a hand rating; check the truth and the report belong to the same photos")
        ranked = suggest(shoots, a.sharp_mode, a.pick_stars, a.top)
        text = render_suggestions(ranked, len(shoots), rated, a.sharp_mode, a.pick_stars)
        if a.write_preset:
            if os.path.exists(a.write_preset):
                sys.exit(f"{a.write_preset} exists; pick a new file name")
            with open(a.write_preset, "w", encoding="utf-8") as f:
                f.write(preset_json(ranked[0][0], a.sharp_mode) + "\n")
            text += f"\n\nwritten the first as {a.write_preset}"
    else:
        text = render(evaluate(report, truth, a.pick_stars), a.pick_stars)
    print(text)
    if a.out:
        with open(a.out, "w", encoding="utf-8") as f:
            f.write(text + "\n")


if __name__ == "__main__":
    main()
