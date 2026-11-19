# Roadmap

Ideas worth doing deliberately later, not bolted onto whatever's being fixed today.

Background for the items below came from desk research in November 2026: unbuilt ideas found in old specs and audits; what Aftershoot, Narrative Select, Lightroom Assisted Culling and others do; models that run under cv2.dnn or onnxruntime; and how those tools score focus, pick keepers and learn from the user (patents, papers, vendor docs). What matters is written out in each item.

Competitor figures are vendor claims and have not been checked. No tool publishes its algorithm, and no independent motorsport test exists.

## Score the car the shooter aimed at

- **Targeted car.** Aftershoot's sports/racing mode is said to check that the *intended* car is sharp, not any car (vendor claim). Pick the vehicle box nearest the camera's AF point from EXIF (maker notes; no plugin reads them yet), falling back to the box nearest the frame centre. A frame where the targeted car is soft but a background car is sharp scores low. Effort S–M; AF-point fields differ per maker.
  Route (from reading the exiv2 and exiftool tag docs; not tested on real files):
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
- **Room ahead of the car.** Direction of travel from the view label (front, side, rear; see view-aware ranking under Models to try) or the streak
  direction: more space in front of the car than behind is the usual composition. Weak
  tie-breaker only. Effort S–M.
- **Peak moments.** SigLIP zero-shot for "car airborne", "wheel lifted", "flames from exhaust",
  "spray / dust plume" → `Moment|…` tags and a tie-breaker inside a burst. Shares the SigLIP 2
  model with view-aware ranking. Unproven; effort M.

## How much of the car is missing, and why

Built: `cut_off` and `blocked` (`score_images.framing_flags`), both yes/no. `blocked` only
counts a larger car box. Not measured: how much is missing, non-car occluders (people, posts,
fences, dust, signs), and whether an edge or an object hides the car when the box does not
touch an edge. Research: `docs/superpowers/research/2026-11-19-framing-occlusion.md`. Best first:
1. **Cut-off share.** The burst's frames of the same view (`burst_views`) give the car's full
   size; visible share = this frame's box / the expected box on the touching edge. A graded
   penalty instead of the flag. No model. Effort S.
2. **Non-car occluder from the SAM mask.** Mask area / box area against the burst's median for
   the view; a drop away from any edge means something is in front. Masks exist only for the
   subject-mode shortlist. Effort S–M.
3. **Occluder share from depth.** Depth Anything V2 Small (Apache-2.0, ONNX; Base and larger
   are non-commercial): share of box pixels clearly nearer than the car's median depth. Works on
   every frame and any object. One paper finds depth less reliable than occlusion cues for
   ordering, so trial it first. Windows CPU time unknown. Effort M.
4. **Edge vs object as separate tags.** From 1 and 2: box on the edge and a larger expected size
   → `Why|Cut off`; a gap inside the box → `Why|Blocked`. Each carries its share. Effort S after 1–2.
5. **Name the occluder.** Grounding DINO or OWLv2 (both Apache-2.0) for person, fence, pole.
   Heavy on CPU; only if 2–3 fall short. Effort L.

## Track the car across a burst

From the user's review of burst 943 (DSC01829–37, a night motion-blur burst). Only DSC01830 and
DSC01831 had a car box, yet DSC01837 kept: with no box, the scorer falls back to the centre third,
and light trails there score as sharp. Best first:
1. **Car not yet in, or gone.** In time order, a frame with no car box before the burst's first
   car frame or after its last is cut off (`cut_off`, so `Why|Cut off` as today). It never keeps
   unless every eligible frame is cut off, even in a creative burst. A frame with no box between
   two car frames is a detector miss and is not flagged. Effort S.
   **Built (2026-11-19), awaiting a Windows cull.**
2. **Weak boxes on the car's track.** Accept a box under `DETECTOR_MIN_SCORE` when it sits where
   the car's travel between neighbouring frames puts it. Fills detector misses in blurred
   frames. Effort S–M. Not approved.
3. **Headlight colour.** In a blurred burst, follow the colour of the headlight or tail-light
   trails seen in the car frames, to tell the car's trails from other lights. Effort M–L. Not approved.

## Why a frame is soft, and dirty lenses

Research: `docs/superpowers/research/2026-11-19-new-signals-across-plugins.md` (sections 1–2).
- **Blur type.** Today a soft frame gets one verdict. Split it: defocus (edges soft in every
  direction) vs motion (soft along one direction) on the car box, from handcrafted features
  (singular-value blur metric, gradient distribution; TikhoFormer reports these match deep models
  on this task). Shake = the whole frame, car included, streaks one way at a slow shutter; a missed
  pan = background sharp, car streaked. Tags `Why|Missed focus`, `Why|Motion blur`, `Why|Shake`.
  Builds on `motion_tiles`. Effort M.
- **Drops or mud on the lens.** No detector with released weights was found. Own idea: a blob
  that stays in the same place across a burst while everything else moves (panning moves the
  scene). Tag `Why|Dirty lens` on the burst, so the user knows to check every frame. Effort M;
  needs a rainy shoot to test.

## Deliberate styles are not mistakes

