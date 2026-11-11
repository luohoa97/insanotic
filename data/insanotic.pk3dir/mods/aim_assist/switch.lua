-- SPDX-License-Identifier: GPL-3.0-or-later
-- aim_assist/switch.lua: pick the weapon that should do the most damage in
-- the current fight.
--
-- Each owned weapon with ammo gets an expected damage per second:
--   dps (balance cvars) x reach (distance vs. the weapon's good range)
--   x hit chance (spread at that distance, projectile flight time against
--   how fast the enemy moves sideways, airborne targets, splash on the floor)
--   x safety (never a weapon whose blast would reach you when self damage
--   is on; less likely ones near that, more so on low health)
--   x Xonotic's bot weapon priority for that distance band.
-- The held weapon gets a bonus so it does not flip-flop, a switch only
-- happens when the best is clearly better, and never shortly after the
-- player picked a weapon by hand.
local S = {}
local W = require("weapons")

local function reach(w, d)
	local lo, hi, max = w.range[1], w.range[2], w.range[3]
	if d > max then return 0 end
	if d < lo then return 0.6 end
	if d <= hi then return 1 end
	return 1 - 0.7 * (d - hi) / math.max(1, max - hi)
end

local function hit_chance(w, d, lateral, air)
	if w.kind == "hitscan" or w.kind == "beam" then
		return math.max(0.25, 1 - w.spread * d / 60)
	end
	local flight = d / math.max(1, w.speed or 1000)
	local miss = math.min(0.9, flight * lateral / (40 + w.splash))
	if w.kind == "guided" then miss = miss * 0.4 end
	local h = 1 - miss
	if air and w.splash < 100 then h = h * 0.75 end
	if not air and w.splash > 0 then h = math.min(1, h + 0.15) end
	return h
end

-- splash you would catch yourself: with self damage on, a weapon whose
-- blast reaches you at this distance is not picked at all; with low health
-- a near-miss distance counts against it too
local function safety(w, target, health)
	if w.splash <= 0 then return 1 end
	local impact = math.min(target.dist, target.impact or target.dist)
	if not target.selfdamage then return 1 end
	if impact <= w.splash + 32 then
		-- in the blast: only worth it when the cost is small next to what we have
		local cost = (w.damage or 100) * (target.selfdamage_pct or 0.65)
		if cost <= health * (target.tolerance or 0) then return 0.5 end
		return 0
	end
	if impact <= w.splash * 1.6 + 32 then return 0.4 end
	if health < 40 and impact < w.splash * 2.5 then return 0.3 end
	return 1
end

-- Xonotic's own bot weapon priorities for close / mid / far range
-- (bot_ai_custom_weapon_priority_*): the order a good player would reach for
-- weapons at that distance. Used as a multiplier between 1.4 (first choice)
-- and 0.8 (last).
local function band_priority(name, dist)
	local d = {}
	for n in (xon.cvar_string("bot_ai_custom_weapon_priority_distances") or "300 850"):gmatch("%S+") do
		d[#d + 1] = tonumber(n)
	end
	local close, far = math.min(d[1] or 300, d[2] or 850), math.max(d[1] or 300, d[2] or 850)
	local band = dist < close and "close" or (dist > far and "far" or "mid")
	local list = xon.cvar_string("bot_ai_custom_weapon_priority_" .. band)
	if not list then return 1 end
	local n, rank = 0, nil
	for wname in list:gmatch("%S+") do
		n = n + 1
		if wname == name then rank = n end
	end
	if not rank or n < 2 then return 1 end
	return 1.4 - 0.6 * (rank - 1) / (n - 1)
end

-- returns the weapon entry (from xon.weapons) to switch to, or nil
-- target: { dist, impact (distance to where a shot goes off), lateral
-- (sideways speed), air, selfdamage }
function S.choose(weapons, target, health, hold_bonus)
	local best, best_score, held, held_score
	for _, wp in ipairs(weapons) do
		local w = W.get(wp.name, wp.ammo)
		local usable = wp.owned and w and w.kind ~= "none" and w.dps and (wp.ammo == nil or wp.ammo > 0 or w.melee)
		if usable then
			local score = w.dps * reach(w, target.dist) * hit_chance(w, target.dist, target.lateral, target.air)
				* safety(w, target, health) * band_priority(wp.name, target.dist)
			if wp.held then
				held, held_score = wp, score * hold_bonus
				score = held_score
			end
			if not best_score or score > best_score then
				best, best_score = wp, score
			end
		end
	end
	if best and best ~= held and (not held_score or best_score > held_score) then
		return best
	end
	return nil
end

return S
