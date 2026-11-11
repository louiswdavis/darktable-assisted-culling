--[[
    assisted_culling.lua — Assisted Culling for darktable

    Lighttable panel that clusters a selection into bursts, shells out to
    score_images.py, streams ratings back, and keeps a single continuous live progress job.
]]

local M = {}
local THIS_DIR = (debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\]")) or "."

-- plugin_common.lua lives beside this file; when this file was copied into lua/contrib by
-- hand it is found through the plugin folder preference instead.
local function load_common()
    local dirs, tried = { THIS_DIR }, {}
    local ok_dt, dt0 = pcall(require, "darktable")
    if ok_dt then
        local ok_p, folder = pcall(dt0.preferences.read, "assisted_culling", "plugin_folder", "directory")
        if ok_p and folder and folder ~= "" then dirs[#dirs + 1] = folder .. "/lua" end
    end
    for _, dir in ipairs(dirs) do
        local path = dir .. "/plugin_common.lua"
        local chunk = loadfile(path)
        if chunk then return chunk() end
        tried[#tried + 1] = path
    end
    error("assisted_culling: plugin_common.lua not found (tried " .. table.concat(tried, ", ")
        .. "). Copy it next to assisted_culling.lua, or set the plugin folder preference.")
end
local C = load_common()

M.cancel_requested = false
M.module_installed = false
M.event_registered = false

-- Panel UI references shared for state management
local action_button = nil
local is_running = false
local is_clearing = false
-- Jobs clicked while a run is going: { label, run }, each started as the one before finishes.
-- Selections and settings are captured when queued, not when the job starts.
local queue = {}
local run_next -- defined after start_culling; score_images calls it as a run finishes
local clear_button = nil

-- Shared with the other two plugins (plugin_common.lua); re-exported for the tests.
M.newest_group_node, M.tag_group_keys, M.native_group_keys, M.number_groups =
    C.newest_group_node, C.tag_group_keys, C.native_group_keys, C.number_groups
M.shot_stem, M.is_raw, M.csv_line, M.parse_csv_line, M.parse_report_line, M.pythonw_of =
    C.shot_stem, C.is_raw, C.csv_line, C.parse_csv_line, C.parse_csv_fields, C.pythonw_of
local lead_rank = C.lead_rank
for name, fn in pairs(C) do
    if type(name) == "string" and name:match("^preset_") then M[name] = fn end
end


-- Images → the ones to score, and per scored id every image that takes its result.
-- One shot = darktable duplicates of a file plus a RAW+JPEG pair (same folder and
-- stem), so the pair always gets the same stars. A shot is scored from the member
-- the scorer reads best: a JPEG at full size over the RAW's embedded preview.
function M.collapse_shots(images)
    local primaries, group_of, lead_of = {}, {}, {}
    local function key_id(img) return tonumber(img.id) or img.id end
    for _, img in ipairs(images) do
        local key = img.path .. "/" .. M.shot_stem(img.filename)
        local lead = lead_of[key]
        if not lead then
            primaries[#primaries + 1] = img
            lead_of[key] = { img = img, slot = #primaries }
            group_of[key_id(img)] = { img }
        else
            local group = group_of[key_id(lead.img)]
            group[#group + 1] = img
            if lead_rank(img.filename) > lead_rank(lead.img.filename) then
                group_of[key_id(lead.img)] = nil
                group_of[key_id(img)] = group
                primaries[lead.slot] = img
                lead.img = img
            end
        end
    end
    return primaries, group_of
end



-- "overexposed;eyes_closed" → { overexposed = true, eyes_closed = true }; "" → {}.
function M.parse_flags(s)
    local set = {}
    for name in s:gmatch("[^;]+") do set[name] = true end
    return set
end


-- "dir\sub/a.jpg" → "dir/sub", "a.jpg"; a bare name has folder "".
local function split_path(p)
    p = p:gsub("\\", "/")
    local dir, name = p:match("^(.*)/([^/]*)$")
    if not dir then return "", p end
    return dir, name
end

-- last-run.csv text + { "folder/filename" = true } → one "file: stars, why" line per frame of
-- the run that matches (a file can match several rows when versions share it), and the
-- paths the run had no row for. A RAW+JPEG pair has one row, under the file that was
-- scored, so a file also matches rows with the same stem in the same folder. Reports
-- without the folder column (older runs) match on the stem alone.
function M.explain_report(text, wanted)
    local lines, seen, names_of = {}, {}, {}
    for path in pairs(wanted) do
        local folder, name = split_path(path)
        local stem = M.shot_stem(name)
        names_of[stem] = names_of[stem] or {}
        table.insert(names_of[stem], { path = path, folder = folder })
    end
    local first = true
    for line in text:gmatch("[^\r\n]+") do
        if first then
            first = false -- header
        else
            local f = M.parse_report_line(line)
            local names = (#f >= 10 and #f <= 12) and names_of[M.shot_stem(f[2])]
            local row_folder = f[11] and (f[11]:gsub("\\", "/"))
            local hit = false
            for _, n in ipairs(names or {}) do
                if not row_folder or n.folder == row_folder then seen[n.path] = true; hit = true end
            end
            if hit then
                local stars = f[6] == "leave" and "left as it was" or (f[6] .. " stars")
                local reason = f[12] and f[12] ~= "" and (" Why: " .. f[12] .. ".") or ""
                lines[#lines + 1] = string.format("%s: %s, burst %s, score %s. %s%s", f[2], stars, f[1], f[5], f[10], reason)
            end
        end
    end
    local missing = {}
    for name in pairs(wanted) do
        if not seen[name] then missing[#missing + 1] = name end
    end
    table.sort(missing)
    return lines, missing
end

-- Stage A points row {id, x0, y0, x1, y1} → SAM prompt: a box when x1,y1 are
-- set, else a point at x0,y0. nil when the numbers don't parse.
function M.parse_prompt(parts)
    local x0, y0 = tonumber(parts[2]), tonumber(parts[3])
    if not (x0 and y0) then return nil end
    if parts[4] == "" and parts[5] == "" then return { x0 = x0, y0 = y0 } end
    local x1, y1 = tonumber(parts[4]), tonumber(parts[5])
    if not (x1 and y1) then return nil end
    return { x0 = x0, y0 = y0, x1 = x1, y1 = y1 }
end

-- Diagnostic tags the scorer lists in results column 7, relative to
-- "Assisted Culling|". Synced by prefix, so a new kind (Subject|Animal|…)
-- needs no change here.
M.DIAG_PREFIXES = { "Assisted Culling|Subject|", "Assisted Culling|Technique|", "Assisted Culling|Scored|",
    "Assisted Culling|Why|" }

function M.is_diag_tag(name)
    for _, p in ipairs(M.DIAG_PREFIXES) do
        if name:sub(1, #p) == p then return true end
    end
    return false
end

-- have: an image's tag names (name → true); wanted: the scorer's ";"-joined
-- column 7. Returns the full names to attach and to detach, sorted.
function M.diag_tag_changes(have, wanted)
    local want, attach, detach = {}, {}, {}
    for rel in wanted:gmatch("[^;]+") do
        local name = "Assisted Culling|" .. rel
        if M.is_diag_tag(name) then
            want[name] = true
            if not have[name] then attach[#attach + 1] = name end
        end
    end
    for name in pairs(have) do
        if not want[name] and M.is_diag_tag(name) then detach[#detach + 1] = name end
    end
    table.sort(attach)
    table.sort(detach)
    return attach, detach
end

-- wanted: the scorer's ";"-joined column 7; off: branch names turned off
-- (e.g. { Subject = true }). Returns column 7 without those branches, so
-- diag_tag_changes detaches them.
function M.filter_diag(wanted, off)
    local kept = {}
    for rel in wanted:gmatch("[^;]+") do
        if not off[rel:match("^[^|]+")] then kept[#kept + 1] = rel end
    end
    return table.concat(kept, ";")
end


-- Panel choices as stored keys, in combobox order.
local genre_opts = {"landscape", "portrait", "sport", "macro", "custom"}
local rank_opts = {"universal", "binary", "relative"}
local sharp_opts = {"center", "tiles_uniformity", "peak", "face_detect", "subject_focus", "sam_subject", "motion_aware"}
local exp_opts = {"whole_frame", "subject_only", "strict", "none"}
local keep_opts = {"single_best", "portrait_mode", "dynamic_burst", "keep_all"}
local nk_opts = {"leave", "reject", "0", "1", "2", "3", "4", "5", "graded"}
-- also keep every frame within this % of its burst's best (the scorer's --keep-margin)
local keep_margin_opts = {"off", "95", "90", "85", "80", "75"}
-- multiplies every sharpness threshold a star needs (the scorer's --star-scale)
local star_scale_opts = {"0.5", "0.75", "1", "1.25", "1.5", "2"}
local group_support_opts = {"native", "tags", "none"}
M.CHOICES = { genre = genre_opts, rank_mode = rank_opts, sharp_mode = sharp_opts, exp_mode = exp_opts,
    keep_mode = keep_opts, keep_margin = keep_margin_opts, non_keeper = nk_opts, star_scale = star_scale_opts, group_support = group_support_opts }

-- The four modes each genre fills in. "custom" has none.
M.GENRE_MODES = {
    landscape = { rank_mode = "universal", sharp_mode = "tiles_uniformity", exp_mode = "strict", keep_mode = "single_best" },
    portrait = { rank_mode = "universal", sharp_mode = "face_detect", exp_mode = "subject_only", keep_mode = "portrait_mode" },
    sport = { rank_mode = "universal", sharp_mode = "motion_aware", exp_mode = "whole_frame", keep_mode = "dynamic_burst" },
    macro = { rank_mode = "universal", sharp_mode = "peak", exp_mode = "whole_frame", keep_mode = "keep_all" },
}

-- True when s's four modes are the ones `genre` fills in.
function M.genre_matches(genre, s)
    local modes = M.GENRE_MODES[genre]
    if not modes then return false end
    for k, v in pairs(modes) do
        if s[k] ~= v then return false end
    end
    return true
end

-- Every panel setting a preset stores, in panel order.
M.PRESET_SCHEMA = {
    { key = "genre", kind = "choice", choices = genre_opts, default = "landscape" },
    { key = "rank_mode", kind = "choice", choices = rank_opts, default = "universal" },
    { key = "sharp_mode", kind = "choice", choices = sharp_opts, default = "tiles_uniformity" },
    { key = "exp_mode", kind = "choice", choices = exp_opts, default = "strict" },
    { key = "keep_mode", kind = "choice", choices = keep_opts, default = "single_best" },
    { key = "keep_margin", kind = "choice", choices = keep_margin_opts, default = "off" },
    { key = "non_keeper", kind = "choice", choices = nk_opts, default = "leave" },
    { key = "star_scale", kind = "choice", choices = star_scale_opts, default = "1" },
    { key = "group_support", kind = "choice", choices = group_support_opts, default = "native" },
    { key = "group_node", kind = "string", default = "" },
    { key = "run_tag", kind = "bool", default = false },
    { key = "apply_while_scoring", kind = "bool", default = false },
    { key = "fast_jpeg_decode", kind = "bool", default = true },
    { key = "penalise_overexposed", kind = "bool", default = true },
    { key = "penalise_underexposed", kind = "bool", default = true },
    { key = "penalise_eyes_closed", kind = "bool", default = true },
    { key = "tag_keeper", kind = "bool", default = true },
    { key = "tag_rejected", kind = "bool", default = true },
    { key = "tag_overexposed", kind = "bool", default = true },
    { key = "tag_underexposed", kind = "bool", default = true },
    { key = "tag_eyes_closed", kind = "bool", default = true },
    { key = "tag_subject", kind = "bool", default = true },
    { key = "tag_technique", kind = "bool", default = true },
    { key = "tag_scored", kind = "bool", default = true },
    { key = "tag_why", kind = "bool", default = true },
}

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
-- Progress bar split: analysis (in SAM mode: finding subjects, then SAM, then
-- scoring) fills it to PROGRESS_ANALYSIS, applying ratings fills the rest.
local PROGRESS_ANALYSIS = 0.75
local PROGRESS_SUBJECTS = 0.15   -- SAM mode: end of finding subjects
local PROGRESS_SAM = 0.45        -- SAM mode: end of segmenting
local STAGE2_WRITE_BUDGET = 12   -- writes per slice before yielding
local STAGE2_SLEEP_MIN_MS = 20   -- minimum yield per slice
local STAGE2_SLEEP_MAX_MS = 300  -- maximum yield per slice
-- Final drain only: ratings are batched, so a slice spends its budget on tag
-- writes alone, which don't reload the collection.
local STAGE2_BATCH_WRITE_BUDGET = 60
local STAGE2_BATCH_LINES = 200   -- results per batched slice

-- darktable's "views/thumbtable/rating" action elements, by star value
local RATING_ELEMENTS = { [-1] = "reject", [0] = "zero", "one", "two", "three", "four", "five" }

local IS_WINDOWS = C.IS_WINDOWS

local TMP_DIR = dt.configuration.tmp_dir
-- Leftovers of a darktable that crashed or was killed mid-run; a day old is surely not live.
C.sweep_temp(TMP_DIR, "dt_assisted_culling_", 86400)
-- The run log: this plugin's lines plus the scorer's stderr. Kept in the
-- config dir, which outlives tmp_dir; the run before it is kept as .prev.log.
local LOG_PATH = dt.configuration.config_dir .. "/assisted_culling.log"
local PREV_LOG_PATH = dt.configuration.config_dir .. "/assisted_culling.prev.log"

-- A run's temp files. Each run gets its own names, so a cancelled scorer that
-- outlives the run's wait keeps its own cancel flag and can't write into the next run.
local MANIFEST_PATH, RESULTS_PATH, PROGRESS_PATH, CANCEL_PATH, DONE_PATH
local POINTS_PATH, POINTS_DONE_PATH, PRESCORE_PATH
local function new_run_paths()
    local base = C.temp_base(TMP_DIR, "dt_assisted_culling_")
    MANIFEST_PATH = base .. "manifest.csv"
    RESULTS_PATH = base .. "results.csv"
    PROGRESS_PATH = base .. "progress.txt"
    CANCEL_PATH = PROGRESS_PATH .. ".cancel"
    DONE_PATH = base .. "done.txt"
    POINTS_PATH = base .. "points.csv"
    POINTS_DONE_PATH = POINTS_PATH .. ".done"
    PRESCORE_PATH = base .. "prescores.csv"
end
new_run_paths()
-- Per-frame scores reused across runs; tmp_dir is wiped, the config dir isn't.
local CACHE_PATH = dt.configuration.config_dir .. "/assisted_culling/scores.sqlite"
local REPORT_PATH = dt.configuration.config_dir .. "/assisted_culling/last-run.csv"
local REPORT_ARCHIVE_DIR = dt.configuration.config_dir .. "/assisted_culling/reports"

-- Masks are per darktable instance (not per run) so a scorer finishing after a cancel
-- can't overwrite a live run's, and they share the sweep's naming.
local MASK_BASE = C.temp_base(TMP_DIR, "dt_assisted_culling_")
local function mask_path_for(id)
    return MASK_BASE .. "mask_" .. tostring(id) .. ".png"
end

local DETECTOR_FILE = "object_detection_yolox_2022nov.onnx"

if dt.gui then
    dt.preferences.register("assisted_culling", "python_bin", "file",
        "Assisted Culling: Python interpreter",
        "Python executable with opencv-python-headless, numpy, Pillow and rawpy installed (e.g. .venv\\Scripts\\python.exe). Empty = auto-detect the repo's .venv",
        "")
    dt.preferences.register("assisted_culling", "plugin_folder", "directory",
        "Assisted Culling: plugin folder",
        "The darktable-assisted-culling folder (holds python/, models/ and .venv). Empty = auto-detect. Subject tracking (SAM) uses models/" .. DETECTOR_FILE .. " from it when present, to outline the most prominent car, motorcycle or truck for SAM",
        "")
end

-- The settings a run reads: a copy of the panel's, taken when the run was clicked.
-- Headless runs use the remembered preset (the template defaults when it is gone).
local function remembered_settings()
    local name = dt.preferences.read("assisted_culling", "preset", "string") or ""
    local f = name ~= "" and name ~= "template"
        and io.open(dt.configuration.config_dir .. "/assisted_culling/presets/" .. name .. ".json", "rb")
    if not f then return M.preset_defaults(M.PRESET_SCHEMA) end
    local text = f:read("a")
    f:close()
    return (M.preset_merge(M.PRESET_SCHEMA, M.preset_decode(text) or {}))
end
local settings = remembered_settings()

local file_exists, read_file, first_existing = C.file_exists, C.read_file, C.first_existing

local function plugin_folder_pref()
    local folder = (dt.preferences.read("assisted_culling", "plugin_folder", "directory") or ""):gsub("[/\\]+$", "")
    return folder
end

-- The script is found from the plugin folder preference alone when it's set; a
-- wrong folder is an error rather than a quiet switch to some other copy.
local function score_script()
    local folder = plugin_folder_pref()
    if folder ~= "" then
        local script = folder .. "/python/score_images.py"
        if not (df.test_file(script, "e") or file_exists(script)) then
            error("the plugin folder preference (" .. folder .. ") has no python/score_images.py; point it at the darktable-assisted-culling folder, or clear it to auto-detect", 0)
        end
        return script
    end
    local found = first_existing({
        THIS_DIR .. "/score_images.py",
        THIS_DIR .. "/python/score_images.py",
        THIS_DIR .. "/../python/score_images.py",
        THIS_DIR .. "/../../python/score_images.py",
    })
    return found or (THIS_DIR .. "/score_images.py")
end

local function plugin_root(script)
    local folder = plugin_folder_pref()
    if folder ~= "" then return folder end
    local script_dir = (script and script:match("^(.*)[/\\]")) or THIS_DIR
    return script_dir:match("^(.*)[/\\]python$") or script_dir
end

local function python_bin(script)
    local pref = dt.preferences.read("assisted_culling", "python_bin", "file")
    if pref and pref ~= "" then return pref end

    local root = plugin_root(script)
    local found = first_existing({
        root .. "/.venv/Scripts/python.exe",
        root .. "/.venv/bin/python",
        THIS_DIR .. "/../.venv/Scripts/python.exe",
        THIS_DIR .. "/../.venv/bin/python",
    })
    if found then return found end

    local v = df.check_if_bin_exists(IS_WINDOWS and "python" or "python3")
    if not v then
        v = IS_WINDOWS and "python" or "python3"
    end
    return v
end

local shell_quote, command_line, run_async_python = C.shell_quote, C.command_line, C.run_async_python

-- SAM / SAM 2 conventions, mirroring darktable's src/common/ai/segmentation.c.
-- darktable.ai exposes no model attributes to Lua, so these are the defaults
-- that file falls back to when a model doesn't override them.
local SAM_INPUT_SIZE = 1024
local SAM_PREV_MASK_DIM = 256
local SAM_MASK_MAX_DIM = 256 -- masks are read back pixel by pixel; cap the cost
local SAM_MEAN = { 123.675, 116.28, 103.53 }
local SAM_STD = { 58.395, 57.12, 57.375 }

-- Returns the enabled mask model's id, or nil and a reason the user can act on.
local function sam_model_id()
    if not dt.ai then
        return nil, "this darktable has no AI support; subject tracking needs darktable 5.6 or newer"
    end
    local id = dt.ai.model_for_task("mask")
    if not id then
        return nil, "no AI mask model is enabled; turn one on in preferences → AI"
    end
    local ok_list, models = pcall(dt.ai.models)
    for _, m in ipairs(ok_list and models or {}) do
        if m.id == id then
            local about = ((m.id or "") .. " " .. (m.name or "") .. " " .. (m.description or "")):lower()
            if about:find("segnext", 1, true) then
                return nil, "the enabled mask model is SegNext; subject tracking needs a SAM or SAM 2 mask model"
            end
        end
    end
    return id
end

-- Segments the subject under (x_frac, y_frac) and saves a 0/1 PNG mask of the
-- image area (padding cropped off). Errors if the model finds nothing there.
local function sam_mask(encoder, decoder, img, prompt, out_path)
    local t = dt.ai.load_image(img, SAM_INPUT_SIZE, SAM_INPUT_SIZE)
    local shape = t:shape()
    local h, w = shape[3], shape[4]
    if h > SAM_INPUT_SIZE or w > SAM_INPUT_SIZE then
        error(string.format("load_image returned %dx%d, larger than %d", w, h, SAM_INPUT_SIZE), 0)
    end
    t:linear_to_srgb()
    local scales, offsets = {}, {}
    for c = 1, 3 do
        scales[c] = 255 / SAM_STD[c]
        offsets[c] = -SAM_MEAN[c] / SAM_STD[c]
    end
    t:scale_add_planes(scales, offsets)
    local padded = dt.ai.create_tensor({ 1, 3, SAM_INPUT_SIZE, SAM_INPUT_SIZE })
    padded:paste(t, 0, 0)

    local feats = { encoder:run(padded) }
    local inputs
    if #feats == 1 then
        inputs = { feats[1] }
    elseif #feats == 3 then
        -- SAM 2 encoders emit high_res_feats_0, high_res_feats_1, image_embeddings;
        -- the decoder wants image_embed first.
        inputs = { feats[3], feats[1], feats[2] }
    else
        error("unexpected SAM encoder output count " .. #feats, 0)
    end

    -- a foreground point (label 1) or box corners (labels 2 and 3), then the
    -- (0,0) label -1 padding point SAM's ONNX export expects
    local pts = prompt.x1 and { { prompt.x0, prompt.y0, 2 }, { prompt.x1, prompt.y1, 3 } }
        or { { prompt.x0, prompt.y0, 1 } }
    local coords = dt.ai.create_tensor({ 1, #pts + 1, 2 })
    local labels = dt.ai.create_tensor({ 1, #pts + 1 })
    for i, p in ipairs(pts) do
        coords:set({ 0, i - 1, 0 }, p[1] * w)
        coords:set({ 0, i - 1, 1 }, p[2] * h)
        labels:set({ 0, i - 1 }, p[3])
    end
    labels:set({ 0, #pts }, -1)
    inputs[#inputs + 1] = coords
    inputs[#inputs + 1] = labels
    inputs[#inputs + 1] = dt.ai.create_tensor({ 1, 1, SAM_PREV_MASK_DIM, SAM_PREV_MASK_DIM })
    inputs[#inputs + 1] = dt.ai.create_tensor({ 1 }) -- has_mask_input = 0

    local masks, iou = decoder:run(table.unpack(inputs))
    local mshape = masks:shape()
    local n_masks, dh, dw = mshape[2], mshape[3], mshape[4]
    local best = 0
    for m = 1, n_masks - 1 do
        if iou:get({ 0, m }) > iou:get({ 0, best }) then best = m end
    end

    local vh = math.max(1, math.floor(h * dh / SAM_INPUT_SIZE + 0.5))
    local vw = math.max(1, math.floor(w * dw / SAM_INPUT_SIZE + 0.5))
    local step = math.max(1, math.ceil(math.max(vh, vw) / SAM_MASK_MAX_DIM))
    local oh, ow = math.ceil(vh / step), math.ceil(vw / step)
    local out = dt.ai.create_tensor({ 1, 1, oh, ow })
    local found = false
    for y = 0, oh - 1 do
        for x = 0, ow - 1 do
            if masks:get({ 0, best, y * step, x * step }) > 0 then -- SAM emits logits
                out:set({ 0, 0, y, x }, 1)
                found = true
            end
        end
    end
    if not found then error("empty mask", 0) end
    out:save(out_path)
end

-- `edited` adds darktable's last-edit time: SAM masks come from the edited
-- export, so the scorer keys cached masked scores on it. Shutter (seconds),
-- aperture (f-number) and focal length (mm) always go last, for the scorer's
-- EXIF intent rules and motion_aware's blur prior.
local function write_manifest(images, burst_of, mask_for_id, shortlisted, edited)
    local f = io.open(MANIFEST_PATH, "w")
    if not f then return false end
    for _, img in ipairs(images) do
        local path = img.path .. "/" .. img.filename
        local fields = { img.id, path, burst_of[img.id],
            mask_for_id and mask_for_id[img.id] or "",
            shortlisted and (shortlisted[img.id] and "1" or "0") or "",
            edited and tostring(img.change_timestamp) or "",
            img.exif_exposure or 0, img.exif_aperture or 0, img.exif_focal_length or 0 }
        f:write(M.csv_line(fields), "\n")
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
    -- is_running stays set: the run still waits for the scorer and cleans up, and a
    -- second run started now would share its temp files. score_images clears it.
    queue = {}
    if action_button then
        action_button.label = _("Cancelling...")
    end
end

local TAG_KEEPER = "Assisted Culling|Keeper"
local TAG_REJECT = "Assisted Culling|Rejected"
local TAG_RUN_FORMAT = "Assisted Culling|Run|%Y-%m-%d %H:%M"
local TAG_CULLED = "Assisted Culling|Culled" -- no longer written; still cleared from older passes
-- Set by the user; runs leave these images out entirely. Never written or cleared by the plugin.
local TAG_LOCKED = "Assisted Culling|Locked"
-- Problem flags the scorer lists in results column 3 (FLAG_PENALTIES in score_images.py),
-- each synced to its own tag. `summary` labels the count in the done message.
local FLAGS = {
    { name = "overexposed", tag = "Assisted Culling|Overexposed", summary = "overexposed" },
    { name = "underexposed", tag = "Assisted Culling|Underexposed", summary = "underexposed" },
    { name = "eyes_closed", tag = "Assisted Culling|Eyes Closed", summary = "with eyes closed" },
}
local ALL_TAGS = { TAG_KEEPER, TAG_REJECT, TAG_CULLED }
for _, f in ipairs(FLAGS) do ALL_TAGS[#ALL_TAGS + 1] = f.tag end

-- One "tag_<key>" setting per branch under "Assisted Culling|". Off = runs
-- stop writing it and detach it from the images they process; ratings and
-- keeper picks are unchanged. Keys match FLAGS names for the flag branches.
local TAG_TOGGLES = {
    { key = "keeper", label = "Keeper", writes = { "Keeper" },
      when = "the best frame (or frames) of its burst." },
    { key = "rejected", label = "Rejected", writes = { "Rejected" },
      when = "it lost to a sharper frame from the same burst. Its stars follow the non-keepers setting." },
    { key = "overexposed", label = "Overexposed", writes = { "Overexposed" },
      when = "blown highlights, judged by the exposure setting." },
    { key = "underexposed", label = "Underexposed", writes = { "Underexposed" },
      when = "crushed shadows, judged by the exposure setting." },
    { key = "eyes_closed", label = "Eyes Closed", writes = { "Eyes Closed" },
      when = "face & eyes sharpness only: a face big enough to judge shows no open eyes. Dark sunglasses trigger it too." },
    { key = "subject", label = "Subject", diag = true, writes = { "Subject|Vehicle|Detected", "Subject|Vehicle|Guessed" },
      when = "subject tracking (SAM) only. Detected: the vehicle detector found the car SAM was pointed at. Guessed: SAM got the guessed subject point instead." },
    { key = "technique", label = "Technique", diag = true, writes = { "Technique|Panning", "Technique|Shallow DoF", "Technique|Motion Blur", "Technique|Missed Pan" },
      when = "the burst's EXIF switched its sharpness mode: panning at 1/125 s or slower, shallow DoF at f/4 or wider. Motorsport mode tags each frame instead: Panning (car sharp, background streaked), Motion Blur (whole frame blurred in one line), Missed Pan (car blurred across the pan)." },
    { key = "scored", label = "Scored", diag = true, writes = { "Scored|Masked", "Scored|Subject bias" },
      when = "subject tracking (SAM) only. Masked: the burst was ranked on SAM masks. Subject bias: a shortlisted frame got no mask, so the burst fell back." },
    { key = "why", label = "Why", diag = true,
      writes = { "Why|Keeper", "Why|Keeper by margin", "Why|Outranked", "Why|Graded", "Why|Not shortlisted" },
      when = "every scored frame, saying how it was decided. Keeper: kept by rank. Keeper by margin: kept by the keeper margin. Outranked: lost to a sharper frame (left or rejected). Graded: lost and rated by burst. Not shortlisted: subject tracking (SAM) left it out of the shortlist. Filter on one to step through, say, every frame that lost to the margin." },
}

local function tag_enabled(key)
    return settings["tag_" .. key]
end

-- Flags the user set to tag-only, as the scorer's --tag-only-flags value.
local function tag_only_flags()
    local names = {}
    for _, f in ipairs(FLAGS) do
        if not settings["penalise_" .. f.name] then
            names[#names + 1] = f.name
        end
    end
    return table.concat(names, ",")
end

local function fmt_eta(elapsed, done, total)
    if elapsed < 3 or done <= 0 or done >= total then return "" end
    local remaining = math.ceil(elapsed * (total - done) / done)
    return string.format(" | ~%dm %02ds left", remaining // 60, remaining % 60)
end

-- Lines wait here while a scorer process appends its stderr to the same file:
-- two processes appending at once can overwrite each other's lines on Windows.
local log_buffer = {}

local function log(msg)
    log_buffer[#log_buffer + 1] = os.date("%H:%M:%S ") .. "lua: " .. msg
end

-- Only call while no scorer process is running.
local function flush_log()
    if #log_buffer == 0 then return end
    local f = io.open(LOG_PATH, "a")
    if not f then return end
    f:write(table.concat(log_buffer, "\n"), "\n")
    f:close()
    log_buffer = {}
end

local function say(msg)
    dt.print(msg)
    log(msg)
end

-- dt.print_error only writes to darktable's log (-d lua); users never see it.
local function notify_error(msg)
    dt.print(msg)
    dt.print_error(msg)
    log(msg)
end

local function pretty(s)
    return (tostring(s):gsub("_", " "))
end

local function tags_of(img)
    local have = {}
    for _, t in ipairs(tags.get_tags(img)) do have[t.name] = true end
    return have
end

-- Returns 1 if a write was needed (attach/detach), else 0. Creates the tag only
-- to attach it, so a branch that is turned off never appears in the tag list.
local function sync_tag(img, have, name, wanted)
    if wanted and not have[name] then
        tags.attach(tags.create(name), img); return 1
    elseif not wanted and have[name] then
        tags.detach(tags.find(name), img); return 1
    end
    return 0
end

function M.score_images(images, rank_mode, sharp_mode, exp_mode, keep_mode, nk_mode)
    rank_mode = rank_mode or "universal"
    sharp_mode = sharp_mode or "subject_focus"
    exp_mode = exp_mode or "whole_frame"
    keep_mode = keep_mode or "dynamic_burst"
    nk_mode = nk_mode or "leave"

    local n_locked = 0
    local lock_tag = images and tags.find(TAG_LOCKED)
    if lock_tag and #lock_tag > 0 then
        local locked = {}
        for i = 1, #lock_tag do locked[tonumber(lock_tag[i].id)] = true end
        local unlocked = {}
        for _, img in ipairs(images) do
            if locked[tonumber(img.id)] then n_locked = n_locked + 1 else unlocked[#unlocked + 1] = img end
        end
        images = unlocked
    end

    if not images or #images == 0 then
        dt.print(n_locked > 0 and _("Assisted Culling: every selected image is tagged Assisted Culling|Locked, so there's nothing to cull. Remove that tag from images you want scored.")
            or _("Assisted Culling: select some images first"))
        is_running = false
        if action_button then action_button.label = _("Cull selection") end
        run_next()
        return
    end

    new_run_paths()
    flush_log() -- anything logged since the last run (e.g. a failed clear) belongs to its log
    pcall(os.remove, PREV_LOG_PATH)
    pcall(os.rename, LOG_PATH, PREV_LOG_PATH)
    log(string.format("run started: darktable %s, %d images (%d locked left out)",
        tostring(dt.configuration.version), #images, n_locked))
    log(string.format("settings: rank %s, sharpness %s, exposure %s, keepers %s, non-keepers %s",
        rank_mode, sharp_mode, exp_mode, keep_mode, nk_mode))

    local culling_job = nil
    local sam_ids = {}
    local main_started = false
    local stage_a_alive = false

    local success, run_err = pcall(function()
        local sam_model
        if sharp_mode == "sam_subject" then
            local why
            sam_model, why = sam_model_id()
            if not sam_model then error("subject tracking (SAM) can't run: " .. why, 0) end
        end

        -- Each shot (duplicates, RAW+JPEG pair) is scored once; the result is applied to all of it.
        local primaries, group_of = M.collapse_shots(images)
        local n_primary = #primaries
        local n_dups = #images - n_primary

        local primary_ids = {}
        for _, img in ipairs(primaries) do table.insert(primary_ids, img.id) end

        -- A shot's group comes from any of its images, not just the lead: grouping may
        -- have seen only the RAWs (JPEGs hidden), or grouped the pair's RAW alone.
        local function members(img) return group_of[tonumber(img.id) or img.id] end
        local mechanism = settings.group_support
        local key_of, node, multi = {}, nil, {}
        if mechanism == "native" then
            local items = {}
            for _, img in ipairs(primaries) do
                local in_shot = {}
                for _, m in ipairs(members(img)) do in_shot[tostring(m.id)] = true end
                -- a leader outside the shot is a real group; one inside is just the pair
                local leader = img.group_leader and img.group_leader.id
                for _, m in ipairs(members(img)) do
                    local l = m.group_leader and m.group_leader.id
                    if l and not in_shot[tostring(l)] then leader = l; break end
                end
                items[#items + 1] = { id = img.id, leader = leader }
            end
            key_of = M.native_group_keys(items)
        elseif mechanism == "tags" then
            local items, lists = {}, {}
            for _, img in ipairs(primaries) do
                local have = {}
                for _, m in ipairs(members(img)) do
                    for name in pairs(tags_of(m)) do have[name] = true end
                end
                items[#items + 1] = { id = img.id, tags = have }
                local names = {}
                for name in pairs(have) do names[#names + 1] = name end
                lists[#lists + 1] = names
            end
            local typed = (settings.group_node or ""):match("^%s*(.-)%s*$")
            node = typed ~= "" and typed or M.newest_group_node(lists)
            if node then key_of, multi = M.tag_group_keys(items, node) end
        end
        local burst_of = M.number_groups(primary_ids, key_of)

        local size_of, n_bursts, grouped = {}, 0, 0
        for _, id in ipairs(primary_ids) do
            if not size_of[burst_of[id]] then n_bursts = n_bursts + 1 end
            size_of[burst_of[id]] = (size_of[burst_of[id]] or 0) + 1
        end
        for _, id in ipairs(primary_ids) do
            if size_of[burst_of[id]] >= 2 then grouped = grouped + 1 end
        end
        local msg = string.format("group support %s: %d of %d photos in groups of 2+", mechanism, grouped, #primaries)
        if mechanism == "tags" then
            msg = msg .. string.format(", node %s", node or "(none found)")
            if node and next(key_of) == nil then msg = msg .. " (matches no selected photo)" end
            if #multi > 0 then msg = msg .. ", several children on ids " .. table.concat(multi, ",") end
        end
        log(msg)

        local overlap, fast_jpeg = settings.apply_while_scoring, settings.fast_jpeg_decode

        pcall(os.remove, MANIFEST_PATH)
        pcall(os.remove, RESULTS_PATH)
        pcall(os.remove, RESULTS_PATH .. ".tmp")
        pcall(os.remove, PROGRESS_PATH)
        pcall(os.remove, CANCEL_PATH)
        pcall(os.remove, DONE_PATH)
        pcall(os.remove, POINTS_PATH)
        pcall(os.remove, POINTS_DONE_PATH)
        pcall(os.remove, PRESCORE_PATH)
        if sam_model then
            -- masks from an earlier run over an overlapping selection must not be reused
            for _, img in ipairs(primaries) do pcall(os.remove, mask_path_for(img.id)) end
        end

        if not write_manifest(primaries, burst_of, nil, nil, sam_model ~= nil) then
            error("couldn't write the image list to darktable's tmp folder (disk full or no write access?)", 0)
        end

        if dt.gui then
            culling_job = dt.gui.create_job(_("Assisted Culling"), true, stop_job)
            culling_job.percent = 0.0
        end

        log(string.format("fast JPEG %s, apply while scoring %s, SAM model %s",
            tostring(fast_jpeg), tostring(overlap), tostring(sam_model or "none")))
        say(string.format("Assisted Culling: scoring %d images in %d groups (%s keepers, %s ranking, %s grouping)",
            n_primary, n_bursts, pretty(keep_mode), pretty(rank_mode), mechanism))
        if n_dups > 0 then
            say(string.format("Assisted Culling: %d image(s) share a shot with another (a duplicate, or the RAW of a RAW+JPEG pair); each shot is scored once and its result copied to all of it.", n_dups))
        end
        if n_primary > 1000 then
            say(_("Assisted Culling: large selection, this can take several minutes. Click Cancel culling to stop at any time."))
        end
        dt.print_hinter(_("Assisted Culling: starting analysis..."))

        local sc_script = score_script()
        if not df.test_file(sc_script, "e") and not file_exists(sc_script) then
            error("score_images.py not found at " .. sc_script .. "; set its path in preferences → Lua options", 0)
        end
        local py_bin = python_bin(sc_script)

        local function cancelled()
            return M.cancel_requested or (culling_job and not culling_job.valid) or file_exists(CANCEL_PATH)
        end

        if sam_model then
            -- Load first: a model that's registered but not downloaded should fail
            -- before the minutes stage A can take on a big batch.
            local function load_part(file, provider)
                local ok_l, ctx = pcall(dt.ai.load_model, sam_model, provider, file)
                if ok_l and ctx then return ctx end
                return nil, tostring(ctx or "load_model returned nothing")
            end
            local encoder, enc_err = load_part("encoder.onnx", nil)
            local decoder, dec_err = load_part("decoder.onnx", "cpu")
            if not (encoder and decoder) then
                if encoder then encoder:close() end
                if decoder then decoder:close() end
                error("couldn't load the mask model '" .. sam_model
                    .. "'; check it's downloaded in preferences → AI (" .. (enc_err or dec_err) .. ")", 0)
            end
            -- closes both models when this block exits, an error included, so a failed run can't leak them
            local _models <close> = setmetatable({}, { __close = function()
                pcall(function() encoder:close() end)
                pcall(function() decoder:close() end)
            end })

            -- Stage A: the scorer shortlists each burst's best frames by the fast heuristic
            -- and picks one prompt per shortlisted frame: a vehicle box or a salient point.
            local detector = plugin_root(sc_script) .. "/models/" .. DETECTOR_FILE
            if not file_exists(detector) then detector = "" end
            local points_argv = { sc_script, MANIFEST_PATH, POINTS_PATH, "--emit-saliency-points" }
            if detector ~= "" then table.move({ "--detector", detector }, 1, 2, #points_argv + 1, points_argv) end
            table.move({
                "--keep-mode", tostring(keep_mode),
                "--exp-mode", tostring(exp_mode),
                "--prescores", PRESCORE_PATH,
                "--cache", CACHE_PATH,
                "--sam-model", sam_model,
                "--progress", PROGRESS_PATH,
            }, 1, 12, #points_argv + 1, points_argv)
            if fast_jpeg then points_argv[#points_argv + 1] = "--fast-jpeg" end
            log("finding subjects: " .. command_line(py_bin, points_argv))
            flush_log()
            local launched, why = run_async_python(py_bin, points_argv, LOG_PATH, true, POINTS_DONE_PATH)
            if not launched then error("couldn't start the scorer: " .. why, 0) end
            while not file_exists(POINTS_DONE_PATH) and not cancelled() do
                local pf = io.open(PROGRESS_PATH, "r")
                local p = pf and pf:read("*a") or ""
                if pf then pf:close() end
                local cur, tot = p:match("(%d+),(%d+)")
                if cur and culling_job and tonumber(tot) > 0 then
                    culling_job.percent = PROGRESS_SUBJECTS * tonumber(cur) / tonumber(tot)
                end
                dt.print_hinter(string.format("Assisted Culling: finding subjects %s / %s", cur or "0", tot or "?"))
                dt.control.sleep(150)
            end
            if cancelled() then
                -- give the stage-A process a moment to see the cancel and exit
                local cf = io.open(CANCEL_PATH, "w")
                if cf then cf:write("1"); cf:close() end
                for _ = 1, 50 do
                    if file_exists(POINTS_DONE_PATH) then break end
                    dt.control.sleep(100)
                end
                stage_a_alive = not file_exists(POINTS_DONE_PATH)
            else
                local dfh = io.open(POINTS_DONE_PATH, "r")
                local code = dfh and tonumber((dfh:read("*a") or ""):match("%d+")) or nil
                if dfh then dfh:close() end
                log("finding subjects: scorer exit " .. tostring(code))
                if code ~= 0 then
                    error("finding subjects failed (scorer exit " .. tostring(code) .. "): " .. read_log_tail(), 0)
                end
            end

            -- Stage B: SAM masks for the shortlist, one model load for the whole batch.
            local mask_for_id, shortlisted = {}, {}
            if not cancelled() then

                local by_id = {}
                for _, img in ipairs(primaries) do by_id[tostring(img.id)] = img end
                local points = {}
                local pfh = io.open(POINTS_PATH, "r")
                if pfh then
                    for line in pfh:lines() do
                        local parts = M.parse_csv_line(line, 6)
                        local prompt = parts and M.parse_prompt(parts)
                        if prompt and by_id[parts[1]] then
                            -- cached = "1": the scorer already has this frame's masked score
                            if parts[6] ~= "1" then points[#points + 1] = { id = parts[1], prompt = prompt } end
                            shortlisted[by_id[parts[1]].id] = true
                        end
                    end
                    pfh:close()
                end

                local n_short = 0
                for _ in pairs(shortlisted) do n_short = n_short + 1 end
                log(string.format("SAM: %d shortlisted, %d already cached, %d to segment",
                    n_short, n_short - #points, #points))
                local made, first_sam_error = 0, nil
                local sam_start = os.time()
                for i, pt in ipairs(points) do
                    if cancelled() then break end
                    local img = by_id[pt.id]
                    local out = mask_path_for(img.id)
                    sam_ids[#sam_ids + 1] = img.id
                    local ok_mask, mask_err = pcall(sam_mask, encoder, decoder, img, pt.prompt, out)
                    local p = pt.prompt
                    local where = p.x1 and string.format("box %.3f,%.3f-%.3f,%.3f", p.x0, p.y0, p.x1, p.y1)
                        or string.format("point %.3f,%.3f", p.x0, p.y0)
                    if ok_mask then
                        mask_for_id[img.id] = out
                        made = made + 1
                        log(string.format("SAM %s (%s) %s: masked", pt.id, img.filename, where))
                    else
                        first_sam_error = first_sam_error or tostring(mask_err)
                        log(string.format("SAM %s (%s) %s: failed: %s", pt.id, img.filename, where, tostring(mask_err)))
                    end
                    if culling_job then
                        culling_job.percent = PROGRESS_SUBJECTS + (PROGRESS_SAM - PROGRESS_SUBJECTS) * i / #points
                    end
                    dt.print_hinter(string.format("Assisted Culling: outlining subjects %d / %d%s", i, #points,
                        fmt_eta(os.time() - sam_start, i, #points)))
                    dt.control.sleep(10) -- hand the Lua lock back so the cancel button and hinter respond
                end

                -- not dt.print_error: the run carries on, and a red toast reads as a failure
                if made < #points and not cancelled() then
                    local why = first_sam_error == "empty mask" and "no subject found"
                        or ("first error: " .. tostring(first_sam_error))
                    say(string.format("Assisted Culling: subject tracking outlined %d of %d frames (%s). Bursts without an outline use center-weighted subject bias instead; the run continues.",
                        made, #points, why))
                end
            end

            if not write_manifest(primaries, burst_of, mask_for_id, shortlisted, true) then
                error("couldn't write the image list to darktable's tmp folder (disk full or no write access?)", 0)
            end
            pcall(os.remove, PROGRESS_PATH)
        end

        local argv = {
            sc_script, MANIFEST_PATH, RESULTS_PATH,
            "--progress", PROGRESS_PATH,
            "--rank-mode", tostring(rank_mode),
            "--sharp-mode", tostring(sharp_mode),
            "--exp-mode", tostring(exp_mode),
            "--keep-mode", tostring(keep_mode),
            "--nk-mode", tostring(nk_mode),
            "--tag-only-flags", tag_only_flags(),
            "--star-scale", tostring(settings.star_scale or "1"),
            "--keep-margin", tostring((tonumber(settings.keep_margin) or 0) / 100),
        }
        if fast_jpeg then argv[#argv + 1] = "--fast-jpeg" end
        if sharp_mode == "motion_aware" then
            local detector = plugin_root(sc_script) .. "/models/" .. DETECTOR_FILE
            if file_exists(detector) then table.move({ "--detector", detector }, 1, 2, #argv + 1, argv) end
        end
        if sam_model then
            table.move({ "--prescores", PRESCORE_PATH, "--sam-model", sam_model }, 1, 4, #argv + 1, argv)
        end
        table.move({
            "--cache", CACHE_PATH,
            "--report", REPORT_PATH,
            "--report-archive-dir", REPORT_ARCHIVE_DIR,
        }, 1, 6, #argv + 1, argv)

        if cancelled() then
            M.cancel_requested = true -- cancelled during the SAM stages: don't start scoring at all
            log("cancelled before scoring")
        else
            log("scoring: " .. command_line(py_bin, argv))
            flush_log()
            local launched, why = run_async_python(py_bin, argv, LOG_PATH, true, DONE_PATH)
            if not launched then error("couldn't start the scorer: " .. why, 0) end
            main_started = true
        end

        local done_code, scorer_exited = nil, false
        -- Once the scorer has exited its stderr can't interleave, so lines hit disk
        -- right away and survive a darktable crash mid-apply.
        local function trace(msg)
            log(msg)
            if scorer_exited then flush_log() end
        end
        local stage1_start = os.time()

        local applied_total, failed_total, first_error, n_skipped = 0, 0, nil, 0
        local stats = { keepers = 0, others = 0, flagged = {}, guessed = 0, subject_bias = 0 }
        for _, f in ipairs(FLAGS) do stats.flagged[f.name] = 0 end

        -- ---- result application (shared by "while scoring" and the final drain) ----
        -- one stamp per run; not in ALL_TAGS, so clearing marks and later runs leave earlier stamps alone
        local run_stamp = settings.run_tag and os.date(TAG_RUN_FORMAT) or nil
        local run_stamp_tag

        -- Reads are cheap; writes reload the lighttable collection / rewrite XMP, so skip no-ops.
        -- Every mark is a tag, never a colour label, so a re-run or "clear" can undo exactly
        -- what earlier passes set without touching labels the user applied by hand.
        -- Set by the final drain: ratings collect here per star value and go out in
        -- batches, since each img.rating write reloads the whole collection.
        local rating_batch = nil

        -- read once per run
        local tag_on, diag_off = {}, {}
        for _, t in ipairs(TAG_TOGGLES) do
            tag_on[t.key] = tag_enabled(t.key)
            if t.diag and not tag_on[t.key] then diag_off[t.label] = true end
        end
        local diag_tag_objs = {}

        local function apply_to_image(img, want_rating, is_keeper, flags, diag)
            local writes = 0
            local have = tags_of(img)

            if want_rating ~= nil and img.rating ~= want_rating then
                if rating_batch then
                    local list = rating_batch[want_rating] or {}
                    list[#list + 1] = img
                    rating_batch[want_rating] = list
                else
                    img.rating = want_rating; writes = writes + 1
                end
            end

            writes = writes + sync_tag(img, have, TAG_KEEPER, is_keeper and tag_on.keeper)
            writes = writes + sync_tag(img, have, TAG_REJECT, not is_keeper and tag_on.rejected)
            for _, f in ipairs(FLAGS) do
                writes = writes + sync_tag(img, have, f.tag, flags[f.name] == true and tag_on[f.name])
            end
            if run_stamp and not have[run_stamp] then
                run_stamp_tag = run_stamp_tag or tags.create(run_stamp)
                tags.attach(run_stamp_tag, img); writes = writes + 1
            end
            if have[TAG_CULLED] then -- marker from older versions; Keeper/Rejected already say "processed"
                tags.detach(tags.find(TAG_CULLED), img); writes = writes + 1
            end
            local attach, detach = M.diag_tag_changes(have, diag)
            for _, name in ipairs(attach) do
                diag_tag_objs[name] = diag_tag_objs[name] or tags.create(name)
                tags.attach(diag_tag_objs[name], img); writes = writes + 1
            end
            for _, name in ipairs(detach) do
                tags.detach(tags.find(name), img); writes = writes + 1
            end
            return writes
        end

        -- Returns the number of DB-touching writes performed.
        local function apply_line(line)
            local parts = M.parse_csv_line(line, 7)
            if not parts then return 0 end
            for k, val in ipairs(parts) do
                parts[k] = val:match("^%s*(.-)%s*$")
            end
            local id = tonumber(parts[1])
            local group = id and group_of[id] or nil
            if not group then return 0 end

            local is_keeper = (tonumber(parts[5]) == 1)
            local flags = M.parse_flags(parts[3])
            if is_keeper then stats.keepers = stats.keepers + 1 else stats.others = stats.others + 1 end
            for name in pairs(flags) do
                if stats.flagged[name] then stats.flagged[name] = stats.flagged[name] + 1 end
            end
            local diag = ";" .. parts[7] .. ";"
            if diag:find(";Subject|Vehicle|Guessed;", 1, true) then stats.guessed = stats.guessed + 1 end
            if diag:find(";Scored|Subject bias;", 1, true) then stats.subject_bias = stats.subject_bias + 1 end
            local want_rating = nil
            if parts[6] ~= "leave" then want_rating = tonumber(parts[6]) or 0 end

            local writes = 0
            for _, img in ipairs(group) do
                local ok_apply, res = pcall(apply_to_image, img, want_rating, is_keeper, flags,
                    M.filter_diag(parts[7], diag_off))
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

        -- Applies each star value's batch with one rating action on a temporary
        -- selection, then restores the user's selection. The action targets
        -- darktable's act-on images (the hovered image, the ones shown in preview or
        -- culling layout), so it only runs when those are exactly the batch; otherwise,
        -- and for any image the action missed, it falls back to per-image writes.
        local n_action_missed = 0
        local function flush_ratings()
            local batch = rating_batch
            if next(batch) == nil then return end
            rating_batch = {}
            local in_lighttable = dt.gui.current_view().id == "lighttable"
            local saved = in_lighttable and dt.gui.selection() or nil
            for rating, imgs in pairs(batch) do
                local used_action = false
                if in_lighttable then
                    local member = {}
                    for _, img in ipairs(imgs) do member[img.id] = true end
                    trace(string.format("ratings: selecting %d images for %d stars", #imgs, rating))
                    dt.gui.selection(imgs)
                    local targets, exact = dt.gui.action_images, true
                    if #targets ~= #imgs then exact = false end
                    for _, t in ipairs(targets) do
                        if not member[t.id] then exact = false; break end
                    end
                    if exact then
                        trace("ratings: rating action")
                        local ok_a, err_a = pcall(dt.gui.action, "views/thumbtable/rating",
                            RATING_ELEMENTS[rating], rating == -1 and "activate" or "select", 1.0)
                        if not ok_a then first_error = first_error or tostring(err_a) end
                        used_action = ok_a
                    else
                        trace(string.format("ratings: act-on is %d images, not the batch; rating one by one", #targets))
                    end
                end
                for _, img in ipairs(imgs) do
                    if img.rating ~= rating then
                        if used_action then n_action_missed = n_action_missed + 1 end
                        local ok_set, err = pcall(function() img.rating = rating end)
                        if not ok_set then
                            applied_total = applied_total - 1
                            failed_total = failed_total + 1
                            first_error = first_error or tostring(err)
                        end
                    end
                end
            end
            if saved then
                trace(string.format("ratings: restoring selection of %d", #saved))
                dt.gui.selection(saved)
            end
        end

        -- One paced slice: stop after the write budget, then yield to the GUI in
        -- proportion to how long the slice took. Returns false if nothing was pending.
        local function apply_slice()
            if pending_idx > #pending then return false end
            local slice_start = os.clock()
            if rating_batch then
                local budget, lines = STAGE2_BATCH_WRITE_BUDGET, 0
                while pending_idx <= #pending and budget > 0 and lines < STAGE2_BATCH_LINES do
                    budget = budget - apply_line(pending[pending_idx])
                    pending_idx = pending_idx + 1
                    lines = lines + 1
                end
                flush_ratings()
            else
                local budget = STAGE2_WRITE_BUDGET
                while pending_idx <= #pending and budget > 0 do
                    budget = budget - math.max(1, apply_line(pending[pending_idx]))
                    pending_idx = pending_idx + 1
                end
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
                            local from = sam_model and PROGRESS_SAM or 0
                            culling_job.percent = from + (PROGRESS_ANALYSIS - from) * math.min(1.0, num / total)
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
                scorer_exited = true
                trace("scoring: scorer exit " .. tostring(done_code))
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
        if M.cancel_requested and main_started then
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
                say(string.format(overlap and "Assisted Culling: analysis done, applying ratings to the last %d images..."
                    or "Assisted Culling: applying ratings to %d images...", remaining))
            end
            local started = os.time()
            local last_toast_pct = 0
            rating_batch = {}

            while pending_idx <= total_lines do
                if M.cancel_requested or (culling_job and not culling_job.valid) or file_exists(CANCEL_PATH) then
                    M.cancel_requested = true
                    break
                end

                trace(string.format("applying: results %d of %d", pending_idx, total_lines))
                apply_slice()

                local done = pending_idx - start_idx
                local pct = done / remaining
                if culling_job then
                    culling_job.percent = PROGRESS_ANALYSIS
                        + (1 - PROGRESS_ANALYSIS) * math.min(1.0, (pending_idx - 1) / total_lines)
                end
                dt.print_hinter(string.format(
                    "Assisted Culling: applying ratings %d / %d (%d%%)%s", pending_idx - 1, total_lines,
                    math.floor(((pending_idx - 1) / total_lines) * 100), fmt_eta(os.time() - started, done, remaining)))
                local milestone = math.floor(((pending_idx - 1) / total_lines) * 4) * 25
                if milestone > last_toast_pct and milestone < 100 then
                    last_toast_pct = milestone
                    dt.print(string.format("Assisted Culling: ratings %d%% applied", milestone))
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
                say(string.format("Assisted Culling: cancelled. %d of %d images were already rated and keep their changes. Run again to finish, or use Clear culling marks to remove the tags.",
                    applied_total, #images))
            else
                say(_("Assisted Culling: cancelled. No images were changed."))
            end
        elseif done_code ~= 0 then
            local tail = read_log_tail()
            if #tail > 300 then tail = tail:sub(#tail - 299) end
            if tail ~= "" then
                notify_error(_("Assisted Culling: failed. ") .. tail)
            else
                notify_error(string.format("Assisted Culling: the scorer stopped with exit code %s. Details are in assisted_culling.log in darktable's config folder.",
                    tostring(done_code or "?")))
            end
        elseif applied_total == 0 then
            local tail = read_log_tail()
            if #tail > 300 then tail = tail:sub(#tail - 299) end
            notify_error(_("Assisted Culling: no ratings came back from the scorer. ")
                .. (tail ~= "" and tail or _("Check the Python interpreter and score_images.py paths in preferences → Lua options.")))
        else
            local msg = string.format("Assisted Culling: done. %d keepers, %d not kept", stats.keepers, stats.others)
            for _, f in ipairs(FLAGS) do
                local n = stats.flagged[f.name]
                if n > 0 then msg = msg .. string.format(", %d %s", n, f.summary) end
            end
            if stats.guessed > 0 then msg = msg .. string.format(", %d with a guessed subject", stats.guessed) end
            if stats.subject_bias > 0 then
                msg = msg .. string.format(", %d scored by subject bias", stats.subject_bias)
            end
            if n_skipped > 0 then msg = msg .. string.format(", %d unreadable (skipped, see log)", n_skipped) end
            if n_locked > 0 then msg = msg .. string.format(", %d locked (left alone)", n_locked) end
            if failed_total > 0 then msg = msg .. string.format(", %d failed to update (see log)", failed_total) end
            say(msg)
            if n_action_missed > 0 then
                log(string.format("%d missed by darktable's rating action (rated one by one)", n_action_missed))
            end
            if first_error then
                dt.print_error("Assisted Culling: first apply error: " .. first_error)
                log("first apply error: " .. first_error)
            end
        end
    end)

    is_running = false
    if action_button then
        action_button.label = _("Cull selection")
    end

    if not success then
        if culling_job then pcall(function() culling_job.valid = false end) end
        notify_error(_("Assisted Culling: couldn't run. ") .. tostring(run_err))
    end

    -- A cancelled scorer that is still running keeps its cancel flag and launcher,
    -- so it can still see the flag and finish. The next run uses other file names.
    local scorer_alive = M.cancel_requested
        and (stage_a_alive or (main_started and not file_exists(DONE_PATH)))
    pcall(os.remove, MANIFEST_PATH)
    pcall(os.remove, RESULTS_PATH)
    pcall(os.remove, RESULTS_PATH .. ".tmp")
    pcall(os.remove, POINTS_PATH)
    pcall(os.remove, PRESCORE_PATH)
    for _, id in ipairs(sam_ids) do pcall(os.remove, mask_path_for(id)) end
    if not scorer_alive then
        pcall(os.remove, PROGRESS_PATH)
        pcall(os.remove, CANCEL_PATH)
        for _, done in ipairs({ POINTS_DONE_PATH, DONE_PATH }) do
            pcall(os.remove, done)
            pcall(os.remove, done .. ".job")
        end
    end
    log("run finished")
    flush_log()
    run_next()
end

-- Removes the plugin's tags. Ratings are NOT reverted.
function M.clear_marks(images)
    if not images or #images == 0 then
        dt.print(_("Assisted Culling: select some images first"))
        return
    end
    local found, any_diag = {}, false
    for _, name in ipairs(ALL_TAGS) do
        local t = tags.find(name)
        if t then table.insert(found, { tag = t, name = name }) end
    end
    for i = 1, #tags do
        if M.is_diag_tag(tags[i].name) then any_diag = true; break end
    end
    if #found == 0 and not any_diag then
        dt.print("Assisted Culling: nothing to clear; no Assisted Culling tags exist yet.")
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
                    local _, detach = M.diag_tag_changes(have, "")
                    for _, name in ipairs(detach) do
                        tags.detach(tags.find(name), img); writes = writes + 1
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
    if not ok then notify_error("Assisted Culling: clearing marks failed: " .. tostring(err)); return end
    dt.print(string.format("Assisted Culling: removed culling tags from %d of %d images%s. Star ratings were not changed.",
        cleared, total, failed > 0 and (", " .. failed .. " couldn't be updated") or ""))
end

local preset_file_store, make_preset_controls = C.preset_file_store, C.make_preset_controls

local step_label, make_section = C.step_label, C.make_section

-- Panel -----------------------------------------------------------------------

-- The panel's settings; set by install_panel. Read when a job is clicked, so a queued job keeps them.
local read_panel

-- dt.gui.action_images follows the live selection; a queued job needs the selection as it was.
local function copy_images(images)
    local out = {}
    for _, img in ipairs(images) do out[#out + 1] = img end
    return out
end

local function launch_score(images, s)
    is_running = true
    M.cancel_requested = false
    settings = s
    if action_button then action_button.label = _("Cancel culling") end
    M.score_images(images, s.rank_mode, s.sharp_mode, s.exp_mode, s.keep_mode, s.non_keeper)
end

local function clear_queue()
    if #queue == 0 then return end
    dt.print(string.format(_("Assisted Culling: %d queued jobs dropped."), #queue))
    queue = {}
end

-- While a run is going, remembers `run` to start when it finishes and returns true. Returns
-- false when nothing is running or there is nothing to queue, so the caller's own checks speak.
local function queue_if_busy(label, has_input, run)
    if not is_running or not has_input then return false end
    queue[#queue + 1] = { label = label, run = run }
    dt.print(string.format(_("Assisted Culling: %s queued (%d waiting); it starts when the current run finishes."),
        label, #queue))
    return true
end

-- Starts the oldest queued job; every run calls it as it finishes.
run_next = function()
    if is_running or is_clearing or #queue == 0 then return end
    local nxt = table.remove(queue, 1)
    log("starting queued job: " .. nxt.label)
    nxt.run()
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
            clear_queue() -- a cancel means "stop what I started", not "run the rest"
            if action_button then action_button.label = _("Cancelling...") end
            dt.print(_("Assisted Culling: cancelling, finishing the current step..."))
        else
            local images, s = copy_images(dt.gui.action_images), read_panel()
            if not queue_if_busy(_("Culling"), #images > 0, function() launch_score(images, s) end) then
                dt.print(_("Assisted Culling: already running. Click Cancel culling in the panel to stop it."))
            end
        end
        return
    end
    launch_score(dt.gui.action_images, read_panel())
end

local function install_panel()
    if M.module_installed then return end
    M.module_installed = true

    local ctl
    local function changed()
        if ctl then ctl.check_dirty() end
    end

    -- The combo values last shown or picked, by schema key. Combobox callbacks run later
    -- and fire on every `selected` assignment, so each acts only when its value differs.
    local shown = M.preset_defaults(M.PRESET_SCHEMA)
    local combos = {}

    local function index_of(list, key)
        for i, v in ipairs(list) do
            if v == key then return i end
        end
        return 1
    end

    local function show_choice(key, value)
        shown[key] = value
        local i = index_of(M.CHOICES[key], value)
        if combos[key].selected ~= i then combos[key].selected = i end
    end

    local function on_choice(key)
        return function(widget)
            local value = M.CHOICES[key][widget.selected]
            if not value or value == shown[key] then return end
            shown[key] = value
            if key == "genre" then
                for k, v in pairs(M.GENRE_MODES[value] or {}) do show_choice(k, v) end
            elseif M.GENRE_MODES[shown.genre] and M.GENRE_MODES[shown.genre][key]
                and not M.genre_matches(shown.genre, shown) then
                show_choice("genre", "custom")
            end
            changed()
        end
    end

    local function choice_combo(key, label, tooltip, labels)
        local c = dt.new_widget("combobox") {
            label = label,
            tooltip = tooltip,
            changed_callback = on_choice(key),
            table.unpack(labels),
        }
        c.selected = index_of(M.CHOICES[key], shown[key])
        combos[key] = c
        return c
    end

    local genre_combo = choice_combo("genre", _("genre"),
        _("Fills in the four settings below for a photography genre. Changing any of them switches to custom."),
        { _("landscape"), _("portrait"), _("sport"), _("macro"), _("custom") })

    local rank_combo = choice_combo("rank_mode", _("ranking mode"),
        _("universal: keepers get stars from fixed sharpness tiers.\nbinary: keepers get top stars; only flags lower them.\nrelative: tiers scale to this selection, so its sharpest frames get 5 stars.\nIn every mode, the rest follow the non-keepers setting."),
        { _("universal absolute"), _("binary (keepers top)"), _("relative to selection") })

    local sharp_combo = choice_combo("sharp_mode", _("sharpness"),
        _("How sharpness is measured.\nedge-to-edge: scores the softest areas of the frame (ignoring plain sky), so a soft corner costs a frame.\nface & eyes: falls back to subject bias when no face is found; tags a frame Eyes Closed (one star lower) when a clear face shows no open eyes.\nsubject tracking (SAM): outlines the subject with darktable's AI mask model before scoring; slower than the rest, since each burst's top few frames go through the model.\nmotorsport: finds the car, scores it at full resolution so overcast light isn't punished, and reads each frame's motion. Good pans score higher (Panning), a whole frame blurred in one straight line is kept with its burst (Motion Blur), a car blurred across the pan scores lower (Missed Pan)."),
        { _("center crop"), _("edge-to-edge uniformity"), _("absolute peak 1%"), _("face & eyes (OpenCV)"), _("subject bias (center-weighted)"), _("subject tracking (SAM)"), _("motorsport (subject & motion)") })

    local exp_combo = choice_combo("exp_mode", _("exposure"),
        _("Flags clipped shadows/highlights (Overexposed/Underexposed tag, one star lower; turn the penalty off under penalties & speed below)."),
        { _("whole frame"), _("subject only (ignore sky)"), _("strict histogram"), _("ignore exposure") })

    local keep_combo = choice_combo("keep_mode", _("keepers"),
        _("How many of each burst are kept (the sharpest ones)."),
        { _("single best only"), _("portrait (1 or 2)"), _("dynamic (1 to 5)"), _("keep all (focus stack)") })

    local keep_margin_combo = choice_combo("keep_margin", _("keeper margin"),
        _("Also keeps every frame scoring within this share of its burst's sharpest frame, on top of the keepers count. 90% keeps any frame at least 90% as sharp as the best."),
        { _("off"), _("within 95% of best"), _("within 90% of best"), _("within 85% of best"), _("within 80% of best"), _("within 75% of best") })

    local non_keeper_combo = choice_combo("non_keeper", _("non-keepers"),
        _("What to do with images that are not kept. They get the Rejected tag unless tags written → Rejected is off.\ngraded: stars below the burst's lowest keeper by how close each frame is to the burst's best: 90%+ one star less, 75%+ two, 60%+ three, 45%+ four, else 0."),
        { _("leave alone"), _("reject (-1)"), _("0 stars"), _("1 star"), _("2 stars"), _("3 stars"), _("4 stars"), _("5 stars"), _("graded by burst") })

    local star_scale_combo = choice_combo("star_scale", _("star strictness"),
        _("Scales the sharpness every star needs, in universal and relative ranking, and how fast graded non-keepers lose stars. Stricter: fewer stars for the same frame. More generous: more stars. The scores themselves don't change."),
        { _("much more generous (×0.5)"), _("more generous (×0.75)"), _("standard (×1)"), _("stricter (×1.25)"), _("much stricter (×1.5)"), _("strictest (×2)") })

    action_button = dt.new_widget("button") {
        label = _("Cull selection"),
        tooltip = _("Score the selected images in bursts and rate/tag them. Click again to cancel."),
    }

    action_button.clicked_callback = function()
        changed()
        start_culling(true)
    end

    local group_support_combo = choice_combo("group_support", _("grouping support"),
        _("What groups photos before keepers are picked. Native groups: darktable's image groups. Grouping tags: the children of the tag node below. None: every photo is judged alone.\nDefault: native groups. Pick grouping tags after an Assisted Grouping run you have not applied as darktable groups."),
        { _("Native groups"), _("Grouping tags"), _("None") })
    local group_node_entry = dt.new_widget("entry") {
        placeholder = _("Grouping tag node (blank = newest run)"),
        tooltip = _("Grouping tags only: the tag node whose children are the groups, e.g. Assisted Grouping|2026-01-01 12:00:00|Group. Blank uses the newest Assisted Grouping run on the selected photos.\nDefault: blank. Set it when the photos carry more than one grouping run."),
        text = "",
    }

    -- Check buttons by schema key, in panel order.
    local checks, check_order = {}, {}
    local function check(key, label, tooltip)
        local c = dt.new_widget("check_button") {
            label = label,
            tooltip = tooltip,
            value = shown[key],
            clicked_callback = changed,
        }
        checks[key] = c
        check_order[#check_order + 1] = key
        return c
    end

    local run_tag_check = check("run_tag", _("Tag each run"),
        _("Add a timestamp tag (Assisted Culling|Run|YYYY-MM-DD HH:MM) to every image a run writes, so the latest run's photos can be filtered apart from earlier ones. Stamps accumulate; remove old ones in darktable's tag manager. Clear culling marks leaves them.\nDefault: off. Turn on when re-running a shoot and you want to review only what changed."))

    local option_checks = {
        check("apply_while_scoring", _("Apply ratings while scoring"),
            _("Faster overall on big batches, but darktable's UI shares the CPU with the scorer; turn off if the UI lags.\nDefault: off. Turn on for batches of several hundred frames.")),
        check("fast_jpeg_decode", _("Fast JPEG decoding"),
            _("Decodes JPEGs and RAW previews at reduced size, several times faster. Sharpness scores shift slightly, but keepers are ranked within each burst, so picks rarely change.\nDefault: on. Turn off when frames are close in sharpness and you want full-size scores.")),
    }
    for _i, f in ipairs(FLAGS) do
        local label = f.tag:match("|(.+)$")
        option_checks[#option_checks + 1] = check("penalise_" .. f.name, string.format(_("%s lowers stars"), label),
            string.format(_("On: %s images get one star less. Off: they're still tagged %s (if it's on under tags written) but keep their rating.\nDefault: on. Turn off for styles where it's the point (low-key, high-key)."), label, label))
    end

    local tag_checks = {}
    for _i, t in ipairs(TAG_TOGGLES) do
        tag_checks[#tag_checks + 1] = check("tag_" .. t.key, t.label,
            string.format(_("Writes: %s\nWhen: %s\nOff: stops writing it and removes it from images on the next run. Ratings and keeper picks are unchanged."),
                "Assisted Culling|" .. table.concat(t.writes, ", Assisted Culling|"), _(t.when)))
    end

    read_panel = function()
        local s = {}
        for key in pairs(combos) do s[key] = M.CHOICES[key][combos[key].selected] or shown[key] end
        for _, key in ipairs(check_order) do s[key] = checks[key].value and true or false end
        s.group_node = (group_node_entry.text or ""):match("^%s*(.-)%s*$")
        return s
    end

    local function show_panel(s)
        for k, v in pairs(s) do shown[k] = v end
        for key in pairs(combos) do show_choice(key, s[key]) end
        for _, key in ipairs(check_order) do checks[key].value = s[key] end
        group_node_entry.text = s.group_node
    end

    clear_button = dt.new_widget("button") {
        label = _("Clear culling marks"),
        tooltip = _("Remove the Assisted Culling tags from the selected images. Star ratings and colour labels are not changed."),
    }

    clear_button.clicked_callback = function()
        local selected = copy_images(dt.gui.action_images)
        if queue_if_busy(_("Clear culling marks"), #selected > 0, function()
            is_clearing = true
            local ok_q, err_q = pcall(M.clear_marks, selected)
            is_clearing = false
            if not ok_q then notify_error("Assisted Culling: clearing marks failed: " .. tostring(err_q)) end
            run_next()
        end) then return end
        if is_running or is_clearing then
            dt.print(_("Assisted Culling: busy with another job, try again when it finishes."))
            return
        end
        is_clearing = true
        local ok_c, err_c = pcall(M.clear_marks, dt.gui.action_images)
        is_clearing = false
        if not ok_c then notify_error("Assisted Culling: clearing marks failed: " .. tostring(err_c)) end
    end

    local why_button = dt.new_widget("button") {
        label = _("Why these ratings?"),
        tooltip = _("Explain the selected images from the last run's report: stars, rank in the burst, flags. Changes nothing."),
    }

    why_button.clicked_callback = function()
        local text = read_file(REPORT_PATH)
        if not text then
            dt.print(_("Assisted Culling: no report yet. Run culling first."))
            return
        end
        local wanted, n = {}, 0
        for _, img in ipairs(dt.gui.action_images) do
            local path = img.path .. "/" .. img.filename
            if not wanted[path] then wanted[path] = true; n = n + 1 end
        end
        if n == 0 then
            dt.print(_("Assisted Culling: select some images first"))
            return
        end
        local lines, missing = M.explain_report(text, wanted)
        for _, l in ipairs(lines) do log("why: " .. l) end
        for _, name in ipairs(missing) do log("why: " .. name .. ": not in the last run") end
        if n == 1 then
            dt.print(lines[1] or string.format(_("Assisted Culling: %s was not in the last run."), missing[1]))
        else
            dt.print(string.format(_("Assisted Culling: %d explained, %d not in the last run. Full text in the log."),
                #lines, #missing))
        end
    end

    local report_button = dt.new_widget("button") {
        label = _("Open last report"),
        tooltip = _("Open last-run.csv (every frame's rank, score, stars and why) in your spreadsheet app. The newest 20 runs are kept in assisted_culling/reports in darktable's config folder."),
    }

    report_button.clicked_callback = function()
        if not file_exists(REPORT_PATH) then
            dt.print(_("Assisted Culling: no report yet. Run culling first."))
            return
        end
        if IS_WINDOWS then
            os.execute(string.format('start "" "%s"', REPORT_PATH:gsub("/", "\\")))
        elseif dt.configuration.running_os == "macos" then
            os.execute("open " .. shell_quote(REPORT_PATH))
        else
            os.execute("xdg-open " .. shell_quote(REPORT_PATH) .. " >/dev/null 2>&1 &")
        end
    end

    ctl = make_preset_controls({
        prefix = "Assisted Culling",
        schema = M.PRESET_SCHEMA,
        store = preset_file_store(dt.configuration.config_dir .. "/assisted_culling/presets"),
        read_panel = read_panel,
        show = show_panel,
        remember = function(name) dt.preferences.write("assisted_culling", "preset", "string", name) end,
        initial = dt.preferences.read("assisted_culling", "preset", "string"),
        -- a scorer may be appending to the log; its lines wait in the buffer until the run ends
        log = function(msg) log(msg); if not is_running then flush_log() end end,
        allow_store_new = true,
    })

    local panel_box = dt.new_widget("box") {
        orientation = "vertical",
        -- shows the template defaults; nothing is saved
        reset_callback = function()
            show_panel(M.preset_defaults(M.PRESET_SCHEMA))
            changed()
        end,
        ctl.widget,
        make_section(1, _("scoring"),
            { genre_combo, rank_combo, sharp_combo, exp_combo, keep_combo, keep_margin_combo, non_keeper_combo, star_scale_combo }),
        make_section(2, _("bursts"), {
            group_support_combo,
            dt.new_widget("label") { label = _("grouping tag node"), halign = "start" },
            group_node_entry,
        }),
        make_section(3, _("penalties & speed"), option_checks),
        make_section(4, _("tags written"), tag_checks),
        step_label(5, _("run")),
        run_tag_check,
        action_button,
        make_section(nil, _("tools"), { why_button, report_button, clear_button }),
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