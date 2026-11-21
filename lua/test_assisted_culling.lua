-- Run with: lua test_assisted_culling.lua
-- Exercises the darktable-independent half of assisted_culling.lua directly.

package.path = package.path .. ";./?.lua"
local C = require("assisted_culling")

local failures = 0
local function check(name, got, want)
    if got ~= want then
        failures = failures + 1
        print(string.format("FAIL %s: got %s, want %s", name, tostring(got), tostring(want)))
    else
        print(string.format("ok   %s", name))
    end
end

-- plugin_common.lua ---------------------------------------------------------------
-- The same file in all three plugin repos; COMMON_HASH pins it. After changing it, copy it to the
-- other two repos and put the hash this prints into their tests too.
local COMMON_HASH = "1a12cbf3"
local script_dir = (arg and arg[0] or ""):match("^(.*)[/\\]") or "."
local PC = dofile(script_dir .. "/plugin_common.lua")
local function fnv1a(text)
    local h = 2166136261
    for i = 1, #text do h = ((h ~ text:byte(i)) * 16777619) & 0xffffffff end
    return string.format("%08x", h)
end
local cf = assert(io.open(script_dir .. "/plugin_common.lua", "rb"))
local common_text = cf:read("a"):gsub("\r\n", "\n")
cf:close()
check("plugin_common.lua matches COMMON_HASH (copy it to the other repos after a change)", fnv1a(common_text), COMMON_HASH)
check("count: 0 is plural", PC.count(0, "image"), "0 images")
check("count: 1 is singular", PC.count(1, "image"), "1 image")
check("count: 2 is plural", PC.count(2, "image"), "2 images")
check("count: an irregular plural", PC.count(2, "entry", "entries"), "2 entries")
check("shell_quote: Windows escapes quotes, keeps %", PC.shell_quote('C:\\x %y% "z"', true), '"C:\\x %y% \\"z\\""')
check("shell_quote: POSIX escapes single quotes", PC.shell_quote("a'b", false), "'a'\\''b'")
check("parse_csv_line: quoted comma and doubled quote", PC.parse_csv_line('1,"a ""x"", b.jpg",3\r', 3)[2], 'a "x", b.jpg')
check("parse_csv_line: wrong field count is nil", PC.parse_csv_line("a,b", 3), nil)
check("lead_rank: full-size JPEG beats RAW", PC.lead_rank("x.JPG") > PC.lead_rank("x.nef"), true)
check("detections_path: <config_dir>/assisted_plugins/detections.sqlite, backslashes folded",
    PC.detections_path({ configuration = { config_dir = "C:\\Users\\me\\dt" } }), "C:/Users/me/dt/assisted_plugins/detections.sqlite")
check("detections_path: one value, so it can end an argument list",
    select("#", PC.detections_path({ configuration = { config_dir = "C:\\Users\\me\\dt" } })), 1)
do -- temp_base / sweep_temp: leftovers older than max_age go, newer ones and other prefixes stay
    local dir = os.tmpname()
    os.remove(dir)
    os.execute(PC.IS_WINDOWS and ('mkdir "' .. dir .. '"') or ("mkdir -p '" .. dir .. "'"))
    local function touch(name) local f = assert(io.open(dir .. "/" .. name, "w")); f:write("x"); f:close() end
    touch("dt_assisted_x_1000_1_old.csv"); touch("dt_assisted_x_5000_1_new.csv"); touch("dt_assisted_y_1000_1_other.csv")
    local base = PC.temp_base(dir, "dt_assisted_x_")
    check("temp_base: <dir>/<prefix><epoch>_<seq>_", base:match("^" .. dir:gsub("%p", "%%%0") .. "/dt_assisted_x_%d+_%d+_$") ~= nil, true)
    local removed = PC.sweep_temp(dir, "dt_assisted_x_", 86400, 1000 + 86401)
    check("sweep_temp: removes only this prefix's stale files", table.concat(removed, ","), "dt_assisted_x_1000_1_old.csv")
    check("sweep_temp: newer file kept", PC.file_exists(dir .. "/dt_assisted_x_5000_1_new.csv"), true)
    check("sweep_temp: other prefix kept", PC.file_exists(dir .. "/dt_assisted_y_1000_1_other.csv"), true)
    for _, n in ipairs(PC.list_dir(dir)) do os.remove(dir .. "/" .. n) end
    os.remove(dir)
