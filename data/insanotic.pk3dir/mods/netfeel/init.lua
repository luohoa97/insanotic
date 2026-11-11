-- SPDX-License-Identifier: GPL-3.0-or-later
-- netfeel: make high ping feel low. Feedback that normally waits a full
-- round trip to the server happens the moment you act:
--   * fire sound when you fire (weapon ready, ammo left)
--   * hit sound when a hitscan shot (Shotgun, Machinegun, Vortex,
--     Vaporizer, Rifle) crosses an enemy's body on your screen
--   * weapon switch sound when you pick a weapon
-- Each early sound is marked "predicted": when the same sound then arrives
-- from the game within cl_lua_predict_window seconds, the engine drops it,
-- so nothing plays twice.
--
-- A sound is only played early when the shot is sure to happen: you are
-- alive and playing, the match is running, the weapon is up (not switching
-- or reloading) and has the ammo for a shot. The engine also tells the mod
-- whether each early sound was then confirmed by the game; after two wrong
-- guesses in a row (a server with other weapon settings, a shot the server
-- refused) that kind of sound waits for the server again for a while.
--
-- Works on any server: it only plays sounds on your side.

local function cvar(name, default, desc)
	xon.cvar_register(name, default, "netfeel: " .. desc)
end
cvar("netfeel_fire", 1, "play the fire sound when you fire, before the server answers")
cvar("netfeel_hit", 1, "play the hit sound when a hitscan shot crosses an enemy on your screen")
cvar("netfeel_switch", 1, "play the weapon switch sound when you pick a weapon")

-- weapon: fire sound as the server names it, refire cvar and default,
-- ammo per shot, hitscan, and up to which distance a hit is predicted
-- (spread weapons scatter beyond it)
local W = {
	blaster    = { "lasergun_fire",     "g_balance_blaster_primary_refire",      0.7,   0 },
	shotgun    = { "shotgun_fire",      "g_balance_shotgun_primary_refire",      0.75,  1, hitscan = 600 },
	machinegun = { "uzi_fire",          "g_balance_machinegun_sustained_refire", 0.1,   1, hitscan = 1200 },
	mortar     = { "grenade_fire",      "g_balance_mortar_primary_refire",       0.8,   2 },
	minelayer  = { "mine_fire",         "g_balance_minelayer_refire",            1.5,   4 },
	electro    = { "electro_fire",      "g_balance_electro_primary_refire",      0.6,   4 },
	crylink    = { "crylink_fire",      "g_balance_crylink_primary_refire",      0.7,   3 },
	vortex     = { "nexfire",           "g_balance_vortex_primary_refire",       1.5,   6, hitscan = math.huge },
	hagar      = { "hagar_fire",        "g_balance_hagar_primary_refire",        0.167, 1 },
	devastator = { "rocket_fire",       "g_balance_devastator_refire",           1.1,   4 },
	vaporizer  = { "minstanexfire",     "g_balance_vaporizer_primary_refire",    1,     1, hitscan = math.huge },
	hlac       = { "lasergun_fire",     "g_balance_hlac_primary_refire",         0.1,   1 },
	rifle      = { "campingrifle_fire", "g_balance_rifle_primary_refire",        1.5,   10, hitscan = math.huge },
	seeker     = { "seeker_fire",       "g_balance_seeker_missile_refire",       0.5,   2 },
}
-- time a weapon needs to come up after a switch (switchdelay_raise)
local RAISE = 0.25

local function refire(w)
	local v = xon.cvar(w[2])
	if not v or v <= 0 then v = w[3] end
	return v
end

local function ray_hits_box(start, dir, center, half)
	local tmin, tmax = 0, math.huge
	for _, k in ipairs({"x", "y", "z"}) do
		local lo, hi = center[k] - half[k], center[k] + half[k]
		if math.abs(dir[k]) < 1e-6 then
			if start[k] < lo or start[k] > hi then return nil end
		else
			local t1, t2 = (lo - start[k]) / dir[k], (hi - start[k]) / dir[k]
			if t1 > t2 then t1, t2 = t2, t1 end
			tmin, tmax = math.max(tmin, t1), math.min(tmax, t2)
			if tmin > tmax then return nil end
		end
	end
	return tmin
end

