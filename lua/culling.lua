--[[
    assisted_culling.lua — Assisted Culling for darktable

    Lighttable panel that clusters a selection into bursts, shells out to
    score_images.py, streams ratings back, and keeps a single continuous live progress job.
]]

local M = {}

M.BURST_GAP_SECONDS = 2
M.cancel_requested = false
M.module_installed = false
M.event_registered = false

-- Panel UI references shared for state management
local action_button = nil
local is_running = false
local is_clearing = false
local clear_button = nil

function M.exif_time_to_epoch(s)
    if not s then return nil end
    local y, mo, d, h, mi, se = s:match("(%d+):(%d+):(%d+) (%d+):(%d+):(%d+)")
    if not y then return nil end
    return os.time({
        year = tonumber(y), month = tonumber(mo), day = tonumber(d),
        hour = tonumber(h), min = tonumber(mi), sec = tonumber(se),
        isdst = false, -- constant offset, so a DST change can't split a burst
    })
end

function M.cluster_by_time(items, gap_seconds)
    gap_seconds = gap_seconds or M.BURST_GAP_SECONDS
    local timed, untimed = {}, {}
    for _, item in ipairs(items) do
        if item.epoch then table.insert(timed, item) else table.insert(untimed, item) end
    end
    table.sort(timed, function(a, b) return a.epoch < b.epoch end)

    local burst_of = {}
    local next_burst = 0
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

function M.csv_line(fields)
    local out = {}
    for i, v in ipairs(fields) do
        out[i] = '"' .. tostring(v):gsub('"', '""') .. '"'
    end
    return table.concat(out, ",")
end

function M.parse_csv_line(line, n)
    local parts = {}
    for part in (line .. ","):gmatch("([^,]*),") do
        table.insert(parts, part)
    end
    if #parts ~= n then return nil end
    return parts
end

local ok, dt = pcall(require, "darktable")
if not ok then return M end

local du = require "lib/dtutils"
local df = require "lib/dtutils.file"
local tags = dt.tags

du.check_min_api_version("7.0.0", "assisted_culling")

local gettext = dt.gettext.gettext
local function _(msgid)
    return gettext(msgid)
end

-- Stage 2 pacing. Every darktable property write (rating, tag
-- attach/detach) reloads the lighttable collection and/or rewrites the XMP
-- sidecar, so we count writes and yield to the GUI after a small budget.
local STAGE2_WRITE_BUDGET = 12   -- writes per slice before yielding
local STAGE2_SLEEP_MIN_MS = 20   -- minimum yield per slice
local STAGE2_SLEEP_MAX_MS = 300  -- maximum yield per slice

local IS_WINDOWS = dt.configuration.running_os == "windows"
local THIS_DIR = (debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\]")) or "."

local TMP_DIR = dt.configuration.tmp_dir
local MANIFEST_PATH = TMP_DIR .. "/dt_assisted_culling_manifest.csv"
local RESULTS_PATH = TMP_DIR .. "/dt_assisted_culling_results.csv"
local LOG_PATH = TMP_DIR .. "/dt_assisted_culling_stderr.log"
local PROGRESS_PATH = TMP_DIR .. "/dt_assisted_culling_progress.txt"
local CANCEL_PATH = PROGRESS_PATH .. ".cancel"
local DONE_PATH = TMP_DIR .. "/dt_assisted_culling_done.txt"

if dt.gui then
    dt.preferences.register("assisted_culling", "python_bin", "file",
        "Assisted Culling: python interpreter",
        "python with opencv-python-headless, numpy, Pillow and rawpy installed",
        "")
    dt.preferences.register("assisted_culling", "score_script", "file",
        "Assisted Culling: score_images.py",
        "path to score_images.py from darktable-assisted-culling (empty = auto-detect)",
        "")
        
    -- Register UI State Preferences
    dt.preferences.register("assisted_culling", "apply_while_scoring", "bool",
        "Assisted Culling: apply ratings while scoring",
        "faster overall on big batches, but darktable's UI shares the CPU with the scorer; turn off if the UI lags",
        false)
    dt.preferences.register("assisted_culling", "fast_jpeg_decode", "bool",
        "Assisted Culling: fast JPEG decoding",
        "decode JPEGs / RAW previews at reduced size: faster, but sharpness scores shift slightly (re-check star tiers)",
        false)
    dt.preferences.register("assisted_culling", "burst_gap_seconds", "integer",
        "Assisted Culling: burst gap (seconds)",
        "photos taken closer together than this are grouped into one burst",
        2, 1, 60)
    dt.preferences.register("assisted_culling", "last_genre", "integer", "Last Genre", "", 1, 1, 5)
    dt.preferences.register("assisted_culling", "last_rank_mode", "integer", "Last Rank Mode", "", 1, 1, 2)
    dt.preferences.register("assisted_culling", "last_sharp_mode", "integer", "Last Sharpness Mode", "", 1, 1, 5)
    dt.preferences.register("assisted_culling", "last_exp_mode", "integer", "Last Exposure Mode", "", 1, 1, 4)
    dt.preferences.register("assisted_culling", "last_keep_mode", "integer", "Last Keeper Mode", "", 1, 1, 4)
    dt.preferences.register("assisted_culling", "last_nk_mode", "integer", "Last Non-Keeper Mode", "", 1, 1, 8)
