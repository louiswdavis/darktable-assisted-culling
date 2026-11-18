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

-- score_images.py -----------------------------------------------------------------
-- What the fake process writes, and what it was last asked.
local PYTHON = { results = "", points = "", progress = "", exit = 0, runs = {} }

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
    write_file(done_path, PYTHON.exit .. "\n")
    return true
end

-- darktable -----------------------------------------------------------------------
local prints, jobs, images_by_id, tags_by_name, tag_list, panel = {}, {}, {}, {}, {}, nil
local hinter_calls, rating_actions = 0, 0
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
    control = { sleep = function() end, dispatch = function(fn) fn() end },
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
        -- the act-on images follow the selection
        selection = function(images)
            local before = dt.gui.action_images
            if images then dt.gui.action_images = images end
            return before
        end,
        action_images = {},
        -- the rating action does nothing here, so every rating falls back to a per-image write
        action = function() rating_actions = rating_actions + 1 end,
        current_view = function() return { id = "lighttable" } end,
        create_job = function(title)
            local job = { valid = true, percent = 0, title = title }
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
require("assisted_culling")
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

click("Cull selection", all)
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

os.execute = real_execute
real_execute(WINDOWS and ('rmdir /s /q "' .. ROOT:gsub("/", "\\") .. '"') or ("rm -rf '" .. ROOT .. "'"))

if failures > 0 then
    print(failures .. " FAILED")
    os.exit(1)
end
print("all passed")
