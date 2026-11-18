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
            if not tags_by_name[name] then
                tags_by_name[name] = { name = name }
                tag_list[#tag_list + 1] = tags_by_name[name]
            end
            return tags_by_name[name]
        end,
        attach = function(tag, img)
            selected_at_attach[#selected_at_attach + 1] = #dt.gui.action_images
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
    local img = { id = id, filename = filename, path = "/photos", rating = 0, tags = {} }
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

-- Cull selection --------------------------------------------------------------------
click("Cull selection", {})
check("cull, nothing selected: asks for a selection", last_print(), "Assisted Culling: select some images first")
check("cull, nothing selected: no job bar", #jobs, 0)
check("cull, nothing selected: the scorer is not started", #PYTHON.runs, 0)

selected_at_attach = {}
click("Cull selection", all)
check("cull: tags were attached", #selected_at_attach > 0, true)
check("cull: the selection stays while tags are attached", math.min(table.unpack(selected_at_attach)), #all)
check("cull: the selection is the same at the end", #dt.gui.action_images, #all)
check("cull: says it started as soon as it is clicked", prints[1], "Assisted Culling: started on 3 images…")
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
check("cull: the end message", last_print(), "Assisted Culling: done. 1 keepers, 1 not kept."
    .. " Left out: 1 unreadable; 1 locked (see log)."
    .. " No groups found: every frame judged alone (group first for keepers).")
check("cull: the button is back to its label", button(panel, "Cull selection") ~= nil, true)
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
local ARGUMENT_CHECKS = { "Leave frames with no vehicle", "Spread keepers over the burst",
    "Break close calls on the number read", "Break close calls with the sharpness judge" }
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
local sharp_combo = combo(panel, "sharpness")
sharp_combo.selected = 7 -- motorsport (subject & motion)
sharp_combo.changed_callback(sharp_combo)
jpeg1.rating, jpeg2.rating = 0, 0
click("Cull selection", { jpeg1, jpeg2 })
check("cull, detector installed: the scorer ran once", #PYTHON.runs, 1)
local detector_run = PYTHON.runs[1] or { argv = {} }
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
click("Cull selection", { jpeg1, jpeg2 })
check("cull, subject tracking: the scorer ran twice", #PYTHON.runs, 2)
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
click("Cull selection", { jpeg1, jpeg2 })
check("cull, scorer fails: says so", printed("Assisted Culling: the scorer stopped with exit code 1")
    or printed("Assisted Culling: failed. "), true)
check("cull, scorer fails: the panel line is cleared", status_label.label, "")
check("cull, scorer fails: the job bar is closed", jobs[1] and jobs[1].valid, false)
PYTHON.exit = 0

click("Cull selection", { jpeg4 })
check("cull, all locked: explains", last_print():find("every selected image is tagged Assisted Culling|Locked", 1, true) ~= nil, true)

-- a collapsed group: darktable reports only jpeg1 as selected, the act-on list also holds the hidden jpeg2
jpeg1.rating, jpeg2.rating = 0, 0
hidden_ids = { [jpeg2.id] = true }
selection_sets, rating_actions = 0, 0
click("Cull selection", { jpeg1, jpeg2 })
check("cull, collapsed group: the hidden member is still selected at the end", #dt.gui.action_images, 2)
check("cull: both frames are rated", jpeg1.rating .. " " .. jpeg2.rating, "3 1")
check("cull: the selection is never changed", selection_sets, 0)
check("cull: darktable's rating action is never fired", rating_actions, 0)
hidden_ids = {}

-- darktable raises while the selection's Locked tag is read, before the scorer starts: the panel is not left busy
local real_find = dt.tags.find
dt.tags.find = function() error("tag list unavailable") end
click("Cull selection", { jpeg1, jpeg2 })
dt.tags.find = real_find
check("cull, error before the run starts: says so and the button is back to its label",
    tostring(printed("Assisted Culling: couldn't run. ")) .. "; " .. tostring(button(panel, "Cull selection") ~= nil), "true; true")
jpeg1.rating = 0
if button(panel, "Cull selection") then click("Cull selection", { jpeg1, jpeg2 }) end
check("cull, error before the run starts: the next click starts a run", #PYTHON.runs .. " run, keeper rated " .. jpeg1.rating, "1 run, keeper rated 3")

-- darktable raises partway through a run, with progress on the panel line
jpeg1.rating, jpeg2.rating = 0, 0
on_sleep = function() if status_now ~= "" then error("darktable is closing") end end
click("Cull selection", { jpeg1, jpeg2 })
on_sleep = nil
check("cull, error during the run: says so, the panel line is cleared and the button is back to its label",
    tostring(printed("Assisted Culling: couldn't run. ")) .. "; '" .. status_label.label .. "'; "
    .. tostring(button(panel, "Cull selection") ~= nil), "true; ''; true")

-- Cancelled partway with "Apply ratings while scoring": the scorer is still going, the job bar's X is clicked
-- once results are applied. The message names Restore previous ratings only when a rating was changed.
local while_scoring = find_widget(panel, "check_button", "Apply ratings while scoring")
while_scoring.value = true
while_scoring.clicked_callback(while_scoring)
PYTHON.hang = true
on_sleep = function() if #PYTHON.runs > 0 and jobs[1] and jobs[1].valid then jobs[1].valid = false end end
jpeg1.rating, jpeg2.rating = 5, 4
click("Cull selection", { jpeg1, jpeg2 })
local cancelled_rated = last_print()
click("Cull selection", { jpeg1, jpeg2 })
on_sleep = nil
PYTHON.hang = false
while_scoring.value = false
while_scoring.clicked_callback(while_scoring)
check("cull, cancelled while scoring: the message names the way to undo what was written", cancelled_rated .. " / " .. last_print(),
    "Assisted Culling: cancelled. 2 of 2 images were already rated and keep their changes. Run again to finish, or use Clear culling marks to remove the tags and Restore previous ratings to put the star ratings back."
    .. " / Assisted Culling: cancelled. 2 of 2 images were already rated and keep their changes. Run again to finish, or use Clear culling marks to remove the tags.")
check("cull, cancelled while scoring: no Lua error", lua_errors(), nil)

-- Bursts page: native groups and tag nodes ------------------------------------------
local native_check = find_widget(panel, "check_button", "Cull by native groups")
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
    click("Cull selection", grouped)
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
check("bursts page: nothing set, the end message has no grouping notice", last_print(), "Assisted Culling: done. 1 keepers, 4 not kept.")
check("bursts page: a node that matches no frame leaves every frame alone", pools(false, "No|Such", "", ""), "1 2 3 4 5")
check("bursts page: a node that matches no frame ends with the grouping notice", last_print(),
    "Assisted Culling: done. 1 keepers, 4 not kept. No groups found: every frame judged alone (group first for keepers).")
PYTHON.results = earlier_results

-- the old dropdown preset is upgraded when it is picked, shown on the page and saved back
local preset_picker = combo(panel, "preset")
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
local preset_actions = combo(panel, "actions")
for i, entry in ipairs(preset_actions) do
    if entry == 'update preset "dropdown"' then preset_actions.selected = i end
end
preset_actions.changed_callback(preset_actions)
check("bursts page: updating the preset saves the typed node, trimmed",
    (read_file(DROPDOWN_PRESET) or ""):find('"group_tag_3": "Side"', 1, true) ~= nil, true)
pick_preset("template")
check("bursts page: the template puts the defaults back", bursts_page(), "true [] [] []")
check("bursts page: no Lua error", lua_errors(), nil)

-- Clear culling marks ---------------------------------------------------------------
click("Clear culling marks", {})
check("clear, nothing selected: asks for a selection", last_print(), "Assisted Culling: select some images first")

click("Clear culling marks", { jpeg1, jpeg2, jpeg3 })
check("clear: says it started", prints[1], "Assisted Culling: clearing marks on 3 images…")
check("clear: progress goes to the panel line", status_shown("clearing marks 3 / 3"), true)
check("clear: the panel line is cleared at the end", status_label.label, "")
check("clear: the keeper tag is gone", has_tag(jpeg1, "Assisted Culling|Keeper"), false)
check("clear: no culling tags left", #jpeg1.tags + #jpeg2.tags, 0)
check("clear: the end message", last_print(),
    "Assisted Culling: removed culling tags from 2 of 3 images. Star ratings were not changed.")
check("clear: the hinter is never used", hinter_calls, 0)
check("clear: no Lua error", lua_errors(), nil)

dt.tags.attach(dt.tags.create("Assisted Culling|Keeper"), jpeg1)
selection_sets = 0
click("Clear culling marks", { jpeg1, jpeg2 })
check("clear: the selection is never changed", selection_sets, 0)

-- Restore previous ratings ----------------------------------------------------------
local PREVIOUS_RATINGS = ROOT .. "/config/assisted_culling.previous-ratings.csv"
click("Restore previous ratings", {})
check("restore, nothing selected: asks for a selection", last_print(), "Assisted Culling: select some images first")

os.remove(PREVIOUS_RATINGS)
click("Restore previous ratings", { jpeg1, jpeg2 })
check("restore, no run yet: says so", last_print(),
    "Assisted Culling: no run has changed a rating yet, so there is nothing to restore.")

jpeg1.rating, jpeg2.rating, jpeg3.rating = 5, 4, 2
click("Cull selection", { jpeg1, jpeg2, jpeg3 })
check("restore: the run rated both scored frames", jpeg1.rating .. " " .. jpeg2.rating .. " " .. jpeg3.rating, "3 1 2")
check("restore: the run saved the rating each frame had", read_file(PREVIOUS_RATINGS),
    "1,5,3,/photos/DSC00001.JPG\n2,4,1,/photos/DSC00002.JPG\n")

-- a run that changes no rating keeps the file of the run before it
click("Cull selection", { jpeg1, jpeg2, jpeg3 })
check("restore: a run that changes no rating keeps the saved ratings", read_file(PREVIOUS_RATINGS),
    "1,5,3,/photos/DSC00001.JPG\n2,4,1,/photos/DSC00002.JPG\n")

jpeg2.rating = 2
selection_sets = 0
click("Restore previous ratings", { jpeg1, jpeg2, jpeg3 })
check("restore: the frame the run rated is back", jpeg1.rating, 5)
check("restore: a frame rated since the run is left alone", jpeg2.rating, 2)
check("restore: a frame the run did not rate is left alone", jpeg3.rating, 2)
check("restore: progress goes to the panel line", status_shown("restoring ratings 3 / 3"), true)
check("restore: the panel line is cleared at the end", status_label.label, "")
check("restore: the selection is never changed", selection_sets, 0)
check("restore: tags are kept", has_tag(jpeg1, "Assisted Culling|Keeper"), true)
check("restore: the end message", last_print(),
    "Assisted Culling: restored the previous rating of 1 of 3 images, 1 rated since the run left alone. Tags were not changed.")

click("Restore previous ratings", { jpeg1 })
check("restore, twice: the second click changes nothing", jpeg1.rating .. "; " .. last_print(),
    "5; Assisted Culling: restored the previous rating of 0 of 1 images, 1 rated since the run left alone. Tags were not changed.")

-- another file with the same image id (a different library) is not touched
write_file(PREVIOUS_RATINGS, "1,0,5,/elsewhere/DSC00001.JPG\n")
click("Restore previous ratings", { jpeg1 })
check("restore, another library's file: left alone", jpeg1.rating, 5)

-- a file name with a comma and a line break still matches its saved line
local odd = image(5, "DSC,5\n.JPG")
odd.rating = 4
PYTHON.results = "5,0.90,,,1,3,\n"
click("Cull selection", { odd })
click("Restore previous ratings", { odd })
check("restore, comma and line break in the file name: the frame is back", odd.rating, 4)

-- an image removed from the library since the click raises when read: the rest are still restored
jpeg1.rating, jpeg2.rating = 5, 4
PYTHON.results = "1,0.90,,,1,3,\n2,0.40,,,0,1,\n"
click("Cull selection", { jpeg1, jpeg2 })
local removed = setmetatable({}, { __index = function() error("image no longer in the library") end })
click("Restore previous ratings", { jpeg1, removed, jpeg2 })
check("restore, an image removed from the library: the others are back", jpeg1.rating .. " " .. jpeg2.rating .. "; " .. last_print(),
    "5 4; Assisted Culling: restored the previous rating of 2 of 3 images, 1 couldn't be updated. Tags were not changed.")
check("restore: no Lua error", lua_errors(), nil)

-- Reset ratings to 0 ------------------------------------------------------------------
click("Reset ratings to 0", {})
check("reset, nothing selected: asks for a selection", last_print(), "Assisted Culling: select some images first")
check("reset, nothing selected: no job bar", #jobs, 0)

jpeg1.rating, jpeg2.rating, jpeg3.rating = 5, -1, 0
selection_sets = 0
click("Reset ratings to 0", { jpeg1, jpeg2, jpeg3 })
check("reset: every frame is at 0 stars, the rejected one too", jpeg1.rating .. " " .. jpeg2.rating .. " " .. jpeg3.rating, "0 0 0")
check("reset: progress goes to the panel line", status_shown("resetting ratings 3 / 3"), true)
check("reset: the panel line is cleared at the end", status_label.label, "")
check("reset: one job bar, closed at the end", #jobs .. " " .. tostring(jobs[1] and jobs[1].valid), "1 false")
check("reset: the selection is never changed", selection_sets, 0)
check("reset: tags are kept", has_tag(jpeg1, "Assisted Culling|Keeper"), true)
check("reset: the end message", last_print(),
    "Assisted Culling: set 2 of 3 images to 0 stars, 1 already at 0. Tags were not changed.")

-- the job bar's x during the first slice: the frames not reached keep their rating
local many = {}
for n = 1, 30 do
    many[n] = image(100 + n, string.format("DSC%05d.JPG", 100 + n))
    many[n].rating = 3
end
on_sleep = function() if jobs[1] and jobs[1].valid then jobs[1].valid = false end end
click("Reset ratings to 0", many)
on_sleep = nil
check("reset, cancelled: the first slice is at 0, the rest keep their rating",
    many[1].rating .. " " .. many[12].rating .. " " .. many[13].rating .. " " .. many[30].rating, "0 0 3 3")
check("reset, cancelled: the message counts both", last_print(),
    "Assisted Culling: reset cancelled. 12 of 30 images were set to 0 stars; 18 not reached keep their rating.")
check("reset, cancelled: the panel line is cleared", status_label.label, "")

click("Reset ratings to 0", { many[13] })
check("reset, after a cancel: the next reset runs, the panel isn't left busy", many[13].rating, 0)

jpeg1.rating, jpeg2.rating = 5, 4
click("Reset ratings to 0", { jpeg1, removed, jpeg2 })
check("reset, an image removed from the library: the others are at 0", jpeg1.rating .. " " .. jpeg2.rating .. "; " .. last_print(),
    "0 0; Assisted Culling: set 2 of 3 images to 0 stars, 1 couldn't be updated. Tags were not changed.")
check("reset: no Lua error", lua_errors(), nil)
check("no job bar is closed twice", double_closes, 0)

os.execute = real_execute
real_execute(WINDOWS and ('rmdir /s /q "' .. ROOT:gsub("/", "\\") .. '"') or ("rm -rf '" .. ROOT .. "'"))

if failures > 0 then
    print(failures .. " FAILED")
    os.exit(1)
end
print("all passed")
