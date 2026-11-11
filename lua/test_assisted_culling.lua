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
local COMMON_HASH = "66ba39a6"
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
check("shell_quote: Windows escapes quotes and doubles %", PC.shell_quote('C:\\x %y% "z"', true), '"C:\\x %%y%% \\"z\\""')
check("shell_quote: POSIX escapes single quotes", PC.shell_quote("a'b", false), "'a'\\''b'")
check("parse_csv_line: quoted comma and doubled quote", PC.parse_csv_line('1,"a ""x"", b.jpg",3\r', 3)[2], 'a "x", b.jpg')
check("parse_csv_line: wrong field count is nil", PC.parse_csv_line("a,b", 3), nil)
check("lead_rank: full-size JPEG beats RAW", PC.lead_rank("x.JPG") > PC.lead_rank("x.nef"), true)
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

-- group keys ----------------------------------------------------------------
local G10 = "Assisted Grouping|2026-11-09 10:00:00|Group"
local G12 = "Assisted Grouping|2026-11-09 12:30:00|Group"
check("newest_group_node picks the greatest stamp",
    C.newest_group_node({ { G10 .. "|0001" }, { "F1|Ferrari", G12 .. "|0001" } }), G12)
check("newest_group_node ignores other tags", C.newest_group_node({ { "F1|Ferrari" } }), nil)
check("newest_group_node with empty input", C.newest_group_node({}), nil)

local gk = C.tag_group_keys({
    { id = 1, tags = { [G12 .. "|0001"] = true, [G12 .. "|0001|x"] = true } },
    { id = 2, tags = { [G12 .. "|0002"] = true } },
}, G12)
check("tag_group_keys reads immediate children only", gk[1] .. "/" .. gk[2], "0001/0002")
local gk2, multi = C.tag_group_keys({
    { id = 3, tags = { [G12 .. "|0002"] = true, [G12 .. "|0001"] = true } },
}, G12)
check("tag_group_keys takes the first child by name", gk2[3], "0001")
check("tag_group_keys reports the photo", multi[1], 3)
local gk3 = C.tag_group_keys({ { id = 4, tags = { [G10 .. "|0001"] = true } } }, G12)
check("tag_group_keys leaves unmatched photos out", gk3[4], nil)

local nk = C.native_group_keys({ { id = 1, leader = 5 }, { id = 2, leader = 5 }, { id = 3 } })
check("native_group_keys maps leaders", nk[1] .. nk[2] .. tostring(nk[3]), "55nil")

local ng = C.number_groups({ 10, 11, 12, 13 }, { [10] = "a", [11] = "a", [13] = "b" })
check("number_groups shares and separates",
    table.concat({ ng[10], ng[11], ng[12], ng[13] }, ","), "1,1,2,3")
local ng2 = C.number_groups({ 7, 8, 9 }, {})
check("number_groups with no keys at all", ng2[7] .. ng2[8] .. ng2[9], "123")

-- csv helpers ------------------------------------------------------------
local line = C.csv_line({ 42, "/home/user/photo 01.NEF", 7 })
check("csv_line quotes and joins fields", line, '"42","/home/user/photo 01.NEF","7"')
check("csv_line doubles embedded quotes", C.csv_line({ 'a "b", c' }), '"a ""b"", c"')

