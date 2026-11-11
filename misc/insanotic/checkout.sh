#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Clones the repositories Insanotic is built from next to this one, at the
# revisions this checkout expects:
#   darkplaces/                  engine           (Insanotic fork)
#   data/xonotic-data.pk3dir/    game code + data (Insanotic fork, ~650 MB)
#   gmqcc/                       QuakeC compiler  (upstream, xonotic-v0.8.6)
#
#   misc/insanotic/checkout.sh            (from the repository root)
#
# Existing checkouts are left alone.

set -eu

GH=${INSANOTIC_GITHUB:-https://github.com/luohoa97}

clone() { # clone <dir> <url> <branch-or-tag> [extra git args]
	dir=$1 url=$2 ref=$3
	shift 3
	if [ -d "$dir/.git" ]; then
		echo "$dir: already checked out"
		return
	fi
	echo "$dir: cloning $url ($ref)"
	git clone "$@" --branch "$ref" "$url" "$dir"
}

clone darkplaces "$GH/insanotic-darkplaces.git" insanotic
clone data/xonotic-data.pk3dir "$GH/insanotic-data.git" insanotic
clone gmqcc https://gitlab.com/xonotic/gmqcc.git xonotic-v0.8.6 --depth 1

echo "done; next: make run-server"