Research: `docs/superpowers/research/2026-11-19-motorsport-styles.md`. Zoom bursts, intentional
camera movement (ICM), light trails, tight detail crops and wide "small car in a landscape" frames
are deliberate, but today read as soft, cut off or far behind. Best first:
1. **Creative burst exemption.** When every frame in a burst is streaked across the whole frame
   (zoom burst: radial; ICM: one direction at 1/8 s or slower) or has no box at a long shutter
   (light trails), tag `Style|…` on the burst and skip the soft, cut-off and far-behind rejects
   for it. Uses `motion_tiles` and EXIF shutter. Effort M.
   **Built (2026-11-19), awaiting a Windows cull:** `zoom_burst` motion class, and a burst that is
   80% zoom burst or motion blur at a median 1/8 s or slower gets `Technique|Creative Burst` and
   skips the cut-off and far-behind rejects. Not yet: light trails (no box at a long shutter).
2. **Fast first picks.** A mode that rates only the first N keepers per session in time order,
   for a "15 edited frames within 90 minutes" delivery; the full cull runs later. Effort S.
   **Built (2026-11-19), awaiting a Windows cull:** panel *first picks* (off/10/15/20/30). Picks the
   N best keepers, one per burst, instead of time order; the rest are left alone with
   `Why|Not a first pick`.
3. **Frozen wheels on a flat pass.** A side-view frame with a sharp car and sharp background at
   a fast shutter is a weaker action frame (guides: frozen wheels kill the sense of speed). Small
   tie-break inside a burst only, never a reject; skipped for airborne or drifting cars (needs
   the peak-moment tags). Effort S–M.
   **Not built (2026-11-19): already covered.** Inside a burst a frozen frame classifies
   `ordinary` (×1.0) and a pan `pan` (×`PAN_BONUS` 1.15), so the pan already outranks it; a burst
   of only frozen frames has nothing to break. The airborne/drift skip would need the peak-moment
   tags, which do not exist yet. Tune `PAN_BONUS` with `eval_culling.py --set` instead.

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

Keep margin, star strictness and the per-mode star tier tables behind one slider from "keep more" to "keep fewer", with the separate settings still in the settings file. `eval_culling.py --suggest` (next section, still open) could pick the slider's points from past hand ratings.

## Learn from hand ratings

Still open: `eval_culling.py` exists, `--suggest` does not. Search a small grid of settings against the ratings changed by hand on past shoots and print the best few. Second stage: a small ranker trained on "kept frame beats dropped frame" pairs inside a burst.

How the second stage could work: every keeper the user swaps by hand is a pair (chosen beats dropped). Fit a Bradley-Terry model over the existing score fields (arXiv 1803.07212), so the ranker learns weights, not pixels. Make it opt-in with a reset button: a 2023 AAAI study found personalised aesthetic models can do worse than the general one.

## More than one keeper per car, when frames differ

Today each car gets one keeper. Apple's keeper patent (US10671895) ranks a burst, drops frames under a quality floor, then keeps extra frames only when they look different enough from the ones already kept, up to 3. For culling: keep a second or third frame of a car only if it's a different view or moment (embedding distance over a threshold). Check it against the one-keeper-per-car rule before building; it could be a setting ("up to N per car").

## Keeper per track

Once grouping writes track ids (see its ROADMAP), pick the keeper per track rather than per
detected car, and break sharpness ties on whether the race number is readable. A sharp frame
with the number hidden is worth less to a shooter selling per-driver photos.

## Small or distant cars

- **Tile or crop** before detection, so a car that fills a small part of the frame still gets a box
- **Segmenter after a darkroom crop**: run SAM on the cropped pixels the user sees, not the full original
- **Other subjects** (people, animals) as the tagging plugin's collection kinds grow

## Models to try

Best first:
1. **CLIP-IQA+ (ONNX) on the subject crop** as a second sharpness/quality judge beside the Laplacian score. Its weights are non-commercial: local use only.
2. **SigLIP 2 zero-shot view** (front, side, rear) for view-aware ranking: prefer the view the shooter usually keeps. Run a throwaway test of colour and view prompts on real frames first.
3. **Self-trained keeper classifier**, once eval data built from the user's own picks exists.
4. **RF-DETR nano/small** beside D-FINE in `compare_detectors` (Apache-2.0), as a candidate upgrade for the detector both plugins share.

Rejected for licence: YOLO11/26 and YOLO-seg (AGPL).

Also:
- don't ship **pyiqa**: its licence is PolyForm Noncommercial plus NTU S-Lab. Port single models with their own licences instead.
- **Q-Align** is a 7B model, too heavy for a lighttable plugin.
- **NIMA MobileNet** (Apache, Keras, no ONNX) is weak; use it only as a tie-breaker, if at all.

## Faster runs on Windows

No published CPU timings exist for the newer models, so measure first.
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
- **N1 (built):** `report_rows` takes "N allowed" from the manifest's burst size
- **N2 (built):** the Lua report lookup and `eval_culling.py` match frames by folder + file stem
- **P2 (built):** a frame stage A or stage C couldn't decode gets its own report row ("left alone: couldn't read the file (…)", rank and score blank); `eval_culling.py` skips those rows
- **Tag rename parity:** culling's tag rename should go through `plugin_common.lua` like the others
