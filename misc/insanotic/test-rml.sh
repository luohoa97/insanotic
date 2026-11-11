#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# End-to-end test of the RmlUi main menu. Starts the client in a window (so it
# needs a display), waits for the menu and checks that
#   - ui/mainmenu.rml and its stylesheet load without a warning,
#   - the document is the one that is showing (rml_list),
#   - a click on the Settings button runs its command, and the menu answers by
#     opening the Settings dialog, which takes the RmlUi menu away again,
#   - closing that dialog brings it back,
#   - on a touch screen a drag scrolls a list (tests/ui/scrolltest.rml), and a
#     tap on one of its rows runs that row's command,
#   - the Quick settings dialog shows cvars and writes them back (data-cvar),
#   - pages from a server (tests/ui/evil/page.rml, and the example_page
#     plugin): a Lua plugin opens one and hears its answer, a hostile page
#     cannot run a local command or read a cvar, its band closes it, and
#     cl_allow_server_pages 0 refuses it.
# The pixel positions are for 1280x720: (1000, 400) is the Settings button, the
# third of the row of three. A fresh profile would first show the first-run
# dialog, so the player name is set.
#
#   misc/insanotic/test-rml.sh        (from the repository root)
#
# Needs the SDL client and the compiled QC ("make insanotic-client insanotic-qc").

set -u

ENGINE=${ENGINE:-./darkplaces/darkplaces-sdl}
USERDIR=${USERDIR:-build/userdir-test-rml}
fail=0

[ -x "$ENGINE" ] || { echo "missing $ENGINE (run: make insanotic-client)" >&2; exit 2; }

expect() { # expect <description> <pattern> <log>
	if printf '%s\n' "$3" | grep -q -- "$2"; then
		echo "ok   $1"
	else
		echo "FAIL $1 (no match for: $2)"
		fail=1
	fi
}

reject() { # reject <description> <pattern> <log>
	if printf '%s\n' "$3" | grep -q -- "$2"; then
		echo "FAIL $1 (unexpected: $2)"
		fail=1
	else
		echo "ok   $1"
	fi
}

# The menu needs a good ten seconds to come up; the commands are spaced from
# there. The close button of the Settings dialog is at the top right of it.
log=$(timeout 120 "$ENGINE" -xonotic -basedir "$PWD" -userdir "$USERDIR" \
	+developer 1 +_cl_name RmlTest +vid_fullscreen 0 +vid_width 1280 +vid_height 720 +vid_touchscreen 0 \
	+defer 12 rml_list \
	+defer 13 "rml_click 1000 400" \
	+defer 15 rml_list \
	+defer 16 "rml_click 1058 119" \
	+defer 18 rml_list \
	+defer 19 quit 2>&1)

expect "RmlUi starts" "Loaded font face" "$log"
reject "no RmlUi warnings or errors" "^RmlUi: .*\(Could not\|No font\|not found\|did not\|Invalid\|Unknown\)" "$log"
expect "main menu document is showing" "mainmenu (shown)" "$log"
expect "click runs the button's command" "RmlUi: command menu_cmd directmenu settings" "$log"
expect "dialog replaces the document" "mainmenu (hidden)" "$log"
n=$(printf '%s\n' "$log" | grep -c "mainmenu (shown)")
if [ "$n" -ge 2 ]; then
	echo "ok   closing the dialog brings the document back"
else
	echo "FAIL closing the dialog brings the document back"
	fail=1
fi

# Touch screen: the list in tests/ui/scrolltest.rml is 40 rows high, the drag
# goes 250 pixels up, and the tap lands on a row after that.
echo "== touch screen"
log=$(timeout 120 "$ENGINE" -xonotic -game tests -basedir "$PWD" -userdir "$USERDIR" \
	+developer 1 +_cl_name RmlTest +vid_fullscreen 0 +vid_width 1280 +vid_height 720 +vid_touchscreen 1 \
	+defer 12 "rml_show scrolltest" \
	+defer 13 "rml_drag 640 450 640 200" \
	+defer 16 "rml_click 640 300" \
	+defer 18 quit 2>&1)

reject "no RmlUi warnings or errors" "^RmlUi: .*\(Could not\|No font\|not found\|did not\|Invalid\|Unknown\)" "$log"
expect "dragging the list scrolls it" "dragged a list to scroll position [0-9][0-9][0-9]" "$log"
reject "the drag does not click a row" "RmlUi: command echo ROW_" "$(printf '%s\n' "$log" | sed '/dragged a list/,$d')"
expect "tapping a row runs its command" "RmlUi: command echo ROW_" "$log"

# Quick settings: the Video tab has a slider on fov. A click in the middle of
# its track sets fov to roughly 80 (the track runs from 60 to 130).
echo "== bindings"
log=$(timeout 120 "$ENGINE" -xonotic -basedir "$PWD" -userdir "$USERDIR" \
	+developer 1 +_cl_name RmlTest +vid_fullscreen 0 +vid_width 1280 +vid_height 720 +vid_touchscreen 0 \
	+fov 120 \
	+defer 12 "rml_show quicksettings" \
	+defer 13 "rml_click 515 274" \
	+defer 14 "rml_click 700 340" \
	+defer 15 fov \
	+defer 16 quit 2>&1)
