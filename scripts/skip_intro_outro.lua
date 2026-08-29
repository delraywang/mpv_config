-- mpv-lazy 的按文件夹片头片尾跳过脚本。
-- 配置保存在视频目录旁的 .mpv/settings.conf 中。

local mp = require("mp")
local utils = require("mp.utils")

local SCRIPT_NAME = mp.get_script_name()
local EXTERNAL_PROP = "skip_intro_outro"
local CONFIG_DIRECTORY_NAME = ".mpv"
local CONFIG_FILE_NAME = "settings.conf"
local SETTING_SKIP_ENABLED = "skip_intro_outro_enabled"
local SETTING_INTRO_SKIP_DELAY = "skip_intro_outro_intro_skip_delay"
local SETTING_INTRO_END_TIME = "skip_intro_outro_intro_end_time"
local SETTING_OUTRO_SKIP_DURATION = "skip_intro_outro_outro_skip_duration"
local SETTING_OUTRO_SKIP_DELAY = "skip_intro_outro_outro_skip_delay"
local RIGHT_CONSUME_PROP = "user-data/" .. SCRIPT_NAME .. "/consume-right"
local DEFAULT_INTRO_SKIP_DELAY = 5
local DEFAULT_OUTRO_SKIP_DELAY = 10

local settings_path = nil
local loaded_path = nil
local settings = {
  skip_enabled = false,
  skip_intro_outro_intro_skip_delay = DEFAULT_INTRO_SKIP_DELAY,
  skip_intro_outro_intro_end_time = 0,
  skip_intro_outro_outro_skip_duration = 0,
  skip_intro_outro_outro_skip_delay = DEFAULT_OUTRO_SKIP_DELAY,
}
-- 当前文件是否已经执行过片尾跳过。
local outro_already_skipped = false
-- 片头跳过检查定时器。
local intro_timer = nil
-- 片头或片尾倒计时定时器。
local countdown_timer = nil
-- 当前等待执行的跳过类型。
local pending_skip = nil
-- 当前视频是否已取消片头跳过。
local intro_skip_cancelled = false
-- 当前文件加载时记录的初始播放位置。
local intro_initial_position = nil
-- 设置菜单打开前的暂停状态。
local settings_menu_pause_state = nil
local serialize_seconds

-- 使用与 uosc_danmaku 的 show_message() 相同的普通 ASS 文本样式，
-- 但按要求固定显示在右上角。
local skip_message_overlay = mp.create_osd_overlay("ass-events")
local skip_message_timer = nil

local function hide_skip_message()
  if skip_message_timer then
    skip_message_timer:kill()
    skip_message_timer = nil
  end
  skip_message_overlay:remove()
end

-- 在右上角显示跳过提示，并按需自动隐藏。
local function show_skip_message(text, duration)
  if skip_message_timer then
    skip_message_timer:kill()
    skip_message_timer = nil
  end

  local width, height = 1920, 1080
  local osd_width, osd_height = mp.get_osd_size()
  if osd_width and osd_height and osd_width > 0 and osd_height > 0 then
    local ratio = osd_width / osd_height
    if width / height < ratio then
      height = width / ratio
    end
  end

  skip_message_overlay.res_x = width
  skip_message_overlay.res_y = height
  skip_message_overlay.data = string.format("{\\an9\\pos(%d,%d)}%s", width - 30, 30, text)
  skip_message_overlay:update()

  if duration and duration > 0 then
    skip_message_timer = mp.add_timeout(duration, hide_skip_message)
  end
end

-- 设置 RIGHT 键是否由本脚本暂时消费。
local function set_right_key_consumed(value)
  mp.set_property_bool(RIGHT_CONSUME_PROP, value)
end

-- 停止当前的跳过倒计时。
local function stop_countdown()
  if countdown_timer then
    countdown_timer:kill()
    countdown_timer = nil
  end
end

local function clear_pending_skip()
  -- 清理倒计时、待执行类型和 RIGHT 键占用标记。
  stop_countdown()
  pending_skip = nil
  set_right_key_consumed(false)
end

