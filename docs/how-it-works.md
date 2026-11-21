# How it works and tuning

Part of [darktable-assisted-culling](../README.md). Scoring, grouping support, the SAM mode, the score cache, and the tuning constants.

## How it works

```
you select images in lighttable
        |
        v
assisted_culling.lua groups the selection by native groups and tag nodes
        |
        v
assisted_culling.lua writes manifest.csv (id, filepath, burst_id, …, shutter, aperture) and runs score_images.py
        |
        v
score_images.py scores sharpness and exposure, picks the keepers per burst, writes results.csv
        |
        v
assisted_culling.lua reads results.csv and applies ratings and tags
```

**One shot, one rating.** A RAW+JPEG pair (same folder and file name, e.g. `DSC01.ARW` + `DSC01.JPG`) and darktable duplicates of one file count as a single shot: it's scored once, and every image in it gets the same stars, tags and keeper decision. A pair is scored from the JPEG, TIFF or PNG (full size; the RAW only offers its embedded preview). These count as RAW: 3FR, ARI, ARW, BAY, CR2, CR3, CRW, DCR, DCS, DNG, ERF, FFF, IIQ, K25, KDC, MDC, MEF, MOS, MRW, NEF, NRW, ORF, ORI, PEF, RAF, RAW, RW2, RWL, SR2, SRF, SRW and X3F. `last-run.csv` has one row per shot, under the scored file; **Why These Ratings?** finds it from either file.

Two small processes talking through CSV files. The Lua side is split into pure logic (time parsing, group keys, CSV) with no darktable dependency, and the darktable integration proper; only the second half needs darktable to run.

### Scoring

Sharpness is the variance of the Laplacian of a downscaled grayscale copy, a standard and cheap focus proxy. Raw variance isn't comparable across cameras, lenses or ISOs, so keepers are picked within their burst; stars come from fixed tiers per sharpness mode, or from this selection in *relative* ranking (see [Ranking mode](panel-options.md#ranking-mode)). Exposure is flagged when more than 2% of pixels are crushed or blown (1% at or near clipping with *strict histogram*). Within a burst the highest sharpness wins; the others are rated per the non-keepers setting, and one far behind the best is rejected and tagged `Rejected`.

### Grouping support

Culling does not cluster images by capture time. Keepers are picked within groups that something else already made. The panel's **2 bursts** page has a **Cull by Native Groups** checkbox and three **tag node** boxes:

- **Cull by Native Groups** (default on): darktable's own image groups form the groups. An image's group is its group leader; members share one group even when the leader isn't in the selection.
- **tag node 1 to 3** (blank = not used): each filled node cuts the groups further, in order 1, 2, 3. Images in a group that carry different children of the node go to separate pools, each with its own keepers. An image without a child of the node stays in the group's shared pool, and so does an image with several children (the log lists those ids).
- **Checkbox off**: the first filled node forms the groups instead. An image without a child of that node is judged alone, and an image with several takes the first by name. The later nodes cut as above.
- **Checkbox off and every box blank**: every image is its own group and is judged alone.

A node is a tag path such as `Rally|2026`; its children are the tags one level below it, e.g. `Rally|2026|37`. Typing `Assisted Grouping` uses each image's own latest [Assisted Grouping](../../darktable-assisted-grouping/README.md) run (`Assisted Grouping|2026-01-01 12:00:00|Group|NNNN`), so after regrouping part of a shoot the regrouped images use the new run and the rest keep the old one. Assisted Grouping must have **Group tags** on, or there is nothing to find. With the checkbox on and every box blank, if no image is in a native group but grouping tags are present, the log and a notice say to type `Assisted Grouping` in a tag node box.

A node holding start-list entries splits per number only for entries tagged `<node>|<number>`; entries tagged `<node>|<team>|<name>` (imported start lists with teams) split per team, not per number.

Presets saved with the earlier **grouping support** dropdown load into the checkbox and tag node boxes and are saved back in that form; the log names the filled settings. *Native groups* becomes the checkbox on, *Grouping tags* becomes the checkbox off with the old grouping node (or `Assisted Grouping` when it was blank) in tag node 1, *None* becomes the checkbox off, and the old car tag node moves to the next free box (with *None* it is dropped: it split nothing).

