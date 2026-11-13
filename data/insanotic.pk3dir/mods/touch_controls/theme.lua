-- SPDX-License-Identifier: GPL-3.0-or-later
-- The look of the controls: the same as the RmlUi menus. Flat rectangular
-- panels in the shadcn zinc palette with a 1 unit border, the Insanotic blue
-- accent (#4da6ff) for pressed state; weapon buttons show the HUD skin's
-- weapon icons; text uses the HUD font.
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
	-- Overkill
	okshotgun = "ok_weapon_shotgun", okmachinegun = "ok_weapon_smg", oknex = "ok_weapon_rail",
	okhmg = "weaponhmg", okrpc = "weaponrpc", hmg = "weaponhmg", rpc = "weaponrpc",
}

local function parse_rgb(s, default)
	if type(s) ~= "string" then return default end
	local r, g, b = s:match("^%s*([%d%.]+)%s+([%d%.]+)%s+([%d%.]+)")
	if not r then return default end
	return {tonumber(r), tonumber(g), tonumber(b)}
end

-- Xonotic's team colours by colormap index (colormapPaletteColor)
local TEAM_RGB = {
	[4] = {1, 0, 0}, [13] = {0, 0.333333, 1}, [12] = {1, 1, 0}, [9] = {1, 0, 1},
}

-- reads the HUD cvars; call once per frame before drawing. scale is the
-- size of the controls relative to the HUD.
function theme.refresh(scale)
	hud.scale = scale or 1
	hud.border = (xon.cvar("hud_panel_bg_border") or 2) * 4 * hud.scale
	local skin = xon.cvar_string("hud_skin")
	hud.skin = (skin and skin ~= "") and skin or "luma"
	hud.bg = parse_rgb(xon.cvar_string("hud_panel_bg_color"), FALLBACK_BG)
	hud.bg_alpha = xon.cvar("hud_panel_bg_alpha") or 1
	hud.fg_alpha = xon.cvar("hud_panel_fg_alpha") or 1
	-- team games: the panel takes the team colour, like the HUD's panels
	local k = xon.cvar("hud_panel_bg_color_team") or 0
	local tp = xon.teamplay()
	if k > 0 and tp and tp ~= 0 then
		local _, colour = xon.me()
		local c = colour and TEAM_RGB[colour]
		if c then hud.bg = {c[1] * k, c[2] * k, c[3] * k} end
	end
end

-- draws a HUD skin image, falling back to the default skin
local function skin_pic(name, x, y, w, h, r, g, b, a)
	if xon.draw_pic("gfx/hud/" .. hud.skin .. "/" .. name, x, y, w, h, r, g, b, a) then return true end
	return xon.draw_pic("gfx/hud/default/" .. name, x, y, w, h, r, g, b, a)
end

-- a flat panel in the style of the menus: zinc fill, 1 unit zinc border,
-- square corners. "lit" (finger on it) turns it Insanotic blue.
local ZINC_FILL = {0.035, 0.035, 0.043}   -- #09090b
local ZINC_EDGE = {0.247, 0.247, 0.275}   -- #3f3f46
local BLUE = {0.302, 0.651, 1}            -- #4da6ff
local BLUE_DEEP = {0.169, 0.471, 0.788}   -- #2b78c9
function theme.panel(x, y, w, h, lit, opacity)
	local t = math.max(1, hud.scale * 1.5)
	local fill, edge, a = ZINC_FILL, ZINC_EDGE, 0.72 * opacity
	if lit then fill, edge, a = BLUE_DEEP, BLUE, 0.9 * opacity end
	xon.draw_fill(x, y, w, h, fill[1], fill[2], fill[3], a)
	local ea = math.min(1, a * 1.3)
	xon.draw_fill(x, y, w, t, edge[1], edge[2], edge[3], ea)
	xon.draw_fill(x, y + h - t, w, t, edge[1], edge[2], edge[3], ea)
	xon.draw_fill(x, y + t, t, h - 2 * t, edge[1], edge[2], edge[3], ea)
	xon.draw_fill(x + w - t, y + t, t, h - 2 * t, edge[1], edge[2], edge[3], ea)
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
	-- the icon the server's game code names (custom weapons too), else
	-- the stock names by netname
	local icon = weapon.icon or ICONS[weapon.name] or ("weapon" .. weapon.name)
	-- some weapons report a stat that is not an ammo count (a float's
	-- bits read as an integer): show no number for those
	local ammo = weapon.ammo
	if ammo and (ammo < 0 or ammo > 99999) then ammo = nil end
	local ih = h * 0.8
	skin_pic(icon, cx - ih / 2, cy - ih / 2 - h * (ammo and 0.1 or 0), ih, ih, 1, 1, 1, a)
	if ammo then
		centred_text(tostring(ammo), cx, cy + h * 0.32, h * 0.26, a)
	end
end

-- joystick: base where the finger landed, knob under the finger. Zinc base
-- with a thin rim, a blue knob while held.
function theme.stick(bx, by, kx, ky, r, active, opacity)
	local a = opacity
	xon.draw_circle(bx, by, r, ZINC_FILL[1], ZINC_FILL[2], ZINC_FILL[3], 0.6 * a)
	xon.draw_ring(bx, by, r, ZINC_EDGE[1], ZINC_EDGE[2], ZINC_EDGE[3], 0.95 * a)
	local k = active and BLUE or {0.63, 0.63, 0.67}
	xon.draw_circle(kx, ky, r * 0.4, k[1], k[2], k[3], 0.9 * a)
	xon.draw_ring(kx, ky, r * 0.4, 1, 1, 1, 0.5 * a)
end

-- hint where the stick can be placed while no finger is down
function theme.stick_hint(x, y, r, opacity)
	local a = opacity
	xon.draw_circle(x, y, r, ZINC_FILL[1], ZINC_FILL[2], ZINC_FILL[3], 0.3 * a)
	xon.draw_ring(x, y, r, ZINC_EDGE[1], ZINC_EDGE[2], ZINC_EDGE[3], 0.6 * a)
	xon.draw_circle(x, y, r * 0.4, ZINC_EDGE[1], ZINC_EDGE[2], ZINC_EDGE[3], 0.35 * a)
end

return theme
