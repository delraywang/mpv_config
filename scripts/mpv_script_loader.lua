-- 复用 mpv Lua 入口脚本的加载逻辑。
-- 调用方仍然是独立的脚本文件，因此 mpv 会保留各自的脚本名称和运行环境。

local mp = require("mp")

local function is_absolute_path(path)
    return type(path) == "string"
        and (path:match("^[A-Za-z]:[/\\]") or path:sub(1, 1) == "/")
end

local function scripts_directory()
    local source = debug.getinfo(1, "S").source:gsub("^@", "")
    return source:match("^(.*)[/\\][^/\\]+$")
end

local function resolve_module_directory(module_name)
    local path = mp.command_native({
        "expand-path",
        "~~/scripts/" .. module_name,
    })

    if is_absolute_path(path) then
        return path
    end

    local base = scripts_directory()
    return base .. "/" .. module_name
end

return function(module_name)
    assert(type(module_name) == "string" and module_name ~= "", "module_name is required")

    local script_dir = resolve_module_directory(module_name)
        :gsub("\\", "/")
        :gsub("/$", "")

    -- main.lua 使用相对于自身目录的 require，例如 lib/std、modules/aes。
    mp.get_script_directory = function()
        return script_dir
    end
    package.path = script_dir .. "/?.lua;"
        .. script_dir .. "/?/init.lua;"
        .. package.path

    return dofile(script_dir .. "/main.lua")
end
