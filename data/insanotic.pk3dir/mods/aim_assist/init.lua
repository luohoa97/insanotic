-- SPDX-License-Identifier: GPL-3.0-or-later
-- aim_assist: aim assistance, auto-fire and weapon choice, for touch and
-- for mouse.
--
-- Runs only where it is allowed: local games (you host, e.g. against bots)
-- and servers that allow it. A server allows each part on its own:
-- sv_allow_aim_assist (aim pull, turn to attacker, rocket steering, hit
-- marker), sv_allow_autofire, sv_allow_autoswitch; sv_allow_assist 1
-- allows all three. On any other server a part does nothing, whatever the
-- settings below say.
--
-- aim_assist_mode: 0 off, 1 only while playing with the touchscreen,
-- 2 with any input (default).
--
-- Each frame, for the weapon in hand:
--  * target: the nearest visible enemy within aim_assist_cone degrees of the
--    crosshair and aim_assist_range units, judged at the point the shot has
--    to go to (see lead)
--  * where on the body: the most central part you can see (an enemy half
--    behind cover is aimed at the part that shows); the Rifle aims for the
--    head (aim_assist_rifle_head)
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

-- ammo of the weapon in hand (nil when it needs none)
local function held_ammo()
	for _, wp in ipairs(xon.weapons()) do
		if wp.held then return wp.ammo end
	end
end
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
cvar("aim_assist_autofire_cone", 8, "with aim_assist_lock: fire as soon as the lead point is within this many degrees of the crosshair")
cvar("aim_assist_lead", 1, "1 = lead moving enemies with projectile weapons")
cvar("aim_assist_lead_extra", 0.05, "seconds added to the lead for network delay")
cvar("aim_assist_feet", 1, "1 = splash weapons aim at a standing enemy's feet")
cvar("aim_assist_rifle_head", 1, "1 = the Rifle aims for the head")
cvar("aim_assist_steer", 1, "1 = steer Devastator rockets onto the enemy and detonate them next to it")
cvar("aim_assist_selfdamage_tolerance", 0.2, "share of your health and armor one shot may cost you in self damage (0 = never hurt yourself)")
cvar("aim_assist_turn", 1, "1 = when an enemy hits you, turn toward them (only someone who just hit you and can see you)")
cvar("aim_assist_turn_speed", 12, "how fast the turn toward an attacker is (share of the angle per second)")
cvar("aim_assist_hit_marker", 1, "1 = show where the last hit came from at the edge of the crosshair")
cvar("aim_assist_debug", 0, "1 = print once a second what aim assist sees and why it does or does not fire")
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

-- each feature has its own server permission (sv_allow_aim_assist,
-- sv_allow_autofire, sv_allow_autoswitch; sv_allow_assist allows all)
local function allowed(kind)
	return xon.assist_allowed(kind)
end

local function enabled()
	if not (allowed("aim") or allowed("autofire") or allowed("autoswitch")) then return false end
	local mode = xon.cvar("aim_assist_mode")
	if mode == 2 then return true end
	if mode == 1 then return xon.input_mode() == "touch" end
	return false
end

