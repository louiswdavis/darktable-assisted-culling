# Using it

Part of [darktable-assisted-culling](../README.md). What you get, how flags cost stars, re-running and clearing.

## Using it

In lighttable, select a batch (a whole shoot or a single burst) and click **Cull Selection** in the **Assisted Culling** panel on the right. Progress shows in darktable's message area; click the button again, or the X on the job in darktable's job area, to cancel. When the selection had no groups (every frame judged alone), the done message ends with a notice saying so; group first for keepers.

Running all three plugins? [WORKFLOW.md](../../darktable-assisted-grouping/WORKFLOW.md) says which order to pick and what to re-run after what.

### What you get

Each frame gets a star rating, which ranks it against the rest of the batch, plus any of these tags. With a tag node set, a group whose frames carry two of its children (two car numbers, say) keeps a frame of each.

| Tag | Meaning |
|-----|---------|
| `Assisted Culling\|Keeper` | The best frame (or frames) of its burst |
| `Assisted Culling\|Rejected` | A much worse frame than its burst's best: far behind (under 30% of the best's sharpness, times *Star Strictness*; at most *Rejects per Burst* of them, worst first) or blank, rated -1. A frame that only lost to a sharper one gets no `Rejected` tag and is rated per *Non-Keepers*. |
| `Assisted Culling\|Overexposed` | Blown highlights |
| `Assisted Culling\|Underexposed` | Crushed shadows |
| `Assisted Culling\|Eyes Closed` | *face & eyes* mode only: a face big enough to judge, with no open eyes found. Dark sunglasses trigger it too. |
| `Assisted Culling\|Cut Off` | *motorsport* mode with the vehicle detector only: the car touches the frame edge it is driving towards, or more than a tenth of it runs past another edge. The direction comes from the car's box moving across the burst (unknown when it moves under 5% of the frame width or fewer than 3 frames have a car; then both side edges count as leading). A car filling 60% of the frame or more is a tight crop and never flagged. A frame with no car before the burst's first frame with a car, or after its last, is cut off too: the car is not in yet, or has gone. One with no car between two car frames is a missed detection and not flagged. |
| `Assisted Culling\|Blocked` | *motorsport* mode with the vehicle detector only: a larger (nearer) vehicle box covers more than a quarter of the car. The car is the box closest in size to the burst's typical car, so a car passing close in front isn't taken for it. |
| `Assisted Culling\|Blank` | At least 95% of the frame is one flat colour (lens cap, black barrier, blown sky, fog), set by **Blank Frames**. Rejected (rating -1) in every mode and never a keeper, even when the whole burst is blank. A dark frame with lit headlights is not blank. |

Frames are also tagged with how they were judged, so you can spot-check the scorer:

