# darktable-assisted-culling

A culling assistant for [darktable](https://www.darktable.org/). Select a batch of images in lighttable, click one button, and it will:

- group your selection into **Bursts** using the groups you already made (darktable's own groups or [Assisted Grouping](../darktable-assisted-grouping/README.md) tags)
- score every frame for **Sharpness** and **exposure clipping**
- pick the sharpest frame in each burst as the **keeper**
- write the result back as a **star rating** plus **tags** under `Assisted Culling|…`

Everything runs locally: a Lua plugin inside darktable and a small Python/OpenCV scorer it shells out to. No API keys, no cloud, no daemon. Nothing is deleted and your colour labels are never touched. It only rates and tags: a reject is a -1 rating on a far-behind or blank frame, and the file stays in your library.

<!-- docs/lighttable.png: lighttable with the Assisted Culling panel and a scored burst -->

## Contents

- [Requirements](#requirements)
- [Install](#install)
- [Documentation](#documentation)
- [Troubleshooting](#troubleshooting)
- [Limitations](#limitations)

## Requirements

- darktable 5.4 or newer, built with Lua (the official builds are). The *subject tracking (SAM)* sharpness mode needs 5.6+ with an AI mask model downloaded.
- Python 3.10+ with `opencv-python-headless` (4.x; `requirements.txt` pins `<5`), `numpy`, `Pillow`, `rawpy` and `onnxruntime` (only the D-FINE / RT-DETR detectors and the sharpness judge use it).
- Windows: `git` and `curl` (Windows 10+ ships `curl`). Linking the plugin needs Developer Mode on (`Win + R`, then `ms-settings:developers`) or an Administrator prompt; without either, copy the files instead (step 2).

`rawpy` needs `libraw`. The Windows and macOS wheels bundle it; on Linux install `libraw-dev` first, or skip `rawpy` if you only shoot JPEG. It's imported lazily, only when a raw file shows up.

## Install

Do the steps in order: Python, darktable, plugins folder, models.
Commands come first under each step; the reasons follow them.

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

Run the block for your system from the repo root, the folder holding `README.md`. It puts the plugin's two files into darktable's `lua/contrib` folder and appends `lua/assisted_culling.luarc`, this plugin's own few lines, to `luarc`. Each plugin adds only its own line, and the last line of each block skips it when `luarc` already has one for this plugin, so running a block twice, or running one from each plugin's repo, adds nothing twice.

Linux / macOS (links):

```
mkdir -p ~/.config/darktable/lua/contrib
ln -sf "$(pwd)/lua/assisted_culling.lua" ~/.config/darktable/lua/contrib/assisted_culling.lua
ln -sf "$(pwd)/lua/plugin_common.lua" ~/.config/darktable/lua/contrib/plugin_common.lua
grep -qs 'contrib/assisted_culling' ~/.config/darktable/luarc || cat lua/assisted_culling.luarc >> ~/.config/darktable/luarc
```

Windows (Command Prompt, copies; no Administrator or Developer Mode needed, re-run after every update):

```
if not exist "%LOCALAPPDATA%\darktable\lua\contrib" mkdir "%LOCALAPPDATA%\darktable\lua\contrib"
copy /Y lua\assisted_culling.lua "%LOCALAPPDATA%\darktable\lua\contrib\"
copy /Y lua\plugin_common.lua "%LOCALAPPDATA%\darktable\lua\contrib\"
findstr /C:"contrib/assisted_culling" "%LOCALAPPDATA%\darktable\luarc" >nul 2>&1 || type lua\assisted_culling.luarc >> "%LOCALAPPDATA%\darktable\luarc"
```

Windows (Command Prompt, links; needs Developer Mode on, `Win + R` then `ms-settings:developers`, or an Administrator prompt; links follow the repo, so no re-run after an update):

```
if not exist "%LOCALAPPDATA%\darktable\lua\contrib" mkdir "%LOCALAPPDATA%\darktable\lua\contrib"
del "%LOCALAPPDATA%\darktable\lua\contrib\assisted_culling.lua" "%LOCALAPPDATA%\darktable\lua\contrib\plugin_common.lua" 2>nul
mklink "%LOCALAPPDATA%\darktable\lua\contrib\assisted_culling.lua" "%CD%\lua\assisted_culling.lua"
mklink "%LOCALAPPDATA%\darktable\lua\contrib\plugin_common.lua" "%CD%\lua\plugin_common.lua"
findstr /C:"contrib/assisted_culling" "%LOCALAPPDATA%\darktable\luarc" >nul 2>&1 || type lua\assisted_culling.luarc >> "%LOCALAPPDATA%\darktable\luarc"
```

Then restart darktable and open `dt-lua-errors.txt` in the config directory (`~/.config/darktable` on Linux/macOS, `%LOCALAPPDATA%\darktable` on Windows). `assisted_culling loaded` means it worked: the panel appears in lighttable once the view has finished loading. `assisted_culling FAILED ...` gives the reason.

**Why these steps.**

- The plugin is two files, and both must sit in `lua/contrib`: `lua/assisted_culling.lua` and `lua/plugin_common.lua`. `plugin_common.lua` is the module the three Assisted plugins share. The three copies are identical, so each plugin's block overwrites the same file harmlessly.
- Without `plugin_common.lua` the plugin fails with `module 'plugin_common' not found`. It has no `luarc` line of its own: the plugin loads it with `loadfile`, looking beside itself first, then in the **plugins folder** preference. Nothing copies it for you, and on a new device the preference does not exist yet (it is registered only after the plugin loads), so put it in `lua/contrib`.
- `lua/assisted_culling.luarc` is a short readable snippet kept in the repo, so each block just appends it and `luarc` shows the plugin on separate lines. It loads the plugin inside `pcall` and appends `loaded` or `FAILED <reason>` to `dt-lua-errors.txt`, so a plugin that does not appear says why. The skip test looks for the text `contrib/assisted_culling` in `luarc`. If your `luarc` already loads this plugin another way, such as a loop that builds the name, the test does not see it: skip the last line of the block.
- Keep `require "tools/script_manager"` (the scripts panel, from the separate `lua-scripts` repo) on the first line of `luarc`. If the scripts panel is missing, remove the Assisted lines, restart, and add them back one at a time; `dt-lua-errors.txt` shows which one fails.
- Copies must be re-made after every update; links follow the repo.

### 3. Point the plugin at the repo

Start darktable, open **preferences → lua options**, and set **plugins folder (holds the three assisted-* folders)** to the folder that holds `darktable-assisted-culling` (and the other assisted plugins). `python/score_images.py`, `models/` and `.venv` are found inside `darktable-assisted-culling`. A folder whose `darktable-assisted-culling` has no `python/score_images.py` is an error. The preference is shared by the assisted plugins; the older per-plugin **Assisted Culling: Plugin folder** preference still works, and the log says once to move it.

There is no interpreter preference: the plugin runs its own `.venv` (else `python`/`python3` on `PATH`), because each assisted plugin has different requirements. On Windows it runs the `pythonw.exe` beside the venv's `python.exe` through `python/launch.py`, so no console window opens and no `.vbs`/`.bat` is written (antivirus behaviour checks such as Bitdefender Advanced Threat Defense flag that chain).

Every other setting lives in the panel and is saved with its [preset](docs/panel-options.md#presets).

### 4. Models

**Recommended** (about 360 MB). Run from the repo root, the folder holding `README.md`, not `python/` (Windows 10+ ships `curl`; `--create-dirs` makes `models/`). Then `pip install -r` again, as in [Python side](#1-python-side), for `onnxruntime`:

```
curl -L --create-dirs -o models/dfine_x_coco.onnx https://huggingface.co/onnx-community/dfine_x_coco-ONNX/resolve/main/onnx/model.onnx
curl -L --create-dirs -o models/hyperiqa_model.onnx https://huggingface.co/86Cao/IQA-ONNX-Models/resolve/main/hyperiqa_model.onnx
curl -L --create-dirs -o models/hyperiqa_model.onnx.data https://huggingface.co/86Cao/IQA-ONNX-Models/resolve/main/hyperiqa_model.onnx.data
```

**Which models culling uses.**

Every model is optional: culling scores without any. There are three jobs, and these are all the models culling uses:

| Job | Used by | Where it lives |
|---|---|---|
| Subject mask (SAM) | the *subject tracking (SAM)* sharpness mode | managed by darktable (below) |
| Vehicle detector | motorsport: SAM's prompt box, *motion-aware* sharpness, burst direction | `models/` in this repo |
| Sharpness judge (HyperIQA) | **Break Close Calls with the Sharpness Judge** only | `models/` in this repo |

`models/` sits next to the venv; `.gitignore` skips the whole folder, so `git pull` leaves it alone. Re-cloning the repo deletes it.


Not in the block on purpose: the other five detectors (`dfine_l`, `rtdetr_v2`, `dfine_m`, `dfine_s`, YOLOX). They're smaller, faster or older steps below D-FINE-X, and the plugin falls back to them only when D-FINE-X isn't installed. Their downloads are in the table below.

Already have the tagging plugin's models? Copy its detector file into this `models` folder instead: the same file shares tagging's detection cache, so frames tagging already detected aren't detected again.

**Subject mask (SAM)** (darktable 5.6+). In darktable, open **preferences → AI**, then enable and download a SAM or SAM 2 mask model. darktable stores and manages it, and the plugin uses whichever mask model is enabled there. SegNext mask models aren't supported; if one is enabled, the run stops and says so.

**Vehicle detector.** The plugin uses the first of these in `models/`, best first, the same order as the tagging plugin. YOLOX runs on OpenCV; the rest need `onnxruntime`. See [Vehicle detector](docs/panel-options.md#vehicle-detector) for what it does.

| File | Size | Download | Notes |
|---|---|---|---|
| `dfine_x_coco.onnx` | 251 MB | `https://huggingface.co/onnx-community/dfine_x_coco-ONNX/resolve/main/onnx/model.onnx` | D-FINE-X, Apache-2.0. Best; in Recommended. |
| `dfine_l_coco.onnx` | 125 MB | `https://huggingface.co/onnx-community/dfine_l_coco-ONNX/resolve/main/onnx/model.onnx` | D-FINE-L, Apache-2.0 |
| `rtdetr_v2_r50vd.onnx` | 172 MB | `https://huggingface.co/onnx-community/rtdetr_v2_r50vd-ONNX/resolve/main/onnx/model.onnx` | RT-DETRv2 R50, Apache-2.0 |
| `dfine_m_coco.onnx` | 79 MB | `https://huggingface.co/onnx-community/dfine_m_coco-ONNX/resolve/main/onnx/model.onnx` | D-FINE-M, Apache-2.0 |
| `dfine_s_coco.onnx` | 42 MB | `https://huggingface.co/onnx-community/dfine_s_coco-ONNX/resolve/main/onnx/model.onnx` | D-FINE-S, Apache-2.0 |
| `object_detection_yolox_2022nov.onnx` | 36 MB | `https://github.com/opencv/opencv_zoo/raw/main/models/object_detection_yolox/object_detection_yolox_2022nov.onnx` | YOLOX, Apache-2.0, OpenCV's model zoo. Fastest, misses more cars. |

**Sharpness judge.** Both files, from [86Cao/IQA-ONNX-Models](https://huggingface.co/86Cao/IQA-ONNX-Models) (Apache-2.0). Keep both names: the model looks for the `.data` file by name. Needs `onnxruntime`.

| File | Size | Download |
|---|---|---|
| `hyperiqa_model.onnx` | 0.4 MB | `https://huggingface.co/86Cao/IQA-ONNX-Models/resolve/main/hyperiqa_model.onnx` |
| `hyperiqa_model.onnx.data` | 109 MB | `https://huggingface.co/86Cao/IQA-ONNX-Models/resolve/main/hyperiqa_model.onnx.data` |

**Check what's installed.** Each file must be named exactly as above (curl's `-o` does that; a browser download saves `model.onnx`). The run log names the detector it picked, plus any better file you haven't installed, e.g. `vehicle detector: object_detection_yolox_2022nov.onnx (better, not installed: dfine_x_coco.onnx, …)`. A run with the judge setting on and its files missing stops and says so.

**curl says `client returned ERROR on write` (error 23)?** curl got the data but couldn't save it. It isn't because the file already exists: curl overwrites. Either `models/` doesn't exist where you ran it (run from the repo root, or add `--create-dirs` as above), or the file is in use (close darktable, or wait for a run to finish, then retry).

## Documentation

- [Using it](docs/usage.md): What you get, how flags cost stars, re-running and clearing.
- [Panel options](docs/panel-options.md): Presets, every panel setting, and the preferences.
- [How it works and tuning](docs/how-it-works.md): Scoring, grouping support, the SAM mode, the score cache, and the tuning constants.
- [Testing and development](docs/testing.md): The Windows acceptance checklist, the tests, the scorer on its own and scoring against your picks.

## Troubleshooting

- **The panel isn't there.** Start darktable with `-d lua` and look for `LUA ERROR` in the log. On Windows the log is `Documents\Darktable\darktable-log.txt`.
- **Every run writes a log** to `assisted_culling.log` in darktable's config directory (e.g. `%LOCALAPPDATA%\darktable` on Windows); the 5 runs before it are kept as `assisted_culling.prev.log` (the last one), `assisted_culling.prev2.log` … `assisted_culling.prev5.log`. Each line is written as it happens, so a crash leaves the last step in the file; each stage logs `started` and `done` with its seconds, and a failed write names its image. It has the settings, the scorer commands, every message shown on screen, each burst's shortlist, sharpness mode and keepers, and in SAM mode one line per segmented frame with its prompt and the exact error if SAM failed on it. Start here when a result looks wrong.
- **"no results" or "scorer produced no ratings".** The scorer failed; its output is at the end of the run log. The usual cause is a `darktable-assisted-culling/.venv` without `python/requirements.txt` installed.
- **"SAM masked 0 of N shortlisted frames".** Look for the `SAM … failed:` lines in the run log for the error on each frame.
- **"score cache … is unreadable".** The cache file is damaged. Delete `assisted_culling/scores.sqlite` in darktable's config directory; the next run rebuilds it.
- **Scores look stale after editing `score_images.py`.** A constant change re-scores by itself (see Tuning); a code-only change doesn't. Delete the cache file.
- **darktable itself crashes on startup on Windows 11** (`0xC0000005`). darktable's Windows binaries are unsigned, and Smart App Control blocks unsigned DLLs that haven't built up reputation; it blocked `libdarkroom.dll` from 5.6.1 on a test machine. Check the `Microsoft-Windows-CodeIntegrity/Operational` event log for event 3077. Don't turn Smart App Control off (it's a one-way switch). An older release passes: `winget install --id darktable.darktable --version 5.4.1` ran with no blocks, and this plugin needs nothing newer.

## Limitations

- Apart from *subject tracking (SAM)* and *face & eyes* (when a face is found), every sharpness mode is a classical whole-frame or patch-grid heuristic. A frame with a sharp background and a soft subject can outscore the frame you'd actually keep.
- The SAM preprocessing (1024 px input, normalisation, prompt format) mirrors darktable's own `src/common/ai/segmentation.c` defaults, because `darktable.ai` doesn't expose a model's attributes to Lua. A mask model with a non-default input size would segment poorly; every image then falls back to *subject bias*, and the plugin reports how many did.
- SAM sees each image through darktable's pipeline (rotated, cropped, lens-corrected), while the scorer reads the original file, turned upright from its EXIF orientation. A darkroom crop that changes the aspect ratio is detected and that image falls back; a crop that keeps the ratio isn't, so on cropped edits the mask can sit off the subject. Cull before you crop.
- The vehicle detector sees the full frame scaled to its 640 px input, so a very small, distant car can be missed. That frame then uses the point guess.

## License

MIT, see [LICENSE](LICENSE).