-- enemies the client can see: {p, dist, center}; teammates go to `friends`
local friends = {}
local function visible_enemies(eye)
	local players = xon.players()
	local _, my_color, my_team = xon.me()
	for _, p in ipairs(players) do
		if p.is_me and not p.alive then return {} end
	end
	local teamplay = xon.teamplay()
	if teamplay == nil then teamplay = true end -- unknown: never aim at your colour
	local out = {}
	friends = {}
	for _, p in ipairs(players) do
		-- teams as the game itself reports them (entcs); the scoreboard
		-- colour only when the server's CSQC does not say
		local mate
		if p.team ~= nil and my_team ~= nil then
			mate = teamplay and p.team == my_team
		else
			mate = teamplay and my_color ~= nil and p.team_color == my_color
		end
		if mate and not p.is_me and p.alive then friends[#friends + 1] = p end
		if not p.is_me and p.alive and not mate then
			local center = p.origin + (p.mins + p.maxs) * 0.5
			local dist = (center - eye):len()
			if dist > 1 then
				-- which parts can be hit: body centre, chest, head, feet. An enemy
				-- behind a low wall or a ledge is still a target through the part
				-- that shows, and the aim goes to that part.
				local cz = (p.mins.z + p.maxs.z) * 0.5
				local parts = {
					{ name = "center", off = V(0, 0, cz) },
					{ name = "chest",  off = V(0, 0, cz + (p.maxs.z - cz) * 0.5) },
					{ name = "head",   off = V(0, 0, p.maxs.z - 8) },
					{ name = "feet",   off = V(0, 0, p.mins.z + 6) },
				}
				local seen, first = {}, nil
				for _, part in ipairs(parts) do
					if xon.traceline(eye, p.origin + part.off).fraction >= 0.999 then
						seen[part.name] = part.off
						first = first or part.off
					end
				end
				if first then
					out[#out + 1] = { p = p, dist = dist, center = center, offset = first, seen = seen }
				end
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

-- self damage: does a blast at `impact` reach you? (only matters when the
-- game hurts players with their own splash, g_balance_selfdamagepercent)
local SELF_MARGIN = 32 -- your own body
local function selfdamage_on()
	return (xon.cvar("g_balance_selfdamagepercent") or 0.65) > 0
end
local function blast_hits_me(eye, impact, w)
	if not w or w.splash <= 0 or not selfdamage_on() then return false end
	if (impact - eye):len() > w.splash + SELF_MARGIN then return false end
	-- inside the blast: acceptable when it costs little of what you have
	local st = xon.stats()
	local pct = xon.cvar("g_balance_selfdamagepercent") or 0.65
	local cost = (w.damage or 100) * pct
	return cost > ((st.health or 0) + (st.armor or 0)) * xon.cvar("aim_assist_selfdamage_tolerance")
end
-- where a shot toward point actually goes off: the first wall in the way, or
-- the point itself
local function impact_point(eye, point)
	local tr = xon.traceline(eye, point)
	return tr.fraction < 1 and tr.endpos or point
end

local last_debug = 0
local function debug(now, fmt, ...)
	if xon.cvar("aim_assist_debug") ~= 0 and now - last_debug >= 1 then
		last_debug = now
		xon.print(string.format(fmt, ...))
	end
end

local state = {
	on_since = nil, last_on = -1,
	steer = nil,            -- { target, fired_at, dir, stop_at }
	last_held = nil, our_switch_at = -100, manual_at = -100, last_switch = -100,
	target = nil,           -- player number we are on
	wounds = {},            -- player number -> damage we dealt since they spawned
	dealt = nil,            -- last damage_dealt total
}

-- who just hurt us: an enemy facing us within 30 degrees with a clear line
-- to our eye, the nearest of them. Only someone who shot at us is ever
-- chosen, so this never points at enemies you could not know about.
local function find_attacker(eye)
	local _, my_color, my_team = xon.me()
	local teamplay = xon.teamplay()
	if teamplay == nil then teamplay = true end
	local best, bestd
	for _, p in ipairs(xon.players()) do
		local mate
		if p.team ~= nil and my_team ~= nil then mate = teamplay and p.team == my_team
		else mate = teamplay and my_color ~= nil and p.team_color == my_color end
		if not p.is_me and p.alive and not mate and p.angles then
			local c = p.origin + (p.mins + p.maxs) * 0.5
			local to_me = (eye - c):normalize()
			local facing = xon.forward(V(0, p.angles.y, 0))
			local flat = V(to_me.x, to_me.y, 0):normalize()
			local d = (eye - c):len()
			if facing * flat > math.cos(math.rad(30)) and xon.traceline(c, eye).fraction >= 0.999
			   and (not bestd or d < bestd) then
				best, bestd = p, d
			end
		end
	end
	return best
end

local function track_hits(eye, now, has_target)
	local st = xon.stats()
	local hp = (st.health or 0) + (st.armor or 0)
	if state.hp and hp < state.hp and st.health > 0 then
		local a = find_attacker(eye)
		if a then
			state.attacker = { num = a.num, at = now, pos = a.origin + (a.mins + a.maxs) * 0.5 }
			-- turn only when not already fighting someone in front of us
			if xon.cvar("aim_assist_turn") ~= 0 and not has_target then
				state.turning = { num = a.num, started = now }
			end
		end
	end
	state.hp = hp
end

-- smooth fast turn toward the attacker; normal assist takes over once they
-- are in front (or after a moment, or when they hide or die)
local function turn_to_attacker(ev, eye, now)
	local tr = state.turning
	if not tr then return false end
	if now - tr.started > 0.7 then state.turning = nil return false end
	local target
	for _, p in ipairs(xon.players()) do
		if p.num == tr.num and p.alive then target = p end
	end
	if not target then state.turning = nil return false end
	local c = target.origin + (target.mins + target.maxs) * 0.5
	if xon.traceline(eye, c).fraction < 0.999 then state.turning = nil return false end
	local want = xon.vectoangles(c - eye)
	local a = ev.angles
	local dy, dx = angle_diff(a.y, want.y), angle_diff(a.x, want.x)
	if math.abs(dy) < 5 and math.abs(dx) < 5 then state.turning = nil return false end
	local k = 1 - math.exp(-xon.cvar("aim_assist_turn_speed") * ev.frametime)
	ev.angles = V(a.x + dx * k, a.y + dy * k, a.z)
	return true
end

-- credit damage we deal to the enemy we are shooting; forget it when they die
local function track_wounds(enemies_all)
	local st = xon.stats()
	if st.damage_dealt then
		if state.dealt and st.damage_dealt > state.dealt and state.target then
			state.wounds[state.target] = (state.wounds[state.target] or 0) + (st.damage_dealt - state.dealt)
		end
		state.dealt = st.damage_dealt
	end
	for _, p in ipairs(enemies_all) do
		if not p.alive then state.wounds[p.num] = nil end
	end
end

-- where the shot leaves the gun: a little right of and below the eye
local MUZZLE_RIGHT, MUZZLE_DOWN = 6, 8
local function axes(angles)
	local f = xon.forward(angles)
	local r = f:cross(V(0, 0, 1)):normalize()
	if r:len() < 0.5 then r = V(0, -1, 0) end
	local u = r:cross(f):normalize()
	return f, r, u
end

-- can a shot aimed from the eye at point reach it? The projectile leaves the
-- muzzle and has some width, so for projectiles the line from the muzzle
-- and two lines offset by the projectile's size must be clear too.
-- Splash weapons may land just short (on the floor or the wall by the
-- target), direct-hit weapons must not.
local function shot_clear(eye, point, w, strict)
	local slack = (w and w.splash > 0) and w.splash * 0.5 or 8
	local function clear(from, to)
		local tr = xon.traceline(from, to)
		return tr.fraction >= 0.995 or (tr.endpos - to):len() <= slack
	end
	if not clear(eye, point) then return false end
	if not w or w.kind == "hitscan" or w.kind == "beam" or w.gravity > 0 then return true end
	local _, r, u = axes(xon.vectoangles(point - eye))
	local muzzle = eye + r * MUZZLE_RIGHT - u * MUZZLE_DOWN
	if not clear(muzzle, point) then return false end
	if not strict then return true end
	local size = 4
	return clear(muzzle + u * size, point + u * size) and clear(muzzle - u * size, point - u * size)
		and clear(muzzle + r * size, point + r * size) and clear(muzzle - r * size, point - r * size)
end

-- candidate points on the body, best first: the Rifle prefers the head,
-- splash weapons a standing enemy's feet, everything else the centre; then
-- the other parts, then the same shifted sideways (around a corner)
local function candidates(p, w, prefer_feet, prefer_head)
	local cz = (p.mins.z + p.maxs.z) * 0.5
	local center = V(0, 0, cz)
	local chest = V(0, 0, cz + (p.maxs.z - cz) * 0.5)
	local head = V(0, 0, p.maxs.z - 8)
	local feet = V(0, 0, p.mins.z + 6)
	local order
	if prefer_head then order = {head, chest, center, feet}
	elseif prefer_feet then order = {feet, center, chest, head}
	else order = {center, chest, head, feet} end
	local out = {}
	for _, o in ipairs(order) do out[#out + 1] = o end
	local side = (p.maxs.x - p.mins.x) * 0.3
	for _, o in ipairs({center, chest, feet}) do
		out[#out + 1] = o + V(side, 0, 0); out[#out + 1] = o - V(side, 0, 0)
		out[#out + 1] = o + V(0, side, 0); out[#out + 1] = o - V(0, side, 0)
	end
	return out
end

-- the enemy to go for (closest to the crosshair, by its centre), then the
-- best point on it a shot can actually reach
local function pick_target(eye, fwd, enemies, w)
	local cone = xon.cvar("aim_assist_cone")
	local range = xon.cvar("aim_assist_range")
	local extra = xon.cvar("aim_assist_lead") ~= 0 and xon.cvar("aim_assist_lead_extra") or 0
	local lead = xon.cvar("aim_assist_lead") ~= 0
	-- who first: lower score wins. Turning less matters most, then the
	-- distance, wounds we already dealt, enemies facing us up close, and
	-- staying on the current target so the view does not flick around
	local ranked = {}
	for _, e in ipairs(enemies) do
		if e.dist <= range then
			local point = lead and P.aim(eye, e.p, w, extra, {}) or e.center
			local off = angle_between((point - eye):normalize(), fwd)
			if off <= cone then
				local score = off / math.max(1, cone) + 0.4 * e.dist / math.max(1, range)
				local hurt = state.wounds[e.p.num] or 0
				score = score - math.min(0.5, hurt / 200)
				if e.p.angles and e.dist < 1500 then
					local facing = xon.forward(V(0, e.p.angles.y, 0))
					local to_me = (eye - e.center):normalize()
					if facing * to_me > 0.9 then score = score - 0.3 end
				end
				if state.target == e.p.num then score = score - 0.35 end
				ranked[#ranked + 1] = { e = e, off = off, score = score }
			end
		end
	end
	table.sort(ranked, function(a, b) return a.score < b.score end)
	for _, r in ipairs(ranked) do
		local e = r.e
		local grounded = P.grounded(e.p)
		local prefer_feet = w and w.splash > 0 and w.kind ~= "hitscan" and grounded and xon.cvar("aim_assist_feet") ~= 0
		local prefer_head = w and w.name == "rifle" and xon.cvar("aim_assist_rifle_head") ~= 0
		local first, tries = nil, {}
		for _, off in ipairs(candidates(e.p, w, prefer_feet, prefer_head)) do
			local point, _, pos
			if lead then
				point, _, pos = P.aim(eye, e.p, w, extra, { offset = off })
			else
				point, pos = e.p.origin + off, e.p.origin
			end
			local t = { e = e, point = point, pos = pos, off = angle_between((point - eye):normalize(), fwd) }
			first = first or t
			tries[#tries + 1] = t
			if shot_clear(eye, point, w, true) then
				t.clear = true
				return t
			end
		end
		-- no point with room for the projectile's width: take one the centre
		-- of the shot still reaches rather than hesitating
		for _, t in ipairs(tries) do
			if shot_clear(eye, t.point, w, false) then
				t.clear = true
				return t
			end
		end
		-- nothing reachable on the nearest enemy: still pull toward it, but
		-- do not shoot; a farther enemy with a clear shot wins over it
		if not ranked.fallback then ranked.fallback = first end
	end
	return ranked.fallback
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
	if xon.cvar("aim_assist_autoswitch") == 0 or state.steer or not allowed("autoswitch") then return end
	local weapons = xon.weapons()
	local held
	for _, wp in ipairs(weapons) do if wp.held then held = wp.name end end
	-- a change we did not ask for is the player's own choice: respect it
	if held ~= state.last_held then
		if state.last_held and now - state.our_switch_at > 1.5 then state.manual_at = now end
		state.last_held = held
	end
	local nearest
	for _, e in ipairs(enemies) do
		if not nearest or e.dist < nearest.dist then nearest = e end
	end
	if not nearest then return end
	-- the weapon in hand would hurt us at this distance: switch now, without
	-- waiting out the timers (it would not fire anyway)
	local held_w = held and W.get(held, held_ammo())
	local urgent = held_w and blast_hits_me(xon.view(), impact_point(xon.view(), nearest.center), held_w)
	if urgent then
		if now - state.last_switch < 0.3 then return end
	else
		if now - state.manual_at < xon.cvar("aim_assist_switch_manual") then return end
		if now - state.last_switch < xon.cvar("aim_assist_switch_delay") then return end
	end
	local v = nearest.p.velocity
	local to = (nearest.center - xon.view()):normalize()
	local lateral = (v - to * (v * to)):len()
	-- the blast would go off at the target or at the first wall before it
	local impact = (impact_point(xon.view(), nearest.center) - xon.view()):len()
	local choice = S.choose(weapons, { dist = nearest.dist, impact = impact, lateral = lateral,
		air = not P.grounded(nearest.p), selfdamage = selfdamage_on(),
		selfdamage_pct = xon.cvar("g_balance_selfdamagepercent") or 0.65,
		tolerance = xon.cvar("aim_assist_selfdamage_tolerance") },
		(xon.stats().health or 0) + (xon.stats().armor or 0), 1.3)
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
	local w = held and W.get(held, held_ammo())
	local enemies = visible_enemies(eye)
	track_wounds(xon.players())

	local can_aim, can_fire = allowed("aim"), allowed("autofire")
	if can_aim and w and w.kind == "guided" and xon.cvar("aim_assist_steer") ~= 0 and steer_devastator(ev, eye, w, now) then
		return
	end

	auto_switch(ev, enemies, now)

	track_hits(eye, now, state.target ~= nil)
	if can_aim and turn_to_attacker(ev, eye, now) then return end

	if w and w.kind == "none" then state.on_since = nil return end
	local t = pick_target(eye, xon.forward(ev.angles), enemies, w)
	state.target = t and t.e.p.num or nil
	local firing = false
	if t then
		local want = xon.vectoangles(t.point - eye)
		-- pull, ramping toward the target, frame-rate independent
		local cone = math.max(0.1, xon.cvar("aim_assist_cone"))
		local ramp = 1 - math.min(1, t.off / cone)
		local lo, hi = xon.cvar("aim_assist_pull_min"), xon.cvar("aim_assist_pull_max")
		local k = 1 - math.exp(-(lo + (hi - lo) * ramp) * ev.frametime)
		local a = ev.angles
		if can_aim then
			ev.angles = V(a.x + angle_diff(a.x, want.x) * k, a.y + angle_diff(a.y, want.y) * k, a.z)
		end
		-- auto-fire against the enlarged body where the shot will meet it
		local half = (t.e.p.maxs - t.e.p.mins) * 0.5 * xon.cvar("aim_assist_hitbox_scale")
		local center = t.pos + (t.e.p.mins + t.e.p.maxs) * 0.5
		local reachable = (not w or w.range[3] >= t.e.dist) and t.e.dist <= xon.cvar("aim_assist_autofire_range")
		local shot_dir = xon.forward(xon.cvar("aim_assist_lock") ~= 0 and want or ev.angles)
		local safe = t.clear and not teammate_in_line(eye, shot_dir, t.e.dist)
			and not blast_hits_me(eye, impact_point(eye, t.point), w)
		-- with the lock, the shot snaps onto the lead point this very frame, so
		-- there is no need to wait for the pull to bring the crosshair over
		-- the lock turns the view: aim assistance, not just auto-fire
		local lock = can_aim and xon.cvar("aim_assist_lock") ~= 0
		local aimed = ray_hits_box(eye, xon.forward(ev.angles), center, half) or t.off < 1
			or (lock and t.off <= xon.cvar("aim_assist_autofire_cone"))
		if can_fire and reachable and safe and xon.cvar("aim_assist_autofire") ~= 0 and aimed then
			state.on_since = state.on_since or now
			state.last_on = now
			if now - state.on_since >= xon.cvar("aim_assist_autofire_delay") then
				firing = true
				if lock then
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
	local lingering = can_fire and state.last_on > 0 and now - state.last_on < xon.cvar("aim_assist_autofire_release")
	if lingering and not firing then
		local fwd = xon.forward(ev.angles)
		local tr = xon.traceline(eye, eye + fwd * 2000)
		if tr.fraction < 0.25 or teammate_in_line(eye, fwd, 2000) or blast_hits_me(eye, tr.endpos, w) then
			lingering = false
		end
	end
	if xon.cvar("aim_assist_debug") ~= 0 then
		local players, _, my_color = xon.players(), xon.me()
		debug(now, "teamplay=%s my_color=%s players=%d enemies=%d target=%s clear=%s off=%.1f firing=%s",
			tostring(xon.teamplay()), tostring(select(2, xon.me())), #players, #enemies,
			t and t.e.p.name or "-", t and tostring(t.clear) or "-", t and t.off or -1, tostring(firing))
	end
	if firing or lingering then
		ev.buttons = ev.buttons | xon.BUTTON_ATTACK
	end
end)

xon.on("Connect", function()
	state.steer, state.last_held = nil, nil
	if xon.cvar("aim_assist_mode") ~= 0 then
		local function word(kind, name) return name .. (allowed(kind) and " on" or " off") end
		xon.print("assistance on this server: " .. word("aim", "aim") .. ", " .. word("autofire", "auto-fire")
			.. ", " .. word("autoswitch", "weapon switch")
			.. " (server cvars sv_allow_aim_assist, sv_allow_autofire, sv_allow_autoswitch)")
	end
end)

-- where the last hit came from: a red dot on a ring around the crosshair,
-- fading out over two seconds
xon.on("HUD", function(ev)
	local a = state.attacker
	if not ev.in_game or not a or xon.cvar("aim_assist_hit_marker") == 0 or not enabled() or not allowed("aim") then return end
	local age = xon.realtime() - a.at
	if age > 2 then return end
	local eye, angles = xon.view()
	local want = xon.vectoangles(a.pos - eye)
	local rel = math.rad(angle_diff(angles.y, want.y)) -- positive: to the left
	local r = math.min(ev.width, ev.height) * 0.18
	local x = ev.width / 2 - math.sin(rel) * r
	local y = ev.height / 2 - math.cos(rel) * r
	local alpha = 1 - age / 2
	xon.draw_circle(x, y, 9, 1, 0.15, 0.1, 0.85 * alpha)
	xon.draw_ring(x, y, 12, 1, 0.6, 0.5, 0.6 * alpha)
end)