local function reset_playback_skip_state()
  if intro_timer then
    intro_timer:kill()
    intro_timer = nil
  end
  clear_pending_skip()
  hide_skip_message()
  intro_skip_cancelled = false
  outro_already_skipped = false
  intro_initial_position = nil
end

local function restore_settings_menu_pause()
  if settings_menu_pause_state == nil then
    return
  end

  local was_paused = settings_menu_pause_state
  settings_menu_pause_state = nil
  if not was_paused then
    mp.set_property_bool("pause", false)
  end
end

local function schedule_settings_menu_pause_restore()
  if settings_menu_pause_state == nil then
    return
  end

  mp.add_timeout(0, function()
    -- uosc 会先关闭旧菜单再打开新菜单；只有整个设置菜单消失后才恢复播放。
    if mp.get_property("user-data/uosc/menu/type", "") == "skip_intro_outro_settings" then
      return
    end
    restore_settings_menu_pause()
  end)
end

local function execute_pending_skip(kind)
  -- 执行倒计时结束后的片头定位或片尾下一集操作。
  if pending_skip ~= kind then
    return
  end

  clear_pending_skip()
  hide_skip_message()

  if kind == "intro" then
    intro_skip_cancelled = true
    local intro_time = settings.skip_intro_outro_intro_end_time
    local position = mp.get_property_number("time-pos", -1)
    if intro_time > 0 and position < intro_time then
      mp.commandv("seek", serialize_seconds(intro_time), "absolute+exact")
    end
  elseif kind == "outro" then
    outro_already_skipped = true
    mp.commandv("script-binding", "uosc/next")
  end
end

local function cancel_pending_skip()
  local kind = pending_skip
  if not kind then
    return false
  end

  clear_pending_skip()
  if kind == "intro" then
    intro_skip_cancelled = true
  else
    -- 取消只对当前文件/本次播放有效；当前位置仍在片尾范围内时不再重复提示。
    outro_already_skipped = true
  end

  show_skip_message(kind == "intro" and "已取消跳过片头" or "已取消跳过片尾", 2)
  return true
end

local function start_countdown(kind, target_position)
  -- 按媒体时间倒计时；播放速度和暂停状态会自然反映在 time-pos 上。
  stop_countdown()
  pending_skip = kind
  set_right_key_consumed(true)

  local last_displayed = nil

  local function update_countdown()
    if pending_skip ~= kind then
      stop_countdown()
      return
    end

    local position = mp.get_property_number("time-pos", -1)
    if position < 0 then
      return
    end

    local remaining = target_position - position
    local displayed = math.max(1, math.ceil(remaining))
    if displayed ~= last_displayed then
      last_displayed = displayed
      show_skip_message(
        string.format(
          "%d秒后将跳过片%s，点击右方向键取消本次跳转",
          displayed,
          kind == "intro" and "头" or "尾"
        )
      )
    end

    if remaining <= 0 then
      execute_pending_skip(kind)
    end
  end

  countdown_timer = mp.add_periodic_timer(0.1, update_countdown)
  update_countdown()
end

local function get_outro_skip_position(duration)
  return duration - settings.skip_intro_outro_outro_skip_duration
end

local function should_start_outro_countdown(position, duration)
  local lead = math.max(0, tonumber(settings.skip_intro_outro_outro_skip_delay) or DEFAULT_OUTRO_SKIP_DELAY)
  local outro_start = get_outro_skip_position(duration)
  -- 片尾配置为“距结尾的时长”。例如片尾为 120 秒、提前量为
  -- 10 秒时，在距结尾 130 秒的位置开始倒计时，倒计时结束时
  -- 正好到达原本的片尾跳过点（距结尾 120 秒）。
  return position >= outro_start - lead
end

local function is_protocol(path)
  return type(path) == "string" and (path:find("^%a[%w.+-]-://") ~= nil or path:find("^%a[%w.+-]-:%?") ~= nil)
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

