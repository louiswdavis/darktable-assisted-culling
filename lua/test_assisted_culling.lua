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

-- exif_time_to_epoch ---------------------------------------------------
check("parses a normal timestamp",
    C.exif_time_to_epoch("2026:06:01 14:30:00") ~= nil, true)
check("returns nil for missing timestamp",
    C.exif_time_to_epoch(nil), nil)
check("returns nil for garbage input",
    C.exif_time_to_epoch("not a date"), nil)

local t1 = C.exif_time_to_epoch("2026:06:01 14:30:00")
local t2 = C.exif_time_to_epoch("2026:06:01 14:30:01")
check("consecutive seconds differ by 1", t2 - t1, 1)

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

print("")
if failures == 0 then
    print("all tests passed")
    os.exit(0)
else
    print(failures .. " test(s) failed")
    os.exit(1)
end
