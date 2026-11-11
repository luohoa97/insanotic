-- SPDX-License-Identifier: GPL-3.0-or-later
-- netfeel: make high ping feel low. Feedback that normally waits a full
-- round trip to the server happens the moment you act:
--   * fire sound when you fire (weapon ready, ammo left)
--   * hit sound when a hitscan shot (Shotgun, Machinegun, Vortex,
--     Vaporizer, Rifle) crosses an enemy's body on your screen
--   * weapon switch sound when you pick a weapon
-- Each early sound is marked "predicted": when the same sound then arrives
-- from the game within cl_lua_predict_window seconds, the engine drops it,
-- so nothing plays twice. The server still decides what really happened
-- (a predicted hit can rarely be a miss on the server, as in any game with
-- client-side hit feedback).
--
-- Works on any server: it only plays sounds on your side.

local function cvar(name, default, desc)
	xon.cvar_register(name, default, "netfeel: " .. desc)
end
cvar("netfeel_fire", 1, "play the fire sound when you fire, before the server answers")
cvar("netfeel_hit", 1, "play the hit sound when a hitscan shot crosses an enemy on your screen")
cvar("netfeel_switch", 1, "play the weapon switch sound when you pick a weapon")

-- weapon: fire sound as the server names it, refire cvar and default,
-- hitscan or not
local W = {
	blaster    = { "lasergun_fire",     "g_balance_blaster_primary_refire",     0.7 },
	shotgun    = { "shotgun_fire",      "g_balance_shotgun_primary_refire",     0.75, hitscan = true },
	machinegun = { "uzi_fire",          "g_balance_machinegun_sustained_refire", 0.1, hitscan = true },
	mortar     = { "grenade_fire",      "g_balance_mortar_primary_refire",      0.8 },
	minelayer  = { "mine_fire",         "g_balance_minelayer_refire",           1.5 },
	electro    = { "electro_fire",      "g_balance_electro_primary_refire",     0.6 },
	crylink    = { "crylink_fire",      "g_balance_crylink_primary_refire",     0.7 },
	vortex     = { "nexfire",           "g_balance_vortex_primary_refire",      1.5, hitscan = true },
	hagar      = { "hagar_fire",        "g_balance_hagar_primary_refire",       0.167 },
	devastator = { "rocket_fire",       "g_balance_devastator_refire",          1.1 },
	vaporizer  = { "minstanexfire",     "g_balance_vaporizer_primary_refire",   1, hitscan = true },
	hlac       = { "lasergun_fire",     "g_balance_hlac_primary_refire",        0.1 },
	rifle      = { "campingrifle_fire", "g_balance_rifle_primary_refire",       1.5, hitscan = true },
	seeker     = { "seeker_fire",       "g_balance_seeker_missile_refire",      0.5 },
}

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

-- distance to the first enemy body the shot crosses before any wall, or nil
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
			local d = ray_hits_box(eye, dir, p.origin + (p.mins + p.maxs) * 0.5, (p.maxs - p.mins) * 0.5)
			if d and d < wall then return d end
		end
	end
	return nil
end

local state = { last_fire = -100, held = nil }

xon.on("Input", function(ev)
	local now = xon.realtime()
	local held = xon.held_weapon()

	-- weapon switch: a weapon picked by impulse (number keys, scroll,
	-- weapon menu) or the held weapon changing without one
	if xon.cvar("netfeel_switch") ~= 0 and ev.impulse and ev.impulse ~= 0 then
		xon.play_sound("weapons/weapon_switch.wav", 1, true)
	end
	if held ~= state.held then
		state.held = held
		state.last_fire = -100
	end

	local w = held and W[held]
	if not w or (ev.buttons & xon.BUTTON_ATTACK) == 0 then return end
	if now - state.last_fire < refire(w) then return end
	for _, wp in ipairs(xon.weapons()) do
		if wp.held and wp.ammo ~= nil and wp.ammo <= 0 then return end
	end
	state.last_fire = now

	if xon.cvar("netfeel_fire") ~= 0 then
		xon.play_sound("weapons/" .. w[1] .. ".wav", 1, true)
	end
	if w.hitscan and xon.cvar("netfeel_hit") ~= 0 and (xon.cvar("cl_hitsound") or 1) ~= 0 then
		local eye = xon.view()
		if shot_hits_enemy(eye, xon.forward(ev.angles)) then
			xon.play_sound("misc/hit.wav", 1, true)
		end
	end
end)
