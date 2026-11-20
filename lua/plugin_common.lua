--[[
    plugin_common.lua — code shared by Assisted Grouping, Assisted Culling and Assisted Tagging.

    Each repo holds its own copy, byte for byte the same; each repo's Lua test hashes it against
    COMMON_HASH, so a change made in one repo fails the other two until it is copied over.
    A plugin loads it with loadfile from its own folder (or the plugin folder preference), never
    through lua/contrib. Everything above the `require "darktable"` line runs in plain `lua`.
]]

local C = {}

-- The plugin's own folder: this file sits in its lua/ folder.
local PLUGIN_DIR = ((debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\]") or "."):match("^(.*)[/\\]")) or ".."

C.IS_WINDOWS = package.config:sub(1, 1) == "\\"

-- Shared preferences ------------------------------------------------------------
-- One plugins folder for all three plugins. The old per-plugin key still works and
-- logs a deprecation line once. There is no interpreter preference: each plugin runs
-- its own .venv, since their requirements differ.

C.SHARED_GROUP = "assisted_plugins"

-- Each plugin loads its own copy of this file, so the "registered" mark lives in
-- package.loaded, which all scripts in darktable's Lua state share.
local REGISTERED_MARK = "assisted_plugins.shared_prefs_registered"

function C.register_shared_prefs(dt)
    if package.loaded[REGISTERED_MARK] then return end
    package.loaded[REGISTERED_MARK] = true
    dt.preferences.register(C.SHARED_GROUP, "plugins_root", "directory",
        "plugins folder (holds the three assisted-* folders)",
        "The folder holding darktable-assisted-grouping, darktable-assisted-culling and darktable-assisted-tagging. Empty = auto-detect",
        "")
end

local deprecation_logged = {}

local function read_pref(dt, group, name, kind)
    local ok, value = pcall(dt.preferences.read, group, name, kind)
    return (((ok and value) or ""):gsub("[/\\]+$", ""))
end

local function old_pref(dt, plugin_group, name, kind, shared_name, log)
    local value = read_pref(dt, plugin_group, name, kind)
    local key = plugin_group .. "/" .. name
    if value ~= "" and log and not deprecation_logged[key] then
        deprecation_logged[key] = true
        log(string.format("preferences: %s is deprecated; set %s/%s", key, C.SHARED_GROUP, shared_name))
    end
    return value
end

-- <plugins_root>/<folder_name>, else the plugin's old plugin_folder, else fallback ("" when nil).
function C.plugin_folder(dt, plugin_group, folder_name, log, fallback)
    local root = read_pref(dt, C.SHARED_GROUP, "plugins_root", "directory")
    if root ~= "" then return root .. "/" .. folder_name end
    local old = old_pref(dt, plugin_group, "plugin_folder", "directory", "plugins_root", log)
    if old ~= "" then return old end
    return fallback or ""
end

-- Group keys --------------------------------------------------------------------
-- How culling and tagging read the groups grouping wrote (tags or native groups).

local GROUP_TAG = "^Assisted Grouping|(%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d)|Group|%d+$"

-- The newest "Assisted Grouping|<stamp>|Group|<n>" among the tag names (name -> true), or nil.
-- Stamps are `YYYY-MM-DD HH:MM:SS`, so string order is time order; a tie takes the greater name.
function C.latest_group_tag(have)
    local best, best_stamp
    for name in pairs(have or {}) do
        local stamp = name:match(GROUP_TAG)
        if stamp and (not best_stamp or stamp > best_stamp or (stamp == best_stamp and name > best)) then
            best, best_stamp = name, stamp
        end
    end
    return best
end

-- id -> the image's own latest group tag, so a half-regrouped selection keeps each run's groups
-- apart; second return counts the grouping runs those tags come from.
function C.latest_group_keys(items)
    local key_of, runs, n_runs = {}, {}, 0
    for _, item in ipairs(items) do
        local tag = C.latest_group_tag(item.tags)
        if tag then
            key_of[item.id] = tag
            local stamp = tag:match(GROUP_TAG)
            if not runs[stamp] then runs[stamp] = true; n_runs = n_runs + 1 end
        end
    end
    return key_of, n_runs
end

C.GROUP_TAGS_HINT = "Grouping tags found but no native groups. Set grouping support to grouping tags to use them."

-- GROUP_TAGS_HINT when native grouping put no photo in a group of 2+ but an item carries a
-- grouping tag (grouping ran with Group tags on but not native groups), else nil.
function C.group_tags_hint(grouped, items)
    if grouped > 0 then return nil end
    for _, item in ipairs(items) do
        if C.latest_group_tag(item.tags) then return C.GROUP_TAGS_HINT end
    end
    return nil
end

-- id -> child name under node (first by name); second return lists ids with several children.
function C.tag_group_keys(items, node)
    local prefix = node .. "|"
    local key_of, multi = {}, {}
    for _, item in ipairs(items) do
        local children = {}
        for name in pairs(item.tags) do
            if name:sub(1, #prefix) == prefix then
                local child = name:sub(#prefix + 1)
                if child ~= "" and not child:find("|", 1, true) then children[#children + 1] = child end
            end
        end
        if #children > 0 then
            table.sort(children)
            key_of[item.id] = children[1]
            if #children > 1 then multi[#multi + 1] = item.id end
        end
    end
    return key_of, multi
end

function C.native_group_keys(items)
    local key_of = {}
    for _, item in ipairs(items) do
        if item.leader then key_of[item.id] = tostring(item.leader) end
    end
    return key_of
end

-- Dense integers from 1 by first appearance; an id with no key gets its own.
function C.number_groups(ids, key_of)
    local group_of, by_key, n = {}, {}, 0
    for _, id in ipairs(ids) do
        local key = key_of[id]
        if key == nil then
            n = n + 1
            group_of[id] = n
        else
            if not by_key[key] then
                n = n + 1
                by_key[key] = n
            end
            group_of[id] = by_key[key]
        end
    end
    return group_of
end

-- Files ------------------------------------------------------------------------

-- Same list as common.py RAW_EXTENSIONS: LibRaw's camera formats.
local RAW_EXT = {}
for ext in ("3fr ari arw bay cr2 cr3 crw dcr dcs dng erf fff iiq k25 kdc mdc mef mos mrw nef nrw "
    .. "orf ori pef raf raw rw2 rwl sr2 srf srw x3f"):gmatch("%S+") do
    RAW_EXT[ext] = true
end
-- Formats the helpers decode at full size with Pillow.
local FULL_SIZE_EXT = { jpg = true, jpeg = true, png = true, tif = true, tiff = true }

-- "IMG_1.ARW" → "img_1": a RAW and its in-camera JPEG share it (darktable's import pairing
-- ignores extension and case too).
function C.shot_stem(filename)
    return (filename:match("^(.+)%.[^.]*$") or filename):lower()
end

function C.is_raw(filename)
    local ext = filename:match("%.([^.]+)$")
    return ext ~= nil and RAW_EXT[ext:lower()] == true
end

-- How well a helper reads a file: 2 full size (JPEG, TIFF, PNG: the camera's exposure and
-- colour), 1 a RAW's embedded preview, 0 anything else (it may not decode at all).
function C.lead_rank(filename)
    local ext = (filename:match("%.([^.]+)$") or ""):lower()
    if FULL_SIZE_EXT[ext] then return 2 end
    return RAW_EXT[ext] and 1 or 0
end

function C.file_exists(name)
    local f = io.open(name, "r")
    if f ~= nil then f:close(); return true else return false end
end

function C.first_existing(paths)
    for _, p in ipairs(paths) do
        if p and p ~= "" and C.file_exists(p) then
            return p
        end
    end
    return nil
end

function C.read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local t = f:read("*a")
    f:close()
    return t
end

-- `path`'s text, or `path`.tmp's when `path` is missing (see write_file_atomic).
function C.read_file_or_tmp(path)
    for _, p in ipairs({ path, path .. ".tmp" }) do
        local f = io.open(p, "r")
        if f then
            local t = f:read("a")
            f:close()
            return t
        end
    end
    return nil
end

-- Writes `text` to `path`.tmp, then moves it onto `path`, so a failed or cut-short
-- write leaves the old file. os.rename won't replace a file on Windows, so on a
-- failed rename the old file is removed and the rename retried; a crash in that gap
-- leaves only `path`.tmp, which read_file_or_tmp falls back to. Returns true, or nil and why.
function C.write_file_atomic(path, text)
    local tmp = path .. ".tmp"
    local f, oerr = io.open(tmp, "w")
    if not f then return nil, oerr end
    local okw, werr = f:write(text)
    local okc, cerr = f:close()
    if not okw or not okc then
        pcall(os.remove, tmp)
        return nil, werr or cerr
    end
    local okr, rerr = os.rename(tmp, path)
    if not okr then
        os.remove(path)
        okr, rerr = os.rename(tmp, path)
    end
    if not okr then return nil, rerr end
    return true
end

-- Run log --------------------------------------------------------------------------
-- The plugin's run log at `path` (`<name>.log`). `w.log(msg)` writes "HH:MM:SS lua: msg"
-- to disk at once, so a darktable crash leaves the last line written. Between `w.hold()`
-- and `w.release()` lines wait in memory: a helper process appends its stderr to the
-- same file then, and two processes appending at once can overwrite each other's
-- lines on Windows. `w.hold()` writes what is waiting first. `w.rotate(keep)` starts
-- a new log: the current one becomes `<name>.prev.log`, older ones `<name>.prev2.log`
-- up to `<name>.prev<keep>.log`.
function C.run_log(path)
    local w = { held = false }
    local waiting = {}

    local function write_waiting()
        if #waiting == 0 then return end
        local f = io.open(path, "a")
        if not f then return end
        f:write(table.concat(waiting, "\n"), "\n")
        f:close()
        waiting = {}
    end

    function w.log(msg)
        waiting[#waiting + 1] = os.date("%H:%M:%S ") .. "lua: " .. msg
        if not w.held then write_waiting() end
    end

    function w.hold()
        write_waiting()
        w.held = true
    end

    function w.release()
        w.held = false
        write_waiting()
    end

    -- Writes what is waiting without ending the hold: for points where the caller
    -- knows the helper is not writing.
    w.flush = write_waiting

    -- Helper output read back by the plugin: written as it is, in order with the lua lines.
    function w.append_lines(text)
        for line in (text or ""):gmatch("[^\r\n]+") do waiting[#waiting + 1] = line end
        if not w.held then write_waiting() end
    end

    function w.rotate(keep)
        local base = path:gsub("%.log$", "")
        local function prev(n) return base .. (n == 1 and ".prev.log" or ".prev" .. n .. ".log") end
        os.remove(prev(keep))
        for n = keep - 1, 1, -1 do os.rename(prev(n), prev(n + 1)) end
        os.rename(path, prev(1))
    end

    return w
end

-- "image 12 (IMG_0012.CR3)" for a log line. An image removed from the library raises on any read.
function C.image_label(img)
    local ok, label = pcall(function() return string.format("image %d (%s)", img.id, img.filename) end)
    return ok and label or "image no longer in the library"
end

-- "1 image" / "2 images" for a toast or alert: `plural` defaults to `noun` plus "s".
function C.count(n, noun, plural)
    return n .. " " .. (n == 1 and noun or plural or noun .. "s")
end

-- pcall that also logs a failure with its traceback as "<what> failed: ...". Returns what pcall returns.
function C.logged_call(log, what, fn)
    return xpcall(fn, function(err)
        log(what .. " failed: " .. debug.traceback(tostring(err), 2))
        return err
    end)
end

-- Lua error log ------------------------------------------------------------------
-- One file per plugin, <config dir>/<plugin>.lua.log, separate from the run log (which
-- each run rotates). Holds only Lua errors: timestamp, label and traceback. Past
-- `max_bytes` (default 256 KB) the older half is dropped, cut at a line start.

-- Appends one entry to `log_path`, trimming first. `now` is os.date's text (tests pin it).
function C.append_error_log(log_path, label, message, max_bytes, now)
    max_bytes = max_bytes or 262144
    local old = C.read_file(log_path)
    if old and #old > max_bytes then
        local keep = old:sub(#old - max_bytes // 2 + 1)
        keep = keep:match("\n(.*)$") or keep
        C.write_file_atomic(log_path, keep)
    end
    local f = io.open(log_path, "a")
    if not f then return end
    f:write(string.format("[%s] %s\n%s\n\n", now or os.date("%Y-%m-%d %H:%M:%S"), label, message))
    f:close()
end

-- Returns guard(label, fn, ...): runs fn(...) under xpcall and returns its results. On
-- an error it logs the traceback to `log_path`, prints it to the console, shows the
-- toast "<title>: Lua error, see <log file name>" and returns nil. `dt` may be nil (tests).
function C.error_guard(dt, log_path, title)
    local toast = title .. ": Lua error, see " .. (log_path:match("[^/\\]+$") or log_path)
    return function(label, fn, ...)
        local res = table.pack(xpcall(fn, debug.traceback, ...))
        if res[1] then return table.unpack(res, 2, res.n) end
        C.append_error_log(log_path, label, tostring(res[2]))
        print(title .. " " .. label .. ": " .. tostring(res[2]))
        if dt and dt.print then pcall(dt.print, toast) end
        return nil
    end
end

-- `fn` run through `guard` (from error_guard) under `label`, for a widget callback or event.
function C.guarded_callback(guard, label, fn)
    return function(...) return guard(label, fn, ...) end
end

-- Returns new_widget(kind)(props): dt.new_widget(kind)(props) with every *_callback
-- function in `props` guarded, labelled by kind and label.
function C.guarded_widget_maker(dt, guard)
    return function(kind)
        return function(props)
            for key, fn in pairs(props) do
                if type(key) == "string" and key:match("_callback$") and type(fn) == "function" then
                    props[key] = C.guarded_callback(guard, kind .. " " .. tostring(props.label or key), fn)
                end
            end
            return dt.new_widget(kind)(props)
        end
    end
end

-- Names in `dir` (files and folders, no dots), or an empty list when it can't be listed.
function C.list_dir(dir, windows)
    if windows == nil then windows = C.IS_WINDOWS end
    local names = {}
    local p = io.popen(windows and ('dir /b "' .. dir:gsub("/", "\\") .. '" 2>nul')
        or ("ls -1 '" .. dir:gsub("'", "'\\''") .. "' 2>/dev/null"))
    if not p then return names end
    for line in p:lines() do
        local name = line:gsub("\r$", "")
        if name ~= "" then names[#names + 1] = name end
    end
    p:close()
    return names
end

-- Temp files are named <dir>/<prefix><epoch>_<seq>_<name>, the epoch being the
-- darktable instance's start (or the run's), so two instances never share a file and
-- the age of a leftover is in its name. One per plugin: prefix "dt_assisted_<name>_".
local temp_seq = 0
function C.temp_base(dir, prefix)
    temp_seq = temp_seq + 1
    return string.format("%s/%s%d_%d_", dir, prefix, os.time(), temp_seq)
end

-- Removes `dir`'s files named <prefix><epoch>… whose epoch is more than `max_age`
-- seconds before `now`: leftovers of crashed or killed instances. Returns the names removed.
function C.sweep_temp(dir, prefix, max_age, now, windows)
    now = now or os.time()
    local removed = {}
    for _, name in ipairs(C.list_dir(dir, windows)) do
        if name:sub(1, #prefix) == prefix then
            local epoch = tonumber(name:sub(#prefix + 1):match("^(%d+)_"))
            if epoch and now - epoch > max_age and os.remove(dir .. "/" .. name) then
                removed[#removed + 1] = name
            end
        end
    end
    return removed
end

-- Library key ------------------------------------------------------------------
-- Image ids restart at 1 in every library, so a ledger row carries the library it
-- belongs to: the FNV-1a hash of the library file's path.

function C.fnv1a(text)
    local h = 2166136261
    for i = 1, #text do h = ((h ~ text:byte(i)) * 16777619) & 0xffffffff end
    return string.format("%08x", h)
end

-- The library file's path as darktable's `database` preference holds it, made absolute
-- against the config directory and normalised. `--library` on the command line isn't
-- written to that preference, so such a library reads as the configured one.
function C.library_path(dt)
    local ok, name = pcall(dt.preferences.read, "darktable", "database", "string")
    name = (ok and name and name ~= "") and name or "library.db"
    if name ~= ":memory:" and not name:match("^/") and not name:match("^%a:[/\\]") then
        name = dt.configuration.config_dir .. "/" .. name
    end
    return (name:gsub("\\", "/"):gsub("/+", "/"))
end

function C.library_key(dt)
    local path = C.library_path(dt)
    if C.IS_WINDOWS then path = path:lower() end
    return C.fnv1a(path)
end

-- The per-frame vehicle detection cache culling and tagging share (python creates the folder).
-- One value: gsub's count must not follow the path into an argument list.
function C.detections_path(dt)
    return ((dt.configuration.config_dir .. "/assisted_plugins/detections.sqlite"):gsub("\\", "/"):gsub("/+", "/"))
end

-- Drops a ledger's entries (numeric keys: image ids) whose image `exists(id)` no longer
-- finds. Returns how many went, and whether the prune was skipped: when no id at all
-- resolves the lookup is what failed, not every image gone.
function C.ledger_prune(ledger, exists)
    local gone, kept = {}, 0
    for id in pairs(ledger) do
        if type(id) == "number" then
            if exists(id) then kept = kept + 1 else gone[#gone + 1] = id end
        end
    end
    if kept == 0 then return 0, #gone > 0 end
    for _, id in ipairs(gone) do ledger[id] = nil end
    return #gone, false
end

-- Plugin helpers ---------------------------------------------------------------
-- Used identically by the three plugins; each passes in the darktable handles it holds.

-- An EXIF "YYYY:MM:DD HH:MM:SS" as epoch seconds, nil when absent, malformed or before 1970.
function C.exif_time_to_epoch(s)
    if not s then return nil end
    local y, mo, d, h, mi, se = s:match("(%d+):(%d+):(%d+) (%d+):(%d+):(%d+)")
    -- Before 1970 (a zero date, an old scan) os.time raises on Windows: undated.
    if not y or tonumber(y) < 1970 then return nil end
    local ok, epoch = pcall(os.time, {
        year = tonumber(y), month = tonumber(mo), day = tonumber(d),
        hour = tonumber(h), min = tonumber(mi), sec = tonumber(se),
        isdst = false, -- constant offset, so a DST change can't split a burst
    })
    return ok and epoch or nil
end

-- " | ~4m 05s left" for a run `done` of `total` after `elapsed` seconds; "" while too early or finished.
function C.fmt_eta(elapsed, done, total)
    if elapsed < 3 or done <= 0 or done >= total then return "" end
    local remaining = math.ceil(elapsed * (total - done) / done)
    return string.format(" | ~%dm %02ds left", remaining // 60, remaining % 60)
end

-- Whether image `id` is still in the library (`dt` is darktable's module). A get_image error counts as
-- gone, as does a stale image whose fields can't be read.
function C.image_exists(dt, id)
    local ok, name = pcall(function()
        local img = dt.database.get_image(id)
        return img and img.filename
    end)
    return ok and name ~= nil
end

-- Writes `rows` (field lists) to `path` as CSV lines; false when the file can't be opened.
function C.write_rows(path, rows)
    local f = io.open(path, "w")
    if not f then return false end
    for _, r in ipairs(rows) do f:write(C.csv_line(r), "\n") end
    f:close()
    return true
end

-- { [tag name] = true } for image `img` (`tags` is darktable's dt.tags).
function C.tags_of(tags, img)
    local have = {}
    for _, t in ipairs(tags.get_tags(img)) do have[t.name] = true end
    return have
end

-- The plugin's folder: the preference `folder` when set, else the parent of the python/ folder
-- holding `script`, else the folder of `script` (`this_dir` when there is no script).
function C.plugin_root(folder, script, this_dir)
    if folder ~= "" then return folder end
    local script_dir = (script and script:match("^(.*)[/\\]")) or this_dir
    return script_dir:match("^(.*)[/\\]python$") or script_dir
end

-- The Python to run: the plugin's .venv when it has one, else the system python (`df` is
-- lib/dtutils.file).
function C.python_bin(root, this_dir, is_windows, df)
    local found = C.first_existing({
        root .. "/.venv/Scripts/python.exe",
        root .. "/.venv/bin/python",
        this_dir .. "/../.venv/Scripts/python.exe",
        this_dir .. "/../.venv/bin/python",
    })
    if found then return found end
    local v = df.check_if_bin_exists(is_windows and "python" or "python3")
    if not v then
        v = is_windows and "python" or "python3"
    end
    return v
end

-- CSV --------------------------------------------------------------------------
-- The manifests and results the plugins trade with their Python helpers.

function C.csv_line(fields)
    local out = {}
    for i, v in ipairs(fields) do
        out[i] = '"' .. tostring(v):gsub('"', '""') .. '"'
    end
    return table.concat(out, ",")
end

-- One CSV line → its fields, honouring "quoted, fields" and "" escapes (what Python's csv
-- module writes). A trailing \r is dropped: csv.writer ends rows with \r\n and only Windows
-- text mode strips it.
function C.parse_csv_fields(line)
    line = line:gsub("\r$", "")
    local fields, i, n = {}, 1, #line
    while i <= n + 1 do
        local value
        if line:sub(i, i) == '"' then
            local j = i + 1
            local buf = {}
            while j <= n do
                local c = line:sub(j, j)
                if c == '"' then
                    if line:sub(j + 1, j + 1) == '"' then buf[#buf + 1] = '"'; j = j + 2
                    else break end
                else
                    buf[#buf + 1] = c; j = j + 1
                end
            end
            value = table.concat(buf)
            i = j + 2
        else
            local j = line:find(",", i, true) or (n + 1)
            value = line:sub(i, j - 1)
            i = j + 1
        end
        fields[#fields + 1] = value
    end
    return fields
end

-- The line's fields when there are exactly n of them, else nil.
function C.parse_csv_line(line, n)
    local fields = C.parse_csv_fields(line)
    if #fields ~= n then return nil end
    return fields
end

-- Python ------------------------------------------------------------------------

-- python.exe → the pythonw.exe beside it (venvs and python.org installs ship both),
-- which opens no console window. nil for any other name.
function C.pythonw_of(py)
    local dir, name = py:match("^(.-)([^/\\]*)$")
    name = name:lower()
    if name == "python.exe" then return dir .. "pythonw.exe" end
    if name == "python" then return dir .. "pythonw" end
    return nil
end

-- One argument quoted for the shell. Windows: cmd.exe keeps everything inside double quotes
-- literal except a `%NAME%` of a set variable, which a command line can't escape (doubling `%`
-- works only in batch files), and a path can't hold `"`; a `"` in any other argument is passed
-- through as \" for the C runtime. `windows` overrides the platform (tests).
function C.shell_quote(s, windows)
    if windows == nil then windows = C.IS_WINDOWS end
    if windows then return '"' .. s:gsub('"', '\\"') .. '"' end
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- "py -u argv..." quoted for the shell: the log line, and the launch off Windows.
function C.command_line(py, argv)
    local parts = { C.shell_quote(py), "-u" }
    for _, a in ipairs(argv) do parts[#parts + 1] = C.shell_quote(a) end
    return table.concat(parts, " ")
end

-- Starts `py -u argv...` without waiting, stderr to err_path (appended when `append`).
-- The exit code goes to a temp file renamed onto done_path, so done_path never exists
-- without its code in it. On Windows python/launch.py runs it under pythonw.exe: no
-- console window, no script host, nothing executable written to tmp (antivirus
-- behaviour checks flag a hidden .vbs/.bat chain). Returns false plus why it didn't start.
function C.run_async_python(py, argv, err_path, append, done_path)
    if C.IS_WINDOWS then
        local pyw = C.pythonw_of(py)
        if not pyw then return false, "the Python preference must point at a python.exe" end
        if pyw:find("[/\\]") and not C.file_exists(pyw) then return false, pyw .. " is missing" end
        local job = done_path .. ".job"
        local f = io.open(job, "w")
        if not f then return false, "no write access to darktable's tmp folder" end
        f:write(done_path, "\n", err_path, "\n", append and "a" or "w", "\n", table.concat(argv, "\n"), "\n")
        f:close()
        local launcher = (argv[1]:match("^(.*)[/\\]") or ".") .. "/launch.py"
        local ok = os.execute('start "" /B ' .. C.shell_quote((pyw:gsub("/", "\\")))
            .. " " .. C.shell_quote((launcher:gsub("/", "\\"))) .. " " .. C.shell_quote((job:gsub("/", "\\"))))
        if not ok then
            pcall(os.remove, job)
            return false, pyw .. " didn't start"
        end
        return true
    end
    local done_tmp = done_path .. ".tmp"
    os.execute('( ' .. C.command_line(py, argv) .. (append and " 2>> " or " 2> ") .. C.shell_quote(err_path)
        .. ' ; echo $? > ' .. C.shell_quote(done_tmp)
        .. ' ; mv -f ' .. C.shell_quote(done_tmp) .. ' ' .. C.shell_quote(done_path) .. ' ) >/dev/null 2>&1 &')
    return true
end

-- Writes ------------------------------------------------------------------------

-- Paced tag/group writes: every attach, detach or group change rewrites an XMP sidecar, so
-- after `budget` writes the GUI gets `sleep_ms`. w.write(fn, weight) runs fn under pcall and
-- counts it as `weight` writes (default 1); w.failed and w.first_error say what went wrong.
-- w.call_s is the seconds spent inside the write calls (os.clock: wall time on Windows) and
-- w.sleeps the number of pauses, for the timing line in the log. With `log`, a failed
-- write logs "<what> failed: <error>" at once; `what` names the image and the operation.
function C.paced_writer(dt, budget, sleep_ms, log)
    local w = { writes = 0, failed = 0, first_error = nil, call_s = 0, sleeps = 0 }
    function w.write(fn, weight, what)
        local call_start = os.clock()
        local okw, werr = pcall(fn)
        w.call_s = w.call_s + os.clock() - call_start
        if not okw then
            w.failed = w.failed + 1
            w.first_error = w.first_error or tostring(werr)
            if log then log((what or "write") .. " failed: " .. tostring(werr)) end
        end
        w.writes = w.writes + (weight or 1)
        if w.writes >= budget then
            w.writes = 0
            w.sleeps = w.sleeps + 1
            dt.control.sleep(sleep_ms)
        end
        return okw
    end
    return w
end

-- Presets -----------------------------------------------------------------------
-- Presets are flat JSON objects: string, number and boolean values only, so a small codec
-- does instead of a JSON library (test_preset_block.lua is the matching tests).
-- Schema item: { key, kind = "bool"|"string"|"number"|"choice", default, choices }.

local function utf8_char(cp)
    if cp < 0x80 then return string.char(cp) end
    if cp < 0x800 then return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40) end
    if cp < 0x10000 then
        return string.char(0xE0 + math.floor(cp / 0x1000), 0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
    end
    return string.char(0xF0 + math.floor(cp / 0x40000), 0x80 + math.floor(cp / 0x1000) % 0x40,
        0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
end

local JSON_ESCAPES = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }

-- Returns the decoded flat object, or nil and why.
function C.preset_decode(text)
    if type(text) ~= "string" then return nil, "no text" end
    local pos = 1
    if text:sub(1, 3) == "\239\187\191" then pos = 4 end
    local function skip() pos = text:find("[^ \t\r\n]", pos) or (#text + 1) end
    local function fail(why) return nil, string.format("%s at character %d", why, pos) end
    local function read_string()
        pos = pos + 1 -- opening quote
        local out = {}
        while true do
            local c = text:sub(pos, pos)
            if c == "" then return nil end
            if c == '"' then pos = pos + 1; return table.concat(out) end
            if c == "\\" then
                local e = text:sub(pos + 1, pos + 1)
                if e == "u" then
                    local cp = tonumber(text:sub(pos + 2, pos + 5), 16)
                    if not cp or #text:sub(pos + 2, pos + 5) ~= 4 then return nil end
                    pos = pos + 6
                    if cp >= 0xD800 and cp <= 0xDBFF and text:sub(pos, pos + 1) == "\\u" then
                        local lo = tonumber(text:sub(pos + 2, pos + 5), 16)
                        if lo and lo >= 0xDC00 and lo <= 0xDFFF then
                            cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
                            pos = pos + 6
                        end
                    end
                    out[#out + 1] = utf8_char(cp)
                elseif JSON_ESCAPES[e] then
                    out[#out + 1] = JSON_ESCAPES[e]
                    pos = pos + 2
                else
                    return nil
                end
            else
                local stop = text:find('["\\]', pos) or (#text + 1)
                out[#out + 1] = text:sub(pos, stop - 1)
                pos = stop
            end
        end
    end

    skip()
    if text:sub(pos, pos) ~= "{" then return fail("expected {") end
    pos = pos + 1
    local obj = {}
    skip()
    if text:sub(pos, pos) == "}" then
        pos = pos + 1
    else
        while true do
            skip()
            if text:sub(pos, pos) ~= '"' then return fail("expected a key") end
            local key = read_string()
            if not key then return fail("bad key") end
            skip()
            if text:sub(pos, pos) ~= ":" then return fail("expected :") end
            pos = pos + 1
            skip()
            local c = text:sub(pos, pos)
            if c == '"' then
                local v = read_string()
                if not v then return fail("bad string") end
                obj[key] = v
            elseif c == "t" and text:sub(pos, pos + 3) == "true" then
                obj[key] = true; pos = pos + 4
            elseif c == "f" and text:sub(pos, pos + 4) == "false" then
                obj[key] = false; pos = pos + 5
            elseif c == "n" and text:sub(pos, pos + 3) == "null" then
                obj[key] = nil; pos = pos + 4
            elseif c == "{" or c == "[" then
                return fail("nested values aren't supported")
            else
                local num = text:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
                local v = num and tonumber(num)
                if not v then return fail("bad value") end
                obj[key] = v
                pos = pos + #num
            end
            skip()
            local sep = text:sub(pos, pos)
            pos = pos + 1
            if sep == "}" then break end
            if sep ~= "," then pos = pos - 1; return fail("expected , or }") end
        end
    end
    skip()
    if pos <= #text then return fail("unexpected text after }") end
    return obj
end

local function json_string(s)
    return '"' .. s:gsub('[%c"\\]', function(c)
        if c == '"' then return '\\"' end
        if c == "\\" then return "\\\\" end
        if c == "\n" then return "\\n" end
        if c == "\r" then return "\\r" end
        if c == "\t" then return "\\t" end
        return string.format("\\u%04x", c:byte())
    end) .. '"'
end

local function json_number(n)
    if n == math.floor(n) and math.abs(n) < 2 ^ 53 then return string.format("%d", n) end
    return string.format("%.14g", n)
end

-- One key per line in schema order, "version" first.
function C.preset_encode(schema, settings)
    local lines = { '  "version": 1' }
    for _, item in ipairs(schema) do
        local v = settings[item.key]
        if v == nil then v = item.default end
        local text
        if type(v) == "boolean" then text = tostring(v)
        elseif type(v) == "number" then text = json_number(v)
        else text = json_string(tostring(v)) end
        lines[#lines + 1] = "  " .. json_string(item.key) .. ": " .. text
    end
    return "{\n" .. table.concat(lines, ",\n") .. "\n}\n"
end

local function preset_value_ok(item, v)
    if item.kind == "bool" then return type(v) == "boolean" end
    if item.kind == "number" then return type(v) == "number" end
    if item.kind == "string" then return type(v) == "string" end
    if type(v) ~= "string" then return false end
    for _, c in ipairs(item.choices or {}) do
        if c == v then return true end
    end
    return false
end

function C.preset_defaults(schema)
    local out = {}
    for _, item in ipairs(schema) do out[item.key] = item.default end
    return out
end

-- Every schema key set: the decoded value when valid, else the default. Returns the
-- settings and the keys whose stored value was unusable (missing keys aren't problems;
-- a stored "" for a number or bool key counts as missing).
function C.preset_merge(schema, decoded)
    local out, problems = {}, {}
    for _, item in ipairs(schema) do
        local v = decoded and decoded[item.key]
        if v == nil or (v == "" and (item.kind == "number" or item.kind == "bool")) then
            out[item.key] = item.default
        elseif preset_value_ok(item, v) then
            out[item.key] = v
        else
            out[item.key] = item.default
            problems[#problems + 1] = item.key
        end
    end
    return out, problems
end

function C.preset_equal(schema, a, b)
    for _, item in ipairs(schema) do
        if a[item.key] ~= b[item.key] then return false end
    end
    return true
end

-- Same characters as a folder name can't hold on Windows; "template" is the built-in preset.
function C.preset_name_ok(raw)
    local name = (raw or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then return nil, "empty" end
    if name:lower() == "template" then return nil, "reserved" end
    if name:find('[/\\:*?"<>|]') then return nil, "bad character" end
    return name
end

-- "template" first, then the names sorted case-insensitively, without duplicates.
function C.preset_order(names)
    local seen, rest = {}, {}
    for _, n in ipairs(names) do
        if n:lower() ~= "template" and not seen[n] then
            seen[n] = true
            rest[#rest + 1] = n
        end
    end
    table.sort(rest, function(x, y)
        local lx, ly = x:lower(), y:lower()
        if lx == ly then return x < y end
        return lx < ly
    end)
    table.insert(rest, 1, "template")
    return rest
end

-- Preset bundles: export writes <folder>/<name>.atpreset/ holding manifest.json, preset.json
-- and any files the plugin's store adds (tagging: entries.json). BUNDLE_VERSION goes up when
-- the layout changes in a way an older plugin can't read.
C.PRESET_BUNDLE_VERSION = 1

-- `files`: the bundle's file names (none holds a comma), `date`: "YYYY-MM-DD".
function C.preset_manifest(plugin, name, files, date)
    return "{\n" .. table.concat({
        '  "version": ' .. C.PRESET_BUNDLE_VERSION,
        '  "plugin": ' .. json_string(plugin),
        '  "preset": ' .. json_string(name),
        '  "files": ' .. json_string(table.concat(files, ",")),
        '  "exported": ' .. json_string(date),
    }, ",\n") .. "\n}\n"
end

-- The manifest's preset name and file list, or nil and why it can't be imported here.
function C.preset_bundle_check(text, plugin)
    local m, err = C.preset_decode(text)
    if not m then return nil, "manifest.json: " .. err end
    if type(m.plugin) ~= "string" or type(m.preset) ~= "string" or type(m.files) ~= "string"
        or type(m.version) ~= "number" then
        return nil, "manifest.json isn't a preset bundle manifest"
    end
    if m.plugin ~= plugin then return nil, string.format("the bundle is for %s, not this plugin", m.plugin) end
    if m.version > C.PRESET_BUNDLE_VERSION then
        return nil, string.format("the bundle is version %d; this plugin reads up to %d, update it first",
            m.version, C.PRESET_BUNDLE_VERSION)
    end
    local files = {}
    for f in m.files:gmatch("[^,]+") do files[#files + 1] = f end
    return { preset = m.preset, files = files }
end

-- `name`, or `name (2)`, `name (3)`… when `taken` holds it (any case); "template" counts as taken.
function C.preset_free_name(name, taken)
    local have = { template = true }
    for _, n in ipairs(taken) do have[n:lower()] = true end
    local out, i = name, 1
    while have[out:lower()] do
        i = i + 1
        out = string.format("%s (%d)", name, i)
    end
    return out
end

-- A page table is { title = string, keys = { string, ... } }: one panel page and the preset keys its
-- widgets edit. The stored page number is used when it is in 1..count, else the first page.
function C.page_index(stored, count)
    if type(stored) == "number" and stored >= 1 and stored <= count then return stored end
    return 1
end

-- Schema keys that no page and no `other` entry covers, and keys listed more than once; both sorted.
function C.page_coverage(pages, other, schema)
    local seen, missing, duplicate = {}, {}, {}
    local function count(key) seen[key] = (seen[key] or 0) + 1 end
    for _, page in ipairs(pages) do
        for _, key in ipairs(page.keys) do count(key) end
    end
    for _, key in ipairs(other) do count(key) end
    for _, entry in ipairs(schema) do
        if not seen[entry.key] then missing[#missing + 1] = entry.key end
    end
    for key, n in pairs(seen) do
        if n > 1 then duplicate[#duplicate + 1] = key end
    end
    table.sort(missing)
    table.sort(duplicate)
    return missing, duplicate
end

local dt_ok, dt = pcall(require, "darktable")
if not dt_ok then return C end

-- Preset controls ------------------------------------------------------------------
-- The preset picker and actions menu at the top of the panel. Lua panels can't use darktable's
-- own presets (lualib.c leaves get_params/set_params NULL), so this builds its own.
-- Combobox callbacks run later and fire on every `selected` assignment, so each one acts
-- only when the widget's value differs from `current`.

local PRESET_WHY = {
    empty = "type a name first",
    reserved = '"template" is the built-in preset',
    ["bad character"] = 'a name can\'t hold / \\ : * ? " < > |',
}

-- Makes `dir` and any missing parents; quiet when it exists.
function C.make_dir(dir)
    local windows = C.IS_WINDOWS
    local quoted = windows and ('"' .. dir:gsub("/", "\\") .. '"') or ("'" .. dir:gsub("'", "'\\''") .. "'")
    os.execute((windows and "mkdir " or "mkdir -p ") .. quoted .. (windows and " 2>nul" or " 2>/dev/null"))
end

-- True when `path` (file or folder) exists.
function C.path_exists(path)
    return os.rename(path, path) and true or false
end

-- Copies folder `from` with everything under it to `to`, which must not exist yet.
function C.copy_tree(from, to)
    if C.IS_WINDOWS then
        local _ok, _how, code = os.execute('robocopy ' .. C.shell_quote((from:gsub("/", "\\"))) .. ' '
            .. C.shell_quote((to:gsub("/", "\\"))) .. ' /E /NFL /NDL /NJH /NJS /NP >nul')
        return code ~= nil and code < 8 -- robocopy: 0-7 success, 8+ failure
    end
    return os.execute("cp -R " .. C.shell_quote(from) .. " " .. C.shell_quote(to)) and true or false
end

-- Presets as <dir>/<name>.json. The folder is made on first use.
function C.preset_file_store(dir)
    local windows = C.IS_WINDOWS
    C.make_dir(dir)
    local store = {}
    function store.path(name) return dir .. "/" .. name .. ".json" end
    function store.list()
        local names = {}
        for _, entry in ipairs(C.list_dir(dir, windows)) do
            local name = entry:match("^(.+)%.json$")
            if name then names[#names + 1] = name end
        end
        return names
    end
    -- Falls back to <name>.json.tmp: what a crash between write_file_atomic's remove and rename leaves.
    function store.read(name) return C.read_file_or_tmp(store.path(name)) end
    function store.write(name, text) return C.write_file_atomic(store.path(name), text) and true or false end
    function store.rename(old, new)
        local ok, err = os.rename(store.path(old), store.path(new))
        return ok and true or false, err
    end
    function store.remove(name)
        local ok, err = os.remove(store.path(name))
        return ok and true or false, err
    end
    return store
end

-- o = { prefix, plugin (bundle id, e.g. "assisted_grouping"), schema, store,
--       read_panel = fn() -> settings | nil, why,
--       show = fn(settings), remember = fn(name), initial = name, log = fn(msg),
--       on_change = fn(name, is_template) | nil, can_switch = fn() -> ok, why | nil,
--       allow_store_new = bool, plugin_folder = fn() -> path or "" }
-- Export writes <plugin_folder()>/exports/<name>.atpreset; with no folder set, the folder above
-- this file's lua/ folder.
-- Optional store.copy_note(from, to) -> confirm text | nil, why and store.copy(from, to) -> ok, err:
-- store new then asks first, and copies the selected preset's store (e.g. a folder) before writing.
-- Optional store.export_files(name, picked) -> { { name, path | dir }, ... } adds files (path) or
-- folders (dir, copied whole) to an exported bundle, and store.import_files(name, bundle_dir, files)
-- -> ok, err puts them in place before import writes the preset. Optional store.export_options =
-- { { key, label, tooltip }, ... } adds a tick box per key to the export box, unticked each time it
-- opens; picked[key] is true for the ticked ones. Optional store.export_label(name, key) -> text
-- relabels a box as the export box opens (e.g. with its size).
-- Returns ctl: ctl.widget (the box to put first in the panel), ctl.widgets, ctl.select(name),
-- ctl.refresh(), ctl.reload(), ctl.check_dirty(), ctl.name(), ctl.saved (settings last loaded or saved).
function C.make_preset_controls(o)
    local ctl = { widgets = {} }
    local names, current, menu_actions = { "template" }, nil, {}
    local name_mode
    local picker, menu, name_entry, name_box, confirm_label, confirm_box, dirty_label
    local confirm_button, confirm_action, delete_clicked
    local export_box, import_box, import_chooser
    local export_checks = {} -- key -> check_button, one per store.export_options entry

    -- Store and preset messages start lowercase; a toast reads as a sentence after the prefix.
    local function say(msg)
        msg = msg:gsub("^%l", string.upper)
        if not msg:find("[.?!…]$") then msg = msg .. "." end
        dt.print(o.prefix .. ": " .. msg)
    end

    local function index_of(name)
        for i, n in ipairs(names) do
            if n == name then return i end
        end
    end

    local function set_entries(combo, items)
        for i = #combo, 1, -1 do combo[i] = nil end
        for i, text in ipairs(items) do combo[i] = text end
    end

    local function show_picker(name)
        local i = index_of(name)
        if i and picker.selected ~= i then picker.selected = i end
    end

    -- Loads `name` into the panel. False (values untouched) when the file can't be used.
    local function load(name)
        local settings
        if name == "template" then
            settings = C.preset_defaults(o.schema)
        else
            local text = o.store.read(name)
            local decoded, err
            if text then decoded, err = C.preset_decode(text) else err = "can't be read" end
            if not decoded then
                local msg = string.format('preset "%s": %s %s, panel unchanged', name, o.store.path(name), err)
                o.log(msg)
                say(msg)
                return false
            end
            local problems
            settings, problems = C.preset_merge(o.schema, decoded)
            for _, key in ipairs(problems) do
                o.log(string.format('preset "%s": %s invalid, using default', name, key))
            end
            if #problems > 0 then
                say(string.format('preset "%s": %d invalid value(s) set to the default (see the log)', name, #problems))
            end
        end
        ctl.saved = settings
        o.show(settings)
        return true
    end

    local function hide_boxes()
        name_box.visible = false
        confirm_box.visible = false
        export_box.visible = false
        import_box.visible = false
    end

    local function ask_name(mode)
        name_mode = mode
        name_entry.text = mode == "rename" and current or ""
        hide_boxes()
        name_box.visible = true
    end

    local function update()
        local settings, why = o.read_panel()
        if not settings then say(why); return end
        if not o.store.write(current, C.preset_encode(o.schema, settings)) then
            say("couldn't write " .. o.store.path(current))
            return
        end
        ctl.saved = settings
        say(string.format('preset "%s" updated', current))
        ctl.check_dirty()
    end

    local function ask_confirm(text, button, action)
        confirm_label.text = text
        confirm_button.label = button
        confirm_action = action
        hide_boxes()
        confirm_box.visible = true
    end

    local function ask_delete()
        ask_confirm(string.format('Delete preset "%s"?', current), "Delete", delete_clicked)
    end

    local function set_menu()
        local items = { "choose…" }
        menu_actions = { false }
        local function add(text, action)
            items[#items + 1] = text
            menu_actions[#menu_actions + 1] = action
        end
        if current ~= "template" then add(string.format('update preset "%s"', current), update) end
        if o.allow_store_new then add("store new preset…", function() ask_name("store") end) end
        if current ~= "template" then
            add("rename preset…", function() ask_name("rename") end)
            add("delete preset", ask_delete)
            add("export preset…", function()
                hide_boxes()
                for _, opt in ipairs(o.store.export_options or {}) do
                    export_checks[opt.key].value = false
                    export_checks[opt.key].label = o.store.export_label and o.store.export_label(current, opt.key) or opt.label
                end
                export_box.visible = true
            end)
        end
        if o.allow_store_new then add("import preset…", function() hide_boxes(); import_box.visible = true end) end
        set_entries(menu, items)
        menu.selected = 1
    end

    function ctl.name() return current end

    -- "Unsaved Changes" when the panel differs from the file. Template has no file.
    function ctl.check_dirty()
        local dirty = false
        if current ~= "template" and ctl.saved then
            local settings = o.read_panel()
            dirty = not settings or not C.preset_equal(o.schema, settings, ctl.saved)
        end
        dirty_label.visible = dirty
        return dirty
    end

    function ctl.select(name)
        if name ~= "template" and not index_of(name) then name = "template" end
        if current and o.can_switch then
            local ok, why = o.can_switch()
            if not ok then say(why); show_picker(current); return false end
        end
        if not load(name) then
            if current then show_picker(current) else ctl.select("template") end
            return false
        end
        current = name
        show_picker(name)
        o.remember(name)
        hide_boxes()
        set_menu()
        if o.on_change then o.on_change(name, name == "template") end
        ctl.check_dirty()
        return true
    end

    -- Rereads the selected preset's file into the panel, dropping unsaved panel changes.
    -- False (panel untouched) when the file can't be used.
    function ctl.reload()
        if not current or not load(current) then return false end
        ctl.check_dirty()
        return true
    end

    -- Rereads the preset list. A selected preset that has gone falls back to template.
    function ctl.refresh()
        names = C.preset_order(o.store.list())
        set_entries(picker, names)
        if current and not index_of(current) then
            current = nil
            ctl.select("template")
        elseif current then
            show_picker(current)
        end
    end

    local function name_taken(name)
        for _, n in ipairs(o.store.list()) do
            if n:lower() == name:lower() and not (name_mode == "rename" and n == current) then return true end
        end
        return false
    end

    local function name_ok_clicked()
        local name, why = C.preset_name_ok(name_entry.text)
        if not name then say("preset name: " .. PRESET_WHY[why]); return end
        if name_taken(name) then say(string.format('a preset called "%s" already exists', name)); return end
        if name_mode == "store" then
            local settings, bad = o.read_panel()
            if not settings then say(bad); return end
            local from = current
            local function store_new()
                if o.store.copy then
                    local ok, err = o.store.copy(from, name)
                    if not ok then say(string.format('couldn\'t copy "%s": %s', from, tostring(err))); return end
                end
                if not o.store.write(name, C.preset_encode(o.schema, settings)) then
                    say("couldn't write " .. o.store.path(name))
                    return
                end
                hide_boxes()
                ctl.refresh()
                ctl.select(name)
            end
            if o.store.copy_note then
                local text, why = o.store.copy_note(from, name)
                if not text then say(why); return end
                ask_confirm(text, "Store", store_new)
                return
            end
            store_new()
        else
            local ok, err = o.store.rename(current, name)
            if not ok then say(string.format('couldn\'t rename "%s": %s', current, tostring(err))); return end
            name_box.visible = false
            current = name
            ctl.refresh()
            o.remember(name)
            set_menu()
        end
    end

    delete_clicked = function()
        local ok, err = o.store.remove(current)
        if not ok then say(string.format('couldn\'t delete "%s": %s', current, tostring(err))); return end
        confirm_box.visible = false
        say(string.format('preset "%s" deleted', current))
        ctl.refresh()
    end

    -- The saved preset, not the panel: unsaved changes stay out and the message says so.
    local function export_clicked()
        local text = o.store.read(current)
        if not text then say("couldn't read " .. o.store.path(current)); return end
        local root = o.plugin_folder and o.plugin_folder() or ""
        local folder = (root ~= "" and root or PLUGIN_DIR) .. "/exports"
        local bundle, i = folder .. "/" .. current .. ".atpreset", 1
        while C.path_exists(bundle) do
            i = i + 1
            bundle = string.format("%s/%s (%d).atpreset", folder, current, i)
        end
        C.make_dir(bundle)
        local picked = {}
        for key, check in pairs(export_checks) do picked[key] = check.value and true or nil end
        local files = { { name = "preset.json", text = text } }
        for _, f in ipairs(o.store.export_files and o.store.export_files(current, picked) or {}) do
            if f.dir then
                files[#files + 1] = f
            else
                local body = C.read_file(f.path)
                if not body then say("couldn't read " .. f.path); return end
                files[#files + 1] = { name = f.name, text = body }
            end
        end
        local names = {}
        for _, f in ipairs(files) do
            names[#names + 1] = f.name
            local ok
            if f.dir then ok = C.copy_tree(f.dir, bundle .. "/" .. f.name)
            else ok = C.write_file_atomic(bundle .. "/" .. f.name, f.text) end
            if not ok then
                say("couldn't write " .. bundle .. "/" .. f.name)
                return
            end
        end
        local manifest = C.preset_manifest(o.plugin, current, names, os.date("%Y-%m-%d"))
        if not C.write_file_atomic(bundle .. "/manifest.json", manifest) then
            say("couldn't write " .. bundle .. "/manifest.json")
            return
        end
        export_box.visible = false
        local msg = string.format('preset "%s" exported to %s', current, bundle)
        o.log(msg .. " (" .. table.concat(names, ", ") .. ")")
        say(msg .. (ctl.check_dirty() and "; unsaved panel changes aren't in it" or ""))
    end

    -- Adds the bundle as a new preset (renamed when the name is taken) without switching to it,
    -- so unsaved panel changes stay.
    local function import_clicked()
        local bundle = import_chooser.value
        if not bundle or bundle == "" then say("pick the .atpreset folder first"); return end
        local manifest_text = C.read_file(bundle .. "/manifest.json")
        if not manifest_text then say(bundle .. " has no manifest.json: pick the .atpreset folder"); return end
        local m, why = C.preset_bundle_check(manifest_text, o.plugin)
        if not m then say(why); return end
        local text = C.read_file(bundle .. "/preset.json")
        local decoded, err
        if text then decoded, err = C.preset_decode(text) else err = "is missing" end
        if not decoded then say(bundle .. "/preset.json " .. err); return end
        local name, bad = C.preset_name_ok(m.preset)
        if not name then say("the bundle's preset name: " .. PRESET_WHY[bad]); return end
        name = C.preset_free_name(name, o.store.list())
        if o.store.import_files then
            local ok, ierr = o.store.import_files(name, bundle, m.files)
            if not ok then say(string.format('couldn\'t import "%s": %s', m.preset, tostring(ierr))); return end
        end
        if not o.store.write(name, text) then say("couldn't write " .. o.store.path(name)); return end
        import_box.visible = false
        ctl.refresh()
        local msg = string.format('imported "%s" from %s', name, bundle)
        o.log(msg)
        say(msg .. (name ~= m.preset and string.format(' ("%s" was taken)', m.preset) or "") .. ". Pick it in the preset list.")
    end

    picker = dt.new_widget("combobox") {
        label = "Preset",
        tooltip = "Pick a saved set of panel settings. template = the defaults. With unsaved changes, switching asks first: Switch drops them. Save with actions → update preset.",
        changed_callback = function(self)
            local name = self.value
            if not (current and name and name ~= "" and name ~= current) then return end
            if ctl.check_dirty() then
                show_picker(current)
                ask_confirm(string.format('Drop unsaved changes and switch to "%s"?', name), "Switch",
                    function() hide_boxes(); ctl.select(name) end)
                return
            end
            ctl.select(name)
        end,
        "template",
    }
    menu = dt.new_widget("combobox") {
        label = "Actions",
        tooltip = "Preset actions: update the selected preset with the panel's values, store the panel as a new preset, rename, delete, export to the plugin's exports folder, or import a bundle.",
        changed_callback = function(self)
            local i = self.selected
            if not i or i <= 1 then return end
            local action = menu_actions[i]
            self.selected = 1
            if action then ctl.check_dirty(); action() end
        end,
        "choose…",
    }
    dirty_label = dt.new_widget("label") { label = "Unsaved Changes", halign = "start", visible = false }
    name_entry = dt.new_widget("entry") { placeholder = "preset name", text = "" }
    name_box = dt.new_widget("box") {
        orientation = "vertical",
        visible = false,
        name_entry,
        dt.new_widget("box") {
            orientation = "horizontal",
            dt.new_widget("button") { label = "OK", clicked_callback = name_ok_clicked },
            dt.new_widget("button") { label = "Cancel", clicked_callback = function() name_box.visible = false end },
        },
    }
    confirm_label = dt.new_widget("text_view") { editable = false, text = "" }
    confirm_button = dt.new_widget("button") {
        label = "Delete",
        clicked_callback = function() if confirm_action then confirm_action() end end,
    }
    confirm_box = dt.new_widget("box") {
        orientation = "vertical",
        visible = false,
        confirm_label,
        dt.new_widget("box") {
            orientation = "horizontal",
            confirm_button,
            dt.new_widget("button") { label = "Cancel", clicked_callback = function() confirm_box.visible = false end },
        },
    }
    local export_parts = {
        orientation = "vertical",
        visible = false,
        dt.new_widget("label") { label = "Export to the Plugin's exports Folder", halign = "start" },
    }
    for _, opt in ipairs(o.store.export_options or {}) do
        export_checks[opt.key] = dt.new_widget("check_button") { label = opt.label, tooltip = opt.tooltip, value = false }
        export_parts[#export_parts + 1] = export_checks[opt.key]
    end
    export_parts[#export_parts + 1] = dt.new_widget("box") {
        orientation = "horizontal",
        dt.new_widget("button") { label = "Export", clicked_callback = export_clicked },
        dt.new_widget("button") { label = "Cancel", clicked_callback = function() export_box.visible = false end },
    }
    export_box = dt.new_widget("box")(export_parts)
    import_chooser = dt.new_widget("file_chooser_button") {
        title = "Preset Bundle (.atpreset Folder)",
        is_directory = true,
        tooltip = "A <name>.atpreset folder made by export preset. A preset with the same name is kept: the import gets (2) added.",
    }
    import_box = dt.new_widget("box") {
        orientation = "vertical",
        visible = false,
        dt.new_widget("label") { label = "Import .atpreset Folder", halign = "start" },
        import_chooser,
        dt.new_widget("box") {
            orientation = "horizontal",
            dt.new_widget("button") { label = "Import", clicked_callback = import_clicked },
            dt.new_widget("button") { label = "Cancel", clicked_callback = function() import_box.visible = false end },
        },
    }
    ctl.widgets = { picker = picker, menu = menu, dirty_label = dirty_label, name_box = name_box, confirm_box = confirm_box,
        export_box = export_box, import_box = import_box, import_chooser = import_chooser }
    ctl.widget = dt.new_widget("box") {
        orientation = "vertical",
        dt.new_widget("box") { orientation = "horizontal", picker, menu },
        dirty_label,
        name_box,
        confirm_box,
        export_box,
        import_box,
    }

    ctl.refresh()
    ctl.select(o.initial or "template")
    return ctl
end

-- Pages ------------------------------------------------------------------------
-- Every panel section is a page, run and tools included; the page button is its heading.
-- Pages: { number, title, widgets }. An accordion: each page is a button ("1  title ▸") with its
-- widgets in a box below it. Clicking a button opens that page (its label ends in ▾) and folds the
-- others; clicking the open page folds everything. The open page is stored in preference `page`
-- of `group` (0 = all folded; the next start opens page 1).
function C.paged_sections(group, pages)
    local buttons, bodies, open = {}, {}, 0
    local function show(index)
        open = index
        for i, page in ipairs(pages) do
            bodies[i].visible = i == index
            buttons[i].label = page.number .. "  " .. page.title .. (i == index and " ▾" or " ▸")
        end
    end
    local body = { orientation = "vertical" }
    for i, page in ipairs(pages) do
        buttons[i] = dt.new_widget("button") {
            clicked_callback = function()
                show(open == i and 0 or i)
                dt.preferences.write(group, "page", "integer", open)
            end,
        }
        bodies[i] = dt.new_widget("box")({ orientation = "vertical", table.unpack(page.widgets) })
        body[#body + 1] = buttons[i]
        body[#body + 1] = bodies[i]
    end
    show(C.page_index(dt.preferences.read(group, "page", "integer"), #pages))
    return dt.new_widget("box")(body)
end

-- To Check ---------------------------------------------------------------------
-- What runs leave for the user to look at (failures, photos a run flagged), in a box above the
-- progress line, so a toast that went by unseen isn't lost. A run's items stay until the next run
-- of the same action or Clear. The newest run's items come first; older ones sit below an
-- "Earlier runs" line, as they may not hold after it. They are saved to `path`, one item per line
-- "action<TAB>text<TAB>image id,image id[<TAB>fix[<TAB>detail<US>detail[<TAB>run]]]" (US = \31,
-- run = os.time() when its run began), so a restart keeps them.
C.ALERT_ROWS = 6

-- [{ action, text, ids, fix, details, run }] from the saved file's text; fix is "", details {} and
-- run 0 on a line without them.
function C.alerts_parse(text)
    local items = {}
    for line in (text or ""):gmatch("[^\r\n]+") do
        local action, item, ids_text, fix, details_text, run =
            line:match("^([^\t]*)\t([^\t]*)\t?([^\t]*)\t?([^\t]*)\t?([^\t]*)\t?([^\t]*)$")
        if action then
            local ids, details = {}, {}
            for id in ids_text:gmatch("%d+") do ids[#ids + 1] = tonumber(id) end
            for detail in details_text:gmatch("[^\31]+") do details[#details + 1] = detail end
            items[#items + 1] = { action = action, text = item, ids = ids, fix = fix, details = details,
                                  run = tonumber(run) or 0 }
        end
    end
    return items
end

function C.alerts_format(items)
    local lines = {}
    for _, item in ipairs(items) do
        local fields = {}
        local details = table.concat(item.details or {}, "\31")
        local run = (item.run or 0) > 0 and tostring(item.run) or ""
        for i, field in ipairs({ item.action, item.text, table.concat(item.ids, ","), item.fix or "", details, run }) do
            fields[i] = field:gsub("[\t\r\n]+", " ")
        end
        -- trailing empty fields are left off, so an item without them saves as an older line did
        while #fields > 3 and fields[#fields] == "" do fields[#fields] = nil end
        lines[#lines + 1] = table.concat(fields, "\t")
    end
    return #lines > 0 and table.concat(lines, "\n") .. "\n" or ""
end

-- alerts.widget is the box; alerts.begin(action) starts a run of `action`, dropping its earlier
-- items; its items go above every older run's; alerts.add(text, ids, fix, details) adds an item to the run begun last, with a Select button
-- when `ids` (image ids) has any, and a Fix button when `fix` ("key" or "key:arg") names a function in `fixes`. `details`:
-- one line per photo or burst, "<name>: <why it is listed>", shown read-only under the item's text. Fix removes
-- the item, then calls fixes[key](images, arg). `fixes` may be filled after this call. `new_widget` is
-- the plugin's widget maker; `log` gets save failures.
function C.alerts_box(new_widget, path, log, fixes)
    fixes = fixes or {}
    local alerts = { items = C.alerts_parse(C.read_file_or_tmp(path)) }
    local current, current_run = "", alerts.items[1] and alerts.items[1].run or 0
    local header = new_widget("section_label") { label = "To Check" }
    local rows, more = {}, new_widget("label") { label = "", halign = "start", visible = false }
    local plugin_title = (path:match("assisted_(%a+)%.checks") or "plugin"):gsub("^%l", string.upper)
    plugin_title = "Assisted " .. plugin_title
    local save
    local function images_of(ids)
        local images = {}
        for _, id in ipairs(ids) do images[#images + 1] = dt.database.get_image(id) end
        if #images < #ids then
            dt.print(string.format("%s: Couldn't open %s, no longer in the library.", plugin_title, C.count(#ids - #images, "image")))
        end
        return images
    end
    for i = 1, C.ALERT_ROWS do
        -- read-only text views: darktable's label can't wrap, a text view wraps at the panel's width
        local row = { label = new_widget("text_view") { editable = false, text = "" },
                      details = new_widget("text_view") { editable = false, text = "" } }
        row.button = new_widget("button") {
            label = "Select",
            tooltip = "Select these photos in the lighttable.",
            clicked_callback = function() dt.gui.selection(images_of(row.item.ids)) end,
        }
        row.fix = new_widget("button") {
            label = "Fix",
            tooltip = "Make the change this line describes, to these photos only.",
            clicked_callback = function()
                local item = row.item
                for k, other in ipairs(alerts.items) do
                    if other == item then table.remove(alerts.items, k) break end
                end
                save()
                local key, arg = item.fix:match("^([^:]*):?(.*)$")
                fixes[key](images_of(item.ids), arg)
            end,
        }
        -- the whole text above its buttons, so a long item is read in full
        -- under the newest run's last item when older items follow
        row.earlier = new_widget("label") { label = "", halign = "start", visible = false }
        row.box = new_widget("box") { orientation = "vertical", row.label, row.details,
            new_widget("box") { orientation = "horizontal", row.button, row.fix }, row.earlier }
        rows[i] = row
    end
    local function show()
        local items = alerts.items
        local newest = items[1] and items[1].run
        for i, row in ipairs(rows) do
            local item = items[i]
            row.box.visible = item ~= nil
            if item then
                row.label.text = (item.action ~= "" and item.action .. ": " or "") .. item.text
                local lines = {}
                for _, detail in ipairs(item.details) do lines[#lines + 1] = "• " .. detail end
                row.details.text = table.concat(lines, "\n")
                row.details.visible = #lines > 0
                row.item = item
                row.button.visible = #item.ids > 0
                row.fix.visible = #item.ids > 0 and fixes[item.fix:match("^[^:]*")] ~= nil
                local next_item = items[i + 1]
                row.earlier.visible = item.run == newest and next_item ~= nil and next_item.run ~= newest
                row.earlier.label = string.format("Earlier runs (before %s): may not hold any more", os.date("%H:%M", newest))
            end
        end
        more.visible = #items > #rows
        more.label = string.format("and %d more (see the log)", #items - #rows)
        alerts.widget.visible = #items > 0
    end
    function save()
        local ok, err = C.write_file_atomic(path, C.alerts_format(alerts.items))
        if not ok then log("to check: couldn't save " .. path .. ": " .. tostring(err)) end
        show()
    end
    function alerts.begin(action)
        -- one higher than the last at least, so two runs in one second stay apart
        current, current_run = action, math.max(os.time(), current_run + 1)
        local kept = {}
        for _, item in ipairs(alerts.items) do
            if item.action ~= action then kept[#kept + 1] = item end
        end
        alerts.items = kept
        save()
    end
    function alerts.add(text, ids, fix, details)
        -- after this run's items, above every older run's
        local at = 1
        while alerts.items[at] and alerts.items[at].run == current_run do at = at + 1 end
        table.insert(alerts.items, at, { action = current, text = text, ids = ids or {}, fix = fix or "",
                                         details = details or {}, run = current_run })
        save()
    end
    local clear = new_widget("button") {
        label = "Clear List",
        tooltip = "Empty this list. Each run replaces its own items anyway.",
        clicked_callback = function()
            alerts.items = {}
            save()
        end,
    }
    -- a blank line above the heading sets the box apart from the section before it; Clear List
    -- sits under the items, on its own line
    local body = { orientation = "vertical",
        new_widget("box") { orientation = "vertical", new_widget("label") { label = " " }, header } }
    for _, row in ipairs(rows) do body[#body + 1] = row.box end
    body[#body + 1] = more
    body[#body + 1] = clear
    alerts.widget = new_widget("box")(body)
    show()
    return alerts
end

return C
