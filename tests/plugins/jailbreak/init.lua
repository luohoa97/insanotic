-- SPDX-License-Identifier: GPL-3.0-or-later
-- Test plugin: probes the sandbox. Prints one line per check; every check
-- must report "blocked". Stays enabled (it only uses pcall on its own).
local function check(what, f)
	local ok, err = pcall(f)
	xon.print(what .. ": " .. (ok and "OPEN" or "blocked"))
end
check("io", function() return io.open("/etc/passwd") end)
check("os", function() return os.execute("true") end)
check("debug", function() return debug.getinfo(1) end)
check("package", function() return package.loadlib("libc.so.6", "system") end)
check("dofile", function() return dofile("/etc/passwd") end)
check("loadfile", function() return loadfile("/etc/passwd") end)
check("bytecode", function() assert(load("\27Lua", "x", "b")) end)
check("string.dump", function() return string.dump(print) end)
check("require escape", function() return require("..secret") end)
check("require absolute", function() return require("/etc/passwd") end)
check("private cvar", function() return xon.cvar_string("rcon_password") end)
check("readonly cvar", function() xon.cvar_set("sv_worldname", "x") end)
