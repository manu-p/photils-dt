--[[ photils Auto Tagging plugin
    copyright (c) 2020 Tobias Scheck

    darktable is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    darktable is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with darktable.  If not, see <http://www.gnu.org/licenses/>.
--]]

--[[
    A darktable plugin which tries to predict keywords based on the selected image.
    This plugin uses photils-cli to handle this task. Photils-cli is an application
    which passes the image through a neural network and generates a feature vector.
    This feature vector will be used to find similar images in a self-hosted online
    database and the corresponding tags. The usage of the feature vector has this advantage
    that at no time your selected image will leave the PC. Rather a representation
    of the image is sent.

    ADDITIONAL SOFTWARE NEEDED FOR THIS SCRIPT
    * photils-cli - https://github.com/scheckmedia/photils-cli

    USAGE
    * require this script from your main lua file
    To do this add this line to the file .config/darktable/luarc:
    require "contrib/photils"
    * Select an image
    * Press "Get Tags"
    * Select the tags you want from a list of suggestions
    * Press "Attach .. Tags" to add the selected tags to your image
--]]

local dt = require "darktable"
local du = require "lib/dtutils"
local df = require "lib/dtutils.file"
local dtsys = require "lib/dtutils.system"

local MODULE_NAME = "photils"
du.check_min_api_version("5.0.0", MODULE_NAME)

local PS = dt.configuration.running_os == "windows" and "\\" or "/"
local gettext = dt.gettext
gettext.bindtextdomain(MODULE_NAME,
    dt.configuration.config_dir .. PS .. "lua" .. PS .. "locale" .. PS)

-- helper functions

local function _(msgid)
    return gettext.dgettext(MODULE_NAME, msgid)
end

local function num_keys(tbl)
    local num = 0
    for _ in pairs(tbl) do num = num + 1 end
    return num
end

local function has_key(tbl, value)
    for k, _ in pairs(tbl) do
        if k == value then
            return true
        end
    end

    return false
end

local photils_installed = df.check_if_bin_exists("photils-cli")

--[[
    local state object

    maybe per_page is a preference variable but I think 10
    is a good value for the ui
]]
local PHOTILS = {
    tags = {},
    page = 1,
    per_page = 10,
    selected_tags = {},
    in_pagination = false,
    tagged_image = ""
}

local GUI = {
    container = dt.new_widget("box") {
        orientation = "vertical",
        sensitive = true,
        dt.new_widget("button") {
            label = _("Get Tags"),
            sensitive = photils_installed,
            clicked_callback = function() PHOTILS.on_tags_clicked() end
        },
        reset_callback = function() PHOTILS.on_reset(true) end
    },
    stack = dt.new_widget("stack"),
    prev_button = dt.new_widget("button") {
        label = "<",
        sensitive = false,
        clicked_callback = function()
            PHOTILS.page = PHOTILS.page - 1
            PHOTILS.paginate()
        end
    },
    next_button = dt.new_widget("button") {
        label = ">",
        sensitive = false,
        clicked_callback = function()
            PHOTILS.page = PHOTILS.page + 1
            PHOTILS.paginate()
        end
    },
    tag_box = dt.new_widget("box") {orientation = "vertical"},
    tag_view = dt.new_widget("box") {orientation = "vertical"},
    page_label = dt.new_widget("label") {label = ""},
    error_view = dt.new_widget("box") {orientation = "vertical"},
    no_tags_label = dt.new_widget("label") {
        label = ""
    },
    restart_required_label = dt.new_widget("label") {
        label = _("requires a restart to be applied")
    },
    attach_button = dt.new_widget("button") {
        label = "",
        sensitive = false,
        clicked_callback = function() PHOTILS.attach_tags() end
    },
    warning = dt.new_widget("label")
}

function PHOTILS.image_changed()
    while not dt.control.ending do
        local current_image = tostring(dt.gui.selection()[1])
        if current_image ~= PHOTILS.tagged_image then
            if PHOTILS.tagged_image ~= "" then
                PHOTILS.tagged_image_has_changed()
            end

            PHOTILS.tagged_image = tostring(current_image)
        end

        dt.control.sleep(100)
    end
end

function PHOTILS.tagged_image_has_changed()
    GUI.warning.label = _(
                            "The suggested tags were not generated\n for the currently selected image!")
end