end

local function file_exists(name)
    local f = io.open(name, "r")
    if f ~= nil then f:close(); return true else return false end
end

local function first_existing(paths)
    for _, p in ipairs(paths) do
        if p and p ~= "" and (df.test_file(p, "e") or file_exists(p)) then
            return p
        end
    end
    return nil
end

local function score_script()
    local pref = dt.preferences.read("assisted_culling", "score_script", "file") or ""
    local home = os.getenv("USERPROFILE") or os.getenv("HOME") or ""
    local found = first_existing({
        pref,
        THIS_DIR .. "/score_images.py",
        THIS_DIR .. "/python/score_images.py",
        THIS_DIR .. "/../python/score_images.py",
        THIS_DIR .. "/../../python/score_images.py",
        home .. "/Pictures/DarkTable/Settings/Plugins/darktable-assisted-culling/python/score_images.py",
    })
    return found or (THIS_DIR .. "/score_images.py")
end

local function python_bin(script)
    local pref = dt.preferences.read("assisted_culling", "python_bin", "file")
    if pref and pref ~= "" then return pref end

    local home = os.getenv("USERPROFILE") or os.getenv("HOME") or ""
    local script_dir = (script and script:match("^(.*)[/\\]")) or THIS_DIR
    local plugin_root = script_dir:match("^(.*)[/\\]python$") or script_dir
    local found = first_existing({
        plugin_root .. "/.venv/Scripts/python.exe",
        plugin_root .. "/.venv/bin/python",
        THIS_DIR .. "/../.venv/Scripts/python.exe",
        THIS_DIR .. "/../.venv/bin/python",
        home .. "/Pictures/DarkTable/Settings/Plugins/darktable-assisted-culling/.venv/Scripts/python.exe",
    })
    if found then return found end

    local v = df.check_if_bin_exists(IS_WINDOWS and "python" or "python3")
    if not v then
        v = IS_WINDOWS and "python" or "python3"
    end
    return v
end

local function shell_quote(s)
    if IS_WINDOWS then return '"' .. s .. '"' end
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function run_async_command(cmd, done_path)
    if IS_WINDOWS then
        local bat = TMP_DIR .. "/dt_assisted_culling_run.bat"
        local vbs = TMP_DIR .. "/dt_assisted_culling_run.vbs"
        local f = io.open(bat, "w")
        if not f then return end
        f:write("@echo off\r\nchcp 65001>nul\r\n")
        f:write(cmd, " < NUL\r\n")
        f:write("echo %ERRORLEVEL%> \"", done_path:gsub("/", "\\"), "\"\r\n")
        f:close()
        local f_vbs = io.open(vbs, "w")
        if not f_vbs then return end
        f_vbs:write('Set WshShell = CreateObject("WScript.Shell")\r\n')
        f_vbs:write('WScript.Quit WshShell.Run(Chr(34) & "', bat:gsub("/", "\\"), '" & Chr(34), 0, False)\r\n')
        f_vbs:close()
        os.execute('wscript.exe "' .. vbs:gsub("/", "\\") .. '"')
    else
        os.execute('( ' .. cmd .. ' ; echo $? > ' .. shell_quote(done_path) .. ' ) >/dev/null 2>&1 &')
    end
end

local function write_manifest(images, burst_of)
    local f = io.open(MANIFEST_PATH, "w")
    if not f then return false end
    for _, img in ipairs(images) do
        local path = img.path .. "/" .. img.filename
        f:write(M.csv_line({ img.id, path, burst_of[img.id] }), "\n")
    end
    f:close()
    return true
end

local function read_log_tail()
    local f = io.open(LOG_PATH, "r")
    if not f then return "" end
    local t = f:read("*a") or ""
    f:close()
    t = t:gsub("%s+$", "")
    if #t > 800 then t = t:sub(#t - 799) end
    return t
end

local function stop_job(job)
    M.cancel_requested = true
    local cf = io.open(CANCEL_PATH, "w")
    if cf then cf:write("1"); cf:close() end
    job.valid = false
    is_running = false
    if action_button then
        action_button.label = _("Start Culling")
    end
end

