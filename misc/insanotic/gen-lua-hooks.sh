#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Generates the Lua hook forwarders and the hook reference from the server's
# MUTATOR_HOOKABLE declarations.
#
#   misc/insanotic/gen-lua-hooks.sh [qcsrc-dir] [out.qc] [out.md]
#
# Defaults (run from the repository root):
#   data/xonotic-data.pk3dir/qcsrc
#   <qcsrc>/common/mutators/mutator/lua/sv_lua_hooks.qc
#   docs/hooks.md
#
# Re-run it whenever a hook is added or changed in the game code.

set -eu

QCSRC=${1:-data/xonotic-data.pk3dir/qcsrc}
OUTQC=${2:-$QCSRC/common/mutators/mutator/lua/sv_lua_hooks.qc}
OUTMD=${3:-docs/hooks.md}

# hook declaration files compiled into the server, in documentation order
FILES="server/mutators/events.qh
common/mutators/events.qh
common/mutators/mutator/nades/nades.qh
common/mutators/mutator/random_items/sv_random_items.qh"

for f in $FILES; do
	[ -f "$QCSRC/$f" ] || { echo "missing $QCSRC/$f" >&2; exit 1; }
done

# hooks somebody registers with CBC_ORDER_EXCLUSIVE: adding any other
# callback to those chains makes that registration fail, so they are not
# forwarded
EXCLUSIVE=$(grep -rhoE 'MUTATOR_HOOKFUNCTION\([A-Za-z0-9_]+, *[A-Za-z0-9_]+, *CBC_ORDER_EXCLUSIVE' "$QCSRC" \
	| sed -E 's/.*, *([A-Za-z0-9_]+), *CBC_ORDER_EXCLUSIVE/\1/' | sort -u | tr '\n' ' ')

