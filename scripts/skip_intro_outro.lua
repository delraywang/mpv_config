-- Per-folder intro/outro skipping for mpv-lazy.
-- Settings are stored beside the video files in .mpv/settings.conf.

local mp = require("mp")
local utils = require("mp.utils")

local SCRIPT_NAME = mp.get_script_name()
local EXTERNAL_PROP = "skip_intro_outro"
local CONFIG_DIRECTORY_NAME = ".mpv"
local CONFIG_FILE_NAME = "settings.conf"
local SETTING_SKIP_ENABLED = "skip_intro_outro_enabled"
local SETTING_INTRO_END_TIME = "skip_intro_outro_intro_end_time"
local SETTING_OUTRO_SKIP_DURATION = "skip_intro_outro_outro_skip_duration"

local settings_path = nil
local loaded_path = nil
local settings = {
    skip_enabled = false,
    skip_intro_outro_intro_end_time = 0,
    skip_intro_outro_outro_skip_duration = 0,
}
local outro_already_skipped = false
local intro_timer = nil

local function is_protocol(path)
    return type(path) == "string" and (
        path:find("^%a[%w.+-]-://") ~= nil or
        path:find("^%a[%w.+-]-:%?") ~= nil
    )
end

local function normalize_path(path)
    local ok, normalized = pcall(mp.command_native, { "normalize-path", path })
    if ok and type(normalized) == "string" and normalized ~= "" then
        return normalized
    end
    return path
end

local function read_file(path)
    local file = io.open(path, "r")
    if not file then
        return nil
    end

    local content = file:read("*all")
    file:close()
    return content
end