reject "no RmlUi warnings or errors" "^RmlUi: .*\(Could not\|No font\|not found\|did not\|Invalid\|Unknown\|Failed\)" "$log"
expect "the slider wrote the cvar" '"fov" is "[78][0-9]\.' "$log"

# Pages from a server need a running game (cl_allow_server_pages is set
# first: the last run of this test turns it off, and it is saved): a listen server with the example
# plugin. The example page has a Send button, answered by the plugin; the
# hostile page has one button for a local command, one for the server and one
# for an answer, and a field bound to a cvar that must stay unread.
echo "== pages from a server"
log=$(timeout 240 "$ENGINE" -xonotic -game tests -basedir "$PWD" -userdir "$USERDIR" \
	+developer 1 +g_lua 1 +cl_allow_server_pages 1 +_cl_name RmlTest +vid_fullscreen 0 +vid_width 1280 +vid_height 720 +vid_touchscreen 0 \
	+defer 8 "map stormkeep" \
	+defer 26 "cmd page" \
	+defer 28 rml_list \
	+defer 29 "rml_click 825 415" \
	+defer 31 rml_list \
	+defer 32 "rml_show_server ui/evil/page.rml" \
	+defer 34 rml_list \
	+defer 35 "rml_click 400 200" \
	+defer 35.5 "rml_click 400 340" \
	+defer 36 "rml_click 400 460" \
	+defer 37 "rml_click 1230 20" \
	+defer 38 rml_list \
	+defer 39 "cl_allow_server_pages 0" \
	+defer 39.5 "rml_show_server ui/evil/page.rml" \
	+defer 41 rml_list \
	+defer 42 quit 2>&1)
expect "a plugin opens a page" "server:ui/example_page/page.rml (shown)" "$log"
expect "the plugin hears the answer" "sent a note" "$log"
expect "a hostile page loads" "server:ui/evil/page.rml (shown)" "$log"
reject "a page cannot run a local command" "^EVIL_LOCAL_COMMAND" "$log"
expect "it is told so" "asked for a local command; refused" "$log"
expect "a page can send a command to the server" "RmlUi: to the server: echo SERVER_CMD_OK" "$log"
expect "an answer holds no cvar value" 'rml_reply "ui/evil/page.rml" "fine" "secret" ""' "$log"
n=$(printf '%s\n' "$log" | grep -c "server:ui/evil/page.rml (shown)")
if [ "$n" -eq 1 ]; then
	echo "ok   the band closes the page, and cl_allow_server_pages 0 refuses it"
else
	echo "FAIL the band closes the page, and cl_allow_server_pages 0 refuses it (page listed $n times)"
	fail=1
fi

# A finger is no pointer: no hover at all, and pressing is only for where it
# went down. tests/ui/touchtest.rml has one button; the finger goes down on
# empty space and drags over it, then goes down on it and drags off.
echo "== touch feedback"
log=$(timeout 120 "$ENGINE" -xonotic -game tests -basedir "$PWD" -userdir "$USERDIR" \
	+developer 1 +_cl_name RmlTest +vid_fullscreen 0 +vid_width 1280 +vid_height 720 +vid_touchscreen 1 \
	+defer 12 "rml_show touchtest" \
	+defer 13 "rml_touch down 100 100" \
	+defer 13.4 "rml_touch move 640 360" \
	+defer 13.8 "echo A; rml_state btn" \
	+defer 14.2 "rml_touch up" \
	+defer 14.6 "echo B; rml_state btn" \
	+defer 15 "rml_touch down 640 360" \
	+defer 15.4 "echo C; rml_state btn" \
	+defer 15.8 "rml_touch move 100 100" \
	+defer 16.2 "echo D; rml_state btn" \
	+defer 16.6 "rml_touch up" \
	+defer 17 "echo E; rml_state btn" \
	+defer 17.4 "rml_touch down 640 360" \
	+defer 17.8 "rml_touch up" \
	+defer 18.5 quit 2>&1)
reject "no RmlUi warnings or errors" "^RmlUi: .*\(Could not\|No font\|not found\|did not\|Invalid\|Unknown\|Failed\)" "$log"
expect "dragging in from empty space does not hover or press the button" "btn hover=0 active=0" "$(printf '%s\n' "$log" | sed -n '/^A *$/,/^B *$/p')"
expect "nothing stays lit after the finger lifts" "btn hover=0 active=0" "$(printf '%s\n' "$log" | sed -n '/^B *$/,/^C *$/p')"
expect "the button is pressed while the finger is on it, without hover" "btn hover=0 active=1" "$(printf '%s\n' "$log" | sed -n '/^C *$/,/^D *$/p')"
expect "dragging off it lets go" "btn hover=0 active=0" "$(printf '%s\n' "$log" | sed -n '/^D *$/,/^E *$/p')"
n=$(printf '%s\n' "$log" | grep -c "^TOUCH_CLICKED")
if [ "$n" -eq 1 ]; then
	echo "ok   only the tap clicked the button"
else
	echo "FAIL only the tap clicked the button (clicked $n times)"
	fail=1
fi

exit $fail
