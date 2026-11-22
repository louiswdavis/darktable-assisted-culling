--[[
    assisted_culling.lua — Assisted Culling for darktable

    Lighttable panel that clusters a selection into bursts, shells out to
    score_images.py, streams ratings back, and keeps a single continuous live progress job.
]]

local M = {}
local THIS_DIR = (debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\]")) or "."

-- plugin_common.lua lives beside this file; when this file was copied into lua/contrib by
-- hand it is found through the plugins folder preference (or the old plugin folder one).
-- C.plugin_folder isn't loaded yet, so both keys are read here directly.
local function load_common()
    local dirs, tried = { THIS_DIR }, {}
    local ok_dt, dt0 = pcall(require, "darktable")
    if ok_dt then
        local ok_r, root = pcall(dt0.preferences.read, "assisted_plugins", "plugins_root", "directory")
        if ok_r and root and root ~= "" then dirs[#dirs + 1] = root .. "/darktable-assisted-culling/lua" end
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
        .. "). Copy it next to assisted_culling.lua, or set the plugins folder preference.")
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
local status_label, status_text = nil, "" -- the progress line at the foot of the panel

-- Shared with the other two plugins (plugin_common.lua); re-exported for the tests.
M.latest_group_tag, M.latest_group_keys, M.group_tags_hint, M.GROUP_TAGS_HINT =
    C.latest_group_tag, C.latest_group_keys, C.group_tags_hint, C.GROUP_TAGS_HINT
M.tag_group_keys, M.native_group_keys, M.number_groups = C.tag_group_keys, C.native_group_keys, C.number_groups
M.shot_stem, M.is_raw, M.csv_line, M.parse_csv_line, M.parse_report_line, M.pythonw_of =
    C.shot_stem, C.is_raw, C.csv_line, C.parse_csv_line, C.parse_csv_fields, C.pythonw_of
local lead_rank = C.lead_rank
for name, fn in pairs(C) do
    if type(name) == "string" and name:match("^preset_") then M[name] = fn end
end


-- Splits each group into one pool per child tag of a tag node, so a burst with two identified
-- cars gets a keeper each. Several children, no child or no group key leave an id's key unchanged.
function M.split_by_tag(ids, key_of, tag_of, multi)
    local several = {}
    for _, id in ipairs(multi) do several[id] = true end
    local out, outs_of, n_tagged = {}, {}, 0
    for _, id in ipairs(ids) do
        local key, tag = key_of[id], tag_of[id]
        if key ~= nil and tag ~= nil and not several[id] then
            out[id] = key .. "\0" .. tag
            n_tagged = n_tagged + 1
        else
            out[id] = key
        end
        if key ~= nil then
            outs_of[key] = outs_of[key] or {}
            outs_of[key][out[id]] = true
        end
    end
    local n_split = 0
    for _, outs in pairs(outs_of) do
        if next(outs, next(outs)) ~= nil then n_split = n_split + 1 end
    end
    return out, n_split, n_tagged
end