| Tag | Meaning |
|-----|---------|
| `Assisted Culling\|Subject\|Vehicle\|Detected` | *subject tracking (SAM)* with the [vehicle detector](panel-options.md#vehicle-detector): the detector found a vehicle and SAM was pointed at it. The class (car, motorcycle, truck) is not tagged: the detector often calls a side-on car a motorcycle. Older runs wrote `Car`/`Motorcycle`/`Truck`; the next run replaces them on the frames it scores, and you can delete the leftover names in the tagging module's dictionary. |
| `Assisted Culling\|Subject\|Vehicle\|Guessed` | The detector found no vehicle, so SAM was given the guessed subject point. Worth a look: the guess can land on a kerb or sponsor board. |
| `Assisted Culling\|Scored\|Masked` | *subject tracking (SAM)*: the burst was ranked on SAM masks |
| `Assisted Culling\|Scored\|Subject bias` | *subject tracking (SAM)*: a shortlisted frame got no mask, so the burst fell back to *subject bias* |
| `Assisted Culling\|Technique\|Panning` / `…\|Shallow DoF` | The burst's EXIF switched its sharpness mode (see [shooting intent](panel-options.md#shooting-intent-from-exif)). In *motorsport*, `Panning` is per frame instead. |
| `Assisted Culling\|Technique\|Motion Blur` / `…\|Missed Pan` / `…\|Zoom Burst` | *motorsport* only: the frame is blurred in one straight line, the car is blurred across the pan, or the background streaks out from the frame centre (see [Motorsport](panel-options.md#motorsport-subject--motion)) |
| `Assisted Culling\|Technique\|Creative Burst` | *motorsport* only: 80% of the burst is zoom bursts or slow motion blur, so none of it is rejected as far behind |
| `Assisted Culling\|Why\|Keeper` / `…\|Keeper by margin` | Every scored frame gets one `Why` tag saying how it was decided. Kept by rank, or kept by the [keeper margin](panel-options.md#keepers). |
| `Assisted Culling\|Why\|Outranked` / `…\|Graded` / `…\|Not shortlisted` | Lost to a sharper frame, lost and rated by burst (*graded by burst*), or left out of the SAM shortlist. Filter on one to step through, say, every frame the margin kept. |
| `Assisted Culling\|Why\|Far behind` | Lost and scored under 30% of its burst's best, times *Star Strictness* (e.g. best 400, frame 100), so it is rejected, at most *Rejects per Burst* of them per burst, worst first: rating -1 and the `Rejected` tag. With *Non-Keepers* on *leave alone* the rating is left and only the tags are written. A frame left out of the SAM shortlist, or with no vehicle, is never far behind. |
| `Assisted Culling\|Why\|Close call` | The burst's last keeper and the best frame that lost scored within 5% of each other. Both get this tag in place of Keeper / Outranked; the keeper is still kept and rated as usual. Check both by eye. |
| `Assisted Culling\|Why\|Spread` | *Spread Keepers Over the Burst* only: kept as the best frame of its stretch of the burst over a sharper frame elsewhere (see [Keeper margin](panel-options.md#keepers)). Wins over Close call on that keeper; the frame it beat still says Close call. |
| `Assisted Culling\|Why\|Subject clearer` | *Break Close Calls with the Sharpness Judge* only: kept over the sharper frame of a close call because the judge model rated it at least 5% higher. The sharper frame keeps Close call. |
| `Assisted Culling\|Why\|Number clearer` | *Break Close Calls on the Number Read* only: kept over the sharper frame of a close call because tagging read the car's number more confidently in it. The sharper frame keeps Close call. |
| `Assisted Culling\|Why\|Other angle` | *Keep the Other Angles* only: the best frame of a view of the car that the burst's sharpest keeper does not show (see [Keepers](panel-options.md#keepers)). Kept one star below that keeper. |
| `Assisted Culling\|Why\|Motion look` | *Keep a Motion-Blur Frame* only: the burst's straightest motion blur with the car in view, kept as well as the sharp keepers and rated by how straight the blur is. |
| `Assisted Culling\|Why\|Blank` | The frame is blank, so it was rejected whatever its sharpness. |
| `Assisted Culling\|Why\|No vehicle` | Only with **Leave Frames with No Vehicle** on (penalties & speed page; default off), in motorsport or SAM sharpness with the vehicle detector installed. The detector found no car, so the frame is never a keeper, keeps its rating and gets no Rejected tag. A burst with no car in any frame is left alone. Other sharpness modes never run the detector, so they never write it. |
| `Assisted Culling\|Why\|Not a first pick` | *First Picks* only: not one of the run's first picks, so the frame keeps its rating, keeper or not, and nothing is rejected. |

`Subject` is grouped by kind (`Vehicle` today), leaving room for other detectors later.

#### When the tags are written

A cull writes in two steps, because each tag change costs about 100 ms in darktable (it rebuilds its tagging lists on every change):

1. **Ratings, `Keeper` and `Rejected`** as the results are applied. The end message (`Assisted Culling: Done. …`) follows; when detail tags are due it ends with `Ratings are ready. Now writing N detail tags`. You can start reviewing.
2. **Detail tags** afterwards: the flags (`Cut Off`, `Blank`, …), `Subject`, `Technique`, `Scored`, `Why` and the run stamp. They go on one image at a time with a pause after each, so darktable stays usable. The panel line shows `writing detail tags: image 40 / 404` with the time left, and a job bar titled *Assisted Culling: Writing detail tags* shows the same progress.

- the job bar's **x** stops the detail tags; ratings and `Keeper` / `Rejected` are already complete. Cull the same images again to write the rest (cached scores make that quick)
- a cull with no detail tag to change skips step 2
- a cancelled cull writes no detail tags
- another cull or reset clicked meanwhile queues until the detail tags finish

The log (`assisted_culling.log`) has one line per step: `apply: timing: … N rating writes, N Keeper / Rejected tag writes; final drain took Ns`, then `apply: detail tags: N of N tag writes on N of N images in Ns (waited Ns for darktable, paused Ns)`, then `apply: tag writes by tag (+ attached, - detached): …` with a count per tag.

#### Choosing which tags are written

Every tag above has a switch under **Tags Written** in the panel (headings *Outputs*, *Check by Hand*, *How It Decided*): one per output tag, and one each for `Subject|Vehicle|Guessed` and the `Subject`, `Technique`, `Scored` and `Why` families. The switches are saved with the [preset](panel-options.md#presets) as `tag_<row>` keys (including `tag_subject_guessed`, default on) and all on in `template`. Each switch's tooltip names the tags it writes. Turn off the ones you don't use to keep darktable's tag list short:

- **Off** = the next run stops writing that row's tags and removes them from the images it processes. Switching *Subject* off drops `Detected` only; `Guessed` has its own switch. A tag that was never written never shows up in the tag list.
- **Stars and keeper picks don't change.** The tags only report the decision; flags still cost stars per *"… lowers stars"*.
- Images outside the run keep their old tags; select them and use **Clear Culling Marks**. darktable keeps tag names nobody uses any more in its tag list; delete them in the tagging module's dictionary.
- `Locked` is yours and has no switch. The `Run` stamp stays the panel checkbox.

Filter on these in darktable's **collections** module (tag → Assisted Culling) to step through just the keepers, or just the rejects. The parent `Assisted Culling` tag collects everything the plugin has scored.

### Flags cost stars, never the keeper

Overexposed, Underexposed, Eyes Closed, Cut Off and Blocked each take one star off. They never decide which frame is kept; that's sharpness alone. Blank is different: a blank frame is always rejected and never kept, and neither safeguard below applies to it.

Two safeguards keep deliberate shots from being punished:

- **Shared by the whole burst = no penalty.** If every frame in a burst is flagged the same way, it was most likely shot that way (a dark tunnel exit, say), so each frame keeps the tag but not the lost star.
- **Per-flag switch.** For styles where a flag is the point (low-key, high-key), turn off *… lowers stars* for that flag under **Penalties & Speed** in the panel. Frames are still tagged (unless that flag's *tag* switch is off); the stars are left alone.

### Re-running and clearing

Re-running is safe: every tag is re-synced to the new result, so a frame that was a keeper last pass and isn't now loses its `Keeper` tag. It does overwrite star ratings, including ones you set by hand, except on non-keepers when *Non-Keepers* is *leave alone* or *reject*. With *reject* (and *First Picks* off), a frame an earlier run rated that is no longer a keeper goes to 0 stars; a rating you set by hand stays.

A few things a re-run doesn't touch:

- **Frames that can't be read** (counted as "unreadable" in the done message) keep whatever an earlier run left on them, tags and stars included.
- **Frames outside the selection** aren't re-scored. Groups are read from the selected frames only, so re-running on part of a burst can leave a keeper from each run. Select whole bursts, or the whole shoot.
- **A cancelled run** keeps the changes it already made; the rest keep their old values. Its message says how many images were changed. Run again to finish, or undo it: **Clear Culling Marks** removes the tags, and when the run had changed a star rating, **Restore Previous Ratings** puts the ratings back.

Tick **Tag Each Run** to also stamp every frame a run writes with `Assisted Culling|Run|YYYY-MM-DD HH:MM`, so you can filter darktable down to one run's frames. Stamps accumulate, and **Clear Culling Marks** leaves them; remove old ones in darktable's tag manager.

Each scoring run also writes `assisted_culling/last-run.csv` in darktable's config folder (the folder holding `assisted_culling.log`): one row per scored frame with its burst, rank in the burst, score, stars, keeper yes/no, flags, diagnostic tags, a `why` line ("kept: rank 1 of 4, 2 allowed", "not kept: rank 3 of 4, only 2 allowed or not eligible; flagged blur"), the file's folder and a `reason` column (the frame's `Why` tag: Keeper, Keeper by margin, Outranked, Far behind, Graded, Not shortlisted, No vehicle, Blank, Close call, Spread, Number clearer, Subject clearer, Other angle, Motion look or Not a first pick) and a `car` column: the frame's child tag under each tag node that cut the groups, joined by `/` (e.g. `37/left`), blank when no node cut or the frame had no child (frames carrying several children of a node stay in their shared pool). A node that forms the groups (checkbox off, first filled node) is not listed. A `direction` column holds the burst's travel direction (left, right or unknown) in motorsport mode with the vehicle detector, blank otherwise. Then `id` (darktable's image id, which follows capture order) and, in *motion_aware* mode, the score parts `eval_culling.py --set` rebuilds from: `subject` (subject sharpness at the burst's shared size), `motion` (pan, missed_pan, motion_blur or ordinary), `straightness`, `crop` (the crop's size and the size it was compared at) and `subject_own` (subject sharpness at the crop's own size); blank in other modes. Last, `reads`: the car numbers tagging read on the frame as `number:confidence`, best first, joined by `|`, only when *Break Close Calls on the Number Read* is on. Then `judge`: the sharpness judge's score for the frame, only for frames it judged with *Break Close Calls with the Sharpness Judge* on. Then `view` (which view of the car the frame shows, a number per burst; blank with no detector or no car) and `motion_look` (`yes` when the frame shows enough of the car to keep for its motion look), which let `eval_culling.py` replay the other-angle and motion-look keepers. The allowance counts every frame of the burst, including frames that couldn't be read. Open it in a spreadsheet to see why a frame lost, or to tune thresholds from evidence. It is overwritten by the next run, but each run's copy is also kept as `assisted_culling/reports/YYYYMMDD-HHMMSS.csv` (newest 20), so two runs can be compared.

While a run is going, **Clear Culling Marks**, **Restore Previous Ratings**, **Reset Ratings to 0** and the culling shortcut queue behind it instead of refusing. Each queued job keeps the selection and settings from when you clicked, and starts when the run before it finishes. Cancelling drops the queue. (The panel button turns into **Cancel Culling** during a run, so a second culling run can only be queued with the shortcut.)

In the panel, **Open Last Report** opens `last-run.csv` in your spreadsheet app. **Why These Ratings?** explains the selected images from that report (stars, rank in the burst, flags) without changing anything: one image shows its line on screen, several show a count with the full text in the log.

To protect a frame, tag it `Assisted Culling|Locked` yourself (create the tag in the **tagging** module). Runs then leave it out entirely: its stars and tags stay as they are, and it doesn't take a keeper slot in its burst, so another frame from that burst can be kept as well. The done message counts the locked frames it left alone.

**Clear Culling Marks** removes all the plugin's tags from the selection without touching star ratings. It still clears `Keeper`/`Rejected`/flag tags on locked frames, but never removes `Locked` itself. Colour labels are never read or written, so any you apply by hand are yours.

**Restore Previous Ratings** undoes the star ratings the plugin wrote. Select the images and click it:

- each image goes back to the rating it had before the first run that changed it, even after several runs
- an image you rated again since the last run that changed it is left alone
- tags are not changed; use **Clear Culling Marks** for those
- the saved ratings are in `assisted_culling.previous-ratings.csv` in darktable's config folder; each run adds the images it changed. A cancelled or failed run saves what it had changed. Delete the file to start the history again.

**Reset Ratings to 0** sets the selected images to 0 stars. Select the images and click it:

- images are set one after the other, a few per step, so darktable stays usable while it works
- the panel line shows `resetting ratings 120 / 800` with the time left, and a job bar shows the same progress
- the job bar's **x** stops it after the current step; images already set stay at 0, the rest keep their rating
- a rejected image is set to 0 stars too; an image already at 0 is skipped
- tags and the selection are not changed, and the saved ratings for **Restore Previous Ratings** are not updated

Older versions used red/yellow colour labels and a `Culled` tag. The tag comes off the next time an image is re-scored (or with **Clear Culling Marks**); the labels stay. To remove them once, collect by the `Assisted Culling` tag, select all, and toggle the labels off.
