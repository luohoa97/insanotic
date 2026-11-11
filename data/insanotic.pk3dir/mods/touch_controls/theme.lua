-- SPDX-License-Identifier: GPL-3.0-or-later
-- The look of the controls: Xonotic's own HUD. Panels use the border image
-- of the player's HUD skin (gfx/hud/<hud_skin>/border_default), tinted with
-- hud_panel_bg_color and hud_panel_bg_alpha like the HUD's own panels; weapon
-- buttons show the skin's weapon icons; text uses the HUD font.
--
-- The engine can only draw a whole image, not a part of one, so the border
-- image is scaled to the panel instead of being cut into a 9-slice. Its
-- corner cuts then grow with the panel, which looks fine at button sizes.
local theme = {}

local FALLBACK_BG = {0, 0.14, 0.25}  -- hud_luma.cfg
local hud = { skin = "luma", bg = FALLBACK_BG, bg_alpha = 1, fg_alpha = 1 }

-- the weapon's netname (xon.weapons()) to the icon file name of the HUD skin
local ICONS = {
	blaster = "weaponlaser", shotgun = "weaponshotgun", machinegun = "weaponuzi",
	mortar = "weapongrenadelauncher", minelayer = "weaponminelayer",
	electro = "weaponelectro", crylink = "weaponcrylink", vortex = "weaponnex",
	hagar = "weaponhagar", devastator = "weaponrocketlauncher",
	porto = "weaponporto", vaporizer = "weaponminstanex", hook = "weaponhook",
	hlac = "weaponhlac", seeker = "weaponseeker", rifle = "weaponrifle",
	fireball = "weaponfireball", tuba = "weapontuba", arc = "weaponarc",
	shockwave = "weaponshockwave",
}

local function parse_rgb(s, default)
	if type(s) ~= "string" then return default end
	local r, g, b = s:match("^%s*([%d%.]+)%s+([%d%.]+)%s+([%d%.]+)")
	if not r then return default end
	return {tonumber(r), tonumber(g), tonumber(b)}
end

-- reads the HUD cvars; call once per frame before drawing
function theme.refresh()
	local skin = xon.cvar_string("hud_skin")
	hud.skin = (skin and skin ~= "") and skin or "luma"
	hud.bg = parse_rgb(xon.cvar_string("hud_panel_bg_color"), FALLBACK_BG)
	hud.bg_alpha = xon.cvar("hud_panel_bg_alpha") or 1
	hud.fg_alpha = xon.cvar("hud_panel_fg_alpha") or 1
end

-- draws a HUD skin image, falling back to the default skin
local function skin_pic(name, x, y, w, h, r, g, b, a)
	if xon.draw_pic("gfx/hud/" .. hud.skin .. "/" .. name, x, y, w, h, r, g, b, a) then return true end
	return xon.draw_pic("gfx/hud/default/" .. name, x, y, w, h, r, g, b, a)
end

local function mix(c, to, k)
	return c[1] + (to[1] - c[1]) * k, c[2] + (to[2] - c[2]) * k, c[3] + (to[3] - c[3]) * k
end

local WHITE = {1, 1, 1}
local ACCENT = {0.55, 0.85, 1}

-- a HUD panel background; "lit" lights it up (finger on it). The HUD's own
-- panels sit on a calm background; these float over the game and have to be
-- found with a thumb, so the panel is drawn twice for body and a rim of
-- weapon_current_bg (the HUD's "selected weapon" frame) marks the button.
function theme.panel(x, y, w, h, lit, opacity)
	local a = math.min(1, hud.bg_alpha * opacity)
	local r, g, b = mix(hud.bg, WHITE, 0.12)
	if lit then
		r, g, b = mix(hud.bg, ACCENT, 0.75)
		a = math.max(a, 0.9 * opacity)
	end
	skin_pic("border_default", x, y, w, h, r, g, b, a)
	skin_pic("border_default", x, y, w, h, r, g, b, a * 0.6)
	skin_pic("weapon_current_bg", x, y, w, h, 1, 1, 1, (lit and 0.9 or 0.3) * opacity)
end

local function centred_text(label, cx, cy, size, a)
	local w = xon.text_width(label, size)
	xon.draw_text(label, cx - w / 2, cy - size / 2, size, 1, 1, 1, a)
end

-- a button centred on (cx, cy): panel plus label
function theme.button(cx, cy, w, h, label, lit, opacity)
	theme.panel(cx - w / 2, cy - h / 2, w, h, lit, opacity)
	if label then
		local size = math.max(10, math.min(h * 0.34, w * 0.42))
		if #label > 3 then size = math.min(size, w * 0.8 / #label * 2) end
		centred_text(label, cx, cy, size, hud.fg_alpha * opacity)
	end
end

-- the weapon in hand: panel, its icon and (when it uses ammo) the ammo count
function theme.weapon(cx, cy, w, h, weapon, lit, opacity)
	theme.panel(cx - w / 2, cy - h / 2, w, h, lit, opacity)
	local a = hud.fg_alpha * opacity
	if not weapon then
		centred_text("-", cx, cy, h * 0.4, a * 0.6)
		return
	end
	local icon = ICONS[weapon.name] or ("weapon" .. weapon.name)
	local ih = h * 0.8
	skin_pic(icon, cx - ih / 2, cy - ih / 2 - h * (weapon.ammo and 0.1 or 0), ih, ih, 1, 1, 1, a)
	if weapon.ammo then
		centred_text(tostring(weapon.ammo), cx, cy + h * 0.32, h * 0.26, a)
	end
end

-- joystick: base where the finger landed, knob under the finger
function theme.stick(bx, by, kx, ky, r, active, opacity)
	local bg, a = hud.bg, math.min(1, hud.bg_alpha * opacity)
	xon.draw_circle(bx, by, r, bg[1], bg[2], bg[3], a * 0.55)
	local rr, rg, rb = mix(bg, active and ACCENT or WHITE, active and 0.7 or 0.45)
	xon.draw_ring(bx, by, r, rr, rg, rb, a * 0.85)
	local kr, kg, kb = mix(bg, active and ACCENT or WHITE, 0.6)
	xon.draw_circle(kx, ky, r * 0.42, kr, kg, kb, a * 0.85)
	xon.draw_ring(kx, ky, r * 0.42, 1, 1, 1, a * 0.7)
end

-- hint where the stick can be placed while no finger is down
function theme.stick_hint(x, y, r, opacity)
	local bg, a = hud.bg, math.min(1, hud.bg_alpha * opacity)
	xon.draw_circle(x, y, r, bg[1], bg[2], bg[3], a * 0.3)
	local rr, rg, rb = mix(bg, WHITE, 0.45)
	xon.draw_ring(x, y, r, rr, rg, rb, a * 0.5)
	xon.draw_circle(x, y, r * 0.42, bg[1], bg[2], bg[3], a * 0.6)
end

return theme
