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

function M.exif_time_to_epoch(s)
    if not s then return nil end
    local y, mo, d, h, mi, se = s:match("(%d+):(%d+):(%d+) (%d+):(%d+):(%d+)")
    if not y then return nil end
    return os.time({
        year = tonumber(y), month = tonumber(mo), day = tonumber(d),
        hour = tonumber(h), min = tonumber(mi), sec = tonumber(se),
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

local ok, dt = pcall(require, "darktable")
if not ok then return M end

local du = require "lib/dtutils"
local df = require "lib/dtutils.file"
local tags = require "darktable.tags"

du.check_min_api_version("7.0.0", "assisted_culling")

local gettext = dt.gettext.gettext
local function _(msgid)
    return gettext(msgid)
end

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
    dt.preferences.register("assisted_culling", "last_genre", "integer", "Last Genre", "", 1)
    dt.preferences.register("assisted_culling", "last_rank_mode", "integer", "Last Rank Mode", "", 1)
    dt.preferences.register("assisted_culling", "last_sharp_mode", "integer", "Last Sharpness Mode", "", 1)
    dt.preferences.register("assisted_culling", "last_exp_mode", "integer", "Last Exposure Mode", "", 1)
    dt.preferences.register("assisted_culling", "last_keep_mode", "integer", "Last Keeper Mode", "", 1)
    dt.preferences.register("assisted_culling", "last_nk_mode", "integer", "Last Non-Keeper Mode", "", 1)
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

    local success, run_err = pcall(function()
        local img_map = {}
        for _, img in ipairs(images) do img_map[tonumber(img.id) or img.id] = img end

        local time_items = {}
        for _, img in ipairs(images) do
            table.insert(time_items, { id = img.id, epoch = M.exif_time_to_epoch(img.exif_datetime_taken) })
        end
        local burst_of = M.cluster_by_time(time_items)

        pcall(os.remove, MANIFEST_PATH)
        pcall(os.remove, RESULTS_PATH)
        pcall(os.remove, RESULTS_PATH .. ".tmp")
        pcall(os.remove, PROGRESS_PATH)
        pcall(os.remove, CANCEL_PATH)
        pcall(os.remove, DONE_PATH)
        pcall(os.remove, LOG_PATH)

        if not write_manifest(images, burst_of) then
            error("Could not write manifest")
        end

        local culling_job = nil
        if dt.gui then
            culling_job = dt.gui.create_job(_("Assisted Culling"), true, stop_job)
            culling_job.percent = 0.0
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
            .. " 2> " .. shell_quote(LOG_PATH)

        run_async_command(cmd, DONE_PATH)

        local done_code = nil

        -- Stage 1 Loop
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
                        dt.print_hinter(string.format(
                            "Assisted Culling: analyzing %d / %d | bursts %s / %s",
                            num, total, b_cur or "?", b_tot or "?"
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

            dt.control.sleep(150)
        end

        local applied_total = 0

        -- =========================================================================
        -- STAGE 2: Applying Ratings Pass via Chunked Asynchronous Execution
        -- =========================================================================
        if not M.cancel_requested then
            dt.print(_("Assisted Culling: Stage 2 applying ratings asynchronously..."))
            
            local keeper_tag = tags.create("Assisted Culling|Keeper")
            local reject_tag = tags.create("Assisted Culling|Rejected")
            local culled_tag = tags.create("Assisted Culling|Culled")
            
            local f = io.open(RESULTS_PATH, "r")
            if f then
                local lines = {}
                for line in f:lines() do table.insert(lines, line) end
                f:close()

                local total_lines = #lines
                local chunk_size = 50
                local current_index = 1

                while current_index <= total_lines do
                    if M.cancel_requested or (culling_job and not culling_job.valid) or file_exists(CANCEL_PATH) then
                        M.cancel_requested = true
                        break
                    end

                    local end_idx = math.min(current_index + chunk_size - 1, total_lines)

                    for i = current_index, end_idx do
                        local line = lines[i]
                        local parts = M.parse_csv_line(line, 6)
                        if parts then
                            for k, val in ipairs(parts) do
                                parts[k] = val:match("^%s*(.-)%s*$")
                            end

                            local id = tonumber(parts[1])
                            local img = id and img_map[id] or nil
                            
                            if img then
                                local raw_rating_str = parts[6]
                                local is_ok = (parts[3] == "ok")
                                local is_keeper = (tonumber(parts[5]) == 1)

                                pcall(function()
                                    if raw_rating_str ~= "leave" then
                                        img.rating = tonumber(raw_rating_str) or 0
                                    end
                                    img.yellow = not is_ok
                                    img.red = not is_keeper
                                    
                                    if is_keeper then
                                        tags.detach(reject_tag, img)
                                        tags.attach(keeper_tag, img)
                                    else
                                        tags.detach(keeper_tag, img)
                                        tags.attach(reject_tag, img)
                                    end

                                    tags.attach(culled_tag, img)
                                    applied_total = applied_total + 1
                                end)
                            end
                        end
                    end

                    if culling_job and total_lines > 0 then
                        culling_job.percent = math.min(1.0, end_idx / total_lines)
                    end
                    dt.print_hinter(string.format("Assisted Culling: applying ratings... (%d / %d)", end_idx, total_lines))

                    current_index = end_idx + 1
                    dt.control.sleep(20)
                end

                if not M.cancel_requested then
                    dt.print(string.format("Assisted Culling: Stage 2 complete. Updated %d images.", applied_total))
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
            dt.print(_("Assisted Culling cancelled."))
        elseif done_code ~= 0 and done_code ~= nil then
            local tail = read_log_tail()
            if tail ~= "" then
                dt.print_error(_("Assisted Culling failed: ") .. tail)
            else
                dt.print_error(_("Assisted Culling failed (scorer exit ") .. tostring(done_code or "?") .. ")")
            end
        elseif applied_total == 0 then
            local tail = read_log_tail()
            dt.print_error(_("Assisted Culling: scorer produced no ratings. ") .. (tail ~= "" and tail or _("Check python path and score_images.py.")))
        else
            dt.print(_("Assisted Culling complete."))
        end
    end)

    is_running = false
    if action_button then
        action_button.label = _("Start Culling")
    end

    if not success then
        dt.print_error(_("Assisted Culling Error: ") .. tostring(run_err))
    end

    pcall(os.remove, MANIFEST_PATH)
    pcall(os.remove, RESULTS_PATH)
    pcall(os.remove, RESULTS_PATH .. ".tmp")
    pcall(os.remove, PROGRESS_PATH)
    pcall(os.remove, CANCEL_PATH)
    pcall(os.remove, DONE_PATH)
    if IS_WINDOWS then
        pcall(os.remove, TMP_DIR .. "/dt_assisted_culling_run.bat")
        pcall(os.remove, TMP_DIR .. "/dt_assisted_culling_run.vbs")
    end
end

local rank_opts = {"universal", "relative"}
local sharp_opts = {"subject_focus", "face_detect", "tiles_uniformity", "peak", "center"}
local exp_opts = {"whole_frame", "subject_only", "strict", "none"}
local keep_opts = {"dynamic_burst", "portrait_mode", "single_best", "keep_all"}
local nk_opts = {"leave", "reject", "0", "1", "2", "3", "4", "5"}

local genre_combo, rank_combo, sharp_combo, exp_combo, keep_combo, non_keeper_combo

local function execute_current_config(images)
    local r_val = rank_opts[rank_combo and rank_combo.value or 1] or "universal"
    local s_val = sharp_opts[sharp_combo and sharp_combo.value or 1] or "subject_focus"
    local e_val = exp_opts[exp_combo and exp_combo.value or 1] or "whole_frame"
    local k_val = keep_opts[keep_combo and keep_combo.value or 1] or "dynamic_burst"
    local nk_val = nk_opts[non_keeper_combo and non_keeper_combo.value or 1] or "leave"
    
    M.score_images(images, r_val, s_val, e_val, k_val, nk_val)
end

local function install_panel()
    if M.module_installed then return end
    M.module_installed = true

    local is_updating = false
    
    local preset_configs = {
        {1, 1, 1, 1},
        {1, 2, 2, 2},
        {1, 3, 3, 3},
        {1, 4, 1, 4},
    }

    genre_combo = dt.new_widget("combobox") {
        label = _("preset"),
        tooltip = _("Sets global configurations based on photography genre."),
        _("sport"), _("portrait"), _("landscape"), _("macro"), _("custom"),
        value = dt.preferences.read("assisted_culling", "last_genre", "integer") or 1,
        changed_callback = function(widget)
            if is_updating then return end
            is_updating = true
            dt.preferences.write("assisted_culling", "last_genre", "integer", widget.value)
            
            local conf = preset_configs[widget.value]
            if conf then
                rank_combo.value = conf[1]
                sharp_combo.value = conf[2]
                exp_combo.value = conf[3]
                keep_combo.value = conf[4]
            end
            
            dt.preferences.write("assisted_culling", "last_rank_mode", "integer", rank_combo.value)
            dt.preferences.write("assisted_culling", "last_sharp_mode", "integer", sharp_combo.value)
            dt.preferences.write("assisted_culling", "last_exp_mode", "integer", exp_combo.value)
            dt.preferences.write("assisted_culling", "last_keep_mode", "integer", keep_combo.value)
            
            is_updating = false
        end
    }

    local function trigger_custom_override()
        if is_updating then return end
        is_updating = true
        genre_combo.value = 5
        dt.preferences.write("assisted_culling", "last_genre", "integer", 5)
        is_updating = false
    end

    rank_combo = dt.new_widget("combobox") {
        label = _("ranking mode"),
        _("universal absolute"), _("relative batch percentile"),
        value = dt.preferences.read("assisted_culling", "last_rank_mode", "integer") or 1, 
        changed_callback = function(widget)
            dt.preferences.write("assisted_culling", "last_rank_mode", "integer", widget.value)
            trigger_custom_override()
        end
    }

    sharp_combo = dt.new_widget("combobox") {
        label = _("sharpness"),
        _("subject tracking (AI)"), _("face & eyes (OpenCV)"), _("edge-to-edge uniformity"), _("absolute peak 1%"), _("center crop"),
        value = dt.preferences.read("assisted_culling", "last_sharp_mode", "integer") or 1, 
        changed_callback = function(widget)
            dt.preferences.write("assisted_culling", "last_sharp_mode", "integer", widget.value)
            trigger_custom_override()
        end
    }

    exp_combo = dt.new_widget("combobox") {
        label = _("exposure"),
        _("whole frame"), _("subject only (ignore sky)"), _("strict histogram"), _("ignore exposure"),
        value = dt.preferences.read("assisted_culling", "last_exp_mode", "integer") or 1, 
        changed_callback = function(widget)
            dt.preferences.write("assisted_culling", "last_exp_mode", "integer", widget.value)
            trigger_custom_override()
        end
    }

    keep_combo = dt.new_widget("combobox") {
        label = _("keepers"),
        _("dynamic (1 to 5)"), _("portrait (1 or 2)"), _("single best only"), _("keep all (focus stack)"),
        value = dt.preferences.read("assisted_culling", "last_keep_mode", "integer") or 1, 
        changed_callback = function(widget)
            dt.preferences.write("assisted_culling", "last_keep_mode", "integer", widget.value)
            trigger_custom_override()
        end
    }

    non_keeper_combo = dt.new_widget("combobox") {
        label = _("non-keepers"),
        _("leave alone"), _("reject (-1)"), _("0 stars"), _("1 star"), _("2 stars"), _("3 stars"), _("4 stars"), _("5 stars"),
        value = dt.preferences.read("assisted_culling", "last_nk_mode", "integer") or 1, 
        changed_callback = function(widget)
            dt.preferences.write("assisted_culling", "last_nk_mode", "integer", widget.value)
            trigger_custom_override()
        end
    }

    action_button = dt.new_widget("button") {
        label = _("Start Culling"),
    }

    action_button.clicked_callback = function()
        if is_running then
            M.cancel_requested = true
            local cf = io.open(CANCEL_PATH, "w")
            if cf then cf:write("1"); cf:close() end
            dt.print(_("Assisted Culling: cancellation requested..."))
            return
        end

        is_running = true
        M.cancel_requested = false

        execute_current_config(dt.gui.action_images)
    end

    local panel_box = dt.new_widget("box") {
        orientation = "vertical",
        reset_callback = function()
            if is_updating then return end
            is_updating = true
            genre_combo.value = 1
            rank_combo.value = 1
            sharp_combo.value = 1
            exp_combo.value = 1
            keep_combo.value = 1
            non_keeper_combo.value = 1
            
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
        action_button
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

    dt.register_event("assisted_culling_run", "shortcut",
        function(event, shortcut)
            execute_current_config(dt.gui.action_images)
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

return M