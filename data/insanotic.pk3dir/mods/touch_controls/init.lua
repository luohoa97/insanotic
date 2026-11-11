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
-- touch_controls_force 1 shows them always. For testing on a desktop:
-- cl_lua_touch_mouse 1 (the left mouse button acts as one finger).

local theme = require("theme")

local function cvar(name, default, desc)
	xon.cvar_register(name, default, "touch_controls: " .. desc)
end
cvar("touch_controls_force", 0, "1 = always show the controls, even with keyboard and mouse")
cvar("touch_controls_size", 1, "scale of all controls")
cvar("touch_controls_opacity", 1, "opacity of all controls (0.2 - 1)")
cvar("touch_controls_look_sensitivity", 0.25, "degrees of turn per screen unit dragged")
cvar("touch_controls_stick_radius", 70, "joystick radius in screen units (before touch_controls_size)")
cvar("touch_controls_stick_deadzone", 0.12, "fraction of the stick radius that does nothing")
cvar("touch_controls_fire_look", 1, "1 = dragging on FIRE also turns the view")

local B = {
	attack = xon.BUTTON_ATTACK, attack2 = xon.BUTTON_ATTACK2,
	jump = xon.BUTTON_JUMP, crouch = xon.BUTTON_CROUCH,
}

-- layout in screen units, recomputed every frame from the screen size
local layout = {}
local function update_layout(w, h)
	local s = xon.cvar("touch_controls_size") * math.min(w, h) / 600
	layout.scale = s
	layout.w, layout.h = w, h
	layout.stick_r = xon.cvar("touch_controls_stick_radius") * s
	layout.stick_zone = { x0 = 0, y0 = h * 0.25, x1 = w * 0.45, y1 = h }
	layout.stick_home = { x = w * 0.16, y = h * 0.72 }
	local br = 44 * s
	layout.buttons = {
		{ id = "fire",   label = "FIRE", x = w - 110 * s, y = h - 120 * s, r = br * 1.35, hold = B.attack, look = true },
		{ id = "alt",    label = "ALT",  x = w - 215 * s, y = h - 70 * s,  r = br * 0.85, hold = B.attack2 },
		{ id = "jump",   label = "JUMP", x = w - 60 * s,  y = h - 240 * s, r = br,        hold = B.jump },
		{ id = "duck",   label = "DUCK", x = w - 175 * s, y = h - 210 * s, r = br * 0.8,  hold = B.crouch },
		-- weapon switching sits left of Xonotic's weapon list on the right edge
		{ id = "next",   label = ">",    x = w - 130 * s, y = h * 0.36,    r = br * 0.62, tap = "weapnext" },
		{ id = "prev",   label = "<",    x = w - 205 * s, y = h * 0.36,    r = br * 0.62, tap = "weapprev" },
		{ id = "menu",   label = "MENU", x = 50 * s,      y = 40 * s,      r = br * 0.6,  tap = "togglemenu" },
		{ id = "chat",   label = "CHAT", x = 125 * s,     y = 40 * s,      r = br * 0.6,  tap = "messagemode" },
		{ id = "score",  label = "TAB",  x = 200 * s,     y = 40 * s,      r = br * 0.6,  press = "+showscores", release = "-showscores" },
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
	return xon.input_mode() == "touch" or xon.cvar("touch_controls_force") ~= 0
end

local function hit_button(x, y)
	for _, b in ipairs(layout.buttons) do
		local dx, dy = x - b.x, y - b.y
		if dx * dx + dy * dy <= (b.r * 1.15) ^ 2 then
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

xon.on("Input", function(ev)
	if not active() then return end
	-- look
	local sens = xon.cvar("touch_controls_look_sensitivity")
	if look_dx ~= 0 or look_dy ~= 0 then
		local a = ev.angles
		ev.angles = xon.vec(math.max(-89, math.min(89, a.x + look_dy * sens)), a.y - look_dx * sens, a.z)
		look_dx, look_dy = 0, 0
	end
	-- move
	if stick then
		local r = layout.stick_r
		local sx, sy = (stick.kx - stick.bx) / r, (stick.ky - stick.by) / r
		local mag = math.sqrt(sx * sx + sy * sy)
		local dead = xon.cvar("touch_controls_stick_deadzone")
		if mag > dead then
			local k = math.min(1, (mag - dead) / (1 - dead)) / mag
			local m = ev.move
			ev.move = xon.vec(m.x - sy * k * (xon.cvar("cl_forwardspeed") or 400),
			                  m.y + sx * k * (xon.cvar("cl_sidespeed") or 400), m.z)
		end
	end
	-- buttons
	local bits = ev.buttons
	for _, b in ipairs(layout.buttons or {}) do
		if b.hold and held[b.id] then bits = bits | b.hold end
	end
	ev.buttons = bits
end)

xon.on("HUD", function(ev)
	if not (active() and ev.in_game) then return end
	update_layout(ev.width, ev.height)
	local o = math.max(0.2, math.min(1, xon.cvar("touch_controls_opacity")))
	if stick then
		theme.stick(stick.bx, stick.by, stick.kx, stick.ky, layout.stick_r, true, o)
	else
		theme.stick_hint(layout.stick_home.x, layout.stick_home.y, layout.stick_r, o * 0.6)
	end
	for _, b in ipairs(layout.buttons) do
		theme.button(b.x, b.y, b.r, b.label, held[b.id], o)
	end
end)

xon.on("Disconnect", release_all)

xon.print("touch controls ready (" .. (xon.has_touch() and "touchscreen found" or "no touchscreen") .. ")")
