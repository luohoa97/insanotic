-- SPDX-License-Identifier: GPL-3.0-or-later
-- Colours and shapes in the spirit of Xonotic's default "luma" menu skin:
-- dark glass panels, a thin cool rim, light-blue accent when pressed.
local theme = {
	panel   = {0.04, 0.06, 0.09, 0.45},
	rim     = {0.70, 0.82, 1.00, 0.55},
	accent  = {0.30, 0.68, 1.00, 0.85},
	knob    = {0.85, 0.92, 1.00, 0.80},
	label   = {1.00, 1.00, 1.00, 0.92},
	dim     = {1.00, 1.00, 1.00, 0.35},
}

local function rgba(c, alpha_scale)
	return c[1], c[2], c[3], c[4] * (alpha_scale or 1)
end

-- round button: glass disc, rim, centred label
function theme.button(x, y, r, label, pressed, opacity)
	local o = opacity or 1
	xon.draw_circle(x, y, r, rgba(pressed and theme.accent or theme.panel, o))
	xon.draw_ring(x, y, r, rgba(theme.rim, o))
	if label then
		local size = math.max(10, r * 0.42)
		local w = xon.text_width(label, size)
		xon.draw_text(label, x - w / 2, y - size / 2, size, rgba(theme.label, o))
	end
end

-- joystick: base ring where the finger landed, knob under the finger
function theme.stick(bx, by, kx, ky, r, active, opacity)
	local o = opacity or 1
	xon.draw_circle(bx, by, r, rgba(theme.panel, o))
	xon.draw_ring(bx, by, r, rgba(active and theme.accent or theme.rim, o))
	xon.draw_circle(kx, ky, r * 0.42, rgba(theme.knob, o))
	xon.draw_ring(kx, ky, r * 0.42, rgba(theme.rim, o))
end

-- hint where the stick can be placed while no finger is down
function theme.stick_hint(x, y, r, opacity)
	xon.draw_ring(x, y, r, rgba(theme.dim, opacity or 1))
	xon.draw_circle(x, y, r * 0.42, rgba(theme.panel, opacity or 1))
end

return theme
