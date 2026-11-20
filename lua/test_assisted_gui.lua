-- Run with: lua test_assisted_gui.lua
-- Runs the darktable half of assisted_culling.lua for real: the panel is built and its buttons
-- are clicked. Only the edges are faked: the darktable API (tags and ratings held in memory), the
-- plugin folder (empty files) and the score_images.py process (os.execute), which answers from PYTHON below.

package.path = package.path .. ";./?.lua"

local failures = 0
local function check(name, got, want)
    if got ~= want then
        failures = failures + 1
        print(string.format("FAIL %s: got %s, want %s", name, tostring(got), tostring(want)))
    else
        print(string.format("ok   %s", name))
    end
end

local WINDOWS = package.config:sub(1, 1) == "\\"
local real_execute = os.execute

local function make_dir(dir)
    real_execute(WINDOWS and ('mkdir "' .. dir:gsub("/", "\\") .. '" 2>nul') or ("mkdir -p '" .. dir .. "'"))
end

local function write_file(path, text)
    local f = assert(io.open(path, "w"))
    f:write(text)
    f:close()
end

local function read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local text = f:read("a")
    f:close()
    return text
end

-- Folders -------------------------------------------------------------------------
local ROOT = ((os.getenv("TEMP") or os.getenv("TMPDIR") or "/tmp"):gsub("\\", "/"):gsub("/$", ""))
    .. "/ac_gui_test_" .. os.time() .. "_" .. math.random(100000, 999999)
local PLUGIN = ROOT .. "/plugins/darktable-assisted-culling"
for _, dir in ipairs({ "/tmp", "/config", "/plugins/darktable-assisted-culling/python",
    "/plugins/darktable-assisted-culling/.venv/Scripts", "/plugins/darktable-assisted-culling/.venv/bin" }) do
    make_dir(ROOT .. dir)
end
for _, file in ipairs({ "/python/score_images.py", "/python/launch.py", "/.venv/Scripts/python.exe",
    "/.venv/Scripts/pythonw.exe", "/.venv/bin/python" }) do
    write_file(PLUGIN .. file, "")
end
-- a preset saved by the old grouping support dropdown, for the bursts page checks
local DROPDOWN_PRESET = ROOT .. "/config/assisted_culling/presets/dropdown.json"
make_dir(ROOT .. "/config/assisted_culling/presets")
write_file(DROPDOWN_PRESET, '{"version": 1, "group_support": "tags", "group_node": "", "car_tag_node": "Rally|2026"}\n')

-- score_images.py -----------------------------------------------------------------
-- What the fake process writes, and what it was last asked. With `hang` it never reports done.
local PYTHON = { results = "", points = "", progress = "", exit = 0, hang = false, runs = {} }

