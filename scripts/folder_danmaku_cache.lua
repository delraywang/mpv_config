-- 弹幕开关已改由 uosc_danmaku 直接保存到当前播放目录的 .mpv/settings.conf。
-- 保留本文件仅用于兼容已有的脚本配置。

local mp = require("mp")
local options = require("mp.options")

local opt = { enabled = true }
options.read_options(opt)

if opt.enabled then
    mp.msg.info("弹幕开关使用当前播放目录的 .mpv/settings.conf")
end
