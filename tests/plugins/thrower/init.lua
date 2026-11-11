-- SPDX-License-Identifier: GPL-3.0-or-later
-- Test plugin: raises an error on the first player spawn. Must be logged
-- with a traceback and disabled.
xon.on("PlayerSpawn", function(ev)
	error("thrower: deliberate failure for " .. tostring(ev[0]))
end)
xon.print("thrower armed")
