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
# a frame that could have kept but scores under this share of the burst's best is far
# behind: rejected (-1), at most settings.reject_cap of them per burst, worst first
FAR_BEHIND_SHARE = 0.30
# the last frame kept by rank and the best frame that wasn't kept are a close call
# when the dropped one scores at least this share of the kept one
CLOSE_CALL_SHARE = 0.95
# share of the burst's best score another view's best frame needs to keep (Other angle)
ANGLE_KEEP_SHARE = 0.7
# blur straightness (0-1) a frame needs to keep for its look (Motion look), and the stars it earns
MOTION_LOOK_STRAIGHT = 0.75
MOTION_LOOK_TIERS = [(0.85, 5), (0.80, 4), (0.75, 3)]
# the star slope: keepers across the run split into equal-count bands, worst band first
SLOPE_STARS = (1, 2, 3, 4, 5)
SLOPE_MIN_KEEPERS = 10  # fewer keepers than this take the tier tables
# with number reads on, the dropped frame of a close call reads a number both frames read
# at least this much more confidently (tagging's OCR, 0-1) than the kept one, so it keeps instead
NUMBER_READ_MIN_GAP = 0.10
# with the sharpness judge on (--sharp-judge), the top frames of a burst within CLOSE_CALL_SHARE of
# its best (at most JUDGE_FRAMES) get a quality score on the car crop, and the dropped frame of a
# close call keeps instead when it scores at least JUDGE_MIN_GAP (a share) above the kept one
JUDGE_FRAMES = 3
JUDGE_MIN_GAP = 0.05

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
    "cut_off": (15, 1),  # car cut by the frame edge (score_images.framing_flags, motion_aware only)
    "blocked": (15, 1),  # car hidden behind a nearer vehicle
    "blank": (100, 5),  # one flat colour (score_images.is_blank): never a keeper, rejected (blank_frames)
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
    dark or all eyes-closed was most likely shot that way on purpose. blank is
    the exception: an all-blank burst holds nothing either way."""
    shared = set.intersection(*map(set, burst_flags.values())) if len(burst_flags) > 1 else set()
    exempt = (shared - {"blank"}) | set(tag_only)
    return {i: tuple(f for f in flags if f not in exempt) for i, flags in burst_flags.items()}


def blank_frames(burst_flags: dict, tag_only=frozenset()) -> set:
    """The frames rate_burst rejects as blank: flagged blank, unless blank is tag-only."""
    return {i for i, flags in penalised_flags(burst_flags, tag_only).items() if "blank" in flags}


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


def slope_stars(sharpness_of: dict) -> dict:
    """id → stars for a run's keepers: ranked by sharpness and split into len(SLOPE_STARS)
    equal-count bands, the best band the most stars. Equal scores share the higher band.
    {} under SLOPE_MIN_KEEPERS keepers."""
    if len(sharpness_of) < SLOPE_MIN_KEEPERS:
        return {}
    ranked = sorted(sharpness_of.values(), reverse=True)
    return {i: SLOPE_STARS[-1 - ranked.index(value) * len(SLOPE_STARS) // len(ranked)]
            for i, value in sharpness_of.items()}


def close_call(burst_sharpness: dict, ranked_keepers: list, losers: list) -> set:
    """The last frame kept by rank and the best eligible frame not kept, when the second
    scores at least CLOSE_CALL_SHARE of the first; else empty. Both lists best first."""
    if not ranked_keepers or not losers:
        return set()
    kept, lost = ranked_keepers[-1], losers[0]
    if burst_sharpness[kept] > 0 and burst_sharpness[lost] >= CLOSE_CALL_SHARE * burst_sharpness[kept]:
        return {kept, lost}
    return set()


def number_clearer(kept_reads: dict, lost_reads: dict) -> bool:
    """True when the dropped frame reads the number both frames read best (highest summed
    confidence) at least NUMBER_READ_MIN_GAP more confidently than the kept frame. Reads are
    {number: confidence}; a frame with none never wins or loses."""
    shared = kept_reads.keys() & lost_reads.keys()
    if not shared:
        return False
    number = max(shared, key=lambda n: (kept_reads[n] + lost_reads[n], n))
    return lost_reads[number] - kept_reads[number] >= NUMBER_READ_MIN_GAP


def judge_shortlist(burst_sharpness: dict, eligible) -> list:
    """The ids the sharpness judge scores: eligible frames at CLOSE_CALL_SHARE of the best
    eligible score or more, best first, at most JUDGE_FRAMES. Only these can be a close call."""
    ranked = sorted((i for i in eligible if i in burst_sharpness), key=lambda i: -burst_sharpness[i])
    if not ranked or burst_sharpness[ranked[0]] <= 0:
        return []
    best = burst_sharpness[ranked[0]]
    return [i for i in ranked if burst_sharpness[i] >= CLOSE_CALL_SHARE * best][:JUDGE_FRAMES]


def judge_clearer(kept_score, lost_score) -> bool:
    """True when the judge scored both frames and the dropped one at least JUDGE_MIN_GAP (a
    share) above the kept one. None (not judged) never wins or loses."""
    if kept_score is None or lost_score is None or kept_score <= 0:
        return False
    return lost_score >= kept_score * (1 + JUDGE_MIN_GAP)


def spread_keepers(burst_sharpness: dict, in_order: list, by_score: list, allowed: int, best: float) -> set:
    """allowed keepers from in_order (the eligible ids in capture order) cut into allowed equal
    slices: each slice's best frame, unless it scores under CLOSE_CALL_SHARE of best, so a
    blurred slice doesn't keep a blurred frame. Each slice that keeps none is made up by the
    next-best frame overall (by_score: the eligible ids best first) not kept yet."""
    kept = set()
    for k in range(allowed):
        part = in_order[k * len(in_order) // allowed:(k + 1) * len(in_order) // allowed]
        pick = max(part, key=lambda i: burst_sharpness[i], default=None)
        if pick is not None and burst_sharpness[pick] >= CLOSE_CALL_SHARE * best:
            kept.add(pick)
    for i in by_score:
        if len(kept) >= allowed:
            break
        kept.add(i)
    return kept


def rate_burst(burst_sharpness: dict, burst_flags: dict, burst_size: int, settings,
               eligible=None, reference=None, mode=None, no_vehicle=frozenset(), order=None,
               reads=None, judged=None, views=None, motion_look=None, slope=None) -> tuple:
    """(members best first, keepers best first, id → stars, id → Why reason) for one
    burst. settings carries keep_mode, rank_mode and nk_mode, plus optional
    keep_margin (share of the burst's best a frame needs to keep as well, 0 = off),
    star_scale (default 1), sharp_mode and tag_only_flags. stars is an int, "leave"
    for a non-keeper the run leaves alone, or -1 for a rejected one. reference is
    the relative mode's selection-wide sharpness for 100 points
    (relative_references); None means the group was too small for one and the
    burst takes universal tiers. mode is the burst's sharp mode (settings.sharp_mode
    when not given) and picks its tier table. no_vehicle frames (the detector found no
    car) are never keepers and keep their rating ("leave"), whatever the other settings.
    Blank frames (blank_frames) are never keepers and are rejected (-1), before no_vehicle.
    A frame flagged cut_off (the car is cut by the frame edge) is never a keeper while
    another eligible frame shows the whole car, tag-only or not; its Why is Outranked.
    The keeper count comes from the eligible frames; burst_size is no longer read.
    A keeper in the close call keeps the stars its own score earns (no top-40% drop).
    settings.spread_keepers (default off) picks keepers per time slice (spread_keepers);
    order lists the ids in capture order, sorted ids when not given. A keeper the
    slices chose instead of a frame ranked higher gets Why|Spread. reads ({id: {number:
    confidence}}, tagging's OCR) settles the close call: when number_clearer, the dropped
    frame keeps instead (Why|Number clearer) and the kept one drops unless the keeper
    margin holds it. judged ({id: judge score}, judge_shortlist's frames) settles a close call
    the reads didn't: when judge_clearer, the same swap with Why|Subject clearer. None or {}
    changes nothing. views ({id: view index}, score_images.burst_views) with
    settings.keep_angles: in each view other than the best keeper's, the best eligible frame
    keeps when it scores ANGLE_KEEP_SHARE of the burst's best, beyond the allowed count, one
    star under the best keeper (floor 1) with Why|Other angle, and that view's other keepers
    rate no higher. A frame with no view takes no part. motion_look ({id: blur straightness}
    of the frames showing enough of the car, score_images.finish_burst) with
    settings.motion_look: the straightest frame keeps as well when it reaches
    MOTION_LOOK_STRAIGHT and is not a keeper already, beyond the allowed count, with
    Why|Motion look and the stars of MOTION_LOOK_TIERS less its flag penalties. slope
    ({id: stars}, slope_stars over the run's keepers) replaces the tier stars of the keepers
    it names, less their flag penalties and without the top-40% drop; relative and binary
    ranking ignore it. A frame that could have kept but scores under FAR_BEHIND_SHARE of
    the burst's best (times star_scale) is rejected (-1, Why|Far behind) in place of its
    nk_mode rating, the worst settings.reject_cap of them per burst (0 = no limit);
    nk_mode leave still leaves its rating alone. nk_mode reject rejects only those and
    leaves the other non-keepers."""
    if not burst_sharpness:
        return [], [], {}, {}

    tag_only = getattr(settings, "tag_only_flags", frozenset())
    blank = blank_frames(burst_flags, tag_only)
    if eligible is None:
        eligible = set(burst_sharpness)
    eligible = set(eligible) - set(no_vehicle) - blank
    cut_off = {i for i in eligible if "cut_off" in burst_flags.get(i, ())}
    cut_off = cut_off if cut_off != eligible else set()  # an all-cut-off burst still keeps
    eligible -= cut_off
    # counted on the frames that can keep, not burst_size: 3 frames of the car in a
    # 7-frame burst keep like a 3-frame burst
    allowed = keepers_allowed(settings.keep_mode, len(eligible))

    sorted_members = sorted(burst_sharpness.keys(),
                            key=lambda i: (i in eligible, burst_sharpness[i]), reverse=True)
    keepers = set([i for i in sorted_members if i in eligible][:allowed])
    best = max((burst_sharpness[i] for i in eligible), default=0.0)
    spread = set()
    if getattr(settings, "spread_keepers", False) and allowed > 1 and best > 0:
        by_rank = keepers
        keepers = spread_keepers(burst_sharpness, [i for i in (order or sorted(burst_sharpness)) if i in eligible],
                                 [i for i in sorted_members if i in eligible], allowed, best)
        spread = keepers - by_rank
    margin = getattr(settings, "keep_margin", 0.0)
    ranked = set(keepers)  # kept by rank (or by slice), before the margin adds any
    if margin > 0 and best > 0:
        keepers |= {i for i in eligible if burst_sharpness[i] >= margin * best}
    close = close_call(burst_sharpness, [i for i in sorted_members if i in ranked],
                       [i for i in sorted_members if i in eligible and i not in keepers])
    clearer, subject_clearer = set(), set()
    if close and (reads or judged):
        kept = [i for i in sorted_members if i in ranked][-1]
        lost = next(i for i in close if i != kept)
        if reads and number_clearer(reads.get(kept, {}), reads.get(lost, {})):
            clearer = {lost}
        elif judged and judge_clearer(judged.get(kept), judged.get(lost)):
            subject_clearer = {lost}
        if clearer or subject_clearer:
            ranked, spread = (ranked - {kept}) | {lost}, spread - {kept}
            in_margin = margin > 0 and burst_sharpness[kept] >= margin * best
            keepers = (keepers if in_margin else keepers - {kept}) | {lost}

    burst_keepers = [i for i in sorted_members if i in keepers]
    num_keepers = len(burst_keepers)
    top_40_count = max(1, int(round(num_keepers * 0.4)))
    top_40_keepers = set(burst_keepers[:top_40_count])
    angle = set()
    if getattr(settings, "keep_angles", False) and views and burst_keepers and best > 0:
        top_view = views.get(burst_keepers[0])
        for view in sorted({v for i, v in views.items() if i in eligible and v is not None} - {top_view}):
            view_best = next(i for i in sorted_members if i in eligible and views.get(i) == view)
            if top_view is not None and burst_sharpness[view_best] >= ANGLE_KEEP_SHARE * best:
                angle.add(view_best)
        keepers |= angle
        burst_keepers = [i for i in sorted_members if i in keepers]
    look = None
    if getattr(settings, "motion_look", False) and motion_look:
        straightest = max((i for i in motion_look if i in burst_sharpness and i not in blank | set(no_vehicle)),
                          key=lambda i: motion_look[i], default=None)
        if straightest is not None and straightest not in keepers and motion_look[straightest] >= MOTION_LOOK_STRAIGHT:
            look = straightest
    penalised = penalised_flags(burst_flags, tag_only)
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
        elif is_keeper and slope and img_id in slope:
            rated[img_id] = max(0, slope[img_id] - star_cost)
            continue
        else:
            stars = max(0, star_tier(raw_score, tiers, star_scale) - star_cost)

        if (is_keeper and settings.keep_mode != "keep_all" and num_keepers > 1
                and img_id not in top_40_keepers and img_id not in close):
            stars = max(0, stars - 1)
        rated[img_id] = stars
    if angle:
        under_best = max(1, rated[burst_keepers[0]] - 1)
        for img_id in angle:
            rated[img_id] = max(0, under_best - sum(FLAG_PENALTIES[f][1] for f in penalised[img_id]))
        for img_id in keepers - angle:  # the view's other keepers never outrate its Other angle frame
            if any(views.get(img_id) == views[a] for a in angle):
                rated[img_id] = min(rated[img_id], under_best)

    lowest_keeper = min((rated[i] for i in keepers), default=5)
    if look is not None:
        keepers.add(look)
        burst_keepers = [i for i in sorted_members if i in keepers]
        rated[look] = max(0, star_tier(motion_look[look], MOTION_LOOK_TIERS)
                          - sum(FLAG_PENALTIES[f][1] for f in penalised[look]))
    far = sorted((i for i in (eligible | cut_off) - keepers
                  if burst_sharpness[i] < FAR_BEHIND_SHARE * star_scale * best), key=lambda i: burst_sharpness[i])
    reject_cap = getattr(settings, "reject_cap", 0)
    far = set(far[:reject_cap] if reject_cap else far)
    stars_of, reason_of = {}, {}
    for img_id in sorted_members:
        is_keeper = img_id in keepers
        stars = rated[img_id]
        if img_id in blank:
            stars_of[img_id], reason_of[img_id] = -1, "Blank"
            continue
        if img_id in no_vehicle:
            stars_of[img_id], reason_of[img_id] = "leave", "No vehicle"
            continue
        if not is_keeper:
            if img_id in far:
                stars = "leave" if settings.nk_mode == "leave" else -1
            elif settings.nk_mode in ("leave", "reject"):
                stars = "leave"
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
        reason_of[img_id] = ("Motion look" if img_id == look
                             else "Other angle" if img_id in angle
                             else "Number clearer" if img_id in clearer
                             else "Subject clearer" if img_id in subject_clearer
                             else "Spread" if img_id in spread
                             else "Close call" if img_id in close
                             else ("Keeper" if img_id in ranked else "Keeper by margin") if is_keeper
                             else "Not shortlisted" if img_id not in eligible | cut_off
                             else "Far behind" if img_id in far
                             else "Graded" if settings.nk_mode == "graded" else "Outranked")
    return sorted_members, burst_keepers, stars_of, reason_of
