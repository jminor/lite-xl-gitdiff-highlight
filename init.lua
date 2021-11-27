-- mod-version:2
local core = require "core"
local config = require "core.config"
local DocView = require "core.docview"
local Doc = require "core.doc"
local common = require "core.common"
local command = require "core.command"
local style = require "core.style"
local gitdiff = require "plugins.gitdiff_highlight.gitdiff"
local _, MiniMap = pcall(require, "plugins.minimap")

-- vscode defaults
style.gitdiff_addition = {common.color "#587c0c"}
style.gitdiff_modification = {common.color "#0c7d9d"}
style.gitdiff_deletion = {common.color "#94151b"}

local function color_for_diff(diff)
	if diff == "addition" then
		return style.gitdiff_addition
	elseif diff == "modification" then
		return style.gitdiff_modification
	else
		return style.gitdiff_deletion
	end
end

style.gitdiff_width = 3

local last_doc_lines = 0

-- maximum size of git diff to read, multiplied by current filesize
config.max_diff_size = 2

local current_diff = {}
local current_file = {
    name = nil,
    is_in_repo = nil
}

local diffs = {}

local function update_diff()
	local current_doc = core.active_view.doc
	if current_doc == nil or current_doc.filename == nil then return end
	if system.get_file_info(current_doc.filename) then
		current_doc = system.absolute_path(current_doc.filename)
	else
		current_doc = current_doc.filename
	end

	core.log_quiet("updating diff for " .. current_doc)

	if current_file.is_in_repo ~= true then
		local proc = process.start({"git", "ls-files", "--recurse-submodules", current_doc}, {
			stdin = process.REDIRECT_DISCARD,
			stdout = process.REDIRECT_PIPE,
			stderr = process.REDIRECT_STDOUT
		})
		proc:wait(100)
		local output = proc:read_stdout()
		current_file.is_in_repo = output and #output > 1
	end
	if not current_file.is_in_repo then
		core.log_quiet("file ".. current_doc .." is not in a git repository")
		return
  end

	local max_diff_size = system.get_file_info(current_doc).size * config.max_diff_size
	local folder = common.dirname(current_doc)
	local filename = common.basename(current_doc)
	-- TODO: On Windows use cmd instead of bash? or chdir instead?
	--       command = { "cmd", "/c", string.format("(%s) 2>&1", opt.command) }
	local diff_proc = process.start({"bash", "-c", string.format("cd %q; git diff HEAD %q", folder, filename)})
	diff_proc:wait(100)
	local raw_diff = diff_proc:read_stdout(max_diff_size)
	local parsed_diff = gitdiff.changed_lines(raw_diff)
	current_diff = parsed_diff
end

local function set_doc(doc_name)
	if current_diff ~= {} and current_file.name ~= nil then
		diffs[current_file.name] = {
			diff = current_diff,
			is_in_repo = current_file.is_in_repo
		}
	end
	current_file.name = doc_name
	if diffs[current_file.name] ~= nil then
		current_diff = diffs[current_file.name].diff
		current_file.is_in_repo = diffs[current_file.name].is_in_repo
	else
		current_diff = {}
		current_file.is_in_repo = nil
	end
	update_diff()
end

local function gitdiff_padding(dv)
	return style.padding.x * 1.5 + dv:get_font():get_width(#dv.doc.lines)
end

local old_docview_gutter = DocView.draw_line_gutter
local old_gutter_width = DocView.get_gutter_width
function DocView:draw_line_gutter(idx, x, y, width)
	if not current_file.is_in_repo then
		return old_docview_gutter(self, idx, x, y, width)
	end

	local gw, gpad = old_gutter_width(self)

	old_docview_gutter(self, idx, x, y, gpad and gw - gpad or gw)

	if current_diff[idx] == nil then
		return
	end

	local color = color_for_diff(current_diff[idx])

	-- add margin in between highlight and text
	x = x + gitdiff_padding(self)
	local yoffset = self:get_line_text_y_offset()
	if current_diff[idx] ~= "deletion" then
		renderer.draw_rect(x, y + yoffset, style.gitdiff_width, self:get_line_height(), color)
		return
		end
	renderer.draw_rect(x, y + (yoffset * 4), style.gitdiff_width, self:get_line_height() / 2, color)
end

function DocView:get_gutter_width()
	if not current_file.is_in_repo then return old_gutter_width(self) end
	return old_gutter_width(self) + style.padding.x * style.gitdiff_width / 12
end

local old_text_change = Doc.on_text_change
function Doc:on_text_change(type)
	local line, col = self:get_selection()
	if current_diff[line] == "addition" then goto end_of_function end
	-- TODO figure out how to detect an addition
	if type == "insert" or (type == "remove" and #self.lines == last_doc_lines) then
		current_diff[line] = "modification"
	elseif type == "remove" then
		current_diff[line] = "deletion"
	end
	::end_of_function::
	last_doc_lines = #self.lines
	return old_text_change(self, type)
end

local old_docview_update = DocView.update
function DocView:update()
	local filename = self.doc.abs_filename
	if filename and current_file.name ~= filename and filename ~= "---" and #filename>0 and core.active_view.doc == self.doc then
		set_doc(filename)
	end
	return old_docview_update(self)
end
local old_doc_save = Doc.save
function Doc:save(...)
	old_doc_save(self, ...)
	update_diff()
end

if MiniMap then
	-- Override MiniMap's line_highlight_color, but first
	-- stash the old one (using [] in case it is not there at all)
	local old_line_highlight_color = MiniMap["line_highlight_color"]
	function MiniMap:line_highlight_color(line_index)
		local diff = current_diff[line_index]
		if diff then
			return color_for_diff(diff)
		end
		return old_line_highlight_color(line_index)
	end
end

local function jump_to_next_change()
	local doc = core.active_view.doc
	local line, col = doc:get_selection()

	while current_diff[line] do
		line = line + 1
	end

	while line < #doc.lines do
		if current_diff[line] then
			doc:set_selection(line, col, line, col)
			return
		end
		line = line + 1
	end
end

local function jump_to_previous_change()
	local doc = core.active_view.doc
	local line, col = doc:get_selection()

	while current_diff[line] do
		line = line - 1
	end

	while line > 0 do
		if current_diff[line] then
			doc:set_selection(line, col, line, col)
			return
		end
		line = line - 1
	end
end

command.add("core.docview", {
	["gitdiff:previous-change"] = function()
		jump_to_previous_change()
	end,

	["gitdiff:next-change"] = function()
		jump_to_next_change()
	end,
})
