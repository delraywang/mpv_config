-- 以 uosc_danmaku.lua 作为脚本入口，确保 mpv 脚本名为 uosc_danmaku。

local mp = require("mp")

local loader_path = mp.command_native({ "expand-path", "~~/scripts/mpv_script_loader.lua" })
local load_script = dofile(loader_path)

load_script("uosc_danmaku")

-- 原核心完成初始化后加载扩展。加载器会改写 mp.get_script_directory()，
-- 因此这里始终通过 mpv 的 expand-path 从 scripts 根目录解析扩展路径。
local extension_path = mp.command_native({ "expand-path", "~~/scripts/danmaku_merge_extension.lua" })
dofile(extension_path)
