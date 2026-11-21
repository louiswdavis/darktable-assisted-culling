# Panel options

Part of [darktable-assisted-culling](../README.md). Presets, every panel setting, and the preferences.

## Presets

The **Preset** picker at the top of the panel saves every panel setting (everything but the buttons) under a name, so a shoot type is one click away.

- **Preset**: `template` first, then your presets by name. Picking one loads its values into the panel. The panel opens on the last one you picked.
- **template**: the built-in defaults. It can't be updated, renamed or deleted; use it as the starting point for a new preset.
- **Actions** beside it: **update preset "<name>"** saves the panel into the selected preset; **store new preset…** asks for a name (type it, then **OK**) and saves the panel as a new preset; **rename preset…**; **delete preset** asks first. On `template` only **store new preset…** is offered.
- **Unsaved Changes** shows under the picker when the panel differs from the saved preset. Switching presets drops them. Text fields have no change signal, so their edits show when **Actions** is opened or a run starts.
- Each preset is `assisted_culling/presets/<name>.json` in darktable's config folder. A name can't be `template` or use characters a Windows file name can't hold.
- A setting missing from a file uses its default; **update preset** writes every setting, so older files fill in. A value that's no longer valid uses the default and logs one line naming the preset and setting.
- A file that can't be read or parsed: the panel says so, names the file, and keeps its current values. The plugin never rewrites a broken file; fix or delete it.
- A run reads the settings when it starts, so switching presets mid-run doesn't change it. Runs without the GUI (`--luacmd`) use the last picked preset, or the template defaults.

## Panel options

