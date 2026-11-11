-- SPDX-License-Identifier: GPL-3.0-or-later
-- aim_assist: aim assistance, auto-fire and weapon choice, for touch and
-- for mouse.
--
-- Runs only where it is allowed: local games (you host, e.g. against bots)
-- and servers that set sv_allow_assist 1. On any other server it does
-- nothing, whatever the settings below say.
--
-- aim_assist_mode: 0 off, 1 only while playing with the touchscreen,
-- 2 with any input (default).
--
-- Each frame, for the weapon in hand:
--  * target: the nearest visible enemy within aim_assist_cone degrees of the
--    crosshair and aim_assist_range units, judged at the point the shot has
--    to go to (see lead)
--  * lead: projectile weapons aim where the shot meets a moving enemy,
--    airborne enemies along their fall, lobbed shots (Mortar) higher for the
--    drop; splash weapons aim at a standing enemy's feet (weapons.lua,
--    predict.lua)
--  * pull: turns the view toward that point, from aim_assist_pull_min at the
--    edge of the cone to aim_assist_pull_max on target (share of the error
--    removed per second)
--  * auto-fire: fires while the crosshair ray passes through the enemy's
--    body (scaled by aim_assist_hitbox_scale) at its predicted position,
--    within aim_assist_autofire_range; with aim_assist_lock the shot itself
--    goes exactly to the lead point, so every shot that fires is on target
--  * Devastator: keeps fire held so the rocket follows the crosshair, keeps
--    the crosshair on the enemy, and detonates the rocket (secondary fire)
--    next to them, never next to you
--  * auto-switch: picks the weapon with the best expected damage for the
--    distance, the enemy's movement, your ammo and health (switch.lua);
--    leaves your own choice alone for aim_assist_switch_manual seconds
--
-- Finding players and teams, and reading weapons from the CSQC, follow the
-- approach of Xonotic Touch's touch_aim.c and touch_hud.c.

local W = require("weapons")
local P = require("predict")
local S = require("switch")
local V = xon.vec

local function cvar(name, default, desc)
	xon.cvar_register(name, default, "aim_assist: " .. desc)
end
cvar("aim_assist_mode", 2, "0 = off, 1 = touchscreen only, 2 = any input (always only where the server allows it)")
cvar("aim_assist_cone", 8, "degrees from the crosshair where the pull starts")
cvar("aim_assist_range", 3000, "maximum target distance for the pull")
cvar("aim_assist_pull_min", 1, "pull strength at the edge of the cone (share of the aim error removed per second)")
cvar("aim_assist_pull_max", 6, "pull strength with the crosshair on the target")
cvar("aim_assist_hitbox_scale", 1.25, "enemy body scale for the auto-fire test")
cvar("aim_assist_autofire", 1, "1 = fire while an enemy is under the crosshair")
cvar("aim_assist_autofire_range", 2000, "maximum target distance for auto-fire")
cvar("aim_assist_autofire_delay", 0, "seconds the enemy must stay under the crosshair before firing")
cvar("aim_assist_autofire_release", 0.12, "seconds firing continues after the crosshair leaves the enemy")
cvar("aim_assist_lock", 1, "1 = while auto-fire shoots, aim exactly at the lead point")
cvar("aim_assist_lead", 1, "1 = lead moving enemies with projectile weapons")
cvar("aim_assist_lead_extra", 0.05, "seconds added to the lead for network delay")
cvar("aim_assist_feet", 1, "1 = splash weapons aim at a standing enemy's feet")
cvar("aim_assist_steer", 1, "1 = steer Devastator rockets onto the enemy and detonate them next to it")
cvar("aim_assist_autoswitch", 1, "1 = switch to the best weapon for the fight")
cvar("aim_assist_switch_delay", 1.5, "seconds between automatic weapon switches")
cvar("aim_assist_switch_manual", 4, "seconds auto-switch waits after you choose a weapon yourself")

local ROCKET = 2 -- PROJECTILE_ROCKET

local function angle_diff(a, b)
	local d = (b - a) % 360
	if d > 180 then d = d - 360 end
	return d
end

local function angle_between(dir, fwd)
	return math.deg(math.acos(math.max(-1, math.min(1, dir * fwd))))
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