# record fields / parameters / parameter fields; control characters because
# descriptions may contain any printable character, and not IFS whitespace so
# empty fields survive "read"
TAB=$(printf '\037')
PS=$(printf '\036')
US=$(printf '\035')
RECORDS=$(for f in $FILES; do
	awk -v file="$f" -v TAB="$TAB" -v PS="$PS" -v US="$US" '
	function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
	function clean_doc(s) {
		gsub(/\/\*\*?/, "", s); gsub(/\*\//, "", s)
		gsub(/\n[ \t]*\*[ \t]?/, "\n", s)
		gsub(/[ \t]*\n[ \t]*/, " ", s)
		gsub(/\|/, "\\|", s)
		return trim(s)
	}
	BEGIN { indoc = 0; doc = ""; indef = 0; pending = "" }
	{
		line = $0
		if (pending != "") { line = pending " " line; pending = "" }
		if (line ~ /MUTATOR_HOOKABLE\(/ && line !~ /\)/) { pending = line; next }

		if (indef) {
			if (match(line, /[io]\([a-z]+, *MUTATOR_ARGV_[0-9]+_[a-z]+\)/)) {
				call = substr(line, RSTART, RLENGTH)
				dir = substr(call, 1, 1)
				type = call; sub(/^[io]\(/, "", type); sub(/,.*/, "", type)
				idx = call; sub(/.*MUTATOR_ARGV_/, "", idx); sub(/_.*/, "", idx)
				desc = ""
				if (match(line, /\/\*\*[^*]*\*\//)) desc = clean_doc(substr(line, RSTART, RLENGTH))
				gsub(/\|/, "\\|", desc)
				params[defname] = params[defname] (params[defname] == "" ? "" : PS) dir US type US idx US desc
			}
			if (line !~ /\\[ \t]*$/) indef = 0
			next
		}

		if (match(line, /^[ \t]*#define EV_[A-Za-z0-9_]+\(i, *o\)/)) {
			defname = line; sub(/^[ \t]*#define /, "", defname); sub(/\(.*/, "", defname)
			params[defname] = ""
			docs[defname] = clean_doc(doc)
			doc = ""
			indef = (line ~ /\\[ \t]*$/)
			next
		}

		if (match(line, /MUTATOR_HOOKABLE\([A-Za-z0-9_]+,[ \t]*[A-Za-z0-9_]+[ \t]*\)/)) {
			decl = substr(line, RSTART, RLENGTH)
			name = decl; sub(/MUTATOR_HOOKABLE\(/, "", name); sub(/,.*/, "", name)
			ev = decl; sub(/.*,[ \t]*/, "", ev); sub(/[ \t]*\)/, "", ev)
			if (ev == "EV_NO_ARGS") { p = ""; d = clean_doc(doc) } else { p = params[ev]; d = docs[ev] }
			print name TAB file TAB p TAB d
			doc = ""
			next
		}

		if (indoc) {
			doc = doc "\n" line
			if (line ~ /\*\//) indoc = 0
			next
		}
		if (line ~ /^[ \t]*\/\*\*/ && line !~ /^[ \t]*\/\*\*\/[ \t]*$/) {
			doc = line
			indoc = (line !~ /\*\//)
			next
		}
		if (line ~ /^[ \t]*\/\/\// ) { s = line; sub(/^[ \t]*\/\/\/[ \t]?/, "", s); doc = doc "\n" s; next }
		if (trim(line) == "") doc = ""
	}' "$QCSRC/$f"
done)

# call sites in server-side code: hook name, then "used" when the call is
# part of an expression (its result matters) or "ignored" when it is a bare
# statement
CALLSITES=$(grep -rhE --exclude='cl_*' 'MUTATOR_CALLHOOK\([A-Za-z0-9_]+' "$QCSRC/server" "$QCSRC/common" "$QCSRC/ecs" "$QCSRC/lib" 2>/dev/null \
	| awk '{
		line = $0
		while (match(line, /MUTATOR_CALLHOOK\([A-Za-z0-9_]+/)) {
			name = substr(line, RSTART + 17, RLENGTH - 17)
			bare = (substr(line, 1, RSTART - 1) ~ /^[ \t]*$/)
			print name, (bare ? "ignored" : "used")
			line = substr(line, RSTART + RLENGTH)
		}
	}' | sort -u)

returns() {
	r=$(printf '%s\n' "$CALLSITES" | awk -v n="$1" '$1 == n { print $2 }' | sort -u | tr '\n' ' ')
	case $r in
		*used*) echo "**used**: the game checks the combined result (see the description for what \`true\` does)" ;;
		*ignored*) echo "ignored: every call site discards it" ;;
		*) echo "no server-side call site found" ;;
	esac
}

COUNT=$(printf '%s\n' "$RECORDS" | grep -c . || true)
[ "$COUNT" -gt 0 ] || { echo "no hooks found" >&2; exit 1; }

is_exclusive() {
	case " $EXCLUSIVE " in *" $1 "*) return 0 ;; esac
	return 1
}

letter() {
	case $1 in
		bool) echo b ;; int) echo i ;; float) echo f ;;
		vector) echo v ;; string) echo s ;; entity) echo e ;;
		*) echo "unknown hook argument type $1" >&2; exit 1 ;;
	esac
}

mkdir -p "$(dirname "$OUTQC")" "$(dirname "$OUTMD")"

