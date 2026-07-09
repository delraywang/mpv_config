-- 按“当前视频所在文件夹名称”缓存并恢复弹幕开关状态。
-- 注意：key 只使用文件夹名称，不使用完整路径；同名文件夹会共享同一份弹幕开关状态。

local mp = require("mp")
local options = require("mp.options")
local utils = require("mp.utils")

local opt = {
    enabled = true,
    cache_path = "~~/_cache/folder-danmaku-cache.json",
    save_delay = 0.8,
    restore_delay = 0.3,
    danmaku_script_name = "uosc_danmaku",
    danmaku_history_path = "~~/danmaku-history.json",
}

options.read_options(opt)

if not opt.enabled then
    mp.msg.info("folder_danmaku_cache 已禁用")
    return
end

local cache_path = mp.command_native({ "expand-path", opt.cache_path })
local danmaku_history_path = mp.command_native({ "expand-path", opt.danmaku_history_path })
local danmaku_state_prop = string.format("user-data/%s/has-danmaku", opt.danmaku_script_name)

local cache = { version = 1, folders = {} }
local current_key = nil
local current_folder_path = nil
local suppress_save_until = 0

local function is_protocol(path)
    return type(path) == "string" and (
        path:find("^%a[%w.+-]-://") ~= nil or
        path:find("^%a[%w.+-]-:%?") ~= nil
    )
end

local function read_json_file(path)
    local file = io.open(path, "r")
    if not file then
        return {}
    end

    local content = file:read("*all")
    file:close()

    if not content or content == "" then
        return {}
    end

    return utils.parse_json(content) or {}
end

local function write_json_file(path, data)
    local file = io.open(path, "w+")
    if not file then
        mp.msg.warn("无法写入弹幕缓存文件: " .. path)
        return
    end

    local content = utils.format_json(data)
    if content then
        file:write(content)
    end
    file:close()
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

local function normalize_cache(raw)
    if type(raw) == "table" and raw.version == 1 and type(raw.folders) == "table" then
        return raw
    end

    return { version = 1, folders = {} }
end

local function load_cache()
    cache = normalize_cache(read_json_file(cache_path))
end

local function save_cache()
    cache.version = 1
    cache.folders = type(cache.folders) == "table" and cache.folders or {}
    write_json_file(cache_path, cache)
end

local function read_danmaku_visibility()
    local history = read_json_file(danmaku_history_path)
    if type(history.show_danmaku) == "boolean" then
        return history.show_danmaku
    end

    return mp.get_property_bool(danmaku_state_prop, false)
end

local function write_danmaku_visibility(flag)
    local history = read_json_file(danmaku_history_path)
    history.show_danmaku = flag and true or false
    write_json_file(danmaku_history_path, history)
end

local function set_danmaku_visibility(flag)
    write_danmaku_visibility(flag)
    mp.commandv(
        "script-message-to",
        opt.danmaku_script_name,
        "set",
        "show_danmaku",
        flag and "on" or "off"
    )
end

local function select_current_folder()
    current_key, current_folder_path = get_folder_key()
end

local function save_danmaku_state(reason)
    if not current_key then
        return
    end

    cache.folders[current_key] = {
        folder_name = current_key,
        folder_path = current_folder_path,
        enabled = read_danmaku_visibility(),
        updated_at = os.time(),
    }
    save_cache()

    mp.msg.verbose(string.format("已保存文件夹弹幕开关 [%s]: %s", reason or "manual", current_key))
end

local save_timer = mp.add_timeout(opt.save_delay, function()
    save_danmaku_state("delayed")
end)
save_timer:kill()

local function schedule_save()
    if not current_key or mp.get_time() < suppress_save_until then
        return
    end

    save_timer:kill()
    save_timer:resume()
end

local function prime_danmaku_history()
    if not current_key then
        return
    end

    local entry = cache.folders[current_key]
    if type(entry) == "table" and type(entry.enabled) == "boolean" then
        write_danmaku_visibility(entry.enabled)
    end
end

local function restore_danmaku_state()
    if not current_key then
        return
    end

    local entry = cache.folders[current_key]
    if type(entry) ~= "table" or type(entry.enabled) ~= "boolean" then
        return
    end

    suppress_save_until = mp.get_time() + opt.restore_delay + 1

    local restore_key = current_key
    local enabled = entry.enabled
    mp.add_timeout(opt.restore_delay, function()
        if current_key == restore_key then
            set_danmaku_visibility(enabled)
        end
    end)

    mp.msg.info("已恢复文件夹弹幕开关: " .. current_key)
end

load_cache()

mp.register_event("start-file", function()
    select_current_folder()
    prime_danmaku_history()
end)

mp.register_event("file-loaded", function()
    select_current_folder()
    restore_danmaku_state()
end)

mp.register_event("end-file", function()
    save_timer:kill()
    save_danmaku_state("end-file")
end)

mp.register_event("shutdown", function()
    save_timer:kill()
    save_danmaku_state("shutdown")
end)

mp.observe_property(danmaku_state_prop, "bool", function()
    schedule_save()
end)

mp.register_script_message("folder-danmaku-cache-save", function()
    save_danmaku_state("script-message")
end)

mp.register_script_message("folder-danmaku-cache-clean", function()
    cache = { version = 1, folders = {} }
    save_cache()
    mp.osd_message("已清理文件夹弹幕开关缓存", 2)
end)

mp.msg.info("正在运行 文件夹弹幕开关缓存")
