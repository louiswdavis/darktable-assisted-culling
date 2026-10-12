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

print("")
if failures == 0 then
    print("all tests passed")
    os.exit(0)
else
    print(failures .. " test(s) failed")
    os.exit(1)
end
