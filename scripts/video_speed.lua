-- 保存并恢复当前视频的播放速度（视频速度）。
-- 配置保存在当前播放目录的 .mpv/settings.conf 的 video_speed 字段。

local mp = require("mp")
local utils = require("mp.utils")

local SETTING_SPEED = "video_speed"
local SETTING_SPEED_ENABLED = "video_speed_enabled"
local SETTING_SPEED_SAVE_DELAY = "video_speed_save_delay"
local SETTING_SPEED_MIN = "video_speed_min_speed"
local SETTING_SPEED_MAX = "video_speed_max_speed"
local SETTINGS_FILE_NAME = "settings.conf"

local SPEED_COMMENT = "# 当前视频的播放速度；1.0 为正常速度。"
local SPEED_OPTION_FIELDS = {
    { key = SETTING_SPEED_ENABLED, comment = "# 是否启用当前视频的自动倍速保存与恢复。" },
    { key = SETTING_SPEED_SAVE_DELAY, comment = "# 倍速变化后的延迟保存时间，单位为秒。" },
    { key = SETTING_SPEED_MIN, comment = "# 允许保存和恢复的最低视频播放速度。" },
    { key = SETTING_SPEED_MAX, comment = "# 允许保存和恢复的最高视频播放速度。" },
}
local speed_options = {
    enabled = true,
    save_delay = 0.8,
    min_speed = 0.1,
    max_speed = 10,
}
local current_folder_name = nil
local current_folder_path = nil
local settings_path = nil
local suppress_save_until = 0
local save_timer = nil

local function is_protocol(path)
    return type(path) == "string" and (
        path:find("^%a[%w.+-]-://") ~= nil or
        path:find("^%a[%w.+-]-:%?") ~= nil
    )
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

local function write_file(path, content)
    if not path then
        return false
    end

    local file = io.open(path, "w")
    if not file then
        mp.msg.warn("无法写入播放速度设置: " .. path)
        return false
    end
    file:write(content)
    file:close()
    return true
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

local function reset_speed_options()
    speed_options = {
        enabled = true,
        save_delay = 0.8,
        min_speed = 0.1,
        max_speed = 10,
    }
end

local function load_speed_options()
    reset_speed_options()
    local content = read_file(settings_path)
    if not content then
        return
    end

    for line in content:gmatch("[^\r\n]+") do
        local key, value = line:match("^%s*([%w_-]+)%s*=%s*(.-)%s*$")
        if key == SETTING_SPEED_ENABLED then
            local parsed = parse_boolean(value)
            if parsed ~= nil then
                speed_options.enabled = parsed
            end
        elseif key == SETTING_SPEED_SAVE_DELAY then
            local parsed = tonumber(value)
            if parsed and parsed >= 0 then
                speed_options.save_delay = parsed
            end
        elseif key == SETTING_SPEED_MIN then
            local parsed = tonumber(value)
            if parsed and parsed > 0 then
                speed_options.min_speed = parsed
            end
        elseif key == SETTING_SPEED_MAX then
            local parsed = tonumber(value)
            if parsed and parsed > 0 then
                speed_options.max_speed = parsed
            end
        end
    end

    if speed_options.min_speed > speed_options.max_speed then
        speed_options.min_speed = 0.1
        speed_options.max_speed = 10
    end
end

local function serialize_speed_option_value(key)
    if key == SETTING_SPEED_ENABLED then
        return speed_options.enabled and "yes" or "no"
    elseif key == SETTING_SPEED_SAVE_DELAY then
        return tostring(speed_options.save_delay)
    elseif key == SETTING_SPEED_MIN then
        return tostring(speed_options.min_speed)
    elseif key == SETTING_SPEED_MAX then
        return tostring(speed_options.max_speed)
    end
    return nil
end

local function serialize_speed(speed)
    local text = string.format("%.3f", speed)
    text = text:gsub("0+$", ""):gsub("%.$", "")
    return text
end

