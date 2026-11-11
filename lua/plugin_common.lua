--[[
    plugin_common.lua — code shared by Assisted Grouping, Assisted Culling and Assisted Tagging.

    Each repo holds its own copy, byte for byte the same; each repo's Lua test hashes it against
    COMMON_HASH, so a change made in one repo fails the other two until it is copied over.
    A plugin loads it with loadfile from its own folder (or the plugin folder preference), never
    through lua/contrib. Everything above the `require "darktable"` line runs in plain `lua`.
]]

local C = {}

C.IS_WINDOWS = package.config:sub(1, 1) == "\\"

-- Shared preferences ------------------------------------------------------------
-- One Python interpreter and one plugins folder for all three plugins. The old
-- per-plugin keys still work and log a deprecation line once per key.

C.SHARED_GROUP = "assisted_plugins"

-- Each plugin loads its own copy of this file, so the "registered" mark lives in
-- package.loaded, which all scripts in darktable's Lua state share.
local REGISTERED_MARK = "assisted_plugins.shared_prefs_registered"

function C.register_shared_prefs(dt)
    if package.loaded[REGISTERED_MARK] then return end
    package.loaded[REGISTERED_MARK] = true
    dt.preferences.register(C.SHARED_GROUP, "python_bin", "file",
        "Python interpreter (.venv)",
        "Python executable with every plugin's python/requirements.txt installed (e.g. .venv\\Scripts\\python.exe). Shared by Assisted Grouping, Culling and Tagging. Empty = auto-detect each plugin's .venv",
        "")
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

-- The shared interpreter, else the plugin's old python_bin, else "" (auto-detect).
function C.python_bin(dt, plugin_group, log)
    local shared = read_pref(dt, C.SHARED_GROUP, "python_bin", "file")
    if shared ~= "" then return shared end
    return old_pref(dt, plugin_group, "python_bin", "file", "python_bin", log)
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

local GROUP_PREFIX = "Assisted Grouping|"
local GROUP_STAMP = "^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d$"

