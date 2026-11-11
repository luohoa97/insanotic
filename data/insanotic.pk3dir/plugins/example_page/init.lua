-- SPDX-License-Identifier: GPL-3.0-or-later
-- example_page: opens a page (ui/example_page/page.rml) in a player's game
-- and handles what the page sends back. A player types "cmd page" in the
-- console to see it. See "Pages" in docs/MODDING.md.

local PAGE = "ui/example_page/page.rml"

-- the page is ordinary game data: it has to be in a pk3 of the server's
-- download list, as for any other file the clients need

xon.on("SV_ParseClientCommand", function(ev)
	-- ev[0] player, ev[1] command name, ev[2] number of words
	if ev[1] ~= "page" then
		return false
	end
	ev[0]:show_page(PAGE)
	return true
end)

-- PageReply: a button of a page was pressed.
--   ev[0] the player, ev[1] the page, ev[2] the button's data-reply,
--   ev.values the named fields of the page, by name (all strings).
-- The client sent this, so check it like any other player input.
xon.on("PageReply", function(ev)
	local player, page, action = ev[0], ev[1], ev[2]
	if page ~= PAGE then
		return
	end
	if action == "send" then
		local note = ev.values.note or ""
		local agreed = ev.values.agree == "1"
		player:sprint("^2Thanks! You wrote: ^7" .. note .. (agreed and " ^2(and agreed)" or "") .. "\n")
		xon.print(player.netname .. "^7 sent a note: " .. note)
		player:close_page()
	elseif action == "heal" then
		if player.alive and player.health < 100 then
			player.health = 100
			player:sprint("^2Healed.\n")
		else
			player:sprint("^1Nothing to heal.\n")
		end
	end
end)