local function update_speed_settings_file(speed_override, remove_speed)
    if not settings_path then
        return false
    end

    local content = read_file(settings_path) or ""
    local lines = {}
    local seen = {}
    local saved_speed = nil

    local current_speed = mp.get_property_number("speed", 1)
    if type(current_speed) ~= "number"
        or current_speed < speed_options.min_speed
        or current_speed > speed_options.max_speed then
        current_speed = 1
    end

    for line in content:gmatch("[^\r\n]+") do
        local key, value = line:match("^%s*([%w_-]+)%s*=%s*(.-)%s*$")
        if key == SETTING_SPEED then
            local parsed = tonumber(value)
            if parsed and parsed >= speed_options.min_speed and parsed <= speed_options.max_speed then
                saved_speed = parsed
            end
        end
    end

    local speed_to_write = nil
    if not remove_speed then
        speed_to_write = speed_override or saved_speed or current_speed
        if type(speed_to_write) ~= "number"
            or speed_to_write < speed_options.min_speed
            or speed_to_write > speed_options.max_speed then
            speed_to_write = current_speed
        end
    end
    local speed_written = false

    for line in content:gmatch("[^\r\n]+") do
        local key = line:match("^%s*([%w_-]+)%s*=")
        local is_speed_option = key == SETTING_SPEED_ENABLED
            or key == SETTING_SPEED_SAVE_DELAY
            or key == SETTING_SPEED_MIN
            or key == SETTING_SPEED_MAX
        if is_speed_option then
            if not seen[key] then
                lines[#lines + 1] = line
                seen[key] = true
                if key == SETTING_SPEED_ENABLED and not remove_speed then
                    lines[#lines + 1] = SPEED_COMMENT
                    lines[#lines + 1] = SETTING_SPEED .. "=" .. serialize_speed(speed_to_write)
                    speed_written = true
                end
            else
                -- 丢弃重复的速度选项，后续保留第一次出现的字段。
            end
        elseif key == SETTING_SPEED then
            -- 速度字段统一在 video_speed_enabled 后写入。
        elseif line == SPEED_COMMENT then
            -- 速度字段会在 video_speed_enabled 后统一写入。
        else
            lines[#lines + 1] = line
        end
    end

    for _, field in ipairs(SPEED_OPTION_FIELDS) do
        if not seen[field.key] then
            lines[#lines + 1] = field.comment
            lines[#lines + 1] = field.key .. "=" .. serialize_speed_option_value(field.key)
            if field.key == SETTING_SPEED_ENABLED and not remove_speed then
                lines[#lines + 1] = SPEED_COMMENT
                lines[#lines + 1] = SETTING_SPEED .. "=" .. serialize_speed(speed_to_write)
                speed_written = true
            end
        end
    end

    if not speed_written and not remove_speed then
        lines[#lines + 1] = SPEED_COMMENT
        lines[#lines + 1] = SETTING_SPEED .. "=" .. serialize_speed(speed_to_write)
    end

    local updated_content = table.concat(lines, "\n") .. "\n"
    if updated_content == content then
        return true
    end
    return write_file(settings_path, updated_content)
end

local function normalize_path(path)
    local ok, normalized = pcall(mp.command_native, { "normalize-path", path })
    if ok and type(normalized) == "string" and normalized ~= "" then
        return normalized
    end
    return path
end

local function get_current_folder()
    local path = mp.get_property("path", "")
    if path == "" or is_protocol(path) then
        return nil, nil
    end

    path = normalize_path(path)

    local directory = utils.split_path(path)
    if not directory or directory == "" then
        return nil, nil
    end

    directory = directory:gsub("[/\\]+$", "")
    local _, folder_name = utils.split_path(directory)
    if not folder_name or folder_name == "" then
        return nil, nil
    end

    return folder_name, directory
end

local function is_valid_speed(speed)
    return type(speed) == "number" and speed >= speed_options.min_speed and speed <= speed_options.max_speed
end

local function is_directory(path)
    local info = utils.file_info(path)
    return info and not info.is_file
end

local function ensure_directory(path)
    if is_directory(path) then
        return true
    end

    local platform = mp.get_property("platform", "")
    if platform == "windows" then
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

local function initialize_current_folder()
    current_folder_name, current_folder_path = get_current_folder()
    settings_path = nil

    if not current_folder_path then
        return
    end

    local config_directory = utils.join_path(current_folder_path, ".mpv")
    if not ensure_directory(config_directory) then
        mp.msg.warn("无法创建播放目录设置目录: " .. config_directory)
        return
    end

    settings_path = utils.join_path(config_directory, SETTINGS_FILE_NAME)
    load_speed_options()
    update_speed_settings_file(nil, false)
end

local function read_speed_setting()
    if not settings_path then
        return nil
    end

    local content = read_file(settings_path)
    if not content then
        return nil
    end

    local speed = nil
    for line in content:gmatch("[^\r\n]+") do
        local key, value = line:match("^%s*([%w_-]+)%s*=%s*(.-)%s*$")
        if key == SETTING_SPEED then
            local parsed = tonumber(value)
            if is_valid_speed(parsed) then
                speed = parsed
            end
        end
    end
    return speed
end

local function save_speed_setting(speed)
    if not settings_path then
        return false
    end

    -- 速度值和启用选项通过同一次合并写入处理，并保持 video_speed 紧跟在
    -- video_speed_enabled 后面；speed=nil 仅用于清理已保存的速度值。
    return update_speed_settings_file(speed, speed == nil)
end

local function save_speed_state(reason)
    if not current_folder_name or not speed_options.enabled then
        return
    end

    local speed = mp.get_property_number("speed", 1)
    if not is_valid_speed(speed) then
        return
    end

    save_speed_setting(speed)

    mp.msg.verbose(string.format("已保存视频播放速度 [%s]: %s", reason or "manual", current_folder_name))
end

local function schedule_speed_save()
    if not current_folder_name or not speed_options.enabled or mp.get_time() < suppress_save_until then
        return
    end

    if save_timer then
        save_timer:kill()
    end
    save_timer = mp.add_timeout(speed_options.save_delay, function()
        save_timer = nil
        save_speed_state("delayed")
    end)
end

local function restore_speed_state()
    if not current_folder_name or not speed_options.enabled then
        return
    end

    local speed = read_speed_setting()
    if not speed then
        return
    end

    suppress_save_until = mp.get_time() + speed_options.save_delay + 1
    mp.set_property_number("speed", speed)
    mp.msg.info("已恢复视频播放速度: " .. current_folder_name)
end

mp.register_event("start-file", function()
    if save_timer then
        save_timer:kill()
        save_timer = nil
    end
    initialize_current_folder()
end)

mp.register_event("file-loaded", function()
    initialize_current_folder()
    restore_speed_state()
end)

mp.register_event("end-file", function()
    if save_timer then
        save_timer:kill()
        save_timer = nil
    end
    save_speed_state("end-file")
end)

mp.register_event("shutdown", function()
    if save_timer then
        save_timer:kill()
        save_timer = nil
    end
    save_speed_state("shutdown")
end)

mp.observe_property("speed", "number", function()
    schedule_speed_save()
end)

mp.register_script_message("video-speed-save", function()
    save_speed_state("script-message")
end)

mp.register_script_message("video-speed-clean", function()
    if save_speed_setting(nil) then
        mp.osd_message("已清理当前视频播放速度设置", 2)
    end
end)

mp.msg.info("正在运行 视频速度设置")
