# Roadmap

Ideas worth doing deliberately later, not bolted onto whatever's being fixed today.

Sources: the shared backlog (`../docs/superpowers/specs/backlog/darktable-plugins-tickets/`, numbered tickets) and three research notes from 2026-11-15 in `../docs/superpowers/research/`:
- `2026-11-15-unbuilt-ideas-harvest.md`: ideas found in old specs, audits and plans that the code doesn't have yet
- `2026-11-15-competitors-and-ux.md`: what Aftershoot, Narrative Select, Lightroom Assisted Culling and others do
- `2026-11-15-model-candidates.md`: models that would run under cv2.dnn or onnxruntime
- `2026-11-15-how-culling-tools-work.md`: how those tools score focus, pick keepers and learn from the user (patents, papers, vendor docs)

Competitor figures in those notes are vendor claims and have not been checked. No tool publishes its algorithm, and no independent motorsport test exists.

## Score the car the shooter aimed at

- **Targeted car.** Aftershoot's sports/racing mode is said to check that the *intended* car is sharp, not any car (vendor claim). Pick the vehicle box nearest the camera's AF point from EXIF (maker notes; no plugin reads them yet), falling back to the box nearest the frame centre. A frame where the targeted car is soft but a background car is sharp scores low. Effort S–M; AF-point fields differ per maker.
  Route (`../docs/superpowers/research/2026-11-16-af-point-metadata.md`, not tested on real files):
  - **Sony first:** maker-note `FocusLocation` holds width, height, X and Y in pixels, readable in Python through exiv2 (`Exif.Sony1.FocusLocation`).
  - Normalise to X/width, Y/height, then apply EXIF orientation and any crop.
  - Before trusting it, check ZV-E10 files in Flexible Spot, Tracking and Wide modes: one unverified forum reply says the tag may follow the detected subject.
  - **Panasonic** `AFPointPosition` is already 0–1.
  - **Canon, Nikon, Fuji and OM** have caveats (centre origin, version-dependent layouts, no frame size). They go behind one interface, with `exiftool -j -n` as an optional fallback.
- **Pan quality, not just pan detection.** Mostly built already: a burst at 1/125 s or slower
  is scored on the subject only (`burst_sharp_mode`), and `motion_tiles` reads streak direction
  to tag `Technique|Panning`, `Motion Blur` or `Missed Pan`. Left to check: whether a good pan
  (strong background streak + sharp car) ranks *above* an equally sharp static shot, or only
  avoids a penalty. If only the latter, a small bonus from the existing streak coherence. Effort S.

## Motorsport failure modes worth scoring

Own ideas (round 5, not researched or tested), cheapest first:
- **Car cut off by the frame edge.** A vehicle box touching the frame edge on the side the car
  is heading means the nose is cut off. Penalty plus a `Why|Cut off` tag. Uses boxes already
  computed. Effort S.
- **Catch-fence focus.** At circuits the AF often locks on the fence in front of the car. Signs:
  the sharpest tiles inside the car box show a regular mesh (a strong peak in the tile's FFT at
  one spacing) while the car's own edges are soft. Penalty plus `Why|Fence focus`. Effort M.
- **Something in front of the car.** A person box or another car's box covering a large share of
  the targeted car → lower rank, unless every frame in the burst has it. Effort S once the
  targeted car exists.
- **Room ahead of the car.** Direction of travel from the view label (ticket 26) or the streak
  direction: more space in front of the car than behind is the usual composition. Weak
  tie-breaker only. Effort S–M.
- **Peak moments.** SigLIP zero-shot for "car airborne", "wheel lifted", "flames from exhaust",
  "spray / dust plume" → `Moment|…` tags and a tie-breaker inside a burst. Shares the SigLIP 2
  model with ticket 26. Unproven; effort M.

## Keep separate scores until the rating step

Adobe's Assisted Culling reports focus, eyes, exposure and misfire as separate signals. Keep culling's scores (sharpness, exposure, subject size, number readable) as separate fields in the manifest and `Why|` tags, and combine them only when picking stars. That lets the strictness slider and a learned ranker weight them without re-scoring.

## A "needs review" state

Today every frame ends up rated. The competitors mark the frames they're unsure of instead:
- an **Unsure / Needs review** bucket (a tag or colour label) for frames whose score sits near the keep line, so a second look covers only those
- **when in doubt, keep**: a close call leans to keeping, because a wrongly rejected frame is the expensive mistake
- a frame with **no vehicle box** stays unrated with a reason tag, instead of being scored on the whole image

Open: whether "unsure" is a colour label, a tag under `Assisted Culling|Why|…`, or both.

## Hand decisions stick