end
do -- failure lines: the image is named, a failed call leaves its traceback
    check("image_label: id and filename", PC.image_label({ id = 12, filename = "IMG_0012.CR3" }), "image 12 (IMG_0012.CR3)")
    local gone = setmetatable({}, { __index = function() error("image removed") end })
    check("image_label: an image that raises on a read", PC.image_label(gone), "image no longer in the library")
    local logged = {}
    local function log_line(line) logged[#logged + 1] = line end
    local ok, err = PC.logged_call(log_line, "cull", function() error("boom") end)
    check("logged_call: a failure returns false and the error", ok == false and tostring(err):find("boom", 1, true) ~= nil, true)
    check("logged_call: the failure is logged once with a traceback",
        #logged == 1 and logged[1]:find("^cull failed: .*boom") ~= nil and logged[1]:find("stack traceback:", 1, true) ~= nil, true)
    local ok_fine, value = PC.logged_call(log_line, "cull", function() return 7 end)
    check("logged_call: a call that works logs nothing", ok_fine == true and value == 7 and #logged == 1, true)
end

do -- run_log: a line reaches the file as it is logged, waits only between hold and release
    local dir = os.tmpname()
    os.remove(dir)
    os.execute(PC.IS_WINDOWS and ('mkdir "' .. dir .. '"') or ("mkdir -p '" .. dir .. "'"))
    local path = dir .. "/plugin.log"
    local function lines() return ((PC.read_file(path) or ""):gsub("%d%d:%d%d:%d%d ", "")) end
    local run_log = PC.run_log(path)
    run_log.log("first")
    check("run_log: a line is in the file as soon as it is logged", lines(), "lua: first\n")
    run_log.hold()
    run_log.log("while the helper runs")
    check("run_log: a held line waits", lines(), "lua: first\n")
    run_log.flush()
    check("run_log: flush writes the waiting lines", lines(), "lua: first\nlua: while the helper runs\n")
    run_log.log("still held")
    check("run_log: flush does not end the hold", lines(), "lua: first\nlua: while the helper runs\n")
    run_log.release()
    run_log.append_lines("py: one\r\npy: two\n")
    check("run_log: release writes the rest, helper lines go in as they are",
        lines(), "lua: first\nlua: while the helper runs\nlua: still held\npy: one\npy: two\n")
    for run = 1, 7 do
        run_log.rotate(5)
        run_log.log("run " .. run)
    end
    check("run_log: rotate keeps the current log and 5 older ones", table.concat(PC.list_dir(dir), ","),
        "plugin.log,plugin.prev.log,plugin.prev2.log,plugin.prev3.log,plugin.prev4.log,plugin.prev5.log")
    check("run_log: the current log holds the newest run", lines(), "lua: run 7\n")
    check("run_log: .prev.log holds the run before", (PC.read_file(dir .. "/plugin.prev.log"):gsub("%d%d:%d%d:%d%d ", "")), "lua: run 6\n")
    check("run_log: .prev5.log holds the oldest kept run", (PC.read_file(dir .. "/plugin.prev5.log"):gsub("%d%d:%d%d:%d%d ", "")), "lua: run 2\n")
    for _, n in ipairs(PC.list_dir(dir)) do os.remove(dir .. "/" .. n) end
    os.remove(dir)
end
do -- paced_writer: a failed write is logged at once with the image and the operation
    local logged = {}
    local w = PC.paced_writer({ control = { sleep = function() end } }, 10, 0, function(msg) logged[#logged + 1] = msg end)
    w.write(function() end, 1, "image 7 (a.nef): attach tag")
    w.write(function() error("database is locked", 0) end, 1, "image 8 (b.nef): attach tag")
    check("paced_writer: only the failed write is logged", table.concat(logged, "|"), "image 8 (b.nef): attach tag failed: database is locked")
end

-- group keys ----------------------------------------------------------------
local G10 = "Assisted Grouping|2026-11-09 10:00:00|Group"
local G12 = "Assisted Grouping|2026-11-09 12:30:00|Group"
-- Half-regrouped selection: 1-2 only carry the 10:00 run, 3-4 the 12:30 run → two bursts, not all singles.
local lk, n_runs = C.latest_group_keys({
    { id = 1, tags = { [G10 .. "|0001"] = true } },
    { id = 2, tags = { [G10 .. "|0001"] = true } },
    { id = 3, tags = { [G10 .. "|0002"] = true, [G12 .. "|0001"] = true } },
    { id = 4, tags = { [G12 .. "|0001"] = true } },
})
local lng = C.number_groups({ 1, 2, 3, 4 }, lk)
check("latest_group_keys keeps each image's own run", table.concat({ lng[1], lng[2], lng[3], lng[4] }, ","), "1,1,2,2")
check("latest_group_keys counts runs", n_runs, 2)
check("group_tags_hint fires when native found nothing but tags exist",
    C.group_tags_hint(0, { { id = 1, tags = { [G12 .. "|0001"] = true } } }), C.GROUP_TAGS_HINT)
check("group_tags_hint silent when native groups exist", C.group_tags_hint(3, { { id = 1, tags = { [G12 .. "|0001"] = true } } }), nil)

local gk = C.tag_group_keys({
    { id = 1, tags = { [G12 .. "|0001"] = true, [G12 .. "|0001|x"] = true } },
    { id = 2, tags = { [G12 .. "|0002"] = true } },
}, G12)
check("tag_group_keys reads immediate children only", gk[1] .. "/" .. gk[2], "0001/0002")
local gk2, multi = C.tag_group_keys({
    { id = 3, tags = { [G12 .. "|0002"] = true, [G12 .. "|0001"] = true } },
}, G12)
check("tag_group_keys takes the first child by name", gk2[3], "0001")
check("tag_group_keys reports the image", multi[1], 3)
local gk3 = C.tag_group_keys({ { id = 4, tags = { [G10 .. "|0001"] = true } } }, G12)
check("tag_group_keys leaves unmatched images out", gk3[4], nil)

local nk = C.native_group_keys({ { id = 1, leader = 5 }, { id = 2, leader = 5 }, { id = 3 } })
check("native_group_keys maps leaders", nk[1] .. nk[2] .. tostring(nk[3]), "55nil")

local ng = C.number_groups({ 10, 11, 12, 13 }, { [10] = "a", [11] = "a", [13] = "b" })
check("number_groups shares and separates",
    table.concat({ ng[10], ng[11], ng[12], ng[13] }, ","), "1,1,2,3")
local ng2 = C.number_groups({ 7, 8, 9 }, {})
check("number_groups with no keys at all", ng2[7] .. ng2[8] .. ng2[9], "123")

-- csv helpers ------------------------------------------------------------
local line = C.csv_line({ 42, "/home/user/image 01.NEF", 7 })
check("csv_line quotes and joins fields", line, '"42","/home/user/image 01.NEF","7"')
check("csv_line doubles embedded quotes", C.csv_line({ 'a "b", c' }), '"a ""b"", c"')

local parsed = C.parse_csv_line("42,/home/user/image 01.NEF,7,ok,1,4", 6)
check("parse_csv_line splits into 6 fields", #parsed, 6)
check("parse_csv_line field 2 keeps spaces", parsed[2], "/home/user/image 01.NEF")
check("parse_csv_line rejects wrong field count", C.parse_csv_line("1,2,3", 6), nil)
local crlf = C.parse_csv_line("7,1,2,3,4,1\r", 6)
check("parse_csv_line drops csv.writer's trailing \\r", crlf and crlf[6], "1")

local point = C.parse_prompt(C.parse_csv_line("124,0.5,0.25,,", 5))
check("parse_prompt: empty corner is a point", point.x0 == 0.5 and point.y0 == 0.25 and point.x1 == nil, true)
local box = C.parse_prompt(C.parse_csv_line("123,0.21,0.4,0.68,0.77", 5))
check("parse_prompt: four numbers are a box", box.x0 == 0.21 and box.y1 == 0.77, true)
check("parse_prompt: half a corner is malformed", C.parse_prompt(C.parse_csv_line("1,0.2,0.4,0.6,", 5)), nil)
check("parse_prompt: non-number is malformed", C.parse_prompt(C.parse_csv_line("1,x,0.4,,", 5)), nil)

-- diag_tag_changes --------------------------------------------------------
local have = {
    ["Assisted Culling|Keeper"] = true,
    ["Assisted Culling|Subject|Vehicle|Guessed"] = true,
    ["Assisted Culling|Scored|Masked"] = true,
    ["Holiday"] = true,
}
local attach, detach = C.diag_tag_changes(have, "Subject|Vehicle|Car;Scored|Masked")
check("diag tags: attaches what's new", table.concat(attach, ","), "Assisted Culling|Subject|Vehicle|Car")
check("diag tags: detaches stale ones, never Keeper or the user's own",
    table.concat(detach, ","), "Assisted Culling|Subject|Vehicle|Guessed")
attach, detach = C.diag_tag_changes(have, "")
check("diag tags: empty column (or preference off) detaches every diagnostic tag",
    table.concat(detach, ","), "Assisted Culling|Scored|Masked,Assisted Culling|Subject|Vehicle|Guessed")
attach = C.diag_tag_changes({}, "Keeper;Subject|Animal|Bird")
check("diag tags: only diagnostic folders can be written; new subject kinds need no code",
    table.concat(attach, ","), "Assisted Culling|Subject|Animal|Bird")

check("filter_diag: drops the names turned off",
    C.filter_diag("Subject|Vehicle|Car;Scored|Masked;Technique|Panning", { ["Subject|Vehicle|Car"] = true, ["Technique|Panning"] = true }),
    "Scored|Masked")
check("filter_diag: nothing off keeps the column", C.filter_diag("Subject|Vehicle|Car;Scored|Masked", {}),
    "Subject|Vehicle|Car;Scored|Masked")
check("filter_diag: matches the full name, not a prefix of it",
    C.filter_diag("Scored|Masked", { Scored = true }), "Scored|Masked")
check("filter_diag: exact names",
    C.filter_diag("Subject|Vehicle|Guessed;Why|Keeper;Technique|Panning", { ["Subject|Vehicle|Detected"] = true, ["Why|Keeper"] = true }),
    "Subject|Vehicle|Guessed;Technique|Panning")
local off_subject = C.diag_off({ subject = false, subject_guessed = true, technique = true, scored = true, why = true })
check("diag_off: subject off drops Detected only",
    tostring(off_subject["Subject|Vehicle|Detected"]) .. "/" .. tostring(off_subject["Subject|Vehicle|Guessed"]), "true/nil")
local off_check = C.diag_off({ subject = true, subject_guessed = false })
check("diag_off: a check switched off drops its name", tostring(off_check["Subject|Vehicle|Guessed"]), "true")
check("diag_off: output rows never filter",
    next(C.diag_off({ keeper = false, rejected = false, subject = true, subject_guessed = true, technique = true, scored = true, why = true })), nil)
attach, detach = C.diag_tag_changes(have, C.filter_diag("Subject|Vehicle|Car;Scored|Masked", { ["Subject|Vehicle|Car"] = true }))
check("filter_diag + diag_tag_changes: an off branch is detached, not attached",
    table.concat(attach, ",") .. "/" .. table.concat(detach, ","), "/Assisted Culling|Subject|Vehicle|Guessed")

local kind_ok = {}
for _, k in ipairs(C.TAG_KINDS) do kind_ok[k.kind] = true end
local bad_kind = {}
for _, t in ipairs(C.TAG_TOGGLES) do
    if not kind_ok[t.kind] then bad_kind[#bad_kind + 1] = t.key end
end
check("TAG_TOGGLES: every row has a kind in TAG_KINDS", table.concat(bad_kind, ","), "")
local order = {}
for _, t in ipairs(C.tag_rows_in_order()) do order[#order + 1] = t.key end
check("tag_rows_in_order: outputs, checks, then diagnostics", table.concat(order, ","),
    "keeper,rejected,overexposed,underexposed,eyes_closed,cut_off,blocked,blank,subject_guessed,subject,technique,scored,why")

local old_off = C.preset_encode(C.PRESET_SCHEMA, { tag_subject = false })
old_off = old_off:gsub('%s*"tag_subject_guessed"%s*:%s*[a-z]+%s*,?', "")
local up, copied = C.upgrade_preset_text(old_off)
check("upgrade_preset_text: tag_subject false gives Guessed off",
    tostring(C.preset_decode(up).tag_subject_guessed) .. "/" .. table.concat(copied or {}, ","), "false/tag_subject_guessed")
local old_on = old_off:gsub('"tag_subject"%s*:%s*false', '"tag_subject": true')
up, copied = C.upgrade_preset_text(old_on)
check("upgrade_preset_text: tag_subject true gives Guessed on",
    tostring(C.preset_decode(up).tag_subject_guessed) .. "/" .. table.concat(copied or {}, ","), "true/tag_subject_guessed")
local full = C.preset_encode(C.PRESET_SCHEMA, { tag_subject = false, tag_subject_guessed = true })
up, copied = C.upgrade_preset_text(full)
check("upgrade_preset_text: no-op when tag_subject_guessed is present", tostring(up == full) .. "/" .. tostring(copied), "true/nil")
up, copied = C.upgrade_preset_text("not json {")
check("upgrade_preset_text: no-op on text that is not JSON", up .. "/" .. tostring(copied), "not json {/nil")
-- a preset saved by the grouping support dropdown: today's grouping keys out, the old three in
local function dropdown_preset(group_support, group_node, car_tag_node)
    local text = C.preset_encode(C.PRESET_SCHEMA, {}):gsub('%s*"group_[%w_]+"%s*:%s*[^,\n]+,', "")
    return (text:gsub('"run_tag"', string.format('"group_support": "%s",\n  "group_node": "%s",\n  "car_tag_node": "%s",\n  "run_tag"',
        group_support, group_node, car_tag_node), 1))
end
local function upgraded_grouping(group_support, group_node, car_tag_node)
    local upgraded, filled = C.upgrade_preset_text(dropdown_preset(group_support, group_node, car_tag_node))
    local s = C.preset_merge(C.PRESET_SCHEMA, C.preset_decode(upgraded))
    return string.format("%s [%s] [%s] [%s] %s", tostring(s.group_native), s.group_tag_1, s.group_tag_2, s.group_tag_3,
        table.concat(filled or {}, ","))
end
check("upgrade_preset_text: native keeps native groups on", upgraded_grouping("native", "", ""), "true [] [] [] group_native")
check("upgrade_preset_text: native with a car node puts it in node 1", upgraded_grouping("native", "ignored", " Rally|2026 "),
    "true [Rally|2026] [] [] group_native,group_tag_1")
check("upgrade_preset_text: tags with a node turns native off, node first", upgraded_grouping("tags", "Shoot|Groups", ""),
    "false [Shoot|Groups] [] [] group_native,group_tag_1")
check("upgrade_preset_text: tags with a blank node uses the latest grouping run", upgraded_grouping("tags", "", "Rally|2026"),
    "false [Assisted Grouping] [Rally|2026] [] group_native,group_tag_1,group_tag_2")
check("upgrade_preset_text: none drops the car node", upgraded_grouping("none", "Shoot|Groups", "Rally|2026"),
    "false [] [] [] group_native")
local today = C.preset_encode(C.PRESET_SCHEMA, { group_native = false, group_tag_1 = "Rally|2026" })
up, copied = C.upgrade_preset_text(today)
check("upgrade_preset_text: no-op on today's grouping keys", tostring(up == today) .. "/" .. tostring(copied), "true/nil")

local flags = C.parse_flags("overexposed;eyes_closed")
check("parse_flags reads every flag", tostring(flags.overexposed and flags.eyes_closed), "true")
check("parse_flags: empty field is no flags", next(C.parse_flags("")), nil)

local pr = C.parse_report_line('1,"a ""x"".jpg",2,3,55.0,leave,no,blur,"Subject|Car,Bird","not kept, rank 2"')
check("parse_report_line: quoted commas and doubled quotes", table.concat(pr, "|"),
    '1|a "x".jpg|2|3|55.0|leave|no|blur|Subject|Car,Bird|not kept, rank 2')
check("parse_report_line: field count", #pr, 10)
check("parse_report_line: empty trailing field kept", #C.parse_report_line("a,b,"), 3)

local report_text = 'burst,file,rank,of,score,stars,keeper,flags,tags,why\n'
    .. '0,a.jpg,1,2,80.0,4,yes,,Subject|Car,"kept: rank 1 of 2, 1 allowed"\n'
    .. '0,b.jpg,2,2,40.0,leave,no,blur,,"not kept: rank 2 of 2, only 1 allowed or not eligible; flagged blur"\n'
local why_lines, why_missing = C.explain_report(report_text, { ["b.jpg"] = true, ["z.jpg"] = true })
check("explain_report: one line for the matching frame", #why_lines, 1)
check("explain_report: a left-alone non-keeper says so", why_lines[1],
    "b.jpg: left as it was, burst 0, score 40.0. not kept: rank 2 of 2, only 1 allowed or not eligible; flagged blur")
check("explain_report: names frames the run had no row for", table.concat(why_missing, ","), "z.jpg")
local why_a = C.explain_report(report_text, { ["a.jpg"] = true })
check("explain_report: a keeper shows its stars", why_a[1], "a.jpg: 4 stars, burst 0, score 80.0. kept: rank 1 of 2, 1 allowed")
local why_raw, why_raw_missing = C.explain_report(report_text, { ["A.ARW"] = true })
check("explain_report: a RAW finds its pair's row", why_raw[1], why_a[1])
check("explain_report: the RAW isn't reported missing", #why_raw_missing, 0)
local why_both = C.explain_report(report_text, { ["a.ARW"] = true, ["a.jpg"] = true })
check("explain_report: a selected pair gives one line", #why_both, 1)
check("explain_report: a score held as measured shows one decimal",
    C.explain_report('burst,file,rank,of,score,stars,keeper,flags,tags,why\n0,m.jpg,1,1,69.565217,4,yes,,,kept\n', { ["m.jpg"] = true })[1],
    "m.jpg: 4 stars, burst 0, score 69.6. kept")
local report_folders = 'burst,file,rank,of,score,stars,keeper,flags,tags,why,folder\n'
    .. '0,a.jpg,1,1,80.0,4,yes,,,kept,C:\\shoot\\cam1\n'
    .. '1,a.jpg,1,1,30.0,1,yes,,,kept,C:\\shoot\\cam2\n'
local why_cam2 = C.explain_report(report_folders, { ["C:\\shoot\\cam2/a.jpg"] = true })
check("explain_report: a same-named file in another folder doesn't match", table.concat(why_cam2, "|"),
    "a.jpg: 1 stars, burst 1, score 30.0. kept")
local report_reason = 'burst,file,rank,of,score,stars,keeper,flags,tags,why,folder,reason\n'
    .. '0,a.jpg,1,2,80.0,4,yes,,Why|Keeper,kept,C:\\shoot,Keeper\n'
    .. '0,b.jpg,2,2,70.0,3,yes,,Why|Keeper by margin,kept,C:\\shoot,Keeper by margin\n'
local why_reason = C.explain_report(report_reason, { ["C:\\shoot/b.jpg"] = true })
check("explain_report: a 12-column report adds the reason", why_reason[1],
    "b.jpg: 3 stars, burst 0, score 70.0. kept Why: Keeper by margin.")
local report_car = 'burst,file,rank,of,score,stars,keeper,flags,tags,why,folder,reason,car\n'
    .. '0,a.jpg,1,2,80.0,4,yes,,Why|Keeper,kept,C:\\shoot,Keeper,\n'
    .. '0,b.jpg,2,2,70.0,3,yes,,Why|Keeper by margin,kept,C:\\shoot,Keeper by margin,37\n'
local why_car_blank = C.explain_report(report_car, { ["C:\\shoot/a.jpg"] = true })
local why_car_37 = C.explain_report(report_car, { ["C:\\shoot/b.jpg"] = true })
check("explain_report: 13-column report row is read", #why_car_blank + #why_car_37, 2)
check("is_diag_tag: Why tags are diagnostics", C.is_diag_tag("Assisted Culling|Why|Outranked"), true)
local _, why_cam3 = C.explain_report(report_folders, { ["C:\\shoot\\cam3/a.jpg"] = true })
check("explain_report: no row in its folder is missing", table.concat(why_cam3, "|"), "C:\\shoot\\cam3/a.jpg")

-- shots ---------------------------------------------------------------------
check("shot_stem drops the extension, any case", C.shot_stem("DSC01.ARW") .. "/" .. C.shot_stem("dsc01.JPG"), "dsc01/dsc01")
check("shot_stem keeps inner dots", C.shot_stem("a.b.jpg"), "a.b")
check("shot_stem with no extension", C.shot_stem("README"), "readme")
check("is_raw on ARW", C.is_raw("X.ARW"), true)
check("is_raw on JPG", C.is_raw("x.jpg"), false)

local function shot_ids(images)
    local primaries, group_of = C.collapse_shots(images)
    local out = {}
    for _, p in ipairs(primaries) do
        local members = {}
        for _, img in ipairs(group_of[p.id]) do members[#members + 1] = img.id end
        out[#out + 1] = p.id .. ":" .. table.concat(members, ",")
    end
    return table.concat(out, " ")
end
check("collapse_shots: RAW+JPEG pair is one shot, scored from the JPEG",
    shot_ids({ { id = 1, path = "/s", filename = "DSC01.ARW" }, { id = 2, path = "/s", filename = "DSC01.JPG" } }),
    "2:1,2")
check("collapse_shots: JPEG first keeps it as lead",
    shot_ids({ { id = 2, path = "/s", filename = "DSC01.JPG" }, { id = 1, path = "/s", filename = "DSC01.ARW" } }),
    "2:2,1")
check("collapse_shots: duplicates of one file are one shot",
    shot_ids({ { id = 1, path = "/s", filename = "a.jpg" }, { id = 3, path = "/s", filename = "a.jpg" } }),
    "1:1,3")
check("collapse_shots: same stem in another folder stays separate",
    shot_ids({ { id = 1, path = "/s", filename = "a.ARW" }, { id = 2, path = "/t", filename = "a.JPG" } }),
    "1:1 2:2")
check("collapse_shots: the swapped lead keeps the shot's position",
    shot_ids({ { id = 1, path = "/s", filename = "a.ARW" }, { id = 5, path = "/s", filename = "b.ARW" },
               { id = 2, path = "/s", filename = "a.JPG" } }),
    "2:1,2 5:5")
local _, swapped = C.collapse_shots({ { id = 1, path = "/s", filename = "a.ARW" }, { id = 2, path = "/s", filename = "a.JPG" } })
check("collapse_shots: the RAW is no longer a lead", swapped[1], nil)
check("collapse_shots: a Pentax PEF pair is scored from the JPEG",
    shot_ids({ { id = 1, path = "/s", filename = "IMGP1.PEF" }, { id = 2, path = "/s", filename = "IMGP1.JPG" } }),
    "2:1,2")
check("collapse_shots: RAW, JPEG and a duplicate are one shot led by the JPEG",
    shot_ids({ { id = 1, path = "/s", filename = "a.NEF" }, { id = 3, path = "/s", filename = "a.NEF" },
               { id = 2, path = "/s", filename = "a.jpg" } }),
    "2:1,3,2")
check("collapse_shots: a RAW leads over a format the scorer can't open full size",
    shot_ids({ { id = 1, path = "/s", filename = "a.heic" }, { id = 2, path = "/s", filename = "a.ARW" } }),
    "2:1,2")

-- pythonw_of (Windows launches through pythonw.exe beside the chosen python.exe)
check("pythonw_of: venv python.exe", C.pythonw_of("C:/x/.venv/Scripts/python.exe"), "C:/x/.venv/Scripts/pythonw.exe")
check("pythonw_of: case-insensitive", C.pythonw_of("C:\\Py\\Python.EXE"), "C:\\Py\\pythonw.exe")
check("pythonw_of: bare python on PATH", C.pythonw_of("python"), "pythonw")
check("pythonw_of: other launcher is refused", C.pythonw_of("C:/Windows/py.exe"), nil)

require("test_preset_block")(C, check)

local cd = C.preset_defaults(C.PRESET_SCHEMA)
check("preset schema: mode defaults", string.format("%s %s %s %s %s %s", cd.genre, cd.rank_mode, cd.sharp_mode,
    cd.exp_mode, cd.keep_mode, cd.non_keeper),
    "landscape universal tiles_uniformity strict single_best leave")
check("preset schema: grouping defaults to native groups and no tag nodes",
    string.format("%s [%s] [%s] [%s]", tostring(cd.group_native), tostring(cd.group_tag_1), tostring(cd.group_tag_2),
        tostring(cd.group_tag_3)), "true [] [] []")
check("preset schema: switch defaults", string.format("%s %s %s %s %s %s", cd.run_tag, cd.apply_while_scoring,
    cd.fast_jpeg_decode, cd.penalise_overexposed, cd.penalise_underexposed, cd.penalise_eyes_closed),
    "false false true true true true")
-- read from the schema, so a new tag_ switch needs no list edit here
local tags_off, schema_seen, schema_twice = {}, {}, {}
for _, s in ipairs(C.PRESET_SCHEMA) do
    if s.key:match("^tag_") and cd[s.key] ~= true then tags_off[#tags_off + 1] = s.key end
    if schema_seen[s.key] then schema_twice[#schema_twice + 1] = s.key end
    schema_seen[s.key] = true
end
check("preset schema: every tag switch defaults on", table.concat(tags_off, ","), "")
check("preset schema: no key twice", table.concat(schema_twice, ","), "")
local page_missing, page_duplicate = PC.page_coverage(C.PANEL_PAGES, C.PANEL_OTHER_KEYS, C.PRESET_SCHEMA)
check("PANEL_PAGES: every preset key is on one page or listed off-stack",
    table.concat(page_missing, " ") .. table.concat(page_duplicate, " "), "")
local page_titles = {}
for _, p in ipairs(C.PANEL_PAGES) do page_titles[#page_titles + 1] = p.title end
check("PANEL_PAGES: titles match the README sections", table.concat(page_titles, ","),
    "Scoring,Bursts,Penalties & Speed,Tags Written,Run,Tools")

local function pool_numbers(ids, key_of)
    local n, out = C.number_groups(ids, key_of), {}
    for i, id in ipairs(ids) do out[i] = n[id] end
    return table.concat(out, " ")
end
local sk, s_split, s_tagged = C.split_by_tag({ "1", "2", "3", "4" }, { ["1"] = "g", ["2"] = "g", ["3"] = "g", ["4"] = "g" },
    { ["1"] = "37", ["2"] = "86", ["3"] = "37" }, {})
check("split_by_tag: child tags split a group, untagged frames share the group pool",
    pool_numbers({ "1", "2", "3", "4" }, sk) .. "|" .. s_split .. "|" .. s_tagged, "1 2 1 3|1|3")
local sk2, _, s_tagged2 = C.split_by_tag({ "1", "2" }, {}, { ["1"] = "37", ["2"] = "37" }, {})
check("split_by_tag: a frame with no group key stays alone",
    pool_numbers({ "1", "2" }, sk2) .. "|" .. s_tagged2, "1 2|0")
local sk3, s_split3, s_tagged3 = C.split_by_tag({ "1", "2", "3" }, { ["1"] = "g", ["2"] = "g", ["3"] = "g" },
    { ["1"] = "37", ["2"] = "37", ["3"] = "86" }, { "3" })
check("split_by_tag: several children → shared pool",
    pool_numbers({ "1", "2", "3" }, sk3) .. "|" .. s_split3 .. "|" .. s_tagged3, "1 1 2|1|2")
local in_keys = { ["1"] = "g", ["2"] = "g" }
local sk4, s_split4 = C.split_by_tag({ "1", "2" }, in_keys, {}, {})
check("split_by_tag: no child tags → keys unchanged",
    tostring(sk4["1"] == in_keys["1"] and sk4["2"] == in_keys["2"]) .. "|" .. s_split4, "true|0")
-- a second node cuts the first node's pools: 1 and 5 share both children, 4 has only the first
local five = { "1", "2", "3", "4", "5" }
local cut1 = C.split_by_tag(five, { ["1"] = "g", ["2"] = "g", ["3"] = "g", ["4"] = "g", ["5"] = "g" },
    { ["1"] = "a", ["2"] = "a", ["3"] = "b", ["4"] = "b", ["5"] = "a" }, {})
local cut2, cut2_split, cut2_tagged = C.split_by_tag(five, cut1, { ["1"] = "x", ["2"] = "y", ["3"] = "x", ["5"] = "x" }, {})
check("split_by_tag: a second node cuts each pool of the first",
    pool_numbers(five, cut2) .. "|" .. cut2_split .. "|" .. cut2_tagged, "1 2 3 4 1|2|4")
check("no_groups_notice: all singletons with grouping on",
    C.no_groups_notice(true, 5, 5), "no groups found: every frame judged alone (group first for keepers)")
check("no_groups_notice: grouped selection is silent", C.no_groups_notice(true, 5, 2), nil)
check("no_groups_notice: grouping off and single frame are silent",
    tostring(C.no_groups_notice(false, 5, 5)) .. "|" .. tostring(C.no_groups_notice(true, 1, 1)), "nil|nil")
check("preset schema: keeper margin defaults off", cd.keep_margin, "off")
check("preset schema: spread keepers defaults off", cd.spread_keepers, false)
check("preset schema: number reads defaults off", cd.number_reads, false)
check("preset schema: other angle, motion look and star slope default on",
    tostring(cd.keep_angles) .. "|" .. tostring(cd.motion_look) .. "|" .. tostring(cd.star_slope), "true|true|true")
for _, t in ipairs(C.TAG_TOGGLES) do
    if t.key == "why" then
        check("TAG_TOGGLES: Why writes fifteen reasons, ending with far behind and not a first pick",
            #t.writes .. "|" .. t.writes[14] .. "|" .. t.writes[15], "15|Why|Far behind|Why|Not a first pick")
    end
end
check("preset schema: sharpness judge defaults off", cd.sharp_judge, false)
check("preset schema: graded non-keepers can be picked",
    C.preset_merge(C.PRESET_SCHEMA, { non_keeper = "graded" }).non_keeper, "graded")
check("preset schema: star strictness defaults to standard", cd.star_scale, "1")
check("preset schema: blank frames default to 95%", cd.blank_share, "95")
check("preset schema: rejects per burst default to 2", cd.reject_cap, "2")
check("preset schema: first picks default off", cd.first_picks, "off")
check("preset schema: an unknown star strictness falls back",
    C.preset_merge(C.PRESET_SCHEMA, { star_scale = "3" }).star_scale, "1")
local has_motion = false
for _, v in ipairs(C.CHOICES.sharp_mode) do if v == "motion_aware" then has_motion = true end end
check("sharp modes: motorsport is offered", has_motion, true)
check("genre modes: sport uses motorsport sharpness", C.GENRE_MODES.sport.sharp_mode, "motion_aware")
check("genre modes: portrait sharpness", C.GENRE_MODES.portrait.sharp_mode, "face_detect")
check("genre modes: macro keepers", C.GENRE_MODES.macro.keep_mode, "keep_all")
check("genre modes: landscape defaults match", C.genre_matches("landscape", cd), true)
check("genre modes: a changed mode no longer matches",
    C.genre_matches("landscape", { rank_mode = "binary", sharp_mode = "tiles_uniformity", exp_mode = "strict", keep_mode = "single_best" }), false)
check("genre modes: custom never matches", C.genre_matches("custom", cd), false)
check("preset schema: a label for a choice falls back",
    C.preset_merge(C.PRESET_SCHEMA, { sharp_mode = "face & eyes (OpenCV)" }).sharp_mode, "tiles_uniformity")
check("preset schema: car boxes from tagging default on", cd.car_boxes_only, true)
check("car_boxes_path: tagging's last-run boxes.json, backslashes folded",
    C.car_boxes_path("C:\\Users\\me\\dt\\", "rallye"), "C:/Users/me/dt/assisted_tagging/last-run/rallye.boxes.json")
local only = function(...) local set = {} for _, f in ipairs({ ... }) do set[f] = true end return function(f) return set[f] end end
check("pick_detector: YOLOX alone is picked, better files listed",
    select(2, C.pick_detector(only("object_detection_yolox_2022nov.onnx"))),
    "vehicle detector: object_detection_yolox_2022nov.onnx (better, not installed: dfine_x_coco.onnx, dfine_l_coco.onnx, rtdetr_v2_r50vd.onnx, dfine_m_coco.onnx, dfine_s_coco.onnx)")
check("pick_detector: D-FINE beats YOLOX", (C.pick_detector(only("dfine_s_coco.onnx", "object_detection_yolox_2022nov.onnx"))), "dfine_s_coco.onnx")
check("pick_detector: the best has no 'not installed' note", select(2, C.pick_detector(only("dfine_x_coco.onnx"))), "vehicle detector: dfine_x_coco.onnx")
check("pick_detector: none installed is nil", (C.pick_detector(only())), nil)

print("")
if failures == 0 then
    print("all tests passed")
    os.exit(0)
else
    print(failures .. " test(s) failed")
    os.exit(1)
end
