-- SPDX-License-Identifier: GPL-3.0-or-later
-- Test plugin: allocates without bound. Must hit the memory cap
-- (sv_lua_memory_limit) and be disabled.
local hoard = {}
xon.on("SV_StartFrame", function()
	for i = 1, 1000 do
		hoard[#hoard + 1] = string.rep("x", 65536) .. i
	end
end)
xon.print("memhog armed")