- **Rejects stick, confirms count.** A frame the user rejected or rated by hand is not re-rated on the next run. A hand pick in a burst counts as the keeper.
- **Changeable keeper.** Picking a different frame as keeper re-runs only that burst's keep step.
- **Restore previous ratings.** Every run saves the ratings it replaced, so one click undoes a run. Several competitors are criticised for having no undo.

## Score-only mode

A run that writes scores (and the `Why` reason tags) but no stars or rejects. Lets the user sort by score and judge before trusting the ratings.

## One strictness setting

Keep margin, star strictness and tier tables (ticket 04) behind one slider from "keep more" to "keep fewer", with the separate settings still in the settings file. Ticket 19 (`eval_culling.py --suggest`, still open) could pick the slider's points from past hand ratings.

## Learn from hand ratings (ticket 19)

Still open: `eval_culling.py` exists, `--suggest` does not. Search a small grid of settings against the ratings changed by hand on past shoots and print the best few. Second stage: a small ranker trained on "kept frame beats dropped frame" pairs inside a burst (see ticket 19).

How the second stage could work: every keeper the user swaps by hand is a pair (chosen beats dropped). Fit a Bradley-Terry model over the existing score fields (arXiv 1803.07212), so the ranker learns weights, not pixels. Make it opt-in with a reset button: a 2023 AAAI study found personalised aesthetic models can do worse than the general one.

## More than one keeper per car, when frames differ

Today each car gets one keeper. Apple's keeper patent (US10671895) ranks a burst, drops frames under a quality floor, then keeps extra frames only when they look different enough from the ones already kept, up to 3. For culling: keep a second or third frame of a car only if it's a different view or moment (embedding distance over a threshold). Check it against the one-keeper rule in ticket 15 before building; it could be a setting ("up to N per car").

## Keeper per track

Once grouping writes track ids (see its ROADMAP), pick the keeper per track rather than per
detected car, and break sharpness ties on whether the race number is readable. A sharp frame
with the number hidden is worth less to a shooter selling per-driver photos.

## Small or distant cars

- **Tile or crop** before detection, so a car that fills a small part of the frame still gets a box
- **Segmenter after a darkroom crop**: run SAM on the cropped pixels the user sees, not the full original
- **Other subjects** (people, animals) as the tagging plugin's collection kinds grow

## Models to try

From `2026-11-15-model-candidates.md`, best first:
1. **CLIP-IQA+ (ONNX) on the subject crop** for a sharpness/quality score (ticket 14). Its weights are non-commercial: local use only.
2. **SigLIP 2 zero-shot view** (front, side, rear) for view-aware ranking (ticket 26; throwaway test is ticket 27).
3. **Self-trained keeper classifier**, once ticket 11's eval data exists.
4. **RF-DETR nano/small** beside D-FINE in `compare_detectors` (Apache-2.0, ticket 13).

Rejected for licence: YOLO11/26 and YOLO-seg (AGPL).

Also from `2026-11-15-how-culling-tools-work.md`:
- don't ship **pyiqa**: its licence is PolyForm Noncommercial plus NTU S-Lab. Port single models with their own licences instead.
- **Q-Align** is a 7B model, too heavy for a lighttable plugin.
- **NIMA MobileNet** (Apache, Keras, no ONNX) is weak; use it only as a tie-breaker, if at all.

## Faster runs on Windows

No published CPU timings exist for the newer models (`../docs/superpowers/research/2026-11-16-af-point-metadata.md`), so measure first.
- **Time each stage** in the report (detect, segment, score per frame), so the slow step is known
  before anything is changed
- **GPU through onnxruntime**: the DirectML provider still works but ONNX Runtime has put it in
  sustained engineering; new Windows work goes to Windows ML. An opt-in
  `onnxruntime-directml` with automatic CPU fallback is the cheap trial; a Windows ML route waits
  until DirectML stops working. Shared with tagging, which runs the same detector
- Already built, not new: subject mode sends only each burst's shortlist (top 3 by subject bias)
  through SAM (README, subject mode)

## Review helpers

- **Open burst in compare**: a button that opens the current burst in darktable's culling view.
  Feasible: darktable's lighttable module exposes `layout` and `zoom_level` to Lua
  (`src/libs/tools/lighttable.c`, enum value `DT_LIGHTTABLE_LAYOUT_CULLING_DYNAMIC`), so the
  plugin selects the burst's images, then sets the layout. Previous/next burst buttons step
  through bursts the same way. ~0.5 day. The grouping plugin could share it ("open group").
- **Second pass on leftovers**: re-run only on frames still unrated or "needs review"

## Smaller known gaps

From the audits:
- **N1:** report "N allowed" from the manifest's burst size, not from the setting
- **N2:** match frames by folder + file stem, so two folders with the same file name don't collide
- **P2:** a frame whose prescore failed gets its own row in the report, not a silent skip
- **Tag rename parity:** culling's tag rename should go through `plugin_common.lua` like the others
