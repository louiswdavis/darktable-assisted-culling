# darktable-ai-cull

A culling assistant for [darktable](https://www.darktable.org/). Select a
batch of images in lighttable, click one button, and it will:

- group your selection into **bursts** by capture time
- score every frame for **sharpness** and **exposure clipping**
- pick the sharpest frame in each burst as the **keeper**
- write the result back as a **star rating**, a **yellow** label for exposure
  problems, a **red** label for rejected duplicates, and darktable's native
  **image grouping** per burst, with the keeper leading the group

Everything runs locally: a Lua plugin inside darktable and a small
Python/OpenCV scorer it shells out to. No API keys, no cloud, no daemon.
Nothing is deleted — it only rates, labels and groups; rejecting is still
your call.

<!-- docs/lighttable.png: lighttable with the AI Cull panel and a scored burst -->

## How it works

```
you select images in lighttable
        |
        v
culling.lua clusters the selection into bursts using each image's
EXIF capture time (darktable already parses this for you)
        |
        v
culling.lua writes manifest.csv (id, filepath, burst_id)
and runs score_images.py
        |
        v
score_images.py opens each file (raw or otherwise), computes a
sharpness score and an exposure status, picks one keeper per burst,
writes results.csv
        |
        v
culling.lua reads results.csv and applies ratings / labels / groups
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
Within a burst the highest sharpness wins; the others get red and zero
stars.

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
git clone https://github.com/ayaan-cs/darktable-ai-cull
cd darktable-ai-cull
python -m venv .venv
.venv/Scripts/pip install -r python/requirements.txt     # Windows
.venv/bin/pip install -r python/requirements.txt         # Linux / macOS
```

### 2. darktable side

darktable's config directory is `~/.config/darktable` on Linux/macOS and
`%LOCALAPPDATA%\darktable` on Windows.

```
# Linux / macOS
cp lua/culling.lua ~/.config/darktable/lua/contrib/culling.lua
echo 'require "contrib/culling"' >> ~/.config/darktable/luarc
```

```
# Windows (PowerShell)
New-Item -ItemType Directory -Force "$env:LOCALAPPDATA\darktable\lua\contrib"
Copy-Item lua\culling.lua "$env:LOCALAPPDATA\darktable\lua\contrib\culling.lua"
Add-Content "$env:LOCALAPPDATA\darktable\luarc" 'require "contrib/culling"'
```

### 3. Point the plugin at Python

Start darktable, open **preferences → lua options**, and set:

- **AI Cull: python interpreter** — the venv's `python.exe` / `bin/python`
- **AI Cull: score_images.py** — `python/score_images.py` from this repo
  (or leave it empty and keep `score_images.py` next to `culling.lua`)

## Use

In lighttable, select a batch — a whole shoot or a single burst — and
click **score selected** in the **AI Cull** panel on the right. Progress
shows in darktable's message area. When it's done:

- **stars** rank each keeper against the rest of the batch
- **yellow** = blown highlights or crushed shadows
- **red** = lost to a sharper frame from the same burst
- burst-mates are grouped, with the keeper as the group's leader

Re-running is safe: groups are rebuilt from scratch each time.

## Tuning

Every threshold is a named constant at the top of the file that uses it:

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
TSV of the rating / labels / group leader darktable holds for each image
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
  removing a *leader* hands its group to another member. So on a re-run
  over already-grouped images, attaching to a leader that still sits in an
  old group scatters the burst; the plugin detaches each keeper into a
  fresh group before attaching its burst-mates.
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

- The file paths handed to the scorer go through a comma-separated
  manifest; a path containing a comma will be skipped.
- Sharpness is a whole-frame measure. A frame with a sharp background and
  a soft subject can outscore the frame you'd actually keep; a subject- or
  face-aware crop before scoring would fix that.
- darktable 5.6+ ships a native `darktable.ai` Lua namespace for local
  ONNX inference. Semantic tagging built on that, calling darktable's own
  models from Lua with no external process, is the natural next piece.

## License

MIT — see [LICENSE](LICENSE).
