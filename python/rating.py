"""Turns a burst's sharpness scores into keepers and stars. Pure Python, no numpy or
cv2, so score_images.py applies it during a run and eval_culling.py replays it on a
finished run's last-run.csv to try other settings (--suggest). The two must agree
exactly: that is why the tables and rules live here and nowhere else."""

STAR_THRESHOLDS = [(95, 5), (85, 4), (75, 3), (60, 2), (45, 1), (0, 0)]
RELATIVE_REFERENCE_PERCENTILE = 95
# a relative group with fewer keeper-eligible frames than this has no reference worth
# "5 stars"; its bursts use the universal tiers of their mode instead (logged)
RELATIVE_MIN_FRAMES = 5
# graded non-keepers: (share of the burst's best score, stars below the burst's lowest keeper);
# a frame under the last share gets 0 stars
GRADED_STEPS = [(0.90, 1), (0.75, 2), (0.60, 3), (0.45, 4)]

# universal tiers for the Laplacian-variance modes (subject_focus, subject_peak, center,
# face_detect, sam_subject); modes on another scale have their own table in
# TIER_THRESHOLDS_BY_MODE
TIER_THRESHOLDS = [
    (2700, 5),
    (2200, 4),
    (1600, 3),
    (1200, 2),
    (750, 1),
    (0, 0),
]
# peak is the 99th percentile of |Laplacian| on 8-bit grey (a magnitude, not a variance)
# and tiles_uniformity averages the weakest third of the patches, so both sit far below
# TIER_THRESHOLDS. First guesses, not measured: replace them with the percentiles of the
# `score` column of a real run's last-run.csv (eval_culling.py gives the hit rate).
PEAK_TIER_THRESHOLDS = [(120, 5), (90, 4), (60, 3), (40, 2), (20, 1), (0, 0)]
UNIFORMITY_TIER_THRESHOLDS = [(1200, 5), (900, 4), (650, 3), (450, 2), (250, 1), (0, 0)]
MOTION_TIER_THRESHOLDS = [(500, 5), (400, 4), (300, 3), (200, 2), (120, 1)]
# sharp mode → its universal tier table; a mode not listed is on the variance scale
TIER_THRESHOLDS_BY_MODE = {
    "peak": PEAK_TIER_THRESHOLDS,
    "tiles_uniformity": UNIFORMITY_TIER_THRESHOLDS,
    "motion_aware": MOTION_TIER_THRESHOLDS,
}

# Per-frame problem flags → (points off the binary-mode score, stars off in
# universal and relative mode). A frame pays for every flag it carries. Binary-mode
# keepers start at 100, so 15 points is one star (STAR_THRESHOLDS) and 30 is three.
# The results CSV lists a frame's flags in column 3; assisted_culling.lua maps each to a tag.
FLAG_PENALTIES = {
    "overexposed": (30, 1),
    "underexposed": (30, 1),
    "eyes_closed": (15, 1),
}


def tier_table(sharp_mode: str) -> list:
    """The universal star tiers for a burst scored in sharp_mode (the burst's own
    mode when EXIF switched it, see score_images.burst_sharp_mode)."""
    return TIER_THRESHOLDS_BY_MODE.get(sharp_mode, TIER_THRESHOLDS)


def keepers_allowed(keep_mode: str, burst_size: int) -> int:
    if keep_mode == "dynamic_burst":
        return 1 if burst_size <= 4 else (2 if burst_size <= 8 else (3 if burst_size <= 12 else (4 if burst_size <= 18 else 5)))
    if keep_mode == "portrait_mode":
        return 1 if burst_size <= 3 else 2
    if keep_mode == "single_best":
        return 1
    return burst_size


def penalised_flags(burst_flags: dict, tag_only=frozenset()) -> dict:
    """id → the flags that cost that frame stars. Tag-only flags never do, nor
    does a flag every frame of a multi-frame burst shares: a burst that's all
    dark or all eyes-closed was most likely shot that way on purpose."""
    shared = set.intersection(*map(set, burst_flags.values())) if len(burst_flags) > 1 else set()
    exempt = shared | set(tag_only)
    return {i: tuple(f for f in flags if f not in exempt) for i, flags in burst_flags.items()}


def percentile(values: list, p: float) -> float:
    """numpy.percentile's default (linear interpolation between the two nearest ranks)."""
    ordered = sorted(float(v) for v in values)
    if len(ordered) == 1:
        return ordered[0]
    pos = p / 100.0 * (len(ordered) - 1)
    lo = int(pos)
    hi = min(lo + 1, len(ordered) - 1)
    return ordered[lo] + (ordered[hi] - ordered[lo]) * (pos - lo)