function PHOTILS.paginate()
    PHOTILS.in_pagination = true
    local num_pages = math.ceil(#PHOTILS.tags / PHOTILS.per_page)
    GUI.page_label.label = string.format(_("  Page %s of %s  "), PHOTILS.page,
                                         num_pages)

    if PHOTILS.page <= 1 then
        PHOTILS.page = 1
        GUI.prev_button.sensitive = false
    else
        GUI.prev_button.sensitive = true
    end

    if PHOTILS.page > num_pages - 1 then
        PHOTILS.page = num_pages
        GUI.next_button.sensitive = false
    else
        GUI.next_button.sensitive = true
    end

    local offset = ((PHOTILS.page - 1) * PHOTILS.per_page) + 1
    local tag_index = 1
    for i = offset, offset + PHOTILS.per_page - 1, 1 do
        local tag = PHOTILS.tags[i]
        GUI.tag_box[tag_index].value = has_key(PHOTILS.selected_tags, tag)

        if tag then
            GUI.tag_box[tag_index].label = tag
            GUI.tag_box[tag_index].sensitive = true
        else
            GUI.tag_box[tag_index].label = ""
            GUI.tag_box[tag_index].sensitive = false
        end
        tag_index = tag_index + 1
    end

    PHOTILS.in_pagination = false
end

function PHOTILS.attach_tags()
    local image = dt.gui.selection()[1]
    for tag, _ in pairs(PHOTILS.selected_tags) do
        local dt_tag = dt.tags.create(tag)
        dt.tags.attach(dt_tag, image)
    end

    dt.print(_("Tags successfully attached to image"))
end

function PHOTILS.get_tags(image)
    local tmp_file = os.tmpname()
    if dt.configuration.running_os == "windows" then
        tmp_file = dt.configuration.tmp_dir .. tmp_file -- windows os.tmpname() defaults to root directory
    end

    local f = io.open(tmp_file, "w")
    if not f then
        dt.print(string.format(_("Error writing to `%s`"), tmp_file))
        os.remove(tmp_file)
        return
    end

    local executable = photils_installed
    if dt.configuration.running_os == "macos" then
        executable =  executable .. "/Contents/MacOS/photils-cli"
    end

    local command = executable .. " -i " .. tostring(image) .. " -o " ..
                        tmp_file

    if dtsys.external_command(command) > 0 then
        dt.print(string.format(_("%s failed, see terminal output for details",
                                 MODULE_NAME)))
        os.remove(tmp_file)
        return
    end

    for i = #PHOTILS.tags, 1, -1 do
        PHOTILS.tags[i] = nil
    end

    for tag in io.lines(tmp_file) do
        PHOTILS.tags[#PHOTILS.tags + 1] = tag
    end

    dt.print(string.format(_("%s found %d tags for your image"), MODULE_NAME,
                           #PHOTILS.tags))
    os.remove(tmp_file)
end

function PHOTILS.on_tags_clicked()
    PHOTILS.page = 1
    GUI.warning.label = ""

    PHOTILS.on_reset(false)

    local images = dt.gui.selection()

    if #images == 0 then
        dt.print(_("No image selected."))
        GUI.stack.active = GUI.no_tags_label
        dt.control.sleep(2000)
    else
        if #images > 1 then
            dt.print(_("This plugin can only handle a single image."))
            dt.gui.selection({images[1]})
            dt.control.sleep(2000)
        end

        PHOTILS.get_tags(images[1])

        if #PHOTILS.tags == 0 then
            GUI.stack.active = GUI.no_tags_label
            return
        end

        GUI.stack.active = GUI.tag_view
        PHOTILS.paginate()
    end
end

function PHOTILS.tag_selected(tag_button)
    if PHOTILS.in_pagination then return end

    if tag_button.value then
        PHOTILS.selected_tags[tag_button.label] = tag_button.label
    else
        PHOTILS.selected_tags[tag_button.label] = nil
    end

    local num_selected = num_keys(PHOTILS.selected_tags)
    if num_selected == 0 then
        GUI.attach_button.label = ""
        GUI.attach_button.sensitive = false
    else
        GUI.attach_button.label = string.format(_("Attach %d Tags"),
                                                num_selected)
        GUI.attach_button.sensitive = true
    end
end

function PHOTILS.on_reset(with_view)
    if with_view then GUI.stack.active = 1 end

    for k, _ in pairs(PHOTILS.selected_tags) do
        PHOTILS.selected_tags[k] = nil
    end

    for _, v in ipairs(GUI.tag_box) do
        v.value = false
    end

    GUI.attach_button.label = ""
    GUI.attach_button.sensitive = false
end

-- add a fix number of buttons
for _ = 1, PHOTILS.per_page, 1 do
    local btn_tag = dt.new_widget("check_button") {
        label = "",
        sensitive = false,
        clicked_callback = PHOTILS.tag_selected
    }

    table.insert(GUI.tag_box, btn_tag)
end

if not photils_installed then
    GUI.no_tags_label.label = _("photils-cli not found")
    dt.print_log(_("photils-cli not found"))
else
    GUI.no_tags_label.label = _("Select an image, click \"Get Tags\" and get \nsuggestions for tags.")
end

GUI.pagination = dt.new_widget("box") {
    orientation = "horizontal",
    GUI.prev_button,
    GUI.page_label,
    GUI.next_button
}


table.insert(GUI.error_view, GUI.no_tags_label)
if not photils_installed then
    table.insert(GUI.error_view, df.executable_path_widget({"photils-cli"}))
    table.insert(GUI.error_view, GUI.restart_required_label)
end
table.insert(GUI.stack, GUI.error_view)
table.insert(GUI.stack, GUI.tag_view)

table.insert(GUI.tag_view, GUI.pagination)
table.insert(GUI.tag_view, GUI.tag_box)
table.insert(GUI.tag_view, GUI.attach_button)
table.insert(GUI.tag_view, GUI.warning)

table.insert(GUI.container, GUI.stack)

GUI.stack.active = 1

local plugin_display_views = {
    [dt.gui.views.lighttable] = {"DT_UI_CONTAINER_PANEL_RIGHT_CENTER", 100},
    [dt.gui.views.darkroom] = {"DT_UI_CONTAINER_PANEL_LEFT_CENTER", 100}
}

dt.control.dispatch(PHOTILS.image_changed)
dt.register_lib(MODULE_NAME,
    "photils autotagger",
    true,
    true,
    plugin_display_views,
    GUI.container,
    nil,
    nil
)