# darktable-assisted-culling

A culling assistant for [darktable](https://www.darktable.org/). Select a batch of images in lighttable, click one button, and it will:

- group your selection into **bursts** using the groups you already made (darktable's own groups or [Assisted Grouping](../darktable-assisted-grouping/README.md) tags)
- score every frame for **sharpness** and **exposure clipping**
- pick the sharpest frame in each burst as the **keeper**
- write the result back as a **star rating** plus **tags** under `Assisted Culling|…`

Everything runs locally: a Lua plugin inside darktable and a small Python/OpenCV scorer it shells out to. No API keys, no cloud, no daemon. Nothing is deleted and your colour labels are never touched. It only rates and tags; rejecting is still your call.

<!-- docs/lighttable.png: lighttable with the Assisted Culling panel and a scored burst -->

## Contents

- [Requirements](#requirements)
- [Install](#install)
- [Using it](#using-it)
- [Presets](#presets)
- [Panel options](#panel-options)
- [Preferences](#preferences)
- [How it works](#how-it-works)
- [Tuning](#tuning)
- [Troubleshooting](#troubleshooting)
- [Limitations](#limitations)
- [Acceptance checklist](#acceptance-checklist)
- [Development](#development)

## Requirements

- darktable 5.4 or newer, built with Lua (the official builds are). The *subject tracking (SAM)* sharpness mode needs 5.6+ with an AI mask model downloaded.
- Python 3.10+ with `opencv-python-headless` (4.x; `requirements.txt` pins `<5`), `numpy`, `Pillow` and `rawpy`.

`rawpy` needs `libraw`. The Windows and macOS wheels bundle it; on Linux install `libraw-dev` first, or skip `rawpy` if you only shoot JPEG. It's imported lazily, only when a raw file shows up.

## Install

### 1. Python side

```
git clone https://github.com/louiswdavis/darktable-assisted-culling
cd darktable-assisted-culling

# Windows (Command Prompt or PowerShell)
python -m venv .venv
.venv\Scripts\pip install -r python\requirements.txt

# Linux / macOS (no plain `python` on macOS)
python3 -m venv .venv
.venv/bin/pip install -r python/requirements.txt
```

### 2. Optional: models

Only needed for the *subject tracking (SAM)* sharpness mode. Every other mode works without them.

1. **SAM mask model** (needs darktable 5.6+). In darktable, open **preferences → AI**, then enable and download a SAM or SAM 2 mask model. darktable stores and manages it, and the plugin uses whichever mask model is enabled there. SegNext mask models aren't supported; if one is enabled, the run stops and says so.
2. **Vehicle detector** (optional, for motorsport). Download [`object_detection_yolox_2022nov.onnx`](https://github.com/opencv/opencv_zoo/raw/main/models/object_detection_yolox/object_detection_yolox_2022nov.onnx) (36 MB, Apache-2.0), into the `models` folder in the repo; it's used automatically once it's there. See [Vehicle detector](#vehicle-detector) for what it does.

### 3. darktable side

darktable's config directory is `~/.config/darktable` on Linux/macOS and `%LOCALAPPDATA%\darktable` on Windows. Link the plugin into it and load it from `luarc`. The plugin is `lua/assisted_culling.lua` plus `lua/plugin_common.lua`, the module the three Assisted plugins share; a link into the repo finds the module beside the plugin by itself.

Linux / macOS:

```
mkdir -p ~/.config/darktable/lua/contrib
ln -s "$(pwd)/lua/assisted_culling.lua" ~/.config/darktable/lua/contrib/assisted_culling.lua
echo 'require "contrib/assisted_culling"' >> ~/.config/darktable/luarc
```

Windows (Command Prompt). Creating symbolic links needs an Administrator prompt unless Developer Mode is enabled.

```
if not exist "%LOCALAPPDATA%\darktable\lua\contrib" mkdir "%LOCALAPPDATA%\darktable\lua\contrib"
mklink "%LOCALAPPDATA%\darktable\lua\contrib\assisted_culling.lua" "%CD%\lua\assisted_culling.lua"
echo require "contrib/assisted_culling" >> "%LOCALAPPDATA%\darktable\luarc"
```

Windows (PowerShell). Same Administrator caveat.

```
New-Item -ItemType Directory -Force "$env:LOCALAPPDATA\darktable\lua\contrib"
New-Item -ItemType SymbolicLink -Path "$env:LOCALAPPDATA\darktable\lua\contrib\assisted_culling.lua" -Value "$PWD\lua\assisted_culling.lua"
Add-Content "$env:LOCALAPPDATA\darktable\luarc" 'require "contrib/assisted_culling"'
```

Windows without Administrator rights or Developer Mode: copy `assisted_culling.lua` into `%LOCALAPPDATA%\darktable\lua\contrib` instead of linking it, and add the same `luarc` line. Re-copy it after every update. With the **plugins folder** preference (next step) set, the plugin loads `plugin_common.lua` from that folder's `darktable-assisted-culling/lua/`; copy it into `contrib` too if you want darktable to start with the preference unset (the three plugins' copies are identical, so one copy serves all of them).

### 4. Point the plugin at the repo

Start darktable, open **preferences → lua options**, and set:

- **Python interpreter (.venv)**: the venv's `python.exe` / `bin/python`. On Windows the plugin runs the `pythonw.exe` beside it through `python/launch.py`, so no console window opens and no `.vbs`/`.bat` is written (antivirus behaviour checks such as Bitdefender Advanced Threat Defense flag that chain). A venv or python.org install has both files.
- **plugins folder (holds the three assisted-* folders)**: the folder that holds `darktable-assisted-culling` (and the other assisted plugins). `python/score_images.py`, `models/` and `.venv` are found inside `darktable-assisted-culling`, so the interpreter preference above is only needed if your Python lives elsewhere. A folder whose `darktable-assisted-culling` has no `python/score_images.py` is an error.

Both are shared by the assisted plugins; the older per-plugin **Assisted Culling: plugin folder** and **python interpreter** preferences still work, and the log says once to move them.

Every other setting lives in the panel and is saved with its [preset](#presets).

## Using it

In lighttable, select a batch (a whole shoot or a single burst) and click **Cull selection** in the **Assisted Culling** panel on the right. Progress shows in darktable's message area; click the button again, or the X on the job in darktable's job area, to cancel.

### What you get

Each frame gets a star rating, which ranks it against the rest of the batch, plus any of these tags:

| Tag | Meaning |
|-----|---------|
| `Assisted Culling\|Keeper` | The best frame (or frames) of its burst |
| `Assisted Culling\|Rejected` | Lost to a sharper frame from the same burst; rated per the *non-keepers* option |
| `Assisted Culling\|Overexposed` | Blown highlights |
| `Assisted Culling\|Underexposed` | Crushed shadows |
| `Assisted Culling\|Eyes Closed` | *face & eyes* mode only: a face big enough to judge, with no open eyes found. Dark sunglasses trigger it too. |

Frames are also tagged with how they were judged, so you can spot-check the scorer:

| Tag | Meaning |
|-----|---------|
| `Assisted Culling\|Subject\|Vehicle\|Detected` | *subject tracking (SAM)* with the [vehicle detector](#vehicle-detector): the detector found a vehicle and SAM was pointed at it. The class (car, motorcycle, truck) is not tagged: the detector often calls a side-on car a motorcycle. Older runs wrote `Car`/`Motorcycle`/`Truck`; the next run replaces them on the frames it scores, and you can delete the leftover names in the tagging module's dictionary. |
| `Assisted Culling\|Subject\|Vehicle\|Guessed` | The detector found no vehicle, so SAM was given the guessed subject point. Worth a look: the guess can land on a kerb or sponsor board. |
| `Assisted Culling\|Scored\|Masked` | *subject tracking (SAM)*: the burst was ranked on SAM masks |
| `Assisted Culling\|Scored\|Subject bias` | *subject tracking (SAM)*: a shortlisted frame got no mask, so the burst fell back to *subject bias* |
| `Assisted Culling\|Technique\|Panning` / `…\|Shallow DoF` | The burst's EXIF switched its sharpness mode (see [shooting intent](#shooting-intent-from-exif)). In *motorsport*, `Panning` is per frame instead. |
| `Assisted Culling\|Technique\|Motion Blur` / `…\|Missed Pan` | *motorsport* only: the frame is blurred in one straight line, or the car is blurred across the pan (see [Motorsport](#motorsport-subject--motion)) |
| `Assisted Culling\|Why\|Keeper` / `…\|Keeper by margin` | Every scored frame gets one `Why` tag saying how it was decided. Kept by rank, or kept by the [keeper margin](#keeper-margin). |
| `Assisted Culling\|Why\|Outranked` / `…\|Graded` / `…\|Not shortlisted` | Lost to a sharper frame (left alone or rejected), lost and rated by burst (*graded by burst*), or left out of the SAM shortlist. Filter on one to step through, say, every frame the margin kept. |

`Subject` is grouped by kind (`Vehicle` today), leaving room for other detectors later.

#### Choosing which tags are written

Every branch above has its own switch under **tags written** in the panel, saved with the [preset](#presets) and all on in `template`. Each switch's tooltip names the tags it writes. Turn off the ones you don't use to keep darktable's tag list short:

- **Off** = the next run stops writing that branch and removes it from the images it processes. A branch that was never written never shows up in the tag list.
- **Stars and keeper picks don't change.** The tags only report the decision; flags still cost stars per *"… lowers stars"*.
- Images outside the run keep their old tags; select them and use **Clear culling marks**. darktable keeps tag names nobody uses any more in its tag list; delete them in the tagging module's dictionary.
- `Locked` is yours and has no switch. The `Run` stamp stays the panel checkbox.

Filter on these in darktable's **collections** module (tag → Assisted Culling) to step through just the keepers, or just the rejects. The parent `Assisted Culling` tag collects everything the plugin has scored.

### Flags cost stars, never the keeper

Overexposed, Underexposed and Eyes Closed each take one star off. They never decide which frame is kept; that's sharpness alone.

Two safeguards keep deliberate shots from being punished:

- **Shared by the whole burst = no penalty.** If every frame in a burst is flagged the same way, it was most likely shot that way (a dark tunnel exit, say), so each frame keeps the tag but not the lost star.
- **Per-flag switch.** For styles where a flag is the point (low-key, high-key), turn off *… lowers stars* for that flag under **penalties & speed** in the panel. Frames are still tagged (unless that flag's *tag* switch is off); the stars are left alone.

### Re-running and clearing

Re-running is safe: every tag is re-synced to the new result, so a frame that was a keeper last pass and isn't now loses its `Keeper` tag. It does overwrite star ratings, including ones you set by hand, except on non-keepers when *non-keepers* is *leave alone*.

A few things a re-run doesn't touch:

- **Frames that can't be read** (counted as "unreadable" in the done message) keep whatever an earlier run left on them, tags and stars included.
- **Frames outside the selection** aren't re-scored. Groups are read from the selected frames only, so re-running on part of a burst can leave a keeper from each run. Select whole bursts, or the whole shoot.
- **A cancelled run** keeps the changes it already made; the rest keep their old values.

Tick **Tag each run** to also stamp every frame a run writes with `Assisted Culling|Run|YYYY-MM-DD HH:MM`, so you can filter darktable down to one run's frames. Stamps accumulate, and **Clear culling marks** leaves them; remove old ones in darktable's tag manager.

Each scoring run also writes `assisted_culling/last-run.csv` in darktable's config folder (the folder holding `assisted_culling.log`): one row per scored frame with its burst, rank in the burst, score, stars, keeper yes/no, flags, diagnostic tags, a `why` line ("kept: rank 1 of 4, 2 allowed", "not kept: rank 3 of 4, only 2 allowed or not eligible; flagged blur"), the file's folder and a `reason` column (the frame's `Why` tag: Keeper, Keeper by margin, Outranked, Graded or Not shortlisted). The allowance counts every frame of the burst, including frames that couldn't be read. Open it in a spreadsheet to see why a frame lost, or to tune thresholds from evidence. It is overwritten by the next run, but each run's copy is also kept as `assisted_culling/reports/YYYYMMDD-HHMMSS.csv` (newest 20), so two runs can be compared.

While a run is going, **Clear culling marks** and the culling shortcut queue behind it instead of refusing. Each queued job keeps the selection and settings from when you clicked, and starts when the run before it finishes. Cancelling drops the queue. (The panel button turns into **Cancel culling** during a run, so a second culling run can only be queued with the shortcut.)

In the panel, **Open last report** opens `last-run.csv` in your spreadsheet app. **Why these ratings?** explains the selected images from that report (stars, rank in the burst, flags) without changing anything: one image shows its line on screen, several show a count with the full text in the log.

To protect a frame, tag it `Assisted Culling|Locked` yourself (create the tag in the **tagging** module). Runs then leave it out entirely: its stars and tags stay as they are, and it doesn't take a keeper slot in its burst, so another frame from that burst can be kept as well. The done message counts the locked frames it left alone.

**Clear culling marks** removes all the plugin's tags from the selection without touching star ratings. It still clears `Keeper`/`Rejected`/flag tags on locked frames, but never removes `Locked` itself. Colour labels are never read or written, so any you apply by hand are yours.

Older versions used red/yellow colour labels and a `Culled` tag. The tag comes off the next time an image is re-scored (or with **Clear culling marks**); the labels stay. To remove them once, collect by the `Assisted Culling` tag, select all, and toggle the labels off.

## Presets

The **preset** picker at the top of the panel saves every panel setting (everything but the buttons) under a name, so a shoot type is one click away.

- **preset**: `template` first, then your presets by name. Picking one loads its values into the panel. The panel opens on the last one you picked.
- **template**: the built-in defaults. It can't be updated, renamed or deleted; use it as the starting point for a new preset.
- **actions** beside it: **update preset "<name>"** saves the panel into the selected preset; **store new preset…** asks for a name (type it, then **OK**) and saves the panel as a new preset; **rename preset…**; **delete preset** asks first. On `template` only **store new preset…** is offered.
- **unsaved changes** shows under the picker when the panel differs from the saved preset. Switching presets drops them. Text fields have no change signal, so their edits show when **actions** is opened or a run starts.
- Each preset is `assisted_culling/presets/<name>.json` in darktable's config folder. A name can't be `template` or use characters a Windows file name can't hold.
- A setting missing from a file uses its default; **update preset** writes every setting, so older files fill in. A value that's no longer valid uses the default and logs one line naming the preset and setting.
- A file that can't be read or parsed: the panel says so, names the file, and keeps its current values. The plugin never rewrites a broken file; fix or delete it.
- A run reads the settings when it starts, so switching presets mid-run doesn't change it. Runs without the GUI (`--luacmd`) use the last picked preset, or the template defaults.

## Panel options

Below the [preset](#presets) picker the panel runs top to bottom in the order you'd check it: **1 scoring** (genre to non-keepers, below), **2 bursts**, **3 penalties & speed**, **4 tags written**, **5 run**, then **tools**. Each section has its own heading; all sections stay open. darktable's reset button (↺ in the panel header) puts every setting back to the template defaults; nothing is saved until you update a preset.

### Genre

*landscape*, *portrait*, *sport* and *macro* set four of the options below in one click. *custom* is selected automatically the moment you change any of them by hand. Genres never change *non-keepers*. A [preset](#presets) saves the genre along with everything else.

| Genre | Ranking mode | Sharpness | Exposure | Keepers |
|--------|--------------|-----------|----------|---------|
| landscape | universal absolute | edge-to-edge uniformity | strict histogram | single best only |
| portrait | universal absolute | face & eyes (OpenCV) | subject only (ignore sky) | portrait (1 or 2) |
| sport | universal absolute | motorsport (subject & motion) | whole frame | dynamic (1 to 5) |
| macro | universal absolute | absolute peak 1% | whole frame | keep all (focus stack) |

*sport* uses *motorsport (subject & motion)*. It works without any model; with the [vehicle detector](#vehicle-detector) installed it scores the car itself instead of the centre third. Its scores sit on their own scale, so *relative to selection* ranking is the safer choice until the universal tiers are tuned on a real shoot.

### Ranking mode

In every mode, keepers are picked within their own burst and non-keepers follow the *non-keepers* setting. The mode only decides a keeper's stars.

- *universal absolute*: keepers are rated against fixed sharpness tiers, so the same frame gets the same stars in any shoot. Each sharpness scale has its own tiers: the variance modes (*subject focus*, *subject peak*, *center*, *face*, *SAM*) share one table, and *peak*, *tiles uniformity* and *motion aware* have their own, so the macro and landscape presets spread stars too. A burst that [switched mode from EXIF](#shooting-intent-from-exif) is rated on the tiers of the mode it was scored in.
- *binary (keepers top)*: every keeper starts at 5 stars and only flags lower it (eyes closed −1, over/underexposed −3).
- *relative to selection*: tiers scale to the selection you're culling, so its sharpest frames get 5 stars even on a soft lens or in low light. The 5-star mark is the 95th percentile of the frames that could keep, so one freak frame can't flatten everyone else. Each sharpness scale is judged on its own: bursts that switched mode from EXIF, and SAM bursts with and without masks, don't share a 5-star mark. A scale with fewer than 5 frames that could keep (a one-frame selection, say) has no mark worth 5 stars, so its bursts take the universal tiers of their mode instead, and the log says so; a scale where every frame scores 0 gives 0 stars. Ratings only appear once every burst is scored, even with *apply ratings while scoring* on.

**Star strictness** (default *standard (×1)*) multiplies the sharpness every star needs in *universal* and *relative* ranking, and how fast [graded non-keepers](#non-keepers) lose stars. *Stricter (×1.25)* to *strictest (×2)* hand out fewer stars for the same frames; *more generous (×0.75)* and *much more generous (×0.5)* hand out more. Scores and keeper picks don't change, and neither does *binary*. Changing it re-applies from the [score cache](#score-cache) without decoding again.

### Sharpness

How each frame's focus is measured.

- *center crop*: Laplacian variance over the middle 50% of the frame.
- *edge-to-edge uniformity*: splits the frame into a 3×3 grid and scores the weakest third of it, so one soft corner (camera shake, tilted focus, a soft lens edge) costs the frame. Plain areas like clear sky are left out, judged on their large-scale tones, which blur doesn't change. Meant for frames that should be sharp corner to corner (landscapes, architecture). Because it scores the weakest areas, its numbers run lower than the other modes', so expect fewer stars from *universal* ranking; *relative* ranking isn't affected.
- *absolute peak 1%*: the sharpest 1% of edges in the whole frame.
- *face & eyes (OpenCV)*: detects the largest face with OpenCV's Haar cascades and scores sharpness over the eyes if found, the whole face box otherwise. Falls back to *subject bias* when no face is detected. Eyes are searched in the upper face, retrying with the glasses-aware cascade; a face at least 120 px wide with no eyes found is tagged *Eyes Closed*. Needs OpenCV 4.x: OpenCV 5 removed the Haar detector, and the scorer stops with an install hint if it finds 5.
- *subject bias (center-weighted)*: a 3×3 grid scored on its sharpest patch, with the center patches counting more, on the assumption the subject is mid-frame. A classical heuristic, not AI.
- *subject tracking (SAM)*: masks the subject with darktable's own AI mask model and scores sharpness only inside the mask. See below.
- *motorsport (subject & motion)*: built for rally and track shoots in any light and at any shutter speed. See below.

#### Motorsport (subject & motion)

- **The car at full resolution.** The [vehicle detector](#vehicle-detector) finds the car (no detector, or no car found: the centre third of the frame). That area is cut from the full-size image, up to 1600 px on its long side, and scored there, so badges, numbers and tread still count. RAW-only frames use the embedded preview, so a small preview limits this.
- **Overcast light isn't punished.** Sharpness is divided by the area's contrast, so a crisp car under flat grey cloud scores like the same car in sun.
- **Motion is read per frame**, not per burst, from the direction of the streaks across a 6×6 grid:
  - car sharp, background streaked → `Technique|Panning`, score ×1.15
  - whole frame streaked in one straight line → `Technique|Motion Blur`; the frame is lifted to its burst's median, so an intentional blur is kept or left with its neighbours rather than rejected. A burst that is all motion blur ranks its straightest frame first.
  - background streaked, car blurred across it → `Technique|Missed Pan`, score ×0.7
  - anything else → no tag, scored on sharpness alone (camera shake and missed focus already score low)
- **Shutter × focal length** makes the streak test easier at slow shutter speeds (1/125 s at 100 mm or longer) and harder at 1/1000 s or faster. It never decides the class on its own.
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

Guessing the subject point works on a bright livery but can pick a sponsor board or kerb instead. For motorsport, give SAM a box around the car:

1. Download [`object_detection_yolox_2022nov.onnx`](https://github.com/opencv/opencv_zoo/raw/main/models/object_detection_yolox/object_detection_yolox_2022nov.onnx) (36 MB, Apache-2.0, from OpenCV's model zoo). A `models` folder in the repo is the easiest place: it sits next to the venv, `.gitignore` already skips `*.onnx`, and `git pull` leaves it alone. From the repo root (Windows 10+ ships `curl`):

   ```
   mkdir models
   curl -L -o models/object_detection_yolox_2022nov.onnx https://github.com/opencv/opencv_zoo/raw/main/models/object_detection_yolox/object_detection_yolox_2022nov.onnx
   ```

   Re-cloning the repo deletes it.
2. Nothing else: with the **plugins folder** preference set (or auto-detected), the file is used whenever `models/object_detection_yolox_2022nov.onnx` exists.

On each shortlisted frame, YOLOX finds cars, motorcycles and trucks (race cars are often labelled as trucks). The most prominent one, scored by confidence × size, becomes SAM's prompt, so a car filling a third of the frame beats a small one in the background. A frame with no vehicle (a crowd shot, a pit board) uses the point guess as before.

It runs on the CPU and adds about a tenth of a second per frame. If the file is missing or isn't a model, the run stops and says so. Remove the file from `models/` to switch it off.

### Exposure

- *whole frame*: checks the whole frame for clipping.
- *subject only (ignore sky)*: drops the top 20% of the frame before checking.
- *strict histogram*: tighter clipping thresholds.
- *ignore exposure*: no exposure flags.

### Keepers

How many frames per burst survive: *single best only*, *portrait (1 or 2)*, *dynamic (1 to 5)* (scales with burst size), or *keep all (focus stack)* for frames you'll merge rather than cull.

**Keeper margin** (default *off*) keeps more: every frame scoring within 95%, 90%, 85%, 80% or 75% of its burst's sharpest frame is kept too, on top of the *keepers* count. A burst of near-identical sharp frames then keeps all of them, and a burst with one clear winner still keeps one. The extra keepers count as lower keepers, so they lose one star like any keeper outside the burst's top 40%. `last-run.csv` says "within the keeper margin of the best" for them.

### Non-keepers

What happens to the frames that aren't kept: *leave alone*, *reject (-1)*, a fixed star count from 0 to 5, or *graded by burst*. They always get the `Rejected` tag regardless.

*graded by burst* rates each non-keeper below the burst's lowest keeper, by how sharp it is next to the burst's best frame:

| Share of the best | Stars |
|---|---|
| 90% or more | one less than the lowest keeper |
| 75% or more | two less |
| 60% or more | three less |
| 45% or more | four less |
| below 45% | 0 |

Flags still cost a star each. **Star strictness** scales these steps too: stricter drops non-keepers faster, more generous keeps them closer to the keeper. For a spread of ratings around each burst's best frame, use *graded by burst* with a keeper margin of 90%.

### 2 bursts

- **grouping support** (Native groups, Grouping tags, None; default Native groups). What groups photos before keepers are picked, see [Grouping support](#grouping-support).
- **Grouping tag node (blank = newest run)**. The tag node whose children are the groups in Grouping tags mode.

### 3 penalties & speed

- **Apply ratings while scoring** (default off). Applies results as they arrive instead of all at the end. Faster on big batches, but darktable's UI shares the CPU with the scorer; turn off if it lags.
- **Fast JPEG decoding** (default on). Decodes JPEGs and raw previews at reduced size. Several times faster; scores shift slightly, which matters little since keepers are ranked within each burst.
- ***Flag* lowers stars** (default on, one per flag). Off = that flag never costs stars; it's still tagged if its tag switch is on. See [Flags cost stars](#flags-cost-stars-never-the-keeper).

### 4 tags written

One switch per branch (default on): `Keeper`, `Rejected`, `Overexposed`, `Underexposed`, `Eyes Closed`, `Subject`, `Technique`, `Scored`, `Why`. Off = runs stop writing that branch and remove it from the images they process; images outside the run keep it until **Clear culling marks**. Ratings and keeper picks don't change. Fewer tag writes also apply results faster. See [Choosing which tags are written](#choosing-which-tags-are-written).

### 5 run

- **Tag each run** (default off). Stamps every frame a run writes with `Assisted Culling|Run|YYYY-MM-DD HH:MM`.
- **Cull selection.** Scores the selected images and rates/tags them. Click again to cancel.

### tools

- **Why these ratings?** Explains the selected images from the last run's report. Changes nothing.
- **Open last report.** Opens `last-run.csv` in your spreadsheet app.
- **Clear culling marks.** Removes the plugin's tags from the selected images (see [Re-running and clearing](#re-running-and-clearing)).

## Preferences

All under **preferences → lua options**. Everything else is a panel setting saved with its [preset](#presets).

| Preference | Default | What it does |
|------------|---------|--------------|
| Python interpreter (.venv) (`assisted_plugins/python_bin`) | empty | Python with the requirements installed; shared by the assisted plugins. The old `assisted_culling/python_bin` is still read and logged as deprecated |
| plugins folder (`assisted_plugins/plugins_root`) | empty (auto-detect) | The folder holding the assisted-* repos; this plugin uses `<plugins folder>/darktable-assisted-culling`, where `python/`, `models/` and `.venv` are found. The old `assisted_culling/plugin_folder` (this repo's folder) is still read and logged as deprecated. Its `models/` detector enables the [vehicle detector](#vehicle-detector) in SAM mode |

## How it works

```
you select images in lighttable
        |
        v
assisted_culling.lua groups the selection by Grouping support (native, tags or none)
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

**One shot, one rating.** A RAW+JPEG pair (same folder and file name, e.g. `DSC01.ARW` + `DSC01.JPG`) and darktable duplicates of one file count as a single shot: it's scored once, and every image in it gets the same stars, tags and keeper decision. A pair is scored from the JPEG, TIFF or PNG (full size; the RAW only offers its embedded preview). These count as RAW: 3FR, ARI, ARW, BAY, CR2, CR3, CRW, DCR, DCS, DNG, ERF, FFF, IIQ, K25, KDC, MDC, MEF, MOS, MRW, NEF, NRW, ORF, ORI, PEF, RAF, RAW, RW2, RWL, SR2, SRF, SRW and X3F. `last-run.csv` has one row per shot, under the scored file; **Why these ratings?** finds it from either file.

Two small processes talking through CSV files. The Lua side is split into pure logic (time parsing, group keys, CSV) with no darktable dependency, and the darktable integration proper; only the second half needs darktable to run.

### Scoring

Sharpness is the variance of the Laplacian of a downscaled grayscale copy, a standard and cheap focus proxy. Raw variance isn't comparable across cameras, lenses or ISOs, so frames are ranked against the rest of *this* batch and the percentile drives the star rating. Exposure is flagged when more than 2% of pixels are crushed or blown. Within a burst the highest sharpness wins; the others are tagged `Rejected` and rated per the non-keepers setting.

### Grouping support

Culling no longer clusters photos by capture time. Keepers are picked within groups that something else already made, and the panel's **grouping support** combobox picks which:

- **Native groups** (default): darktable's own image groups. A photo's group is its group leader; members share one group even when the leader isn't in the selection.
- **Grouping tags**: the children of an [Assisted Grouping](../darktable-assisted-grouping/README.md) tag node, e.g. `Assisted Grouping|2026-01-01 12:00:00|Group|NNNN`. The **Grouping tag node (blank = newest run)** entry names the node; blank uses the newest Assisted Grouping run found on the selected photos. Assisted Grouping must have **Write group tags** on, or there is nothing to find. A photo with several children under the node takes the first by name (the log lists them); a photo tagged only by an older run is alone.
- **None**: every photo is its own group and is judged alone.

A photo with no group is its own group, and a selection with no groups at all still runs. Groups are not size-checked: a coarse group (Assisted Grouping's burst gap set high, or its Camera or Parent layers joining different cars) makes culling pick one keeper across all of them. That is your grouping settings at work: tighten the grouping, switch to **None**, or fix the group. The log records the mechanism, how many photos landed in groups of 2 or more, and in Grouping tags mode the node used (or that it matched no selected photo).

### How the SAM mode fits together

`darktable.ai` is a generic ONNX runtime for Lua (`load_model` / `ctx:run`, plus a model registry keyed by task: `denoise`, `upscale`, `mask`). The `mask` model is SAM, which needs a prompt; darktable's darkroom object-mask tool supplies one with a click, and there's no "find the subject" task. And `darktable.ai` only runs inside darktable's Lua process, while scoring happens in the separate Python process. So this mode runs in three stages instead of two:

1. **Shortlist and prompt** (Python). `score_images.py --emit-saliency-points --keep-mode … [--detector yolox.onnx]` shortlists each burst and writes one prompt per shortlisted frame as `id,x0,y0,x1,y1,cached` in frame fractions. A vehicle box fills all four; a salient point leaves `x1,y1` empty. `cached` is `1` when that frame's masked score is already in the score cache.
2. **Mask** (Lua). The plugin runs SAM on each prompt that isn't cached and writes a mask PNG. A box goes to SAM as two corner points labelled 2 and 3, the encoding darktable's `dt_seg_point_t` documents.
3. **Score** (Python). The scorer reads the mask path, shortlist flag and darktable edit time from the 4th, 5th and 6th manifest columns. Every mode gets shutter and aperture in the 7th and 8th.

### Score cache

Decoding and scoring is the slow part of a run, so per-frame scores are saved in `assisted_culling/scores.sqlite` inside darktable's config directory (e.g. `~/.config/darktable` on Linux and macOS). Re-running the same shoot with only a different ranking mode, keeper count, non-keeper option, grouping or "… lowers stars" preference then skips decoding and re-applies in seconds.

A cached score is only reused when everything that produced it is the same:

| Changes the score (new entry) | Only uses the score (reused) |
|-------------------------------|------------------------------|
| the file itself (path, modified time, size) | ranking mode, star strictness, keeper margin |
| sharpness mode, as adjusted by [shooting intent](#shooting-intent-from-exif) | keepers, non-keepers |
| motorsport mode: the vehicle detector file, the frame's shutter speed and focal length | |
| exposure mode | grouping support |
| fast JPEG decode | the per-flag *… lowers stars* options |
| SAM mode: the mask model, the vehicle detector file, the prompt, and your last darktable edit of the frame | |

In SAM mode, raising the keeper count or changing the grouping can put new frames on a burst's shortlist; only those get a SAM pass. An edit in darktable (crop, rotate, lens correction) changes what SAM sees, so it re-runs SAM for that frame next time.

Every key also carries a fingerprint of the scoring constants in `score_images.py` and the versions of OpenCV, Pillow, rawpy and numpy, so editing a constant or upgrading a package re-scores on the next run by itself. The first run after this plugin update re-scores everything once (the old keys carried a version number instead).

Entries not used for 90 days are deleted at the start of a run. To start over, delete the file.

EXIF can't supply the prompt instead: darktable exposes focus *distance*, not the AF point's position.

## Tuning

Everything you'd change per shoot is a panel option or a preference. What's left is a named constant at the top of the file that uses it:

- `assisted_culling.lua`: `PROGRESS_ANALYSIS` (0.75) is the share of the progress bar for analysis; applying ratings fills the rest. In SAM mode, `PROGRESS_SUBJECTS` (0.15) and `PROGRESS_SAM` (0.45) mark where finding subjects and segmenting end.
- `assisted_culling.lua`: `STAGE2_BATCH_WRITE_BUDGET` (60 tag writes) and `STAGE2_BATCH_LINES` (200 results) size each slice of the final apply step before it yields to the GUI. Lower them if darktable stutters while ratings apply.
- `rating.py` (the keeper and star rules; `score_images.py` applies them during a run and `eval_culling.py --suggest` replays them):
  - `TIER_THRESHOLDS` (universal mode, variance scale), `PEAK_TIER_THRESHOLDS`, `UNIFORMITY_TIER_THRESHOLDS` and `MOTION_TIER_THRESHOLDS` (the other scales, mapped in `TIER_THRESHOLDS_BY_MODE`) and `STAR_THRESHOLDS` (binary and relative mode, as a percentage) turn sharpness into stars. The peak and uniformity tables are first guesses: set them from the `score` column of a real run's `last-run.csv` and check with [the eval script](#scoring-a-run-against-your-own-picks).
  - `RELATIVE_REFERENCE_PERCENTILE` sets which frame marks 5 stars in relative mode; `RELATIVE_MIN_FRAMES` (5) is the smallest scale that gets one.
  - `GRADED_STEPS` sets the shares of the burst's best that *graded by burst* non-keepers step down at.
  - `FLAG_PENALTIES` sets what each flag costs: points off the binary score (15 points is one star) and stars off in universal and relative mode.
- `score_images.py`:
  - `SHADOW_CLIP`, `HIGHLIGHT_CLIP` and `CLIP_PCT_FLAG` control exposure flagging.
  - `BLINK_MIN_FACE_PX` is the smallest face width judged for closed eyes.
  - `DETECTOR_MIN_SCORE` is the confidence a vehicle detection needs.
  - `PANNING_SHUTTER` (1/125 s) and `SHALLOW_DOF_APERTURE` (f/4) are the [shooting intent](#shooting-intent-from-exif) cutoffs.
  - Motorsport mode: `STREAK_COHERENCE` (how strong a streak must be), `STREAK_SHARE` / `_SLOW` / `_FAST` (share of the background that must streak), `SUBJECT_STREAK_MAX` (how much of the car may streak in a good pan), `PAN_BONUS` and `MISSED_PAN_FACTOR`.
  - `SCORE_CACHE_MAX_AGE_DAYS` (default 90) is how long an unused cache entry is kept.
  - Nothing to bump after changing a constant: the ones that feed a score are listed in `CACHE_INPUTS` and hashed into every cache key, so the next run re-scores. Star and penalty tables, the shooting-intent cutoffs and the other names in `CACHE_NEUTRAL` only use the scores, so they re-apply from the cache. A new constant goes in one of the two tuples, or `test_score_images.py` fails. A change to the scoring *code* with no constant behind it isn't detected: delete `scores.sqlite` after one.

These are sensible starting points, not tuned defaults. Run a real shoot through it, see what gets flagged, and adjust. To adjust from numbers rather than impressions, [score a run against your own picks](#scoring-a-run-against-your-own-picks).

## Troubleshooting

- **The panel isn't there.** Start darktable with `-d lua` and look for `LUA ERROR` in the log. On Windows the log is `Documents\Darktable\darktable-log.txt`.
- **Every run writes a log** to `assisted_culling.log` in darktable's config directory (e.g. `%LOCALAPPDATA%\darktable` on Windows); the run before it is kept as `assisted_culling.prev.log`. It has the settings, the scorer commands, every message shown on screen, each burst's shortlist, sharpness mode and keepers, and in SAM mode one line per segmented frame with its prompt and the exact error if SAM failed on it. Start here when a result looks wrong.
- **"no results" or "scorer produced no ratings".** The scorer failed; its output is at the end of the run log. The usual cause is the interpreter preference pointing at a Python without the requirements installed.
- **"SAM masked 0 of N shortlisted frames".** Look for the `SAM … failed:` lines in the run log for the error on each frame.
- **"score cache … is unreadable".** The cache file is damaged. Delete `assisted_culling/scores.sqlite` in darktable's config directory; the next run rebuilds it.
- **Scores look stale after editing `score_images.py`.** A constant change re-scores by itself (see Tuning); a code-only change doesn't. Delete the cache file.
- **darktable itself crashes on startup on Windows 11** (`0xC0000005`). darktable's Windows binaries are unsigned, and Smart App Control blocks unsigned DLLs that haven't built up reputation; it blocked `libdarkroom.dll` from 5.6.1 on a test machine. Check the `Microsoft-Windows-CodeIntegrity/Operational` event log for event 3077. Don't turn Smart App Control off (it's a one-way switch). An older release passes: `winget install --id darktable.darktable --version 5.4.1` ran with no blocks, and this plugin needs nothing newer.

## Limitations

- Apart from *subject tracking (SAM)* and *face & eyes* (when a face is found), every sharpness mode is a classical whole-frame or patch-grid heuristic. A frame with a sharp background and a soft subject can outscore the frame you'd actually keep.
- The SAM preprocessing (1024 px input, normalisation, prompt format) mirrors darktable's own `src/common/ai/segmentation.c` defaults, because `darktable.ai` doesn't expose a model's attributes to Lua. A mask model with a non-default input size would segment poorly; every image then falls back to *subject bias*, and the plugin reports how many did.
- SAM sees each image through darktable's pipeline (rotated, cropped, lens-corrected), while the scorer reads the original file, turned upright from its EXIF orientation. A darkroom crop that changes the aspect ratio is detected and that image falls back; a crop that keeps the ratio isn't, so on cropped edits the mask can sit off the subject. Cull before you crop.
- The vehicle detector sees the same downscaled copy as the scorer (800 px on the long side), so a very small, distant car can be missed. That frame then uses the point guess.

## Acceptance checklist

The grouping-support changes have not run in darktable yet. Work through these steps on Windows, in order, and note the result of each. Use a test collection, or a copy of your library, for the first pass.

**Setup**

1. **Install Python** as in [Install](#1-python-side). *Expect:* the requirements install with no errors.
2. **Install the plugin** as in [Install](#3-darktable-side) and start darktable. *Expect:* an **Assisted Culling** panel on the right in lighttable, with sections *1 scoring*, *2 bursts*, *3 penalties & speed*, *4 tags written*, *5 run* (with a **Cull selection** button) and *tools*, each under its own heading. No `LUA ERROR` in the darktable log.
3. **Set the plugins folder** in **preferences → lua options → plugins folder (holds the three assisted-* folders)** to the folder holding the repo, and leave the interpreter empty. *Expect:* runs find the repo's `.venv` without the interpreter preference.

**One run per grouping mechanism**

Use a selection with at least two bursts of 3+ frames each.

4. **Native groups.** Group each burst in darktable (ctrl+g), set **grouping support** to *Native groups*, and click **Cull selection**. *Expect:* one `Keeper` per burst (more if *keepers* allows), the rest `Rejected` or rated per *non-keepers*. The log at `%LOCALAPPDATA%\darktable\assisted_culling.log` shows `run started`, the `settings:` line, `group support native: N of M photos in groups of 2+` and `run finished`.
5. **Grouping tags, blank node.** Run Assisted Grouping with **Write group tags** on, then set **grouping support** to *Grouping tags*, leave the node blank, and cull. *Expect:* the same per-burst keepers as step 4. The `group support tags:` log line ends with `node Assisted Grouping|<stamp>|Group` (the newest run).
6. **Grouping tags, wrong node.** Type a node that doesn't exist on these photos and cull. *Expect:* every photo is judged alone, and the `group support tags:` log line ends with `(matches no selected photo)`.
7. **None.** Set **grouping support** to *None* and cull. *Expect:* every photo is judged alone; each frame can be a keeper.

**Panel**

8. **Cancel.** Start a run on a large selection and click the button while it shows **Cancel culling**. *Expect:* the run stops; frames already done keep their changes. Repeat with the X on the job in darktable's job area. *Expect:* the button shows **Cancelling...** until the run has stopped, then **Cull selection** again; a new run started straight after works normally.
9. **Why these ratings?** with nothing selected. *Expect:* "Assisted Culling: select some images first".
10. **Clear culling marks** on the selection. *Expect:* the plugin's tags are gone; star ratings are unchanged.
11. **Tag switches.** Cull a batch with every tag on and note the stars. Under **tags written** in the panel, turn off *Subject* and *Rejected*, then cull the same batch again. *Expect:* the stars and keepers are the same as before; no image in the batch has an `Assisted Culling|Subject|…` or `Assisted Culling|Rejected` tag; `Keeper`, the flags, `Technique`, `Scored` and `Why` are still there. Filter on `Assisted Culling|Why|Outranked`: every match is a non-keeper. Turn off *Why* and cull again: the `Why` tags are gone from the batch. No `LUA ERROR`.

## Development

### Tests

Run these from the repo root (the `darktable-assisted-culling` folder).

The pure-logic half of the plugin runs under any Lua 5.4:

```
cd lua && lua test_assisted_culling.lua
```

No `lua` binary handy? `pip install lupa` in the venv, then:

```
.venv/bin/python -c "import lupa; L=lupa.LuaRuntime(); L.execute('package.path=\"./lua/?.lua;\"..package.path; dofile(\"lua/test_assisted_culling.lua\")')"
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
   `rally-photos.txt` holds one file or folder per line; folders are read for their photos, and a RAW with a JPEG beside it counts once. Plain paths work in place of the `@list`.
3. Run the plugin with the settings under test.
4. Score it:
   ```
   python python/eval_culling.py @rally-photos.txt --truth rally-truth.csv --sharp-mode subject_focus
   ```
   Without `--truth` the sidecars are read directly, which only makes sense before the plugin has rated them. `--report PATH` points at a `last-run.csv` other than the one in darktable's config folder (an archived copy under `assisted_culling/reports/`, say). `--out FILE` also saves the text.

It prints, overall and per group, per sharpness mode and per motion class: the hit rate (your picks the plugin kept), false keepers (plugin keepers you didn't pick) and Spearman's rank correlation between your stars and its stars (rejected counts as -1; frames the run left alone are excluded and counted). A pick is a photo you rated 1 star or more and didn't reject; `--pick-stars 3` raises the bar. The sharpness mode per burst is the one you pass, corrected where the run's `Technique` tag shows a burst switched (see [Shooting intent from EXIF](#shooting-intent-from-exif)). Only report rows for the given photos count, so one `last-run.csv` can cover more than the shoot. A truth CSV can also be written by hand: columns `file` (name or path), `stars` (or `rating`, -1 for a reject) and optionally `rejected`.

Same inputs give the same output, so two runs with different settings are compared by diffing their `--out` files.

#### Letting it suggest settings

Instead of re-running the plugin per setting, `--suggest` replays the run's scores under every combination of ranking mode, keepers, keeper margin, star strictness and non-keepers (the panel's own choices) and prints the best few against your picks:

```
python python/eval_culling.py @rally-photos.txt --truth rally-truth.csv --sharp-mode subject_focus --suggest
```

Each suggestion shows its hit rate, false keepers and Spearman, then the preset as JSON: paste it into `assisted_culling/presets/<name>.json` (see [Presets](#presets)), or `--write-preset FILE` writes the first one (to a new file only). Nothing in the plugin changes on its own. `--top N` shows more than 5.

- It needs `--sharp-mode`, because the replay rates each burst with the tiers of the mode the run used. The sharpness mode and the tier tables are not searched: `star_scale` covers "stricter or looser stars", and a different sharpness mode means different scores, so that is a new run.
- One shoot overfits: the best settings for one rally are the ones that happen to fit that rally. Keep each run's `last-run.csv` and `--snapshot` CSV and add them with `--shoot REPORT TRUTH` (repeatable; all must be runs in the same `--sharp-mode`). Counts are pooled across shoots. With one shoot it says so.
- The replay reads the report, not the photos: it uses the same scores, bursts and shortlist. Frames the run could not read are not in the report, and tag-only flags are not either, so every flag it lists costs a star. The ranking is hit rate minus false-keeper rate, then Spearman; when two choices give the same numbers the panel's default wins.
- `python/rating.py` holds the keeper and star rules for both the plugin and the replay, so the two agree exactly.

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
- **Setting `img.rating` from Lua reloads the whole collection, once per image** (`src/lua/image.c`); tags and darktable's own rating action don't. So the final apply step sets ratings in batches: for each star value it selects that batch and fires the `views/thumbtable/rating` action, then restores your selection. The action rates darktable's *act-on* images (the hovered thumbnail, or the images shown in preview or culling layout), so the plugin checks `dt.gui.action_images` equals the batch first and rates one by one when it doesn't. "Apply ratings while scoring" keeps per-image writes, since changing the selection while you're working would get in the way.

## License

MIT, see [LICENSE](LICENSE).