local parsed = C.parse_csv_line("42,/home/user/photo 01.NEF,7,ok,1,4", 6)
check("parse_csv_line splits into 6 fields", #parsed, 6)
check("parse_csv_line field 2 keeps spaces", parsed[2], "/home/user/photo 01.NEF")
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

check("filter_diag: drops the branches turned off",
    C.filter_diag("Subject|Vehicle|Car;Scored|Masked;Technique|Panning", { Subject = true, Technique = true }),
    "Scored|Masked")
check("filter_diag: nothing off keeps the column", C.filter_diag("Subject|Vehicle|Car;Scored|Masked", {}),
    "Subject|Vehicle|Car;Scored|Masked")
check("filter_diag: matches the branch name, not a prefix of it",
    C.filter_diag("Scored|Masked", { Score = true }), "Scored|Masked")
attach, detach = C.diag_tag_changes(have, C.filter_diag("Subject|Vehicle|Car;Scored|Masked", { Subject = true }))
check("filter_diag + diag_tag_changes: an off branch is detached, not attached",
    table.concat(attach, ",") .. "/" .. table.concat(detach, ","), "/Assisted Culling|Subject|Vehicle|Guessed")

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
check("preset schema: mode defaults", string.format("%s %s %s %s %s %s %s [%s]", cd.genre, cd.rank_mode, cd.sharp_mode,
    cd.exp_mode, cd.keep_mode, cd.non_keeper, cd.group_support, cd.group_node),
    "landscape universal tiles_uniformity strict single_best leave native []")
check("preset schema: switch defaults", string.format("%s %s %s %s %s %s", cd.run_tag, cd.apply_while_scoring,
    cd.fast_jpeg_decode, cd.penalise_overexposed, cd.penalise_underexposed, cd.penalise_eyes_closed),
    "false false true true true true")
local all_tags_on = true
for _, k in ipairs({ "keeper", "rejected", "overexposed", "underexposed", "eyes_closed", "subject", "technique", "scored", "why" }) do
    if cd["tag_" .. k] ~= true then all_tags_on = false end
end
check("preset schema: every tag switch defaults on", all_tags_on, true)
check("preset schema: 26 keys", #C.PRESET_SCHEMA, 26)
local page_missing, page_duplicate = PC.page_coverage(C.PANEL_PAGES, C.PANEL_OTHER_KEYS, C.PRESET_SCHEMA)
check("PANEL_PAGES: every preset key is on one page or listed off-stack",
    table.concat(page_missing, " ") .. table.concat(page_duplicate, " "), "")
local page_titles = {}
for _, p in ipairs(C.PANEL_PAGES) do page_titles[#page_titles + 1] = p.title end
check("PANEL_PAGES: titles match the README sections", table.concat(page_titles, ","),
    "scoring,bursts,penalties & speed,tags written,run,tools")

local function pool_numbers(ids, key_of)
    local n, out = C.number_groups(ids, key_of), {}
    for i, id in ipairs(ids) do out[i] = n[id] end
    return table.concat(out, " ")
end
local sk, s_split, s_carred = C.split_by_car({ "1", "2", "3", "4" }, { ["1"] = "g", ["2"] = "g", ["3"] = "g", ["4"] = "g" },
    { ["1"] = "37", ["2"] = "86", ["3"] = "37" }, {})
check("split_by_car: cars split a group, untagged frames share the group pool",
    pool_numbers({ "1", "2", "3", "4" }, sk) .. "|" .. s_split .. "|" .. s_carred, "1 2 1 3|1|3")
local sk2, _, s_carred2 = C.split_by_car({ "1", "2" }, {}, { ["1"] = "37", ["2"] = "37" }, {})
check("split_by_car: a frame with no group key stays alone",
    pool_numbers({ "1", "2" }, sk2) .. "|" .. s_carred2, "1 2|0")
local sk3, s_split3, s_carred3 = C.split_by_car({ "1", "2", "3" }, { ["1"] = "g", ["2"] = "g", ["3"] = "g" },
    { ["1"] = "37", ["2"] = "37", ["3"] = "86" }, { "3" })
check("split_by_car: several cars → shared pool",
    pool_numbers({ "1", "2", "3" }, sk3) .. "|" .. s_split3 .. "|" .. s_carred3, "1 1 2|1|2")
local in_keys = { ["1"] = "g", ["2"] = "g" }
local sk4, s_split4 = C.split_by_car({ "1", "2" }, in_keys, {}, {})
check("split_by_car: no cars → keys unchanged",
    tostring(sk4["1"] == in_keys["1"] and sk4["2"] == in_keys["2"]) .. "|" .. s_split4, "true|0")
check("no_groups_notice: all singletons in native mode",
    C.no_groups_notice("native", 5, 5), "no groups found: every frame judged alone (group first for keepers)")
check("no_groups_notice: grouped selection is silent", C.no_groups_notice("tags", 5, 2), nil)
check("no_groups_notice: none mode and single frame are silent",
    tostring(C.no_groups_notice("none", 5, 5)) .. "|" .. tostring(C.no_groups_notice("native", 1, 1)), "nil|nil")
check("preset schema: keeper margin defaults off", cd.keep_margin, "off")
check("preset schema: graded non-keepers can be picked",
    C.preset_merge(C.PRESET_SCHEMA, { non_keeper = "graded" }).non_keeper, "graded")
check("preset schema: star strictness defaults to standard", cd.star_scale, "1")
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

print("")
if failures == 0 then
    print("all tests passed")
    os.exit(0)
else
    print(failures .. " test(s) failed")
    os.exit(1)
end
