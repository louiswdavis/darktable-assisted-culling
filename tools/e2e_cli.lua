-- e2e_cli.lua — headless end-to-end check of culling.lua inside darktable-cli.
--
-- darktable's GUI isn't needed: darktable-cli runs Lua too, it just never
-- loads the user luarc (since 5.6 that's done by script_manager, GUI only),
-- so this script requires the installed plugin itself.
--
-- Usage (Windows shown; adjust paths and quoting for other shells):
--
--   set DT_AI_CULL_FOLDER=C:\path\to\a\folder\of\photos
--   set DT_AI_CULL_REPORT=C:\path\to\report.tsv
--   darktable-cli.exe <any.jpg> <out.jpg> --core --library "%LOCALAPPDATA%\darktable\library.db" ^
--       -d lua --luacmd "dofile([[C:/path/to/tools/e2e_cli.lua]])"
--
-- Two darktable-cli quirks this script works around:
--   * dt.database.import(<folder>) queues an asynchronous job and returns
--     before anything is imported, so files are imported one at a time
--     (that path is synchronous and returns the image).
--   * the bundled system luarc sleeps 1 s on a "first run" (releasing the
--     Lua lock), and darktable-cli tears Lua down as soon as its export is
--     done — which can be before --luacmd ever runs. Make sure darktablerc
--     has  lua/luarc/darktable_first_run_complete=TRUE  (a normal GUI start
--     writes it; set it by hand if darktable's GUI has never come up).
--
-- Writes one TSV row per image with the rating and Assisted Culling tags
-- darktable now holds, which is the plugin's whole observable output.

local dt = require "darktable"

local FOLDER = assert(os.getenv("DT_AI_CULL_FOLDER"), "set DT_AI_CULL_FOLDER")
local REPORT = assert(os.getenv("DT_AI_CULL_REPORT"), "set DT_AI_CULL_REPORT")
local GAP = tonumber(os.getenv("DT_AI_CULL_GAP"))  -- optional BURST_GAP_SECONDS override

local function log(s) dt.print_log("[e2e] " .. s) end

local function list_files(folder)
    local cmd
    if dt.configuration.running_os == "windows" then
        cmd = 'dir /b /on "' .. folder:gsub("/", "\\") .. '"'
    else
        cmd = 'ls -1 "' .. folder .. '"'
    end
    local names = {}
    local p = assert(io.popen(cmd))
    for name in p:lines() do
        local ext = name:match("%.([^.]+)$")
        if ext and ext:lower():match("^jpe?g$") then names[#names + 1] = name end
    end
    p:close()
    return names
end

local ok, err = pcall(function()
    local culling = require "contrib/culling"
    if GAP then culling.BURST_GAP_SECONDS = GAP end
    log("plugin loaded, gap = " .. culling.BURST_GAP_SECONDS .. ", gui = " .. tostring(dt.gui ~= nil))

    local images = {}
    for _, name in ipairs(list_files(FOLDER)) do
        images[#images + 1] = dt.database.import(FOLDER .. "/" .. name)
    end
    log("imported " .. #images .. " images from " .. FOLDER)

    culling.score_images(images)

    local f = assert(io.open(REPORT, "w"))
    f:write("id\tfilename\ttaken\trating\ttags\n")
    for _, img in ipairs(images) do
        local marks = {}
        for _, t in ipairs(dt.tags.get_tags(img)) do
            local leaf = t.name:match("^Assisted Culling|(.+)$")
            if leaf then marks[#marks + 1] = leaf end
        end
        table.sort(marks)
        f:write(table.concat({ img.id, img.filename, tostring(img.exif_datetime_taken),
            tostring(img.rating), table.concat(marks, ",") }, "\t"), "\n")
    end
    f:close()
    log("wrote " .. REPORT)
end)
if not ok then
    log("FAILED: " .. tostring(err))
    local f = io.open(REPORT .. ".FAILED", "w")
    if f then f:write(tostring(err), "\n"); f:close() end
end
