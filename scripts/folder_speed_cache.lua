-- 按“当前视频所在文件夹名称”缓存并恢复播放速度。
-- 注意：key 只使用文件夹名称，不使用完整路径；同名文件夹会共享同一份速度。

local mp = require("mp")
local options = require("mp.options")
local utils = require("mp.utils")

local opt = {
    enabled = true,
    cache_path = "~~/_cache/folder-speed-cache.json",
    save_delay = 0.8,
    min_speed = 0.1,
    max_speed = 10,
}

options.read_options(opt)

if not opt.enabled then
    mp.msg.info("folder_speed_cache 已禁用")
    return
end

local cache_path = mp.command_native({ "expand-path", opt.cache_path })

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
        mp.msg.warn("无法写入速度缓存文件: " .. path)
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

local function valid_speed(speed)
    return type(speed) == "number" and speed >= opt.min_speed and speed <= opt.max_speed
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

local function select_current_folder()
    current_key, current_folder_path = get_folder_key()
end

local function save_speed_state(reason)
    if not current_key then
        return
    end

    local speed = mp.get_property_number("speed", 1)
    if not valid_speed(speed) then
        return
    end

    cache.folders[current_key] = {
        folder_name = current_key,
        folder_path = current_folder_path,
        speed = speed,
        updated_at = os.time(),
    }
    save_cache()

    mp.msg.verbose(string.format("已保存文件夹播放速度 [%s]: %s", reason or "manual", current_key))
end

local save_timer = mp.add_timeout(opt.save_delay, function()
    save_speed_state("delayed")
end)
save_timer:kill()

local function schedule_save()
    if not current_key or mp.get_time() < suppress_save_until then
        return
    end

    save_timer:kill()
    save_timer:resume()
end

local function restore_speed_state()
    if not current_key then
        return
    end

    local entry = cache.folders[current_key]
    if type(entry) ~= "table" or not valid_speed(entry.speed) then
        return
    end

    suppress_save_until = mp.get_time() + opt.save_delay + 1
    mp.set_property_number("speed", entry.speed)
    mp.msg.info("已恢复文件夹播放速度: " .. current_key)
end

load_cache()

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
    cache = { version = 1, folders = {} }
    save_cache()
    mp.osd_message("已清理文件夹播放速度缓存", 2)
end)

mp.msg.info("正在运行 文件夹播放速度缓存")
