# darktable-assisted-culling

A culling assistant for [darktable](https://www.darktable.org/). Select a batch of images in lighttable, click one button, and it will:

- group your selection into **bursts** by capture time
- score every frame for **sharpness** and **exposure clipping**
- pick the sharpest frame in each burst as the **keeper**
- write the result back as a **star rating** plus **tags** under `Assisted Culling|…`: `Keeper` or `Rejected`, `Overexposed` / `Underexposed` for exposure problems, and `Culled` on everything it has processed

Everything runs locally: a Lua plugin inside darktable and a small Python/OpenCV scorer it shells out to. No API keys, no cloud, no daemon.
Nothing is deleted, and your colour labels are never touched — it only rates and tags; rejecting is still your call.

<!-- docs/lighttable.png: lighttable with the Assisted Culling panel and a scored burst -->

## How it works

```
you select images in lighttable
        |
        v
culling.lua clusters the selection into bursts using each image's EXIF capture time (darktable already parses this for you)
        |
        v
culling.lua writes manifest.csv (id, filepath, burst_id) and runs score_images.py
        |
        v
score_images.py opens each file (raw or otherwise), computes a sharpness score and an exposure status, picks one keeper per burst, writes results.csv
        |
        v
culling.lua reads results.csv and applies ratings / tags
```

Two small processes talking through a CSV file. The Lua side is split
into pure logic (time parsing, clustering, CSV) with no darktable
dependency, and the darktable integration proper; only the second half
needs darktable to run.

**Scoring.** Sharpness is the variance of the Laplacian of a downscaled
grayscale copy — a standard, cheap focus proxy. Raw variance isn't
comparable across cameras, lenses or ISOs, so frames are ranked against
the rest of *this* batch and the percentile drives the star rating.
Exposure is flagged when more than 2 % of pixels are crushed or blown.
Within a burst the highest sharpness wins; the others are tagged
`Rejected` and rated per the non-keepers setting.

**Why time-based grouping.** An earlier version grouped duplicates by
perceptual image hashing. That technique is built to spot near-identical
copies of a file, which isn't the same problem as "different frames of
the same burst", where subject or focus genuinely changed between shots;
the results were inconsistent. darktable already gives Lua scripts each
image's `exif_datetime_taken`, and clustering on capture-time proximity
(the same approach the community's `AutoGrouper.lua` uses) is simpler and
far more reliable.

## Requirements

- darktable 5.4 or newer, built with Lua (the official builds are)
- Python 3.10+ with `opencv-python-headless`, `numpy`, `Pillow`, `rawpy`

`rawpy` needs `libraw`; the Windows and macOS wheels bundle it. On Linux
install `libraw-dev` first, or skip `rawpy` if you only shoot JPEG — it's
imported lazily, only when a raw file shows up.

## Install

### 1. Python side

```
git clone https://github.com/louiswdavis/darktable-assisted-culling
cd darktable-assisted-culling

python -m venv .venv
.venv/Scripts/pip install -r python/requirements.txt     # Windows
.venv/bin/pip install -r python/requirements.txt         # Linux / macOS
```

### 2. darktable side

darktable's config directory is `~/.config/darktable` on Linux/macOS and `%LOCALAPPDATA%\darktable` on Windows.

```
# Linux / macOS

mkdir -p ~/.config/darktable/lua/contrib
ln -s "$(pwd)/lua/culling.lua" ~/.config/darktable/lua/contrib/culling.lua
echo 'require "contrib/culling"' >> ~/.config/darktable/luarc
```

```
# Windows (Command Prompt)
# Note: Creating symbolic links on Windows requires running cmd as Administrator (unless Developer Mode is enabled).

if not exist "%LOCALAPPDATA%\darktable\lua\contrib" mkdir "%LOCALAPPDATA%\darktable\lua\contrib"
mklink "%LOCALAPPDATA%\darktable\lua\contrib\culling.lua" "%CD%\lua\culling.lua"
echo require "contrib/culling" >> "%LOCALAPPDATA%\darktable\luarc"
```

```
# Windows (PowerShell)
# Note: Creating symbolic links on Windows requires running PowerShell as Administrator (unless Developer Mode is enabled).

New-Item -ItemType Directory -Force "$env:LOCALAPPDATA\darktable\lua\contrib"
New-Item -ItemType SymbolicLink -Path "$env:LOCALAPPDATA\darktable\lua\contrib\culling.lua" -Value "$PWD\lua\culling.lua"
Add-Content "$env:LOCALAPPDATA\darktable\luarc" 'require "contrib/culling"'
```

### 3. Point the plugin at Python

Start darktable, open **preferences → lua options**, and set:

- **Assisted Culling: python interpreter** — the venv's `python.exe` / `bin/python`
- **Assisted Culling: score_images.py** — `python/score_images.py` from this repo (or leave it empty and keep `score_images.py` next to `culling.lua`)

## Use

In lighttable, select a batch — a whole shoot or a single burst — and
click **Start Culling** in the **Assisted Culling** panel on the right. Progress
shows in darktable's message area. When it's done:

- **stars** rank each keeper against the rest of the batch
- **`Assisted Culling|Keeper`** = the best frame(s) of its burst
- **`Assisted Culling|Rejected`** = lost to a sharper frame from the same
  burst (rated per the non-keeper setting below)
- **`Assisted Culling|Overexposed`** / **`Underexposed`** = blown
  highlights or crushed shadows
- **`Assisted Culling|Culled`** = processed by the plugin at least once

Filter on these in darktable's **collections** module (tag → Assisted
Culling) to step through just the keepers, or just the rejects.

Re-running is safe: every tag is re-synced to the new result, so a frame
that was a keeper last pass and isn't now loses its `Keeper` tag. **Clear
culling marks** removes all the plugin's tags without touching star
ratings. Colour labels are never read or written, so any you apply by hand
are yours.

Passes made before this version used red/yellow colour labels. Those
labels stay where they were; to remove them once, collect by the
`Assisted Culling|Culled` tag, select all, and toggle the labels off.

### Panel options

- **preset** — landscape / portrait / sport / macro set the four options
  below to sensible combinations in one click; **custom** is selected
  automatically the moment you change any of them by hand.
- **ranking mode** — *universal absolute* rates every frame against fixed
  sharpness tiers; *relative batch percentile* gives keepers top stars and
  everything else none, scored against the rest of its own burst.
- **sharpness** — how each frame's focus is measured:
  - *center crop* — Laplacian variance over the middle 50% of the frame.
  - *edge-to-edge uniformity* — a 3×3 patch grid scored with equal weight,
    for subjects that should be sharp corner to corner (landscapes, macro).
  - *absolute peak 1%* — the sharpest 1% of edges in the whole frame.
  - *face & eyes (OpenCV)* — detects the largest face via OpenCV's Haar
    cascades and scores sharpness over the eyes if found, the whole face
    box otherwise; falls back to *edge-to-edge uniformity* when no face is
    detected.
  - *subject bias (center-weighted)* — the same 3×3 grid as above, but the
    center patches count more, on the assumption the subject is mid-frame.
    This is a classical heuristic, not AI — see **Limitations and ideas**.
- **exposure** — *whole frame*, *subject only (ignore sky)* (drops the top
  20% of the frame before checking for clipping), *strict histogram*
  (tighter clipping thresholds), or *ignore exposure*.
- **keepers** — how many frames per burst survive: *single best only*,
  *portrait (1 or 2)*, *dynamic (1 to 5, scaling with burst size)*, or
  *keep all (focus stack)* for frames you'll merge rather than cull.
- **non-keepers** — what happens to the frames that aren't kept: *leave
  alone*, *reject (-1)*, or a fixed star count from 0–5. They always get
  the `Rejected` tag regardless of this setting.

## Tuning

Ranking mode, sharpness mode, exposure mode, keeper count and non-keeper
handling are all panel dropdowns (see **Panel options** above) — no file
editing needed for those. What's left as a named constant at the top of
the file that uses it:

- `culling.lua` — `BURST_GAP_SECONDS` (default 2): how close in time two
  shots must be to count as one burst. 2 s suits continuous-drive bursts
  from a camera. For deliberate re-takes with a phone, 5 s fits better;
  on a 14-frame hand-held phone series (frames 4–50 s apart) the default
  grouped nothing, while 5 s clustered three pairs and picked the sharper
  frame each time.
- `score_images.py` — `SHADOW_CLIP` / `HIGHLIGHT_CLIP` / `CLIP_PCT_FLAG`
  control exposure flagging; `STAR_THRESHOLDS` and `EXPOSURE_PENALTY`
  control how sharpness percentile + exposure become a star count.

These are sensible starting points, not tuned defaults. Run a real shoot
through it, see what gets flagged, and adjust.

## Testing

The pure-logic half of the plugin runs under any Lua 5.4:

```
cd lua && lua test_culling.lua
```

No `lua` binary handy? `pip install lupa` in the venv, then:

```
.venv/Scripts/python -c "import lupa.lua54 as l; L=l.LuaRuntime(); L.execute('package.path=\"./lua/?.lua;\"..package.path; dofile(\"lua/test_culling.lua\")')"
```

The scorer runs standalone against any folder of images, no darktable
involved — `manifest.csv` is `id,filepath,burst_id` per line:

```
python python/score_images.py manifest.csv results.csv
```

The darktable half can be exercised **without the GUI** through
`darktable-cli`, which initialises Lua and honours `--luacmd`.
`tools/e2e_cli.lua` imports a folder, runs the plugin on it, and writes a
TSV of the rating and `Assisted Culling` tags darktable holds for each image
afterwards — the plugin's entire observable output:

```
set DT_AI_CULL_FOLDER=C:/path/to/photos
set DT_AI_CULL_REPORT=C:/path/to/report.tsv
set DT_AI_CULL_GAP=5                     # optional BURST_GAP_SECONDS override
darktable-cli.exe any.jpg out.jpg --core --library "%LOCALAPPDATA%\darktable\library.db" -d lua --luacmd "dofile([[C:/path/to/tools/e2e_cli.lua]])"
```

Results land in the real library, so they show up in lighttable later.
The script's header documents the two `darktable-cli` quirks it works
around.

## Notes from the darktable source

Things that cost time to find out, recorded so they don't again:

- **`register_lib` takes eight positional arguments** —
  `(plugin_name, name, expandable, resetable, containers, widget,
  view_enter, view_leave)`. Leaving out `resetable` shifts the container
  table into a boolean slot and the panel never registers.
- **Registering a lib straight from `luarc` is a startup race.**
  darktable can report lighttable as the current view before the view has
  finished initialising, and a lib registered in that window is silently
  never attached (`src/views/view.c` documents it; the lua-scripts hit it
  as #19197). The plugin installs its panel from the `view-changed` event
  into lighttable instead, which fires only once the view is fully up.
- **`darktable-cli` never runs your `luarc`.** Since 5.6 the user `luarc`
  is loaded by `script_manager` (GUI only); before that the C code only
  loaded it when a GUI existed. `--luacmd` still runs, and it's the way to
  test headlessly. Anything GTK-wrapped — `register_lib`,
  `preferences.register` — blocks forever headless, so the plugin gates
  those on `dt.gui`.
- **`dt.control.execute` releases the Lua lock** while the child runs.
  That keeps the GUI responsive, but headless it lets `darktable-cli` tear
  Lua down mid-run once its export finishes; without a GUI the plugin
  uses plain `os.execute` and holds the lock.
- **`group_with` first removes the image from its current group**, and
  removing a *leader* hands its group to another member. The plugin no
  longer stacks bursts with darktable's image grouping (bursts are a
  scoring concept only, tracked by capture time), but if that's ever added
  back: on a re-run over already-grouped images, attaching to a leader
  that still sits in an old group scatters the burst, so detach each
  keeper into a fresh group before attaching its burst-mates.
- **Windows shell-outs go through a `.bat` file**, following
  `lib/dtutils/system.lua` in darktable's lua-scripts: cmd.exe mangles a
  command line with more than one quoted item.

## Troubleshooting

- **The panel isn't there.** Start darktable with `-d lua` and look for
  `LUA ERROR` in the log. On Windows the log is
  `Documents\Darktable\darktable-log.txt`.
- **"no results"** — the scorer failed. Its stderr is in
  `dt_ai_cull_stderr.log` in darktable's temp directory; the usual cause is
  the interpreter preference pointing at a Python without the
  requirements installed.
- **darktable itself crashes on startup on Windows 11** (`0xC0000005`).
  darktable's Windows binaries are unsigned, and Smart App Control blocks
  unsigned DLLs that haven't built up reputation — it blocked `libdarkroom.dll`
  from 5.6.1 on a test machine. Check the
  `Microsoft-Windows-CodeIntegrity/Operational` event log for event 3077.
  Don't turn Smart App Control off (it's a one-way switch); an older
  release passes — `winget install --id darktable.darktable --version 5.4.1`
  ran with no blocks — and this plugin needs nothing newer.

