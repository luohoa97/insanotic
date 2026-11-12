#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# End-to-end test of the map previews of the server list (netconn.c). It
# starts a dedicated server on a map the client has no picture of (the map
# "boil" of the official maps pack, copied as "ptest" into the server's own
# folder) and checks that
#   - the server says it can send a picture (inspreview in its infoResponse),
#     and does not with sv_mappreview 0,
#   - a request with a made-up challenge gets no answer at all,
#   - a client with the server in its favorites asks for the picture and
#     keeps it as mappreviews/ptest-<crc>.jpg.
#
#   misc/insanotic/test-mappreview.sh        (from the repository root)
#
# Needs the dedicated engine and the SDL client, the compiled QC, nc and unzip.

set -u

SERVER=${SERVER:-./darkplaces/darkplaces-dedicated}
CLIENT=${CLIENT:-./darkplaces/darkplaces-sdl}
PORT=${PORT:-26111}
PORT2=${PORT2:-26112}
SRVDIR=${SRVDIR:-build/userdir-test-mappreview-srv}
CLDIR=${CLDIR:-build/userdir-test-mappreview}
MAPS=$(ls data/xonotic-*-maps.pk3 2>/dev/null | head -1)
fail=0

for f in "$SERVER" "$CLIENT"; do
	[ -x "$f" ] || { echo "missing $f (run: make insanotic-server insanotic-client)" >&2; exit 2; }
done
command -v nc >/dev/null && command -v unzip >/dev/null || { echo "needs nc and unzip" >&2; exit 2; }
[ -n "$MAPS" ] || { echo "missing the official maps pack in data/" >&2; exit 2; }

check() { # check <description> <condition: 0 = ok>
	if [ "$2" -eq 0 ]; then
		echo "ok   $1"
	else
		echo "FAIL $1"
		fail=1
	fi
}

# the server's own copy of a map, under a name the client has never seen
mkdir -p "$SRVDIR/data/maps"
unzip -p "$MAPS" maps/boil.bsp > "$SRVDIR/data/maps/ptest.bsp"
unzip -p "$MAPS" maps/boil.jpg > "$SRVDIR/data/maps/ptest.jpg"

start_server() { # start_server <port> <extra cvars...>
	port=$1
	shift
	timeout 150 "$SERVER" -xonotic -basedir "$PWD" -userdir "$SRVDIR" +port "$port" \
		+sv_public 0 +hostname "Preview test" +map ptest +maxplayers 4 "$@" >"$SRVDIR/log-$port.txt" 2>&1 &
	# the map takes a while
	n=0
	while [ "$n" -lt 40 ] && ! grep -q "spawned" "$SRVDIR/log-$port.txt" 2>/dev/null; do
		sleep 1
		n=$((n + 1))
	done
	sleep 2
}

ask() { # ask <port> <packet text>: the server's answer, if any
	printf '\377\377\377\377%s' "$2" | nc -u -w1 127.0.0.1 "$1" 2>/dev/null
}

start_server "$PORT"
ask "$PORT" "getinfo x" | grep -aq 'inspreview.1'
check "the server says it can send a picture" $?

answer=$(ask "$PORT" "getmappreview madeupchal ptest" | wc -c)
[ "$answer" -eq 0 ]
check "a request with a made-up challenge gets no answer" $?

rm -rf "$CLDIR/data/mappreviews"
log=$(timeout 100 "$CLIENT" -xonotic -basedir "$PWD" -userdir "$CLDIR" \
	+developer 1 +_cl_name PreviewTest +vid_fullscreen 0 +vid_width 1280 +vid_height 720 +vid_touchscreen 0 \
	+net_slist_favorites "127.0.0.1:$PORT" \
	+defer 10 "rml_show servers" \
	+defer 20 quit 2>&1)
printf '%s\n' "$log" | grep -q "map preview of ptest: kept"
check "the client asks for the picture and keeps it" $?
ls "$CLDIR"/data/mappreviews/ptest-*.jpg >/dev/null 2>&1
check "it is stored as mappreviews/ptest-<crc>.jpg" $?

start_server "$PORT2" +sv_mappreview 0
ask "$PORT2" "getinfo x" | grep -aq 'inspreview'
[ $? -ne 0 ]
check "with sv_mappreview 0 the server does not offer one" $?

exit $fail