serialize_seconds = function(seconds)
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

  if #parts ~= 2 and #parts ~= 3 then
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
    -- mkdir 是 cmd 内置命令；将路径作为独立参数传入，以保留 Windows 视频目录中的空格和 Unicode 字符。
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
  local managed_keys = {
    [SETTING_SKIP_ENABLED] = true,
    [SETTING_INTRO_SKIP_DELAY] = true,
    [SETTING_INTRO_END_TIME] = true,
    [SETTING_OUTRO_SKIP_DURATION] = true,
    [SETTING_OUTRO_SKIP_DELAY] = true,
  }
  local managed_comments = {
    ["# 是否启用跳过片头片尾。"] = true,
    ["# 片头跳转前的等待时间，单位为秒；设为 0 可立即跳转。"] = true,
    ["# 片头结束时间，单位为秒；视频播放时会跳转到此时间。"] = true,
    ["# 片尾跳过时长，单位为秒；播放到总时长减去此值时切换下一集。"] = true,
    ["# 片尾提前倒计时，单位为秒；在片尾跳过点前提前此时间开始倒计时。"] = true,
  }

  -- 所有由本脚本维护的字段在同一个批次中生成，并固定 enabled 为第一项。
  local managed_lines = {
    "# 是否启用跳过片头片尾。",
    SETTING_SKIP_ENABLED .. "=" .. (settings.skip_enabled and "yes" or "no"),
    "# 片头跳转前的等待时间，单位为秒；设为 0 可立即跳转。",
    SETTING_INTRO_SKIP_DELAY .. "=" .. serialize_seconds(settings.skip_intro_outro_intro_skip_delay),
    "# 片头结束时间，单位为秒；视频播放时会跳转到此时间。",
    SETTING_INTRO_END_TIME .. "=" .. serialize_seconds(settings.skip_intro_outro_intro_end_time),
    "# 片尾跳过时长，单位为秒；播放到总时长减去此值时切换下一集。",
    SETTING_OUTRO_SKIP_DURATION .. "=" .. serialize_seconds(settings.skip_intro_outro_outro_skip_duration),
    "# 片尾提前倒计时，单位为秒；在片尾跳过点前提前此时间开始倒计时。",
    SETTING_OUTRO_SKIP_DELAY .. "=" .. serialize_seconds(settings.skip_intro_outro_outro_skip_delay),
  }

  local lines = {}
  local managed_inserted = false

  for line in existing_content:gmatch("[^\r\n]+") do
    local key = line:match("^%s*([%w_-]+)%s*=")
    if managed_keys[key] then
      if not managed_inserted then
        for _, managed_line in ipairs(managed_lines) do
          lines[#lines + 1] = managed_line
        end
        managed_inserted = true
      end
    elseif managed_comments[line] then
      -- 与本脚本字段一起替换本脚本生成的注释，其他注释保持不变。
    else
      -- 保留其他脚本字段和注释。
      lines[#lines + 1] = line
    end
  end

  if not managed_inserted then
    for _, managed_line in ipairs(managed_lines) do
      lines[#lines + 1] = managed_line
    end
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
    skip_intro_outro_intro_skip_delay = DEFAULT_INTRO_SKIP_DELAY,
    skip_intro_outro_intro_end_time = 0,
    skip_intro_outro_outro_skip_duration = 0,
    skip_intro_outro_outro_skip_delay = DEFAULT_OUTRO_SKIP_DELAY,
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
    elseif key == SETTING_INTRO_SKIP_DELAY then
      loaded.skip_intro_outro_intro_skip_delay = parse_seconds(value) or DEFAULT_INTRO_SKIP_DELAY
    elseif key == SETTING_INTRO_END_TIME then
      loaded.skip_intro_outro_intro_end_time = parse_seconds(value) or 0
    elseif key == SETTING_OUTRO_SKIP_DURATION then
      loaded.skip_intro_outro_outro_skip_duration = parse_seconds(value) or 0
    elseif key == SETTING_OUTRO_SKIP_DELAY then
      loaded.skip_intro_outro_outro_skip_delay = parse_seconds(value) or DEFAULT_OUTRO_SKIP_DELAY
    end
  end
  return loaded
end

local function get_current_video_folder()
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

local function load_settings_for_current_folder()
  -- 读取当前视频文件夹的设置，并合并维护本脚本的配置字段。
  settings_path = nil
  loaded_path = nil
  settings = {
    skip_enabled = false,
    skip_intro_outro_intro_skip_delay = DEFAULT_INTRO_SKIP_DELAY,
    skip_intro_outro_intro_end_time = 0,
    skip_intro_outro_outro_skip_duration = 0,
    skip_intro_outro_outro_skip_delay = DEFAULT_OUTRO_SKIP_DELAY,
  }

  local directory, path = get_current_video_folder()
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
  -- 打开片头片尾设置菜单；菜单打开期间暂停播放。
  if not settings_path then
    mp.osd_message("片头片尾跳过仅支持本地视频文件", 3)
    return
  end

  if settings_menu_pause_state == nil then
    settings_menu_pause_state = mp.get_property_bool("pause", false)
  end
  mp.set_property_bool("pause", true)

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
      hint = format_seconds(settings.skip_intro_outro_intro_end_time),
      keep_open = true,
      selectable = true,
      actions = {
        {
          icon = "my_location",
          name = "capture_intro",
          label = "将当前播放时间设为片头",
        },
      },
    },
    {
      title = "片尾",
      hint = format_seconds(settings.skip_intro_outro_outro_skip_duration),
      keep_open = true,
      selectable = true,
      actions = {
        {
          icon = "my_location",
          name = "capture_outro",
          label = "将当前播放时间设为片尾",
        },
      },
    },
  }

  local menu = {
    type = "skip_intro_outro_settings",
    title = "片头片尾跳过",
    footnote = "打开设置时会暂停播放；片头为跳转到的时间，片尾为距视频结尾的时长。",
    search_style = "disabled",
    item_actions_place = "outside",
    callback = { SCRIPT_NAME, "skip-intro-outro-configure" },
    items = items,
  }

  if edit_key then
    local is_intro = edit_key == SETTING_INTRO_END_TIME
    menu.title = error_message or (is_intro and "设置片头时间" or "设置片尾时间")
    menu.footnote = is_intro and "输入秒数、MM:SS 或 HH:MM:SS；例如 90、1:30、0:01:30。"
        or "输入距片尾的秒数、MM:SS 或 HH:MM:SS；例如 90、1:30、0:01:30。"
    menu.search_style = "palette"
    menu.search_debounce = "submit"
    menu.search_suggestion = format_seconds(settings[edit_key])
    menu.on_search = { "script-message-to", SCRIPT_NAME, "skip-intro-outro-configure", edit_key }
  end

  mp.commandv("script-message-to", "uosc", "open-menu", utils.format_json(menu))
end

local function save_settings_or_warn()
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
  if save_settings_or_warn() then
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
  if save_settings_or_warn() then
    mp.osd_message(
      "片尾已设为 " .. format_seconds(settings.skip_intro_outro_outro_skip_duration) .. "（距片尾）",
      2
    )
  end
  open_settings_menu()
end

local function set_skip_time_setting(key, text)
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
  if save_settings_or_warn() then
    mp.osd_message(
      (key == SETTING_INTRO_END_TIME and "片头" or "片尾") .. "已设为 " .. format_seconds(seconds),
      2
    )
  end
  open_settings_menu()
end

local function schedule_intro_skip()
  -- 等待恢复播放位置稳定后，决定是否启动片头倒计时或直接定位。
  if intro_timer then
    intro_timer:kill()
    intro_timer = nil
  end
  if
      intro_skip_cancelled
      or pending_skip
      or not settings.skip_enabled
      or settings.skip_intro_outro_intro_end_time <= 0
      or not loaded_path
  then
    return
  end

  local path = loaded_path
  -- 等待 mpv 应用 watch-later/start 中保存的播放位置，再决定是否跳过片头。
  intro_timer = mp.add_timeout(0.5, function()
    intro_timer = nil
    if
        loaded_path ~= path
        or intro_skip_cancelled
        or pending_skip
        or not settings.skip_enabled
        or settings.skip_intro_outro_intro_end_time <= 0
    then
      return
    end

    local position = mp.get_property_number("time-pos", -1)
    local duration = mp.get_property_number("duration", 0)
    -- 文件尚未准备好时稍后重试，避免过早跳转覆盖恢复位置。
    if position < 0 or duration <= 0 then
      schedule_intro_skip()
      return
    end

    -- 已恢复到片头之后的位置时，说明这是续播，不应再跳回片头。
    if position >= settings.skip_intro_outro_intro_end_time then
      return
    end

    local restored_position = intro_initial_position and intro_initial_position > 0.1
    if settings.skip_intro_outro_intro_end_time < duration and not restored_position then
      local delay = math.max(0, tonumber(settings.skip_intro_outro_intro_skip_delay) or DEFAULT_INTRO_SKIP_DELAY)
      if delay <= 0 then
        intro_skip_cancelled = true
        mp.commandv("seek", serialize_seconds(settings.skip_intro_outro_intro_end_time), "absolute+exact")
      else
        start_countdown("intro", position + delay)
      end
    elseif settings.skip_intro_outro_intro_end_time < duration then
      -- 已恢复到片头结束点之前仍视为续播，保持原有的立即跳转行为。
      mp.commandv("seek", serialize_seconds(settings.skip_intro_outro_intro_end_time), "absolute+exact")
    end
  end)
end

mp.register_script_message("open-skip-intro-outro-settings", function()
  open_settings_menu()
end)

mp.register_script_message("right-pressed", cancel_pending_skip)

mp.register_script_message("set", function(property, value)
  if property ~= EXTERNAL_PROP then
    return
  end
  if not settings_path then
    reset_playback_skip_state()
    settings.skip_enabled = false
    sync_toggle()
    mp.osd_message("片头片尾跳过仅支持本地视频文件", 3)
    return
  end

  settings.skip_enabled = value == "on"
  if not settings.skip_enabled then
    reset_playback_skip_state()
  else
    intro_skip_cancelled = false
    outro_already_skipped = false
    schedule_intro_skip()
  end
  save_settings_or_warn()
  sync_toggle()
end)

mp.register_script_message("skip-intro-outro-configure", function(first, second)
  local event = type(first) == "string" and utils.parse_json(first) or nil
  if event and event.type == "close" then
    schedule_settings_menu_pause_restore()
    return
  end
  if event and event.type == "activate" then
    if event.action == "capture_intro" then
      capture_intro()
    elseif event.action == "capture_outro" then
      capture_outro()
    elseif event.index == 1 then
      settings.skip_enabled = not settings.skip_enabled
      if not settings.skip_enabled then
        reset_playback_skip_state()
      else
        intro_skip_cancelled = false
        outro_already_skipped = false
        schedule_intro_skip()
      end
      save_settings_or_warn()
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
    set_skip_time_setting(first, second)
  end
end)

mp.register_event("start-file", function()
  restore_settings_menu_pause()
  reset_playback_skip_state()
end)

mp.register_event("file-loaded", function()
  restore_settings_menu_pause()
  reset_playback_skip_state()
  local initial_position = mp.get_property_number("time-pos", -1)
  if initial_position >= 0 then
    intro_initial_position = initial_position
  end
  register_settings_button()
  load_settings_for_current_folder()
  sync_toggle()
  schedule_intro_skip()
end)

mp.observe_property("time-pos", "number", function(_, position)
  if
      outro_already_skipped
      or pending_skip
      or not settings.skip_enabled
      or settings.skip_intro_outro_outro_skip_duration <= 0
      or not position
  then
    return
  end

  local duration = mp.get_property_number("duration", 0)
  if duration <= settings.skip_intro_outro_outro_skip_duration then
    return
  end

  if should_start_outro_countdown(position, duration) then
    start_countdown("outro", get_outro_skip_position(duration))
  end
end)

-- 脚本加载时 uosc 可能尚未初始化，因此启动后再尝试注册一次设置按钮。
mp.add_timeout(0.5, register_settings_button)
mp.msg.info("正在运行 片头片尾跳过")
