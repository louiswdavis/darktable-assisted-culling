-- Run with: lua test_culling.lua
-- Exercises the darktable-independent half of culling.lua directly.

package.path = package.path .. ";./?.lua"
local C = require("culling")

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

-- cluster_by_time --------------------------------------------------------
-- Three shots one second apart (a burst), then a fourth shot 10 seconds
-- later (a separate moment), then one image with no EXIF time at all.
local items = {
    { id = 1, epoch = C.exif_time_to_epoch("2026:06:01 14:30:00") },
    { id = 2, epoch = C.exif_time_to_epoch("2026:06:01 14:30:01") },
    { id = 3, epoch = C.exif_time_to_epoch("2026:06:01 14:30:02") },
    { id = 4, epoch = C.exif_time_to_epoch("2026:06:01 14:30:12") },
    { id = 5, epoch = nil },
}
local bursts = C.cluster_by_time(items, 2)

check("burst: images 1,2,3 share a burst", bursts[1] == bursts[2] and bursts[2] == bursts[3], true)
check("burst: image 4 is a separate burst from 1-3", bursts[4] ~= bursts[1], true)
check("burst: untimed image 5 gets its own burst", bursts[5] ~= bursts[1] and bursts[5] ~= bursts[4], true)

-- order shouldn't matter: shuffle the input and expect the same clustering
local shuffled = { items[4], items[1], items[3], items[5], items[2] }
local bursts2 = C.cluster_by_time(shuffled, 2)
check("burst: clustering is order-independent",
    (bursts2[1] == bursts2[2] and bursts2[2] == bursts2[3] and bursts2[4] ~= bursts2[1]), true)

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

print("")
if failures == 0 then
    print("all tests passed")
    os.exit(0)
else
    print(failures .. " test(s) failed")
    os.exit(1)
end
