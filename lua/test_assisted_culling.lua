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
for _, k in ipairs({ "keeper", "rejected", "overexposed", "underexposed", "eyes_closed", "subject", "technique", "scored" }) do
    if cd["tag_" .. k] ~= true then all_tags_on = false end
end
check("preset schema: every tag switch defaults on", all_tags_on, true)
check("preset schema: 22 keys", #C.PRESET_SCHEMA, 22)
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