The rally setup reads group tags; see [WORKFLOW.md](../../darktable-assisted-grouping/WORKFLOW.md).

An image with no group is its own group, and a selection with no groups at all still runs. Groups are not size-checked: a coarse group (Assisted Grouping's burst gap set high, or its Camera or Parent layers joining different cars) makes culling pick one keeper across all of them. That is your grouping settings at work: tighten the grouping, add a tag node, or fix the group. The log's `grouping:` line records whether native groups were on, how many images landed in groups of 2 or more, and for each node how many grouped images it tagged and how many groups it split (or that it matched no selected image).

### How the SAM mode fits together

`darktable.ai` is a generic ONNX runtime for Lua (`load_model` / `ctx:run`, plus a model registry keyed by task: `denoise`, `upscale`, `mask`). The `mask` model is SAM, which needs a prompt; darktable's darkroom object-mask tool supplies one with a click, and there's no "find the subject" task. And `darktable.ai` only runs inside darktable's Lua process, while scoring happens in the separate Python process. So this mode runs in three stages instead of two:

1. **Shortlist and prompt** (Python). `score_images.py --emit-saliency-points --keep-mode … [--detector <detector>.onnx]` shortlists each burst and writes one prompt per shortlisted frame as `id,x0,y0,x1,y1,cached` in frame fractions. A vehicle box fills all four; a salient point leaves `x1,y1` empty. `cached` is `1` when that frame's masked score is already in the score cache.
2. **Mask** (Lua). The plugin runs SAM on each prompt that isn't cached and writes a mask PNG. A box goes to SAM as two corner points labelled 2 and 3, the encoding darktable's `dt_seg_point_t` documents.
3. **Score** (Python). The scorer reads the mask path, shortlist flag and darktable edit time from the 4th, 5th and 6th manifest columns. Every mode gets shutter and aperture in the 7th and 8th.

### Score cache

Decoding and scoring is the slow part of a run, so per-frame scores are saved in `assisted_culling/scores.sqlite` inside darktable's config directory (e.g. `~/.config/darktable` on Linux and macOS). Re-running the same shoot with only a different ranking mode, keeper count, non-keeper option, grouping or "… lowers stars" option then skips decoding and re-applies in seconds.

A cached score is only reused when everything that produced it is the same:

| Changes the score (new entry) | Only uses the score (reused) |
|-------------------------------|------------------------------|
| the file itself (path, modified time, size) | ranking mode, star strictness, keeper margin |
| sharpness mode, as adjusted by [shooting intent](panel-options.md#shooting-intent-from-exif) | keepers, non-keepers, rejects per burst, first picks |
| motorsport mode: the vehicle detector file, the frame's shutter speed and focal length | |
| exposure mode | native groups, tag nodes |
| fast JPEG decode | the per-flag *… lowers stars* options |
| SAM mode: the mask model, the vehicle detector file, the prompt, and your last darktable edit of the frame | |

In SAM mode, raising the keeper count or changing the grouping can put new frames on a burst's shortlist; only those get a SAM pass. An edit in darktable (crop, rotate, lens correction) changes what SAM sees, so it re-runs SAM for that frame next time.

Every key also carries a fingerprint of the scoring constants in `score_images.py` and the versions of OpenCV, Pillow, rawpy and numpy, so editing a constant or upgrading a package re-scores on the next run by itself.

Entries not used for 90 days are deleted at the start of a run. To start over, delete the file.

EXIF can't supply the prompt instead: darktable exposes focus *distance*, not the AF point's position.

## Tuning

Everything you'd change per shoot is a panel option or a preference. What's left is a named constant at the top of the file that uses it:

- `assisted_culling.lua`: `PROGRESS_ANALYSIS` (0.75) is the share of the progress bar for analysis; applying ratings fills the rest. In SAM mode, `PROGRESS_SUBJECTS` (0.15) and `PROGRESS_SAM` (0.45) mark where finding subjects and segmenting end.
- `assisted_culling.lua`: `STAGE2_BATCH_WRITE_BUDGET` (60 tag and rating writes) and `STAGE2_BATCH_LINES` (200 results) size each slice of the final apply step before it yields to the GUI. Lower them if darktable stutters while ratings apply.
- `rating.py` (the keeper and star rules; `score_images.py` applies them during a run and `eval_culling.py --suggest` replays them):
  - `TIER_THRESHOLDS` (universal mode, variance scale), `PEAK_TIER_THRESHOLDS`, `UNIFORMITY_TIER_THRESHOLDS` and `MOTION_TIER_THRESHOLDS` (the other scales, mapped in `TIER_THRESHOLDS_BY_MODE`) and `STAR_THRESHOLDS` (binary and relative mode, as a percentage) turn sharpness into stars. The peak and uniformity tables are first guesses: set them from the `score` column of a real run's `last-run.csv` and check with [the eval script](testing.md#scoring-a-run-against-your-own-picks).
  - `RELATIVE_REFERENCE_PERCENTILE` sets which frame marks 5 stars in relative mode; `RELATIVE_MIN_FRAMES` (5) is the smallest scale that gets one.
  - `GRADED_STEPS` sets the shares of the burst's best that *graded by burst* non-keepers step down at.
  - `ANGLE_KEEP_SHARE` (0.7) is the share of the burst's best an Other angle keeper must score.
  - `MOTION_LOOK_STRAIGHT` (0.75) is the blur straightness a Motion look keeper needs; `MOTION_LOOK_TIERS` turns straightness into its stars.
  - `SLOPE_STARS` (1 to 5) are the stars the even slope hands out, lowest first; `SLOPE_MIN_KEEPERS` (10) is the fewest keepers it runs on.
  - `FLAG_PENALTIES` sets what each flag costs: points off the binary score (15 points is one star) and stars off in universal and relative mode.
- `score_images.py`:
  - `SHADOW_CLIP`, `HIGHLIGHT_CLIP` and `CLIP_PCT_FLAG` control exposure flagging.
  - `BLINK_MIN_FACE_PX` is the smallest face width judged for closed eyes.
  - `DETECTOR_MIN_SCORE` is the confidence a vehicle detection needs.
  - `CAR_BOX_MIN_IOU` (0.5) is how much a detector box must overlap one of [tagging's car boxes](panel-options.md#car-boxes-from-tagging) to be kept.
  - `SUBJECT_SCALES` (400, 600, 800, 1200) are the long-side sizes each car crop is also scored at, so a burst's frames can be compared at the largest size they all reach. Crops are never enlarged.
  - `PANNING_SHUTTER` (1/125 s) and `SHALLOW_DOF_APERTURE` (f/4) are the [shooting intent](panel-options.md#shooting-intent-from-exif) cutoffs.
  - `VIEW_ASPECT_STEP` (1.3) is how much a car box must change shape to count as another view; `MOTION_LOOK_MIN_BOX` (0.5) is the smallest car box, as a share of the burst's typical one, a Motion look keeper may have.
  - Motorsport mode: `STREAK_COHERENCE` (how strong a streak must be), `STREAK_SHARE` / `_SLOW` / `_FAST` (share of the background that must streak), `SUBJECT_STREAK_MAX` (how much of the car may streak in a good pan), `PAN_BONUS` and `MISSED_PAN_FACTOR`.
  - `SCORE_CACHE_MAX_AGE_DAYS` (default 90) is how long an unused cache entry is kept.
  - Nothing to bump after changing a constant: the ones that feed a score are listed in `CACHE_INPUTS` and hashed into every cache key, so the next run re-scores. Star and penalty tables, the shooting-intent cutoffs and the other names in `CACHE_NEUTRAL` only use the scores, so they re-apply from the cache. A new constant goes in one of the two tuples, or `test_score_images.py` fails. A change to the scoring *code* with no constant behind it isn't detected: delete `scores.sqlite` after one.

These are sensible starting points, not tuned defaults. Run a real shoot through it, see what gets flagged, and adjust. To adjust from numbers rather than impressions, [score a run against your own picks](testing.md#scoring-a-run-against-your-own-picks).