-- The launch as plugin_common.run_async_python writes it: a job file on Windows, a shell line elsewhere.
os.execute = function(cmd)
    if not cmd or not cmd:find("score_images.py", 1, true) and not cmd:find("launch.py", 1, true) then return real_execute(cmd) end
    local argv, done_path = {}, nil
    if WINDOWS then
        local job
        for quoted in cmd:gmatch('"([^"]*)"') do job = quoted end
        local lines = {}
        for line in (read_file(job) or ""):gmatch("[^\r\n]+") do lines[#lines + 1] = line end
        done_path = lines[1]
        for i = 4, #lines do argv[#argv + 1] = lines[i] end
    else
        local tokens = {}
        for quoted in cmd:gmatch("'([^']*)'") do tokens[#tokens + 1] = quoted end
        done_path = tokens[#tokens]
        for i = 2, #tokens - 4 do argv[#argv + 1] = tokens[i] end
    end
    PYTHON.runs[#PYTHON.runs + 1] = { argv = argv, manifest = read_file(argv[2]) }
    for i, arg in ipairs(argv) do
        if arg == "--progress" then write_file(argv[i + 1], PYTHON.progress) end
    end
    local finds_subjects = false
    for _, arg in ipairs(argv) do finds_subjects = finds_subjects or arg == "--emit-saliency-points" end
    write_file(argv[3], finds_subjects and PYTHON.points or PYTHON.results)
    if PYTHON.log then
        local f = assert(io.open(ROOT .. "/config/assisted_culling.log", "a"))
        f:write(PYTHON.log)
        f:close()
    end
    if not PYTHON.hang then write_file(done_path, PYTHON.exit .. "\n") end
    return true
end

-- darktable -----------------------------------------------------------------------
local prints, jobs, images_by_id, tags_by_name, tag_list, panel = {}, {}, {}, {}, {}, nil
local hinter_calls, rating_actions = 0, 0
-- image id → true for members darktable hides in a collapsed group; writes to the selection so far
local hidden_ids, selection_sets = {}, 0
local double_closes = 0 -- times a job that was already closed was closed again
-- called at each dt.control.sleep, where darktable runs its own events (a cancel click, an error)
local on_sleep = nil
-- how many images were selected at each tag attach
local selected_at_attach = {}
-- the name of each tag attached, in order
local attached_names = {}
-- tag name → times dt.tags.create was asked for it
local creates_by_name = {}
local prefs = { ["assisted_plugins/plugins_root"] = ROOT .. "/plugins" }
local PREF_EMPTY = { string = "", directory = "", file = "", integer = 0, float = 0, bool = false }

-- darktable's AI tensors and mask models: every element reads `fill`, a saved tensor is a file
local AI = { saved = {}, closed = 0 }
local function tensor(shape, fill)
    return {
        shape = function() return shape end,
        linear_to_srgb = function() end,
        scale_add_planes = function() end,
        paste = function() end,
        set = function() end,
        get = function() return fill or 0 end,
        save = function(_, path)
            write_file(path, "mask")
            AI.saved[#AI.saved + 1] = path
        end,
    }
end
local MASK_MODELS = {
    ["encoder.onnx"] = function() return tensor({ 1, 256, 64, 64 }) end,
    ["decoder.onnx"] = function() return tensor({ 1, 1, 256, 256 }, 1), tensor({ 1, 1 }, 1) end,
}

local dt
dt = {
    ai = {
        model_for_task = function() return "sam2-test" end,
        models = function() return { { id = "sam2-test", name = "SAM 2", description = "mask" } } end,
        load_model = function(_id, _provider, file)
            return { run = MASK_MODELS[file], close = function() AI.closed = AI.closed + 1 end }
        end,
        load_image = function() return tensor({ 1, 3, 683, 1024 }) end,
        create_tensor = function(shape) return tensor(shape) end,
    },
    configuration = { tmp_dir = ROOT .. "/tmp", config_dir = ROOT .. "/config", version = "test", running_os = WINDOWS and "windows" or "macos" },
    gettext = { gettext = function(msgid) return msgid end },
    preferences = {
        register = function() end,
        read = function(group, name, kind)
            local value = prefs[group .. "/" .. name]
            if value == nil then return PREF_EMPTY[kind] end
            return value
        end,
        write = function(group, name, _kind, value) prefs[group .. "/" .. name] = value end,
    },
    print = function(msg) prints[#prints + 1] = msg end,
    print_error = function() end,
    print_hinter = function() hinter_calls = hinter_calls + 1 end,
    -- as in darktable: dt.tags is the list of all tags, and a tag is the list of its images
    tags = setmetatable({
        get_tags = function(img) return img.tags end,
        find = function(name) return tags_by_name[name] end,
        create = function(name)
            creates_by_name[name] = (creates_by_name[name] or 0) + 1
            if not tags_by_name[name] then
                tags_by_name[name] = { name = name }
                tag_list[#tag_list + 1] = tags_by_name[name]
            end
            return tags_by_name[name]
        end,
        attach = function(tag, img)
            selected_at_attach[#selected_at_attach + 1] = #dt.gui.action_images
            attached_names[#attached_names + 1] = tag.name
            for _, have in ipairs(img.tags) do
                if have == tag then return end
            end
            img.tags[#img.tags + 1] = tag
            tag[#tag + 1] = img
        end,
        detach = function(tag, img)
            for i, have in ipairs(img.tags) do
                if have == tag then table.remove(img.tags, i); break end
            end
            for i, tagged in ipairs(tag) do
                if tagged == img then table.remove(tag, i); break end
            end
        end,
    }, { __len = function() return #tag_list end, __index = function(_, i) return tag_list[i] end }),
    control = { sleep = function() if on_sleep then on_sleep() end end, dispatch = function(fn) fn() end },
    database = { get_image = function(id) return images_by_id[id] end },
    register_event = function() end,
    destroy_event = function() end,
    register_lib = function(...)
        for i = 1, select("#", ...) do
            local arg = select(i, ...)
            if type(arg) == "table" and arg.kind then panel = arg end
        end
    end,
    -- a widget is its own property table: children in the array part, values as fields
    new_widget = function(kind)
        return function(props)
            props.kind = kind
            return props
        end
    end,
    gui = {
        libs = {},
        views = { lighttable = {} },
        -- the act-on images follow the selection; like darktable, reading the selection leaves out
        -- the hidden members of collapsed groups
        selection = function(images)
            local before = {}
            for _, img in ipairs(dt.gui.action_images) do
                if not hidden_ids[img.id] then before[#before + 1] = img end
            end
            if images then
                selection_sets = selection_sets + 1
                dt.gui.action_images = images
            end
            return before
        end,
        action_images = {},
        -- the plugin rates image by image; darktable's rating action is never fired
        action = function() rating_actions = rating_actions + 1 end,
        current_view = function() return { id = "lighttable" } end,
        -- as darktable 5.6: closing a closed job frees it twice (a crash), and its percent can't be set
        create_job = function(title)
            local state = { valid = true, percent = 0, title = title }
            local job = setmetatable({}, {
                __index = state,
                __newindex = function(_, key, value)
                    if not state.valid then
                        if key == "valid" then double_closes = double_closes + 1 end
                        error("Accessing an invalid job")
                    end
                    state[key] = value
                end,
            })
            jobs[#jobs + 1] = job
            return job
        end,
    },
}
package.loaded["darktable"] = dt
package.loaded["lib/dtutils"] = { check_min_api_version = function() end }
package.loaded["lib/dtutils.file"] = {
    check_if_bin_exists = function() return false end,
    test_file = function(path) return os.rename(path, path) and true or false end,
}

-- An image as darktable hands it over, ungrouped and unrated.
local function image(id, filename)
    local img = { id = id, filename = filename, path = "/images", rating = 0, tags = {} }
    img.group_leader = img
    images_by_id[id] = img
    return img
end

local function printed(text)
    for _, msg in ipairs(prints) do
        if msg:find(text, 1, true) then return true end
    end
    return false
end

local function last_print()
    return prints[#prints] or ""
end

local function button(widget, label)
    if type(widget) ~= "table" then return nil end
    if widget.kind == "button" and widget.label == label then return widget end
    for _, child in ipairs(widget) do
        local found = button(child, label)
        if found then return found end
    end
    return nil
end

local function has_tag(img, name)
    for _, tag in ipairs(img.tags) do
        if tag.name == name then return true end
    end
    return false
end

local function lua_errors()
    return read_file(ROOT .. "/config/assisted_culling.lua.log")
end

-- Startup -------------------------------------------------------------------------
local CULLING = require("assisted_culling")
check("the panel is installed at startup", panel ~= nil, true)
check("startup has no Lua error", lua_errors(), nil)

-- The progress line is the panel's last widget; every text it is given is kept.
local status_label, status_texts, status_now = panel[#panel], {}, ""
check("the panel ends with the progress line", status_label.kind, "label")
check("the progress line starts empty", status_label.label, "")
rawset(status_label, "label", nil)
setmetatable(status_label, {
    __index = function(_, key) if key == "label" then return status_now end end,
    __newindex = function(widget, key, value)
        if key ~= "label" then rawset(widget, key, value); return end
        status_now = value
        status_texts[#status_texts + 1] = value
    end,
})

local function status_shown(text)
    for _, shown in ipairs(status_texts) do
        if shown:find(text, 1, true) then return true end
    end
    return false
end

-- The selected images are read at the click, as in darktable.
local function click(label, images)
    prints, jobs, PYTHON.runs, status_texts = {}, {}, {}, {}
    dt.gui.action_images = images
    button(panel, label).clicked_callback()
end

local jpeg1, jpeg2, jpeg3, jpeg4 = image(1, "DSC00001.JPG"), image(2, "DSC00002.JPG"), image(3, "DSC00003.JPG"), image(4, "DSC00004.JPG")
dt.tags.attach(dt.tags.create("Assisted Culling|Locked"), jpeg4)
local all = { jpeg1, jpeg2, jpeg3, jpeg4 }
-- frame 1 is a 3-star keeper, frame 2 is not kept, frame 3 gets no result (unreadable)
PYTHON.results = "1,0.90,,,1,3,\n2,0.40,,,0,1,\n"
PYTHON.progress = "2,3,1,2"

-- Cull Selection --------------------------------------------------------------------
click("Cull Selection", {})
check("cull, nothing selected: asks for a selection", last_print(), "Assisted Culling: Select some images first.")
check("cull, nothing selected: no job bar", #jobs, 0)
check("cull, nothing selected: the scorer is not started", #PYTHON.runs, 0)

selected_at_attach = {}
click("Cull Selection", all)
check("cull: tags were attached", #selected_at_attach > 0, true)
check("cull: the selection stays while tags are attached", math.min(table.unpack(selected_at_attach)), #all)
check("cull: the selection is the same at the end", #dt.gui.action_images, #all)
check("cull: says it started as soon as it is clicked", prints[1], "Assisted Culling: Started on 3 images…")
check("cull: one job bar", #jobs, 1)
check("cull: the job bar is titled", jobs[1] and jobs[1].title, "Assisted Culling")
check("cull: the job bar is closed at the end", jobs[1] and jobs[1].valid, false)
check("cull: the scorer ran once", #PYTHON.runs, 1)
local manifest = PYTHON.runs[1] and PYTHON.runs[1].manifest or ""
check("cull: the manifest has the unlocked frames", manifest:find("DSC00003.JPG", 1, true) ~= nil, true)
check("cull: the locked frame is not sent", manifest:find("DSC00004.JPG", 1, true), nil)
check("cull: progress goes to the panel line", status_shown("analyzing 2 / 3 | bursts 1 / 2"), true)
check("cull: the panel line shows the ratings step", status_shown("applying ratings 2 / 2 (100%)"), true)
check("cull: the panel line is cleared at the end", status_label.label, "")
check("cull: the hinter is never used", hinter_calls, 0)
check("cull: the keeper is rated", jpeg1.rating, 3)
check("cull: the other frame is rated", jpeg2.rating, 1)
check("cull: the keeper is tagged", has_tag(jpeg1, "Assisted Culling|Keeper"), true)
check("cull: the keeper tag stays off the other frame", has_tag(jpeg2, "Assisted Culling|Keeper"), false)
check("cull: the unreadable frame is untouched", jpeg3.rating, 0)
check("cull: the locked frame is untouched", jpeg4.rating, 0)
check("cull: the end message", last_print(), "Assisted Culling: Done. 1 keepers, 1 not kept."
    .. " Left out: 1 unreadable; 1 locked (see log)."
    .. " No groups found: every frame judged alone (group first for keepers).")
check("cull: the button is back to its label", button(panel, "Cull Selection") ~= nil, true)
check("cull: no Lua error", lua_errors(), nil)

-- Cull with the vehicle detector and the judge installed and every option that adds a scorer
-- argument on: each argument-building branch runs through the real command line
local function find_widget(widget, kind, label)
    if widget.kind == kind and widget.label == label then return widget end
    for _, child in ipairs(widget) do
        local found = find_widget(child, kind, label)
        if found then return found end
    end
    return nil
end
local function combo(widget, label) return find_widget(widget, "combobox", label) end
local ARGUMENT_CHECKS = { "Leave Frames with No Vehicle", "Spread Keepers Over the Burst",
    "Break Close Calls on the Number Read", "Break Close Calls with the Sharpness Judge" }
local function set_argument_checks(value)
    for _, label in ipairs(ARGUMENT_CHECKS) do
        local check_button = find_widget(panel, "check_button", label)
        check_button.value = value
        check_button.clicked_callback(check_button)
    end
end
make_dir(PLUGIN .. "/models")
write_file(PLUGIN .. "/models/dfine_x_coco.onnx", "")
write_file(PLUGIN .. "/models/hyperiqa_model.onnx", "")
set_argument_checks(true)
local sharp_combo = combo(panel, "Sharpness")
sharp_combo.selected = 7 -- motorsport (subject & motion)
sharp_combo.changed_callback(sharp_combo)
local first_picks_combo = combo(panel, "First Picks")
first_picks_combo.selected = 3 -- 15
first_picks_combo.changed_callback(first_picks_combo)
jpeg1.rating, jpeg2.rating = 0, 0
click("Cull Selection", { jpeg1, jpeg2 })
first_picks_combo.selected = 1
first_picks_combo.changed_callback(first_picks_combo)
check("cull, detector installed: the scorer ran once", #PYTHON.runs, 1)
local detector_run = PYTHON.runs[1] or { argv = {} }
check("cull, first picks 15: passed to the scorer",
    (table.concat(detector_run.argv, " "):match("%-%-first%-picks (%S+)")), "15")
local detector_args = {}
for i, arg in ipairs(detector_run.argv) do
    if arg == "--detector" or arg == "--detections" then detector_args[#detector_args + 1] = arg .. " " .. tostring(detector_run.argv[i + 1]) end
end
check("cull, detector installed: the detector and the detection cache are passed", table.concat(detector_args, "; "),
    "--detector " .. PLUGIN .. "/models/dfine_x_coco.onnx; --detections " .. ROOT .. "/config/assisted_plugins/detections.sqlite")
check("cull, detector installed: the argument after the cache path is an option",
    (table.concat(detector_run.argv, " "):match("detections%.sqlite (%S+)")), "--car-boxes")
local option_args = {}
for i, arg in ipairs(detector_run.argv) do
    if arg == "--no-vehicle-leave" or arg == "--spread-keepers" or arg == "--keep-angles" or arg == "--motion-look"
        or arg == "--star-slope" then option_args[#option_args + 1] = arg end
    if arg == "--number-reads" or arg == "--sharp-judge" then option_args[#option_args + 1] = arg .. " " .. tostring(detector_run.argv[i + 1]) end
end
check("cull, every argument option on: each one reaches the scorer", table.concat(option_args, "; "),
    "--no-vehicle-leave; --spread-keepers; --keep-angles; --motion-look; --star-slope; --number-reads " .. ROOT .. "/config/assisted_tagging/last-run/.boxes.json; --sharp-judge "
    .. PLUGIN .. "/models/hyperiqa_model.onnx")
check("cull, detector installed: the keeper is rated", jpeg1.rating, 3)
check("cull, detector installed: no Lua error", lua_errors(), nil)

-- Cull with subject tracking: the scorer finds the subjects, darktable's mask model outlines them, the scorer scores
sharp_combo.selected = 6 -- subject tracking (SAM)
sharp_combo.changed_callback(sharp_combo)
PYTHON.points = "1,0.500,0.500,,,0\n2,0.200,0.300,0.600,0.700,0\n"
jpeg1.rating, jpeg2.rating = 0, 0
click("Cull Selection", { jpeg1, jpeg2 })
check("cull, subject tracking: the scorer ran twice", #PYTHON.runs, 2)
check("cull, first picks back off: not passed",
    table.concat((PYTHON.runs[2] or { argv = {} }).argv, " "):find("--first-picks", 1, true), nil)
local points_run, scoring_run = PYTHON.runs[1] or { argv = {} }, PYTHON.runs[2] or { argv = {} }
local function options(argv, names)
    local found = {}
    for i, arg in ipairs(argv) do
        for _, name in ipairs(names) do
            if arg == name then found[#found + 1] = arg .. " " .. tostring(argv[i + 1]) end
        end
    end
    return table.concat(found, "; ")
end
check("cull, subject tracking: the first run finds subjects with the detector and the mask model",
    tostring(points_run.argv[4]) .. "; " .. options(points_run.argv, { "--detector", "--detections", "--sam-model" }),
    "--emit-saliency-points; --detector " .. PLUGIN .. "/models/dfine_x_coco.onnx; --detections " .. ROOT
    .. "/config/assisted_plugins/detections.sqlite; --sam-model sam2-test")
check("cull, subject tracking: both frames are outlined and the models are closed",
    #AI.saved .. " masks, " .. AI.closed .. " closed", "2 masks, 2 closed")
check("cull, subject tracking: the scoring run gets the mask model and each frame's mask",
    options(scoring_run.argv, { "--sam-model" }) .. "; " .. tostring((scoring_run.manifest or ""):find(AI.saved[1] or "no mask", 1, true) ~= nil)
    .. " " .. tostring((scoring_run.manifest or ""):find(AI.saved[2] or "no mask", 1, true) ~= nil), "--sam-model sam2-test; true true")
check("cull, subject tracking: the keeper is rated", jpeg1.rating, 3)
check("cull, subject tracking: no Lua error", lua_errors(), nil)
os.remove(PLUGIN .. "/models/dfine_x_coco.onnx")
os.remove(PLUGIN .. "/models/hyperiqa_model.onnx")
set_argument_checks(false)
sharp_combo.selected = 5
sharp_combo.changed_callback(sharp_combo)

jpeg1.rating, jpeg2.rating = 0, 0
PYTHON.exit = 1
click("Cull Selection", { jpeg1, jpeg2 })
check("cull, scorer fails: says so", printed("Assisted Culling: The scorer stopped with exit code 1")
    or printed("Assisted Culling: Failed. "), true)
check("cull, scorer fails: the panel line is cleared", status_label.label, "")
check("cull, scorer fails: the job bar is closed", jobs[1] and jobs[1].valid, false)
-- a crash: the log ends in a traceback, cut to its tail in the toast
PYTHON.log = "10:00:01 py: scoring: failed after 3s, peak memory 812 MB\nTraceback (most recent call last):\n  File \"score_images.py\", line 2063, in main\n"
    .. string.rep("    frame = load(path)  # padding past the toast's 300 characters\n", 6)
    .. "ValueError: cannot reshape array of size 0\n"
click("Cull Selection", { jpeg1, jpeg2 })
local cull_row
for i = 2, #panel[#panel - 1] do
    local row = panel[#panel - 1][i]
    if row.visible and row[1] and (row[1].text or ""):find("^Cull: ") then cull_row = row[1].text end
end
check("cull, scorer crashes: To check names the error, not a cut log tail", cull_row,
    "Cull: failed: ValueError: cannot reshape array of size 0 (see the log)")
PYTHON.log = nil
PYTHON.exit = 0

click("Cull Selection", { jpeg4 })
check("cull, all locked: explains", last_print():find("Every selected image is tagged Assisted Culling|Locked", 1, true) ~= nil, true)

-- a collapsed group: darktable reports only jpeg1 as selected, the act-on list also holds the hidden jpeg2
jpeg1.rating, jpeg2.rating = 0, 0
hidden_ids = { [jpeg2.id] = true }
selection_sets, rating_actions = 0, 0
click("Cull Selection", { jpeg1, jpeg2 })
check("cull, collapsed group: the hidden member is still selected at the end", #dt.gui.action_images, 2)
check("cull: both frames are rated", jpeg1.rating .. " " .. jpeg2.rating, "3 1")
check("cull: the selection is never changed", selection_sets, 0)
check("cull: darktable's rating action is never fired", rating_actions, 0)
hidden_ids = {}

-- darktable raises while the selection's Locked tag is read, before the scorer starts: the panel is not left busy
local real_find = dt.tags.find
dt.tags.find = function() error("tag list unavailable") end
click("Cull Selection", { jpeg1, jpeg2 })
dt.tags.find = real_find
check("cull, error before the run starts: says so and the button is back to its label",
    tostring(printed("Assisted Culling: Couldn't run. ")) .. "; " .. tostring(button(panel, "Cull Selection") ~= nil), "true; true")
jpeg1.rating = 0
if button(panel, "Cull Selection") then click("Cull Selection", { jpeg1, jpeg2 }) end
check("cull, error before the run starts: the next click starts a run", #PYTHON.runs .. " run, keeper rated " .. jpeg1.rating, "1 run, keeper rated 3")

-- darktable raises partway through a run, with progress on the panel line
jpeg1.rating, jpeg2.rating = 0, 0
on_sleep = function() if status_now ~= "" then error("darktable is closing") end end
click("Cull Selection", { jpeg1, jpeg2 })
on_sleep = nil
check("cull, error during the run: says so, the panel line is cleared and the button is back to its label",
    tostring(printed("Assisted Culling: Couldn't run. ")) .. "; '" .. status_label.label .. "'; "
    .. tostring(button(panel, "Cull Selection") ~= nil), "true; ''; true")

-- Cancelled partway with "Apply Ratings While Scoring": the scorer is still going, the job bar's X is clicked
-- once results are applied. The message names Restore Previous Ratings only when a rating was changed.
local while_scoring = find_widget(panel, "check_button", "Apply Ratings While Scoring")
while_scoring.value = true
while_scoring.clicked_callback(while_scoring)
PYTHON.hang = true
on_sleep = function() if #PYTHON.runs > 0 and jobs[1] and jobs[1].valid then jobs[1].valid = false end end
jpeg1.rating, jpeg2.rating = 5, 4
click("Cull Selection", { jpeg1, jpeg2 })
local cancelled_rated = last_print()
click("Cull Selection", { jpeg1, jpeg2 })
on_sleep = nil
PYTHON.hang = false
while_scoring.value = false
while_scoring.clicked_callback(while_scoring)
check("cull, cancelled while scoring: the message names the way to undo what was written", cancelled_rated .. " / " .. last_print(),
    "Assisted Culling: Cancelled. 2 of 2 images were already rated and keep their changes. Run again to finish, or use Clear Culling Marks to remove the tags and Restore Previous Ratings to put the star ratings back."
    .. " / Assisted Culling: Cancelled. 2 of 2 images were already rated and keep their changes. Run again to finish, or use Clear Culling Marks to remove the tags.")
check("cull, cancelled while scoring: no Lua error", lua_errors(), nil)

-- Bursts page: native groups and tag nodes ------------------------------------------
local native_check = find_widget(panel, "check_button", "Cull by Native Groups")
local node_entries = {}
local function collect_node_entries(widget)
    if widget.kind == "entry" and (widget.placeholder or ""):find("^tag node %d") then node_entries[#node_entries + 1] = widget end
    for _, child in ipairs(widget) do
        if type(child) == "table" then collect_node_entries(child) end
    end
end
collect_node_entries(panel)
local function bursts_page()
    local texts = {}
    for i, entry in ipairs(node_entries) do texts[i] = "[" .. entry.text .. "]" end
    return tostring(native_check and native_check.value) .. " " .. table.concat(texts, " ")
end
check("bursts page: native groups on and three blank tag node boxes by default", bursts_page(), "true [] [] []")

-- frames 11-14 are one darktable group, 15 is on its own
local grouped = { image(11, "DSC00011.JPG"), image(12, "DSC00012.JPG"), image(13, "DSC00013.JPG"), image(14, "DSC00014.JPG"),
    image(15, "DSC00015.JPG") }
for i = 2, 4 do grouped[i].group_leader = grouped[1] end
local function tag_frames(name, ...)
    for _, i in ipairs({ ... }) do dt.tags.attach(dt.tags.create(name), grouped[i]) end
end
tag_frames("Rally|2026|37", 1, 3, 5)
tag_frames("Rally|2026|86", 2)
tag_frames("Side|left", 1, 3)
tag_frames("Side|right", 5)
tag_frames("Assisted Grouping|2026-01-01 12:00:00|Group|0001", 4, 5)
local earlier_results = PYTHON.results
PYTHON.results = "11,0.90,,,1,3,\n12,0.40,,,0,1,\n13,0.40,,,0,1,\n14,0.40,,,0,1,\n15,0.40,,,0,1,\n"
-- Culls the five frames with the page set this way; each frame's group number, then ":" and
-- manifest column 10 when it is filled.
local function pools(native, node_1, node_2, node_3)
    native_check.value = native
    native_check.clicked_callback(native_check)
    node_entries[1].text, node_entries[2].text, node_entries[3].text = node_1, node_2, node_3
    click("Cull Selection", grouped)
    local out = {}
    for line in (PYTHON.runs[1] and PYTHON.runs[1].manifest or ""):gmatch("[^\r\n]+") do
        local fields = CULLING.parse_report_line(line)
        out[#out + 1] = fields[3] .. (fields[10] ~= "" and ":" .. fields[10] or "")
    end
    return table.concat(out, " ")
end
check("bursts page: native groups alone", pools(true, "", "", ""), "1 1 1 1 2")
check("bursts page: a tag node cuts the native groups, untagged frames share a pool, column 10 has the child",
    pools(true, " Rally|2026 ", "", ""), "1:37 2:86 1:37 3 4:37")
check("bursts page: a later node cuts further, children joined in column 10",
    pools(true, "", "Rally|2026", "Side"), "1:37/left 2:86 1:37/left 3 4:37/right")
check("bursts page: native off, node 1 forms the groups and a frame without its tag is alone",
    pools(false, "Rally|2026", "", ""), "1 2 1 3 1")
check("bursts page: native off, node 2 cuts node 1's groups",
    pools(false, "Rally|2026", "Side", ""), "1:left 2 1:left 3 4:right")
check("bursts page: native off, Assisted Grouping groups by each frame's latest run",
    pools(false, "Assisted Grouping", "", ""), "1 2 3 4 4")
check("bursts page: nothing set, every frame alone", pools(false, "", "", ""), "1 2 3 4 5")
check("bursts page: nothing set, the end message has no grouping notice", last_print(), "Assisted Culling: Done. 1 keepers, 4 not kept.")
check("bursts page: a node that matches no frame leaves every frame alone", pools(false, "No|Such", "", ""), "1 2 3 4 5")
check("bursts page: a node that matches no frame ends with the grouping notice", last_print(),
    "Assisted Culling: Done. 1 keepers, 4 not kept. No groups found: every frame judged alone (group first for keepers).")
check("timing line splits the progress updates into job bar, panel line and toast",
    (read_file(ROOT .. "/config/assisted_culling.log") or ""):find(
        "in progress updates %(job bar [%d.]+s, panel line [%d.]+s, toast [%d.]+s%); %d+ rating writes, %d+ Keeper / Rejected tag writes; final drain took") ~= nil, true)
check("tag writes are logged by tag",
    (read_file(ROOT .. "/config/assisted_culling.log") or ""):find(
        "apply: tag writes by tag %(%+ attached, %- detached%): ") ~= nil, true)
PYTHON.results = earlier_results

-- the old dropdown preset is upgraded when it is picked, shown on the page and saved back
local preset_picker = combo(panel, "Preset")
local function pick_preset(name)
    for i, entry in ipairs(preset_picker) do
        if entry == name then preset_picker.selected, preset_picker.value = i, name end
    end
    preset_picker.changed_callback(preset_picker)
end
pools(true, "", "", "")
pick_preset("dropdown")
check("bursts page: an old tags preset shows native off, the latest grouping run, then the car node",
    bursts_page(), "false [Assisted Grouping] [Rally|2026] []")
check("bursts page: the upgraded preset is saved back in today's keys",
    tostring((read_file(DROPDOWN_PRESET) or ""):find('"group_tag_2": "Rally|2026"', 1, true) ~= nil) .. " "
    .. tostring((read_file(DROPDOWN_PRESET) or ""):find("group_support", 1, true)), "true nil")
check("bursts page: the upgrade is logged", (read_file(ROOT .. "/config/assisted_culling.log") or ""):find(
    "preset dropdown: group_native, group_tag_1, group_tag_2 filled from the old preset's settings", 1, true) ~= nil, true)
node_entries[3].text = " Side "
local preset_actions = combo(panel, "Actions")
for i, entry in ipairs(preset_actions) do
    if entry == 'update preset "dropdown"' then preset_actions.selected = i end
end
preset_actions.changed_callback(preset_actions)
check("bursts page: updating the preset saves the typed node, trimmed",
    (read_file(DROPDOWN_PRESET) or ""):find('"group_tag_3": "Side"', 1, true) ~= nil, true)
pick_preset("template")
check("bursts page: the template puts the defaults back", bursts_page(), "true [] [] []")
check("bursts page: no Lua error", lua_errors(), nil)

-- Clear Culling Marks ---------------------------------------------------------------
click("Clear Culling Marks", {})
check("clear, nothing selected: asks for a selection", last_print(), "Assisted Culling: Select some images first.")

click("Clear Culling Marks", { jpeg1, jpeg2, jpeg3 })
check("clear: says it started", prints[1], "Assisted Culling: Clearing marks on 3 images…")
check("clear: progress goes to the panel line", status_shown("clearing marks 3 / 3"), true)
check("clear: the panel line is cleared at the end", status_label.label, "")
check("clear: the keeper tag is gone", has_tag(jpeg1, "Assisted Culling|Keeper"), false)
check("clear: no culling tags left", #jpeg1.tags + #jpeg2.tags, 0)
check("clear: the end message", last_print(),
    "Assisted Culling: Removed culling tags from 1 of 3 images. Star ratings were not changed.")
check("clear: the hinter is never used", hinter_calls, 0)
check("clear: one job bar, closed at the end", #jobs .. " " .. tostring(jobs[1] and jobs[1].valid), "1 false")
check("clear: the log has the timing line",
    (read_file(ROOT .. "/config/assisted_culling.log") or ""):find(
        "clear: timing: 3 of 3 images in %d+s; [%d.]+s in tag writes, [%d.]+s waiting for darktable, [%d.]+s paused; %d+ tag writes\n") ~= nil, true)
check("clear: no Lua error", lua_errors(), nil)

dt.tags.attach(dt.tags.create("Assisted Culling|Keeper"), jpeg1)
selection_sets = 0
click("Clear Culling Marks", { jpeg1, jpeg2 })
check("clear: the selection is never changed", selection_sets, 0)

-- an image with tags ends its slice, so the job bar's x stops the run after it
local keeper_tag = dt.tags.create("Assisted Culling|Keeper")
dt.tags.attach(keeper_tag, jpeg1)
dt.tags.attach(keeper_tag, jpeg2)
on_sleep = function() if jobs[1] and jobs[1].valid then jobs[1].valid = false end end
click("Clear Culling Marks", { jpeg1, jpeg2, jpeg3 })
on_sleep = nil
check("clear, cancelled: the first image is cleared, the next keeps its tag",
    tostring(has_tag(jpeg1, "Assisted Culling|Keeper")) .. " " .. tostring(has_tag(jpeg2, "Assisted Culling|Keeper")), "false true")
check("clear, cancelled: the message counts both", last_print(),
    "Assisted Culling: Clear cancelled. Removed culling tags from 1 of 3 images; 2 not reached keep their tags.")
check("clear, cancelled: the panel line is cleared", status_label.label, "")

-- To check: the photos the cancelled clear didn't reach
local to_check = panel[#panel - 1]
check("To check sits above the progress line, outside the folding pages",
    type(to_check) == "table" and to_check[1] and to_check[1][2] and to_check[1][2].label, "To Check")
to_check = type(to_check) == "table" and to_check[1] and to_check[1][2] and to_check[1][2].label == "To Check" and to_check or { {}, {} }
local CHECKS_FILE = ROOT .. "/config/assisted_culling.checks.txt"
-- the row of the clear's item: an earlier Cull run's items stay above it
local function clear_row()
    for i = 2, #to_check do
        local row = to_check[i]
        if row.visible and row[1] and (row[1].text or ""):find("^Clear: ") then return row end
    end
    return { {}, {} }
end
check("To check: the cancelled clear shows in the box", to_check.visible, true)
check("To check: no ratings back, the line names no log fragment",
    (read_file(CHECKS_FILE) or ""):find("Cull\tno ratings came back from the scorer (see the log)\t\t\t\t", 1, true) ~= nil, true)
check("To check: the row names the action and the count",
    (clear_row()[1].text or ""):gsub("\n", " "), "Clear: Clear cancelled: 2 images not reached keep their tags.")
check("To check: the item is saved for a restart",
    (read_file(CHECKS_FILE) or ""):find("Clear\tClear cancelled: 2 images not reached keep their tags.\t2,3\t", 1, true) ~= nil, true)
selection_sets = 0
;(button(clear_row(), "Select") or { clicked_callback = function() end }).clicked_callback()
check("To check: Select selects the images not reached", selection_sets .. " " .. #dt.gui.action_images, "1 2")
selection_sets = 0
click("Clear Culling Marks", { jpeg2 })
check("clear, after a cancel: the next clear runs", has_tag(jpeg2, "Assisted Culling|Keeper"), false)
check("To check: the next clear replaces its items", (read_file(CHECKS_FILE) or ""):find("Clear\t", 1, true), nil)
check("To check: the clear's row is gone", clear_row()[1].text, nil)
dt.tags.attach(keeper_tag, jpeg1)
dt.tags.attach(keeper_tag, jpeg2)
on_sleep = function() if jobs[1] and jobs[1].valid then jobs[1].valid = false end end
click("Clear Culling Marks", { jpeg1, jpeg2, jpeg3 })
on_sleep = nil
check("To check: a second cancelled clear fills the box again", clear_row()[1].text ~= nil, true)
;(button(to_check, "Clear List") or { clicked_callback = function() end }).clicked_callback()
check("To check: Clear empties the box", to_check.visible, false)
check("To check: Clear empties the saved list", read_file(CHECKS_FILE), "")
click("Clear Culling Marks", { jpeg2 })

-- Restore Previous Ratings ----------------------------------------------------------
local PREVIOUS_RATINGS = ROOT .. "/config/assisted_culling.previous-ratings.csv"
click("Restore Previous Ratings", {})
check("restore, nothing selected: asks for a selection", last_print(), "Assisted Culling: Select some images first.")

os.remove(PREVIOUS_RATINGS)
click("Restore Previous Ratings", { jpeg1, jpeg2 })
check("restore, no run yet: says so", last_print(),
    "Assisted Culling: No run has changed a rating yet, so there is nothing to restore.")

jpeg1.rating, jpeg2.rating, jpeg3.rating = 5, 4, 2
click("Cull Selection", { jpeg1, jpeg2, jpeg3 })
check("restore: the run rated both scored frames", jpeg1.rating .. " " .. jpeg2.rating .. " " .. jpeg3.rating, "3 1 2")
check("restore: the run saved the rating each frame had", read_file(PREVIOUS_RATINGS),
    "1,5,3,/images/DSC00001.JPG\n2,4,1,/images/DSC00002.JPG\n")

-- a run that changes no rating keeps the file of the run before it
click("Cull Selection", { jpeg1, jpeg2, jpeg3 })
check("restore: a run that changes no rating keeps the saved ratings", read_file(PREVIOUS_RATINGS),
    "1,5,3,/images/DSC00001.JPG\n2,4,1,/images/DSC00002.JPG\n")

jpeg2.rating = 2
selection_sets = 0
click("Restore Previous Ratings", { jpeg1, jpeg2, jpeg3 })
check("restore: the frame the run rated is back", jpeg1.rating, 5)
check("restore: a frame rated since the run is left alone", jpeg2.rating, 2)
check("restore: a frame the run did not rate is left alone", jpeg3.rating, 2)
check("restore: progress goes to the panel line", status_shown("restoring ratings 3 / 3"), true)
check("restore: the panel line is cleared at the end", status_label.label, "")
check("restore: the selection is never changed", selection_sets, 0)
check("restore: tags are kept", has_tag(jpeg1, "Assisted Culling|Keeper"), true)
check("restore: the end message", last_print(),
    "Assisted Culling: Restored the previous rating of 1 of 3 images, 1 rated since the run left alone. Tags were not changed.")

click("Restore Previous Ratings", { jpeg1 })
check("restore, twice: the second click changes nothing", jpeg1.rating .. "; " .. last_print(),
    "5; Assisted Culling: Restored the previous rating of 0 of 1 images, 1 rated since the run left alone. Tags were not changed.")

-- another file with the same image id (a different library) is not touched
write_file(PREVIOUS_RATINGS, "1,0,5,/elsewhere/DSC00001.JPG\n")
click("Restore Previous Ratings", { jpeg1 })
check("restore, another library's file: left alone", jpeg1.rating, 5)

-- a file name with a comma and a line break still matches its saved line
local odd = image(5, "DSC,5\n.JPG")
odd.rating = 4
PYTHON.results = "5,0.90,,,1,3,\n"
click("Cull Selection", { odd })
click("Restore Previous Ratings", { odd })
check("restore, comma and line break in the file name: the frame is back", odd.rating, 4)

-- an image removed from the library since the click raises when read: the rest are still restored
jpeg1.rating, jpeg2.rating = 5, 4
PYTHON.results = "1,0.90,,,1,3,\n2,0.40,,,0,1,\n"
click("Cull Selection", { jpeg1, jpeg2 })
local removed = setmetatable({}, { __index = function() error("image no longer in the library") end })
click("Restore Previous Ratings", { jpeg1, removed, jpeg2 })
check("restore, an image removed from the library: the others are back", jpeg1.rating .. " " .. jpeg2.rating .. "; " .. last_print(),
    "5 4; Assisted Culling: Restored the previous rating of 2 of 3 images, 1 couldn't be updated. Tags were not changed.")
check("restore: no Lua error", lua_errors(), nil)

-- Reject mode: a frame that is no longer a keeper loses the stars a run wrote, not the user's own
local non_keeper_combo = combo(panel, "Non-Keepers")
non_keeper_combo.selected = 2 -- reject
non_keeper_combo.changed_callback(non_keeper_combo)
os.remove(PREVIOUS_RATINGS)
local was_kept, kept_twice, hand_rated, rerated = image(11, "DSC00011.JPG"), image(12, "DSC00012.JPG"),
    image(13, "DSC00013.JPG"), image(14, "DSC00014.JPG")
was_kept.rating, hand_rated.rating = 4, 2
PYTHON.results = "11,0.90,,,1,3,\n12,0.90,,,1,5,\n13,0.40,,,0,leave,\n14,0.90,,,1,3,\n"
click("Cull Selection", { was_kept, kept_twice, hand_rated, rerated })
rerated.rating = 4
PYTHON.results = "11,0.40,,,0,leave,\n12,0.90,,,1,2,\n13,0.40,,,0,leave,\n14,0.40,,,0,leave,\n"
click("Cull Selection", { was_kept, kept_twice, hand_rated, rerated })
check("reject mode, keeper dropped: the run's stars go to 0, hand ratings stay",
    was_kept.rating .. " " .. kept_twice.rating .. " " .. hand_rated.rating .. " " .. rerated.rating, "0 2 2 4")
check("reject mode: the log counts the frames set to 0",
    (read_file(ROOT .. "/config/assisted_culling.log") or ""):find("apply: 1 non-keepers set to 0", 1, true) ~= nil, true)
check("reject mode: the saved ratings keep the rating from before the first run", read_file(PREVIOUS_RATINGS),
    "11,4,0,/images/DSC00011.JPG\n12,0,2,/images/DSC00012.JPG\n14,0,3,/images/DSC00014.JPG\n")
click("Restore Previous Ratings", { was_kept, kept_twice, hand_rated, rerated })
check("reject mode, restore after two runs: back to the ratings from before the first",
    was_kept.rating .. " " .. kept_twice.rating .. " " .. hand_rated.rating .. " " .. rerated.rating, "4 0 2 4")
non_keeper_combo.selected = 1 -- leave
non_keeper_combo.changed_callback(non_keeper_combo)
check("reject mode: no Lua error", lua_errors(), nil)

-- Verify Selection ----------------------------------------------------------------------
-- 21 still matches its cull, 22 was rated by hand since, 23 was never culled, 24 lost its Keeper tag
local matching, hand_changed, never_culled, untagged = image(21, "DSC00021.JPG"), image(22, "DSC00022.JPG"),
    image(23, "DSC00023.JPG"), image(24, "DSC00024.JPG")
local verify_set = { matching, hand_changed, never_culled, untagged }
PYTHON.results = "21,0.90,,,1,3,\n22,0.90,,,1,4,\n24,0.90,,,1,2,\n"
click("Cull Selection", { matching, hand_changed, untagged })
hand_changed.rating = 1
dt.tags.detach(keeper_tag, untagged)
local REPORT = ROOT .. "/config/assisted_culling/last-run.csv"
write_file(REPORT, "the last cull's report\n")
local ratings_file = read_file(PREVIOUS_RATINGS)
local function verify_row(text)
    for i = 2, #to_check do
        local row = to_check[i]
        if row.visible and row[1] and (row[1].text or ""):gsub("\n", " "):find(text, 1, true) then return row end
    end
    return { {}, {}, { {}, {} } }
end
PYTHON.results = "21,0.90,,,1,3,\n22,0.90,,,1,4,\n23,0.90,,,1,5,\n24,0.90,,,1,2,\n"
click("Verify Selection", verify_set)
check("verify: says it started", printed("Assisted Culling: Verify started on 4 images…"), true)
check("verify: the scorer is not asked for a report", #PYTHON.runs .. " "
    .. tostring(table.concat((PYTHON.runs[1] or { argv = {} }).argv, " "):find("--report", 1, true)), "1 nil")
check("verify: no rating and no Keeper tag is written",
    matching.rating .. " " .. hand_changed.rating .. " " .. never_culled.rating .. " " .. untagged.rating .. " "
    .. tostring(has_tag(never_culled, "Assisted Culling|Keeper")) .. " " .. tostring(has_tag(untagged, "Assisted Culling|Keeper")),
    "3 1 0 2 false false")
check("verify: the last cull's report and saved ratings are kept", read_file(REPORT) .. tostring(read_file(PREVIOUS_RATINGS) == ratings_file),
    "the last cull's report\ntrue")
check("verify: the toast counts what differs", last_print(),
    "Assisted Culling: Verify only, nothing changed. 1 of 4 images would get other stars from a cull now, 1 ratings were changed by hand, 2 bursts have the wrong Keeper tags. See To check.")
local differ = verify_row("images would get other stars")
check("verify: one row for the images a cull would rate differently, with Fix",
    (differ[1].text or ""):gsub("\n", " ") .. "; " .. tostring(differ[2].text):gsub("\n%s*", " ") .. "; " .. tostring(differ[3][2].visible),
    "Verify: 1 images would get other stars from a cull now; Fix culls their 1 bursts (1 images).; • DSC00023.JPG: 0 stars, a cull now gives 5; true")
local by_hand = verify_row("You changed")
check("verify: ratings changed by hand get their own row, with no Fix",
    tostring(by_hand[2].text):gsub("\n%s*", " ") .. "; " .. tostring(by_hand[3][1].visible) .. " " .. tostring(by_hand[3][2].visible),
    "• DSC00022.JPG: 1 stars, the last cull wrote 4; true false")
check("verify: the Keeper row lists the bursts' images, Fix = cull",
    (read_file(CHECKS_FILE) or ""):find("Verify\t2 bursts have no Keeper tag or more than a cull gives; Fix culls them (2 images).\t23,24\tcull\t", 1, true) ~= nil, true)
;(button(verify_row("bursts have no Keeper tag"), "Fix") or { clicked_callback = function() end }).clicked_callback()
check("verify, Fix: Cull Selection ran on those bursts only",
    never_culled.rating .. " " .. tostring(has_tag(untagged, "Assisted Culling|Keeper")) .. " " .. hand_changed.rating, "5 true 1")
click("Verify Selection", verify_set)
check("verify again, after Fix: only the hand-changed rating is left", last_print(),
    "Assisted Culling: Verify only, nothing changed. 0 of 4 images would get other stars from a cull now, 1 ratings were changed by hand, 0 bursts have the wrong Keeper tags. See To check.")
check("verify again: the Keeper row is gone", verify_row("bursts have no Keeper tag")[1].text, nil)
check("verify: no Lua error", lua_errors(), nil)

-- Detail tags --------------------------------------------------------------------------
-- Ratings and Keeper / Rejected are written first; the Why and flag tags follow under their own job bar.
local detail1, detail2, detail3 = image(201, "DSC00201.JPG"), image(202, "DSC00202.JPG"), image(203, "DSC00203.JPG")
PYTHON.results = "201,0.90,cut_off,,1,3,Why|Keeper\n202,0.40,,,0,1,Why|Far behind\n203,0.30,,,0,1,Why|Far behind\n"
attached_names, creates_by_name = {}, {}
click("Cull Selection", { detail1, detail2, detail3 })
check("detail tags: a tag attached to two images is looked up once in the run",
    creates_by_name["Assisted Culling|Rejected"] .. " " .. creates_by_name["Assisted Culling|Why|Far behind"], "1 1")
check("detail tags: every Keeper / Rejected tag is attached before the first detail tag", table.concat(attached_names, ", "),
    "Assisted Culling|Keeper, Assisted Culling|Rejected, Assisted Culling|Rejected, Assisted Culling|Why|Keeper,"
    .. " Assisted Culling|Cut Off, Assisted Culling|Why|Far behind, Assisted Culling|Why|Far behind")
check("detail tags: a second job bar, both closed at the end",
    #jobs .. " " .. tostring(jobs[2] and jobs[2].title) .. " " .. tostring(jobs[1].valid) .. " " .. tostring(jobs[2] and jobs[2].valid),
    "2 Assisted Culling: Writing detail tags false false")
check("detail tags: the end message says the ratings are ready and how many tags follow",
    printed("Assisted Culling: Done. 1 keepers, 2 not kept (2 rejected), 1 cut off. No groups found: every frame judged alone (group first for keepers). Ratings are ready. Now writing 4 detail tags; the job bar's x stops them."), true)
check("detail tags: progress goes to the panel line", status_shown("writing detail tags: image 3 / 3"), true)
check("detail tags: the panel line is cleared at the end", status_label.label, "")
check("detail tags: the last message counts them", last_print(), "Assisted Culling: Detail tags written (4).")
local detail_log = read_file(ROOT .. "/config/assisted_culling.log") or ""
check("detail tags: the log has the stage's line",
    detail_log:find("apply: detail tags: 4 of 4 tag writes on 3 of 3 images in %d+s %(waited [%d.]+s for darktable, paused [%d.]+s%)\n") ~= nil, true)
check("detail tags: the timing line counts only the Keeper / Rejected tags", detail_log:find("3 Keeper / Rejected tag writes", 1, true) ~= nil, true)
check("detail tags: the tally has them", detail_log:find("2 +Assisted Culling|Why|Far behind", 1, true) ~= nil, true)

click("Cull Selection", { detail1, detail2, detail3 })
check("detail tags, same images again: nothing to write, no second job bar", #jobs .. " " .. last_print(),
    "1 Assisted Culling: Done. 1 keepers, 2 not kept (2 rejected), 1 cut off. No groups found: every frame judged alone (group first for keepers).")

-- the detail job bar's x after the first image: ratings and Keeper / Rejected are complete, the rest wait for a rerun
local detail4, detail5, detail6 = image(204, "DSC00204.JPG"), image(205, "DSC00205.JPG"), image(206, "DSC00206.JPG")
PYTHON.results = "204,0.90,,,1,3,Why|Keeper\n205,0.40,,,0,1,Why|Outranked\n206,0.30,,,0,-1,Why|Far behind\n"
on_sleep = function() if jobs[2] and jobs[2].valid then jobs[2].valid = false end end
click("Cull Selection", { detail4, detail5, detail6 })
on_sleep = nil
check("detail tags, stopped: the first image has its tag, an outranked frame has its rating and no Rejected tag, the far-behind frame has Rejected",
    tostring(has_tag(detail4, "Assisted Culling|Why|Keeper")) .. " " .. tostring(has_tag(detail5, "Assisted Culling|Why|Outranked"))
    .. " " .. detail5.rating .. " " .. tostring(has_tag(detail5, "Assisted Culling|Rejected")) .. " " .. tostring(has_tag(detail6, "Assisted Culling|Rejected")),
    "true false 1 false true")
check("detail tags, stopped: the message says what is left", last_print(),
    "Assisted Culling: Detail tags stopped. 2 images still miss theirs; ratings and Keeper / Rejected are complete. Cull the same images again to write the rest.")
check("detail tags, stopped: the panel line is cleared", status_label.label, "")
click("Cull Selection", { detail4, detail5, detail6 })
check("detail tags, culled again after a stop: the rest are written",
    tostring(has_tag(detail5, "Assisted Culling|Why|Outranked")) .. " " .. tostring(has_tag(detail6, "Assisted Culling|Why|Far behind")) .. " " .. last_print(),
    "true true Assisted Culling: Detail tags written (2).")
check("detail tags: no Lua error", lua_errors(), nil)

-- Reset Ratings to 0 ------------------------------------------------------------------
click("Reset Ratings to 0", {})
check("reset, nothing selected: asks for a selection", last_print(), "Assisted Culling: Select some images first.")
check("reset, nothing selected: no job bar", #jobs, 0)

jpeg1.rating, jpeg2.rating, jpeg3.rating = 5, -1, 0
selection_sets = 0
click("Reset Ratings to 0", { jpeg1, jpeg2, jpeg3 })
check("reset: every frame is at 0 stars, the rejected one too", jpeg1.rating .. " " .. jpeg2.rating .. " " .. jpeg3.rating, "0 0 0")
check("reset: progress goes to the panel line", status_shown("resetting ratings 3 / 3"), true)
check("reset: the panel line is cleared at the end", status_label.label, "")
check("reset: one job bar, closed at the end", #jobs .. " " .. tostring(jobs[1] and jobs[1].valid), "1 false")
check("reset: the selection is never changed", selection_sets, 0)
check("reset: tags are kept", has_tag(jpeg1, "Assisted Culling|Keeper"), true)
check("reset: the end message", last_print(),
    "Assisted Culling: Set 2 of 3 images to 0 stars, 1 already at 0. Tags were not changed.")

-- the job bar's x during the first slice: the frames not reached keep their rating
local many = {}
for n = 1, 30 do
    many[n] = image(100 + n, string.format("DSC%05d.JPG", 100 + n))
    many[n].rating = 3
end
on_sleep = function() if jobs[1] and jobs[1].valid then jobs[1].valid = false end end
click("Reset Ratings to 0", many)
on_sleep = nil
check("reset, cancelled: the first slice is at 0, the rest keep their rating",
    many[1].rating .. " " .. many[12].rating .. " " .. many[13].rating .. " " .. many[30].rating, "0 0 3 3")
check("reset, cancelled: the message counts both", last_print(),
    "Assisted Culling: Reset cancelled. 12 of 30 images were set to 0 stars; 18 not reached keep their rating.")
check("reset, cancelled: the panel line is cleared", status_label.label, "")

click("Reset Ratings to 0", { many[13] })
check("reset, after a cancel: the next reset runs, the panel isn't left busy", many[13].rating, 0)

jpeg1.rating, jpeg2.rating = 5, 4
click("Reset Ratings to 0", { jpeg1, removed, jpeg2 })
check("reset, an image removed from the library: the others are at 0", jpeg1.rating .. " " .. jpeg2.rating .. "; " .. last_print(),
    "0 0; Assisted Culling: Set 2 of 3 images to 0 stars, 1 couldn't be updated. Tags were not changed.")
check("reset: no Lua error", lua_errors(), nil)
check("no job bar is closed twice", double_closes, 0)

local placed, twice = {}, {}
local function walk_widgets(widget)
    if type(widget) ~= "table" or not widget.kind then return end
    if placed[widget] then twice[#twice + 1] = tostring(widget.label or widget.kind) end
    placed[widget] = true
    for _, child in ipairs(widget) do walk_widgets(child) end
end
walk_widgets(panel)
check("no widget is placed twice in the panel", table.concat(twice, ", "), "")
-- the box below the page button titled `title` (C.paged_sections: button, body, button, body…)
local function page_body(widget, title)
    if type(widget) ~= "table" then return nil end
    for i, child in ipairs(widget) do
        if type(child) == "table" and child.kind == "button" and type(child.label) == "string"
            and child.label:match("^%d+  " .. title .. " ") then return widget[i + 1] end
        local found = page_body(child, title)
        if found then return found end
    end
    return nil
end
-- every button under `box`, nested boxes included, in panel order
local function button_labels(box, out)
    out = out or {}
    for _, w in ipairs(box or {}) do
        if type(w) == "table" and w.kind == "button" then out[#out + 1] = w.label
        elseif type(w) == "table" then button_labels(w, out) end
    end
    return table.concat(out, ", ")
end
check("Run page: model runs only, main button first",
    button_labels(page_body(panel, "Run")), "Cull Selection, Verify Selection")
check("Tools page: explain, then Undo",
    button_labels(page_body(panel, "Tools")),
    "Why These Ratings?, Open Last Report, Clear Culling Marks, Restore Previous Ratings, Reset Ratings to 0")

os.execute = real_execute
real_execute(WINDOWS and ('rmdir /s /q "' .. ROOT:gsub("/", "\\") .. '"') or ("rm -rf '" .. ROOT .. "'"))

if failures > 0 then
    print(failures .. " FAILED")
    os.exit(1)
end
print("all passed")