local function format_seconds(seconds)
    seconds = math.max(0, tonumber(seconds) or 0)
    local hours = math.floor(seconds / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    local whole_seconds = math.floor(seconds % 60)

    if hours > 0 then
        return string.format("%d:%02d:%02d", hours, minutes, whole_seconds)
    end
    return string.format("%d:%02d", minutes, whole_seconds)
end

local function serialize_seconds(seconds)
    local value = string.format("%.3f", math.max(0, tonumber(seconds) or 0))
    value = value:gsub("0+$", ""):gsub("%.$", "")
    return value == "" and "0" or value
end

local function parse_seconds(text)
    if type(text) ~= "string" then
        return nil
    end

    text = text:gsub("%s", "")
    if text == "" then
        return nil
    end

    local plain = tonumber(text)
    if plain and plain >= 0 then
        return plain
    end

    local parts = {}
    for part in text:gmatch("[^:]+") do
        parts[#parts + 1] = tonumber(part)
    end

    if (#parts ~= 2 and #parts ~= 3) then
        return nil
    end
    for _, part in ipairs(parts) do
        if not part or part < 0 then
            return nil
        end
    end

    if #parts == 2 then
        if parts[2] >= 60 then
            return nil
        end
        return parts[1] * 60 + parts[2]
    end

    if parts[2] >= 60 or parts[3] >= 60 then
        return nil
    end
    return parts[1] * 3600 + parts[2] * 60 + parts[3]
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
    local result
    if platform == "windows" then
        -- mkdir is a cmd built-in; passing the path as a separate argument
        -- preserves spaces and Unicode characters in Windows video folders.
        local windows_path = path:gsub("/", "\\")
        result = mp.command_native({
            name = "subprocess",
            playback_only = false,
            capture_stdout = true,
            capture_stderr = true,
            args = { "cmd", "/C", "mkdir", windows_path },
        })
    else
        result = mp.command_native({
            name = "subprocess",
            playback_only = false,
            capture_stdout = true,
            capture_stderr = true,
            args = { "mkdir", "-p", path },
        })
    end

    if not is_directory(path) then
        local details = "unknown error"
        if result then
            details = result.stderr ~= "" and result.stderr
                or result.error_string ~= "" and result.error_string
                or "exit status " .. tostring(result.status)
        end
        mp.msg.warn("无法创建片头片尾设置目录: " .. path .. " (" .. tostring(details) .. ")")
        return false
    end
    return true
end

local function write_settings()
    if not settings_path then
        return false
    end

    -- 只更新片头片尾字段；其他脚本写入的内容原样保留。
    -- 弹幕字段由 uosc_danmaku 自己追加和维护，这里不读取也不生成它。
    local existing_content = read_file(settings_path) or ""
    local lines = {}
    local seen = {
        [SETTING_SKIP_ENABLED] = false,
        [SETTING_INTRO_END_TIME] = false,
        [SETTING_OUTRO_SKIP_DURATION] = false,
    }

    for line in existing_content:gmatch("[^\r\n]+") do
        local key = line:match("^%s*([%w_-]+)%s*=")
        if key == SETTING_SKIP_ENABLED then
            if not seen[key] then
                lines[#lines + 1] = key .. "=" .. (settings.skip_enabled and "yes" or "no")
                seen[key] = true
            end
        elseif key == SETTING_INTRO_END_TIME then
            if not seen[key] then
                lines[#lines + 1] = key .. "=" .. serialize_seconds(settings.skip_intro_outro_intro_end_time)
                seen[key] = true
            end
        elseif key == SETTING_OUTRO_SKIP_DURATION then
            if not seen[key] then
                lines[#lines + 1] = key .. "=" .. serialize_seconds(settings.skip_intro_outro_outro_skip_duration)
                seen[key] = true
            end
        else
            -- 保留其他脚本字段和注释。
            lines[#lines + 1] = line
        end
    end

    if not seen[SETTING_SKIP_ENABLED] then
        lines[#lines + 1] = "# 是否启用跳过片头片尾。"
        lines[#lines + 1] = SETTING_SKIP_ENABLED .. "=" .. (settings.skip_enabled and "yes" or "no")
    end
    if not seen[SETTING_INTRO_END_TIME] then
        lines[#lines + 1] = "# 片头结束时间，单位为秒；视频播放时会跳转到此时间。"
        lines[#lines + 1] = SETTING_INTRO_END_TIME .. "=" .. serialize_seconds(settings.skip_intro_outro_intro_end_time)
    end
    if not seen[SETTING_OUTRO_SKIP_DURATION] then
        lines[#lines + 1] = "# 片尾跳过时长，单位为秒；播放到总时长减去此值时切换下一集。"
        lines[#lines + 1] = SETTING_OUTRO_SKIP_DURATION .. "=" .. serialize_seconds(settings.skip_intro_outro_outro_skip_duration)
    end

    local file = io.open(settings_path, "w")
    if not file then
        mp.msg.warn("无法写入片头片尾设置: " .. settings_path)
        return false
    end

    file:write(table.concat(lines, "\n") .. "\n")
    file:close()
    return true
end

local function read_settings()
    local loaded = {
        skip_enabled = false,
        skip_intro_outro_intro_end_time = 0,
        skip_intro_outro_outro_skip_duration = 0,
    }
    local content = settings_path and read_file(settings_path) or nil
    if not content then
        return loaded
    end

    for line in content:gmatch("[^\r\n]+") do
        local key, value = line:match("^%s*([%w_-]+)%s*=%s*(.-)%s*$")
        if key == SETTING_SKIP_ENABLED then
            value = value:lower()
            loaded.skip_enabled = value == "yes" or value == "on" or value == "true" or value == "1"
        elseif key == SETTING_INTRO_END_TIME then
            loaded.skip_intro_outro_intro_end_time = parse_seconds(value) or 0
        elseif key == SETTING_OUTRO_SKIP_DURATION then
            loaded.skip_intro_outro_outro_skip_duration = parse_seconds(value) or 0
        end
    end
    return loaded
end

local function current_video_folder()
    local path = mp.get_property("path", "")
    if path == "" or is_protocol(path) then
        return nil, nil
    end

    path = normalize_path(path)
    local directory = utils.split_path(path)
    if not directory or directory == "" then
        return nil, nil
    end
    return directory:gsub("[/\\]+$", ""), path
end

local function sync_toggle()
    local value = settings.skip_enabled and "on" or "off"
    mp.set_property_bool("user-data/" .. SCRIPT_NAME .. "/" .. EXTERNAL_PROP, settings.skip_enabled)
    mp.commandv("script-message-to", "uosc", "set", EXTERNAL_PROP, value)
end

local function register_settings_button()
    local payload = utils.format_json({
        icon = "skip_next",
        tooltip = "片头片尾设置",
        command = "script-message open-skip-intro-outro-settings",
    })
    mp.commandv("script-message-to", "uosc", "set-button", "skip_intro_outro_settings", payload)
end

local function load_settings_for_current_file()
    settings_path = nil
    loaded_path = nil
    settings = {
        skip_enabled = false,
        skip_intro_outro_intro_end_time = 0,
        skip_intro_outro_outro_skip_duration = 0,
    }

    local directory, path = current_video_folder()
    if not directory then
        return
    end

    local config_directory = utils.join_path(directory, CONFIG_DIRECTORY_NAME)
    if not ensure_directory(config_directory) then
        return
    end

    settings_path = utils.join_path(config_directory, CONFIG_FILE_NAME)
    loaded_path = path
    if not utils.file_info(settings_path) then
        write_settings()
    end
    settings = read_settings()
    -- 合并片头片尾字段，保留 settings.conf 中其他脚本的配置。
    write_settings()
end

local function open_settings_menu(edit_key, error_message)
    if not settings_path then
        mp.osd_message("片头片尾跳过仅支持本地视频文件", 3)
        return
    end

    local items = {
        {
            title = "跳过片头片尾",
            hint = settings.skip_enabled and "已开启" or "已关闭",
            active = settings.skip_enabled,
            keep_open = true,
            selectable = true,
        },
        {
            title = "片头",
            hint = "当前：" .. format_seconds(settings.skip_intro_outro_intro_end_time),
            keep_open = true,
            selectable = true,
            actions = {{
                icon = "my_location",
                name = "capture_intro",
                label = "将当前播放时间设为片头",
            }},
        },
        {
            title = "片尾",
            hint = "当前：" .. format_seconds(settings.skip_intro_outro_outro_skip_duration) .. "（距片尾）",
            keep_open = true,
            selectable = true,
            actions = {{
                icon = "my_location",
                name = "capture_outro",
                label = "将“视频总时长 − 当前播放时间”设为片尾",
            }},
        },
    }

    local menu = {
        type = "skip_intro_outro_settings",
        title = "片头片尾跳过",
        footnote = "片头为跳转到的时间；片尾为距视频结尾的时长。",
        search_style = "disabled",
        item_actions_place = "outside",
        callback = { SCRIPT_NAME, "skip-intro-outro-configure" },
        items = items,
    }

    if edit_key then
        local is_intro = edit_key == SETTING_INTRO_END_TIME
        menu.title = error_message or (is_intro and "设置片头时间" or "设置片尾时间")
        menu.footnote = is_intro
            and "输入秒数、MM:SS 或 HH:MM:SS；例如 90、1:30、0:01:30。"
            or "输入距片尾的秒数、MM:SS 或 HH:MM:SS；例如 90、1:30、0:01:30。"
        menu.search_style = "palette"
        menu.search_debounce = "submit"
        menu.search_suggestion = format_seconds(settings[edit_key])
        menu.on_search = { "script-message-to", SCRIPT_NAME, "skip-intro-outro-configure", edit_key }
    end

    mp.commandv("script-message-to", "uosc", "open-menu", utils.format_json(menu))
end

local function save_or_warn()
    if write_settings() then
        return true
    end
    mp.osd_message("无法保存片头片尾设置", 3)
    return false
end

local function capture_intro()
    local position = mp.get_property_number("time-pos", -1)
    if position < 0 then
        mp.osd_message("无法获取当前播放时间", 3)
        return
    end

    settings.skip_intro_outro_intro_end_time = position
    if save_or_warn() then
        mp.osd_message("片头已设为 " .. format_seconds(position), 2)
    end
    open_settings_menu()
end

local function capture_outro()
    local duration = mp.get_property_number("duration", 0)
    local position = mp.get_property_number("time-pos", -1)
    if duration <= 0 or position < 0 then
        mp.osd_message("无法获取视频总时长或当前播放时间", 3)
        return
    end

    settings.skip_intro_outro_outro_skip_duration = math.max(0, duration - position)
    if save_or_warn() then
        mp.osd_message("片尾已设为 " .. format_seconds(settings.skip_intro_outro_outro_skip_duration) .. "（距片尾）", 2)
    end
    open_settings_menu()
end

local function set_time_setting(key, text)
    local seconds = parse_seconds(text)
    if not seconds then
        open_settings_menu(key, "时间格式无效")
        return
    end

    local duration = mp.get_property_number("duration", 0)
    if duration > 0 and seconds >= duration then
        open_settings_menu(key, "设置时间必须短于视频总时长")
        return
    end

    settings[key] = seconds
    if save_or_warn() then
        mp.osd_message((key == SETTING_INTRO_END_TIME and "片头" or "片尾") .. "已设为 " .. format_seconds(seconds), 2)
    end
    open_settings_menu()
end

local function schedule_intro_skip()
    if intro_timer then
        intro_timer:kill()
        intro_timer = nil
    end
    if not settings.skip_enabled or settings.skip_intro_outro_intro_end_time <= 0 or not loaded_path then
        return
    end

    local path = loaded_path
    intro_timer = mp.add_timeout(0.15, function()
        if loaded_path ~= path or not settings.skip_enabled or settings.skip_intro_outro_intro_end_time <= 0 then
            return
        end

        local duration = mp.get_property_number("duration", 0)
        if duration <= 0 or settings.skip_intro_outro_intro_end_time < duration then
            mp.commandv("seek", serialize_seconds(settings.skip_intro_outro_intro_end_time), "absolute+exact")
        end
    end)
end

mp.register_script_message("open-skip-intro-outro-settings", function()
    open_settings_menu()
end)

mp.register_script_message("set", function(property, value)
    if property ~= EXTERNAL_PROP then
        return
    end
    if not settings_path then
        settings.skip_enabled = false
        sync_toggle()
        mp.osd_message("片头片尾跳过仅支持本地视频文件", 3)
        return
    end

    settings.skip_enabled = value == "on"
    save_or_warn()
    sync_toggle()
end)

mp.register_script_message("skip-intro-outro-configure", function(first, second)
    local event = type(first) == "string" and utils.parse_json(first) or nil
    if event and event.type == "activate" then
        if event.action == "capture_intro" then
            capture_intro()
        elseif event.action == "capture_outro" then
            capture_outro()
        elseif event.index == 1 then
            settings.skip_enabled = not settings.skip_enabled
            save_or_warn()
            sync_toggle()
            open_settings_menu()
        elseif event.index == 2 then
            open_settings_menu(SETTING_INTRO_END_TIME)
        elseif event.index == 3 then
            open_settings_menu(SETTING_OUTRO_SKIP_DURATION)
        end
        return
    end

    if first == SETTING_INTRO_END_TIME or first == SETTING_OUTRO_SKIP_DURATION then
        set_time_setting(first, second)
    end
end)

mp.register_event("start-file", function()
    outro_already_skipped = false
end)

mp.register_event("file-loaded", function()
    register_settings_button()
    outro_already_skipped = false
    load_settings_for_current_file()
    sync_toggle()
    schedule_intro_skip()
end)

mp.observe_property("time-pos", "number", function(_, position)
    if outro_already_skipped or not settings.skip_enabled
        or settings.skip_intro_outro_outro_skip_duration <= 0 or not position then
        return
    end

    local duration = mp.get_property_number("duration", 0)
    if duration <= settings.skip_intro_outro_outro_skip_duration then
        return
    end

    if position >= duration - settings.skip_intro_outro_outro_skip_duration then
        outro_already_skipped = true
        mp.commandv("script-binding", "uosc/next")
    end
end)

-- uosc may still be initializing while scripts are loaded; retry once after startup.
mp.add_timeout(0.5, register_settings_button)
mp.msg.info("正在运行 片头片尾跳过")