# ---------------------------------------------------------------- QuakeC
{
	echo "// generated by misc/insanotic/gen-lua-hooks.sh; do not modify"
	echo "// SPDX-License-Identifier: GPL-3.0-or-later"
	echo "#include \"sv_lua.qh\""
	echo ""
	echo "// Every server hook is forwarded to the Lua plugins. lua_hookcount() keeps"
	echo "// hooks that no plugin listens to down to a single builtin call."
	printf '%s\n' "$RECORDS" | while IFS="$TAB" read -r name file params doc; do
		[ -n "$name" ] || continue
		if is_exclusive "$name"; then
			echo ""
			echo "// $name: not forwarded (registered with CBC_ORDER_EXCLUSIVE)"
			continue
		fi
		sig=""
		if [ -n "$params" ]; then
			oldifs=$IFS; IFS=$PS
			for p in $params; do
				dir=${p%%"$US"*}; rest=${p#*"$US"}; type=${rest%%"$US"*}; rest=${rest#*"$US"}; idx=${rest%%"$US"*}
				l=$(letter "$type")
				if [ "$dir" = o ]; then sig="$sig >$l$idx"; else sig="$sig $l$idx"; fi
			done
			IFS=$oldifs
		fi
		sig=${sig# }
		echo ""
		echo "MUTATOR_HOOKFUNCTION(lua, $name)"
		echo "{"
		echo "	if (!lua_hookcount(\"$name\")) return false;"
		echo "	return lua_hook(\"$name\", \"$sig\") != 0;"
		echo "}"
	done
} > "$OUTQC"

# ---------------------------------------------------------------- Markdown
{
	echo "# Server hooks"
	echo ""
	echo "<!-- generated by misc/insanotic/gen-lua-hooks.sh; do not edit by hand -->"
	echo ""
	echo "Every hook the 0.8.6 server game code exposes through \`MUTATOR_HOOKABLE\`,"
	echo "with its arguments and return semantics. Lua plugins subscribe with"
	echo "\`xon.on(\"<HookName>\", function(ev) ... end)\`."
	echo ""
	echo "## How hooks behave"
	echo ""
	echo "- Arguments live in the QuakeC globals \`MUTATOR_ARGV_<n>_<type>\`. In Lua they"
	echo "  are \`ev[n]\` (the same index \`n\`), and \`ev.hook\` is the hook name."
	echo "- **in** arguments are read when the hook fires. **out** arguments are"
	echo "  written back after all handlers ran: assign \`ev[n] = value\` to change"
	echo "  them. An argument listed as both in and out arrives with the current value"
	echo "  and can be modified."
	echo "- Return value: the game ORs together the return values of every"
	echo "  callback (QuakeC mutators and Lua handlers). Each hook below says whether"
	echo "  its call sites use that result; where they do, \`true\` means what the"
	echo "  description says (usually \"block\" or \"handled\") and \`false\`/\`nil\`"
	echo "  keeps the default behaviour."
	echo "- Entities are handles (\`nil\` for world/none); vectors are \`xon.vec\`"
	echo "  tables; \`bool\` arguments are Lua booleans; \`int\` arguments are integers."
	echo "- Handlers run in plugin load order, then in registration order within a plugin."
	echo "  Each plugin sees the out-values left by the previous plugin."
	echo ""
	if [ -n "$EXCLUSIVE" ]; then
		echo "Hooks that some gamemode claims with \`CBC_ORDER_EXCLUSIVE\` cannot have"
		echo "extra callbacks and are **not forwarded to Lua**: $(echo $EXCLUSIVE | sed 's/\([A-Za-z0-9_]*\)/`\1`/g; s/ /, /g')."
		echo ""
	fi
	echo "$COUNT hooks. Source paths are relative to \`qcsrc/\`."
	echo ""
	echo "## Index"
	echo ""
	printf '%s\n' "$RECORDS" | while IFS="$TAB" read -r name file params doc; do
		[ -n "$name" ] || continue
		anchor=$(echo "$name" | tr 'A-Z' 'a-z')
		echo "[\`$name\`](#$anchor)"
	done | paste -sd' ' - | sed 's/) \[/) · [/g'
	echo ""
	lastfile=""
	printf '%s\n' "$RECORDS" | while IFS="$TAB" read -r name file params doc; do
		[ -n "$name" ] || continue
		if [ "$file" != "$lastfile" ]; then
			echo "## \`$file\`"
			echo ""
			lastfile=$file
		fi
		echo "### $name"
		echo ""
		[ -n "$doc" ] && { echo "$doc"; echo ""; }
		if is_exclusive "$name"; then
			echo "_Not forwarded to Lua (exclusive hook)._"
			echo ""
		fi
		echo "Return value: $(returns "$name")."
		echo ""
		if [ -z "$params" ]; then
			echo "No arguments."
		else
			echo "| ev | dir | type | description |"
			echo "|---|---|---|---|"
			oldifs=$IFS; IFS=$PS
			for p in $params; do
				dir=${p%%"$US"*}; rest=${p#*"$US"}; type=${rest%%"$US"*}; rest=${rest#*"$US"}; idx=${rest%%"$US"*}; desc=${rest#*"$US"}
				[ "$dir" = o ] && dir=out || dir=in
				echo "| $idx | $dir | $type | $desc |"
			done
			IFS=$oldifs
		fi
		echo ""
	done
} > "$OUTMD"

echo "wrote $COUNT hooks to $OUTQC and $OUTMD"
