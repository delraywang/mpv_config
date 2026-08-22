-- 按当前视频所在文件夹保存并恢复播放速度。
-- 配置保存在当前播放目录的 .mpv/settings.conf 的 speed 字段。

local mp = require("mp")
local options = require("mp.options")
local utils = require("mp.utils")

local opt = {
    enabled = true,
    save_delay = 0.8,
    min_speed = 0.1,
    max_speed = 10,
}

options.read_options(opt)

if not opt.enabled then
    mp.msg.info("folder_speed_cache 已禁用")
    return
end

local SETTING_SPEED = "speed"
local SETTINGS_FILE_NAME = "settings.conf"
local SPEED_COMMENT = "# 当前文件夹视频的播放速度；1.0 为正常速度。"
local current_folder_name = nil
local current_folder_path = nil
local settings_path = nil
local suppress_save_until = 0

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

local function normalize_path(path)
    local ok, normalized = pcall(mp.command_native, { "normalize-path", path })
    if ok and type(normalized) == "string" and normalized ~= "" then
        return normalized
    end
    return path
end

local function get_folder_key()
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

local function valid_speed(speed)
    return type(speed) == "number" and speed >= opt.min_speed and speed <= opt.max_speed
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

local function select_current_folder()
    current_folder_name, current_folder_path = get_folder_key()
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
end

local function serialize_speed(speed)
    local text = string.format("%.3f", speed)
    text = text:gsub("0+$", ""):gsub("%.$", "")
    return text
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
            if valid_speed(parsed) then
                speed = parsed
            end
        end
    end
    return speed
end

local function update_speed_setting(speed)
    if not settings_path then
        return false
    end

    local content = read_file(settings_path) or ""
    local lines = {}
    local found = false
    for line in content:gmatch("[^\r\n]+") do
        local key = line:match("^%s*([%w_-]+)%s*=")
        if key == SETTING_SPEED then
            if not found then
                found = true
                if speed == nil and lines[#lines] == SPEED_COMMENT then
                    lines[#lines] = nil
                end
                if speed ~= nil then
                    lines[#lines + 1] = SETTING_SPEED .. "=" .. serialize_speed(speed)
                end
            end
        else
            lines[#lines + 1] = line
        end
    end

    if speed ~= nil and not found then
        lines[#lines + 1] = SPEED_COMMENT
        lines[#lines + 1] = SETTING_SPEED .. "=" .. serialize_speed(speed)
    end

    if speed == nil and not found then
        return true
    end

    return write_file(settings_path, table.concat(lines, "\n") .. "\n")
end

local function save_speed_state(reason)
    if not current_folder_name then
        return
    end

    local speed = mp.get_property_number("speed", 1)
    if not valid_speed(speed) then
        return
    end

    update_speed_setting(speed)

    mp.msg.verbose(string.format("已保存文件夹播放速度 [%s]: %s", reason or "manual", current_folder_name))
end

local save_timer = mp.add_timeout(opt.save_delay, function()
    save_speed_state("delayed")
end)
save_timer:kill()

local function schedule_save()
    if not current_folder_name or mp.get_time() < suppress_save_until then
        return
    end

    save_timer:kill()
    save_timer:resume()
end

local function restore_speed_state()
    if not current_folder_name then
        return
    end

    local speed = read_speed_setting()
    if not speed then
        return
    end

    suppress_save_until = mp.get_time() + opt.save_delay + 1
    mp.set_property_number("speed", speed)
    mp.msg.info("已恢复文件夹播放速度: " .. current_folder_name)
end

mp.register_event("start-file", function()
    select_current_folder()
end)

mp.register_event("file-loaded", function()
    select_current_folder()
    restore_speed_state()
end)

mp.register_event("end-file", function()
    save_timer:kill()
    save_speed_state("end-file")
end)

mp.register_event("shutdown", function()
    save_timer:kill()
    save_speed_state("shutdown")
end)

mp.observe_property("speed", "number", function()
    schedule_save()
end)

mp.register_script_message("folder-speed-cache-save", function()
    save_speed_state("script-message")
end)

mp.register_script_message("folder-speed-cache-clean", function()
    if update_speed_setting(nil) then
        mp.osd_message("已清理当前文件夹播放速度设置", 2)
    end
end)

mp.msg.info("正在运行 文件夹播放速度设置")
