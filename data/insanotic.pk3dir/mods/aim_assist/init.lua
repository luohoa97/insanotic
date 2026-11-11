-- SPDX-License-Identifier: GPL-3.0-or-later
-- aim_assist: aim assistance and auto-fire, for touch and for mouse.
--
-- Runs only where it is allowed: local games (you host, e.g. against bots)
-- and servers that set sv_allow_assist 1. On any other server it does
-- nothing, whatever the settings below say.
--
-- aim_assist_mode: 0 off, 1 only while playing with the touchscreen,
-- 2 with any input (default).
--
-- What it does, each frame:
--  * finds the nearest visible enemy within aim_assist_cone degrees of
--    the crosshair and aim_assist_range units
--  * magnetism: turns the view toward it, never snapping. The strength
--    ramps from aim_assist_pull_min at the edge of the cone to
--    aim_assist_pull_max with the crosshair on the target (share of the
--    remaining aim error removed per second)
--  * auto-fire: holds fire while the crosshair ray passes through the
--    enemy's body scaled by aim_assist_hitbox_scale, within
--    aim_assist_autofire_range units, after aim_assist_autofire_delay s
--
-- Finding players and teams follows the approach of Xonotic Touch's
-- touch_aim.c (see xon.players in docs/MODDING.md).

local function cvar(name, default, desc)
	xon.cvar_register(name, default, "aim_assist: " .. desc)
end
cvar("aim_assist_mode", 2, "0 = off, 1 = touchscreen only, 2 = any input (always only where the server allows it)")
cvar("aim_assist_cone", 8, "degrees from the crosshair where the pull starts")
cvar("aim_assist_range", 3000, "maximum target distance for the pull")
cvar("aim_assist_pull_min", 1, "pull strength at the edge of the cone (share of the aim error removed per second)")
cvar("aim_assist_pull_max", 6, "pull strength with the crosshair on the target")
cvar("aim_assist_autofire_range", 2000, "maximum target distance for auto-fire")
cvar("aim_assist_hitbox_scale", 1.25, "enemy body scale for the auto-fire test")
cvar("aim_assist_autofire", 1, "1 = fire while an enemy is under the crosshair")
cvar("aim_assist_autofire_delay", 0.08, "seconds the enemy must stay under the crosshair before firing")
cvar("aim_assist_autofire_release", 0.12, "seconds firing continues after the crosshair leaves the enemy")

local V = xon.vec

local function angle_diff(a, b)
	local d = (b - a) % 360
	if d > 180 then d = d - 360 end
	return d
end

local function ray_hits_box(start, dir, center, half)
	local tmin, tmax = 0, math.huge
	for _, k in ipairs({"x", "y", "z"}) do
		local lo, hi = center[k] - half[k], center[k] + half[k]
		if math.abs(dir[k]) < 1e-6 then
			if start[k] < lo or start[k] > hi then return false end
		else
			local t1, t2 = (lo - start[k]) / dir[k], (hi - start[k]) / dir[k]
			if t1 > t2 then t1, t2 = t2, t1 end
			tmin, tmax = math.max(tmin, t1), math.min(tmax, t2)
			if tmin > tmax then return false end
		end
	end
	return true
end

local function enabled()
	if not xon.assist_allowed() then return false end
	local mode = xon.cvar("aim_assist_mode")
	if mode == 2 then return true end
	if mode == 1 then return xon.input_mode() == "touch" end
	return false
end

-- returns target center, half size, and whether it is visible, for the
-- enemy nearest to the crosshair within the cone
local function find_target(eye, fwd)
	local players = xon.players()
	local my_color
	for _, p in ipairs(players) do
		if p.is_me then my_color = p.team_color; if not p.alive then return nil end end
	end
	-- unknown teamplay counts as a team game: never aim at your own colour
	local teamplay = xon.teamplay()
	if teamplay == nil then teamplay = true end
	local cos_cone = math.cos(math.rad(xon.cvar("aim_assist_cone")))
	local range = xon.cvar("aim_assist_range")
	local best_c, center, half, best_dist
	for _, p in ipairs(players) do
		if not p.is_me and p.alive and not (teamplay and my_color and p.team_color == my_color) then
			local c = p.origin + (p.mins + p.maxs) * 0.5
			local d = c - eye
			local dist = d:len()
			if dist > 1 and dist <= range then
				local cosang = (d / dist) * fwd
				if cosang >= cos_cone and (not best_c or cosang > best_c)
				   and xon.traceline(eye, c).fraction >= 0.999 then
					best_c, center, half, best_dist = cosang, c, (p.maxs - p.mins) * 0.5, dist
				end
			end
		end
	end
	-- angle from the crosshair, for the pull ramp
	local off = best_c and math.deg(math.acos(math.min(1, best_c))) or nil
	return center, half, best_dist, off
end

local on_since, last_on = nil, -1

xon.on("Input", function(ev)
	if not enabled() then on_since = nil return end
	local eye = xon.view()
	local fwd = xon.forward(ev.angles)
	local center, half, dist, off = find_target(eye, fwd)
	local now = xon.realtime()
	if center then
		-- magnetism, frame-rate independent
		local want = xon.vectoangles(center - eye)
		local cone = math.max(0.1, xon.cvar("aim_assist_cone"))
		local t = 1 - math.min(1, off / cone) -- 0 at the cone edge, 1 on target
		local lo, hi = xon.cvar("aim_assist_pull_min"), xon.cvar("aim_assist_pull_max")
		local k = 1 - math.exp(-(lo + (hi - lo) * t) * ev.frametime)
		local a = ev.angles
		ev.angles = V(a.x + angle_diff(a.x, want.x) * k, a.y + angle_diff(a.y, want.y) * k, a.z)
		-- auto-fire against the enlarged body
		if xon.cvar("aim_assist_autofire") ~= 0 and dist <= xon.cvar("aim_assist_autofire_range")
		   and ray_hits_box(eye, xon.forward(ev.angles), center, half * xon.cvar("aim_assist_hitbox_scale")) then
			on_since = on_since or now
			last_on = now
		else
			on_since = nil
		end
	else
		on_since = nil
	end
	local firing = (on_since and now - on_since >= xon.cvar("aim_assist_autofire_delay"))
		or (now - last_on < xon.cvar("aim_assist_autofire_release") and last_on > 0)
	if firing then
		ev.buttons = ev.buttons | xon.BUTTON_ATTACK
	end
end)

xon.on("Connect", function()
	if xon.cvar("aim_assist_mode") ~= 0 then
		xon.print(xon.assist_allowed() and "aim assist available on this server"
			or "aim assist off: this server does not allow it (sv_allow_assist)")
	end
end)
