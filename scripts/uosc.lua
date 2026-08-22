-- 以 uosc.lua 作为脚本入口，确保 mpv 脚本名为 uosc。
-- uosc/main.lua 内部使用 lib/* 相对模块，包装器同时固定其模块目录。

local mp = require("mp")

local function get_script_dir()
    local path = mp.command_native({"expand-path", "~~/scripts/uosc"})
    if type(path) == "string" and path ~= "" and path:match("^[A-Za-z]:[/\\]") then
        return path
    end

    local source = debug.getinfo(1, "S").source:gsub("^@", "")
    local scripts_dir = source:match("^(.*)[/\\][^/\\]+$")
    return scripts_dir .. "\\uosc"
end

local script_dir = get_script_dir():gsub("\\", "/"):gsub("/$", "")
mp.get_script_directory = function() return script_dir end
package.path = script_dir .. "/?.lua;" .. script_dir .. "/?/init.lua;" .. package.path

dofile(script_dir .. "/main.lua")
