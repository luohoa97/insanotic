-- SPDX-License-Identifier: GPL-3.0-or-later
-- touch_controls: on-screen controls for touchscreens.
--
-- Left side: a dynamic joystick. It appears where your thumb lands, the
-- knob follows the thumb, and it vanishes when you let go. Dragging past
-- the rim pulls the base along, so you never "fall off" the stick.
-- Right side: drag anywhere to look. Buttons: FIRE (drag on it to aim while
-- shooting), ALT, JUMP, DUCK, weapon next/previous, and MENU / CHAT / SCORE
-- along the top.
--
-- Shown automatically while you play with a touchscreen; they step aside as
-- soon as keyboard or mouse is used, and never appear on a PC without one.
-- touch_controls_force 1 shows them always, -1 never. For testing on a
-- desktop: cl_lua_touch_mouse 1 (the left mouse button acts as one finger).
--
-- Look: the player's HUD skin (see theme.lua).
-- Movement help: touch_controls_autohop jumps again on every landing while
-- JUMP is held; touch_controls_airstrafe turns sideways stick input plus
-- turning the view into proper air strafing (only where assists are allowed).

local theme = require("theme")

local function cvar(name, default, desc)
	xon.cvar_register(name, default, "touch_controls: " .. desc)
end
cvar("touch_controls_force", 0, "0 = show while a touchscreen is used, 1 = always show, -1 = never show")
cvar("touch_controls_size", 1, "scale of all controls")
cvar("touch_controls_opacity", 1, "opacity of all controls (0.2 - 1)")
cvar("touch_controls_look_sensitivity", 0.25, "degrees of turn per screen unit dragged")
cvar("touch_controls_stick_radius", 70, "joystick radius in screen units (before touch_controls_size)")
cvar("touch_controls_stick_deadzone", 0.12, "fraction of the stick radius that does nothing")
cvar("touch_controls_fire_look", 1, "1 = dragging on FIRE also turns the view")
cvar("touch_controls_autohop", 1, "1 = holding JUMP jumps again at every landing (bunny hop)")
cvar("touch_controls_airstrafe", 1, "1 = in the air, sideways stick plus turning the view strafes for speed (only where assists are allowed)")

local B = {
	attack = xon.BUTTON_ATTACK, attack2 = xon.BUTTON_ATTACK2,
	jump = xon.BUTTON_JUMP, crouch = xon.BUTTON_CROUCH,
}

-- layout in screen units, recomputed every frame from the screen size.
-- Buttons are rectangles around (x, y). The right edge is left to Xonotic's
-- weapon list, the top centre and right to its timer and scoreboard, the
-- bottom centre to health and ammo.
local layout = {}
local function update_layout(w, h)
	local s = xon.cvar("touch_controls_size") * math.min(w, h) / 600
	layout.scale = s
	layout.w, layout.h = w, h
	layout.stick_r = xon.cvar("touch_controls_stick_radius") * s
	layout.stick_zone = { x0 = 0, y0 = h * 0.25, x1 = w * 0.45, y1 = h }
	layout.stick_home = { x = w * 0.18, y = h * 0.66 }
	local wy = h * 0.36
	layout.buttons = {
		{ id = "fire",   label = "FIRE", x = w - 115 * s, y = h - 105 * s, w = 112 * s, h = 112 * s, hold = B.attack, look = true },
		{ id = "jump",   label = "JUMP", x = w - 125 * s, y = h - 232 * s, w = 84 * s,  h = 84 * s,  hold = B.jump },
		{ id = "alt",    label = "ALT",  x = w - 245 * s, y = h - 80 * s,  w = 72 * s,  h = 72 * s,  hold = B.attack2 },
		{ id = "duck",   label = "DUCK", x = w - 250 * s, y = h - 175 * s, w = 72 * s,  h = 72 * s,  hold = B.crouch },
		-- weapon switching sits left of Xonotic's weapon list on the right edge
		{ id = "prev",   label = "<",    x = w - 330 * s, y = wy, w = 52 * s, h = 52 * s, tap = "weapprev" },
		{ id = "weapon", weapon = true,  x = w - 240 * s, y = wy, w = 84 * s, h = 62 * s, tap = "weaplast" },
		{ id = "next",   label = ">",    x = w - 150 * s, y = wy, w = 52 * s, h = 52 * s, tap = "weapnext" },
		{ id = "menu",   label = "MENU", x = 50 * s,  y = 36 * s, w = 76 * s, h = 40 * s, tap = "togglemenu" },
		{ id = "chat",   label = "CHAT", x = 134 * s, y = 36 * s, w = 76 * s, h = 40 * s, tap = "messagemode" },
		{ id = "score",  label = "TAB",  x = 218 * s, y = 36 * s, w = 76 * s, h = 40 * s, press = "+showscores", release = "-showscores" },
	}