-- enemies the client can see: {p, dist, center}; teammates go to `friends`
local friends = {}
local function visible_enemies(eye)
	local players = xon.players()
	local _, my_color = xon.me()
	for _, p in ipairs(players) do
		if p.is_me and not p.alive then return {} end
	end
	local teamplay = xon.teamplay()
	if teamplay == nil then teamplay = true end -- unknown: never aim at your colour
	local out = {}
	friends = {}
	for _, p in ipairs(players) do
		local mate = teamplay and my_color ~= nil and p.team_color == my_color
		if mate and not p.is_me and p.alive then friends[#friends + 1] = p end
		if not p.is_me and p.alive and not mate then
			local center = p.origin + (p.mins + p.maxs) * 0.5
			local dist = (center - eye):len()
			if dist > 1 and xon.traceline(eye, center).fraction >= 0.999 then
				out[#out + 1] = { p = p, dist = dist, center = center }
			end
		end
	end
	return out
end

-- would a shot along dir pass through a teammate before reaching dist?
local function teammate_in_line(eye, dir, dist)
	for _, f in ipairs(friends) do
		local c = f.origin + (f.mins + f.maxs) * 0.5
		if (c - eye):len() < dist + 64 and ray_hits_box(eye, dir, c, (f.maxs - f.mins) * 0.5 * 1.3) then
			return true
		end
	end
	return false
end

-- is the way to the aim point open? splash weapons may land on the floor or
-- wall right next to it
local function path_clear(eye, point, w)
	local tr = xon.traceline(eye, point)
	if tr.fraction >= 0.99 then return true end
	local slack = (w and w.splash > 0) and w.splash * 0.5 or 8
	return (tr.endpos - point):len() <= slack
end

-- self damage: does a blast at `impact` reach you? (only matters when the
-- game hurts players with their own splash, g_balance_selfdamagepercent)
local SELF_MARGIN = 32 -- your own body
local function selfdamage_on()
	return (xon.cvar("g_balance_selfdamagepercent") or 0.65) > 0
end
local function blast_hits_me(eye, impact, w)
	if not w or w.splash <= 0 or not selfdamage_on() then return false end
	return (impact - eye):len() <= w.splash + SELF_MARGIN
end
-- where a shot toward point actually goes off: the first wall in the way, or
-- the point itself
local function impact_point(eye, point)
	local tr = xon.traceline(eye, point)
	return tr.fraction < 1 and tr.endpos or point
end

local state = {
	on_since = nil, last_on = -1,
	steer = nil,            -- { target, fired_at, dir, stop_at }
	last_held = nil, our_switch_at = -100, manual_at = -100, last_switch = -100,
}

local function pick_target(eye, fwd, enemies, w)
	local cone = xon.cvar("aim_assist_cone")
	local range = xon.cvar("aim_assist_range")
	local opts = { feet = xon.cvar("aim_assist_feet") ~= 0 }
	local extra = xon.cvar("aim_assist_lead_extra")
	local best
	for _, e in ipairs(enemies) do
		if e.dist <= range then
			local point, pos
			if xon.cvar("aim_assist_lead") ~= 0 then
				point, _, pos = P.aim(eye, e.p, w, extra, opts)
			else
				point, pos = e.center, e.p.origin
			end
			local off = angle_between((point - eye):normalize(), fwd)
			if off <= cone and (not best or off < best.off) then
				best = { e = e, point = point, pos = pos, off = off }
			end
		end
	end
	return best
end

-- the rocket we fired most recently: the one closest to where it should be
local function my_rocket(eye, s)
	local speed = W.get("devastator").speed
	local best, bestd
	local expect = eye + s.dir * (speed * (xon.realtime() - s.fired_at))
	for _, pr in ipairs(xon.projectiles()) do
		if pr.kind == ROCKET then
			local d = (pr.origin - expect):len()
			if d < 400 and (not bestd or d < bestd) then best, bestd = pr, d end
		end
	end
	return best
end

-- Devastator: keep the rocket on the enemy and set it off next to them.
-- Returns true while steering (the caller then leaves the input alone).
local function steer_devastator(ev, eye, w, now)
	local s = state.steer
	if not s then return false end
	if now > s.stop_at then state.steer = nil return false end
	local target
	for _, e in ipairs(visible_enemies(eye)) do
		if e.p.num == s.target then target = e end
	end
	if not target then state.steer = nil return false end
	local want = xon.vectoangles(target.center - eye)
	ev.angles = V(want.x, want.y, ev.angles.z)
	ev.buttons = ev.buttons | xon.BUTTON_ATTACK -- fire held: the rocket follows the view
	local rocket = my_rocket(eye, s)
	if rocket and now - s.fired_at > 0.15 then
		s.dir = (rocket.origin - eye):normalize()
		local near_target = (rocket.origin - target.center):len() <= w.splash * 0.8
		local near_me = (rocket.origin - eye):len() <= w.splash * 1.3
		if near_target and not near_me then
			ev.buttons = (ev.buttons & ~xon.BUTTON_ATTACK) | xon.BUTTON_ATTACK2 -- detonate
			state.steer = nil
		end
	end
	return true
end

local function auto_switch(ev, enemies, now)
	if xon.cvar("aim_assist_autoswitch") == 0 or state.steer then return end
	local weapons = xon.weapons()
	local held
	for _, wp in ipairs(weapons) do if wp.held then held = wp.name end end
	-- a change we did not ask for is the player's own choice: respect it
	if held ~= state.last_held then
		if state.last_held and now - state.our_switch_at > 1.5 then state.manual_at = now end
		state.last_held = held
	end
	if now - state.manual_at < xon.cvar("aim_assist_switch_manual") then return end
	if now - state.last_switch < xon.cvar("aim_assist_switch_delay") then return end
	local nearest
	for _, e in ipairs(enemies) do
		if not nearest or e.dist < nearest.dist then nearest = e end
	end
	if not nearest then return end
	local v = nearest.p.velocity
	local to = (nearest.center - xon.view()):normalize()
	local lateral = (v - to * (v * to)):len()
	-- the blast would go off at the target or at the first wall before it
	local impact = (impact_point(xon.view(), nearest.center) - xon.view()):len()
	local choice = S.choose(weapons, { dist = nearest.dist, impact = impact, lateral = lateral,
		air = not P.grounded(nearest.p), selfdamage = selfdamage_on() }, xon.stats().health, 1.3)
	if choice then
		ev.impulse = choice.impulse
		state.last_switch, state.our_switch_at = now, now
	end
end

xon.on("Input", function(ev)
	if not enabled() then state.on_since, state.steer = nil, nil return end
	local now = xon.realtime()
	local eye = xon.view()
	local held = xon.held_weapon()
	local w = held and W.get(held)
	local enemies = visible_enemies(eye)

	if w and w.kind == "guided" and xon.cvar("aim_assist_steer") ~= 0 and steer_devastator(ev, eye, w, now) then
		return
	end

	auto_switch(ev, enemies, now)

	if w and w.kind == "none" then state.on_since = nil return end
	local t = pick_target(eye, xon.forward(ev.angles), enemies, w)
	local firing = false
	if t then
		local want = xon.vectoangles(t.point - eye)
		-- pull, ramping toward the target, frame-rate independent
		local cone = math.max(0.1, xon.cvar("aim_assist_cone"))
		local ramp = 1 - math.min(1, t.off / cone)
		local lo, hi = xon.cvar("aim_assist_pull_min"), xon.cvar("aim_assist_pull_max")
		local k = 1 - math.exp(-(lo + (hi - lo) * ramp) * ev.frametime)
		local a = ev.angles
		ev.angles = V(a.x + angle_diff(a.x, want.x) * k, a.y + angle_diff(a.y, want.y) * k, a.z)
		-- auto-fire against the enlarged body where the shot will meet it
		local half = (t.e.p.maxs - t.e.p.mins) * 0.5 * xon.cvar("aim_assist_hitbox_scale")
		local center = t.pos + (t.e.p.mins + t.e.p.maxs) * 0.5
		local reachable = (not w or w.range[3] >= t.e.dist) and t.e.dist <= xon.cvar("aim_assist_autofire_range")
		local shot_dir = xon.forward(xon.cvar("aim_assist_lock") ~= 0 and want or ev.angles)
		local safe = path_clear(eye, t.point, w) and not teammate_in_line(eye, shot_dir, t.e.dist)
			and not blast_hits_me(eye, impact_point(eye, t.point), w)
		if reachable and safe and xon.cvar("aim_assist_autofire") ~= 0
		   and (ray_hits_box(eye, xon.forward(ev.angles), center, half) or t.off < 1) then
			state.on_since = state.on_since or now
			state.last_on = now
			if now - state.on_since >= xon.cvar("aim_assist_autofire_delay") then
				firing = true
				if xon.cvar("aim_assist_lock") ~= 0 then
					ev.angles = V(want.x, want.y, ev.angles.z)
				end
				if w and w.kind == "guided" and xon.cvar("aim_assist_steer") ~= 0 then
					state.steer = { target = t.e.p.num, fired_at = now, dir = (t.point - eye):normalize(), stop_at = now + 4 }
				end
			end
		else
			state.on_since = nil
		end
	else
		state.on_since = nil
	end
	-- keep firing briefly after the enemy slips off the crosshair, but only
	-- while nothing (wall, teammate) is right in front of the shot
	local lingering = state.last_on > 0 and now - state.last_on < xon.cvar("aim_assist_autofire_release")
	if lingering and not firing then
		local fwd = xon.forward(ev.angles)
		local tr = xon.traceline(eye, eye + fwd * 2000)
		if tr.fraction < 0.25 or teammate_in_line(eye, fwd, 2000) or blast_hits_me(eye, tr.endpos, w) then
			lingering = false
		end
	end
	if firing or lingering then
		ev.buttons = ev.buttons | xon.BUTTON_ATTACK
	end
end)

xon.on("Connect", function()
	state.steer, state.last_held = nil, nil
	if xon.cvar("aim_assist_mode") ~= 0 then
		xon.print(xon.assist_allowed() and "aim assist available on this server"
			or "aim assist off: this server does not allow it (sv_allow_assist)")
	end
end)
