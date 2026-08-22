--[[

文件夹属性保存恢复说明

记录播放目录内的属性变化，支持下次播放同一目录时恢复；数据保存在 .mpv/settings.conf
（选项 --save-position-on-quit 保存的是基于具体文件的属性，不要与 --watch-later-options 保存的属性相冲突）

可用的快捷键示例（在 input.conf 中写入）：
 <KEY>   script-message-to save_global_props clean_data   # 清除已记录的数据

]]

local mp = require "mp"
mp.options = require "mp.options"
mp.utils = require "mp.utils"

local opt = {
	load = true,

	save_mode = 1,                     -- <1|2>
	props     = "volume,mute",
	dup_block = false
}
mp.options.read_options(opt)

if opt.load == false then
	mp.msg.info("脚本已被初始化禁用")
	return
end
-- 原因：首个添加 --watch-later-options 选项的版本
local min_major = 0
local min_minor = 34
local min_patch = 0
local mpv_ver_curr = mp.get_property_native("mpv-version", "unknown")
local function is_version_incompatible(full_str, tar_major, tar_minor, tar_patch)
	if full_str == "unknown" then
		return true
	end

	local clean_ver_str = full_str:gsub("^[^%d]*", "")
	local major, minor, patch = clean_ver_str:match("^(%d+)%.(%d+)%.(%d+)")
	major = tonumber(major)
	minor = tonumber(minor)
	patch = tonumber(patch or 0)
	if major < tar_major then
		return true
	elseif major == tar_major then
		if minor < tar_minor then
			return true
		elseif minor == tar_minor then
			if patch < tar_patch then
				return true
			end
		end
	end

	return false
end
if is_version_incompatible(mpv_ver_curr, min_major, min_minor, min_patch) then
	mp.msg.warn("当前mpv版本 (" .. (mpv_ver_curr or "未知") .. ") 低于 " .. min_major .. "." .. min_minor .. "." .. min_patch .. "，已终止脚本。")
	return
end

local function split_csv(inputstr)
	local result = {}
	for str in string.gmatch(inputstr, "([^,]+)") do
		table.insert(result, str)
	end
	return result
end

opt.props = split_csv(opt.props)
local watch_later_opts = split_csv(mp.get_property("watch-later-options"))
local dup_opts = false

local function check_watch_later_overlap(properties, watch_later_options)
	for _, property in ipairs(properties) do
		for _, option in ipairs(watch_later_options) do
			if property == option then
				dup_opts = true
				mp.msg.warn("存在与 --watch-later-options 重合的项目： " .. property)
			end
		end
	end
end

check_watch_later_overlap(opt.props, watch_later_opts)

if dup_opts and opt.dup_block then
	mp.msg.warn("已自动禁用 全局属性保存恢复")
	return
end

local cleaned = false
local settings_path = nil
local saved_data = {}

local function is_protocol(path)
	return type(path) == "string" and (
		path:find("^%a[%w.+-]-://") ~= nil or path:find("^%a[%w.+-]-:%?") ~= nil
	)
end

local function normalize_path(path)
	local ok, normalized = pcall(mp.command_native, { "normalize-path", path })
	if ok and type(normalized) == "string" and normalized ~= "" then
		return normalized
	end
	return path
end

local function is_directory(path)
	local info = mp.utils.file_info(path)
	return info and not info.is_file
end

local function ensure_directory(path)
	if is_directory(path) then
		return true
	end

	if mp.get_property("platform", "") == "windows" then
		mp.command_native({
			name = "subprocess",
			playback_only = false,
			capture_stdout = true,
			capture_stderr = true,
			args = { "cmd", "/C", "mkdir", (path:gsub("/", "\\")) },
		})
	else
		mp.command_native({
			name = "subprocess",
			playback_only = false,
			capture_stdout = true,
			capture_stderr = true,
			args = { "mkdir", "-p", path },
		})
	end

	return is_directory(path)
end

local function prepare_settings_path()
	settings_path = nil
	saved_data = {}
	cleaned = false

	local path = mp.get_property("path", "")
	if path == "" or is_protocol(path) then
		return false
	end

	local directory = mp.utils.split_path(normalize_path(path))
	if not directory or directory == "" then
		return false
	end

	local config_directory = mp.utils.join_path(directory:gsub("[/\\]+$", ""), ".mpv")
	if not ensure_directory(config_directory) then
		mp.msg.warn("无法创建播放目录设置目录: " .. config_directory)
		return false
	end

	settings_path = mp.utils.join_path(config_directory, "settings.conf")
	return true
end

local property_set = {}
local property_comments = {
	volume = "# 当前文件夹视频的音量。",
	mute = "# 当前文件夹视频是否静音。",
}
for _, prop_name in ipairs(opt.props) do
	property_set[prop_name] = true
end

local function read_file(path)
	if not path then
		return nil
	end
	local file = io.open(path, "r")
	if not file then
		return nil
	end
	local content = file:read("*all")
	file:close()
	return content
end

local function parse_boolean(value)
	value = value:lower()
	if value == "yes" or value == "on" or value == "true" or value == "1" then
		return true
	elseif value == "no" or value == "off" or value == "false" or value == "0" then
		return false
	end
	return nil
