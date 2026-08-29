-- RIGHT 短按快进，长按临时加速；长按期间可用 UP/DOWN 微调临时倍速。
-- 片头片尾倒计时期间由跳过脚本消费 RIGHT 按键。
local mp = require("mp")

local HOLD_DELAY = 0.4

-- RIGHT 是否处于按下状态。
local key_down = false
-- RIGHT 是否已经触发长按倍速。
local holding = false
-- 长按前保存的播放速度。
local previous_speed = 1
-- 长按期间使用的临时播放速度。
local temporary_speed = nil
-- 等待长按触发的定时器。
local hold_timer = nil
-- 当前 RIGHT 按键是否由片头片尾脚本消费。
local right_consumed = false
-- RIGHT 是否被其他方向键按下事件取消，需要在方向键松开后重新激活。
local right_binding_canceled = false
local RIGHT_CONSUME_PROP = "user-data/skip_intro_outro/consume-right"

-- 右上角显示临时倍速，使用与弹幕加载提示相同的普通 ASS 文本样式。
local speed_message_overlay = mp.create_osd_overlay("ass-events")

-- 停止等待长按触发的定时器。
local function stop_hold_timer()
  if hold_timer then
    hold_timer:kill()
    hold_timer = nil
  end
end

-- 隐藏右上角的临时倍速提示。
local function hide_temporary_speed_message()
  speed_message_overlay:remove()
end

-- 前置声明：上下方向键释放后重新激活 RIGHT。
local rearm_right_binding

-- 在右上角显示当前临时倍速。
local function show_temporary_speed_message()
  if not temporary_speed then
    return
  end

  local width, height = 1920, 1080
  local osd_width, osd_height = mp.get_osd_size()
  if osd_width and osd_height and osd_width > 0 and osd_height > 0 then
    local ratio = osd_width / osd_height
    if width / height < ratio then
      height = width / ratio
    end
  end

  local speed_text
  if math.abs(temporary_speed - math.floor(temporary_speed)) < 0.000001 then
    speed_text = string.format("%dx", temporary_speed)
  else
    speed_text = string.format("%.1fx", temporary_speed)
  end

  speed_message_overlay.res_x = width
  speed_message_overlay.res_y = height
  speed_message_overlay.data = string.format("{\\an9\\pos(%d,%d)}当前倍速%s", width - 30, 30, speed_text)
  speed_message_overlay:update()
end

-- 移除长按期间临时接管的上下方向键。
local function remove_temporary_speed_bindings()
  mp.remove_key_binding("right_hold_speed_up")
  mp.remove_key_binding("right_hold_speed_down")
end

-- 按上下方向键调整当前临时倍速。
local function handle_temporary_speed_key(event, delta)
  if event.event == "down" or event.event == "repeat" then
    if not key_down or not holding or not temporary_speed then
      return
    end

    -- 按 0.1 的精度计算，避免浮点数累加造成显示误差；最低保持 0.1 倍速。
    temporary_speed = math.max(0.1, math.floor((temporary_speed + delta) * 10 + 0.5) / 10)
    mp.set_property_number("speed", temporary_speed)
    show_temporary_speed_message()
  elseif event.event == "up" and not event.canceled then
    rearm_right_binding()
  end
end

-- 在右键长按期间接管上下方向键，屏蔽它们原本绑定的功能。
local function add_temporary_speed_bindings()
  mp.add_forced_key_binding("UP", "right_hold_speed_up", function(event)
    handle_temporary_speed_key(event, 0.1)
  end, { complex = true })
  mp.add_forced_key_binding("DOWN", "right_hold_speed_down", function(event)
    handle_temporary_speed_key(event, -0.1)
  end, { complex = true })
end

-- 上下方向键松开后重新激活 RIGHT，并刷新上下键绑定。
rearm_right_binding = function()
  if not key_down or not right_binding_canceled then
    return
  end

  right_binding_canceled = false
  -- mpv 在按下第二个键时会取消第一个键的逻辑按下状态；重新发送
  -- keydown 可以恢复 RIGHT 的监听，实际的 RIGHT 松开事件仍会正常到达。
  mp.commandv("keydown", "RIGHT")

  -- 重新创建上下键绑定，清理它们被 RIGHT 恢复动作取消后的按键状态，
  -- 确保下一次上下键按下仍然可以调整临时速度。
  if holding then
    remove_temporary_speed_bindings()
    add_temporary_speed_bindings()
  end
end

-- 长按达到阈值后切换到临时倍速。
local function begin_hold()
  hold_timer = nil
  if not key_down then
    return
  end

  holding = true
  -- 低于 2 倍时提升到 2 倍；达到或超过 2 倍时，在原速度基础上增加 1 倍。
  temporary_speed = previous_speed < 2 and 2 or previous_speed + 1
  mp.set_property_number("speed", temporary_speed)
  add_temporary_speed_bindings()
  show_temporary_speed_message()
end

-- 处理 RIGHT 的按下和释放事件。
local function handle_right(event)
  if event.event == "down" then
    if key_down then
      return
    end

    key_down = true
    right_binding_canceled = false
    stop_hold_timer()

    -- 片头片尾倒计时期间由跳过脚本接管 RIGHT；本次取消按键同时消费按下和释放事件，
    -- 避免触发快进或长按倍速。
    if mp.get_property_bool(RIGHT_CONSUME_PROP, false) then
      -- 先清除共享标记，再通知跳过脚本；本次按键仍会被消费，下一次 RIGHT 恢复原有功能。
      mp.set_property_bool(RIGHT_CONSUME_PROP, false)
      right_consumed = true
      mp.commandv("script-message-to", "skip_intro_outro", "right-pressed")
      return
    end

    right_consumed = false
    holding = false
    previous_speed = mp.get_property_number("speed", 1)
    hold_timer = mp.add_timeout(HOLD_DELAY, begin_hold)
  elseif event.event == "up" then
    if not key_down then
      return
    end

    -- UP/DOWN 等第二个按键会让 mpv 发送一次 canceled 的 RIGHT 释放事件。
    -- 这不是用户真正松开 RIGHT，必须保留长按状态，等待上下方向键松开后重启 RIGHT。
    if event.canceled then
      right_binding_canceled = true
      return
    end

    key_down = false
    stop_hold_timer()
    hide_temporary_speed_message()

    if right_consumed then
      right_consumed = false
      holding = false
      right_binding_canceled = false
      temporary_speed = nil
      return
    end

    if holding then
      remove_temporary_speed_bindings()
      mp.set_property_number("speed", previous_speed)
    else
      mp.commandv("seek", "5")
    end

    holding = false
    right_binding_canceled = false
    temporary_speed = nil
  end
end

mp.add_key_binding("RIGHT", "right_hold_speed", handle_right, {
  complex = true,
  repeatable = true,
})
