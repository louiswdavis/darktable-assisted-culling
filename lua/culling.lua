--[[
    culling.lua — AI-assisted culling for darktable

    Adds an "AI Cull" panel to the lighttable view. Select a batch of
    images (e.g. a whole shoot) and click "score selected". It will:

      1. Cluster the selection into bursts by capture time (two shots
         taken within BURST_GAP_SECONDS of each other are one burst).
      2. Hand each image's file path + burst id to score_images.py,
         which scores sharpness and exposure per image.
      3. Read the results back and apply them in darktable: a star
         rating, a yellow label for exposure problems, a red label for
         non-keeper duplicates, and darktable's native image grouping
         for each burst.

    Install:
      1. Copy this file to <config>/lua/contrib/culling.lua, where <config> is
             ~/.config/darktable            (Linux / macOS)
             %LOCALAPPDATA%\darktable       (Windows)
      2. Add this line to <config>/luarc:
             require "contrib/culling"
      3. Restart darktable. A new "AI Cull" panel appears in lighttable,
         on the right side.
      4. In preferences > lua options, point "AI Cull: python interpreter"
         at a Python that has python/requirements.txt installed, and
         "AI Cull: score_images.py" at that file (or leave it empty and
         keep score_images.py next to this file).

    Note on testing: the pure logic below (time parsing, burst
    clustering, CSV formatting) is covered by test_culling.lua, which
    runs under a plain `lua` interpreter with no darktable involved.
    The darktable-specific calls in the second half of this file
    (dt.new_widget, dt.register_lib, image.rating, and so on) can only
    be exercised inside darktable itself.
]]

-- =========================================================================
-- Part 1: pure logic — no darktable dependency, covered by test_culling.lua
-- =========================================================================

local M = {}  -- exposed so test_culling.lua can require this file directly

M.BURST_GAP_SECONDS = 2  -- shots within this many seconds count as one burst

-- Parses darktable's "YYYY:MM:DD HH:MM:SS" exif_datetime_taken format into
-- a Unix epoch number. Returns nil if the string doesn't match (images
-- with missing EXIF data end up as their own singleton burst).
function M.exif_time_to_epoch(s)
    if not s then return nil end
    local y, mo, d, h, mi, se = s:match("(%d+):(%d+):(%d+) (%d+):(%d+):(%d+)")
    if not y then return nil end
    return os.time({
        year = tonumber(y), month = tonumber(mo), day = tonumber(d),
        hour = tonumber(h), min = tonumber(mi), sec = tonumber(se),
    })
end

-- items: array of {id=..., epoch=... or nil}
-- Returns a table mapping id -> burst_id (a small integer).
-- Images with no timestamp each get their own burst.
function M.cluster_by_time(items, gap_seconds)
    gap_seconds = gap_seconds or M.BURST_GAP_SECONDS
    local timed, untimed = {}, {}
    for _, item in ipairs(items) do
        if item.epoch then table.insert(timed, item) else table.insert(untimed, item) end
    end
    table.sort(timed, function(a, b) return a.epoch < b.epoch end)

    local burst_of = {}
    local next_burst = 1
    local prev_epoch = nil
    for _, item in ipairs(timed) do
        if prev_epoch == nil or (item.epoch - prev_epoch) > gap_seconds then
            next_burst = next_burst + 1
        end
        burst_of[item.id] = next_burst
        prev_epoch = item.epoch
    end
    for _, item in ipairs(untimed) do
        next_burst = next_burst + 1
        burst_of[item.id] = next_burst
    end
    return burst_of
end

-- Minimal CSV line helpers. No embedded-comma/quote handling because our
-- fields are always ids, numbers, plain filesystem paths, or single words
-- (see the note in the README about paths containing commas).
function M.csv_line(fields)
    return table.concat(fields, ",")
end

function M.parse_csv_line(line, n)
    local parts = {}
    for part in (line .. ","):gmatch("([^,]*),") do
        table.insert(parts, part)
    end
    if #parts ~= n then return nil end
    return parts
end

-- =========================================================================
-- Part 2: darktable integration — only runs inside darktable
-- =========================================================================

local ok, dt = pcall(require, "darktable")
if not ok then
    return M  -- allows test_culling.lua to load this file outside darktable
end