end

local function parse_setting_value(prop_name, value)
	local current_value = mp.get_property_native(prop_name)
	if type(current_value) == "boolean" then
		return parse_boolean(value)
	elseif type(current_value) == "number" then
		return tonumber(value)
	end
	return value
end

local function serialize_setting_value(value)
	if type(value) == "boolean" then
		return value and "yes" or "no"
	elseif type(value) == "number" then
		return tostring(value)
	elseif type(value) == "string" then
		return value
	end
	return nil
end

local function property_comment(prop_name)
	return property_comments[prop_name] or "# 当前文件夹视频的 mpv 属性：" .. prop_name .. "。"
end

local function is_property_comment(line, prop_name)
	if line == property_comment(prop_name) then
		return true
	end

	-- 修复旧版本写入的损坏静音注释；后续统一写入完整 UTF-8 注释。
	return prop_name == "mute"
		and type(line) == "string"
		and line:match("视频是否静音。$") ~= nil
end

local function read_saved_data()
	local result = {}
	local content = read_file(settings_path)
	if not content then
		return result
	end

	for line in content:gmatch("[^\r\n]+") do
		local key, value = line:match("^%s*([^%s=]+)%s*=%s*(.-)%s*$")
		if key and property_set[key] then
			local parsed = parse_setting_value(key, value)
			if parsed ~= nil then
				result[key] = parsed
			end
		end
	end
	return result
end

local function write_settings_file(lines)
	local file = io.open(settings_path, "w")
	if file == nil then
		mp.msg.warn("无法写入文件夹属性设置: " .. settings_path)
		return false
	end
	file:write(table.concat(lines, "\n") .. "\n")
	file:close()
	return true
end

local function persist_saved_data()
	if cleaned or not settings_path then
		mp.msg.verbose("因清理属性记录而中止保存功能")
		return
	end

	local content = read_file(settings_path) or ""
	local lines = {}
	local updated = {}
	for line in content:gmatch("[^\r\n]+") do
		local key = line:match("^%s*([^%s=]+)%s*=")
		if key and property_set[key] and saved_data[key] ~= nil then
			if not updated[key] then
				if is_property_comment(lines[#lines], key) then
					lines[#lines] = property_comment(key)
				end
				local serialized = serialize_setting_value(saved_data[key])
				if serialized ~= nil then
					lines[#lines + 1] = key .. "=" .. serialized
				else
					lines[#lines + 1] = line
				end
				updated[key] = true
			end
		else
			lines[#lines + 1] = line
		end
	end

	for _, prop_name in ipairs(opt.props) do
		if saved_data[prop_name] ~= nil and not updated[prop_name] then
			local serialized = serialize_setting_value(saved_data[prop_name])
			if serialized ~= nil then
				lines[#lines + 1] = property_comment(prop_name)
				lines[#lines + 1] = prop_name .. "=" .. serialized
			end
		end
	end

	write_settings_file(lines)
end

local function clear_saved_properties()
	if not settings_path then
		mp.osd_message("没有可清理的本地播放目录设置", 2)
		return
	end

	local content = read_file(settings_path)
	if content then
		local lines = {}
		for line in content:gmatch("[^\r\n]+") do
			local key = line:match("^%s*([^%s=]+)%s*=")
			if key and property_set[key] then
				if is_property_comment(lines[#lines], key) then
					lines[#lines] = nil
				end
			else
				lines[#lines + 1] = line
			end
		end
		write_settings_file(lines)
	end
	cleaned = true
	mp.msg.info("全局属性保存恢复 已清理设置")
	mp.osd_message("已清理记录的属性\n建议重启mpv", 2)
end

local function apply_saved_properties()
	for _, prop_name in ipairs(opt.props) do
		local saved_value = saved_data[prop_name]
		if saved_value ~= nil then
			mp.set_property_native(prop_name, saved_value)
		end
	end
end

local function initialize_property_saving()
	for _, prop_name in ipairs(opt.props) do
		if opt.save_mode == 2 then
			mp.observe_property(prop_name, "native", function(_, prop_value)
				saved_data[prop_name] = mp.get_property_native(prop_name)
				persist_saved_data()
			end)
		end
	end
end

initialize_property_saving()
mp.msg.info("正在运行 文件夹属性保存恢复 模式" .. opt.save_mode)

mp.register_event("file-loaded", function()
	if prepare_settings_path() then
		saved_data = read_saved_data()
		apply_saved_properties()
	end
end)

if opt.save_mode == 1 then
	mp.register_event("shutdown", function()
		for _, prop_name in ipairs(opt.props) do
			saved_data[prop_name] = mp.get_property_native(prop_name)
			persist_saved_data()
		end
	end)
end

mp.register_event("end-file", function()
	if opt.save_mode ~= 1 then
		return
	end
	for _, prop_name in ipairs(opt.props) do
		saved_data[prop_name] = mp.get_property_native(prop_name)
	end
	persist_saved_data()
end)

mp.register_script_message("clean_data", clear_saved_properties)