-- Notice for the done message when grouping was on but every frame is its own burst
-- (the two cull-first orders land here); nil otherwise.
function M.no_groups_notice(grouping_on, n_primary, n_bursts)
    if grouping_on and n_primary >= 2 and n_bursts == n_primary then
        return "no groups found: every frame judged alone (group first for keepers)"
    end
    return nil
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
            local names = #f >= 10 and names_of[M.shot_stem(f[2])]
            local row_folder = f[11] and (f[11]:gsub("\\", "/"))
            local hit = false
            for _, n in ipairs(names or {}) do
                if not row_folder or n.folder == row_folder then seen[n.path] = true; hit = true end
            end
            if hit then
                local stars = f[6] == "leave" and "left as it was" or (f[6] .. " stars")
                local reason = f[12] and f[12] ~= "" and (" Why: " .. f[12] .. ".") or ""
                -- the report holds the score as measured; one decimal is enough to read
                local score = tonumber(f[5]) and string.format("%.1f", tonumber(f[5])) or f[5]
                lines[#lines + 1] = string.format("%s: %s, burst %s, score %s. %s%s", f[2], stars, f[1], score, f[10], reason)
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

-- wanted: the scorer's ";"-joined column 7; off: full relative names turned off
-- (M.diag_off). Returns column 7 without them, so diag_tag_changes detaches them.
function M.filter_diag(wanted, off)
    local kept = {}
    for rel in wanted:gmatch("[^;]+") do
        if not off[rel] then kept[#kept + 1] = rel end
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
-- at most this many far-behind frames rejected per burst, worst first (the scorer's --reject-cap)
local reject_cap_opts = {"off", "1", "2", "3", "5"}
-- also keep every frame within this % of its burst's best (the scorer's --keep-margin)
local keep_margin_opts = {"off", "95", "90", "85", "80", "75"}
-- multiplies every sharpness threshold a star needs (the scorer's --star-scale)
local star_scale_opts = {"0.5", "0.75", "1", "1.25", "1.5", "2"}
-- a frame this % one flat colour is blank and rejected (the scorer's --blank-share)
local blank_share_opts = {"off", "99", "97", "95", "90"}
-- rate only this many of the run's best keepers, one per burst (the scorer's --first-picks)
local first_picks_opts = {"off", "10", "15", "20", "30"}
-- The panel's tag node boxes, in cut order.
local GROUP_TAG_KEYS = { "group_tag_1", "group_tag_2", "group_tag_3" }
-- Typed in a tag node box, it stands for each photo's own latest Assisted Grouping run.
M.LATEST_GROUPING_NODE = "Assisted Grouping"
M.TAG_NODE_HINT = "Grouping tags found but no native groups. Type Assisted Grouping in a tag node box to use them."
M.CHOICES = { genre = genre_opts, rank_mode = rank_opts, sharp_mode = sharp_opts, exp_mode = exp_opts,
    keep_mode = keep_opts, keep_margin = keep_margin_opts, non_keeper = nk_opts, reject_cap = reject_cap_opts,
    star_scale = star_scale_opts, blank_share = blank_share_opts, first_picks = first_picks_opts }

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

-- Tagging's boxes.json for its selected collection (its last run there): the car boxes its
-- SigLIP 2 box check kept, which score_images.py --car-boxes scores on. The path is built
-- the way tagging builds it; a missing file means raw detector boxes.
function M.car_boxes_path(config_dir, collection)
    return ((config_dir .. "/assisted_tagging/last-run/" .. (collection or "") .. ".boxes.json"):gsub("\\", "/"):gsub("/+", "/"))
end

-- Vehicle detector files, best first, in tagging's order (its M.MODEL_LISTS "vehicles").
-- The DETR family (D-FINE, RT-DETR) runs on onnxruntime; YOLOX on OpenCV.
M.DETECTOR_FILES = { "dfine_x_coco.onnx", "dfine_l_coco.onnx", "rtdetr_v2_r50vd.onnx",
    "dfine_m_coco.onnx", "dfine_s_coco.onnx", "object_detection_yolox_2022nov.onnx" }

-- The first of M.DETECTOR_FILES for which `exists(file)` holds (nil when none), and the
-- run-log line naming it plus the better files not installed (nil when none is installed).
function M.pick_detector(exists)
    local missing = {}
    for _, file in ipairs(M.DETECTOR_FILES) do
        if exists(file) then
            local line = "vehicle detector: " .. file
            if #missing > 0 then line = line .. " (better, not installed: " .. table.concat(missing, ", ") .. ")" end
            return file, line
        end
        missing[#missing + 1] = file
    end
    return nil, nil
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
    { key = "reject_cap", kind = "choice", choices = reject_cap_opts, default = "2" },
    { key = "star_scale", kind = "choice", choices = star_scale_opts, default = "1" },
    { key = "first_picks", kind = "choice", choices = first_picks_opts, default = "off" },
    { key = "group_native", kind = "bool", default = true },
    { key = "group_tag_1", kind = "string", default = "" },
    { key = "group_tag_2", kind = "string", default = "" },
    { key = "group_tag_3", kind = "string", default = "" },
    { key = "run_tag", kind = "bool", default = false },
    { key = "apply_while_scoring", kind = "bool", default = false },
    { key = "fast_jpeg_decode", kind = "bool", default = true },
    { key = "penalise_overexposed", kind = "bool", default = true },
    { key = "penalise_underexposed", kind = "bool", default = true },
    { key = "penalise_eyes_closed", kind = "bool", default = true },
    { key = "penalise_cut_off", kind = "bool", default = true },
    { key = "penalise_blocked", kind = "bool", default = true },
    { key = "blank_share", kind = "choice", choices = blank_share_opts, default = "95" },
    { key = "spread_keepers", kind = "bool", default = false },
    { key = "keep_angles", kind = "bool", default = true },
    { key = "motion_look", kind = "bool", default = true },
    { key = "star_slope", kind = "bool", default = true },
    { key = "number_reads", kind = "bool", default = false },
    { key = "sharp_judge", kind = "bool", default = false },
    { key = "no_vehicle_leave", kind = "bool", default = false },
    { key = "car_boxes_only", kind = "bool", default = true },
    { key = "tag_keeper", kind = "bool", default = true },
    { key = "tag_rejected", kind = "bool", default = true },
    { key = "tag_overexposed", kind = "bool", default = true },
    { key = "tag_underexposed", kind = "bool", default = true },
    { key = "tag_eyes_closed", kind = "bool", default = true },
    { key = "tag_cut_off", kind = "bool", default = true },
    { key = "tag_blocked", kind = "bool", default = true },
    { key = "tag_blank", kind = "bool", default = true },
    { key = "tag_subject", kind = "bool", default = true },
    { key = "tag_subject_guessed", kind = "bool", default = true },
    { key = "tag_technique", kind = "bool", default = true },
    { key = "tag_scored", kind = "bool", default = true },
    { key = "tag_why", kind = "bool", default = true },
}

-- The panel's pages and the preset keys each page's widgets edit (C.page_coverage checks them).
-- Page 4 holds every `tag_` key of the schema.
local tag_keys = {}
for _, f in ipairs(M.PRESET_SCHEMA) do
    if f.key:sub(1, 4) == "tag_" then tag_keys[#tag_keys + 1] = f.key end
end
M.PANEL_PAGES = {
    { number = 1, title = "Scoring", keys = { "genre", "rank_mode", "sharp_mode", "exp_mode", "keep_mode",
        "keep_margin", "spread_keepers", "keep_angles", "motion_look", "number_reads", "sharp_judge", "non_keeper",
        "reject_cap", "star_scale", "star_slope", "first_picks" } },
    { number = 2, title = "Bursts", keys = { "group_native", "group_tag_1", "group_tag_2", "group_tag_3" } },
    { number = 3, title = "Penalties & Speed", keys = { "apply_while_scoring", "fast_jpeg_decode",
        "penalise_overexposed", "penalise_underexposed", "penalise_eyes_closed", "penalise_cut_off",
        "penalise_blocked", "blank_share", "no_vehicle_leave", "car_boxes_only" } },
    { number = 4, title = "Tags Written", keys = tag_keys },
    { number = 5, title = "Run", keys = { "run_tag" } },
    { number = 6, title = "Tools", keys = {} },
}
M.PANEL_OTHER_KEYS = {}

-- One "tag_<key>" setting per row. Off = runs stop writing the row's tags and
-- detach them from the images they process; ratings and keeper picks are
-- unchanged. kind: output (flags and keeper picks), check (frames to look at by
-- hand, written whatever the diagnostics say), diag (how the run decided).
-- Keys match FLAGS names for the flag rows.
M.TAG_TOGGLES = {
    { key = "keeper", label = "Keeper", kind = "output", writes = { "Keeper" },
      when = "The best frame (or frames) of its burst." },
    { key = "rejected", label = "Rejected", kind = "output", writes = { "Rejected" },
      when = "Far behind its burst's best (Why|Far behind, at most rejects per burst) or blank (Why|Blank); rated -1 whatever the non-keepers setting. A frame that only lost to a sharper one is not tagged Rejected." },
    { key = "overexposed", label = "Overexposed", kind = "output", writes = { "Overexposed" },
      when = "Blown highlights, judged by the exposure setting." },
    { key = "underexposed", label = "Underexposed", kind = "output", writes = { "Underexposed" },
      when = "Crushed shadows, judged by the exposure setting." },
    { key = "eyes_closed", label = "Eyes Closed", kind = "output", writes = { "Eyes Closed" },
      when = "Face & eyes sharpness only: a face big enough to judge shows no open eyes. Dark sunglasses trigger it too." },
    { key = "cut_off", label = "Cut Off", kind = "output", writes = { "Cut Off" },
      when = "Motorsport sharpness with a vehicle detector only: the car touches the frame edge it is driving towards, or runs well past another edge. Not when every frame of the burst is cut off, or the car fills most of the frame." },
    { key = "blocked", label = "Blocked", kind = "output", writes = { "Blocked" },
      when = "Motorsport sharpness with a vehicle detector only: a nearer vehicle covers over a quarter of the car. Not when every frame of the burst is blocked." },
    { key = "blank", label = "Blank", kind = "output", writes = { "Blank" },
      when = "Nearly the whole frame is one flat colour (lens cap, black barrier, blown sky, fog), judged by the blank frames setting. Always rejected, even when every frame of the burst is blank." },
    { key = "subject_guessed", label = "Subject guessed", kind = "check", writes = { "Subject|Vehicle|Guessed" },
      when = "Subject tracking (SAM) only. The vehicle detector found nothing, so SAM got the guessed subject point: check these frames by hand." },
    { key = "subject", label = "Subject", kind = "diag", writes = { "Subject|Vehicle|Detected" },
      when = "Subject tracking (SAM) only. Detected: the vehicle detector found the car SAM was pointed at." },
    { key = "technique", label = "Technique", kind = "diag", writes = { "Technique|Panning", "Technique|Shallow DoF", "Technique|Motion Blur", "Technique|Missed Pan", "Technique|Zoom Burst", "Technique|Creative Burst" },
      when = "The burst's EXIF switched its sharpness mode: panning at 1/125 s or slower, shallow DoF at f/4 or wider. Motorsport mode tags each frame instead: Panning (car sharp, background streaked), Motion Blur (whole frame blurred in one line), Missed Pan (car blurred across the pan), Zoom Burst (streaks run out from the frame centre). Creative Burst: most of the burst is zoom bursts or motion blur at 1/8 s or slower, so none of it is rejected as cut off or far behind." },
    { key = "scored", label = "Scored", kind = "diag", writes = { "Scored|Masked", "Scored|Subject bias" },
      when = "Subject tracking (SAM) only. Masked: the burst was ranked on SAM masks. Subject bias: a shortlisted frame got no mask, so the burst fell back." },
    { key = "why", label = "Why", kind = "diag",
      writes = { "Why|Keeper", "Why|Keeper by margin", "Why|Outranked", "Why|Graded", "Why|Not shortlisted",
          "Why|No vehicle", "Why|Close call", "Why|Blank", "Why|Spread", "Why|Number clearer", "Why|Subject clearer",
          "Why|Other angle", "Why|Motion look", "Why|Far behind", "Why|Not a first pick" },
      when = "Every scored frame, saying how it was decided. Keeper: kept by rank. Keeper by margin: kept by the keeper margin. Outranked: lost to a sharper frame. Far behind: lost and scored under 30% of its burst's best (times star strictness), so it is rejected (at most rejects per burst, worst first). Graded: lost and rated by burst. Not shortlisted: subject tracking (SAM) left it out of the shortlist. No vehicle: the detector found no car, so the frame kept its rating (only with \"Leave Frames with No Vehicle\" on). Blank: the frame is one flat colour, so it was rejected. Close call: the last keeper and the best frame that lost scored within 5% of each other; the keeper is still kept, but check both. Spread: kept as its stretch of the burst's best frame over a sharper frame elsewhere (only with \"Spread Keepers Over the Burst\" on). Number clearer: kept over the sharper frame of a close call because tagging read the car's number clearer in it (only with \"Break Close Calls on the Number Read\" on). Subject clearer: kept over the sharper frame of a close call because the sharpness judge scored its car clearer (only with \"Break Close Calls with the Sharpness Judge\" on). Other angle: the best frame of a view of the car the sharpest keeper does not show, kept one star below it (only with \"Keep the Other Angles\" on). Motion look: the burst's straightest motion blur with the car in view, kept as well as the sharp keepers (only with \"Keep a Motion-Blur Frame\" on). Not a first pick: left alone because it is not one of the run's first picks (only with first picks on). Filter on one to step through, say, every frame that lost to the margin." },
}

-- Headings of the tags-written page, in order; each TAG_TOGGLES row's `kind` is one of these.
M.TAG_KINDS = {
    { kind = "output", label = "Outputs" },
    { kind = "check", label = "Check by Hand" },
    { kind = "diag", label = "How It Decided" },
}

-- TAG_TOGGLES rows grouped by TAG_KINDS order, file order within a kind.
function M.tag_rows_in_order()
    local rows = {}
    for _i, k in ipairs(M.TAG_KINDS) do
        for _j, t in ipairs(M.TAG_TOGGLES) do
            if t.kind == k.kind then rows[#rows + 1] = t end
        end
    end
    return rows
end

-- enabled: tag_<key> switches by key. Returns the relative names (column 7 form)
-- of every switched-off non-output row, for filter_diag.
function M.diag_off(enabled)
    local off = {}
    for _i, t in ipairs(M.TAG_TOGGLES) do
        if t.kind ~= "output" and not enabled[t.key] then
            for _j, rel in ipairs(t.writes) do off[rel] = true end
        end
    end
    return off
end

-- Returns preset text in today's keys, and the list of keys filled from old ones; text that does
-- not decode or needs no upgrade comes back unchanged, list nil.
-- tag_subject_guessed is copied from tag_subject when absent. A preset from the grouping support
-- dropdown (group_support, group_node, car_tag_node) becomes group_native plus tag nodes that
-- group the same way: "tags" turns native groups off with its node first (blank node: the latest
-- grouping run), the car node follows, and "none" drops the car node, which split nothing.
function M.upgrade_preset_text(text)
    local decoded = M.preset_decode(text)
    if not decoded then return text end
    local filled = {}
    if decoded.tag_subject_guessed == nil and decoded.tag_subject ~= nil then
        decoded.tag_subject_guessed = decoded.tag_subject
        filled[#filled + 1] = "tag_subject_guessed"
    end
    if decoded.group_native == nil and decoded.group_support ~= nil then
        decoded.group_native = decoded.group_support == "native"
        filled[#filled + 1] = "group_native"
        local nodes = {}
        if decoded.group_support == "tags" then
            local node = tostring(decoded.group_node or ""):match("^%s*(.-)%s*$")
            nodes[1] = node ~= "" and node or M.LATEST_GROUPING_NODE
        end
        local car_node = tostring(decoded.car_tag_node or ""):match("^%s*(.-)%s*$")
        if car_node ~= "" and decoded.group_support ~= "none" then nodes[#nodes + 1] = car_node end
        for n, node in ipairs(nodes) do
            decoded[GROUP_TAG_KEYS[n]] = node
            filled[#filled + 1] = GROUP_TAG_KEYS[n]
        end
    end
    if #filled == 0 then return text end
    return M.preset_encode(M.PRESET_SCHEMA, decoded), filled
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
-- Progress bar split: analysis (in SAM mode: finding subjects, then SAM, then
-- scoring) fills it to PROGRESS_ANALYSIS, applying ratings fills the rest.
local PROGRESS_ANALYSIS = 0.75
local PROGRESS_SUBJECTS = 0.15   -- SAM mode: end of finding subjects
local PROGRESS_SAM = 0.45        -- SAM mode: end of segmenting
local STAGE2_WRITE_BUDGET = 12   -- writes per slice before yielding
local STAGE2_SLEEP_MIN_MS = 20   -- minimum yield per slice
local STAGE2_SLEEP_MAX_MS = 300  -- maximum yield per slice
-- Final drain only: the scorer has exited, so a slice can hold more tag and rating writes.
local STAGE2_BATCH_WRITE_BUDGET = 60
local STAGE2_BATCH_LINES = 200   -- results per final-drain slice

local IS_WINDOWS = C.IS_WINDOWS

local TMP_DIR = dt.configuration.tmp_dir
-- Leftovers of a darktable that crashed or was killed mid-run; a day old is surely not live.
C.sweep_temp(TMP_DIR, "dt_assisted_culling_", 86400)
-- The run log: this plugin's lines plus the scorer's stderr. Kept in the
-- config dir, which outlives tmp_dir; the 5 runs before it are kept as .prev.log, .prev2.log to .prev5.log.
local LOG_PATH = dt.configuration.config_dir .. "/assisted_culling.log"
local LOGS_KEPT = 5
-- Lua errors (panel build, callbacks, events) go to their own log, which runs never rotate.
local LUA_LOG_PATH = dt.configuration.config_dir .. "/assisted_culling.lua.log"
local guard = C.error_guard(dt, LUA_LOG_PATH, "Assisted Culling")
local new_widget = C.guarded_widget_maker(dt, guard)

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

-- `--detector <model> --detections <shared cache>`, plus `--car-boxes <tagging's file>` when
-- the "Only car boxes" setting is on.
local function detector_argv(detector, settings)
    local argv = { "--detector", detector, "--detections", C.detections_path(dt) }
    if settings.car_boxes_only then
        table.move({ "--car-boxes", (M.car_boxes_path(dt.configuration.config_dir,
            dt.preferences.read("assisted_tagging", "last_collection", "string"))) }, 1, 2, #argv + 1, argv)
    end
    return argv
end
local REPORT_PATH = dt.configuration.config_dir .. "/assisted_culling/last-run.csv"
local REPORT_ARCHIVE_DIR = dt.configuration.config_dir .. "/assisted_culling/reports"
-- "id,previous,written,path" per image the last rating-changing run rated; read by M.restore_ratings.
-- The path is last, so its commas are kept; a line break in it is written as a space.
local PREVIOUS_RATINGS_PATH = dt.configuration.config_dir .. "/assisted_culling.previous-ratings.csv"

-- Masks are per darktable instance (not per run) so a scorer finishing after a cancel
-- can't overwrite a live run's, and they share the sweep's naming.
local MASK_BASE = C.temp_base(TMP_DIR, "dt_assisted_culling_")
local function mask_path_for(id)
    return MASK_BASE .. "mask_" .. tostring(id) .. ".png"
end

-- HyperIQA from huggingface.co/86Cao/IQA-ONNX-Models; its weights sit beside it in
-- hyperiqa_model.onnx.data, a name the model file holds, so neither can be renamed
local JUDGE_FILE = "hyperiqa_model.onnx"

if dt.gui then
    C.register_shared_prefs(dt)
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
    text = M.upgrade_preset_text(text)
    return (M.preset_merge(M.PRESET_SCHEMA, M.preset_decode(text) or {}))
end
local settings = remembered_settings()

local file_exists, read_file, first_existing = C.file_exists, C.read_file, C.first_existing

-- Defined with the log buffer further down; the preference readers log deprecations.
local log

local function plugin_folder_pref()
    return C.plugin_folder(dt, "assisted_culling", "darktable-assisted-culling", log)
end

-- The script is found from the plugin folder preference alone when it's set; a
-- wrong folder is an error rather than a quiet switch to some other copy.
local function score_script()
    local folder = plugin_folder_pref()
    if folder ~= "" then
        local script = folder .. "/python/score_images.py"
        if not (df.test_file(script, "e") or file_exists(script)) then
            error("the plugins folder preference gives " .. folder .. ", which has no python/score_images.py; point it at the folder holding darktable-assisted-culling, or clear it to auto-detect", 0)
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

local function plugin_root(script) return C.plugin_root(plugin_folder_pref(), script, THIS_DIR) end

-- The best installed vehicle detector in models/ (M.pick_detector), logged; "" when none is.
local function detector_path(script)
    local dir = plugin_root(script) .. "/models/"
    local file, line = M.pick_detector(function(f) return file_exists(dir .. f) end)
    if not file then return "" end
    log(line)
    return dir .. file
end

local function python_bin(script) return C.python_bin(plugin_root(script), THIS_DIR, IS_WINDOWS, df) end

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
        return nil, "this darktable has no AI support; subject tracking needs darktable 5.6 or newer."
    end
    local id = dt.ai.model_for_task("mask")
    if not id then
        return nil, "no AI mask model is enabled; turn one on in preferences → AI."
    end
    local ok_list, models = pcall(dt.ai.models)
    for _, m in ipairs(ok_list and models or {}) do
        if m.id == id then
            local about = ((m.id or "") .. " " .. (m.name or "") .. " " .. (m.description or "")):lower()
            if about:find("segnext", 1, true) then
                return nil, "the enabled mask model is SegNext; subject tracking needs a SAM or SAM 2 mask model."
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
local function write_manifest(images, burst_of, mask_for_id, shortlisted, edited, split_of)
    local f = io.open(MANIFEST_PATH, "w")
    if not f then return false end
    for _, img in ipairs(images) do
        local path = img.path .. "/" .. img.filename
        local fields = { img.id, path, burst_of[img.id],
            mask_for_id and mask_for_id[img.id] or "",
            shortlisted and (shortlisted[img.id] and "1" or "0") or "",
            edited and tostring(img.change_timestamp) or "",
            img.exif_exposure or 0, img.exif_aperture or 0, img.exif_focal_length or 0,
            split_of and split_of[img.id] or "" }
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
-- each synced to its own tag. `summary` labels the count in the done message. A flag with
-- `rejects` has no "lowers stars" switch: the scorer always rejects it (blank_share turns it off).
local FLAGS = {
    { name = "overexposed", tag = "Assisted Culling|Overexposed", summary = "overexposed" },
    { name = "underexposed", tag = "Assisted Culling|Underexposed", summary = "underexposed" },
    { name = "eyes_closed", tag = "Assisted Culling|Eyes Closed", summary = "with eyes closed" },
    { name = "cut_off", tag = "Assisted Culling|Cut Off", summary = "cut off" },
    { name = "blocked", tag = "Assisted Culling|Blocked", summary = "blocked" },
    { name = "blank", tag = "Assisted Culling|Blank", summary = "blank", rejects = true },
}
local ALL_TAGS = { TAG_KEEPER, TAG_REJECT, TAG_CULLED }
for _, f in ipairs(FLAGS) do ALL_TAGS[#ALL_TAGS + 1] = f.tag end

local function tag_enabled(key)
    return settings["tag_" .. key]
end

-- Flags the user set to tag-only, as the scorer's --tag-only-flags value.
local function tag_only_flags()
    local names = {}
    for _, f in ipairs(FLAGS) do
        if not f.rejects and not settings["penalise_" .. f.name] then
            names[#names + 1] = f.name
        end
    end
    return table.concat(names, ",")
end

local fmt_eta = C.fmt_eta

-- Lines reach disk at once, except while a scorer process appends its stderr to
-- the same file (run_log.hold to run_log.release).
local run_log = C.run_log(LOG_PATH)
log = run_log.log

-- Only call while no scorer process is running.
local flush_log = run_log.flush

local function say(msg)
    dt.print(msg)
    log(msg)
end

-- A panel label, not dt.print_hinter: the hinter crashes darktable 5.6 when set often from Lua.
local function show_status(text)
    if not status_label or text == status_text then return end
    status_text = text
    status_label.label = text
end

-- the "To check" box above the progress line
-- filled by install_panel: the To check Fix buttons run panel actions
local fixes = {}
local alerts = C.alerts_box(new_widget, dt.configuration.config_dir .. "/assisted_culling.checks.txt", log, fixes)

-- dt.print_error only writes to darktable's log (-d lua); users never see it. Errors also go to To check.
-- `to_check` is the To check line when the toast's text doesn't read well there.
local function notify_error(msg, to_check)
    dt.print(msg)
    dt.print_error(msg)
    log(msg)
    alerts.add(to_check or (msg:gsub("^Assisted Culling: ", "")))
end

-- The To check line for a failed scorer run: `lead`, then the scorer's last log line (a crash's
-- last line names the error), not the cut log tail the toast carries. A tail read_log_tail cut
-- starts mid-line, so its first line is skipped.
local function scorer_failure(lead, tail)
    local last, whole = nil, #tail < 800
    for line in tail:gmatch("[^\r\n]+") do
        if whole and not line:find(" lua: ", 1, true) then last = line end
        whole = true
    end
    return lead .. (last and ": " .. last:gsub("^%d%d:%d%d:%d%d py: ", "") or "") .. " (see the log)"
end

local function pretty(s)
    return (tostring(s):gsub("_", " "))
end

local function tags_of(img) return C.tags_of(tags, img) end

-- Returns 1 if a write was needed (attach/detach), else 0. Creates the tag only
-- to attach it, so a branch that is turned off never appears in the tag list.
-- tally counts the writes under "+name" (attach) and "-name" (detach). tag_named
-- returns the run's tag object for a name.
local function sync_tag(img, have, name, wanted, tally, tag_named)
    if wanted and not have[name] then
        tags.attach(tag_named(name), img); tally["+" .. name] = (tally["+" .. name] or 0) + 1; return 1
    elseif not wanted and have[name] then
        tags.detach(tag_named(name), img); tally["-" .. name] = (tally["-" .. name] or 0) + 1; return 1
    end
    return 0
end

-- image id → { previous, written, path } from PREVIOUS_RATINGS_PATH: the rating the image had
-- before a run first changed it, and the last rating a run wrote.
local function read_saved_ratings()
    local record_of = {}
    for id, previous, written, path in (read_file(PREVIOUS_RATINGS_PATH) or "")
            :gmatch("(%d+),(%-?%d+),(%-?%d+),([^\r\n]*)") do
        record_of[tonumber(id)] = { previous = tonumber(previous), written = tonumber(written), path = path }
    end
    return record_of
end

-- verify: score and rank as a cull would, write nothing, and list in To check what a cull would change
function M.score_images(images, rank_mode, sharp_mode, exp_mode, keep_mode, nk_mode, verify)
    rank_mode = rank_mode or "universal"
    sharp_mode = sharp_mode or "subject_focus"
    exp_mode = exp_mode or "whole_frame"
    keep_mode = keep_mode or "dynamic_burst"
    nk_mode = nk_mode or "leave"

    local n_locked = 0
    -- false while the run has only looked at the selection: no run files or log of its own yet
    local run_started = false
    local culling_job = nil
    local sam_ids = {}
    local main_started = false
    local stage_a_alive = false
    local run_began = os.time()
    -- image id → { path, previous, written }: the rating each image had when the run first met it
    local previous_ratings = {}
    -- earlier runs' records; an image still at its written rating has plugin stars, not the user's
    local saved_ratings = read_saved_ratings()

    local success, run_err = C.logged_call(log, "cull", function()
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
            dt.print(n_locked > 0 and _("Assisted Culling: Every selected image is tagged Assisted Culling|Locked, so there's nothing to cull. Remove that tag from images you want scored.")
                or _("Assisted Culling: Select some images first."))
            return
        end

        run_started = true
        alerts.begin(verify and "Verify" or "Cull")
        new_run_paths()
        flush_log() -- anything logged since the last run (e.g. a failed clear) belongs to its log
        run_log.rotate(LOGS_KEPT)
        log(string.format("%s started: darktable %s, %d images (%d locked left out)", verify and "verify" or "run",
            tostring(dt.configuration.version), #images, n_locked))
        log(string.format("settings: rank %s, sharpness %s, exposure %s, keepers %s, non-keepers %s, rejects per burst %s, first picks %s",
            rank_mode, sharp_mode, exp_mode, keep_mode, nk_mode, tostring(settings.reject_cap), tostring(settings.first_picks)))

        -- the job and the start message go up before the selection's tags and groups are read
        if dt.gui then
            culling_job = dt.gui.create_job(_("Assisted Culling"), true, stop_job)
            culling_job.percent = 0.0
        end
        say(string.format("Assisted Culling: %s on %s…", verify and "Verify started" or "Started",
            #images == 1 and "1 image" or #images .. " images"))
        local sam_model
        if sharp_mode == "sam_subject" then
            local why
            sam_model, why = sam_model_id()
            if not sam_model then error("Subject tracking (SAM) can't run: " .. why, 0) end
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
        -- the tag names across a shot's members (name → true)
        local function have_of(img)
            local have = {}
            for _, m in ipairs(members(img)) do
                for name in pairs(tags_of(m)) do have[name] = true end
            end
            return have
        end
        local nodes = {}
        for _, key in ipairs(GROUP_TAG_KEYS) do
            local node = (settings[key] or ""):match("^%s*(.-)%s*$")
            if node ~= "" then nodes[#nodes + 1] = node end
        end
        local grouping_on = settings.group_native or #nodes > 0
        local tag_items = {}
        if #nodes > 0 then
            for _, img in ipairs(primaries) do tag_items[#tag_items + 1] = { id = img.id, tags = have_of(img) } end
        end
        -- id → the photo's child tag under the node, the ids with several children, a note for the log
        local function node_keys(node)
            if node == M.LATEST_GROUPING_NODE then
                local tag_of, n_runs = M.latest_group_keys(tag_items)
                return tag_of, {}, n_runs > 0 and string.format("latest run per image (%d runs)", n_runs) or "no grouping tags found"
            end
            local tag_of, tag_multi = M.tag_group_keys(tag_items, node)
            return tag_of, tag_multi, next(tag_of) == nil and "matches no selected image" or nil
        end
        local function cut_note(text, note, tag_multi)
            return text .. (note and " (" .. note .. ")" or "")
                .. (#tag_multi > 0 and ", several children on ids " .. table.concat(tag_multi, ",") or "")
        end
        -- Native groups form the groups when on, else the first filled tag node does; every later
        -- node cuts them further.
        local key_of, cut_notes, first_split = {}, {}, 1
        if settings.group_native then
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
        elseif nodes[1] then
            local tag_multi, note
            key_of, tag_multi, note = node_keys(nodes[1])
            cut_notes[1] = cut_note(string.format("tag node %s forms the groups", nodes[1]), note, tag_multi)
            first_split = 2
        end
        local n_groups_before_split = 0
        do
            local pre_of, seen = M.number_groups(primary_ids, key_of), {}
            for _, id in ipairs(primary_ids) do
                if not seen[pre_of[id]] then seen[pre_of[id]] = true; n_groups_before_split = n_groups_before_split + 1 end
            end
        end
        -- id → the child tags that split it off, for manifest column 10
        local split_of = nil
        for n = first_split, #nodes do
            local tag_of, tag_multi, note = node_keys(nodes[n])
            local n_split, n_tagged
            key_of, n_split, n_tagged = M.split_by_tag(primary_ids, key_of, tag_of, tag_multi)
            split_of = split_of or {}
            for id, child in pairs(tag_of) do split_of[id] = split_of[id] and split_of[id] .. "/" .. child or child end
            cut_notes[#cut_notes + 1] = cut_note(string.format("tag node %s: %d grouped images tagged, %d groups split",
                nodes[n], n_tagged, n_split), note, tag_multi)
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
        local msg = string.format("grouping: native groups %s, %d of %d images in groups of 2+",
            settings.group_native and "on" or "off", grouped, #primaries)
        for _, note in ipairs(cut_notes) do msg = msg .. ", " .. note end
        log(msg)
        if settings.group_native and #nodes == 0 and grouped == 0 then
            local items = {}
            for _, img in ipairs(primaries) do items[#items + 1] = { id = img.id, tags = have_of(img) } end
            if M.group_tags_hint(grouped, items) then
                log(M.TAG_NODE_HINT)
                dt.print("Assisted Culling: " .. M.TAG_NODE_HINT)
            end
        end

        local overlap, fast_jpeg = settings.apply_while_scoring, settings.fast_jpeg_decode

        pcall(os.remove, MANIFEST_PATH)
        pcall(os.remove, RESULTS_PATH)
        pcall(os.remove, RESULTS_PATH .. ".tmp")
        pcall(os.remove, RESULTS_PATH .. ".all")
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

        if not write_manifest(primaries, burst_of, nil, nil, sam_model ~= nil, split_of) then
            error("couldn't write the image list to darktable's tmp folder (disk full or no write access?)", 0)
        end

        log(string.format("fast JPEG %s, apply while scoring %s, SAM model %s",
            tostring(fast_jpeg), tostring(overlap), tostring(sam_model or "none")))
        say(string.format("Assisted Culling: Scoring %d images in %d groups (%s keepers, %s ranking, %s grouping).",
            n_primary, n_bursts, pretty(keep_mode), pretty(rank_mode),
            settings.group_native and (#nodes > 0 and "native + tag" or "native") or (#nodes > 0 and "tag" or "no")))
        if n_dups > 0 then
            say(string.format("Assisted Culling: %d image(s) share a shot with another (a duplicate, or the RAW of a RAW+JPEG pair); each shot is scored once and its result copied to all of it.", n_dups))
        end
        if n_primary > 1000 then
            say(_("Assisted Culling: Large selection, this can take several minutes. Click Cancel Culling to stop at any time."))
        end
        show_status(_("starting analysis…"))

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
            local detector = detector_path(sc_script)
            local points_argv = { sc_script, MANIFEST_PATH, POINTS_PATH, "--emit-saliency-points" }
            if detector ~= "" then
                local det = detector_argv(detector, settings)
                table.move(det, 1, #det, #points_argv + 1, points_argv)
            end
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
            run_log.hold()
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
                show_status(string.format("finding subjects %s / %s", cur or "0", tot or "?"))
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
                if not stage_a_alive then run_log.release() end
            else
                run_log.release()
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
                    show_status(string.format("outlining subjects %d / %d%s", i, #points,
                        fmt_eta(os.time() - sam_start, i, #points)))
                    dt.control.sleep(10) -- hand the Lua lock back so the cancel button responds
                end

                -- not dt.print_error: the run carries on, and a red toast reads as a failure
                if made < #points and not cancelled() then
                    local why = first_sam_error == "empty mask" and "no subject found"
                        or ("first error: " .. tostring(first_sam_error))
                    say(string.format("Assisted Culling: Subject tracking outlined %d of %d frames (%s). Bursts without an outline use center-weighted subject bias instead; the run continues.",
                        made, #points, why))
                    alerts.add(string.format("Subject tracking outlined %d of %d frames (%s); the rest used subject bias.", made, #points, why))
                end
            end

            if not write_manifest(primaries, burst_of, mask_for_id, shortlisted, true, split_of) then
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
            "--reject-cap", tostring(tonumber(settings.reject_cap) or 0),
            "--tag-only-flags", tag_only_flags(),
            "--star-scale", tostring(settings.star_scale or "1"),
            "--keep-margin", tostring((tonumber(settings.keep_margin) or 0) / 100),
            "--blank-share", tostring((tonumber(settings.blank_share) or 0) / 100),
        }
        if fast_jpeg then argv[#argv + 1] = "--fast-jpeg" end
        if settings.no_vehicle_leave then argv[#argv + 1] = "--no-vehicle-leave" end
        if settings.spread_keepers then argv[#argv + 1] = "--spread-keepers" end
        if settings.keep_angles then argv[#argv + 1] = "--keep-angles" end
        if settings.motion_look then argv[#argv + 1] = "--motion-look" end
        if settings.star_slope then argv[#argv + 1] = "--star-slope" end
        if tonumber(settings.first_picks) then
            table.move({ "--first-picks", settings.first_picks }, 1, 2, #argv + 1, argv)
        end
        if settings.number_reads then
            table.move({ "--number-reads", (M.car_boxes_path(dt.configuration.config_dir,
                dt.preferences.read("assisted_tagging", "last_collection", "string"))) }, 1, 2, #argv + 1, argv)
        end
        if sharp_mode == "motion_aware" then
            local detector = detector_path(sc_script)
            if detector ~= "" then
                local det = detector_argv(detector, settings)
                table.move(det, 1, #det, #argv + 1, argv)
            end
            if settings.sharp_judge then
                local judge = plugin_root(sc_script) .. "/models/" .. JUDGE_FILE
                if not file_exists(judge) then
                    error("\"Break Close Calls with the Sharpness Judge\" is on but " .. judge
                        .. " is missing: download " .. JUDGE_FILE .. " and " .. JUDGE_FILE
                        .. ".data (see the README), or turn it off", 0)
                end
                table.move({ "--sharp-judge", judge }, 1, 2, #argv + 1, argv)
            end
        end
        if sam_model then
            table.move({ "--prescores", PRESCORE_PATH, "--sam-model", sam_model }, 1, 4, #argv + 1, argv)
        end
        argv[#argv + 1], argv[#argv + 2] = "--cache", CACHE_PATH
        -- Why and --learn read the last cull's report, so a verify keeps it
        if not verify then
            table.move({ "--report", REPORT_PATH, "--report-archive-dir", REPORT_ARCHIVE_DIR }, 1, 4, #argv + 1, argv)
        end

        if cancelled() then
            M.cancel_requested = true -- cancelled during the SAM stages: don't start scoring at all
            log("cancelled before scoring")
        else
            log("scoring: " .. command_line(py_bin, argv))
            run_log.hold()
            local launched, why = run_async_python(py_bin, argv, LOG_PATH, true, DONE_PATH)
            if not launched then error("couldn't start the scorer: " .. why, 0) end
            main_started = true
        end

        local done_code = nil
        local stage1_start = os.time()

        local applied_total, failed_total, first_error, n_skipped = 0, 0, nil, 0
        local stats = { keepers = 0, others = 0, rejected = 0, flagged = {}, guessed = 0, subject_bias = 0 }
        -- image ids for To check
        local guessed_ids, close_ids, no_vehicle_ids = {}, {}, {}
        -- verify: burst number → { ids, name, keepers, tagged, differs }, in the order met; one line per photo
        local verify_bursts, verify_order = {}, {}
        local differ_details, hand_ids, hand_details = {}, {}, {}
        for _, f in ipairs(FLAGS) do stats.flagged[f.name] = 0 end

        -- ---- result application (shared by "while scoring" and the final drain) ----
        -- one stamp per run; not in ALL_TAGS, so clearing marks and later runs leave earlier stamps alone
        local run_stamp = settings.run_tag and os.date(TAG_RUN_FORMAT) or nil

        -- Reads are cheap; writes reload the lighttable collection / rewrite XMP, so skip no-ops.
        -- Every mark is a tag, never a colour label, so a re-run or "clear" can undo exactly
        -- what earlier passes set without touching labels the user applied by hand.
        -- Set for the final drain, which runs bigger slices: no scorer is sharing the CPU by then.
        local final_drain = false

        -- read once per run
        local tag_on = {}
        for _, t in ipairs(M.TAG_TOGGLES) do tag_on[t.key] = tag_enabled(t.key) end
        local diag_off = M.diag_off(tag_on)
        -- rejected: a frame the scorer rejected (far behind its burst's best, or blank). A frame
        -- left alone for no vehicle is neither.
        -- The rating and Keeper / Rejected are written here; every other tag change is queued
        -- in detail_queue and written after the end message.
        local rating_writes, all_writes, tag_tally = 0, 0, {}
        -- first picks leaves every rating alone, keeper or not
        local demote_plugin_stars, demoted = nk_mode == "reject" and not tonumber(settings.first_picks), 0
        local detail_queue, detail_total = {}, 0
        -- one lookup per tag name per run
        local tag_objs = {}
        local function tag_named(name)
            tag_objs[name] = tag_objs[name] or tags.create(name)
            return tag_objs[name]
        end
        local function apply_to_image(img, want_rating, is_keeper, flags, diag, rejected)
            local writes = 0
            local have = tags_of(img)
            local path = (img.path .. "/" .. img.filename):gsub("[\r\n]", " ")
            local saved = saved_ratings[img.id]
            local plugin_rated = saved ~= nil and saved.path == path and img.rating == saved.written

            -- reject mode leaves a non-keeper's own rating alone; stars a run wrote go back to 0
            if want_rating == nil and demote_plugin_stars and not is_keeper and plugin_rated and img.rating ~= 0 then
                want_rating = 0
                demoted = demoted + 1
            end

            if want_rating ~= nil and img.rating ~= want_rating then
                local record = previous_ratings[img.id]
                    or (plugin_rated and saved)
                    or { path = path, previous = img.rating }
                record.written = want_rating
                previous_ratings[img.id] = record
                img.rating = want_rating; writes = writes + 1
                rating_writes = rating_writes + 1
            end

            writes = writes + sync_tag(img, have, TAG_KEEPER, is_keeper and tag_on.keeper, tag_tally, tag_named)
            writes = writes + sync_tag(img, have, TAG_REJECT, rejected and tag_on.rejected, tag_tally, tag_named)

            local attach, detach = M.diag_tag_changes(have, diag)
            for _, f in ipairs(FLAGS) do
                local wanted = flags[f.name] == true and tag_on[f.name]
                if wanted and not have[f.tag] then
                    attach[#attach + 1] = f.tag
                elseif not wanted and have[f.tag] then
                    detach[#detach + 1] = f.tag
                end
            end
            if run_stamp and not have[run_stamp] then attach[#attach + 1] = run_stamp end
            -- marker from older versions; Keeper/Rejected already say "processed"
            if have[TAG_CULLED] then detach[#detach + 1] = TAG_CULLED end
            if #attach + #detach > 0 then
                detail_queue[#detail_queue + 1] = { img = img, attach = attach, detach = detach }
                detail_total = detail_total + #attach + #detach
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
            local rejected = not is_keeper and not diag:find(";Why|No vehicle;", 1, true)
                and (diag:find(";Why|Far behind;", 1, true) ~= nil
                    or diag:find(";Why|Blank;", 1, true) ~= nil)
            if rejected then stats.rejected = stats.rejected + 1 end
            local guessed = diag:find(";Subject|Vehicle|Guessed;", 1, true) ~= nil
            local close_call = diag:find(";Why|Close call;", 1, true) ~= nil
            local no_vehicle = diag:find(";Why|No vehicle;", 1, true) ~= nil
            if guessed then stats.guessed = stats.guessed + 1 end
            if diag:find(";Scored|Subject bias;", 1, true) then stats.subject_bias = stats.subject_bias + 1 end
            local want_rating = nil
            if parts[6] ~= "leave" then want_rating = tonumber(parts[6]) or 0 end

            if verify then
                local burst = verify_bursts[burst_of[id]]
                if not burst then
                    burst = { ids = {}, keepers = 0, tagged = 0, differs = false }
                    verify_bursts[burst_of[id]] = burst
                    verify_order[#verify_order + 1] = burst
                end
                for _, img in ipairs(group) do
                    local ok_check, check_err = pcall(function()
                        local path = (img.path .. "/" .. img.filename):gsub("[\r\n]", " ")
                        local saved = saved_ratings[img.id]
                        local want = want_rating
                        if want == nil and demote_plugin_stars and not is_keeper and img.rating ~= 0
                            and saved ~= nil and saved.path == path and img.rating == saved.written then
                            want = 0
                        end
                        burst.ids[#burst.ids + 1] = img.id
                        burst.name = burst.name or img.filename
                        if is_keeper then burst.keepers = burst.keepers + 1 end
                        if tags_of(img)[TAG_KEEPER] then burst.tagged = burst.tagged + 1 end
                        if want == nil or img.rating == want then return end
                        if saved ~= nil and saved.path == path and img.rating ~= saved.written then
                            hand_ids[#hand_ids + 1] = img.id
                            hand_details[#hand_details + 1] = string.format("%s: %d stars, the last cull wrote %d",
                                img.filename, img.rating, saved.written)
                        else
                            burst.differs = true
                            differ_details[#differ_details + 1] = string.format("%s: %d stars, a cull now gives %d",
                                img.filename, img.rating, want)
                        end
                    end)
                    if ok_check then
                        applied_total = applied_total + 1
                    else
                        failed_total = failed_total + 1
                        first_error = first_error or tostring(check_err)
                        log(C.image_label(img) .. ": verify couldn't read it: " .. tostring(check_err))
                    end
                end
                return 0
            end

            local writes = 0
            for _, img in ipairs(group) do
                local ok_apply, res = pcall(apply_to_image, img, want_rating, is_keeper, flags,
                    M.filter_diag(parts[7], diag_off), rejected)
                if ok_apply then
                    if guessed then guessed_ids[#guessed_ids + 1] = img.id end
                    if close_call then close_ids[#close_ids + 1] = img.id end
                    if no_vehicle then no_vehicle_ids[#no_vehicle_ids + 1] = img.id end
                    applied_total = applied_total + 1
                    writes = writes + res
                    all_writes = all_writes + res
                else
                    failed_total = failed_total + 1
                    first_error = first_error or tostring(res)
                    log(C.image_label(img) .. ": rating and Keeper / Rejected tags failed: " .. tostring(res))
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

        -- os.clock is wall time on Windows: seconds in tag and rating writes, pauses and the
        -- final drain's progress updates (job bar, status label, toast), which wait for darktable's GUI
        local write_s, pause_s, bar_s, label_s, toast_s, drain_s = 0, 0, 0, 0, 0, 0

        -- One paced slice: stop after the write budget, then yield to the GUI in
        -- proportion to how long the slice took. Returns false if nothing was pending.
        local function apply_slice()
            if pending_idx > #pending then return false end
            local slice_start = os.clock()
            if final_drain then
                local budget, lines = STAGE2_BATCH_WRITE_BUDGET, 0
                while pending_idx <= #pending and budget > 0 and lines < STAGE2_BATCH_LINES do
                    budget = budget - apply_line(pending[pending_idx])
                    pending_idx = pending_idx + 1
                    lines = lines + 1
                end
            else
                local budget = STAGE2_WRITE_BUDGET
                while pending_idx <= #pending and budget > 0 do
                    budget = budget - math.max(1, apply_line(pending[pending_idx]))
                    pending_idx = pending_idx + 1
                end
            end
            write_s = write_s + os.clock() - slice_start
            local slice_ms = (os.clock() - slice_start) * 1000
            local pause_start = os.clock()
            dt.control.sleep(math.max(STAGE2_SLEEP_MIN_MS, math.min(STAGE2_SLEEP_MAX_MS, math.floor(slice_ms))))
            pause_s = pause_s + os.clock() - pause_start
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
                        show_status(string.format(
                            "analyzing %d / %d | bursts %s / %s%s%s%s",
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
                run_log.release()
                log("scoring: scorer exit " .. tostring(done_code))
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
            if file_exists(DONE_PATH) then run_log.release() end
        end

        -- Final drain: apply whatever is left, paced, with progress
        if not M.cancel_requested then
            pull_results(true)
            local total_lines = #pending
            n_skipped = math.max(0, n_primary - total_lines)
            local start_idx = pending_idx - 1
            local remaining = total_lines - start_idx
            if remaining > 0 then
                say(string.format(overlap and "Assisted Culling: Analysis done, applying ratings to the last %d images..."
                    or "Assisted Culling: Applying ratings to %d images...", remaining))
            end
            local started = os.time()
            local last_toast_pct = 0
            final_drain = true

            while pending_idx <= total_lines do
                if M.cancel_requested or (culling_job and not culling_job.valid) or file_exists(CANCEL_PATH) then
                    M.cancel_requested = true
                    break
                end

                local slice_from, ratings_before, writes_before = pending_idx, rating_writes, all_writes
                apply_slice()

                local bar_start = os.clock()
                local done = pending_idx - start_idx
                local pct = done / remaining
                if culling_job then
                    culling_job.percent = PROGRESS_ANALYSIS
                        + (1 - PROGRESS_ANALYSIS) * math.min(1.0, (pending_idx - 1) / total_lines)
                end
                local label_start = os.clock()
                bar_s = bar_s + label_start - bar_start
                show_status(string.format(
                    "applying ratings %d / %d (%d%%)%s", pending_idx - 1, total_lines,
                    math.floor(((pending_idx - 1) / total_lines) * 100), fmt_eta(os.time() - started, done, remaining)))
                local toast_start = os.clock()
                label_s = label_s + toast_start - label_start
                log(string.format("applying: results %d to %d of %d: %d rating writes, %d tag writes, panel line waited %.1fs",
                    slice_from, pending_idx - 1, total_lines, rating_writes - ratings_before,
                    all_writes - writes_before - (rating_writes - ratings_before), toast_start - label_start))
                local milestone = math.floor(((pending_idx - 1) / total_lines) * 4) * 25
                if milestone > last_toast_pct and milestone < 100 then
                    last_toast_pct = milestone
                    dt.print(string.format("Assisted Culling: Ratings %d%% applied", milestone))
                end
                toast_s = toast_s + os.clock() - toast_start
            end
            drain_s = os.time() - started
        end

        -- closed once: closing a job the bar's x already closed crashes darktable
        if culling_job and culling_job.valid then
            culling_job.percent = 1.0
            dt.control.sleep(50)
            culling_job.valid = false
        end

        show_status("")

        if M.cancel_requested then
            if applied_total > 0 and not verify then
                say(string.format("Assisted Culling: Cancelled. %d of %d images were already rated and keep their changes. Run again to finish, or use Clear Culling Marks to remove the tags%s.",
                    applied_total, #images,
                    next(previous_ratings) and " and Restore Previous Ratings to put the star ratings back" or ""))
                alerts.add(string.format("Cancelled: %d of %d images were rated; run again to finish.", applied_total, #images))
            else
                say(_("Assisted Culling: Cancelled. No images were changed."))
            end
        elseif done_code ~= 0 then
            local tail = read_log_tail()
            local to_check = scorer_failure("failed", tail)
            if #tail > 300 then tail = tail:sub(#tail - 299) end
            if tail ~= "" then
                notify_error(_("Assisted Culling: Failed. ") .. tail, to_check)
            else
                notify_error(string.format("Assisted Culling: The scorer stopped with exit code %s. Details are in assisted_culling.log in darktable's config folder.",
                    tostring(done_code or "?")))
            end
        elseif applied_total == 0 then
            local tail = read_log_tail()
            local to_check = tail ~= "" and scorer_failure("no ratings came back from the scorer", tail) or nil
            if #tail > 300 then tail = tail:sub(#tail - 299) end
            notify_error(_("Assisted Culling: No ratings came back from the scorer. ")
                .. (tail ~= "" and tail or _("Check the plugins folder in preferences → Lua options, and that darktable-assisted-culling/.venv has python/requirements.txt installed.")), to_check)
        elseif verify then
            local differ_ids, keeper_ids, keeper_details, n_differ_bursts, n_keeper_bursts = {}, {}, {}, 0, 0
            for _, burst in ipairs(verify_order) do
                if burst.differs then
                    n_differ_bursts = n_differ_bursts + 1
                    table.move(burst.ids, 1, #burst.ids, #differ_ids + 1, differ_ids)
                end
                if tag_on.keeper and burst.keepers > 0 and (burst.tagged == 0 or burst.tagged > burst.keepers) then
                    n_keeper_bursts = n_keeper_bursts + 1
                    table.move(burst.ids, 1, #burst.ids, #keeper_ids + 1, keeper_ids)
                    keeper_details[#keeper_details + 1] = string.format("%s: %d Keeper tags, a cull now gives %d",
                        burst.name, burst.tagged, burst.keepers)
                end
            end
            if #differ_details + #hand_ids + n_keeper_bursts == 0 then
                say(string.format("Assisted Culling: Verify only, nothing changed. All %d images match a cull now.", applied_total))
            else
                say(string.format("Assisted Culling: Verify only, nothing changed. %d of %d images would get other stars from a cull now, %d ratings were changed by hand, %d bursts have the wrong Keeper tags. See To check.",
                    #differ_details, applied_total, #hand_ids, n_keeper_bursts))
            end
            if #differ_details > 0 then
                alerts.add(string.format("%d images would get other stars from a cull now; Fix culls their %d bursts (%d images).",
                    #differ_details, n_differ_bursts, #differ_ids), differ_ids, "cull", differ_details)
            end
            if #hand_ids > 0 then
                alerts.add(string.format("You changed %d ratings since the last cull; a cull keeps or overwrites them by its settings.", #hand_ids),
                    hand_ids, nil, hand_details)
            end
            if n_keeper_bursts > 0 then
                alerts.add(string.format("%d bursts have no Keeper tag or more than a cull gives; Fix culls them (%d images).",
                    n_keeper_bursts, #keeper_ids), keeper_ids, "cull", keeper_details)
            end
            if failed_total > 0 then alerts.add(string.format("%d images couldn't be read (see log).", failed_total)) end
            if n_skipped > 0 then alerts.add(string.format("%d images unreadable (see log).", n_skipped)) end
            log(string.format("verify: %d of %d images differ from a cull now, %d changed by hand, %d bursts with wrong Keeper tags",
                #differ_details, applied_total, #hand_ids, n_keeper_bursts))
        else
            local msg = string.format("Assisted Culling: Done. %d keepers, %d not kept", stats.keepers, stats.others)
            if stats.rejected > 0 then msg = msg .. string.format(" (%d rejected)", stats.rejected) end
            for _, f in ipairs(FLAGS) do
                local n = stats.flagged[f.name]
                if n > 0 then msg = msg .. string.format(", %d %s", n, f.summary) end
            end
            if stats.guessed > 0 then msg = msg .. string.format(", %d with a guessed subject", stats.guessed) end
            if stats.subject_bias > 0 then
                msg = msg .. string.format(", %d scored by subject bias", stats.subject_bias)
            end
            msg = msg .. "."
            local left_out = {}
            if n_skipped > 0 then left_out[#left_out + 1] = n_skipped .. " unreadable" end
            if n_locked > 0 then left_out[#left_out + 1] = n_locked .. " locked" end
            if failed_total > 0 then left_out[#left_out + 1] = failed_total .. " failed to update" end
            if #left_out > 0 then msg = msg .. " Left out: " .. table.concat(left_out, "; ") .. " (see log)." end
            local notice = M.no_groups_notice(grouping_on, n_primary, n_groups_before_split)
            if notice then msg = msg .. " " .. notice:gsub("^%l", string.upper) .. "." end
            if detail_total > 0 then
                msg = msg .. string.format(" Ratings are ready. Now writing %d detail tags; the job bar's x stops them.", detail_total)
            end
            say(msg)
            if #guessed_ids > 0 then
                alerts.add(string.format("%s with a guessed subject: check them by hand.", C.count(#guessed_ids, "image")), guessed_ids)
            end
            if #close_ids > 0 then alerts.add(string.format("%s in close calls: check both frames.", C.count(#close_ids, "image")), close_ids) end
            if #no_vehicle_ids > 0 then
                alerts.add(string.format("%s left unrated (no vehicle found): rate them by hand.", C.count(#no_vehicle_ids, "image")), no_vehicle_ids)
            end
            if failed_total > 0 then alerts.add(string.format("%d images couldn't be updated (see log).", failed_total)) end
            if n_skipped > 0 then alerts.add(string.format("%d images unreadable (see log).", n_skipped)) end
            log(string.format("apply: timing: %.1fs in tag and rating writes, %.1fs paused, %.1fs in progress updates (job bar %.1fs, panel line %.1fs, toast %.1fs); %d rating writes, %d Keeper / Rejected tag writes; final drain took %ds",
                write_s, pause_s, bar_s + label_s + toast_s, bar_s, label_s, toast_s, rating_writes, all_writes - rating_writes, drain_s))
            if demote_plugin_stars then
                log(string.format("apply: %d non-keepers set to 0 (stars an earlier run wrote); others kept their rating", demoted))
            end
            -- Each tag write makes darktable rebuild its tagging lists (about 100ms). The panel
            -- line waits for darktable to catch up, then the pause leaves it as long again for the user.
            if detail_total > 0 then
                local detail_job = dt.gui.create_job(_("Assisted Culling: Writing detail tags"), true,
                    function(cancelled_job) cancelled_job.valid = false end)
                local detail_started, detail_idx, detail_written, detail_failed = os.time(), 1, 0, 0
                local detail_wait_s, detail_pause_s = 0, 0
                log(string.format("detail tags: started, %d tag writes on %d images", detail_total, #detail_queue))
                while detail_idx <= #detail_queue and detail_job.valid do
                    local detail = detail_queue[detail_idx]
                    -- guarded per image: one removed from the library since it was rated raises on a write
                    local ok_detail, detail_err = pcall(function()
                        for _, name in ipairs(detail.attach) do
                            tags.attach(tag_named(name), detail.img)
                            tag_tally["+" .. name] = (tag_tally["+" .. name] or 0) + 1
                            detail_written = detail_written + 1
                        end
                        for _, name in ipairs(detail.detach) do
                            tags.detach(tag_named(name), detail.img)
                            tag_tally["-" .. name] = (tag_tally["-" .. name] or 0) + 1
                            detail_written = detail_written + 1
                        end
                    end)
                    if not ok_detail then
                        detail_failed = detail_failed + 1
                        log(C.image_label(detail.img) .. ": detail tags failed: " .. tostring(detail_err))
                    end
                    detail_idx = detail_idx + 1
                    detail_job.percent = (detail_idx - 1) / #detail_queue
                    local wait_start = os.clock()
                    show_status(string.format("writing detail tags: image %d / %d%s", detail_idx - 1, #detail_queue,
                        fmt_eta(os.time() - detail_started, detail_idx - 1, #detail_queue)))
                    local waited_s = os.clock() - wait_start
                    local pause_ms = math.max(STAGE2_SLEEP_MIN_MS, math.min(STAGE2_SLEEP_MAX_MS, math.floor(waited_s * 1000)))
                    dt.control.sleep(pause_ms)
                    detail_wait_s, detail_pause_s = detail_wait_s + waited_s, detail_pause_s + pause_ms / 1000
                end
                local detail_left = #detail_queue - detail_idx + 1
                if detail_failed > 0 then
                    alerts.add(string.format("%d images couldn't get their detail tags (see log).", detail_failed))
                end
                if detail_job.valid then detail_job.valid = false end
                show_status("")
                log(string.format("apply: detail tags: %d of %d tag writes on %d of %d images in %ds (waited %.1fs for darktable, paused %.1fs)%s%s",
                    detail_written, detail_total, detail_idx - 1, #detail_queue, os.time() - detail_started, detail_wait_s, detail_pause_s,
                    detail_failed > 0 and (", " .. detail_failed .. " images couldn't be updated") or "",
                    detail_left > 0 and ", stopped at the job bar" or ""))
                if detail_left > 0 then
                    say(string.format("Assisted Culling: Detail tags stopped. %d images still miss theirs; ratings and Keeper / Rejected are complete. Cull the same images again to write the rest.",
                        detail_left))
                    local unreached = {}
                    for k = detail_idx, #detail_queue do
                        local ok_id, id = pcall(function() return detail_queue[k].img.id end)
                        if ok_id then unreached[#unreached + 1] = id end
                    end
                    alerts.add(string.format("Detail tags stopped: %d images still miss theirs; cull them again.", #unreached), unreached)
                else
                    say(string.format("Assisted Culling: Detail tags written (%d)%s.", detail_written,
                        detail_failed > 0 and (", " .. detail_failed .. " images couldn't be updated") or ""))
                end
            end
            local tag_lines = {}
            for name, count in pairs(tag_tally) do tag_lines[#tag_lines + 1] = { name = name, count = count } end
            table.sort(tag_lines, function(a, b) return a.count > b.count or (a.count == b.count and a.name < b.name) end)
            for index, tag_line in ipairs(tag_lines) do tag_lines[index] = tag_line.count .. " " .. tag_line.name end
            log("apply: tag writes by tag (+ attached, - detached): " .. (#tag_lines > 0 and table.concat(tag_lines, ", ") or "none"))
            if first_error then
                dt.print_error("Assisted Culling: First apply error: " .. first_error)
                log("first apply error: " .. first_error)
            end
        end
    end)

    is_running = false
    if action_button then
        action_button.label = _("Cull Selection")
    end
    show_status("")

    if not success then
        if culling_job then pcall(function() if culling_job.valid then culling_job.valid = false end end) end
        notify_error(_("Assisted Culling: Couldn't run. ") .. tostring(run_err))
    end
    if not run_started then
        run_next()
        return
    end

    -- merged into the earlier runs' records; a run that changed no rating leaves the file in place
    if next(previous_ratings) then
        for id, record in pairs(previous_ratings) do saved_ratings[id] = record end
        local saved, save_err = pcall(function()
            local lines = {}
            for id, record in pairs(saved_ratings) do
                lines[#lines + 1] = string.format("%d,%d,%d,%s", id, record.previous, record.written, record.path)
            end
            table.sort(lines)
            local f = assert(io.open(PREVIOUS_RATINGS_PATH, "wb"))
            f:write(table.concat(lines, "\n"), "\n")
            f:close()
        end)
        if not saved then
            notify_error(_("Assisted Culling: Couldn't save the previous ratings, so this run can't be undone: ")
                .. tostring(save_err))
        end
    end

    -- A cancelled scorer that is still running keeps its cancel flag and launcher,
    -- so it can still see the flag and finish. The next run uses other file names.
    local scorer_alive = M.cancel_requested
        and (stage_a_alive or (main_started and not file_exists(DONE_PATH)))
    pcall(os.remove, MANIFEST_PATH)
    pcall(os.remove, RESULTS_PATH)
    pcall(os.remove, RESULTS_PATH .. ".tmp")
    pcall(os.remove, RESULTS_PATH .. ".all")
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
    log(string.format("run finished, %ds in total", os.time() - run_began))
    if scorer_alive then flush_log() else run_log.release() end
    run_next()
end

-- Removes the plugin's tags. Ratings are NOT reverted.
function M.clear_marks(images)
    if not images or #images == 0 then
        dt.print(_("Assisted Culling: Select some images first."))
        return
    end
    dt.print(string.format("Assisted Culling: Clearing marks on %s…", #images == 1 and "1 image" or #images .. " images"))
    local found, saw_tag = {}, false
    for _, name in ipairs(ALL_TAGS) do
        local t = tags.find(name)
        if t then table.insert(found, { tag = t, name = name }) end
    end
    for i = 1, #tags do
        if M.is_diag_tag(tags[i].name) then saw_tag = true; break end
    end
    if #found == 0 and not saw_tag then
        dt.print("Assisted Culling: Nothing to clear; no Assisted Culling tags exist yet.")
        return
    end

    alerts.begin("Clear")
    local total, cleared, failed, writes = #images, 0, 0, 0
    local write_s, wait_s, pause_s = 0, 0, 0
    local diag_tags = {}
    local job = dt.gui.create_job(_("Assisted Culling: Clear culling marks"), true,
        function(cancelled_job) cancelled_job.valid = false end)
    local started = os.time()
    local i = 1
    -- Each tag write makes darktable rebuild its tagging lists (about 100ms). An image with
    -- writes ends its slice; the panel line waits for darktable to catch up, then the pause
    -- leaves it as long again, so the backlog can't grow over thousands of images.
    local ok, err = pcall(function()
        while i <= total and job.valid do
            local budget = STAGE2_WRITE_BUDGET
            local slice_start = os.clock()
            while i <= total and budget > 0 do
                local img = images[i]
                local ok_one, res = pcall(function()
                    local have = tags_of(img)
                    local img_writes = 0
                    for _, ft in ipairs(found) do
                        if have[ft.name] then tags.detach(ft.tag, img); img_writes = img_writes + 1 end
                    end
                    local _, detach = M.diag_tag_changes(have, "")
                    for _, name in ipairs(detach) do
                        diag_tags[name] = diag_tags[name] or tags.find(name)
                        tags.detach(diag_tags[name], img); img_writes = img_writes + 1
                    end
                    return img_writes
                end)
                if not ok_one then
                    failed = failed + 1
                    budget = budget - 1
                    log(C.image_label(img) .. ": clearing marks failed: " .. tostring(res))
                elseif res > 0 then
                    cleared, writes, budget = cleared + 1, writes + res, 0
                else
                    budget = budget - 1
                end
                i = i + 1
            end
            write_s = write_s + os.clock() - slice_start
            job.percent = (i - 1) / total
            local wait_start = os.clock()
            show_status(string.format("clearing marks %d / %d%s", i - 1, total, fmt_eta(os.time() - started, i - 1, total)))
            local waited_s = os.clock() - wait_start
            local pause_ms = math.max(STAGE2_SLEEP_MIN_MS, math.min(STAGE2_SLEEP_MAX_MS, math.floor(waited_s * 1000)))
            dt.control.sleep(pause_ms)
            wait_s, pause_s = wait_s + waited_s, pause_s + pause_ms / 1000
        end
    end)
    local cancelled = ok and i <= total
    pcall(function() if job.valid then job.valid = false end end)
    show_status("")
    if not ok then notify_error("Assisted Culling: Clearing marks failed: " .. tostring(err)); return end
    log(string.format("clear: timing: %d of %d images in %ds; %.1fs in tag writes, %.1fs waiting for darktable, %.1fs paused; %d tag writes%s",
        i - 1, total, os.time() - started, write_s, wait_s, pause_s, writes, cancelled and ", stopped at the job bar" or ""))
    local counts = failed > 0 and (", " .. failed .. " couldn't be updated") or ""
    if cancelled then
        say(string.format("Assisted Culling: Clear cancelled. Removed culling tags from %d of %d images%s; %d not reached keep their tags.",
            cleared, total, counts, total - i + 1))
        local unreached = {}
        for k = i, total do
            local ok_id, id = pcall(function() return images[k].id end)
            if ok_id then unreached[#unreached + 1] = id end
        end
        alerts.add(string.format("Clear cancelled: %d images not reached keep their tags.", #unreached), unreached)
    else
        say(string.format("Assisted Culling: Removed culling tags from %d of %d images%s. Star ratings were not changed.",
            cleared, total, counts))
    end
    if failed > 0 then alerts.add(string.format("%d images couldn't be cleared (see log).", failed)) end
    flush_log()
end

-- Sets each image back to the rating it had before the first run that changed it
-- (PREVIOUS_RATINGS_PATH). An image whose rating is no longer what the last run wrote was rated
-- since and is left alone. Tags are not changed.
function M.restore_ratings(images)
    if not images or #images == 0 then
        dt.print(_("Assisted Culling: Select some images first."))
        return
    end
    local record_of = read_saved_ratings()
    if not next(record_of) then
        dt.print(_("Assisted Culling: No run has changed a rating yet, so there is nothing to restore."))
        return
    end

    alerts.begin("Restore ratings")
    local total, restored, rated_since, failed = #images, 0, 0, 0
    local i = 1
    local ok, err = pcall(function()
        while i <= total do
            local budget = STAGE2_WRITE_BUDGET
            local slice_start = os.clock()
            while i <= total and budget > 0 do
                local img = images[i]
                -- guarded per image: one removed from the library since the click raises on any read
                if not pcall(function()
                    local record = record_of[img.id]
                    if record and record.path == (img.path .. "/" .. img.filename):gsub("[\r\n]", " ") then
                        if img.rating ~= record.written then
                            rated_since = rated_since + 1
                        else
                            img.rating = record.previous
                            restored = restored + 1
                        end
                    end
                end) then
                    failed = failed + 1
                end
                budget = budget - 1
                i = i + 1
            end
            show_status(string.format("restoring ratings %d / %d", i - 1, total))
            dt.control.sleep(math.max(STAGE2_SLEEP_MIN_MS,
                math.min(STAGE2_SLEEP_MAX_MS, math.floor((os.clock() - slice_start) * 1000))))
        end
    end)
    show_status("")
    if not ok then notify_error("Assisted Culling: Restoring ratings failed: " .. tostring(err)); return end
    dt.print(string.format("Assisted Culling: Restored the previous rating of %d of %d images%s%s. Tags were not changed.",
        restored, total, rated_since > 0 and (", " .. rated_since .. " rated since the run left alone") or "",
        failed > 0 and (", " .. failed .. " couldn't be updated") or ""))
    if failed > 0 then alerts.add(string.format("%d images couldn't be restored.", failed)) end
end

-- Sets each image to 0 stars, a few per slice, with a job bar whose x stops it between slices.
-- A rejected image is set to 0 stars too. Tags are not changed. The job is closed once: by its x,
-- or here at the end; closing a closed job crashes darktable.
function M.reset_ratings(images)
    if not images or #images == 0 then
        dt.print(_("Assisted Culling: Select some images first."))
        return
    end
    alerts.begin("Reset ratings")
    local total, reset, already, failed = #images, 0, 0, 0
    local job = dt.gui.create_job(_("Assisted Culling: Reset ratings to 0"), true,
        function(cancelled_job) cancelled_job.valid = false end)
    local started = os.time()
    local i = 1
    local ok, err = pcall(function()
        while i <= total and job.valid do
            local budget = STAGE2_WRITE_BUDGET
            local slice_start = os.clock()
            while i <= total and budget > 0 do
                local img = images[i]
                -- guarded per image: one removed from the library since the click raises on any read
                local ok_one, wrote = pcall(function()
                    if img.rating == 0 then return false end
                    img.rating = 0
                    return true
                end)
                if not ok_one then
                    failed = failed + 1
                    log(C.image_label(img) .. ": resetting the rating failed: " .. tostring(wrote))
                elseif wrote then
                    reset = reset + 1
                    budget = budget - 1
                else
                    already = already + 1
                end
                i = i + 1
            end
            job.percent = (i - 1) / total
            show_status(string.format("resetting ratings %d / %d%s", i - 1, total, fmt_eta(os.time() - started, i - 1, total)))
            dt.control.sleep(math.max(STAGE2_SLEEP_MIN_MS,
                math.min(STAGE2_SLEEP_MAX_MS, math.floor((os.clock() - slice_start) * 1000))))
        end
    end)
    local cancelled = ok and i <= total
    pcall(function() if job.valid then job.valid = false end end)
    show_status("")
    if not ok then notify_error("Assisted Culling: Resetting ratings failed: " .. tostring(err)); return end
    local counts = string.format("%s%s", already > 0 and (", " .. already .. " already at 0") or "",
        failed > 0 and (", " .. failed .. " couldn't be updated") or "")
    log(string.format("reset ratings: %d images, %ds", total, os.time() - started))
    if cancelled then
        say(string.format("Assisted Culling: Reset cancelled. %d of %d images were set to 0 stars%s; %d not reached keep their rating.",
            reset, total, counts, total - i + 1))
        local unreached = {}
        for k = i, total do
            local ok_id, id = pcall(function() return images[k].id end)
            if ok_id then unreached[#unreached + 1] = id end
        end
        alerts.add(string.format("Reset cancelled: %d images not reached keep their rating.", #unreached), unreached)
    else
        say(string.format("Assisted Culling: Set %d of %d images to 0 stars%s. Tags were not changed.", reset, total, counts))
    end
    if failed > 0 then alerts.add(string.format("%d images couldn't be reset (see log).", failed)) end
    flush_log()
end

local preset_file_store, make_preset_controls = C.preset_file_store, C.make_preset_controls


-- Panel -----------------------------------------------------------------------

-- The panel's settings; set by install_panel. Read when a job is clicked, so a queued job keeps them.
local read_panel

-- dt.gui.action_images follows the live selection; a queued job needs the selection as it was.
local function copy_images(images)
    local out = {}
    for _, img in ipairs(images) do out[#out + 1] = img end
    return out
end

local function launch_score(images, s, verify)
    is_running = true
    M.cancel_requested = false
    settings = s
    if action_button then action_button.label = _("Cancel Culling") end
    M.score_images(images, s.rank_mode, s.sharp_mode, s.exp_mode, s.keep_mode, s.non_keeper, verify)
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

-- images: the photos to cull, the lighttable's action images when nil. verify: score without writing.
local function start_culling(allow_cancel, images, verify)
    if is_clearing then
        dt.print(_("Assisted Culling: Busy clearing marks, try again in a moment."))
        return
    end
    if is_running then
        if allow_cancel then
            M.cancel_requested = true
            local cf = io.open(CANCEL_PATH, "w")
            if cf then cf:write("1"); cf:close() end
            clear_queue() -- a cancel means "stop what I started", not "run the rest"
            if action_button then action_button.label = _("Cancelling...") end
            dt.print(_("Assisted Culling: Cancelling, finishing the current step..."))
        else
            local queued, s = copy_images(images or dt.gui.action_images), read_panel()
            if not queue_if_busy(verify and _("Verify") or _("Culling"), #queued > 0, function() launch_score(queued, s, verify) end) then
                dt.print(_("Assisted Culling: Already running. Click Cancel Culling in the panel to stop it."))
            end
        end
        return
    end
    launch_score(images or dt.gui.action_images, read_panel(), verify)
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
        local c = new_widget("combobox") {
            label = label,
            tooltip = tooltip,
            changed_callback = on_choice(key),
            table.unpack(labels),
        }
        c.selected = index_of(M.CHOICES[key], shown[key])
        combos[key] = c
        return c
    end

    local genre_combo = choice_combo("genre", _("Genre"),
        _("Fills in ranking mode, sharpness, exposure and keepers for a photography genre. Changing any of those four switches this to custom."),
        { _("landscape"), _("portrait"), _("sport"), _("macro"), _("custom") })

    local rank_combo = choice_combo("rank_mode", _("Ranking Mode"),
        _("universal: keepers get stars from fixed sharpness tiers.\nbinary: keepers get top stars; only flags lower them.\nrelative: tiers scale to this selection, so its sharpest frames get 5 stars.\nIn every mode, the rest follow the non-keepers setting."),
        { _("universal absolute"), _("binary (keepers top)"), _("relative to selection") })

    local sharp_combo = choice_combo("sharp_mode", _("Sharpness"),
        _("How sharpness is measured.\ncenter crop: the middle half of the frame only.\nedge-to-edge: scores the softest areas of the frame (ignoring plain sky), so a soft corner costs a frame.\nabsolute peak 1%: the sharpest 1% of edges anywhere in the frame, for a small sharp subject (macro).\nface & eyes: falls back to subject bias when no face is found; tags a frame Eyes Closed (one star lower) when a clear face shows no open eyes.\nsubject bias: a 3×3 grid weighted toward the centre, for a subject roughly mid-frame.\nsubject tracking (SAM): outlines the subject with darktable's AI mask model before scoring; slower than the rest, since each burst's top few frames go through the model.\nmotorsport: finds the car, scores it at full resolution so overcast light isn't punished, and reads each frame's motion. Good pans score higher (Panning), a whole frame blurred in one straight line is kept with its burst (Motion Blur), a car blurred across the pan scores lower (Missed Pan), streaks running out from the frame centre read as Zoom Burst."),
        { _("center crop"), _("edge-to-edge uniformity"), _("absolute peak 1%"), _("face & eyes (OpenCV)"), _("subject bias (center-weighted)"), _("subject tracking (SAM)"), _("motorsport (subject & motion)") })

    local exp_combo = choice_combo("exp_mode", _("Exposure"),
        _("Flags clipped highlights or shadows (Overexposed / Underexposed tag, one star lower; the penalty can be turned off on the penalties & speed page).\nwhole frame: flags a frame with over 2% of it clipped.\nsubject only: the same, ignoring the top fifth of the frame (sky).\nstrict histogram: flags from 1% of the frame at or near clipping.\nignore exposure: no exposure flags."),
        { _("whole frame"), _("subject only (ignore sky)"), _("strict histogram"), _("ignore exposure") })

    local keep_combo = choice_combo("keep_mode", _("Keepers"),
        _("How many of each burst are kept (the sharpest ones).\nsingle best: 1.\nportrait: 1 in a burst of up to 3 frames, else 2.\ndynamic: 1 in a burst of up to 4 frames, 2 up to 8, 3 up to 12, 4 up to 18, else 5.\nkeep all: every frame (focus stacks)."),
        { _("single best only"), _("portrait (1 or 2)"), _("dynamic (1 to 5)"), _("keep all (focus stack)") })

    local keep_margin_combo = choice_combo("keep_margin", _("Keeper Margin"),
        _("Also keeps every frame scoring within this share of its burst's sharpest frame, on top of the keepers count. 90% keeps any frame at least 90% as sharp as the best."),
        { _("off"), _("within 95% of best"), _("within 90% of best"), _("within 85% of best"), _("within 80% of best"), _("within 75% of best") })

    local non_keeper_combo = choice_combo("non_keeper", _("Non-Keepers"),
        _("The rating of frames that are not kept.\nleave alone: keeps their rating and writes only the tags.\nreject bad frames: rejects only the far-behind frames and leaves the rest alone, except stars an earlier run wrote, which go to 0.\n0 to 5 stars: that rating.\ngraded: stars below the burst's lowest keeper by how close each frame is to the burst's best: 90%+ one star less, 75%+ two, 60%+ three, 45%+ four, else 0.\nWhatever is picked, a frame under 30% of its burst's best (times star strictness) is far behind and rejected (-1, Rejected tag), up to rejects per burst: with the best at 400, a frame at 100 is far behind."),
        { _("leave alone"), _("reject bad frames (-1)"), _("0 stars"), _("1 star"), _("2 stars"), _("3 stars"), _("4 stars"), _("5 stars"), _("graded by burst") })

    local reject_cap_combo = choice_combo("reject_cap", _("Rejects per Burst"),
        _("The most far-behind frames rejected in one burst, worst first. The others far behind get the non-keepers rating. Blank frames are always rejected."),
        { _("no limit"), _("1"), _("2"), _("3"), _("5") })

    local star_scale_combo = choice_combo("star_scale", _("Star Strictness"),
        _("Scales the sharpness every star needs, in universal and relative ranking, how fast graded non-keepers lose stars, and the far-behind line (30% of the burst's best). Stricter: fewer stars for the same frame. More generous: more stars. The scores themselves don't change. With Rate Keepers Against Each Other on, keepers in a universal run of 10 or more take their stars from that instead; this still sets how fast graded non-keepers lose stars."),
        { _("much more generous (×0.5)"), _("more generous (×0.75)"), _("standard (×1)"), _("stricter (×1.25)"), _("much stricter (×1.5)"), _("strictest (×2)") })

    local first_picks_combo = choice_combo("first_picks", _("First Picks"),
        _("For a quick delivery: rates only this many of the run's best keepers, at most one per burst (the burst's best keeper, most stars first, then sharpness). Every other frame keeps its rating and gets Why|Not a first pick; nothing is rejected. Run a normal cull later for the full set.\nDefault: off."),
        { _("off"), _("10"), _("15"), _("20"), _("30") })

    action_button = new_widget("button") {
        label = _("Cull Selection"),
        tooltip = _("Score the selected images in bursts and rate/tag them. Click again to cancel."),
    }

    action_button.clicked_callback = C.guarded_callback(guard, "button action", function()
        changed()
        start_culling(true)
    end)

    local verify_button = new_widget("button") {
        label = _("Verify Selection"),
        tooltip = _("Score the selected images as Cull Selection would and change nothing. To check lists the images whose stars a cull would change, ratings you changed by hand since the last cull, and bursts whose Keeper tags don't match; Fix culls those bursts. Scores come from the cache, so a repeat is quick."),
    }
    verify_button.clicked_callback = C.guarded_callback(guard, "button verify", function()
        changed()
        start_culling(false, nil, true)
    end)
    fixes.cull = function(images) start_culling(false, images, false) end

    local group_tag_entries = {}
    for n in ipairs(GROUP_TAG_KEYS) do
        group_tag_entries[n] = new_widget("entry") {
            placeholder = string.format(_("tag node %d (blank = not used)"), n),
            tooltip = _("A tag node whose children section the images, e.g. Rally|2026 (car numbers from Assisted Tagging) or Assisted Grouping|2026-01-01 12:00:00|Group. Each filled node cuts the groups further, in order: images with different children go to separate pools, each with its own keepers, and images without the tag stay together in their group. With native groups off, the first filled node forms the groups and images without its tag are judged alone. Type Assisted Grouping to use each image's own latest Assisted Grouping run.\nDefault: blank (not used)."),
            text = "",
        }
    end

    -- Check buttons by schema key, in panel order.
    local checks, check_order = {}, {}
    local function check(key, label, tooltip)
        local c = new_widget("check_button") {
            label = label,
            tooltip = tooltip,
            value = shown[key],
            clicked_callback = changed,
        }
        checks[key] = c
        check_order[#check_order + 1] = key
        return c
    end

    local group_widgets = {
        check("group_native", _("Cull by Native Groups"),
            _("On: darktable's image groups are the groups keepers are picked within. Off: the first filled tag node below forms the groups; with none filled, every image is judged alone.\nDefault: on. Turn off after an Assisted Grouping run you have not applied as darktable groups, and type Assisted Grouping in tag node 1.")),
        new_widget("section_label") { label = _("Extra Grouping by Tags") },
    }
    for n, entry in ipairs(group_tag_entries) do
        group_widgets[#group_widgets + 1] = new_widget("label") { label = string.format(_("tag node %d"), n), halign = "start" }
        group_widgets[#group_widgets + 1] = entry
    end

    local run_tag_check = check("run_tag", _("Tag Each Run"),
        _("Add a timestamp tag (Assisted Culling|Run|YYYY-MM-DD HH:MM) to every image a run writes, so the latest run's images can be filtered apart from earlier ones. Stamps accumulate; remove old ones in darktable's tag manager. Clear Culling Marks leaves them.\nDefault: off. Turn on when re-running a shoot and you want to review only what changed."))

    local option_checks = {
        new_widget("section_label") { label = _("Speed") },
        check("apply_while_scoring", _("Apply Ratings While Scoring"),
            _("Faster overall on big batches, but darktable's UI shares the CPU with the scorer; turn off if the UI lags. No effect with first picks on: ratings wait until the picks are chosen.\nDefault: off. Turn on for batches of several hundred frames.")),
        check("fast_jpeg_decode", _("Fast JPEG Decoding"),
            _("Decodes JPEGs and RAW previews at reduced size, several times faster. Sharpness scores shift slightly, but keepers are ranked within each burst, so picks rarely change.\nDefault: on. Turn off when frames are close in sharpness and you want full-size scores.")),
    }
    option_checks[#option_checks + 1] = new_widget("section_label") { label = _("Penalties (Each Lowers Stars by One)") }
    for _i, f in ipairs(FLAGS) do
        if not f.rejects then
            local label = f.tag:match("|(.+)$")
            option_checks[#option_checks + 1] = check("penalise_" .. f.name, string.format(_("%s Lowers Stars"), label),
                string.format(_("On: %s images get one star less. Off: they're still tagged %s (if it's on under tags written) but keep their rating.\nDefault: on. Turn off when the flag is the look you want, e.g. low-key or high-key for the exposure flags."), label, label))
        end
    end
    option_checks[#option_checks + 1] = new_widget("section_label") { label = _("Blank Frames and Vehicles") }
    option_checks[#option_checks + 1] = choice_combo("blank_share", _("Blank Frames"),
        _("Rejects a frame when at least this share of it is one flat colour (lens cap, black barrier, blown sky, fog), and tags it Blank and Why|Blank. It is never a keeper, even when the whole burst is blank. A dark frame with lit headlights is not blank.\nDefault: 95%. Pick off to rate blank frames like any other."),
        { _("off"), _("99% one colour"), _("97% one colour"), _("95% one colour"), _("90% one colour") })
    option_checks[#option_checks + 1] = check("no_vehicle_leave", _("Leave Frames with No Vehicle"),
        _("Motorsport and subject tracking (SAM) sharpness only, when the vehicle detector is installed. A frame where it finds no car is never a keeper, keeps its rating and gets Why|No vehicle, instead of being scored on the centre of the frame. A burst with no car in any frame is left alone.\nDefault: off. Turn on for car shoots once you've checked a run's No vehicle frames really are empty."))
    option_checks[#option_checks + 1] = check("car_boxes_only", _("Only Car Boxes (From Tagging)"),
        _("Motorsport and subject tracking (SAM) sharpness only, when the vehicle detector is installed. Once Assisted Tagging has run on these images with its car check, sharpness is judged only on the boxes it kept as cars, so a marshal, shed or railing box is never the subject. A frame whose boxes it all dropped counts as no vehicle. Images tagging hasn't run on, or that changed since, use every detector box.\nDefault: on. Turn off to judge every detector box."))

    local tag_checks = {}
    local kind_labels, last_kind = {}, nil
    for _i, k in ipairs(M.TAG_KINDS) do kind_labels[k.kind] = k.label end
    for _i, t in ipairs(M.tag_rows_in_order()) do
        if t.kind ~= last_kind then
            tag_checks[#tag_checks + 1] = new_widget("section_label") { label = _(kind_labels[t.kind]) }
            last_kind = t.kind
        end
        tag_checks[#tag_checks + 1] = check("tag_" .. t.key, t.label,
            string.format(_("Writes: %s\nWhen: %s\nOff: stops writing it and removes it from images on the next run. Ratings and keeper picks are unchanged."),
                "Assisted Culling|" .. table.concat(t.writes, ", Assisted Culling|"), _(t.when)))
    end

    read_panel = function()
        local s = {}
        for key in pairs(combos) do s[key] = M.CHOICES[key][combos[key].selected] or shown[key] end
        for _, key in ipairs(check_order) do s[key] = checks[key].value and true or false end
        for n, key in ipairs(GROUP_TAG_KEYS) do s[key] = (group_tag_entries[n].text or ""):match("^%s*(.-)%s*$") end
        return s
    end

    local function show_panel(s)
        for k, v in pairs(s) do shown[k] = v end
        for key in pairs(combos) do show_choice(key, s[key]) end
        for _, key in ipairs(check_order) do checks[key].value = s[key] end
        for n, key in ipairs(GROUP_TAG_KEYS) do group_tag_entries[n].text = s[key] end
    end

    clear_button = new_widget("button") {
        label = _("Clear Culling Marks"),
        tooltip = _("Remove the Assisted Culling tags from the selected images, with progress in the panel and a job bar you can cancel. Star ratings and colour labels are not changed."),
    }

    clear_button.clicked_callback = C.guarded_callback(guard, "button clear", function()
        local selected = copy_images(dt.gui.action_images)
        if queue_if_busy(_("Clear Culling Marks"), #selected > 0, function()
            is_clearing = true
            local ok_q, err_q = pcall(M.clear_marks, selected)
            is_clearing = false
            if not ok_q then notify_error("Assisted Culling: Clearing marks failed: " .. tostring(err_q)) end
            run_next()
        end) then return end
        if is_running or is_clearing then
            dt.print(_("Assisted Culling: Busy with another job, try again when it finishes."))
            return
        end
        is_clearing = true
        local ok_c, err_c = pcall(M.clear_marks, dt.gui.action_images)
        is_clearing = false
        if not ok_c then notify_error("Assisted Culling: Clearing marks failed: " .. tostring(err_c)) end
    end)

    local restore_button = new_widget("button") {
        label = _("Restore Previous Ratings"),
        tooltip = _("Set the selected images back to the star rating they had before the last run that changed a rating. An image you rated since that run is left alone. Tags are not changed; use Clear Culling Marks for those."),
    }

    restore_button.clicked_callback = C.guarded_callback(guard, "button restore", function()
        local selected = copy_images(dt.gui.action_images)
        if queue_if_busy(_("Restore Previous Ratings"), #selected > 0, function()
            is_clearing = true
            local ok_q, err_q = pcall(M.restore_ratings, selected)
            is_clearing = false
            if not ok_q then notify_error("Assisted Culling: Restoring ratings failed: " .. tostring(err_q)) end
            run_next()
        end) then return end
        if is_running or is_clearing then
            dt.print(_("Assisted Culling: Busy with another job, try again when it finishes."))
            return
        end
        is_clearing = true
        local ok_r, err_r = pcall(M.restore_ratings, selected)
        is_clearing = false
        if not ok_r then notify_error("Assisted Culling: Restoring ratings failed: " .. tostring(err_r)) end
    end)

    local reset_button = new_widget("button") {
        label = _("Reset Ratings to 0"),
        tooltip = _("Set the selected images to 0 stars, a few at a time, with progress in the panel and a job bar you can cancel. A rejected image is set to 0 stars too. Tags are not changed."),
    }

    reset_button.clicked_callback = C.guarded_callback(guard, "button reset", function()
        local selected = copy_images(dt.gui.action_images)
        if queue_if_busy(_("Reset Ratings to 0"), #selected > 0, function()
            is_clearing = true
            local ok_q, err_q = pcall(M.reset_ratings, selected)
            is_clearing = false
            if not ok_q then notify_error("Assisted Culling: Resetting ratings failed: " .. tostring(err_q)) end
            run_next()
        end) then return end
        if is_running or is_clearing then
            dt.print(_("Assisted Culling: Busy with another job, try again when it finishes."))
            return
        end
        is_clearing = true
        local ok_r, err_r = pcall(M.reset_ratings, selected)
        is_clearing = false
        if not ok_r then notify_error("Assisted Culling: Resetting ratings failed: " .. tostring(err_r)) end
    end)

    local why_button = new_widget("button") {
        label = _("Why These Ratings?"),
        tooltip = _("Explain the selected images from the last run's report: stars, rank in the burst, flags. Changes nothing."),
    }

    why_button.clicked_callback = C.guarded_callback(guard, "button why", function()
        local text = read_file(REPORT_PATH)
        if not text then
            dt.print(_("Assisted Culling: No report yet. Run culling first."))
            return
        end
        local wanted, n = {}, 0
        for _, img in ipairs(dt.gui.action_images) do
            local path = img.path .. "/" .. img.filename
            if not wanted[path] then wanted[path] = true; n = n + 1 end
        end
        if n == 0 then
            dt.print(_("Assisted Culling: Select some images first."))
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
    end)

    local report_button = new_widget("button") {
        label = _("Open Last Report"),
        tooltip = _("Open last-run.csv (every frame's rank, score, stars and why) in your spreadsheet app. The newest 20 runs are kept in assisted_culling/reports in darktable's config folder."),
    }

    report_button.clicked_callback = C.guarded_callback(guard, "button report", function()
        if not file_exists(REPORT_PATH) then
            dt.print(_("Assisted Culling: No report yet. Run culling first."))
            return
        end
        if IS_WINDOWS then
            os.execute(string.format('start "" "%s"', REPORT_PATH:gsub("/", "\\")))
        elseif dt.configuration.running_os == "macos" then
            os.execute("open " .. shell_quote(REPORT_PATH))
        else
            os.execute("xdg-open " .. shell_quote(REPORT_PATH) .. " >/dev/null 2>&1 &")
        end
    end)

    local store = preset_file_store(dt.configuration.config_dir .. "/assisted_culling/presets")
    local raw_read = store.read
    store.read = function(name)
        local text = raw_read(name)
        if not text then return text end
        local upgraded, copied = M.upgrade_preset_text(text)
        -- saved back, so the upgrade (and its log line) happens once
        if copied then
            if store.write(name, upgraded) then
                log("preset " .. name .. ": " .. table.concat(copied, ", ") .. " filled from the old preset's settings")
            else
                log("preset " .. name .. ": couldn't save the upgraded preset to " .. store.path(name))
            end
            if not is_running then flush_log() end
        end
        return upgraded
    end

    ctl = make_preset_controls({
        prefix = "Assisted Culling",
        plugin = "assisted_culling",
        plugin_folder = plugin_folder_pref,
        schema = M.PRESET_SCHEMA,
        store = store,
        read_panel = read_panel,
        show = show_panel,
        remember = function(name) dt.preferences.write("assisted_culling", "preset", "string", name) end,
        initial = dt.preferences.read("assisted_culling", "preset", "string"),
        -- a scorer may be appending to the log; its lines wait in the buffer until the run ends
        log = function(msg) log(msg); if not is_running then flush_log() end end,
        allow_store_new = true,
    })

    local page_widgets = {
        { new_widget("section_label") { label = _("How Frames Are Scored") },
          genre_combo, rank_combo, sharp_combo, exp_combo,
          new_widget("section_label") { label = _("Keepers per Burst") },
          keep_combo, keep_margin_combo,
          check("spread_keepers", _("Spread Keepers Over the Burst"),
              _("Cuts each burst into as many equal stretches of capture order as keepers allowed and keeps the sharpest frame of each, so a car through a corner keeps its entry and exit, not three near-copies of one moment. A stretch whose best frame scores under 95% of the burst's best keeps nothing; the next-sharpest frame overall is kept instead. A keeper picked this way over a sharper frame gets Why|Spread. Needs more than one keeper allowed.\nDefault: off. Unproven: compare a run with it on and off against your picks (eval_culling.py) before relying on it.")),
          check("keep_angles", _("Keep the Other Angles"),
              _("When a burst shows the car from more than one side (the detector's box changes shape by 1.3 times or more), also keeps the best frame of each other view that scores at least 70% of the burst's best, one star below the sharpest keeper. A frame with the car cut off by the frame edge never keeps while the burst has a frame showing the whole car. The frame kept this way gets Why|Other angle. Needs the detector (motorsport sharpness).\nDefault: on.")),
          check("motion_look", _("Keep a Motion-Blur Frame"),
              _("Also keeps the one frame per burst whose blur runs most nearly in a single straight line (straightness 0.75 or more) with the car in view and not cut off, on top of the sharp keepers and never in place of one. Blurred objects in front of the car do not rule it out. Rated by how straight the blur is: 3 stars from 0.75, 4 from 0.80, 5 from 0.85. The frame kept this way gets Why|Motion look. Needs the detector (motorsport sharpness).\nDefault: on.")),
          new_widget("section_label") { label = _("Close Calls (Best Frame That Lost Within 5% of the Last Keeper)") },
          check("number_reads", _("Break Close Calls on the Number Read"),
              _("In a close call (the last keeper and the best frame that lost score within 5%), keeps the frame where tagging read the car's number clearly: both frames must read the same number and the dropped one read it at least 0.10 more confidently. Reads come from tagging's last run on this collection (its boxes.json); frames changed since, or missing from it, keep the sharpness ranking. The frame kept this way gets Why|Number clearer.\nDefault: off. Unproven: compare a run with it on and off against your picks (eval_culling.py) before relying on it.")),
          check("sharp_judge", _("Break Close Calls with the Sharpness Judge"),
              _("In a close call that the number read left alone, scores the car crop of the burst's top frames (up to 3 within 5% of the best) with a learned image-quality model (HyperIQA) and keeps the frame it scores at least 5% clearer. Motorsport sharpness only. Needs hyperiqa_model.onnx and hyperiqa_model.onnx.data in the plugin's models folder (see the README); each judged frame is decoded again, so a run takes longer. The frame kept this way gets Why|Subject clearer.\nDefault: off. Unproven: compare a run with it on and off against your picks (eval_culling.py) before relying on it.")),
          new_widget("section_label") { label = _("Ratings") },
          non_keeper_combo, reject_cap_combo, star_scale_combo,
          check("star_slope", _("Rate Keepers Against Each Other"),
              _("Rates the run's keepers against each other instead of against fixed score steps: ranked by sharpness and cut into five equal groups, the sharpest group 5 stars, the next 4, down to 1. Changes stars only, never which frames are kept. Star strictness does not move these keepers' stars. Other angle keepers stay one star below their burst's best, Motion look keepers keep their own rating, and a flag still costs its stars. Runs with fewer than 10 keepers, and the relative and binary ranking, use the fixed steps.\nDefault: on.")),
          first_picks_combo },
        group_widgets,
        option_checks,
        tag_checks,
        { new_widget("section_label") { label = _("Cull (Writes Ratings and Tags)") },
          run_tag_check, action_button, verify_button },
        { new_widget("section_label") { label = _("Explain the Last Run (Changes Nothing)") },
          why_button, report_button,
          new_widget("section_label") { label = _("Undo") },
          clear_button, restore_button, reset_button },
    }
    local pages = {}
    for i, page in ipairs(M.PANEL_PAGES) do
        pages[i] = { number = page.number, title = _(page.title), widgets = page_widgets[i] }
    end

    status_label = new_widget("label") { label = "", halign = "start" }
    local panel_box = new_widget("box") {
        orientation = "vertical",
        -- shows the template defaults; nothing is saved
        reset_callback = function()
            show_panel(M.preset_defaults(M.PRESET_SCHEMA))
            changed()
        end,
        ctl.widget,
        C.paged_sections("assisted_culling", pages),
        alerts.widget,
        status_label,
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
            guard("shortcut cull", start_culling, false)
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
        guard("panel install", function()
            install_panel()
            restart()
        end)
    else
        if not M.event_registered then
            dt.register_event("assisted_culling", "view-changed", function(event, old_view, new_view)
                if new_view.name == "lighttable" or new_view.id == "lighttable" then
                    guard("panel install", function()
                        install_panel()
                        restart()
                    end)
                end
            end)
            M.event_registered = true
        end
    end
end

M.fmt_eta = fmt_eta
return M