def relative_references(groups: dict) -> dict:
    """group → the sharpness that earns 100 points in relative mode: the 95th
    percentile of the group's keeper-eligible scores, so one freak frame
    can't flatten everyone else's stars. A group under RELATIVE_MIN_FRAMES
    gets no reference, so its bursts fall back to universal tiers."""
    return {g: percentile(v, RELATIVE_REFERENCE_PERCENTILE)
            for g, v in groups.items() if len(v) >= RELATIVE_MIN_FRAMES}


def star_tier(value: float, table: list, scale: float = 1.0) -> int:
    for threshold, stars in table:
        if value >= threshold * scale:
            return stars
    return 0


def rate_burst(burst_sharpness: dict, burst_flags: dict, burst_size: int, settings,
               eligible=None, reference=None, mode=None) -> tuple:
    """(members best first, keepers best first, id → stars, id → Why reason) for one
    burst. settings carries keep_mode, rank_mode and nk_mode, plus optional
    keep_margin (share of the burst's best a frame needs to keep as well, 0 = off),
    star_scale (default 1), sharp_mode and tag_only_flags. stars is an int, "leave"
    for a non-keeper the run leaves alone, or -1 for a rejected one. reference is
    the relative mode's selection-wide sharpness for 100 points
    (relative_references); None means the group was too small for one and the
    burst takes universal tiers. mode is the burst's sharp mode (settings.sharp_mode
    when not given) and picks its tier table."""
    if not burst_sharpness:
        return [], [], {}, {}

    allowed = keepers_allowed(settings.keep_mode, burst_size)
    if eligible is None:
        eligible = set(burst_sharpness)

    sorted_members = sorted(burst_sharpness.keys(),
                            key=lambda i: (i in eligible, burst_sharpness[i]), reverse=True)
    keepers = set([i for i in sorted_members if i in eligible][:allowed])
    best = max((burst_sharpness[i] for i in eligible), default=0.0)
    margin = getattr(settings, "keep_margin", 0.0)
    ranked = set(keepers)  # kept by rank, before the margin adds any
    if margin > 0 and best > 0:
        keepers |= {i for i in eligible if burst_sharpness[i] >= margin * best}

    burst_keepers = [i for i in sorted_members if i in keepers]
    num_keepers = len(burst_keepers)
    top_40_count = max(1, int(round(num_keepers * 0.4)))
    top_40_keepers = set(burst_keepers[:top_40_count])
    penalised = penalised_flags(burst_flags, getattr(settings, "tag_only_flags", frozenset()))
    star_scale = getattr(settings, "star_scale", 1.0)
    tiers = tier_table(mode or getattr(settings, "sharp_mode", ""))

    rated = {}
    for img_id in sorted_members:
        is_keeper = img_id in keepers
        raw_score = burst_sharpness[img_id]
        star_cost = sum(FLAG_PENALTIES[f][1] for f in penalised[img_id])

        if settings.rank_mode == "relative" and reference is not None:
            score = 100.0 * raw_score / reference if reference > 0 else 0.0
            stars = max(0, star_tier(score, STAR_THRESHOLDS, star_scale) - star_cost)
        elif settings.rank_mode == "binary":
            score = 100.0 if is_keeper else 0.0
            score -= sum(FLAG_PENALTIES[f][0] for f in penalised[img_id])
            stars = star_tier(max(0, score), STAR_THRESHOLDS)
        else:
            stars = max(0, star_tier(raw_score, tiers, star_scale) - star_cost)

        if is_keeper and settings.keep_mode != "keep_all" and num_keepers > 1 and img_id not in top_40_keepers:
            stars = max(0, stars - 1)
        rated[img_id] = stars

    lowest_keeper = min((rated[i] for i in keepers), default=5)
    stars_of, reason_of = {}, {}
    for img_id in sorted_members:
        is_keeper = img_id in keepers
        stars = rated[img_id]
        if not is_keeper:
            if settings.nk_mode == "leave":
                stars = "leave"
            elif settings.nk_mode == "reject":
                stars = -1
            elif settings.nk_mode == "graded":
                raw_score = burst_sharpness[img_id]
                share = (raw_score / best if best > 0 else 0.0) / star_scale
                drop = next((d for t, d in GRADED_STEPS if share >= t), None)
                stars = 0 if drop is None else max(0, lowest_keeper - drop)
                stars = max(0, stars - sum(FLAG_PENALTIES[f][1] for f in penalised[img_id]))
            else:
                try:
                    stars = int(settings.nk_mode)
                except ValueError:
                    stars = 0
        stars_of[img_id] = stars
        reason_of[img_id] = (("Keeper" if img_id in ranked else "Keeper by margin") if is_keeper
                             else "Not shortlisted" if img_id not in eligible
                             else "Graded" if settings.nk_mode == "graded" else "Outranked")
    return sorted_members, burst_keepers, stars_of, reason_of
