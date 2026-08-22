-- 在媒体文件所在目录生成一个可点击的 Windows 快捷方式，用于继续之前的播放。
-- 快捷方式默认名为“继续之前播放”，会覆盖同目录下同名的旧快捷方式。

local mp = require("mp")
local msg = require("mp.msg")
local utils = require("mp.utils")

local options = {
    enabled = true,
    shortcut_name = "继续之前播放",
    mpv_executable = "~~home/../mpv.exe",
    end_rewind = 10,
    create_on_end = true,
    create_on_shutdown = true,
}

require("mp.options").read_options(options, mp.get_script_name())

if mp.get_property("platform", "") ~= "windows" then
    msg.warn("resume_link 目前只支持 Windows 快捷方式")
    return
end

local current_path = nil
local last_position = 0
local current_duration = 0
local last_saved_path = nil
local last_saved_reason = nil

local function is_local_path(path)
    if type(path) ~= "string" or path == "" then
        return false
    end

    -- 网络地址没有可写入的本地媒体目录。
    return not path:match("^%a[%w+.-]*://") and not path:match("^%a[%w+.-]*:%?")
end

local function join_path(folder, name)
    if folder:match("[/\\]$") then
        return folder .. name
    end
    return folder .. "\\" .. name
end

local function escape_powershell_string(value)
    -- PowerShell 单引号字符串中，单引号用两个单引号表示。
    return tostring(value):gsub("'", "''")
end

local function get_shortcut_name()
    local name = tostring(options.shortcut_name or "继续之前播放")
    name = name:gsub('[<>:"/\\|?*]', "_"):gsub("[%c]", "_")
    if name == "" or name == "." or name == ".." then
        return "继续之前播放"
    end
    return name
end

local function resolve_mpv_executable()
    local path = mp.command_native({"expand-path", options.mpv_executable})
    local info = path and utils.file_info(path)
    if info and info.is_file then
        return path
    end

    -- 便携版默认位于 portable_config 的上一级；找不到时交给 Windows PATH 查找。
    return "mpv.exe"
end

local function create_shortcut(media_path, position, reason)
    if not is_local_path(media_path) then
        return false
    end

    local folder = utils.split_path(media_path)
    if not folder or folder == "" then
        msg.warn("无法确定媒体文件所在目录: " .. media_path)
        return false
    end

    position = math.max(0, tonumber(position) or 0)
    local shortcut_path = join_path(folder, get_shortcut_name() .. ".lnk")
    local mpv_path = resolve_mpv_executable()
    -- 使用带斜杠的 ~~home/ 获取绝对配置目录；不带斜杠时 mpv 可能不会展开它。
    local config_dir = mp.command_native({"expand-path", "~~home/"})
    config_dir = config_dir:gsub("[/\\]$", "")
    local arguments = string.format('--config-dir="%s" --start=%.3f -- "%s"', config_dir, position, media_path)

    local command = string.format([[
$ErrorActionPreference = 'Stop'
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut('%s')
$shortcut.TargetPath = '%s'
$shortcut.Arguments = '%s'
$shortcut.WorkingDirectory = '%s'
$shortcut.IconLocation = '%s,0'
$shortcut.Description = 'mpv 继续之前播放'
$shortcut.Save()
]],
        escape_powershell_string(shortcut_path),
        escape_powershell_string(mpv_path),
        escape_powershell_string(arguments),
        escape_powershell_string(config_dir),
        escape_powershell_string(mpv_path)
    )

    local result = utils.subprocess({
        args = {
            "powershell.exe",
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-Command",
            command,
        },
        cancellable = false,
    })

    if not result or result.status ~= 0 then
        msg.error("无法创建继续播放快捷方式: " .. shortcut_path)
        if result and result.stderr and result.stderr ~= "" then
            msg.error(result.stderr)
        end
        return false
    end

    last_saved_path = media_path
    last_saved_reason = reason
    msg.info(string.format("已生成继续播放快捷方式: %s (%.1f 秒)", shortcut_path, position))
    return true
end

local function update_current_file()
    current_path = mp.get_property("path")
    last_position = mp.get_property_number("time-pos", 0) or 0
    current_duration = mp.get_property_number("duration", 0) or 0
end

local function rewind_at_end(position)
    local rewind = math.max(0, tonumber(options.end_rewind) or 0)
    position = math.max(0, tonumber(position) or 0)

    if current_duration > 0 then
        position = math.min(position, current_duration)
        position = math.max(0, math.min(position, current_duration - rewind))
    else
        position = math.max(0, position - rewind)
    end
    return position
end

local function on_file_loaded()
    update_current_file()
end

local function on_end_file(event)
    if not options.enabled or not options.create_on_end or not current_path then
        return
    end

    local duration = mp.get_property_number("duration", 0) or 0
    if duration > 0 then
        current_duration = duration
    end

    local reason = event and event.reason or "unknown"
    if reason == "error" or reason == "redirect" then
        return
    end

    local position = rewind_at_end(last_position)
    create_shortcut(current_path, position, "end-file")
end

local function on_shutdown()
    if not options.enabled or not options.create_on_shutdown or not current_path then
        return
    end

    -- keep-open=yes 时，文件结束后仍会停在结束画面；避免 shutdown 把刚刚生成的
    -- “回退 10 秒”入口覆盖成“从文件末尾开始”。
    if last_saved_reason == "end-file"
        and last_saved_path == current_path
        and current_duration > 0
        and last_position >= current_duration - 1 then
        return
    end

    create_shortcut(current_path, last_position, "shutdown")
end

mp.observe_property("time-pos", "number", function(_, position)
    if position and position >= 0 then
        last_position = position
    end
end)

mp.observe_property("duration", "number", function(_, duration)
    if duration and duration > 0 then
        current_duration = duration
    end
end)

mp.register_event("file-loaded", on_file_loaded)
mp.register_event("end-file", on_end_file)
mp.register_event("shutdown", on_shutdown)
