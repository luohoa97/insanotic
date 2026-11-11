-- SPDX-License-Identifier: GPL-3.0-or-later
-- Test plugin: loops forever inside a hook. Must be killed by the
-- instruction limit and disabled while the server keeps running.
xon.on("SV_StartFrame", function()
	while true do end
end)
xon.print("runaway armed")