## Limitations and ideas

- *Face & eyes* only helps when OpenCV's Haar cascade actually finds a
  face in frame; everything else — including the *subject bias* sharpness
  mode — is still a classical heuristic (center-weighted patch variance),
  not real subject detection. A frame with a sharp background and a soft
  subject can still outscore the frame you'd actually keep when no face is
  detected.
- **`darktable.ai` is real and Lua-scriptable** (`load_model` / `ctx:run`
  on arbitrary ONNX tensors, plus a model registry keyed by task —
  `denoise`, `upscale`, `mask`), but it isn't an automatic subject
  detector out of the box, and it's a parked idea rather than a planned
  feature. The only shipped `mask`-task model is a SAM-style
  encoder/decoder; it needs a point or box prompt, and darktable's own use
  of it (the darkroom object-mask tool) supplies that via a GUI click —
  that tool isn't exposed to Lua, and there's no "find the subject"
  task to call instead. Worse, `darktable.ai` only runs inside
  darktable's Lua process; the actual scoring happens in the separate
  `score_images.py` process, so using it would mean generating a bbox in
  Lua and threading it into the manifest for the scorer to crop against —
  on top of solving the prompt problem. A face bbox from the *face & eyes*
  mode above is the one prompt source that would actually be reliable,
  but that detection runs in Python, so wiring it to a Lua-side SAM call
  means a three-stage pipeline instead of today's two processes, for a
  model that's slower per image and depends on the user having downloaded
  it through darktable's AI model manager. For the dominant case (a
  person in frame) *face & eyes* already covers this more cheaply. If
  broader subject coverage (pets, sport, product shots) is ever needed, a
  classical saliency-point heuristic — no new ML dependency, no new
  process boundary — is the right next small step, not SAM.

## License

MIT — see [LICENSE](LICENSE).
