-- SPDX-License-Identifier: GPL-3.0-or-later
-- aim_assist/weapons.lua: how each stock weapon fires, for leading shots and
-- for choosing a weapon. Numbers come from the balance cvars the client has
-- (the defaults below are the 0.8.6 values), so a server with the same
-- balance gets exact leads.
--
-- kind:  hitscan | projectile | guided (Devastator) | beam | none
-- splash: blast radius (0 = direct hit only)
-- range: { best_min, best_max, max } in units
-- gravity: share of sv_gravity acting on the projectile
local W = {}

local function c(name, default)
	local v = xon.cvar(name)
	if v == nil or v == 0 then return default end
	return v
end

local defs = {
	blaster    = { kind = "projectile", speed = {"g_balance_blaster_primary_speed", 6000}, splash = 60,  range = {0, 600, 1200},  dmg = {"g_balance_blaster_primary_damage", 20},   refire = {"g_balance_blaster_primary_refire", 0.7} },
	shotgun    = { kind = "hitscan",    spread = 0.12,                                     splash = 0,   range = {0, 350, 900},   dmg = {"g_balance_shotgun_primary_damage", 4},    refire = {"g_balance_shotgun_primary_refire", 0.75}, pellets = {"g_balance_shotgun_primary_bullets", 12} },
	machinegun = { kind = "hitscan",    spread = 0.03,                                     splash = 0,   range = {200, 1500, 3000}, dmg = {"g_balance_machinegun_sustained_damage", 10}, refire = {"g_balance_machinegun_sustained_refire", 0.1} },
	mortar     = { kind = "projectile", speed = {"g_balance_mortar_primary_speed", 1900},  splash = 120, range = {300, 1200, 2000}, dmg = {"g_balance_mortar_primary_damage", 55},  refire = {"g_balance_mortar_primary_refire", 0.8}, gravity = 1, up = {"g_balance_mortar_primary_speed_up", 225} },
	minelayer  = { kind = "projectile", speed = {"g_balance_minelayer_speed", 1000},       splash = 175, range = {300, 800, 1400},  dmg = {"g_balance_minelayer_damage", 42},        refire = {"g_balance_minelayer_refire", 1.5} },
	electro    = { kind = "projectile", speed = {"g_balance_electro_primary_speed", 2500}, splash = 100, range = {150, 1000, 2000}, dmg = {"g_balance_electro_primary_damage", 40}, refire = {"g_balance_electro_primary_refire", 0.6} },
	crylink    = { kind = "projectile", speed = {"g_balance_crylink_primary_speed", 2000}, splash = 80,  range = {0, 500, 1200},   dmg = {"g_balance_crylink_primary_damage", 10},  refire = {"g_balance_crylink_primary_refire", 0.7}, pellets = {"g_balance_crylink_primary_shots", 6} },
	vortex     = { kind = "hitscan",    spread = 0,                                        splash = 0,   range = {400, 4000, 8000}, dmg = {"g_balance_vortex_primary_damage", 80},  refire = {"g_balance_vortex_primary_refire", 1.5} },
	hagar      = { kind = "projectile", speed = {"g_balance_hagar_primary_speed", 2200},   splash = 65,  range = {150, 900, 1800},  dmg = {"g_balance_hagar_primary_damage", 25},    refire = {"g_balance_hagar_primary_refire", 0.167} },
	devastator = { kind = "guided",     speed = {"g_balance_devastator_speed", 1300},      splash = 110, range = {350, 1500, 4000}, dmg = {"g_balance_devastator_damage", 80},       refire = {"g_balance_devastator_refire", 1.1} },
	vaporizer  = { kind = "hitscan",    spread = 0,                                        splash = 0,   range = {0, 5000, 8000},   dmg = {"g_balance_vaporizer_primary_damage", 150}, refire = {"g_balance_vaporizer_primary_refire", 1} },
	hlac       = { kind = "projectile", speed = {"g_balance_hlac_primary_speed", 6000},    splash = 70,  range = {0, 700, 1500},    dmg = {"g_balance_hlac_primary_damage", 18},     refire = {"g_balance_hlac_primary_refire", 0.1} },
	rifle      = { kind = "hitscan",    spread = 0,                                        splash = 0,   range = {500, 5000, 8000}, dmg = {"g_balance_rifle_primary_damage", 80},   refire = {"g_balance_rifle_primary_refire", 1.5} },
	seeker     = { kind = "projectile", speed = {"g_balance_seeker_missile_speed", 1000},  splash = 80,  range = {200, 1000, 2000}, dmg = {"g_balance_seeker_missile_damage", 25},   refire = {"g_balance_seeker_missile_refire", 0.5} },
	fireball   = { kind = "projectile", speed = {"g_balance_fireball_primary_speed", 1200}, splash = 200, range = {500, 1000, 2000}, dmg = {"g_balance_fireball_primary_damage", 200}, refire = {"g_balance_fireball_primary_refire", 2} },
	arc        = { kind = "beam",       spread = 0,                                        splash = 0,   range = {0, 800, 1000},    dmg = {"g_balance_arc_beam_damage", 115},        refire = {"", 1} },
	-- tools, not for shooting players on their own
	porto = { kind = "none" }, hook = { kind = "none" }, tuba = { kind = "none" },
}

-- profile for a weapon by its netname, with current balance values; nil
-- for weapons this mod does not know (a mod's weapon: fired as hitscan)
function W.get(name)
	local d = defs[name]
	if not d then return nil end
	local p = { name = name, kind = d.kind, splash = d.splash or 0, range = d.range or {0, 1000, 3000},
		spread = d.spread or 0, gravity = d.gravity or 0 }
	if d.speed then p.speed = c(d.speed[1], d.speed[2]) end
	if d.up then p.up = c(d.up[1], d.up[2]) end
	if d.dmg then
		p.damage = c(d.dmg[1], d.dmg[2]) -- one projectile / pellet
		local dmg = p.damage * (d.pellets and c(d.pellets[1], d.pellets[2]) or 1)
		local refire = math.max(0.05, c(d.refire[1], d.refire[2]))
		p.dps = dmg / refire
	end
	return p
end

return W
