-- SPDX-License-Identifier: GPL-3.0-or-later
-- hello: smallest useful Insanotic server plugin.
--  * says hello whenever a player spawns
--  * doubles Devastator (rocket) damage while hello_double_rockets is 1

xon.cvar_register("hello_double_rockets", 1, "hello plugin: 1 = Devastator rockets deal double damage")
xon.cvar_register("hello_verbose", 0, "hello plugin: 1 = log every doubled rocket hit")

xon.on("PlayerSpawn", function(ev)
	local player = ev[0]
	xon.print(player.netname .. "^7 spawned at " .. tostring(player.origin))
end)

-- Damage_Calculate: ev[0] inflictor, ev[1] attacker, ev[2] target,
-- ev[3] deathtype, ev[4] damage (in/out), ev[5] mirror damage (in/out),
-- ev[6] force (in/out). See docs/hooks.md.
xon.on("Damage_Calculate", function(ev)
	if xon.cvar("hello_double_rockets") == 0 then
		return
	end
	local inflictor = ev[0]
	if inflictor and inflictor.classname == "rocket" then
		ev[4] = ev[4] * 2
		if xon.cvar("hello_verbose") ~= 0 then
			local target = ev[2]
			xon.print(string.format("rocket hit on %s: damage doubled to %g",
				target and target.netname or "?", ev[4]))
		end
	end
end)

xon.print("hello from Lua " .. _VERSION .. "; rocket doubling is " ..
	(xon.cvar("hello_double_rockets") ~= 0 and "on" or "off"))
