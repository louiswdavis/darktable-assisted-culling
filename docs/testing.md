# Testing and development

Part of [darktable-assisted-culling](../README.md). The Windows acceptance checklist, the tests, the scorer on its own and scoring against your picks.

## Acceptance checklist

The grouping-support changes have not run in darktable yet. Work through these steps on Windows, in order, and note the result of each. Use a test collection, or a copy of your library, for the first pass.

**Setup**

1. **Install Python** as in [Install](../README.md#1-python-side). *Expect:* the requirements install with no errors.
2. **Install the plugin** as in [Install](../README.md#2-darktable-side) and start darktable. *Expect:* an **Assisted Culling** panel on the right in lighttable, with the page buttons *1 scoring ▾* (open, its settings below it) to *6 tools ▸*; opening *5 run* shows a **Cull Selection** button. No `LUA ERROR` in the darktable log.
3. **Set the plugins folder** in **preferences → lua options → plugins folder (holds the three assisted-* folders)** to the folder holding the repo. *Expect:* runs find the repo's `.venv`.

**One run per grouping mechanism**

Use a selection with at least two bursts of 3+ frames each.

4. **Native groups.** Group each burst in darktable (ctrl+g), tick **Cull by Native Groups**, leave the tag node boxes blank, and click **Cull Selection**. *Expect:* one `Keeper` per burst (more if *Keepers* allows), the rest rated per *Non-Keepers*, with `Rejected` only on frames far behind their burst's best. The log at `%LOCALAPPDATA%\darktable\assisted_culling.log` shows `run started`, the `settings:` line, `grouping: native groups on, N of M images in groups of 2+` and `run finished`.
5. **Tag node cuts the groups.** Tag two frames of one burst with different children of a node (e.g. `Rally|2026|37` and `Rally|2026|86`), type the node in **tag node 1**, and cull. *Expect:* that burst keeps a frame of each child; untagged frames in it share one pool. The `grouping:` log line ends with `tag node Rally|2026: N grouped images tagged, 1 groups split`.
6. **Tag node forms the groups.** Run Assisted Grouping with **Group tags** on, untick **Cull by Native Groups**, type `Assisted Grouping` in **tag node 1**, and cull. *Expect:* the same per-burst keepers as step 4. The log line reads `grouping: native groups off, … tag node Assisted Grouping forms the groups`. Then type a node that doesn't exist on these images and cull again. *Expect:* every image is judged alone, and the log line ends with `(matches no selected image)`.
7. **Nothing set.** Untick **Cull by Native Groups**, blank all three boxes, and cull. *Expect:* every image is judged alone; each frame can be a keeper, and no "No groups found" notice shows.

**Panel**

8. **Cancel.** Start a run on a large selection and click the button while it shows **Cancel Culling**. *Expect:* the run stops; frames already done keep their changes. Repeat with the X on the job in darktable's job area. *Expect:* the button shows **Cancelling...** until the run has stopped, then **Cull Selection** again; a new run started straight after works normally.
9. **Why These Ratings?** with nothing selected. *Expect:* "Assisted Culling: Select some images first.".
10. **Clear Culling Marks** on the selection. *Expect:* the plugin's tags are gone; star ratings are unchanged.
11. **Tag switches.** Cull a batch with every tag on and note the stars. Under **Tags Written** in the panel, turn off *Subject* and *Rejected*, then cull the same batch again. *Expect:* the stars and keepers are the same as before; no image in the batch has an `Assisted Culling|Subject|Vehicle|Detected` or `Assisted Culling|Rejected` tag; `Keeper`, the flags, `Subject|Vehicle|Guessed`, `Technique`, `Scored` and `Why` are still there. Filter on `Assisted Culling|Why|Outranked`: every match is a non-keeper. Turn off *Why* and cull again: the `Why` tags are gone from the batch. No `LUA ERROR`.
12. **Checks survive diagnostics off.** Turn off *Subject*, *Technique*, *Scored* and *Why* (leave *Subject guessed* on) and cull a burst where the vehicle detector finds nothing. *Expect:* `Assisted Culling|Subject|Vehicle|Guessed` is still written and no `Detected`, `Technique`, `Scored` or `Why` tags appear.
13. **Restore Previous Ratings.** Give three frames ratings by hand and note them, cull them, then change one frame's rating by hand. Select all three and click **Restore Previous Ratings**. *Expect:* the two untouched frames are back to the ratings you noted; the one you changed keeps your new rating; the plugin's tags are unchanged; the message counts 2 restored and 1 rated since the run. Try it on a few hundred frames and note how long it takes.
14. **Reset Ratings to 0.** Give a few hundred frames 3 stars and reject one. Select them all and click **Reset Ratings to 0**. *Expect:* the panel line counts up (`resetting ratings 120 / 300`), a job bar appears, and the thumbnails lose their stars as it goes. Click the job bar's **x** part-way. *Expect:* it stops within a second or two; the message says how many were set and how many were not reached; the frames not reached still have 3 stars. Click the button again. *Expect:* it finishes the rest, counts the first part as "already at 0", the rejected frame is at 0 stars, tags and the selection are unchanged. Note how long the full reset takes next to darktable's own `0` key on the same selection.
15. **Detail tags after the ratings.** Cull a few hundred frames that were never culled, with *Why* on. *Expect:* the stars and `Keeper` / `Rejected` appear first and the message ends `Ratings are ready. Now writing N detail tags`; a second job bar (*writing detail tags*) counts up and darktable still scrolls and opens images meanwhile; at the end `Assisted Culling: Detail tags written (N).`. Cull again and click the detail job bar's **x** partway (clear the marks first): the message says how many images still miss theirs, and one more cull writes the rest. No crash, no `LUA ERROR`.
16. **Export and import a preset.** Store a preset named `Rally`, then pick **export preset…** in the actions menu, click **Export** (no folder to pick). *Expect:* `Preset "Rally" exported to <plugin folder>\exports\Rally.atpreset.zip`; that zip holds `manifest.json` and `preset.json`. Export again with nothing changed. *Expect:* `already exported and unchanged`. Change a setting, update the preset, export again. *Expect:* `exported to …\Rally.atpreset.zip (replaced the earlier export)`, with the new value in `preset.json`. Pick **import preset…**, choose the `Rally.atpreset.zip` file, click **Import**. *Expect:* `imported "Rally (2)" …`; picking `Rally (2)` shows the same settings as `Rally`.
17. **Verify Selection.** Cull a burst, change one frame's stars by hand, remove `Keeper` from another burst's keeper, and select both bursts plus a frame never culled. Click **Verify Selection**. *Expect:* `Verify started on N images…`, then `Verify only, nothing changed. …`; no star or tag changed; **Open Last Report** shows the cull's report, not the verify. To check lists the never-culled frame under *would get other stars* (with **Fix**), your hand change under *you changed 1 ratings* (no **Fix**), and the burst without `Keeper` under *bursts have no Keeper tag*. Click **Fix** on that line. *Expect:* only that burst is culled again and gets its `Keeper`; your hand rating stays. Verify again: only the hand-changed line is left.

## Development

### Tests

Run these from the repo root (the `darktable-assisted-culling` folder). One command runs every `python/test_*.py` and the Lua suite `lua/test_assisted_culling.lua` (or only the ones named, e.g. `score_images assisted_culling`) and writes each one's output to `tests/<name>.txt`. The Lua suite uses a `lua` on PATH if there is one, else lupa: run `pip install lupa` in the venv once (Windows has no `lua` by default):

```
# Linux / macOS
.venv/bin/python python/run_tests.py

# Windows
.venv\Scripts\python python\run_tests.py
```

The scorer's pure functions (saliency point, vehicle detection decoding, mask-aware sharpness, flags, manifest parsing) have their own tests on synthetic images, and a stress test runs 6000 mock frames through the whole scorer:

```
# Linux / macOS
.venv/bin/python python/test_score_images.py
.venv/bin/python python/stress_test_cull.py

# Windows
.venv\Scripts\python python\test_score_images.py
.venv\Scripts\python python\stress_test_cull.py
```

The eval script has its own stdlib-only tests: `python python/test_eval_culling.py` (they also run `rating.py`, which needs neither numpy nor cv2).

### Running the scorer on its own

The scorer runs standalone against any folder of images, no darktable involved. `manifest.csv` is `id,filepath,burst_id` per line:

```
python python/score_images.py manifest.csv results.csv
```

### Scoring a run against your own picks

`python/eval_culling.py` compares `last-run.csv` with the stars and rejects you gave a shoot by hand, so tuning star tiers, keeper settings or a new model is done on numbers. It needs no darktable, numpy or cv2.

1. Cull a shoot by hand in darktable: stars and rejects, as you would normally.
2. Before running the plugin on it, save those ratings, because the plugin writes its own stars into the same sidecars:
   ```
   python python/eval_culling.py @rally-photos.txt --snapshot rally-truth.csv
   ```
   `rally-photos.txt` holds one file or folder per line; folders are read for their images, and a RAW with a JPEG beside it counts once. Plain paths work in place of the `@list`.
3. Run the plugin with the settings under test.
4. Score it:
   ```
   python python/eval_culling.py @rally-photos.txt --truth rally-truth.csv --sharp-mode subject_focus
   ```
   Without `--truth` the sidecars are read directly, which only makes sense before the plugin has rated them. `--report PATH` points at a `last-run.csv` other than the one in darktable's config folder (an archived copy under `assisted_culling/reports/`, say). `--out FILE` also saves the text.

It prints, overall and per group, per sharpness mode and per motion class: the hit rate (your picks the plugin kept), false keepers (plugin keepers you didn't pick) and Spearman's rank correlation between your stars and its stars (rejected counts as -1; frames the run left alone are excluded and counted). A pick is an image you rated 1 star or more and didn't reject; `--pick-stars 3` raises the bar. The sharpness mode per burst is the one you pass, corrected where the run's `Technique` tag shows a burst switched (see [Shooting intent from EXIF](panel-options.md#shooting-intent-from-exif)). Only report rows for the given images count, so one `last-run.csv` can cover more than the shoot. A truth CSV can also be written by hand: columns `file` (name or path), `stars` (or `rating`, -1 for a reject) and optionally `rejected`.

Same inputs give the same output, so two runs with different settings are compared by diffing their `--out` files.

It also judges the order inside each burst, on the frames you rated by hand: **top-1 agreement** (the plugin's best frame is one of your picks) and **Spearman** between its scores and your stars. It prints the mean top-1, the median Spearman and the 5 worst bursts with their first frame in capture order, so you can find them in darktable. Bursts with under 3 rated frames, or rated all the same, are skipped and counted.

#### Changing a scoring constant without a re-run

A *motion_aware* run stores each frame's score parts in the report (subject sharpness, motion class, straightness). `--set NAME=value` rebuilds the scores from them with one constant changed, replays the keepers and stars, and prints the same summary:

```
python python/eval_culling.py @rally-photos.txt --truth rally-truth.csv --sharp-mode motion_aware --set PAN_BONUS=1.1
```

- `NAME` is `PAN_BONUS`, `MISSED_PAN_FACTOR`, `CLOSE_CALL_SHARE` or `SAME_SCALE`; repeat `--set` to change several.
- `--set SAME_SCALE=0` ranks each car at its own crop size (`subject_own`) instead of the burst's shared size. Run the eval with and without it to see what the shared size changes against your picks.
- Pass the run's panel settings too (`--rank-mode`, `--keep-mode`, `--keep-margin`, `--spread-keepers`, `--number-reads` (on/off), `--sharp-judge` (on/off), `--keep-angles`, `--motion-look`, `--star-slope` (on/off, each on by default), `--non-keeper`, `--star-scale`; each defaults to the plugin's default). A first line says in how many bursts a replay with nothing changed keeps the live run's frames: anything short of all means the settings differ from the run's.
- Another line says in how many bursts the stored parts rebuild the live order. Anything short of all means `score_images.py` and `eval_culling.py` disagree on the constants.
- A report from another sharpness mode, or from an older version, has no parts: `--set PAN_BONUS` then stops with a message. `--set CLOSE_CALL_SHARE` works on any report.

#### Letting it suggest settings

Instead of re-running the plugin per setting, `--suggest` replays the run's scores under every combination of ranking mode, keepers, keeper margin, spread keepers, number reads, the sharpness judge, other angles, motion look, star slope, star strictness and non-keepers (the panel's own choices; other angles and motion look need a report with the `view` and `motion_look` columns) and prints the best few against your picks:

```
python python/eval_culling.py @rally-photos.txt --truth rally-truth.csv --sharp-mode subject_focus --suggest
```

Each suggestion shows its hit rate, false keepers and Spearman, then the preset as JSON: paste it into `assisted_culling/presets/<name>.json` (see [Presets](panel-options.md#presets)), or `--write-preset FILE` writes the first one (to a new file only). Nothing in the plugin changes on its own. `--top N` shows more than 5.

- It needs `--sharp-mode`, because the replay rates each burst with the tiers of the mode the run used. The sharpness mode and the tier tables are not searched: `star_scale` covers "stricter or looser stars", and a different sharpness mode means different scores, so that is a new run.
- One shoot overfits: the best settings for one rally are the ones that happen to fit that rally. Keep each run's `last-run.csv` and `--snapshot` CSV and add them with `--shoot REPORT TRUTH` (repeatable; all must be runs in the same `--sharp-mode`). Counts are pooled across shoots. With one shoot it says so.
- The replay reads the report, not the images: it uses the same scores, bursts and shortlist. Frames the run could not read are not in the report, and tag-only flags are not either, so every flag it lists costs a star. The ranking is hit rate minus false-keeper rate, then Spearman; when two choices give the same numbers the panel's default wins.
- `python/rating.py` holds the keeper and star rules for both the plugin and the replay, so the two agree exactly.
- A setting the reports cannot tell apart is not searched and stays at the panel's default: other angles with no `view` in any report, motion look with no `motion_look` frame, star slope when no shoot has 10 (`SLOPE_MIN_KEEPERS`) frames that can keep. The output names each one with the reason and says how many of the combinations it tried.

#### Learning from what you did after a run

`--learn` needs no snapshot and no image list. It reads every archived report (the `reports` folder beside `last-run.csv`, or `--learn DIR`) and the sidecars as they are now, and takes what you changed as the truth:

```
python python/eval_culling.py --learn
python python/eval_culling.py --learn --sharp-mode motion_aware --suggest
```

- A correction: a frame's stars or reject flag differ from what the run wrote. The same value means you did not judge it. A frame the run left alone is compared with what an older report wrote, else with unrated.
- An edit: a frame you developed is a pick, stronger than any star rating, unless you rejected it. Edited means the sidecar's `darktable:history_current_hash` equals neither `history_basic_hash` nor `history_auto_hash`, which is darktable's own test for an altered image. A paired RAW's sidecar counts.
- Only a burst with a correction or an edit counts, and then all its frames do, with their stars as they are now. A frame counts in the newest report that holds it. A frame with no rated sidecar is skipped.
- It prints how many frames and bursts it learned from by source, what it left out, and `plugin kept N of the M frames you picked; you raised A, lowered B`. With `--suggest` these are the truth; `--shoot` adds more.
- Run it on the machine that holds the images, with darktable writing sidecars. The archive keeps the newest 20 reports, and all of them are read as runs in the `--sharp-mode` you pass.

### End-to-end without the GUI

The darktable half can be exercised headlessly through `darktable-cli`, which initialises Lua and honours `--luacmd`. `tools/e2e_cli.lua` imports a folder, runs the plugin on it, and writes a TSV of the rating and `Assisted Culling` tags darktable holds for each image afterwards, which is the plugin's entire observable output:

```
set DT_AI_CULL_FOLDER=C:/path/to/photos
set DT_AI_CULL_REPORT=C:/path/to/report.tsv
darktable-cli.exe any.jpg out.jpg --core --library "%LOCALAPPDATA%\darktable\library.db" -d lua --luacmd "dofile([[C:/path/to/tools/e2e_cli.lua]])"
```

Results land in the real library, so they show up in lighttable later. The script's header documents the two `darktable-cli` quirks it works around.

### Notes from the darktable source

Things that cost time to find out, recorded so they don't again:

- **`register_lib` takes eight positional arguments**: `(plugin_name, name, expandable, resetable, containers, widget, view_enter, view_leave)`. Leaving out `resetable` shifts the container table into a boolean slot and the panel never registers.
- **Registering a lib straight from `luarc` is a startup race.** darktable can report lighttable as the current view before the view has finished initialising, and a lib registered in that window is silently never attached (`src/views/view.c` documents it; the lua-scripts hit it as #19197). The plugin installs its panel from the `view-changed` event into lighttable instead, which fires only once the view is fully up.
- **`darktable-cli` never runs your `luarc`.** Since 5.6 the user `luarc` is loaded by `script_manager` (GUI only); before that the C code only loaded it when a GUI existed. `--luacmd` still runs, and it's the way to test headlessly. Anything GTK-wrapped (`register_lib`, `preferences.register`) blocks forever headless, so the plugin gates those on `dt.gui`.
- **`dt.control.execute` releases the Lua lock** while the child runs. That keeps the GUI responsive, but headless it lets `darktable-cli` tear Lua down mid-run once its export finishes, so without a GUI the plugin uses plain `os.execute` and holds the lock.
- **`group_with` first removes the image from its current group**, and removing a *leader* hands its group to another member. The plugin no longer stacks bursts with darktable's image grouping (bursts are a scoring concept only, read from the groups you made), but if that's ever added back: on a re-run over already-grouped images, attaching to a leader that still sits in an old group scatters the burst, so detach each keeper into a fresh group before attaching its burst-mates.
- **Windows shell-outs go through a `.bat` file**, following `lib/dtutils/system.lua` in darktable's lua-scripts: cmd.exe mangles a command line with more than one quoted item. In that file, write the exit code with the redirect first (`> "f" echo %ERRORLEVEL%`): `echo 0> "f"` reads as "redirect handle 0" and leaves `f` empty.
- **Ratings are written one image at a time with `img.rating`**, a few per slice, and the plugin never changes your selection. Selecting a batch and firing darktable's `views/thumbtable/rating` action was slower: on Windows with 110 images selected, darktable took 9 to 12 seconds to answer `dt.gui.selection()` / `dt.gui.action_images` before each batch (17 to 24 seconds for a run), while per-image writes set 110 ratings in 2 seconds.