-- ---- configuration ------------------------------------------------------
-- Both settings live in darktable's preferences dialog, under "lua options":
--   python interpreter   - one that has python/requirements.txt installed
--                          (a venv's python.exe / bin/python is ideal)
--   score_images.py      - where this repo's python/score_images.py lives;
--                          leave empty to look next to this file, so simply
--                          dropping both files into lua/contrib/ works too.
local IS_WINDOWS = dt.configuration.running_os == "windows"

-- Registering only adds the entries to the preferences dialog (and, like
-- register_lib, is GTK-wrapped, so headless it would wait for a GTK main
-- loop that never runs). Reading works with or without a GUI.
if dt.gui then
    dt.preferences.register("ai_cull", "python_bin", "file",
        "AI Cull: python interpreter",
        "python with opencv-python-headless, numpy, Pillow and rawpy installed",
        IS_WINDOWS and "python" or "python3")
    dt.preferences.register("ai_cull", "score_script", "file",
        "AI Cull: score_images.py",
        "path to score_images.py from darktable-ai-cull (empty = next to culling.lua)",
        "")
end

local THIS_DIR = (debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\]")) or "."

local function python_bin()
    local v = dt.preferences.read("ai_cull", "python_bin", "file")
    if v == nil or v == "" then v = IS_WINDOWS and "python" or "python3" end
    return v
end

local function score_script()
    local v = dt.preferences.read("ai_cull", "score_script", "file")
    if v == nil or v == "" then v = THIS_DIR .. "/score_images.py" end
    return v
end
-- --------------------------------------------------------------------------

-- darktable hands us a per-platform temp directory that already exists, so
-- there's no mkdir to do (and no /tmp to assume on Windows).
local TMP_DIR = dt.configuration.tmp_dir
local MANIFEST_PATH = TMP_DIR .. "/dt_ai_cull_manifest.csv"
local RESULTS_PATH = TMP_DIR .. "/dt_ai_cull_results.csv"
local LOG_PATH = TMP_DIR .. "/dt_ai_cull_stderr.log"

-- cmd.exe only understands double quotes; POSIX shells get single quotes.
local function shell_quote(s)
    if IS_WINDOWS then
        return '"' .. s .. '"'
    end
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- dt.control.execute releases the Lua lock while the child runs, so the GUI
-- stays responsive. Headless (darktable-cli, where dt.gui is nil) there is
-- no GUI to keep responsive, and releasing the lock would let darktable-cli
-- tear the Lua state down underneath us once its export finishes, so we use
-- plain os.execute and keep the lock for the duration.
local execute = dt.gui and dt.control.execute or os.execute

-- On Windows the command goes through cmd.exe, which mangles a command line
-- that contains more than one quoted item, so we follow the convention from
-- darktable's own lua-scripts (lib/dtutils/system.lua): write the command
-- into a .bat file and execute that instead.
local function run_command(cmd)
    if not IS_WINDOWS then
        return execute(cmd)
    end
    local bat = TMP_DIR .. "/dt_ai_cull_run.bat"
    local f = io.open(bat, "w")
    if not f then
        dt.print_error("AI Cull: cannot write " .. bat)
        return 1
    end
    f:write("@echo off\n")
    f:write("chcp 65001>nul\n")  -- UTF-8 so non-ASCII paths survive the round trip
    f:write(cmd, "\n")
    f:write("exit /b %ERRORLEVEL%\n")
    f:close()
    local rc = execute(bat)
    os.remove(bat)
    return rc
end

local function write_manifest(images, burst_of)
    local f = io.open(MANIFEST_PATH, "w")
    for _, img in ipairs(images) do
        local path = img.path .. "/" .. img.filename
        f:write(M.csv_line({ img.id, path, burst_of[img.id] }), "\n")
    end
    f:close()
end

local function read_results()
    local results = {}
    local f = io.open(RESULTS_PATH, "r")
    if not f then return results end
    for line in f:lines() do
        local parts = M.parse_csv_line(line, 6)
        if parts then
            local id = tonumber(parts[1])
            results[id] = {
                sharpness = tonumber(parts[2]),
                exposure = parts[3],
                burst_id = parts[4],
                is_keeper = tonumber(parts[5]) == 1,
                stars = tonumber(parts[6]),
            }
        end
    end
    f:close()
    return results
end

local function apply_results(images, results)
    -- The keeper leads its burst's group, so a collapsed group in lighttable
    -- shows the frame worth keeping rather than whichever came first.
    local burst_leader = {}
    for _, img in ipairs(images) do
        local r = results[img.id]
        if r and (r.is_keeper or not burst_leader[r.burst_id]) then
            burst_leader[r.burst_id] = img
        end
    end

    -- Detach each leader into a fresh group of its own first. group_with()
    -- always removes the image from its current group before adding it,
    -- and pulling a *leader* out of a group hands that group to another
    -- member — so on a re-run over already-grouped images, attaching to a
    -- leader that still sits in an old group would scatter the burst.
    for _, leader in pairs(burst_leader) do
        leader:group_with()
    end

    for _, img in ipairs(images) do
        local r = results[img.id]
        if r then
            img.rating = r.stars
            img.yellow = (r.exposure ~= "ok")   -- flag exposure problems
            img.red = not r.is_keeper           -- flag non-keeper duplicates

            local leader = burst_leader[r.burst_id]
            if leader.id ~= img.id then
                img:group_with(leader)
            end
        end
    end
end

-- Scores a list of images and applies the result. Exposed on the module so
-- it can be driven without the button, e.g. from `darktable --luacmd` or
-- headlessly from darktable-cli:
--     package.loaded["contrib/culling"].score_images(images)
function M.score_images(images)
    if #images == 0 then
        dt.print("AI Cull: select some images first")
        return
    end

    local time_items = {}
    for _, img in ipairs(images) do
        table.insert(time_items, { id = img.id, epoch = M.exif_time_to_epoch(img.exif_datetime_taken) })
    end
    local burst_of = M.cluster_by_time(time_items)

    dt.print("AI Cull: scoring " .. #images .. " images...")
    write_manifest(images, burst_of)
    os.remove(RESULTS_PATH)  -- never read a stale result from a previous run

    local cmd = shell_quote(python_bin()) .. " " .. shell_quote(score_script())
        .. " " .. shell_quote(MANIFEST_PATH) .. " " .. shell_quote(RESULTS_PATH)
        .. " 2> " .. shell_quote(LOG_PATH)
    dt.print_log("AI Cull: " .. cmd)
    local rc = run_command(cmd)
    dt.print_log("AI Cull: scorer exited with " .. tostring(rc))

    local results = read_results()
    if next(results) == nil then
        dt.print("AI Cull: no results — see " .. LOG_PATH)
        return
    end

    apply_results(images, results)
    dt.print("AI Cull: done")
end

-- The panel only exists when there is a GUI (darktable-cli has no dt.gui,
-- and register_lib would block waiting for a GTK main loop that never runs).
if dt.gui then
    local installed = false
    local function install_panel()
        if installed then return end
        installed = true
        local score_button = dt.new_widget("button") {
            label = "score selected",
            clicked_callback = function() M.score_images(dt.gui.selection()) end,
        }
        -- register_lib(plugin_name, name, expandable, resetable, containers, widget)
        dt.register_lib(
            "ai_cull",
            "AI Cull",
            true,   -- expandable
            false,  -- resetable (no reset button; nothing to reset)
            { [dt.gui.views.lighttable] = { "DT_UI_CONTAINER_PANEL_RIGHT_CENTER", 100 } },
            score_button
        )
    end

    -- Registering a lib straight from luarc is a known startup race: darktable
    -- may report lighttable as the current view before that view has finished
    -- initialising, and a lib registered in that window is silently never
    -- attached to the panel (src/views/view.c documents this; the lua-scripts
    -- collection hit it as issue #19197). So install the panel from the
    -- view-changed event into lighttable, which fires only once the view is
    -- fully up. If that event already went by before we got here, the view is
    -- complete and installing now is safe -- darktable >= 5.6 says so via the
    -- darktable_gui_safe flag its system luarc sets; older versions have no
    -- flag, so there we apply darktable's own workaround for this (#21035): a
    -- short sleep in the Lua thread that lets the main thread finish starting.
    dt.register_event("ai_cull", "view-changed", function(_, _, new_view)
        if new_view.id == "lighttable" then install_panel() end
    end)
    if _G.darktable_gui_safe then
        install_panel()
    elseif dt.gui.current_view().id == "lighttable" then
        dt.control.sleep(1500)
        install_panel()
    end
end

return M
