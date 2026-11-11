-- SPDX-License-Identifier: GPL-3.0-or-later
-- Test plugin: tries to survive the instruction limit by catching the
-- kill with pcall in a loop. Must still be disabled.
xon.on("SV_StartFrame", function()
	while true do
		pcall(function() while true do end end)
	end
end)
xon.print("sneaky armed")
