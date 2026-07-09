local mp = require("mp")

local HOLD_DELAY = 0.4

local key_down = false
local holding = false
local previous_speed = 1
local hold_timer = nil

local function stop_timer()
    if hold_timer then
        hold_timer:kill()
        hold_timer = nil
    end
end

local function begin_hold()
    hold_timer = nil
    if not key_down then return end

    holding = true
    local target_speed = previous_speed < 2 and 2 or 3
    mp.set_property_number("speed", target_speed)
end

local function handle_right(event)
    if event.event == "down" then
        if key_down then return end

        key_down = true
        holding = false
        previous_speed = mp.get_property_number("speed", 1)
        stop_timer()
        hold_timer = mp.add_timeout(HOLD_DELAY, begin_hold)
    elseif event.event == "up" then
        if not key_down then return end

        key_down = false
        stop_timer()

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