local TAG_KEEPER = "Assisted Culling|Keeper"
local TAG_REJECT = "Assisted Culling|Rejected"
local TAG_CULLED = "Assisted Culling|Culled"
local TAG_OVEREXPOSED = "Assisted Culling|Overexposed"
local TAG_UNDEREXPOSED = "Assisted Culling|Underexposed"
local ALL_TAGS = { TAG_KEEPER, TAG_REJECT, TAG_CULLED, TAG_OVEREXPOSED, TAG_UNDEREXPOSED }

local function fmt_eta(elapsed, done, total)
    if elapsed < 3 or done <= 0 or done >= total then return "" end
    local remaining = math.ceil(elapsed * (total - done) / done)
    return string.format(" | ~%dm %02ds left", remaining // 60, remaining % 60)
end

-- dt.print_error only writes to darktable's log (-d lua); users never see it.
local function notify_error(msg)
    dt.print(msg)
    dt.print_error(msg)
end

local function pretty(s)
    return (tostring(s):gsub("_", " "))
end

local function tags_of(img)
    local have = {}
    for _, t in ipairs(tags.get_tags(img)) do have[t.name] = true end
    return have
end

-- Returns 1 if a write was needed (attach/detach), else 0.
local function sync_tag(img, have, tag, name, wanted)
    if wanted and not have[name] then
        tags.attach(tag, img); return 1
    elseif not wanted and have[name] then
        tags.detach(tag, img); return 1
    end
    return 0
end

function M.score_images(images, rank_mode, sharp_mode, exp_mode, keep_mode, nk_mode)
    rank_mode = rank_mode or "universal"
    sharp_mode = sharp_mode or "subject_focus"
    exp_mode = exp_mode or "whole_frame"
    keep_mode = keep_mode or "dynamic_burst"
    nk_mode = nk_mode or "leave"

    if not images or #images == 0 then
        dt.print(_("Assisted Culling: select some images first"))
        is_running = false
        if action_button then action_button.label = _("Start Culling") end
        return
    end

    local culling_job = nil

    local success, run_err = pcall(function()
        -- Duplicates (same file) are scored once; the result is applied to all of them.
        local primaries, group_of, seen = {}, {}, {}
        for _, img in ipairs(images) do
            local key = img.path .. "/" .. img.filename
            local lead = seen[key]
            if lead then
                table.insert(group_of[tonumber(lead.id) or lead.id], img)
            else
                seen[key] = img
                group_of[tonumber(img.id) or img.id] = { img }
                table.insert(primaries, img)
            end
        end
        local n_primary = #primaries
        local n_dups = #images - n_primary

        local time_items = {}
        for _, img in ipairs(primaries) do
            table.insert(time_items, { id = img.id, epoch = M.exif_time_to_epoch(img.exif_datetime_taken) })
        end

        local gap = M.BURST_GAP_SECONDS
        if dt.gui then
            local g = dt.preferences.read("assisted_culling", "burst_gap_seconds", "integer")
            if g and g >= 1 then gap = g end
        end
        local burst_of = M.cluster_by_time(time_items, gap)

        local overlap, fast_jpeg = false, false
        if dt.gui then
            overlap = dt.preferences.read("assisted_culling", "apply_while_scoring", "bool") and true or false
            fast_jpeg = dt.preferences.read("assisted_culling", "fast_jpeg_decode", "bool") and true or false
        end

        local burst_seen, n_bursts, n_untimed = {}, 0, 0
        for _, it in ipairs(time_items) do
            local b = burst_of[it.id]
            if not burst_seen[b] then burst_seen[b] = true; n_bursts = n_bursts + 1 end
            if not it.epoch then n_untimed = n_untimed + 1 end
        end

        pcall(os.remove, MANIFEST_PATH)
        pcall(os.remove, RESULTS_PATH)
        pcall(os.remove, RESULTS_PATH .. ".tmp")
        pcall(os.remove, PROGRESS_PATH)
        pcall(os.remove, CANCEL_PATH)
        pcall(os.remove, DONE_PATH)
        pcall(os.remove, LOG_PATH)

        if not write_manifest(primaries, burst_of) then
            error("Could not write manifest")
        end

        if dt.gui then
            culling_job = dt.gui.create_job(_("Assisted Culling"), true, stop_job)
            culling_job.percent = 0.0
        end

        dt.print(string.format("Assisted Culling: scoring %d images in %d bursts (%s keepers, %s ranking, %ds burst gap)",
            n_primary, n_bursts, pretty(keep_mode), pretty(rank_mode), gap))
        if n_dups > 0 then
            dt.print(string.format("Assisted Culling: %d duplicate(s) share a file with another image; scored once and matched.", n_dups))
        end
        if n_untimed > 0 then
            dt.print(string.format("Assisted Culling: %d image(s) have no capture time and are scored alone.", n_untimed))
        end
        if n_primary > 1000 then
            dt.print(_("Assisted Culling: large selection, this can take a few minutes. You can cancel any time."))
        end
        dt.print_hinter(_("Assisted Culling: starting analysis..."))

        local sc_script = score_script()
        if not df.test_file(sc_script, "e") and not file_exists(sc_script) then
            error("score_images.py not found at: " .. sc_script)
        end
        local py_bin = python_bin(sc_script)

        local cmd = shell_quote(py_bin) .. " -u " .. shell_quote(sc_script)
            .. " " .. shell_quote(MANIFEST_PATH)
            .. " " .. shell_quote(RESULTS_PATH)
            .. " --progress " .. shell_quote(PROGRESS_PATH)
            .. " --rank-mode " .. shell_quote(tostring(rank_mode))
            .. " --sharp-mode " .. shell_quote(tostring(sharp_mode))
            .. " --exp-mode " .. shell_quote(tostring(exp_mode))
            .. " --keep-mode " .. shell_quote(tostring(keep_mode))
            .. " --nk-mode " .. shell_quote(tostring(nk_mode))
            .. (fast_jpeg and " --fast-jpeg" or "")
            .. " 2> " .. shell_quote(LOG_PATH)

        run_async_command(cmd, DONE_PATH)

        local done_code = nil
        local stage1_start = os.time()

        local applied_total, failed_total, first_error, n_skipped = 0, 0, nil, 0
        local stats = { keepers = 0, others = 0, flagged = 0 }

        -- ---- result application (shared by "while scoring" and the final drain) ----
        local keeper_tag, reject_tag, culled_tag, over_tag, under_tag
        local function ensure_tags()
            if not keeper_tag then
                keeper_tag = tags.create(TAG_KEEPER)
                reject_tag = tags.create(TAG_REJECT)
                culled_tag = tags.create(TAG_CULLED)
                over_tag = tags.create(TAG_OVEREXPOSED)
                under_tag = tags.create(TAG_UNDEREXPOSED)
            end
        end

        -- Reads are cheap; writes reload the lighttable collection / rewrite XMP, so skip no-ops.
        -- Every mark is a tag, never a colour label, so a re-run or "clear" can undo exactly
        -- what earlier passes set without touching labels the user applied by hand.
        local function apply_to_image(img, want_rating, is_keeper, exposure)
            ensure_tags()
            local writes = 0
            local have = tags_of(img)

            if want_rating ~= nil and img.rating ~= want_rating then
                img.rating = want_rating; writes = writes + 1
            end

            writes = writes + sync_tag(img, have, keeper_tag, TAG_KEEPER, is_keeper)
            writes = writes + sync_tag(img, have, reject_tag, TAG_REJECT, not is_keeper)
            writes = writes + sync_tag(img, have, over_tag, TAG_OVEREXPOSED, exposure == "overexposed")
            writes = writes + sync_tag(img, have, under_tag, TAG_UNDEREXPOSED, exposure == "underexposed")
            writes = writes + sync_tag(img, have, culled_tag, TAG_CULLED, true)
            return writes
        end

        -- Returns the number of DB-touching writes performed.
        local function apply_line(line)
            local parts = M.parse_csv_line(line, 6)
            if not parts then return 0 end
            for k, val in ipairs(parts) do
                parts[k] = val:match("^%s*(.-)%s*$")
            end
            local id = tonumber(parts[1])
            local group = id and group_of[id] or nil
            if not group then return 0 end

            local is_keeper = (tonumber(parts[5]) == 1)
            local exposure = parts[3]
            if is_keeper then stats.keepers = stats.keepers + 1 else stats.others = stats.others + 1 end
            if exposure ~= "ok" then stats.flagged = stats.flagged + 1 end
            local want_rating = nil
            if parts[6] ~= "leave" then want_rating = tonumber(parts[6]) or 0 end

            local writes = 0
            for _, img in ipairs(group) do
                local ok_apply, res = pcall(apply_to_image, img, want_rating, is_keeper, exposure)
                if ok_apply then
                    applied_total = applied_total + 1
                    writes = writes + res
                else
                    failed_total = failed_total + 1
                    first_error = first_error or tostring(res)
                end
            end
            return writes
        end

        -- Incrementally read newly written result lines (the scorer appends one burst at a time).
        local pending, pending_idx = {}, 1
        local results_offset, partial = 0, ""
        local function pull_results(final)
            local rf = io.open(RESULTS_PATH, "rb")
            if rf then
                rf:seek("set", results_offset)
                local chunk = rf:read("*a")
                rf:close()
                if chunk and chunk ~= "" then
                    results_offset = results_offset + #chunk
                    local data = partial .. chunk
                    local last_nl = data:match(".*()\n")
                    if last_nl then
                        for line in data:sub(1, last_nl - 1):gmatch("[^\n]+") do pending[#pending + 1] = line end
                        partial = data:sub(last_nl + 1)
                    else
                        partial = data
                    end
                end
            end
            if final and partial:match("%S") then
                pending[#pending + 1] = partial
                partial = ""
            end
        end

        -- One paced slice: stop after the write budget, then yield to the GUI in
        -- proportion to how long the slice took. Returns false if nothing was pending.
        local function apply_slice()
            if pending_idx > #pending then return false end
            local slice_start = os.clock()
            local budget = STAGE2_WRITE_BUDGET
            while pending_idx <= #pending and budget > 0 do
                budget = budget - math.max(1, apply_line(pending[pending_idx]))
                pending_idx = pending_idx + 1
            end
            local slice_ms = (os.clock() - slice_start) * 1000
            dt.control.sleep(math.max(STAGE2_SLEEP_MIN_MS, math.min(STAGE2_SLEEP_MAX_MS, math.floor(slice_ms))))
            return true
        end

        -- Stage 1: wait for the scorer, showing progress (and optionally applying results as they arrive)
        while true do
            if M.cancel_requested or (culling_job and not culling_job.valid) or file_exists(CANCEL_PATH) then
                M.cancel_requested = true
                local cf = io.open(CANCEL_PATH, "w")
                if cf then cf:write("1"); cf:close() end
                break
            end

            local pf = io.open(PROGRESS_PATH, "r")
            if pf then
                local p = pf:read("*a"); pf:close()
                if p and p ~= "" then
                    local cur, tot, b_cur, b_tot = p:match("(%d+),(%d+),(%d+),(%d+)")
                    local num = tonumber(cur)
                    local total = tonumber(tot)
                    if num and total and total > 0 then
                        if culling_job then
                            culling_job.percent = math.min(1.0, num / total)
                        end
                        local elapsed = os.time() - stage1_start
                        local rate = (elapsed >= 3 and num > 0) and string.format(" | %.1f img/s", num / elapsed) or ""
                        local applied_txt = overlap and string.format(" | applied %d", pending_idx - 1) or ""
                        dt.print_hinter(string.format(
                            "Assisted Culling: analyzing %d / %d | bursts %s / %s%s%s%s",
                            num, total, b_cur or "?", b_tot or "?", applied_txt, rate, fmt_eta(elapsed, num, total)
                        ))
                    end
                end
            end

            if file_exists(DONE_PATH) then
                local df_done = io.open(DONE_PATH, "r")
                if df_done then
                    local raw_content = df_done:read("*a") or ""
                    df_done:close()
                    done_code = tonumber(raw_content:match("%d+"))
                end
                break
            end

            if overlap then
                pull_results(false)
                if not apply_slice() then dt.control.sleep(150) end
            else
                dt.control.sleep(150)
            end
        end

        -- After a cancel, give the scorer a moment to exit so it can't overlap the next run.
        if M.cancel_requested then
            for i = 1, 50 do
                if file_exists(DONE_PATH) then break end
                dt.control.sleep(100)
            end
        end

        -- Final drain: apply whatever is left, paced, with progress
        if not M.cancel_requested then
            pull_results(true)
            local total_lines = #pending
            n_skipped = math.max(0, n_primary - total_lines)
            local start_idx = pending_idx - 1
            local remaining = total_lines - start_idx
            if remaining > 0 then
                dt.print(string.format(overlap and "Assisted Culling: analysis done, applying the last %d..."
                    or "Assisted Culling: applying ratings to %d...", remaining))
            end
            local started = os.time()
            local last_toast_pct = 0

            while pending_idx <= total_lines do
                if M.cancel_requested or (culling_job and not culling_job.valid) or file_exists(CANCEL_PATH) then
                    M.cancel_requested = true
                    break
                end

                apply_slice()

                local done = pending_idx - start_idx
                local pct = done / remaining
                if culling_job then culling_job.percent = math.min(1.0, (pending_idx - 1) / total_lines) end
                dt.print_hinter(string.format(
                    "Assisted Culling: applying ratings %d / %d (%d%%)%s", pending_idx - 1, total_lines,
                    math.floor(((pending_idx - 1) / total_lines) * 100), fmt_eta(os.time() - started, done, remaining)))
                local milestone = math.floor(((pending_idx - 1) / total_lines) * 4) * 25
                if milestone > last_toast_pct and milestone < 100 then
                    last_toast_pct = milestone
                    dt.print(string.format("Assisted Culling: %d%% applied", milestone))
                end
            end
        end

        if culling_job then
            culling_job.percent = 1.0
            dt.control.sleep(50)
            culling_job.valid = false
        end

        dt.print_hinter(" ")

        if M.cancel_requested then
            if applied_total > 0 then
                dt.print(string.format("Assisted Culling cancelled. %d of %d images were already updated and keep their changes.",
                    applied_total, #images))
            else
                dt.print(_("Assisted Culling cancelled. No images were changed."))
            end
        elseif done_code ~= 0 and done_code ~= nil then
            local tail = read_log_tail()
            if #tail > 300 then tail = tail:sub(#tail - 299) end
            if tail ~= "" then
                notify_error(_("Assisted Culling failed: ") .. tail)
            else
                notify_error(_("Assisted Culling failed (scorer exit ") .. tostring(done_code or "?") .. ")")
            end
        elseif applied_total == 0 then
            local tail = read_log_tail()
            if #tail > 300 then tail = tail:sub(#tail - 299) end
            notify_error(_("Assisted Culling: scorer produced no ratings. ") .. (tail ~= "" and tail or _("Check python path and score_images.py.")))
        else
            local msg = string.format("Assisted Culling done: %d keepers, %d not kept", stats.keepers, stats.others)
            if stats.flagged > 0 then msg = msg .. string.format(", %d exposure-flagged", stats.flagged) end
            if n_skipped > 0 then msg = msg .. string.format(", %d unreadable (skipped)", n_skipped) end
            if failed_total > 0 then msg = msg .. string.format(", %d failed to update (see log)", failed_total) end
            dt.print(msg)
            if first_error then dt.print_error("Assisted Culling: first apply error: " .. first_error) end
        end
    end)

    is_running = false
    if action_button then
        action_button.label = _("Start Culling")
    end

    if not success then
        if culling_job then pcall(function() culling_job.valid = false end) end
        notify_error(_("Assisted Culling Error: ") .. tostring(run_err))
    end

    -- Keep the cancel flag if the scorer is still alive, so it can still see it.
    local scorer_alive = M.cancel_requested and not file_exists(DONE_PATH)
    pcall(os.remove, MANIFEST_PATH)
    pcall(os.remove, RESULTS_PATH)
    pcall(os.remove, RESULTS_PATH .. ".tmp")
    if not scorer_alive then
        pcall(os.remove, PROGRESS_PATH)
        pcall(os.remove, CANCEL_PATH)
    end
    pcall(os.remove, DONE_PATH)
    if IS_WINDOWS then
        pcall(os.remove, TMP_DIR .. "/dt_assisted_culling_run.bat")
        pcall(os.remove, TMP_DIR .. "/dt_assisted_culling_run.vbs")
    end
end

-- Removes the plugin's tags. Ratings are NOT reverted.
function M.clear_marks(images)
    if not images or #images == 0 then
        dt.print(_("Assisted Culling: select some images first"))
        return
    end
    local found = {}
    for _, name in ipairs(ALL_TAGS) do
        local t = tags.find(name)
        if t then table.insert(found, { tag = t, name = name }) end
    end
    if #found == 0 then
        dt.print("Assisted Culling: nothing to clear, no culling tags exist.")
        return
    end

    local total, cleared, failed = #images, 0, 0
    local i = 1
    local ok, err = pcall(function()
        while i <= total do
            local budget = STAGE2_WRITE_BUDGET
            local slice_start = os.clock()
            while i <= total and budget > 0 do
                local img = images[i]
                local ok_one, res = pcall(function()
                    local have = tags_of(img)
                    local writes = 0
                    for _, ft in ipairs(found) do
                        if have[ft.name] then tags.detach(ft.tag, img); writes = writes + 1 end
                    end
                    return writes
                end)
                if ok_one then
                    if res > 0 then cleared = cleared + 1 end
                    budget = budget - math.max(1, res)
                else
                    failed = failed + 1
                    budget = budget - 1
                end
                i = i + 1
            end
            dt.print_hinter(string.format("Assisted Culling: clearing marks %d / %d", i - 1, total))
            dt.control.sleep(math.max(STAGE2_SLEEP_MIN_MS,
                math.min(STAGE2_SLEEP_MAX_MS, math.floor((os.clock() - slice_start) * 1000))))
        end
    end)
    dt.print_hinter(" ")
    if not ok then notify_error("Assisted Culling: clear failed: " .. tostring(err)); return end
    dt.print(string.format("Assisted Culling: cleared marks on %d of %d images%s. Star ratings were not changed.",
        cleared, total, failed > 0 and (", " .. failed .. " failed") or ""))
end

local rank_opts = {"universal", "relative"}
local sharp_opts = {"center", "tiles_uniformity", "peak", "face_detect", "subject_focus"}
local exp_opts = {"whole_frame", "subject_only", "strict", "none"}
local keep_opts = {"single_best", "portrait_mode", "dynamic_burst", "keep_all"}
local nk_opts = {"leave", "reject", "0", "1", "2", "3", "4", "5"}

local genre_combo, rank_combo, sharp_combo, exp_combo, keep_combo, non_keeper_combo

local function execute_current_config(images)
    local r_val = rank_opts[rank_combo and rank_combo.selected or 1] or "universal"
    local s_val = sharp_opts[sharp_combo and sharp_combo.selected or 1] or "center"
    local e_val = exp_opts[exp_combo and exp_combo.selected or 1] or "whole_frame"
    local k_val = keep_opts[keep_combo and keep_combo.selected or 1] or "single_best"
    local nk_val = nk_opts[non_keeper_combo and non_keeper_combo.selected or 1] or "leave"
    
    M.score_images(images, r_val, s_val, e_val, k_val, nk_val)
end

local function start_culling(allow_cancel)
    if is_clearing then
        dt.print(_("Assisted Culling: busy clearing marks, try again in a moment."))
        return
    end
    if is_running then
        if allow_cancel then
            M.cancel_requested = true
            local cf = io.open(CANCEL_PATH, "w")
            if cf then cf:write("1"); cf:close() end
            if action_button then action_button.label = _("Cancelling...") end
            dt.print(_("Assisted Culling: cancellation requested..."))
        else
            dt.print(_("Assisted Culling: already running. Use the panel button to cancel."))
        end
        return
    end
    is_running = true
    M.cancel_requested = false
    if action_button then action_button.label = _("Cancel Culling") end
    execute_current_config(dt.gui.action_images)
end

local function install_panel()
    if M.module_installed then return end
    M.module_installed = true

    local is_updating = false
    
    local preset_configs = {
        {1, 2, 3, 1},
        {1, 4, 2, 2},
        {1, 5, 1, 3},
        {1, 3, 1, 4},
    }

    local function trigger_custom_override()
        if is_updating then return end
        is_updating = true
        if genre_combo then
            genre_combo.selected = 5
            dt.preferences.write("assisted_culling", "last_genre", "integer", 5)
        end
        is_updating = false
    end

    genre_combo = dt.new_widget("combobox") {
        label = _("preset"),
        tooltip = _("Sets global configurations based on photography genre."),
        _("landscape"), _("portrait"), _("sport"), _("macro"), _("custom"),
        selected = dt.preferences.read("assisted_culling", "last_genre", "integer") or 1,
        changed_callback = function(widget)
            if is_updating then return end
            is_updating = true
            dt.preferences.write("assisted_culling", "last_genre", "integer", widget.selected)
            
            local conf = preset_configs[widget.selected]
            if conf then
                if rank_combo then rank_combo.selected = conf[1] end
                if sharp_combo then sharp_combo.selected = conf[2] end
                if exp_combo then exp_combo.selected = conf[3] end
                if keep_combo then keep_combo.selected = conf[4] end
                
                dt.preferences.write("assisted_culling", "last_rank_mode", "integer", conf[1])
                dt.preferences.write("assisted_culling", "last_sharp_mode", "integer", conf[2])
                dt.preferences.write("assisted_culling", "last_exp_mode", "integer", conf[3])
                dt.preferences.write("assisted_culling", "last_keep_mode", "integer", conf[4])
            end
            
            is_updating = false
        end
    }

    rank_combo = dt.new_widget("combobox") {
        label = _("ranking mode"),
        tooltip = _("universal: stars from fixed sharpness tiers.\nrelative: keepers get top stars, the rest none."),
        _("universal absolute"), _("relative batch percentile"),
        selected = dt.preferences.read("assisted_culling", "last_rank_mode", "integer") or 1, 
        changed_callback = function(widget)
            if is_updating then return end
            dt.preferences.write("assisted_culling", "last_rank_mode", "integer", widget.selected)
            trigger_custom_override()
        end
    }

    sharp_combo = dt.new_widget("combobox") {
        label = _("sharpness"),
        tooltip = _("How sharpness is measured. Face & eyes falls back to edge-to-edge uniformity when no face is found, so it adds nothing over that mode for bursts with no people in them."),
        _("center crop"), _("edge-to-edge uniformity"), _("absolute peak 1%"), _("face & eyes (OpenCV)"), _("subject bias (center-weighted)"),
        selected = dt.preferences.read("assisted_culling", "last_sharp_mode", "integer") or 1, 
        changed_callback = function(widget)
            if is_updating then return end
            dt.preferences.write("assisted_culling", "last_sharp_mode", "integer", widget.selected)
            trigger_custom_override()
        end
    }

    exp_combo = dt.new_widget("combobox") {
        label = _("exposure"),
        tooltip = _("Flags clipped shadows/highlights (Overexposed/Underexposed tag, one star lower)."),
        _("whole frame"), _("subject only (ignore sky)"), _("strict histogram"), _("ignore exposure"),
        selected = dt.preferences.read("assisted_culling", "last_exp_mode", "integer") or 1, 
        changed_callback = function(widget)
            if is_updating then return end
            dt.preferences.write("assisted_culling", "last_exp_mode", "integer", widget.selected)
            trigger_custom_override()
        end
    }

    keep_combo = dt.new_widget("combobox") {
        label = _("keepers"),
        tooltip = _("How many of each burst are kept (the sharpest ones)."),
        _("single best only"), _("portrait (1 or 2)"), _("dynamic (1 to 5)"), _("keep all (focus stack)"),
        selected = dt.preferences.read("assisted_culling", "last_keep_mode", "integer") or 1, 
        changed_callback = function(widget)
            if is_updating then return end
            dt.preferences.write("assisted_culling", "last_keep_mode", "integer", widget.selected)
            trigger_custom_override()
        end
    }

    non_keeper_combo = dt.new_widget("combobox") {
        label = _("non-keepers"),
        tooltip = _("What to do with images that are not kept. They always get the Rejected tag."),
        _("leave alone"), _("reject (-1)"), _("0 stars"), _("1 star"), _("2 stars"), _("3 stars"), _("4 stars"), _("5 stars"),
        selected = dt.preferences.read("assisted_culling", "last_nk_mode", "integer") or 1, 
        changed_callback = function(widget)
            if is_updating then return end
            dt.preferences.write("assisted_culling", "last_nk_mode", "integer", widget.selected)
            trigger_custom_override()
        end
    }

    action_button = dt.new_widget("button") {
        label = _("Start Culling"),
        tooltip = _("Score the selected images in bursts and rate/tag them. Click again to cancel."),
    }

    action_button.clicked_callback = function()
        start_culling(true)
    end

    clear_button = dt.new_widget("button") {
        label = _("Clear culling marks"),
        tooltip = _("Remove the Assisted Culling tags from the selected images. Star ratings and colour labels are not changed."),
    }

    clear_button.clicked_callback = function()
        if is_running or is_clearing then
            dt.print(_("Assisted Culling: busy, wait for the current job to finish."))
            return
        end
        is_clearing = true
        local ok_c, err_c = pcall(M.clear_marks, dt.gui.action_images)
        is_clearing = false
        if not ok_c then notify_error("Assisted Culling: " .. tostring(err_c)) end
    end

    local panel_box = dt.new_widget("box") {
        orientation = "vertical",
        reset_callback = function()
            if is_updating then return end
            is_updating = true
            genre_combo.selected = 1
            rank_combo.selected = 1
            sharp_combo.selected = 1
            exp_combo.selected = 1
            keep_combo.selected = 1
            non_keeper_combo.selected = 1
            
            dt.preferences.write("assisted_culling", "last_genre", "integer", 1)
            dt.preferences.write("assisted_culling", "last_rank_mode", "integer", 1)
            dt.preferences.write("assisted_culling", "last_sharp_mode", "integer", 1)
            dt.preferences.write("assisted_culling", "last_exp_mode", "integer", 1)
            dt.preferences.write("assisted_culling", "last_keep_mode", "integer", 1)
            dt.preferences.write("assisted_culling", "last_nk_mode", "integer", 1)
            is_updating = false
        end,
        genre_combo,
        rank_combo,
        sharp_combo,
        exp_combo,
        keep_combo,
        non_keeper_combo,
        action_button,
        clear_button
    }

    dt.register_lib(
        "assisted_culling", _("Assisted Culling"), true, true,
        { [dt.gui.views.lighttable] = { "DT_UI_CONTAINER_PANEL_RIGHT_CENTER", 100 } },
        panel_box
    )
end

local function destroy()
    if dt.gui.libs["assisted_culling"] then
        dt.gui.libs["assisted_culling"].visible = false
    end
    dt.destroy_event("assisted_culling_run", "shortcut")
end

local function restart()
    if dt.gui.libs["assisted_culling"] then
        dt.gui.libs["assisted_culling"].visible = true
    end

    pcall(dt.destroy_event, "assisted_culling_run", "shortcut")
    dt.register_event("assisted_culling_run", "shortcut",
        function(event, shortcut)
            start_culling(false)
        end, _("execute Assisted Culling on selected images")
    )
end

M.destroy = destroy
M.restart = restart
M.destroy_method = "hide"
M.show = restart
M.metadata = {
    name = _("Assisted Culling"),
    purpose = _("Assisted culling, sharpness grading, and keeper selection"),
    author = "Custom Script",
    help = ""
}

if dt.gui then
    if dt.gui.current_view().id == "lighttable" then
        install_panel()
        restart()
    else
        if not M.event_registered then
            dt.register_event("assisted_culling", "view-changed", function(event, old_view, new_view)
                if new_view.name == "lighttable" or new_view.id == "lighttable" then
                    install_panel()
                    restart()
                end
            end)
            M.event_registered = true
        end
    end
end

M.fmt_eta = fmt_eta
return M