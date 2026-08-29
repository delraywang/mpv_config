-- 以 uosc.lua 作为脚本入口，确保 mpv 脚本名为 uosc。

local mp = require("mp")

local loader_path = mp.command_native({ "expand-path", "~~/scripts/mpv_script_loader.lua" })
local load_script = dofile(loader_path)

load_script("uosc")