end

-- finger state, by touch id
local fingers = {}  -- id -> { role, x, y, lx, ly, button, bx, by }
local stick = nil   -- { id, bx, by, kx, ky }
local look_dx, look_dy = 0, 0
local held = {}     -- button id -> true while pressed

-- shown only on a touchscreen that was just used: a PC without one never
-- sees them, a touch laptop hides them as soon as keyboard or mouse is used
local function active()
	local force = xon.cvar("touch_controls_force")
	if force < 0 then return false end
	return force > 0 or xon.input_mode() == "touch"
end

local function hit_button(x, y)
	for _, b in ipairs(layout.buttons) do
		if math.abs(x - b.x) <= b.w * 0.55 and math.abs(y - b.y) <= b.h * 0.55 then
			return b
		end
	end
end

local function in_zone(z, x, y)
	return x >= z.x0 and x <= z.x1 and y >= z.y0 and y <= z.y1
end

local function finger_down(t)
	local f = { x = t.x, y = t.y, lx = t.x, ly = t.y }
	local b = hit_button(t.x, t.y)
	if b then
		f.role, f.button = "button", b
		held[b.id] = true
		if b.tap then xon.command(b.tap) end
		if b.press then xon.command(b.press) end
	elseif not stick and in_zone(layout.stick_zone, t.x, t.y) then
		f.role = "stick"
		stick = { id = t.id, bx = t.x, by = t.y, kx = t.x, ky = t.y }
	else
		f.role = "look"
	end
	fingers[t.id] = f
end

local function finger_move(id, f, t)
	local dx, dy = t.x - f.lx, t.y - f.ly
	f.lx, f.ly = t.x, t.y
	if f.role == "look" or (f.role == "button" and f.button.look and xon.cvar("touch_controls_fire_look") ~= 0) then
		look_dx, look_dy = look_dx + dx, look_dy + dy
	elseif f.role == "stick" and stick then
		local r = layout.stick_r
		local ox, oy = t.x - stick.bx, t.y - stick.by
		local d = math.sqrt(ox * ox + oy * oy)
		if d > r then -- drag the base along behind the thumb
			stick.bx = t.x - ox / d * r
			stick.by = t.y - oy / d * r
		end
		stick.kx, stick.ky = t.x, t.y
	end
end

local function finger_up(id, f)
	if f.role == "button" then
		held[f.button.id] = nil
		if f.button.release then xon.command(f.button.release) end
	elseif f.role == "stick" then
		stick = nil
	end
	fingers[id] = nil
end

local function release_all()
	for id, f in pairs(fingers) do finger_up(id, f) end
	look_dx, look_dy = 0, 0
end

xon.on("Frame", function(ev)
	local on = active() and ev.in_game
	-- only in game: menus keep the engine's own touch-to-mouse handling
	xon.touch_capture(on)
	if not on then
		if next(fingers) then release_all() end
		return
	end
	update_layout(xon.screen_size())
	local seen = {}
	for _, t in ipairs(xon.touches()) do
		seen[t.id] = true
		local f = fingers[t.id]
		if f then finger_move(t.id, f, t) else finger_down(t) end
	end
	for id, f in pairs(fingers) do
		if not seen[id] then finger_up(id, f) end
	end
end)

-- Where the player stands, for the movement helpers: nil when unknown.
-- Returns "ground" or "air".
local function footing(onground)
	if onground ~= nil then return onground and "ground" or "air" end
	local me
	for _, p in ipairs(xon.players()) do
		if p.is_me then me = p break end
	end
	if not me or not me.alive then return nil end
	if me.velocity.z > 30 then return "air" end
	local o = me.origin
	local feet = o.z + me.mins.z
	local tr = xon.traceline(o, xon.vec(o.x, o.y, feet - 2))
	if tr.fraction < 1 and tr.normal.z >= 0.7 then return "ground" end
	return "air"
