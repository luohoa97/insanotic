-- SPDX-License-Identifier: GPL-3.0-or-later
-- aim_assist/predict.lua: where to aim so the shot meets a moving target.
local P = {}
local V = xon.vec

-- is a player standing on something (short trace down from the feet)
function P.grounded(p)
	if math.abs(p.velocity.z) > 30 then return false end
	local feet = p.origin + V(0, 0, p.mins.z + 1)
	return xon.traceline(feet, feet - V(0, 0, 12)).fraction < 1
end

-- position of a player after t seconds: straight line, plus falling under
-- gravity when airborne (stopped at the floor below, if any)
function P.position(p, t, gravity, air)
	local pos = p.origin + p.velocity * t
	if air and gravity > 0 then
		pos = pos - V(0, 0, 0.5 * gravity * t * t)
		local floor = xon.traceline(p.origin, V(pos.x, pos.y, pos.z + p.mins.z))
		if floor.fraction < 1 then
			pos = V(pos.x, pos.y, floor.endpos.z - p.mins.z)
		end
	end
	return pos
end

-- aim point for a weapon profile w (see weapons.lua) from eye at player p.
-- Returns the point, the flight time, and the target's predicted origin.
-- extra: seconds of lag to add (the screen shows players slightly late)
function P.aim(eye, p, w, extra, opts)
	local gravity = xon.cvar("sv_gravity") or 800
	local air = not P.grounded(p)
	-- the body part to aim at, relative to the origin (default: centre)
	local center_off = opts.offset or (p.mins + p.maxs) * 0.5
	local t = extra
	local pos = P.position(p, t, gravity, air)
	if w and w.speed and w.kind ~= "hitscan" and w.kind ~= "beam" then
		-- fixed-point iteration on the meeting time
		for _ = 1, 4 do
			local target = pos + center_off
			t = (target - eye):len() / w.speed + extra
			pos = P.position(p, t, gravity, air)
		end
	end
	local point = pos + center_off
	-- splash weapons at a standing target: aim at the floor by its feet, so a
	-- near miss still catches it in the blast
	if opts.feet and w and w.splash > 0 and not air and w.kind ~= "hitscan" then
		point = pos + V(0, 0, p.mins.z + 6)
	end
	-- lobbed projectiles fall on their way: aim higher by the drop
	if w and w.gravity > 0 and w.speed then
		local tt = (point - eye):len() / w.speed
		point = point + V(0, 0, 0.5 * gravity * w.gravity * tt * tt - (w.up or 0) * tt)
	end
	return point, t, pos
end

return P