-- distance to the first enemy body the shot crosses before any wall, or
-- nil. Only the core of the body counts (players on your screen are a
-- little behind where the server has them, so edge hits are guesses).
local function shot_hits_enemy(eye, dir)
	local _, my_color, my_team = xon.me()
	local teamplay = xon.teamplay()
	if teamplay == nil then teamplay = true end
	local wall = xon.traceline(eye, eye + dir * 16384).fraction * 16384
	for _, p in ipairs(xon.players()) do
		local mate
		if p.team ~= nil and my_team ~= nil then mate = teamplay and p.team == my_team
		else mate = teamplay and my_color ~= nil and p.team_color == my_color end
		if not p.is_me and p.alive and not mate then
			local d = ray_hits_box(eye, dir, p.origin + (p.mins + p.maxs) * 0.5, (p.maxs - p.mins) * 0.35)
			if d and d < wall then return d end
		end
	end
	return nil
end

local function float_stat(name)
	local _, f = xon.stat(name)
	return f
end

-- true when a shot pressed now would really be fired by the server
local function can_fire(now)
	local _, _, _, dead, spectator = xon.me()
	if dead or spectator then return false end
	if (xon.stats().health or 0) <= 0 then return false end
	local t = xon.time()
	local start = float_stat("GAMESTARTTIME")
	if start and start > t then return false end -- countdown
	local round = float_stat("ROUNDSTARTTIME")
	if round and round > t then return false end
	if (xon.stat("GAME_STOPPED") or 0) ~= 0 then return false end
	if (xon.stat("FROZEN") or 0) ~= 0 then return false end
	if (xon.stat("TIMEOUT_STATUS") or 0) == 2 then return false end
	return true
end

-- guesses waiting for the game's answer, and the back-off per kind
local pending = {}
local misses = { fire = 0, hit = 0 }
local paused_until = { fire = 0, hit = 0 }

local function predict(kind, path, now)
	if now < paused_until[kind] then return end
	local ticket = xon.play_sound(path, 1, true)
	if type(ticket) == "number" then
		pending[#pending + 1] = { ticket = ticket, kind = kind, time = now }
	end
end

local function check_guesses(now)
	local i = 1
	while i <= #pending do
		local g = pending[i]
		local ok = xon.sound_confirmed(g.ticket)
		if ok == nil and now - g.time > 3 then
			table.remove(pending, i) -- too old to know
		elseif ok == nil then
			i = i + 1 -- still waiting
		else
			if ok then
				misses[g.kind] = 0
			else
				misses[g.kind] = misses[g.kind] + 1
				if misses[g.kind] >= 2 then
					paused_until[g.kind] = now + 5
					misses[g.kind] = 0
				end
			end
			table.remove(pending, i)
		end
	end
end

local state = { last_fire = -100, held = nil, held_since = -100 }

xon.on("Input", function(ev)
	local now = xon.realtime()
	local held = xon.held_weapon()
	check_guesses(now)

	-- weapon switch: a weapon picked by impulse (number keys, scroll,
	-- weapon menu)
	if xon.cvar("netfeel_switch") ~= 0 and ev.impulse and ev.impulse ~= 0 then
		xon.play_sound("weapons/weapon_switch.wav", 1, true)
	end
	if held ~= state.held then
		state.held = held
		state.held_since = now
		state.last_fire = -100
	end

	local w = held and W[held]
	if not w or (ev.buttons & xon.BUTTON_ATTACK) == 0 then return end
	if now - state.last_fire < refire(w) then return end
	if now - state.held_since < RAISE then return end
	local ws = xon.weapon_state()
	if not ws or ws.switching then return end
	if ws.clip_size and ws.clip_size > 0 and (ws.clip_load or 0) < math.max(w[4], 1) then return end
	for _, wp in ipairs(xon.weapons()) do
		if wp.held and wp.ammo ~= nil and wp.ammo < w[4] then return end
	end
	if not can_fire(now) then return end
	state.last_fire = now

	if xon.cvar("netfeel_fire") ~= 0 then
		predict("fire", "weapons/" .. w[1] .. ".wav", now)
	end
	if w.hitscan and xon.cvar("netfeel_hit") ~= 0 and (xon.cvar("cl_hitsound") or 1) ~= 0 then
		local d = shot_hits_enemy(xon.view(), xon.forward(ev.angles))
		if d and d <= w.hitscan then
			predict("hit", "misc/hit.wav", now)
		end
	end
end)