-- Greatest-stamp "Assisted Grouping|<stamp>|Group" among the tag names, or nil.
function C.newest_group_node(tag_lists)
    local best
    for _, tags in ipairs(tag_lists) do
        for _, name in ipairs(tags) do
            if name:sub(1, #GROUP_PREFIX) == GROUP_PREFIX then
                local stamp, rest = name:sub(#GROUP_PREFIX + 1):match("^([^|]+)|(.*)$")
                if stamp and stamp:match(GROUP_STAMP) and (rest == "Group" or rest:sub(1, 6) == "Group|") then
                    if not best or stamp > best then best = stamp end
                end
            end
        end
    end
    return best and (GROUP_PREFIX .. best .. "|Group") or nil
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
-- literal except a `%NAME%` of a set variable, and a path can't hold `"`; a `"` in any other
-- argument is passed through as \" for the C runtime, and a lone `%` is doubled so cmd.exe
-- leaves it alone. `windows` overrides the platform (tests).
function C.shell_quote(s, windows)
    if windows == nil then windows = C.IS_WINDOWS end
    if windows then return '"' .. s:gsub('"', '\\"'):gsub("%%", "%%%%") .. '"' end
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
function C.paced_writer(dt, budget, sleep_ms)
    local w = { writes = 0, failed = 0, first_error = nil }
    function w.write(fn, weight)
        local okw, werr = pcall(fn)
        if not okw then
            w.failed = w.failed + 1
            w.first_error = w.first_error or tostring(werr)
        end
        w.writes = w.writes + (weight or 1)
        if w.writes >= budget then
            w.writes = 0
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

-- Presets as <dir>/<name>.json. The folder is made on first use.
function C.preset_file_store(dir)
    local windows = C.IS_WINDOWS
    local function quote(s)
        if windows then return '"' .. s:gsub("/", "\\") .. '"' end
        return "'" .. s:gsub("'", "'\\''") .. "'"
    end
    os.execute((windows and "mkdir " or "mkdir -p ") .. quote(dir) .. (windows and " 2>nul" or " 2>/dev/null"))
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

-- o = { prefix, schema, store, read_panel = fn() -> settings | nil, why,
--       show = fn(settings), remember = fn(name), initial = name, log = fn(msg),
--       on_change = fn(name, is_template) | nil, can_switch = fn() -> ok, why | nil,
--       allow_store_new = bool }
-- Optional store.copy_note(from, to) -> confirm text | nil, why and store.copy(from, to) -> ok, err:
-- store new then asks first, and copies the selected preset's store (e.g. a folder) before writing.
-- Returns ctl: ctl.widget (the box to put first in the panel), ctl.widgets, ctl.select(name),
-- ctl.refresh(), ctl.reload(), ctl.check_dirty(), ctl.name(), ctl.saved (settings last loaded or saved).
function C.make_preset_controls(o)
    local ctl = { widgets = {} }
    local names, current, menu_actions = { "template" }, nil, {}
    local name_mode
    local picker, menu, name_entry, name_box, confirm_label, confirm_box, dirty_label
    local confirm_button, confirm_action, delete_clicked

    local function say(msg) dt.print(o.prefix .. ": " .. msg) end

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
    end

    local function ask_name(mode)
        name_mode = mode
        name_entry.text = mode == "rename" and current or ""
        confirm_box.visible = false
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
        confirm_label.label = text
        confirm_button.label = button
        confirm_action = action
        name_box.visible = false
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
        end
        set_entries(menu, items)
        menu.selected = 1
    end

    function ctl.name() return current end

    -- "unsaved changes" when the panel differs from the file. Template has no file.
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

    picker = dt.new_widget("combobox") {
        label = "preset",
        tooltip = "Pick a saved set of panel settings. template = the defaults. Unsaved changes are dropped when you switch. Save with actions → update preset.",
        changed_callback = function(self)
            local name = self.value
            if current and name and name ~= "" and name ~= current then ctl.select(name) end
        end,
        "template",
    }
    menu = dt.new_widget("combobox") {
        label = "actions",
        tooltip = "Preset actions: update the selected preset with the panel's values, store the panel as a new preset, rename or delete.",
        changed_callback = function(self)
            local i = self.selected
            if not i or i <= 1 then return end
            local action = menu_actions[i]
            self.selected = 1
            if action then ctl.check_dirty(); action() end
        end,
        "choose…",
    }
    dirty_label = dt.new_widget("label") { label = "unsaved changes", halign = "start", visible = false }
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
    confirm_label = dt.new_widget("label") { label = "", halign = "start" }
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
    ctl.widgets = { picker = picker, menu = menu, dirty_label = dirty_label, name_box = name_box, confirm_box = confirm_box }
    ctl.widget = dt.new_widget("box") {
        orientation = "vertical",
        dt.new_widget("box") { orientation = "horizontal", picker, menu },
        dirty_label,
        name_box,
        confirm_box,
    }

    ctl.refresh()
    ctl.select(o.initial or "template")
    return ctl
end

-- Sections ----------------------------------------------------------------------
-- A panel section is a section_label heading ("1  title"; number optional) above its widgets.
-- Sections don't fold: Lua has no clickable heading widget, and a button header looks like a button.
-- Pages live in a stack under a combobox (paged_sections); the run area uses make_section directly.

function C.step_label(number, title)
    return dt.new_widget("section_label") { label = (number and (number .. "  ") or "") .. title }
end

function C.make_section(number, title, widgets)
    local body = { orientation = "vertical", C.step_label(number, title) }
    for i = 1, #widgets do body[#body + 1] = widgets[i] end
    return dt.new_widget("box")(body)
end

-- Pages: { number, title, widgets }. A combobox picks which page the stack shows; the choice is
-- stored in preference `page` of `group`. The stack is not size-fixed, so it resizes per page.
function C.paged_sections(group, pages)
    local stack = dt.new_widget("stack") { h_size_fixed = false, v_size_fixed = false }
    local labels = {}
    for i, page in ipairs(pages) do
        stack[i] = C.make_section(page.number, page.title, page.widgets)
        labels[i] = page.number .. "  " .. page.title
    end
    local start = C.page_index(dt.preferences.read(group, "page", "integer"), #pages)
    stack.active = start
    local picker = dt.new_widget("combobox") {
        label = "page",
        selected = start,
        changed_callback = function(self)
            stack.active = self.selected
            dt.preferences.write(group, "page", "integer", self.selected)
        end,
        table.unpack(labels),
    }
    return dt.new_widget("box") { orientation = "vertical", picker, stack }
end

return C
