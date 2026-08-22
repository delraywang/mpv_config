-- RIGHT 短按快进，长按临时加速；片头片尾倒计时期间由跳过脚本消费该按键。
local mp = require("mp")

local HOLD_DELAY = 0.4

-- RIGHT 是否处于按下状态。
local key_down = false
-- RIGHT 是否已经触发长按倍速。
local holding = false
-- 长按前保存的播放速度。
local previous_speed = 1
-- 等待长按触发的定时器。
local hold_timer = nil
-- 当前 RIGHT 按键是否由片头片尾脚本消费。
local right_consumed = false
local RIGHT_CONSUME_PROP = "user-data/skip_intro_outro/consume-right"

-- 停止等待长按触发的定时器。
local function stop_hold_timer()
    if hold_timer then
        hold_timer:kill()
        hold_timer = nil
    end
end

-- 长按达到阈值后切换到临时倍速。
local function begin_hold()
    hold_timer = nil
    if not key_down then return end

    holding = true
    local target_speed = previous_speed < 2 and 2 or 3
    mp.set_property_number("speed", target_speed)
end

-- 处理 RIGHT 的按下和释放事件。
local function handle_right(event)
    if event.event == "down" then
        if key_down then return end

        key_down = true
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
        if not key_down then return end

        key_down = false
        stop_hold_timer()

        if right_consumed then
            right_consumed = false
            holding = false
            return
        end

        if holding then
            mp.set_property_number("speed", previous_speed)
        else
            mp.commandv("seek", "5")
        end

        holding = false
    end
end

mp.add_key_binding("RIGHT", "right_hold_speed", handle_right, {
    complex = true,
    repeatable = true,
})