end

local TURN_MEMORY = 0.15 -- seconds a turn keeps counting after the finger stops moving
local turn_dir, turn_left = 0, 0  -- +1 turning right, -1 turning left
local hop_pressed = false         -- what we sent for JUMP last frame

xon.on("Input", function(ev)
	if not active() then return end
	local dt = ev.frametime or 0
	-- look
	local sens = xon.cvar("touch_controls_look_sensitivity")
	if math.abs(look_dx) > 0.5 then
		turn_dir = look_dx > 0 and 1 or -1  -- dragging right turns the view right
		turn_left = TURN_MEMORY
	else
		turn_left = turn_left - dt
	end
	if look_dx ~= 0 or look_dy ~= 0 then
		local a = ev.angles
		ev.angles = xon.vec(math.max(-89, math.min(89, a.x + look_dy * sens)), a.y - look_dx * sens, a.z)
		look_dx, look_dy = 0, 0
	end
	-- move
	local sx = 0
	if stick then
		local r = layout.stick_r
		local sy
		sx, sy = (stick.kx - stick.bx) / r, (stick.ky - stick.by) / r
		local mag = math.sqrt(sx * sx + sy * sy)
		local dead = xon.cvar("touch_controls_stick_deadzone")
		if mag > dead then
			local k = math.min(1, (mag - dead) / (1 - dead)) / mag
			local m = ev.move
			ev.move = xon.vec(m.x - sy * k * (xon.cvar("cl_forwardspeed") or 400),
			                  m.y + sx * k * (xon.cvar("cl_sidespeed") or 400), m.z)
		else
			sx = 0
		end
	end
	-- buttons
	local bits = ev.buttons
	for _, b in ipairs(layout.buttons or {}) do
		if b.hold and held[b.id] then bits = bits | b.hold end
	end
	-- movement help: needs to know the footing only when it is switched on
	local hop = held.jump and xon.cvar("touch_controls_autohop") ~= 0
	local strafe = math.abs(sx) > 0.35 and turn_left > 0 and xon.cvar("touch_controls_airstrafe") ~= 0 and xon.assist_allowed()
	local where = (hop or strafe) and footing(ev.onground) or nil
	-- bunny hop: Xonotic only jumps on a fresh press, so on the ground the
	-- button is released for one frame between presses. In the air it stays
	-- held (the jetpack and swimming use it).
	if hop and where == "ground" and hop_pressed then
		bits = bits & ~B.jump
	end
	hop_pressed = (bits & B.jump) ~= 0
	-- air strafing: sideways stick while turning means "strafe the way I turn"
	-- with forward held, the standard speed-gaining move
	if strafe and where == "air" then
		ev.move = xon.vec(xon.cvar("cl_forwardspeed") or 400, turn_dir * (xon.cvar("cl_sidespeed") or 400), ev.move.z)
	end
	ev.buttons = bits
end)

xon.on("HUD", function(ev)
	if not (active() and ev.in_game) then return end
	update_layout(ev.width, ev.height)
	theme.refresh(layout.scale)
	local o = math.max(0.2, math.min(1, xon.cvar("touch_controls_opacity")))
	if stick then
		theme.stick(stick.bx, stick.by, stick.kx, stick.ky, layout.stick_r, true, o)
	else
		theme.stick_hint(layout.stick_home.x, layout.stick_home.y, layout.stick_r, o)
	end
	local current
	for _, w in ipairs(xon.weapons()) do
		if w.held then current = w break end
	end
	for _, b in ipairs(layout.buttons) do
		if b.weapon then
			theme.weapon(b.x, b.y, b.w, b.h, current, held[b.id], o)
		else
			theme.button(b.x, b.y, b.w, b.h, b.label, held[b.id], o)
		end
	end
end)

xon.on("Disconnect", release_all)

xon.print("touch controls ready (" .. (xon.has_touch() and "touchscreen found" or "no touchscreen") .. ")")
