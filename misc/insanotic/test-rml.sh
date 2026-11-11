#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# End-to-end test of the RmlUi main menu. Starts the client in a window (so it
# needs a display), waits for the menu and checks that
#   - ui/mainmenu.rml and its stylesheet load without a warning,
#   - the document is the one that is showing (rml_list),
#   - a click on the Settings button runs its command, and the menu answers by
#     opening the Settings dialog, which takes the RmlUi menu away again,
#   - closing that dialog brings it back.
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

exit $fail
