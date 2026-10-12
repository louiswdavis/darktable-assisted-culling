# darktable-assisted-culling

A culling assistant for [darktable](https://www.darktable.org/). Select a batch of images in lighttable, click one button, and it will:

- group your selection into **bursts** by capture time
- score every frame for **sharpness** and **exposure clipping**
- pick the sharpest frame in each burst as the **keeper**
- write the result back as a **star rating** plus **tags** under `Assisted Culling|…`

Everything runs locally: a Lua plugin inside darktable and a small Python/OpenCV scorer it shells out to. No API keys, no cloud, no daemon. Nothing is deleted and your colour labels are never touched. It only rates and tags; rejecting is still your call.

<!-- docs/lighttable.png: lighttable with the Assisted Culling panel and a scored burst -->

## Contents

- [Requirements](#requirements)
- [Install](#install)
- [Using it](#using-it)
- [Panel options](#panel-options)
- [Preferences](#preferences)
- [How it works](#how-it-works)
- [Tuning](#tuning)
- [Troubleshooting](#troubleshooting)
- [Limitations](#limitations)
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

### 2. darktable side

darktable's config directory is `~/.config/darktable` on Linux/macOS and `%LOCALAPPDATA%\darktable` on Windows. Link the plugin into it and load it from `luarc`.

Linux / macOS:

```
mkdir -p ~/.config/darktable/lua/contrib
ln -s "$(pwd)/lua/culling.lua" ~/.config/darktable/lua/contrib/culling.lua
echo 'require "contrib/culling"' >> ~/.config/darktable/luarc
```

Windows (Command Prompt). Creating symbolic links needs an Administrator prompt unless Developer Mode is enabled.

```
if not exist "%LOCALAPPDATA%\darktable\lua\contrib" mkdir "%LOCALAPPDATA%\darktable\lua\contrib"
mklink "%LOCALAPPDATA%\darktable\lua\contrib\culling.lua" "%CD%\lua\culling.lua"
echo require "contrib/culling" >> "%LOCALAPPDATA%\darktable\luarc"
```

Windows (PowerShell). Same Administrator caveat.

```
New-Item -ItemType Directory -Force "$env:LOCALAPPDATA\darktable\lua\contrib"
New-Item -ItemType SymbolicLink -Path "$env:LOCALAPPDATA\darktable\lua\contrib\culling.lua" -Value "$PWD\lua\culling.lua"
Add-Content "$env:LOCALAPPDATA\darktable\luarc" 'require "contrib/culling"'
```

### 3. Point the plugin at Python

Start darktable, open **preferences → lua options**, and set:

- **Assisted Culling: python interpreter**: the venv's `python.exe` / `bin/python`
- **Assisted Culling: score_images.py**: `python/score_images.py` from this repo, or leave it empty and keep `score_images.py` next to `culling.lua`

The other preferences are optional; see [Preferences](#preferences).

### 4. Optional: AI models

Only needed for the *subject tracking (SAM)* sharpness mode. Every other mode works without them.

1. **SAM mask model** (needs darktable 5.6+). In darktable, open **preferences → AI**, then enable and download a SAM or SAM 2 mask model. darktable stores and manages it, and the plugin uses whichever mask model is enabled there. SegNext mask models aren't supported; if one is enabled, the run stops and says so.
2. **Vehicle detector** (optional, for motorsport). Download [`object_detection_yolox_2022nov.onnx`](https://github.com/opencv/opencv_zoo/raw/main/models/object_detection_yolox/object_detection_yolox_2022nov.onnx) (36 MB, Apache-2.0), ideally into a `models` folder in the repo, then set **Assisted Culling: object detector model (YOLOX .onnx)** in preferences → lua options to that file. See [Vehicle detector](#vehicle-detector) for what it does.

## Using it

In lighttable, select a batch (a whole shoot or a single burst) and click **Start Culling** in the **Assisted Culling** panel on the right. Progress shows in darktable's message area; click the button again to cancel.

### What you get

Each frame gets a star rating, which ranks it against the rest of the batch, plus any of these tags:

| Tag | Meaning |
|-----|---------|
| `Assisted Culling\|Keeper` | The best frame (or frames) of its burst |
| `Assisted Culling\|Rejected` | Lost to a sharper frame from the same burst; rated per the *non-keepers* option |
| `Assisted Culling\|Overexposed` | Blown highlights |
| `Assisted Culling\|Underexposed` | Crushed shadows |
| `Assisted Culling\|Eyes Closed` | *face & eyes* mode only: a face big enough to judge, with no open eyes found. Dark sunglasses trigger it too. |

With the *diagnostic tags* preference on (the default), frames are also tagged with how they were judged, so you can spot-check the scorer:

| Tag | Meaning |
|-----|---------|
| `Assisted Culling\|Subject\|Vehicle\|Car` (or `Motorcycle`, `Truck`) | *subject tracking (SAM)* with the [vehicle detector](#vehicle-detector): the vehicle SAM was pointed at |
| `Assisted Culling\|Subject\|Vehicle\|Guessed` | The detector found no vehicle, so SAM was given the guessed subject point. Worth a look: the guess can land on a kerb or sponsor board. |
| `Assisted Culling\|Scored\|Masked` | *subject tracking (SAM)*: the burst was ranked on SAM masks |
| `Assisted Culling\|Scored\|Subject bias` | *subject tracking (SAM)*: a shortlisted frame got no mask, so the burst fell back to *subject bias* |
| `Assisted Culling\|Technique\|Panning` / `…\|Shallow DoF` | The burst's EXIF switched its sharpness mode (see [shooting intent](#shooting-intent-from-exif)) |

`Subject` is grouped by kind (`Vehicle` today), leaving room for other detectors later. Turning the preference off removes these tags on the next run.

Filter on these in darktable's **collections** module (tag → Assisted Culling) to step through just the keepers, or just the rejects. The parent `Assisted Culling` tag collects everything the plugin has scored.

### Flags cost stars, never the keeper

Overexposed, Underexposed and Eyes Closed each take one star off. They never decide which frame is kept; that's sharpness alone.

Two safeguards keep deliberate shots from being punished:

- **Shared by the whole burst = no penalty.** If every frame in a burst is flagged the same way, it was most likely shot that way (a dark tunnel exit, say), so each frame keeps the tag but not the lost star.
- **Per-flag switch.** For styles where a flag is the point (low-key, high-key), turn off *"Assisted Culling: … lowers stars"* for that flag in preferences → Lua options. Frames are still tagged; the stars are left alone.

### Re-running and clearing

Re-running is safe: every tag is re-synced to the new result, so a frame that was a keeper last pass and isn't now loses its `Keeper` tag. It does overwrite star ratings, including ones you set by hand.

To protect a frame, tag it `Assisted Culling|Locked` yourself (create the tag in the **tagging** module). Runs then leave it out entirely: its stars and tags stay as they are, and it doesn't take a keeper slot in its burst, so another frame from that burst can be kept as well. The done message counts the locked frames it left alone.

**Clear culling marks** removes all the plugin's tags from the selection without touching star ratings. It still clears `Keeper`/`Rejected`/flag tags on locked frames, but never removes `Locked` itself. Colour labels are never read or written, so any you apply by hand are yours.

Older versions used red/yellow colour labels and a `Culled` tag. The tag comes off the next time an image is re-scored (or with **Clear culling marks**); the labels stay. To remove them once, collect by the `Assisted Culling` tag, select all, and toggle the labels off.

## Panel options

### Preset

*landscape*, *portrait*, *sport* and *macro* set four of the options below in one click. *custom* is selected automatically the moment you change any of them by hand. Presets never change *non-keepers*.

| Preset | Ranking mode | Sharpness | Exposure | Keepers |
|--------|--------------|-----------|----------|---------|
| landscape | universal absolute | edge-to-edge uniformity | strict histogram | single best only |
| portrait | universal absolute | face & eyes (OpenCV) | subject only (ignore sky) | portrait (1 or 2) |
| sport | universal absolute | subject bias (center-weighted) | whole frame | dynamic (1 to 5) |
| macro | universal absolute | absolute peak 1% | whole frame | keep all (focus stack) |

*sport* uses *subject bias* because it works everywhere. If you've set up SAM, switch sharpness to *subject tracking (SAM)* for motorsport.

### Ranking mode

- *universal absolute*: every frame is rated against fixed sharpness tiers.
- *relative batch percentile*: keepers get top stars and everything else none, scored against the rest of its own burst.

### Sharpness

How each frame's focus is measured.

- *center crop*: Laplacian variance over the middle 50% of the frame.
- *edge-to-edge uniformity*: splits the frame into a 3×3 grid and scores the weakest third of it, so one soft corner (camera shake, tilted focus, a soft lens edge) costs the frame. Plain areas like clear sky are left out, judged on their large-scale tones, which blur doesn't change. Meant for frames that should be sharp corner to corner (landscapes, architecture). Because it scores the weakest areas, its numbers run lower than the other modes', so expect fewer stars from *universal* ranking; *relative* ranking isn't affected.
- *absolute peak 1%*: the sharpest 1% of edges in the whole frame.
- *face & eyes (OpenCV)*: detects the largest face with OpenCV's Haar cascades and scores sharpness over the eyes if found, the whole face box otherwise. Falls back to *subject bias* when no face is detected. Eyes are searched in the upper face, retrying with the glasses-aware cascade; a face at least 120 px wide with no eyes found is tagged *Eyes Closed*. Needs OpenCV 4.x: OpenCV 5 removed the Haar detector, and the scorer stops with an install hint if it finds 5.
- *subject bias (center-weighted)*: a 3×3 grid scored on its sharpest patch, with the center patches counting more, on the assumption the subject is mid-frame. A classical heuristic, not AI.
- *subject tracking (SAM)*: masks the subject with darktable's own AI mask model and scores sharpness only inside the mask. See below.

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

   Re-cloning the repo deletes it. If you do that often, keep it next to the score cache instead (`assisted_culling` in darktable's config directory).
2. Set **Assisted Culling: object detector model** in preferences → Lua options to the file's full path, e.g. `C:\Users\you\darktable-assisted-culling\models\object_detection_yolox_2022nov.onnx`.

On each shortlisted frame, YOLOX finds cars, motorcycles and trucks (race cars are often labelled as trucks). The most prominent one, scored by confidence × size, becomes SAM's prompt, so a car filling a third of the frame beats a small one in the background. A frame with no vehicle (a crowd shot, a pit board) uses the point guess as before.

It runs on the CPU and adds about a tenth of a second per frame. If the file is missing or isn't a model, the run stops and says so. Leave the preference empty to switch it off.

### Exposure

- *whole frame*: checks the whole frame for clipping.
- *subject only (ignore sky)*: drops the top 20% of the frame before checking.
- *strict histogram*: tighter clipping thresholds.
- *ignore exposure*: no exposure flags.

### Keepers

How many frames per burst survive: *single best only*, *portrait (1 or 2)*, *dynamic (1 to 5)* (scales with burst size), or *keep all (focus stack)* for frames you'll merge rather than cull.

### Non-keepers

What happens to the frames that aren't kept: *leave alone*, *reject (-1)*, or a fixed star count from 0 to 5. They always get the `Rejected` tag regardless.

## Preferences

All under **preferences → lua options**.

| Preference | Default | What it does |
|------------|---------|--------------|
| Assisted Culling: python interpreter | empty | Python with the requirements installed |
| Assisted Culling: score_images.py | empty (auto-detect) | Path to the scorer |
| Assisted Culling: object detector model (YOLOX .onnx) | empty (off) | Enables the [vehicle detector](#vehicle-detector) in SAM mode |
| Assisted Culling: apply ratings while scoring | off | Applies results as they arrive instead of all at the end. Faster on big batches, but darktable's UI shares the CPU with the scorer; turn off if it lags. |
| Assisted Culling: fast JPEG decoding | on | Decodes JPEGs and raw previews at reduced size. Several times faster; scores shift slightly, which matters little since keepers are ranked within each burst. |
| Assisted Culling: burst gap (seconds) | 2 | Photos taken closer together than this are one burst. 2 s suits continuous-drive bursts; for deliberate re-takes on a phone, 5 s fits better. |
| Assisted Culling: diagnostic tags | on | Tags how each frame was judged (`Subject`, `Technique`, `Scored`); see [What you get](#what-you-get). Each tag write reloads darktable's collection, so turn off to speed up applying results. |
| Assisted Culling: *Tag* lowers stars | on, one per flag | Off = that flag is still tagged but never costs stars. See [Flags cost stars](#flags-cost-stars-never-the-keeper). |

## How it works

```
you select images in lighttable
        |
        v
culling.lua groups the selection into bursts by EXIF capture time
        |
        v
culling.lua writes manifest.csv (id, filepath, burst_id, …, shutter, aperture) and runs score_images.py
        |
        v
score_images.py scores sharpness and exposure, picks the keepers per burst, writes results.csv
        |
        v
culling.lua reads results.csv and applies ratings and tags
```

Two small processes talking through CSV files. The Lua side is split into pure logic (time parsing, clustering, CSV) with no darktable dependency, and the darktable integration proper; only the second half needs darktable to run.

### Scoring

Sharpness is the variance of the Laplacian of a downscaled grayscale copy, a standard and cheap focus proxy. Raw variance isn't comparable across cameras, lenses or ISOs, so frames are ranked against the rest of *this* batch and the percentile drives the star rating. Exposure is flagged when more than 2% of pixels are crushed or blown. Within a burst the highest sharpness wins; the others are tagged `Rejected` and rated per the non-keepers setting.

### Why group by time

An earlier version grouped frames by perceptual image hashing. That technique is built to spot near-identical copies of a file, which isn't the same problem as "different frames of the same burst", where subject or focus genuinely changed between shots, and the results were inconsistent. darktable already gives Lua scripts each image's `exif_datetime_taken`, and clustering on capture-time proximity (the same approach the community's `AutoGrouper.lua` uses) is simpler and far more reliable.

### How the SAM mode fits together

`darktable.ai` is a generic ONNX runtime for Lua (`load_model` / `ctx:run`, plus a model registry keyed by task: `denoise`, `upscale`, `mask`). The `mask` model is SAM, which needs a prompt; darktable's darkroom object-mask tool supplies one with a click, and there's no "find the subject" task. And `darktable.ai` only runs inside darktable's Lua process, while scoring happens in the separate Python process. So this mode runs in three stages instead of two:

1. **Shortlist and prompt** (Python). `score_images.py --emit-saliency-points --keep-mode … [--detector yolox.onnx]` shortlists each burst and writes one prompt per shortlisted frame as `id,x0,y0,x1,y1,cached` in frame fractions. A vehicle box fills all four; a salient point leaves `x1,y1` empty. `cached` is `1` when that frame's masked score is already in the score cache.
2. **Mask** (Lua). The plugin runs SAM on each prompt that isn't cached and writes a mask PNG. A box goes to SAM as two corner points labelled 2 and 3, the encoding darktable's `dt_seg_point_t` documents.
3. **Score** (Python). The scorer reads the mask path, shortlist flag and darktable edit time from the 4th, 5th and 6th manifest columns. Every mode gets shutter and aperture in the 7th and 8th.

### Score cache

Decoding and scoring is the slow part of a run, so per-frame scores are saved in `assisted_culling/scores.sqlite` inside darktable's config directory (e.g. `~/.config/darktable` on Linux and macOS). Re-running the same shoot with only a different ranking mode, keeper count, non-keeper option, burst gap or "… lowers stars" preference then skips decoding and re-applies in seconds.

A cached score is only reused when everything that produced it is the same:

| Changes the score (new entry) | Only uses the score (reused) |
|-------------------------------|------------------------------|
| the file itself (path, modified time, size) | ranking mode |
| sharpness mode, as adjusted by [shooting intent](#shooting-intent-from-exif) | keepers, non-keepers |
| exposure mode | burst gap |
| fast JPEG decode | the per-flag "… lowers stars" preferences |
| SAM mode: the mask model, the vehicle detector file, the prompt, and your last darktable edit of the frame | |

In SAM mode, raising the keeper count or changing the burst gap can put new frames on a burst's shortlist; only those get a SAM pass. An edit in darktable (crop, rotate, lens correction) changes what SAM sees, so it re-runs SAM for that frame next time.

Entries not used for 90 days are deleted at the start of a run. To start over, delete the file.

EXIF can't supply the prompt instead: darktable exposes focus *distance*, not the AF point's position.

## Tuning

Everything you'd change per shoot is a panel option or a preference. What's left is a named constant at the top of the file that uses it:

- `culling.lua`: `BURST_GAP_SECONDS` (default 2) is the burst gap used when the preference isn't available, e.g. headless runs. On a 14-frame hand-held phone series (frames 4–50 s apart) 2 s grouped nothing, while 5 s clustered three pairs and picked the sharper frame each time.
- `culling.lua`: `STAGE2_BATCH_WRITE_BUDGET` (60 tag writes) and `STAGE2_BATCH_LINES` (200 results) size each slice of the final apply step before it yields to the GUI. Lower them if darktable stutters while ratings apply.
- `score_images.py`:
  - `SHADOW_CLIP`, `HIGHLIGHT_CLIP` and `CLIP_PCT_FLAG` control exposure flagging.
  - `STAR_THRESHOLDS` (relative mode) and `TIER_THRESHOLDS` (universal mode) turn sharpness into stars.
  - `FLAG_PENALTIES` sets what each flag costs: points off the relative score (15 points is one star) and stars off in universal mode.
  - `BLINK_MIN_FACE_PX` is the smallest face width judged for closed eyes.
  - `DETECTOR_MIN_SCORE` is the confidence a vehicle detection needs.
  - `PANNING_SHUTTER` (1/125 s) and `SHALLOW_DOF_APERTURE` (f/4) are the [shooting intent](#shooting-intent-from-exif) cutoffs.
  - `SCORE_CACHE_MAX_AGE_DAYS` (default 90) is how long an unused cache entry is kept.
  - `SCORE_CACHE_VERSION`: bump it after changing any of the constants above that feed a score (clip levels, `MAX_DIM`, `BLINK_MIN_FACE_PX`, `DETECTOR_MIN_SCORE`, …) or the scoring code, so old cached scores aren't reused. Star and penalty tables don't need a bump, and neither do the shooting-intent cutoffs: they only pick which mode a burst uses, and the mode is already part of the cache key.

These are sensible starting points, not tuned defaults. Run a real shoot through it, see what gets flagged, and adjust.

## Troubleshooting

- **The panel isn't there.** Start darktable with `-d lua` and look for `LUA ERROR` in the log. On Windows the log is `Documents\Darktable\darktable-log.txt`.
- **Every run writes a log** to `assisted_culling.log` in darktable's config directory (e.g. `%LOCALAPPDATA%\darktable` on Windows); the run before it is kept as `assisted_culling.prev.log`. It has the settings, the scorer commands, every message shown on screen, each burst's shortlist, sharpness mode and keepers, and in SAM mode one line per segmented frame with its prompt and the exact error if SAM failed on it. Start here when a result looks wrong.
- **"no results" or "scorer produced no ratings".** The scorer failed; its output is at the end of the run log. The usual cause is the interpreter preference pointing at a Python without the requirements installed.
- **"SAM masked 0 of N shortlisted frames".** Look for the `SAM … failed:` lines in the run log for the error on each frame.
- **"score cache … is unreadable".** The cache file is damaged. Delete `assisted_culling/scores.sqlite` in darktable's config directory; the next run rebuilds it.
- **Scores look stale after changing a constant in `score_images.py`.** Bump `SCORE_CACHE_VERSION` (see Tuning), or delete the cache file.
- **darktable itself crashes on startup on Windows 11** (`0xC0000005`). darktable's Windows binaries are unsigned, and Smart App Control blocks unsigned DLLs that haven't built up reputation; it blocked `libdarkroom.dll` from 5.6.1 on a test machine. Check the `Microsoft-Windows-CodeIntegrity/Operational` event log for event 3077. Don't turn Smart App Control off (it's a one-way switch). An older release passes: `winget install --id darktable.darktable --version 5.4.1` ran with no blocks, and this plugin needs nothing newer.

## Limitations

- Apart from *subject tracking (SAM)* and *face & eyes* (when a face is found), every sharpness mode is a classical whole-frame or patch-grid heuristic. A frame with a sharp background and a soft subject can outscore the frame you'd actually keep.
- The SAM preprocessing (1024 px input, normalisation, prompt format) mirrors darktable's own `src/common/ai/segmentation.c` defaults, because `darktable.ai` doesn't expose a model's attributes to Lua. A mask model with a non-default input size would segment poorly; every image then falls back to *subject bias*, and the plugin reports how many did.
- SAM sees each image through darktable's pipeline (rotated, cropped, lens-corrected), while the scorer reads the original file, turned upright from its EXIF orientation. A darkroom crop that changes the aspect ratio is detected and that image falls back; a crop that keeps the ratio isn't, so on cropped edits the mask can sit off the subject. Cull before you crop.
- The vehicle detector sees the same downscaled copy as the scorer (800 px on the long side), so a very small, distant car can be missed. That frame then uses the point guess.

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

### Running the scorer on its own

The scorer runs standalone against any folder of images, no darktable involved. `manifest.csv` is `id,filepath,burst_id` per line:

```
python python/score_images.py manifest.csv results.csv
```

### End-to-end without the GUI

The darktable half can be exercised headlessly through `darktable-cli`, which initialises Lua and honours `--luacmd`. `tools/e2e_cli.lua` imports a folder, runs the plugin on it, and writes a TSV of the rating and `Assisted Culling` tags darktable holds for each image afterwards, which is the plugin's entire observable output:

```
set DT_AI_CULL_FOLDER=C:/path/to/photos
set DT_AI_CULL_REPORT=C:/path/to/report.tsv
set DT_AI_CULL_GAP=5                     # optional BURST_GAP_SECONDS override
darktable-cli.exe any.jpg out.jpg --core --library "%LOCALAPPDATA%\darktable\library.db" -d lua --luacmd "dofile([[C:/path/to/tools/e2e_cli.lua]])"
```

Results land in the real library, so they show up in lighttable later. The script's header documents the two `darktable-cli` quirks it works around.

### Notes from the darktable source

Things that cost time to find out, recorded so they don't again:

- **`register_lib` takes eight positional arguments**: `(plugin_name, name, expandable, resetable, containers, widget, view_enter, view_leave)`. Leaving out `resetable` shifts the container table into a boolean slot and the panel never registers.
- **Registering a lib straight from `luarc` is a startup race.** darktable can report lighttable as the current view before the view has finished initialising, and a lib registered in that window is silently never attached (`src/views/view.c` documents it; the lua-scripts hit it as #19197). The plugin installs its panel from the `view-changed` event into lighttable instead, which fires only once the view is fully up.
- **`darktable-cli` never runs your `luarc`.** Since 5.6 the user `luarc` is loaded by `script_manager` (GUI only); before that the C code only loaded it when a GUI existed. `--luacmd` still runs, and it's the way to test headlessly. Anything GTK-wrapped (`register_lib`, `preferences.register`) blocks forever headless, so the plugin gates those on `dt.gui`.
- **`dt.control.execute` releases the Lua lock** while the child runs. That keeps the GUI responsive, but headless it lets `darktable-cli` tear Lua down mid-run once its export finishes, so without a GUI the plugin uses plain `os.execute` and holds the lock.
- **`group_with` first removes the image from its current group**, and removing a *leader* hands its group to another member. The plugin no longer stacks bursts with darktable's image grouping (bursts are a scoring concept only, tracked by capture time), but if that's ever added back: on a re-run over already-grouped images, attaching to a leader that still sits in an old group scatters the burst, so detach each keeper into a fresh group before attaching its burst-mates.
- **Windows shell-outs go through a `.bat` file**, following `lib/dtutils/system.lua` in darktable's lua-scripts: cmd.exe mangles a command line with more than one quoted item. In that file, write the exit code with the redirect first (`> "f" echo %ERRORLEVEL%`): `echo 0> "f"` reads as "redirect handle 0" and leaves `f` empty.
- **Setting `img.rating` from Lua reloads the whole collection, once per image** (`src/lua/image.c`); tags and darktable's own rating action don't. So the final apply step sets ratings in batches: for each star value it selects that batch and fires the `views/thumbtable/rating` action, then restores your selection. The action rates darktable's *act-on* images (the hovered thumbnail, or the images shown in preview or culling layout), so the plugin checks `dt.gui.action_images` equals the batch first and rates one by one when it doesn't. "Apply ratings while scoring" keeps per-image writes, since changing the selection while you're working would get in the way.

## License

MIT, see [LICENSE](LICENSE).
