#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# End-to-end test of the server Lua plugin loader. Runs the dedicated server
# twice on stormkeep with bots:
#   1. g_lua 0: no plugin may load (stock behaviour)
#   2. g_lua 1 with tests/plugins/ on top of the normal data: the sandbox
#      probes must all be blocked, the runaway, pcall-escape, memory-hog and
#      error plugins must be disabled, sv_lua_reload must work mid-match and
#      the server must still answer afterwards.
#
#   misc/insanotic/test-plugins.sh        (from the repository root)
#
# Needs the dedicated engine, the compiled QC and the stormkeep map
# ("make insanotic-server insanotic-qc insanotic-map" does all three).

set -u

ENGINE=${ENGINE:-./darkplaces/darkplaces-dedicated}
PORT=${PORT:-26099}
USERDIR=${USERDIR:-build/userdir-test}
fail=0

[ -x "$ENGINE" ] || { echo "missing $ENGINE (run: make insanotic-server)" >&2; exit 2; }

run() {
	timeout 90 "$ENGINE" -xonotic "$@" -userdir "$USERDIR" +port "$PORT" \
		+set bot_join_empty 1 +set bot_number 2 +set g_warmup 0 2>&1
}

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

echo "== g_lua 0"
log=$(run -game tests +set g_lua 0 +map stormkeep +defer 5 "echo TEST_ALIVE" +defer 6 quit)
expect "server runs" "TEST_ALIVE" "$log"
reject "no plugin loads" "\[lua\] loaded plugin" "$log"

echo "== g_lua 1"
log=$(run -game tests +set g_lua 1 +set sv_lua_memory_limit 8 +map stormkeep \
	+defer 6 sv_lua_plugins +defer 7 sv_lua_reload +defer 9 "echo TEST_ALIVE" +defer 10 quit)
expect "hello loads" "loaded plugin hello" "$log"
expect "hello sees spawns" "\[hello\].* spawned at" "$log"
reject "sandbox probes all blocked" "\[jailbreak\].*: OPEN" "$log"
expect "sandbox probes ran" "\[jailbreak\].*readonly cvar: blocked" "$log"
expect "runaway loop disabled" "plugin runaway disabled" "$log"
expect "pcall escape disabled" "plugin sneaky disabled" "$log"
expect "memory hog disabled" "plugin memhog disabled" "$log"
expect "error disabled with traceback" "plugin thrower .*deliberate failure" "$log"
expect "reload mid-match" "reloading plugins" "$log"
expect "server still running" "TEST_ALIVE" "$log"

[ $fail -eq 0 ] && echo "all plugin tests passed" || echo "plugin tests FAILED"
exit $fail