Below the [preset](#presets) picker are the page buttons **1 Scoring ▸** (genre to first picks, below), **2 Bursts ▸**, **3 Penalties & Speed ▸**, **4 Tags Written ▸**, **5 Run ▸** and **6 Tools ▸**: clicking one opens its contents below it (its label ends in **▾**) and folds the others; clicking the open one folds it. The open page is remembered across restarts. Below the pages sit the [To check](#to-check) box and the progress line. darktable's reset button (↺ in the panel header) puts every setting back to the template defaults; nothing is saved until you update a preset.

Page 1 has four headings: **How Frames Are Scored** (genre, ranking mode, sharpness, exposure), **Keepers per Burst** (keepers, keeper margin, spread keepers, keep the other angles, keep a motion-blur frame), **close calls** (the number-read and sharpness-judge tie-breaks) and **Ratings** (non-keepers, rejects per burst, star strictness, rate keepers against each other, first picks).

### Genre

*landscape*, *portrait*, *sport* and *macro* set four of the options below in one click. *custom* is selected automatically the moment you change any of them by hand. Genres never change *Non-Keepers*. A [preset](#presets) saves the genre along with everything else.

| Genre | Ranking mode | Sharpness | Exposure | Keepers |
|--------|--------------|-----------|----------|---------|
| landscape | universal absolute | edge-to-edge uniformity | strict histogram | single best only |
| portrait | universal absolute | face & eyes (OpenCV) | subject only (ignore sky) | portrait (1 or 2) |
| sport | universal absolute | motorsport (subject & motion) | whole frame | dynamic (1 to 5) |
| macro | universal absolute | absolute peak 1% | whole frame | keep all (focus stack) |

*sport* uses *motorsport (subject & motion)*. It works without any model; with the [vehicle detector](#vehicle-detector) installed it scores the car itself instead of the centre third. Its scores sit on their own scale, so *relative to selection* ranking is the safer choice until the universal tiers are tuned on a real shoot.

### Ranking mode

In every mode, keepers are picked within their own burst and non-keepers follow the *Non-Keepers* setting. The mode only decides a keeper's stars.

- *universal absolute*: keepers are rated against fixed sharpness tiers, so the same frame gets the same stars in any shoot. Each sharpness scale has its own tiers: the variance modes (*subject focus*, *subject peak*, *center*, *face*, *SAM*) share one table, and *peak*, *tiles uniformity* and *motion aware* have their own, so the macro and landscape presets spread stars too. A burst that [switched mode from EXIF](#shooting-intent-from-exif) is rated on the tiers of the mode it was scored in.
- *binary (keepers top)*: every keeper starts at 5 stars and only flags lower it (eyes closed, cut off and blocked −1, over/underexposed −3).
- *relative to selection*: tiers scale to the selection you're culling, so its sharpest frames get 5 stars even on a soft lens or in low light. The 5-star mark is the 95th percentile of the frames that could keep, so one freak frame can't flatten everyone else. Each sharpness scale is judged on its own: bursts that switched mode from EXIF, and SAM bursts with and without masks, don't share a 5-star mark. A scale with fewer than 5 frames that could keep (a one-frame selection, say) has no mark worth 5 stars, so its bursts take the universal tiers of their mode instead, and the log says so; a scale where every frame scores 0 gives 0 stars. Ratings only appear once every burst is scored, even with *apply ratings while scoring* on.

**Star strictness** (default *standard (×1)*) multiplies the sharpness every star needs in *universal* and *relative* ranking, how fast [graded non-keepers](#non-keepers) lose stars, and the far-behind line (30% of the burst's best). *Stricter (×1.25)* to *strictest (×2)* hand out fewer stars for the same frames; *more generous (×0.75)* and *much more generous (×0.5)* hand out more. Scores and keeper picks don't change, and neither do *binary* keepers' stars; which frames fall under the far-behind line does. With *Rate Keepers Against Each Other* on, the keepers of a *universal* run of 10 or more take their stars from that instead, and star strictness only sets how fast graded non-keepers lose stars. Changing it re-applies from the [score cache](how-it-works.md#score-cache) without decoding again.

### Sharpness

How each frame's focus is measured. Every mode except *motorsport* scores a copy shrunk to 800 px on its long side (`MAX_DIM`), so a small subject, a distant car or a face a few dozen pixels wide, is scored on few pixels and coarser than it looks at full size. *Motorsport* cuts the car from the full-size image instead (below).

- *center crop*: Laplacian variance over the middle 50% of the frame.
- *edge-to-edge uniformity*: splits the frame into a 3×3 grid and scores the weakest third of it, so one soft corner (camera shake, tilted focus, a soft lens edge) costs the frame. Plain areas like clear sky are left out, judged on their large-scale tones, which blur doesn't change. Meant for frames that should be sharp corner to corner (landscapes, architecture). Because it scores the weakest areas, its numbers run lower than the other modes', so expect fewer stars from *universal* ranking; *relative* ranking isn't affected.
- *absolute peak 1%*: the sharpest 1% of edges in the whole frame.
- *face & eyes (OpenCV)*: detects the largest face with OpenCV's Haar cascades and scores sharpness over the eyes if found, the whole face box otherwise. Falls back to *subject bias* when no face is detected. Eyes are searched in the upper face, retrying with the glasses-aware cascade; a face at least 120 px wide with no eyes found is tagged *Eyes Closed*. Needs OpenCV 4.x: OpenCV 5 removed the Haar detector, and the scorer stops with an install hint if it finds 5.
- *subject bias (center-weighted)*: a 3×3 grid scored on its sharpest patch, with the center patches counting more, on the assumption the subject is mid-frame. A classical heuristic, not AI.
- *subject tracking (SAM)*: masks the subject with darktable's own AI mask model and scores sharpness only inside the mask. See below.
- *motorsport (subject & motion)*: built for rally and track shoots in any light and at any shutter speed. See below.

#### Motorsport (subject & motion)

- **The car at full resolution.** The [vehicle detector](#vehicle-detector) finds the car (no detector, or no car found: the centre third of the frame). That area is cut from the full-size image, up to 1600 px on its long side, and scored there, so badges, numbers and tread still count. RAW-only frames use the embedded preview, so a small preview limits this.
- **Every frame of a burst is compared at one size.** A car coming toward the camera fills more pixels in each frame, and a bigger crop scores sharper for that alone. So each crop is also scored shrunk to 400, 600, 800 and 1200 px (`SUBJECT_SCALES`; never enlarged), and the burst is ranked at the largest size all its crops reach. The report's `crop` column shows it (`2310x1100 → 800`). A burst with a crop under 400 px can't share a size; the log says so and its frames use their smallest sizes.
- **Overcast light isn't punished.** Sharpness is divided by the area's contrast, so a crisp car under flat grey cloud scores like the same car in sun.
- **Motion is read per frame**, not per burst, from the direction of the streaks across a 6×6 grid:
  - car sharp, background streaked → `Technique|Panning`, score ×1.15
  - whole frame streaked in one straight line → `Technique|Motion Blur`; the frame is lifted to its burst's median, so an intentional blur is kept or left with its neighbours rather than rejected. A burst that is all motion blur ranks its straightest frame first.
  - background streaked, car blurred across it → `Technique|Missed Pan`, score ×0.7
  - background streaked along lines running out from the frame centre (zoom ring turned during the exposure) → `Technique|Zoom Burst`, score ×1
  - anything else → no tag, scored on sharpness alone (camera shake and missed focus already score low)
- **Shutter × focal length** makes the streak test easier at slow shutter speeds (1/125 s at 100 mm or longer) and harder at 1/1000 s or faster. It never decides the class on its own.
- **A creative burst is not rejected.** When 80% of a burst's scored frames are zoom bursts, or motion blur at a median shutter of 1/8 s or slower, every frame gets `Technique|Creative Burst`. Its cut-off frames can keep, except frames with no car before the first car frame or after the last, and no frame is rejected as `Far behind`. The burst's log line ends `creative burst`.
- Each frame's class, streak share and crop size go in the log as a `motion …` line.

#### Shooting intent from EXIF

Two settings tell the scorer a soft background or soft edges were on purpose. Each burst is judged on its median shutter speed and aperture, so all its frames are scored the same way. Frames without EXIF are left out of the median.

- **Panning** (1/125 s or slower) in *subject bias*: only the sharpest patch counts. The usual small credit for an evenly sharp frame is dropped, since a pan's background is meant to be streaked. *Edge-to-edge uniformity* ignores shutter speed, because a slow shutter there is usually a tripod landscape.
- **Shallow depth of field** (f/4 or wider) in *edge-to-edge uniformity*: the burst is scored with *subject bias* instead, so wide-open shots with soft corners aren't penalised for them.

The other modes already ignore the background, so EXIF doesn't change them.

#### Subject tracking (SAM)

This is the mode that isn't fooled when autofocus lands on a catch fence instead of the car. SAM needs a hint of where the subject is, so the plugin gives it one: the frame's most distinctive region (edge detail plus colour contrast, like a bright livery against grey tarmac), or a box around a detected vehicle if you've set up the [vehicle detector](#vehicle-detector).

To keep it practical on long bursts, only a shortlist goes through the model: each burst's top frames by the fast *subject bias* score (3, or more if the keepers setting can keep more). Frames outside the shortlist can't become keepers. It's still slower than the other modes, since the shortlisted frames are decoded a second time for masked scoring and SAM runs on them through darktable's pipeline.

Needs darktable 5.6+ with a SAM or SAM 2 mask model enabled and downloaded (preferences → AI). If it isn't, the run stops before touching anything and says so. If SAM can't segment a shortlisted frame, that whole burst falls back to *subject bias*, so its frames are never compared on two different scales, and the plugin tells you how many frames it masked.

#### Vehicle detector

Guessing the subject point works on a bright livery but can pick a sponsor board or kerb instead. For motorsport, give SAM a box around the car: install a detector file ([Models](../README.md#4-models)) and, with the **plugins folder** preference set (or auto-detected), the best one in `models/` is used.

On each shortlisted frame, the detector finds cars, motorcycles and trucks (race cars are often labelled as trucks). The most prominent one, scored by confidence × size, becomes SAM's prompt, so a car filling a third of the frame beats a small one in the background. A frame with no vehicle (a crowd shot, a pit board) uses the point guess.

It runs on the CPU. YOLOX adds about a tenth of a second per frame; D-FINE-X is slower, but a frame tagging already detected with the same file comes from the shared cache. If the picked file isn't a model, the run stops and says so. Remove every detector file from `models/` to switch it off.

Vehicle boxes are cached in `assisted_plugins/detections.sqlite` in darktable's config directory, shared with the tagging plugin so a frame both plugins see with the same detector is detected once. The key is the file (path, modified time, size), the detector model (its name, size and content, not its folder) and a fingerprint of the shared detector code, so a new detector or a `vehicle_detect.py` change re-detects everything once; rows unused for 90 days are dropped. Delete the file to start over. The tagging plugin's `compare_detectors.py` measures two detectors against each other on your own images.

#### Car boxes from tagging

The detector also boxes trucks, vans and parked cars, and the most prominent box can be one of those rather than the race car. The tagging plugin's car check already throws those boxes out, and its last run writes the boxes it kept to `assisted_tagging/last-run/<collection>.boxes.json` in darktable's config directory. With **Only Car Boxes (From Tagging)** on, culling reads that file (`--car-boxes`) and drops any detector box that overlaps none of tagging's boxes by at least `CAR_BOX_MIN_IOU` (0.5). The motorsport detail then says `car box … from tagging (N other boxes dropped)`, and a frame left with no box says `tagging's car check dropped N`.

- Run tagging on the same collection first. The file is tagging's last run, picked by tagging's last collection; frames not in it use every detector box, as with the setting off.
- A frame edited (its file modified) after that tagging run, or one tagging failed on, uses every box too. The log counts these.
- A people tagging run writes no car boxes, so it is ignored.
- The log line `car boxes: …` says where the boxes came from, how many frames were checked and how many boxes were dropped.

### Exposure

A flagged frame is tagged `Overexposed` or `Underexposed` and loses one star (see [Flags cost stars](usage.md#flags-cost-stars-never-the-keeper)).

- *whole frame*: flags a frame with over 2% of it clipped.
- *subject only (ignore sky)*: the same, ignoring the top fifth of the frame (sky).
- *strict histogram*: flags from 1% of the frame at or near clipping.
- *ignore exposure*: no exposure flags.

### Keepers

How many frames per burst survive: *single best only*, *portrait (1 or 2)*, *dynamic (1 to 5)* (scales with burst size), or *keep all (focus stack)* for frames you'll merge rather than cull.

**Keeper margin** (default *off*) keeps more: every frame scoring within 95%, 90%, 85%, 80% or 75% of its burst's sharpest frame is kept too, on top of the *Keepers* count. A burst of near-identical sharp frames then keeps all of them, and a burst with one clear winner still keeps one. The extra keepers count as lower keepers, so they lose one star like any keeper outside the burst's top 40%. `last-run.csv` says "within the keeper margin of the best" for them.

**Spread Keepers Over the Burst** (default *off*, unproven) picks the keepers per stretch of the burst instead of by score alone. The burst's frames, in capture order (darktable's image id), are cut into as many equal stretches as keepers allowed, and each stretch keeps its sharpest frame. A car through a corner then keeps its entry and exit rather than three near-copies of the sharpest moment. A stretch whose best frame scores under 95% (`CLOSE_CALL_SHARE`) of the burst's best keeps nothing, and the next-sharpest frame overall is kept instead, so a mostly blurred burst still keeps its sharp frames. A keeper picked over a sharper frame gets `Why|Spread`. It does nothing when one keeper is allowed. The keeper margin still adds frames on top. Check it against your picks before relying on it: run once with it on and once off, then `eval_culling.py` each report.

**Keep the Other Angles** (default *on*; needs the detector, so *motorsport* sharpness) keeps a second view of the car. Each frame's view comes from the shape of the detector's box (width over height): in capture order, a frame whose shape is 1.3 times or more off the current view's median starts the next view (`VIEW_ASPECT_STEP`). One odd box between two frames that agree is treated as a wrong box. The best frame of each view the sharpest keeper is not in keeps when it scores at least 70% of the burst's best (`ANGLE_KEEP_SHARE`), on top of the keepers allowed, with `Why|Other angle` and one star below the sharpest keeper (never under 1). That view's other keepers are capped at the same stars. With the detector on, a frame flagged cut off never keeps while the burst has a frame showing the whole car, whatever this setting says.

**Keep a Motion-Blur Frame** (default *on*; needs the detector) keeps a frame for its look, not its sharpness. Per burst, the frame whose blur runs most nearly in one straight line keeps when its straightness is 0.75 or more (`MOTION_LOOK_STRAIGHT`), the car is detected, is not cut off and its box is at least half the burst's typical box (`MOTION_LOOK_MIN_BOX`). Blurred objects in front of the car do not rule the frame out. It is added to the keepers, never swapped for one, with `Why|Motion look` and stars from its straightness (`MOTION_LOOK_TIERS`): 3 from 0.75, 4 from 0.80, 5 from 0.85. Flags still cost their stars.

**Break Close Calls on the Number Read** (default *off*, unproven) settles a close call (the last keeper and the best frame that lost score within 5%) on the car number instead of a few percent of sharpness. It needs a tagging run on the same collection: the reads come from tagging's `boxes.json`, and frames changed since that run, or missing from it, keep the sharpness ranking. Both frames must read the same number, and the dropped frame must read it at least 0.10 (`NUMBER_READ_MIN_GAP`) more confidently; then it is kept in place of the keeper and gets `Why|Number clearer`. When several numbers are shared, the one with the highest combined confidence decides. A keeper inside the keeper margin stays kept as well. Check it against your picks: after a run with it on, `eval_culling.py --sharp-mode <mode>` prints the hit rate with it off and on.

**Break Close Calls with the Sharpness Judge** (default *off*, unproven; *motorsport* sharpness only) settles a close call with a learned image-quality model (HyperIQA) instead of a few percent of Laplacian sharpness, which a busy background or noise can tip. It needs the [sharpness judge](../README.md#4-models) model files; with the setting on and the files missing, the run stops and says so. Per burst it scores at most 3 (`JUDGE_FRAMES`) frames, those within the close-call share of the best, on 3×3 tiles of the car crop at 224 px, averaged. When the dropped frame scores at least 5% (`JUDGE_MIN_GAP`) above the last keeper, it is kept instead and gets `Why|Subject clearer`. The number read decides first when it is on and settles the call; the judge only sees close calls the reads left. Judge scores are cached with the other scores. Runtime per judged frame is not measured yet. Check it against your picks: after a run with it on, `eval_culling.py --sharp-mode motion_aware` prints the hit rate with it off and on.

### Non-keepers

What happens to the frames that aren't kept: *leave alone*, *reject bad frames (-1)*, a fixed star count from 0 to 5, or *graded by burst*. A frame far behind its burst's best (under 30% of its sharpness, times *Star Strictness*) is rejected whatever is picked here: rating -1 and the `Rejected` tag (`Why|Far behind`). *leave alone* still leaves its rating and writes only the tags. *reject bad frames* rejects only those and leaves the other frames not kept alone; they get no `Rejected` tag.

**Rejects per Burst** (no limit, 1, 2, 3, 5; default 2) caps the far-behind rejects in one burst to its worst frames. The other far-behind frames get the *Non-Keepers* rating as frames that lost (`Why|Outranked` or `Graded`). Blank frames are always rejected and never count toward it.

**First Picks** (off, 10, 15, 20, 30; default *off*) is for a quick delivery before the full cull. The whole selection is scored as usual, then only the N best keepers are rated, at most one per burst: each burst's best keeper, by stars then score. Every other frame is left alone, keeper or not: no rating change, no reject, and `Why|Not a first pick`. darktable shows nothing until the picks are chosen, so *Apply Ratings While Scoring* has no effect; the log line reads `first picks: X of Y keepers rated`. Run the cull again with it off for the full cull.

*graded by burst* rates each non-keeper below the burst's lowest keeper, by how sharp it is next to the burst's best frame:

| Share of the best | Stars |
|---|---|
| 90% or more | one less than the lowest keeper |
| 75% or more | two less |
| 60% or more | three less |
| 45% or more | four less |
| below 45% | 0; rejected (-1) when far behind (under 30%) |

Flags still cost a star each. **Star strictness** scales these steps too: stricter drops non-keepers faster, more generous keeps them closer to the keeper. For a spread of ratings around each burst's best frame, use *graded by burst* with a keeper margin of 90%.

**Rate Keepers Against Each Other** (default *on*; *universal* ranking only) rates the run's keepers against each other, so a shoot uses all five stars instead of bunching at two or three. It changes stars only, never which frames are kept, and *Star Strictness* does not move the stars of keepers rated this way. The keepers are ranked by sharpness and cut into five equal groups (`SLOPE_STARS`): the sharpest group gets 5 stars, the next 4, down to 1. Equal scores share the higher group. Other angle keepers stay one star below their burst's best, Motion look keepers keep their own rating, and flags still cost their stars. A run with fewer than 10 keepers (`SLOPE_MIN_KEEPERS`) uses the fixed star steps, as do the *binary* and *relative* ranking modes. Every burst is rated after the last one is scored, so with *Apply Ratings While Scoring* on the ratings still arrive at the end of scoring.

### 2 Bursts

- **Cull by Native Groups** (checkbox, default on). darktable's own image groups form the groups keepers are picked in, see [Grouping support](how-it-works.md#grouping-support).
- Under the heading **Extra Grouping by Tags**: **tag node 1**, **tag node 2**, **tag node 3** (blank = not used). Tag nodes whose children cut the groups further, in that order, e.g. the collection prefix from [Assisted Tagging](../../darktable-assisted-tagging/README.md) for one keeper per number. With the checkbox off, the first filled node forms the groups. Type `Assisted Grouping` for each image's latest Assisted Grouping run.

### 3 Penalties & Speed

Three headings: **Speed**, **Penalties (Each Lowers Stars by One)**, **Blank Frames and Vehicles**.

- **Apply Ratings While Scoring** (default off). Applies results as they arrive instead of all at the end. Faster on big batches, but darktable's UI shares the CPU with the scorer; turn off if it lags. No effect with *First Picks* on.
- **Fast JPEG Decoding** (default on). Decodes JPEGs and raw previews at reduced size. Several times faster; scores shift slightly, which matters little since keepers are ranked within each burst. It speeds up the whole-frame checks only: with *motorsport* sharpness, each frame is still decoded once more at full size to cut the car, so that mode gains less.
- **Blank Frames** (off, 99%, 97%, 95%, 90% one colour; default 95%). A frame at least this share one flat colour is tagged `Blank` and rejected. Off rates blank frames like any other.
- ***Flag* lowers stars** (default on, one per flag). Off = that flag never costs stars; it's still tagged if its tag switch is on. See [Flags cost stars](usage.md#flags-cost-stars-never-the-keeper).
- **Leave Frames with No Vehicle** (default off). *Motorsport* and *subject tracking (SAM)* sharpness with the [vehicle detector](#vehicle-detector) installed: a frame where it finds no car is never a keeper, keeps its rating and gets `Why|No vehicle`. A burst with no car in any frame is left alone.
- **Only Car Boxes (From Tagging)** (default on). In *motorsport* and *subject tracking (SAM)* sharpness with the [vehicle detector](#vehicle-detector) installed, sharpness and framing use only the detector boxes that the tagging plugin's last run kept as cars. See [Car boxes from tagging](#car-boxes-from-tagging).

### 4 Tags Written

One switch per row (default on), under three headings:

- **Outputs**: `Keeper`, `Rejected`, `Overexposed`, `Underexposed`, `Eyes Closed`, `Cut Off`, `Blocked`, `Blank`.
- **Check by Hand**: `Subject guessed` (writes `Subject|Vehicle|Guessed`: frames to look at by hand).
- **How It Decided**: `Subject` (writes `Subject|Vehicle|Detected`), `Technique`, `Scored`, `Why`.

A check is written whatever the diagnostics say; only its own switch stops it. Off = runs stop writing that row and remove it from the images they process; images outside the run keep it until **Clear Culling Marks**. Ratings and keeper picks don't change. Fewer tag writes also apply results faster. A preset saved before `Subject guessed` existed loads with it set to whatever `Subject` was, is saved back that way, and the log says so once (`preset <name>: tag_subject_guessed filled from the old preset's settings`). See [Choosing which tags are written](usage.md#choosing-which-tags-are-written).

### 5 Run

One heading, **Cull (Writes Ratings and Tags)**.

- **Tag Each Run** (default off). Stamps every frame a run writes with `Assisted Culling|Run|YYYY-MM-DD HH:MM`.
- **Cull Selection.** Scores the selected images and rates/tags them. Click again to cancel.
- **Verify Selection.** Scores the selected images as **Cull Selection** would and changes nothing: no rating, no tag, and the last run's report (used by **Why These Ratings?**) stays. [To check](#to-check) then lists what a cull would change. Scores come from the [score cache](how-it-works.md#score-cache), so a repeat is quick. While a run is going it is queued; **Cancel Culling** stops it.

### 6 Tools

Two headings: **Explain the Last Run (Changes Nothing)** over the first two buttons, and **Undo**.

- **Why These Ratings?** Explains the selected images from the last run's report. Changes nothing.
- **Open Last Report.** Opens `last-run.csv` in your spreadsheet app.
- **Clear Culling Marks.** Removes the plugin's tags from the selected images (see [Re-running and clearing](usage.md#re-running-and-clearing)).
- **Restore Previous Ratings.** Sets the selected images back to the star rating they had before the last run that changed a rating (same section).
- **Reset Ratings to 0.** Sets the selected images to 0 stars one after the other, with progress and a cancellable job bar (same section).

### To Check

A box headed **To Check**, above the progress line, lists what a run leaves for you to look at, so a toast that went by unseen isn't lost. It shows only when it has items. Each item reads `<action>: <what happened>` in full, wrapped over as many lines as it needs, with its buttons below. The newest run's items sit on top. Older runs' items move below an *Earlier runs (before HH:MM): may not hold any more* line, since a later run can have settled them; they stay until you remove them, so a Fix still works. It lists:

- **Cull**: errors, subject tracking that outlined only some frames, a cancel after some images were rated, images with a guessed subject, images in close calls, images that couldn't be updated or read, detail tags that failed or were stopped.
- **Verify**: images whose stars differ from what a cull gives now, with one line per image (`DSC00023.JPG: 0 stars, a cull now gives 5`); ratings you changed by hand since the last cull (`1 stars, the last cull wrote 4`), on their own line with no **Fix**; and, with the *Keeper* tag on, bursts with no `Keeper` tag or more than a cull gives. **Fix** on the stars line and the Keeper line runs **Cull Selection** on those bursts' images.
- **Clear**, **Restore ratings**, **Reset ratings**: a cancel that left images not reached, and images that couldn't be changed.

- **Fix** beside a line makes the change it describes to those images only, and removes the line.
- **Select** beside a line selects its images in the lighttable. Images removed from the library since are skipped, and a toast counts them. Lines about images darktable couldn't read or update have no **Select**: those images may be gone.
- The next run of the same action replaces that action's lines; other actions' lines stay. **Clear List**, under the items, empties the box.
- Six lines show; more add `and N more (see the log)`. The list is saved to `assisted_culling.checks.txt` in darktable's config folder, so it survives a restart.

## Preferences

All under **preferences → lua options**. Everything else is a panel setting saved with its [preset](#presets).

| Preference | Default | What it does |
|------------|---------|--------------|
| plugins folder (`assisted_plugins/plugins_root`) | empty (auto-detect) | The folder holding the assisted-* repos; this plugin uses `<plugins folder>/darktable-assisted-culling`, where `python/`, `models/` and `.venv` are found. The old `assisted_culling/plugin_folder` (this repo's folder) is still read and logged as deprecated. Its `models/` detector enables the [vehicle detector](#vehicle-detector) in SAM mode |
